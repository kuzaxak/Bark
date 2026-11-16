#import <AppKit/AppKit.h>

#include <cmath>
#include <limits>
#include <set>
#include <string>
#include <vector>

#include "bark/bridge/barc_bridge_functions.h"
#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_window_factory.h"
#include "bark/browser/ui/bark_window_host.h"
#include "base/command_line.h"
#include "base/run_loop.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/side_panel/side_panel_entry_id.h"
#include "chrome/browser/ui/side_panel/side_panel_entry_key.h"
#include "chrome/browser/ui/side_panel/side_panel_ui.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "components/permissions/permission_request_manager.h"
#include "components/permissions/test/permission_request_observer.h"
#include "ui/base/test/scoped_fake_nswindow_fullscreen.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/javascript_dialogs/app_modal_dialog_controller.h"
#include "components/javascript_dialogs/app_modal_dialog_view.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/test_utils.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "testing/gtest_mac.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget.h"

@interface NSWindow (BarkWindowHostTest)
- (BOOL)_hasActiveAppearance;
- (BOOL)_hasActiveAppearanceForStandardWindowButton:(NSWindowButton)button;
@end

namespace {

BrowserWindowInterface* FindBrowser(int32_t id) {
  return GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(id));
}

void CollectClassNames(views::View* view, std::set<std::string>* names) {
  names->insert(std::string(view->GetClassName()));
  for (views::View* child : view->children()) {
    CollectClassNames(child, names);
  }
}

content::WebContents* TabContents(int32_t tab) {
  auto* interface = tabs::TabHandle(tab).Get();
  return interface ? interface->GetContents() : nullptr;
}

struct HostEvents {
  struct Row {
    BarcWindowHostEvent event;
    bool watched_alive;
  };
  ~HostEvents() { barc_window_host_unobserve(token); }
  bool Observe(int32_t window) {
    token = barc_window_host_observe(window, &HostEvents::Receive, this);
    return token != 0;
  }
  uint64_t token = 0;
  std::vector<Row> rows;
  __weak NSView* watched = nil;
  static void Receive(const BarcWindowHostEvent* event, void* context) {
    auto* self = static_cast<HostEvents*>(context);
    self->rows.push_back({*event, self->watched != nil});
  }
  std::vector<int32_t> Fullscreen() const {
    std::vector<int32_t> kinds;
    for (const auto& row : rows) {
      if (row.event.kind == BARC_WINDOW_HOST_FULLSCREEN_CHANGED) {
        kinds.push_back(row.event.fullscreen);
      }
    }
    return kinds;
  }
  std::vector<const Row*> Of(int32_t kind) const {
    std::vector<const Row*> found;
    for (const auto& row : rows) {
      if (row.event.kind == kind) {
        found.push_back(&row);
      }
    }
    return found;
  }
  const Row* Retired(int32_t tab) const {
    for (const auto& row : rows) {
      if (row.event.kind == BARC_WINDOW_HOST_PAGE_VIEW_RETIRED &&
          row.event.tab == tab) {
        return &row;
      }
    }
    return nullptr;
  }
};

uint64_t DiscoveryRevision() {
  BarcDiscoverySnapshot snapshot = {.size = sizeof(BarcDiscoverySnapshot)};
  barc_discovery_snapshot(nullptr, 0, nullptr, 0, &snapshot);
  return snapshot.revision;
}

int InnerWidth(content::WebContents* contents) {
  return content::EvalJs(contents, "innerWidth").ExtractInt();
}

// A traffic light's frame in its window, with a top-left origin.
NSRect LightFrame(NSWindow* window, NSWindowButton type) {
  NSButton* button = [window standardWindowButton:type];
  NSRect frame = [button convertRect:button.bounds toView:nil];
  frame.origin.y = NSHeight(window.frame) - NSMaxY(frame);
  return frame;
}

// The close light's top-left corner, after checking that the other two follow
// it at AppKit's 20 pt pitch on the same row.
NSPoint LightsOrigin(NSWindow* window) {
  const NSRect close = LightFrame(window, NSWindowCloseButton);
  const NSRect minimize = LightFrame(window, NSWindowMiniaturizeButton);
  const NSRect zoom = LightFrame(window, NSWindowZoomButton);
  EXPECT_EQ(NSMinX(close) + 20, NSMinX(minimize));
  EXPECT_EQ(NSMinX(close) + 40, NSMinX(zoom));
  EXPECT_EQ(NSMinY(close), NSMinY(minimize));
  EXPECT_EQ(NSMinY(close), NSMinY(zoom));
  return close.origin;
}

void WaitForFullscreen(NSWindow* window, bool fullscreen) {
  NSString* name = fullscreen ? NSWindowDidEnterFullScreenNotification
                              : NSWindowDidExitFullScreenNotification;
  base::RunLoop loop;
  base::OnceClosure quit = loop.QuitClosure();
  __block base::OnceClosure block_quit = std::move(quit);
  id observer = [NSNotificationCenter.defaultCenter
      addObserverForName:name
                  object:window
                   queue:nil
              usingBlock:^(NSNotification*) {
                if (block_quit) {
                  std::move(block_quit).Run();
                }
              }];
  [window toggleFullScreen:nil];
  loop.Run();
  [NSNotificationCenter.defaultCenter removeObserver:observer];
}

}  // namespace

class BarkWindowHostBrowserTest : public InProcessBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-native-shell");
    command_line->AppendSwitch("barc-shared-native-window");
    command_line->AppendSwitchASCII("bark-window", "host");
  }

 protected:
  int32_t OpenHostWindow() {
    const int32_t id = barc_window_new_peer(browser()->GetSessionID().id());
    EXPECT_GT(id, 0);
    return id;
  }
  bark::BarkWindowHost* HostOf(int32_t id) {
    return bark::BarkWindowHost::ForBrowser(FindBrowser(id));
  }
  // A shown host window with the app's root view and one loaded tab.
  int32_t OpenPage(int32_t window, NSView* root, const char* path) {
    EXPECT_EQ(1, barc_window_set_root_view(window, (__bridge void*)root));
    const int32_t tab = barc_tab_create(
        window, embedded_test_server()->GetURL(path).spec().c_str(), 1);
    EXPECT_NE(0, tab);
    EXPECT_TRUE(content::WaitForLoadStop(TabContents(tab)));
    return tab;
  }
  NSView* PageView(int32_t window, int32_t tab) {
    return (__bridge NSView*)barc_tab_native_view(window, tab);
  }
  NSView* Place(int32_t window, int32_t tab, NSView* root) {
    NSView* page = PageView(window, tab);
    EXPECT_NE(nil, page);
    page.frame = root.bounds;
    [root addSubview:page];
    return page;
  }
  // A window of the app's profile `uuid`; with `owner`, the profile joins that
  // window as another client.
  int32_t OpenProfile(const char* uuid, int32_t owner = 0) {
    using Opened = base::test::TestFuture<barc_profile_status, int32_t>;
    Opened opened;
    auto completed = [](barc_profile_status status, int32_t window,
                        void* data) {
      static_cast<Opened*>(data)->SetValue(status, window);
    };
    if (owner) {
      barc_profile_open_in_native_window(owner, uuid, BARC_PROFILE_BLANK,
                                         completed, &opened);
    } else {
      barc_profile_open_window(uuid, BARC_PROFILE_BLANK, completed, &opened);
    }
    EXPECT_EQ(BARC_PROFILE_OK, opened.Get<0>());
    return opened.Get<1>();
  }
};

constexpr char kWorkProfile[] = "6f0bd61e-9a43-4b7f-8d8e-56b1a9a0c2d4";
constexpr char kHomeProfile[] = "0d3b5c1e-8f2a-4e6b-9a7c-2b4d6e8f0a1c";

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, NormalBrowserGetsHostWindow) {
  EXPECT_NE(nullptr, BrowserView::GetBrowserViewForBrowser(browser()));
  EXPECT_EQ(nullptr, bark::BarkBrowserWindow::FromBrowser(browser()));

  const int32_t peer = OpenHostWindow();
  auto* created = FindBrowser(peer);
  ASSERT_NE(nullptr, created);
  EXPECT_EQ(nullptr, BrowserView::GetBrowserViewForBrowser(created));
  auto* window = bark::BarkBrowserWindow::FromBrowser(created);
  ASSERT_NE(nullptr, window);
  EXPECT_EQ(static_cast<BrowserWindow*>(window),
            BrowserWindow::FromBrowser(created));
  ASSERT_TRUE(created->GetWindow()->GetNativeWindow());
  EXPECT_EQ(window->host(), bark::BarkWindowHost::ForNativeWindow(
                                created->GetWindow()->GetNativeWindow()));
  EXPECT_EQ(created, GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
                         created->GetWindow()->GetNativeWindow()));

  using Result = base::test::TestFuture<barc_profile_status, int32_t>;
  Result opened;
  barc_profile_open_window(
      "6f0bd61e-9a43-4b7f-8d8e-56b1a9a0c2d4", BARC_PROFILE_BLANK,
      [](barc_profile_status status, int32_t window, void* data) {
        static_cast<Result*>(data)->SetValue(status, window);
      },
      &opened);
  ASSERT_EQ(BARC_PROFILE_OK, opened.Get<0>());
  auto* profile_window = FindBrowser(opened.Get<1>());
  ASSERT_NE(nullptr, profile_window);
  EXPECT_NE(nullptr, bark::BarkBrowserWindow::FromBrowser(profile_window));
  EXPECT_EQ(nullptr, BrowserView::GetBrowserViewForBrowser(profile_window));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, NoStockChromeViewsExist) {
  const int32_t peer = OpenHostWindow();
  auto* host = HostOf(peer);
  ASSERT_NE(nullptr, host);
  views::Widget* widget = host->widget();
  ASSERT_NE(nullptr, widget);
  std::set<std::string> names;
  CollectClassNames(widget->GetRootView(), &names);
  for (const char* stock :
       {"BrowserView", "ToolbarView", "TabStrip", "TabStripRegionView",
        "VerticalTabStripRegionView", "MultiContentsView", "TopContainerView",
        "BookmarkBarView", "ContentsWebView", "StatusBubbleViews"}) {
    EXPECT_FALSE(names.contains(stock)) << stock;
  }
  std::vector<std::string> sized;
  for (views::View* child : widget->GetClientContentsView()->children()) {
    if (!child->bounds().IsEmpty()) {
      sized.emplace_back(child->GetClassName());
    }
  }
  EXPECT_EQ(std::vector<std::string>{"NativeViewHost"}, sized);
  NSWindow* window = widget->GetNativeWindow().GetNativeNSWindow();
  EXPECT_NSEQ(@"BarkNSWindow", NSStringFromClass([window class]));
  EXPECT_EQ(nullptr, BrowserView::GetBrowserViewForNativeWindow(
                         widget->GetNativeWindow()));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, EmptyStripKeepsWindow) {
  const int32_t kept = OpenHostWindow();
  ASSERT_EQ(1, barc_window_set_app_lifetime(kept));
  const int32_t tab = barc_tab_create(kept, "about:blank", 1);
  ASSERT_NE(0, tab);
  auto* browser = FindBrowser(kept);
  ASSERT_NE(nullptr, bark::BarkBrowserWindow::FromBrowser(browser));
  auto* host = HostOf(kept);
  ASSERT_NE(nullptr, host);
  EXPECT_TRUE(host->widget()->IsVisible());
  ASSERT_EQ(1, barc_tab_close(kept, tab));
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return browser->GetTabStripModel()->empty(); }));
  base::RunLoop().RunUntilIdle();
  ASSERT_EQ(browser, FindBrowser(kept));
  EXPECT_FALSE(browser->IsDeleteScheduled());
  EXPECT_EQ(host, HostOf(kept));
  EXPECT_TRUE(host->widget()->IsVisible());
  EXPECT_NE(0, barc_tab_create(kept, "about:blank", 1));

  const int32_t ordinary = OpenHostWindow();
  const int32_t last = barc_tab_create(ordinary, "about:blank", 1);
  ASSERT_NE(0, last);
  ui_test_utils::BrowserDestroyedObserver closed(FindBrowser(ordinary));
  ASSERT_EQ(1, barc_tab_close(ordinary, last));
  closed.Wait();
  EXPECT_EQ(nullptr, FindBrowser(ordinary));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, CloseRunsBeforeUnload) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t peer = OpenHostWindow();
  const int32_t tab = barc_tab_create(
      peer, embedded_test_server()->GetURL("/title1.html").spec().c_str(), 1);
  ASSERT_NE(0, tab);
  auto* page = TabContents(tab);
  ASSERT_TRUE(content::WaitForLoadStop(page));
  ASSERT_TRUE(content::ExecJs(page, "onbeforeunload = () => 'keep';"));
  content::PrepContentsForBeforeUnloadTest(page);
  auto* browser = FindBrowser(peer);
  auto* host = HostOf(peer);
  NSWindow* window = host->widget()->GetNativeWindow().GetNativeNSWindow();

  [[window standardWindowButton:NSWindowCloseButton] performClick:nil];
  auto* dialog = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(dialog->is_before_unload_dialog());
  EXPECT_EQ(page, dialog->web_contents());
  dialog->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !UnloadController::From(browser)->is_attempting_to_close_browser();
  }));
  EXPECT_EQ(browser, FindBrowser(peer));
  EXPECT_EQ(page, TabContents(tab));
  EXPECT_TRUE(host->widget()->IsVisible());

  ui_test_utils::BrowserDestroyedObserver closed(browser);
  [[window standardWindowButton:NSWindowCloseButton] performClick:nil];
  dialog = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(dialog->is_before_unload_dialog());
  dialog->view()->AcceptAppModalDialog();
  closed.Wait();
  EXPECT_EQ(nullptr, FindBrowser(peer));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, PopupKeepsBrowserView) {
  BrowserWindowInterface* popup = nullptr;
  {
    bark::ScopedAppWindowCreation app_window;
    popup = CreateBrowserWindow(BrowserWindowCreateParams(
        BrowserWindowInterface::TYPE_POPUP, *browser()->GetProfile(), true));
  }
  ASSERT_NE(nullptr, popup);
  EXPECT_NE(nullptr, BrowserView::GetBrowserViewForBrowser(popup));
  EXPECT_EQ(nullptr, bark::BarkBrowserWindow::FromBrowser(popup));

  auto* normal = CreateBrowserWindow(
      BrowserWindowCreateParams(*browser()->GetProfile(), true));
  ASSERT_NE(nullptr, normal);
  EXPECT_NE(nullptr, BrowserView::GetBrowserViewForBrowser(normal));
  EXPECT_EQ(nullptr, bark::BarkBrowserWindow::FromBrowser(normal));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest,
                       LegacyShellCallsRefusedInHostMode) {
  const int32_t peer = OpenHostWindow();
  ASSERT_NE(nullptr, HostOf(peer));
  const int32_t tab = barc_tab_create(peer, "about:blank", 1);
  ASSERT_NE(0, tab);
  NSView* sidebar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
  NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 40)];
  void* sidebar_pointer = (__bridge void*)sidebar;
  void* header_pointer = (__bridge void*)header;
  EXPECT_EQ(0, barc_window_attach_native_shell(peer, sidebar_pointer));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(peer, sidebar_pointer));
  EXPECT_EQ(0, barc_window_native_shell_is_owned(peer, nullptr));
  EXPECT_EQ(0, barc_window_set_native_header(peer, sidebar_pointer, nullptr,
                                             header_pointer, 40));
  EXPECT_EQ(0, barc_window_detach_native_shell_if_owned(peer, sidebar_pointer));
  EXPECT_EQ(0, barc_window_set_page_hidden(peer, 1));
  EXPECT_EQ(0, barc_window_admit_discovered(peer, sidebar_pointer));
  EXPECT_EQ(0u, barc_tab_present_peek(peer, tab, peer, tab, sidebar_pointer,
                                      header_pointer, nullptr));
  EXPECT_EQ(0, barc_tab_hide_peek(peer, tab, peer, tab, 1, header_pointer,
                                  nullptr));
  EXPECT_EQ(0, barc_tab_is_peek_presented(peer, tab, peer, tab, 1,
                                          header_pointer, nullptr));
  BarcSplitLayout layout = {.size = sizeof(BarcSplitLayout)};
  EXPECT_EQ(0, barc_window_set_split(peer, &layout));
  EXPECT_EQ(nil, sidebar.superview);
  EXPECT_EQ(nil, header.superview);
  EXPECT_EQ(1, barc_window_select(peer));
  EXPECT_EQ(1, barc_window_show(peer));
}

class BarkWindowHostOffBrowserTest : public InProcessBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-native-shell");
    command_line->AppendSwitch("barc-shared-native-window");
  }
};

IN_PROC_BROWSER_TEST_F(BarkWindowHostOffBrowserTest,
                       OldPathUnchangedWithoutSwitch) {
  EXPECT_FALSE(bark::IsHostWindowMode());
  const int32_t peer = barc_window_new_peer(browser()->GetSessionID().id());
  ASSERT_GT(peer, 0);
  auto* created = FindBrowser(peer);
  ASSERT_NE(nullptr, created);
  auto* view = BrowserView::GetBrowserViewForBrowser(created);
  ASSERT_NE(nullptr, view);
  EXPECT_NE(nullptr, view->barc_native_shell());
  EXPECT_EQ(nullptr, bark::BarkBrowserWindow::FromBrowser(created));
  EXPECT_EQ(nullptr, bark::BarkWindowHost::ForBrowser(created));
  NSView* sidebar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
  EXPECT_EQ(1, barc_window_attach_native_shell(peer, (__bridge void*)sidebar));
  EXPECT_EQ(1, barc_window_native_shell_is_owned(peer, (__bridge void*)sidebar));
  EXPECT_EQ(1, barc_window_set_app_lifetime(peer));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, PageViewVisibleWhenPlaced) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t peer = OpenHostWindow();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  const int32_t tab = OpenPage(peer, root, "/title1.html");
  NSWindow* window = HostOf(peer)->widget()->GetNativeWindow().GetNativeNSWindow();
  EXPECT_EQ(window, root.window);
  auto* contents = TabContents(tab);
  NSView* page = Place(peer, tab, root);
  EXPECT_EQ(window, page.window);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents->GetVisibility() == content::Visibility::VISIBLE;
  }));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, PageViewHiddenWhenRemoved) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t peer = OpenHostWindow();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  const int32_t tab = OpenPage(peer, root, "/title1.html");
  auto* contents = TabContents(tab);
  NSView* page = Place(peer, tab, root);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents->GetVisibility() == content::Visibility::VISIBLE;
  }));
  page.hidden = YES;
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents->GetVisibility() == content::Visibility::HIDDEN;
  }));
  page.hidden = NO;
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents->GetVisibility() == content::Visibility::VISIBLE;
  }));
  [page removeFromSuperview];
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents->GetVisibility() == content::Visibility::HIDDEN;
  }));
  EXPECT_EQ(page, PageView(peer, tab));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, PageViewSizeFollowsFrame) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t peer = OpenHostWindow();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  const int32_t tab = OpenPage(peer, root, "/title1.html");
  auto* contents = TabContents(tab);
  NSView* page = Place(peer, tab, root);
  page.frame = NSMakeRect(10, 10, 700, 500);
  ASSERT_TRUE(base::test::RunUntil([&] { return InnerWidth(contents) == 700; }));
  EXPECT_EQ(gfx::Size(700, 500), contents->GetContainerBounds().size());
  page.frame = NSMakeRect(20, 20, 640, 480);
  ASSERT_TRUE(base::test::RunUntil([&] { return InnerWidth(contents) == 640; }));
  EXPECT_EQ(480, content::EvalJs(contents, "innerHeight").ExtractInt());
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest,
                       UnplacedActiveTabHasNonZeroSize) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t peer = OpenHostWindow();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  const int32_t tab = OpenPage(peer, root, "/title1.html");
  auto* contents = TabContents(tab);
  EXPECT_EQ(nil, PageView(peer, tab).superview);
  EXPECT_FALSE(contents->GetContainerBounds().size().IsEmpty());
  EXPECT_GT(InnerWidth(contents), 0);
  EXPECT_GT(content::EvalJs(contents, "innerHeight").ExtractInt(), 0);
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest,
                       PageViewRetiredBeforeDestruction) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t peer = OpenHostWindow();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  const int32_t first = OpenPage(peer, root, "/title1.html");
  HostEvents events;
  ASSERT_TRUE(events.Observe(peer));

  // Closed by the app.
  const int32_t closed = barc_tab_create(
      peer, embedded_test_server()->GetURL("/title2.html").spec().c_str(), 0);
  ASSERT_NE(0, closed);
  void* closed_view = barc_tab_native_view(peer, closed);
  @autoreleasepool {
    NSView* page = PageView(peer, closed);
    events.watched = page;
    [root addSubview:page];
  }
  content::WebContentsDestroyedWatcher closed_destroyed(TabContents(closed));
  ASSERT_EQ(1, barc_tab_close(peer, closed));
  closed_destroyed.Wait();
  ASSERT_TRUE(base::test::RunUntil([&] { return events.Retired(closed); }));
  EXPECT_EQ(peer, events.Retired(closed)->event.window);
  EXPECT_EQ(closed_view, events.Retired(closed)->event.view);
  EXPECT_TRUE(events.Retired(closed)->watched_alive);

  // Closed by the page itself.
  auto* opener = TabContents(first);
  ASSERT_TRUE(content::ExecJs(opener, "child = window.open('/title2.html');"));
  auto* strip = FindBrowser(peer)->GetTabStripModel();
  ASSERT_TRUE(base::test::RunUntil([&] { return strip->count() == 2; }));
  auto* child = strip->GetWebContentsAt(1) == opener
                    ? strip->GetWebContentsAt(0)
                    : strip->GetWebContentsAt(1);
  const int32_t child_tab =
      tabs::TabInterface::GetFromContents(child)->GetHandle().raw_value();
  ASSERT_TRUE(content::WaitForLoadStop(child));
  @autoreleasepool {
    events.watched = PageView(peer, child_tab);
  }
  content::WebContentsDestroyedWatcher child_destroyed(child);
  ASSERT_TRUE(content::ExecJs(opener, "child.close();"));
  child_destroyed.Wait();
  ASSERT_TRUE(base::test::RunUntil([&] { return events.Retired(child_tab); }));
  EXPECT_TRUE(events.Retired(child_tab)->watched_alive);

  // Moved to another window: the page lives on, but leaves this one.
  const int32_t other = OpenHostWindow();
  const int32_t moved = barc_tab_create(
      peer, embedded_test_server()->GetURL("/title2.html").spec().c_str(), 0);
  NSView* moved_view = PageView(peer, moved);
  ASSERT_EQ(1, barc_tab_transfer(peer, moved, other));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.Retired(moved); }));
  EXPECT_EQ(peer, events.Retired(moved)->event.window);
  EXPECT_EQ((__bridge void*)moved_view, events.Retired(moved)->event.view);
  EXPECT_EQ(moved_view, PageView(other, moved));
  EXPECT_EQ(nil, PageView(peer, moved));

  barc_window_host_unobserve(events.token);
  const size_t seen = events.rows.size();
  ASSERT_EQ(1, barc_tab_close(peer, first));
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(seen, events.rows.size());
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, OccludedWindowHidesPage) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t peer = OpenHostWindow();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  const int32_t tab = OpenPage(peer, root, "/title1.html");
  auto* contents = TabContents(tab);
  Place(peer, tab, root);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents->GetVisibility() == content::Visibility::VISIBLE;
  }));
  views::Widget* widget = HostOf(peer)->widget();
  widget->Minimize();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents->GetVisibility() != content::Visibility::VISIBLE;
  }));
  widget->Restore();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents->GetVisibility() == content::Visibility::VISIBLE;
  }));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, WindowHostCallsRefuseBadInput) {
  const int32_t peer = OpenHostWindow();
  const int32_t old_path = browser()->GetSessionID().id();
  const int32_t old_tab = barc_window_tab_at(old_path, 0);
  NSView* root = [[NSView alloc] init];
  EXPECT_EQ(0, barc_window_set_root_view(peer, nullptr));
  EXPECT_EQ(0, barc_window_set_root_view(-1, (__bridge void*)root));
  EXPECT_EQ(0, barc_window_set_root_view(old_path, (__bridge void*)root));
  EXPECT_EQ(nullptr, barc_tab_native_view(old_path, old_tab));
  EXPECT_EQ(nullptr, barc_tab_native_view(peer, old_tab));
  EXPECT_EQ(nullptr, barc_tab_native_view(peer, 0));
  HostEvents events;
  EXPECT_EQ(0u, barc_window_host_observe(peer, nullptr, &events));
  EXPECT_EQ(0u, barc_window_host_observe(old_path, &HostEvents::Receive, &events));
  EXPECT_EQ(0u, barc_window_host_observe(-1, &HostEvents::Receive, &events));
  barc_window_host_unobserve(0);
  barc_window_host_unobserve(12345);
  BarcWindowChrome chrome = {.size = sizeof(BarcWindowChrome),
                             .titlebar_height = 48,
                             .leading_inset = 13};
  EXPECT_EQ(0, barc_window_set_chrome(old_path, &chrome));
  EXPECT_EQ(1, barc_window_set_root_view(peer, (__bridge void*)root));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, RendererCrashKeepsHostWindow) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t peer = OpenHostWindow();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  const int32_t tab = OpenPage(peer, root, "/title1.html");
  NSView* page = Place(peer, tab, root);
  auto* contents = TabContents(tab);
  auto* browser = FindBrowser(peer);
  content::CrashTab(contents);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(browser, FindBrowser(peer));
  EXPECT_EQ(contents, TabContents(tab));
  EXPECT_TRUE(contents->IsCrashed());
  EXPECT_EQ(page, PageView(peer, tab));
  EXPECT_TRUE(HostOf(peer)->widget()->IsVisible());
  ASSERT_EQ(1, barc_tab_reload(peer, tab));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_FALSE(contents->IsCrashed());
  EXPECT_EQ(page, PageView(peer, tab));
  EXPECT_EQ(page.window, root.window);
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, HostWindowHasSidePanelUI) {
  const int32_t peer = OpenHostWindow();
  auto* side_panel = SidePanelUI::From(FindBrowser(peer));
  ASSERT_NE(nullptr, side_panel);
  EXPECT_FALSE(side_panel->IsSidePanelShowing());
  EXPECT_FALSE(side_panel->GetCurrentEntryId());
  side_panel->Show(SidePanelEntryId::kReadAnything);
  EXPECT_FALSE(side_panel->IsSidePanelShowing());
  EXPECT_FALSE(side_panel->IsSidePanelEntryShowing(
      SidePanelEntryKey(SidePanelEntryId::kReadAnything)));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, PermissionPromptInHostWindow) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t peer = OpenHostWindow();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  const int32_t tab = OpenPage(peer, root, "/title1.html");
  Place(peer, tab, root);
  auto* contents = TabContents(tab);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return contents->GetVisibility() == content::Visibility::VISIBLE;
  }));
  auto* manager =
      permissions::PermissionRequestManager::FromWebContents(contents);
  ASSERT_NE(nullptr, manager);
  permissions::PermissionRequestObserver shown(contents);
  content::ExecuteScriptAsync(
      contents,
      "navigator.geolocation.getCurrentPosition("
      "  () => document.title = 'granted',"
      "  error => document.title = 'denied:' + error.code);");
  shown.Wait();
  ASSERT_TRUE(shown.request_shown());
  ASSERT_TRUE(manager->IsRequestInProgress());
  views::BubbleDialogDelegate* prompt = nullptr;
  for (views::Widget* widget : views::Widget::GetAllOwnedWidgets(
           HostOf(peer)->widget()->GetNativeView())) {
    if (auto* bubble = widget->widget_delegate()->AsBubbleDialogDelegate()) {
      prompt = bubble;
    }
  }
  ASSERT_NE(nullptr, prompt);
  EXPECT_TRUE(prompt->GetWidget()->IsVisible());
  EXPECT_TRUE(bark::BarkBrowserWindow::FromBrowser(FindBrowser(peer))
                  ->GetPageBoundsInScreen()
                  .Contains(prompt->GetAnchorRect().origin()));
  content::TitleWatcher denied(contents, u"denied:1");
  manager->Deny(std::monostate());
  EXPECT_EQ(u"denied:1", denied.WaitAndGetTitle());
  EXPECT_EQ(FindBrowser(peer),
            tabs::TabHandle(tab).Get()->GetBrowserWindowInterface());
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, FullscreenEventsFollowThePage) {
  ui::test::ScopedFakeNSWindowFullscreen fake_fullscreen;
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t peer = OpenHostWindow();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  const int32_t tab = OpenPage(peer, root, "/title1.html");
  Place(peer, tab, root);
  auto* contents = TabContents(tab);
  HostEvents events;
  ASSERT_TRUE(events.Observe(peer));
  ASSERT_TRUE(content::ExecJs(contents, "document.body.requestFullscreen();"));
  ASSERT_TRUE(
      base::test::RunUntil([&] { return !events.Fullscreen().empty(); }));
  EXPECT_EQ(std::vector<int32_t>{BARC_FULLSCREEN_PAGE}, events.Fullscreen());
  ASSERT_TRUE(content::ExecJs(contents, "document.exitFullscreen();"));
  ASSERT_TRUE(
      base::test::RunUntil([&] { return events.Fullscreen().size() >= 2; }));
  EXPECT_EQ((std::vector<int32_t>{BARC_FULLSCREEN_PAGE, BARC_FULLSCREEN_NONE}),
            events.Fullscreen());
  EXPECT_FALSE(HostOf(peer)->widget()->IsFullscreen());
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest,
                       FullscreenEventsFollowWindowToPageAndBack) {
  ui::test::ScopedFakeNSWindowFullscreen fake_fullscreen;
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t peer = OpenHostWindow();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  const int32_t tab = OpenPage(peer, root, "/title1.html");
  Place(peer, tab, root);
  auto* contents = TabContents(tab);
  auto* browser = FindBrowser(peer);
  HostEvents events;
  ASSERT_TRUE(events.Observe(peer));
  chrome::ToggleFullscreenMode(browser, /*user_initiated=*/true);
  ASSERT_TRUE(
      base::test::RunUntil([&] { return !events.Fullscreen().empty(); }));
  EXPECT_EQ(std::vector<int32_t>{BARC_FULLSCREEN_WINDOW}, events.Fullscreen());
  ASSERT_TRUE(content::ExecJs(contents, "document.body.requestFullscreen();"));
  ASSERT_TRUE(
      base::test::RunUntil([&] { return events.Fullscreen().size() >= 2; }));
  ASSERT_TRUE(content::ExecJs(contents, "document.exitFullscreen();"));
  ASSERT_TRUE(
      base::test::RunUntil([&] { return events.Fullscreen().size() >= 3; }));
  EXPECT_TRUE(HostOf(peer)->widget()->IsFullscreen());
  chrome::ToggleFullscreenMode(browser, /*user_initiated=*/true);
  ASSERT_TRUE(
      base::test::RunUntil([&] { return events.Fullscreen().size() >= 4; }));
  EXPECT_EQ((std::vector<int32_t>{BARC_FULLSCREEN_WINDOW, BARC_FULLSCREEN_PAGE,
                                  BARC_FULLSCREEN_WINDOW,
                                  BARC_FULLSCREEN_NONE}),
            events.Fullscreen());
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, ChromeMetricsMoveLights) {
  const int32_t peer = OpenHostWindow();
  NSWindow* window =
      HostOf(peer)->widget()->GetNativeWindow().GetNativeNSWindow();
  ASSERT_FALSE(window.visible);
  BarcWindowChrome chrome = {.size = sizeof(BarcWindowChrome),
                             .titlebar_height = 48,
                             .leading_inset = 13};
  ASSERT_EQ(1, barc_window_set_chrome(peer, &chrome));
  EXPECT_NSEQ(NSMakePoint(13, 16), LightsOrigin(window));

  ASSERT_EQ(1, barc_window_show(peer));
  ASSERT_TRUE(base::test::RunUntil([&] { return window.visible; }));
  EXPECT_NSEQ(NSMakePoint(13, 16), LightsOrigin(window));

  chrome.titlebar_height = 40;
  chrome.leading_inset = 20;
  ASSERT_EQ(1, barc_window_set_chrome(peer, &chrome));
  EXPECT_NSEQ(NSMakePoint(20, 12), LightsOrigin(window));

  chrome.titlebar_height = 48;
  chrome.leading_inset = 13;
  ASSERT_EQ(1, barc_window_set_chrome(peer, &chrome));
  WaitForFullscreen(window, true);
  EXPECT_TRUE(window.styleMask & NSWindowStyleMaskFullScreen);
  WaitForFullscreen(window, false);
  EXPECT_FALSE(window.styleMask & NSWindowStyleMaskFullScreen);
  EXPECT_NSEQ(NSMakePoint(13, 16), LightsOrigin(window));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, LightsGreyUntilHovered) {
  NSWindow* old_path =
      browser()->GetWindow()->GetNativeWindow().GetNativeNSWindow();
  const int32_t peer = OpenHostWindow();
  NSWindow* window =
      HostOf(peer)->widget()->GetNativeWindow().GetNativeNSWindow();
  ASSERT_EQ(1, barc_window_show(peer));
  for (NSWindow* key : {old_path, window}) {
    [NSApp activateIgnoringOtherApps:YES];
    [key makeKeyAndOrderFront:nil];
    ASSERT_TRUE(base::test::RunUntil(
        [&] { return key.isKeyWindow && [key _hasActiveAppearance]; }));
    for (NSWindowButton type : {NSWindowCloseButton, NSWindowMiniaturizeButton,
                                NSWindowZoomButton}) {
      EXPECT_EQ(key == old_path,
                [key _hasActiveAppearanceForStandardWindowButton:type])
          << (key == window ? "host " : "old path ") << type;
    }
  }
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, WindowChromeRefusesBadInput) {
  const int32_t peer = OpenHostWindow();
  const BarcWindowChrome good = {.size = sizeof(BarcWindowChrome),
                                 .titlebar_height = 48,
                                 .leading_inset = 13};
  EXPECT_EQ(0, barc_window_set_chrome(peer, nullptr));
  EXPECT_EQ(0, barc_window_set_chrome(-1, &good));
  EXPECT_EQ(0, barc_window_set_chrome(browser()->GetSessionID().id(), &good));
  const double nan = std::numeric_limits<double>::quiet_NaN();
  const double inf = std::numeric_limits<double>::infinity();
  for (BarcWindowChrome bad :
       {BarcWindowChrome{.size = 0, .titlebar_height = 48, .leading_inset = 13},
        BarcWindowChrome{.size = sizeof(size_t) + sizeof(double),
                         .titlebar_height = 48,
                         .leading_inset = 13},
        BarcWindowChrome{good.size, 0, 13}, BarcWindowChrome{good.size, -48, 13},
        BarcWindowChrome{good.size, nan, 13}, BarcWindowChrome{good.size, inf, 13},
        BarcWindowChrome{good.size, 48, -1}, BarcWindowChrome{good.size, 48, nan},
        BarcWindowChrome{good.size, 48, inf}}) {
    EXPECT_EQ(0, barc_window_set_chrome(peer, &bad))
        << bad.size << " " << bad.titlebar_height << " " << bad.leading_inset;
  }
  EXPECT_EQ(1, barc_window_set_chrome(peer, &good));
  auto* browser = FindBrowser(peer);
  ui_test_utils::BrowserDestroyedObserver closed(browser);
  ASSERT_EQ(1, barc_window_close(peer));
  closed.Wait();
  EXPECT_EQ(0, barc_window_set_chrome(peer, &good));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, CrashedPageEventsFollowTheRenderer) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t peer = OpenHostWindow();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  const int32_t tab = OpenPage(peer, root, "/title1.html");
  NSView* page = Place(peer, tab, root);
  auto* contents = TabContents(tab);
  HostEvents events;
  ASSERT_TRUE(events.Observe(peer));
  events.watched = page;
  content::CrashTab(contents);
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return !events.Of(BARC_WINDOW_HOST_PAGE_CRASHED).empty(); }));
  const auto* crashed = events.Of(BARC_WINDOW_HOST_PAGE_CRASHED).front();
  EXPECT_EQ(peer, crashed->event.window);
  EXPECT_EQ(tab, crashed->event.tab);
  EXPECT_EQ((__bridge void*)page, crashed->event.view);
  EXPECT_TRUE(events.Of(BARC_WINDOW_HOST_PAGE_RESTORED).empty());

  ASSERT_EQ(1, barc_tab_reload(peer, tab));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return !events.Of(BARC_WINDOW_HOST_PAGE_RESTORED).empty(); }));
  const auto* restored = events.Of(BARC_WINDOW_HOST_PAGE_RESTORED).front();
  EXPECT_EQ(tab, restored->event.tab);
  EXPECT_EQ((__bridge void*)page, restored->event.view);
  EXPECT_EQ(1u, events.Of(BARC_WINDOW_HOST_PAGE_CRASHED).size());
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest,
                       CrashedTabMovedToAnotherWindowIsRestoredOnReload) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t first = OpenHostWindow();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  const int32_t tab = OpenPage(first, root, "/title1.html");
  Place(first, tab, root);
  auto* contents = TabContents(tab);
  content::CrashTab(contents);
  ASSERT_TRUE(contents->IsCrashed());

  const int32_t second = OpenHostWindow();
  NSView* other = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  ASSERT_EQ(1, barc_window_set_root_view(second, (__bridge void*)other));
  HostEvents events;
  ASSERT_TRUE(events.Observe(second));
  ASSERT_EQ(1, barc_tab_transfer(first, tab, second));
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return !events.Of(BARC_WINDOW_HOST_PAGE_CRASHED).empty(); }));
  EXPECT_EQ(tab, events.Of(BARC_WINDOW_HOST_PAGE_CRASHED).front()->event.tab);

  ASSERT_EQ(1, barc_tab_reload(second, tab));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return !events.Of(BARC_WINDOW_HOST_PAGE_RESTORED).empty(); }));
  EXPECT_EQ(tab, events.Of(BARC_WINDOW_HOST_PAGE_RESTORED).front()->event.tab);
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, TwoProfilesShareOneWindow) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work = OpenProfile(kWorkProfile);
  const int32_t home = OpenProfile(kHomeProfile, work);
  ASSERT_GT(home, 0);
  ASSERT_NE(work, home);
  auto* work_browser = FindBrowser(work);
  auto* home_browser = FindBrowser(home);
  ASSERT_NE(nullptr, bark::BarkBrowserWindow::FromBrowser(home_browser));
  EXPECT_EQ(nullptr, BrowserView::GetBrowserViewForBrowser(home_browser));
  auto* host = HostOf(work);
  ASSERT_NE(nullptr, host);
  EXPECT_EQ(host, HostOf(home));
  EXPECT_EQ(2u, host->clients().size());
  EXPECT_EQ(work_browser->GetWindow()->GetNativeWindow(),
            home_browser->GetWindow()->GetNativeWindow());
  EXPECT_NE(work_browser->GetProfile(), home_browser->GetProfile());

  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  auto* work_page = TabContents(OpenPage(work, root, "/title1.html"));
  auto* home_page = TabContents(OpenPage(home, root, "/title1.html"));
  ASSERT_TRUE(content::ExecJs(work_page, "document.cookie = 'client=work'"));
  EXPECT_EQ("client=work", content::EvalJs(work_page, "document.cookie"));
  EXPECT_EQ("", content::EvalJs(home_page, "document.cookie"));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, UnselectedClientsTabRetires) {
  const int32_t work = OpenProfile(kWorkProfile);
  const int32_t home = OpenProfile(kHomeProfile, work);
  ASSERT_GT(home, 0);
  ASSERT_EQ(1, barc_window_select(work));
  const int32_t tab = barc_tab_create(home, "about:blank", 0);
  ASSERT_NE(0, tab);
  ASSERT_FALSE(FindBrowser(home)->IsSelectedForNativeWindow());
  HostEvents events;
  ASSERT_TRUE(events.Observe(work));
  events.watched = PageView(home, tab);
  ASSERT_NE(nil, events.watched);
  ASSERT_EQ(1, barc_tab_close(home, tab));
  ASSERT_TRUE(base::test::RunUntil([&] { return events.Retired(tab); }));
  EXPECT_EQ(home, events.Retired(tab)->event.window);
  EXPECT_TRUE(events.Retired(tab)->watched_alive);
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest,
                       SelectedClientAnswersWindowLookups) {
  const int32_t work = OpenProfile(kWorkProfile);
  const int32_t home = OpenProfile(kHomeProfile, work);
  ASSERT_GT(home, 0);
  auto* work_browser = FindBrowser(work);
  auto* home_browser = FindBrowser(home);
  auto* collection = GlobalBrowserCollection::GetInstance();
  const gfx::NativeWindow native = work_browser->GetWindow()->GetNativeWindow();
  ASSERT_EQ(1, barc_window_show(work));
  [NSApp activateIgnoringOtherApps:YES];
  [native.GetNativeNSWindow() makeKeyAndOrderFront:nil];
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return collection->GetLastActiveBrowser() == work_browser; }));
  EXPECT_TRUE(work_browser->IsSelectedForNativeWindow());
  EXPECT_FALSE(home_browser->IsSelectedForNativeWindow());
  EXPECT_EQ(work_browser, collection->FindBrowserWithWindow(native));

  HostEvents events;
  ASSERT_TRUE(events.Observe(work));
  const uint64_t revision = DiscoveryRevision();
  ASSERT_EQ(1, barc_window_select(home));
  EXPECT_FALSE(work_browser->IsSelectedForNativeWindow());
  EXPECT_TRUE(home_browser->IsSelectedForNativeWindow());
  EXPECT_EQ(home_browser, collection->FindBrowserWithWindow(native));
  EXPECT_EQ(home_browser, collection->GetLastActiveBrowser());
  EXPECT_LT(revision, DiscoveryRevision());
  BarcDiscoveryWindow row = {.size = sizeof(BarcDiscoveryWindow)};
  ASSERT_EQ(1, barc_window_discovery_state(work, &row));
  EXPECT_EQ(home, row.selected_client);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !events.Of(BARC_WINDOW_HOST_FULLSCREEN_CHANGED).empty();
  }));
  const auto& selected = events.Of(BARC_WINDOW_HOST_FULLSCREEN_CHANGED).back()->event;
  EXPECT_EQ(home, selected.window);
  EXPECT_EQ(BARC_FULLSCREEN_NONE, selected.fullscreen);

  work_browser->GetWindow()->Show();
  EXPECT_TRUE(work_browser->IsSelectedForNativeWindow());
  EXPECT_EQ(work_browser, collection->FindBrowserWithWindow(native));
  EXPECT_EQ(work_browser, collection->GetLastActiveBrowser());

  home_browser->GetWindow()->ShowInactive();
  EXPECT_TRUE(home_browser->IsSelectedForNativeWindow());
  EXPECT_EQ(home_browser, collection->FindBrowserWithWindow(native));
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, ClosingOneClientKeepsWindow) {
  const int32_t work = OpenProfile(kWorkProfile);
  const int32_t home = OpenProfile(kHomeProfile, work);
  ASSERT_GT(home, 0);
  ASSERT_EQ(1, barc_window_show(home));
  auto* work_browser = FindBrowser(work);
  auto* host = HostOf(work);
  const gfx::NativeWindow native = work_browser->GetWindow()->GetNativeWindow();
  HostEvents events;
  ASSERT_TRUE(events.Observe(work));

  ui_test_utils::BrowserDestroyedObserver closed(FindBrowser(home));
  ASSERT_EQ(1, barc_window_close(home));
  closed.Wait();
  EXPECT_EQ(nullptr, FindBrowser(home));
  EXPECT_EQ(host, HostOf(work));
  EXPECT_EQ(1u, host->clients().size());
  EXPECT_TRUE(host->widget()->IsVisible());
  EXPECT_TRUE(work_browser->IsSelectedForNativeWindow());
  EXPECT_EQ(work_browser,
            GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(native));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !events.Of(BARC_WINDOW_HOST_FULLSCREEN_CHANGED).empty();
  }));
  EXPECT_EQ(work,
            events.Of(BARC_WINDOW_HOST_FULLSCREEN_CHANGED).back()->event.window);
}

IN_PROC_BROWSER_TEST_F(BarkWindowHostBrowserTest, CloseButtonAsksEveryClient) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const int32_t work = OpenProfile(kWorkProfile);
  const int32_t home = OpenProfile(kHomeProfile, work);
  ASSERT_GT(home, 0);
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  auto* home_page = TabContents(OpenPage(home, root, "/title1.html"));
  ASSERT_TRUE(content::ExecJs(home_page, "onbeforeunload = () => 'keep';"));
  content::PrepContentsForBeforeUnloadTest(home_page);
  ASSERT_EQ(1, barc_window_show(work));
  auto* work_browser = FindBrowser(work);
  auto* home_browser = FindBrowser(home);
  auto* host = HostOf(work);
  NSWindow* window = host->widget()->GetNativeWindow().GetNativeNSWindow();

  [[window standardWindowButton:NSWindowCloseButton] performClick:nil];
  auto* dialog = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(dialog->is_before_unload_dialog());
  EXPECT_EQ(home_page, dialog->web_contents());
  EXPECT_TRUE(home_browser->IsSelectedForNativeWindow());
  dialog->view()->CancelAppModalDialog();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !UnloadController::From(home_browser)->is_attempting_to_close_browser();
  }));
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(work_browser, FindBrowser(work));
  EXPECT_EQ(home_browser, FindBrowser(home));
  EXPECT_EQ(2u, host->clients().size());
  EXPECT_TRUE(host->widget()->IsVisible());

  ui_test_utils::BrowserDestroyedObserver work_closed(work_browser);
  ui_test_utils::BrowserDestroyedObserver home_closed(home_browser);
  [[window standardWindowButton:NSWindowCloseButton] performClick:nil];
  dialog = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(dialog->is_before_unload_dialog());
  dialog->view()->AcceptAppModalDialog();
  work_closed.Wait();
  home_closed.Wait();
  EXPECT_EQ(nullptr, FindBrowser(work));
  EXPECT_EQ(nullptr, FindBrowser(home));
}
