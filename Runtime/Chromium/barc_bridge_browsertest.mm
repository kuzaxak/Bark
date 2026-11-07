#import <AppKit/AppKit.h>

#include "chrome/browser/ui/views/frame/barc_bridge.h"
#include "chrome/browser/ui/views/frame/barc_profiles.h"
#include "chrome/browser/ui/views/frame/barc_runtime_startup.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "base/run_loop.h"

#include <algorithm>
#include <array>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "base/command_line.h"
#include "base/functional/callback_helpers.h"
#include "base/scoped_observation.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/download/download_prefs.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "chrome/browser/policy/developer_tools_policy_handler.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/sessions/session_service.h"
#include "chrome/browser/sessions/session_service_factory.h"
#include "chrome/browser/ui/browser_active_state_manager/browser_active_state_manager.h"
#include "chrome/browser/ui/browser_command_controller.h"
#include "chrome/browser/ui/browser_element_identifiers.h"
#include "chrome/browser/ui/browser_init_state.h"
#include "chrome/browser/ui/browser_manager_service.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/embedder_browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/find_bar/find_bar.h"
#include "chrome/browser/ui/find_bar/find_bar_controller.h"
#include "chrome/browser/ui/tabs/tab_muted_utils.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/ui/views/frame/app_menu_button.h"
#include "chrome/browser/ui/views/download/download_in_progress_dialog_view.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/browser_widget.h"
#include "chrome/browser/ui/views/frame/tab_strip_region_view.h"
#include "chrome/browser/ui/views/side_panel/side_panel.h"
#include "chrome/browser/ui/views/tab_search_bubble_host.h"
#include "chrome/browser/ui/views/tabs/shared/tab_strip_combo_button.h"
#include "chrome/browser/ui/views/toolbar/toolbar_view.h"
#include "chrome/common/pref_names.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/download/public/common/download_item.h"
#include "components/javascript_dialogs/app_modal_dialog_controller.h"
#include "components/javascript_dialogs/app_modal_dialog_view.h"
#include "components/prefs/pref_service.h"
#include "components/sessions/core/session_id.h"
#include "components/tabs/public/tab_interface.h"
#include "components/zoom/zoom_controller.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/download_test_observer.h"
#include "content/public/test/no_renderer_crashes_assertion.h"
#include "content/public/test/slow_download_http_response.h"
#include "content/public/test/test_navigation_observer.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/controllable_http_response.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/base/window_open_disposition.h"
#include "ui/views/interaction/view_subregion_anchor.h"
#include "ui/views/view_observer.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/view_utils.h"
#include "ui/views/window/dialog_delegate.h"
#include "ui/views/widget/widget_observer.h"
#include "url/gurl.h"

@interface BarcReentrantNativeView : NSView
@property(copy) void (^onMove)(NSView*);
@property(copy) void (^onVisibility)(NSView*);
@end
@implementation BarcReentrantNativeView
@synthesize onMove = _onMove;
@synthesize onVisibility = _onVisibility;
- (void)setHidden:(BOOL)hidden {
  [super setHidden:hidden];
  auto callback = self.onVisibility;
  self.onVisibility = nil;
  if (callback)
    callback(self);
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  auto callback = self.onMove;
  self.onMove = nil;
  if (callback)
    callback(self);
}
@end

namespace {
struct NavigationEvent {
  int32_t kind;
  int32_t window;
  std::string url;
  std::string title;
  int32_t error;
  uint32_t flags;
};
class NavigationEvents {
 public:
  ~NavigationEvents() { barc_tab_unobserve(token); }
  static void Receive(void* context, uint64_t observation, int32_t kind,
                      int32_t window, int32_t tab, const char* url,
                      const char* title, int32_t error, uint32_t flags) {
    auto* self = static_cast<NavigationEvents*>(context);
    self->token = observation;
    self->events.push_back({kind, window, url, title, error, flags});
    if (kind == BARC_TAB_INITIAL && self->release_owner) {
      auto* owner = self->release_owner.get();
      barc_tab_unobserve(observation);
      owner->reset();
      return;
    }
    if (self->unsubscribe_initial && kind == BARC_TAB_INITIAL)
      barc_tab_unobserve(observation);
    if (kind == BARC_TAB_STARTED && self->transfer_destination) {
      EXPECT_EQ(0, barc_tab_transfer(window, tab, self->transfer_destination));
      self->transfer_refused = true;
    }
    if (kind == BARC_TAB_STARTED &&
        (self->close_started || self->close_window_started)) {
      if (self->unsubscribe_before_close)
        barc_tab_unobserve(observation);
      EXPECT_EQ(1, self->close_window_started ? barc_window_close(window)
                                            : barc_tab_close(window, tab));
    }
    if (kind == BARC_TAB_STATE && self->commands_on_audio_state &&
        (flags & BARC_TAB_MUTED)) {
      self->commands_on_audio_state = false;
      EXPECT_EQ(0, barc_tab_execute_command(window, tab, BARC_PAGE_ZOOM_IN));
      EXPECT_EQ(0, barc_tab_set_muted(window, tab, 0));
      self->audio_commands_refused = true;
      if (self->close_on_audio_state)
        EXPECT_EQ(1, barc_tab_close(window, tab));
    }
    if (kind == BARC_TAB_CLOSE_CANCELLED) {
      if (self->retry_cancelled) {
        self->retry_cancelled = false;
        EXPECT_EQ(1, barc_tab_close(window, tab));
      } else if (self->unsubscribe_cancelled) {
        barc_tab_unobserve(observation);
      }
    }
    if (kind == BARC_TAB_CLOSED) {
      barc_tab_unobserve(observation);
      EXPECT_EQ(0u, barc_tab_observe(window, tab, Receive, context));
      if (self->on_closed)
        std::move(self->on_closed).Run();
    }
  }
  size_t Count(int32_t kind) const {
    return std::count_if(events.begin(), events.end(),
                        [kind](const auto& e) { return e.kind == kind; });
  }
  base::OnceClosure on_closed;
  uint64_t token = 0;
  raw_ptr<std::unique_ptr<NavigationEvents>> release_owner = nullptr;
  bool unsubscribe_initial = false;
  bool close_started = false;
  bool close_window_started = false;
  bool unsubscribe_before_close = false;
  int32_t transfer_destination = 0;
  bool transfer_refused = false;
  bool commands_on_audio_state = false;
  bool audio_commands_refused = false;
  bool close_on_audio_state = false;
  bool retry_cancelled = false;
  bool unsubscribe_cancelled = false;
  std::vector<NavigationEvent> events;
};

// Preempt only after acceptance has started dismissing this exact warning.
class PreemptOnDownloadWarningDismissal : public views::WidgetObserver {
 public:
  PreemptOnDownloadWarningDismissal(views::Widget* warning,
                                    base::OnceClosure preempt)
      : preempt_(std::move(preempt)) {
    observation_.Observe(warning);
  }
  void OnWidgetVisibilityChanged(views::Widget*, bool visible) override {
    if (!visible) Preempt();
  }
  void OnWidgetDestroying(views::Widget*) override { Preempt(); }
 private:
  void Preempt() {
    observation_.Reset();
    if (preempt_) std::move(preempt_).Run();
  }
  base::OnceClosure preempt_;
  base::ScopedObservation<views::Widget, views::WidgetObserver> observation_{this};
};

class ViewOwnerDeletionObserver : public views::ViewObserver {
 public:
  ViewOwnerDeletionObserver(BrowserWindowInterface* browser, BrowserView* view)
      : browser_(browser) {
    observation_.Observe(view);
  }
  void OnViewIsDeleting(views::View*) override {
    EXPECT_EQ(nullptr, BrowserView::Get(browser_->GetUnownedUserDataHost()));
    EXPECT_EQ(nullptr, BrowserView::GetBrowserViewForBrowser(browser_));
    observation_.Reset();
    browser_ = nullptr;
    deleted_ = true;
  }
  bool deleted() const { return deleted_; }

 private:
  raw_ptr<BrowserWindowInterface> browser_;
  bool deleted_ = false;
  base::ScopedObservation<views::View, views::ViewObserver> observation_{this};
};
// Close a separate destination during the source's actual removal notification.
class CloseTransferDestination : public TabStripModelObserver {
 public:
  CloseTransferDestination(TabStripModel* source, int32_t destination)
      : destination_(destination) {
    source->AddObserver(this);
  }
  void OnTabStripModelChanged(TabStripModel*,
                              const TabStripModelChange& change,
                              const TabStripSelectionChange&) override {
    if (change.type() == TabStripModelChange::kRemoved && !called_) {
      called_ = true;
      EXPECT_EQ(1, barc_window_close(destination_));
    }
  }
  bool called() const { return called_; }

 private:
  const int32_t destination_;
  bool called_ = false;
};
}  // namespace

class BarcBridgeBrowserTest : public InProcessBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-native-shell");
  }
};

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, NativeShellRetainedUntilDetach) {
  const int32_t window = browser()->GetSessionID().id();
  auto* view = BrowserView::GetBrowserViewForBrowser(browser());
  ASSERT_NE(nullptr, view->barc_native_shell());
  __weak NSView* attached = nil;
  @autoreleasepool {
    NSView* replacement =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
    attached = replacement;
    ASSERT_EQ(1, barc_window_attach_native_shell(window,
                                                 (__bridge void*)replacement));
  }
  @autoreleasepool {
    EXPECT_NE(nil, attached);
    EXPECT_EQ(barc::kNativeShellWidth, barc::NativeShellWidth(view));
    ASSERT_EQ(1, barc_window_attach_native_shell(window, nullptr));
  }
  EXPECT_EQ(nil, attached);
  EXPECT_EQ(0, barc::NativeShellWidth(view));
  EXPECT_EQ(0, barc_window_attach_native_shell(-1, nullptr));

  const int32_t empty_peer = barc_window_new_peer(window);
  ASSERT_GT(empty_peer, 0);
  auto* peer = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(empty_peer));
  ui_test_utils::BrowserDestroyedObserver peer_closed(peer);
  EXPECT_EQ(0, barc_tab_create(empty_peer, "not a valid URL", 1));
  EXPECT_EQ(1, barc_window_close(empty_peer));
  peer_closed.Wait();
  EXPECT_EQ(0, barc_window_close(empty_peer));
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, NativeAttachReentrantCallbacks) {
  const int32_t primary = browser()->GetSessionID().id();
  auto* primary_view = BrowserView::GetBrowserViewForBrowser(browser());
  auto* popup = CreateBrowserWindow(BrowserWindowCreateParams(
      BrowserWindowInterface::TYPE_POPUP, browser()->GetProfile(), true));
  ASSERT_TRUE(popup);
  const int32_t popup_id = popup->GetSessionID().id();
  ASSERT_EQ(nullptr, BrowserView::GetBrowserViewForBrowser(popup)->barc_native_shell());
  EXPECT_EQ(0, barc_window_native_shell_is_owned(popup_id, nullptr));
  ui_test_utils::BrowserDestroyedObserver popup_closed(popup);
  ASSERT_EQ(1, barc_window_close(popup_id));
  popup_closed.Wait();
  BarcReentrantNativeView* shell = [[BarcReentrantNativeView alloc] init];
  NSView* nested = [[NSView alloc] init];
  shell.onMove = ^(NSView*) {
    EXPECT_EQ(0, barc_window_attach_native_shell(primary, (__bridge void*)nested));
    EXPECT_EQ(1, barc_window_select(primary));
  };
  ASSERT_EQ(1, barc_window_attach_native_shell(primary, (__bridge void*)shell));
  EXPECT_EQ(shell, primary_view->barc_native_shell()->native_view().GetNativeNSView());
  EXPECT_EQ(1, barc_window_native_shell_is_owned(primary, (__bridge void*)shell));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(primary, (__bridge void*)nested));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(primary, nullptr));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(-1, (__bridge void*)shell));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(-1, nullptr));
  EXPECT_EQ(0, barc_window_detach_native_shell_if_owned(primary, (__bridge void*)nested));
  EXPECT_EQ(0, barc_window_detach_native_shell_if_owned(primary, nullptr));
  EXPECT_EQ(0, barc_window_detach_native_shell_if_owned(-1, (__bridge void*)shell));
  EXPECT_EQ(shell, primary_view->barc_native_shell()->native_view().GetNativeNSView());
  EXPECT_EQ(1, barc_window_detach_native_shell_if_owned(primary, (__bridge void*)shell));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(primary, (__bridge void*)shell));
  EXPECT_EQ(1, barc_window_native_shell_is_owned(primary, nullptr));
  EXPECT_EQ(0, barc_window_detach_native_shell_if_owned(primary, nullptr));
  EXPECT_EQ(1, barc_window_native_shell_is_owned(primary, nullptr));
  EXPECT_EQ(1, barc_window_attach_native_shell(primary, (__bridge void*)nested));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(primary, (__bridge void*)shell));
  EXPECT_EQ(1, barc_window_native_shell_is_owned(primary, (__bridge void*)nested));
  EXPECT_EQ(0, barc_window_detach_native_shell_if_owned(primary, (__bridge void*)shell));
  EXPECT_EQ(1, barc_window_native_shell_is_owned(primary, (__bridge void*)nested));
  EXPECT_EQ(1, barc_window_attach_native_shell(primary, (__bridge void*)shell));
  shell.onMove = ^(NSView*) {
    EXPECT_EQ(0, barc_window_attach_native_shell(primary, (__bridge void*)nested));
  };
  ASSERT_EQ(1, barc_window_attach_native_shell(primary, nullptr));
  EXPECT_FALSE(primary_view->barc_native_shell()->native_view());

  // Raw Cocoa close bypasses C-ABI close deferral during both reparenting
  // and the NativeViewHost visibility callout.
  for (bool close_on_visibility : {false, true}) {
    const int32_t peer = barc_window_new_peer(primary);
    ASSERT_GT(peer, 0);
    ASSERT_NE(0, barc_tab_create(peer, "about:blank", 0));
    auto* owner = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
        SessionID::FromSerializedValue(peer));
    auto alive = owner->GetWeakPtr();
    auto* peer_view = BrowserView::GetBrowserViewForBrowser(owner);
    auto view_alive = peer_view->GetAsWeakPtr();
    NSWindow* native_window = peer_view->GetWidget()->GetNativeWindow().GetNativeNSWindow();
    BarcReentrantNativeView* closing = [[BarcReentrantNativeView alloc] init];
    if (close_on_visibility)
      closing.onVisibility = ^(NSView*) { [native_window close]; };
    else
      closing.onMove = ^(NSView*) { [native_window close]; };
    EXPECT_EQ(0, barc_window_attach_native_shell(peer, (__bridge void*)closing));
    EXPECT_FALSE(view_alive);
    ASSERT_TRUE(base::test::RunUntil([&] { return !alive; }));
    EXPECT_NE(nullptr, primary_view->barc_native_shell());
  }
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, ClosedDistinguishesOwnerShutdown) {
  const int32_t primary = browser()->GetSessionID().id();
  for (int close_kind : {0, 1, 2, 3}) {
    SCOPED_TRACE(close_kind);
    const int32_t peer = barc_window_new_peer(primary);
    ASSERT_GT(peer, 0);
    const int32_t tab = barc_tab_create(peer, "about:blank", 0);
    ASSERT_NE(0, tab);
    NavigationEvents events;
    ASSERT_NE(0u, barc_tab_observe(peer, tab, NavigationEvents::Receive, &events));
    if (close_kind == 0) {
      ASSERT_EQ(1, barc_tab_close(peer, tab));
    } else if (close_kind == 1) {
      ASSERT_TRUE(content::ExecJs(tabs::TabHandle(tab).Get()->GetContents(),
                                  "window.close();"));
    } else if (close_kind == 2) {
      ASSERT_EQ(1, barc_window_close(peer));
    } else {
      auto* owner = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
          SessionID::FromSerializedValue(peer));
      [owner->GetWindow()->GetNativeWindow().GetNativeNSWindow() close];
    }
    ASSERT_TRUE(base::test::RunUntil([&] { return events.Count(BARC_TAB_CLOSED) == 1; }));
    const auto terminal = std::find_if(events.events.begin(), events.events.end(),
        [](const auto& event) { return event.kind == BARC_TAB_CLOSED; });
    ASSERT_NE(events.events.end(), terminal);
    EXPECT_EQ(close_kind >= 2, !!(terminal->flags & BARC_TAB_OWNER_ENDED));
  }
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       LastTabTransferAndCompletedClose) {
  // Keep the primary test window alive throughout both last-tab window closes.
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL first_url = embedded_test_server()->GetURL("/title1.html");
  const GURL second_url = embedded_test_server()->GetURL("/title2.html");
  const int32_t primary = browser()->GetSessionID().id();
  const int32_t source = barc_window_new_peer(primary);
  ASSERT_GT(source, 0);
  const int32_t page = barc_tab_create(source, first_url.spec().c_str(), 1);
  ASSERT_NE(0, page);
  auto* contents = tabs::TabHandle(page).Get()->GetContents();
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  {
    content::TestNavigationObserver navigated(contents);
    ASSERT_EQ(1, barc_tab_navigate(source, page, second_url.spec().c_str()));
    navigated.Wait();
  }
  ASSERT_EQ(second_url, contents->GetLastCommittedURL());
  const int history_entries = contents->GetController().GetEntryCount();
  ASSERT_GE(history_entries, 2);
  ASSERT_TRUE(content::ExecJs(contents,
                              "window.marker = 'original document';"
                              "document.body.innerHTML = '<input id=draft>';"));
  ASSERT_TRUE(content::ExecJs(
      contents,
      "document.querySelector('#draft').value = 'unsaved draft';"
      "document.body.style.height = '6000px'; window.scrollTo(0, 1200);"));
  ASSERT_EQ(1200, content::EvalJs(contents, "window.scrollY"));

  const int32_t destination = barc_window_new_peer(primary);
  ASSERT_GT(destination, 0);
  auto* collection = GlobalBrowserCollection::GetInstance();
  auto* source_browser =
      collection->FindBrowserWithID(SessionID::FromSerializedValue(source));
  ui_test_utils::BrowserDestroyedObserver source_closed(source_browser);
  ASSERT_EQ(1, barc_tab_transfer(source, page, destination));
  source_closed.Wait();
  EXPECT_EQ(nullptr, collection->FindBrowserWithID(
                         SessionID::FromSerializedValue(source)));
  ASSERT_NE(nullptr, tabs::TabHandle(page).Get());
  EXPECT_EQ(contents, tabs::TabHandle(page).Get()->GetContents());
  EXPECT_EQ("original document", content::EvalJs(contents, "window.marker"));
  EXPECT_EQ(
      "unsaved draft",
      content::EvalJs(contents, "document.querySelector('#draft').value"));
  EXPECT_EQ(1200, content::EvalJs(contents, "window.scrollY"));
  EXPECT_EQ(history_entries, contents->GetController().GetEntryCount());
  EXPECT_TRUE(contents->GetController().CanGoBack());
  {
    content::TestNavigationObserver went_back(contents);
    contents->GetController().GoBack();
    went_back.Wait();
  }
  EXPECT_EQ(first_url, contents->GetLastCommittedURL());
  EXPECT_EQ(0, barc_tab_select(source, page));
  EXPECT_EQ(0, barc_tab_navigate(primary, page, "about:blank"));
  EXPECT_EQ(1, barc_tab_select(destination, page));

  auto* destination_browser = collection->FindBrowserWithID(
      SessionID::FromSerializedValue(destination));
  ui_test_utils::BrowserDestroyedObserver destination_closed(
      destination_browser);
  content::WebContentsDestroyedWatcher document_destroyed(contents);
  ASSERT_EQ(1, barc_tab_close(destination, page));
  document_destroyed.Wait();
  destination_closed.Wait();
  EXPECT_EQ(nullptr, tabs::TabHandle(page).Get());
  EXPECT_EQ(0, barc_tab_close(destination, page));
  EXPECT_EQ(0, barc_tab_create(source, "about:blank", 1));
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       LastTabTransferCancellationRetainsLiveSource) {
  const int32_t primary = browser()->GetSessionID().id();
  const int32_t source_id = barc_window_new_peer(primary);
  const int32_t destination_id = barc_window_new_peer(primary);
  ASSERT_GT(source_id, 0);
  ASSERT_GT(destination_id, 0);
  const int32_t page = barc_tab_create(source_id, "about:blank", 1);
  ASSERT_NE(0, page);
  auto* contents = tabs::TabHandle(page).Get()->GetContents();
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  ASSERT_TRUE(content::ExecJs(contents,
                              "window.liveMarker = 'retained';"
                              "document.body.innerHTML = '<input id=draft>';"
                              "draft.value = 'unsaved';"));
  auto* source = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(source_id));
  ASSERT_NE(nullptr, source);
  auto* strip = source->GetTabStripModel();
  CloseTransferDestination cancellation(strip, destination_id);
  EXPECT_EQ(0, barc_tab_transfer(source_id, page, destination_id));
  ASSERT_TRUE(cancellation.called());
  ASSERT_EQ(source, GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
                        SessionID::FromSerializedValue(source_id)));
  EXPECT_FALSE(source->IsDeleteScheduled());
  EXPECT_FALSE(
      UnloadController::From(source)->is_attempting_to_close_browser());
  ASSERT_EQ(1, strip->count());
  ASSERT_NE(nullptr, tabs::TabHandle(page).Get());
  EXPECT_EQ(contents, tabs::TabHandle(page).Get()->GetContents());
  EXPECT_EQ(contents, strip->GetActiveWebContents());
  EXPECT_EQ("retained", content::EvalJs(contents, "liveMarker"));
  EXPECT_EQ("unsaved", content::EvalJs(contents, "draft.value"));
  EXPECT_EQ(1, barc_tab_select(source_id, page));
  const int32_t extra = barc_tab_create(source_id, "about:blank", 0);
  EXPECT_NE(0, extra);
  EXPECT_EQ(contents, strip->GetActiveWebContents());
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       BackgroundTransferCancellationPreservesSelectionAndPin) {
  const int32_t primary = browser()->GetSessionID().id();
  const int32_t source_id = barc_window_new_peer(primary);
  const int32_t destination_id = barc_window_new_peer(primary);
  ASSERT_GT(source_id, 0);
  ASSERT_GT(destination_id, 0);
  const int32_t selected = barc_tab_create(source_id, "about:blank", 1);
  const int32_t background = barc_tab_create(source_id, "about:blank", 0);
  ASSERT_NE(0, selected);
  ASSERT_NE(0, background);
  auto* source = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(source_id));
  ASSERT_NE(nullptr, source);
  auto* strip = source->GetTabStripModel();
  auto* selected_contents = tabs::TabHandle(selected).Get()->GetContents();
  auto* background_contents = tabs::TabHandle(background).Get()->GetContents();
  ASSERT_TRUE(content::WaitForLoadStop(background_contents));
  strip->SetTabPinned(strip->GetIndexOfWebContents(background_contents), true);
  ASSERT_EQ(selected_contents, strip->GetActiveWebContents());
  CloseTransferDestination cancellation(strip, destination_id);
  EXPECT_EQ(0, barc_tab_transfer(source_id, background, destination_id));
  ASSERT_TRUE(cancellation.called());
  EXPECT_FALSE(source->IsDeleteScheduled());
  EXPECT_FALSE(
      UnloadController::From(source)->is_attempting_to_close_browser());
  ASSERT_EQ(2, strip->count());
  ASSERT_NE(nullptr, tabs::TabHandle(background).Get());
  EXPECT_EQ(background_contents,
            tabs::TabHandle(background).Get()->GetContents());
  EXPECT_EQ(selected_contents, strip->GetActiveWebContents());
  const int restored = strip->GetIndexOfWebContents(background_contents);
  ASSERT_NE(TabStripModel::kNoTab, restored);
  EXPECT_TRUE(strip->IsTabPinned(restored));
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, BrowserLookupUsesLogicalOwner) {
  EXPECT_EQ(nullptr, BrowserView::GetBrowserViewForBrowser(nullptr));
  using Result = base::test::TestFuture<barc_profile_status, int32_t>;
  Result opened;
  barc_profile_open_window(
      "b482ffdf-5bb1-4f77-b176-12f17ae8f1af", BARC_PROFILE_SETTINGS,
      [](barc_profile_status status, int32_t window, void* data) {
        static_cast<Result*>(data)->SetValue(status, window);
      },
      &opened);
  ASSERT_EQ(BARC_PROFILE_OK, opened.Get<0>());
  const int32_t peer_id = opened.Get<1>();
  auto* peer = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(peer_id));
  ASSERT_NE(nullptr, peer);
  EXPECT_NE(browser()->GetProfile(), peer->GetProfile());
  auto* first_view = BrowserView::GetBrowserViewForBrowser(browser());
  auto* peer_view = BrowserView::GetBrowserViewForBrowser(peer);
  ASSERT_NE(nullptr, first_view);
  ASSERT_NE(nullptr, peer_view);
  ASSERT_NE(first_view, peer_view);
  auto* widget = first_view->GetWidget();
  void* original =
      widget->GetNativeWindowProperty(BrowserView::kBrowserViewKey);
  // Deliberately conflict physical metadata without sharing/moving widgets.
  // This is a lookup prerequisite regression, not a composition proof.
  widget->SetNativeWindowProperty(BrowserView::kBrowserViewKey, peer_view);
  EXPECT_EQ(peer_view, BrowserView::GetBrowserViewForNativeWindow(
                           widget->GetNativeWindow()));
  EXPECT_EQ(first_view, BrowserView::GetBrowserViewForBrowser(browser()));
  EXPECT_EQ(peer_view, BrowserView::GetBrowserViewForBrowser(peer));
  widget->SetNativeWindowProperty(BrowserView::kBrowserViewKey, original);

  ViewOwnerDeletionObserver view_deleted(peer, peer_view);
  ui_test_utils::BrowserDestroyedObserver peer_closed(peer);
  ASSERT_EQ(1, barc_window_close(peer_id));
  peer_closed.Wait();
  EXPECT_TRUE(view_deleted.deleted());
  EXPECT_EQ(0, barc_window_close(peer_id));
  EXPECT_EQ(first_view, BrowserView::GetBrowserViewForBrowser(browser()));
}

// Tests warning policy inputs using real isolated Browser/Profile/download
// objects. This does not establish shared native-window composition.
IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       GroupedOTRDownloadWarningCounting) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      &content::SlowDownloadHttpResponse::HandleSlowDownloadRequest));
  ASSERT_TRUE(embedded_test_server()->Start());
  auto* first = CreateIncognitoBrowser();
  auto* second = CreateIncognitoBrowser();
  ASSERT_EQ(first->GetProfile(), second->GetProfile());
  auto* manager = first->GetProfile()->GetDownloadManager();
  // Lazy OTR download UI initialization resets the prompting preference.
  auto* download_prefs = DownloadPrefs::FromDownloadManager(manager);
  first->GetProfile()->GetPrefs()->SetBoolean(prefs::kPromptForDownload, false);
  ASSERT_EQ(first->GetProfile(), manager->GetBrowserContext());
  ASSERT_FALSE(first->GetProfile()->GetPrefs()->GetBoolean(
      prefs::kPromptForDownload));
  ASSERT_FALSE(download_prefs->PromptForDownload());
  base::ScopedClosureRunner cleanup(
      base::BindLambdaForTesting([profile = first->GetProfile()->GetWeakPtr()] {
        if (!profile) {
          return;
        }
        content::DownloadManager::DownloadVector items;
        profile->GetDownloadManager()->GetAllDownloads(&items);
        for (const auto& item : items) {
          item->Cancel(/*user_cancel=*/true);
        }
      }));
  content::DownloadTestObserverInProgress progress(manager, 1);
  ui_test_utils::NavigateToURLWithDisposition(
      first,
      embedded_test_server()->GetURL(
          content::SlowDownloadHttpResponse::kKnownSizeUrl),
      WindowOpenDisposition::CURRENT_TAB, ui_test_utils::BROWSER_TEST_NO_WAIT);
  progress.WaitForFinished();
  ASSERT_EQ(1u, progress.NumDownloadsSeenInState(
                    download::DownloadItem::IN_PROGRESS));
  auto* controller = UnloadController::From(first);
  int count = -1;
  EXPECT_EQ(UnloadController::DownloadCloseType::kOk,
            controller->OkToCloseWithInProgressDownloads(&count));
  EXPECT_EQ(0, count);
  std::array<BrowserWindowInterface*, 2> group{first, second};
  EXPECT_EQ(UnloadController::DownloadCloseType::kLastWindowInIncognitoProfile,
            controller->OkToCloseWithInProgressDownloads(&count, group));
  EXPECT_EQ(1, count);
  auto* third = CreateIncognitoBrowser();
  ASSERT_EQ(first->GetProfile(), third->GetProfile());
  EXPECT_EQ(UnloadController::DownloadCloseType::kOk,
            controller->OkToCloseWithInProgressDownloads(&count, group));
  EXPECT_EQ(0, count);
  bool warned = false;
  EXPECT_EQ(UnloadController::WarnBeforeClosingResult::kOkToClose,
            UnloadController::From(browser())->MaybeWarnBeforeClosing(
                base::BindLambdaForTesting(
                    [&](UnloadController::WarnBeforeClosingResult) {
                      warned = true;
                    }),
                group));
  EXPECT_FALSE(warned);  // Regular macOS downloads continue after window close.
}

namespace {
constexpr char kSharedWork[] = "b482ffdf-5bb1-4f77-b176-12f17ae8f1af";
constexpr char kSharedPersonal[] = "c9c590de-4a1c-44ae-b110-ddf377cba483";
using SharedProfileResult =
    base::test::TestFuture<barc_profile_status, int32_t>;
void SharedProfileCompleted(barc_profile_status status,
                            int32_t window,
                            void* data) {
  static_cast<SharedProfileResult*>(data)->SetValue(status, window);
}
struct ReleasedProfileRequest {
  raw_ptr<SharedProfileResult> result;
  raw_ptr<std::unique_ptr<ReleasedProfileRequest>> owner;
  static void Completed(barc_profile_status status, int32_t window, void* data) {
    auto* request = static_cast<ReleasedProfileRequest*>(data);
    auto* owner = request->owner.get();
    request->result->SetValue(status, window);
    owner->reset();
  }
};
BrowserWindowInterface* SharedWindow(int32_t id) {
  return GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(id));
}

class RedirectNativeSelection : public TabStripModelObserver {
 public:
  RedirectNativeSelection(TabStripModel* strip, int32_t target)
      : target_(target) {
    strip->AddObserver(this);
  }
  void Arm() { armed_ = true; }
  void OnTabStripModelChanged(TabStripModel*,
                              const TabStripModelChange&,
                              const TabStripSelectionChange&) override {
    if (armed_) {
      armed_ = false;
      EXPECT_EQ(1, barc_window_select(target_));
    }
  }

 private:
  const int32_t target_;
  bool armed_ = false;
};
}  // namespace

class BarcSharedNativeWindowBrowserTest : public BarcBridgeBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    BarcBridgeBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-shared-native-window");
  }

 protected:
  int32_t Open(const char* uuid,
               int32_t owner = 0,
               barc_profile_destination destination = BARC_PROFILE_SETTINGS) {
    SharedProfileResult result;
    if (owner) {
      barc_profile_open_in_native_window(owner, uuid, destination,
                                         SharedProfileCompleted, &result);
    } else {
      barc_profile_open_window(uuid, destination, SharedProfileCompleted,
                               &result);
    }
    EXPECT_FALSE(result.IsReady());
    EXPECT_EQ(BARC_PROFILE_OK, result.Get<0>());
    return result.Get<1>();
  }
  void Navigate(BrowserWindowInterface* window, const GURL& url) {
    auto* contents = window->GetTabStripModel()->GetActiveWebContents();
    content::TestNavigationObserver navigated(contents);
    ASSERT_EQ(
        1, barc_tab_navigate(window->GetSessionID().id(),
                             barc_window_tab_at(window->GetSessionID().id(), 0),
                             url.spec().c_str()));
    navigated.Wait();
    ASSERT_TRUE(content::WaitForLoadStop(contents));
  }
};

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       PageCommandsRequireExactActiveOwnerAndRespectPolicy) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  const int32_t work_tab = barc_window_tab_at(work_id, 0);
  const int32_t background = barc_tab_create(work_id, "about:blank", 0);
  ASSERT_GT(background, 0);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  ASSERT_GT(personal_id, 0);
  ASSERT_EQ(1, barc_tab_select(personal_id, barc_window_tab_at(personal_id, 0)));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_IN));
  ASSERT_EQ(1, barc_tab_select(work_id, work_tab));
  EXPECT_EQ(0, barc_tab_execute_command(personal_id, work_tab, BARC_PAGE_ZOOM_IN));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, background, BARC_PAGE_ZOOM_IN));
  EXPECT_EQ(0, barc_tab_execute_command(-1, work_tab, BARC_PAGE_FIND));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, -1));
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  auto* zoom = zoom::ZoomController::FromWebContents(contents);
  ASSERT_TRUE(zoom);
  const double initial_zoom = zoom->GetZoomLevel();
  ASSERT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_IN));
  EXPECT_GT(zoom->GetZoomLevel(), initial_zoom);
  EXPECT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_OUT));
  EXPECT_DOUBLE_EQ(initial_zoom, zoom->GetZoomLevel());
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_RESET));
  ASSERT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_IN));
  EXPECT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_RESET));
  EXPECT_DOUBLE_EQ(initial_zoom, zoom->GetZoomLevel());
  ASSERT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_FIND));
  EXPECT_TRUE(FindBarController::From(work)->find_bar()->IsFindBarVisible());
  EXPECT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_FIND_NEXT));
  EXPECT_EQ(1, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_FIND_PREVIOUS));
  auto* commands = chrome::BrowserCommandController::From(work);
  commands->UpdateCommandEnabled(IDC_FIND, false);
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_FIND));
  commands->UpdateCommandEnabled(IDC_FIND, true);
  work->GetProfile()->GetPrefs()->SetBoolean(prefs::kPrintingEnabled, false);
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_PRINT));
  work->GetProfile()->GetPrefs()->SetInteger(
      prefs::kDevToolsAvailability,
      static_cast<int>(policy::DeveloperToolsAvailability::kDisallowed));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_DEVTOOLS));
  // The old window/tab pair cannot act on a same-profile transferred document.
  const int32_t peer = barc_window_new_peer(work_id);
  ASSERT_GT(peer, 0);
  ASSERT_EQ(1, barc_tab_transfer(work_id, work_tab, peer));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, work_tab, BARC_PAGE_ZOOM_IN));
  EXPECT_EQ(1, barc_tab_execute_command(peer, work_tab, BARC_PAGE_ZOOM_IN));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       BackgroundTabMuteReportsActualStateWithoutSelection) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t active_tab = barc_window_tab_at(work_id, 0);
  const int32_t background = barc_tab_create(work_id, "about:blank", 0);
  ASSERT_GT(background, 0);
  const int32_t personal_id = Open(kSharedPersonal, work_id, BARC_PROFILE_BLANK);
  const int32_t personal_tab = barc_window_tab_at(personal_id, 0);
  ASSERT_EQ(1, barc_tab_select(personal_id, personal_tab));
  auto* contents = tabs::TabHandle(background).Get()->GetContents();
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, background, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  ASSERT_FALSE(events.events.empty());
  EXPECT_EQ(contents->IsAudioMuted(), (events.events.back().flags & BARC_TAB_MUTED) != 0);
  EXPECT_EQ(contents->IsCurrentlyAudible(), (events.events.back().flags & BARC_TAB_AUDIBLE) != 0);
  const auto count = events.Count(BARC_TAB_STATE);
  EXPECT_EQ(0, barc_tab_set_muted(personal_id, background, 1));
  EXPECT_EQ(0, barc_tab_set_muted(work_id, background, 2));
  EXPECT_EQ(0, barc_tab_set_muted(-1, background, 1));
  ASSERT_EQ(1, barc_tab_set_muted(work_id, background, 1));
  EXPECT_TRUE(contents->IsAudioMuted());
  EXPECT_EQ(TabMutedReason::kAudioIndicator, GetTabAudioMutedReason(contents));
  EXPECT_GT(events.Count(BARC_TAB_STATE), count);
  EXPECT_NE(0u, events.events.back().flags & BARC_TAB_MUTED);
  ASSERT_EQ(1, barc_tab_set_muted(work_id, background, 0));
  EXPECT_FALSE(contents->IsAudioMuted());
  EXPECT_EQ(0u, events.events.back().flags & BARC_TAB_MUTED);
  EXPECT_EQ(active_tab, work->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
  EXPECT_EQ(personal_tab, SharedWindow(personal_id)->GetTabStripModel()->GetActiveTab()->GetHandle().raw_value());
  EXPECT_TRUE(SharedWindow(personal_id)->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
  // A transferred background tab retains its observer and explicit identity.
  const int32_t peer = barc_window_new_peer(work_id);
  ASSERT_GT(peer, 0);
  ASSERT_EQ(1, barc_tab_transfer(work_id, background, peer));
  EXPECT_EQ(0, barc_tab_set_muted(work_id, background, 1));
  EXPECT_EQ(1, barc_tab_set_muted(peer, background, 1));
  EXPECT_EQ(peer, events.events.back().window);
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       AudioCallbackCannotRetargetCommandsDuringClose) {
  const int32_t work_id = Open(kSharedWork, 0, BARC_PROFILE_BLANK);
  const int32_t active = barc_window_tab_at(work_id, 0);
  const int32_t background = barc_tab_create(work_id, "about:blank", 0);
  ASSERT_GT(background, 0);
  ASSERT_EQ(1, barc_tab_select(work_id, active));
  auto* contents = tabs::TabHandle(background).Get()->GetContents();
  auto weak_contents = contents->GetWeakPtr();
  NavigationEvents events;
  events.token = barc_tab_observe(work_id, background, NavigationEvents::Receive, &events);
  ASSERT_NE(0u, events.token);
  events.commands_on_audio_state = true;
  events.close_on_audio_state = true;
  EXPECT_EQ(1, barc_tab_set_muted(work_id, background, 1));
  EXPECT_TRUE(events.audio_commands_refused);
  ASSERT_TRUE(base::test::RunUntil([&] { return events.Count(BARC_TAB_CLOSED) == 1; }));
  ASSERT_TRUE(base::test::RunUntil([&] { return !weak_contents; }));
  EXPECT_EQ(active, barc_window_tab_at(work_id, 0));
  EXPECT_EQ(0, barc_tab_set_muted(work_id, background, 0));
  EXPECT_EQ(0, barc_tab_execute_command(work_id, background, BARC_PAGE_FIND));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       ProfilesShareNativeWindowAndRetainLivePage) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  auto* work_contents = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(work_contents));
  EXPECT_EQ(true, content::EvalJs(
                      work_contents,
                      "customElements.whenDefined('settings-ui').then(() => "
                      "!!document.querySelector('settings-ui').shadowRoot."
                      "querySelector('settings-main'))"));
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  const int32_t work_peer_id =
      Open(kSharedWork, work_id, BARC_PROFILE_EXTENSIONS);
  auto* work_peer = SharedWindow(work_peer_id);
  ASSERT_TRUE(work_peer);
  auto* view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  auto* peer_view = BrowserView::GetBrowserViewForBrowser(work_peer);
  auto* host = view->browser_widget();
  const auto native_window = host->GetNativeWindow();
  auto* work_frame = view->parent();
  EXPECT_EQ(host, personal_view->browser_widget());
  EXPECT_EQ(host, peer_view->browser_widget());
  EXPECT_EQ(native_window, personal->GetWindow()->GetNativeWindow());
  EXPECT_EQ(native_window, work_peer->GetWindow()->GetNativeWindow());
  EXPECT_NE(work->GetProfile(), personal->GetProfile());
  EXPECT_EQ(work->GetProfile(), work_peer->GetProfile());
  EXPECT_NE(view, personal_view);
  EXPECT_NE(view->parent(), personal_view->parent());
  work->GetProfile()->GetPrefs()->SetBoolean(prefs::kShowHomeButton, true);
  personal->GetProfile()->GetPrefs()->SetBoolean(prefs::kShowHomeButton, false);
  auto* personal_contents =
      personal->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(personal_contents));
  EXPECT_EQ(false,
            content::EvalJs(personal_contents,
                            "new "
                            "Promise(r=>chrome.settingsPrivate.getPref('"
                            "browser.show_home_button',p=>r(p.value)))"));
  auto* extensions = work_peer->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(extensions));
  EXPECT_EQ("object",
            content::EvalJs(extensions, "typeof chrome.developerPrivate"));
  EXPECT_EQ(work->GetProfile(), extensions->GetBrowserContext());
  ASSERT_NO_FATAL_FAILURE(
      Navigate(work, embedded_test_server()->GetURL("/title1.html")));
  ASSERT_EQ(1, barc_window_select(work_id));
  ASSERT_TRUE(content::ExecJs(
      work_contents,
      "window.nativeMarker='original'; document.body.innerHTML='<input "
      "id=draft>';"
      "draft.value='retained form'; document.body.style.height='6000px';"
      "history.pushState({kept:true},'', '#kept'); window.scrollTo(0,1200);"));
  const int history_count = work_contents->GetController().GetEntryCount();
  ASSERT_EQ(1200, content::EvalJs(work_contents, "scrollY"));
  for (int i = 0; i < 3; ++i) {
    ASSERT_EQ(1, barc_window_select(personal_id));
    EXPECT_EQ(personal,
              GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                  native_window));
    ASSERT_TRUE(base::test::RunUntil([&] {
      return content::EvalJs(personal_contents, "document.visibilityState")
                 .ExtractString() == "visible";
    }));
    ASSERT_TRUE(base::test::RunUntil([&] {
      return content::EvalJs(work_contents, "document.visibilityState")
                 .ExtractString() == "hidden";
    }));
    ASSERT_EQ(1, barc_window_select(work_id));
    EXPECT_EQ(work,
              GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                  native_window));
    ASSERT_TRUE(base::test::RunUntil([&] {
      return content::EvalJs(work_contents, "document.visibilityState")
                 .ExtractString() == "visible";
    }));
    EXPECT_EQ(work_contents, work->GetTabStripModel()->GetActiveWebContents());
    EXPECT_EQ(work_frame, view->parent());
    EXPECT_EQ(host, view->GetWidget());
    EXPECT_EQ("original", content::EvalJs(work_contents, "nativeMarker"));
    EXPECT_EQ("retained form", content::EvalJs(work_contents, "draft.value"));
    EXPECT_EQ(1200, content::EvalJs(work_contents, "scrollY"));
    EXPECT_EQ(history_count, work_contents->GetController().GetEntryCount());
  }
  host->Deactivate();
  EXPECT_EQ(work, GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                      native_window));
  host->Hide();
  EXPECT_EQ(work, GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                      native_window));
  ASSERT_EQ(1, barc_window_select(personal_id));
  EXPECT_EQ(personal,
            GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                native_window));
  host->Show();
  ASSERT_EQ(1, barc_tab_select(work_id, barc_window_tab_at(work_id, 0)));
  EXPECT_TRUE(work->IsSelectedForNativeWindow());
  EXPECT_FALSE(personal->IsSelectedForNativeWindow());
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       InactiveOwnerCloseTransfersPhysicalLifetime) {
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  ASSERT_TRUE(work_view);
  ASSERT_TRUE(personal_view);
  EXPECT_EQ(work_view->GetWidget(), personal_view->GetWidget());
  for (auto* view : {work_view, personal_view}) {
    auto* combo = views::AsViewClass<TabStripComboButton>(
        view->tab_strip_view()->GetViewByElementId(
            kTabStripComboButtonElementId));
    ASSERT_TRUE(combo);
    auto* bubble_host = view->GetTabSearchBubbleHost();
    ASSERT_TRUE(bubble_host);
    EXPECT_EQ(view->browser(), bubble_host->GetBrowser());
    ASSERT_TRUE(view->side_panel());
    EXPECT_TRUE(view->Contains(view->side_panel()));
    auto* anchor = view->GetFallbackPopupAnchor();
    ASSERT_TRUE(anchor);
    auto* subregion = anchor->AsA<views::ViewSubregionAnchor>();
    ASSERT_TRUE(subregion);
    EXPECT_EQ(view, &subregion->view());
    auto* menu_button = views::AsViewClass<AppMenuButton>(
        view->toolbar()->GetViewByElementId(kToolbarAppMenuButtonElementId));
    ASSERT_TRUE(menu_button);
    const bool was_visible = menu_button->GetVisible();
    menu_button->SetVisible(false);
    EXPECT_FALSE(menu_button->IsDrawn());
    EXPECT_EQ(anchor, menu_button->GetAnchor().GetIfElement());
    menu_button->SetVisible(was_visible);
    EXPECT_TRUE(combo->Contains(bubble_host->button()));
    EXPECT_TRUE(view->Contains(bubble_host->button()));
    auto* other_view = view == work_view ? personal_view : work_view;
    EXPECT_FALSE(other_view->Contains(bubble_host->button()));
    EXPECT_NE(bubble_host, other_view->GetTabSearchBubbleHost());
  }
  auto* host = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  auto* work_contents = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(work_contents);
  // Exercise retained inactive contents that still resolve to the shared host,
  // whose native metadata identifies the selected Personal BrowserView.
  ASSERT_EQ(host, views::Widget::GetTopLevelWidgetForNativeView(
                      work_contents->GetNativeView()));
  ASSERT_EQ(personal_view, BrowserView::GetBrowserViewForNativeWindow(
                               host->GetNativeWindow()));
  EXPECT_EQ(work_view,
            BrowserWindow::FindBrowserWindowWithWebContents(work_contents));
  EXPECT_EQ(personal_view, BrowserWindow::FindBrowserWindowWithWebContents(
                               personal->GetTabStripModel()
                                   ->GetActiveWebContents()));
  auto host_alive = host->GetWeakPtr();
  const auto native_window = host->GetNativeWindow();
  auto* contents = personal->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  ASSERT_TRUE(content::ExecJs(contents, "window.ownerSurvivor='live';"));
  ui_test_utils::BrowserDestroyedObserver work_closed(work);
  ASSERT_EQ(1, barc_window_close(work_id));
  work_closed.Wait();
  ASSERT_TRUE(host_alive);
  EXPECT_EQ(personal,
            GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                native_window));
  EXPECT_EQ("live", content::EvalJs(contents, "ownerSurvivor"));
  EXPECT_EQ(0, barc_window_select(work_id));
  ui_test_utils::BrowserDestroyedObserver personal_closed(personal);
  ASSERT_EQ(1, barc_window_close(personal_id));
  personal_closed.Wait();
  EXPECT_FALSE(host_alive);
  EXPECT_EQ(0, barc_window_close(personal_id));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       ForcedNativeCloseDestroysEveryLogicalBrowser) {
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  auto work_alive = work->GetWeakPtr();
  auto personal_alive = personal->GetWeakPtr();
  auto* host = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  auto host_alive = host->GetWeakPtr();
  NavigationEvents work_events, personal_events;
  ASSERT_NE(0u, barc_tab_observe(work_id, barc_window_tab_at(work_id, 0),
                               NavigationEvents::Receive, &work_events));
  ASSERT_NE(0u, barc_tab_observe(personal_id, barc_window_tab_at(personal_id, 0),
                               NavigationEvents::Receive, &personal_events));
  work_events.on_closed = base::BindLambdaForTesting([&] {
    if (personal_alive) {
      EXPECT_TRUE(UnloadController::From(personal_alive.get())->owner_close_admitted());
      EXPECT_EQ(personal_alive->GetTabStripModel()->count(),
                static_cast<int>(barc_window_tab_count(personal_id)));
    }
  });
  ui_test_utils::BrowserDestroyedObserver work_closed(work);
  ui_test_utils::BrowserDestroyedObserver personal_closed(personal);
  host->CloseNow();
  for (const auto* events : {&work_events, &personal_events}) {
    ASSERT_EQ(1u, events->Count(BARC_TAB_CLOSED));
    const auto terminal = std::find_if(events->events.begin(), events->events.end(),
        [](const auto& event) { return event.kind == BARC_TAB_CLOSED; });
    EXPECT_TRUE(terminal->flags & BARC_TAB_OWNER_ENDED);
  }
  work_closed.Wait();
  personal_closed.Wait();
  EXPECT_FALSE(work_alive);
  EXPECT_FALSE(personal_alive);
  EXPECT_FALSE(host_alive);
  EXPECT_EQ(nullptr, SharedWindow(work_id));
  EXPECT_EQ(nullptr, SharedWindow(personal_id));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       PromptFreePhysicalCloseDoesNotActivateOtherProfiles) {
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  int intermediate_activations = 0;
  auto count = base::BindLambdaForTesting(
      [&](BrowserWindowInterface*) { ++intermediate_activations; });
  auto first =
      BrowserActiveStateManager::From(work)->RegisterDidBecomeActive(count);
  auto second =
      BrowserActiveStateManager::From(personal)->RegisterDidBecomeActive(count);
  auto* host = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  ui_test_utils::BrowserDestroyedObserver work_closed(work);
  ui_test_utils::BrowserDestroyedObserver personal_closed(personal);
  host->Close();
  work_closed.Wait();
  personal_closed.Wait();
  EXPECT_EQ(0, intermediate_activations);
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       TabSelectionRespectsCallbackDrivenProfileChange) {
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  const int32_t target_tab = barc_tab_create(work_id, "about:blank", 0);
  ASSERT_NE(0, target_tab);
  RedirectNativeSelection redirect(work->GetTabStripModel(), personal_id);
  redirect.Arm();
  EXPECT_EQ(0, barc_tab_select(work_id, target_tab));
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
}

namespace {
class ConstructionSessionService : public SessionService {
 public:
  explicit ConstructionSessionService(Profile* profile)
      : SessionService(profile) {}
  void WindowOpened(BrowserWindowInterface* window) override {
    ++opened;
    SessionService::WindowOpened(window);
  }
  void WindowClosed(SessionID window) override {
    ++closed;
    SessionService::WindowClosed(window);
  }
  int opened = 0;
  int closed = 0;
};

class CandidateCreationEvents : public BrowserCollectionObserver {
 public:
  CandidateCreationEvents() {
    observation_.Observe(GlobalBrowserCollection::GetInstance());
  }
  void SetCandidate(int32_t id) { candidate_ = id; }
  void OnBrowserCreated(BrowserWindowInterface* window) override {
    if (window->GetSessionID().id() == candidate_) {
      ++created;
    }
  }
  void OnBrowserClosed(BrowserWindowInterface* window) override {
    if (window->GetSessionID().id() == candidate_) {
      ++closed;
    }
  }
  int created = 0;
  int closed = 0;

 private:
  int32_t candidate_ = 0;
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver>
      observation_{this};
};
}  // namespace

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       FeatureInitHostClosureAbortsUnpublishedBrowser) {
  const int32_t host_id = Open(kSharedWork);
  auto* host = SharedWindow(host_id);
  ASSERT_TRUE(host);
  auto host_alive = host->GetWeakPtr();
  const size_t browsers_before =
      GlobalBrowserCollection::GetInstance()->GetSize();
  auto* manager = g_browser_process->profile_manager();
  base::test::TestFuture<Profile*> initialized;
  manager->CreateProfileAsync(manager->user_data_dir().AppendASCII(
                                  std::string("Barc-") + kSharedPersonal),
                              initialized.GetCallback());
  auto* profile = initialized.Get();
  ASSERT_TRUE(profile);
  auto profile_alive = ScopedProfileKeepAlive::TryAcquire(
      profile, ProfileKeepAliveOrigin::kProfileCreationFlow);
  ASSERT_TRUE(profile_alive);
  auto* sessions =
      SessionServiceFactory::GetInstance()
          ->SetTestingSubclassFactoryAndUse<ConstructionSessionService>(
              profile, base::BindOnce([](content::BrowserContext* context) {
                return std::make_unique<ConstructionSessionService>(
                    Profile::FromBrowserContext(context));
              }));
  ASSERT_TRUE(sessions);
  CandidateCreationEvents events;
  base::WeakPtr<BrowserWindowInterface> candidate_alive;
  int32_t candidate_id = 0;
  bool closed_in_factory = false;
  auto feature_override =
      BrowserWindowFeatures::GetUserDataFactoryForTesting()
          .AddOverrideForTesting<EmbedderBrowserWindowFeatures>(
              base::BindLambdaForTesting(
                  [&](BrowserWindowInterface& candidate) {
                    const auto& params =
                        BrowserInitState::From(&candidate)->create_params();
                    if (params.native_window_owner &&
                        params.native_window_owner->id() == host_id &&
                        !closed_in_factory) {
                      closed_in_factory = true;
                      candidate_id = candidate.GetSessionID().id();
                      candidate_alive = candidate.GetWeakPtr();
                      events.SetCandidate(candidate_id);
                      // Existing production feature factory callout, not a
                      // custom or test-only BrowserWindow. The host dies before
                      // factory admission.
                      BrowserManagerService::SynchronouslyDestroyBrowser(
                          host_alive.get());
                    }
                    return std::make_unique<EmbedderBrowserWindowFeatures>(
                        &candidate);
                  }));
  SharedProfileResult result;
  barc_profile_open_in_native_window(host_id, kSharedPersonal,
                                     BARC_PROFILE_SETTINGS,
                                     SharedProfileCompleted, &result);
  EXPECT_EQ(BARC_PROFILE_UNAVAILABLE, result.Get<0>());
  EXPECT_EQ(0, result.Get<1>());
  EXPECT_TRUE(closed_in_factory);
  EXPECT_FALSE(host_alive);
  EXPECT_FALSE(candidate_alive);
  EXPECT_GT(candidate_id, 0);
  EXPECT_EQ(nullptr, SharedWindow(candidate_id));
  EXPECT_EQ(0, events.created);
  EXPECT_EQ(0, events.closed);
  EXPECT_EQ(0, sessions->opened);
  EXPECT_EQ(0, sessions->closed);
  EXPECT_EQ(browsers_before - 1,
            GlobalBrowserCollection::GetInstance()->GetSize());
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       GroupedBeforeUnloadCancellationRetainsEveryDocument) {
  const int32_t work_id = Open(kSharedWork);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  ASSERT_TRUE(embedded_test_server()->Start());
  auto* work = SharedWindow(work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(work);
  ASSERT_TRUE(personal);
  Navigate(work, embedded_test_server()->GetURL("/title1.html"));
  Navigate(personal, embedded_test_server()->GetURL("/title2.html"));
  auto work_alive = work->GetWeakPtr();
  auto personal_alive = personal->GetWeakPtr();
  auto* host = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  auto host_alive = host->GetWeakPtr();
  std::array<content::WebContents*, 2> pages{
      work->GetTabStripModel()->GetActiveWebContents(),
      personal->GetTabStripModel()->GetActiveWebContents()};
  for (auto* page : pages) {
    ASSERT_TRUE(
        content::ExecJs(page, "document.body.innerHTML = '<input id=draft>';"
                              "draft.value = 'unsaved'; window.liveMarker = {};"
                              "onbeforeunload = () => 'keep draft';"));
    content::PrepContentsForBeforeUnloadTest(page);
  }
  NavigationEvents work_events, personal_events;
  ASSERT_NE(0u, barc_tab_observe(work_id, barc_window_tab_at(work_id, 0),
                                NavigationEvents::Receive, &work_events));
  ASSERT_NE(0u, barc_tab_observe(personal_id, barc_window_tab_at(personal_id, 0),
                                NavigationEvents::Receive, &personal_events));
  bool cancelled_application_quit = false;
  auto quit_observation = chrome::AddClosingAllBrowsersCallback(
      base::BindLambdaForTesting([&](bool closing) {
        cancelled_application_quit |= !closing;
      }));
  host->Close();
  auto* first = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(first->is_before_unload_dialog());
  EXPECT_EQ(0u, work_events.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(0u, personal_events.Count(BARC_TAB_CLOSE_CANCELLED));
  auto* first_page = first->web_contents();
  ASSERT_TRUE(first_page == pages[0] || first_page == pages[1]);
  EXPECT_TRUE((first_page == pages[0] ? work : personal)
                  ->IsSelectedForNativeWindow());
  first->view()->AcceptAppModalDialog();
  auto* second = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(second->is_before_unload_dialog());
  ASSERT_TRUE(second->web_contents() == pages[0] ||
              second->web_contents() == pages[1]);
  EXPECT_NE(first_page, second->web_contents());
  EXPECT_TRUE((second->web_contents() == pages[0] ? work : personal)
                  ->IsSelectedForNativeWindow());
  second->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return work_alive && personal_alive &&
           !UnloadController::From(work_alive.get())
                ->is_attempting_to_close_browser() &&
           !UnloadController::From(personal_alive.get())
                ->is_attempting_to_close_browser();
  }));
  EXPECT_FALSE(cancelled_application_quit);
  EXPECT_EQ(1u, work_events.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(1u, personal_events.Count(BARC_TAB_CLOSE_CANCELLED));

  EXPECT_EQ(0u, work_events.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(0u, personal_events.Count(BARC_TAB_CLOSED));
  const size_t work_titles = work_events.Count(BARC_TAB_TITLE);
  const size_t personal_titles = personal_events.Count(BARC_TAB_TITLE);
  ASSERT_TRUE(content::ExecJs(pages[0], "document.title='Work stays live'"));
  ASSERT_TRUE(content::ExecJs(pages[1], "document.title='Personal stays live'"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return work_events.Count(BARC_TAB_TITLE) > work_titles &&
           personal_events.Count(BARC_TAB_TITLE) > personal_titles;
  }));

  ASSERT_TRUE(host_alive);
  EXPECT_EQ(host, BrowserView::GetBrowserViewForBrowser(work_alive.get())
                      ->browser_widget());
  EXPECT_EQ(host, BrowserView::GetBrowserViewForBrowser(personal_alive.get())
                      ->browser_widget());
  EXPECT_EQ(pages[0], work_alive->GetTabStripModel()->GetActiveWebContents());
  EXPECT_EQ(pages[1],
            personal_alive->GetTabStripModel()->GetActiveWebContents());
  for (auto* page : pages) {
    EXPECT_EQ("unsaved", content::EvalJs(page, "draft.value"));
    EXPECT_EQ("object", content::EvalJs(page, "typeof liveMarker"));
    ASSERT_TRUE(content::ExecJs(page, "onbeforeunload = null;"));
  }
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       ProfileClosePreemptsPendingLocalDownloadWarning) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      &content::SlowDownloadHttpResponse::HandleSlowDownloadRequest));
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  auto work_alive = work->GetWeakPtr();
  Profile* otr_profile = work->GetProfile()->GetPrimaryOTRProfile(true);
  BrowserWindowCreateParams params(otr_profile, true);
  params.native_window_owner = work->GetSessionID();
  auto* otr = CreateBrowserWindow(std::move(params));
  ASSERT_TRUE(otr);
  auto otr_alive = otr->GetWeakPtr();
  const int32_t otr_id = otr->GetSessionID().id();
  ASSERT_NE(0, barc_tab_create(otr_id, "about:blank", 1));
  Navigate(otr, embedded_test_server()->GetURL("/title1.html"));
  auto* page = otr->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(
      page,
      "document.body.innerHTML = '<input id=draft>'; draft.value='unsaved';"
      "onbeforeunload = () => 'keep draft';"));
  content::PrepContentsForBeforeUnloadTest(page);
  const auto otr_path = otr_profile->GetPath();
  auto otr_profile_alive = otr_profile->GetWeakPtr();
  auto* manager = otr_profile->GetDownloadManager();
  // Initialize the OTR default before overriding it for this warning fixture.
  auto* download_prefs = DownloadPrefs::FromDownloadManager(manager);
  otr_profile->GetPrefs()->SetBoolean(prefs::kPromptForDownload, false);
  ASSERT_EQ(otr_profile, manager->GetBrowserContext());
  ASSERT_FALSE(otr_profile->GetPrefs()->GetBoolean(prefs::kPromptForDownload));
  ASSERT_FALSE(download_prefs->PromptForDownload());
  base::ScopedClosureRunner cleanup(
      base::BindLambdaForTesting([otr_profile_alive] {
        if (!otr_profile_alive) {
          return;
        }
        content::DownloadManager::DownloadVector items;
        otr_profile_alive->GetDownloadManager()->GetAllDownloads(&items);
        for (const auto& item : items) {
          item->Cancel(/*user_cancel=*/true);
        }
      }));
  content::DownloadTestObserverInProgress progress(manager, 1);
  ASSERT_NE(0,
            barc_tab_create(
                otr_id,
                embedded_test_server()
                    ->GetURL(content::SlowDownloadHttpResponse::kKnownSizeUrl)
                    .spec()
                    .c_str(),
                0));
  progress.WaitForFinished();
  content::DownloadManager::DownloadVector initial_downloads;
  manager->GetAllDownloads(&initial_downloads);
  ASSERT_EQ(1u, initial_downloads.size());
  const std::string download_guid = initial_downloads.front()->GetGuid();
  auto* host = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  ASSERT_EQ(host, BrowserView::GetBrowserViewForBrowser(otr)->browser_widget());
  auto children_before =
      views::Widget::GetAllOwnedWidgets(host->GetNativeView());
  host->Close();
  base::WeakPtr<views::Widget> warning;
  ASSERT_TRUE(base::test::RunUntil([&] {
    for (const auto& child :
         views::Widget::GetAllOwnedWidgets(host->GetNativeView())) {
      if (!children_before.contains(child) && child->IsVisible() &&
          views::AsViewClass<DownloadInProgressDialogView>(child->GetClientContentsView())) {
        warning = child->GetWeakPtr();
        return true;
      }
    }
    return false;
  }));
  base::test::TestFuture<base::FilePath> aborted;
  chrome::CloseAllBrowsersWithProfile(
      otr_profile, false, base::NullCallback(),
      aborted.GetRepeatingCallback<const base::FilePath&>());
  // The replacement owner must dismiss only its stale download warning, before
  // its beforeunload prompt can own the same physical modal anchor.
  EXPECT_TRUE(
      base::test::RunUntil([&] { return !warning || !warning->IsVisible(); }));
  // Keep a failing cancellation regression clean enough to finish, rather than
  // leaving the old modal blocking the profile-close cancellation below.
  if (warning && warning->IsVisible()) {
    warning->Close();
  }
  auto* dialog = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(dialog->is_before_unload_dialog());
  dialog->view()->CancelAppModalDialog();
  EXPECT_EQ(otr_path, aborted.Get());
  ASSERT_TRUE(work_alive);
  ASSERT_TRUE(otr_alive);
  EXPECT_EQ(page, otr_alive->GetTabStripModel()->GetWebContentsAt(0));
  EXPECT_EQ("unsaved", content::EvalJs(page, "draft.value"));
  EXPECT_FALSE(UnloadController::From(otr_alive.get())
                   ->is_attempting_to_close_browser());
  ASSERT_TRUE(otr_profile_alive);
  content::DownloadManager::DownloadVector remaining_downloads;
  otr_profile_alive->GetDownloadManager()->GetAllDownloads(
      &remaining_downloads);
  ASSERT_EQ(1u, remaining_downloads.size());
  EXPECT_EQ(download_guid, remaining_downloads.front()->GetGuid());
  EXPECT_EQ(download::DownloadItem::IN_PROGRESS,
            remaining_downloads.front()->GetState());
  NavigationEvents wait_work, wait_otr;
  ASSERT_NE(0u, barc_tab_observe(work_id, barc_window_tab_at(work_id, 0),
                                NavigationEvents::Receive, &wait_work));
  ASSERT_NE(0u, barc_tab_observe(otr_id, barc_window_tab_at(otr_id, 0),
                                NavigationEvents::Receive, &wait_otr));
  // A second local group accepts its download warning. Preempt at its actual
  // dismissal, while accepted continuation is still pending, not by a timer.
  content::PrepContentsForBeforeUnloadTest(page);
  host->Close();
  ASSERT_TRUE(base::test::RunUntil([&] {
    for (const auto& child : views::Widget::GetAllOwnedWidgets(host->GetNativeView())) {
      if (child->IsVisible() && views::AsViewClass<DownloadInProgressDialogView>(
                                    child->GetClientContentsView())) {
        warning = child->GetWeakPtr();
        return true;
      }
    }
    return false;
  }));
  base::test::TestFuture<base::FilePath> second_aborted;
  bool preempted_during_wait = false;
  PreemptOnDownloadWarningDismissal preempt_on_dismissal(
      warning.get(), base::BindLambdaForTesting([&] {
        preempted_during_wait = true;
        EXPECT_TRUE(host->HasPhysicalClosePending());
        EXPECT_FALSE(host->IsPhysicalCloseCommitted());
        ASSERT_TRUE(otr_profile_alive);
        chrome::CloseAllBrowsersWithProfile(
            otr_profile_alive.get(), false, base::NullCallback(),
            second_aborted.GetRepeatingCallback<const base::FilePath&>());
      }));
  warning->widget_delegate()->AsDialogDelegate()->AcceptDialog();
  auto* second_dialog = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(second_dialog->is_before_unload_dialog());
  EXPECT_TRUE(preempted_during_wait);
  EXPECT_EQ(page, second_dialog->web_contents());
  // Local group cancellation is complete before the replacement profile-family
  // close is refused. That later abort resets both regular and OTR controllers.
  EXPECT_EQ(1u, wait_work.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(1u, wait_otr.Count(BARC_TAB_CLOSE_CANCELLED));
  second_dialog->view()->CancelAppModalDialog();
  EXPECT_EQ(otr_path, second_aborted.Get());
  ASSERT_TRUE(work_alive);
  ASSERT_TRUE(otr_alive);
  EXPECT_FALSE(host->HasPhysicalClosePending());
  EXPECT_EQ(2u, wait_work.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(2u, wait_otr.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(0u, wait_work.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(0u, wait_otr.Count(BARC_TAB_CLOSED));
  base::RunLoop().RunUntilIdle();
  EXPECT_FALSE(host->HasPhysicalClosePending());
  EXPECT_EQ(2u, wait_work.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(2u, wait_otr.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(0u, wait_work.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(0u, wait_otr.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(page, otr_alive->GetTabStripModel()->GetWebContentsAt(0));
  EXPECT_EQ("unsaved", content::EvalJs(page, "draft.value"));
  ASSERT_TRUE(content::ExecJs(page, "onbeforeunload = null;"));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       RendererFailurePreservesOtherProfileDocument) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  const GURL work_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_NO_FATAL_FAILURE(Navigate(work, work_url));
  ASSERT_NO_FATAL_FAILURE(
      Navigate(personal, embedded_test_server()->GetURL("/title2.html")));
  auto* work_contents = work->GetTabStripModel()->GetActiveWebContents();
  auto* personal_contents = personal->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(work_contents);
  ASSERT_TRUE(personal_contents);
  auto* personal_process = personal_contents->GetPrimaryMainFrame()->GetProcess();
  auto* work_process = work_contents->GetPrimaryMainFrame()->GetProcess();
  ASSERT_NE(work_process, personal_process);
  ASSERT_NE(work_process->GetProcess().Pid(),
            personal_process->GetProcess().Pid());
  const auto personal_pid = personal_process->GetProcess().Pid();
  auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  ASSERT_TRUE(work_view);
  ASSERT_TRUE(personal_view);
  auto* host = work_view->GetWidget();
  ASSERT_EQ(host, personal_view->GetWidget());
  const auto native_window = host->GetNativeWindow();
  ASSERT_NE(work->GetProfile(), personal->GetProfile());
  ASSERT_TRUE(personal->IsSelectedForNativeWindow());
  ASSERT_FALSE(work->IsSelectedForNativeWindow());
  ASSERT_TRUE(content::ExecJs(personal_contents, R"JS(
    document.body.innerHTML = '<input id="draft">';
    document.getElementById('draft').value = 'unsaved-personal';
    window.personalProbe = (() => {
      const state = {count: 7};
      const originalBody = document.body;
      return () => [++state.count, originalBody === document.body,
                    document.getElementById('draft').value];
    })();
  )JS"));
  {
    content::ScopedAllowRendererCrashes allow_expected_crash(work_process);
    // Upstream helper targets only this process, waits for its exit, asserts
    // abnormal termination, and verifies WebContents::IsCrashed().
    content::CrashTab(work_contents);
  }
  ASSERT_TRUE(work_contents->IsCrashed());
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
  EXPECT_FALSE(work_contents->GetPrimaryMainFrame()->IsRenderFrameLive());
  EXPECT_FALSE(personal_contents->IsCrashed());
  EXPECT_EQ("[8,true,\"unsaved-personal\"]",
            content::EvalJs(personal_contents, "JSON.stringify(personalProbe())"));
  EXPECT_EQ(personal_process,
            personal_contents->GetPrimaryMainFrame()->GetProcess());
  EXPECT_EQ(personal_pid, personal_process->GetProcess().Pid());
  EXPECT_EQ(work_view, BrowserView::GetBrowserViewForBrowser(work));
  EXPECT_EQ(personal_view, BrowserView::GetBrowserViewForBrowser(personal));
  EXPECT_EQ(host, work_view->GetWidget());
  EXPECT_EQ(host, personal_view->GetWidget());
  EXPECT_EQ(native_window, personal->GetWindow()->GetNativeWindow());
  EXPECT_EQ(personal, GlobalBrowserCollection::GetInstance()
                          ->FindBrowserWithWindow(native_window));
  // The existing bridge has navigation, not a dedicated Reload entry point.
  // Recover the crashed tab by loading its same committed URL through it.
  ASSERT_NO_FATAL_FAILURE(Navigate(work, work_url));
  EXPECT_FALSE(work_contents->IsCrashed());
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
  EXPECT_TRUE(work_contents->GetPrimaryMainFrame()->IsRenderFrameLive());
  EXPECT_EQ("This page has no title.",
            content::EvalJs(work_contents, "document.body.textContent.trim()"));
  EXPECT_EQ("[9,true,\"unsaved-personal\"]",
            content::EvalJs(personal_contents, "JSON.stringify(personalProbe())"));
  EXPECT_EQ(personal_process,
            personal_contents->GetPrimaryMainFrame()->GetProcess());
  EXPECT_EQ(personal_pid, personal_process->GetProcess().Pid());
  EXPECT_EQ(personal->GetProfile(), personal_contents->GetBrowserContext());
  EXPECT_EQ(work->GetProfile(), work_contents->GetBrowserContext());
  EXPECT_EQ(host, BrowserView::GetBrowserViewForBrowser(work)->GetWidget());
  EXPECT_EQ(host, BrowserView::GetBrowserViewForBrowser(personal)->GetWidget());
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       PopupOpenerSurvivesSameProfileLiveTransfer) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_TRUE(work);
  const int32_t personal_id = Open(kSharedPersonal, work_id);
  auto* personal = SharedWindow(personal_id);
  ASSERT_TRUE(personal);
  const GURL url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_NO_FATAL_FAILURE(Navigate(work, url));
  auto* source = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_EQ(1, barc_window_select(personal_id));
  ASSERT_TRUE(personal->IsSelectedForNativeWindow());
  ASSERT_FALSE(work->IsSelectedForNativeWindow());
  ASSERT_TRUE(content::ExecJs(source, R"JS(
    window.addEventListener('message', e => {
      if (e.origin === location.origin && e.source === window.openedPopup &&
          e.data === 'reverse') e.source.postMessage('reverse-ack', e.origin);
    });
  )JS"));
  BrowserWindowInterface* popup_browser = nullptr;
  content::WebContents* popup = nullptr;
  {
    ui_test_utils::BrowserCreatedObserver popup_created;
    content::WebContentsAddedObserver popup_contents_added;
    // ExecJs defaults to a normal test user gesture; no popup/security bypass.
    ASSERT_TRUE(content::ExecJs(source, content::JsReplace(
        "window.openedPopup = window.open($1, 'barc-popup', 'popup,width=400,height=300');"
        "if (!openedPopup) throw Error('popup blocked');", url)));
    popup_browser = popup_created.Wait();
    popup = popup_contents_added.GetWebContents();
  }
  ASSERT_TRUE(popup_browser);
  ASSERT_TRUE(popup);
  ASSERT_EQ(popup, popup_browser->GetTabStripModel()->GetActiveWebContents());
  ASSERT_TRUE(content::WaitForLoadStop(popup));
  ASSERT_EQ(url, popup->GetLastCommittedURL());
  EXPECT_EQ(work->GetProfile(), popup_browser->GetProfile());
  EXPECT_EQ(work->GetProfile(), popup->GetBrowserContext());
  EXPECT_NE(personal->GetProfile(), popup->GetBrowserContext());
  const auto shared_native = work->GetWindow()->GetNativeWindow();
  EXPECT_NE(shared_native, popup_browser->GetWindow()->GetNativeWindow());
  ASSERT_TRUE(content::ExecJs(popup, R"JS(
    if (!window.opener) throw Error('missing JS opener');
    document.body.innerHTML = '<input id="draft">';
    document.getElementById('draft').value = 'unsaved-popup';
    window.liveProbe = (() => {
      let count = 10;
      const body = document.body;
      return () => [++count, body === document.body,
                    document.getElementById('draft').value];
    })();
    window.addEventListener('message', e => {
      if (e.origin === location.origin && e.source === window.opener &&
          e.data === 'forward') e.source.postMessage('forward-ack', e.origin);
    });
  )JS"));
  auto exchange = [&] {
    EXPECT_EQ("forward-ack", content::EvalJs(source, R"JS(
      new Promise(resolve => {
        function onReply(e) {
          if (e.origin === location.origin && e.source === openedPopup &&
              e.data === 'forward-ack') {
            removeEventListener('message', onReply); resolve(e.data);
          }
        }
        addEventListener('message', onReply);
        openedPopup.postMessage('forward', location.origin);
      })
    )JS"));
    EXPECT_EQ("reverse-ack", content::EvalJs(popup, R"JS(
      new Promise(resolve => {
        function onReply(e) {
          if (e.origin === location.origin && e.source === opener &&
              e.data === 'reverse-ack') {
            removeEventListener('message', onReply); resolve(e.data);
          }
        }
        addEventListener('message', onReply);
        opener.postMessage('reverse', location.origin);
      })
    )JS"));
  };
  exchange();
  EXPECT_EQ("[11,true,\"unsaved-popup\"]",
            content::EvalJs(popup, "JSON.stringify(liveProbe())"));
  auto* original_frame = popup->GetPrimaryMainFrame();
  const int32_t popup_id = popup_browser->GetSessionID().id();
  const int32_t popup_tab = barc_window_tab_at(popup_id, 0);
  ASSERT_NE(0, popup_tab);
  const int32_t peer_id = barc_window_new_peer(popup_id);
  ASSERT_NE(0, peer_id);
  ui_test_utils::BrowserDestroyedObserver popup_closed(popup_browser);
  ASSERT_EQ(1, barc_tab_transfer(popup_id, popup_tab, peer_id));
  popup_closed.Wait();
  auto* peer = SharedWindow(peer_id);
  ASSERT_TRUE(peer);
  EXPECT_EQ(work->GetProfile(), peer->GetProfile());
  EXPECT_EQ(popup, peer->GetTabStripModel()->GetActiveWebContents());
  EXPECT_EQ(original_frame, popup->GetPrimaryMainFrame());
  EXPECT_EQ(popup_tab, barc_window_tab_at(peer_id, 0));
  exchange();
  EXPECT_EQ("[12,true,\"unsaved-popup\"]",
            content::EvalJs(popup, "JSON.stringify(liveProbe())"));
  // TabStripModel opener metadata may change at detach; JS opener must not.
  BrowserWindowInterface* noopener_browser = nullptr;
  content::WebContents* noopener = nullptr;
  {
    ui_test_utils::BrowserCreatedObserver noopener_created;
    content::WebContentsAddedObserver noopener_contents_added;
    EXPECT_EQ(true, content::EvalJs(source, content::JsReplace(
        "window.open($1, '_blank', 'noopener,popup,width=400,height=300') === null",
        url)));
    noopener_browser = noopener_created.Wait();
    noopener = noopener_contents_added.GetWebContents();
  }
  ASSERT_TRUE(noopener_browser);
  ASSERT_TRUE(noopener);
  ASSERT_TRUE(content::WaitForLoadStop(noopener));
  ASSERT_EQ(url, noopener->GetLastCommittedURL());
  EXPECT_EQ(work->GetProfile(), noopener_browser->GetProfile());
  EXPECT_EQ(work->GetProfile(), noopener->GetBrowserContext());
  EXPECT_EQ(true, content::EvalJs(noopener, "window.opener === null"));
  EXPECT_TRUE(SharedWindow(personal_id));
}


IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, NavigationCommandsAndEvents) {
  net::test_server::ControllableHttpResponse slow(embedded_test_server(), "/slow");
  ASSERT_TRUE(embedded_test_server()->Start());
  const auto window = browser()->GetSessionID().id();
  const auto tab = barc_window_tab_at(window, 0);
  auto* contents = browser()->tab_strip_model()->GetWebContentsAt(0);
  NavigationEvents observed;
  ASSERT_NE(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &observed));
  ASSERT_EQ(1u, observed.events.size());
  EXPECT_EQ(BARC_TAB_INITIAL, observed.events.front().kind);
  EXPECT_EQ(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &observed));
  const GURL first = embedded_test_server()->GetURL("/title1.html");
  const GURL second = embedded_test_server()->GetURL("/title2.html");
  ASSERT_EQ(1, barc_tab_navigate(window, tab, first.spec().c_str()));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  ASSERT_EQ(1, barc_tab_navigate(window, tab,
      embedded_test_server()->GetURL("/server-redirect?" + second.spec()).spec().c_str()));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_EQ(second, contents->GetLastCommittedURL());
  ASSERT_TRUE(base::test::RunUntil([&] { return observed.Count(BARC_TAB_FINISHED) == 2; }));
  EXPECT_EQ(second.spec(), observed.events.back().url);
  EXPECT_TRUE(observed.events.back().flags & BARC_TAB_BACK);
  ASSERT_EQ(1, barc_tab_go_back(window, tab));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_EQ(first, contents->GetLastCommittedURL());
  EXPECT_TRUE(observed.events.back().flags & BARC_TAB_FORWARD);
  ASSERT_EQ(1, barc_tab_go_forward(window, tab));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_EQ(second, contents->GetLastCommittedURL());
  const size_t before_reload = observed.events.size();
  ASSERT_EQ(1, barc_tab_reload(window, tab));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_TRUE(std::any_of(observed.events.begin() + before_reload,
                         observed.events.end(), [&](const auto& event) {
    return event.kind == BARC_TAB_FINISHED &&
           (event.flags & BARC_TAB_RELOAD) && event.url == second.spec() &&
           !(event.flags & BARC_TAB_LOADING);
  }));
  const size_t before_same_document = observed.events.size();
  const size_t starts_before_same_document = observed.Count(BARC_TAB_STARTED);
  const size_t finishes_before_same_document = observed.Count(BARC_TAB_FINISHED);
  ASSERT_TRUE(content::ExecJs(contents, "document.title='Observed title'; history.pushState({}, '', '#same')"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return std::any_of(observed.events.begin() + before_same_document,
                       observed.events.end(), [&](const auto& event) {
      return event.kind == BARC_TAB_COMMITTED &&
             (event.flags & BARC_TAB_SAME_DOCUMENT) &&
             event.url == second.spec() + "#same";
    });
  }));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return std::any_of(observed.events.begin() + before_same_document,
                       observed.events.end(), [](const auto& event) {
      return event.kind == BARC_TAB_TITLE && event.title == "Observed title";
    });
  }));
  EXPECT_EQ(starts_before_same_document, observed.Count(BARC_TAB_STARTED));
  EXPECT_EQ(finishes_before_same_document, observed.Count(BARC_TAB_FINISHED));
  ASSERT_EQ(1, barc_tab_navigate(window, tab,
      embedded_test_server()->GetURL("/slow").spec().c_str()));
  slow.WaitForRequest();
  ASSERT_EQ(1, barc_tab_stop(window, tab));
  ASSERT_TRUE(base::test::RunUntil([&] { return observed.Count(BARC_TAB_FAILED) == 1; }));
  const auto& failed = *std::find_if(observed.events.begin(), observed.events.end(),
      [](const auto& e) { return e.kind == BARC_TAB_FAILED; });
  EXPECT_TRUE(failed.flags & BARC_TAB_ABORTED);
  EXPECT_TRUE(failed.flags & BARC_TAB_PROVISIONAL);
  const size_t finished = observed.Count(BARC_TAB_FINISHED);
  slow.Done();
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(finished, observed.Count(BARC_TAB_FINISHED));
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest, NavigationObserverLifetimeAndTransfer) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const auto window = browser()->GetSessionID().id();
  const auto tab = barc_window_tab_at(window, 0);
  NavigationEvents cancelled;
  cancelled.unsubscribe_initial = true;
  EXPECT_EQ(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &cancelled));
  auto self_releasing = std::make_unique<NavigationEvents>();
  self_releasing->release_owner = &self_releasing;
  EXPECT_EQ(0u, barc_tab_observe(window, tab, NavigationEvents::Receive,
                                self_releasing.get()));
  EXPECT_EQ(nullptr, self_releasing);
  NavigationEvents observed;
  ASSERT_NE(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &observed));
  const auto peer = barc_window_new_peer(window);
  ASSERT_GT(peer, 0);
  // Keep the source alive, independently of the moving observed tab.
  ASSERT_NE(0, barc_tab_create(window, "about:blank", 0));
  ASSERT_EQ(1, barc_tab_transfer(window, tab, peer));
  EXPECT_EQ(peer, observed.events.back().window);
  EXPECT_EQ(0, barc_tab_reload(window, tab));
  auto* owner = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(peer));
  ASSERT_NE(nullptr, owner);
  auto* contents = owner->GetTabStripModel()->GetWebContentsAt(0);
  observed.transfer_destination = window;
  ASSERT_EQ(1, barc_tab_navigate(peer, tab,
      embedded_test_server()->GetURL("/title1.html").spec().c_str()));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_TRUE(observed.transfer_refused);
  EXPECT_EQ(owner, tabs::TabHandle(tab).Get()->GetBrowserWindowInterface());
  EXPECT_EQ(1u, cancelled.events.size());
  EXPECT_EQ(peer, observed.events.back().window);
  barc_tab_unobserve(observed.token);
  const size_t count = observed.events.size();
  ASSERT_EQ(1, barc_tab_reload(peer, tab));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_EQ(count, observed.events.size());
  NavigationEvents closing;
  closing.close_started = true;
  ASSERT_NE(0u, barc_tab_observe(peer, tab, NavigationEvents::Receive, &closing));
  ASSERT_EQ(1, barc_tab_navigate(peer, tab,
      embedded_test_server()->GetURL("/title2.html").spec().c_str()));
  ASSERT_TRUE(base::test::RunUntil([&] { return closing.Count(BARC_TAB_CLOSED) == 1; }));
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1u, closing.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(BARC_TAB_CLOSED, closing.events.back().kind);
  auto* source_page = browser()->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(source_page, "window.unrelatedMarker = 'live'"));
  for (bool unsubscribe : {false, true}) {
    const auto close_window = barc_window_new_peer(window);
    const auto close_tab = barc_tab_create(close_window, "about:blank", 1);
    ASSERT_NE(0, close_tab);
    auto* close_owner = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
        SessionID::FromSerializedValue(close_window));
    ASSERT_NE(nullptr, close_owner);
    auto alive = close_owner->GetWeakPtr();
    ASSERT_TRUE(content::WaitForLoadStop(
        close_owner->GetTabStripModel()->GetActiveWebContents()));
    NavigationEvents window_closing;
    window_closing.close_window_started = true;
    window_closing.unsubscribe_before_close = unsubscribe;
    ASSERT_NE(0u, barc_tab_observe(close_window, close_tab,
                                  NavigationEvents::Receive, &window_closing));
    ASSERT_EQ(1, barc_tab_navigate(close_window, close_tab,
        embedded_test_server()->GetURL("/title2.html").spec().c_str()));
    ASSERT_TRUE(base::test::RunUntil([&] { return !alive; }));
    EXPECT_EQ(unsubscribe ? 0u : 1u, window_closing.Count(BARC_TAB_CLOSED));
    const size_t delivered = window_closing.events.size();
    base::RunLoop().RunUntilIdle();
    EXPECT_EQ(delivered, window_closing.events.size());
    EXPECT_EQ("live", content::EvalJs(source_page, "unrelatedMarker"));
  }

}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       NavigationBindingDuringLoadAndContentsReplacement) {
  net::test_server::ControllableHttpResponse pending(embedded_test_server(),
                                                    "/pending");
  net::test_server::ControllableHttpResponse superseded(embedded_test_server(),
                                                       "/superseded");
  net::test_server::ControllableHttpResponse tail(embedded_test_server(), "/tail");
  ASSERT_TRUE(embedded_test_server()->Start());
  const auto window = browser()->GetSessionID().id();
  const auto tab = barc_window_tab_at(window, 0);
  auto* contents = browser()->tab_strip_model()->GetWebContentsAt(0);
  ASSERT_EQ(1, barc_tab_navigate(window, tab,
      embedded_test_server()->GetURL("/pending").spec().c_str()));
  pending.WaitForRequest();
  NavigationEvents observed;
  ASSERT_NE(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &observed));
  EXPECT_TRUE(observed.events.front().flags & BARC_TAB_LOADING);
  pending.Send("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<title>Pending</title><img src='/tail'>");
  pending.Done();
  tail.WaitForRequest();
  const size_t before_same_document = observed.events.size();
  ASSERT_TRUE(content::ExecJs(contents, "history.pushState({}, '', '#during-load')"));
  EXPECT_TRUE(contents->IsLoading());
  EXPECT_EQ(0u, observed.Count(BARC_TAB_FINISHED));
  EXPECT_TRUE(std::any_of(observed.events.begin() + before_same_document,
                         observed.events.end(), [&](const auto& event) {
    return event.kind == BARC_TAB_COMMITTED &&
           (event.flags & BARC_TAB_SAME_DOCUMENT) &&
           (event.flags & BARC_TAB_LOADING) &&
           event.url == embedded_test_server()->GetURL("/pending#during-load").spec();
  }));
  barc_tab_unobserve(observed.token);
  ASSERT_NE(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &observed));
  EXPECT_EQ(BARC_TAB_INITIAL, observed.events.back().kind);
  EXPECT_TRUE(observed.events.back().flags & BARC_TAB_LOADING);
  tail.Send("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n");
  tail.Done();
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  ASSERT_EQ(0u, observed.Count(BARC_TAB_FINISHED));
  EXPECT_EQ(0u, observed.Count(BARC_TAB_STARTED));
  EXPECT_FALSE(observed.events.back().flags & BARC_TAB_LOADING);
  EXPECT_EQ(contents->GetVisibleURL().spec(), observed.events.back().url);
  ASSERT_EQ(1, barc_tab_navigate(window, tab,
      embedded_test_server()->GetURL("/superseded").spec().c_str()));
  superseded.WaitForRequest();
  ASSERT_EQ(1, barc_tab_navigate(window, tab,
      embedded_test_server()->GetURL("/title1.html").spec().c_str()));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  superseded.Done();
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(0u, observed.Count(BARC_TAB_FAILED));
  EXPECT_EQ(1u, observed.Count(BARC_TAB_FINISHED));
  // Discard is supported only in the background; the TabHandle survives while
  // observation leaves the old contents before their destruction.
  ASSERT_NE(0, barc_tab_create(window, "about:blank", 1));
  auto replacement = content::WebContents::Create(
      content::WebContents::CreateParams(browser()->GetProfile()));
  auto* new_contents = replacement.get();
  auto old = browser()->tab_strip_model()->DiscardWebContents(
      contents, std::move(replacement));
  old.reset();
  EXPECT_EQ(0u, observed.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(BARC_TAB_STATE, observed.events.back().kind);
  ASSERT_EQ(1, barc_tab_navigate(window, tab,
      embedded_test_server()->GetURL("/title2.html").spec().c_str()));
  ASSERT_TRUE(content::WaitForLoadStop(new_contents));
  EXPECT_EQ(2u, observed.Count(BARC_TAB_FINISHED));
  EXPECT_EQ("Title Of Awesomeness", observed.events.back().title);
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       TabCloseCancellationAllowsUnsubscribeAndRetry) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),
      embedded_test_server()->GetURL("/title1.html")));
  const int32_t window = browser()->GetSessionID().id();
  const int32_t tab = barc_window_tab_at(window, 0);
  auto* page = tabs::TabHandle(tab).Get()->GetContents();
  ASSERT_NE(0, barc_tab_create(window, "about:blank", 0));
  ASSERT_TRUE(content::ExecJs(page,
      "document.body.innerHTML='<input id=draft>'; draft.value='keep';"
      "onbeforeunload=()=> 'keep';"));
  content::PrepContentsForBeforeUnloadTest(page);
  NavigationEvents events;
  events.retry_cancelled = true;
  events.unsubscribe_cancelled = true;
  ASSERT_NE(0u, barc_tab_observe(window, tab, NavigationEvents::Receive, &events));
  content::WebContentsDestroyedWatcher destroyed(page);
  ASSERT_EQ(1, barc_tab_close(window, tab));
  auto* first = ui_test_utils::WaitForAppModalDialog();
  EXPECT_EQ(0u, events.Count(BARC_TAB_CLOSE_CANCELLED));
  first->view()->CancelAppModalDialog();
  auto* second = ui_test_utils::WaitForAppModalDialog();
  EXPECT_EQ(page, second->web_contents());
  EXPECT_EQ(1u, events.Count(BARC_TAB_CLOSE_CANCELLED));
  EXPECT_EQ(0u, events.Count(BARC_TAB_CLOSED));
  auto second_alive = second->GetWeakPtr();
  second->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !second_alive && events.Count(BARC_TAB_CLOSE_CANCELLED) == 2;
  }));
  EXPECT_EQ(page, tabs::TabHandle(tab).Get()->GetContents());
  EXPECT_EQ("keep", content::EvalJs(page, "draft.value"));
  ASSERT_TRUE(content::ExecJs(page, "onbeforeunload=null;"));
  barc_tab_unobserve(events.token);
  const size_t delivered = events.events.size();
  ASSERT_EQ(1, barc_tab_close(window, tab));
  destroyed.Wait();
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(nullptr, tabs::TabHandle(tab).Get());
  EXPECT_EQ(delivered, events.events.size());
}

IN_PROC_BROWSER_TEST_F(BarcBridgeBrowserTest,
                       WindowCloseCancellationFollowsTransferredObservation) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),
      embedded_test_server()->GetURL("/title1.html")));
  const int32_t source = browser()->GetSessionID().id();
  const int32_t tab = barc_window_tab_at(source, 0);
  auto* page = tabs::TabHandle(tab).Get()->GetContents();
  ASSERT_NE(0, barc_tab_create(source, "about:blank", 0));
  ASSERT_TRUE(content::ExecJs(page, "onbeforeunload=()=> 'keep';"));
  content::PrepContentsForBeforeUnloadTest(page);
  NavigationEvents events;
  ASSERT_NE(0u, barc_tab_observe(source, tab, NavigationEvents::Receive, &events));
  const int32_t peer = barc_window_new_peer(source);
  ASSERT_EQ(1, barc_tab_transfer(source, tab, peer));
  ASSERT_EQ(1, barc_window_close(peer));
  auto* dialog = ui_test_utils::WaitForAppModalDialog();
  EXPECT_EQ(0u, events.Count(BARC_TAB_CLOSE_CANCELLED));
  dialog->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return events.Count(BARC_TAB_CLOSE_CANCELLED) == 1;
  }));
  EXPECT_EQ(peer, events.events.back().window);
  EXPECT_EQ(0u, events.Count(BARC_TAB_CLOSED));
  EXPECT_EQ(page, tabs::TabHandle(tab).Get()->GetContents());
  ASSERT_TRUE(content::ExecJs(page, "onbeforeunload=null;"));
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       BlankConstructionWaitsForModelAdmission) {
  SharedProfileResult first;
  auto request = std::make_unique<ReleasedProfileRequest>();
  request->result = &first;
  request->owner = &request;
  barc_profile_open_window(kSharedWork, BARC_PROFILE_BLANK,
                           ReleasedProfileRequest::Completed, request.get());
  ASSERT_EQ(BARC_PROFILE_OK, first.Get<0>());
  EXPECT_EQ(nullptr, request);
  auto* work = SharedWindow(first.Get<1>());
  ASSERT_NE(nullptr, work);
  EXPECT_FALSE(work->GetWindow()->IsVisible());
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(page));
  EXPECT_EQ(GURL("about:blank"), page->GetLastCommittedURL());
  SharedProfileResult second;
  barc_profile_open_in_native_window(first.Get<1>(), kSharedPersonal,
      BARC_PROFILE_BLANK, SharedProfileCompleted, &second);
  ASSERT_EQ(BARC_PROFILE_OK, second.Get<0>());
  auto* personal = SharedWindow(second.Get<1>());
  ASSERT_NE(nullptr, personal);
  EXPECT_EQ(work->GetWindow()->GetNativeWindow(),
            personal->GetWindow()->GetNativeWindow());
  EXPECT_TRUE(work->IsSelectedForNativeWindow());
  EXPECT_FALSE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(personal->GetWindow()->IsVisible());
  NSView* shell = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
  ASSERT_EQ(1, barc_window_attach_native_shell(second.Get<1>(), (__bridge void*)shell));
  ASSERT_EQ(1, barc_window_select(second.Get<1>()));
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
  // The startup completion path uses this same normal Show only after caller
  // admission/attachment. This is a construction test, not native-focus proof.
  auto alive = personal->GetWeakPtr();
  ASSERT_EQ(1, barc_window_show(second.Get<1>()));
  EXPECT_EQ(0, barc_window_show(-1));
  ASSERT_TRUE(alive);
  EXPECT_TRUE(alive->GetWindow()->IsVisible());
  BarcReentrantNativeView* switching = [[BarcReentrantNativeView alloc] init];
  const int32_t work_id = first.Get<1>();
  switching.onMove = ^(NSView*) { EXPECT_EQ(1, barc_window_select(work_id)); };
  EXPECT_EQ(0, barc_window_attach_native_shell(second.Get<1>(),
                                               (__bridge void*)switching));
  EXPECT_TRUE(work->IsSelectedForNativeWindow());
  EXPECT_FALSE(personal->IsSelectedForNativeWindow());
  // Inactive detach remains supported and must not steal the newer selection.
  EXPECT_EQ(1, barc_window_attach_native_shell(second.Get<1>(), nullptr));
  EXPECT_TRUE(work->IsSelectedForNativeWindow());
}

IN_PROC_BROWSER_TEST_F(BarcSharedNativeWindowBrowserTest,
                       DownloadWarningCancelsOnlyAfterRefusal) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      &content::SlowDownloadHttpResponse::HandleSlowDownloadRequest));
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work_id = Open(kSharedWork);
  auto* work = SharedWindow(work_id);
  ASSERT_NE(nullptr, work);
  Profile* otr_profile = work->GetProfile()->GetPrimaryOTRProfile(true);
  auto profile_alive = otr_profile->GetWeakPtr();
  BrowserWindowCreateParams params(otr_profile, true);
  params.native_window_owner = work->GetSessionID();
  auto* otr = CreateBrowserWindow(std::move(params));
  ASSERT_NE(nullptr, otr);
  const int32_t otr_id = otr->GetSessionID().id();
  ASSERT_NE(0, barc_tab_create(otr_id, "about:blank", 1));
  auto* manager = otr_profile->GetDownloadManager();
  auto* prefs_for_download = DownloadPrefs::FromDownloadManager(manager);
  otr_profile->GetPrefs()->SetBoolean(prefs::kPromptForDownload, false);
  ASSERT_FALSE(prefs_for_download->PromptForDownload());
  base::ScopedClosureRunner cleanup(base::BindLambdaForTesting([profile_alive] {
    if (!profile_alive) return;
    content::DownloadManager::DownloadVector items;
    profile_alive->GetDownloadManager()->GetAllDownloads(&items);
    for (const auto& item : items) item->Cancel(true);
  }));
  content::DownloadTestObserverInProgress progress(manager, 1);
  ASSERT_NE(0, barc_tab_create(otr_id,
      embedded_test_server()->GetURL(content::SlowDownloadHttpResponse::kKnownSizeUrl)
          .spec().c_str(), 0));
  progress.WaitForFinished();
  std::vector<std::unique_ptr<NavigationEvents>> observations;
  std::vector<int32_t> observed_windows;
  std::vector<int32_t> observed_tabs;
  for (auto* owner : {work, otr}) {
    for (int index = 0; index < owner->GetTabStripModel()->count(); ++index) {
      auto events = std::make_unique<NavigationEvents>();
      ASSERT_NE(0u, barc_tab_observe(owner->GetSessionID().id(),
          owner->GetTabStripModel()->GetTabAtIndex(index)->GetHandle().raw_value(),
          NavigationEvents::Receive, events.get()));
      observed_tabs.push_back(owner->GetTabStripModel()->GetTabAtIndex(index)
                                  ->GetHandle().raw_value());
      observed_windows.push_back(owner->GetSessionID().id());
      observations.push_back(std::move(events));
    }
  }
  auto* host = BrowserView::GetBrowserViewForBrowser(work)->browser_widget();
  auto host_alive = host->GetWeakPtr();
  auto children_before = views::Widget::GetAllOwnedWidgets(host->GetNativeView());
  auto find_warning = [&]() -> base::WeakPtr<views::Widget> {
    for (const auto& child : views::Widget::GetAllOwnedWidgets(host->GetNativeView())) {
      if (!children_before.contains(child) && child->IsVisible() &&
          views::AsViewClass<DownloadInProgressDialogView>(child->GetClientContentsView()))
        return child->GetWeakPtr();
    }
    return {};
  };
  base::WeakPtr<views::Widget> warning;
  const char* phase = "logical-refusal";
  auto describe = [&] {
    std::ostringstream state;
    state << "phase=" << phase << " host alive=" << !!host_alive;
    if (host_alive) {
      auto* browser_host = static_cast<BrowserWidget*>(host_alive.get());
      state << " pending=" << browser_host->HasPhysicalClosePending()
            << " committed=" << browser_host->IsPhysicalCloseCommitted();
      if (host_alive->GetNativeView()) {
        for (const auto& child : views::Widget::GetAllOwnedWidgets(
                 host_alive->GetNativeView())) {
          state << " widget visible=" << child->IsVisible()
                << " closed=" << child->IsClosed();
          if (child->GetClientContentsView())
            state << " type=" << child->GetClientContentsView()->GetClassMetaData()->type_name();
        }
      }
    }
    for (size_t index = 0; index < observations.size(); ++index) {
      state << " window=" << observed_windows[index] << " tab=" << observed_tabs[index]
            << " CLOSED=" << observations[index]->Count(BARC_TAB_CLOSED)
            << " CANCEL=" << observations[index]->Count(BARC_TAB_CLOSE_CANCELLED);
      auto* tab = tabs::TabHandle(observed_tabs[index]).Get();
      auto* owner = tab ? tab->GetBrowserWindowInterface() : nullptr;
      if (owner) {
        auto* controller = UnloadController::From(owner);
        state << " owner=" << owner->GetSessionID().id()
              << " tabs=" << owner->GetTabStripModel()->count()
              << " delete=" << owner->IsDeleteScheduled();
        if (controller)
          state << " attempt=" << controller->is_attempting_to_close_browser()
                << " warning=" << controller->IsWaitingForDownloadCloseConfirmation()
                << " status=" << static_cast<int>(controller->GetBrowserClosingStatus());
      }
    }
    return state.str();
  };
  // Logical close uses HandleBeforeClose, whose initial DeniedByUser status
  // still means a pending warning. It must not complete a cancellation yet.
  ASSERT_EQ(1, barc_window_close(otr_id));
  ASSERT_TRUE(base::test::RunUntil([&] { warning = find_warning(); return !!warning; }))
      << describe();
  for (const auto& events : observations)
    EXPECT_EQ(0u, events->Count(BARC_TAB_CLOSE_CANCELLED));
  warning->widget_delegate()->AsDialogDelegate()->CancelDialog();
  std::vector<size_t> prior_cancellations;
  for (int32_t owner : observed_windows)
    prior_cancellations.push_back(owner == otr_id ? 1u : 0u);
  auto cancellation_counts_match = [&](size_t group_cancellations) {
    for (size_t index = 0; index < observations.size(); ++index) {
      if (observations[index]->Count(BARC_TAB_CLOSE_CANCELLED) !=
          prior_cancellations[index] + group_cancellations) return false;
    }
    return true;
  };
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !warning && cancellation_counts_match(0);
  })) << describe();
  phase = "group-refusal";
  children_before = views::Widget::GetAllOwnedWidgets(host->GetNativeView());
  host->Close();
  ASSERT_TRUE(base::test::RunUntil([&] { warning = find_warning(); return !!warning; }))
      << describe();
  EXPECT_TRUE(cancellation_counts_match(0)) << describe();
  warning->widget_delegate()->AsDialogDelegate()->CancelDialog();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !warning && cancellation_counts_match(1);
  })) << describe();
  for (const auto& events : observations) EXPECT_EQ(0u, events->Count(BARC_TAB_CLOSED));
  ASSERT_TRUE(profile_alive);
  content::DownloadManager::DownloadVector downloads;
  profile_alive->GetDownloadManager()->GetAllDownloads(&downloads);
  ASSERT_EQ(1u, downloads.size());
  EXPECT_EQ(download::DownloadItem::IN_PROGRESS, downloads.front()->GetState());
  downloads.clear();
  phase = "group-acceptance";
  children_before = views::Widget::GetAllOwnedWidgets(host->GetNativeView());
  host->Close();
  ASSERT_TRUE(base::test::RunUntil([&] { warning = find_warning(); return !!warning; }))
      << describe();
  EXPECT_TRUE(cancellation_counts_match(1)) << describe();
  auto* accept = warning->widget_delegate()->AsDialogDelegate();
  children_before.clear();
  accept->AcceptDialog();
  const bool closed = base::test::RunUntil([&] {
    return std::all_of(observations.begin(), observations.end(),
        [](const auto& e) { return e->Count(BARC_TAB_CLOSED) == 1; });
  });

  ASSERT_TRUE(closed) << describe();
  EXPECT_TRUE(cancellation_counts_match(1)) << describe();
}


namespace {
struct DiscoveryEvents {
  std::vector<uint64_t> revisions;
  bool unsubscribe = false;
  int32_t close_window = 0;
  static void Receive(void* context, uint64_t token, uint64_t revision) {
    auto* self = static_cast<DiscoveryEvents*>(context);
    self->revisions.push_back(revision);
    const int32_t close_window = self->close_window;
    if (self->unsubscribe)
      barc_discovery_unobserve(token);
    if (close_window)
      EXPECT_EQ(1, barc_window_close(close_window));
  }
};
struct DiscoveryRows {
  std::vector<BarcDiscoveryWindow> windows;
  std::vector<BarcDiscoveryTab> tabs;
  BarcDiscoverySnapshot snapshot{};
  void Read() {
    const auto result = barc_discovery_snapshot(nullptr, 0, nullptr, 0, &snapshot);
    ASSERT_TRUE(result == BARC_DISCOVERY_READ_CAPACITY ||
                result == BARC_DISCOVERY_READ_OK);
    windows.resize(snapshot.window_count);
    tabs.resize(snapshot.tab_count);
    ASSERT_EQ(BARC_DISCOVERY_READ_OK,
              barc_discovery_snapshot(windows.data(), windows.size(),
                                      tabs.data(), tabs.size(), &snapshot));
  }
};
}  // namespace

class BarcDiscoveryBrowserTest : public BarcSharedNativeWindowBrowserTest {
 public:
  void SetUp() override {
    barc_set_runtime_ready_callback([](void*) {
      int32_t initial = 0;
      GlobalBrowserCollection::GetInstance()->ForEach(
          [&](BrowserWindowInterface* window) {
            if (window->GetType() == BrowserWindowInterface::TYPE_NORMAL) {
              initial = window->GetSessionID().id();
              return false;
            }
            return true;
          });
      CHECK_GT(initial, 0);
      NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
      CHECK(barc_window_attach_native_shell(initial, (__bridge void*)header));
      CHECK(barc_window_admit_discovered(initial, (__bridge void*)header));
      barc_runtime_complete_startup(initial);
    }, nullptr);
    BarcSharedNativeWindowBrowserTest::SetUp();
  }
 protected:
  BrowserWindowInterface* NewNormal() {
    return CreateBrowserWindow(BrowserWindowCreateParams(
        BrowserWindowInterface::TYPE_NORMAL, browser()->GetProfile(), false));
  }
  NSView* Attach(int32_t id) {
    NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
    EXPECT_EQ(1, barc_window_attach_native_shell(id, (__bridge void*)header));
    return header;
  }
};

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       AdmissionPreservesIndependentPresentationAndHide) {
  auto* first = NewNormal();
  auto* second = NewNormal();
  ASSERT_TRUE(first);
  ASSERT_TRUE(second);
  const int32_t first_id = first->GetSessionID().id();
  const int32_t second_id = second->GetSessionID().id();
  chrome::AddAndReturnTabAt(first, GURL("about:blank"), -1, true);
  chrome::AddAndReturnTabAt(second, GURL("about:blank"), -1, true);
  first->GetWindow()->Show();
  second->GetWindow()->ShowInactive();
  EXPECT_FALSE(first->GetWindow()->IsVisible());
  EXPECT_FALSE(second->GetWindow()->IsVisible());
  // Active-tab mutation must not consume a deferred first Show.
  chrome::AddAndReturnTabAt(first, GURL("about:blank"), -1, true);
  NSView* first_header = Attach(first_id);
  NSView* second_header = Attach(second_id);
  ASSERT_EQ(1, barc_window_admit_discovered(first_id,
                                           (__bridge void*)first_header));
  ASSERT_EQ(1, barc_window_admit_discovered(second_id,
                                           (__bridge void*)second_header));
  EXPECT_TRUE(first->GetWindow()->IsVisible());
  EXPECT_TRUE(second->GetWindow()->IsVisible());
  BarcDiscoveryWindow row{};
  ASSERT_EQ(1, barc_window_discovery_state(second_id, &row));
  EXPECT_FALSE(row.flags & BARC_DISCOVERY_AWAITING_ADMISSION);
  EXPECT_FALSE(row.flags & BARC_DISCOVERY_PHYSICAL_ACTIVE);
  // Hide explicitly cancels presentation, while admission may still succeed.
  auto* hidden = NewNormal();
  ASSERT_TRUE(hidden);
  chrome::AddAndReturnTabAt(hidden, GURL("about:blank"), -1, true);
  hidden->GetWindow()->Show();
  hidden->GetWindow()->Hide();
  const int32_t hidden_id = hidden->GetSessionID().id();
  NSView* hidden_header = Attach(hidden_id);
  ASSERT_EQ(1, barc_window_admit_discovered(hidden_id,
                                           (__bridge void*)hidden_header));
  EXPECT_FALSE(hidden->GetWindow()->IsVisible());
  EXPECT_EQ(0, barc_window_admit_discovered(hidden_id,
                                           (__bridge void*)first_header));
  // Popups retain their ordinary Chrome presentation and no product header.
  auto* popup = CreateBrowserWindow(BrowserWindowCreateParams(
      BrowserWindowInterface::TYPE_POPUP, browser()->GetProfile(), false));
  ASSERT_TRUE(popup);
  chrome::AddAndReturnTabAt(popup, GURL("about:blank"), -1, true);
  popup->GetWindow()->ShowInactive();
  EXPECT_TRUE(popup->GetWindow()->IsVisible());
  EXPECT_EQ(1, barc_window_select(popup->GetSessionID().id()));
  EXPECT_EQ(nullptr, BrowserView::GetBrowserViewForBrowser(popup)->barc_native_shell());
  EXPECT_EQ(0, barc_window_admit_discovered(popup->GetSessionID().id(),
                                           (__bridge void*)first_header));
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       SnapshotCoalescesAndTracksFactoryMembership) {
  DiscoveryEvents events;
  const uint64_t token = barc_discovery_observe(DiscoveryEvents::Receive, &events);
  ASSERT_NE(0u, token);
  EXPECT_EQ(0u, barc_discovery_observe(DiscoveryEvents::Receive, &events));
  EXPECT_TRUE(events.revisions.empty());
  base::RunLoop().RunUntilIdle();
  ASSERT_EQ(1u, events.revisions.size());
  const int32_t id = browser()->GetSessionID().id();
  BarcDiscoveryWindow direct{};
  ASSERT_EQ(1, barc_window_discovery_state(id, &direct));
  const int32_t created = barc_tab_create(id, "about:blank", 1);
  ASSERT_GT(created, 0);
  DiscoveryRows rows;
  rows.Read();
  auto found = std::ranges::find(rows.tabs, created, &BarcDiscoveryTab::tab);
  ASSERT_NE(rows.tabs.end(), found);
  EXPECT_TRUE(found->flags & BARC_DISCOVERY_TAB_APP_FACTORY);
  EXPECT_TRUE(found->flags & BARC_DISCOVERY_ACTIVE_TAB);
  ASSERT_EQ(1, barc_window_discovery_state(id, &direct));
  EXPECT_EQ(created, direct.active_tab);
  // Capacity refusal must not expose partial rows.
  BarcDiscoveryWindow untouched{};
  untouched.window = -123;
  BarcDiscoverySnapshot counts{};
  EXPECT_EQ(BARC_DISCOVERY_READ_CAPACITY,
            barc_discovery_snapshot(&untouched, 1, nullptr, 0, &counts));
  EXPECT_EQ(-123, untouched.window);
  base::RunLoop().RunUntilIdle();
  const size_t settled = events.revisions.size();
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(settled, events.revisions.size());
  // Same-count replacement is structural, even though both count queries match.
  const size_t previous_count = rows.tabs.size();
  ASSERT_EQ(1, barc_tab_close(id, created));
  const int32_t replacement = barc_tab_create(id, "about:blank", 0);
  ASSERT_GT(replacement, 0);
  rows.Read();
  EXPECT_EQ(previous_count, rows.tabs.size());
  EXPECT_EQ(rows.tabs.end(), std::ranges::find(rows.tabs, created, &BarcDiscoveryTab::tab));
  EXPECT_NE(rows.tabs.end(), std::ranges::find(rows.tabs, replacement, &BarcDiscoveryTab::tab));
  base::RunLoop().RunUntilIdle();
  EXPECT_GT(events.revisions.size(), settled);
  // Pending delivery is canceled, and self-unsubscription admits a new owner.
  events.unsubscribe = true;
  auto* closing = NewNormal();
  ASSERT_TRUE(closing);
  chrome::AddAndReturnTabAt(closing, GURL("about:blank"), -1, true);
  events.close_window = closing->GetSessionID().id();
  auto closing_alive = closing->GetWeakPtr();
  base::RunLoop().RunUntilIdle();
  ASSERT_TRUE(base::test::RunUntil([&] { return !closing_alive; }));
  const size_t canceled = events.revisions.size();
  chrome::AddAndReturnTabAt(browser(), GURL("about:blank"), -1, false);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(canceled, events.revisions.size());
  const uint64_t pending = barc_discovery_observe(DiscoveryEvents::Receive, &events);
  ASSERT_NE(0u, pending);
  barc_discovery_unobserve(pending);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(canceled, events.revisions.size());
}

IN_PROC_BROWSER_TEST_F(BarcDiscoveryBrowserTest,
                       PhysicalIdentitySurvivesOwnerAndOpenerStaysNative) {
  const int32_t work = Open("5a33ed34-5816-4a1c-b20c-eed936e4ee73", 0,
                            BARC_PROFILE_BLANK);
  ASSERT_GT(work, 0);
  const int32_t personal = Open("74446f9e-12fc-45d8-bb7f-33640823fe44", work,
                                BARC_PROFILE_BLANK);
  ASSERT_GT(personal, 0);
  BarcDiscoveryWindow work_row{}, personal_row{};
  ASSERT_EQ(1, barc_window_discovery_state(work, &work_row));
  ASSERT_EQ(1, barc_window_discovery_state(personal, &personal_row));
  const uint64_t group = work_row.physical_group;
  EXPECT_EQ(group, personal_row.physical_group);
  EXPECT_EQ(work, personal_row.selected_client);
  EXPECT_EQ(BARC_DISCOVERY_REGULAR, personal_row.profile_kind);
  EXPECT_STREQ("74446f9e-12fc-45d8-bb7f-33640823fe44",
               personal_row.regular_profile_uuid);
  EXPECT_TRUE(work_row.flags & BARC_DISCOVERY_WINDOW_APP_FACTORY);
  EXPECT_FALSE(personal_row.flags & BARC_DISCOVERY_AWAITING_ADMISSION);
  const int32_t initial_tab = barc_window_tab_at(personal, 0);
  DiscoveryRows rows;
  rows.Read();
  auto initial = std::ranges::find(rows.tabs, initial_tab, &BarcDiscoveryTab::tab);
  ASSERT_NE(rows.tabs.end(), initial);
  EXPECT_TRUE(initial->flags & BARC_DISCOVERY_TAB_APP_FACTORY);
  auto* work_owner = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(work));
  ui_test_utils::BrowserDestroyedObserver closed(work_owner);
  ASSERT_EQ(1, barc_window_close(work));
  closed.Wait();
  EXPECT_EQ(0, barc_window_discovery_state(work, &work_row));
  ASSERT_EQ(1, barc_window_discovery_state(personal, &personal_row));
  EXPECT_EQ(group, personal_row.physical_group);
  EXPECT_EQ(personal, personal_row.selected_client);
  // A Chrome-created popup is not an app-factory tab/window. Its actual JS
  // opener is reported without selecting or showing a product header.
  auto* opener = browser()->GetTabStripModel()->GetActiveWebContents();
  content::WebContentsAddedObserver added;
  ASSERT_TRUE(content::ExecJs(opener,
      "window.open('about:blank', 'catalog-popup', 'popup,width=400,height=300')"));
  auto* popup_contents = added.GetWebContents();
  ASSERT_TRUE(popup_contents);
  auto* popup_tab = tabs::TabInterface::GetFromContents(popup_contents);
  ASSERT_TRUE(popup_tab);
  auto* popup_owner = popup_tab->GetBrowserWindowInterface();
  ASSERT_TRUE(popup_owner);
  BarcDiscoveryWindow popup_row{};
  ASSERT_EQ(1, barc_window_discovery_state(popup_owner->GetSessionID().id(),
                                          &popup_row));
  EXPECT_EQ(BARC_DISCOVERY_POPUP, popup_row.kind);
  EXPECT_FALSE(popup_row.flags & BARC_DISCOVERY_WINDOW_APP_FACTORY);
  rows.Read();
  auto popup = std::ranges::find(rows.tabs, popup_tab->GetHandle().raw_value(),
                                 &BarcDiscoveryTab::tab);
  ASSERT_NE(rows.tabs.end(), popup);
  EXPECT_FALSE(popup->flags & BARC_DISCOVERY_TAB_APP_FACTORY);
  EXPECT_EQ(tabs::TabInterface::GetFromContents(opener)->GetHandle().raw_value(),
            popup->opener_tab);
}
