#import <AppKit/AppKit.h>

#include "bark/bridge/barc_bridge_functions.h"
#include "bark/browser/ui/bark_window_host.h"
#include "bark/bridge/barc_profiles.h"

#include "base/command_line.h"
#include "base/memory/raw_ptr.h"
#include "base/run_loop.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "chrome/browser/enterprise/data_protection/data_protection_navigation_controller.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/enterprise/buildflags/buildflags.h"
#include "components/enterprise/data_controls/core/browser/test_utils.h"
#include "components/sessions/core/session_id.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/views/widget/widget.h"

namespace {
using OpenResult = base::test::TestFuture<barc_profile_status, int32_t>;
void Opened(barc_profile_status status, int32_t window, void* data) {
  static_cast<OpenResult*>(data)->SetValue(status, window);
}
BrowserWindowInterface* FindWindow(int32_t id) {
  return GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(id));
}

}  // namespace

class BarcNativePolicyBrowserTest : public InProcessBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-shared-native-window");
  }
  void SetUpOnMainThread() override {
    InProcessBrowserTest::SetUpOnMainThread();
    ASSERT_TRUE(embedded_test_server()->Start());
    OpenResult work;
    barc_profile_open_window("af1ebd13-7dde-42ca-90b3-a1ba6ad4ca21",
                             BARC_PROFILE_BLANK, Opened, &work);
    ASSERT_EQ(BARC_PROFILE_OK, work.Get<0>());
    work_id_ = work.Get<1>();
    work_ = FindWindow(work_id_);
    ASSERT_NE(nullptr, work_);
    OpenResult personal;
    barc_profile_open_in_native_window(
        work_id_, "f27d8cc9-0498-42e0-b2f9-54578890c34e",
        BARC_PROFILE_BLANK, Opened, &personal);
    ASSERT_EQ(BARC_PROFILE_OK, personal.Get<0>());
    personal_id_ = personal.Get<1>();
    personal_ = FindWindow(personal_id_);
    ASSERT_NE(nullptr, personal_);
    ASSERT_NE(work_->GetProfile(), personal_->GetProfile());
    host_ = bark::BarkWindowHost::ForBrowser(work_);
    ASSERT_NE(nullptr, host_);
    ASSERT_EQ(host_, bark::BarkWindowHost::ForBrowser(personal_));
    root_ = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    ASSERT_EQ(1, barc_window_set_root_view(work_id_, (__bridge void*)root_));
    ASSERT_EQ(1, barc_window_select(work_id_));
  }

  void TearDownOnMainThread() override {
    host_ = nullptr;
    root_ = nil;
    work_ = nullptr;
    personal_ = nullptr;
    InProcessBrowserTest::TearDownOnMainThread();
  }

 protected:
  int32_t work_id_ = 0;
  int32_t personal_id_ = 0;
  raw_ptr<BrowserWindowInterface> work_ = nullptr;
  raw_ptr<BrowserWindowInterface> personal_ = nullptr;
  raw_ptr<bark::BarkWindowHost> host_ = nullptr;
  NSView* __strong root_ = nil;

  NSView* Page(int32_t owner, int32_t index = 0) {
    return (__bridge NSView*)barc_tab_native_view(owner,
                                                 barc_window_tab_at(owner, index));
  }
};

#if BUILDFLAG(ENTERPRISE_SCREENSHOT_PROTECTION)
IN_PROC_BROWSER_TEST_F(BarcNativePolicyBrowserTest,
                       CapturePolicyTracksVisibleProfileBeforeShow) {
  data_controls::SetDataControls(work_->GetProfile()->GetPrefs(), {R"({
    "name": "block_screenshot", "rule_id": "shared-work-policy",
    "sources": {"urls": ["*"]},
    "restrictions": [{"class": "SCREENSHOT", "level": "BLOCK"}]
  })"});
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      work_, embedded_test_server()->GetURL("/title1.html")));
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      personal_, embedded_test_server()->GetURL("/title2.html")));
  auto* work_contents = work_->GetTabStripModel()->GetActiveWebContents();
  auto* personal_contents = personal_->GetTabStripModel()->GetActiveWebContents();
  ASSERT_EQ(work_->GetProfile(), work_contents->GetBrowserContext());
  ASSERT_EQ(personal_->GetProfile(), personal_contents->GetBrowserContext());
  ASSERT_TRUE(base::test::RunUntil([&] {
    return enterprise_data_protection::IsScreenShareBlocked(work_contents);
  }));
  ASSERT_FALSE(enterprise_data_protection::IsScreenShareBlocked(personal_contents));
  NSView* work_page = Page(work_id_);
  NSView* personal_page = Page(personal_id_);
  ASSERT_NE(nil, work_page);
  ASSERT_NE(nil, personal_page);
  auto* widget = host_->widget();
  ASSERT_EQ(1, barc_window_select(work_id_));
  EXPECT_FALSE(widget->AreScreenshotsAllowed());
  [root_ addSubview:work_page];
  ASSERT_EQ(1, barc_window_show(work_id_));
  EXPECT_FALSE(widget->AreScreenshotsAllowed());

  [work_page removeFromSuperview];
  ASSERT_EQ(1, barc_window_select(personal_id_));
  EXPECT_TRUE(widget->AreScreenshotsAllowed());
  [root_ addSubview:personal_page];
  EXPECT_TRUE(widget->AreScreenshotsAllowed());

  [personal_page removeFromSuperview];
  ASSERT_EQ(1, barc_window_select(work_id_));
  EXPECT_FALSE(widget->AreScreenshotsAllowed());
  [root_ addSubview:work_page];
  EXPECT_FALSE(widget->AreScreenshotsAllowed());
}
#endif

IN_PROC_BROWSER_TEST_F(BarcNativePolicyBrowserTest,
                       DetachedPersonalPanesPreserveWorkResponder) {
  ASSERT_NE(0, barc_tab_create(personal_id_, "about:blank", 0));
  ASSERT_EQ(1, barc_window_show(work_id_));
  NSView* work = Page(work_id_);
  ASSERT_NE(nil, work);
  work.frame = root_.bounds;
  [root_ addSubview:work];
  NSWindow* window = root_.window;
  ASSERT_NE(nil, window);
  NSTextField* editor =
      [[NSTextField alloc] initWithFrame:NSMakeRect(10, 10, 180, 28)];
  [root_ addSubview:editor];
  ASSERT_TRUE([window makeFirstResponder:editor]);
  NSResponder* responder = window.firstResponder;
  ASSERT_NE(nil, responder);

  NSView* personal_root =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  for (int i = 0; i < 2; ++i) {
    NSView* pane = Page(personal_id_, i);
    ASSERT_NE(nil, pane);
    pane.frame = NSMakeRect(400 * i, 0, 400, 600);
    [personal_root addSubview:pane];
    EXPECT_EQ(nil, pane.window);
  }
  personal_->GetTabStripModel()->GetActiveWebContents()->Focus();
  base::RunLoop().RunUntilIdle();
  EXPECT_TRUE(work_->IsSelectedForNativeWindow());
  EXPECT_FALSE(personal_->IsSelectedForNativeWindow());
  EXPECT_EQ(responder, window.firstResponder);
}
