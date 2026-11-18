#include <algorithm>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <vector>

#include "bark/bridge/barc_bridge_functions.h"
#include "bark/bridge/bridge_internal.h"
#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_window_host.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "chrome/browser/file_select_helper.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/browser_widget.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_request_manager.h"
#include "components/tabs/public/tab_interface.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/document_user_data.h"
#include "bark/browser/ui/native_space_page.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"

namespace {

using barc::internal::LookupTab;
using barc::internal::Window;

class SwitchDocument : public content::DocumentUserData<SwitchDocument> {
 public:
  uint64_t id() const { return id_; }

 private:
  friend class content::DocumentUserData<SwitchDocument>;
  explicit SwitchDocument(content::RenderFrameHost* frame)
      : DocumentUserData(frame), id_(++next_id_) {}

  static inline uint64_t next_id_ = 0;
  const uint64_t id_;
  DOCUMENT_USER_DATA_KEY_DECL();
};
DOCUMENT_USER_DATA_KEY_IMPL(SwitchDocument);

struct PromptSnapshot {
  BarcSpaceSwitchPrompt record;
  content::WeakDocumentPtr document;
  base::WeakPtr<permissions::PermissionRequest> permission;
  std::shared_ptr<const FileSelectHelper::UploadChooserState> upload;
};

struct Selection {
  int32_t client = 0;
  int32_t tab = 0;
  bool operator==(const Selection&) const = default;
};

struct PhysicalWindow {
  explicit PhysicalWindow(BrowserWindowInterface* browser) {
    if (auto* bark_host = bark::BarkWindowHost::ForBrowser(browser)) {
      group = bark_host->physical_group();
      host = bark_host->GetWeakPtr();
    } else if (auto* view = browser
                                ? BrowserView::GetBrowserViewForBrowser(browser)
                                : nullptr) {
      if (auto* browser_widget = view->browser_widget()) {
        group = browser_widget->barc_physical_group();
        widget = browser_widget->GetWeakPtr();
      }
    }
  }

  BrowserWindowInterface* SelectedClient() const {
    if (host && !host->closing() && host->selected()) {
      return host->selected()->browser();
    }
    if (widget && !widget->IsClosed()) {
      auto* browser_widget = static_cast<BrowserWidget*>(widget.get());
      auto* view = browser_widget->selected_browser_view();
      if (view && !browser_widget->IsPhysicalCloseCommitted()) {
        return view->browser();
      }
    }
    return nullptr;
  }

  Selection Selected() const {
    auto* browser = SelectedClient();
    if (!browser || browser->IsDeleteScheduled()) {
      return {};
    }
    auto* tab = browser->GetTabStripModel()->GetActiveTab();
    return {browser->GetSessionID().id(),
            tab && !bark::IsNativeSpacePageSuppressed(browser)
                ? tab->GetHandle().raw_value()
                : 0};
  }

  uint64_t group = 0;
  base::WeakPtr<bark::BarkWindowHost> host;
  base::WeakPtr<views::Widget> widget;
};

PromptSnapshot Snapshot(BarcSpaceSwitchPromptKind kind,
                        Selection source,
                        content::RenderFrameHost* frame) {
  return {
      .record = {.size = sizeof(BarcSpaceSwitchPrompt),
                 .kind = kind,
                 .client = source.client,
                 .tab = source.tab,
                 .document = SwitchDocument::GetOrCreateForCurrentDocument(
                                 frame)->id()},
      .document = frame->GetWeakDocumentPtr(),
  };
}

bool HasModal(content::WebContents* contents) {
  auto* manager =
      web_modal::WebContentsModalDialogManager::FromWebContents(contents);
  return manager && manager->IsDialogActive();
}

void CaptureUploads(Selection source,
                    content::WebContents* contents,
                    std::vector<PromptSnapshot>& prompts) {
  for (auto& chooser : FileSelectHelper::GetLiveUploadChoosers(contents)) {
    if (auto* frame = chooser->document.AsRenderFrameHostIfValid()) {
      auto prompt = Snapshot(BARC_SPACE_SWITCH_UPLOAD, source, frame);
      prompt.upload = std::move(chooser);
      prompts.push_back(std::move(prompt));
    }
  }
}

std::vector<PromptSnapshot> CapturePrompts(Selection source,
                                           content::WebContents* contents) {
  std::vector<PromptSnapshot> prompts;
  auto* manager =
      permissions::PermissionRequestManager::FromWebContents(contents);
  if (manager) {
    for (const auto& request : manager->Requests()) {
      if (auto* frame = content::RenderFrameHost::FromID(
              request->get_requesting_frame_id())) {
        auto prompt = Snapshot(BARC_SPACE_SWITCH_PERMISSION, source, frame);
        prompt.permission = request->GetWeakPtr();
        prompts.push_back(std::move(prompt));
      }
    }
  }
  CaptureUploads(source, contents, prompts);
  if (HasModal(contents)) {
    prompts.push_back(Snapshot(BARC_SPACE_SWITCH_TAB_MODAL, source,
                               contents->GetPrimaryMainFrame()));
  }
  return prompts;
}

int32_t PromptDisposition(const PromptSnapshot& prompt) {
  if (prompt.upload && prompt.upload->cancelled) {
    return BARC_SPACE_SWITCH_PROMPT_CANCELLED;
  }
  auto* frame = prompt.document.AsRenderFrameHostIfValid();
  if (!frame ||
      frame->GetLifecycleState() !=
          content::RenderFrameHost::LifecycleState::kActive) {
    return BARC_SPACE_SWITCH_PROMPT_RETIRED;
  }
  auto* contents = content::WebContents::FromRenderFrameHost(frame);
  auto* tab = LookupTab(Window(prompt.record.client), prompt.record.tab);
  if (!tab || tab->GetContents() != contents) {
    return BARC_SPACE_SWITCH_PROMPT_RETIRED;
  }
  if (prompt.record.kind == BARC_SPACE_SWITCH_PERMISSION) {
    auto* manager =
        permissions::PermissionRequestManager::FromWebContents(contents);
    if (!manager || !prompt.permission ||
        !manager->HasPendingRequest(*prompt.permission)) {
      return BARC_SPACE_SWITCH_PROMPT_RETIRED;
    }
    const bool shown = manager->GetCurrentPrompt() &&
        std::ranges::any_of(manager->Requests(), [&](const auto& request) {
          return request.get() == prompt.permission.get();
        });
    return shown ? BARC_SPACE_SWITCH_PROMPT_RETAINED
                 : BARC_SPACE_SWITCH_PROMPT_PARKED;
  }
  if (prompt.upload) {
    const auto live = FileSelectHelper::GetLiveUploadChoosers(contents);
    if (!std::ranges::contains(live, prompt.upload)) {
      return BARC_SPACE_SWITCH_PROMPT_RETIRED;
    }
    return prompt.upload->native_panel_is_running
               ? BARC_SPACE_SWITCH_PROMPT_RETAINED
               : BARC_SPACE_SWITCH_PROMPT_WAITING;
  }
  return HasModal(contents) ? BARC_SPACE_SWITCH_PROMPT_RETAINED
                            : BARC_SPACE_SWITCH_PROMPT_RETIRED;
}

struct PendingSwitch {
  BarcSpaceSwitchRequest request;
  BarcSpaceSwitchCallback callback;
  raw_ptr<void> context;
  BarcSpaceSwitchResult result;
  std::vector<BarcSpaceSwitchPrompt> prompts;
  std::vector<PromptSnapshot> outgoing;
};

struct Batch {
  std::deque<PendingSwitch> requests;
};

std::map<uint64_t, Batch*>& ActiveBatches() {
  static base::NoDestructor<std::map<uint64_t, Batch*>> batches;
  return *batches;
}

int32_t SelectSpace(const PhysicalWindow& window,
                    PendingSwitch& pending,
                    const Batch& batch) {
  const auto request = pending.request;
  const auto before = window.Selected();
  if (!before.client) {
    return BARC_SPACE_SWITCH_CLOSED;
  }
  auto* client = Window(request.client);
  if (barc::internal::navigation_callback_depth || !client ||
      PhysicalWindow(client).group != window.group ||
      client->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
      (request.tab && !LookupTab(client, request.tab))) {
    return BARC_SPACE_SWITCH_REFUSED;
  }
  auto* outgoing = before != Selection{request.client, request.tab}
                       ? LookupTab(Window(before.client), before.tab)
                       : nullptr;
  if (outgoing) {
    pending.outgoing = CapturePrompts(before, outgoing->GetContents());
  }
  if (before.client != request.client) {
    auto* previous = window.SelectedClient()->GetTabStripModel();
    for (int index = 0; index < previous->count(); ++index) {
      auto* tab = previous->GetTabAtIndex(index);
      const int32_t handle = tab->GetHandle().raw_value();
      if (handle != before.tab) {
        CaptureUploads({before.client, handle}, tab->GetContents(),
                       pending.outgoing);
      }
    }
  }
  if (outgoing && HasModal(outgoing->GetContents())) {
    return BARC_SPACE_SWITCH_REFUSED;
  }

  const auto count_before = batch.requests.size();
  auto destination_alive = client->GetWeakPtr();
  // Mark a parked destination before activation, so a permission prompt
  // cannot reopen during the owner callback sequence for an empty space.
  const bool suppressing =
      !request.tab && bark::SetNativeSpacePageSuppressed(client, true);
  const bool selected = window.host
      ? window.host->Select(bark::BarkBrowserWindow::FromBrowser(client))
      : static_cast<BrowserWidget*>(window.widget.get())
            ->SelectLogicalBrowserView(BrowserView::GetBrowserViewForBrowser(client));
  if (suppressing && destination_alive) {
    if (selected && destination_alive->IsSelectedForNativeWindow()) {
      if (before.client == request.client) {
        destination_alive->NotifyNativeWindowSelectionChanged();
        barc::BrowserDiscoveryChanged();
      }
    } else {
      bark::SetNativeSpacePageSuppressed(destination_alive.get(), false);
    }
  }
  const auto settled = window.Selected();
  if (!settled.client) {
    return BARC_SPACE_SWITCH_CLOSED;
  }
  if (batch.requests.size() != count_before) {
    return BARC_SPACE_SWITCH_SUPERSEDED;
  }
  if (!selected || settled.client != request.client) {
    return settled == before ? BARC_SPACE_SWITCH_REFUSED
                             : BARC_SPACE_SWITCH_SUPERSEDED;
  }

  if (request.tab) {
    auto* tab = LookupTab(destination_alive.get(), request.tab);
    if (!tab) {
      return settled == before ? BARC_SPACE_SWITCH_REFUSED
                               : BARC_SPACE_SWITCH_SUPERSEDED;
    }
    auto contents = tab->GetContents()->GetWeakPtr();
    auto* strip = destination_alive->GetTabStripModel();
    strip->ActivateTabAt(strip->GetIndexOfWebContents(contents.get()));
    if (!window.Selected().client) {
      return BARC_SPACE_SWITCH_CLOSED;
    }
    if (!destination_alive || !contents ||
        batch.requests.size() != count_before ||
        window.SelectedClient() != destination_alive.get() ||
        destination_alive->GetTabStripModel()->GetActiveWebContents() !=
            contents.get()) {
      return BARC_SPACE_SWITCH_SUPERSEDED;
    }
    if (bark::SetNativeSpacePageSuppressed(destination_alive.get(), false)) {
      destination_alive->NotifyNativeWindowSelectionChanged();
      barc::BrowserDiscoveryChanged();
    }
    if (contents && batch.requests.size() == count_before &&
        window.Selected() == Selection{request.client, request.tab}) {
      contents->Focus();
    }
    const auto focused = window.Selected();
    if (!focused.client) {
      return BARC_SPACE_SWITCH_CLOSED;
    }
    if (batch.requests.size() != count_before ||
        focused != Selection{request.client, request.tab}) {
      return BARC_SPACE_SWITCH_SUPERSEDED;
    }
  }
  return BARC_SPACE_SWITCH_APPLIED;
}

}  // namespace

int barc_window_switch_space(const BarcSpaceSwitchRequest* request,
                             BarcSpaceSwitchCallback callback, void* context) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      !request || request->size < sizeof(BarcSpaceSwitchRequest) ||
      request->request == 0 || request->window <= 0 || request->client <= 0 ||
      request->tab < 0 || !callback) {
    return 0;
  }
  auto* anchor = Window(request->window);
  const PhysicalWindow window(anchor);
  const uint64_t group = window.group;
  PendingSwitch pending{
      .request = *request,
      .callback = callback,
      .context = context,
      .result = {.size = sizeof(BarcSpaceSwitchResult),
                 .request = request->request,
                 .physical_group = group},
  };
  if (!group) {
    pending.result.status = anchor ? BARC_SPACE_SWITCH_REFUSED
                                   : BARC_SPACE_SWITCH_CLOSED;
    callback(&pending.result, context);
    return 1;
  }
  if (auto active = ActiveBatches().find(group); active != ActiveBatches().end()) {
    active->second->requests.push_back(std::move(pending));
    return 1;
  }

  Batch batch;
  batch.requests.push_back(std::move(pending));
  ActiveBatches().emplace(group, &batch);
  for (size_t i = 0; i < batch.requests.size(); ++i) {
    auto& item = batch.requests[i];
    item.result.status = i + 1 == batch.requests.size()
                             ? SelectSpace(window, item, batch)
                             : BARC_SPACE_SWITCH_SUPERSEDED;
  }
  ActiveBatches().erase(group);

  const auto final_selection = window.Selected();
  for (auto& item : batch.requests) {
    if (!final_selection.client) {
      item.result.status = BARC_SPACE_SWITCH_CLOSED;
    } else if (&item != &batch.requests.back()) {
      item.result.status = BARC_SPACE_SWITCH_SUPERSEDED;
    }
    item.result.selected_client = final_selection.client;
    item.result.active_tab = final_selection.tab;
    for (auto& prompt : item.outgoing) {
      prompt.record.disposition = PromptDisposition(prompt);
      item.prompts.push_back(prompt.record);
    }
  }
  // Capture every result before delivering any. Selection invoked from a
  // completion is an independent event and cannot change this settled batch.
  for (auto& item : batch.requests) {
    item.result.prompts = item.prompts.empty() ? nullptr : item.prompts.data();
    item.result.prompt_count = item.prompts.size();
    item.callback(&item.result, item.context);
  }
  return 1;
}
