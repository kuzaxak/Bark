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
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
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
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/views/frame/barc_profiles.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
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
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/referrer.h"
#include "ui/base/base_window.h"
#include "ui/gfx/geometry/insets.h"
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

// Tokens own observers, never tabs or profiles. Each callback holds only its
// observer alive, so unsubscribe/close during delivery cannot free its stack.
class TabObservation;
using Observations = std::map<uint64_t, std::shared_ptr<TabObservation>>;
Observations& ObservationTable() {
  static base::NoDestructor<Observations> table;
  return *table;
}
class TabObservation : public content::WebContentsObserver,
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
    active_ = false;
    callback_ = nullptr;
    context_ = nullptr;
    Observe(nullptr);
    UnbindOwner();
    detach_ = {};
    insert_ = {};
    discard_ = {};
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
  void DidStartNavigation(content::NavigationHandle* handle) override {
    auto keep_alive = shared_from_this();
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
  return 2;
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
