#include "chrome/browser/ui/views/frame/barc_profiles.h"

#include <string>
#include <utility>

#include "base/files/file_util.h"
#include "base/run_loop.h"
#include "base/test/test_future.h"
#include "base/threading/thread_restrictions.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_attributes_entry.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/common/pref_names.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "components/prefs/pref_service.h"
#include "components/sessions/core/session_id.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/base/base_window.h"
#include "url/gurl.h"

namespace {
constexpr char kWork[] = "b482ffdf-5bb1-4f77-b176-12f17ae8f1af";
constexpr char kPersonal[] = "c9c590de-4a1c-44ae-b110-ddf377cba483";
using Result = base::test::TestFuture<barc_profile_status, int32_t>;
void Completed(barc_profile_status status, int32_t window, void* data) {
  static_cast<Result*>(data)->SetValue(status, window);
}
BrowserWindowInterface* Window(int32_t id) {
  return GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(id));
}
}  // namespace

class BarcProfilesBrowserTest : public InProcessBrowserTest {};

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest, UUIDOwnershipAndInternalPages) {
  // Concurrent same-UUID requests exercise ProfileManager's own coalescing.
  Result first;
  Result second;
  barc_profile_open_window(kWork, BARC_PROFILE_SETTINGS, Completed, &first);
  barc_profile_open_window("B482FFDF-5BB1-4F77-B176-12F17AE8F1AF",
                           BARC_PROFILE_EXTENSIONS, Completed, &second);
  EXPECT_FALSE(first.IsReady());
  ASSERT_EQ(BARC_PROFILE_OK, first.Get<0>());
  ASSERT_EQ(BARC_PROFILE_OK, second.Get<0>());
  auto* work = Window(first.Get<1>());
  auto* work_peer = Window(second.Get<1>());
  ASSERT_NE(nullptr, work);
  ASSERT_NE(nullptr, work_peer);
  ASSERT_EQ(work->GetProfile(), work_peer->GetProfile());
  auto* manager = g_browser_process->profile_manager();
  const auto path =
      manager->user_data_dir().AppendASCII(std::string("Barc-") + kWork);
  EXPECT_EQ(path, work->GetProfile()->GetPath());
  EXPECT_EQ(work->GetProfile(), manager->GetProfileByPath(path));
  EXPECT_NE(browser()->GetProfile(), work->GetProfile());

  Result third;
  barc_profile_open_window(kPersonal, BARC_PROFILE_SETTINGS, Completed, &third);
  ASSERT_EQ(BARC_PROFILE_OK, third.Get<0>());
  auto* personal = Window(third.Get<1>());
  ASSERT_NE(nullptr, personal);
  EXPECT_NE(work->GetProfile(), personal->GetProfile());
  EXPECT_NE(path, personal->GetProfile()->GetPath());
  work->GetProfile()->GetPrefs()->SetBoolean(prefs::kShowHomeButton, true);
  personal->GetProfile()->GetPrefs()->SetBoolean(prefs::kShowHomeButton, false);
  EXPECT_TRUE(
      work_peer->GetProfile()->GetPrefs()->GetBoolean(prefs::kShowHomeButton));
  EXPECT_FALSE(
      personal->GetProfile()->GetPrefs()->GetBoolean(prefs::kShowHomeButton));

  auto* settings = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(settings));
  EXPECT_EQ(work->GetProfile(), settings->GetBrowserContext());
  EXPECT_EQ(GURL("chrome://settings/"), settings->GetLastCommittedURL());
  EXPECT_EQ(true, content::EvalJs(settings,
                                  "new "
                                  "Promise(r=>chrome.settingsPrivate.getPref('"
                                  "browser.show_home_button',p=>r(p.value)))"));
  auto* extensions = work_peer->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(extensions));
  EXPECT_EQ(work->GetProfile(), extensions->GetBrowserContext());
  EXPECT_EQ(GURL("chrome://extensions/"), extensions->GetLastCommittedURL());
  EXPECT_EQ("object",
            content::EvalJs(extensions, "typeof chrome.developerPrivate"));

  // Labels are independent of the immutable UUID/path; frontmost is irrelevant.
  auto* entry =
      manager->GetProfileAttributesStorage().GetProfileAttributesWithPath(path);
  ASSERT_NE(nullptr, entry);
  entry->SetLocalProfileName(u"Renamed Work", false);
  for (auto [destination, url] :
       {std::pair{BARC_PROFILE_PRIVACY, "chrome://settings/privacy"},
        std::pair{BARC_PROFILE_SITE_SETTINGS, "chrome://settings/content"},
        std::pair{BARC_PROFILE_CLEAR_DATA,
                  "chrome://settings/clearBrowserData"}}) {
    personal->GetWindow()->Activate();
    Result opened;
    barc_profile_open_window(kWork, destination, Completed, &opened);
    ASSERT_EQ(BARC_PROFILE_OK, opened.Get<0>());
    auto* window = Window(opened.Get<1>());
    ASSERT_NE(nullptr, window);
    EXPECT_EQ(work->GetProfile(), window->GetProfile());
    EXPECT_EQ(path, window->GetProfile()->GetPath());
    char uuid[37];
    EXPECT_EQ(sizeof(uuid),
              barc_window_profile_uuid(opened.Get<1>(), uuid, sizeof(uuid)));
    EXPECT_STREQ(kWork, uuid);
    auto* contents = window->GetTabStripModel()->GetActiveWebContents();
    ASSERT_TRUE(content::WaitForLoadStop(contents));
    EXPECT_EQ(work->GetProfile(), contents->GetBrowserContext());
    EXPECT_EQ(GURL(url), contents->GetLastCommittedURL());
  }
  char short_uuid[5];
  EXPECT_EQ(37u, barc_window_profile_uuid(first.Get<1>(), short_uuid,
                                          sizeof(short_uuid)));
  EXPECT_STREQ("b482", short_uuid);
  const int32_t closed_id = second.Get<1>();
  CloseBrowserSynchronously(work_peer);
  char closed_uuid[37] = "unchanged";
  EXPECT_EQ(0u, barc_window_profile_uuid(closed_id, closed_uuid,
                                         sizeof(closed_uuid)));
  EXPECT_STREQ("", closed_uuid);
  char default_uuid[37] = "unchanged";
  EXPECT_EQ(0u, barc_window_profile_uuid(browser()->GetSessionID().id(),
                                         default_uuid, sizeof(default_uuid)));
  EXPECT_STREQ("", default_uuid);
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest, InvalidUUIDNeverFallsBack) {
  const size_t count = GlobalBrowserCollection::GetInstance()->GetSize();
  const char* const invalid[] = {nullptr, "", "../Default",
                                 "00000000-0000-0000-0000-000000000000",
                                 "b482ffdf5bb14f77b17612f17ae8f1af"};
  for (const char* uuid : invalid) {
    Result result;
    barc_profile_open_window(uuid, BARC_PROFILE_SETTINGS, Completed, &result);
    EXPECT_FALSE(result.IsReady());
    EXPECT_EQ(BARC_PROFILE_INVALID_ARGUMENT, result.Get<0>());
    EXPECT_EQ(0, result.Get<1>());
  }
  Result destination;
  barc_profile_open_window(kWork, static_cast<barc_profile_destination>(5),
                           Completed, &destination);
  EXPECT_EQ(BARC_PROFILE_INVALID_ARGUMENT, destination.Get<0>());
  EXPECT_EQ(0, destination.Get<1>());
  EXPECT_EQ(count, GlobalBrowserCollection::GetInstance()->GetSize());
  char stale[37] = "unchanged";
  EXPECT_EQ(0u, barc_window_profile_uuid(-1, stale, sizeof(stale)));
  EXPECT_STREQ("", stale);
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       AsyncCreationFailureNeverFallsBack) {
  constexpr char kFailed[] = "6752d615-f78d-43ea-bd1a-a7aa0a2b8c97";
  auto* manager = g_browser_process->profile_manager();
  const auto root = manager->user_data_dir();
  const auto path = root.AppendASCII(std::string("Barc-") + kFailed);
  {
    base::ScopedAllowBlockingForTesting allow_io;
    const auto obstruction = root.AppendASCII("barc-profile-obstruction");
    ASSERT_TRUE(base::WriteFile(obstruction, "owned synthetic obstruction"));
    // Unlike a file at `path` (which Chromium may open read-only), this leaves
    // the profile directory absent. JsonPrefStore's no_dir initialization then
    // fails asynchronously, propagating nullptr through ProfileManager.
    ASSERT_TRUE(
        base::CreateSymbolicLink(obstruction.AppendASCII("profile"), path));
    ASSERT_FALSE(base::PathExists(path));
  }
  const auto windows = GlobalBrowserCollection::GetInstance()->GetSize();
  struct Completion {
    Result result;
    int calls = 0;
  } completion;
  barc_profile_open_window(
      kFailed, BARC_PROFILE_SETTINGS,
      [](barc_profile_status status, int32_t window, void* data) {
        auto* completion = static_cast<Completion*>(data);
        ++completion->calls;
        completion->result.SetValue(status, window);
      },
      &completion);
  EXPECT_FALSE(completion.result.IsReady());
  EXPECT_EQ(BARC_PROFILE_FAILED, completion.result.Get<0>());
  EXPECT_EQ(0, completion.result.Get<1>());
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1, completion.calls);
  EXPECT_EQ(windows, GlobalBrowserCollection::GetInstance()->GetSize());
  EXPECT_EQ(nullptr, manager->GetProfileByPath(path));
}
