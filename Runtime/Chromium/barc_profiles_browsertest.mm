#include "chrome/browser/ui/views/frame/barc_profiles.h"

#include <string>
#include <utility>
#include <vector>

#include "base/files/file_util.h"
#include "base/run_loop.h"
#include "base/scoped_observation.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "base/threading/thread_restrictions.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/extensions/chrome_test_extension_loader.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/extensions/extension_util.h"
#include "chrome/browser/profiles/nuke_profile_directory_utils.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_attributes_entry.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/frame/barc_bridge.h"
#include "chrome/common/pref_names.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/prefs/pref_service.h"
#include "components/sessions/core/session_id.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "extensions/browser/background_script_executor.h"
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
