#import <AppKit/AppKit.h>

#include "chrome/browser/ui/views/frame/barc_bridge.h"

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

#include "chrome/browser/webauthn/barc_vault_authenticator.h"
#include "chrome/browser/ui/views/frame/barc_public_headers_sha256.h"
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
#include "chrome/browser/content_blocking/native_content_blocker.h"
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
#include "chrome/browser/ui/views/frame/barc_profiles.h"
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
#include "chrome/browser/ui/views/frame/barc_runtime_startup.h"
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
#include "ui/views/controls/native/native_view_host.h"
#include "url/gurl.h"

// Intrinsic view pairing, never a window/profile lookup registry. The header
// must not retain its sidebar through a callback; native hosts retain both.
@interface BarcPageHeader : NSObject
@property(nonatomic, strong) NSView* view;
@property(nonatomic) int height;
@end
@implementation BarcPageHeader
@synthesize view = _view;
@synthesize height = _height;
@end

namespace {
const char kNativePageHeaderKey = 0;
BarcPageHeader* PageHeader(NSView* sidebar) {
  return sidebar ? objc_getAssociatedObject(sidebar, &kNativePageHeaderKey) : nil;
}
// UI-thread-only; the storage outlives all reentrant observer callouts.
int navigation_callback_depth = 0;
bool attaching_native_shell = false;
const char kApplicationLaunchKey = 0;
struct ApplicationLaunch : public base::SupportsUserData::Data,
                           public base::LinkNode<ApplicationLaunch> {
  ApplicationLaunch(uint64_t request, std::string space,
                    base::WeakPtr<Profile> profile)
      : request(request), space(std::move(space)), profile(std::move(profile)) {}
  ~ApplicationLaunch() override {
    if (next()) {
      RemoveFromList();
      barc::NotifyApplicationBrowserAvailable();
    }
  }
  uint64_t request;
  std::string space;
  base::WeakPtr<Profile> profile;
  base::RepeatingClosure resume;
};
// An index of pending intrinsic records, not another URL/payload owner.
base::LinkedList<ApplicationLaunch>& PendingApplicationPageIntents() {
  static base::LinkedList<ApplicationLaunch> pending;
  return pending;
}

BrowserWindowInterface* Window(int32_t id) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      id <= 0)
    return nullptr;
  auto* collection = GlobalBrowserCollection::GetInstance();
  auto* window =
      collection
          ? collection->FindBrowserWithID(SessionID::FromSerializedValue(id))
          : nullptr;
  return window && !window->IsDeleteScheduled() ? window : nullptr;
}
tabs::TabInterface* LookupTab(BrowserWindowInterface* window, int32_t id) {
  if (!window || id == 0)
    return nullptr;
  auto* tab = tabs::TabHandle(id).Get();
  return tab && tab->GetBrowserWindowInterface() == window ? tab : nullptr;
}
const char kPeekRoleKey = 0;
const char kPeekSourceKey = 0;
void ResetPeekConsent(base::SupportsUserData::Data* data, const void* key);
base::CallbackListSubscription PreservePeekDataAcrossDiscard(
    tabs::TabInterface* tab, const void* key) {
  return tab->RegisterWillDiscardContents(base::BindRepeating(
      [](const void* key, tabs::TabInterface*, content::WebContents* old_contents,
         content::WebContents* new_contents) {
        // The intrinsic tab relationship survives replacement of its renderer.
        // Move the same subscription-bearing object before old contents die.
        if (auto data = old_contents->TakeUserData(key)) {
          ResetPeekConsent(data.get(), key);
          new_contents->SetUserData(key, std::move(data));
        }
      }, key));
}
struct PeekRole : public base::SupportsUserData::Data {
  PeekRole(tabs::TabInterface* tab, tabs::TabInterface* source)
      : source(source->GetWeakPtr()),
        discard(PreservePeekDataAcrossDiscard(tab, &kPeekRoleKey)) {}
  base::WeakPtr<tabs::TabInterface> source;
  bool close_committed = false;
  base::CallbackListSubscription discard;
};
struct PeekSource : public base::SupportsUserData::Data {
  PeekSource(tabs::TabInterface* source, tabs::TabInterface* peek)
      : peek(peek->GetWeakPtr()),
        discard(PreservePeekDataAcrossDiscard(source, &kPeekSourceKey)) {}
  base::WeakPtr<tabs::TabInterface> peek;
  bool close_committed = false;
  base::CallbackListSubscription discard;
};
void ResetPeekConsent(base::SupportsUserData::Data* data, const void* key) {
  if (key == &kPeekRoleKey) static_cast<PeekRole*>(data)->close_committed = false;
  if (key == &kPeekSourceKey) static_cast<PeekSource*>(data)->close_committed = false;
}
PeekRole* PeekRoleFor(tabs::TabInterface* tab) {
  return tab ? static_cast<PeekRole*>(tab->GetContents()->GetUserData(&kPeekRoleKey)) : nullptr;
}
void ClearPeekRole(tabs::TabInterface* tab) {
  auto* role = PeekRoleFor(tab);
  if (!role) return;
  if (auto* source = role->source.get()) {
    auto* link = static_cast<PeekSource*>(source->GetContents()->GetUserData(&kPeekSourceKey));
    if (link && link->peek.get() == tab)
      source->GetContents()->RemoveUserData(&kPeekSourceKey);
  }
  tab->GetContents()->RemoveUserData(&kPeekRoleKey);
  barc::BrowserDiscoveryChanged();
}
GURL URL(const char* value) {
  return value ? GURL(value) : GURL();
}
// Catalog state owns only subscriptions, never browsers, tabs or profiles.
uint64_t discovery_revision = 0;
bool discovery_stopped = false;
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

bool DiscoveryWindowRow(BrowserWindowInterface* browser,
                        BarcDiscoveryWindow* row) {
  auto* view = browser && !browser->IsDeleteScheduled()
                   ? BrowserView::GetBrowserViewForBrowser(browser) : nullptr;
  auto* widget = view ? view->browser_widget() : nullptr;
  auto* selected = widget ? widget->selected_browser_view() : nullptr;
  if (!view || !selected || widget->IsClosed())
    return false;
  *row = {};
  row->window = browser->GetSessionID().id();
  row->physical_group = widget->barc_physical_group();
  row->selected_client = selected->browser()->GetSessionID().id();
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
  if (widget->IsActive()) row->flags |= BARC_DISCOVERY_PHYSICAL_ACTIVE;
  if (widget->IsVisible()) row->flags |= BARC_DISCOVERY_PHYSICAL_VISIBLE;
  if (selected == view) row->flags |= BARC_DISCOVERY_SELECTED_CLIENT;
  if (view->barc_app_factory_origin()) row->flags |= BARC_DISCOVERY_WINDOW_APP_FACTORY;
  if (view->barc_compact_shell()) row->flags |= BARC_DISCOVERY_COMPACT_MINI;
  if (view->BarcAwaitingNativeAdmission()) row->flags |= BARC_DISCOVERY_AWAITING_ADMISSION;
  if (UnloadController::From(browser)->owner_close_admitted())
    row->flags |= BARC_DISCOVERY_OWNER_ENDING;
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
class NativeDownloadManager;
struct NativeDownloadData {
  std::weak_ptr<NativeDownloadManager> source;
  uint64_t manager = 0;
  int32_t event = BARC_DOWNLOAD_ITEM;
  std::string profile, guid, url, target, filename;
  int32_t state = BARC_DOWNLOAD_PROGRESS;
  int32_t error = 0;
  uint32_t flags = 0;
  int64_t received = 0, total = -1;
  double started = 0;
};
class NativeDownloadManager final
    : public content::DownloadManager::Observer,
      public download::DownloadItem::Observer,
      public std::enable_shared_from_this<NativeDownloadManager> {
 public:
  NativeDownloadManager(content::DownloadManager* manager, uint64_t id,
      std::string profile, bool is_private,
      base::RepeatingCallback<void(NativeDownloadData)> publish,
      base::RepeatingCallback<void(uint64_t)> ended)
      : manager_(manager), id_(id), profile_(std::move(profile)),
        private_(is_private), publish_(std::move(publish)), ended_(std::move(ended)) {}
  ~NativeDownloadManager() override { Cancel(); }
  uint64_t id() const { return id_; }
  bool active() const { return manager_ != nullptr; }
  bool owns(content::DownloadManager* manager) const { return manager_ == manager; }
  void Start() {
    manager_->AddObserver(this);
    content::DownloadManager::DownloadVector items;
    manager_->GetAllDownloads(&items);
    for (const auto& item : items) Add(item.get());
  }
  void Cancel() {
    items_.RemoveAllObservations();
    if (manager_) manager_->RemoveObserver(this);
    manager_ = nullptr;
  }
  bool CanAction(const std::string& guid, int32_t action) const {
    auto* item = manager_ ? manager_->GetDownloadByGuid(guid) : nullptr;
    if (!item) return false;
    if (action == BARC_DOWNLOAD_CANCEL) return item->GetState() == download::DownloadItem::IN_PROGRESS;
    if (action == BARC_DOWNLOAD_REMOVE) return item->IsDone();
    return false;
  }
  std::string SafeTarget(const std::string& guid) const {
    auto* item = manager_ ? manager_->GetDownloadByGuid(guid) : nullptr;
    return item && SafeFile(item) ? item->GetTargetFilePath().AsUTF8Unsafe() : std::string();
  }
  bool Action(const std::string& guid, int32_t action) {
    if (!CanAction(guid, action)) return false;
    auto* item = manager_->GetDownloadByGuid(guid);
    if (action == BARC_DOWNLOAD_CANCEL && item->GetState() == download::DownloadItem::IN_PROGRESS) {
      item->Cancel(true);
      return true;
    }
    if (action == BARC_DOWNLOAD_REMOVE && item->IsDone()) {
      item->Remove();
      return true;
    }
    return false;
  }
  void OnDownloadCreated(content::DownloadManager*, download::DownloadItem* item) override { Add(item); }
  void OnManagerInitialized() override {
    content::DownloadManager::DownloadVector items;
    manager_->GetAllDownloads(&items);
    for (const auto& item : items) Add(item.get());
  }
  void ManagerGoingDown(content::DownloadManager*) override {
    auto keep_alive = shared_from_this();
    Cancel();
    auto data = Data(nullptr); data.event = BARC_DOWNLOAD_MANAGER_ENDED;
    publish_.Run(std::move(data));
    ended_.Run(id_);
  }
  void OnDownloadUpdated(download::DownloadItem* item) override { publish_.Run(Data(item)); }
  void OnDownloadRemoved(download::DownloadItem* item) override {
    auto data = Data(item); data.event = BARC_DOWNLOAD_REMOVED;
    publish_.Run(std::move(data));
  }
  void OnDownloadDestroyed(download::DownloadItem* item) override {
    OnDownloadRemoved(item);
    items_.RemoveObservation(item);
  }
 private:
  static bool SafeFile(download::DownloadItem* item) {
    return item->GetState() == download::DownloadItem::COMPLETE &&
        !item->IsDangerous() && !item->IsInsecure() &&
        !item->GetFileExternallyRemoved() && !item->GetTargetFilePath().empty();
  }
  void Add(download::DownloadItem* item) {
    if (!items_.IsObservingSource(item)) items_.AddObservation(item);
    publish_.Run(Data(item));
  }
  NativeDownloadData Data(download::DownloadItem* item) {
    NativeDownloadData data;
    data.source = weak_from_this(); data.manager = id_; data.profile = profile_;
    if (private_) data.flags |= BARC_DOWNLOAD_PRIVATE;
    if (!item) return data;
    data.guid = item->GetGuid(); data.url = item->GetURL().spec();
    data.target = item->GetTargetFilePath().AsUTF8Unsafe();
    data.filename = item->GetFileNameToReportUser().AsUTF8Unsafe();
    switch (item->GetState()) {
      case download::DownloadItem::IN_PROGRESS: data.state = BARC_DOWNLOAD_PROGRESS; break;
      case download::DownloadItem::COMPLETE: data.state = BARC_DOWNLOAD_COMPLETE; break;
      case download::DownloadItem::CANCELLED: data.state = BARC_DOWNLOAD_CANCELLED; break;
      case download::DownloadItem::INTERRUPTED: data.state = BARC_DOWNLOAD_INTERRUPTED; break;
      case download::DownloadItem::MAX_DOWNLOAD_STATE: NOTREACHED();
    }
    if (item->IsDangerous() || item->IsInsecure()) data.flags |= BARC_DOWNLOAD_UNSAFE;
    if (SafeFile(item)) data.flags |= BARC_DOWNLOAD_SAFE_FILE;
    data.error = static_cast<int32_t>(item->GetLastReason());
    data.received = item->GetReceivedBytes(); data.total = item->GetTotalBytes();
    data.started = item->GetStartTime().InSecondsFSinceUnixEpoch();
    return data;
  }
  raw_ptr<content::DownloadManager> manager_;
  const uint64_t id_;
  const std::string profile_;
  const bool private_;
  base::RepeatingCallback<void(NativeDownloadData)> publish_;
  base::RepeatingCallback<void(uint64_t)> ended_;
  base::ScopedMultiSourceObservation<download::DownloadItem, download::DownloadItem::Observer> items_{this};
};
class NativeDownloads final : public BrowserCollectionObserver,
                             public std::enable_shared_from_this<NativeDownloads> {
 public:
  NativeDownloads(uint64_t token, BarcDownloadCallback callback, void* context)
      : token_(token), callback_(callback), context_(context) {}
  ~NativeDownloads() override { Cancel(); }
  uint64_t token() const { return token_; }
  void Start() {
    auto* collection = GlobalBrowserCollection::GetInstance();
    collection_.Observe(collection);
    collection->ForEach([&](BrowserWindowInterface* browser) { AddBrowser(browser); return true; });
  }
  void Cancel() {
    weak_.InvalidateWeakPtrs(); callback_ = nullptr; context_ = nullptr;
    collection_.Reset(); pending_.clear();
    auto managers = std::move(managers_);
    for (auto& [manager, observer] : managers) observer->Cancel();
  }
  void OnBrowserCreated(BrowserWindowInterface* browser) override { AddBrowser(browser); }
  bool CanAction(uint64_t id, const std::string& guid, int32_t action) const {
    auto found = managers_.find(id);
    return found != managers_.end() && found->second->CanAction(guid, action);
  }
  std::string SafeTarget(uint64_t id, const std::string& guid) const {
    auto found = managers_.find(id);
    return found == managers_.end() ? std::string() : found->second->SafeTarget(guid);
  }
  int Action(uint64_t id, const std::string& guid, int32_t action) {
    auto found = managers_.find(id);
    if (found == managers_.end()) return 0;
    auto observer = found->second;
    return observer->Action(guid, action);
  }
 private:
  void AddBrowser(BrowserWindowInterface* browser) {
    if (!callback_) return;
    std::array<char, 37> identity{};
    const int32_t window = browser->GetSessionID().id();
    bool is_private = false;
    if (barc_window_profile_uuid(window, identity.data(), identity.size()) != identity.size()) {
      if (barc_window_private_session_uuid(window, identity.data(), identity.size()) != identity.size()) return;
      is_private = true;
    }
    auto* profile = browser->GetProfile();
    auto* manager = profile->GetDownloadManager();
    if (!manager || manager->GetBrowserContext() != profile ||
        std::ranges::any_of(managers_, [manager](const auto& entry) { return entry.second->owns(manager); })) return;
    CHECK_NE(next_manager_, UINT64_MAX);
    auto observer = std::make_shared<NativeDownloadManager>(manager, ++next_manager_, identity.data(), is_private,
        base::BindRepeating(&NativeDownloads::Queue, weak_.GetWeakPtr()),
        base::BindRepeating(&NativeDownloads::Ended, weak_.GetWeakPtr()));
    managers_.emplace(observer->id(), observer);
    observer->Start();
  }
  void Ended(uint64_t manager) { managers_.erase(manager); }
  void Queue(NativeDownloadData data) {
    if (!callback_) return;
    if (data.event == BARC_DOWNLOAD_MANAGER_ENDED) {
      for (auto it = pending_.begin(); it != pending_.end();) {
        if (it->first.first == data.manager) it = pending_.erase(it); else ++it;
      }
    }
    pending_[{data.manager, data.guid}] = std::move(data);
    if (queued_) return;
    queued_ = true;
    content::GetUIThreadTaskRunner({})->PostNonNestableTask(FROM_HERE,
        base::BindOnce(&NativeDownloads::Deliver, weak_.GetWeakPtr()));
  }
  void Deliver() {
    auto keep_alive = shared_from_this(); queued_ = false;
    auto pending = std::move(pending_); pending_.clear();
    for (auto& [key, data] : pending) {
      if (!callback_) break;
      if (data.event != BARC_DOWNLOAD_MANAGER_ENDED) {
        auto source = data.source.lock();
        if (!source || !source->active()) continue;
      }
      BarcDownloadSnapshot row{data.manager, data.profile.c_str(), data.guid.c_str(),
          data.url.c_str(), data.target.c_str(), data.filename.c_str(), data.state,
          data.error, data.flags, data.received, data.total, data.started};
      base::AutoReset<int> callback_scope(&navigation_callback_depth, navigation_callback_depth + 1);
      callback_(context_.get(), token_, data.event, &row);
    }
  }
  const uint64_t token_;
  BarcDownloadCallback callback_;
  raw_ptr<void> context_;
  uint64_t next_manager_ = 0;
  bool queued_ = false;
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver> collection_{this};
  std::map<uint64_t, std::shared_ptr<NativeDownloadManager>> managers_;
  std::map<std::pair<uint64_t, std::string>, NativeDownloadData> pending_;
  base::WeakPtrFactory<NativeDownloads> weak_{this};
};
std::shared_ptr<NativeDownloads>& DownloadOwner() {
  static base::NoDestructor<std::shared_ptr<NativeDownloads>> owner;
  return *owner;
}

// Tokens own observers, never tabs or profiles. Each callback holds only its
// observer alive, so unsubscribe/close during delivery cannot free its stack.
class NativeBlockInfoBar final : public ConfirmInfoBarDelegate {
 public:
  explicit NativeBlockInfoBar(base::RepeatingClosure continue_request)
      : continue_request_(std::move(continue_request)) {}
  InfoBarIdentifier GetIdentifier() const override {
    return BARC_NATIVE_CONTENT_BLOCK_INFOBAR_DELEGATE;
  }
  bool EqualsDelegate(infobars::InfoBarDelegate* other) const override {
    return other->GetIdentifier() == GetIdentifier();
  }
  std::u16string GetMessageText() const override {
    return u"Barc blocked this page.";
  }
  int GetButtons() const override { return BUTTON_OK; }
  std::u16string GetButtonLabel(InfoBarButton) const override { return u"Continue"; }
  bool Accept() override {
    // The exact app page owns the exception. Keep the bar if it refuses the
    // request; a successful navigation expires it through Chromium normally.
    auto request = continue_request_;
    request.Run();
    return false;
  }
 private:
  const base::RepeatingClosure continue_request_;
};

class TabObservation;
using Observations = std::map<uint64_t, std::shared_ptr<TabObservation>>;
Observations& ObservationTable() {
  static base::NoDestructor<Observations> table;
  return *table;
}
class TabObservation : public content::WebContentsObserver,
                       public autofill::AutofillManager::Observer,
                       public chrome::mojom::NookTranslationClient,
                       public media_session::mojom::MediaSessionObserver,
                       public content::BrowsingDataRemover::Observer,
                       public ProfileManagerObserver,
                       public TabStripModelObserver,
                       public std::enable_shared_from_this<TabObservation> {
 public:
  TabObservation(uint64_t token, tabs::TabInterface* tab,
                 BarcTabCallback callback, void* context)
      : content::WebContentsObserver(tab->GetContents()), token_(token),
        tab_(tab->GetHandle()), callback_(callback), context_(context) {
    detach_ = tab->RegisterWillDetach(base::BindRepeating(
        &TabObservation::Detach, base::Unretained(this)));
    insert_ = tab->RegisterDidInsert(base::BindRepeating(
        &TabObservation::Inserted, base::Unretained(this)));
    discard_ = tab->RegisterWillDiscardContents(base::BindRepeating(
        &TabObservation::Discard, base::Unretained(this)));
    picker_deactivate_ = tab->RegisterWillDeactivate(base::BindRepeating(
        [](TabObservation* self, tabs::TabInterface*) { self->CancelPicker(); },
        base::Unretained(this)));
    BindOwner();
  }
  ~TabObservation() override { vault_callback_ = nullptr; vault_focus_.reset(); UnbindOwner(); }
  int32_t tab_id() const { return tab_.raw_value(); }
  bool active() const { return active_; }
  struct VaultSubmission {
    uint64_t token;
    base::WeakPtr<BrowserWindowInterface> owner;
    std::string origin, username, password;
  };
  BarcVaultSaveCallback vault_save_callback_ = nullptr;
  std::optional<VaultSubmission> vault_submission_;
  uint64_t vault_submission_serial_ = 0;
  bool vault_save_notification_posted_ = false;
  bool VaultSaveCurrent(uint64_t serial) const {
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    return active_ && !closing_ && !discovery_stopped && vault_save_callback_ &&
        vault_submission_ && serial && vault_submission_->token == serial &&
        web_contents() && tab && tab->GetContents() == web_contents() && owner &&
        !owner->IsDeleteScheduled() && owner == vault_submission_->owner.get() &&
        owner->GetProfile() == web_contents()->GetBrowserContext();
  }
  void NotifyVaultSave() {
    if (vault_save_notification_posted_) return;
    vault_save_notification_posted_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
        base::BindOnce([](std::weak_ptr<TabObservation> weak) {
          auto self = weak.lock();
          if (!self) return;
          self->vault_save_notification_posted_ = false;
          if (!self->active_ || !self->vault_save_callback_) return;
          auto callback = self->vault_save_callback_;
          // Copies survive a synchronous application callback retiring the offer.
          auto submission = self->vault_submission_;
          NSView* view = nil;
          if (submission && self->VaultSaveCurrent(submission->token)) {
            if (auto* widget = self->web_contents()->GetRenderWidgetHostView())
              view = widget->GetNativeView().GetNativeNSView();
          }
          base::AutoReset depth(&navigation_callback_depth, navigation_callback_depth + 1);
          callback(self->context_.get(), self->token_, view ? submission->token : 0,
              view ? submission->origin.c_str() : "",
              view ? submission->username.c_str() : "",
              view ? submission->password.c_str() : "", (__bridge void*)view);
        }, weak_from_this()));
  }
  void ClearVaultSave() {
    if (!vault_submission_) return;
    vault_submission_.reset();
    NotifyVaultSave();
  }
  void ObserveVaultSave(BarcVaultSaveCallback callback) {
    ClearVaultSave();
    vault_save_callback_ = callback;
  }
  bool OfferVaultSave(const password_manager::PasswordForm& credentials) {
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    // A newer validated submission supersedes this owner's earlier offer even
    // when unsupported credentials must fall through to the stock Chrome UI.
    if (vault_submission_ && vault_submission_->owner.get() == owner)
      ClearVaultSave();
    const auto origin = url::Origin::Create(credentials.url);
    if (!vault_save_callback_ || !active_ || closing_ || discovery_stopped || !owner ||
        owner->IsDeleteScheduled() || !web_contents() ||
        owner->GetProfile() != web_contents()->GetBrowserContext() ||
        origin.opaque() || !(origin.scheme() == "https" ||
            (origin.scheme() == "http" && net::IsLocalhost(origin.GetURL()))) ||
        credentials.username_value.empty() || credentials.password_value.empty() ||
        credentials.username_value.size() > 65536 || credentials.password_value.size() > 65536) return false;
    const std::string username = base::UTF16ToUTF8(credentials.username_value);
    const std::string password = base::UTF16ToUTF8(credentials.password_value.value());
    if (username.size() > 65536 || password.size() > 65536 ||
        username.find('\0') != std::string::npos || password.find('\0') != std::string::npos) return false;
    CHECK_NE(vault_submission_serial_, UINT64_MAX);
    vault_submission_.emplace(VaultSubmission{++vault_submission_serial_, owner->GetWeakPtr(),
        origin.Serialize(), username, password});
    NotifyVaultSave();
    return true;
  }
  struct VaultPasskey {
    uint64_t serial;
    content::WeakDocumentPtr document;
    base::WeakPtr<BrowserWindowInterface> owner;
    base::WeakPtr<views::Widget> widget;
    int operation;
    std::string arguments;
    base::OnceCallback<void(std::optional<std::string>)> reply;
  };
  std::optional<VaultPasskey> vault_passkey_;
  BarcVaultPasskeyCallback vault_passkey_callback_ = nullptr;
  uint64_t vault_passkey_serial_ = 0;
  bool vault_passkey_notification_posted_ = false;
  bool VaultPasskeyCurrent(uint64_t serial) const {
    if (!serial || !vault_passkey_ || vault_passkey_->serial != serial ||
        !vault_passkey_callback_ || !active_ || closing_ || discovery_stopped || !web_contents()) return false;
    return VaultPasskeyContextCurrent(vault_passkey_->document,vault_passkey_->owner,vault_passkey_->widget);
  }
  bool VaultPasskeyContextCurrent(const content::WeakDocumentPtr& document,
      const base::WeakPtr<BrowserWindowInterface>& expected_owner,
      const base::WeakPtr<views::Widget>& widget) const {
    if (!vault_passkey_callback_ || !active_ || closing_ || discovery_stopped || !web_contents()) return false;
    auto* frame = document.AsRenderFrameHostIfValid();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (!frame || !frame->IsActive() || !frame->IsRenderFrameLive() || !owner ||
        owner != expected_owner.get() || owner->IsDeleteScheduled() ||
        !owner->IsSelectedForNativeWindow() || owner->GetTabStripModel()->GetActiveTab() != tab ||
        UnloadController::From(owner)->is_attempting_to_close_browser() ||
        UnloadController::From(owner)->owner_close_admitted() ||
        tab->GetContents() != web_contents() || frame->GetBrowserContext() != owner->GetProfile()) return false;
    auto* view = BrowserView::GetBrowserViewForBrowser(owner);
    return view && widget && view->browser_widget() == widget.get();
  }
  void NotifyVaultPasskey() {
    if (vault_passkey_notification_posted_) return;
    vault_passkey_notification_posted_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
        base::BindOnce([](std::weak_ptr<TabObservation> weak) {
          auto self = weak.lock(); if (!self) return;
          self->vault_passkey_notification_posted_ = false;
          auto callback = self->vault_passkey_callback_;
          if (!callback || !self->active_) return;
          uint64_t serial = 0; int operation = 0; std::string arguments;
          NSView* view = nil;
          if (self->vault_passkey_ && self->VaultPasskeyCurrent(self->vault_passkey_->serial)) {
            auto* widget = self->web_contents()->GetRenderWidgetHostView();
            if (widget) view = widget->GetNativeView().GetNativeNSView();
            if (view) { serial = self->vault_passkey_->serial;
              operation = self->vault_passkey_->operation; arguments = self->vault_passkey_->arguments; }
          }
          base::AutoReset depth(&navigation_callback_depth,navigation_callback_depth + 1);
          callback(self->context_.get(),self->token_,serial,operation,arguments.c_str(),(__bridge void*)view);
        },weak_from_this()));
  }
  void CancelVaultPasskey() {
    if (!vault_passkey_) return;
    auto reply = std::move(vault_passkey_->reply);
    vault_passkey_.reset(); NotifyVaultPasskey();
    // Leave native ownership/model stacks before invoking the request handler.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
        base::BindOnce(std::move(reply),std::nullopt));
  }
  void ObserveVaultPasskeys(BarcVaultPasskeyCallback callback) {
    CancelVaultPasskey(); vault_passkey_callback_ = callback; ObserveVaultOwner();
  }
  base::OnceClosure StartVaultPasskey(content::RenderFrameHost* frame,int operation,
      std::string arguments,base::OnceCallback<void(std::optional<std::string>)> reply) {
    auto* tab = tab_.Get(); auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* view = owner ? BrowserView::GetBrowserViewForBrowser(owner) : nullptr;
    if (!vault_passkey_callback_ || !frame || !view || !view->browser_widget() ||
        vault_passkey_ || !frame->IsActive() ||
        content::WebContents::FromRenderFrameHost(frame) != web_contents()) {
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
          base::BindOnce(std::move(reply),std::nullopt)); return {};
    }
    CHECK_NE(vault_passkey_serial_,UINT64_MAX);
    const uint64_t serial = ++vault_passkey_serial_;
    vault_passkey_.emplace(VaultPasskey{serial,frame->GetWeakDocumentPtr(),owner->GetWeakPtr(),
        view->browser_widget()->GetWeakPtr(),operation,std::move(arguments),std::move(reply)});
    if (!VaultPasskeyCurrent(serial)) { CancelVaultPasskey(); return {}; }
    NotifyVaultPasskey();
    return base::BindOnce([](std::weak_ptr<TabObservation> weak,uint64_t serial) {
      if (auto self = weak.lock(); self && self->vault_passkey_ && self->vault_passkey_->serial == serial)
        self->CancelVaultPasskey();
    },weak_from_this(),serial);
  }
  bool CompleteVaultPasskey(uint64_t serial,bool accepted,std::optional<std::string> result) {
    if (!vault_passkey_ || vault_passkey_->serial != serial) return false;
    const bool current = VaultPasskeyCurrent(serial);
    auto reply = std::move(vault_passkey_->reply); vault_passkey_.reset(); NotifyVaultPasskey();
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
        base::BindOnce(std::move(reply),current && accepted ? std::move(result) : std::nullopt));
    return current;
  }
  struct VaultFocus {
    uint64_t token;
    content::WeakDocumentPtr document;
    content::WeakDocumentPtr cache_document;
    base::WeakPtr<autofill::AutofillManager> manager;
    base::WeakPtr<BrowserWindowInterface> owner;
    base::WeakPtr<views::Widget> physical_widget;
    autofill::FormGlobalId form;
    autofill::FieldGlobalId field;
    autofill::FieldRendererId username;
    bool code;
    gfx::RectF bounds;
  };
  void NotifyVaultFocus() {
    if (vault_notification_posted_) return;
    vault_notification_posted_ = true;
    // Leave upstream Autofill observer/model stacks before application callouts.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
        base::BindOnce([](std::weak_ptr<TabObservation> weak) {
          auto self = weak.lock();
          if (!self) return;
          self->vault_notification_posted_ = false;
          auto callback = self->vault_callback_;
          if (!callback || !self->active_ || self->closing_ || discovery_stopped) return;
          uint64_t serial = 0;
          std::string origin;
          int kind = 0;
          NSView* native = nil;
          gfx::RectF rect;
          if (self->vault_focus_ && self->VaultCurrent(self->vault_focus_->token)) {
            const auto& focus = *self->vault_focus_;
            serial = focus.token;
            origin = focus.document.AsRenderFrameHostIfValid()->GetLastCommittedOrigin().Serialize();
            kind = focus.code ? 1 : 0;
            rect = focus.bounds;
            native = self->web_contents()->GetRenderWidgetHostView()->GetNativeView().GetNativeNSView();
          }
          if (!native) serial = 0;
          base::AutoReset depth(&navigation_callback_depth, navigation_callback_depth + 1);
          callback(self->context_.get(), self->token_, serial, origin.c_str(), kind,
                   (__bridge void*)native, rect.x(), rect.y(), rect.width(), rect.height());
        }, weak_from_this()));
  }
  void ClearVaultFocus() {
    if (!vault_focus_) return;
    vault_focus_.reset();
    NotifyVaultFocus();
  }
  void ObserveVault(BarcVaultCallback callback) {
    auto hold = shared_from_this();
    ClearVaultFocus();
    vault_callback_ = callback;
    ObserveVaultOwner();
    vault_managers_.Reset();
    if (callback && web_contents()) {
      if (auto* client = autofill::ContentAutofillClient::FromWebContents(web_contents()))
        vault_managers_.Observe(client, autofill::ScopedAutofillManagersObservation::InitializationPolicy::kObservePreexistingManagers);
    }
  }
  void ObserveVaultOwner() {
    vault_selection_ = {}; vault_active_ = {}; vault_inactive_ = {}; vault_tab_ = {};
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if ((!vault_callback_ && !vault_passkey_callback_) || !owner) return;
    vault_selection_ = owner->RegisterNativeWindowSelectionChanged(base::BindRepeating(
        [](std::weak_ptr<TabObservation> weak) { if (auto self = weak.lock()) self->InvalidateVaultIfNeeded(); }, weak_from_this()));
    auto changed = base::BindRepeating([](std::weak_ptr<TabObservation> weak, BrowserWindowInterface*) {
      if (auto self = weak.lock()) self->InvalidateVaultIfNeeded();
    }, weak_from_this());
    vault_active_ = owner->RegisterDidBecomeActive(changed);
    vault_inactive_ = owner->RegisterDidBecomeInactive(changed);
    vault_tab_ = owner->RegisterActiveTabDidChange(changed);
  }
  bool VaultCurrent(uint64_t token, bool foreground = true) const {
    if (!token || !vault_callback_ || !vault_focus_ || vault_focus_->token != token ||
        !active_ || closing_ || discovery_stopped || !web_contents()) return false;
    auto* frame = vault_focus_->document.AsRenderFrameHostIfValid();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (!frame || !frame->IsActive() || !frame->IsRenderFrameLive() ||
        owner != vault_focus_->owner.get() || !owner || owner->IsDeleteScheduled() ||
        !owner->IsSelectedForNativeWindow() || owner->GetTabStripModel()->GetActiveTab() != tab ||
        UnloadController::From(owner)->is_attempting_to_close_browser() ||
        UnloadController::From(owner)->owner_close_admitted() ||
        LookupTab(owner, tab_id()) != tab || tab->GetContents() != web_contents() ||
        frame->GetBrowserContext() != owner->GetProfile() ||
        web_contents()->GetFocusedFrame() != frame) return false;
    auto* view = web_contents()->GetRenderWidgetHostView();
    if (!view || (foreground && !view->HasFocus())) return false;
    auto* owner_view = BrowserView::GetBrowserViewForBrowser(owner);
    if (!owner_view || !vault_focus_->physical_widget ||
        owner_view->browser_widget() != vault_focus_->physical_widget.get()) return false;
    // Preserve the stock owned-prompt gate; Pawl never restores focus behind
    // an unrelated Chrome permission/install/modal widget.
    for (views::Widget* child : views::Widget::GetAllOwnedWidgets(owner_view->browser_widget()->GetNativeView()))
      if (child->IsVisible()) return false;
    auto* cache_frame = vault_focus_->cache_document.AsRenderFrameHostIfValid();
    auto* manager = vault_focus_->manager.get();
    if (!cache_frame || !manager ||
        static_cast<autofill::ContentAutofillDriver&>(manager->driver()).render_frame_host() != cache_frame) return false;
    const auto* form = manager->FindCachedFormById(vault_focus_->form);
    const auto* field = form ? form->GetFieldById(vault_focus_->field) : nullptr;
    return field && field->is_focusable() &&
        (vault_focus_->code ? field->html_type() == autofill::HtmlFieldType::kOneTimeCode :
         field->form_control_type() == autofill::FormControlType::kInputPassword);
  }
  void InvalidateVaultIfNeeded() {
    if (vault_passkey_ && !VaultPasskeyCurrent(vault_passkey_->serial)) CancelVaultPasskey();
    if (!vault_focus_) return;
    if (!VaultCurrent(vault_focus_->token, false)) ClearVaultFocus();
    else NotifyVaultFocus();
  }
  void OnWebContentsFocused(content::RenderWidgetHost*) override { InvalidateVaultIfNeeded(); }
  void OnWebContentsLostFocus(content::RenderWidgetHost*) override { InvalidateVaultIfNeeded(); }
  bool CancelVaultFocus(uint64_t token) {
    if (!vault_focus_ || vault_focus_->token != token) return false;
    ClearVaultFocus();
    return true;
  }
  void OnAfterAskForValuesToFill(autofill::AutofillManager& manager,
      autofill::FormGlobalId form, autofill::FieldGlobalId field) override {
    if (!vault_focus_) OnAfterFocusOnFormField(manager, form, field);
  }
  void OnAfterFormsSeen(autofill::AutofillManager&, base::span<const autofill::FormGlobalId>,
                       base::span<const autofill::FormGlobalId>) override { InvalidateVaultIfNeeded(); }
  void OnAutofillManagerStateChanged(autofill::AutofillManager& manager,
      autofill::AutofillManager::LifecycleState,
      autofill::AutofillManager::LifecycleState state) override {
    if (vault_focus_ && vault_focus_->manager.get() == &manager &&
        state != autofill::AutofillManager::LifecycleState::kActive) ClearVaultFocus();
  }
  void OnAfterFocusOnNonFormField(autofill::AutofillManager& manager) override {
    auto hold = shared_from_this();
    if (vault_focus_ && vault_focus_->cache_document.AsRenderFrameHostIfValid() ==
        static_cast<autofill::ContentAutofillDriver&>(manager.driver()).render_frame_host()) ClearVaultFocus();
  }
  void OnAfterFocusOnFormField(autofill::AutofillManager& manager,
      autofill::FormGlobalId form_id, autofill::FieldGlobalId field_id) override {
    auto hold = shared_from_this();
    ClearVaultFocus();
    if (!vault_callback_ || !active_ || closing_ || discovery_stopped) return;
    auto* cache_frame = static_cast<autofill::ContentAutofillDriver&>(manager.driver()).render_frame_host();
    auto* factory = autofill::ContentAutofillDriverFactory::FromWebContents(web_contents());
    content::RenderFrameHost* frame = nullptr;
    if (factory) for (auto* driver : factory->GetExistingDrivers()) {
      if (driver->GetFrameToken() == field_id.frame_token)
        frame = static_cast<autofill::ContentAutofillDriver*>(driver)->render_frame_host();
    }
    if (!frame || frame->GetBrowserContext() != cache_frame->GetBrowserContext()) return;
    const auto origin = frame->GetLastCommittedOrigin();
    if (origin.opaque() || !(origin.scheme() == "https" ||
        (origin.scheme() == "http" && (origin.host() == "localhost" || origin.host() == "127.0.0.1")))) return;
    auto pair = manager.FindFormAndField(form_id, field_id);
    if (!pair.form_structure || !pair.autofill_field) return;
    const bool code = pair.autofill_field->html_type() == autofill::HtmlFieldType::kOneTimeCode;
    if (!code && pair.autofill_field->form_control_type() != autofill::FormControlType::kInputPassword) return;
    autofill::FieldRendererId username;
    if (!code) {
      for (const auto& field : pair.form_structure->fields()) {
        if (field->host_frame() == field_id.frame_token && field->is_focusable() &&
            (field->Type().GetTypes().contains(autofill::USERNAME) || field->autocomplete_attribute() == "username")) {
          if (username) return; // Ambiguous form never selects a username by guess.
          username = field->renderer_id();
        }
      }
    }
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* owner_view = owner ? BrowserView::GetBrowserViewForBrowser(owner) : nullptr;
    if (!owner_view) return;
    CHECK_NE(vault_serial_, UINT64_MAX);
    const uint64_t serial = ++vault_serial_;
    vault_focus_.emplace(VaultFocus{serial, frame->GetWeakDocumentPtr(), cache_frame->GetWeakDocumentPtr(), manager.GetWeakPtr(), owner->GetWeakPtr(), owner_view->browser_widget()->GetWeakPtr(), form_id, field_id, username, code, pair.autofill_field->bounds()});
    if (!VaultCurrent(serial)) { vault_focus_.reset(); return; }
    NotifyVaultFocus();
  }
  bool FillVault(uint64_t token, const char* username, const char* secret) {
    auto hold = shared_from_this();
    if (navigation_callback_depth || !username || !secret ||
        // The trusted C caller supplies NUL-terminated borrowed UTF-8.
        // Bound parsing without retaining its pointers after this call.
        UNSAFE_BUFFERS(strnlen(username, 65537)) > 65536 ||
        UNSAFE_BUFFERS(strnlen(secret, 65537)) > 65536 ||
        !base::IsStringUTF8(username) || !base::IsStringUTF8(secret) || !VaultCurrent(token)) return false;
    const auto request = *vault_focus_;
    auto* frame = request.document.AsRenderFrameHostIfValid();
    auto* driver = password_manager::ContentPasswordManagerDriver::GetForRenderFrameHost(frame);
    if (!driver) return false;
    // Consume before sending a typed driver command; no reusable secret capability.
    vault_focus_.reset();
    if (request.code)
      driver->FillField(request.field.renderer_id, base::UTF8ToUTF16(secret),
          autofill::FieldPropertiesFlags::kAutofilledOnUserTrigger, base::DoNothing());
    else
      driver->FillSuggestionById(request.username, request.field.renderer_id,
          base::UTF8ToUTF16(username), base::UTF8ToUTF16(secret),
          autofill::AutofillSuggestionTriggerSource::kManualFallbackPasswords);
    return true;
  }

  bool closing() const { return closing_; }
  void RecordNativeBlock(int64_t navigation, const GURL& url) {
    if (active_ && !closing_ && navigation && navigation_ == navigation &&
        url.SchemeIsHTTPOrHTTPS()) blocked_url_ = url;
  }
  bool NativeBlockCurrent(int64_t navigation, const GURL& url) const {
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    return active_ && !closing_ && !discovery_stopped && web_contents() &&
        navigation_ == navigation && blocked_url_ == url && owner &&
        !owner->IsDeleteScheduled() && !UnloadController::From(owner)->owner_close_admitted() &&
        !UnloadController::From(owner)->is_attempting_to_close_browser() &&
        LookupTab(owner, tab_id()) == tab && tab->GetContents() == web_contents() &&
        web_contents()->GetBrowserContext() == owner->GetProfile();
  }
  void ShowNativeBlock(int64_t navigation, const GURL& url) {
    if (!NativeBlockCurrent(navigation, url)) return;
    auto* manager = infobars::ContentInfoBarManager::FromWebContents(web_contents());
    if (!manager) return;
    manager->AddInfoBar(ConfirmInfoBar::Create(std::make_unique<NativeBlockInfoBar>(
        base::BindRepeating([](std::weak_ptr<TabObservation> weak,
                              int64_t navigation, GURL url) {
          auto self = weak.lock();
          if (!self || !self->NativeBlockCurrent(navigation, url)) return;
          auto* tab = self->tab_.Get();
          auto* owner = tab->GetBrowserWindowInterface();
          if (!owner->IsSelectedForNativeWindow() ||
              owner->GetTabStripModel()->GetActiveTab() != tab) return;
          self->Emit(BARC_TAB_CONTINUE_NATIVE_BLOCK, 0, 0, &url);
        }, weak_from_this(), navigation, url))), true);
  }
  bool EnablePeek(bool enabled) {
    if (!active_ || closing_) return false;
    peek_enabled_ = enabled;
    if (!enabled) { peek_request_.reset(); peek_current_serial_ = 0; }
    return true;
  }
  struct PeekRequest {
    PeekRequest(content::RenderFrameHost* frame, content::WebContents* contents,
                BrowserWindowInterface* owner, const content::OpenURLParams& params)
        : document(frame->GetWeakDocumentPtr()),
          main_document(contents->GetPrimaryMainFrame()->GetWeakDocumentPtr()),
          owner(owner->GetWeakPtr()), params(params) {}
    content::WeakDocumentPtr document;
    content::WeakDocumentPtr main_document;
    base::WeakPtr<BrowserWindowInterface> owner;
    content::OpenURLParams params;
  };
  bool CanRequestPeek(content::RenderFrameHost* frame) const {
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    std::array<char, 37> identity{};
    auto* view = owner ? BrowserView::GetBrowserViewForBrowser(owner) : nullptr;
    const bool managed = view && !view->browser_widget()->HasPhysicalClosePending() && owner &&
        (barc_window_profile_uuid(owner->GetSessionID().id(), identity.data(), identity.size()) == identity.size() ||
         barc_window_private_session_uuid(owner->GetSessionID().id(), identity.data(), identity.size()) == identity.size());
    return managed && owner->GetType() == BrowserWindowInterface::TYPE_NORMAL &&
        owner->IsSelectedForNativeWindow() && owner->GetTabStripModel()->GetActiveTab() == tab &&
        active_ && !closing_ && peek_enabled_ && !PeekRoleFor(tab) &&
        !barc::IsPeekCloseCommitted(tab) && frame && frame->IsActive() && web_contents() &&
        content::WebContents::FromRenderFrameHost(frame) == web_contents() &&
        web_contents()->GetPrimaryMainFrame() && owner &&
        Window(owner->GetSessionID().id()) == owner &&
        owner->GetProfile() == frame->GetBrowserContext() &&
        !UnloadController::From(owner)->owner_close_admitted() &&
        barc::CanResolveApplicationBrowser();
  }
  void RequestPeek(content::RenderFrameHost* frame,
                   const content::OpenURLParams& params) {
    if (!CanRequestPeek(frame) || !params.url.is_valid() ||
        params.url.SchemeIs("javascript") ||
        peek_serial_ == std::numeric_limits<int32_t>::max())
      return;
    auto keep_alive = shared_from_this();
    peek_request_.emplace(frame, web_contents(),
                         tab_.Get()->GetBrowserWindowInterface(), params);
    ++peek_serial_;
    peek_current_serial_ = peek_serial_;
    Emit(BARC_TAB_PEEK_REQUESTED, peek_serial_, 0, &params.url);
  }
  bool PeekRequestIsCurrent(int32_t serial) const {
    if (serial <= 0 || serial != peek_serial_ || !peek_request_)
      return false;
    auto* frame = peek_request_->document.AsRenderFrameHostIfValid();
    return CanRequestPeek(frame) && peek_request_->owner &&
        tab_.Get()->GetBrowserWindowInterface() == peek_request_->owner.get() &&
        peek_request_->main_document.AsRenderFrameHostIfValid() ==
            web_contents()->GetPrimaryMainFrame();
  }
  std::optional<PeekRequest> TakePeekRequest(int32_t serial) {
    if (!PeekRequestIsCurrent(serial))
      return std::nullopt;
    auto request = std::move(peek_request_);
    peek_request_.reset();
    return request;
  }
  bool PeekSerialIsCurrent(int32_t serial) const {
    return active_ && !closing_ && peek_current_serial_ == serial;
  }
  void Cancel() {
    auto keep_alive = shared_from_this();
    CancelFiles(false);
    ObserveVault(nullptr);
    ObserveVaultSave(nullptr);
    ObserveVaultPasskeys(nullptr);
    active_ = false;
    CancelPicker();
    CancelScript();
    peek_enabled_ = false;
    peek_request_.reset();
    peek_current_serial_ = 0;
    if (thumbnail_) {
      thumbnail_->cancelled.Set();
      thumbnail_.reset();
    }
    site_data_remover_.Reset();
    site_data_.reset();
    translation_receiver_.reset();
    translation_callback_ = nullptr;
    translation_document_ = {};
    media_callback_ = nullptr;
    media_receiver_.reset();
    media_snapshot_.reset();
    media_document_ = {};
    media_refresh_pending_ = false;
    active_ = false;
    callback_ = nullptr;
    context_ = nullptr;
    Observe(nullptr);
    UnbindOwner();
    detach_ = {};
    insert_ = {};
    discard_ = {};
  }
  bool CancelCapture(uint64_t request) {
    if (!thumbnail_ || thumbnail_->request != request) return false;
    thumbnail_->cancelled.Set();
    thumbnail_->callback = nullptr;
    // Keep the single slot occupied until the compositor/encoding callback
    // retires. Cancellation must not enqueue another large copy per call.
    return true;
  }
  bool ScreenshotAllowed() const {
    return web_contents() &&
        extensions::ExtensionsBrowserClient::Get()->IsScreenshotRestricted(web_contents()).has_value();
  }
  bool CaptureThumbnail(uint64_t request, BarcTabThumbnailCallback callback,
                        int32_t screenshot_width = 0) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || discovery_stopped || thumbnail_ || !request || !callback || !web_contents() ||
        screenshot_width < 0 || screenshot_width > 4096)
      return false;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* view = web_contents()->GetRenderWidgetHostView();
    auto* document = web_contents()->GetPrimaryMainFrame();
    if (!owner || owner->IsDeleteScheduled() ||
        UnloadController::From(owner)->owner_close_admitted() ||
        UnloadController::From(owner)->is_attempting_to_close_browser() ||
        LookupTab(owner, tab_id()) != tab || tab->GetContents() != web_contents() ||
        web_contents()->GetBrowserContext() != owner->GetProfile() ||
        !view || !document || !document->IsActive() || !ScreenshotAllowed())
      return false;
    if (screenshot_width) {
      if (!view->IsSurfaceAvailableForCopy()) return false;
    } else if (!owner->IsSelectedForNativeWindow() ||
        owner->GetTabStripModel()->GetActiveTab() != tab ||
        web_contents()->GetVisibility() != content::Visibility::VISIBLE || !view->IsShowing()) {
      return false;
    }
    const gfx::Size bounds = view->GetViewBounds().size();
    if (bounds.IsEmpty())
      return false;
    // Scale at copy time; never allocate a full-resolution screenshot first.
    const double native_scale = screenshot_width ? view->GetDeviceScaleFactor() : 1.0;
    const double scale = screenshot_width
        ? std::min(native_scale, static_cast<double>(screenshot_width) / bounds.width())
        : std::min(1.0, 400.0 / std::max(bounds.width(), bounds.height()));
    const double width = std::max(1.0, std::floor(bounds.width() * scale));
    const double height = std::max(1.0, std::floor(bounds.height() * scale));
    if (!std::isfinite(width) || !std::isfinite(height) ||
        width > 4096 || height > 4096 || width * height > 8 * 1024 * 1024)
      return false;
    const gfx::Size output(static_cast<int>(width), static_cast<int>(height));
    auto capture = std::make_shared<ThumbnailCapture>();
    capture->screenshot = screenshot_width != 0;
    capture->output = output;
    capture->owner = owner->GetWeakPtr();
    capture->document = document->GetWeakDocumentPtr();
    capture->navigation = navigation_;
    capture->request = request;
    capture->callback = callback;
    thumbnail_ = capture;
    view->CopyFromSurface(gfx::Rect(), output, base::Seconds(1),
        base::BindPostTaskToCurrentDefault(base::BindOnce(
            [](std::weak_ptr<TabObservation> weak,
               std::shared_ptr<ThumbnailCapture> capture,
               const content::CopyFromSurfaceResult& result) {
              if (auto self = weak.lock())
                self->ThumbnailCopied(std::move(capture), result);
            }, weak_from_this(), capture)));
    return true;
  }
  struct FileRequest : network::SimpleURLLoaderStreamConsumer,
                       std::enable_shared_from_this<FileRequest> {
    std::weak_ptr<TabObservation> observer;
    base::WeakPtr<BrowserWindowInterface> owner;
    content::WeakDocumentPtr document;
    int64_t navigation=0, bytes=0;
    uint64_t id=0;
    GURL url;
    base::FilePath temporary;
    std::string basename;
    base::ScopedFD directory;
    BarcFileCallback callback=nullptr;
    std::unique_ptr<network::SimpleURLLoader> loader;
    std::unique_ptr<net::FileStream> stream;
    scoped_refptr<net::DrainableIOBuffer> buffer;
    base::OnceClosure resume;
    ~FileRequest() override {
      if (directory.is_valid() && !basename.empty()) unlinkat(directory.get(),basename.c_str(),0);
    }
    void OnDataReceived(std::string_view data,base::OnceClosure continue_reading) override {
      auto request=shared_from_this();
      if (auto self=observer.lock()) self->FileData(request,data,std::move(continue_reading));
    }
    void OnComplete(bool success) override {
      auto request=shared_from_this();
      if (auto self=observer.lock()) self->FileComplete(request,success);
    }
    void OnRetry(base::OnceClosure) override {
      auto request=shared_from_this();
      if (auto self=observer.lock()) self->FinishFile(request,BARC_FILE_FAILED);
    }
  };
  struct PreparedFile {
    PreparedFile()=default;
    PreparedFile(PreparedFile&&)=default;
    PreparedFile& operator=(PreparedFile&& other) {
      if (this!=&other) {
        Cleanup();directory=std::move(other.directory);file=std::move(other.file);
        basename=std::move(other.basename);path=std::move(other.path);
      }
      return *this;
    }
    ~PreparedFile(){Cleanup();}
    void Cleanup(){if (directory.is_valid() && !basename.empty()) unlinkat(directory.get(),basename.c_str(),0);}
    base::ScopedFD directory;
    base::File file;
    std::string basename;
    base::FilePath path;
  };
  static void DeleteOwnedFile(base::ScopedFD directory,std::string basename,base::File file={}) {
    PreparedFile owned;owned.directory=std::move(directory);owned.basename=std::move(basename);owned.file=std::move(file);
    // The RAII payload also unlinks if shutdown rejects/drops this cleanup task.
    base::ThreadPool::PostTask(FROM_HERE,{base::MayBlock()},base::BindOnce(
        [](PreparedFile owned) {},std::move(owned)));
  }
  bool FileCurrent(const std::shared_ptr<FileRequest>& request,bool admitted=true) const {
    auto* frame = request->document.AsRenderFrameHostIfValid();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    const auto found=file_requests_.find(request->id);
    return (!admitted || (found!=file_requests_.end() && found->second==request)) &&
        active_ && !closing_ && !discovery_stopped && frame && frame->IsActive() &&
        web_contents() && frame == web_contents()->GetPrimaryMainFrame() &&
        navigation_ == request->navigation && owner && owner == request->owner.get() &&
        !owner->IsDeleteScheduled() && Window(owner->GetSessionID().id()) == owner &&
        LookupTab(owner, tab_id()) == tab && tab->GetContents() == web_contents() &&
        frame->GetBrowserContext() == owner->GetProfile() && !owner->GetProfile()->ShutdownStarted() &&
        !IsProfileDirectoryPendingDeletion(owner->GetProfile()->GetPath()) &&
        !UnloadController::From(owner)->owner_close_admitted() &&
        !UnloadController::From(owner)->is_attempting_to_close_browser();
  }
  void FinishFile(std::shared_ptr<FileRequest> request, int result, int status=0,
                  std::string mime={}, int64_t bytes=0, bool deliver=true) {
    auto hold = shared_from_this();
    auto found = file_requests_.find(request->id);
    if (found == file_requests_.end() || found->second != request) return;
    file_requests_.erase(found);
    if (file_requests_.empty()) file_profile_observation_.Reset();
    auto callback = std::exchange(request->callback, nullptr);
    request->loader.reset();
    request->stream.reset(); // Cancels writes using its descriptor, never a pathname.
    request->buffer=nullptr;request->resume.Reset();
    int descriptor=-1;
    const std::string temporary=request->temporary.value();
    if (result==BARC_FILE_OK && deliver && active_) descriptor=request->directory.release();
    else DeleteOwnedFile(std::move(request->directory),std::move(request->basename));
    if (deliver && active_ && callback) {
      base::AutoReset<int> scope(&navigation_callback_depth,navigation_callback_depth+1);
      callback(context_.get(),token_,request->id,result,status,
          descriptor>=0 ? temporary.c_str():"",mime.c_str(),bytes,descriptor);
    }
  }
  void CancelFiles(bool deliver=true) {
    auto requests = file_requests_;
    for (auto& [id, request] : requests) FinishFile(request, BARC_FILE_CANCELLED, 0, {}, 0, deliver);
  }
  void OnProfileMarkedForPermanentDeletion(Profile* profile) override {
    CancelFilesForProfile(profile->GetPath());
  }
  void OnProfileManagerDestroying() override { CancelFiles(); }
  bool CancelFile(uint64_t id) {
    auto found=file_requests_.find(id);
    if (found==file_requests_.end()) return false;
    FinishFile(found->second, BARC_FILE_CANCELLED);return true;
  }
  void CancelFilesForProfile(const base::FilePath& path) {
    if (web_contents() && Profile::FromBrowserContext(web_contents()->GetBrowserContext())->GetPath()==path)
      CancelFiles();
  }
  bool DownloadFile(uint64_t id, GURL url, base::FilePath directory, BarcFileCallback callback) {
    auto hold=shared_from_this();
    if (navigation_callback_depth || !id || !callback || file_requests_.size()>=6 ||
        file_requests_.contains(id) || !url.is_valid() || !url.SchemeIs("https") ||
        url.has_username() || url.has_password() || !directory.IsAbsolute() || !web_contents()) return false;
    auto* tab=tab_.Get();auto* owner=tab ? tab->GetBrowserWindowInterface():nullptr;
    auto* frame=web_contents()->GetPrimaryMainFrame();
    if (!owner || !frame) return false;
    auto request=std::make_shared<FileRequest>();
    request->id=id;request->owner=owner->GetWeakPtr();request->document=frame->GetWeakDocumentPtr();
    request->navigation=navigation_;request->url=std::move(url);request->callback=callback;
    if (!FileCurrent(request,false)) return false;
    if (!g_browser_process || !g_browser_process->profile_manager()) return false;
    request->observer=weak_from_this();
    file_requests_.emplace(id,request);
    if (!file_profile_observation_.IsObserving()) file_profile_observation_.Observe(g_browser_process->profile_manager());
    base::ThreadPool::PostTaskAndReplyWithResult(FROM_HERE,{base::MayBlock()},
        base::BindOnce([](base::FilePath directory) {
          PreparedFile prepared;base::FilePath canonical;
          if (!base::NormalizeFilePath(directory,&canonical) || canonical!=directory) return prepared;
          prepared.directory.reset(open(directory.value().c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));
          struct stat opened{},named{};
          if (!prepared.directory.is_valid() || fstat(prepared.directory.get(),&opened) ||
              stat(directory.value().c_str(),&named) || opened.st_dev!=named.st_dev || opened.st_ino!=named.st_ino)
            return prepared;
          prepared.basename=".devmcp-"+base::Uuid::GenerateRandomV4().AsLowercaseString();
          const int file=openat(prepared.directory.get(),prepared.basename.c_str(),O_CREAT|O_EXCL|O_WRONLY|O_CLOEXEC|O_NOFOLLOW,0600);
          if (file>=0) {prepared.file=base::File(file);prepared.path=directory.AppendASCII(prepared.basename);}
          else prepared.basename.clear();
          return prepared;
        },std::move(directory)),
        base::BindOnce([](std::weak_ptr<TabObservation> weak,std::shared_ptr<FileRequest> request,PreparedFile prepared) {
          auto self=weak.lock();
          if (!self || !self->file_requests_.contains(request->id) || self->file_requests_.at(request->id)!=request) {
            DeleteOwnedFile(std::move(prepared.directory),std::move(prepared.basename),std::move(prepared.file));return;
          }
          request->directory=std::move(prepared.directory);request->basename=std::move(prepared.basename);
          request->temporary=std::move(prepared.path);
          if (!prepared.file.IsValid()) {self->FinishFile(request,BARC_FILE_FAILED);return;}
          request->stream=std::make_unique<net::FileStream>(std::move(prepared.file),
              base::ThreadPool::CreateSequencedTaskRunner({base::MayBlock(),base::TaskPriority::USER_VISIBLE}));
          self->StartFile(request);
        },weak_from_this(),request));
    return true;
  }
  void StartFile(std::shared_ptr<FileRequest> request) {
    auto hold=shared_from_this();
    if (!FileCurrent(request)) {FinishFile(request,BARC_FILE_CANCELLED);return;}
    if (request->temporary.empty()) {FinishFile(request,BARC_FILE_FAILED);return;}
    auto* frame=request->document.AsRenderFrameHostIfValid();
    auto resource=std::make_unique<network::ResourceRequest>();
    resource->url=request->url;
    resource->site_for_cookies=frame->GetIsolationInfoForSubresources().site_for_cookies();
    resource->request_initiator=frame->GetLastCommittedOrigin();
    resource->trusted_params.emplace();
    resource->trusted_params->isolation_info=frame->GetIsolationInfoForSubresources();
    resource->credentials_mode=network::mojom::CredentialsMode::kInclude;
    resource->load_flags=net::LOAD_DO_NOT_SAVE_COOKIES | net::LOAD_DISABLE_CACHE;
    resource->do_not_prompt_for_login=true;
    const auto referrer=content::Referrer::SanitizeForRequest(request->url,
        content::Referrer(frame->GetLastCommittedURL(),network::mojom::ReferrerPolicy::kDefault));
    resource->referrer=referrer.url;
    resource->referrer_policy=content::Referrer::ReferrerPolicyForUrlRequest(referrer.policy);
    const auto& user_agent=web_contents()->GetUserAgentOverride();
    if (!user_agent.ua_string_override.empty()) resource->headers.SetHeader("User-Agent",user_agent.ua_string_override);
    static constexpr auto annotation=net::DefineNetworkTrafficAnnotation("barc_devmcp_download",R"(
      semantics { sender:"Nook DevMCP download tool" description:"User-authorized HTTPS GET to an owned temporary file in the configured tool directory." trigger:"Authorized developer tool call." data:"The exact Agent profile's normal destination cookies, user agent and sanitized referrer." destination:WEBSITE }
      policy { cookies_allowed:YES cookies_store:"The exact Agent profile storage partition." setting:"Developer mode and local browser tools must both be enabled." policy_exception_justification:"Explicit authenticated local developer tool request." })");
    request->loader=network::SimpleURLLoader::Create(std::move(resource),annotation);
    request->loader->SetTimeoutDuration(base::Seconds(30));
    request->loader->SetOnRedirectCallback(base::BindRepeating(
        [](std::weak_ptr<TabObservation> weak,std::weak_ptr<FileRequest> pending,const GURL&,
           const net::RedirectInfo& redirect,const network::mojom::URLResponseHead& response,std::vector<std::string>*) {
          auto self=weak.lock();auto request=pending.lock();if (!self || !request) return;
          if (!self->FileCurrent(request)) self->FinishFile(request,BARC_FILE_CANCELLED);
          else if (!redirect.new_url.SchemeIs("https") || redirect.new_url.has_username() || redirect.new_url.has_password())
            self->FinishFile(request,BARC_FILE_HTTP,response.headers ? response.headers->response_code():0);
        },weak_from_this(),std::weak_ptr<FileRequest>(request)));
    auto factory=frame->GetStoragePartition()->GetURLLoaderFactoryForBrowserProcess();
    if (!FileCurrent(request)) {FinishFile(request,BARC_FILE_CANCELLED);return;}
    request->loader->DownloadAsStream(factory.get(),request.get());
  }
  void FileData(std::shared_ptr<FileRequest> request,std::string_view data,base::OnceClosure resume) {
    auto hold=shared_from_this();
    if (!FileCurrent(request)) {FinishFile(request,BARC_FILE_CANCELLED);return;}
    if (data.size()>100*1024*1024-static_cast<size_t>(request->bytes)) {FinishFile(request,BARC_FILE_TOO_LARGE);return;}
    // Pinned network loading_params.cc caps its pipe at 2MiB. Keep at most
    // one such chunk while FileStream applies backpressure; never a whole body.
    if (data.size()>2*1024*1024 || request->buffer) {FinishFile(request,BARC_FILE_FAILED);return;}
    request->buffer=base::MakeRefCounted<net::DrainableIOBuffer>(
        base::MakeRefCounted<net::StringIOBuffer>(std::string(data)),data.size());
    request->resume=std::move(resume);WriteFile(request);
  }
  void WriteFile(std::shared_ptr<FileRequest> request) {
    if (!FileCurrent(request)) {FinishFile(request,BARC_FILE_CANCELLED);return;}
    auto result=request->stream->Write(request->buffer.get(),request->buffer->BytesRemaining(),
        base::BindOnce([](std::weak_ptr<TabObservation> weak,std::weak_ptr<FileRequest> pending,
                          base::expected<base::ByteSize,net::Error> result) {
          if (auto self=weak.lock()) if (auto request=pending.lock()) self->FileWritten(request,std::move(result));
        },weak_from_this(),std::weak_ptr<FileRequest>(request)));
    if (result || result.error()!=net::ERR_IO_PENDING) FileWritten(request,std::move(result));
  }
  void FileWritten(std::shared_ptr<FileRequest> request,base::expected<base::ByteSize,net::Error> result) {
    auto hold=shared_from_this();
    if (!FileCurrent(request)) {FinishFile(request,BARC_FILE_CANCELLED);return;}
    if (!result || result->InBytes()<=0 || result->InBytes()>static_cast<uint64_t>(request->buffer->BytesRemaining())) {
      FinishFile(request,BARC_FILE_FAILED);return;
    }
    const int bytes=static_cast<int>(result->InBytes());request->bytes+=bytes;request->buffer->DidConsume(bytes);
    if (request->buffer->BytesRemaining()) {WriteFile(request);return;}
    request->buffer=nullptr;
    auto resume=std::move(request->resume);std::move(resume).Run();
  }
  void FileComplete(std::shared_ptr<FileRequest> request,bool success) {
    auto hold=shared_from_this();
    if (!FileCurrent(request)) {FinishFile(request,BARC_FILE_CANCELLED);return;}
    const auto* response=request->loader->ResponseInfo();
    const int status=response && response->headers ? response->headers->response_code():0;
    std::string mime;if (response && response->headers) response->headers->GetMimeType(&mime);
    if (!success || request->buffer) {
      FinishFile(request,status && (status<200 || status>=300)?BARC_FILE_HTTP:BARC_FILE_FAILED,status,mime);return;
    }
    request->stream->Close(base::BindOnce(
        [](std::weak_ptr<TabObservation> weak,std::weak_ptr<FileRequest> pending,int status,std::string mime,net::Error result) {
          auto self=weak.lock();auto request=pending.lock();if (!self || !request) return;
          self->FinishFile(request,!self->FileCurrent(request)?BARC_FILE_CANCELLED:
              (result==net::OK?BARC_FILE_OK:BARC_FILE_FAILED),status,std::move(mime),request->bytes);
        },weak_from_this(),std::weak_ptr<FileRequest>(request),status,std::move(mime)));
  }
  std::map<uint64_t,std::shared_ptr<FileRequest>> file_requests_;
  base::ScopedObservation<ProfileManager,ProfileManagerObserver> file_profile_observation_{this};
  bool TranslationCurrent() const {
    auto* frame = translation_document_.AsRenderFrameHostIfValid();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    return !discovery_stopped && active_ && !closing_ && frame && web_contents() &&
        frame == web_contents()->GetPrimaryMainFrame() && frame->IsActive() &&
        frame->IsRenderFrameLive() && !frame->IsErrorDocument() && owner &&
        !owner->IsDeleteScheduled() && !UnloadController::From(owner)->owner_close_admitted() &&
        Window(owner->GetSessionID().id()) == owner && LookupTab(owner, tab_id()) == tab &&
        frame->GetBrowserContext() == owner->GetProfile();
  }
  static std::string TranslationPayload(const std::string& text, const std::string& language,
      const std::vector<chrome::mojom::NookTranslationNodePtr>& nodes) {
    if (text.size() > 8192 || language.size() > 256 || nodes.size() > 128) return {};
    base::ListValue list;
    size_t bytes = 0;
    for (const auto& node : nodes) {
      bytes += node->id.size() + node->text.size();
      if (node->id.size() > 32 || node->text.size() > 131072 || bytes > 512 * 1024) return {};
      list.Append(base::DictValue().Set("id", node->id).Set("text", node->text));
    }
    auto payload = base::WriteJson(base::DictValue().Set("text", text).Set("lang", language)
        .Set("nodes", std::move(list))).value_or(std::string());
    return payload.size() <= 512 * 1024 ? payload : std::string();
  }
  void NodesChanged(const blink::DocumentToken& document, uint64_t generation,
                    bool aborted, std::vector<chrome::mojom::NookTranslationNodePtr> nodes) override {
    auto keep_alive = shared_from_this();
    if (!TranslationCurrent() || generation != translation_generation_ || !translation_callback_) return;
    auto* frame = translation_document_.AsRenderFrameHostIfValid();
    if (frame->GetDocumentToken() != document) return;
    auto payload = TranslationPayload("", "", nodes);
    if (payload.empty()) return;
    base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
    translation_callback_(context_.get(), token_, generation, 0, aborted ? 2 : 0, payload.c_str());
  }
  struct PickerRequest {
    uint64_t request;
    int32_t window;
    base::WeakPtr<BrowserWindowInterface> owner;
    content::WeakDocumentPtr document;
    blink::DocumentToken token;
    BarcPickerCallback callback;
  };
  bool PickerCurrent() const {
    if (!picker_ || !active_ || closing_ || discovery_stopped || !web_contents()) return false;
    auto* owner = picker_->owner.get();
    auto* tab = tab_.Get();
    auto* frame = picker_->document.AsRenderFrameHostIfValid();
    return owner && Window(picker_->window) == owner && !owner->IsDeleteScheduled() &&
        !UnloadController::From(owner)->owner_close_admitted() &&
        !UnloadController::From(owner)->is_attempting_to_close_browser() &&
        tab && tab->IsActivated() && web_contents()->GetVisibility() == content::Visibility::VISIBLE &&
        tab->GetBrowserWindowInterface() == owner &&
        LookupTab(owner, tab_id()) == tab && tab->GetContents() == web_contents() &&
        web_contents()->GetBrowserContext() == owner->GetProfile() && frame &&
        frame == web_contents()->GetPrimaryMainFrame() && frame->IsActive() &&
        frame->IsRenderFrameLive() && !frame->IsErrorDocument();
  }
  void CancelPicker(uint64_t request = 0) {
    if (!picker_ || (request && picker_->request != request)) return;
    auto keep_alive = shared_from_this();
    auto pending = std::move(picker_);
    picker_.reset();
    if (picker_remote_.is_bound())
      picker_remote_->NookCancelBoostPicker(pending->token, token_, pending->request);
    picker_remote_.reset();
    base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
    pending->callback(context_.get(), token_, pending->request, "", 0);
  }
  void OnVisibilityChanged(content::Visibility visibility) override {
    if (visibility != content::Visibility::VISIBLE) {
      ClearVaultFocus();
      CancelPicker();
    }
  }
  bool StartPicker(uint64_t request, BarcPickerCallback callback) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || discovery_stopped || picker_ || !callback ||
        !request || request <= picker_request_ || !web_contents()) return false;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* frame = web_contents()->GetPrimaryMainFrame();
    if (!owner || !tab->IsActivated() || owner->IsDeleteScheduled() ||
        UnloadController::From(owner)->owner_close_admitted() ||
        UnloadController::From(owner)->is_attempting_to_close_browser() ||
        LookupTab(owner, tab_id()) != tab || tab->GetContents() != web_contents() ||
        web_contents()->GetBrowserContext() != owner->GetProfile() ||
        web_contents()->GetVisibility() != content::Visibility::VISIBLE ||
        !frame || !frame->IsActive() || !frame->IsRenderFrameLive() || frame->IsErrorDocument() ||
        !frame->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() ||
        frame->IsSandboxed(network::mojom::WebSandboxFlags::kScripts) ||
        !web_contents()->GetOrCreateWebPreferences().javascript_enabled ||
        HostContentSettingsMapFactory::GetForProfile(owner->GetProfile())->GetContentSetting(
            frame->GetLastCommittedURL(), frame->GetLastCommittedURL(),
            ContentSettingsType::JAVASCRIPT) == CONTENT_SETTING_BLOCK) return false;
    picker_request_ = request;
    picker_.emplace(PickerRequest{request, owner->GetSessionID().id(), owner->GetWeakPtr(),
        frame->GetWeakDocumentPtr(), frame->GetDocumentToken(), callback});
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&picker_remote_);
    if (!PickerCurrent()) { picker_.reset(); picker_remote_.reset(); return false; }
    picker_remote_->NookStartBoostPicker(picker_->token, token_, request,
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(base::BindOnce(
            [](std::weak_ptr<TabObservation> weak, uint64_t request, const std::string& selector) {
              auto self = weak.lock();
              if (!self || !self->picker_ || self->picker_->request != request) return;
              const bool current = self->PickerCurrent();
              auto callback = self->picker_->callback;
              self->picker_.reset(); self->picker_remote_.reset();
              const bool valid = current && selector.size() <= 2048 && base::IsStringUTF8(selector) &&
                  selector.find('\0') == std::string::npos;
              base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
              callback(self->context_.get(), self->token_, request,
                  valid ? selector.data() : "", valid ? selector.size() : 0);
            }, weak_from_this(), request), std::string()));
    return true;
  }
  std::optional<PickerRequest> picker_;
  uint64_t picker_request_ = 0;
  mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> picker_remote_;

  struct ScriptRequest {
    uint64_t request;
    int32_t window;
    base::WeakPtr<BrowserWindowInterface> owner;
    content::WeakDocumentPtr document;
    blink::DocumentToken token;
    BarcScriptCallback callback;
  };
  bool ScriptCurrent() const {
    if (!script_ || !active_ || closing_ || discovery_stopped || !web_contents()) return false;
    auto* owner = script_->owner.get();
    auto* tab = tab_.Get();
    auto* frame = script_->document.AsRenderFrameHostIfValid();
    return owner && Window(script_->window) == owner && !owner->IsDeleteScheduled() &&
        !UnloadController::From(owner)->owner_close_admitted() &&
        !UnloadController::From(owner)->is_attempting_to_close_browser() &&
        tab && tab->GetBrowserWindowInterface() == owner &&
        LookupTab(owner, tab_id()) == tab && tab->GetContents() == web_contents() &&
        web_contents()->GetBrowserContext() == owner->GetProfile() && frame &&
        frame == web_contents()->GetPrimaryMainFrame() && frame->IsActive() &&
        frame->IsRenderFrameLive() && !frame->IsErrorDocument();
  }
  void CancelScript(uint64_t request = 0) {
    if (!script_ || (request && script_->request != request)) return;
    auto keep_alive = shared_from_this();
    auto pending = std::move(script_);
    script_.reset();
    if (script_remote_.is_bound())
      script_remote_->NookCancelScript(pending->token, token_, pending->request);
    script_remote_.reset();
    auto callback = pending->callback;
    base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
    callback(context_.get(), token_, pending->request, BARC_SCRIPT_CANCELLED, "", 0, "", 0, 0);
  }
  bool EvaluateScript(uint64_t request, int32_t mode, int32_t world,
                      const std::string& source, BarcScriptCallback callback) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || discovery_stopped || script_ || !callback ||
        !request || request <= script_request_ || source.size() > 128 * 1024 ||
        (mode != 0 && mode != 1) || (world != 0 && world != 1) || !web_contents()) return false;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* frame = web_contents()->GetPrimaryMainFrame();
    if (!owner || owner->IsDeleteScheduled() ||
        UnloadController::From(owner)->owner_close_admitted() ||
        UnloadController::From(owner)->is_attempting_to_close_browser() ||
        LookupTab(owner, tab_id()) != tab || tab->GetContents() != web_contents() ||
        web_contents()->GetBrowserContext() != owner->GetProfile() ||
        !frame || !frame->IsActive() || !frame->IsRenderFrameLive() || frame->IsErrorDocument() ||
        !frame->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() ||
        frame->IsSandboxed(network::mojom::WebSandboxFlags::kScripts) ||
        !web_contents()->GetOrCreateWebPreferences().javascript_enabled ||
        HostContentSettingsMapFactory::GetForProfile(owner->GetProfile())->GetContentSetting(
            frame->GetLastCommittedURL(), frame->GetLastCommittedURL(),
            ContentSettingsType::JAVASCRIPT) == CONTENT_SETTING_BLOCK ||
        !DevToolsWindow::AllowDevToolsFor(owner->GetProfile(), web_contents())) return false;
    script_request_ = request;
    script_.emplace(ScriptRequest{request, owner->GetSessionID().id(), owner->GetWeakPtr(),
        frame->GetWeakDocumentPtr(), frame->GetDocumentToken(), callback});
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&script_remote_);
    if (!ScriptCurrent()) { script_.reset(); script_remote_.reset(); return false; }
    script_remote_->NookEvaluateScript(script_->token, token_, request, mode, world, source,
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(base::BindOnce(
            [](std::weak_ptr<TabObservation> weak, uint64_t request,
               chrome::mojom::NookScriptResultPtr result) {
              auto self = weak.lock();
              if (!self || !self->script_ || self->script_->request != request) return;
              const bool current = self->ScriptCurrent();
              auto callback = self->script_->callback;
              self->script_.reset();
              self->script_remote_.reset();
              const int status = !current ? BARC_SCRIPT_CANCELLED :
                  (result ? static_cast<int>(result->status) : BARC_SCRIPT_UNAVAILABLE);
              base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
              callback(self->context_.get(), self->token_, request, status,
                  result && current ? result->text.data() : "",
                  result && current ? result->text.size() : 0,
                  result && current ? result->json.data() : "",
                  result && current ? result->json.size() : 0,
                  result && current && result->is_string);
            }, weak_from_this(), request), chrome::mojom::NookScriptResultPtr()));
    return true;
  }
  std::optional<ScriptRequest> script_;
  uint64_t script_request_ = 0;
  mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> script_remote_;

  bool Translate(uint64_t generation, uint64_t request, int32_t operation,
                 const std::string& json, BarcTranslationCallback callback) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || !web_contents() || !generation || !request || !callback ||
        operation < 0 || operation > 3 || generation < translation_generation_ ||
        json.size() > 512 * 1024 || request <= translation_request_) return false;
    auto* frame = web_contents()->GetPrimaryMainFrame();
    if (!frame || !frame->IsActive() || !frame->IsRenderFrameLive() || frame->IsErrorDocument() ||
        !frame->GetLastCommittedURL().SchemeIsHTTPOrHTTPS()) return false;
    auto value = base::JSONReader::Read(json, base::JSON_PARSE_RFC);
    if (!value || !value->is_list() || value->GetList().size() > 128) return false;
    std::vector<chrome::mojom::NookTranslationNodePtr> pairs;
    size_t bytes = 0;
    for (const auto& entry : value->GetList()) {
      if (!entry.is_dict()) return false;
      const auto* id = entry.GetDict().FindString("id");
      const auto* text = entry.GetDict().FindString("text");
      if (!id || !text || id->size() > 32 || text->size() > 131072) return false;
      bytes += id->size() + text->size();
      if (bytes > 512 * 1024) return false;
      pairs.push_back(chrome::mojom::NookTranslationNode::New(*id, *text));
    }
    if (operation != 2 && !pairs.empty()) return false;
    const auto previous_document = translation_document_;
    if (operation == 0) translation_document_ = frame->GetWeakDocumentPtr();
    if (!TranslationCurrent() || (operation != 0 && generation != translation_generation_)) {
      translation_document_ = previous_document;
      return false;
    }
    if (generation != translation_generation_ ||
        previous_document.AsRenderFrameHostIfValid() != frame) {
      translation_receiver_.reset();
    }
    translation_generation_ = generation;
    translation_request_ = request;
    translation_callback_ = callback;
    mojo::PendingAssociatedRemote<chrome::mojom::NookTranslationClient> client;
    // Returning to a displayed page resumes the same script/observer. Replacing
    // its endpoint would signal abandonment and restore the translated DOM.
    if (operation == 1 && !translation_receiver_.is_bound()) {
      client = translation_receiver_.BindNewEndpointAndPassRemote();
      translation_receiver_.set_disconnect_handler(base::BindOnce(
          [](std::weak_ptr<TabObservation> weak) {
            if (auto self = weak.lock()) self->translation_receiver_.reset();
          }, weak_from_this()));
    }
    auto document = translation_document_;
    const auto document_token = frame->GetDocumentToken();
    mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> remote;
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&remote);
    if (!TranslationCurrent() || translation_request_ != request ||
        translation_document_.AsRenderFrameHostIfValid() != document.AsRenderFrameHostIfValid()) return false;
    auto* proxy = remote.get();
    proxy->NookTranslate(document_token, generation, operation, std::move(pairs), std::move(client),
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(base::BindOnce(
            [](mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame>,
               std::weak_ptr<TabObservation> weak, content::WeakDocumentPtr document,
               uint64_t generation, uint64_t request, int32_t operation,
               BarcTranslationCallback callback, bool applied, const std::string& text,
               const std::string& language, std::vector<chrome::mojom::NookTranslationNodePtr> nodes) {
              auto self = weak.lock();
              if (!self || !self->active_ || discovery_stopped || !self->callback_) return;
              const bool current = self->TranslationCurrent() && generation == self->translation_generation_ &&
                  self->translation_request_ == request &&
                  self->translation_document_.AsRenderFrameHostIfValid() == document.AsRenderFrameHostIfValid();
              auto payload = current && applied ? TranslationPayload(text, language, nodes) : std::string();
              if (current && (operation == 3 || (operation == 1 && !applied))) {
                self->translation_receiver_.reset(); self->translation_callback_ = nullptr;
              }
              base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
              callback(self->context_.get(), self->token_, generation, request,
                       !current ? 1 : (!applied || payload.empty() ? 2 : 0), payload.c_str());
            }, std::move(remote), weak_from_this(), document, generation, request, operation, callback),
            false, std::string(), std::string(), std::vector<chrome::mojom::NookTranslationNodePtr>()));
    return true;
  }

  bool SetUserCSS(uint64_t request, const GURL& expected_url,
                  std::string css, BarcStyleCallback callback) {
    auto keep_alive = shared_from_this();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* frame = web_contents() ? web_contents()->GetPrimaryMainFrame() : nullptr;
    if (!active_ || closing_ || !request || request <= style_request_ || !callback ||
        !owner || owner->IsDeleteScheduled() ||
        UnloadController::From(owner)->owner_close_admitted() || !frame ||
        !frame->IsActive() || !frame->IsRenderFrameLive() || frame->IsErrorDocument() ||
        owner->GetProfile() != web_contents()->GetBrowserContext() ||
        frame->GetBrowserContext() != owner->GetProfile() ||
        Window(owner->GetSessionID().id()) != owner ||
        LookupTab(owner, tab_id()) != tab || tab->GetContents() != web_contents() ||
        !expected_url.SchemeIsHTTPOrHTTPS() ||
        expected_url != frame->GetLastCommittedURL() ||
        css.size() > 16 * 1024 * 1024 || !base::IsStringUTF8(css)) return false;
    style_request_ = request;
    auto document = frame->GetWeakDocumentPtr();
    const auto document_token = frame->GetDocumentToken();
    auto expected_owner = owner->GetWeakPtr();
    mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> remote;
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&remote);
    // Interface binding can be overridden by embedders/tests. Do not retain
    // borrowed owners or let a nested request overwrite newer CSS admission.
    if (!active_ || closing_ || style_request_ != request || !expected_owner ||
        !web_contents() || !document.AsRenderFrameHostIfValid() ||
        document.AsRenderFrameHostIfValid() != web_contents()->GetPrimaryMainFrame() ||
        !tab_.Get() || tab_.Get()->GetBrowserWindowInterface() != expected_owner.get() ||
        expected_owner->IsDeleteScheduled() ||
        UnloadController::From(expected_owner.get())->owner_close_admitted()) return false;
    auto* proxy = remote.get();
    // Retain the associated remote until reply/error, following CoreTabHelper.
    // The callback holds no CSS buffer and publication ends on unobserve.
    proxy->SetNookBoostStyle(document_token, css,
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(base::BindOnce(
            [](mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame>,
               std::weak_ptr<TabObservation> weak,
               base::WeakPtr<BrowserWindowInterface> expected_owner,
               content::WeakDocumentPtr document, uint64_t request,
               BarcStyleCallback callback, bool applied) {
              auto self = weak.lock();
              if (discovery_stopped || !self || !self->active_ || !self->callback_ ||
                  self->style_request_ != request) return;
              auto* frame = document.AsRenderFrameHostIfValid();
              auto* tab = self->tab_.Get();
              auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
              const bool current = !self->closing_ && frame && self->web_contents() &&
                  frame == self->web_contents()->GetPrimaryMainFrame() &&
                  frame->IsActive() && frame->IsRenderFrameLive() && !frame->IsErrorDocument() &&
                  expected_owner && owner == expected_owner.get() &&
                  !owner->IsDeleteScheduled() &&
                  !UnloadController::From(owner)->owner_close_admitted() &&
                  Window(owner->GetSessionID().id()) == owner &&
                  LookupTab(owner, self->tab_id()) == tab &&
                  frame->GetBrowserContext() == owner->GetProfile();
              base::AutoReset<int> callback_scope(&navigation_callback_depth,
                                                  navigation_callback_depth + 1);
              callback(self->context_.get(), self->token_, request,
                       !current ? 1 : (applied ? 0 : 2));
            }, std::move(remote), weak_from_this(), expected_owner, document,
            request, callback), false));
    return true;
  }

  bool ClearSiteData(uint64_t request, int32_t action, BarcSiteDataCallback callback) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || site_data_ || !request || !callback ||
        action < BARC_SITE_COOKIES || action > BARC_SITE_COOKIES_AND_RELOAD ||
        !web_contents())
      return false;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* frame = web_contents()->GetPrimaryMainFrame();
    const GURL url = frame ? frame->GetLastCommittedURL() : GURL();
    if (!owner || owner->IsDeleteScheduled() || !owner->IsSelectedForNativeWindow() ||
        owner->GetTabStripModel()->GetActiveTab() != tab ||
        web_contents()->GetBrowserContext() != owner->GetProfile() || !frame ||
        !url.SchemeIsHTTPOrHTTPS() || frame->GetLastCommittedOrigin().opaque() ||
        frame->GetStorageKey().nonce().has_value() ||
        frame->GetStorageKey().top_level_site().opaque() ||
        (action == BARC_SITE_COOKIES_AND_RELOAD &&
         !chrome::IsCommandEnabled(owner, IDC_RELOAD)))
      return false;
    auto pending = std::make_shared<SiteDataRequest>();
    pending->owner = owner->GetWeakPtr();
    pending->document = frame->GetWeakDocumentPtr();
    pending->navigation = navigation_;
    pending->request = request;
    pending->action = action;
    pending->host = url.host();
    pending->keys = net::CookiePartitionKeyCollection::MatchesSite(
        frame->GetStorageKey().top_level_site());
    pending->callback = callback;
    site_data_ = pending;
    if (action == BARC_SITE_CACHE) {
      auto filter = content::BrowsingDataFilterBuilder::Create(
          content::BrowsingDataFilterBuilder::Mode::kDelete,
          content::BrowsingDataFilterBuilder::OriginMatchingMode::kOriginInAllContexts);
      filter->AddOrigin(frame->GetLastCommittedOrigin());
      filter->SetStoragePartitionConfig(frame->GetStoragePartition()->GetConfig());
      auto* remover = owner->GetProfile()->GetBrowsingDataRemover();
      site_data_remover_.Observe(remover);
      remover->RemoveWithFilterAndReply(base::Time(), base::Time::Max(),
          content::BrowsingDataRemover::DATA_TYPE_CACHE,
          content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB,
          std::move(filter), this);
    } else {
      frame->GetStoragePartition()->GetCookieManagerForBrowserProcess()->GetAllCookies(
          mojo::WrapCallbackWithDropHandler(base::BindOnce(
              [](std::weak_ptr<TabObservation> weak,
                 std::shared_ptr<SiteDataRequest> pending,
                 const std::vector<net::CanonicalCookie>& cookies) {
                if (auto self = weak.lock()) self->ClearExactCookies(pending, cookies);
              }, weak_from_this(), pending), base::BindOnce(
              [](std::weak_ptr<TabObservation> weak,
                 std::shared_ptr<SiteDataRequest> pending) {
                if (auto self = weak.lock()) self->FinishSiteData(pending, false);
              }, weak_from_this(), pending)));
    }
    return true;
  }
  void OnBrowsingDataRemoverDone(uint64_t failed) override {
    if (site_data_) FinishSiteData(site_data_, failed == 0);
  }
  void Emit(int32_t event, int32_t error = 0, uint32_t extra = 0,
            const GURL* event_url = nullptr) {
    auto keep_alive = shared_from_this();
    if (!active_ || !callback_)
      return;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    const int32_t window = owner ? owner->GetSessionID().id() : 0;
    uint32_t flags = extra;
    std::string url, title;
    if (web_contents()) {
      auto& controller = web_contents()->GetController();
      if (web_contents()->IsLoading())
        flags |= BARC_TAB_LOADING;
      if (web_contents()->IsAudioMuted())
        flags |= BARC_TAB_MUTED;
      if (web_contents()->IsCurrentlyAudible())
        flags |= BARC_TAB_AUDIBLE;
      flags |= BARC_TAB_PIP_STATE_KNOWN;
      if (web_contents()->HasPictureInPictureVideo())
        flags |= BARC_TAB_VIDEO_PIP;
      if (web_contents()->HasPictureInPictureDocument())
        flags |= BARC_TAB_DOCUMENT_PIP;
      if (controller.CanGoBack())
        flags |= BARC_TAB_BACK;
      if (controller.CanGoForward())
        flags |= BARC_TAB_FORWARD;
      url = web_contents()->GetVisibleURL().spec();
      title = base::UTF16ToUTF8(web_contents()->GetTitle());
    }
    if (event_url)
      url = event_url->spec();
    base::AutoReset<int> callback_scope(&navigation_callback_depth,
                                        navigation_callback_depth + 1);
    callback_(context_.get(), token_, event, window, tab_id(), url.c_str(),
              title.c_str(), error, flags);
  }
  int SetMediaCallback(BarcMediaCallback callback) {
    if (!active_ || closing_ || !web_contents() || (media_callback_ && callback)) return 0;
    media_callback_ = callback;
    media_receiver_.reset();
    media_snapshot_.reset();
    media_document_ = {};
    media_refresh_pending_ = false;
    if (callback) {
      if (auto* main = web_contents()->GetPrimaryMainFrame()) media_document_ = main->GetWeakDocumentPtr();
      if (navigation_callback_depth) ScheduleMediaRefresh();
      if (auto* session = content::MediaSession::GetIfExists(web_contents()))
        BindMedia(session);
      else
        RefreshMedia();
    }
    return 1;
  }
  void MediaSessionCreated(content::MediaSession* session) override {
    if (!media_callback_) return;
    auto keep_alive = shared_from_this();
    BindMedia(session);
  }
  void MediaSessionInfoChanged(media_session::mojom::MediaSessionInfoPtr) override { RefreshMedia(); }
  void MediaSessionMetadataChanged(const std::optional<media_session::MediaMetadata>&) override { RefreshMedia(); }
  void MediaSessionActionsChanged(const std::vector<media_session::mojom::MediaSessionAction>&) override { RefreshMedia(); }
  void MediaSessionImagesChanged(const base::flat_map<media_session::mojom::MediaSessionImageType,
                                 std::vector<media_session::MediaImage>>&) override {}
  void MediaSessionPositionChanged(const std::optional<media_session::MediaPosition>&) override {}
  void BindMedia(content::MediaSession* session) {
    media_receiver_.reset();
    session->AddObserver(media_receiver_.BindNewPipeAndPassRemote());
    RefreshMedia();
  }
  struct MediaSnapshot {
    uint32_t flags = 0;
    int32_t window = 0;
    std::string title, artist, album;
    bool operator==(const MediaSnapshot&) const = default;
  };
  void ScheduleMediaRefresh() {
    if (!active_ || !media_callback_ || !web_contents()) return;
    auto* main = web_contents()->GetPrimaryMainFrame();
    if (!main) return;
    if (media_refresh_pending_ && media_document_.AsRenderFrameHostIfValid() == main) return;
    auto document = main->GetWeakDocumentPtr();
    media_document_ = document;
    media_refresh_pending_ = true;
    // Non-nestable: a client may enter a modal loop inside a navigation callback.
    // Read after ALL native navigation observers reset the old media service.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(
        FROM_HERE, base::BindOnce([](std::weak_ptr<TabObservation> weak,
                                    content::WeakDocumentPtr expected) {
          auto self = weak.lock();
          auto* frame = expected.AsRenderFrameHostIfValid();
          if (!self || !self->active_ || !frame || !self->web_contents() ||
              frame != self->web_contents()->GetPrimaryMainFrame() ||
              !self->media_refresh_pending_ ||
              self->media_document_.AsRenderFrameHostIfValid() != frame) return;
          self->media_refresh_pending_ = false;
          self->media_snapshot_.reset();
          self->RefreshMedia();
        }, weak_from_this(), document));
  }
  void RefreshMedia(bool document_ended = false) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || !media_callback_ || !web_contents() ||
        (media_refresh_pending_ && !document_ended)) return;
    MediaSnapshot current;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    current.window = owner ? owner->GetSessionID().id() : 0;
    auto* session = content::MediaSession::GetIfExists(web_contents());
    auto* main = web_contents()->GetPrimaryMainFrame();
    if (!main) return;
    if (document_ended) {
      media_document_ = main->GetWeakDocumentPtr();
      media_refresh_pending_ = false;
    } else if (media_document_.AsRenderFrameHostIfValid() != main) {
      ScheduleMediaRefresh();
      return;
    }
    auto document = main->GetWeakDocumentPtr();
    // Observe only this actual page/profile. Query live state rather than using
    // queued Mojo payloads from a document/route that may already have ended.
    if (owner && !owner->IsDeleteScheduled() && (document_ended || tab->GetContents() == web_contents()) &&
        owner->GetProfile() == web_contents()->GetBrowserContext()) {
      if (document_ended) {
        // A real replacement ends the old controllable player, unlike a
        // transient unavailable route/owner. Clear its paused mini-player rank.
        current.flags = BARC_MEDIA_KNOWN;
      } else if (session) {
        auto* routed = session->GetRoutedFrame();
        const auto info = session->GetMediaSessionInfoSync();
        const bool valid_route = !routed || (routed->IsActive() &&
            routed->GetOutermostMainFrame() == main);
        if (info && valid_route && (!info->is_controllable || (routed && info->audio_video_states))) {
          current.flags = BARC_MEDIA_KNOWN;
          if (info->is_controllable) current.flags |= BARC_MEDIA_CONTROLLABLE;
          if (info->playback_state == media_session::mojom::MediaPlaybackState::kPlaying)
            current.flags |= BARC_MEDIA_PLAYING;
          if (info->audio_video_states) {
            for (const auto value : *info->audio_video_states) {
              if (value == media_session::mojom::MediaAudioVideoState::kAudioVideo ||
                  value == media_session::mojom::MediaAudioVideoState::kVideoOnly)
                current.flags |= BARC_MEDIA_VIDEO;
            }
          }
          const auto actions = session->GetMediaSessionActionsSync();
          auto has = [&](media_session::mojom::MediaSessionAction action) {
            return std::ranges::find(actions, action) != actions.end();
          };
          if (info->is_controllable && has(media_session::mojom::MediaSessionAction::kPlay)) current.flags |= BARC_MEDIA_CAN_PLAY;
          if (info->is_controllable && has(media_session::mojom::MediaSessionAction::kPause)) current.flags |= BARC_MEDIA_CAN_PAUSE;
          if (info->is_controllable && has(media_session::mojom::MediaSessionAction::kPreviousTrack)) current.flags |= BARC_MEDIA_PREVIOUS;
          if (info->is_controllable && has(media_session::mojom::MediaSessionAction::kNextTrack)) current.flags |= BARC_MEDIA_NEXT;
          if (web_contents()->IsCurrentlyAudible()) current.flags |= BARC_MEDIA_AUDIBLE;
          if (routed && !info->hide_metadata) {
            const auto& metadata = session->GetMediaSessionMetadata();
            current.title = base::UTF16ToUTF8(metadata.title.substr(0, 1024));
            current.artist = base::UTF16ToUTF8(metadata.artist.substr(0, 1024));
            current.album = base::UTF16ToUTF8(metadata.album.substr(0, 1024));
          }
        }
      }
    }
    if (!document.AsRenderFrameHostIfValid() ||
        (media_snapshot_ && *media_snapshot_ == current)) return;
    media_snapshot_ = current;
    const auto callback = media_callback_;
    void* context = context_.get();
    base::AutoReset<int> scope(&navigation_callback_depth, navigation_callback_depth + 1);
    callback(context, token_, current.window, tab_id(), current.flags,
             current.title.c_str(), current.artist.c_str(), current.album.c_str());
  }
  void OnAudioStateChanged(bool) override {
    auto keep_alive = shared_from_this();
    Emit(BARC_TAB_STATE);
    RefreshMedia();
  }
  void MediaStartedPlaying(const MediaPlayerInfo&, const content::MediaPlayerId&) override {
    auto keep_alive = shared_from_this();
    auto* tab = tab_.Get();
    if (!tab || !PeekRoleFor(tab) || tab->GetContents() != web_contents()) return;
    auto* owner = tab->GetBrowserWindowInterface();
    auto* view = owner ? BrowserView::GetBrowserViewForBrowser(owner) : nullptr;
    // A retained hidden Peek is not an audible background tab. Use Chromium's
    // real session pause, including a later autoplay after a refused card.
    if (!view || !view->browser_widget()->IsBarcPeekVisible(tab))
      content::MediaSession::Get(web_contents())->Suspend(
          media_session::mojom::MediaSession::SuspendType::kUI);
  }
  void MediaPictureInPictureChanged(bool) override { Emit(BARC_TAB_STATE); }
  void DidUpdateAudioMutingState(bool) override { Emit(BARC_TAB_STATE); }
  void RenderFrameDeleted(content::RenderFrameHost* frame) override {
    if (vault_passkey_ && (!vault_passkey_->document.AsRenderFrameHostIfValid() ||
        vault_passkey_->document.AsRenderFrameHostIfValid() == frame)) CancelVaultPasskey();
    if (vault_focus_ && (!vault_focus_->document.AsRenderFrameHostIfValid() ||
        vault_focus_->document.AsRenderFrameHostIfValid() == frame)) ClearVaultFocus();
  }
  void DidStartNavigation(content::NavigationHandle* handle) override {
    auto keep_alive = shared_from_this();
    if (vault_passkey_ && !handle->IsSameDocument() &&
        (handle->IsInPrimaryMainFrame() || !vault_passkey_->document.AsRenderFrameHostIfValid() ||
         vault_passkey_->document.AsRenderFrameHostIfValid()->GetFrameTreeNodeId() == handle->GetFrameTreeNodeId()))
      CancelVaultPasskey();
    if (vault_focus_ && (handle->IsInPrimaryMainFrame() ||
        (vault_focus_->document.AsRenderFrameHostIfValid() &&
         vault_focus_->document.AsRenderFrameHostIfValid()->GetFrameTreeNodeId() == handle->GetFrameTreeNodeId()))) ClearVaultFocus();
    if (handle->IsInPrimaryMainFrame() && thumbnail_)
      thumbnail_->cancelled.Set();
    if (handle->IsInPrimaryMainFrame() && site_data_) site_data_->cancelled = true;
    if (!handle->IsInPrimaryMainFrame() || handle->IsSameDocument())
      return;
    CancelPicker();
    CancelScript();
    CancelFiles();
    if (!active_) return;
    peek_request_.reset();
    peek_current_serial_ = 0;
    navigation_ = handle->GetNavigationId();
    blocked_url_.reset();
    committed_ = false;
    navigation_flags_ = handle->GetReloadType() != content::ReloadType::NONE
                            ? BARC_TAB_RELOAD
                            : 0;
    Emit(BARC_TAB_STARTED, 0, navigation_flags_, &handle->GetURL());
  }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    auto keep_alive = shared_from_this();
    if (!handle->IsInPrimaryMainFrame())
      return;
    if (handle->IsSameDocument()) {
      if (handle->HasCommitted() && handle->GetNetErrorCode() == net::OK)
        Emit(BARC_TAB_COMMITTED, 0, BARC_TAB_SAME_DOCUMENT, &handle->GetURL());
      return;
    }
    if (handle->HasCommitted()) {
      CancelPicker();
      CancelFiles();
      translation_receiver_.reset();
      translation_callback_ = nullptr;
      translation_document_ = {};
      ScheduleMediaRefresh();
    }
    // A subscription cannot reconstruct starts or failures from before binding.
    // A real new primary commit is observable; otherwise report current state.
    if (!navigation_) {
      if (handle->HasCommitted() && handle->GetNetErrorCode() == net::OK)
        Emit(BARC_TAB_COMMITTED, 0, 0, &handle->GetURL());
      else
        Emit(BARC_TAB_STATE);
      RefreshMedia();
      return;
    }
    if (handle->GetNavigationId() != navigation_)
      return;
    if (handle->GetNetErrorCode() != net::OK) {
      committed_ = false;
      // Replacement can cancel the old request before the new DidStart arrives.
      // The public discard reason identifies that ordering without URL guesses.
      if (auto reason = handle->GetNavigationDiscardReason(); reason) {
        switch (*reason) {
          case content::NavigationDiscardReason::kNewReloadNavigation:
          case content::NavigationDiscardReason::kNewHistoryNavigation:
          case content::NavigationDiscardReason::kNewOtherNavigationBrowserInitiated:
          case content::NavigationDiscardReason::kNewOtherNavigationRendererInitiated:
          case content::NavigationDiscardReason::kNewDuplicateNavigation:
          case content::NavigationDiscardReason::kCommittedNavigation:
            Emit(BARC_TAB_STATE);
            return;
          default:
            break;
        }
      }
      const GURL displayed = web_contents()->GetLastCommittedURL();
      const int64_t failed_navigation = handle->GetNavigationId();
      const GURL failed_url = handle->GetURL();
      const bool native_blocked = handle->GetNetErrorCode() == net::ERR_BLOCKED_BY_CLIENT &&
          blocked_url_ == failed_url;
      Emit(BARC_TAB_FAILED, handle->GetNetErrorCode(), navigation_flags_ |
          (!handle->HasCommitted() ? BARC_TAB_PROVISIONAL : 0) |
          (handle->GetNetErrorCode() == net::ERR_ABORTED ? BARC_TAB_ABORTED : 0),
          &displayed);
      if (native_blocked && NativeBlockCurrent(failed_navigation, failed_url)) {
        Emit(BARC_TAB_NATIVE_BLOCKED, 0, 0, &failed_url);
        // Run after every DidFinishNavigation observer, including InfoBar
        // expiry. A newer navigation/owner invalidates this one weak task.
        base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(
            FROM_HERE, base::BindOnce([](std::weak_ptr<TabObservation> weak,
                                        int64_t navigation, GURL url) {
              if (auto self = weak.lock()) self->ShowNativeBlock(navigation, url);
            }, weak_from_this(), failed_navigation, failed_url));
      }
      RefreshMedia();
      return;
    }
    if (!handle->HasCommitted())
      return;
    committed_ = true;
    const GURL url = handle->GetURL();
    Emit(BARC_TAB_COMMITTED, 0, navigation_flags_, &url);
    // No borrowed NavigationHandle is touched after a media client callout.
    RefreshMedia();
  }
  void NavigationListPruned(const content::PrunedDetails&) override {
    Emit(BARC_TAB_STATE);
  }
  void NavigationEntriesDeleted() override { Emit(BARC_TAB_STATE); }
  void DidStartLoading() override { Emit(BARC_TAB_STATE); }
  void DidStopLoading() override {
    auto keep_alive = shared_from_this();
    if (committed_) {
      committed_ = false;
      Emit(BARC_TAB_FINISHED, 0, navigation_flags_);
    } else {
      Emit(BARC_TAB_STATE);
    }
  }
  void TitleWasSet(content::NavigationEntry*) override { Emit(BARC_TAB_TITLE); }
  void WebContentsDestroyed() override { Close(); }
  void BeforeUnloadFired(bool proceed) override {
    if (proceed)
      return;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* controller = owner ? UnloadController::From(owner) : nullptr;
    // WebContents notifies before its delegate resets the window-close state.
    // Window/group refusal comes from the terminal window notification instead.
    if (!controller || !controller->is_attempting_to_close_browser())
      Emit(BARC_TAB_CLOSE_CANCELLED);
  }
  void OnTabCloseCancelled(const tabs::TabInterface* tab) override {
    if (tab->GetHandle() == tab_)
      Emit(BARC_TAB_CLOSE_CANCELLED);
  }
  void OnTabStripModelDestroyed(TabStripModel* strip) override {
    if (strip_ == strip) {
      strip_ = nullptr;
      window_cancelled_ = {};
    }
  }
 private:
  BarcVaultCallback vault_callback_ = nullptr;
  uint64_t vault_serial_ = 0;
  bool vault_notification_posted_ = false;
  base::CallbackListSubscription vault_selection_, vault_active_, vault_inactive_, vault_tab_;
  std::optional<VaultFocus> vault_focus_;
  autofill::ScopedAutofillManagersObservation vault_managers_{this};
  struct ThumbnailCapture {
    ThumbnailCapture();
    ~ThumbnailCapture();
    base::WeakPtr<BrowserWindowInterface> owner;
    content::WeakDocumentPtr document;
    int64_t navigation = 0;
    uint64_t request = 0;
    BarcTabThumbnailCallback callback = nullptr;
    bool screenshot = false;
    gfx::Size output;
    base::AtomicFlag cancelled;
  };
  bool ThumbnailIsCurrent(const std::shared_ptr<ThumbnailCapture>& capture) {
    if (!active_ || closing_ || thumbnail_ != capture ||
        capture->cancelled.IsSet() || capture->navigation != navigation_ ||
        !capture->owner || capture->owner->IsDeleteScheduled() || !web_contents() ||
        discovery_stopped || UnloadController::From(capture->owner.get())->owner_close_admitted() ||
        UnloadController::From(capture->owner.get())->is_attempting_to_close_browser() ||
        !ScreenshotAllowed())
      return false;
    auto* document = capture->document.AsRenderFrameHostIfValid();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    return document && document == web_contents()->GetPrimaryMainFrame() &&
        owner == capture->owner.get() &&
        Window(owner->GetSessionID().id()) == owner &&
        LookupTab(owner, tab_id()) == tab && tab->GetContents() == web_contents() &&
        document->GetBrowserContext() == owner->GetProfile();
  }
  void FinishThumbnail(std::shared_ptr<ThumbnailCapture> capture,
                       std::vector<uint8_t> bytes = {}) {
    if (thumbnail_ != capture)
      return;
    auto keep_alive = shared_from_this();
    const bool current = ThumbnailIsCurrent(capture);
    thumbnail_.reset();
    if (!active_ || !capture->callback)
      return;
    base::AutoReset<int> callback_scope(&navigation_callback_depth,
                                        navigation_callback_depth + 1);
    capture->callback(context_.get(), token_, capture->request,
                      current && !bytes.empty() ? bytes.data() : nullptr,
                      current ? bytes.size() : 0);
  }
  void ThumbnailCopied(std::shared_ptr<ThumbnailCapture> capture,
                       const content::CopyFromSurfaceResult& result) {
    if (!ThumbnailIsCurrent(capture) || !result.has_value() ||
        result->bitmap.drawsNothing() || result->bitmap.width() > capture->output.width() ||
        result->bitmap.height() > capture->output.height()) {
      FinishThumbnail(std::move(capture));
      return;
    }
    SkBitmap bitmap = result->bitmap;
    bitmap.setImmutable();
    base::ThreadPool::PostTaskAndReplyWithResult(FROM_HERE,
        {base::TaskPriority::BEST_EFFORT},
        base::BindOnce([](std::shared_ptr<ThumbnailCapture> capture, SkBitmap bitmap) {
          if (capture->cancelled.IsSet())
            return std::vector<uint8_t>();
          auto encoded = capture->screenshot ? gfx::JPEGCodec::Encode(bitmap, 70)
              : gfx::PNGCodec::EncodeBGRASkBitmap(bitmap, false);
          const size_t limit = capture->screenshot ? 8 * 1024 * 1024 : 1024 * 1024;
          if (capture->cancelled.IsSet() || !encoded || encoded->size() > limit)
            return std::vector<uint8_t>();
          return std::move(*encoded);
        }, capture, std::move(bitmap)),
        base::BindOnce([](std::weak_ptr<TabObservation> weak,
                          std::shared_ptr<ThumbnailCapture> capture,
                          std::vector<uint8_t> bytes) {
          if (auto self = weak.lock())
            self->FinishThumbnail(std::move(capture), std::move(bytes));
        }, weak_from_this(), capture));
  }
  std::shared_ptr<ThumbnailCapture> thumbnail_;

  struct SiteDataRequest {
    SiteDataRequest();
    ~SiteDataRequest();
    base::WeakPtr<BrowserWindowInterface> owner;
    content::WeakDocumentPtr document;
    int64_t navigation = 0;
    uint64_t request = 0;
    int32_t action = BARC_SITE_COOKIES;
    std::string host;
    net::CookiePartitionKeyCollection keys;
    BarcSiteDataCallback callback = nullptr;
    bool cancelled = false;
  };
  bool SiteDataIsCurrent(const std::shared_ptr<SiteDataRequest>& pending) {
    if (!active_ || closing_ || site_data_ != pending || pending->cancelled ||
        pending->navigation != navigation_ || !pending->owner ||
        pending->owner->IsDeleteScheduled() || !web_contents()) return false;
    auto* frame = pending->document.AsRenderFrameHostIfValid();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    return frame && frame == web_contents()->GetPrimaryMainFrame() &&
        owner == pending->owner.get() && owner->IsSelectedForNativeWindow() &&
        Window(owner->GetSessionID().id()) == owner && LookupTab(owner, tab_id()) == tab &&
        owner->GetTabStripModel()->GetActiveTab() == tab &&
        tab->GetContents() == web_contents() &&
        frame->GetBrowserContext() == owner->GetProfile();
  }
  void ClearExactCookies(std::shared_ptr<SiteDataRequest> pending,
                         const std::vector<net::CanonicalCookie>& cookies) {
    if (!SiteDataIsCurrent(pending)) { FinishSiteData(pending, true); return; }
    // host_name filters only host cookies; including_domains expands to eTLD+1.
    // Neither preserves the product's exact host/.host scope. Delete selected
    // canonical cookies instead, explicitly retaining unrelated CHIPS keys.
    std::vector<net::CanonicalCookie> matching;
    for (const auto& cookie : cookies) {
      if ((cookie.Domain() == pending->host || cookie.Domain() == "." + pending->host) &&
          (!cookie.IsPartitioned() || pending->keys.Contains(*cookie.PartitionKey())))
        matching.push_back(cookie);
    }
    if (matching.empty()) { FinishSiteData(pending, true); return; }
    auto done = base::BarrierCallback<bool>(matching.size(), base::BindOnce(
        [](std::weak_ptr<TabObservation> weak, std::shared_ptr<SiteDataRequest> pending,
           const std::vector<bool>& results) {
          if (auto self = weak.lock()) self->FinishSiteData(pending,
              std::ranges::all_of(results, [](bool result) { return result; }));
        }, weak_from_this(), pending));
    auto* manager = pending->document.AsRenderFrameHostIfValid()
                        ->GetStoragePartition()->GetCookieManagerForBrowserProcess();
    for (const auto& cookie : matching) {
      manager->DeleteCanonicalCookie(cookie,
          mojo::WrapCallbackWithDefaultInvokeIfNotRun(base::BindOnce(done), false));
    }
  }
  void FinishSiteData(std::shared_ptr<SiteDataRequest> pending, bool success) {
    if (site_data_ != pending) return;
    auto keep_alive = shared_from_this();
    int32_t result = !SiteDataIsCurrent(pending) ? BARC_SITE_CANCELLED :
        (success ? BARC_SITE_COMPLETED : BARC_SITE_FAILED);
    site_data_remover_.Reset();
    site_data_.reset();
    if (result == BARC_SITE_COMPLETED && pending->action == BARC_SITE_COOKIES_AND_RELOAD) {
      auto* owner = pending->owner.get();
      result = chrome::IsCommandEnabled(owner, IDC_RELOAD) && chrome::ExecuteCommand(owner, IDC_RELOAD)
          ? BARC_SITE_COMPLETED : BARC_SITE_FAILED;
    }
    if (!active_ || !pending->callback) return;
    base::AutoReset<int> callback_scope(&navigation_callback_depth, navigation_callback_depth + 1);
    pending->callback(context_.get(), token_, pending->request, result);
  }
  std::shared_ptr<SiteDataRequest> site_data_;
  uint64_t style_request_ = 0;
  content::WeakDocumentPtr translation_document_;
  uint64_t translation_generation_ = 0;
  uint64_t translation_request_ = 0;
  BarcTranslationCallback translation_callback_ = nullptr;
  mojo::AssociatedReceiver<chrome::mojom::NookTranslationClient> translation_receiver_{this};
  base::ScopedObservation<content::BrowsingDataRemover,
                           content::BrowsingDataRemover::Observer> site_data_remover_{this};

  void UnbindOwner() {
    ClearVaultFocus();
    CancelVaultPasskey();
    ClearVaultSave();
    vault_selection_ = {}; vault_active_ = {}; vault_inactive_ = {}; vault_tab_ = {};
    window_cancelled_ = {};
    if (strip_)
      strip_->RemoveObserver(this);
    strip_ = nullptr;
  }
  void BindOwner() {
    UnbindOwner();
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (!owner)
      return;
    strip_ = owner->GetTabStripModel();
    strip_->AddObserver(this);
    if (vault_callback_ || vault_passkey_callback_) ObserveVaultOwner();
    window_cancelled_ = owner->RegisterBrowserCloseCancelled(base::BindRepeating(
        &TabObservation::WindowCloseCancelled, base::Unretained(this)));
  }
  void WindowCloseCancelled(BrowserWindowInterface* owner,
                            BrowserWindowInterface::ClosingStatus status) {
    if (status != BrowserWindowInterface::ClosingStatus::kDeniedByUser &&
        status != BrowserWindowInterface::ClosingStatus::kDeniedByPolicy)
      return;
    auto* tab = tab_.Get();
    auto* controller = UnloadController::From(owner);
    if (!tab || tab->GetBrowserWindowInterface() != owner || !controller ||
        controller->IsWaitingForDownloadCloseConfirmation())
      return;
    Emit(BARC_TAB_CLOSE_CANCELLED);
  }
  void Detach(tabs::TabInterface*, tabs::TabInterface::DetachReason reason) {
    auto keep_alive = shared_from_this();
    CancelPicker();
    CancelScript();
    CancelFiles();
    if (!active_) return;
    peek_request_.reset();
    peek_current_serial_ = 0;
    if (thumbnail_)
      thumbnail_->cancelled.Set();
    if (site_data_) site_data_->cancelled = true;
    if (reason == tabs::TabInterface::DetachReason::kDelete)
      Close();
    else
      UnbindOwner();
  }
  void Inserted(tabs::TabInterface*) {
    auto keep_alive = shared_from_this();
    BindOwner();
    Emit(BARC_TAB_STATE);
    RefreshMedia();
  }
  void Discard(tabs::TabInterface*, content::WebContents*,
               content::WebContents* replacement) {
    auto keep_alive = shared_from_this();
    CancelPicker();
    CancelScript();
    CancelFiles();
    if (!active_) return;
    if (thumbnail_)
      thumbnail_->cancelled.Set();
    if (site_data_) site_data_->cancelled = true;
    navigation_ = 0;
    blocked_url_.reset();
    navigation_flags_ = 0;
    committed_ = false;
    translation_receiver_.reset();
    translation_callback_ = nullptr;
    translation_document_ = {};
    media_receiver_.reset();
    media_snapshot_.reset();
    media_document_ = {};
    media_refresh_pending_ = false;
    Observe(replacement);
    if (media_callback_) RefreshMedia(true);
    Emit(BARC_TAB_STATE);
    if (media_callback_) {
      if (!active_ || !media_callback_) return;
      if (auto* session = content::MediaSession::GetIfExists(replacement)) BindMedia(session);
      else RefreshMedia();
    }
  }
  void Close() {
    auto keep_alive = shared_from_this();
    if (!active_)
      return;
    // Keep duplicate admission blocked through the terminal callout, including
    // when it unsubscribes before attempting to bind the closing tab again.
    closing_ = true;
    CancelPicker();
    CancelScript();
    CancelFiles();
    if (!active_) return;
    auto callback = callback_;
    void* context = context_.get();
    callback_ = nullptr;
    context_ = nullptr;
    active_ = false;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    if (callback) {
      base::AutoReset<int> callback_scope(&navigation_callback_depth,
                                          navigation_callback_depth + 1);
      callback(context, token_, BARC_TAB_CLOSED,
               owner ? owner->GetSessionID().id() : 0, tab_id(), "", "", 0,
               owner && UnloadController::From(owner)->owner_close_admitted()
                   ? BARC_TAB_OWNER_ENDED : 0);
    }
    ObservationTable().erase(token_);
    Cancel();
  }
  BarcMediaCallback media_callback_ = nullptr;
  mojo::Receiver<media_session::mojom::MediaSessionObserver> media_receiver_{this};
  std::optional<MediaSnapshot> media_snapshot_;
  content::WeakDocumentPtr media_document_;
  bool media_refresh_pending_ = false;
  bool peek_enabled_ = false;
  int32_t peek_serial_ = 0;
  int32_t peek_current_serial_ = 0;
  std::optional<PeekRequest> peek_request_;
  const uint64_t token_;
  const tabs::TabHandle tab_;
  BarcTabCallback callback_;
  raw_ptr<void> context_;
  bool active_ = true;
  bool closing_ = false;
  int64_t navigation_ = 0;
  std::optional<GURL> blocked_url_;
  bool committed_ = false;
  uint32_t navigation_flags_ = 0;
  raw_ptr<TabStripModel> strip_ = nullptr;
  base::CallbackListSubscription window_cancelled_;
  base::CallbackListSubscription detach_, insert_, discard_, picker_deactivate_;
};
TabObservation::ThumbnailCapture::ThumbnailCapture() = default;
TabObservation::ThumbnailCapture::~ThumbnailCapture() = default;
TabObservation::SiteDataRequest::SiteDataRequest() = default;
TabObservation::SiteDataRequest::~SiteDataRequest() = default;
}  // namespace

int barc_tab_start_boost_picker(uint64_t observation, uint64_t request,
    BarcPickerCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(observation);
  return found != ObservationTable().end() && found->second->StartPicker(request, callback);
}
int barc_tab_cancel_boost_picker(uint64_t observation, uint64_t request) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) || !request) return 0;
  auto found = ObservationTable().find(observation);
  if (found == ObservationTable().end()) return 0;
  found->second->CancelPicker(request);
  return 1;
}

int barc_tab_evaluate_script(uint64_t observation, uint64_t request,
    int32_t mode, int32_t world, const char* source, BarcScriptCallback callback) {
  // The C contract requires readable NUL-terminated UTF-8. Bound allocation
  // before copying that caller-owned input; no body or script inspection.
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) || !source ||
      UNSAFE_BUFFERS(strnlen(source, 128 * 1024 + 1)) > 128 * 1024 ||
      !base::IsStringUTF8(source))
    return 0;
  auto found = ObservationTable().find(observation);
  return found != ObservationTable().end() &&
      found->second->EvaluateScript(request, mode, world, source, callback);
}
int barc_tab_cancel_script(uint64_t observation, uint64_t request) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) || !request)
    return 0;
  auto found = ObservationTable().find(observation);
  if (found == ObservationTable().end()) return 0;
  found->second->CancelScript(request);
  return 1;
}

int barc_tab_enable_peek(uint64_t observation, int enabled) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      (enabled != 0 && enabled != 1)) return 0;
  auto found = ObservationTable().find(observation);
  return found != ObservationTable().end() && found->second->EnablePeek(enabled != 0);
}

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
  return !discovery_stopped && row && DiscoveryWindowRow(Window(window), row);
}
int32_t barc_discovery_snapshot(BarcDiscoveryWindow* windows, size_t window_capacity,
                                BarcDiscoveryTab* tabs, size_t tab_capacity,
                                BarcDiscoverySnapshot* snapshot) {
  if (!snapshot || (!windows && window_capacity) || (!tabs && tab_capacity))
    return BARC_DISCOVERY_READ_INVALID_ARGUMENT;
  *snapshot = {};
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
  base::span<BarcDiscoveryWindow> window_rows;
  base::span<BarcDiscoveryTab> tab_rows;
  // SAFETY: C callers supply writable arrays of the declared capacities; after
  // this boundary conversion every write is checked against the counted rows.
  if (windows) window_rows = UNSAFE_BUFFERS(base::span(windows, window_capacity));
  if (tabs) tab_rows = UNSAFE_BUFFERS(base::span(tabs, tab_capacity));
  size_t window_index = 0, tab_index = 0;
  collection->ForEach([&](BrowserWindowInterface* browser) {
    BarcDiscoveryWindow row;
    if (!DiscoveryWindowRow(browser, &row))
      return true;
    window_rows[window_index++] = row;
    auto* strip = browser->GetTabStripModel();
    for (int index = 0; index < strip->count(); ++index) {
      auto* tab = strip->GetTabAtIndex(index);
      tab_rows[tab_index++] = {row.window, tab->GetHandle().raw_value(),
          DiscoveryOpener(tab), index,
          PeekRoleFor(tab) && PeekRoleFor(tab)->source ? PeekRoleFor(tab)->source->GetHandle().raw_value() : 0,
          (row.active_tab == tab->GetHandle().raw_value()
               ? static_cast<uint32_t>(BARC_DISCOVERY_ACTIVE_TAB) : 0u) |
          (static_cast<tabs::TabModel*>(strip->GetTabAtIndex(index))->barc_app_factory_origin()
               ? static_cast<uint32_t>(BARC_DISCOVERY_TAB_APP_FACTORY) : 0u) |
          (PeekRoleFor(tab) ? static_cast<uint32_t>(BARC_DISCOVERY_TAB_PEEK) : 0u)};
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

uint64_t barc_tab_observe(int32_t window, int32_t tab_id,
                          BarcTabCallback callback, void* context) {
  auto* tab = LookupTab(Window(window), tab_id);
  if (!tab || !callback)
    return 0;
  for (const auto& entry : ObservationTable())
    if (entry.second->tab_id() == tab_id)
      return 0;
  static uint64_t next_token = 0;
  CHECK_NE(next_token, UINT64_MAX);
  const uint64_t token = ++next_token;
  auto observer = std::make_shared<TabObservation>(token, tab, callback, context);
  ObservationTable().emplace(token, observer);
  observer->Emit(BARC_TAB_INITIAL);
  return observer->active() ? token : 0;
}
void barc_tab_unobserve(uint64_t token) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI))
    return;
  auto found = ObservationTable().find(token);
  if (found == ObservationTable().end())
    return;
  auto observer = found->second;
  if (!observer->closing())
    ObservationTable().erase(found);
  observer->Cancel();
}
int barc_tab_capture_thumbnail(uint64_t token, uint64_t request,
                               BarcTabThumbnailCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI))
    return 0;
  const auto found = ObservationTable().find(token);
  return found != ObservationTable().end() &&
         found->second->CaptureThumbnail(request, callback);
}

int barc_tab_capture_screenshot(uint64_t token, uint64_t request, int32_t max_width,
                                 BarcTabThumbnailCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) || max_width < 1 || max_width > 4096)
    return 0;
  const auto found = ObservationTable().find(token);
  return found != ObservationTable().end() &&
         found->second->CaptureThumbnail(request, callback, max_width);
}
int barc_tab_cancel_capture(uint64_t token, uint64_t request) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  const auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->CancelCapture(request);
}

int barc_tab_download_file(uint64_t token,uint64_t request,const char* url,const char* directory,BarcFileCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) || !url || !directory) return 0;
  auto found=ObservationTable().find(token);
  return found!=ObservationTable().end() && found->second->DownloadFile(request,GURL(url),base::FilePath::FromUTF8Unsafe(directory),callback);
}
int barc_tab_cancel_file(uint64_t token,uint64_t request) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found=ObservationTable().find(token);
  return found!=ObservationTable().end() && found->second->CancelFile(request);
}

namespace {
NativeContentBlocker* BlockerForWindow(int32_t id, bool create = true) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || !barc::IsNativeApplicationRegistered() ||
      !NativeContentBlocker::IsRegistered()) return nullptr;
  auto* window = Window(id);
  if (!window || UnloadController::From(window)->owner_close_admitted())
    return nullptr;
  // Actual context, including independent OTR. Never resolve its original.
  return NativeContentBlocker::Get(window->GetProfile(), create);
}
std::optional<std::string> BlockerDomain(const char* input) {
  if (!input || !*input) return std::string();
  const GURL url(std::string("https://") + input);
  if (!url.is_valid() || url.host().empty() || url.has_username() ||
      url.has_password() || url.has_port() || url.has_query() || url.has_ref() ||
      url.path() != "/") return std::nullopt;
  return std::string(url.host());
}
}  // namespace

namespace {
NativeContentBlocker::Completion BlockerCompletion(
    BarcBlockerCallback callback, void* context,
    base::WeakPtr<BrowserWindowInterface> owner = {}, uint64_t context_id = 0) {
  struct Reply {
    BarcBlockerCallback callback;
    raw_ptr<void> context;
  };
  auto reply = std::make_unique<Reply>(Reply{callback, context});
  return base::BindOnce([](std::unique_ptr<Reply> reply,
                          base::WeakPtr<BrowserWindowInterface> owner,
                          uint64_t context_id, NativeContentBlocker::Result result) {
    if (context_id) {
      auto* service = owner && !owner->IsDeleteScheduled()
          ? BlockerForWindow(owner->GetSessionID().id(), false) : nullptr;
      if (!service || service->state().context_id != context_id)
        result.status = NativeContentBlocker::Result::kOwnerEnded;
    }
    auto callback = reply->callback;
    void* context = reply->context.get();
    reply->context = nullptr;
    reply.reset();
    {
      base::AutoReset<int> scope(&navigation_callback_depth,
                                 navigation_callback_depth + 1);
      callback(context, result.revision, static_cast<int32_t>(result.status));
    }
    barc::NotifyApplicationBrowserAvailable();
  }, std::move(reply), std::move(owner), context_id);
}
}  // namespace

int barc_blocker_state(int32_t window, BarcBlockerState* output) {
  if (!output) return 0;
  *output = {};
  auto* service = BlockerForWindow(window, false);
  if (!service) return 0;
  const auto state = service->state();
  *output = {state.context_id, state.publication_revision, state.installed_revision,
             state.source_generation, state.required_source_generation,
             state.pending_revision, state.ready, state.requested_policy};
  return 1;
}
int barc_blocker_set_policy(int32_t policy, uint64_t required_source_generation,
                            const char* const* domains, size_t count) {
  // This one registration call is passive before ChromeMain. Do not construct
  // stores, a keyed factory or workers to publish initially unresolved intent.
  if (![NSThread isMainThread] || discovery_stopped ||
      !barc::IsNativeApplicationRegistered() ||
      policy < BARC_BLOCKER_UNRESOLVED || policy > BARC_BLOCKER_ENABLED ||
      (!NativeContentBlocker::IsRegistered() && policy != BARC_BLOCKER_UNRESOLVED) ||
      (!domains && count) ||
      (policy == BARC_BLOCKER_UNRESOLVED && (count || required_source_generation)) ||
      (policy != BARC_BLOCKER_UNRESOLVED &&
       !content::BrowserThread::CurrentlyOn(content::BrowserThread::UI))) return 0;
  std::vector<std::string> parsed;
  for (const auto* domain : UNSAFE_BUFFERS(base::span(domains, count))) {
    auto host = BlockerDomain(domain);
    if (!host || host->empty()) return 0;
    parsed.push_back(std::move(*host));
  }
  return NativeContentBlocker::SetPolicy(
      static_cast<NativeContentBlocker::Policy>(policy), required_source_generation,
      std::move(parsed));
}
int barc_blocker_publish_rules(const uint8_t* bytes, size_t length,
    uint64_t source_generation, BarcBlockerCallback callback, void* context) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || !barc::IsNativeApplicationRegistered() ||
      !NativeContentBlocker::IsRegistered() || !callback || !source_generation ||
      ((bytes == nullptr) != (length == 0))) return 0;
  scoped_refptr<const base::RefCountedMemory> input;
  if (bytes) input = base::MakeRefCounted<base::RefCountedStaticMemory>(
      UNSAFE_BUFFERS(base::span(bytes, length)));
  NativeContentBlocker::PublishRules(std::move(input), source_generation,
                                     BlockerCompletion(callback, context));
  return 1;
}
int barc_blocker_prepare(int32_t window, BarcBlockerCallback callback, void* context) {
  if (!callback) return 0;
  auto* original = Window(window);
  auto owner = original ? original->GetWeakPtr()
                       : base::WeakPtr<BrowserWindowInterface>();
  auto* service = BlockerForWindow(window);
  if (!service || !owner || Window(window) != owner.get()) return 0;
  const uint64_t context_id = service->state().context_id;
  service->Prepare(BlockerCompletion(callback, context, std::move(owner), context_id));
  return 1;
}
int barc_blocker_set_tab_policy(int32_t window, int32_t tab_id, int oauth,
                                const char* continued_host,
                                uint64_t disabled_for_ms) {
  auto* owner = Window(window);
  auto* tab = owner ? LookupTab(owner, tab_id) : nullptr;
  auto domain = BlockerDomain(continued_host);
  if (!tab || !domain || (oauth != 0 && oauth != 1) ||
      disabled_for_ms > static_cast<uint64_t>(INT64_MAX)) return 0;
  auto* service = BlockerForWindow(window);
  if (!service) return 0;
  const bool published = service->SetTabPolicy(*tab, oauth != 0, std::move(*domain),
                                               base::Milliseconds(disabled_for_ms));
  // An exact asynchronous policy gate may settle after header admission or a
  // cached/disabled install. Wake the existing captured-intent drain once its
  // caller returns; this is not a resource request or readiness polling path.
  if (published) barc::NotifyApplicationBrowserAvailable();
  return published;
}

int barc_tab_observe_vault_passkeys(uint64_t token, BarcVaultPasskeyCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token); if (found == ObservationTable().end()) return 0;
  auto retained = found->second; retained->ObserveVaultPasskeys(callback); return 1;
}
int barc_tab_vault_passkey_is_current(uint64_t token,uint64_t request) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->VaultPasskeyCurrent(request);
}
int barc_tab_complete_vault_passkey(uint64_t token,uint64_t request,int32_t accepted,const char* result) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token); if (found == ObservationTable().end()) return 0;
  std::optional<std::string> copied;
  if (accepted) {
    if (!result) return 0;
    // Trusted C caller promises a readable NUL-terminated result. No secrets in logs.
    const size_t length = UNSAFE_BUFFERS(strnlen(result,262145));
    if (length > 262144) return 0;
    copied.emplace(result,length);
    if (!base::IsStringUTF8(*copied)) return 0;
  }
  auto retained = found->second;
  return retained->CompleteVaultPasskey(request,accepted != 0,std::move(copied));
}
int barc_tab_observe_vault_save(uint64_t token, BarcVaultSaveCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  if (found == ObservationTable().end()) return 0;
  auto retained = found->second;
  retained->ObserveVaultSave(callback);
  return 1;
}
int barc_tab_vault_save_is_current(uint64_t token, uint64_t submission) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->VaultSaveCurrent(submission);
}
int barc_tab_cancel_vault_save(uint64_t token, uint64_t submission) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  if (found == ObservationTable().end() || !found->second->vault_submission_ ||
      found->second->vault_submission_->token != submission) return 0;
  auto retained = found->second;
  retained->ClearVaultSave();
  return 1;
}
int barc_tab_observe_vault(uint64_t token, BarcVaultCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  if (found == ObservationTable().end() || !found->second->active()) return 0;
  auto retained = found->second;
  retained->ObserveVault(callback);
  return 1;
}
int barc_tab_vault_focus_is_current(uint64_t token, uint64_t focus) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->VaultCurrent(focus);
}
int barc_tab_vault_field_is_current(uint64_t token, uint64_t focus) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->VaultCurrent(focus, false);
}
int barc_tab_cancel_vault_focus(uint64_t token, uint64_t focus) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  if (found == ObservationTable().end()) return 0;
  auto retained = found->second;
  return retained->CancelVaultFocus(focus);
}
int barc_tab_fill_vault(uint64_t token, uint64_t focus, const char* username, const char* secret) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return 0;
  auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->FillVault(focus, username, secret);
}

int barc_tab_translate(uint64_t observation, uint64_t generation,
    uint64_t request, int32_t operation, const char* pairs, BarcTranslationCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || !pairs || !callback) return 0;
  auto found = ObservationTable().find(observation);
  return found != ObservationTable().end() &&
      found->second->Translate(generation, request, operation, pairs, callback);
}

int barc_tab_set_user_css(uint64_t token, uint64_t request,
                          const char* committed_url, const char* css,
                          BarcStyleCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || !committed_url || !css) return 0;
  const auto found = ObservationTable().find(token);
  return found != ObservationTable().end() &&
      found->second->SetUserCSS(request, GURL(committed_url), css, callback);
}

int barc_tab_clear_site_data(uint64_t token, uint64_t request, int32_t action,
                             BarcSiteDataCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || navigation_callback_depth)
    return 0;
  const auto found = ObservationTable().find(token);
  return found != ObservationTable().end() && found->second->ClearSiteData(request, action, callback);
}
uint64_t barc_downloads_observe(BarcDownloadCallback callback, void* context) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      !callback || DownloadOwner() || discovery_stopped ||
      !GlobalBrowserCollection::GetInstance()) return 0;
  static uint64_t next_token = 0;
  CHECK_NE(next_token, UINT64_MAX);
  auto observer = std::make_shared<NativeDownloads>(++next_token, callback, context);
  DownloadOwner() = observer;
  observer->Start();
  return observer->token();
}
void barc_downloads_unobserve(uint64_t token) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      !DownloadOwner() || DownloadOwner()->token() != token) return;
  auto observer = std::move(DownloadOwner());
  observer->Cancel();
}
int barc_download_action(uint64_t token, uint64_t manager, const char* guid, int32_t action) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      !DownloadOwner() || DownloadOwner()->token() != token || !guid ||
      (action != BARC_DOWNLOAD_CANCEL && action != BARC_DOWNLOAD_REMOVE)) return 0;
  auto observer = DownloadOwner();
  if (!observer->CanAction(manager, guid, action)) return 0;
  if (navigation_callback_depth) {
    content::GetUIThreadTaskRunner({})->PostNonNestableTask(FROM_HERE,
        base::BindOnce([](std::weak_ptr<NativeDownloads> weak, uint64_t manager,
                          std::string guid, int32_t action) {
          if (auto live = weak.lock()) live->Action(manager, guid, action);
        }, std::weak_ptr<NativeDownloads>(observer), manager, std::string(guid), action));
    return 1;
  }
  return observer->Action(manager, guid, action);
}
size_t barc_download_copy_safe_target(uint64_t token, uint64_t manager,
                                       const char* guid, char* buffer, size_t capacity) {
  base::span<char> output;
  if (buffer && capacity) {
    // SAFETY: The C caller supplies capacity writable chars, as documented.
    output = UNSAFE_BUFFERS(base::span<char>(buffer, capacity));
    output[0] = '\0';
  }
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      !DownloadOwner() || DownloadOwner()->token() != token || !guid) return 0;
  const std::string path = DownloadOwner()->SafeTarget(manager, guid);
  if (path.empty()) return 0;
  if (!output.empty()) {
    const size_t count = std::min(output.size() - 1, path.size());
    output.first(count).copy_from(base::span(path).first(count));
    output[count] = '\0';
  }
  return path.size() + 1;
}
int barc_tab_execute_command(int32_t window_id, int32_t tab_id,
                             int32_t command) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || navigation_callback_depth)
    return 0;
  auto* window = Window(window_id);
  auto* tab = LookupTab(window, tab_id);
  if (command == BARC_PAGE_CLEAR_BACK_FORWARD_CACHE) {
    auto* unload = window ? UnloadController::From(window) : nullptr;
    auto* view = window ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
    if (!tab || window->IsDeleteScheduled() || !unload ||
        unload->owner_close_admitted() || unload->is_attempting_to_close_browser() ||
        (view && view->browser_widget()->HasPhysicalClosePending()) ||
        tab->GetContents()->IsBeingDestroyed() ||
        tab->GetContents()->GetBrowserContext() != window->GetProfile()) return 0;
    auto owner = window->GetWeakPtr();
    auto contents = tab->GetContents()->GetWeakPtr();
    auto* frame = contents->GetPrimaryMainFrame();
    if (!frame || !frame->IsRenderFrameLive() ||
        frame->GetLifecycleState() != content::RenderFrameHost::LifecycleState::kActive) return 0;
    auto document = frame->GetWeakDocumentPtr();
    contents->GetController().GetBackForwardCache().Flush();
    // Cache eviction may synchronously close/transfer/navigate the live page.
    // Re-resolve exact ownership; no borrowed tab/owner survives that callout.
    if (discovery_stopped || !owner || !contents || contents->IsBeingDestroyed() ||
        Window(window_id) != owner.get() || owner->IsDeleteScheduled() || UnloadController::From(owner.get())->owner_close_admitted() ||
        UnloadController::From(owner.get())->is_attempting_to_close_browser()) return 0;
    auto* current_view = BrowserView::GetBrowserViewForBrowser(owner.get());
    if (current_view && current_view->browser_widget()->HasPhysicalClosePending()) return 0;
    auto* current = LookupTab(owner.get(), tab_id);
    auto* current_document = document.AsRenderFrameHostIfValid();
    return current && current_document && current_document->IsRenderFrameLive() &&
        current_document->GetLifecycleState() == content::RenderFrameHost::LifecycleState::kActive &&
        current->GetContents() == contents.get() && contents->GetBrowserContext() == owner->GetProfile() &&
        current_document == contents->GetPrimaryMainFrame();
  }
  if (!tab || window->IsDeleteScheduled() ||
      tab->GetContents()->GetBrowserContext() != window->GetProfile() ||
      !window->IsSelectedForNativeWindow() ||
      window->GetTabStripModel()->GetActiveWebContents() != tab->GetContents())
    return 0;
  if (command == BARC_PAGE_HARD_RELOAD &&
      NativeContentBlocker::IsRegistered() &&
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return 0;
  if (command == BARC_PAGE_VIDEO_PIP_TOGGLE) {
    auto* contents = tab->GetContents();
    // Document PiP has a different lifetime/UI contract; observing it does not
    // mean this video toggle may close or recreate it.
    if (contents->HasPictureInPictureDocument())
      return 0;
    auto* session = content::MediaSession::Get(contents);
    const bool exiting = contents->HasPictureInPictureVideo();
    const auto action = exiting
        ? media_session::mojom::MediaSessionAction::kExitPictureInPicture
        : media_session::mojom::MediaSessionAction::kEnterPictureInPicture;
    const auto actions = session->GetMediaSessionActionsSync();
    if (std::ranges::find(actions, action) == actions.end())
      return 0;
    // Use Chromium's normal routed user action. The site's registered handler
    // and native permission/activation checks remain authoritative. No owner or
    // contents are dereferenced after the potentially reentrant dispatch.
    if (exiting)
      session->ExitPictureInPicture();
    else
      session->EnterPictureInPicture();
    return 1;
  }
  const char* devtools_panel = nullptr;
  switch (command) {
    case BARC_PAGE_DEVTOOLS_CONSOLE: devtools_panel = "console"; break;
    case BARC_PAGE_DEVTOOLS_NETWORK: devtools_panel = "network"; break;
    case BARC_PAGE_DEVTOOLS_PERFORMANCE: devtools_panel = "timeline"; break;
    default: break;
  }
  if (devtools_panel) {
    if (!chrome::IsCommandEnabled(window, IDC_DEV_TOOLS) ||
        !DevToolsWindow::AllowDevToolsFor(window->GetProfile(), tab->GetContents()))
      return 0;
    DevToolsWindow::OpenDevToolsWindow(
        tab->GetContents(), window->GetProfile(),
        DevToolsOpenedByAction::kMainMenuOrMainShortcut,
        content::DevToolsManagerDelegate::DevToolsOptions(devtools_panel));
    return 1;
  }
  int chrome_command;
  switch (command) {
    case BARC_PAGE_FIND: chrome_command = IDC_FIND; break;
    case BARC_PAGE_FIND_NEXT: chrome_command = IDC_FIND_NEXT; break;
    case BARC_PAGE_FIND_PREVIOUS: chrome_command = IDC_FIND_PREVIOUS; break;
    case BARC_PAGE_ZOOM_IN: chrome_command = IDC_ZOOM_PLUS; break;
    case BARC_PAGE_ZOOM_OUT: chrome_command = IDC_ZOOM_MINUS; break;
    case BARC_PAGE_ZOOM_RESET: chrome_command = IDC_ZOOM_NORMAL; break;
    case BARC_PAGE_PRINT: chrome_command = IDC_PRINT; break;
    case BARC_PAGE_DEVTOOLS: chrome_command = IDC_DEV_TOOLS; break;
    case BARC_PAGE_DEVTOOLS_INSPECT: chrome_command = IDC_DEV_TOOLS_INSPECT; break;
    case BARC_PAGE_HARD_RELOAD: chrome_command = IDC_RELOAD_BYPASSING_CACHE; break;
    default: return 0;
  }
  if (!chrome::IsCommandEnabled(window, chrome_command) ||
      (command == BARC_PAGE_PRINT && !chrome::CanPrint(window)) ||
      ((command == BARC_PAGE_DEVTOOLS || command == BARC_PAGE_DEVTOOLS_INSPECT) &&
       !DevToolsWindow::AllowDevToolsFor(window->GetProfile(), tab->GetContents())))
    return 0;
  // No callback occurs between exact admission and controller dispatch. The
  // command itself may enter a modal loop: never dereference borrowed owners
  // or contents after this call, and do not reinterpret its result as UI completion.
  return chrome::ExecuteCommand(window, chrome_command);
}
int barc_window_get_split(int32_t id, int32_t member, BarcSplitLayout* layout) {
  auto* window = Window(id);
  auto* strip = window ? window->GetTabStripModel() : nullptr;
  auto* active = strip ? strip->GetActiveTab() : nullptr;
  auto* target = member ? tabs::TabHandle(member).Get() : active;
  if (!window || !layout || !target)
    return 0;
  auto* view = BrowserView::GetBrowserViewForBrowser(window);
  auto* widget = view ? view->browser_widget() : nullptr;
  std::vector<tabs::TabInterface*> presented;
  split_tabs::SplitTabVisualData visual;
  tabs::TabInterface* presented_active = nullptr;
  uint64_t generation = 0;
  const bool mounted = widget && widget->GetBarcPresentedTabs(
      &presented, &visual, &presented_active, &generation);
  if (widget && widget->HasBarcPresentedTabs() && !mounted)
    return 0;
  if (mounted && std::ranges::contains(presented, target)) {
    BarcSplitLayout result{};
    result.count = presented.size();
    result.orientation = visual.split_layout() == split_tabs::SplitTabLayout::kSideBySide ? 0 : 1;
    result.active_tab = presented_active->GetHandle().raw_value();
    result.kind = 1;
    result.generation = generation;
    for (size_t i = 0; i < presented.size(); ++i)
      base::span(result.tabs)[i] = presented[i]->GetHandle().raw_value();
    base::span(result.dividers).first(presented.size() - 1).copy_from(visual.split_dividers());
    *layout = result;
    return 1;
  }
  if (target->GetBrowserWindowInterface() != window || !target->GetSplit())
    return 0;
  const auto split = *target->GetSplit();
  const auto* data = strip->GetSplitData(split);
  const auto tabs = data->ListTabs();
  if (tabs.size() < 2 || tabs.size() > 4 ||
      data->visual_data()->pane_count() != tabs.size())
    return 0;
  BarcSplitLayout result{};
  result.count = tabs.size();
  result.orientation = data->visual_data()->split_layout() ==
      split_tabs::SplitTabLayout::kSideBySide ? 0 : 1;
  result.active_tab = active && active->GetSplit() == split
      ? active->GetHandle().raw_value() : 0;
  result.collection = data->GetCollectionHandle().raw_value();
  for (size_t i = 0; i < tabs.size(); ++i) {
    if (tabs[i]->GetBrowserWindowInterface() != window ||
        tabs[i]->GetContents()->GetBrowserContext() != window->GetProfile())
      return 0;
    base::span(result.tabs)[i] = tabs[i]->GetHandle().raw_value();
  }
  base::span(result.dividers).first(tabs.size() - 1)
      .copy_from(data->visual_data()->split_dividers());
  *layout = result;
  return 1;
}
int barc_window_set_split(int32_t id, const BarcSplitLayout* layout) {
  if (!layout || navigation_callback_depth)
    return 0;
  const BarcSplitLayout request = *layout;
  if (request.count < 2 || request.count > 4 || request.orientation > 1)
    return 0;
  const auto handles = base::span(request.tabs).first(request.count);
  const auto dividers = base::span(request.dividers).first(request.count - 1);
  if (!split_tabs::SplitTabVisualData::AreValidDividers(dividers) ||
      dividers.front() <= 0 || dividers.back() >= 1 ||
      !std::ranges::contains(handles, request.active_tab))
    return 0;
  auto* window = Window(id);
  auto* view = window ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
  if (!view || !view->GetIsNormalType() || !window->IsSelectedForNativeWindow())
    return 0;
  std::vector<tabs::TabInterface*> tabs;
  bool mixed = false;
  for (int32_t handle : handles) {
    auto* tab = handle ? tabs::TabHandle(handle).Get() : nullptr;
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* owner_view = owner ? BrowserView::GetBrowserViewForBrowser(owner) : nullptr;
    if (!owner || Window(owner->GetSessionID().id()) != owner ||
        !owner_view || !owner_view->GetIsNormalType() ||
        owner_view->browser_widget() != view->browser_widget() ||
        tab->GetContents()->GetBrowserContext() != owner->GetProfile() ||
        std::ranges::contains(tabs, tab))
      return 0;
    mixed |= owner != window;
    tabs.push_back(tab);
  }
  if (mixed) {
    if (window->GetProfile()->IsOffTheRecord() ||
        std::ranges::any_of(tabs, [](auto* tab) {
          return tab->GetBrowserWindowInterface()->GetProfile()->IsOffTheRecord();
        }) || !LookupTab(window, request.active_tab))
      return 0;
    base::AutoReset callback_depth(&navigation_callback_depth, navigation_callback_depth + 1);
    return view->browser_widget()->SetBarcPresentedTabs(
        tabs, split_tabs::SplitTabVisualData(request.orientation == 0
            ? split_tabs::SplitTabLayout::kSideBySide : split_tabs::SplitTabLayout::kStacked, dividers),
        LookupTab(window, request.active_tab));
  }
  auto owner = window->GetWeakPtr();
  auto* widget = view->browser_widget();
  auto widget_alive = widget->GetWeakPtr();
  const uint64_t selection_before = widget->barc_selection_epoch();
  base::WeakPtr<tabs::TabInterface> active_before;
  if (auto* active = window->GetTabStripModel()->GetActiveTab())
    active_before = active->GetWeakPtr();
  if (widget->HasBarcPresentedTabs()) {
    if (!active_before)
      return 0;
    // All new members have already passed exact owner/profile admission. Return
    // borrowed containers before the normal same-owner collection mutation.
    base::AutoReset clearing_depth(&navigation_callback_depth, navigation_callback_depth + 1);
    widget->ClearBarcPresentedTabs();
    if (!widget_alive || !owner || Window(id) != owner.get() ||
        widget->barc_selection_epoch() != selection_before || !active_before ||
        owner->GetTabStripModel()->GetActiveTab() != active_before.get() ||
        !owner->IsSelectedForNativeWindow() || widget->HasBarcPresentedTabs())
      return 0;
    for (int32_t handle : handles) {
      if (!LookupTab(owner.get(), handle))
        return 0;
    }
  }
  // Selection/close observers can call the C boundary. Defer destructive close
  // until this model operation returns; split mutations refuse nested callbacks.
  base::AutoReset callback_depth(&navigation_callback_depth,
                                 navigation_callback_depth + 1);
  const auto orientation = request.orientation == 0
      ? split_tabs::SplitTabLayout::kSideBySide
      : split_tabs::SplitTabLayout::kStacked;
  window->GetTabStripModel()->SetSplit(
      tabs, LookupTab(window, request.active_tab),
      split_tabs::SplitTabVisualData(orientation, dividers));
  if (!owner || Window(id) != owner.get() ||
      !owner->IsSelectedForNativeWindow())
    return 0;
  BarcSplitLayout actual{};
  return barc_window_get_split(id, 0, &actual) &&
         actual.count == request.count &&
         actual.active_tab == request.active_tab &&
         actual.orientation == request.orientation &&
         std::ranges::equal(base::span(actual.tabs).first(actual.count), handles) &&
         std::ranges::equal(base::span(actual.dividers).first(actual.count - 1),
                            dividers);
}
int barc_window_clear_split(int32_t id, int32_t member,
                            const BarcSplitLayout* expected) {
  if (!expected || navigation_callback_depth)
    return 0;
  const BarcSplitLayout request = *expected;
  BarcSplitLayout actual{};
  if (!barc_window_get_split(id, member, &actual) ||
      actual.kind != request.kind || actual.generation != request.generation ||
      (actual.kind == 0 ? request.collection <= 0 || actual.collection != request.collection
                        : request.generation == 0 || actual.generation != request.generation) ||
      actual.count != request.count || actual.orientation != request.orientation ||
      actual.active_tab != request.active_tab ||
      !std::ranges::equal(base::span(actual.tabs).first(actual.count),
                         base::span(request.tabs).first(request.count)) ||
      !std::ranges::equal(base::span(actual.dividers).first(actual.count - 1),
                         base::span(request.dividers).first(request.count - 1))) {
    return 0;
  }
  auto* window = Window(id);
  auto* view = window ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
  if (!view || !view->GetIsNormalType())
    return 0;
  if (actual.kind == 1) {
    auto* widget = view->browser_widget();
    auto alive = widget->GetWeakPtr();
    auto* selected = tabs::TabHandle(actual.active_tab).Get();
    auto* selected_owner = selected ? selected->GetBrowserWindowInterface() : nullptr;
    if (!selected_owner || Window(selected_owner->GetSessionID().id()) != selected_owner ||
        !selected_owner->IsSelectedForNativeWindow() ||
        UnloadController::From(selected_owner)->owner_close_admitted())
      return 0;
    auto selected_tab = selected->GetWeakPtr();
    auto owner_alive = selected_owner->GetWeakPtr();
    const uint64_t epoch = widget->barc_selection_epoch();
    const auto local_split = selected->GetSplit();
    std::optional<tabs::TabCollection::Handle> local_collection;
    std::optional<split_tabs::SplitTabVisualData> local_visual;
    std::vector<int32_t> local_members;
    if (local_split) {
      const auto* data = selected_owner->GetTabStripModel()->GetSplitData(*local_split);
      local_collection = data->GetCollectionHandle();
      local_visual = *data->visual_data();
      for (auto* local_tab : data->ListTabs())
        local_members.push_back(local_tab->GetHandle().raw_value());
    }
    base::AutoReset callback_depth(&navigation_callback_depth, navigation_callback_depth + 1);
    widget->ClearBarcPresentedTabs();
    const auto current = [&] {
      return alive && owner_alive && selected_tab &&
          Window(owner_alive->GetSessionID().id()) == owner_alive.get() &&
          owner_alive->IsSelectedForNativeWindow() &&
          !UnloadController::From(owner_alive.get())->owner_close_admitted() &&
          widget->barc_selection_epoch() == epoch && !widget->HasBarcPresentedTabs() &&
          selected_tab->GetBrowserWindowInterface() == owner_alive.get() &&
          owner_alive->GetTabStripModel()->GetActiveTab() == selected_tab.get();
    };
    if (!current() || selected_tab->GetSplit() != local_split)
      return 0;
    if (local_split) {
      auto* strip = owner_alive->GetTabStripModel();
      const auto* data = strip->GetSplitData(*local_split);
      std::vector<int32_t> members;
      for (auto* local_tab : data->ListTabs())
        members.push_back(local_tab->GetHandle().raw_value());
      if (data->GetCollectionHandle() != *local_collection ||
          *data->visual_data() != *local_visual || members != local_members)
        return 0;
      // Explicit product separation leaves its selected page singly displayed.
      // Automatic detach/rollback remain view-only and never dissolve groups.
      strip->RemoveSplit(*local_split);
      if (!current() || local_collection->Get() || selected_tab->GetSplit())
        return 0;
    }
    return current() && !selected_tab->GetSplit();
  }
  auto* strip = window->GetTabStripModel();
  auto* target = LookupTab(window, base::span(actual.tabs).front());
  auto* active = strip->GetActiveTab();
  if (!target || !target->GetSplit() || !active)
    return 0;
  const auto split = *target->GetSplit();
  const auto collection = strip->GetSplitData(split)->GetCollectionHandle();
  const int32_t active_before = active->GetHandle().raw_value();
  auto owner = window->GetWeakPtr();
  base::AutoReset callback_depth(&navigation_callback_depth,
                                 navigation_callback_depth + 1);
  // This changes only the existing tab collection. Never select a retained
  // logical client or focus an inactive/background native window to dissolve it.
  strip->RemoveSplit(split);
  window = Window(id);
  if (!owner || window != owner.get() || collection.Get())
    return 0;
  active = window->GetTabStripModel()->GetActiveTab();
  return active && active->GetHandle().raw_value() == active_before;
}

int barc_tab_observe_media(uint64_t observation, BarcMediaCallback callback) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped) return 0;
  auto found = ObservationTable().find(observation);
  if (found == ObservationTable().end()) return 0;
  auto retained = found->second;
  return retained->SetMediaCallback(callback);
}
int barc_tab_media_action(int32_t window_id, int32_t tab_id, int32_t action) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      discovery_stopped || navigation_callback_depth) return 0;
  auto* owner = Window(window_id);
  auto* tab = LookupTab(owner, tab_id);
  if (!tab || owner->IsDeleteScheduled() || UnloadController::From(owner)->owner_close_admitted() ||
      tab->GetContents()->GetBrowserContext() != owner->GetProfile()) return 0;
  auto* contents = tab->GetContents();
  auto* session = content::MediaSession::GetIfExists(contents);
  if (!session) return 0;
  auto* routed = session->GetRoutedFrame();
  if (!routed || !routed->IsActive() || routed->GetOutermostMainFrame() != contents->GetPrimaryMainFrame()) return 0;
  media_session::mojom::MediaSessionAction required;
  switch (action) {
    case BARC_MEDIA_PLAY: required = media_session::mojom::MediaSessionAction::kPlay; break;
    case BARC_MEDIA_PAUSE: required = media_session::mojom::MediaSessionAction::kPause; break;
    case BARC_MEDIA_PREVIOUS_TRACK: required = media_session::mojom::MediaSessionAction::kPreviousTrack; break;
    case BARC_MEDIA_NEXT_TRACK: required = media_session::mojom::MediaSessionAction::kNextTrack; break;
    default: return 0;
  }
  const auto actions = session->GetMediaSessionActionsSync();
  if (std::ranges::find(actions, required) == actions.end()) return 0;
  // The exact page may end/transfer during the normal routed callout. No native
  // owner is dereferenced afterward; no selection, activation or fallback occurs.
  switch (action) {
    case BARC_MEDIA_PLAY: session->Resume(content::MediaSession::SuspendType::kUI); break;
    case BARC_MEDIA_PAUSE: session->Suspend(content::MediaSession::SuspendType::kUI); break;
    case BARC_MEDIA_PREVIOUS_TRACK: session->PreviousTrack(); break;
    case BARC_MEDIA_NEXT_TRACK: session->NextTrack(); break;
  }
  return 1;
}
int barc_tab_set_muted(int32_t window_id, int32_t tab_id, int muted) {
  if (navigation_callback_depth || (muted != 0 && muted != 1))
    return 0;
  auto* window = Window(window_id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab || tab->GetContents()->GetBrowserContext() != window->GetProfile())
    return 0;
  auto contents = tab->GetContents()->GetWeakPtr();
  const bool accepted = SetTabAudioMuted(contents.get(), muted != 0,
                                        TabMutedReason::kAudioIndicator, {});
  // Audio observers can close or transfer the bound page. Never retain/use a
  // borrowed TabInterface across that callout or silently address its replacement.
  auto* current = LookupTab(Window(window_id), tab_id);
  return accepted && contents && current && current->GetContents() == contents.get();
}
size_t barc_tab_copy_history(int32_t window, int32_t tab_id, int32_t direction,
                             char* buffer, size_t capacity) {
  auto* owner = Window(window);
  auto* tab = LookupTab(owner, tab_id);
  if (!tab || (direction != 0 && direction != 1) ||
      tab->GetContents()->GetBrowserContext() != owner->GetProfile()) return 0;
  auto& controller = tab->GetContents()->GetController();
  base::ListValue entries;
  const int step = direction ? 1 : -1;
  for (int index = controller.GetCurrentEntryIndex() + step, scanned = 0;
       index >= 0 && index < controller.GetEntryCount() && scanned < 100;
       index += step, ++scanned) {
    auto* entry = controller.GetEntryAtIndex(index);
    if (!entry || entry->GetTitle().size() > 4096) continue;
    const std::string title = base::UTF16ToUTF8(entry->GetTitle());
    const std::string& url = entry->GetVirtualURL().spec();
    if (title.size() > 4096 || url.size() > 8192) continue;
    entries.Append(base::DictValue().Set("id", entry->GetUniqueID())
        .Set("title", title).Set("url", url));
  }
  std::string json;
  if (!base::JSONWriter::Write(entries, &json) || json.size() >= 1024 * 1024) return 0;
  const size_t required = json.size() + 1;
  if (buffer && capacity >= required) {
    // SAFETY: This C ABI requires the caller to supply a writable allocation
    // containing at least capacity chars. Only the conversion trusts that
    // contract; all subsequent writes are bounded span operations.
    auto output = UNSAFE_BUFFERS(base::span<char>(buffer, capacity));
    output.first(json.size()).copy_from(base::span(json));
    output[json.size()] = '\0';
  }
  return required;
}
int barc_tab_go_to_history_entry(int32_t window, int32_t tab_id, int32_t entry_id) {
  if (navigation_callback_depth || entry_id <= 0) return 0;
  auto* owner = Window(window);
  auto* tab = LookupTab(owner, tab_id);
  if (!tab || !owner->IsSelectedForNativeWindow() || !tab->IsActivated() ||
      tab->GetContents()->GetBrowserContext() != owner->GetProfile() ||
      (NativeContentBlocker::IsRegistered() &&
       tab->GetContents()->GetUserData(&kApplicationLaunchKey))) return 0;
  auto& controller = tab->GetContents()->GetController();
  for (int index = 0; index < controller.GetEntryCount(); ++index) {
    auto* entry = controller.GetEntryAtIndex(index);
    if (entry && entry->GetUniqueID() == entry_id) {
      controller.GoToIndex(index);
      return 1;
    }
  }
  return 0;
}
int barc_tab_go_back(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
  // Captured application/private intents own the first navigation until exact
  // context policy and model admission consume their intrinsic blank role.
  if (tab && NativeContentBlocker::IsRegistered() &&
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return 0;
  if (!tab || !tab->GetContents()->GetController().CanGoBack())
    return 0;
  tab->GetContents()->GetController().GoBack();
  return 1;
}
int barc_tab_go_forward(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
  // Captured application/private intents own the first navigation until exact
  // context policy and model admission consume their intrinsic blank role.
  if (tab && NativeContentBlocker::IsRegistered() &&
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return 0;
  if (!tab || !tab->GetContents()->GetController().CanGoForward())
    return 0;
  tab->GetContents()->GetController().GoForward();
  return 1;
}
int barc_tab_reload(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
  // Captured application/private intents own the first navigation until exact
  // context policy and model admission consume their intrinsic blank role.
  if (tab && NativeContentBlocker::IsRegistered() &&
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return 0;
  if (!tab)
    return 0;
  tab->GetContents()->GetController().Reload(content::ReloadType::NORMAL, true);
  return 1;
}
int barc_tab_stop(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
  if (!tab)
    return 0;
  tab->GetContents()->Stop();
  return 1;
}
uint32_t barc_bridge_version() {
  return BARC_BRIDGE_VERSION;
}
const char* barc_public_headers_sha256() {
  return BARC_PUBLIC_HEADERS_SHA256;
}
const char* barc_chromium_version() {
  return version_info::GetVersionNumber().data();
}
int32_t barc_window_new_peer(int32_t source) {
  auto* window = Window(source);
  if (!window)
    return 0;
  auto* peer = CreateBrowserWindow(
      BrowserWindowCreateParams(*window->GetProfile(), true));
  if (auto* view = peer ? BrowserView::GetBrowserViewForBrowser(peer) : nullptr)
    view->MarkBarcAppFactoryOrigin();
  return peer ? peer->GetSessionID().id() : 0;
}
int32_t barc_window_new_peer_in_native_window(int32_t source_id,
                                                int32_t owner_id) {
  auto* source = Window(source_id);
  auto* owner = Window(owner_id);
  if (!source || !owner || !barc::CanResolveApplicationBrowser() ||
      navigation_callback_depth || !owner->GetWindow() ||
      UnloadController::From(source)->owner_close_admitted() ||
      UnloadController::From(owner)->owner_close_admitted() ||
      !BrowserWindow::CanCreateInNativeWindow(owner->GetSessionID()))
    return 0;
  std::array<char, 37> source_uuid{}, owner_uuid{};
  const bool private_source = barc_window_private_session_uuid(
      source_id, source_uuid.data(), source_uuid.size()) == 37;
  if (private_source) {
    if (barc_window_private_session_uuid(owner_id, owner_uuid.data(),
                                         owner_uuid.size()) != 37 ||
        source_uuid != owner_uuid)
      return 0;
  } else if (barc_window_profile_uuid(source_id, source_uuid.data(),
                                       source_uuid.size()) != 37 ||
             barc_window_profile_uuid(owner_id, owner_uuid.data(),
                                       owner_uuid.size()) != 37) {
    return 0;
  }
  auto source_alive = source->GetWeakPtr();
  auto owner_alive = owner->GetWeakPtr();
  auto profile_alive = source->GetProfile()->GetWeakPtr();
  auto keep_alive = ScopedProfileKeepAlive::TryAcquire(
      source->GetProfile()->GetOriginalProfile(),
      ProfileKeepAliveOrigin::kProfileCreationFlow);
  auto* collection = GlobalBrowserCollection::GetInstance();
  auto* selected = collection->FindBrowserWithWindow(
      owner->GetWindow()->GetNativeWindow());
  auto selected_alive = selected ? selected->GetWeakPtr()
                                : base::WeakPtr<BrowserWindowInterface>();
  if (!keep_alive || !selected_alive)
    return 0;
  BrowserWindowCreateParams params(*source->GetProfile(), true);
  params.native_window_owner = owner->GetSessionID();
  auto* created = CreateBrowserWindow(std::move(params));
  if (!created)
    return 0;
  auto created_alive = created->GetWeakPtr();
  if (auto* view = BrowserView::GetBrowserViewForBrowser(created))
    view->MarkBarcAppFactoryOrigin();
  const auto valid = [&] {
    if (!barc::CanResolveApplicationBrowser() || !source_alive || !owner_alive ||
        !profile_alive || !created_alive || source_alive->IsDeleteScheduled() ||
        owner_alive->IsDeleteScheduled() || created_alive->IsDeleteScheduled() ||
        !owner_alive->GetWindow() || !created_alive->GetWindow() ||
        source_alive->GetProfile() != profile_alive.get() ||
        created_alive->GetProfile() != profile_alive.get() ||
        UnloadController::From(source_alive.get())->owner_close_admitted() ||
        UnloadController::From(owner_alive.get())->owner_close_admitted())
      return false;
    return owner_alive->GetWindow()->GetNativeWindow() ==
               created_alive->GetWindow()->GetNativeWindow() &&
        GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
            owner_alive->GetWindow()->GetNativeWindow()) == selected_alive.get();
  };
  if (!valid()) {
    if (created_alive && !created_alive->IsDeleteScheduled() &&
        created_alive->GetWindow() && created_alive->GetTabStripModel()->empty())
      created_alive->GetWindow()->Close();
    return 0;
  }
  return created_alive->GetSessionID().id();
}
int barc_tab_create_peek(uint64_t observation, int32_t serial,
                         BarcTransferAdmission admission, void* context) {
  auto found = ObservationTable().find(observation);
  if (!admission || navigation_callback_depth || found == ObservationTable().end()) return 0;
  auto observed = found->second;
  if (!observed->PeekRequestIsCurrent(serial)) return 0;
  auto* source = tabs::TabHandle(observed->tab_id()).Get();
  auto* owner = source ? source->GetBrowserWindowInterface() : nullptr;
  if (!owner || barc::PeekForSource(source)) return 0;
  auto source_alive = source->GetWeakPtr();
  auto owner_alive = owner->GetWeakPtr();
  const int32_t peer_id = barc_window_new_peer_in_native_window(
      owner->GetSessionID().id(), owner->GetSessionID().id());
  auto* peer = Window(peer_id);
  const auto close_empty = [&] {
    auto* live = Window(peer_id);
    if (live && live->GetTabStripModel()->empty()) live->GetWindow()->Close();
  };
  if (!peer || !source_alive || !owner_alive ||
      source_alive->GetBrowserWindowInterface() != owner_alive.get() ||
      peer->GetProfile() != owner_alive->GetProfile() ||
      !observed->PeekRequestIsCurrent(serial) || barc::PeekForSource(source_alive.get())) {
    close_empty(); return 0;
  }
  auto request = observed->TakePeekRequest(serial);
  if (!request) { close_empty(); return 0; }
  // Stock context-menu new-tab navigation has no invented JavaScript opener.
  content::WebContents::CreateParams create(peer->GetProfile());
  auto blank = content::WebContents::Create(create);
  NavigateParams insert(peer, std::move(blank));
  insert.disposition = WindowOpenDisposition::NEW_BACKGROUND_TAB;
  insert.window_action = NavigateParams::WindowAction::kNoAction;
  Navigate(&insert);
  peer = Window(peer_id);
  auto* contents = insert.navigated_or_inserted_contents.get();
  if (!peer || !contents || peer->GetTabStripModel()->GetIndexOfWebContents(contents) == TabStripModel::kNoTab) {
    close_empty(); return 0;
  }
  auto* peek = tabs::TabInterface::GetFromContents(contents);
  auto peek_alive = peek->GetWeakPtr();
  const int32_t tab_id = peek->GetHandle().raw_value();
  auto current = [&] {
    auto* live = Window(peer_id);
    auto* main = request->main_document.AsRenderFrameHostIfValid();
    return live && source_alive && owner_alive && peek_alive && main &&
        request->document.AsRenderFrameHostIfValid() &&
        source_alive->GetContents()->GetPrimaryMainFrame() == main &&
        source_alive->GetBrowserWindowInterface() == owner_alive.get() &&
        LookupTab(live, tab_id) == peek_alive.get() &&
        live->GetTabStripModel()->GetActiveTab() == peek_alive.get() &&
        owner_alive->IsSelectedForNativeWindow() &&
        owner_alive->GetTabStripModel()->GetActiveTab() == source_alive.get() &&
        live->GetProfile() == owner_alive->GetProfile() &&
        observed->PeekSerialIsCurrent(serial) && barc::CanResolveApplicationBrowser() &&
        !UnloadController::From(live)->owner_close_admitted() &&
        !UnloadController::From(owner_alive.get())->owner_close_admitted();
  };
  auto refuse = [&] {
    if (peek_alive) ClearPeekRole(peek_alive.get());
    if (auto* live = LookupTab(Window(peer_id), tab_id)) {
      // No target navigation has happened. A callback may have moved it; only
      // this still-owned untouched blank can be closed here.
      if (live->GetContents()->GetController().IsInitialBlankNavigation() &&
          !live->GetContents()->GetController().GetPendingEntry()) {
        ClearPeekRole(live);
        barc_tab_close(peer_id, tab_id);
      }
    }
    close_empty(); return 0;
  };
  if (!current()) return refuse();
  contents->WasHidden();
  if (!current()) return refuse();
  contents->SetUserData(&kPeekRoleKey, std::make_unique<PeekRole>(peek, source_alive.get()));
  source_alive->GetContents()->SetUserData(&kPeekSourceKey, std::make_unique<PeekSource>(source_alive.get(), peek));
  int accepted = 0;
  {
    base::AutoReset guard(&navigation_callback_depth, navigation_callback_depth + 1);
    accepted = admission(context, peer_id, tab_id);
  }
  if (!accepted || !current() ||
      !barc::IsPeekPair(source_alive.get(), peek_alive.get()) ||
      !peek_alive->GetContents()->GetController().IsInitialBlankNavigation() ||
      peek_alive->GetContents()->GetController().GetPendingEntry())
    return refuse();
  // The existing observer is now bound. Reuse Chromium's captured stock link
  // parameters (initiator/referrer/protocol handling), never a replayed URL.
  request->params.disposition = WindowOpenDisposition::CURRENT_TAB;
  content::NavigationController::LoadURLParams load(request->params);
  peek_alive->GetContents()->GetController().LoadURLWithParams(load);
  barc::BrowserDiscoveryChanged();
  return 1;
}
uint64_t barc_tab_present_peek(int32_t source_window, int32_t source_tab,
    int32_t peek_window, int32_t peek_tab, void* expected_sidebar,
    void* header, void* actions) {
  auto* source = LookupTab(Window(source_window), source_tab);
  auto* peek = LookupTab(Window(peek_window), peek_tab);
  auto* owner = source ? BrowserView::GetBrowserViewForBrowser(source->GetBrowserWindowInterface()) : nullptr;
  if (!owner || !expected_sidebar || !header || !actions || navigation_callback_depth) return 0;
  return owner->browser_widget()->PresentBarcPeek(source, peek,
      gfx::NativeView((__bridge NSView*)expected_sidebar),
      gfx::NativeView((__bridge NSView*)header), gfx::NativeView((__bridge NSView*)actions));
}
int barc_tab_hide_peek(int32_t source_window, int32_t source_tab,
    int32_t peek_window, int32_t peek_tab, uint64_t generation,
    void* header, void* actions) {
  auto* source = LookupTab(Window(source_window), source_tab);
  auto* peek = LookupTab(Window(peek_window), peek_tab);
  auto* owner = source ? BrowserView::GetBrowserViewForBrowser(source->GetBrowserWindowInterface()) : nullptr;
  return owner && header && actions && !navigation_callback_depth &&
      owner->browser_widget()->HideBarcPeek(source, peek, generation,
          gfx::NativeView((__bridge NSView*)header), gfx::NativeView((__bridge NSView*)actions));
}
int barc_tab_is_peek_presented(int32_t source_window, int32_t source_tab,
    int32_t peek_window, int32_t peek_tab, uint64_t generation,
    void* header, void* actions) {
  auto* source = LookupTab(Window(source_window), source_tab);
  auto* peek = LookupTab(Window(peek_window), peek_tab);
  auto* owner = source ? BrowserView::GetBrowserViewForBrowser(source->GetBrowserWindowInterface()) : nullptr;
  return owner && header && actions && owner->browser_widget()->IsBarcPeekPresented(
      source, peek, generation, gfx::NativeView((__bridge NSView*)header),
      gfx::NativeView((__bridge NSView*)actions));
}
int barc_window_close(int32_t id) {
  auto* window = Window(id);
  if (!window)
    return 0;
  if (navigation_callback_depth) {
    return content::GetUIThreadTaskRunner({})->PostNonNestableTask(
        FROM_HERE, base::BindOnce([](int32_t window) { barc_window_close(window); },
                                 id));
  }
  window->GetWindow()->Close();
  return 1;
}
size_t barc_window_tab_count(int32_t id) {
  auto* window = Window(id);
  return window ? window->GetTabStripModel()->count() : 0;
}
int32_t barc_window_tab_at(int32_t id, size_t index) {
  auto* window = Window(id);
  if (!window ||
      index >= static_cast<size_t>(window->GetTabStripModel()->count()))
    return 0;
  return window->GetTabStripModel()
      ->GetTabAtIndex(static_cast<int>(index))
      ->GetHandle()
      .raw_value();
}
int32_t barc_tab_create(int32_t id, const char* value, int foreground) {
  auto* window = Window(id);
  GURL url = URL(value);
  if (!window || !url.is_valid())
    return 0;
  const bool present = window->GetTabStripModel()->empty() || foreground;
  if (present && !barc_window_select(id))
    return 0;
  window = Window(id);
  if (!window)
    return 0;
  auto* contents = chrome::AddAndReturnTabAt(window, url, -1, foreground != 0);
  // Insertion observers can close or move the new tab. Compare the returned
  // address against the surviving strip before dereferencing its contents.
  window = Window(id);
  if (!window || !contents)
    return 0;
  auto* strip = window->GetTabStripModel();
  const int index = strip->GetIndexOfWebContents(contents);
  if (index == TabStripModel::kNoTab)
    return 0;
  static_cast<tabs::TabModel*>(strip->GetTabAtIndex(index))->set_barc_app_factory_origin();
  barc::BrowserDiscoveryChanged();
  const int32_t tab_id = strip->GetTabAtIndex(index)->GetHandle().raw_value();
  // A nested profile selection wins over this request's original foreground
  // intent. Show itself can also invoke callbacks, so resolve once more after it.
  if (present && window->IsSelectedForNativeWindow())
    window->GetWindow()->Show();
  return LookupTab(Window(id), tab_id) ? tab_id : 0;
}
int barc_tab_select(int32_t id, int32_t tab_id) {
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab || !barc_window_select(id))
    return 0;
  // Admission can invoke native/profile callbacks; resolve the existing handles
  // again before mutating selection or focusing the requested document.
  window = Window(id);
  tab = LookupTab(window, tab_id);
  if (!tab)
    return 0;
  auto contents = tab->GetContents()->GetWeakPtr();
  auto* strip = window->GetTabStripModel();
  strip->ActivateTabAt(strip->GetIndexOfWebContents(tab->GetContents()));
  if (!contents)
    return 0;
  window = Window(id);
  tab = LookupTab(window, tab_id);
  if (!tab || tab->GetContents() != contents.get() ||
      !window->IsSelectedForNativeWindow())
    return 0;
  contents->Focus();
  return 1;
}
int barc_tab_search(int32_t id, int32_t tab_id, const char* query,
                    const char* kagi_session_token) {
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab || !query || strlen(query) > 16384 ||
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return 0;
  char identity[37] = {};
  if (barc_window_profile_uuid(id, identity, sizeof(identity)) != sizeof(identity) &&
      barc_window_private_session_uuid(id, identity, sizeof(identity)) != sizeof(identity)) return 0;
  auto* service = TemplateURLServiceFactory::GetForProfile(window->GetProfile());
  if (!service || !service->loaded()) return 0;
  const auto* provider = service->GetDefaultSearchProvider();
  if (!provider || !provider->SupportsReplacement(service->search_terms_data())) return 0;
  TemplateURLRef::PostContent post;
  GURL url(provider->url_ref().ReplaceSearchTerms(
      TemplateURLRef::SearchTermsArgs(base::UTF8ToUTF16(query)),
      service->search_terms_data(), &post));
  if (!url.SchemeIsHTTPOrHTTPS()) return 0;
  // The Session Link remains in the app Keychain. Borrow it only for an
  // explicitly selected, uncontrolled token-free Kagi template; never store it
  // in TemplateURLData, nor send it to a custom/managed/extension provider.
  if (kagi_session_token && *kagi_session_token && strlen(kagi_session_token) <= 8192 &&
      provider->url() == "https://kagi.com/search?q={searchTerms}" &&
      provider->url_ref().GetPostParamsString().empty() &&
      !service->is_default_search_managed() && !service->IsExtensionControlledDefaultSearch()) {
    url = net::AppendQueryParameter(url, "token", kagi_session_token);
  }
  content::NavigationController::LoadURLParams params(url);
  params.transition_type = ui::PAGE_TRANSITION_GENERATED;
  if (!post.first.empty()) {
    params.load_type = content::NavigationController::LOAD_TYPE_HTTP_POST;
    params.post_data = network::ResourceRequestBody::CreateFromCopyOfBytes(base::as_byte_span(post.second));
    params.extra_headers = "Content-Type: " + post.first;
  }
  tab->GetContents()->GetController().LoadURLWithParams(params);
  return 1;
}
int barc_tab_navigate(int32_t id, int32_t tab_id, const char* value) {
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  GURL url = URL(value);
  // Captured application/private intents own the first navigation until exact
  // context policy and model admission consume their intrinsic blank role.
  if (tab && NativeContentBlocker::IsRegistered() &&
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return 0;
  if (!tab || !url.is_valid())
    return 0;
  tab->GetContents()->GetController().LoadURL(
      url, content::Referrer(), ui::PAGE_TRANSITION_TYPED, std::string());
  return 1;
}
int barc_tab_close(int32_t id, int32_t tab_id) {
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab)
    return 0;
  if (navigation_callback_depth) {
    return content::GetUIThreadTaskRunner({})->PostNonNestableTask(
        FROM_HERE, base::BindOnce(
            [](int32_t window, int32_t tab) { barc_tab_close(window, tab); },
            id, tab_id));
  }
  window->GetTabStripModel()->CloseWebContents(
      tab->GetContents(), TabCloseTypes::CLOSE_USER_GESTURE |
                              TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
  return 1;
}
namespace {
int TransferTab(int32_t source_id, int32_t tab_id, int32_t destination_id,
                BarcTransferAdmission admission, void* context) {
  auto* source = Window(source_id);
  auto* destination = Window(destination_id);
  auto* tab = LookupTab(source, tab_id);
  if (!tab || !destination || source == destination ||
      source->GetProfile() != destination->GetProfile())
    return 0;
  if (navigation_callback_depth)
    return 0;
  if (!barc_window_select(destination_id))
    return 0;
  source = Window(source_id);
  destination = Window(destination_id);
  tab = LookupTab(source, tab_id);
  if (!tab || !destination ||
      source->GetProfile() != destination->GetProfile())
    return 0;
  auto* from = source->GetTabStripModel();
  const int source_index = from->GetIndexOfWebContents(tab->GetContents());
  const int pinned = from->IsTabPinned(source_index) ? AddTabTypes::ADD_PINNED : 0;
  const int rollback_types =
      pinned | (from->active_index() == source_index ? AddTabTypes::ADD_ACTIVE : 0);
  // A failed move must return the original live split, not just its page.
  const auto original_split = tab->GetSplit();
  const auto original_group = tab->GetGroup();
  auto* active_before = from->GetActiveTab();
  if (!active_before)
    return 0;
  const auto original_active = active_before->GetHandle().raw_value();
  auto source_alive = source->GetWeakPtr();
  std::vector<int32_t> split_members;
  std::optional<split_tabs::SplitTabVisualData> split_visual;
  std::optional<tabs::TabCollection::Handle> split_collection;
  if (original_split) {
    const auto* data = from->GetSplitData(*original_split);
    const auto members = data->ListTabs();
    if (members.size() < 2 || members.size() > 4 ||
        data->visual_data()->pane_count() != members.size())
      return 0;
    split_visual = *data->visual_data();
    split_collection = data->GetCollectionHandle();
    for (auto* member : members)
      split_members.push_back(member->GetHandle().raw_value());
  }
  const auto split_unchanged = [&](int32_t expected_active, bool inserted) {
    auto* owner = Window(source_id);
    if (!original_split || !source_alive || owner != source_alive.get())
      return false;
    auto* strip = owner->GetTabStripModel();
    auto* active = strip->GetActiveTab();
    if (!active || active->GetHandle().raw_value() != expected_active)
      return false;
    std::vector<int32_t> remaining;
    for (int32_t member : split_members) {
      if (member == tab_id && !inserted)
        continue;
      auto* current = LookupTab(owner, member);
      if (!current || current->GetGroup() != original_group ||
          current->IsPinned() != (pinned != 0))
        return false;
      if (member == tab_id) {
        if (current->IsSplit())
          return false;
      } else {
        remaining.push_back(member);
      }
    }
    if (remaining.size() == 1) {
      return !strip->ContainsSplit(*original_split) &&
             !LookupTab(owner, remaining.front())->IsSplit();
    }
    if (!strip->ContainsSplit(*original_split))
      return false;
    const auto* data = strip->GetSplitData(*original_split);
    const auto members = data->ListTabs();
    if (data->GetCollectionHandle() != *split_collection ||
        members.size() != remaining.size() ||
        *data->visual_data() != split_tabs::SplitTabVisualData::EqualSplit(
            split_visual->split_layout(), remaining.size()))
      return false;
    for (size_t i = 0; i < remaining.size(); ++i) {
      if (members[i]->GetHandle().raw_value() != remaining[i])
        return false;
    }
    return true;
  };
  // The ordinary empty-strip notification closes the source, so defer it until
  // the live tab is safely inserted or returned. Explicit closes still win.
  base::ScopedClosureRunner complete_detach(base::BindOnce(
      [](base::WeakPtr<BrowserWindowInterface> source) {
        if (source && !source->IsDeleteScheduled())
          source->GetTabStripModel()->NotifyEmptyAfterDeferredDetach();
      },
      source->GetWeakPtr()));
  auto detached = from->DetachTabAtForInsertion(source_index,
                                               /*notify_empty=*/false);
  if (!detached)
    return 0;
  // Detach notifies observers, which may close the destination. Restore to the
  // surviving source when possible; do not retain a dead destination strip.
  destination = Window(destination_id);
  const auto restore_source = [&]() -> int {
    if (auto* surviving_source = Window(source_id);
        source_alive && surviving_source == source_alive.get() &&
        !UnloadController::From(surviving_source)->owner_close_admitted()) {
      auto* strip = surviving_source->GetTabStripModel();
      int32_t after_detach_active = original_active;
      if (original_split && original_active == tab_id) {
        const size_t position = std::ranges::find(split_members, tab_id) -
                                split_members.begin();
        after_detach_active = position + 1 < split_members.size()
            ? split_members[position + 1] : split_members[position - 1];
      }
      const bool restore_split = split_unchanged(after_detach_active, false);
      int insertion = std::min(source_index, strip->count());
      // Do not dissolve a surviving or deliberately reconfigured split just
      // to return the detached page. Rebuild the original collection below
      // only if its identity, members, geometry and active pane still match.
      if (insertion < strip->count()) {
        if (const auto at = strip->GetSplitForTab(insertion)) {
          const auto range = strip->GetSplitData(*at)->GetIndexRange();
          if (insertion > static_cast<int>(range.start()))
            insertion = range.end();
        }
      }
      if (restore_split && split_members.size() > 2)
        insertion = strip->GetSplitData(*original_split)->GetIndexRange().end();
      // Keep the surviving active pane during reinsertion. Restoring an active
      // moved pane before its split would briefly hide/remount the other panes.
      const int returning_types = original_split
          ? rollback_types & ~AddTabTypes::ADD_ACTIVE : rollback_types;
      strip->InsertDetachedTabAt(insertion, std::move(detached), returning_types,
                                restore_split ? original_group : std::nullopt);
      if (restore_split && split_unchanged(after_detach_active, true)) {
        // Only this restoration phase defers destructive C callbacks; the
        // destination-close notification above retains its existing behavior.
        base::AutoReset depth(&navigation_callback_depth,
                              navigation_callback_depth + 1);
        if (split_members.size() > 2)
          strip->RemoveSplit(*original_split);
        surviving_source = Window(source_id);
        if (!source_alive || surviving_source != source_alive.get())
          return 0;
        strip = surviving_source->GetTabStripModel();
        std::vector<int> indices;
        for (int32_t member : split_members) {
          auto* current = LookupTab(surviving_source, member);
          if (!current || current->IsSplit() ||
              current->GetGroup() != original_group ||
              current->IsPinned() != (pinned != 0))
            return 0;
          indices.push_back(strip->GetIndexOfTab(current));
        }
        auto* active = strip->GetActiveTab();
        if (!active || active->GetHandle().raw_value() != after_detach_active)
          return 0;
        strip->RestoreSplit(*original_split, indices, *split_visual);
        surviving_source = Window(source_id);
        if (!source_alive || surviving_source != source_alive.get())
          return 0;
        strip = surviving_source->GetTabStripModel();
        active = strip->GetActiveTab();
        if (original_active != after_detach_active && active &&
            active->GetHandle().raw_value() == after_detach_active &&
            strip->ContainsSplit(*original_split)) {
          const auto* data = strip->GetSplitData(*original_split);
          const auto members = data->ListTabs();
          bool unchanged = *data->visual_data() == *split_visual &&
                           members.size() == split_members.size();
          for (size_t i = 0; unchanged && i < members.size(); ++i)
            unchanged = members[i]->GetHandle().raw_value() == split_members[i];
          if (unchanged) {
            auto* restored_active = LookupTab(surviving_source, original_active);
            if (restored_active)
              strip->ActivateTabAt(strip->GetIndexOfTab(restored_active));
          }
        }
      }
    }
    return 0;
  };
  if (!destination)
    return restore_source();
  auto* to = destination->GetTabStripModel();
  const int32_t previous_active = to->GetActiveTab()
      ? to->GetActiveTab()->GetHandle().raw_value() : 0;
  to->InsertDetachedTabAt(to->count(), std::move(detached),
                         AddTabTypes::ADD_ACTIVE | pinned);
  destination = Window(destination_id);
  if (!LookupTab(destination, tab_id))
    return 0;
  if (admission && !admission(context, destination_id, tab_id)) {
    // Admission may reenter close/transfer. Restore only if this exact tab still
    // belongs to this destination and the original source remains live.
    source = Window(source_id);
    destination = Window(destination_id);
    tab = LookupTab(destination, tab_id);
    if (!source || !tab || source->GetProfile() != destination->GetProfile() ||
        UnloadController::From(source)->owner_close_admitted())
      return 0;
    const bool restore_previous_active =
        destination->GetTabStripModel()->GetActiveTab() == tab;
    base::ScopedClosureRunner complete_rollback(base::BindOnce(
        [](base::WeakPtr<BrowserWindowInterface> destination) {
          if (destination && !destination->IsDeleteScheduled())
            destination->GetTabStripModel()->NotifyEmptyAfterDeferredDetach();
        }, destination->GetWeakPtr()));
    to = destination->GetTabStripModel();
    detached = to->DetachTabAtForInsertion(to->GetIndexOfTab(tab),
                                          /*notify_empty=*/false);
    if (!detached)
      return 0;
    destination = Window(destination_id);
    const int32_t active_after_detach = destination &&
            destination->GetTabStripModel()->GetActiveTab()
        ? destination->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value()
        : 0;
    source = Window(source_id);
    if (!source || UnloadController::From(source)->owner_close_admitted()) {
      // An explicit source close won during detach. Keep the live page in its
      // still-surviving destination instead of destroying it as rollback state.
      if (auto* surviving = Window(destination_id)) {
        if (!UnloadController::From(surviving)->owner_close_admitted()) {
          auto* strip = surviving->GetTabStripModel();
          strip->InsertDetachedTabAt(strip->count(), std::move(detached),
              pinned | (restore_previous_active ? AddTabTypes::ADD_ACTIVE : 0));
        }
      }
      return 0;
    }
    restore_source();
    destination = Window(destination_id);
    if (restore_previous_active && destination) {
      to = destination->GetTabStripModel();
      auto* active = to->GetActiveTab();
      const int32_t current_active = active ? active->GetHandle().raw_value() : 0;
      // Reinsertion/restoring a split notifies source observers. A newer
      // destination selection from those callouts must not be overwritten.
      if (current_active == active_after_detach) {
        if (auto* previous = LookupTab(destination, previous_active)) {
          if (previous != active)
            to->ActivateTabAt(to->GetIndexOfTab(previous));
        }
      }
    }
    return 0;
  }
  destination = Window(destination_id);
  tab = LookupTab(destination, tab_id);
  if (!tab)
    return 0;
  if (admission) ClearPeekRole(tab);
  if (destination->IsSelectedForNativeWindow() &&
      (!admission || destination->GetTabStripModel()->GetActiveTab() == tab))
    destination->GetWindow()->Show();
  return LookupTab(Window(destination_id), tab_id) ? 1 : 0;
}
}  // namespace
int barc_tab_transfer(int32_t source, int32_t tab, int32_t destination) {
  return TransferTab(source, tab, destination, nullptr, nullptr);
}
int barc_tab_transfer_with_admission(int32_t source, int32_t tab,
                                     int32_t destination,
                                     BarcTransferAdmission admission,
                                     void* context) {
  if (!admission) return 0;
  if (source == destination && !navigation_callback_depth) {
    auto* owner = Window(source);
    auto* page = LookupTab(owner, tab);
    if (!page || !PeekRoleFor(page) || UnloadController::From(owner)->owner_close_admitted()) return 0;
    auto alive = page->GetWeakPtr();
    if (!admission(context, destination, tab) || !alive ||
        LookupTab(Window(destination), tab) != alive.get()) return 0;
    ClearPeekRole(alive.get());
    return 1;
  }
  return TransferTab(source, tab, destination, admission, context);
}
int barc_window_select(int32_t id) {
  auto* window = Window(id);
  auto* view = window ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
  return view && view->browser_widget()->SelectLogicalBrowserView(view);
}
size_t barc_tab_copy_launch_space(int32_t window, int32_t tab_id,
                                   char* buffer, size_t capacity) {
  base::span<char> output;
  if (buffer && capacity) {
    // SAFETY: C callers provide `capacity` writable bytes. Only this boundary
    // conversion trusts that claim; all subsequent copies use bounded spans.
    output = UNSAFE_BUFFERS(base::span<char>(buffer, capacity));
    output[0] = '\0';
  }
  auto* tab = LookupTab(Window(window), tab_id);
  auto* launch = tab ? static_cast<ApplicationLaunch*>(
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) : nullptr;
  if (!launch || launch->space.empty()) return 0;
  if (!output.empty()) {
    const size_t count = std::min(output.size() - 1, launch->space.size());
    output.first(count).copy_from(base::span(launch->space).first(count));
    output[count] = '\0';
  }
  return launch->space.size() + 1;
}
int barc_tab_application_pending(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
  return tab && tab->GetContents()->GetUserData(&kApplicationLaunchKey) ? 1 : 0;
}
size_t barc_tab_copy_title(int32_t id,
                           int32_t tab_id,
                           char* buffer,
                           size_t capacity) {
  base::span<char> output;
  if (buffer && capacity) {
    // SAFETY: This C ABI requires the caller to supply a writable allocation
    // containing at least capacity chars. Only the conversion trusts that
    // contract; all subsequent writes are bounded span operations.
    output = UNSAFE_BUFFERS(base::span<char>(buffer, capacity));
    output[0] = '\0';
  }
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab)
    return 0;
  const std::string title = base::UTF16ToUTF8(tab->GetContents()->GetTitle());
  if (buffer && capacity) {
    const size_t count = std::min(title.size(), capacity - 1);
    output.first(count).copy_from(base::span(title).first(count));
    output[count] = '\0';
  }
  return title.size() + 1;
}
int barc_window_show(int32_t id) {
  if (!barc_window_select(id))
    return 0;
  auto* window = Window(id);
  if (!window || !window->IsSelectedForNativeWindow())
    return 0;
  auto alive = window->GetWeakPtr();
  window->GetWindow()->Show();
  return alive && Window(id) == alive.get() &&
         alive->IsSelectedForNativeWindow();
}
int barc_window_attach_native_shell(int32_t id, void* native_view) {
  auto* window = Window(id);
  auto* browser_view = window ? BrowserView::GetBrowserViewForBrowser(window)
                              : nullptr;
  auto* host = browser_view ? browser_view->barc_native_shell() : nullptr;
  if (!host || attaching_native_shell)
    return 0;
  NSView* view = (__bridge NSView*)native_view;
  if (view.window && view.window !=
          browser_view->GetWidget()->GetNativeWindow().GetNativeNSWindow())
    return 0;
  auto owner = window->GetWeakPtr();
  auto browser = browser_view->GetAsWeakPtr();
  auto* selected_view = browser_view->browser_widget()->selected_browser_view();
  if (!selected_view)
    return 0;
  auto selected = selected_view->GetAsWeakPtr();
  auto* header_host = browser_view->barc_page_header();
  views::ViewTracker header_alive(header_host);
  BarcPageHeader* paired = browser_view->barc_compact_shell() ? nil : PageHeader(view);
  if (paired.view.window && paired.view.window !=
          browser_view->GetWidget()->GetNativeWindow().GetNativeNSWindow()) return 0;
  views::ViewTracker host_alive(host);
  const auto intact = [&] {
    return owner && Window(id) == owner.get() && browser && host_alive.view() &&
           BrowserView::GetBrowserViewForBrowser(owner.get()) == browser.get() &&
           browser->barc_native_shell() == host_alive.view() &&
           (!header_host || (header_alive.view() && browser->barc_page_header() == header_alive.view())) && selected &&
           browser->browser_widget()->selected_browser_view() == selected.get();
  };
  // Stack-owned guards survive synchronous native teardown. C close requests
  // are non-nestable deferred; native NSWindow.close is guarded inside Views.
  base::AutoReset<bool> attach_scope(&attaching_native_shell, true);
  base::AutoReset<int> callback_scope(&navigation_callback_depth,
                                      navigation_callback_depth + 1);
  browser->BarcNativeShellWillChange();
  // Hide the exact pair before any reentrant detach/hierarchy notification.
  if (header_host) {
    header_host->SetVisible(false);
    if (!intact()) return 0;
  }
  host->SetVisible(false);
  if (!intact()) return 0;
  if (header_host) {
    header_host->Detach();
    if (!intact()) return 0;
  }
  host->Detach();
  if (!intact())
    return 0;
  if (view) {
    host->Attach(gfx::NativeView(view));
    if (!intact() || host->native_view().GetNativeNSView() != view)
      return 0;
  }
  if (paired && header_host) {
    header_host->Attach(gfx::NativeView(paired.view));
    if (!intact() || header_host->native_view().GetNativeNSView() != paired.view) return 0;
    header_host->SetVisible(true);
    if (!intact()) return 0;
  }
  host->SetVisible(view != nil);
  if (!intact())
    return 0;
  browser->InvalidateLayout();
  return intact();
}


int barc_window_set_native_header(int32_t id, void* expected_sidebar,
    void* expected_header, void* replacement_header, int32_t height) {
  auto* owner = Window(id);
  auto* browser = owner ? BrowserView::GetBrowserViewForBrowser(owner) : nullptr;
  auto* sidebar_host = browser ? browser->barc_native_shell() : nullptr;
  auto* host = browser ? browser->barc_page_header() : nullptr;
  NSView* sidebar = (__bridge NSView*)expected_sidebar;
  NSView* expected = (__bridge NSView*)expected_header;
  NSView* replacement = (__bridge NSView*)replacement_header;
  if (!browser || browser->barc_compact_shell() || !sidebar_host || !host ||
      !sidebar || attaching_native_shell || height < 0 || height > 128 ||
      (replacement != nil) != (height > 0) || replacement == sidebar ||
      sidebar_host->native_view().GetNativeNSView() != sidebar ||
      host->native_view().GetNativeNSView() != expected ||
      (replacement.window && replacement.window != sidebar.window) ||
      (replacement != expected && replacement.superview)) return 0;
  BarcPageHeader* old = PageHeader(sidebar);
  if (expected == replacement && old.view == replacement && old.height == height) return 1;
  auto alive = browser->GetAsWeakPtr();
  auto owner_alive = owner->GetWeakPtr();
  views::ViewTracker sidebar_alive(sidebar_host), header_alive(host);
  const auto current = [&] {
    return alive && owner_alive && Window(id) == owner_alive.get() &&
        BrowserView::GetBrowserViewForBrowser(owner_alive.get()) == alive.get() &&
        sidebar_alive.view() && header_alive.view() &&
        alive->barc_native_shell() == sidebar_alive.view() &&
        alive->barc_page_header() == header_alive.view() &&
        sidebar_host->native_view().GetNativeNSView() == sidebar;
  };
  base::AutoReset<bool> attachment(&attaching_native_shell, true);
  base::AutoReset<int> callbacks(&navigation_callback_depth, navigation_callback_depth + 1);
  // A height-only update preserves the native responder and never reparents.
  if (expected != replacement) {
    host->SetVisible(false);
    if (!current()) return 0;
    host->Detach();
    if (!current()) return 0;
    if (replacement) {
      host->Attach(gfx::NativeView(replacement));
      if (!current() || host->native_view().GetNativeNSView() != replacement) return 0;
    }
  }
  BarcPageHeader* paired = nil;
  if (replacement) {
    paired = [[BarcPageHeader alloc] init]; paired.view = replacement; paired.height = height;
  }
  objc_setAssociatedObject(sidebar, &kNativePageHeaderKey, paired, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (!current()) return 0;
  host->SetVisible(replacement != nil);
  if (!current()) return 0;
  alive->InvalidateLayout();
  return current() && host->native_view().GetNativeNSView() == replacement;
}

int barc_window_native_shell_is_owned(int32_t id, void* expected_view) {
  auto* window = Window(id);
  auto* browser = window ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
  auto* host = browser ? browser->barc_native_shell() : nullptr;
  return host &&
         host->native_view().GetNativeNSView() == (__bridge NSView*)expected_view;
}
int barc_window_detach_native_shell_if_owned(int32_t id, void* expected_view) {
  return expected_view && barc_window_native_shell_is_owned(id, expected_view)
             ? barc_window_attach_native_shell(id, nullptr) : 0;
}

@interface BarcPeekBackdrop : NSView {
 @private
  base::WeakPtr<tabs::TabInterface> source_;
  base::WeakPtr<tabs::TabInterface> peek_;
}
- (instancetype)initWithSource:(tabs::TabInterface*)source peek:(tabs::TabInterface*)peek;
@end
@implementation BarcPeekBackdrop
- (instancetype)initWithSource:(tabs::TabInterface*)source peek:(tabs::TabInterface*)peek {
  if ((self = [super initWithFrame:NSZeroRect])) {
    source_ = source->GetWeakPtr();
    peek_ = peek->GetWeakPtr();
  }
  return self;
}
- (void)drawRect:(NSRect)dirty {
  [[NSColor colorWithWhite:0.5 alpha:0.45] setFill];
  NSRectFillUsingOperation(dirty, NSCompositingOperationSourceOver);
}
- (void)mouseDown:(NSEvent*)event {
  if (!source_ || !peek_ || !barc::IsPeekPair(source_.get(), peek_.get())) return;
  auto* owner = peek_->GetBrowserWindowInterface();
  if (owner) barc_tab_close(owner->GetSessionID().id(), peek_->GetHandle().raw_value());
}
@end
@class BarcNativeShell;
namespace {
class ShellObserver final : public TabStripModelObserver {
 public:
  explicit ShellObserver(BarcNativeShell* shell, TabStripModel* strip);
  ~ShellObserver() override;
  void OnTabStripModelChanged(TabStripModel*,
                              const TabStripModelChange&,
                              const TabStripSelectionChange&) override;
  void OnTabChangedAt(tabs::TabInterface*, TabChangeType) override;
  void OnTabStripModelDestroyed(TabStripModel*) override;

 private:
  __weak BarcNativeShell* shell_;
  raw_ptr<TabStripModel> strip_;
};
}  // namespace

@interface BarcNativeShell : NSView {
  int32_t window_id_;
  NSPopUpButton* tabs_;
  NSTextField* address_;
  std::unique_ptr<ShellObserver> observer_;
}
- (instancetype)initWithBrowser:(BrowserWindowInterface*)browser;
- (void)refreshTabs;
@end

@implementation BarcNativeShell
- (BOOL)isFlipped {
  return YES;
}
- (instancetype)initWithBrowser:(BrowserWindowInterface*)browser {
  if ((self = [super initWithFrame:NSMakeRect(0, 0, 240, 600)])) {
    window_id_ = browser->GetSessionID().id();
    NSTextField* label = [NSTextField labelWithString:@"Barc native shell"];
    label.frame = NSMakeRect(12, 16, 216, 24);
    [self addSubview:label];
    address_ = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 52, 216, 26)];
    address_.placeholderString = @"URL";
    address_.target = self;
    address_.action = @selector(navigate:);
    [self addSubview:address_];
    tabs_ = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(12, 92, 216, 26)
                                       pullsDown:NO];
    tabs_.target = self;
    tabs_.action = @selector(selectTab:);
    [self addSubview:tabs_];
    NSArray<NSString*>* labels = @[
      @"New tab", @"Chromium Settings", @"Extensions", @"Move tab to new window"
    ];
    const std::array<SEL, 4> actions = {
        @selector(newTab:), @selector(settings:), @selector(extensions:),
        @selector(moveTab:)};
    for (NSUInteger index = 0; index < labels.count; ++index) {
      NSButton* button = [NSButton buttonWithTitle:labels[index]
                                            target:self
                                            action:actions[index]];
      button.frame = NSMakeRect(12, 138 + index * 40, 216, 30);
      [self addSubview:button];
    }
    observer_ =
        std::make_unique<ShellObserver>(self, browser->GetTabStripModel());
    [self refreshTabs];
  }
  return self;
}
- (void)refreshTabs {
  auto* browser = Window(window_id_);
  [tabs_ removeAllItems];
  if (!browser)
    return;
  auto* strip = browser->GetTabStripModel();
  for (int i = 0; i < strip->count(); ++i) {
    auto* tab = strip->GetTabAtIndex(i);
    NSString* title = [NSString
        stringWithUTF8String:base::UTF16ToUTF8(tab->GetContents()->GetTitle())
                                 .c_str()];
    NSMenuItem* item =
        [[NSMenuItem alloc] initWithTitle:title.length ? title : @"Untitled"
                                   action:nil
                            keyEquivalent:@""];
    item.representedObject = @(tab->GetHandle().raw_value());
    [tabs_.menu addItem:item];
  }
  if (strip->active_index() >= 0)
    [tabs_ selectItemAtIndex:strip->active_index()];
}
- (int32_t)selectedTab {
  return [tabs_.selectedItem.representedObject intValue];
}
- (void)selectTab:(id)sender {
  barc_tab_select(window_id_, [self selectedTab]);
}
- (void)navigate:(id)sender {
  barc_tab_navigate(window_id_, [self selectedTab],
                    address_.stringValue.UTF8String);
}
- (void)newTab:(id)sender {
  barc_tab_create(window_id_, "about:blank", 1);
}
- (void)settings:(id)sender {
  barc_tab_create(window_id_, "chrome://settings/", 1);
}
- (void)extensions:(id)sender {
  barc_tab_create(window_id_, "chrome://extensions/", 1);
}
- (void)moveTab:(id)sender {
  const int32_t tab = [self selectedTab];
  if (!tab)
    return;
  const int32_t peer = barc_window_new_peer(window_id_);
  if (peer && !barc_tab_transfer(window_id_, tab, peer))
    barc_window_close(peer);
}
@end

namespace {
ShellObserver::ShellObserver(BarcNativeShell* shell, TabStripModel* strip)
    : shell_(shell), strip_(strip) {
  strip_->AddObserver(this);
}
ShellObserver::~ShellObserver() {
  if (strip_)
    strip_->RemoveObserver(this);
}
void ShellObserver::OnTabStripModelChanged(TabStripModel*,
                                           const TabStripModelChange&,
                                           const TabStripSelectionChange&) {
  [shell_ refreshTabs];
}
void ShellObserver::OnTabChangedAt(tabs::TabInterface*, TabChangeType) {
  [shell_ refreshTabs];
}
void ShellObserver::OnTabStripModelDestroyed(TabStripModel*) {
  strip_ = nullptr;
}
}  // namespace

namespace barc {
base::RepeatingCallback<bool()> VaultPasskeyContext(content::RenderFrameHost* frame) {
  auto* contents = frame ? content::WebContents::FromRenderFrameHost(frame) : nullptr;
  for (const auto& [token,observer] : ObservationTable()) {
    if (observer->web_contents() != contents || !observer->active() || !observer->vault_passkey_callback_) continue;
    auto* tab = tabs::TabInterface::GetFromContents(contents);
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* view = owner ? BrowserView::GetBrowserViewForBrowser(owner) : nullptr;
    if (!frame || !view || !view->browser_widget()) return {};
    return base::BindRepeating([](std::weak_ptr<TabObservation> weak,content::WeakDocumentPtr document,
        base::WeakPtr<BrowserWindowInterface> owner,base::WeakPtr<views::Widget> widget) {
      auto self = weak.lock(); return self && self->VaultPasskeyContextCurrent(document,owner,widget);
    },std::weak_ptr<TabObservation>(observer),frame->GetWeakDocumentPtr(),owner->GetWeakPtr(),view->browser_widget()->GetWeakPtr());
  }
  return {};
}
base::OnceClosure StartVaultPasskeyRequest(content::RenderFrameHost* frame,
    const url::Origin& origin,int operation,base::DictValue arguments,
    base::OnceCallback<void(std::optional<std::string>)> reply) {
  auto* contents = frame ? content::WebContents::FromRenderFrameHost(frame) : nullptr;
  std::string json;
  if (frame && frame->GetLastCommittedOrigin() == origin &&
      (operation == 0 || operation == 1) && base::JSONWriter::Write(arguments,&json) && json.size() <= 65536) {
    std::vector<std::shared_ptr<TabObservation>> observers;
    for (const auto& [token,observer] : ObservationTable())
      if (observer->web_contents() == contents && observer->vault_passkey_callback_) observers.push_back(observer);
    if (!observers.empty()) return observers.front()->StartVaultPasskey(frame,operation,std::move(json),std::move(reply));
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(FROM_HERE,
      base::BindOnce(std::move(reply),std::nullopt)); return {};
}
bool OfferVaultPasswordSave(content::WebContents* contents,
                            const password_manager::PasswordForm& credentials) {
  if (!contents) return false;
  // Snapshot existing observation ownership; no separate save registry.
  std::vector<std::shared_ptr<TabObservation>> observers;
  for (const auto& [token, observer] : ObservationTable())
    if (observer->web_contents() == contents) observers.push_back(observer);
  for (const auto& observer : observers)
    if (observer->OfferVaultSave(credentials)) return true;
  return false;
}

void CancelDocumentDownloadsForProfilePath(const base::FilePath& path) {
  std::vector<std::shared_ptr<TabObservation>> observers;
  for (const auto& [id,observer]:ObservationTable()) observers.push_back(observer);
  for (auto& observer:observers) observer->CancelFilesForProfile(path);
}
void RecordNativeNavigationBlock(content::WebContents* contents,
                                 int64_t navigation, const GURL& url) {
  if (!contents) return;
  for (const auto& [token, observer] : ObservationTable()) {
    if (observer->web_contents() == contents) {
      observer->RecordNativeBlock(navigation, url);
      return;
    }
  }
}
bool IsPeekCloseCommitted(tabs::TabInterface* source) {
  auto* link = source ? static_cast<PeekSource*>(source->GetContents()->GetUserData(&kPeekSourceKey)) : nullptr;
  auto* role = PeekRoleFor(source);
  return (link && link->close_committed) || (role && role->close_committed);
}
void ResetPeekCloseCommitted(tabs::TabInterface* tab, content::WebContents* expected) {
  // New role objects begin uncommitted; replacement contents have their own
  // lifetime. Undo only the surviving old contents skipped by this commit.
  if (!tab || tab->GetContents() != expected) return;
  if (auto* role = PeekRoleFor(tab)) role->close_committed = false;
  if (auto* link = static_cast<PeekSource*>(expected->GetUserData(&kPeekSourceKey)))
    link->close_committed = false;
}
bool CommitPeekPairClose(tabs::TabInterface* source, tabs::TabInterface* peek) {
  if (!IsPeekPair(source, peek)) return false;
  static_cast<PeekSource*>(source->GetContents()->GetUserData(&kPeekSourceKey))->close_committed = true;
  PeekRoleFor(peek)->close_committed = true;
  return true;
}
void NotifyPeekCloseCancelled(tabs::TabInterface* tab) {
  if (!tab) return;
  std::vector<std::shared_ptr<TabObservation>> observers;
  for (const auto& [token, observer] : ObservationTable()) {
    if (observer->tab_id() == tab->GetHandle().raw_value()) observers.push_back(observer);
  }
  for (const auto& observer : observers) observer->Emit(BARC_TAB_CLOSE_CANCELLED);
}
tabs::TabInterface* PeekForSource(tabs::TabInterface* source) {
  auto* link = source ? static_cast<PeekSource*>(source->GetContents()->GetUserData(&kPeekSourceKey)) : nullptr;
  auto* peek = link ? link->peek.get() : nullptr;
  auto* role = PeekRoleFor(peek);
  return role && role->source.get() == source ? peek : nullptr;
}
bool IsPeekPair(tabs::TabInterface* source, tabs::TabInterface* peek) {
  auto* role = PeekRoleFor(peek);
  auto* link = source ? static_cast<PeekSource*>(source->GetContents()->GetUserData(&kPeekSourceKey)) : nullptr;
  auto* owner = source ? source->GetBrowserWindowInterface() : nullptr;
  auto* peer = peek ? peek->GetBrowserWindowInterface() : nullptr;
  return role && role->source.get() == source && link && link->peek.get() == peek &&
      owner && peer && !owner->IsDeleteScheduled() && !peer->IsDeleteScheduled() &&
      owner->GetProfile() == peer->GetProfile() && owner->GetWindow() && peer->GetWindow() &&
      owner->GetWindow()->GetNativeWindow() == peer->GetWindow()->GetNativeWindow();
}
bool CanRequestPeek(content::RenderFrameHost* frame) {
  if (!frame || !IsNativeApplicationRegistered()) return false;
  for (const auto& [token, observation] : ObservationTable()) {
    if (observation->CanRequestPeek(frame)) return true;
  }
  return false;
}
void RequestPeek(content::RenderFrameHost* frame,
                 const content::OpenURLParams& params) {
  if (!frame || !IsNativeApplicationRegistered()) return;
  // Observations are the existing page ownership, not a second tab lookup map.
  for (const auto& [token, observation] : ObservationTable()) {
    if (observation->CanRequestPeek(frame)) {
      auto retained = observation;
      retained->RequestPeek(frame, params);
      return;
    }
  }
}
base::ScopedClosureRunner ProtectNativeViewMutation() {
  CHECK(content::BrowserThread::CurrentlyOn(content::BrowserThread::UI));
  ++navigation_callback_depth;
  return base::ScopedClosureRunner(base::BindOnce([] {
    CHECK_GT(navigation_callback_depth, 0);
    --navigation_callback_depth;
  }));
}
void BrowserDiscoveryChanged() {
  CHECK_NE(discovery_revision, UINT64_MAX);
  ++discovery_revision;
  if (auto observer = DiscoveryOwner()) observer->Schedule();
}
void StopBrowserDiscovery() {
  discovery_stopped = true;
  NativeContentBlocker::StopPolicy();
  ClearApplicationPageIntents();
  if (auto downloads = std::move(DownloadOwner())) downloads->Cancel();
  auto observer = std::move(DiscoveryOwner());
  if (observer) observer->Cancel();
}
int NativeShellWidth(const BrowserView* browser_view) {
  auto* shell = browser_view->barc_native_shell();
  return shell && shell->GetVisible() && !browser_view->barc_compact_shell()
      ? kNativeShellWidth : 0;
}
int NativeShellHeight(const BrowserView* browser_view) {
  auto* shell = browser_view->barc_native_shell();
  if (!shell || !shell->GetVisible()) return 0;
  if (browser_view->barc_compact_shell()) return 44;
  auto* header = browser_view->barc_page_header();
  BarcPageHeader* paired = PageHeader(shell->native_view().GetNativeNSView());
  return header && header->GetVisible() && paired &&
      header->native_view().GetNativeNSView() == paired.view ? paired.height : 0;
}
bool MarkApplicationPage(int32_t window, int32_t tab_id, uint64_t request,
                          std::string space) {
  auto* owner = Window(window);
  auto* tab = LookupTab(owner, tab_id);
  if (!tab || !request || tab->GetContents()->GetBrowserContext() != owner->GetProfile() ||
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) return false;
  tab->GetContents()->SetUserData(&kApplicationLaunchKey,
      std::make_unique<ApplicationLaunch>(request, std::move(space), owner->GetProfile()->GetWeakPtr()));
  return true;
}
bool ApplicationPageMatches(int32_t window, int32_t tab_id, uint64_t request) {
  auto* owner = Window(window);
  auto* tab = LookupTab(owner, tab_id);
  auto* launch = tab ? static_cast<ApplicationLaunch*>(
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) : nullptr;
  return launch && launch->request == request && launch->profile &&
      owner->GetProfile() == launch->profile.get() &&
      tab->GetContents()->GetBrowserContext() == launch->profile.get();
}
bool SetApplicationPageResume(ApplicationPage page, base::RepeatingClosure resume) {
  if (!resume || !ApplicationPageMatches(page.window, page.tab, page.request))
    return false;
  auto* launch = static_cast<ApplicationLaunch*>(
      LookupTab(Window(page.window), page.tab)->GetContents()->GetUserData(
          &kApplicationLaunchKey));
  if (launch->resume) return false;
  launch->resume = std::move(resume);
  PendingApplicationPageIntents().Append(launch);
  NotifyApplicationBrowserAvailable();
  return true;
}
void DrainApplicationPageIntents() {
  auto& pending = PendingApplicationPageIntents();
  if (pending.empty()) return;
  // Re-read the front on the next event. A callback can consume any record,
  // close its owner or stop the runtime; never preserve an intrusive next node.
  auto resume = pending.head()->value()->resume;
  resume.Run();
}
void ClearApplicationPageIntents() {
  auto& pending = PendingApplicationPageIntents();
  while (!pending.empty()) {
    auto* launch = pending.head()->value();
    launch->RemoveFromList();
    launch->resume.Reset();
  }
}
void ConsumeApplicationPage(int32_t window, int32_t tab_id, uint64_t request) {
  if (ApplicationPageMatches(window, tab_id, request))
    LookupTab(Window(window), tab_id)->GetContents()->RemoveUserData(&kApplicationLaunchKey);
}
void AbandonApplicationPageRequest(int32_t tab_id, uint64_t request) {
  auto* tab = tabs::TabHandle(tab_id).Get();
  auto* launch = tab ? static_cast<ApplicationLaunch*>(
      tab->GetContents()->GetUserData(&kApplicationLaunchKey)) : nullptr;
  // Clearing this exact request's intrinsic hint is not a command against a
  // newer owner. A transferred page survives and cannot remain falsely pending.
  if (launch && launch->request == request && launch->profile &&
      tab->GetContents()->GetBrowserContext() == launch->profile.get())
    tab->GetContents()->RemoveUserData(&kApplicationLaunchKey);
}
bool ConfigureNativeMini(BrowserWindowInterface* browser) {
  auto* view = browser && !browser->IsDeleteScheduled()
      ? BrowserView::GetBrowserViewForBrowser(browser) : nullptr;
  return view && view->InitializeBarcCompactShell();
}
namespace {
class PeekUnloadHandler final : public UnloadController::TabUnloadHandler {
 public:
  explicit PeekUnloadHandler(BrowserWindowInterface* browser)
      : browser_(browser->GetWeakPtr()) {}
  bool ShouldSkipBeforeUnload(content::WebContents* contents) override {
    return IsPeekCloseCommitted(tabs::TabInterface::GetFromContents(contents));
  }
  bool ShouldShowCustomConfirmation(content::WebContents* contents) override {
    auto* tab = tabs::TabInterface::GetFromContents(contents);
    if (!browser_ || browser_->IsDeleteScheduled() || !tab ||
        tab->GetBrowserWindowInterface() != browser_.get() ||
        UnloadController::From(browser_.get())->owner_close_admitted() ||
        IsPeekCloseCommitted(tab)) return false;
    auto* view = BrowserView::GetBrowserViewForBrowser(browser_.get());
    return view && view->browser_widget() && (PeekForSource(tab) ||
        view->browser_widget()->HasPhysicalClosePending() || browser_shutdown::IsTryingToQuit());
  }
  bool ShowCustomConfirmation(content::WebContents* contents,
      base::OnceCallback<void(bool)> on_closed) override {
    if (!ShouldShowCustomConfirmation(contents)) return false;
    auto* source = tabs::TabInterface::GetFromContents(contents);
    auto* view = BrowserView::GetBrowserViewForBrowser(browser_.get());
    auto* widget = view->browser_widget();
    if (widget->HasPhysicalClosePending() || browser_shutdown::IsTryingToQuit()) {
      if (!browser_shutdown::IsTryingToQuit() && !widget->IsPhysicalCloseTarget(source)) {
        // This controller already belongs to another exact subset. Do not run
        // its old continuation/reset over that cohort or start a second prompt.
        contents->SetClosedByUserGesture(false);
        NotifyPeekCloseCancelled(source);
      }
      return true;
    }
    auto* peek = PeekForSource(source);
    return widget->RequestPeekPairClose(source, peek, std::move(on_closed));
  }
 private:
  base::WeakPtr<BrowserWindowInterface> browser_;
};
}  // namespace
views::NativeViewHost* CreateNativeShell(BrowserView* browser_view) {
  const bool registered = IsNativeApplicationRegistered();
  if ((!registered &&
       !base::CommandLine::ForCurrentProcess()->HasSwitch("barc-native-shell")) ||
      browser_view->browser()->GetType() != BrowserWindowInterface::TYPE_NORMAL)
    return nullptr;
  if (registered) {
    UnloadController::From(browser_view->browser())->AddTabUnloadHandler(
        std::make_unique<PeekUnloadHandler>(browser_view->browser()));
  }
  auto* host =
      browser_view->AddChildView(std::make_unique<views::NativeViewHost>());
  if (registered) {
    host->SetVisible(false);
    return host;
  }
  BarcNativeShell* shell =
      [[BarcNativeShell alloc] initWithBrowser:browser_view->browser()];
  host->Attach(gfx::NativeView(shell));
  return host;
}
void AttachPeekBackdrop(views::NativeViewHost* host, tabs::TabInterface* source,
                        tabs::TabInterface* peek) {
  if (!host || !IsPeekPair(source, peek)) return;
  BarcPeekBackdrop* backdrop = [[BarcPeekBackdrop alloc] initWithSource:source peek:peek];
  host->Attach(gfx::NativeView(backdrop));
}
bool MovePeekNativeShell(BrowserWindowInterface* from, BrowserWindowInterface* to) {
  if (!from || !to || from == to || from->GetProfile() != to->GetProfile()) return false;
  auto source = from->GetWeakPtr();
  auto destination = to->GetWeakPtr();
  auto* old_view = BrowserView::GetBrowserViewForBrowser(from);
  auto* new_view = BrowserView::GetBrowserViewForBrowser(to);
  if (!old_view || !new_view || old_view->browser_widget() != new_view->browser_widget() ||
      !old_view->barc_native_shell() || !new_view->barc_native_shell() ||
      new_view->barc_native_shell()->native_view()) return false;
  NSView* expected = old_view->barc_native_shell()->native_view().GetNativeNSView();
  if (!expected) return false;
  const int32_t old_id = from->GetSessionID().id(), new_id = to->GetSessionID().id();
  auto selected = old_view->browser_widget()->selected_browser_view()->GetAsWeakPtr();
  auto current = [&] {
    return source && destination && selected && Window(old_id) == source.get() &&
        Window(new_id) == destination.get() &&
        BrowserView::GetBrowserViewForBrowser(source.get()) &&
        BrowserView::GetBrowserViewForBrowser(destination.get()) &&
        BrowserView::GetBrowserViewForBrowser(destination.get())->browser_widget()->selected_browser_view() == selected.get();
  };
  if (!barc_window_detach_native_shell_if_owned(old_id, (__bridge void*)expected) || !current()) return false;
  if (!barc_window_native_shell_is_owned(new_id, nullptr)) return false;
  return barc_window_attach_native_shell(new_id, (__bridge void*)expected) && current();
}
void LayoutNativeShell(views::NativeViewHost* shell,
                       BrowserView* browser_view) {
  if (!shell || !shell->GetVisible())
    return;
  const gfx::Rect bounds = browser_view->GetLocalBounds();
  if (browser_view->barc_compact_shell()) {
    shell->SetBounds(bounds.x(), bounds.y(), bounds.width(), 44);
  } else {
    auto alive = browser_view->GetAsWeakPtr();
    views::ViewTracker header(browser_view->barc_page_header());
    shell->SetBounds(bounds.x(), bounds.y(), kNativeShellWidth, bounds.height());
    if (!alive || !header.view() || alive->barc_page_header() != header.view()) return;
    const int height = NativeShellHeight(alive.get());
    if (header.view()->GetVisible()) {
      header.view()->SetBounds(bounds.x() + kNativeShellWidth, bounds.y(),
          std::max(0, bounds.width() - kNativeShellWidth), height);
    }
  }
}
}  // namespace barc
