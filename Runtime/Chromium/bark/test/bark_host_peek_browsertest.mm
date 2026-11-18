#import <AppKit/AppKit.h>

#include <algorithm>
#include <set>
#include <string>
#include <vector>

#include "bark/bridge/barc_bridge_functions.h"
#include "bark/bridge/barc_runtime_startup.h"
#include "bark/browser/ui/bark_window_host.h"
#include "base/base_switches.h"
#include "base/command_line.h"
#include "base/test/test_future.h"
#include "base/test/run_until.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/renderer_context_menu/render_view_context_menu_test_util.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/hit_test_region_observer.h"
#include "third_party/blink/public/common/input/web_mouse_event.h"
#include "ui/base/base_window.h"
#include "ui/base/test/ui_controls.h"
#include "ui/gfx/mac/coordinate_conversion.h"

namespace {

struct PeekRequest {
  static void Receive(void* context, uint64_t, int32_t event, int32_t,
                      int32_t, const char* url, const char*, int32_t serial,
                      uint32_t) {
    if (event == BARC_TAB_PEEK_REQUESTED) {
      auto* request = static_cast<PeekRequest*>(context);
      ++request->count;
      request->serial = serial;
      request->url = url;
    }
  }

  int count = 0;
  int32_t serial = 0;
  std::string url;
};

}  // namespace

class BarkHostPeekBrowserTest : public InProcessBrowserTest {
 public:
  BarkHostPeekBrowserTest() { SetAllowFeaturesSwitches(true); }

  void SetUp() override {
    barc_set_runtime_browser_target_callback(
        [](int32_t, const char*, int32_t, int32_t,
           BarcApplicationTarget*, void*) -> int32_t { return 0; },
        nullptr);
    barc_set_runtime_ready_callback(
        [](void*) {
          int32_t initial = 0;
          GlobalBrowserCollection::GetInstance()->ForEach(
              [&](BrowserWindowInterface* window) {
                if (window->GetType() != BrowserWindowInterface::TYPE_NORMAL) {
                  return true;
                }
                initial = window->GetSessionID().id();
                return false;
              });
          CHECK_GT(initial, 0);
          const int32_t window = barc_window_new_peer(initial);
          CHECK_GT(window, 0);
          NSView* root =
              [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
          CHECK_EQ(1, barc_window_set_root_view(window, (__bridge void*)root));
          barc_runtime_complete_startup(window);
        },
        nullptr);
    InProcessBrowserTest::SetUp();
  }

  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-native-shell");
    command_line->AppendSwitch("barc-shared-native-window");
    command_line->AppendSwitchASCII("bark-window", "host");
    command_line->AppendSwitchASCII(switches::kDisableFeatures, "MediaRouter");
  }

  void TearDownOnMainThread() override {
    if (peek_observation_) {
      barc_tab_unobserve(peek_observation_);
    }
    if (source_observation_) {
      barc_tab_unobserve(source_observation_);
    }
    InProcessBrowserTest::TearDownOnMainThread();
  }

 protected:
  void OpenSource() {
    ASSERT_TRUE(barc::CanResolveApplicationBrowser());
    ASSERT_TRUE(embedded_test_server()->Start());
    window_ = barc_window_new_peer(browser()->GetSessionID().id());
    ASSERT_GT(window_, 0);
    ASSERT_TRUE(Host());
    root_ = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    ASSERT_EQ(1, barc_window_set_root_view(window_, (__bridge void*)root_));
    source_ = barc_tab_create(window_, SourceURL().spec().c_str(), 1);
    ASSERT_NE(0, source_);
    ASSERT_TRUE(content::WaitForLoadStop(Contents(source_)));
    ASSERT_EQ(1, barc_window_show(window_));
    ASSERT_NE(nil, Mount(source_));
    ASSERT_EQ(Contents(source_), Tabs()->GetActiveWebContents());
    ASSERT_TRUE(content::ExecJs(Contents(source_), R"(
      document.body.innerHTML = '<a href="/title2.html" style="position:fixed;'
          + 'left:0;top:0;width:200px;height:60px;display:block">link</a>';
    )"));
    content::WaitForHitTestData(Contents(source_)->GetPrimaryMainFrame());
    source_observation_ = barc_tab_observe(window_, source_, PeekRequest::Receive,
                                           &source_request_);
    ASSERT_NE(0u, source_observation_);
    ASSERT_EQ(1, barc_tab_enable_peek(source_observation_,
        BARC_TAB_PEEK_CAPABLE | BARC_TAB_PEEK_ON_SHIFT_CLICK));
  }

  GURL SourceURL() { return embedded_test_server()->GetURL("/title1.html"); }
  GURL TargetURL() { return embedded_test_server()->GetURL("/title2.html"); }

  BrowserWindowInterface* Owner() {
    return GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
        SessionID::FromSerializedValue(window_));
  }

  bark::BarkWindowHost* Host() {
    return bark::BarkWindowHost::ForBrowser(Owner());
  }

  TabStripModel* Tabs() { return Owner()->GetTabStripModel(); }

  content::WebContents* Contents(int32_t tab) {
    auto* page = tabs::TabHandle(tab).Get();
    return page ? page->GetContents() : nullptr;
  }

  NSView* Mount(int32_t tab) {
    NSView* view = (__bridge NSView*)barc_tab_native_view(window_, tab);
    if (view) {
      view.frame = root_.bounds;
      [root_ addSubview:view];
    }
    return view;
  }

  void ClickLink(int modifiers) {
    content::SimulateMouseClickAt(Contents(source_), modifiers,
                                  blink::WebMouseEvent::Button::kLeft,
                                  gfx::Point(30, 20));
  }

  void RequestFromMenu(int32_t tab, bool present = true) {
    auto* contents = Contents(tab);
    auto* frame = contents->GetPrimaryMainFrame();
    content::ContextMenuParams params;
    params.page_url = contents->GetLastCommittedURL();
    params.frame_url = params.page_url;
    params.frame_origin = frame->GetLastCommittedOrigin();
    params.link_url = params.unfiltered_link_url = TargetURL();
    TestRenderViewContextMenu menu(*frame, params);
    menu.Init();
    EXPECT_EQ(present, menu.IsItemPresent(IDC_CONTENT_CONTEXT_OPENLINKINPEEK));
    if (present && menu.IsItemPresent(IDC_CONTENT_CONTEXT_OPENLINKINPEEK)) {
      EXPECT_TRUE(menu.IsCommandIdEnabled(IDC_CONTENT_CONTEXT_OPENLINKINPEEK));
      menu.ExecuteCommand(IDC_CONTENT_CONTEXT_OPENLINKINPEEK, 0);
    }
  }

  int CreatePeek(bool accept = true) {
    accept_ = accept;
    return barc_tab_create_peek(source_observation_, source_request_.serial,
        [](void* context, int32_t window, int32_t tab) -> int {
          auto* test = static_cast<BarkHostPeekBrowserTest*>(context);
          EXPECT_EQ(test->window_, window);
          EXPECT_EQ(test->Contents(test->source_), test->Tabs()->GetActiveWebContents());
          auto* page = test->Contents(tab);
          if (!page) {
            ADD_FAILURE();
            return 0;
          }
          EXPECT_TRUE(page->GetController().IsInitialBlankNavigation());
          EXPECT_EQ(nullptr, page->GetController().GetPendingEntry());
          EXPECT_FALSE(page->HasOpener());
          test->peek_ = tab;
          if (!test->accept_) {
            return 0;
          }
          test->peek_observation_ = barc_tab_observe(
              window, tab, PeekRequest::Receive, &test->peek_request_);
          EXPECT_NE(0u, test->peek_observation_);
          return test->peek_observation_ != 0;
        }, this);
  }

  BarcDiscoveryTab Discover(int32_t tab) {
    BarcDiscoverySnapshot snapshot{sizeof(BarcDiscoverySnapshot)};
    if (barc_discovery_snapshot(nullptr, 0, nullptr, 0, &snapshot) !=
        BARC_DISCOVERY_READ_CAPACITY) {
      ADD_FAILURE();
      return {};
    }
    std::vector<BarcDiscoveryWindow> windows(
        snapshot.window_count, {.size = sizeof(BarcDiscoveryWindow)});
    std::vector<BarcDiscoveryTab> tabs(
        snapshot.tab_count, {.size = sizeof(BarcDiscoveryTab)});
    EXPECT_EQ(BARC_DISCOVERY_READ_OK, barc_discovery_snapshot(
        windows.data(), windows.size(), tabs.data(), tabs.size(), &snapshot));
    auto row = std::ranges::find(tabs, tab, &BarcDiscoveryTab::tab);
    return row != tabs.end() ? *row : BarcDiscoveryTab{};
  }

  void PlayAudio(int32_t tab) {
    ASSERT_EQ(true, content::EvalJs(Contents(tab), R"((async () => {
      window.peekAudio = new Audio('/media/pink_noise_140ms.wav');
      peekAudio.loop = true;
      await peekAudio.play();
      return true;
    })())"));
  }

  int32_t window_ = 0;
  int32_t source_ = 0;
  int32_t peek_ = 0;
  NSView* __strong root_ = nil;
  PeekRequest source_request_;
  PeekRequest peek_request_;
  uint64_t source_observation_ = 0;
  uint64_t peek_observation_ = 0;
  bool accept_ = true;
};

IN_PROC_BROWSER_TEST_F(BarkHostPeekBrowserTest,
                       ShiftAndOptionClickUseTheRealLinkEntryPoints) {
  ASSERT_NO_FATAL_FAILURE(OpenSource());
  const size_t browsers = GlobalBrowserCollection::GetInstance()->GetSize();
  auto download_count = [&] {
    std::vector<raw_ptr<download::DownloadItem, VectorExperimental>> downloads;
    Owner()->GetProfile()->GetDownloadManager()->GetAllDownloads(&downloads);
    return downloads.size();
  };
  const size_t downloads = download_count();
  ClickLink(blink::WebInputEvent::kShiftKey);
  ASSERT_TRUE(base::test::RunUntil([&] { return source_request_.count == 1; }));
  EXPECT_EQ(TargetURL().spec(), source_request_.url);
  ClickLink(blink::WebInputEvent::kAltKey);
  ASSERT_TRUE(base::test::RunUntil([&] { return source_request_.count == 2; }));
  EXPECT_EQ(TargetURL().spec(), source_request_.url);
  EXPECT_EQ(browsers, GlobalBrowserCollection::GetInstance()->GetSize());
  EXPECT_EQ(SourceURL(), Contents(source_)->GetLastCommittedURL());
  EXPECT_EQ(downloads, download_count());
}

IN_PROC_BROWSER_TEST_F(BarkHostPeekBrowserTest,
                       ShiftClickWithPeekOffOpensBarkWindow) {
  ASSERT_NO_FATAL_FAILURE(OpenSource());
  ASSERT_EQ(1, barc_tab_enable_peek(source_observation_, BARC_TAB_PEEK_CAPABLE));
  auto* collection = GlobalBrowserCollection::GetInstance();
  std::set<int32_t> existing;
  collection->ForEach([&](BrowserWindowInterface* window) {
    existing.insert(window->GetSessionID().id());
    return true;
  });
  ClickLink(blink::WebInputEvent::kShiftKey);
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return collection->GetSize() == existing.size() + 1; }));
  BrowserWindowInterface* opened = nullptr;
  collection->ForEach([&](BrowserWindowInterface* window) {
    if (!existing.contains(window->GetSessionID().id())) {
      opened = window;
      return false;
    }
    return true;
  });
  ASSERT_NE(nullptr, opened);
  EXPECT_NE(nullptr, bark::BarkWindowHost::ForBrowser(opened));
  EXPECT_EQ(BrowserWindowInterface::TYPE_NORMAL, opened->GetType());
  EXPECT_EQ(Owner()->GetProfile(), opened->GetProfile());
  auto* target = opened->GetTabStripModel()->GetActiveWebContents();
  ASSERT_NE(nullptr, target);
  ASSERT_TRUE(content::WaitForLoadStop(target));
  EXPECT_EQ(TargetURL(), target->GetLastCommittedURL());
  EXPECT_EQ(0, source_request_.count);
  EXPECT_EQ(SourceURL(), Contents(source_)->GetLastCommittedURL());
}

class BarkHostPeekPaneBrowserTest : public BarkHostPeekBrowserTest {
 public:
  void SetUp() override {
    ui_controls::EnableUIControls();
    BarkHostPeekBrowserTest::SetUp();
  }
};

IN_PROC_BROWSER_TEST_F(BarkHostPeekPaneBrowserTest,
                       ShiftClickFromAnInactivePaneSelectsItAndRequestsPeek) {
  ASSERT_NO_FATAL_FAILURE(OpenSource());
  NSView* source_view = (__bridge NSView*)barc_tab_native_view(window_, source_);
  source_view.frame = NSMakeRect(0, 0, 395, 600);
  const int32_t other = barc_tab_create(window_, SourceURL().spec().c_str(), 1);
  ASSERT_NE(0, other);
  NSView* other_view = Mount(other);
  ASSERT_NE(nil, other_view);
  other_view.frame = NSMakeRect(405, 0, 395, 600);
  NSWindow* window = source_view.window;
  ASSERT_NE(nil, window);
  [NSApp activateIgnoringOtherApps:YES];
  Owner()->GetWindow()->Activate();
  ASSERT_TRUE(base::test::RunUntil([&] { return window.isKeyWindow; }));
  ASSERT_EQ(Contents(other), Tabs()->GetActiveWebContents());

  const gfx::Rect source_bounds = gfx::ScreenRectFromNSRect(
      [window convertRectToScreen:[source_view convertRect:source_view.bounds
                                                  toView:nil]]);
  const gfx::NativeWindow native_window(window);
  base::test::TestFuture<void> moved;
  ASSERT_TRUE(ui_controls::SendMouseMoveNotifyWhenDone(
      source_bounds.x() + 30, source_bounds.y() + 20, moved.GetCallback(),
      native_window));
  ASSERT_TRUE(moved.Wait());
  base::test::TestFuture<void> clicked;
  ASSERT_TRUE(ui_controls::SendMouseEventsNotifyWhenDone(
      ui_controls::LEFT, ui_controls::DOWN | ui_controls::UP,
      clicked.GetCallback(), ui_controls::kShift, native_window));
  ASSERT_TRUE(clicked.Wait());
  ASSERT_TRUE(base::test::RunUntil([&] { return source_request_.count == 1; }));
  EXPECT_EQ(Contents(source_), Tabs()->GetActiveWebContents());
  EXPECT_EQ(TargetURL().spec(), source_request_.url);
}


IN_PROC_BROWSER_TEST_F(BarkHostPeekBrowserTest,
                       MenuAdmissionCreatesOneBackgroundPageAndPromotesIt) {
  ASSERT_NO_FATAL_FAILURE(OpenSource());
  const size_t browsers = GlobalBrowserCollection::GetInstance()->GetSize();
  const size_t clients = Host()->clients().size();
  const int tabs = Tabs()->count();
  RequestFromMenu(source_);
  ASSERT_EQ(1, source_request_.count);
  EXPECT_EQ(TargetURL().spec(), source_request_.url);
  ASSERT_EQ(1, CreatePeek());
  EXPECT_EQ(0, CreatePeek());
  EXPECT_EQ(browsers, GlobalBrowserCollection::GetInstance()->GetSize());
  EXPECT_EQ(clients, Host()->clients().size());
  EXPECT_EQ(tabs + 1, Tabs()->count());
  EXPECT_EQ(Contents(source_), Tabs()->GetActiveWebContents());
  ASSERT_TRUE(content::WaitForLoadStop(Contents(peek_)));
  EXPECT_EQ(TargetURL(), Contents(peek_)->GetLastCommittedURL());
  EXPECT_EQ(SourceURL().spec(), content::EvalJs(Contents(peek_), "document.referrer"));
  auto row = Discover(peek_);
  EXPECT_EQ(window_, row.window);
  EXPECT_EQ(source_, row.peek_source_tab);
  EXPECT_TRUE(row.flags & BARC_DISCOVERY_TAB_PEEK);

  ASSERT_NE(nil, Mount(peek_));
  ASSERT_EQ(1, barc_tab_select(window_, peek_));
  ASSERT_EQ(1, barc_tab_enable_peek(peek_observation_, BARC_TAB_PEEK_CAPABLE));
  RequestFromMenu(peek_, false);
  EXPECT_EQ(0, peek_request_.count);
  auto* contents = Contents(peek_);
  const auto document = contents->GetPrimaryMainFrame()->GetDocumentToken();
  ASSERT_TRUE(content::ExecJs(contents, "window.peekDraft = 'retained';"));
  ASSERT_EQ(1, barc_tab_transfer_with_admission(window_, peek_, window_,
      [](void*, int32_t, int32_t) -> int { return 1; }, nullptr));
  EXPECT_EQ(contents, Contents(peek_));
  EXPECT_EQ(document, contents->GetPrimaryMainFrame()->GetDocumentToken());
  EXPECT_EQ("retained", content::EvalJs(contents, "peekDraft"));
  row = Discover(peek_);
  EXPECT_EQ(window_, row.window);
  EXPECT_EQ(0, row.peek_source_tab);
  EXPECT_FALSE(row.flags & BARC_DISCOVERY_TAB_PEEK);
}

IN_PROC_BROWSER_TEST_F(BarkHostPeekBrowserTest,
                       RejectedAdmissionRemovesOnlyTheBlankAndCloseSelectsSource) {
  ASSERT_NO_FATAL_FAILURE(OpenSource());
  const int32_t neighbor = barc_tab_create(window_, "about:blank", 0);
  ASSERT_NE(0, neighbor);
  ASSERT_EQ(1, barc_tab_select(window_, source_));
  const int tabs = Tabs()->count();
  RequestFromMenu(source_);
  ASSERT_EQ(1, source_request_.count);
  EXPECT_EQ(0, CreatePeek(false));
  ASSERT_NE(0, peek_);
  EXPECT_FALSE(Contents(peek_));
  EXPECT_EQ(tabs, Tabs()->count());
  EXPECT_EQ(Contents(source_), Tabs()->GetActiveWebContents());

  RequestFromMenu(source_);
  ASSERT_EQ(2, source_request_.count);
  ASSERT_EQ(1, CreatePeek());
  ASSERT_TRUE(content::WaitForLoadStop(Contents(peek_)));
  ASSERT_NE(nil, Mount(peek_));
  ASSERT_EQ(1, barc_tab_select(window_, peek_));
  EXPECT_EQ(Contents(peek_), Tabs()->GetActiveWebContents());
  ASSERT_EQ(1, barc_tab_close_selecting(peek_observation_, source_));
  EXPECT_FALSE(Contents(peek_));
  EXPECT_TRUE(Contents(neighbor));
  EXPECT_EQ(Contents(source_), Tabs()->GetActiveWebContents());
}

IN_PROC_BROWSER_TEST_F(BarkHostPeekBrowserTest, AudioPausesOnlyForHiddenPeek) {
  ASSERT_NO_FATAL_FAILURE(OpenSource());
  RequestFromMenu(source_);
  ASSERT_EQ(1, source_request_.count);
  ASSERT_EQ(1, CreatePeek());
  ASSERT_TRUE(content::WaitForLoadStop(Contents(peek_)));
  NSView* peek_view = Mount(peek_);
  ASSERT_NE(nil, peek_view);
  auto* contents = Contents(peek_);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents->GetVisibility() != content::Visibility::HIDDEN;
  }));
  ASSERT_NO_FATAL_FAILURE(PlayAudio(peek_));
  ASSERT_TRUE(base::test::RunUntil([&] { return contents->IsCurrentlyAudible(); }));
  [peek_view removeFromSuperview];
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents->GetVisibility() == content::Visibility::HIDDEN;
  }));
  ASSERT_TRUE(base::test::RunUntil([&] { return !contents->IsCurrentlyAudible(); }));
  EXPECT_EQ(true, content::EvalJs(contents, "peekAudio.paused"));
  ASSERT_NO_FATAL_FAILURE(PlayAudio(peek_));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(contents, "peekAudio.paused").ExtractBool();
  }));
  ASSERT_NE(nil, Mount(peek_));
  EXPECT_EQ(true, content::EvalJs(contents, "peekAudio.paused"));

  auto* source = Contents(source_);
  ASSERT_NO_FATAL_FAILURE(PlayAudio(source_));
  ASSERT_TRUE(base::test::RunUntil([&] { return source->IsCurrentlyAudible(); }));
  NSView* source_view = (__bridge NSView*)barc_tab_native_view(window_, source_);
  [source_view removeFromSuperview];
  ASSERT_TRUE(base::test::RunUntil([&] {
    return source->GetVisibility() == content::Visibility::HIDDEN;
  }));
  EXPECT_EQ(false, content::EvalJs(source, "peekAudio.paused"));
}
