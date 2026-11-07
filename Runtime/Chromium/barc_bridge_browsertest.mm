#import <AppKit/AppKit.h>

#include "chrome/browser/ui/views/frame/barc_bridge.h"
#include "chrome/browser/ui/views/frame/barc_profiles.h"

#include <array>

#include "base/command_line.h"
#include "base/functional/callback_helpers.h"
#include "base/scoped_observation.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/download/download_prefs.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/sessions/session_service.h"
#include "chrome/browser/sessions/session_service_factory.h"
#include "chrome/browser/ui/browser_active_state_manager/browser_active_state_manager.h"
#include "chrome/browser/ui/browser_element_identifiers.h"
#include "chrome/browser/ui/browser_init_state.h"
#include "chrome/browser/ui/browser_manager_service.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/embedder_browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/ui/views/frame/app_menu_button.h"
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
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/base/window_open_disposition.h"
#include "ui/views/interaction/view_subregion_anchor.h"
#include "ui/views/view_observer.h"
#include "url/gurl.h"

namespace {
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
  ui_test_utils::BrowserDestroyedObserver work_closed(work);
  ui_test_utils::BrowserDestroyedObserver personal_closed(personal);
  host->CloseNow();
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
  bool cancelled_application_quit = false;
  auto quit_observation = chrome::AddClosingAllBrowsersCallback(
      base::BindLambdaForTesting([&](bool closing) {
        cancelled_application_quit |= !closing;
      }));
  host->Close();
  auto* first = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(first->is_before_unload_dialog());
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
      if (!children_before.contains(child) && child->IsVisible()) {
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
