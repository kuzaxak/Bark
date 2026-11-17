#import <AppKit/AppKit.h>

#include "bark/bridge/barc_profiles.h"

#include <atomic>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "components/search_engines/template_url.h"
#include "components/search_engines/template_url_data.h"
#include "components/search_engines/template_url_service.h"
#include "base/check.h"
#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/run_loop.h"
#include "base/scoped_observation.h"
#include "base/synchronization/lock.h"
#include "base/test/scoped_run_loop_timeout.h"
#include "base/functional/callback_helpers.h"
#include "content/public/browser/browser_task_traits.h"
#include "services/network/public/cpp/network_switches.h"
#include "net/test/embedded_test_server/http_response.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "base/threading/thread_restrictions.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/extensions/chrome_test_extension_loader.h"
#include "chrome/browser/extensions/api/messaging/native_messaging_test_util.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/extensions/extension_util.h"
#include "chrome/browser/prefs/incognito_mode_prefs.h"
#include "chrome/browser/profiles/nuke_profile_directory_utils.h"
#include "chrome/browser/profiles/delete_profile_helper.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_attributes_entry.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "chrome/browser/profiles/profile_window.h"
#include "chrome/browser/renderer_context_menu/render_view_context_menu_test_util.h"
#include "chrome/browser/sessions/session_data_service.h"
#include "chrome/browser/sessions/session_data_service_factory.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/profiles/profile_picker.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "bark/browser/content_blocking/native_content_blocker.h"
#include "bark/bridge/barc_bridge.h"
#include "bark/bridge/barc_runtime_startup.h"
#include "chrome/common/pref_names.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/download/public/common/download_item.h"
#include "components/javascript_dialogs/app_modal_dialog_controller.h"
#include "components/javascript_dialogs/app_modal_dialog_view.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/policy/core/common/policy_pref_names.h"
#include "components/prefs/pref_service.h"
#include "components/sessions/core/session_id.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/download_manager.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/download_test_observer.h"
#include "content/public/test/slow_download_http_response.h"
#include "extensions/browser/background_script_executor.h"
#include "extensions/browser/api/messaging/message_service.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/process_manager.h"
#include "extensions/common/constants.h"
#include "extensions/common/extension.h"
#include "extensions/common/extension_builder.h"
#include "extensions/common/mojom/manifest.mojom.h"
#include "extensions/test/extension_test_message_listener.h"
#include "extensions/test/test_extension_dir.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/test/embedded_test_server/http_request.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/base/base_window.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "url/gurl.h"
#include "url/origin.h"

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

  // The app's typed Password Manager link uses the existing navigation seam
  // after exact-profile utility admission, not a new profile factory route.
  ASSERT_NE(work, work_peer);
  ASSERT_EQ(1, barc_tab_navigate(second.Get<1>(),
      barc_window_tab_at(second.Get<1>(), 0),
      "chrome://password-manager/passwords"));
  ASSERT_TRUE(content::WaitForLoadStop(extensions));
  EXPECT_EQ(GURL("chrome://password-manager/passwords"), extensions->GetLastCommittedURL());
  EXPECT_EQ(work->GetProfile(), extensions->GetBrowserContext());
  EXPECT_NE(nullptr, extensions->GetWebUI());
  EXPECT_EQ(GURL("chrome://settings/"), settings->GetLastCommittedURL());
  auto* personal_settings = personal->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(personal_settings));
  EXPECT_EQ(personal->GetProfile(), personal_settings->GetBrowserContext());
  EXPECT_EQ(GURL("chrome://settings/"), personal_settings->GetLastCommittedURL());
  EXPECT_FALSE(personal->GetProfile()->GetPrefs()->GetBoolean(prefs::kShowHomeButton));

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
  barc_profile_open_window(kWork, static_cast<barc_profile_destination>(-1),
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

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       PrivateSessionsOwnDataChildrenAndFinalDisposal) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL site = embedded_test_server()->GetURL("/title1.html");
  auto* manager = g_browser_process->profile_manager();
  Result first;
  Result second;
  barc_private_session_open_window(Completed, &first);
  barc_private_session_open_window(Completed, &second);
  ASSERT_EQ(BARC_PROFILE_OK, first.Get<0>());
  ASSERT_EQ(BARC_PROFILE_OK, second.Get<0>());
  const int32_t first_id = first.Get<1>();
  const int32_t second_id = second.Get<1>();
  auto* first_window = Window(first_id);
  auto* second_window = Window(second_id);
  ASSERT_TRUE(first_window);
  ASSERT_TRUE(second_window);
  auto* first_profile = first_window->GetProfile();
  auto* second_profile = second_window->GetProfile();
  ASSERT_TRUE(first_profile->IsGuestSession());
  ASSERT_TRUE(first_profile->IsPrimaryOTRProfile());
  ASSERT_TRUE(second_profile->IsGuestSession());
  ASSERT_TRUE(second_profile->IsPrimaryOTRProfile());
  ASSERT_NE(first_profile, second_profile);
  ASSERT_NE(first_profile->GetOriginalProfile(),
            second_profile->GetOriginalProfile());
  ASSERT_NE(browser()->GetProfile(), first_profile->GetOriginalProfile());
  char first_session[37];
  char second_session[37];
  ASSERT_EQ(37u, barc_window_private_session_uuid(first_id, first_session,
                                                  sizeof(first_session)));
  ASSERT_EQ(37u, barc_window_private_session_uuid(second_id, second_session,
                                                  sizeof(second_session)));
  EXPECT_STRNE(first_session, second_session);
  EXPECT_EQ(37u, barc_window_private_session_uuid(first_id, nullptr, 0));
  char short_session[5];
  EXPECT_EQ(37u, barc_window_private_session_uuid(first_id, short_session,
                                                  sizeof(short_session)));
  EXPECT_EQ(std::string(first_session).substr(0, 4), short_session);
  char rejected[37] = "unchanged";
  EXPECT_EQ(0u, barc_window_private_session_uuid(-1, rejected, sizeof(rejected)));
  EXPECT_STREQ("", rejected);
  EXPECT_EQ(0u, barc_window_profile_uuid(first_id, rejected, sizeof(rejected)));
  EXPECT_STREQ("", rejected);
  EXPECT_EQ(0u, barc_window_private_session_uuid(browser()->GetSessionID().id(),
                                                 rejected, sizeof(rejected)));
  EXPECT_STREQ("", rejected);
  const auto first_path = first_profile->GetPath();
  ASSERT_TRUE(ProfileManager::IsPrivateSessionProfilePath(first_path));
  ASSERT_EQ(manager->user_data_dir(), first_path.DirName());
  EXPECT_FALSE(ProfileManager::IsPrivateSessionProfilePath(
      first_path.AppendASCII("child")));
  auto* entry = manager->GetProfileAttributesStorage().GetProfileAttributesWithPath(
      first_path);
  ASSERT_TRUE(entry);
  EXPECT_TRUE(entry->IsEphemeral());
  EXPECT_TRUE(entry->IsOmitted());
  auto first_alive = first_profile->GetWeakPtr();
  auto parent_alive = first_profile->GetOriginalProfile()->GetWeakPtr();
  auto* first_page = first_window->GetTabStripModel()->GetActiveWebContents();
  auto* second_page = second_window->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::NavigateToURL(first_page, site));
  ASSERT_TRUE(content::NavigateToURL(second_page, site));
  EXPECT_EQ("session=first", content::EvalJs(
      first_page, "document.cookie='session=first;path=/';document.cookie"));
  EXPECT_EQ("", content::EvalJs(second_page, "document.cookie"));
  EXPECT_EQ("session=second", content::EvalJs(
      second_page, "document.cookie='session=second;path=/';document.cookie"));
  auto* first_settings =
      HostContentSettingsMapFactory::GetForProfile(first_profile);
  auto* second_settings =
      HostContentSettingsMapFactory::GetForProfile(second_profile);
  ASSERT_TRUE(first_settings);
  ASSERT_TRUE(second_settings);
  first_settings->SetContentSettingDefaultScope(
      site, site, ContentSettingsType::GEOLOCATION, CONTENT_SETTING_ALLOW);
  EXPECT_EQ(CONTENT_SETTING_ALLOW, first_settings->GetContentSetting(
      site, site, ContentSettingsType::GEOLOCATION));
  EXPECT_EQ(CONTENT_SETTING_ASK, second_settings->GetContentSetting(
      site, site, ContentSettingsType::GEOLOCATION));
  EXPECT_EQ(CONTENT_SETTING_ASK,
      HostContentSettingsMapFactory::GetForProfile(browser()->GetProfile())
          ->GetContentSetting(site, site, ContentSettingsType::GEOLOCATION));

  // A real window.open child must retain the exact session, not singleton Guest.
  content::WebContents* child_page = nullptr;
  {
    content::WebContentsAddedObserver popup;
    ASSERT_EQ(true, content::EvalJs(first_page, content::JsReplace(
        "window.open($1, 'barc-private-child', 'popup');true", site)));
    child_page = popup.GetWebContents();
  }
  ASSERT_TRUE(child_page);
  ASSERT_TRUE(content::WaitForLoadStop(child_page));
  ASSERT_EQ(first_profile, child_page->GetBrowserContext());
  auto* child_tab = tabs::TabInterface::GetFromContents(child_page);
  ASSERT_TRUE(child_tab);
  auto* child = child_tab->GetBrowserWindowInterface();
  ASSERT_TRUE(child);
  ASSERT_NE(first_window, child);
  const int32_t child_id = child->GetSessionID().id();
  char child_session[37];
  EXPECT_EQ(37u, barc_window_private_session_uuid(child_id, child_session,
                                                  sizeof(child_session)));
  EXPECT_STREQ(first_session, child_session);
  EXPECT_EQ("session=first", content::EvalJs(child_page, "document.cookie"));
  ASSERT_EQ(1, barc_window_close(first_id));
  ASSERT_TRUE(base::test::RunUntil([&] { return !Window(first_id); }));
  ASSERT_TRUE(first_alive);
  ASSERT_TRUE(parent_alive);
  EXPECT_EQ("session=first", content::EvalJs(child_page, "document.cookie"));
  ASSERT_EQ(1, barc_window_close(child_id));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !first_alive && !parent_alive &&
           !manager->GetProfileByPath(first_path) &&
           !manager->GetProfileAttributesStorage()
                .GetProfileAttributesWithPath(first_path);
  }));
  EXPECT_TRUE(IsProfileDirectoryMarkedForDeletion(first_path));
  EXPECT_EQ(0u, barc_window_private_session_uuid(first_id, rejected,
                                                 sizeof(rejected)));
  EXPECT_STREQ("", rejected);
  EXPECT_EQ("session=second", content::EvalJs(second_page, "document.cookie"));

  Result fresh;
  barc_private_session_open_window(Completed, &fresh);
  ASSERT_EQ(BARC_PROFILE_OK, fresh.Get<0>());
  auto* fresh_profile = Window(fresh.Get<1>())->GetProfile();
  EXPECT_NE(first_path, fresh_profile->GetPath());
  auto* fresh_page = Window(fresh.Get<1>())->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::NavigateToURL(fresh_page, site));
  EXPECT_EQ("", content::EvalJs(fresh_page, "document.cookie"));
  EXPECT_EQ(CONTENT_SETTING_ASK,
      HostContentSettingsMapFactory::GetForProfile(fresh_profile)
          ->GetContentSetting(site, site, ContentSettingsType::GEOLOCATION));
  ASSERT_TRUE(content::NavigateToURL(
      browser()->GetTabStripModel()->GetActiveWebContents(), site));
  EXPECT_EQ("", content::EvalJs(
      browser()->GetTabStripModel()->GetActiveWebContents(), "document.cookie"));
  EXPECT_EQ(1, barc_window_close(second_id));
  EXPECT_EQ(1, barc_window_close(fresh.Get<1>()));
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       PrivateGuestRejectsOptedInAndExternalExtensions) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL site = embedded_test_server()->GetURL("/title1.html");
  auto* regular = browser()->GetProfile();
  extensions::TestExtensionDir dir;
  dir.WriteManifest(R"({"manifest_version":3,"name":"Private isolation",
    "version":"1.0","permissions":["tabs","storage"],
    "host_permissions":["<all_urls>"],
    "background":{"service_worker":"worker.js"},
    "content_scripts":[{"matches":["<all_urls>"],"js":["content.js"]}]})");
  dir.WriteFile(FILE_PATH_LITERAL("content.js"),
      "document.documentElement.setAttribute('data-barc-extension', 'ran');");
  dir.WriteFile(FILE_PATH_LITERAL("worker.js"), R"(
    globalThis.eventsFinished = Promise.resolve();
    const record = (kind, value) => {
      eventsFinished = eventsFinished.then(async () => {
        const {seen = []} = await chrome.storage.local.get('seen');
        seen.push({kind, id: value.id, windowId: value.windowId});
        await chrome.storage.local.set({seen});
      });
    };
    chrome.tabs.onCreated.addListener(tab => record('tab', tab));
    chrome.windows.onCreated.addListener(win => record('window', win));
    chrome.test.sendMessage('private-extension-ready');
  )");
  extensions::ChromeTestExtensionLoader loader(regular);
  auto extension = loader.LoadExtension(dir.UnpackedPath());
  ASSERT_TRUE(extension);
  const std::string extension_id = extension->id();
  ExtensionTestMessageListener reloaded("private-extension-ready");
  reloaded.set_browser_context(regular);
  reloaded.set_extension_id(extension_id);
  extensions::util::SetIsIncognitoEnabled(extension_id, regular, true);
  ASSERT_TRUE(reloaded.WaitUntilSatisfied());
  ASSERT_TRUE(extensions::ExtensionPrefs::Get(regular)
                  ->IsIncognitoEnabled(extension_id));
  auto worker = [&](const std::string& script) {
    auto* process_manager = extensions::ProcessManager::Get(regular);
    if (process_manager->GetServiceWorkersForExtension(extension_id).empty()) {
      base::test::TestFuture<bool> awake;
      if (!process_manager->WakeEventPage(extension_id, awake.GetCallback()) ||
          !awake.Get()) {
        ADD_FAILURE() << "Regular extension worker did not wake";
        return base::Value();
      }
    }
    return extensions::BackgroundScriptExecutor::ExecuteScript(
        regular, extension_id, script,
        extensions::BackgroundScriptExecutor::ResultCapture::kSendScriptResult);
  };
  ASSERT_EQ(base::Value(true), worker(R"(
    eventsFinished.then(() => chrome.storage.local.set({seen: []})).then(
      () => chrome.test.sendScriptResult(true));
  )"));
  auto* regular_page = browser()->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::NavigateToURL(regular_page, site));
  EXPECT_EQ("ran", content::EvalJs(regular_page, R"(
    new Promise(resolve => {
      const read = () => document.documentElement.getAttribute('data-barc-extension');
      if (read()) { resolve(read()); return; }
      const observer = new MutationObserver(() => {
        if (read()) { observer.disconnect(); resolve(read()); }
      });
      observer.observe(document.documentElement, {attributes: true});
    });
  )"));
  Result first;
  Result second;
  barc_private_session_open_window(Completed, &first);
  barc_private_session_open_window(Completed, &second);
  ASSERT_EQ(BARC_PROFILE_OK, first.Get<0>());
  ASSERT_EQ(BARC_PROFILE_OK, second.Get<0>());
  std::vector<int> private_tabs;
  std::vector<int> private_windows;
  for (int32_t id : {first.Get<1>(), second.Get<1>()}) {
    auto* window = Window(id);
    ASSERT_TRUE(window);
    auto* profile = window->GetProfile();
    ASSERT_TRUE(profile->IsGuestSession());
    ASSERT_NE(regular, profile->GetOriginalProfile());
    auto* registry = extensions::ExtensionRegistry::Get(profile);
    ASSERT_TRUE(registry);
    EXPECT_FALSE(registry->GetInstalledExtension(extension_id));
    auto* pdf = registry->enabled_extensions().GetByID(extension_misc::kPdfExtensionId);
    ASSERT_TRUE(pdf);
    EXPECT_EQ(extensions::mojom::ManifestLocation::kComponent, pdf->location());
    // Exercise actual registrar admission, including the external exemption
    // that generic --disable-extensions semantics otherwise permit.
    auto* registrar = extensions::ExtensionRegistrar::Get(
        profile->GetOriginalProfile());
    ASSERT_TRUE(registrar);
    registrar->AddExtension(extension);
    auto external = extensions::ExtensionBuilder("Private policy denied")
        .SetLocation(extensions::mojom::ManifestLocation::kExternalPolicy).Build();
    registrar->AddExtension(external);
    EXPECT_FALSE(registry->GetInstalledExtension(extension_id));
    EXPECT_FALSE(registry->GetInstalledExtension(external->id()));
    auto* page = window->GetTabStripModel()->GetActiveWebContents();
    ASSERT_TRUE(content::NavigateToURL(page, site));
    EXPECT_EQ(false, content::EvalJs(page,
        "document.documentElement.hasAttribute('data-barc-extension')"));
    EXPECT_TRUE(extensions::ProcessManager::Get(profile)
                    ->GetServiceWorkersForExtension(extension_id).empty());
    const int tab_id = extensions::ExtensionTabUtil::GetTabId(page);
    const int window_id = extensions::ExtensionTabUtil::GetWindowId(window);
    ASSERT_GT(tab_id, 0);
    ASSERT_GT(window_id, 0);
    private_tabs.push_back(tab_id);
    private_windows.push_back(window_id);
  }
  // Positive regular traffic proves collection is running; storage survives
  // legitimate MV3 worker eviction. Foreign IDs are real extension API IDs.
  const int32_t own_window = barc_window_new_peer(browser()->GetSessionID().id());
  ASSERT_NE(0, own_window);
  const int own_window_api_id =
      extensions::ExtensionTabUtil::GetWindowId(Window(own_window));
  const int32_t own_tab = barc_tab_create(own_window, site.spec().c_str(), 0);
  ASSERT_NE(0, own_tab);
  const int own_api_id = extensions::ExtensionTabUtil::GetTabId(
      tabs::TabHandle(own_tab).Get()->GetContents());
  ASSERT_TRUE(base::test::RunUntil([&] {
    return worker(content::JsReplace(R"(
      eventsFinished.then(() => chrome.storage.local.get('seen')).then(
        ({seen = []}) => chrome.test.sendScriptResult(
          seen.some(e => e.kind === 'tab' && e.id === $1) &&
          seen.some(e => e.kind === 'window' && e.id === $2)));
    )", own_api_id, own_window_api_id)) == base::Value(true);
  }));
  for (size_t i = 0; i < private_tabs.size(); ++i) {
    EXPECT_EQ(base::Value(false), worker(content::JsReplace(R"(
      eventsFinished.then(() => chrome.storage.local.get('seen')).then(
        ({seen = []}) => chrome.test.sendScriptResult(seen.some(e =>
          (e.kind === 'tab' && (e.id === $1 || e.windowId === $2)) ||
          (e.kind === 'window' && e.id === $2))));
    )", private_tabs[i], private_windows[i])));
    EXPECT_EQ(base::Value(false), worker(content::JsReplace(R"(
      Promise.all([chrome.tabs.query({}), chrome.windows.getAll()]).then(
        ([tabs, windows]) => chrome.test.sendScriptResult(
          tabs.some(t => t.id === $1 || t.windowId === $2) ||
          windows.some(w => w.id === $2)));
    )", private_tabs[i], private_windows[i])));
  }
  EXPECT_EQ(1, barc_window_close(first.Get<1>()));
  EXPECT_EQ(1, barc_window_close(second.Get<1>()));
  EXPECT_EQ(1, barc_window_close(own_window));
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       PrivateNoWindowAndFailedInitializationReleaseParents) {
  auto* manager = g_browser_process->profile_manager();
  const auto windows_before = GlobalBrowserCollection::GetInstance()->GetSize();
  base::FilePath unused_path;
  base::WeakPtr<Profile> unused_otr;
  base::WeakPtr<Profile> unused_parent;
  bool initialized_guest = false;
  base::test::TestFuture<void> handed_off;
  manager->CreatePrivateSessionAsync(base::BindLambdaForTesting(
      [&](Profile* profile) {
        if (profile) {
          initialized_guest = profile->IsGuestSession() &&
                              profile->IsPrimaryOTRProfile();
          unused_path = profile->GetPath();
          unused_otr = profile->GetWeakPtr();
          unused_parent = profile->GetOriginalProfile()->GetWeakPtr();
        }
        // Resolve even on failure; assert saved state outside this callback.
        // Deliberately decline to create a window after actual profile init.
        handed_off.SetValue();
      }));
  ASSERT_TRUE(handed_off.Wait());
  ASSERT_TRUE(initialized_guest);
  ASSERT_FALSE(unused_path.empty());
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !unused_otr && !unused_parent &&
           !manager->GetProfileByPath(unused_path) &&
           !manager->GetProfileAttributesStorage()
                .GetProfileAttributesWithPath(unused_path);
  }));
  EXPECT_TRUE(IsProfileDirectoryMarkedForDeletion(unused_path));
  EXPECT_EQ(windows_before, GlobalBrowserCollection::GetInstance()->GetSize());

  // OnProfileAdded runs before CreateProfileAsync is called for this fresh
  // reserved path. Reuse the existing real inaccessible-path regression,
  // without a production failure injection or a directory-creation race.
  class ObstructFreshSession : public ProfileAttributesStorage::Observer {
   public:
    void OnProfileAdded(const base::FilePath& path) override {
      if (!ProfileManager::IsPrivateSessionProfilePath(path)) {
        return;
      }
      observed_path = path;
      base::ScopedAllowBlockingForTesting allow_io;
      const auto obstruction = path.DirName().AppendASCII(
          "barc-private-test-obstruction");
      ASSERT_TRUE(base::WriteFile(obstruction, "owned synthetic obstruction"));
      ASSERT_TRUE(base::CreateSymbolicLink(obstruction.AppendASCII("profile"),
                                           path));
      ASSERT_FALSE(base::PathExists(path));
    }
    base::FilePath observed_path;
  } obstruction;
  base::ScopedObservation<ProfileAttributesStorage,
                          ProfileAttributesStorage::Observer>
      observed(&obstruction);
  observed.Observe(&manager->GetProfileAttributesStorage());
  struct Completion {
    Result result;
    int calls = 0;
  } completion;
  barc_private_session_open_window(
      [](barc_profile_status status, int32_t window, void* data) {
        auto* completion = static_cast<Completion*>(data);
        ++completion->calls;
        completion->result.SetValue(status, window);
      }, &completion);
  EXPECT_FALSE(completion.result.IsReady());
  EXPECT_EQ(BARC_PROFILE_FAILED, completion.result.Get<0>());
  EXPECT_EQ(0, completion.result.Get<1>());
  observed.Reset();
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1, completion.calls);
  ASSERT_FALSE(obstruction.observed_path.empty());
  EXPECT_FALSE(manager->GetProfileByPath(obstruction.observed_path));
  EXPECT_FALSE(manager->GetProfileAttributesStorage()
                   .GetProfileAttributesWithPath(obstruction.observed_path));
  EXPECT_TRUE(IsProfileDirectoryMarkedForDeletion(obstruction.observed_path));
  EXPECT_EQ(windows_before, GlobalBrowserCollection::GetInstance()->GetSize());
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       StockOffRecordIdentitiesAreNotBarcSessions) {
  auto* incognito = CreateBrowser(
      browser()->GetProfile()->GetPrimaryOTRProfile(/*create_if_needed=*/true));
  ASSERT_TRUE(incognito);
  char identity[37] = "unchanged";
  EXPECT_EQ(0u, barc_window_private_session_uuid(incognito->GetSessionID().id(),
                                                 identity, sizeof(identity)));
  EXPECT_STREQ("", identity);
  base::test::TestFuture<Profile*> guest_ready;
  g_browser_process->profile_manager()->CreateProfileAsync(
      ProfileManager::GetGuestProfilePath(), guest_ready.GetCallback());
  auto* guest = guest_ready.Get();
  ASSERT_TRUE(guest);
  ASSERT_TRUE(guest->IsGuestSession());
  auto* guest_window = CreateBrowser(guest);
  ASSERT_TRUE(guest_window);
  EXPECT_EQ(0u,
            barc_window_private_session_uuid(guest_window->GetSessionID().id(),
                                             identity, sizeof(identity)));
  EXPECT_STREQ("", identity);
}

class BarcPrivateCommandBrowserTest : public BarcProfilesBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    BarcProfilesBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-shared-native-window");
    command_line->AppendSwitch("barc-native-shell");
  }
  void SetUp() override {
    barc_set_runtime_ready_callback(
        [](void*) {
          int32_t initial = 0;
          GlobalBrowserCollection::GetInstance()->ForEach(
              [&](BrowserWindowInterface* window) {
                initial = window->GetSessionID().id();
                return false;
              });
          CHECK_GT(initial, 0);
          NSView* header =
              [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 600)];
          CHECK(
              barc_window_attach_native_shell(initial, (__bridge void*)header));
          CHECK(barc_window_admit_discovered(initial, (__bridge void*)header));
          barc_runtime_complete_startup(initial);
        },
        nullptr);
    barc_set_runtime_window_request_callback(
        [](int32_t request, void* pointer) {
          static_cast<BarcPrivateCommandBrowserTest*>(pointer)
              ->window_requests.push_back(request);
        },
        this);
    BarcProfilesBrowserTest::SetUp();
  }

 protected:
  std::vector<int32_t> window_requests;
};

IN_PROC_BROWSER_TEST_F(BarcPrivateCommandBrowserTest,
                       NativeIncognitoAsksTheAppForItsPrivateWindow) {
  auto* manager = g_browser_process->profile_manager();
  const size_t profiles_before =
      manager->GetProfileAttributesStorage().GetNumberOfProfiles();
  chrome::NewIncognitoWindow(browser()->GetProfile());
  content::RunAllTasksUntilIdle();
  EXPECT_EQ(std::vector<int32_t>{BARC_APPLICATION_NEW_PRIVATE_WINDOW},
            window_requests);
  EXPECT_EQ(profiles_before,
            manager->GetProfileAttributesStorage().GetNumberOfProfiles());
  GlobalBrowserCollection::GetInstance()->ForEach(
      [&](BrowserWindowInterface* window) {
        EXPECT_EQ(0u, barc_window_private_session_uuid(
                          window->GetSessionID().id(), nullptr, 0));
        return true;
      });
  // The app opens its private window as an independent, hidden session.
  Result factory;
  barc_private_session_open_window(Completed, &factory);
  ASSERT_EQ(BARC_PROFILE_OK, factory.Get<0>());
  auto* window = Window(factory.Get<1>());
  ASSERT_TRUE(window);
  EXPECT_FALSE(window->GetWindow()->IsVisible());
  BarcDiscoveryWindow factory_row{sizeof(BarcDiscoveryWindow)};
  ASSERT_EQ(1, barc_window_discovery_state(factory.Get<1>(), &factory_row));
  EXPECT_NE(0u, factory_row.flags & BARC_DISCOVERY_WINDOW_APP_FACTORY);
  EXPECT_EQ(37u, barc_window_private_session_uuid(factory.Get<1>(), nullptr, 0));
  // New Window from a private window asks the app too.
  size_t browsers = 0;
  GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface*) {
    ++browsers;
    return true;
  });
  chrome::NewWindow(window);
  content::RunAllTasksUntilIdle();
  EXPECT_EQ((std::vector<int32_t>{BARC_APPLICATION_NEW_PRIVATE_WINDOW,
                                  BARC_APPLICATION_NEW_WINDOW}),
            window_requests);
  size_t after = 0;
  GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface*) {
    ++after;
    return true;
  });
  EXPECT_EQ(browsers, after);
}

IN_PROC_BROWSER_TEST_F(BarcPrivateCommandBrowserTest,
                       NativeIncognitoPreservesDisabledPolicy) {
  auto* manager = g_browser_process->profile_manager();
  const size_t profiles_before =
      manager->GetProfileAttributesStorage().GetNumberOfProfiles();
  IncognitoModePrefs::SetAvailability(
      browser()->GetProfile()->GetPrefs(),
      policy::IncognitoModeAvailability::kDisabled);
  chrome::NewIncognitoWindow(browser()->GetProfile());
  EXPECT_TRUE(window_requests.empty());
  EXPECT_EQ(profiles_before,
            manager->GetProfileAttributesStorage().GetNumberOfProfiles());
  GlobalBrowserCollection::GetInstance()->ForEach(
      [&](BrowserWindowInterface* window) {
        char identity[37];
        EXPECT_EQ(0u,
                  barc_window_private_session_uuid(window->GetSessionID().id(),
                                                   identity, sizeof(identity)));
        return true;
      });
}

IN_PROC_BROWSER_TEST_F(BarcPrivateCommandBrowserTest,
                       ForcedParentCannotFallBackToIndependentGuest) {
  auto* manager = g_browser_process->profile_manager();
  const size_t profiles_before =
      manager->GetProfileAttributesStorage().GetNumberOfProfiles();
  IncognitoModePrefs::SetAvailability(
      browser()->GetProfile()->GetPrefs(),
      policy::IncognitoModeAvailability::kForced);
  chrome::NewIncognitoWindow(browser()->GetProfile());
  EXPECT_TRUE(window_requests.empty());
  EXPECT_EQ(profiles_before,
            manager->GetProfileAttributesStorage().GetNumberOfProfiles());
  GlobalBrowserCollection::GetInstance()->ForEach(
      [&](BrowserWindowInterface* window) {
        char identity[37];
        EXPECT_EQ(0u,
                  barc_window_private_session_uuid(window->GetSessionID().id(),
                                                   identity, sizeof(identity)));
        return true;
      });
}

namespace {
class OnPrivateProfileAdded : public ProfileManagerObserver {
 public:
  explicit OnPrivateProfileAdded(base::OnceClosure action)
      : action_(std::move(action)) {
    observation_.Observe(g_browser_process->profile_manager());
  }
  void OnProfileAdded(Profile* profile) override {
    if (action_ &&
        ProfileManager::IsPrivateSessionProfilePath(profile->GetPath())) {
      called_ = true;
      std::move(action_).Run();
    }
  }
  bool called() const { return called_; }
 private:
  bool called_ = false;
  base::OnceClosure action_;
  base::ScopedObservation<ProfileManager, ProfileManagerObserver>
      observation_{this};
};
std::vector<int32_t> PrivateWindows() {
  std::vector<int32_t> windows;
  GlobalBrowserCollection::GetInstance()->ForEach(
      [&](BrowserWindowInterface* window) {
        if (barc_window_private_session_uuid(window->GetSessionID().id(),
                                             nullptr, 0)) {
          windows.push_back(window->GetSessionID().id());
        }
        return true;
      });
  return windows;
}
}  // namespace

IN_PROC_BROWSER_TEST_F(BarcPrivateCommandBrowserTest,
                       ContextLinksUseIndependentPrivateSessions) {
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL source_url = embedded_test_server()->GetURL("/title1.html");
  const GURL target = embedded_test_server()->GetURL("/echoheader?Referer");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), source_url));
  auto* source = browser()->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(source,
      "document.body.innerHTML='<input id=draft value=retained>'"));
  for (size_t expected = 1; expected <= 2; ++expected) {
    content::ContextMenuParams params;
    params.page_url = source_url;
    params.frame_url = source_url;
    params.frame_origin = url::Origin::Create(source_url);
    params.link_url = target;
    auto menu = std::make_unique<TestRenderViewContextMenu>(
        *source->GetPrimaryMainFrame(), params);
    menu->Init();
    ASSERT_TRUE(menu->IsCommandIdEnabled(
        IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD));
    menu->ExecuteCommand(IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD, 0);
    menu.reset();  // Normal menu dismissal must not cancel admitted intent.
    ASSERT_TRUE(base::test::RunUntil([&] {
      return PrivateWindows().size() == expected;
    }));
  }
  const auto windows = PrivateWindows();
  ASSERT_EQ(2u, windows.size());
  char first_identity[37], second_identity[37];
  ASSERT_EQ(37u, barc_window_private_session_uuid(
                     windows[0], first_identity, sizeof(first_identity)));
  ASSERT_EQ(37u, barc_window_private_session_uuid(
                     windows[1], second_identity, sizeof(second_identity)));
  EXPECT_STRNE(first_identity, second_identity);
  EXPECT_NE(Window(windows[0])->GetProfile(), Window(windows[1])->GetProfile());
  for (int32_t id : windows) {
    auto* contents = Window(id)->GetTabStripModel()->GetActiveWebContents();
    ASSERT_TRUE(content::WaitForLoadStop(contents));
    EXPECT_EQ(target, contents->GetLastCommittedURL());
    EXPECT_EQ("None", content::EvalJs(contents, "document.body.textContent"));
    EXPECT_EQ("", content::EvalJs(contents, "document.referrer"));
    EXPECT_TRUE(ui::PageTransitionCoreTypeIs(
        contents->GetController().GetLastCommittedEntry()->GetTransitionType(),
        ui::PAGE_TRANSITION_LINK));
    BarcDiscoveryWindow row{sizeof(BarcDiscoveryWindow)};
    ASSERT_EQ(1, barc_window_discovery_state(id, &row));
    EXPECT_TRUE(row.flags & BARC_DISCOVERY_AWAITING_ADMISSION);
    EXPECT_FALSE(row.flags & BARC_DISCOVERY_WINDOW_APP_FACTORY);
    EXPECT_FALSE(Window(id)->GetWindow()->IsVisible());
  }
  EXPECT_EQ(source_url, source->GetLastCommittedURL());
  EXPECT_EQ("retained", content::EvalJs(source, "draft.value"));
}

IN_PROC_BROWSER_TEST_F(BarcPrivateCommandBrowserTest,
                       ContextLinkCancelsWithSourceOrPolicy) {
  auto requests = std::make_shared<std::atomic<int>>(0);
  embedded_test_server()->RegisterRequestMonitor(base::BindRepeating(
      [](std::shared_ptr<std::atomic<int>> requests,
         const net::test_server::HttpRequest& request) {
        if (request.relative_url == "/echoheader?Referer") {
          ++*requests;
        }
      }, requests));
  ASSERT_TRUE(embedded_test_server()->Start());
  auto* manager = g_browser_process->profile_manager();
  for (int reason = 0; reason < 3; ++reason) {
    SCOPED_TRACE(reason);
    const int32_t owner = browser()->GetSessionID().id();
    const int32_t tab = barc_tab_create(owner, "about:blank", 1);
    ASSERT_GT(tab, 0);
    auto* source = tabs::TabHandle(tab).Get()->GetContents();
    const GURL original = embedded_test_server()->GetURL("/title1.html");
    ASSERT_TRUE(content::NavigateToURL(source, original));
    auto alive = source->GetWeakPtr();
    const GURL replacement("data:text/html,replaced-source-document");
    const size_t profiles_before =
        manager->GetProfileAttributesStorage().GetNumberOfProfiles();
    OnPrivateProfileAdded changed(base::BindLambdaForTesting([&] {
      if (reason == 0) {
        ASSERT_EQ(1, barc_tab_close(owner, tab));
      } else if (reason == 1) {
        ASSERT_TRUE(content::NavigateToURL(source, replacement));
      } else {
        IncognitoModePrefs::SetAvailability(browser()->GetProfile()->GetPrefs(),
            policy::IncognitoModeAvailability::kDisabled);
      }
    }));
    auto menu = TestRenderViewContextMenu::Create(source, original,
        embedded_test_server()->GetURL("/echoheader?Referer"));
    ASSERT_TRUE(menu->IsCommandIdEnabled(
        IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD));
    menu->ExecuteCommand(IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD, 0);
    menu.reset();
    ASSERT_TRUE(base::test::RunUntil([&] {
      return changed.called() && PrivateWindows().empty() &&
          manager->GetProfileAttributesStorage().GetNumberOfProfiles() ==
              profiles_before;
    }));
    EXPECT_EQ(0, requests->load());
    if (reason == 0) {
      EXPECT_FALSE(alive);
    } else {
      ASSERT_TRUE(alive);
      EXPECT_EQ(reason == 1 ? replacement : original,
                alive->GetLastCommittedURL());
      ASSERT_EQ(1, barc_tab_close(owner, tab));
    }
    IncognitoModePrefs::SetAvailability(browser()->GetProfile()->GetPrefs(),
        policy::IncognitoModeAvailability::kEnabled);
  }
}

IN_PROC_BROWSER_TEST_F(BarcPrivateCommandBrowserTest,
                       StockPrivateGuestAndPickerCannotBypassAdmission) {
  auto* manager = g_browser_process->profile_manager();
  const size_t windows = GlobalBrowserCollection::GetInstance()->GetSize();
  const size_t profiles =
      manager->GetProfileAttributesStorage().GetNumberOfProfiles();
  chrome::OpenURLOffTheRecord(browser()->GetProfile(), GURL("about:blank"));
  for (const GURL& url : {GURL("about:blank"), GURL("chrome://history")}) {
    NavigateParams params(browser(), url, ui::PAGE_TRANSITION_LINK);
    params.disposition = WindowOpenDisposition::OFF_THE_RECORD;
    EXPECT_FALSE(Navigate(&params));
  }
  EXPECT_FALSE(browser()->GetProfile()->HasPrimaryOTRProfile());
  base::test::TestFuture<BrowserWindowInterface*> guest;
  profiles::SwitchToGuestProfile(guest.GetCallback());
  EXPECT_EQ(nullptr, guest.Get());
  EXPECT_FALSE(ProfilePicker::IsOpen());
  ProfilePicker::Show(ProfilePicker::Params::FromEntryPoint(
      ProfilePicker::EntryPoint::kAppMenuProfileSubMenuManageProfiles));
  EXPECT_FALSE(ProfilePicker::IsOpen());
  base::test::TestFuture<Profile*> picked;
  ProfilePicker::Show(
      ProfilePicker::Params::ForGlicManager(picked.GetCallback()));
  EXPECT_EQ(nullptr, picked.Get());
  base::test::TestFuture<ProfilePicker::FirstRunExitStatus,
                         ProfilePicker::FirstRunFinishReason> first_run;
  ProfilePicker::Show(ProfilePicker::Params::ForFirstRun(
      browser()->GetProfile()->GetPath(), first_run.GetCallback()));
  EXPECT_EQ(ProfilePicker::FirstRunExitStatus::kAbandonedFlow,
            first_run.Get<0>());
  EXPECT_FALSE(ProfilePicker::IsOpen());
  EXPECT_EQ(windows, GlobalBrowserCollection::GetInstance()->GetSize());
  EXPECT_EQ(profiles,
            manager->GetProfileAttributesStorage().GetNumberOfProfiles());
  EXPECT_TRUE(PrivateWindows().empty());
}

namespace {
using DeleteResult = base::test::TestFuture<barc_profile_delete_result>;
void Deleted(barc_profile_delete_result result, void* context) {
  static_cast<DeleteResult*>(context)->SetValue(result);
}
class OnExplicitSurvivorCreating : public ProfileManagerObserver {
 public:
  OnExplicitSurvivorCreating(base::FilePath expected, base::OnceClosure action)
      : expected_(std::move(expected)), action_(std::move(action)) {
    observation_.Observe(g_browser_process->profile_manager());
  }
  void OnProfileCreationStarted(Profile* profile) override {
    if (profile->GetPath() == expected_ && action_) { std::move(action_).Run(); }
  }
 private:
  const base::FilePath expected_;
  base::OnceClosure action_;
  base::ScopedObservation<ProfileManager, ProfileManagerObserver> observation_{this};
};
class OnExplicitProfileMarked : public ProfileManagerObserver {
 public:
  OnExplicitProfileMarked(Profile* expected, base::OnceClosure action)
      : expected_(expected), action_(std::move(action)) {
    observation_.Observe(g_browser_process->profile_manager());
  }
  void OnProfileMarkedForPermanentDeletion(Profile* profile) override {
    if (profile == expected_ && action_) { std::move(action_).Run(); }
  }
 private:
  const raw_ptr<Profile> expected_;
  base::OnceClosure action_;
  base::ScopedObservation<ProfileManager, ProfileManagerObserver> observation_{this};
};
}  // namespace

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       KeptDeletionRefusalPreservesDownloadAndProfile) {
  embedded_test_server()->RegisterRequestHandler(base::BindRepeating(
      &content::SlowDownloadHttpResponse::HandleSlowDownloadRequest));
  ASSERT_TRUE(embedded_test_server()->Start());
  Result work_result, personal_result;
  barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &work_result);
  barc_profile_open_window(kPersonal, BARC_PROFILE_BLANK, Completed, &personal_result);
  ASSERT_EQ(BARC_PROFILE_OK, work_result.Get<0>());
  ASSERT_EQ(BARC_PROFILE_OK, personal_result.Get<0>());
  auto* work = Window(work_result.Get<1>());
  ASSERT_TRUE(work);
  auto* profile = work->GetProfile();
  const auto path = profile->GetPath();
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::NavigateToURL(contents, embedded_test_server()->GetURL("/beforeunload.html")));
  content::PrepContentsForBeforeUnloadTest(contents);
  profile->GetPrefs()->SetBoolean(prefs::kPromptForDownload, false);
  auto* downloads = profile->GetDownloadManager();
  content::DownloadTestObserverInProgress observer(downloads, 1);
  ui_test_utils::NavigateToURLWithDisposition(
      work, embedded_test_server()->GetURL(content::SlowDownloadHttpResponse::kKnownSizeUrl),
      WindowOpenDisposition::NEW_BACKGROUND_TAB, ui_test_utils::BROWSER_TEST_NO_WAIT);
  observer.WaitForFinished();
  download::SimpleDownloadManager::DownloadVector items;
  downloads->GetAllDownloads(&items);
  ASSERT_EQ(1u, items.size());
  ASSERT_EQ(download::DownloadItem::IN_PROGRESS, items[0]->GetState());
  const auto guid = items[0]->GetGuid();
  DeleteResult recovery;
  barc_profile_delete_kept(kWork, kPersonal, 1, Deleted, &recovery);
  EXPECT_EQ(BARC_PROFILE_DELETE_PENDING, recovery.Get());
  EXPECT_TRUE(IsProfileDirectoryPendingDeletion(path));
  EXPECT_TRUE(Window(work_result.Get<1>()));
  EXPECT_EQ(download::DownloadItem::IN_PROGRESS, items[0]->GetState());
  // Failed retry preflight must not consume this operation's reservation.
  auto* manager = g_browser_process->profile_manager();
  const auto survivor_path = Window(personal_result.Get<1>())->GetProfile()->GetPath();
  ASSERT_TRUE(ScheduleProfileDirectoryForDeletion(survivor_path));
  base::test::TestFuture<DeleteProfileHelper::ExplicitDeletionResult> unavailable;
  manager->GetDeleteProfileHelper().DeleteProfileWithExplicitSurvivor(
      path, survivor_path, false, unavailable.GetCallback());
  EXPECT_EQ(DeleteProfileHelper::ExplicitDeletionResult::kPending, unavailable.Get());
  CancelProfileDeletion(survivor_path);
  DeleteResult result;
  barc_profile_delete_kept(kWork, kPersonal, 0, Deleted, &result);
  auto* dialog = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(dialog && dialog->view());
  dialog->view()->CancelAppModalDialog();
  EXPECT_EQ(BARC_PROFILE_DELETE_CANCELLED, result.Get());
  EXPECT_TRUE(IsProfileDirectoryPendingDeletion(path));
  Result blocked;
  barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &blocked);
  EXPECT_EQ(BARC_PROFILE_UNAVAILABLE, blocked.Get<0>());
  EXPECT_EQ(0, barc_profile_delete_cancel_ack(kWork, kWork));
  EXPECT_EQ(1, barc_profile_delete_cancel_ack(kWork, kPersonal));
  EXPECT_FALSE(IsProfileDirectoryPendingDeletion(path));
  EXPECT_EQ(profile, g_browser_process->profile_manager()->GetProfileByPath(path));
  EXPECT_TRUE(Window(work_result.Get<1>()));
  ASSERT_TRUE(downloads->GetDownloadByGuid(guid));
  EXPECT_EQ(download::DownloadItem::IN_PROGRESS,
            downloads->GetDownloadByGuid(guid)->GetState());
  ASSERT_TRUE(content::ExecJs(contents, "window.onbeforeunload=null"));
  downloads->GetDownloadByGuid(guid)->Cancel(true);
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       KeptDeletionWipesAndRejectsReentrantFactoryWithoutReplacement) {
  Result work_result, personal_result, private_result;
  barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &work_result);
  barc_profile_open_window(kPersonal, BARC_PROFILE_BLANK, Completed, &personal_result);
  barc_private_session_open_window(Completed, &private_result);
  ASSERT_EQ(BARC_PROFILE_OK, work_result.Get<0>());
  ASSERT_EQ(BARC_PROFILE_OK, personal_result.Get<0>());
  ASSERT_EQ(BARC_PROFILE_OK, private_result.Get<0>());
  auto* manager = g_browser_process->profile_manager();
  auto* work = Window(work_result.Get<1>());
  auto* personal = Window(personal_result.Get<1>());
  auto* private_window = Window(private_result.Get<1>());
  ASSERT_TRUE(work && personal && private_window);
  auto* profile = work->GetProfile();
  const auto path = profile->GetPath();
  auto keep_alive = ScopedProfileKeepAlive::TryAcquire(
      profile, ProfileKeepAliveOrigin::kProfileCreationFlow);
  ASSERT_TRUE(keep_alive);
  const auto count = manager->GetProfileAttributesStorage().GetNumberOfProfiles();
  const GURL cookie_url("http://deletion.test/");
  ASSERT_TRUE(content::SetCookie(profile, cookie_url, "owner=work"));
  ASSERT_TRUE(content::SetCookie(personal->GetProfile(), cookie_url, "owner=personal"));
  personal->GetProfile()->GetPrefs()->SetBoolean(prefs::kShowHomeButton, true);
  auto* private_profile = private_window->GetProfile();
  private_profile->GetPrefs()->SetBoolean(prefs::kShowHomeButton, true);
  ASSERT_TRUE(content::SetCookie(private_profile, cookie_url, "owner=private"));
  extensions::ScopedTestNativeMessagingHost native_host;
  ASSERT_NO_FATAL_FAILURE(native_host.RegisterTestHost(false));
  auto* messaging = extensions::MessageService::Get(profile);
  const auto channels_before = messaging->GetChannelCountForTest();
  extensions::TestExtensionDir extension_dir;
  // Pinned public test key from api_test/native_messaging; permits only the
  // scoped upstream synthetic echo host, never a real registered native host.
  extension_dir.WriteManifest(R"({"manifest_version":3,"name":"Deletion worker",
      "key":"MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDcBHwzDvyBQ6bDppkIs9MP4ksKqCMyXQ/A52JivHZKh4YO/9vJsT3oaYhSpDCE9RPocOEQvwsHsFReW2nUEc6OLLyoCFFxIb7KkLGsmfakkut/fFdNJYh0xOTbSN8YvLWcqph09XAY2Y/f0AL7vfO1cuCqtkMt8hFrBGWxDdf9CQIDAQAB",
      "permissions":["nativeMessaging"],
      "version":"1.0","background":{"service_worker":"worker.js"}})");
  extension_dir.WriteFile(FILE_PATH_LITERAL("worker.js"), R"(
      globalThis.port = chrome.runtime.connectNative('com.google.chrome.test.echo');
      port.onMessage.addListener(message => {
        if (message.echo === 'deletion-probe') chrome.test.sendMessage('deletion-worker-ready');
      });
      port.postMessage('deletion-probe');
  )");
  ExtensionTestMessageListener ready("deletion-worker-ready");
  ready.set_browser_context(profile);
  extensions::ChromeTestExtensionLoader loader(profile);
  auto extension = loader.LoadExtension(extension_dir.UnpackedPath());
  ASSERT_TRUE(extension);
  ASSERT_TRUE(ready.WaitUntilSatisfied());
  EXPECT_EQ(channels_before + 1, messaging->GetChannelCountForTest());
  const auto extension_id = extension->id();
  ASSERT_TRUE(extensions::ExtensionRegistry::Get(profile)->enabled_extensions().Contains(extension_id));
  Result reentrant;
  OnExplicitProfileMarked marked(profile, base::BindLambdaForTesting([&] {
    barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &reentrant);
  }));
  DeleteResult result;
  barc_profile_delete_kept(kWork, kPersonal, 0, Deleted, &result);
  EXPECT_EQ(BARC_PROFILE_DELETED, result.Get());
  EXPECT_EQ(BARC_PROFILE_UNAVAILABLE, reentrant.Get<0>());
  EXPECT_TRUE(IsProfileDirectoryMarkedForDeletion(path));
  EXPECT_FALSE(manager->GetProfileAttributesStorage().GetProfileAttributesWithPath(path));
  EXPECT_EQ(count - 1, manager->GetProfileAttributesStorage().GetNumberOfProfiles());
  EXPECT_FALSE(extensions::ExtensionRegistry::Get(profile)->enabled_extensions().Contains(extension_id));
  EXPECT_TRUE(extensions::ProcessManager::Get(profile)->GetServiceWorkersForExtension(extension_id).empty());
  EXPECT_EQ(channels_before, messaging->GetChannelCountForTest());
  EXPECT_EQ("", content::GetCookies(profile, cookie_url));
  EXPECT_EQ("owner=personal", content::GetCookies(personal->GetProfile(), cookie_url));
  EXPECT_EQ("owner=private", content::GetCookies(private_profile, cookie_url));
  EXPECT_TRUE(Window(personal_result.Get<1>()));
  EXPECT_EQ(private_profile, Window(private_result.Get<1>())->GetProfile());
  EXPECT_TRUE(personal->GetProfile()->GetPrefs()->GetBoolean(prefs::kShowHomeButton));
  EXPECT_TRUE(private_profile->GetPrefs()->GetBoolean(prefs::kShowHomeButton));
  // No stock replacement is created; the explicit survivor remains the same.
  EXPECT_EQ(manager->user_data_dir().AppendASCII(std::string("Barc-") + kPersonal),
            personal->GetProfile()->GetPath());
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       KeptDeletionReconcilesAbsentUnloadedTargetWithoutCreation) {
  constexpr char kAbsent[] = "da624c1d-3aa0-41af-99dc-b36ceacb4e7a";
  Result survivor;
  barc_profile_open_window(kPersonal, BARC_PROFILE_BLANK, Completed, &survivor);
  ASSERT_EQ(BARC_PROFILE_OK, survivor.Get<0>());
  auto* manager = g_browser_process->profile_manager();
  const auto path = manager->user_data_dir().AppendASCII(std::string("Barc-") + kAbsent);
  ASSERT_FALSE(manager->GetProfileByPath(path));
  ASSERT_FALSE(manager->GetProfileAttributesStorage().GetProfileAttributesWithPath(path));
  const auto count = manager->GetProfileAttributesStorage().GetNumberOfProfiles();
  DeleteResult result;
  barc_profile_delete_kept(kAbsent, kPersonal, 1, Deleted, &result);
  EXPECT_EQ(BARC_PROFILE_DELETED, result.Get());
  EXPECT_FALSE(manager->GetProfileByPath(path));
  EXPECT_FALSE(manager->GetProfileAttributesStorage().GetProfileAttributesWithPath(path));
  EXPECT_EQ(count, manager->GetProfileAttributesStorage().GetNumberOfProfiles());
  EXPECT_TRUE(Window(survivor.Get<1>()));
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       KeptDeletionReservesTargetBeforeSurvivorInitialization) {
  constexpr char kNewSurvivor[] = "66c2c18f-201e-41e8-b465-5eb193a85db4";
  Result work;
  barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &work);
  ASSERT_EQ(BARC_PROFILE_OK, work.Get<0>());
  auto* manager = g_browser_process->profile_manager();
  auto* target = Window(work.Get<1>())->GetProfile();
  const auto path = target->GetPath();
  const auto survivor_path = manager->user_data_dir().AppendASCII(
      std::string("Barc-") + kNewSurvivor);
  ASSERT_FALSE(manager->IsProfileLoadedOrLoading(survivor_path));
  bool saw_preparation = false;
  DeleteResult recovery;
  Result blocked;
  OnExplicitSurvivorCreating preparing(survivor_path, base::BindLambdaForTesting([&] {
    // Real Profile construction is paused here before it is initialized. Do
    // not pump a nested profile-init loop; exercise the synchronous upstream
    // window factory and queue the regular bridge factory against that gap.
    saw_preparation = true;
    EXPECT_FALSE(recovery.IsReady());
    EXPECT_TRUE(IsProfileDirectoryPendingDeletion(path));
    EXPECT_EQ(nullptr, chrome::OpenEmptyWindow(target, false));
    barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &blocked);
  }));
  barc_profile_delete_kept(kWork, kNewSurvivor, 1, Deleted, &recovery);
  EXPECT_TRUE(saw_preparation);
  EXPECT_EQ(BARC_PROFILE_DELETE_PENDING, recovery.Get());
  EXPECT_EQ(BARC_PROFILE_UNAVAILABLE, blocked.Get<0>());
  EXPECT_TRUE(Window(work.Get<1>()));
  // Explicit retry owns the same reservation; no accidental stock/default
  // survivor is chosen after the newly loaded exact model identity.
  DeleteResult deleted;
  barc_profile_delete_kept(kWork, kNewSurvivor, 0, Deleted, &deleted);
  EXPECT_EQ(BARC_PROFILE_DELETED, deleted.Get());
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       ActiveDeletionWaitsForAssignmentBeforeMarkAndWipe) {
  Result work_result, personal_result;
  barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &work_result);
  barc_profile_open_window(kPersonal, BARC_PROFILE_BLANK, Completed, &personal_result);
  ASSERT_EQ(BARC_PROFILE_OK, work_result.Get<0>());
  ASSERT_EQ(BARC_PROFILE_OK, personal_result.Get<0>());
  auto* manager = g_browser_process->profile_manager();
  auto* profile = Window(work_result.Get<1>())->GetProfile();
  const auto path = profile->GetPath();
  auto keep_alive = ScopedProfileKeepAlive::TryAcquire(
      profile, ProfileKeepAliveOrigin::kProfileCreationFlow);
  ASSERT_TRUE(keep_alive);
  const GURL url("http://assignment.test/");
  ASSERT_TRUE(content::SetCookie(profile, url, "owner=work"));
  const GURL session_only_url("http://session-only.assignment.test/");
  HostContentSettingsMapFactory::GetForProfile(profile)->SetContentSettingDefaultScope(
      session_only_url, session_only_url, ContentSettingsType::COOKIES,
      CONTENT_SETTING_SESSION_ONLY);
  ASSERT_TRUE(content::SetCookie(profile, session_only_url, "session=work; Max-Age=3600"));
  ASSERT_EQ("session=work", content::GetCookies(profile, session_only_url));
  extensions::TestExtensionDir extension_dir;
  extension_dir.WriteManifest(R"({"manifest_version":3,"name":"Assignment probe",
                                  "version":"1.0"})");
  extensions::ChromeTestExtensionLoader loader(profile);
  auto extension = loader.LoadExtension(extension_dir.UnpackedPath());
  ASSERT_TRUE(extension);
  DeleteResult admitted;
  barc_profile_prepare_reassignment(kWork, kPersonal, 0, Deleted, &admitted);
  ASSERT_EQ(BARC_PROFILE_CLOSE_ADMITTED, admitted.Get());
  EXPECT_FALSE(Window(work_result.Get<1>()));
  EXPECT_TRUE(Window(personal_result.Get<1>()));
  EXPECT_TRUE(IsProfileDirectoryPendingDeletion(path));
  EXPECT_FALSE(IsProfileDirectoryMarkedForDeletion(path));
  EXPECT_EQ("owner=work", content::GetCookies(profile, url));
  EXPECT_EQ("session=work", content::GetCookies(profile, session_only_url));
  EXPECT_TRUE(extensions::ExtensionRegistry::Get(profile)->enabled_extensions().Contains(extension->id()));
  Result refused;
  barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &refused);
  EXPECT_EQ(BARC_PROFILE_UNAVAILABLE, refused.Get<0>());
  DeleteResult wrong_survivor;
  barc_profile_continue_deletion(kWork, kWork, Deleted, &wrong_survivor);
  EXPECT_EQ(BARC_PROFILE_DELETE_PENDING, wrong_survivor.Get());
  EXPECT_FALSE(IsProfileDirectoryMarkedForDeletion(path));
  // Models persist the exact destination assignment before making this call.
  DeleteResult completed;
  barc_profile_continue_deletion(kWork, kPersonal, Deleted, &completed);
  EXPECT_EQ(BARC_PROFILE_DELETED, completed.Get());
  EXPECT_TRUE(IsProfileDirectoryMarkedForDeletion(path));
  EXPECT_EQ("", content::GetCookies(profile, url));
  EXPECT_EQ("", content::GetCookies(profile, session_only_url));
  EXPECT_FALSE(extensions::ExtensionRegistry::Get(profile)->enabled_extensions().Contains(extension->id()));
  EXPECT_TRUE(Window(personal_result.Get<1>()));
  EXPECT_FALSE(manager->GetProfileAttributesStorage().GetProfileAttributesWithPath(path));
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       UncommittedActiveRecoveryNeverClosesOrMarksProfile) {
  Result work_result, personal_result;
  barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &work_result);
  barc_profile_open_window(kPersonal, BARC_PROFILE_BLANK, Completed, &personal_result);
  ASSERT_EQ(BARC_PROFILE_OK, work_result.Get<0>());
  ASSERT_EQ(BARC_PROFILE_OK, personal_result.Get<0>());
  auto* profile = Window(work_result.Get<1>())->GetProfile();
  const auto path = profile->GetPath();
  DeleteResult recovery;
  barc_profile_prepare_reassignment(kWork, kPersonal, 1, Deleted, &recovery);
  EXPECT_EQ(BARC_PROFILE_DELETE_CANCELLED, recovery.Get());
  EXPECT_TRUE(Window(work_result.Get<1>()));
  EXPECT_FALSE(IsProfileDirectoryMarkedForDeletion(path));
  Result blocked;
  barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &blocked);
  EXPECT_EQ(BARC_PROFILE_UNAVAILABLE, blocked.Get<0>());
  EXPECT_EQ(1, barc_profile_delete_cancel_ack(kWork, kPersonal));
  EXPECT_FALSE(IsProfileDirectoryPendingDeletion(path));
  EXPECT_EQ(profile, Window(work_result.Get<1>())->GetProfile());
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       ActiveDeletionVetoNeverAdmitsAssignmentOrWipes) {
  ASSERT_TRUE(embedded_test_server()->Start());
  Result work_result, personal_result;
  barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &work_result);
  barc_profile_open_window(kPersonal, BARC_PROFILE_BLANK, Completed, &personal_result);
  ASSERT_EQ(BARC_PROFILE_OK, work_result.Get<0>());
  ASSERT_EQ(BARC_PROFILE_OK, personal_result.Get<0>());
  auto* profile = Window(work_result.Get<1>())->GetProfile();
  const auto path = profile->GetPath();
  auto* contents = Window(work_result.Get<1>())->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::NavigateToURL(contents, embedded_test_server()->GetURL("/beforeunload.html")));
  content::PrepContentsForBeforeUnloadTest(contents);
  const GURL cookie_url("http://assignment.test/");
  ASSERT_TRUE(content::SetCookie(profile, cookie_url, "owner=work"));
  const GURL session_only_url("http://session-only.assignment.test/");
  HostContentSettingsMapFactory::GetForProfile(profile)->SetContentSettingDefaultScope(
      session_only_url, session_only_url, ContentSettingsType::COOKIES,
      CONTENT_SETTING_SESSION_ONLY);
  ASSERT_TRUE(content::SetCookie(profile, session_only_url, "session=work; Max-Age=3600"));
  ASSERT_EQ("session=work", content::GetCookies(profile, session_only_url));
  ASSERT_EQ("owner=work", content::GetCookies(profile, cookie_url));
  DeleteResult result;
  barc_profile_prepare_reassignment(kWork, kPersonal, 0, Deleted, &result);
  auto* dialog = ui_test_utils::WaitForAppModalDialog();
  ASSERT_TRUE(dialog && dialog->view());
  dialog->view()->CancelAppModalDialog();
  EXPECT_EQ(BARC_PROFILE_DELETE_CANCELLED, result.Get());
  EXPECT_FALSE(IsProfileDirectoryMarkedForDeletion(path));
  EXPECT_TRUE(Window(work_result.Get<1>()));
  EXPECT_EQ("owner=work", content::GetCookies(profile, cookie_url));
  EXPECT_EQ("session=work", content::GetCookies(profile, session_only_url));
  DeleteResult forbidden;
  barc_profile_continue_deletion(kWork, kPersonal, Deleted, &forbidden);
  EXPECT_EQ(BARC_PROFILE_DELETE_PENDING, forbidden.Get());
  EXPECT_EQ(1, barc_profile_delete_cancel_ack(kWork, kPersonal));
  ASSERT_TRUE(content::ExecJs(contents, "window.onbeforeunload=null"));
  // Releasing the exact cancelled reservation restores ordinary cleanup.
  SessionDataServiceFactory::GetForProfile(profile)->StartCleanup();
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::GetCookies(profile, cookie_url).empty() &&
           content::GetCookies(profile, session_only_url).empty();
  }));
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest,
                       DeferredDeletionPreservesOrphanedBytesUntilAssignment) {
  constexpr char kOrphan[] = "120991c1-3c30-425a-aa21-d31e5db5043e";
  constexpr char kMarked[] = "4a604b11-12a1-405c-9249-0c08df1639bb";
  Result survivor;
  barc_profile_open_window(kPersonal, BARC_PROFILE_BLANK, Completed, &survivor);
  ASSERT_EQ(BARC_PROFILE_OK, survivor.Get<0>());
  auto* manager = g_browser_process->profile_manager();
  const auto path = manager->user_data_dir().AppendASCII(std::string("Barc-") + kOrphan);
  const auto bytes = path.AppendASCII("unsaved-source-probe");
  {
    base::ScopedAllowBlockingForTesting allow_io;
    ASSERT_TRUE(base::CreateDirectory(path));
    ASSERT_TRUE(base::WriteFile(bytes, "owned synthetic source bytes"));
  }
  ASSERT_FALSE(manager->IsProfileLoadedOrLoading(path));
  ASSERT_FALSE(manager->GetProfileAttributesStorage().GetProfileAttributesWithPath(path));
  DeleteResult preparation;
  barc_profile_prepare_reassignment(kOrphan, kPersonal, 0, Deleted, &preparation);
  EXPECT_EQ(BARC_PROFILE_DELETE_PENDING, preparation.Get());
  {
    base::ScopedAllowBlockingForTesting allow_io;
    EXPECT_TRUE(base::PathExists(bytes));
  }
  EXPECT_FALSE(IsProfileDirectoryMarkedForDeletion(path));
  EXPECT_FALSE(manager->IsProfileLoadedOrLoading(path));
  DeleteResult not_admitted;
  barc_profile_continue_deletion(kOrphan, kPersonal, Deleted, &not_admitted);
  EXPECT_EQ(BARC_PROFILE_DELETE_PENDING, not_admitted.Get());
  {
    base::ScopedAllowBlockingForTesting allow_io;
    EXPECT_TRUE(base::PathExists(bytes));
  }
  // Ordinary kept deletion retains its existing admitted disk cleanup path.
  DeleteResult kept;
  barc_profile_delete_kept(kOrphan, kPersonal, 0, Deleted, &kept);
  EXPECT_EQ(BARC_PROFILE_DELETED, kept.Get());
  {
    base::ScopedAllowBlockingForTesting allow_io;
    EXPECT_FALSE(base::PathExists(path));
  }
  // Previously marked restart cleanup remains destructive, not a new admission.
  const auto marked_path = manager->user_data_dir().AppendASCII(std::string("Barc-") + kMarked);
  {
    base::ScopedAllowBlockingForTesting allow_io;
    ASSERT_TRUE(base::CreateDirectory(marked_path));
    ASSERT_TRUE(base::WriteFile(marked_path.AppendASCII("marked-source-probe"), "marked bytes"));
  }
  ProfileAttributesInitParams marked_attributes;
  marked_attributes.profile_path = marked_path;
  marked_attributes.profile_name = u"Synthetic marked source";
  auto& storage = manager->GetProfileAttributesStorage();
  storage.AddProfile(std::move(marked_attributes));
  ASSERT_TRUE(storage.GetProfileAttributesWithPath(marked_path));
  ASSERT_TRUE(ScheduleProfileDirectoryForDeletion(marked_path));
  MarkProfileDirectoryForDeletion(marked_path);
  // Match Chromium's restart-cleanup case: durable mark, missing attributes.
  storage.RemoveProfile(marked_path);
  ASSERT_FALSE(storage.GetProfileAttributesWithPath(marked_path));
  DeleteResult marked;
  barc_profile_prepare_reassignment(kMarked, kPersonal, 1, Deleted, &marked);
  EXPECT_EQ(BARC_PROFILE_DELETED, marked.Get());
  {
    base::ScopedAllowBlockingForTesting allow_io;
    EXPECT_FALSE(base::PathExists(marked_path));
  }
  EXPECT_TRUE(Window(survivor.Get<1>()));
}

// The real kind-3 resolver, with model/policy admission deliberately held.
// Each captured menu URL remains in its intrinsic blank record, not this fixture.
class BarcPrivateMenuPolicyBrowserTest : public BarcPrivateCommandBrowserTest {
 public:
  void SetUp() override {
    barc_set_runtime_browser_target_callback(
        [](int32_t kind, const char*, int32_t window, int32_t tab,
           BarcApplicationTarget* output, void* context) -> int32_t {
          auto* test = static_cast<BarcPrivateMenuPolicyBrowserTest*>(context);
          if (output) *output = {.size = output->size};
          if (kind != 3) return 0;
          test->front_ = {window, tab, 0};
          auto* browser = Window(window);
          if (!browser || !barc_tab_application_pending(window, tab)) return 0;
          auto* policy = NativeContentBlocker::Get(browser->GetProfile(), true);
          if (test->allowed_tab_ != tab || !policy->state().ready) return -1;
          output->window = window;
          return 1;
        }, this);
    BarcPrivateCommandBrowserTest::SetUp();
  }
  void SetUpInProcessBrowserTestFixture() override {
    BarcPrivateCommandBrowserTest::SetUpInProcessBrowserTestFixture();
    CHECK(NativeContentBlocker::SetPolicy(NativeContentBlocker::kUnresolved, 0, {}));
  }
  void SetUpOnMainThread() override {
    BarcPrivateCommandBrowserTest::SetUpOnMainThread();
    CHECK(barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  }
 protected:
  void Request(content::WebContents* source, const GURL& target) {
    content::ContextMenuParams params;
    params.page_url = source->GetLastCommittedURL();
    params.frame_url = params.page_url;
    params.frame_origin = url::Origin::Create(params.page_url);
    params.link_url = target;
    params.unfiltered_link_url = target;
    auto menu = std::make_unique<TestRenderViewContextMenu>(
        *source->GetPrimaryMainFrame(), params);
    menu->Init();
    ASSERT_TRUE(menu->IsCommandIdEnabled(IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD));
    menu->ExecuteCommand(IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD, 0);
  }
  void Wake(int32_t window, int32_t tab) {
    // Successful publication is the production coalesced readiness wake,
    // including unchanged/cached/disabled policy.
    ASSERT_EQ(1, barc_blocker_set_tab_policy(window, tab, 0, nullptr, 0));
  }
  barc::ApplicationPage front_;
  int32_t allowed_tab_ = 0;
};

IN_PROC_BROWSER_TEST_F(BarcPrivateMenuPolicyBrowserTest,
                       PrivateMenuWaitsForExactPolicyAndDrainsPeers) {
  auto requests = std::make_shared<std::atomic<int>>(0);
  embedded_test_server()->RegisterRequestMonitor(base::BindRepeating(
      [](std::shared_ptr<std::atomic<int>> requests,
         const net::test_server::HttpRequest& request) {
        if (request.relative_url == "/echoheader?Referer") ++*requests;
      }, requests));
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL source_url = embedded_test_server()->GetURL("/title1.html");
  const GURL target = embedded_test_server()->GetURL("/echoheader?Referer");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), source_url));
  auto* source = browser()->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(source, "document.body.innerHTML='<input id=draft value=retained>';window.savedNode=draft"));
  // Announce a not-yet-produced source before either private context exists.
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_ENABLED, 1, nullptr, 0));
  Request(source, target);
  ASSERT_TRUE(base::test::RunUntil([&] { return front_.tab != 0; }));
  const auto first = front_;
  Request(source, target);
  ASSERT_TRUE(base::test::RunUntil([&] { return PrivateWindows().size() == 2; }));
  auto* blank = Window(first.window)->GetTabStripModel()->GetActiveWebContents();
  auto blank_alive = blank->GetWeakPtr();
  ASSERT_TRUE(content::WaitForLoadStop(blank));
  EXPECT_EQ(GURL(url::kAboutBlankURL), blank->GetLastCommittedURL());
  EXPECT_FALSE(blank->GetController().GetPendingEntry());
  EXPECT_EQ(0, barc_tab_navigate(first.window, first.tab, target.spec().c_str()));
  EXPECT_EQ(0, barc_tab_reload(first.window, first.tab));
  EXPECT_EQ(0, barc_tab_go_back(first.window, first.tab));
  EXPECT_EQ(0, barc_tab_go_forward(first.window, first.tab));
  EXPECT_EQ(0, requests->load());
  allowed_tab_ = first.tab;
  Wake(first.window, first.tab);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(1, barc_tab_application_pending(first.window, first.tab));
  // Disable releases readiness without waiting for the nonexistent producer.
  ASSERT_EQ(1, barc_blocker_set_policy(BARC_BLOCKER_DISABLED, 0, nullptr, 0));
  Wake(first.window, first.tab);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !blank_alive || (blank_alive->GetLastCommittedURL() == target &&
                            front_.tab != first.tab);
  }));
  ASSERT_TRUE(blank_alive);
  EXPECT_EQ(1, requests->load());
  const auto second = front_;
  EXPECT_EQ(0, barc_tab_application_pending(first.window, first.tab));
  EXPECT_EQ(1, barc_tab_application_pending(second.window, second.tab));
  auto* other = Window(second.window)->GetTabStripModel()->GetActiveWebContents();
  auto other_alive = other->GetWeakPtr();
  ASSERT_TRUE(content::WaitForLoadStop(other));
  EXPECT_EQ(GURL(url::kAboutBlankURL), other->GetLastCommittedURL());
  EXPECT_NE(blank->GetBrowserContext(), other->GetBrowserContext());
  allowed_tab_ = second.tab;
  Wake(second.window, second.tab);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return !other_alive || other_alive->GetLastCommittedURL() == target;
  }));
  ASSERT_TRUE(other_alive);
  for (auto* page : {blank, other}) {
    ASSERT_TRUE(content::WaitForLoadStop(page));
    EXPECT_EQ("None", content::EvalJs(page, "document.body.textContent"));
    EXPECT_EQ("", content::EvalJs(page, "document.referrer"));
    EXPECT_FALSE(page->HasOpener());
  }
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(2, requests->load());
  EXPECT_EQ(source_url, source->GetLastCommittedURL());
  EXPECT_EQ(true, content::EvalJs(source, "savedNode===draft && draft.value==='retained'"));
}

IN_PROC_BROWSER_TEST_F(BarcPrivateMenuPolicyBrowserTest,
                       PrivateMenuHeadCancellationPreservesNextIntent) {
  auto requests = std::make_shared<std::atomic<int>>(0);
  embedded_test_server()->RegisterRequestMonitor(base::BindRepeating(
      [](std::shared_ptr<std::atomic<int>> requests,
         const net::test_server::HttpRequest& request) {
        if (request.relative_url == "/echoheader?Referer") ++*requests;
      }, requests));
  ASSERT_TRUE(embedded_test_server()->Start());
  const GURL target = embedded_test_server()->GetURL("/echoheader?Referer");
  for (int reason = 0; reason < 3; ++reason) {
    SCOPED_TRACE(reason);
    front_ = {};
    allowed_tab_ = 0;
    const int32_t owner = browser()->GetSessionID().id();
    const int32_t source_tab = barc_tab_create(owner, "about:blank", 1);
    auto* source = tabs::TabHandle(source_tab).Get()->GetContents();
    ASSERT_TRUE(content::NavigateToURL(source, embedded_test_server()->GetURL("/title1.html")));
    Request(source, target);
    ASSERT_TRUE(base::test::RunUntil([&] { return front_.tab != 0; }));
    const auto first = front_;
    // A different exact source owns the peer; cancelling the head cannot
    // borrow its source identity or leave the deterministic drain stranded.
    auto* peer_source = browser()->GetTabStripModel()->GetWebContentsAt(0);
    ASSERT_NE(peer_source, source);
    Request(peer_source, target);
    ASSERT_TRUE(base::test::RunUntil([&] { return PrivateWindows().size() == 2; }));
    auto* first_contents = tabs::TabHandle(first.tab).Get()->GetContents();
    auto first_alive = first_contents->GetWeakPtr();
    if (reason == 0) {
      ASSERT_TRUE(content::NavigateToURL(source, embedded_test_server()->GetURL("/title2.html")));
    } else if (reason == 1) {
      ASSERT_EQ(1, barc_tab_close(owner, source_tab));
    } else {
      ASSERT_EQ(1, barc_tab_close(first.window, first.tab));
    }
    ASSERT_TRUE(base::test::RunUntil([&] {
      return !first_alive && front_.tab != first.tab && PrivateWindows().size() == 1;
    }));
    EXPECT_EQ(reason, requests->load());
    const auto second = front_;
    allowed_tab_ = second.tab;
    Wake(second.window, second.tab);
    auto* page = tabs::TabHandle(second.tab).Get()->GetContents();
    auto page_alive = page->GetWeakPtr();
    ASSERT_TRUE(base::test::RunUntil([&] {
      return !page_alive || page_alive->GetLastCommittedURL() == target;
    }));
    ASSERT_TRUE(page_alive);
    ASSERT_TRUE(content::WaitForLoadStop(page));
    EXPECT_EQ(reason + 1, requests->load());
    ASSERT_EQ(1, barc_window_close(second.window));
    ASSERT_TRUE(base::test::RunUntil([&] { return PrivateWindows().empty(); }));
    base::RunLoop().RunUntilIdle();
    EXPECT_EQ(reason + 1, requests->load());
    if (tabs::TabHandle(source_tab).Get()) ASSERT_EQ(1, barc_tab_close(owner, source_tab));
  }
}

IN_PROC_BROWSER_TEST_F(BarcPrivateMenuPolicyBrowserTest,
                       PrivateMenuNewBlankNavigationCannotReviveCapturedIntent) {
  auto requests = std::make_shared<std::atomic<int>>(0);
  embedded_test_server()->RegisterRequestMonitor(base::BindRepeating(
      [](std::shared_ptr<std::atomic<int>> requests,
         const net::test_server::HttpRequest& request) {
        if (request.relative_url == "/echoheader?Referer") ++*requests;
      }, requests));
  ASSERT_TRUE(embedded_test_server()->Start());
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(),
      embedded_test_server()->GetURL("/title1.html")));
  auto* source = browser()->GetTabStripModel()->GetActiveWebContents();
  for (bool reload : {true, false}) {
    SCOPED_TRACE(reload);
    front_ = {};
    allowed_tab_ = 0;
    Request(source, embedded_test_server()->GetURL("/echoheader?Referer"));
    ASSERT_TRUE(base::test::RunUntil([&] { return front_.tab != 0; }));
    const auto page = front_;
    auto* contents = tabs::TabHandle(page.tab).Get()->GetContents();
    auto alive = contents->GetWeakPtr();
    ASSERT_TRUE(content::WaitForLoadStop(contents));
    const int original_entry = contents->GetController().GetActiveEntry()->GetUniqueID();
    const int64_t original_document = contents->GetController().GetActiveEntry()
        ->GetMainFrameDocumentSequenceNumber();
    if (reload) {
      contents->GetController().Reload(content::ReloadType::NORMAL, false);
    } else {
      content::NavigationController::LoadURLParams replacement{GURL(url::kAboutBlankURL)};
      replacement.should_replace_current_entry = true;
      contents->GetController().LoadURLWithParams(replacement);
    }
    ASSERT_TRUE(content::WaitForLoadStop(contents));
    ASSERT_TRUE(alive);
    auto* entry = contents->GetController().GetActiveEntry();
    if (reload) {
      EXPECT_EQ(original_entry, entry->GetUniqueID());
      EXPECT_TRUE(ui::PageTransitionCoreTypeIs(entry->GetTransitionType(),
                                               ui::PAGE_TRANSITION_RELOAD));
      EXPECT_NE(original_document, entry->GetMainFrameDocumentSequenceNumber());
      ASSERT_TRUE(content::ExecJs(contents,
          "history.replaceState({afterReload:true},'',location.href);true;"));
      entry = contents->GetController().GetActiveEntry();
      EXPECT_EQ(original_entry, entry->GetUniqueID());
      EXPECT_EQ(1, contents->GetController().GetEntryCount());
      EXPECT_TRUE(ui::PageTransitionCoreTypeIs(entry->GetTransitionType(),
                                               ui::PAGE_TRANSITION_RELOAD));
    } else {
      EXPECT_NE(original_entry, entry->GetUniqueID());
    }
    allowed_tab_ = page.tab;
    Wake(page.window, page.tab);
    ASSERT_TRUE(base::test::RunUntil([&] {
      return !barc_tab_application_pending(page.window, page.tab);
    }));
    ASSERT_TRUE(alive); // Cancellation abandons the role, not the newer page.
    EXPECT_EQ(GURL(url::kAboutBlankURL), alive->GetLastCommittedURL());
    EXPECT_EQ(GURL(url::kAboutBlankURL), alive->GetVisibleURL());
    EXPECT_FALSE(alive->GetController().GetPendingEntry());
    EXPECT_EQ(0, requests->load());
    Wake(page.window, page.tab); // A later wake cannot resurrect the old URL.
    base::RunLoop().RunUntilIdle();
    EXPECT_EQ(0, requests->load());
    ASSERT_TRUE(alive);
    EXPECT_EQ(GURL(url::kAboutBlankURL), alive->GetVisibleURL());
    EXPECT_FALSE(alive->GetController().GetPendingEntry());
    ASSERT_EQ(1, barc_window_close(page.window));
    ASSERT_TRUE(base::test::RunUntil([&] { return PrivateWindows().empty(); }));
  }
}

namespace {
struct LiveReply {
  uint64_t token = 0;
  int calls = 0;
  barc_live_result result = BARC_LIVE_FAILED;
  int status = 0;
  std::string body;
  ~LiveReply() { barc_profile_live_cancel(token); }
  static void Receive(void* context, uint64_t token, barc_live_result result,
                      int32_t status, const uint8_t* body, size_t length) {
    auto* reply = static_cast<LiveReply*>(context);
    ++reply->calls; reply->token = token; reply->result = result; reply->status = status;
    reply->body.assign(reinterpret_cast<const char*>(body), length);
  }
  void Start(const char* uuid, int source = BARC_LIVE_GITHUB_ISSUES, const char* argument = "") {
    token = barc_profile_live_get(uuid, source, argument, Receive, this);
  }
  bool Wait() { return base::test::RunUntil([&] { return calls == 1; }); }
};
}

class BarcLiveFetchBrowserTest : public BarcProfilesBrowserTest {
 public:
  BarcLiveFetchBrowserTest() {
    net::EmbeddedTestServer::ServerCertificateConfig certificate;
    certificate.dns_names = {"github.com", "mail.google.com", "app.asana.com"};
    https_.SetSSLConfig(certificate);
    https_.RegisterRequestHandler(base::BindRepeating(
        &BarcLiveFetchBrowserTest::Handle, base::Unretained(this)));
    CHECK(https_.Start());
  }
  void SetUpCommandLine(base::CommandLine* command_line) override {
    BarcProfilesBrowserTest::SetUpCommandLine(command_line);
    const auto endpoint = https_.host_port_pair().ToString();
    command_line->AppendSwitchASCII(network::switches::kHostResolverRules,
        "MAP github.com " + endpoint + ", MAP mail.google.com " + endpoint +
        ", MAP app.asana.com " + endpoint);
  }
  void TearDownOnMainThread() override {
    work_keep_.reset(); personal_keep_.reset();
    BarcProfilesBrowserTest::TearDownOnMainThread();
  }
 protected:
  Profile* Load(const char* uuid, std::unique_ptr<ScopedProfileKeepAlive>& keep) {
    base::test::TestFuture<Profile*> ready;
    barc::WithRegularProfileForApplication(uuid, base::BindLambdaForTesting([&](Profile* profile) {
      if (profile) keep = ScopedProfileKeepAlive::TryAcquire(profile, ProfileKeepAliveOrigin::kProfileCreationFlow);
      ready.SetValue(profile);
    }));
    return ready.Get();
  }
  int WindowCount(Profile* profile) {
    int count = 0;
    GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface* browser) {
      if (browser->GetProfile() == profile) ++count;
      return true;
    });
    return count;
  }
  std::vector<std::string> Cookies() {
    base::AutoLock lock(lock_); return cookies_;
  }
  std::atomic<int> mode_{0};
  std::atomic<int> requests_{0};
  std::unique_ptr<ScopedProfileKeepAlive> work_keep_, personal_keep_;
 private:
  std::unique_ptr<net::test_server::HttpResponse> Handle(const net::test_server::HttpRequest& request) {
    ++requests_;
    // Wake RunUntil on UI even for a deliberately header-less hung response.
    content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::DoNothing());
    {
      base::AutoLock lock(lock_);
      auto found = request.headers.find("Cookie");
      cookies_.push_back(found == request.headers.end() ? "" : found->second);
    }
    if (mode_ == 3) return std::make_unique<net::test_server::HungResponse>();
    if (mode_ == 4) {
      // Declares more than the limit and ends early, as a connection that
      // closes mid-body does.
      return std::make_unique<net::test_server::RawHttpResponse>(
          "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
          "Content-Length: 4194305\r\n",
          "partial");
    }
    auto response = std::make_unique<net::test_server::BasicHttpResponse>();
    response->set_code(mode_ == 1 ? net::HTTP_FOUND : net::HTTP_OK);
    response->set_content_type("application/octet-stream");
    response->AddCustomHeader("Set-Cookie", "must-not-save=1; Secure; SameSite=Strict");
    if (mode_ == 1) response->AddCustomHeader("Location", "https://mail.google.com/redirected");
    response->set_content(mode_ == 2 ? std::string(4 * 1024 * 1024 + 1, 'x') : std::string("A\0B", 3));
    return response;
  }
  net::EmbeddedTestServer https_{net::EmbeddedTestServer::TYPE_HTTPS};
  base::Lock lock_;
  std::vector<std::string> cookies_;
};

IN_PROC_BROWSER_TEST_F(BarcLiveFetchBrowserTest, ExactProfileCookiesWithoutTabsAndNoCookieSaving) {
  auto* work = Load(kWork, work_keep_);
  auto* personal = Load(kPersonal, personal_keep_);
  ASSERT_TRUE(work && personal && work_keep_ && personal_keep_);
  ASSERT_EQ(0, WindowCount(work)); ASSERT_EQ(0, WindowCount(personal));
  const GURL origin("https://github.com/");
  ASSERT_TRUE(content::SetCookie(work, origin, "owner=work; Secure; SameSite=Strict"));
  ASSERT_TRUE(content::SetCookie(personal, origin, "owner=personal; Secure; SameSite=Strict"));
  LiveReply a, b;
  a.Start(kWork); ASSERT_NE(0u, a.token); ASSERT_TRUE(a.Wait());
  b.Start(kPersonal); ASSERT_NE(0u, b.token); ASSERT_TRUE(b.Wait());
  EXPECT_EQ(BARC_LIVE_OK, a.result); EXPECT_EQ(200, a.status);
  EXPECT_EQ(std::string("A\0B", 3), a.body);
  auto cookies = Cookies(); ASSERT_EQ(2u, cookies.size());
  EXPECT_NE(std::string::npos, cookies[0].find("owner=work"));
  EXPECT_EQ(std::string::npos, cookies[0].find("personal"));
  EXPECT_NE(std::string::npos, cookies[1].find("owner=personal"));
  EXPECT_EQ(std::string::npos, content::GetCookies(work, origin).find("must-not-save"));
  EXPECT_EQ(0, WindowCount(work)); EXPECT_EQ(0, WindowCount(personal));
}

IN_PROC_BROWSER_TEST_F(BarcLiveFetchBrowserTest, RedirectStatusNeverForwardsAndBodiesAreBounded) {
  mode_ = 1;
  LiveReply redirect; redirect.Start(kWork); ASSERT_TRUE(redirect.Wait());
  EXPECT_EQ(BARC_LIVE_OK, redirect.result); EXPECT_EQ(302, redirect.status);
  EXPECT_EQ(1, requests_.load()); EXPECT_TRUE(redirect.body.empty());
  mode_ = 2;
  LiveReply large; large.Start(kWork); ASSERT_TRUE(large.Wait());
  EXPECT_EQ(BARC_LIVE_TOO_LARGE, large.result); EXPECT_TRUE(large.body.empty());
  EXPECT_EQ(1, redirect.calls);
  // The size the response declares decides, also when its body ends early.
  mode_ = 4;
  LiveReply cut; cut.Start(kWork); ASSERT_TRUE(cut.Wait());
  EXPECT_EQ(BARC_LIVE_TOO_LARGE, cut.result); EXPECT_TRUE(cut.body.empty());
}

IN_PROC_BROWSER_TEST_F(BarcLiveFetchBrowserTest, CancelLimitsAndPrivateIdentityRefusal) {
  mode_ = 3;
  LiveReply a, b, refused;
  a.Start(kWork); b.Start(kWork); refused.Start(kWork);
  ASSERT_NE(0u, a.token); ASSERT_NE(0u, b.token); EXPECT_EQ(0u, refused.token);
  barc_profile_live_cancel(a.token); barc_profile_live_cancel(a.token);
  barc_profile_live_cancel(b.token);
  EXPECT_EQ(1, a.calls); EXPECT_EQ(1, b.calls); EXPECT_EQ(0, refused.calls);
  EXPECT_EQ(BARC_LIVE_CANCELLED, a.result);
  LiveReply invalid; invalid.Start(kWork, BARC_LIVE_GMAIL, "0/../other");
  EXPECT_EQ(0u, invalid.token); EXPECT_EQ(0, invalid.calls);
  Result private_window;
  barc_private_session_open_window(Completed, &private_window);
  ASSERT_EQ(BARC_PROFILE_OK, private_window.Get<0>());
  std::array<char, 37> uuid{};
  ASSERT_EQ(uuid.size(), barc_window_private_session_uuid(private_window.Get<1>(), uuid.data(), uuid.size()));
  LiveReply private_read; private_read.Start(uuid.data());
  EXPECT_EQ(0u, private_read.token); EXPECT_EQ(0, private_read.calls);
  ASSERT_EQ(1, barc_window_close(private_window.Get<1>()));
  const std::array<const char*, 4> identities = {kWork, kPersonal,
      "f18d0c5c-6549-4fb2-85d7-54030b269cf4", "49dc1a24-9d09-49c0-a935-33a21c8d9906"};
  std::array<LiveReply, 8> bounded;
  for (size_t index = 0; index < bounded.size(); ++index) {
    bounded[index].Start(identities[index / 2]);
    ASSERT_NE(0u, bounded[index].token);
  }
  LiveReply ninth;
  ninth.Start("ca1586f0-c1b0-49a7-af1b-e8a86c27cdb1");
  EXPECT_EQ(0u, ninth.token); EXPECT_EQ(0, ninth.calls);
  for (auto& pending : bounded) {
    barc_profile_live_cancel(pending.token);
    EXPECT_EQ(1, pending.calls); EXPECT_EQ(BARC_LIVE_CANCELLED, pending.result);
  }
}

IN_PROC_BROWSER_TEST_F(BarcLiveFetchBrowserTest, DeletionAdmissionReleasesRequestKeepAlive) {
  auto* work = Load(kWork, work_keep_);
  ASSERT_TRUE(work);
  ASSERT_TRUE(Load(kPersonal, personal_keep_));
  mode_ = 3;
  LiveReply pending; pending.Start(kWork);
  ASSERT_TRUE(base::test::RunUntil([&] { return requests_.load() > 0; }));
  work_keep_.reset();
  base::test::TestFuture<barc_profile_delete_result> deleted;
  barc_profile_delete_kept(kWork, kPersonal, 0,
      [](barc_profile_delete_result result, void* context) {
        static_cast<base::test::TestFuture<barc_profile_delete_result>*>(context)->SetValue(result);
      }, &deleted);
  ASSERT_TRUE(pending.Wait());
  EXPECT_EQ(BARC_LIVE_CANCELLED, pending.result);
  EXPECT_EQ(BARC_PROFILE_DELETED, deleted.Get());
}

IN_PROC_BROWSER_TEST_F(BarcLiveFetchBrowserTest, OverallDeadlineIncludesHungResponse) {
  base::test::ScopedRunLoopTimeout deadline(FROM_HERE, base::Seconds(25));
  mode_ = 3;
  LiveReply pending; pending.Start(kWork);
  ASSERT_NE(0u, pending.token); ASSERT_TRUE(pending.Wait());
  EXPECT_EQ(BARC_LIVE_TIMEOUT, pending.result); EXPECT_EQ(1, pending.calls);
}

IN_PROC_BROWSER_TEST_F(BarcLiveFetchBrowserTest, CancelDuringProfileInitializationNeverStartsLateGet) {
  class CancelBeforeBorrow : public ProfileManagerObserver {
   public:
    CancelBeforeBorrow(ProfileManager* manager, LiveReply* reply)
        : reply_(reply), path_(manager->user_data_dir().AppendASCII(std::string("Barc-") + kWork)) {
      observation_.Observe(manager);
    }
    void OnProfileAdded(Profile* profile) override {
      if (profile->GetPath() != path_) return;
      // DoFinalInit notifies OnProfileAdded before initialized callbacks run.
      // This cancels the actual request before its resolver borrows the Profile.
      EXPECT_NE(0u, reply_->token);
      barc_profile_live_cancel(reply_->token);
      seen = true;
    }
    bool seen = false;
   private:
    raw_ptr<LiveReply> reply_;
    const base::FilePath path_;
    base::ScopedObservation<ProfileManager, ProfileManagerObserver> observation_{this};
  };
  auto* manager = g_browser_process->profile_manager();
  ASSERT_FALSE(manager->IsProfileLoadedOrLoading(
      manager->user_data_dir().AppendASCII(std::string("Barc-") + kWork)));
  LiveReply pending;
  CancelBeforeBorrow cancel(manager, &pending);
  pending.Start(kWork);
  ASSERT_NE(0u, pending.token); ASSERT_TRUE(pending.Wait());
  EXPECT_TRUE(cancel.seen); EXPECT_EQ(BARC_LIVE_CANCELLED, pending.result);
  base::RunLoop().RunUntilIdle();
  EXPECT_EQ(0, requests_.load()); EXPECT_EQ(1, pending.calls);
}

namespace {
using SearchResult = base::test::TestFuture<int32_t, std::string>;
void SearchDone(void* context, int32_t status, const char* json) {
  static_cast<SearchResult*>(context)->SetValue(status, json ? json : "");
}
constexpr char kSearchSeed[] = R"({"selected":"kagi","engines":[
 {"id":"kagi","name":"Kagi","url":"https://kagi.com/search?q={searchTerms}"},
 {"id":"custom","name":"Custom","url":"https://custom.invalid/?q={searchTerms}"}]})";
}
IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest, ExactSearchImportAndNativeWebUIChoicePreserved) {
  Result created;
  barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &created);
  ASSERT_EQ(BARC_PROFILE_OK, created.Get<0>());
  auto* work = Window(created.Get<1>());
  ASSERT_TRUE(work);
  SearchResult first;
  barc_profile_search_state(kWork, 0, 0, kSearchSeed, nullptr, 1, SearchDone, &first);
  ASSERT_EQ(0, first.Get<0>());
  auto data = base::JSONReader::ReadDict(first.Get<1>(), base::JSON_PARSE_RFC);
  ASSERT_TRUE(data);
  EXPECT_EQ("Kagi", *data->FindString("name"));
  EXPECT_EQ("kagi", *data->FindString("suggestions"));
  auto* service = TemplateURLServiceFactory::GetForProfile(work->GetProfile());
  ASSERT_TRUE(service && service->loaded());
  EXPECT_EQ("https://kagi.com/search?q={searchTerms}", service->GetDefaultSearchProvider()->url());
  TemplateURLData native;
  native.SetShortName(u"Native WebUI Choice"); native.SetKeyword(u"native-choice");
  native.SetURL("https://native.invalid/search?q={searchTerms}");
  auto* choice = service->Add(std::make_unique<TemplateURL>(native));
  ASSERT_TRUE(choice && service->CanMakeDefault(choice));
  service->SetUserSelectedDefaultSearchProvider(choice);
  // Simulates a preexisting explicit WebUI choice with no app import marker.
  work->GetProfile()->GetPrefs()->SetBoolean("barc.search_imported", false);
  SearchResult second;
  barc_profile_search_state(kWork, created.Get<1>(), 0, kSearchSeed, nullptr, 0, SearchDone, &second);
  ASSERT_EQ(0, second.Get<0>());
  auto compact = base::JSONReader::ReadDict(second.Get<1>(), base::JSON_PARSE_RFC);
  ASSERT_TRUE(compact);
  EXPECT_EQ("Native WebUI Choice", *compact->FindString("name"));
  EXPECT_TRUE(compact->FindList("providers")->empty());
  EXPECT_TRUE(compact->FindString("suggestions")->empty());
  SearchResult foreign;
  barc_profile_search_state(kPersonal, created.Get<1>(), 0, kSearchSeed, nullptr, 0, SearchDone, &foreign);
  EXPECT_NE(0, foreign.Get<0>());
  SearchResult private_kind;
  barc_profile_search_state(kWork, created.Get<1>(), 1, kSearchSeed, nullptr, 0, SearchDone, &private_kind);
  EXPECT_NE(0, private_kind.Get<0>());
  SearchResult kept;
  barc_profile_search_state(kPersonal, 0, 0, kSearchSeed, nullptr, 0, SearchDone, &kept);
  ASSERT_EQ(0, kept.Get<0>());
  EXPECT_EQ(choice, service->GetDefaultSearchProvider());
}

IN_PROC_BROWSER_TEST_F(BarcProfilesBrowserTest, NativeSearchDispatchPreservesPOSTWithoutPreliminaryGET) {
  std::vector<net::test_server::HttpRequest> requests;
  base::Lock lock;
  embedded_test_server()->RegisterRequestHandler(base::BindLambdaForTesting(
      [&](const net::test_server::HttpRequest& request)
          -> std::unique_ptr<net::test_server::HttpResponse> {
        if (request.relative_url != "/search") return nullptr;
        { base::AutoLock guard(lock); requests.push_back(request); }
        auto response = std::make_unique<net::test_server::BasicHttpResponse>();
        response->set_content_type("text/html"); response->set_content("<title>POST search</title>");
        return response;
      }));
  ASSERT_TRUE(embedded_test_server()->Start());
  Result created;
  barc_profile_open_window(kWork, BARC_PROFILE_BLANK, Completed, &created);
  ASSERT_EQ(BARC_PROFILE_OK, created.Get<0>());
  auto* work = Window(created.Get<1>());
  SearchResult initialized;
  barc_profile_search_state(kWork, created.Get<1>(), 0, kSearchSeed, nullptr, 0, SearchDone, &initialized);
  ASSERT_EQ(0, initialized.Get<0>());
  auto* service = TemplateURLServiceFactory::GetForProfile(work->GetProfile());
  TemplateURLData post;
  post.SetShortName(u"POST"); post.SetKeyword(u"post-test");
  post.SetURL(embedded_test_server()->GetURL("/search").spec());
  post.search_url_post_params = "q={searchTerms}";
  auto* provider = service->Add(std::make_unique<TemplateURL>(post));
  ASSERT_TRUE(provider && service->CanMakeDefault(provider));
  service->SetUserSelectedDefaultSearchProvider(provider);
  auto* contents = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(barc_tab_search(created.Get<1>(), barc_window_tab_at(created.Get<1>(), 0), "hello world", nullptr));
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  EXPECT_EQ("POST search", content::EvalJs(contents, "document.title"));
  { base::AutoLock guard(lock);
    ASSERT_EQ(1u, requests.size()); EXPECT_EQ(net::test_server::METHOD_POST, requests[0].method);
    EXPECT_NE(std::string::npos, requests[0].content.find("hello"));
    EXPECT_NE(std::string::npos, requests[0].content.find("world")); }
}
