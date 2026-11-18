#import <AppKit/AppKit.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <limits>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <objc/runtime.h>

#include "bark/browser/webauthn/barc_vault_authenticator.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "net/base/url_util.h"
#include "components/search_engines/template_url_service.h"
#include "components/search_engines/template_url.h"
#include "services/network/public/cpp/resource_request_body.h"

#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/files/scoped_file.h"
#include "base/uuid.h"
#include "net/base/file_stream.h"
#include "net/base/io_buffer.h"
#include "services/network/public/cpp/simple_url_loader_stream_consumer.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "chrome/browser/profiles/nuke_profile_directory_utils.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/common/referrer.h"
#include "net/base/isolation_info.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/cookies/site_for_cookies.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"

#include "base/containers/linked_list.h"
#include "base/memory/ref_counted_memory.h"
#include "bark/browser/content_blocking/native_content_blocker.h"
#include "base/supports_user_data.h"
#include "base/auto_reset.h"
#include "base/synchronization/atomic_flag.h"
#include "base/task/bind_post_task.h"
#include "base/task/thread_pool.h"
#include "base/barrier_callback.h"
#include "base/no_destructor.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/scoped_multi_source_observation.h"
#include "components/download/public/common/download_item.h"
#include "content/public/browser/back_forward_cache.h"
#include "content/public/browser/download_manager.h"
#include "base/task/single_thread_task_runner.h"
#include "content/public/browser/media_session.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "mojo/public/cpp/bindings/associated_receiver.h"
#include "chrome/common/chrome_render_frame.mojom.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/navigation_discard_reason.h"
#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "components/autofill/content/browser/content_autofill_client.h"
#include "components/autofill/content/browser/content_autofill_driver.h"
#include "components/autofill/core/browser/autofill_field.h"
#include "components/autofill/core/browser/form_structure.h"
#include "components/autofill/core/browser/foundations/scoped_autofill_managers_observation.h"
#include "components/password_manager/content/browser/content_password_manager_driver.h"
#include "components/password_manager/core/browser/password_form.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/strings/utf_string_conversions.h"
#include "base/strings/string_util.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/version_info/version_info.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "third_party/blink/public/common/web_preferences/web_preferences.h"
#include "services/network/public/mojom/web_sandbox_flags.mojom.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "bark/bridge/barc_profiles.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_muted_utils.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "bark/bridge/barc_runtime_startup.h"
#include "chrome/browser/ui/views/infobars/confirm_infobar.h"
#include "components/infobars/content/content_infobar_manager.h"
#include "components/infobars/core/confirm_infobar_delegate.h"
#include "ui/views/view_tracker.h"
#include "chrome/browser/ui/views/frame/browser_widget.h"
#include "components/sessions/core/session_id.h"
#include "components/tabs/public/split_tab_data.h"
#include "components/tabs/public/tab_interface.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/weak_document_ptr.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_partition_key_collection.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "third_party/blink/public/common/storage_key/storage_key.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/base_window.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/codec/jpeg_codec.h"
#include "extensions/browser/extensions_browser_client.h"
#include "chrome/browser/ui/views/toolbar/toolbar_view.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/controls/native/native_view_host.h"
#include "url/gurl.h"

#include "bark/bridge/barc_bridge_functions.h"
#include "bark/bridge/bridge_internal.h"
#include "bark/browser/ui/native_space_page.h"
#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_window_host.h"

using namespace barc::internal;

namespace {
class BrowserDiscovery;
std::shared_ptr<BrowserDiscovery>& DiscoveryOwner() {
  static base::NoDestructor<std::shared_ptr<BrowserDiscovery>> owner;
  return *owner;
}
class BrowserDiscovery final
    : public BrowserCollectionObserver,
      public TabStripModelObserver,
      public std::enable_shared_from_this<BrowserDiscovery> {
 public:
  BrowserDiscovery(uint64_t token, BarcDiscoveryCallback callback, void* context)
      : token_(token), callback_(callback), context_(context) {}
  ~BrowserDiscovery() override { Cancel(); }
  uint64_t token() const { return token_; }
  void Start() {
    auto* collection = GlobalBrowserCollection::GetInstance();
    collection_.Observe(collection);
    collection->ForEach([&](BrowserWindowInterface* browser) {
      AddStrip(browser->GetTabStripModel());
      return true;
    });
  }
  void Cancel() {
    weak_factory_.InvalidateWeakPtrs();
    queued_ = false;
    callback_ = nullptr;
    context_ = nullptr;
    collection_.Reset();
    auto strips = std::move(strips_);
    strips_.clear();
    for (const auto& strip : strips)
      strip->RemoveObserver(this);
  }
  void Schedule() {
    if (queued_ || !callback_)
      return;
    queued_ = true;
    content::GetUIThreadTaskRunner({})->PostNonNestableTask(
        FROM_HERE, base::BindOnce(&BrowserDiscovery::Deliver,
                                 weak_factory_.GetWeakPtr()));
  }
  void OnBrowserCreated(BrowserWindowInterface* browser) override {
    AddStrip(browser->GetTabStripModel());
    barc::BrowserDiscoveryChanged();
  }
  void OnBrowserClosed(BrowserWindowInterface* browser) override {
    auto* strip = browser->GetTabStripModel();
    if (strips_.erase(strip))
      strip->RemoveObserver(this);
    barc::BrowserDiscoveryChanged();
  }
  void OnBrowserActivated(BrowserWindowInterface*) override {
    barc::BrowserDiscoveryChanged();
  }
  void OnBrowserDeactivated(BrowserWindowInterface*) override {
    barc::BrowserDiscoveryChanged();
  }
  void OnTabStripModelChanged(TabStripModel*, const TabStripModelChange& change,
                             const TabStripSelectionChange& selection) override {
    if (change.type() != TabStripModelChange::kSelectionOnly ||
        selection.old_tab != selection.new_tab)
      barc::BrowserDiscoveryChanged();
  }
  void OnSplitTabChanged(const SplitTabChange& change) override {
    if (change.type == SplitTabChange::Type::kVisualsChanged &&
        change.GetVisualsChange()->is_intermediate())
      return;
    barc::BrowserDiscoveryChanged();
  }
  void OnTabStripModelDestroyed(TabStripModel* strip) override {
    strips_.erase(strip);
    barc::BrowserDiscoveryChanged();
  }
 private:
  void AddStrip(TabStripModel* strip) {
    if (strip && strips_.insert(strip).second)
      strip->AddObserver(this);
  }
  void Deliver() {
    auto keep_alive = shared_from_this();
    queued_ = false;
    auto callback = callback_;
    void* context = context_.get();
    const uint64_t revision = discovery_revision;
    if (callback)
      callback(context, token_, revision);
    // Callback may unobserve, release context or shut down; no member access.
    // Availability delivery is coalesced and non-nestable after this lifetime.
    barc::NotifyApplicationBrowserAvailable();
  }
  const uint64_t token_;
  BarcDiscoveryCallback callback_;
  raw_ptr<void> context_;
  bool queued_ = false;
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver>
      collection_{this};
  std::set<raw_ptr<TabStripModel>> strips_;
  base::WeakPtrFactory<BrowserDiscovery> weak_factory_{this};
};

void DiscoveryKinds(BrowserWindowInterface* browser, BarcDiscoveryWindow* row) {
  auto* active = browser->GetTabStripModel()->GetActiveTab();
  row->active_tab = active ? active->GetHandle().raw_value() : 0;
  switch (browser->GetType()) {
    case BrowserWindowInterface::TYPE_NORMAL: row->kind = BARC_DISCOVERY_NORMAL; break;
    case BrowserWindowInterface::TYPE_POPUP: row->kind = BARC_DISCOVERY_POPUP; break;
    case BrowserWindowInterface::TYPE_APP:
    case BrowserWindowInterface::TYPE_APP_POPUP: row->kind = BARC_DISCOVERY_APP; break;
    case BrowserWindowInterface::TYPE_DEVTOOLS: row->kind = BARC_DISCOVERY_DEVTOOLS; break;
    default: row->kind = BARC_DISCOVERY_OTHER_WINDOW; break;
  }
  auto* profile = browser->GetProfile();
  row->profile_kind = profile->IsGuestSession() ? BARC_DISCOVERY_GUEST
      : profile->IsIncognitoProfile() ? BARC_DISCOVERY_INCOGNITO
      : profile->IsRegularProfile() ? BARC_DISCOVERY_REGULAR
      : BARC_DISCOVERY_OTHER_PROFILE;
  if (row->profile_kind == BARC_DISCOVERY_REGULAR)
    barc_window_profile_uuid(row->window, row->regular_profile_uuid,
                             sizeof(row->regular_profile_uuid));
}
bool HostDiscoveryWindowRow(BrowserWindowInterface* browser,
                            BarcDiscoveryWindow* row) {
  auto* host = bark::BarkWindowHost::ForBrowser(browser);
  auto* selected = host ? host->selected() : nullptr;
  if (!selected || host->closing() || !host->widget())
    return false;
  *row = {.size = sizeof(BarcDiscoveryWindow)};
  row->window = browser->GetSessionID().id();
  row->physical_group = host->physical_group();
  row->selected_client = selected->browser()->GetSessionID().id();
  DiscoveryKinds(browser, row);
  if (host->widget()->IsActive()) row->flags |= BARC_DISCOVERY_PHYSICAL_ACTIVE;
  if (host->widget()->IsVisible()) row->flags |= BARC_DISCOVERY_PHYSICAL_VISIBLE;
  if (selected->browser() == browser) row->flags |= BARC_DISCOVERY_SELECTED_CLIENT;
  if (bark::BarkBrowserWindow::FromBrowser(browser)->app_created())
    row->flags |= BARC_DISCOVERY_WINDOW_APP_FACTORY;
  if (browser->GetType() == BrowserWindowInterface::TYPE_POPUP)
    row->flags |= BARC_DISCOVERY_COMPACT_MINI;
  if (selected->browser() == browser && host->awaiting_admission())
    row->flags |= BARC_DISCOVERY_AWAITING_ADMISSION;
  if (UnloadController::From(browser)->owner_close_admitted())
    row->flags |= BARC_DISCOVERY_OWNER_ENDING;
  if (browser->GetTabStripModel()->empty()) row->flags |= BARC_DISCOVERY_EMPTY_STRIP;
  if (bark::IsNativeSpacePageSuppressed(browser))
    row->flags |= BARC_DISCOVERY_SPACE_SUPPRESSED;
  if (AppLifetimeGroups().contains(row->physical_group))
    row->flags |= BARC_DISCOVERY_APP_LIFETIME;
  return true;
}
bool DiscoveryWindowRow(BrowserWindowInterface* browser,
                        BarcDiscoveryWindow* row) {
  if (browser && !browser->IsDeleteScheduled() &&
      bark::BarkWindowHost::ForBrowser(browser))
    return HostDiscoveryWindowRow(browser, row);
  auto* view = browser && !browser->IsDeleteScheduled()
                   ? BrowserView::GetBrowserViewForBrowser(browser) : nullptr;
  auto* widget = view ? view->browser_widget() : nullptr;
  auto* selected = widget ? widget->selected_browser_view() : nullptr;
  if (!view || !selected || widget->IsClosed())
    return false;
  *row = {.size = sizeof(BarcDiscoveryWindow)};
  row->window = browser->GetSessionID().id();
  row->physical_group = widget->barc_physical_group();
  row->selected_client = selected->browser()->GetSessionID().id();
  DiscoveryKinds(browser, row);
  if (widget->IsActive()) row->flags |= BARC_DISCOVERY_PHYSICAL_ACTIVE;
  if (widget->IsVisible()) row->flags |= BARC_DISCOVERY_PHYSICAL_VISIBLE;
  if (selected == view) row->flags |= BARC_DISCOVERY_SELECTED_CLIENT;
  if (view->barc_app_factory_origin()) row->flags |= BARC_DISCOVERY_WINDOW_APP_FACTORY;
  if (view->barc_compact_shell()) row->flags |= BARC_DISCOVERY_COMPACT_MINI;
  if (view->BarcAwaitingNativeAdmission()) row->flags |= BARC_DISCOVERY_AWAITING_ADMISSION;
  if (UnloadController::From(browser)->owner_close_admitted())
    row->flags |= BARC_DISCOVERY_OWNER_ENDING;
  if (browser->GetTabStripModel()->empty()) row->flags |= BARC_DISCOVERY_EMPTY_STRIP;
  if (bark::IsNativeSpacePageSuppressed(browser))
    row->flags |= BARC_DISCOVERY_SPACE_SUPPRESSED;
  if (AppLifetimeGroups().contains(row->physical_group))
    row->flags |= BARC_DISCOVERY_APP_LIFETIME;
  return true;
}
int32_t DiscoveryOpener(tabs::TabInterface* tab) {
  auto* frame = tab->GetContents()->GetOpener();
  auto* opener = frame ? tabs::TabInterface::MaybeGetFromContents(
                            content::WebContents::FromRenderFrameHost(frame)) : nullptr;
  auto* owner = opener ? opener->GetBrowserWindowInterface() : nullptr;
  auto* current = tab->GetBrowserWindowInterface();
  return owner && current && owner->GetProfile() == current->GetProfile()
             ? opener->GetHandle().raw_value() : 0;
}

// Subscriptions contain no Profile/download ownership and no history store.
}  // namespace

uint64_t barc_discovery_observe(BarcDiscoveryCallback callback, void* context) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || !GlobalBrowserCollection::GetInstance() ||
      !callback || DiscoveryOwner())
    return 0;
  static uint64_t next_token = 0;
  CHECK_NE(next_token, UINT64_MAX);
  auto observer = std::make_shared<BrowserDiscovery>(++next_token, callback, context);
  DiscoveryOwner() = observer;
  observer->Start();
  barc::BrowserDiscoveryChanged();
  return observer->token();
}
void barc_discovery_unobserve(uint64_t token) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI))
    return;
  auto observer = DiscoveryOwner();
  if (observer && observer->token() == token) {
    DiscoveryOwner().reset();
    observer->Cancel();
  }
}
int barc_window_discovery_state(int32_t window, BarcDiscoveryWindow* row) {
  BarcDiscoveryWindow value;
  if (discovery_stopped || !IsSized(row) || !DiscoveryWindowRow(Window(window), &value))
    return 0;
  WriteKnownFields(row, value);
  return 1;
}
int32_t barc_discovery_snapshot(BarcDiscoveryWindow* windows, size_t window_capacity,
                                BarcDiscoveryTab* tabs, size_t tab_capacity,
                                BarcDiscoverySnapshot* snapshot) {
  if (!IsSized(snapshot) || (!windows && window_capacity) || (!tabs && tab_capacity) ||
      (window_capacity && !IsSized(windows)) || (tab_capacity && !IsSized(tabs)))
    return BARC_DISCOVERY_READ_INVALID_ARGUMENT;
  WriteKnownFields(snapshot, BarcDiscoverySnapshot{});
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || !GlobalBrowserCollection::GetInstance())
    return BARC_DISCOVERY_READ_UNAVAILABLE;
  auto* collection = GlobalBrowserCollection::GetInstance();
  collection->ForEach([&](BrowserWindowInterface* browser) {
    BarcDiscoveryWindow row;
    if (DiscoveryWindowRow(browser, &row)) {
      ++snapshot->window_count;
      snapshot->tab_count += browser->GetTabStripModel()->count();
    }
    return true;
  });
  snapshot->revision = discovery_revision;
  if (window_capacity < snapshot->window_count || tab_capacity < snapshot->tab_count)
    return BARC_DISCOVERY_READ_CAPACITY;
  const size_t window_stride = window_capacity ? windows->size : 0;
  const size_t tab_stride = tab_capacity ? tabs->size : 0;
  base::span<uint8_t> window_bytes;
  base::span<uint8_t> tab_bytes;
  // SAFETY: C callers supply writable arrays of the declared capacities and row
  // sizes; after this boundary conversion every write is checked against them.
  if (windows) window_bytes = UNSAFE_BUFFERS(base::span(reinterpret_cast<uint8_t*>(windows),
                                                        window_capacity * window_stride));
  if (tabs) tab_bytes = UNSAFE_BUFFERS(base::span(reinterpret_cast<uint8_t*>(tabs),
                                                  tab_capacity * tab_stride));
  auto window_row = [&](size_t index) {
    return reinterpret_cast<BarcDiscoveryWindow*>(
        window_bytes.subspan(index * window_stride, sizeof(BarcDiscoveryWindow)).data());
  };
  auto tab_row = [&](size_t index) {
    return reinterpret_cast<BarcDiscoveryTab*>(
        tab_bytes.subspan(index * tab_stride, sizeof(BarcDiscoveryTab)).data());
  };
  size_t window_index = 0, tab_index = 0;
  collection->ForEach([&](BrowserWindowInterface* browser) {
    BarcDiscoveryWindow row;
    if (!DiscoveryWindowRow(browser, &row))
      return true;
    WriteKnownFields(window_row(window_index++), row);
    auto* strip = browser->GetTabStripModel();
    for (int index = 0; index < strip->count(); ++index) {
      auto* tab = strip->GetTabAtIndex(index);
      WriteKnownFields(tab_row(tab_index++), {0, row.window, tab->GetHandle().raw_value(),
          DiscoveryOpener(tab), index,
          PeekRoleFor(tab) && PeekRoleFor(tab)->source ? PeekRoleFor(tab)->source->GetHandle().raw_value() : 0,
          (row.active_tab == tab->GetHandle().raw_value()
               ? static_cast<uint32_t>(BARC_DISCOVERY_ACTIVE_TAB) : 0u) |
          (static_cast<tabs::TabModel*>(strip->GetTabAtIndex(index))->barc_app_factory_origin()
               ? static_cast<uint32_t>(BARC_DISCOVERY_TAB_APP_FACTORY) : 0u) |
          (PeekRoleFor(tab) ? static_cast<uint32_t>(BARC_DISCOVERY_TAB_PEEK) : 0u)});
    }
    return true;
  });
  return BARC_DISCOVERY_READ_OK;
}
int barc_window_admit_discovered(int32_t id, void* expected_view) {
  auto* window = Window(id);
  auto* view = window ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
  if (!view || !expected_view || !barc_window_native_shell_is_owned(id, expected_view))
    return 0;
  NSView* expected = (__bridge NSView*)expected_view;
  auto owner = window->GetWeakPtr();
  auto alive = view->GetAsWeakPtr();
  const bool admitted = view->AdmitBarcNativeWindow(gfx::NativeView(expected));
  return admitted && owner && Window(id) == owner.get() && alive &&
         barc_window_native_shell_is_owned(id, (__bridge void*)expected);
}


namespace barc {
void BrowserDiscoveryChanged() {
  CHECK_NE(discovery_revision, UINT64_MAX);
  ++discovery_revision;
  if (auto observer = DiscoveryOwner()) observer->Schedule();
}
void StopBrowserDiscovery() {
  discovery_stopped = true;
  NativeContentBlocker::StopPolicy();
  ClearApplicationPageIntents();
  CancelDownloadObservation();
  auto observer = std::move(DiscoveryOwner());
  if (observer) observer->Cancel();
}
}  // namespace barc
