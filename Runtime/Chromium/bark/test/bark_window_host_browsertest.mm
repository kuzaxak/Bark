#import <AppKit/AppKit.h>

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

int InnerWidth(content::WebContents* contents) {
  return content::EvalJs(contents, "innerWidth").ExtractInt();
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
};

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
