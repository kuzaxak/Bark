#import <AppKit/AppKit.h>

#include "chrome/browser/ui/views/frame/barc_bridge.h"

#include <algorithm>
#include <array>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <string_view>

#include "base/command_line.h"
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
#include "content/public/browser/download_manager.h"
#include "base/task/single_thread_task_runner.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_discard_reason.h"
#include "net/base/net_errors.h"
#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/strings/utf_string_conversions.h"
#include "base/version_info/version_info.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/views/frame/barc_profiles.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_tabstrip.h"
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
#include "ui/views/view_tracker.h"
#include "chrome/browser/ui/views/frame/browser_widget.h"
#include "components/sessions/core/session_id.h"
#include "components/tabs/public/tab_interface.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/weak_document_ptr.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_partition_key_collection.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "third_party/blink/public/common/storage_key/storage_key.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/referrer.h"
#include "ui/base/base_window.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/views/controls/native/native_view_host.h"
#include "url/gurl.h"

namespace {
// UI-thread-only; the storage outlives all reentrant observer callouts.
int navigation_callback_depth = 0;
bool attaching_native_shell = false;
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
class TabObservation;
using Observations = std::map<uint64_t, std::shared_ptr<TabObservation>>;
Observations& ObservationTable() {
  static base::NoDestructor<Observations> table;
  return *table;
}
class TabObservation : public content::WebContentsObserver,
                       public content::BrowsingDataRemover::Observer,
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
    BindOwner();
  }
  ~TabObservation() override { UnbindOwner(); }
  int32_t tab_id() const { return tab_.raw_value(); }
  bool active() const { return active_; }
  bool closing() const { return closing_; }
  void Cancel() {
    if (thumbnail_) {
      thumbnail_->cancelled.Set();
      thumbnail_.reset();
    }
    site_data_remover_.Reset();
    site_data_.reset();
    active_ = false;
    callback_ = nullptr;
    context_ = nullptr;
    Observe(nullptr);
    UnbindOwner();
    detach_ = {};
    insert_ = {};
    discard_ = {};
  }
  bool CaptureThumbnail(uint64_t request, BarcTabThumbnailCallback callback) {
    auto keep_alive = shared_from_this();
    if (!active_ || closing_ || thumbnail_ || !request || !callback || !web_contents())
      return false;
    auto* tab = tab_.Get();
    auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
    auto* view = web_contents()->GetRenderWidgetHostView();
    auto* document = web_contents()->GetPrimaryMainFrame();
    if (!owner || owner->IsDeleteScheduled() ||
        !owner->IsSelectedForNativeWindow() ||
        owner->GetTabStripModel()->GetActiveTab() != tab ||
        web_contents()->GetVisibility() != content::Visibility::VISIBLE ||
        !view || !view->IsShowing() || !document)
      return false;
    const gfx::Size bounds = view->GetViewBounds().size();
    if (bounds.IsEmpty())
      return false;
    // Scale at the compositor copy, never capture a full-resolution bitmap.
    const double scale = std::min(1.0, 400.0 / std::max(bounds.width(), bounds.height()));
    const gfx::Size output(std::max(1, static_cast<int>(bounds.width() * scale)),
                           std::max(1, static_cast<int>(bounds.height() * scale)));
    auto capture = std::make_shared<ThumbnailCapture>();
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
  void OnAudioStateChanged(bool) override { Emit(BARC_TAB_STATE); }
  void DidUpdateAudioMutingState(bool) override { Emit(BARC_TAB_STATE); }
  void DidStartNavigation(content::NavigationHandle* handle) override {
    auto keep_alive = shared_from_this();
    if (handle->IsInPrimaryMainFrame() && thumbnail_)
      thumbnail_->cancelled.Set();
    if (handle->IsInPrimaryMainFrame() && site_data_) site_data_->cancelled = true;
    if (!handle->IsInPrimaryMainFrame() || handle->IsSameDocument())
      return;
    navigation_ = handle->GetNavigationId();
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
    // A subscription cannot reconstruct starts or failures from before binding.
    // A real new primary commit is observable; otherwise report current state.
    if (!navigation_) {
      if (handle->HasCommitted() && handle->GetNetErrorCode() == net::OK)
        Emit(BARC_TAB_COMMITTED, 0, 0, &handle->GetURL());
      else
        Emit(BARC_TAB_STATE);
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
      Emit(BARC_TAB_FAILED, handle->GetNetErrorCode(), navigation_flags_ |
          (!handle->HasCommitted() ? BARC_TAB_PROVISIONAL : 0) |
          (handle->GetNetErrorCode() == net::ERR_ABORTED ? BARC_TAB_ABORTED : 0),
          &displayed);
      return;
    }
    if (!handle->HasCommitted())
      return;
    committed_ = true;
    const GURL url = handle->GetURL();
    Emit(BARC_TAB_COMMITTED, 0, navigation_flags_, &url);
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
  struct ThumbnailCapture {
    ThumbnailCapture();
    ~ThumbnailCapture();
    base::WeakPtr<BrowserWindowInterface> owner;
    content::WeakDocumentPtr document;
    int64_t navigation = 0;
    uint64_t request = 0;
    BarcTabThumbnailCallback callback = nullptr;
    base::AtomicFlag cancelled;
  };
  bool ThumbnailIsCurrent(const std::shared_ptr<ThumbnailCapture>& capture) {
    if (!active_ || closing_ || thumbnail_ != capture ||
        capture->cancelled.IsSet() || capture->navigation != navigation_ ||
        !capture->owner || capture->owner->IsDeleteScheduled() || !web_contents())
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
        result->bitmap.drawsNothing() || result->bitmap.width() > 400 ||
        result->bitmap.height() > 400) {
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
          auto encoded = gfx::PNGCodec::EncodeBGRASkBitmap(bitmap, false);
          if (capture->cancelled.IsSet() || !encoded || encoded->size() > 1048576)
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
  base::ScopedObservation<content::BrowsingDataRemover,
                           content::BrowsingDataRemover::Observer> site_data_remover_{this};

  void UnbindOwner() {
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
    if (thumbnail_)
      thumbnail_->cancelled.Set();
    if (site_data_) site_data_->cancelled = true;
    if (reason == tabs::TabInterface::DetachReason::kDelete)
      Close();
    else
      UnbindOwner();
  }
  void Inserted(tabs::TabInterface*) {
    BindOwner();
    Emit(BARC_TAB_STATE);
  }
  void Discard(tabs::TabInterface*, content::WebContents*,
               content::WebContents* replacement) {
    if (thumbnail_)
      thumbnail_->cancelled.Set();
    if (site_data_) site_data_->cancelled = true;
    navigation_ = 0;
    navigation_flags_ = 0;
    committed_ = false;
    Observe(replacement);
    Emit(BARC_TAB_STATE);
  }
  void Close() {
    auto keep_alive = shared_from_this();
    if (!active_)
      return;
    // Keep duplicate admission blocked through the terminal callout, including
    // when it unsubscribes before attempting to bind the closing tab again.
    closing_ = true;
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
  const uint64_t token_;
  const tabs::TabHandle tab_;
  BarcTabCallback callback_;
  raw_ptr<void> context_;
  bool active_ = true;
  bool closing_ = false;
  int64_t navigation_ = 0;
  bool committed_ = false;
  uint32_t navigation_flags_ = 0;
  raw_ptr<TabStripModel> strip_ = nullptr;
  base::CallbackListSubscription window_cancelled_;
  base::CallbackListSubscription detach_, insert_, discard_;
};
TabObservation::ThumbnailCapture::ThumbnailCapture() = default;
TabObservation::ThumbnailCapture::~ThumbnailCapture() = default;
TabObservation::SiteDataRequest::SiteDataRequest() = default;
TabObservation::SiteDataRequest::~SiteDataRequest() = default;
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
          (row.active_tab == tab->GetHandle().raw_value()
               ? static_cast<uint32_t>(BARC_DISCOVERY_ACTIVE_TAB) : 0u) |
          (static_cast<tabs::TabModel*>(strip->GetTabAtIndex(index))->barc_app_factory_origin()
               ? static_cast<uint32_t>(BARC_DISCOVERY_TAB_APP_FACTORY) : 0u)};
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
  if (discovery_stopped || navigation_callback_depth)
    return 0;
  auto* window = Window(window_id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab || window->IsDeleteScheduled() ||
      tab->GetContents()->GetBrowserContext() != window->GetProfile() ||
      !window->IsSelectedForNativeWindow() ||
      window->GetTabStripModel()->GetActiveWebContents() != tab->GetContents())
    return 0;
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
    case BARC_PAGE_HARD_RELOAD: chrome_command = IDC_RELOAD_BYPASSING_CACHE; break;
    default: return 0;
  }
  if (!chrome::IsCommandEnabled(window, chrome_command) ||
      (command == BARC_PAGE_PRINT && !chrome::CanPrint(window)) ||
      (command == BARC_PAGE_DEVTOOLS &&
       !DevToolsWindow::AllowDevToolsFor(window->GetProfile(), tab->GetContents())))
    return 0;
  // No callback occurs between exact admission and controller dispatch. The
  // command itself may enter a modal loop: never dereference borrowed owners
  // or contents after this call, and do not reinterpret its result as UI completion.
  return chrome::ExecuteCommand(window, chrome_command);
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
int barc_tab_go_back(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
  if (!tab || !tab->GetContents()->GetController().CanGoBack())
    return 0;
  tab->GetContents()->GetController().GoBack();
  return 1;
}
int barc_tab_go_forward(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
  if (!tab || !tab->GetContents()->GetController().CanGoForward())
    return 0;
  tab->GetContents()->GetController().GoForward();
  return 1;
}
int barc_tab_reload(int32_t window, int32_t tab_id) {
  auto* tab = LookupTab(Window(window), tab_id);
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
  return 3;
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
int barc_tab_navigate(int32_t id, int32_t tab_id, const char* value) {
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  GURL url = URL(value);
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
int barc_tab_transfer(int32_t source_id,
                      int32_t tab_id,
                      int32_t destination_id) {
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
  if (!destination) {
    if (auto* surviving_source = Window(source_id)) {
      auto* strip = surviving_source->GetTabStripModel();
      strip->InsertDetachedTabAt(std::min(source_index, strip->count()),
                                std::move(detached), rollback_types);
    }
    return 0;
  }
  auto* to = destination->GetTabStripModel();
  to->InsertDetachedTabAt(to->count(), std::move(detached),
                         AddTabTypes::ADD_ACTIVE | pinned);
  destination = Window(destination_id);
  if (!LookupTab(destination, tab_id))
    return 0;
  if (destination->IsSelectedForNativeWindow())
    destination->GetWindow()->Show();
  return LookupTab(Window(destination_id), tab_id) ? 1 : 0;
}
int barc_window_select(int32_t id) {
  auto* window = Window(id);
  auto* view = window ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
  return view && view->browser_widget()->SelectLogicalBrowserView(view);
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
  views::ViewTracker host_alive(host);
  const auto intact = [&] {
    return owner && Window(id) == owner.get() && browser && host_alive.view() &&
           BrowserView::GetBrowserViewForBrowser(owner.get()) == browser.get() &&
           browser->barc_native_shell() == host_alive.view() && selected &&
           browser->browser_widget()->selected_browser_view() == selected.get();
  };
  // Stack-owned guards survive synchronous native teardown. C close requests
  // are non-nestable deferred; native NSWindow.close is guarded inside Views.
  base::AutoReset<bool> attach_scope(&attaching_native_shell, true);
  base::AutoReset<int> callback_scope(&navigation_callback_depth,
                                      navigation_callback_depth + 1);
  browser->BarcNativeShellWillChange();
  host->Detach();
  if (!intact())
    return 0;
  if (view) {
    host->Attach(gfx::NativeView(view));
    if (!intact() || host->native_view().GetNativeNSView() != view)
      return 0;
  }
  host->SetVisible(view != nil);
  if (!intact())
    return 0;
  browser->InvalidateLayout();
  return intact();
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
void BrowserDiscoveryChanged() {
  CHECK_NE(discovery_revision, UINT64_MAX);
  ++discovery_revision;
  if (auto observer = DiscoveryOwner()) observer->Schedule();
}
void StopBrowserDiscovery() {
  discovery_stopped = true;
  if (auto downloads = std::move(DownloadOwner())) downloads->Cancel();
  auto observer = std::move(DiscoveryOwner());
  if (observer) observer->Cancel();
}
int NativeShellWidth(const BrowserView* browser_view) {
  auto* shell = browser_view->barc_native_shell();
  return shell && shell->GetVisible() ? kNativeShellWidth : 0;
}
views::NativeViewHost* CreateNativeShell(BrowserView* browser_view) {
  const bool registered = IsNativeApplicationRegistered();
  if ((!registered &&
       !base::CommandLine::ForCurrentProcess()->HasSwitch("barc-native-shell")) ||
      browser_view->browser()->GetType() != BrowserWindowInterface::TYPE_NORMAL)
    return nullptr;
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
void LayoutNativeShell(views::NativeViewHost* shell,
                       views::View* browser_view) {
  if (!shell || !shell->GetVisible())
    return;
  const gfx::Rect bounds = browser_view->GetLocalBounds();
  shell->SetBounds(bounds.x(), bounds.y(), kNativeShellWidth, bounds.height());
}
}  // namespace barc
