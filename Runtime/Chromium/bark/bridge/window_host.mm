#import <AppKit/AppKit.h>

#include <cmath>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "bark/bridge/barc_bridge_functions.h"
#include "bark/bridge/bridge_internal.h"
#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_extension_popup.h"
#include "bark/browser/ui/bark_window_host.h"
#include "base/check.h"
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/common/extension.h"

using namespace barc::internal;

namespace {

bool OnUIThread() {
  return content::BrowserThread::CurrentlyOn(content::BrowserThread::UI);
}

struct ActionTarget {
  raw_ptr<BrowserWindowInterface> browser;
  raw_ptr<content::WebContents> contents;
  raw_ptr<ToolbarActionsModel> model;
  raw_ptr<extensions::ExtensionRegistry> registry;
};

std::optional<ActionTarget> FindActionTarget(int32_t id, int32_t tab_id) {
  if (!OnUIThread()) {
    return std::nullopt;
  }
  auto* browser = Window(id);
  auto* host = bark::BarkWindowHost::ForBrowser(browser);
  if (!host || host->closing() || browser->IsDeleteScheduled() ||
      !browser->IsSelectedForNativeWindow()) {
    return std::nullopt;
  }
  auto* profile = browser->GetProfile();
  if (profile->IsGuestSession() || profile->IsOffTheRecord()) {
    return std::nullopt;
  }
  auto* tab = LookupTab(browser, tab_id);
  auto* contents = tab ? tab->GetContents() : nullptr;
  if (!contents || contents->GetBrowserContext() != profile ||
      contents != browser->GetTabStripModel()->GetActiveWebContents() ||
      !host->IsPageMounted(contents)) {
    return std::nullopt;
  }
  auto* model = ToolbarActionsModel::Get(profile);
  auto* registry = extensions::ExtensionRegistry::Get(profile);
  if (!model || !registry) {
    return std::nullopt;
  }
  return ActionTarget{browser, contents, model, registry};
}

const extensions::Extension* AvailableAction(const ActionTarget& target,
                                             const std::string& id) {
  return target.model->actions_initialized() && target.model->HasAction(id)
             ? target.registry->enabled_extensions().GetByID(id)
             : nullptr;
}

struct ActionRow {
  std::string id;
  std::string title;
  std::string badge;
  int flags;
};

BarcFullscreenKind Kind(bark::HostFullscreen fullscreen) {
  switch (fullscreen) {
    case bark::HostFullscreen::kNone:
      return BARC_FULLSCREEN_NONE;
    case bark::HostFullscreen::kWindow:
      return BARC_FULLSCREEN_WINDOW;
    case bark::HostFullscreen::kPage:
      return BARC_FULLSCREEN_PAGE;
  }
}

// One window_host_observe registration. It forwards the host's notices as
// posted events, which still arrive after the host is gone.
class HostObservation : public bark::BarkWindowHost::Observer,
                        public ToolbarActionsModel::Observer {
 public:
  HostObservation(uint64_t token,
                  bark::BarkWindowHost* host,
                  BarcWindowHostCallback callback,
                  void* context)
      : token_(token),
        host_(host->GetWeakPtr()),
        callback_(callback),
        context_(context) {
    host->AddObserver(this);
  }
  ~HostObservation() override {
    if (host_) {
      host_->RemoveObserver(this);
    }
  }

  void OnPageViewRetiring(int32_t window,
                          int32_t tab,
                          gfx::NativeView view) override {
    Post(BarcWindowHostEvent{.size = sizeof(BarcWindowHostEvent),
                             .kind = BARC_WINDOW_HOST_PAGE_VIEW_RETIRED,
                             .window = window,
                             .tab = tab},
         view.GetNativeNSView());
  }
  void OnPageCrashed(int32_t window,
                     int32_t tab,
                     gfx::NativeView view,
                     bool crashed) override {
    Post(BarcWindowHostEvent{.size = sizeof(BarcWindowHostEvent),
                             .kind = crashed ? BARC_WINDOW_HOST_PAGE_CRASHED
                                             : BARC_WINDOW_HOST_PAGE_RESTORED,
                             .window = window,
                             .tab = tab},
         view.GetNativeNSView());
  }
  void OnFullscreenChanged(int32_t window,
                           bark::HostFullscreen fullscreen) override {
    Post(BarcWindowHostEvent{.size = sizeof(BarcWindowHostEvent),
                             .kind = BARC_WINDOW_HOST_FULLSCREEN_CHANGED,
                             .window = window,
                             .fullscreen = Kind(fullscreen)},
         nil);
  }

  void ObserveActions(bark::BarkWindowHost* host,
                      ToolbarActionsModel* model,
                      int32_t owner) {
    if (host_.get() != host) {
      return;
    }
    action_owner_ = owner;
    if (!actions_.IsObservingSource(model)) {
      actions_.Reset();
      actions_.Observe(model);
    }
  }

  void OnToolbarActionAdded(const ToolbarActionsModel::ActionId&) override {
    ScheduleActionChange();
  }
  void OnToolbarActionRemoved(const ToolbarActionsModel::ActionId&) override {
    ScheduleActionChange();
  }
  void OnToolbarActionUpdated(const ToolbarActionsModel::ActionId&) override {
    ScheduleActionChange();
  }
  void OnToolbarModelInitialized() override { ScheduleActionChange(); }
  void OnToolbarPinnedActionsChanged() override { ScheduleActionChange(); }
  void OnToolbarActionsModelShutdown() override {
    actions_.Reset();
    action_owner_ = 0;
  }

  void DeliverActionChange() {
    action_change_pending_ = false;
    if (!actions_.IsObserving() || !host_ || host_->closing()) {
      return;
    }
    auto* selected = host_->selected();
    if (!selected ||
        selected->browser()->GetSessionID().id() != action_owner_) {
      actions_.Reset();
      action_owner_ = 0;
      return;
    }
    Deliver(BarcWindowHostEvent{
        .size = sizeof(BarcWindowHostEvent),
        .kind = BARC_WINDOW_HOST_EXTENSION_ACTIONS_CHANGED,
        .window = action_owner_});
  }

  void Deliver(const BarcWindowHostEvent& event) {
    callback_(&event, context_);
  }

 private:
  // Keeps the event's page view alive until it is delivered.
  void Post(BarcWindowHostEvent event, NSView* view);
  void ScheduleActionChange();

  base::ScopedObservation<ToolbarActionsModel, ToolbarActionsModel::Observer>
      actions_{this};
  int32_t action_owner_ = 0;
  bool action_change_pending_ = false;
  const uint64_t token_;
  base::WeakPtr<bark::BarkWindowHost> host_;
  const BarcWindowHostCallback callback_;
  const raw_ptr<void> context_;
};

std::map<uint64_t, std::unique_ptr<HostObservation>>& Observations() {
  static base::NoDestructor<std::map<uint64_t, std::unique_ptr<HostObservation>>>
      observations;
  return *observations;
}

void DeliverPosted(uint64_t token, BarcWindowHostEvent event, NSView* view) {
  auto& observations = Observations();
  auto found = observations.find(token);
  if (found != observations.end()) {
    event.view = (__bridge void*)view;
    found->second->Deliver(event);
  }
}

void DeliverPostedActionChange(uint64_t token) {
  auto& observations = Observations();
  auto found = observations.find(token);
  if (found != observations.end()) {
    found->second->DeliverActionChange();
  }
}

void HostObservation::ScheduleActionChange() {
  if (!action_change_pending_) {
    action_change_pending_ = true;
    content::GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE, base::BindOnce(&DeliverPostedActionChange, token_));
  }
}

void HostObservation::Post(BarcWindowHostEvent event, NSView* view) {
  content::GetUIThreadTaskRunner({})->PostTask(
      FROM_HERE, base::BindOnce(&DeliverPosted, token_, event, view));
}

std::optional<std::vector<ActionRow>> SnapshotActions(int32_t id,
                                                       int32_t tab_id) {
  const auto target = FindActionTarget(id, tab_id);
  if (!target) {
    return std::nullopt;
  }
  auto* host = bark::BarkWindowHost::ForBrowser(target->browser);
  for (const auto& entry : Observations()) {
    entry.second->ObserveActions(host, target->model, id);
  }
  if (!target->model->actions_initialized()) {
    return std::nullopt;
  }
  const int extension_tab_id =
      extensions::ExtensionTabUtil::GetTabId(target->contents);
  auto* actions =
      extensions::ExtensionActionManager::Get(target->browser->GetProfile());
  std::vector<ActionRow> rows;
  auto append = [&](const std::string& extension_id, bool pinned) {
    const auto* extension = AvailableAction(*target, extension_id);
    auto* action = extension ? actions->GetExtensionAction(*extension) : nullptr;
    if (!action) {
      return;
    }
    int flags = pinned ? BARC_EXTENSION_PINNED : 0;
    if (target->model->IsActionForcePinned(extension_id)) {
      flags |= BARC_EXTENSION_PIN_LOCKED;
    }
    if (bark::IsExtensionActionEnabledForPage(*target->browser,
                                             *target->contents, *extension)) {
      flags |= BARC_EXTENSION_ENABLED;
    }
    auto title = action->GetTitle(extension_tab_id);
    if (title.empty()) {
      title = extension->name();
    }
    rows.push_back({extension_id, std::move(title),
                    action->GetDisplayBadgeText(extension_tab_id), flags});
  };
  for (const auto& extension_id : target->model->pinned_action_ids()) {
    append(extension_id, true);
  }
  for (const auto& extension_id : target->model->action_ids()) {
    if (!target->model->IsActionPinned(extension_id)) {
      append(extension_id, false);
    }
  }

  return rows;
}

}  // namespace

int barc_tab_list_extension_actions(int32_t id,
                                    int32_t tab_id,
                                    BarcExtensionActionCallback callback,
                                    void* context) {
  if (!callback) {
    return 0;
  }
  const auto rows = SnapshotActions(id, tab_id);
  if (!rows) {
    return 0;
  }

  // The receiver may change selection, mutate pins, or close the window.
  for (const auto& row : *rows) {
    callback(context, row.id.c_str(), row.title.c_str(), row.badge.c_str(),
             row.flags);
  }
  return 1;
}

int barc_tab_set_extension_pinned(int32_t id,
                                  int32_t tab_id,
                                  const char* extension_id,
                                  int pinned) {
  if (!extension_id || (pinned != 0 && pinned != 1)) {
    return 0;
  }
  auto target = FindActionTarget(id, tab_id);
  const std::string action_id(extension_id);
  if (!target || !AvailableAction(*target, action_id) ||
      target->model->IsActionForcePinned(action_id)) {
    return 0;
  }
  auto* model = target->model.get();
  target.reset();
  const bool desired = pinned != 0;
  if (model->IsActionPinned(action_id) != desired) {
    model->SetActionVisibility(action_id, desired);
  }
  return 1;
}

int barc_tab_invoke_extension(int32_t id,
                              int32_t tab_id,
                              const char* extension_id) {
  if (!extension_id) {
    return 0;
  }
  auto target = FindActionTarget(id, tab_id);
  const std::string action_id(extension_id);
  if (!target || !AvailableAction(*target, action_id)) {
    return 0;
  }
  auto* browser = target->browser.get();
  auto* contents = target->contents.get();
  target.reset();
  return bark::RunExtensionActionForPage(*browser, *contents, action_id);
}

int barc_window_set_root_view(int32_t id, void* root_view) {
  auto* window = Window(id);
  auto* host = bark::BarkWindowHost::ForBrowser(window);
  NSView* view = (__bridge NSView*)root_view;
  if (!host || !view || ![view isKindOfClass:[NSView class]]) {
    return 0;
  }
  return host->SetRootView(gfx::NativeView(view)) ? 1 : 0;
}

void* barc_tab_native_view(int32_t id, int32_t tab_id) {
  auto* window = Window(id);
  auto* tab = bark::BarkWindowHost::ForBrowser(window)
                  ? LookupTab(window, tab_id)
                  : nullptr;
  if (!tab || !tab->GetContents()) {
    return nullptr;
  }
  return (__bridge void*)tab->GetContents()->GetNativeView().GetNativeNSView();
}

int barc_window_set_chrome(int32_t id, const BarcWindowChrome* chrome) {
  if (!OnUIThread() || !chrome || chrome->size < sizeof(BarcWindowChrome) ||
      !std::isfinite(chrome->titlebar_height) ||
      !std::isfinite(chrome->leading_inset) || chrome->titlebar_height <= 0 ||
      chrome->leading_inset < 0) {
    return 0;
  }
  auto* host = bark::BarkWindowHost::ForBrowser(Window(id));
  return host && host->SetChrome(chrome->titlebar_height, chrome->leading_inset)
             ? 1
             : 0;
}

uint64_t barc_window_host_observe(int32_t id,
                                  BarcWindowHostCallback callback,
                                  void* context) {
  if (!OnUIThread() || !callback) {
    return 0;
  }
  auto* host = bark::BarkWindowHost::ForBrowser(Window(id));
  if (!host || host->closing()) {
    return 0;
  }
  static uint64_t next_token = 0;
  CHECK_NE(next_token, UINT64_MAX);
  const uint64_t token = ++next_token;
  Observations()[token] =
      std::make_unique<HostObservation>(token, host, callback, context);
  return token;
}

void barc_window_host_unobserve(uint64_t observation) {
  if (!OnUIThread()) {
    return;
  }
  Observations().erase(observation);
}
