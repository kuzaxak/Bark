#import <AppKit/AppKit.h>

#include <cstdlib>
#include <utility>

#include "bark/bridge/barc_bridge_functions.h"
#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_window_host.h"
#include "base/base_switches.h"
#include "base/command_line.h"
#include "base/test/run_until.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/display/screen_base.h"
#include "ui/gfx/geometry/rect.h"

namespace {

class BarkCompactBoundsBrowserTest : public InProcessBrowserTest {
 public:
  BarkCompactBoundsBrowserTest() { SetAllowFeaturesSwitches(true); }

  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-native-shell");
    command_line->AppendSwitch("barc-shared-native-window");
    command_line->AppendSwitchASCII("bark-window", "host");
    command_line->AppendSwitchASCII(switches::kDisableFeatures, "MediaRouter");
  }
};

TEST(BarkCompactBoundsTest, FitsNearestDisplayWorkArea) {
  const gfx::Rect primary_bounds(0, 0, 1200, 900);
  const gfx::Rect secondary_bounds(-1250, -700, 1000, 650);
  display::Display primary(1, primary_bounds);
  display::Display secondary(2, secondary_bounds);
  primary.set_work_area(gfx::Rect(0, 24, 1200, 850));
  secondary.set_work_area(gfx::Rect(-1250, -680, 1000, 610));
  display::ScreenBase screen;
  screen.display_list().AddDisplay(primary,
                                   display::DisplayList::Type::PRIMARY);
  screen.display_list().AddDisplay(secondary,
                                   display::DisplayList::Type::NOT_PRIMARY);

  auto fit = [&screen](const gfx::Rect& bounds) {
    return bark::BarkWindowHost::ConstrainCompactBounds(bounds, screen);
  };
  const gfx::Rect valid(-900, -600, 320, 240);
  EXPECT_EQ(valid, fit(valid));
  EXPECT_EQ(gfx::Rect(-1250, -680, 320, 240),
            fit(gfx::Rect(-1600, -900, 320, 240)));
  EXPECT_EQ(gfx::Rect(700, 274, 500, 600), fit(gfx::Rect(1300, 920, 500, 600)));
  EXPECT_EQ(secondary.work_area(), fit(gfx::Rect(-1800, -850, 1500, 1000)));
}

IN_PROC_BROWSER_TEST_F(BarkCompactBoundsBrowserTest,
                       RequestedPopupContentSize) {
  const gfx::Rect available =
      display::Screen::Get()->GetPrimaryDisplay().work_area();
  if (available.width() < 540 || available.height() < 690) {
    GTEST_SKIP() << "The primary work area cannot fit the fixture";
  }
  const gfx::Point origin(available.x() + 20, available.y() + 20);
  for (const auto& requested : {gfx::Size(500, 600), gfx::Size(320, 240)}) {
    BrowserWindowCreateParams params(BrowserWindowInterface::TYPE_POPUP,
                                     *browser()->GetProfile(), true);
    params.initial_bounds = gfx::Rect(origin, requested);
    params.initial_origin_specified =
        BrowserWindowCreateParams::ValueSpecified::kSpecified;
    auto* popup = CreateBrowserWindow(std::move(params));
    ASSERT_TRUE(popup);
    auto* host = bark::BarkWindowHost::ForBrowser(popup);
    ASSERT_TRUE(host);
    auto* window = host->selected();
    EXPECT_EQ(origin, window->GetBounds().origin());
    EXPECT_NEAR(requested.width(), window->GetContentsSize().width(), 1);
    EXPECT_NEAR(requested.height(), window->GetContentsSize().height(), 1);
    CloseBrowserSynchronously(popup);
  }
}

IN_PROC_BROWSER_TEST_F(BarkCompactBoundsBrowserTest,
                       MountedViewportAndScriptBounds) {
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), embedded_test_server()->GetURL("/title1.html")));
  auto* opener = browser()->tab_strip_model()->GetActiveWebContents();
  ui_test_utils::BrowserCreatedObserver created;
  const gfx::Rect available =
      display::Screen::Get()->GetPrimaryDisplay().work_area();
  if (available.width() < 540 || available.height() < 450) {
    GTEST_SKIP() << "The primary work area cannot fit the fixture";
  }
  ASSERT_TRUE(
      content::EvalJs(opener, content::JsReplace(
                                  "!!open(location.href, '_blank', "
                                  "'popup,width=320,height=240,left=' + $1 + "
                                  "',top=' + $2)",
                                  available.x() + 20, available.y() + 20))
          .ExtractBool());
  auto* popup = created.Wait();
  ASSERT_TRUE(popup);
  auto* host = bark::BarkWindowHost::ForBrowser(popup);
  ASSERT_TRUE(host);
  auto* window = host->selected();
  const int32_t window_id = popup->GetSessionID().id();
  NSView* root = [[NSView alloc] initWithFrame:NSZeroRect];
  ASSERT_EQ(1, barc_window_set_root_view(window_id, (__bridge void*)root));

  ASSERT_TRUE(base::test::RunUntil(
      [&] { return popup->GetTabStripModel()->GetActiveWebContents(); }));
  auto* page = popup->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(page));
  NSView* page_view = page->GetNativeView().GetNativeNSView();
  ASSERT_TRUE(page_view);
  constexpr int kHeaderHeight = 44;
  gfx::Rect initial_bounds = window->GetBounds();
  initial_bounds.set_height(initial_bounds.height() + kHeaderHeight);
  window->SetBounds(initial_bounds);
  NSRect viewport = root.bounds;
  viewport.size.height -= kHeaderHeight;
  page_view.frame = viewport;
  page_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [root addSubview:page_view];
  EXPECT_NEAR(320, window->GetContentsSize().width(), 1);
  EXPECT_NEAR(240, window->GetContentsSize().height(), 1);

  window->SetContentsSize(gfx::Size(360, 280));
  ASSERT_TRUE(base::test::RunUntil([&] {
    const gfx::Size size = window->GetContentsSize();
    return std::abs(size.width() - 360) <= 1 &&
           std::abs(size.height() - 280) <= 1;
  }));
  ASSERT_TRUE(content::ExecJs(page, "resizeTo(420, 350)"));
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return window->GetBounds().size() == gfx::Size(420, 350); }));
  EXPECT_NEAR(306, window->GetContentsSize().height(), 1);
  const gfx::Point origin = window->GetBounds().origin();
  ASSERT_TRUE(content::ExecJs(page, "moveBy(15, 20)"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return window->GetBounds().origin() == origin + gfx::Vector2d(15, 20);
  }));
  CloseBrowserSynchronously(popup);
}

}  // namespace
