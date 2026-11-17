#import <AppKit/AppKit.h>

#include <cstdlib>
#include <memory>
#include <utility>
#include <vector>
#include <string>

#include "bark/bridge/barc_bridge_functions.h"
#include "bark/bridge/barc_bridge_api.h"
#include "bark/bridge/barc_profiles.h"
#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_window_host.h"
#include "base/base_switches.h"
#include "base/command_line.h"
#include "base/functional/callback_helpers.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "base/time/time.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/renderer_context_menu/render_view_context_menu_test_util.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "components/permissions/permission_request_manager.h"
#include "components/permissions/test/permission_request_observer.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "components/tabs/public/tab_interface.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/test_navigation_observer.h"
#include "content/public/test/test_utils.h"
#include "net/http/http_status_code.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/http_request.h"
#include "net/test/embedded_test_server/http_response.h"
#include "third_party/blink/public/common/input/web_input_event.h"
#include "third_party/blink/public/common/input/web_mouse_event.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/test/ui_controls.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/mac/coordinate_conversion.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/test/widget_test.h"
#include "ui/views/widget/widget.h"
#include "ui/views/window/dialog_delegate.h"

namespace {

BrowserWindowInterface* FindBrowser(int32_t id) {
  return GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(id));
}

content::WebContents* TabContents(int32_t tab) {
  auto* interface = tabs::TabHandle(tab).Get();
  return interface ? interface->GetContents() : nullptr;
}

std::unique_ptr<net::test_server::HttpResponse> ServePane(
    const net::test_server::HttpRequest& request) {
  if (request.relative_url == "/auth") {
    auto response = std::make_unique<net::test_server::BasicHttpResponse>();
    response->set_code(net::HTTP_UNAUTHORIZED);
    response->AddCustomHeader("WWW-Authenticate", "Basic realm=\"bark\"");
    response->set_content_type("text/html");
    response->set_content("<title>denied</title>");
    return response;
  }
  if (!request.relative_url.starts_with("/pane")) {
    return nullptr;
  }
  auto response = std::make_unique<net::test_server::BasicHttpResponse>();
  response->set_content_type("text/html");
  response->set_content(
      "<title>pane</title><body style='margin:0;background:rgb(255,0,0)'>"
      "<a id=link href=/pane-target style='display:block;height:100px'>link"
      "</a><script>window.clicks = 0;"
      "addEventListener('click', () => clicks++);</script></body>");
  return response;
}

}  // namespace

// A Bark window whose app root holds two tabs of one client side by side, as
// the app places the panes of a split.
class BarkHostSplitBrowserTest : public InProcessBrowserTest {
 public:
  BarkHostSplitBrowserTest() { SetAllowFeaturesSwitches(true); }

  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-native-shell");
    command_line->AppendSwitch("barc-shared-native-window");
    command_line->AppendSwitchASCII("bark-window", "host");
    // The app starts the engine without Cast.
    command_line->AppendSwitchASCII(switches::kDisableFeatures, "MediaRouter");
  }

 protected:
  void OpenSplit() {
    embedded_test_server()->RegisterRequestHandler(
        base::BindRepeating(&ServePane));
    ASSERT_TRUE(embedded_test_server()->Start());
    window_ = barc_window_new_peer(browser()->GetSessionID().id());
    ASSERT_GT(window_, 0);
    root_ = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    ASSERT_EQ(1, barc_window_set_root_view(window_, (__bridge void*)root_));
    left_ = barc_tab_create(
        window_, embedded_test_server()->GetURL("/pane-left").spec().c_str(),
        1);
    right_ = barc_tab_create(
        window_, embedded_test_server()->GetURL("/pane-right").spec().c_str(),
        1);
    ASSERT_NE(0, left_);
    ASSERT_NE(0, right_);
    ASSERT_TRUE(content::WaitForLoadStop(TabContents(left_)));
    ASSERT_TRUE(content::WaitForLoadStop(TabContents(right_)));
    ASSERT_EQ(1, barc_window_show(window_));
    left_view_ = (__bridge NSView*)barc_tab_native_view(window_, left_);
    right_view_ = (__bridge NSView*)barc_tab_native_view(window_, right_);
    ASSERT_NE(nil, left_view_);
    ASSERT_NE(nil, right_view_);
    left_view_.frame = NSMakeRect(0, 0, 395, 600);
    right_view_.frame = NSMakeRect(405, 0, 395, 600);
    [root_ addSubview:left_view_];
    [root_ addSubview:right_view_];
  }
  TabStripModel* Tabs() { return FindBrowser(window_)->GetTabStripModel(); }
  content::WebContents* Left() { return TabContents(left_); }
  content::WebContents* Right() { return TabContents(right_); }
  // The page's own pixels at its centre, from its compositor.
  SkColor CentrePixel(content::WebContents* contents) {
    base::test::TestFuture<const content::CopyFromSurfaceResult&> copied;
    contents->GetRenderWidgetHostView()->CopyFromSurface(
        gfx::Rect(), gfx::Size(), base::Seconds(10), copied.GetCallback());
    const auto& result = copied.Get();
    if (!result.has_value() || result->bitmap.drawsNothing()) {
      return SK_ColorTRANSPARENT;
    }
    const SkBitmap& bitmap = result->bitmap;
    return bitmap.getColor(bitmap.width() / 2, bitmap.height() / 2);
  }

  // The visible tab-modal dialog of `contents`, shown over the host window.
  views::Widget* WaitForTabModalOf(content::WebContents* contents) {
    views::Widget* found = nullptr;
    auto* host = bark::BarkBrowserWindow::FromBrowser(FindBrowser(window_))->host();
    EXPECT_TRUE(base::test::RunUntil([&] {
      auto* manager =
          web_modal::WebContentsModalDialogManager::FromWebContents(contents);
      if (!manager || !manager->IsDialogActive()) {
        return false;
      }
      for (views::Widget* widget : views::Widget::GetAllOwnedWidgets(
               host->widget()->GetNativeView())) {
        if (widget->IsVisible() && !widget->IsClosed() &&
            widget->widget_delegate() &&
            widget->widget_delegate()->GetModalType() ==
                ui::mojom::ModalType::kChild) {
          found = widget;
          return true;
        }
      }
      return false;
    }));
    return found;
  }
  gfx::Rect PaneInScreen(NSView* pane) {
    NSWindow* window = pane.window;
    return gfx::ScreenRectFromNSRect(
        [window convertRectToScreen:[pane convertRect:pane.bounds toView:nil]]);
  }
  void Cancel(views::Widget* dialog) {
    views::test::WidgetDestroyedWaiter closed(dialog);
    dialog->widget_delegate()->AsDialogDelegate()->CancelDialog();
    closed.Wait();
  }

  int32_t window_ = 0;
  int32_t left_ = 0;
  int32_t right_ = 0;
  NSView* root_ = nil;
  NSView* left_view_ = nil;
  NSView* right_view_ = nil;
};

IN_PROC_BROWSER_TEST_F(BarkHostSplitBrowserTest, InactivePlacedTabIsVisible) {
  OpenSplit();
  ASSERT_EQ(Right(), Tabs()->GetActiveWebContents());
  EXPECT_TRUE(base::test::RunUntil([&] {
    return Left()->GetVisibility() == content::Visibility::VISIBLE &&
           Right()->GetVisibility() == content::Visibility::VISIBLE;
  }));
  EXPECT_EQ("visible", content::EvalJs(Left(), "document.visibilityState"));
  // The inactive page runs script and paints what it changes.
  EXPECT_EQ(2, content::EvalJs(Left(), "1 + 1"));
  EXPECT_TRUE(base::test::RunUntil(
      [&] { return CentrePixel(Left()) == SkColorSetRGB(255, 0, 0); }));
  ASSERT_TRUE(content::ExecJs(
      Left(), "document.body.style.background = 'rgb(0, 128, 0)'"));
  EXPECT_TRUE(base::test::RunUntil(
      [&] { return CentrePixel(Left()) == SkColorSetRGB(0, 128, 0); }));
  // Its frame follows its view.
  left_view_.frame = NSMakeRect(0, 0, 300, 600);
  EXPECT_TRUE(base::test::RunUntil([&] {
    return Left()->GetRenderWidgetHostView()->GetViewBounds().width() == 300;
  }));
  EXPECT_EQ(Right(), Tabs()->GetActiveWebContents());
}

namespace {

void MakeFirstResponder(content::WebContents* contents) {
  NSView* view =
      contents->GetRenderWidgetHostView()->GetNativeView().GetNativeNSView();
  [view.window makeFirstResponder:view];
}

}  // namespace

// A pane that takes the keys without the person's click in it, as when the
// window becomes key or a relaunch restores the panes, changes nothing: the
// app's choice of active tab stands.
IN_PROC_BROWSER_TEST_F(BarkHostSplitBrowserTest,
                       PaneTakingTheKeysKeepsTheActiveTab) {
  OpenSplit();
  ASSERT_EQ(Right(), Tabs()->GetActiveWebContents());
  MakeFirstResponder(Left());
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(Left(), "document.hasFocus()").ExtractBool();
  }));
  Left()->Focus();
  content::RunAllTasksUntilIdle();
  EXPECT_EQ(Right(), Tabs()->GetActiveWebContents());
}

IN_PROC_BROWSER_TEST_F(BarkHostSplitBrowserTest,
                       ActivationKeepsOtherPanesVisible) {
  OpenSplit();
  ASSERT_EQ(1, barc_tab_select(window_, left_));
  ASSERT_EQ(Left(), Tabs()->GetActiveWebContents());
  EXPECT_EQ(content::Visibility::VISIBLE, Right()->GetVisibility());
  EXPECT_EQ(right_view_, [right_view_.superview.subviews lastObject]);
  EXPECT_EQ(root_, right_view_.superview);
  EXPECT_EQ(root_, left_view_.superview);
  ASSERT_TRUE(content::ExecJs(
      Right(), "document.body.style.background = 'rgb(0, 0, 255)'"));
  EXPECT_TRUE(base::test::RunUntil(
      [&] { return CentrePixel(Right()) == SkColorSetRGB(0, 0, 255); }));
}

IN_PROC_BROWSER_TEST_F(BarkHostSplitBrowserTest,
                       UnplacedTabFocusChangesNothing) {
  OpenSplit();
  const int32_t hidden = barc_tab_create(
      window_, embedded_test_server()->GetURL("/pane-hidden").spec().c_str(),
      0);
  ASSERT_NE(0, hidden);
  ASSERT_TRUE(content::WaitForLoadStop(TabContents(hidden)));
  ASSERT_EQ(Right(), Tabs()->GetActiveWebContents());
  TabContents(hidden)->Focus();
  content::RunAllTasksUntilIdle();
  EXPECT_EQ(Right(), Tabs()->GetActiveWebContents());
}

IN_PROC_BROWSER_TEST_F(BarkHostSplitBrowserTest, TabModalDialogCentresOnItsPane) {
  OpenSplit();
  for (auto [contents, pane] : {std::pair{Left(), left_view_},
                                std::pair{Right(), right_view_}}) {
    SCOPED_TRACE(pane == left_view_ ? "left" : "right");
    content::ExecuteScriptAsync(contents, "location.href = '/auth'");
    views::Widget* sign_in = WaitForTabModalOf(contents);
    ASSERT_TRUE(sign_in);
    const gfx::Rect area = PaneInScreen(pane);
    const gfx::Rect frame = sign_in->GetWindowBoundsInScreen();
    EXPECT_LE(std::abs(frame.CenterPoint().x() - area.CenterPoint().x()), 1)
        << area.ToString() << " " << frame.ToString();
    EXPECT_EQ(area.y(), frame.y()) << area.ToString() << " " << frame.ToString();
    Cancel(sign_in);
    ASSERT_TRUE(content::WaitForLoadStop(contents));
  }
  // A pane narrower than the dialog keeps it inside the window.
  left_view_.frame = NSMakeRect(0, 0, 120, 600);
  right_view_.frame = NSMakeRect(130, 0, 670, 600);
  content::ExecuteScriptAsync(Left(), "location.href = '/auth'");
  views::Widget* sign_in = WaitForTabModalOf(Left());
  ASSERT_TRUE(sign_in);
  gfx::Rect inside = bark::BarkBrowserWindow::FromBrowser(FindBrowser(window_))
                         ->host()
                         ->widget()
                         ->GetClientAreaBoundsInScreen();
  inside.Inset(8);
  EXPECT_TRUE(inside.Contains(sign_in->GetWindowBoundsInScreen()))
      << inside.ToString() << " " << sign_in->GetWindowBoundsInScreen().ToString();
  Cancel(sign_in);
}

namespace {

// Visible bubbles the host window owns.
std::vector<views::BubbleDialogDelegate*> BubblesOf(views::Widget* host) {
  std::vector<views::BubbleDialogDelegate*> bubbles;
  for (views::Widget* widget :
       views::Widget::GetAllOwnedWidgets(host->GetNativeView())) {
    auto* bubble = widget->widget_delegate()
                       ? widget->widget_delegate()->AsBubbleDialogDelegate()
                       : nullptr;
    if (bubble && widget->IsVisible() && !widget->IsClosed()) {
      bubbles.push_back(bubble);
    }
  }
  return bubbles;
}

constexpr char kAskForLocation[] =
    "navigator.geolocation.getCurrentPosition(() => {}, () => {});";

}  // namespace

IN_PROC_BROWSER_TEST_F(BarkHostSplitBrowserTest, FocusedPanePromptUnchanged) {
  OpenSplit();
  views::Widget* host =
      bark::BarkBrowserWindow::FromBrowser(FindBrowser(window_))->host()->widget();
  permissions::PermissionRequestObserver shown(Right());
  content::ExecuteScriptAsync(Right(), kAskForLocation);
  shown.Wait();
  ASSERT_TRUE(shown.request_shown());
  ASSERT_TRUE(base::test::RunUntil([&] { return !BubblesOf(host).empty(); }));
  const gfx::Rect pane = PaneInScreen(right_view_);
  EXPECT_EQ(pane.x() + 40, BubblesOf(host).front()->GetAnchorRect().x());
}

namespace {

struct Retired {
  std::vector<std::pair<int32_t, void*>> views;
  static void Receive(const BarcWindowHostEvent* event, void* context) {
    if (event->kind == BARC_WINDOW_HOST_PAGE_VIEW_RETIRED) {
      static_cast<Retired*>(context)->views.emplace_back(event->tab,
                                                         event->view);
    }
  }
};

void IgnoreTabEvent(void*, uint64_t, int32_t, int32_t, int32_t, const char*,
                    const char*, int32_t, uint32_t) {}

// Every tab that became the client's active tab, in order.
class ActiveTabs : public TabStripModelObserver {
 public:
  explicit ActiveTabs(TabStripModel* tabs) { tabs->AddObserver(this); }
  void OnTabStripModelChanged(TabStripModel* tabs,
                              const TabStripModelChange& change,
                              const TabStripSelectionChange& selection) override {
    if (selection.active_tab_changed() && selection.new_contents) {
      shown.push_back(selection.new_contents);
    }
  }
  std::vector<content::WebContents*> shown;
};

}  // namespace

IN_PROC_BROWSER_TEST_F(BarkHostSplitBrowserTest, ClosingAPaneRetiresItsView) {
  OpenSplit();
  Retired retired;
  const uint64_t token =
      barc_window_host_observe(window_, &Retired::Receive, &retired);
  ASSERT_NE(0u, token);
  base::ScopedClosureRunner unobserve(
      base::BindOnce(&barc_window_host_unobserve, token));
  ASSERT_EQ(Right(), Tabs()->GetActiveWebContents());
  ASSERT_EQ(1, barc_tab_close(window_, left_));
  ASSERT_TRUE(base::test::RunUntil([&] { return !retired.views.empty(); }));
  EXPECT_EQ(left_, retired.views.front().first);
  EXPECT_EQ((__bridge void*)left_view_, retired.views.front().second);
  EXPECT_EQ(Right(), Tabs()->GetActiveWebContents());
  EXPECT_EQ(content::Visibility::VISIBLE, Right()->GetVisibility());
}

IN_PROC_BROWSER_TEST_F(BarkHostSplitBrowserTest, CloseSelectingAPaneActivatesIt) {
  OpenSplit();
  // A tab of the window outside the split, after the right pane: Chromium's
  // own choice when the right pane closes.
  const int32_t outside = barc_tab_create(
      window_, embedded_test_server()->GetURL("/pane-outside").spec().c_str(),
      0);
  ASSERT_NE(0, outside);
  ASSERT_EQ(Right(), Tabs()->GetActiveWebContents());
  ActiveTabs active(Tabs());
  base::ScopedClosureRunner stop_watching(base::BindOnce(
      [](TabStripModel* tabs, ActiveTabs* active) {
        tabs->RemoveObserver(active);
      },
      Tabs(), &active));
  const uint64_t observation =
      barc_tab_observe(window_, right_, &IgnoreTabEvent, nullptr);
  ASSERT_NE(0u, observation);
  ASSERT_EQ(1, barc_tab_close_selecting(observation, left_));
  ASSERT_TRUE(base::test::RunUntil([&] { return Tabs()->count() == 2; }));
  EXPECT_EQ(Left(), Tabs()->GetActiveWebContents());
  EXPECT_EQ(std::vector<content::WebContents*>{Left()}, active.shown);
  EXPECT_EQ(content::Visibility::VISIBLE, Left()->GetVisibility());
}

// The app's startup: a host window completes it, so the engine runs in native
// application mode as in Bark.
class BarkHostSplitAppBrowserTest : public BarkHostSplitBrowserTest {
 public:
  void SetUp() override {
    barc_set_runtime_ready_callback(
        [](void*) {
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
          const int32_t window = barc_window_new_peer(initial);
          CHECK_GT(window, 0);
          static NSView* root =
              [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
          CHECK_EQ(1, barc_window_set_root_view(window, (__bridge void*)root));
          barc_runtime_complete_startup(window);
        },
        nullptr);
    BarkHostSplitBrowserTest::SetUp();
  }
};

IN_PROC_BROWSER_TEST_F(BarkHostSplitAppBrowserTest,
                       StockSplitEntryPointsAreGoneInHostWindow) {
  OpenSplit();
  content::ContextMenuParams params;
  params.page_url = Left()->GetLastCommittedURL();
  params.frame_url = params.page_url;
  params.frame_origin = Left()->GetPrimaryMainFrame()->GetLastCommittedOrigin();
  params.link_url = params.unfiltered_link_url =
      embedded_test_server()->GetURL("/pane-target");
  TestRenderViewContextMenu menu(*Left()->GetPrimaryMainFrame(), params);
  menu.Init();
  EXPECT_FALSE(menu.IsItemPresent(IDC_CONTENT_CONTEXT_OPENLINKSPLITVIEW));
  EXPECT_FALSE(chrome::IsCommandEnabled(FindBrowser(window_), IDC_NEW_SPLIT_TAB));
  // Cmd+Option+click is Chromium's "open in split"; it opens a plain tab here.
  const int count = Tabs()->count();
  content::SimulateMouseClickAt(
      Left(), blink::WebInputEvent::kMetaKey | blink::WebInputEvent::kAltKey,
      blink::WebMouseEvent::Button::kLeft, gfx::Point(20, 20));
  ASSERT_TRUE(base::test::RunUntil([&] { return Tabs()->count() == count + 1; }));
  for (int i = 0; i < Tabs()->count(); ++i) {
    EXPECT_FALSE(Tabs()->GetTabAtIndex(i)->IsSplit());
  }
}

// Real clicks and key-window changes, as in interactive UI tests; each case
// runs in its own test process.
class BarkHostSplitFocusBrowserTest : public BarkHostSplitBrowserTest {
 public:
  void SetUp() override {
    ui_controls::EnableUIControls();
    ASSERT_TRUE(ui_controls::IsUIControlsEnabled());
    BarkHostSplitBrowserTest::SetUp();
  }

 protected:
  void MakeKey() {
    NSWindow* window = left_view_.window;
    [NSApp activateIgnoringOtherApps:YES];
    bark::BarkBrowserWindow::FromBrowser(FindBrowser(window_))->Activate();
    ASSERT_TRUE(base::test::RunUntil([&] { return window.isKeyWindow; }));
  }
  // A click in the pane's middle, below its link.
  void ClickIn(NSView* pane) {
    const gfx::Point point = PaneInScreen(pane).CenterPoint();
    base::test::TestFuture<void> moved;
    const gfx::NativeWindow window(pane.window);
    ASSERT_TRUE(ui_controls::SendMouseMoveNotifyWhenDone(
        point.x(), point.y(), moved.GetCallback(), window));
    ASSERT_TRUE(moved.Wait());
    base::test::TestFuture<void> clicked;
    ASSERT_TRUE(ui_controls::SendMouseEventsNotifyWhenDone(
        ui_controls::LEFT, ui_controls::DOWN | ui_controls::UP,
        clicked.GetCallback(), ui_controls::kNoAccelerator, window));
    ASSERT_TRUE(clicked.Wait());
  }
};

IN_PROC_BROWSER_TEST_F(BarkHostSplitFocusBrowserTest,
                       InactivePlacedTabTakesAClick) {
  OpenSplit();
  MakeKey();
  ClickIn(left_view_);
  EXPECT_TRUE(base::test::RunUntil(
      [&] { return content::EvalJs(Left(), "clicks").ExtractInt() == 1; }));
}

IN_PROC_BROWSER_TEST_F(BarkHostSplitFocusBrowserTest,
                       ClickInUnfocusedPaneReachesThePage) {
  OpenSplit();
  MakeKey();
  ASSERT_EQ(Right(), Tabs()->GetActiveWebContents());
  ClickIn(left_view_);
  EXPECT_TRUE(base::test::RunUntil(
      [&] { return Tabs()->GetActiveWebContents() == Left(); }));
  EXPECT_TRUE(base::test::RunUntil(
      [&] { return content::EvalJs(Left(), "clicks").ExtractInt() == 1; }));
  EXPECT_EQ(0, content::EvalJs(Right(), "clicks").ExtractInt());
  EXPECT_EQ(content::Visibility::VISIBLE, Right()->GetVisibility());
}

IN_PROC_BROWSER_TEST_F(BarkHostSplitFocusBrowserTest, PaneClickSelectsItsClient) {
  OpenSplit();
  base::test::TestFuture<barc_profile_status, int32_t> opened;
  barc_profile_open_in_native_window(
      window_, "8a4f2c61-3d7e-4b19-a0c5-6e2d9f1b7a34", BARC_PROFILE_BLANK,
      [](barc_profile_status status, int32_t window, void* data) {
        static_cast<base::test::TestFuture<barc_profile_status, int32_t>*>(data)
            ->SetValue(status, window);
      },
      &opened);
  ASSERT_EQ(BARC_PROFILE_OK, opened.Get<0>());
  const int32_t other = opened.Get<1>();
  ASSERT_EQ(1, barc_window_select(window_));
  auto* other_tab = FindBrowser(other)->GetTabStripModel()->GetActiveTab();
  ASSERT_TRUE(other_tab);
  NSView* other_view = (__bridge NSView*)barc_tab_native_view(
      other, other_tab->GetHandle().raw_value());
  ASSERT_NE(nil, other_view);
  other_view.frame = NSMakeRect(405, 0, 395, 600);
  [right_view_ removeFromSuperview];
  [root_ addSubview:other_view];
  content::WebContents* other_contents = other_tab->GetContents();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return other_contents->GetVisibility() == content::Visibility::VISIBLE;
  }));
  ASSERT_TRUE(FindBrowser(window_)->IsSelectedForNativeWindow());
  MakeKey();
  ClickIn(other_view);
  EXPECT_TRUE(base::test::RunUntil(
      [&] { return FindBrowser(other)->IsSelectedForNativeWindow(); }));
  EXPECT_EQ(content::Visibility::VISIBLE, Left()->GetVisibility());
}

IN_PROC_BROWSER_TEST_F(BarkHostSplitFocusBrowserTest,
                       PageCommandReachesClickedPane) {
  OpenSplit();
  MakeKey();
  ClickIn(left_view_);
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return Tabs()->GetActiveWebContents() == Left(); }));
  content::TestNavigationObserver reloaded(Left());
  chrome::ExecuteCommand(FindBrowser(window_), IDC_RELOAD);
  reloaded.Wait();
  EXPECT_EQ(Left()->GetLastCommittedURL(), reloaded.last_navigation_url());
}

IN_PROC_BROWSER_TEST_F(BarkHostSplitFocusBrowserTest,
                       PermissionPromptWaitsForItsPane) {
  OpenSplit();
  MakeKey();
  views::Widget* host =
      bark::BarkBrowserWindow::FromBrowser(FindBrowser(window_))->host()->widget();
  ASSERT_EQ(Right(), Tabs()->GetActiveWebContents());
  auto* manager = permissions::PermissionRequestManager::FromWebContents(Left());
  content::ExecuteScriptAsync(Left(), kAskForLocation);
  ASSERT_TRUE(base::test::RunUntil([&] { return manager->IsRequestInProgress(); }));
  content::RunAllTasksUntilIdle();
  EXPECT_TRUE(BubblesOf(host).empty());
  ClickIn(left_view_);
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return Tabs()->GetActiveWebContents() == Left(); }));
  ASSERT_TRUE(base::test::RunUntil([&] { return !BubblesOf(host).empty(); }));
  const gfx::Rect pane = PaneInScreen(left_view_);
  EXPECT_EQ(pane.x() + 40, BubblesOf(host).front()->GetAnchorRect().x())
      << pane.ToString() << " "
      << BubblesOf(host).front()->GetAnchorRect().ToString();
}

// B11: Chromium's rule for a page that is not in front holds an alert from the
// unfocused pane and answers confirm() and prompt() from it at once. The held
// alert shows on its pane once the person clicks that pane.
IN_PROC_BROWSER_TEST_F(BarkHostSplitFocusBrowserTest,
                       UnfocusedPaneAlertShowsWhenThePaneIsClicked) {
  OpenSplit();
  Tabs()->ActivateTabAt(Tabs()->GetIndexOfWebContents(Right()));
  ASSERT_EQ(Right(), Tabs()->GetActiveWebContents());
  EXPECT_EQ(false, content::EvalJs(Left(), "confirm('b11')"));
  EXPECT_EQ(true, content::EvalJs(Left(), "prompt('b11') === null"));
  ASSERT_TRUE(content::ExecJs(Left(), "alert('b11')"));
  EXPECT_FALSE(web_modal::WebContentsModalDialogManager::FromWebContents(Left())
                   ->IsDialogActive());
  MakeKey();
  ClickIn(left_view_);
  views::Widget* dialog = WaitForTabModalOf(Left());
  ASSERT_NE(nullptr, dialog);
  EXPECT_TRUE(PaneInScreen(left_view_).Contains(
      dialog->GetWindowBoundsInScreen().CenterPoint()));
  Cancel(dialog);
}

// A relaunch restores the panes with another pane's view holding the keys than
// the tab the app selects; the window becoming key keeps the app's choice.
IN_PROC_BROWSER_TEST_F(BarkHostSplitFocusBrowserTest,
                       WindowBecomingKeyKeepsTheActiveTab) {
  OpenSplit();
  NSWindow* other = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 200, 200)
                styleMask:NSWindowStyleMaskTitled
                  backing:NSBackingStoreBuffered
                    defer:NO];
  other.releasedWhenClosed = NO;
  [NSApp activateIgnoringOtherApps:YES];
  [other makeKeyAndOrderFront:nil];
  ASSERT_TRUE(base::test::RunUntil([&] { return other.isKeyWindow; }));
  ASSERT_EQ(1, barc_tab_select(window_, right_));
  NSView* left_page =
      Left()->GetRenderWidgetHostView()->GetNativeView().GetNativeNSView();
  ASSERT_TRUE([left_view_.window makeFirstResponder:left_page]);
  MakeKey();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(Left(), "document.hasFocus()").ExtractBool();
  }));
  content::RunAllTasksUntilIdle();
  EXPECT_EQ(Right(), Tabs()->GetActiveWebContents());
  [other close];
}
