#include "bark/bridge/barc_bridge.h"
#include "bark/bridge/barc_profiles.h"

#include "base/command_line.h"
#include "base/memory/raw_ptr.h"
#include "base/run_loop.h"
#include "base/scoped_observation.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "chrome/browser/enterprise/data_protection/data_protection_navigation_controller.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/split_tab_metrics.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/frame/browser_frame_view.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/browser_widget.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/enterprise/buildflags/buildflags.h"
#include "components/enterprise/data_controls/core/browser/test_utils.h"
#include "components/sessions/core/session_id.h"
#include "components/split_tabs/split_tab_visual_data.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/views/controls/webview/webview.h"
#include "ui/views/focus/focus_manager.h"
#include "ui/views/view.h"
#include "ui/views/view_observer.h"
#include "ui/views/view_utils.h"

namespace {
using OpenResult = base::test::TestFuture<barc_profile_status, int32_t>;
void Opened(barc_profile_status status, int32_t window, void* data) {
  static_cast<OpenResult*>(data)->SetValue(status, window);
}
BrowserWindowInterface* FindWindow(int32_t id) {
  return GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(id));
}

#if BUILDFLAG(ENTERPRISE_SCREENSHOT_PROTECTION)
// Observe actual retained frame transitions, not a synthetic policy cache.
class CaptureAtVisibilityChange : public views::ViewObserver {
 public:
  CaptureAtVisibilityChange(views::View* frame,
                           BrowserWidget* widget,
                           bool expected_allow)
      : widget_(widget), expected_allow_(expected_allow) {
    observation_.Observe(frame);
  }
  void OnViewVisibilityChanged(views::View* observed,
                               views::View* starting,
                               bool visible) override {
    if (observed != starting)
      return;
    ++changes_;
    EXPECT_EQ(expected_allow_, widget_->AreScreenshotsAllowed())
        << "capture policy at frame visible=" << visible;
  }
  void OnViewIsDeleting(views::View*) override { observation_.Reset(); }
  int changes() const { return changes_; }

 private:
  raw_ptr<BrowserWidget> widget_;
  bool expected_allow_;
  int changes_ = 0;
  base::ScopedObservation<views::View, views::ViewObserver> observation_{this};
};
#endif
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
                             BARC_PROFILE_SETTINGS, Opened, &work);
    ASSERT_EQ(BARC_PROFILE_OK, work.Get<0>());
    work_id_ = work.Get<1>();
    work_ = FindWindow(work_id_);
    ASSERT_NE(nullptr, work_);
    OpenResult personal;
    barc_profile_open_in_native_window(
        work_id_, "f27d8cc9-0498-42e0-b2f9-54578890c34e",
        BARC_PROFILE_SETTINGS, Opened, &personal);
    ASSERT_EQ(BARC_PROFILE_OK, personal.Get<0>());
    personal_id_ = personal.Get<1>();
    personal_ = FindWindow(personal_id_);
    ASSERT_NE(nullptr, personal_);
    work_view_ = BrowserView::GetBrowserViewForBrowser(work_);
    personal_view_ = BrowserView::GetBrowserViewForBrowser(personal_);
    ASSERT_NE(nullptr, work_view_);
    ASSERT_NE(nullptr, personal_view_);
    ASSERT_NE(work_->GetProfile(), personal_->GetProfile());
    ASSERT_EQ(work_view_->browser_widget(), personal_view_->browser_widget());
    ASSERT_EQ(work_view_->GetNativeWindow(), personal_view_->GetNativeWindow());
    ASSERT_NE(nullptr, work_view_->parent());
    ASSERT_NE(nullptr, personal_view_->parent());
    ASSERT_TRUE(views::IsViewClass<BrowserFrameView>(work_view_->parent()));
    ASSERT_TRUE(views::IsViewClass<BrowserFrameView>(personal_view_->parent()));
    ASSERT_TRUE(work_view_->parent()->Contains(work_view_));
    ASSERT_TRUE(personal_view_->parent()->Contains(personal_view_));
    ASSERT_NE(work_view_->parent(), personal_view_->parent());
    ASSERT_EQ(1, barc_window_select(work_id_));
  }

  void TearDownOnMainThread() override {
    work_view_ = nullptr;
    personal_view_ = nullptr;
    work_ = nullptr;
    personal_ = nullptr;
    InProcessBrowserTest::TearDownOnMainThread();
  }

 protected:
  int32_t work_id_ = 0;
  int32_t personal_id_ = 0;
  raw_ptr<BrowserWindowInterface> work_ = nullptr;
  raw_ptr<BrowserWindowInterface> personal_ = nullptr;
  raw_ptr<BrowserView> work_view_ = nullptr;
  raw_ptr<BrowserView> personal_view_ = nullptr;
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
  ASSERT_EQ(1, barc_window_select(work_id_));
  auto* widget = work_view_->browser_widget();
  ASSERT_FALSE(widget->AreScreenshotsAllowed());
  // A real inactive BrowserView callback cannot relax the selected policy.
  personal_view_->ApplyScreenshotSettings(true);
  EXPECT_FALSE(widget->AreScreenshotsAllowed());
  {
    CaptureAtVisibilityChange outgoing(work_view_->parent(), widget, false);
    CaptureAtVisibilityChange incoming(personal_view_->parent(), widget, true);
    ASSERT_EQ(1, barc_window_select(personal_id_));
    EXPECT_EQ(1, outgoing.changes());
    EXPECT_EQ(1, incoming.changes());
    EXPECT_TRUE(widget->AreScreenshotsAllowed());
  }
  // Nor may an inactive protected profile block the selected unprotected view.
  work_view_->ApplyScreenshotSettings(false);
  EXPECT_TRUE(widget->AreScreenshotsAllowed());
  {
    CaptureAtVisibilityChange outgoing(personal_view_->parent(), widget, true);
    CaptureAtVisibilityChange incoming(work_view_->parent(), widget, false);
    ASSERT_EQ(1, barc_window_select(work_id_));
    EXPECT_EQ(1, outgoing.changes());
    EXPECT_EQ(1, incoming.changes());
    EXPECT_FALSE(widget->AreScreenshotsAllowed());
  }
}
#endif

IN_PROC_BROWSER_TEST_F(BarcNativePolicyBrowserTest,
                       InactiveSplitPreservesSharedStoredFocus) {
  ASSERT_NE(0, barc_tab_create(personal_id_, "about:blank", 0));
  ASSERT_EQ(1, barc_window_select(work_id_));
  auto* widget = work_view_->browser_widget();
  widget->Hide();
  ASSERT_TRUE(base::test::RunUntil([&] { return !widget->IsActive(); }));
  auto* focus = widget->GetFocusManager();
  // Clear only the Views focus. ClearFocus() also makes the native content
  // view first responder on macOS, which can restore the focused view.
  focus->SetFocusedView(nullptr);
  auto* stored = work_view_->GetActiveContentsWebView();
  focus->SetStoredFocusView(stored);
  ASSERT_EQ(nullptr, focus->GetFocusedView());
  ASSERT_EQ(stored, focus->GetStoredFocusView());
  auto* strip = personal_->GetTabStripModel();
  ASSERT_EQ(2, strip->count());
  const auto split = strip->AddToNewSplit(
      {0, 1}, split_tabs::SplitTabVisualData(),
      split_tabs::SplitTabCreatedSource::kToolbarButton);
  base::RunLoop().RunUntilIdle();
  EXPECT_TRUE(strip->ContainsSplit(split));
  EXPECT_EQ(2u, personal_view_->GetAllVisibleContentsWebViews().size());
  EXPECT_FALSE(personal_view_->IsSelectedForNativeWindow());
  EXPECT_EQ(nullptr, focus->GetFocusedView());
  EXPECT_EQ(stored, focus->GetStoredFocusView());
}
