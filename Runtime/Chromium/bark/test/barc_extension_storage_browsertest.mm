#import <AppKit/AppKit.h>

// Synthetic routing/storage/consent mechanics. Test-assisted CRX updates do
// not qualify ordinary install/update or Chrome Web Store flows.
#include "bark/bridge/barc_bridge.h"
#include "bark/bridge/barc_bridge_functions.h"
#include "bark/bridge/barc_profiles.h"
#include "bark/browser/ui/bark_window_host.h"

#include <array>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_file_value_serializer.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/scoped_path_override.h"
#include "base/test/test_future.h"
#include "base/threading/thread_restrictions.h"
#include "base/values.h"
#include "chrome/browser/extensions/api/messaging/native_messaging_test_util.h"
#include "chrome/browser/extensions/chrome_test_extension_loader.h"
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/extensions/extension_install_prompt_show_params.h"
#include "chrome/browser/extensions/extension_tab_util.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/extensions/extension_install_dialog_view.h"
#include "chrome/common/chrome_paths.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "components/policy/core/browser/browser_policy_connector.h"
#include "components/policy/core/common/mock_configuration_policy_provider.h"
#include "components/policy/core/common/policy_map.h"
#include "components/policy/core/common/policy_types.h"
#include "components/policy/policy_constants.h"
#include "components/sessions/core/session_id.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/test_devtools_protocol_client.h"
#include "extensions/browser/api/management/management_api_constants.h"
#include "extensions/browser/api/messaging/message_service.h"
#include "extensions/browser/api/messaging/native_message_host.h"
#include "extensions/browser/background_script_executor.h"
#include "extensions/browser/browsertest_util.h"
#include "extensions/browser/crx_installer.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_dialog_auto_confirm.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_host.h"
#include "extensions/browser/extension_host_registry.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/install/crx_install_error.h"
#include "extensions/browser/process_manager.h"
#include "extensions/browser/test_extension_registry_observer.h"
#include "extensions/common/error_utils.h"
#include "extensions/common/extension.h"
#include "extensions/common/mojom/api_permission_id.mojom.h"
#include "extensions/common/permissions/permission_set.h"
#include "extensions/test/extension_test_message_listener.h"
#include "extensions/test/test_extension_dir.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/views/view_utils.h"
#include "ui/views/widget/any_widget_observer.h"
#include "ui/views/widget/widget.h"
#include "ui/views/window/dialog_delegate.h"
#include "url/gurl.h"

namespace {
views::Widget* WidgetFor(BrowserWindowInterface* browser) {
  auto* host = bark::BarkWindowHost::ForBrowser(browser);
  return host ? host->widget() : nullptr;
}

constexpr char kWork[] = "487b52fa-b56a-4df1-ad84-11508a148957";
constexpr char kPersonal[] = "19f3fcde-3a09-467e-b995-5abb4ab69a2c";
using OpenResult = base::test::TestFuture<barc_profile_status, int32_t>;
void Opened(barc_profile_status status, int32_t id, void* data) {
  static_cast<OpenResult*>(data)->SetValue(status, id);
}
BrowserWindowInterface* Window(int32_t id) {
  return GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(id));
}
base::Value Worker(Profile* profile,
                   const std::string& extension_id,
                   const std::string& script) {
  auto* manager = extensions::ProcessManager::Get(profile);
  if (manager->GetServiceWorkersForExtension(extension_id).empty()) {
    base::test::TestFuture<bool> awake;
    if (!manager->WakeEventPage(extension_id, awake.GetCallback()) ||
        !awake.Get()) {
      ADD_FAILURE() << "Could not wake selected profile's extension worker";
      return base::Value();
    }
  }
  return extensions::BackgroundScriptExecutor::ExecuteScript(
      profile, extension_id, script,
      extensions::BackgroundScriptExecutor::ResultCapture::kSendScriptResult);
}
base::Value ReadState(Profile* profile, const std::string& extension_id) {
  return Worker(profile, extension_id, R"(
    (async () => {
      const local = await chrome.storage.local.get('mark');
      const session = await chrome.storage.session.get('mark');
      return {local: local.mark ?? null, session: session.mark ?? null,
              instance: globalThis.workerInstance};
    })().then(value => chrome.test.sendScriptResult(value),
              error => chrome.test.sendScriptResult({error: String(error)}));
  )");
}
void ExpectMarks(const base::Value& value,
                 const char* local,
                 const char* session) {
  ASSERT_TRUE(value.is_dict()) << value;
  const auto& state = value.GetDict();
  ASSERT_NE(nullptr, state.FindString("local")) << value;
  ASSERT_NE(nullptr, state.FindString("session")) << value;
  EXPECT_EQ(local, *state.FindString("local"));
  EXPECT_EQ(session, *state.FindString("session"));
  const auto* instance = state.FindString("instance");
  ASSERT_NE(nullptr, instance) << value;
  EXPECT_FALSE(instance->empty());
}
void WriteMarks(Profile* profile,
                const std::string& extension_id,
                const char* local,
                const char* session) {
  EXPECT_EQ(base::Value(true), Worker(profile, extension_id,
                                      content::JsReplace(R"(
    (async () => {
      await chrome.storage.local.set({mark: $1});
      await chrome.storage.session.set({mark: $2});
      return true;
    })().then(value => chrome.test.sendScriptResult(value),
              error => chrome.test.sendScriptResult({error: String(error)}));
  )",
                                                         local, session)));
}
}  // namespace

class BarcExtensionStorageBrowserTest : public InProcessBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-shared-native-window");
  }

 protected:
  void OpenProfiles(int32_t& work_id, int32_t& personal_id) {
    OpenResult work;
    barc_profile_open_window(kWork, BARC_PROFILE_EXTENSIONS, Opened, &work);
    ASSERT_EQ(BARC_PROFILE_OK, work.Get<0>());
    work_id = work.Get<1>();
    OpenResult personal;
    barc_profile_open_in_native_window(
        work_id, kPersonal, BARC_PROFILE_SETTINGS, Opened, &personal);
    ASSERT_EQ(BARC_PROFILE_OK, personal.Get<0>());
    personal_id = personal.Get<1>();
    auto* first = Window(work_id);
    auto* second = Window(personal_id);
    ASSERT_TRUE(first);
    ASSERT_TRUE(second);
    ASSERT_NE(first->GetProfile(), second->GetProfile());
    ASSERT_NE(nullptr, WidgetFor(first));
    ASSERT_EQ(WidgetFor(first), WidgetFor(second));
    NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    ASSERT_EQ(1, barc_window_set_root_view(work_id, (__bridge void*)root));
    ASSERT_EQ(1, barc_window_show(work_id));
    std::array<char, 37> uuid{};
    EXPECT_EQ(uuid.size(),
              barc_window_profile_uuid(work_id, uuid.data(), uuid.size()));
    EXPECT_STREQ(kWork, uuid.data());
    EXPECT_EQ(uuid.size(),
              barc_window_profile_uuid(personal_id, uuid.data(), uuid.size()));
    EXPECT_STREQ(kPersonal, uuid.data());
  }
  void MountPage(int32_t id) {
    auto* host = bark::BarkWindowHost::ForBrowser(Window(id));
    ASSERT_TRUE(host);
    NSView* root = host->root_view().GetNativeNSView();
    ASSERT_NE(nil, root);
    NSView* page = (__bridge NSView*)barc_tab_native_view(
        id, barc_window_tab_at(id, 0));
    ASSERT_NE(nil, page);
    for (NSView* mounted in root.subviews) {
      [mounted removeFromSuperview];
    }
    page.frame = root.bounds;
    [root addSubview:page];
  }

  void InstallBoth(extensions::TestExtensionDir& dir,
                   Profile* work,
                   Profile* personal,
                   std::string& extension_id) {
    dir.WriteManifest(R"({"manifest_version":3,"name":"Barc storage probe",
      "version":"1.0","permissions":["storage"],
      "background":{"service_worker":"worker.js"}})");
    dir.WriteFile(FILE_PATH_LITERAL("worker.js"), R"(
      globalThis.workerInstance = crypto.randomUUID();
      chrome.test.sendMessage('storage-ready');
    )");
    ExtensionTestMessageListener work_ready("storage-ready");
    work_ready.set_browser_context(work);
    ExtensionTestMessageListener personal_ready("storage-ready");
    personal_ready.set_browser_context(personal);
    extensions::ChromeTestExtensionLoader first_loader(work);
    auto first = first_loader.LoadExtension(dir.UnpackedPath());
    ASSERT_TRUE(first);
    extension_id = first->id();
    work_ready.set_extension_id(extension_id);
    ASSERT_TRUE(work_ready.WaitUntilSatisfied());
    EXPECT_EQ(nullptr, extensions::ExtensionRegistry::Get(personal)
                           ->GetInstalledExtension(extension_id));
    extensions::ChromeTestExtensionLoader second_loader(personal);
    auto second = second_loader.LoadExtension(dir.UnpackedPath());
    ASSERT_TRUE(second);
    ASSERT_EQ(extension_id, second->id());
    personal_ready.set_extension_id(extension_id);
    ASSERT_TRUE(personal_ready.WaitUntilSatisfied());
  }
  // Match upstream native-messaging fixture lifetime. The helper scopes its
  // own filesystem cleanup; path overrides stay installed through teardown.
  extensions::ScopedTestNativeMessagingHost native_host_;
  std::unique_ptr<base::ScopedPathOverride> native_system_path_;
};

IN_PROC_BROWSER_TEST_F(BarcExtensionStorageBrowserTest,
                       ActionPopupFollowsSelectedLogicalOwner) {
  int32_t work_id = 0;
  int32_t personal_id = 0;
  ASSERT_NO_FATAL_FAILURE(OpenProfiles(work_id, personal_id));
  auto* work = Window(work_id);
  auto* personal = Window(personal_id);
  auto* host = bark::BarkWindowHost::ForBrowser(work);
  ASSERT_TRUE(host);
  ASSERT_EQ(host, bark::BarkWindowHost::ForBrowser(personal));
  ASSERT_NO_FATAL_FAILURE(MountPage(work_id));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return host->widget()->IsActive() && work->IsSelectedForNativeWindow();
  }));

  extensions::TestExtensionDir dir;
  dir.WriteManifest(R"({"manifest_version":3,"name":"Bark action probe",
    "version":"1.0","background":{"service_worker":"worker.js"},
    "action":{"default_popup":"default.html"}})");
  dir.WriteFile(FILE_PATH_LITERAL("worker.js"), "// Browser test action probe.");
  dir.WriteFile(FILE_PATH_LITERAL("default.html"), "<p>Unexpected default popup</p>");
  dir.WriteFile(FILE_PATH_LITERAL("selected.html"), "<p>Selected page popup</p>");
  extensions::ChromeTestExtensionLoader work_loader(work->GetProfile());
  auto extension = work_loader.LoadExtension(dir.UnpackedPath());
  ASSERT_TRUE(extension);
  extensions::ChromeTestExtensionLoader personal_loader(personal->GetProfile());
  auto other = personal_loader.LoadExtension(dir.UnpackedPath());
  ASSERT_TRUE(other);
  ASSERT_EQ(extension->id(), other->id());

  const auto invoke = [&](BrowserWindowInterface* owner, int32_t id) {
    return Worker(owner->GetProfile(), extension->id(),
                  "(async () => {"
                  "  try {"
                  "    const [tab] = await chrome.tabs.query({windowId: " +
                      std::to_string(id) +
                      ", active: true});"
                  "    await chrome.action.setPopup({tabId: tab.id, "
                  "                                  popup: 'selected.html'});"
                  "    await chrome.action.openPopup({windowId: " +
                      std::to_string(id) +
                      "});"
                  "    chrome.test.sendScriptResult('shown');"
                  "  } catch (e) { chrome.test.sendScriptResult(e.message); }"
                  "})();");
  };

  auto* work_hosts = extensions::ExtensionHostRegistry::Get(work->GetProfile());
  auto* personal_hosts =
      extensions::ExtensionHostRegistry::Get(personal->GetProfile());
  ASSERT_EQ(base::Value("shown"), invoke(work, work_id));
  ASSERT_TRUE(base::test::RunUntil([&] {
    const auto opened = work_hosts->GetHostsForExtension(extension->id());
    return opened.size() == 1 && opened[0]->has_loaded_once();
  }));
  const auto opened = work_hosts->GetHostsForExtension(extension->id());
  ASSERT_EQ(1u, opened.size());
  auto* popup = opened[0]->host_contents();
  ASSERT_TRUE(popup);
  EXPECT_EQ(work->GetProfile(), popup->GetBrowserContext());
  EXPECT_EQ(extension->GetResourceURL("selected.html"),
            popup->GetLastCommittedURL());
  EXPECT_TRUE(personal_hosts->GetHostsForExtension(extension->id()).empty());

  ASSERT_EQ(1, barc_window_select(personal_id));
  ASSERT_NO_FATAL_FAILURE(MountPage(personal_id));
  EXPECT_EQ(host->widget(), WidgetFor(personal));
  EXPECT_TRUE(personal->IsSelectedForNativeWindow());
  EXPECT_FALSE(work->IsSelectedForNativeWindow());
  EXPECT_TRUE(base::test::RunUntil([&] {
    return work_hosts->GetHostsForExtension(extension->id()).empty();
  }));
  EXPECT_NE(base::Value("shown"), invoke(work, work_id));
  EXPECT_TRUE(work_hosts->GetHostsForExtension(extension->id()).empty());
  EXPECT_TRUE(personal_hosts->GetHostsForExtension(extension->id()).empty());
}

IN_PROC_BROWSER_TEST_F(BarcExtensionStorageBrowserTest,
                       DevToolsActionTargetsSelectedProfileAndPage) {
  int32_t work_id = 0;
  int32_t personal_id = 0;
  ASSERT_NO_FATAL_FAILURE(OpenProfiles(work_id, personal_id));
  auto* work = Window(work_id);
  auto* personal = Window(personal_id);
  ASSERT_NO_FATAL_FAILURE(MountPage(work_id));

  extensions::TestExtensionDir dir;
  dir.WriteManifest(R"({"manifest_version":3,"name":"Bark action click probe",
    "version":"1.0","background":{"service_worker":"worker.js"},"action":{}})");
  dir.WriteFile(FILE_PATH_LITERAL("worker.js"), R"(
    chrome.action.onClicked.addListener(tab => {
      chrome.test.sendMessage('clicked:' + tab.windowId + ':' + tab.id);
    });
  )");
  extensions::ChromeTestExtensionLoader work_loader(work->GetProfile());
  auto extension = work_loader.LoadExtension(dir.UnpackedPath());
  ASSERT_TRUE(extension);
  extensions::ChromeTestExtensionLoader personal_loader(personal->GetProfile());
  auto other = personal_loader.LoadExtension(dir.UnpackedPath());
  ASSERT_TRUE(other);
  ASSERT_EQ(extension->id(), other->id());

  class ProtocolClient : public content::TestDevToolsProtocolClient {
   public:
    using TestDevToolsProtocolClient::error;
  } cdp;
  cdp.AttachToBrowserTarget();
  base::ScopedClosureRunner detach(base::BindOnce(
      &ProtocolClient::DetachProtocolClient, base::Unretained(&cdp)));
  auto run_action = [&](BrowserWindowInterface* owner) {
    auto* page = owner->GetTabStripModel()->GetActiveWebContents();
    auto target = content::DevToolsAgentHost::GetOrCreateForTab(page);
    base::DictValue params;
    params.Set("id", extension->id());
    params.Set("targetId", target->GetId());
    cdp.SendCommandSync("Extensions.triggerAction", std::move(params));
  };
  const auto click_message = [](BrowserWindowInterface* owner) {
    const auto* page = owner->GetTabStripModel()->GetActiveWebContents();
    return "clicked:" + std::to_string(owner->GetSessionID().id()) + ":" +
           std::to_string(extensions::ExtensionTabUtil::GetTabId(page));
  };
  ExtensionTestMessageListener clicked(click_message(work));
  clicked.set_browser_context(work->GetProfile());
  clicked.set_extension_id(extension->id());
  ASSERT_TRUE(base::test::RunUntil([&] { return WidgetFor(work)->IsActive(); }));
  run_action(work);
  ASSERT_FALSE(cdp.error());
  EXPECT_TRUE(clicked.WaitUntilSatisfied());

  ASSERT_EQ(1, barc_window_select(personal_id));
  ASSERT_NO_FATAL_FAILURE(MountPage(personal_id));
  run_action(work);
  ASSERT_TRUE(cdp.error());
  const auto* error_message = cdp.error()->FindString("message");
  ASSERT_TRUE(error_message);
  EXPECT_EQ("Action unavailable for the selected page.", *error_message);
  EXPECT_EQ(WidgetFor(work), WidgetFor(personal));

  ExtensionTestMessageListener personal_clicked(click_message(personal));
  personal_clicked.set_browser_context(personal->GetProfile());
  personal_clicked.set_extension_id(extension->id());
  run_action(personal);
  ASSERT_FALSE(cdp.error());
  EXPECT_TRUE(personal_clicked.WaitUntilSatisfied());
}

class BarcNativeExtensionActionsBrowserTest
    : public BarcExtensionStorageBrowserTest {
 protected:
  void SetUpInProcessBrowserTestFixture() override {
    BarcExtensionStorageBrowserTest::SetUpInProcessBrowserTestFixture();
    policy_provider_.SetDefaultReturns(true, true);
    policy::BrowserPolicyConnector::SetPolicyProviderForTesting(
        &policy_provider_);
  }

  void SetForcePin(const std::string& id) {
    policy::PolicyMap policies;
    if (!id.empty()) {
      base::DictValue extensions;
      extensions.Set(id, base::DictValue().Set("toolbar_pin", "force_pinned"));
      policies.Set(policy::key::kExtensionSettings,
                   policy::POLICY_LEVEL_MANDATORY, policy::POLICY_SCOPE_USER,
                   policy::POLICY_SOURCE_PLATFORM,
                   base::Value(std::move(extensions)), nullptr);
    }
    policy_provider_.UpdateChromePolicy(policies);
  }

 private:
  testing::NiceMock<policy::MockConfigurationPolicyProvider> policy_provider_;
};

IN_PROC_BROWSER_TEST_F(BarcNativeExtensionActionsBrowserTest,
                       NativeActionsScopeMetadataPinAndPopupToPresentedPage) {
  int32_t work_id = 0;
  int32_t personal_id = 0;
  ASSERT_NO_FATAL_FAILURE(OpenProfiles(work_id, personal_id));
  auto* work = Window(work_id);
  auto* personal = Window(personal_id);
  ASSERT_NO_FATAL_FAILURE(MountPage(work_id));
  const int32_t work_tab = barc_window_tab_at(work_id, 0);
  const int32_t personal_tab = barc_window_tab_at(personal_id, 0);

  extensions::TestExtensionDir dir;
  dir.WriteManifest(R"({"manifest_version":3,"name":"Bark native action",
    "version":"1.0","background":{"service_worker":"worker.js"},
    "action":{"default_title":"Default title","default_popup":"popup.html"}})");
  dir.WriteFile(FILE_PATH_LITERAL("worker.js"), "// Browser test action probe.");
  dir.WriteFile(FILE_PATH_LITERAL("popup.html"), "<p>Real action popup</p>");
  const auto load = [&](Profile* profile) {
    extensions::ChromeTestExtensionLoader loader(profile);
    return loader.LoadExtension(dir.UnpackedPath());
  };
  auto extension = load(work->GetProfile());
  ASSERT_TRUE(extension);
  auto other = load(personal->GetProfile());
  ASSERT_TRUE(other);
  const auto& id = extension->id();
  ASSERT_EQ(id, other->id());

  struct Row {
    std::string id;
    std::string title;
    std::string badge;
    int flags;
  };
  const auto append = [](void* context, const char* extension_id,
                         const char* title, const char* badge, int flags) {
    static_cast<std::vector<Row>*>(context)->push_back(
        {extension_id, title, badge, flags});
  };
  std::vector<Row> rows;
  const auto list = [&](int32_t owner, int32_t tab) {
    rows.clear();
    return barc_tab_list_extension_actions(owner, tab, append, &rows);
  };
  int invalidations = 0;
  const uint64_t observation = barc_window_host_observe(
      work_id,
      [](const BarcWindowHostEvent* event, void* context) {
        if (event->kind == BARC_WINDOW_HOST_EXTENSION_ACTIONS_CHANGED) {
          ++*static_cast<int*>(context);
        }
      },
      &invalidations);
  ASSERT_NE(0u, observation);
  base::ScopedClosureRunner unobserve(base::BindOnce(
      barc_window_host_unobserve, observation));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return WidgetFor(work)->IsActive() && list(work_id, work_tab) &&
           rows.size() == 1;
  }));

  const int prior_update = invalidations;
  EXPECT_EQ(base::Value("updated"), Worker(work->GetProfile(), id, R"(
    (async () => {
      const [tab] = await chrome.tabs.query({active: true});
      await chrome.action.setTitle({tabId: tab.id, title: 'Work title'});
      await chrome.action.setBadgeText({tabId: tab.id, text: 'W'});
      chrome.test.sendScriptResult('updated');
    })();
  )"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return invalidations > prior_update && list(work_id, work_tab) &&
           rows.size() == 1 && rows[0].badge == "W";
  }));
  EXPECT_EQ(id, rows[0].id);
  EXPECT_EQ("Work title", rows[0].title);
  EXPECT_NE(0, rows[0].flags & BARC_EXTENSION_ENABLED);

  const int initial_pin = (rows[0].flags & BARC_EXTENSION_PINNED) == 0;
  const int before_pin = invalidations;
  ASSERT_EQ(1, barc_tab_set_extension_pinned(work_id, work_tab, id.c_str(),
                                             initial_pin));
  ASSERT_TRUE(base::test::RunUntil([&] { return invalidations > before_pin; }));
  EXPECT_EQ(1, barc_tab_set_extension_pinned(work_id, work_tab, id.c_str(), 1));
  ASSERT_EQ(1, list(work_id, work_tab));
  ASSERT_EQ(1u, rows.size());
  EXPECT_NE(0, rows[0].flags & BARC_EXTENSION_PINNED);
  EXPECT_EQ(0, list(personal_id, personal_tab));
  EXPECT_EQ(0, barc_tab_set_extension_pinned(
                   personal_id, personal_tab, id.c_str(), 1));

  SetForcePin(id);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return list(work_id, work_tab) && rows.size() == 1 &&
           (rows[0].flags & BARC_EXTENSION_PIN_LOCKED);
  }));
  EXPECT_EQ(0, barc_tab_set_extension_pinned(work_id, work_tab, id.c_str(), 0));
  SetForcePin({});
  ASSERT_TRUE(base::test::RunUntil([&] {
    return list(work_id, work_tab) && rows.size() == 1 &&
           !(rows[0].flags & BARC_EXTENSION_PIN_LOCKED);
  }));

  ASSERT_EQ(1, barc_window_select(personal_id));
  ASSERT_NO_FATAL_FAILURE(MountPage(personal_id));
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return list(personal_id, personal_tab) && rows.size() == 1; }));
  EXPECT_EQ("Default title", rows[0].title);
  EXPECT_TRUE(rows[0].badge.empty());
  EXPECT_EQ(0, rows[0].flags & (BARC_EXTENSION_PINNED | BARC_EXTENSION_PIN_LOCKED));
  EXPECT_EQ(0, barc_tab_invoke_extension(work_id, work_tab, id.c_str()));

  auto* personal_hosts =
      extensions::ExtensionHostRegistry::Get(personal->GetProfile());
  ASSERT_EQ(1, barc_tab_invoke_extension(personal_id, personal_tab, id.c_str()));
  ASSERT_TRUE(base::test::RunUntil([&] {
    const auto popups = personal_hosts->GetHostsForExtension(id);
    return popups.size() == 1 && popups[0]->has_loaded_once();
  }));
  EXPECT_TRUE(extensions::ExtensionHostRegistry::Get(work->GetProfile())
                  ->GetHostsForExtension(id)
                  .empty());
  ASSERT_EQ(1, barc_window_select(work_id));
  ASSERT_NO_FATAL_FAILURE(MountPage(work_id));
  EXPECT_TRUE(base::test::RunUntil(
      [&] { return personal_hosts->GetHostsForExtension(id).empty(); }));

  OpenResult guest;
  barc_private_session_open_window(Opened, &guest);
  ASSERT_EQ(BARC_PROFILE_OK, guest.Get<0>());
  const int32_t guest_id = guest.Get<1>();
  NSView* root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  ASSERT_EQ(1, barc_window_set_root_view(guest_id, (__bridge void*)root));
  ASSERT_NO_FATAL_FAILURE(MountPage(guest_id));
  const int32_t guest_tab = barc_window_tab_at(guest_id, 0);
  EXPECT_EQ(0, list(guest_id, guest_tab));
  EXPECT_TRUE(rows.empty());
  EXPECT_EQ(0, barc_tab_set_extension_pinned(guest_id, guest_tab, id.c_str(), 1));
  EXPECT_EQ(0, barc_tab_invoke_extension(guest_id, guest_tab, id.c_str()));

  ASSERT_EQ(1, list(work_id, work_tab));
  const int prior_title = invalidations;
  EXPECT_EQ(base::Value("updated"), Worker(work->GetProfile(), id, R"(
    (async () => {
      const [tab] = await chrome.tabs.query({active: true});
      await chrome.action.setTitle({tabId: tab.id, title: ''});
      chrome.test.sendScriptResult('updated');
    })();
  )"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return list(work_id, work_tab) && invalidations > prior_title &&
           rows.size() == 1 && rows[0].title == "Bark native action";
  }));
  struct CloseDuringList {
    int32_t window;
    int rows = 0;
  } closing{work_id};
  EXPECT_EQ(1, barc_tab_list_extension_actions(
                   work_id, work_tab,
                   [](void* context, const char*, const char*, const char*,
                      int) {
                     auto& state = *static_cast<CloseDuringList*>(context);
                     if (++state.rows == 1) {
                       EXPECT_EQ(1, barc_window_close(state.window));
                     }
                   },
                   &closing));
  EXPECT_EQ(1, closing.rows);
  EXPECT_TRUE(base::test::RunUntil([&] { return !Window(work_id); }));
}

IN_PROC_BROWSER_TEST_F(BarcExtensionStorageBrowserTest,
                       IsolatedStorageSurvivesWorkWorkerRestart) {
  int32_t work_id = 0;
  int32_t personal_id = 0;
  ASSERT_NO_FATAL_FAILURE(OpenProfiles(work_id, personal_id));
  auto* work = Window(work_id)->GetProfile();
  auto* personal = Window(personal_id)->GetProfile();
  extensions::TestExtensionDir dir;
  std::string extension_id;
  ASSERT_NO_FATAL_FAILURE(InstallBoth(dir, work, personal, extension_id));
  WriteMarks(work, extension_id, "work-local", "work-session");
  WriteMarks(personal, extension_id, "personal-local", "personal-session");
  auto before = ReadState(work, extension_id);
  ASSERT_NO_FATAL_FAILURE(ExpectMarks(before, "work-local", "work-session"));
  const std::string old_instance = *before.GetDict().FindString("instance");
  auto other = ReadState(personal, extension_id);
  ASSERT_NO_FATAL_FAILURE(
      ExpectMarks(other, "personal-local", "personal-session"));
  EXPECT_NE(old_instance, *other.GetDict().FindString("instance"));
  extensions::browsertest_util::StopServiceWorkerForExtensionGlobalScope(
      work, extension_id);
  ASSERT_TRUE(base::test::RunUntil([&] {
    return extensions::ProcessManager::Get(work)
        ->GetServiceWorkersForExtension(extension_id)
        .empty();
  }));
  auto after = ReadState(
      work, extension_id);  // Explicit wake, then real worker execution.
  ASSERT_NO_FATAL_FAILURE(ExpectMarks(after, "work-local", "work-session"));
  EXPECT_NE(old_instance, *after.GetDict().FindString("instance"));
  ASSERT_NO_FATAL_FAILURE(ExpectMarks(ReadState(personal, extension_id),
                                      "personal-local", "personal-session"));
  // Personal may legitimately idle-stop. No requirement that its JS global or
  // worker version remain alive across operations in Work.
}

IN_PROC_BROWSER_TEST_F(
    BarcExtensionStorageBrowserTest,
    RetainedExtensionsPageManagesOnlyWorkWhilePersonalSelected) {
  int32_t work_id = 0;
  int32_t personal_id = 0;
  ASSERT_NO_FATAL_FAILURE(OpenProfiles(work_id, personal_id));
  auto* work_window = Window(work_id);
  auto* personal_window = Window(personal_id);
  auto* work = work_window->GetProfile();
  auto* personal = personal_window->GetProfile();
  auto* page = work_window->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(page));
  ASSERT_EQ(work, page->GetBrowserContext());
  ASSERT_EQ(GURL("chrome://extensions/"), page->GetLastCommittedURL());
  ASSERT_EQ(true, content::EvalJs(page, R"(
    customElements.whenDefined('extensions-manager').then(() =>
      typeof chrome.management.setEnabled === 'function' &&
      typeof chrome.management.uninstall === 'function')
  )"));
  extensions::TestExtensionDir dir;
  std::string extension_id;
  ASSERT_NO_FATAL_FAILURE(InstallBoth(dir, work, personal, extension_id));
  WriteMarks(work, extension_id, "work-local", "work-session");
  WriteMarks(personal, extension_id, "personal-local", "personal-session");
  ASSERT_EQ(1, barc_window_select(personal_id));
  ASSERT_TRUE(personal_window->IsSelectedForNativeWindow());
  // Same management API used by chrome/browser/resources/extensions/service.ts.
  ASSERT_EQ(true, content::EvalJs(page, content::JsReplace(R"(
    chrome.management.setEnabled($1, false).then(() => true,
      error => 'disable-error:' + error)
  )",
                                                           extension_id)));
  auto* work_registry = extensions::ExtensionRegistry::Get(work);
  auto* personal_registry = extensions::ExtensionRegistry::Get(personal);
  EXPECT_TRUE(work_registry->disabled_extensions().Contains(extension_id));
  EXPECT_TRUE(personal_registry->enabled_extensions().Contains(extension_id));
  EXPECT_TRUE(personal_window->IsSelectedForNativeWindow());
  ASSERT_NO_FATAL_FAILURE(ExpectMarks(ReadState(personal, extension_id),
                                      "personal-local", "personal-session"));
  ASSERT_EQ(true, content::EvalJs(page, content::JsReplace(R"(
    chrome.management.setEnabled($1, true).then(() => true,
      error => 'enable-error:' + error)
  )",
                                                           extension_id)));
  EXPECT_TRUE(work_registry->enabled_extensions().Contains(extension_id));
  auto restored = ReadState(work, extension_id);
  ASSERT_TRUE(restored.is_dict()) << restored;
  ASSERT_NE(nullptr, restored.GetDict().FindString("local"));
  EXPECT_EQ("work-local", *restored.GetDict().FindString("local"));
  // Session storage may be cleared by disable; only local durability is
  // required.
  EXPECT_TRUE(personal_window->IsSelectedForNativeWindow());
  {
    int initialized_widgets = 0;
    views::AnyWidgetObserver observer(views::test::AnyWidgetTestPasskey{});
    observer.set_initialized_callback(base::BindLambdaForTesting(
        [&](views::Widget*) { ++initialized_widgets; }));
    // Inactive logical-owner confirmation must cancel before creating UI;
    // no auto-consent is installed for this request.
    EXPECT_EQ(extensions::ErrorUtils::FormatErrorMessage(
                  extension_management_api_constants::kUninstallCanceledError,
                  extension_id),
              content::EvalJs(page, content::JsReplace(R"(
      chrome.management.uninstall($1, {showConfirmDialog: true}).then(
        () => 'unexpected-success', error => error.message ?? String(error))
    )",
                                                       extension_id)));
    // Exercise the non-tab/service-worker route too. Existing test gesture
    // support authorizes this confirmation request; no consent auto-accept is
    // installed. CurrentWindowForFunction must choose Work's logical browser,
    // not Personal's selected owner of the same native Widget.
    EXPECT_EQ(base::Value(extensions::ErrorUtils::FormatErrorMessage(
                  extension_management_api_constants::kUninstallCanceledError,
                  extension_id)),
              Worker(work, extension_id, R"(
      chrome.test.runWithUserGesture(() => {
        chrome.management.uninstallSelf({showConfirmDialog: true}).then(
          () => chrome.test.sendScriptResult('unexpected-success'),
          error => chrome.test.sendScriptResult(error.message ?? String(error)));
      });
    )"));
    EXPECT_EQ(0, initialized_widgets);
  }
  EXPECT_TRUE(work_registry->enabled_extensions().Contains(extension_id));
  EXPECT_TRUE(personal_registry->enabled_extensions().Contains(extension_id));
  EXPECT_TRUE(personal_window->IsSelectedForNativeWindow());
  ASSERT_NO_FATAL_FAILURE(ExpectMarks(ReadState(personal, extension_id),
                                      "personal-local", "personal-session"));
  ASSERT_EQ(1, barc_window_select(work_id));
  ASSERT_TRUE(work_window->IsSelectedForNativeWindow());
  {
    // Existing test consent handles the ordinary confirmation request. This
    // qualifies profile-bound API mutation, not prompt anchors/consent UI.
    extensions::ScopedTestDialogAutoConfirm confirm(
        extensions::ScopedTestDialogAutoConfirm::ACCEPT);
    ASSERT_EQ(true, content::EvalJs(page, content::JsReplace(R"(
      chrome.management.uninstall($1, {showConfirmDialog: true}).then(() => true,
        error => 'uninstall-error:' + error)
    )",
                                                             extension_id)));
  }
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return !work_registry->GetInstalledExtension(extension_id); }));
  EXPECT_TRUE(personal_registry->enabled_extensions().Contains(extension_id));
  EXPECT_TRUE(work_window->IsSelectedForNativeWindow());
  EXPECT_EQ(work, page->GetBrowserContext());
  ASSERT_NO_FATAL_FAILURE(ExpectMarks(ReadState(personal, extension_id),
                                      "personal-local", "personal-session"));
}

IN_PROC_BROWSER_TEST_F(
    BarcExtensionStorageBrowserTest,
    EscalatedReenableConsentRemainsWithOriginalLogicalOwner) {
  int32_t work_id = 0;
  int32_t personal_id = 0;
  ASSERT_NO_FATAL_FAILURE(OpenProfiles(work_id, personal_id));
  auto* work_window = Window(work_id);
  auto* personal_window = Window(personal_id);
  auto* work = work_window->GetProfile();
  auto* personal = personal_window->GetProfile();
  auto* page = work_window->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::WaitForLoadStop(page));
  ASSERT_EQ(work, page->GetBrowserContext());
  ASSERT_EQ(GURL("chrome://extensions/"), page->GetLastCommittedURL());

  // Real signed update/permission-delta processing, with the same test-assisted
  // off-store allowance as Chromium's update tests. No store-install claim.
  extensions::TestExtensionDir dir;
  dir.WriteManifest(R"({"manifest_version":3,"name":"Barc permission update",
    "version":"1.0","permissions":["storage"],
    "background":{"service_worker":"worker.js"}})");
  dir.WriteFile(FILE_PATH_LITERAL("worker.js"),
                "globalThis.workerInstance = crypto.randomUUID();");
  const auto low_crx = dir.Pack("low.crx");
  extensions::ChromeTestExtensionLoader work_loader(work);
  auto low = work_loader.LoadExtension(low_crx);
  ASSERT_TRUE(low);
  const std::string extension_id = low->id();
  extensions::ChromeTestExtensionLoader personal_loader(personal);
  auto other = personal_loader.LoadExtension(low_crx);
  ASSERT_TRUE(other);
  ASSERT_EQ(extension_id, other->id());
  WriteMarks(personal, extension_id, "personal-local", "personal-session");
  dir.WriteManifest(R"({"manifest_version":3,"name":"Barc permission update",
    "version":"2.0","permissions":["storage","tabs"],
    "background":{"service_worker":"worker.js"}})");
  const auto high_crx = dir.Pack("high.crx");
  auto update = extensions::CrxInstaller::CreateSilent(work);
  update->set_expected_id(extension_id);
  update->set_install_immediately(true);
  update->set_allow_silent_install(false);
  update->set_grant_permissions(false);
  update->set_off_store_install_allow_reason(
      extensions::CrxInstaller::OffStoreInstallAllowedInTest);
  base::test::TestFuture<std::optional<extensions::CrxInstallError>> updated;
  update->AddInstallerCallback(
      updated.GetCallback<const std::optional<extensions::CrxInstallError>&>());
  update->InstallCrx(high_crx);
  ASSERT_FALSE(updated.Get().has_value());
  auto* registry = extensions::ExtensionRegistry::Get(work);
  auto* prefs = extensions::ExtensionPrefs::Get(work);
  ASSERT_TRUE(registry->disabled_extensions().Contains(extension_id));
  ASSERT_TRUE(prefs->DidExtensionEscalatePermissions(extension_id));
  auto granted = prefs->GetGrantedPermissions(extension_id);
  ASSERT_TRUE(granted);
  ASSERT_FALSE(
      granted->HasAPIPermission(extensions::mojom::APIPermissionID::kTab));
  auto* personal_registry = extensions::ExtensionRegistry::Get(personal);
  ASSERT_TRUE(personal_registry->enabled_extensions().Contains(extension_id));
  EXPECT_EQ("1.0", personal_registry->GetInstalledExtension(extension_id)
                       ->version()
                       .GetString());

  ASSERT_EQ(1, barc_window_select(personal_id));
  {
    int created = 0;
    views::AnyWidgetObserver observed(views::test::AnyWidgetTestPasskey{});
    observed.set_initialized_callback(
        base::BindLambdaForTesting([&](views::Widget*) { ++created; }));
    EXPECT_EQ(extension_management_api_constants::kUserDidNotReEnableError,
              content::EvalJs(page, content::JsReplace(R"(
      chrome.management.setEnabled($1, true).then(
        () => 'unexpected-acceptance', error => error.message ?? String(error))
    )",
                                                       extension_id)));
    EXPECT_EQ(0, created);
  }
  EXPECT_TRUE(personal_window->IsSelectedForNativeWindow());
  EXPECT_TRUE(registry->disabled_extensions().Contains(extension_id));
  EXPECT_FALSE(
      prefs->GetGrantedPermissions(extension_id)
          ->HasAPIPermission(extensions::mojom::APIPermissionID::kTab));
  ASSERT_NO_FATAL_FAILURE(ExpectMarks(ReadState(personal, extension_id),
                                      "personal-local", "personal-session"));

  // Positive real consent UI, without auto-confirm or disabling click guards.
  ASSERT_EQ(1, barc_window_select(work_id));
  base::WeakPtr<views::Widget> consent;
  views::AnyWidgetObserver observed(views::test::AnyWidgetTestPasskey{});
  observed.set_shown_callback(
      base::BindLambdaForTesting([&](views::Widget* widget) {
        auto* view = views::AsViewClass<ExtensionInstallDialogView>(
            widget->widget_delegate()->GetContentsView());
        if (view)
          consent = widget->GetWeakPtr();
      }));
  ASSERT_EQ(true, content::EvalJs(page, content::JsReplace(R"(
    globalThis.reenableResult = chrome.management.setEnabled($1, true).then(
      () => 'unexpected-acceptance', error => error.message ?? String(error));
    true;
  )",
                                                           extension_id)));
  ASSERT_TRUE(
      base::test::RunUntil([&] { return consent && consent->IsVisible(); }));
  auto* view = views::AsViewClass<ExtensionInstallDialogView>(
      consent->widget_delegate()->GetContentsView());
  ASSERT_TRUE(view);
  EXPECT_EQ(work_window, view->GetShowParamsForTesting()->GetBrowserOwner());
  EXPECT_EQ(page, view->GetShowParamsForTesting()->GetParentWebContents());
  EXPECT_TRUE(work_window->IsSelectedForNativeWindow());
  EXPECT_FALSE(
      prefs->GetGrantedPermissions(extension_id)
          ->HasAPIPermission(extensions::mojom::APIPermissionID::kTab));
  consent->widget_delegate()->AsDialogDelegate()->CancelDialog();
  EXPECT_EQ(extension_management_api_constants::kUserDidNotReEnableError,
            content::EvalJs(page, "globalThis.reenableResult"));
  EXPECT_TRUE(registry->disabled_extensions().Contains(extension_id));
  EXPECT_FALSE(
      prefs->GetGrantedPermissions(extension_id)
          ->HasAPIPermission(extensions::mojom::APIPermissionID::kTab));
  ASSERT_TRUE(base::test::RunUntil([&] { return !consent; }));

  // Existing show callback is the boundary after real async icon/permission
  // loading, before native presentation. Reparent the actual live source tab
  // there; matching Profile/native Widget is not enough to retain ownership.
  OpenResult peer_result;
  barc_profile_open_in_native_window(work_id, kWork, BARC_PROFILE_SETTINGS,
                                     Opened, &peer_result);
  ASSERT_EQ(BARC_PROFILE_OK, peer_result.Get<0>());
  const int32_t peer_id = peer_result.Get<1>();
  ASSERT_EQ(work, Window(peer_id)->GetProfile());
  ASSERT_EQ(1, barc_window_select(work_id));
  const int32_t source_tab = barc_window_tab_at(work_id, 0);
  const int32_t survivor_tab = barc_tab_create(work_id, "about:blank", 0);
  ASSERT_NE(0, survivor_tab);
  scoped_refptr<const extensions::Extension> high =
      registry->disabled_extensions().GetByID(extension_id);
  ASSERT_TRUE(high);
  auto pending = std::make_unique<ExtensionInstallPrompt>(
      page, std::make_unique<extensions::InstallPromptData>(
                extensions::InstallPromptData::RE_ENABLE_PROMPT));
  base::test::TestFuture<ExtensionInstallPrompt::DoneCallbackPayload> finished;
  bool icon_delivered = false;
  int created = 0;
  views::AnyWidgetObserver no_reparented_ui(
      views::test::AnyWidgetTestPasskey{});
  no_reparented_ui.set_initialized_callback(
      base::BindLambdaForTesting([&](views::Widget*) { ++created; }));
  pending->ShowDialog(
      finished.GetCallback(), high.get(), nullptr,
      base::BindLambdaForTesting(
          [&](std::unique_ptr<ExtensionInstallPromptShowParams> params,
              ExtensionInstallPrompt::DoneCallback callback,
              std::unique_ptr<extensions::InstallPromptData> data) {
            icon_delivered = true;
            EXPECT_TRUE(params->CanShowForBrowserOwner());
            EXPECT_EQ(1, barc_tab_transfer(work_id, source_tab, peer_id));
            EXPECT_EQ(page, tabs::TabHandle(source_tab).Get()->GetContents());
            EXPECT_EQ(
                Window(peer_id),
                tabs::TabHandle(source_tab).Get()->GetBrowserWindowInterface());
            EXPECT_EQ(1, barc_window_select(work_id));
            EXPECT_EQ(work_window, Window(work_id));
            EXPECT_FALSE(work_window->IsDeleteScheduled());
            EXPECT_TRUE(work_window->IsSelectedForNativeWindow());
            EXPECT_FALSE(params->CanShowForBrowserOwner());
            ExtensionInstallPrompt::GetDefaultShowDialogCallback().Run(
                std::move(params), std::move(callback), std::move(data));
          }));
  EXPECT_FALSE(icon_delivered);
  EXPECT_EQ(ExtensionInstallPrompt::Result::ABORTED, finished.Get().result);
  EXPECT_TRUE(icon_delivered);
  EXPECT_EQ(0, created);
  EXPECT_TRUE(work_window->IsSelectedForNativeWindow());
  EXPECT_FALSE(work_window->IsDeleteScheduled());
  EXPECT_EQ(Window(peer_id),
            tabs::TabHandle(source_tab).Get()->GetBrowserWindowInterface());
  EXPECT_EQ(work, page->GetBrowserContext());
  EXPECT_TRUE(registry->disabled_extensions().Contains(extension_id));
  EXPECT_FALSE(
      prefs->GetGrantedPermissions(extension_id)
          ->HasAPIPermission(extensions::mojom::APIPermissionID::kTab));
  // A displayed prompt must die with its logical owner, even though peer
  // Work and Personal keep the physical Widget and Work Profile alive.
  auto* survivor_contents = tabs::TabHandle(survivor_tab).Get()->GetContents();
  ASSERT_EQ(work_window,
            tabs::TabHandle(survivor_tab).Get()->GetBrowserWindowInterface());
  consent.reset();
  auto displayed = std::make_unique<ExtensionInstallPrompt>(
      survivor_contents, std::make_unique<extensions::InstallPromptData>(
                             extensions::InstallPromptData::RE_ENABLE_PROMPT));
  base::test::TestFuture<ExtensionInstallPrompt::DoneCallbackPayload> closed;
  displayed->ShowDialog(closed.GetCallback(), high.get(), nullptr,
                        ExtensionInstallPrompt::GetDefaultShowDialogCallback());
  ASSERT_TRUE(
      base::test::RunUntil([&] { return consent && consent->IsVisible(); }));
  auto* closing_view = views::AsViewClass<ExtensionInstallDialogView>(
      consent->widget_delegate()->GetContentsView());
  ASSERT_TRUE(closing_view);
  EXPECT_EQ(work_window,
            closing_view->GetShowParamsForTesting()->GetBrowserOwner());
  ASSERT_NE(nullptr, WidgetFor(work_window));
  const auto widget_alive = WidgetFor(work_window)->GetWeakPtr();
  const auto owner_alive = work_window->GetWeakPtr();
  EXPECT_EQ(1, barc_window_close(work_id));
  EXPECT_EQ(ExtensionInstallPrompt::Result::USER_CANCELED, closed.Get().result);
  ASSERT_TRUE(base::test::RunUntil([&] { return !consent && !owner_alive; }));
  ASSERT_TRUE(widget_alive);
  ASSERT_TRUE(Window(personal_id));
  ASSERT_TRUE(Window(peer_id));
  EXPECT_EQ(
      widget_alive.get(),
      WidgetFor(Window(personal_id)));
  EXPECT_EQ(
      widget_alive.get(),
      WidgetFor(Window(peer_id)));
  EXPECT_TRUE(registry->disabled_extensions().Contains(extension_id));
  EXPECT_FALSE(
      prefs->GetGrantedPermissions(extension_id)
          ->HasAPIPermission(extensions::mojom::APIPermissionID::kTab));
  ASSERT_NO_FATAL_FAILURE(ExpectMarks(ReadState(personal, extension_id),
                                      "personal-local", "personal-session"));
  // Finally accept the real re-enable prompt in the selected surviving Work
  // peer. Wait for the ordinary button guard; this is consent routing, not a
  // native click or store-install qualification.
  ASSERT_EQ(1, barc_window_select(peer_id));
  consent.reset();
  ASSERT_EQ(true, content::EvalJs(page, content::JsReplace(R"(
    globalThis.finalReenable = chrome.management.setEnabled($1, true).then(
      () => true, error => error.message ?? String(error));
    true;
  )",
                                                           extension_id)));
  ASSERT_TRUE(base::test::RunUntil([&] {
    if (!consent || !consent->IsVisible())
      return false;
    auto* accepting = views::AsViewClass<ExtensionInstallDialogView>(
        consent->widget_delegate()->GetContentsView());
    return accepting &&
           accepting->IsDialogButtonEnabled(ui::mojom::DialogButton::kOk);
  }));
  auto* accepting = views::AsViewClass<ExtensionInstallDialogView>(
      consent->widget_delegate()->GetContentsView());
  ASSERT_TRUE(accepting);
  EXPECT_EQ(Window(peer_id),
            accepting->GetShowParamsForTesting()->GetBrowserOwner());
  EXPECT_EQ(page, accepting->GetShowParamsForTesting()->GetParentWebContents());
  consent->widget_delegate()->AsDialogDelegate()->AcceptDialog();
  EXPECT_EQ(true, content::EvalJs(page, "globalThis.finalReenable"));
  EXPECT_TRUE(registry->enabled_extensions().Contains(extension_id));
  EXPECT_EQ(
      "2.0",
      registry->GetInstalledExtension(extension_id)->version().GetString());
  EXPECT_TRUE(prefs->GetGrantedPermissions(extension_id)
                  ->HasAPIPermission(extensions::mojom::APIPermissionID::kTab));
  EXPECT_TRUE(personal_registry->enabled_extensions().Contains(extension_id));
  EXPECT_EQ("1.0", personal_registry->GetInstalledExtension(extension_id)
                       ->version()
                       .GetString());
  EXPECT_FALSE(
      extensions::ExtensionPrefs::Get(personal)
          ->GetGrantedPermissions(extension_id)
          ->HasAPIPermission(extensions::mojom::APIPermissionID::kTab));
  ASSERT_NO_FATAL_FAILURE(ExpectMarks(ReadState(personal, extension_id),
                                      "personal-local", "personal-session"));
  ASSERT_TRUE(base::test::RunUntil([&] { return !consent; }));
}

IN_PROC_BROWSER_TEST_F(BarcExtensionStorageBrowserTest,
                       OptionalPermissionsKeepWorkerAndTabLogicalOwnership) {
  int32_t work_id = 0;
  int32_t personal_id = 0;
  ASSERT_NO_FATAL_FAILURE(OpenProfiles(work_id, personal_id));
  auto* work_window = Window(work_id);
  auto* personal_window = Window(personal_id);
  auto* work = work_window->GetProfile();
  auto* personal = personal_window->GetProfile();
  extensions::TestExtensionDir dir;
  dir.WriteManifest(R"({"manifest_version":3,"name":"Barc optional permissions",
    "version":"1.0","permissions":["storage"],
    "optional_permissions":["tabs","bookmarks"],
    "background":{"service_worker":"worker.js"}})");
  dir.WriteFile(FILE_PATH_LITERAL("worker.js"),
                "globalThis.workerInstance = crypto.randomUUID();"
                "chrome.test.sendMessage('optional-ready');");
  dir.WriteFile(FILE_PATH_LITERAL("request.html"),
                "<!doctype html><body>Optional permission source tab</body>");
  ExtensionTestMessageListener work_ready("optional-ready");
  work_ready.set_browser_context(work);
  ExtensionTestMessageListener personal_ready("optional-ready");
  personal_ready.set_browser_context(personal);
  extensions::ChromeTestExtensionLoader work_loader(work);
  auto extension = work_loader.LoadExtension(dir.UnpackedPath());
  ASSERT_TRUE(extension);
  const std::string extension_id = extension->id();
  work_ready.set_extension_id(extension_id);
  ASSERT_TRUE(work_ready.WaitUntilSatisfied());
  extensions::ChromeTestExtensionLoader personal_loader(personal);
  auto other = personal_loader.LoadExtension(dir.UnpackedPath());
  ASSERT_TRUE(other);
  ASSERT_EQ(extension_id, other->id());
  personal_ready.set_extension_id(extension_id);
  ASSERT_TRUE(personal_ready.WaitUntilSatisfied());
  WriteMarks(work, extension_id, "work-local", "work-session");
  WriteMarks(personal, extension_id, "personal-local", "personal-session");
  const std::string has_tabs = R"(
    chrome.permissions.contains({permissions: ['tabs']}).then(
      value => chrome.test.sendScriptResult(value),
      error => chrome.test.sendScriptResult({error: String(error)}));
  )";
  const std::string has_bookmarks = R"(
    chrome.permissions.contains({permissions: ['bookmarks']}).then(
      value => chrome.test.sendScriptResult(value),
      error => chrome.test.sendScriptResult({error: String(error)}));
  )";
  EXPECT_EQ(base::Value(false), Worker(work, extension_id, has_tabs));
  EXPECT_EQ(base::Value(false), Worker(personal, extension_id, has_tabs));
  EXPECT_EQ(base::Value(false), Worker(work, extension_id, has_bookmarks));
  EXPECT_EQ(base::Value(false), Worker(personal, extension_id, has_bookmarks));
  const std::string request_tabs = R"(
    chrome.test.runWithUserGesture(() => {
      chrome.permissions.request({permissions: ['tabs']}).then(
        value => chrome.test.sendScriptResult(value),
        error => chrome.test.sendScriptResult({error: String(error)}));
    });
  )";
  ASSERT_EQ(1, barc_window_select(personal_id));
  {
    int created = 0;
    views::AnyWidgetObserver observed(views::test::AnyWidgetTestPasskey{});
    observed.set_initialized_callback(
        base::BindLambdaForTesting([&](views::Widget*) { ++created; }));
    EXPECT_EQ(base::Value(false), Worker(work, extension_id, request_tabs));
    EXPECT_EQ(0, created);
  }
  EXPECT_TRUE(personal_window->IsSelectedForNativeWindow());
  EXPECT_EQ(base::Value(false), Worker(work, extension_id, has_tabs));
  EXPECT_EQ(base::Value(false), Worker(personal, extension_id, has_tabs));

  ASSERT_EQ(1, barc_window_select(work_id));
  // Wake without assuming MV3 globals survive an arbitrary idle interval.
  ASSERT_NO_FATAL_FAILURE(
      ExpectMarks(ReadState(work, extension_id), "work-local", "work-session"));
  {
    base::WeakPtr<views::Widget> consent;
    views::AnyWidgetObserver observed(views::test::AnyWidgetTestPasskey{});
    observed.set_shown_callback(
        base::BindLambdaForTesting([&](views::Widget* widget) {
          if (!widget->widget_delegate())
            return;
          if (views::AsViewClass<ExtensionInstallDialogView>(
                  widget->widget_delegate()->GetContentsView()))
            consent = widget->GetWeakPtr();
        }));
    extensions::BackgroundScriptExecutor request(work);
    ASSERT_TRUE(
        request.ExecuteScriptAsync(extension_id, request_tabs,
                                   extensions::BackgroundScriptExecutor::
                                       ResultCapture::kSendScriptResult));
    ASSERT_TRUE(base::test::RunUntil([&] {
      if (!consent || !consent->IsVisible())
        return false;
      auto* dialog = views::AsViewClass<ExtensionInstallDialogView>(
          consent->widget_delegate()->GetContentsView());
      return dialog &&
             dialog->IsDialogButtonEnabled(ui::mojom::DialogButton::kOk);
    }));
    auto* dialog = views::AsViewClass<ExtensionInstallDialogView>(
        consent->widget_delegate()->GetContentsView());
    ASSERT_TRUE(dialog);
    EXPECT_EQ(work_window,
              dialog->GetShowParamsForTesting()->GetBrowserOwner());
    EXPECT_EQ(nullptr,
              dialog->GetShowParamsForTesting()->GetParentWebContents());
    EXPECT_TRUE(work_window->IsSelectedForNativeWindow());
    // Actual dialog acceptance after its normal guard, not auto-confirm. This
    // checks mechanical permission routing, not native input/CWS qualification.
    consent->widget_delegate()->AsDialogDelegate()->AcceptDialog();
    EXPECT_EQ(base::Value(true), request.WaitForResult());
    ASSERT_TRUE(base::test::RunUntil([&] { return !consent; }));
  }
  EXPECT_EQ(base::Value(true), Worker(work, extension_id, has_tabs));
  EXPECT_EQ(base::Value(false), Worker(personal, extension_id, has_tabs));
  EXPECT_EQ(base::Value(false), Worker(work, extension_id, has_bookmarks));

  // A tab sender must beat the existing same-profile current-window selector.
  // Peer is selected, while the original Work browser and source tab remain
  // alive: a factory that loses the TabInterface would wrongly prompt in Peer.
  const int32_t source_tab = barc_tab_create(
      work_id, extension->url().Resolve("request.html").spec().c_str(), 1);
  ASSERT_NE(0, source_tab);
  auto* contents = tabs::TabHandle(source_tab).Get()->GetContents();
  ASSERT_TRUE(content::WaitForLoadStop(contents));
  ASSERT_EQ(work, contents->GetBrowserContext());
  ASSERT_EQ(work_window,
            tabs::TabHandle(source_tab).Get()->GetBrowserWindowInterface());
  OpenResult peer_result;
  barc_profile_open_in_native_window(work_id, kWork, BARC_PROFILE_SETTINGS,
                                     Opened, &peer_result);
  ASSERT_EQ(BARC_PROFILE_OK, peer_result.Get<0>());
  const int32_t peer_id = peer_result.Get<1>();
  ASSERT_EQ(work, Window(peer_id)->GetProfile());
  ASSERT_EQ(
      WidgetFor(work_window),
      WidgetFor(Window(peer_id)));
  ASSERT_EQ(1, barc_window_select(peer_id));
  ASSERT_FALSE(work_window->IsSelectedForNativeWindow());
  ASSERT_TRUE(Window(peer_id)->IsSelectedForNativeWindow());
  ASSERT_FALSE(work_window->IsDeleteScheduled());
  {
    int created = 0;
    views::AnyWidgetObserver observed(views::test::AnyWidgetTestPasskey{});
    observed.set_initialized_callback(
        base::BindLambdaForTesting([&](views::Widget*) { ++created; }));
    EXPECT_EQ(false, content::EvalJs(contents, R"(
      new Promise(resolve => {
        chrome.test.runWithUserGesture(() => {
          chrome.permissions.request({permissions: ['bookmarks']}).then(
            resolve, error => resolve({error: String(error)}));
        });
      });
    )"));
    EXPECT_EQ(0, created);
  }
  EXPECT_TRUE(Window(peer_id)->IsSelectedForNativeWindow());
  EXPECT_FALSE(work_window->IsDeleteScheduled());
  EXPECT_EQ(work_window,
            tabs::TabHandle(source_tab).Get()->GetBrowserWindowInterface());
  EXPECT_EQ(base::Value(true), Worker(work, extension_id, has_tabs));
  EXPECT_EQ(base::Value(false), Worker(work, extension_id, has_bookmarks));
  EXPECT_EQ(base::Value(false), Worker(personal, extension_id, has_tabs));
  EXPECT_EQ(base::Value(false), Worker(personal, extension_id, has_bookmarks));
  ASSERT_NO_FATAL_FAILURE(
      ExpectMarks(ReadState(work, extension_id), "work-local", "work-session"));
  ASSERT_NO_FATAL_FAILURE(ExpectMarks(ReadState(personal, extension_id),
                                      "personal-local", "personal-session"));
}

IN_PROC_BROWSER_TEST_F(BarcExtensionStorageBrowserTest,
                       NativePortsAndOriginChecksRemainInstallationScoped) {
  int32_t work_id = 0;
  int32_t personal_id = 0;
  ASSERT_NO_FATAL_FAILURE(OpenProfiles(work_id, personal_id));
  auto* work_window = Window(work_id);
  auto* personal_window = Window(personal_id);
  auto* work = work_window->GetProfile();
  auto* personal = personal_window->GetProfile();
  extensions::TestExtensionDir dir;
  dir.WriteManifest(R"({"manifest_version":3,"name":"Barc native ports",
    "version":"1.0","permissions":["storage","nativeMessaging"],
    "background":{"service_worker":"worker.js"}})");
  dir.WriteFile(FILE_PATH_LITERAL("worker.js"), R"(
    globalThis.workerInstance = crypto.randomUUID();
    globalThis.nativePort = null;
    globalThis.nativePending = null;
    globalThis.openNative = () => {
      const port = chrome.runtime.connectNative('com.barc.g1.echo');
      nativePort = port;
      port.onMessage.addListener(message => {
        if (nativePort !== port || !nativePending)
          throw new Error('Unexpected native response');
        const pending = nativePending;
        nativePending = null;
        pending.resolve(message);
      });
      port.onDisconnect.addListener(() => {
        const error = chrome.runtime.lastError?.message ?? 'Native port closed';
        if (nativePort === port && nativePending) {
          const pending = nativePending;
          nativePending = null;
          pending.reject(new Error(error));
        }
      });
      return true;
    };
    globalThis.echoNative = value => new Promise((resolve, reject) => {
      if (nativePending)
        throw new Error('Overlapping fixture request');
      nativePending = {resolve, reject};
      try { nativePort.postMessage(value); }
      catch (error) { nativePending = null; reject(error); }
    });
    globalThis.denyNative = () => new Promise(resolve => {
      const denied = chrome.runtime.connectNative('com.barc.g1.denied');
      denied.onDisconnect.addListener(() => {
        resolve(chrome.runtime.lastError?.message ?? 'Missing denied-origin error');
      });
      denied.onMessage.addListener(() => {
        denied.disconnect();
        resolve('Unexpected response from forbidden host');
      });
      denied.postMessage({profile: 'forbidden-origin-probe'});
    });
    chrome.test.sendMessage('native-worker-ready');
  )");
  ExtensionTestMessageListener work_ready("native-worker-ready");
  work_ready.set_browser_context(work);
  ExtensionTestMessageListener personal_ready("native-worker-ready");
  personal_ready.set_browser_context(personal);
  extensions::ChromeTestExtensionLoader work_loader(work);
  auto extension = work_loader.LoadExtension(dir.UnpackedPath());
  ASSERT_TRUE(extension);
  const std::string extension_id = extension->id();
  work_ready.set_extension_id(extension_id);
  ASSERT_TRUE(work_ready.WaitUntilSatisfied());
  extensions::ChromeTestExtensionLoader personal_loader(personal);
  auto other = personal_loader.LoadExtension(dir.UnpackedPath());
  ASSERT_TRUE(other);
  ASSERT_EQ(extension_id, other->id());
  personal_ready.set_extension_id(extension_id);
  ASSERT_TRUE(personal_ready.WaitUntilSatisfied());

  ASSERT_NO_FATAL_FAILURE(native_host_.RegisterTestHost(/*user_level=*/true));
  {
    base::ScopedAllowBlockingForTesting allow_io;
    // No real user/system NativeMessagingHosts directory is searched.
    native_system_path_ = std::make_unique<base::ScopedPathOverride>(
        chrome::DIR_NATIVE_MESSAGING, native_host_.temp_dir());
    const std::string forbidden_origin =
        "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/";
    ASSERT_NE(forbidden_origin, extension->url().spec());
    const std::array<std::pair<const char*, std::string>, 2> hosts{{
        {"com.barc.g1.echo", extension->url().spec()},
        {"com.barc.g1.denied", forbidden_origin},
    }};
    for (const auto& [name, origin] : hosts) {
      auto manifest =
          base::DictValue()
              .Set("name", name)
              .Set("description", "Isolated Barc native-port regression")
              .Set("type", "stdio")
              .Set("path", native_host_.temp_dir()
                               .AppendASCII("echo.py")
                               .AsUTF8Unsafe())
              .Set("allowed_origins", base::ListValue().Append(origin));
      JSONFileValueSerializer serializer(
          native_host_.temp_dir().AppendASCII(std::string(name) + ".json"));
      ASSERT_TRUE(serializer.Serialize(manifest));
    }
  }
  auto* work_messages = extensions::MessageService::Get(work);
  auto* personal_messages = extensions::MessageService::Get(personal);
  ASSERT_TRUE(work_messages);
  ASSERT_TRUE(personal_messages);
  ASSERT_NE(work_messages, personal_messages);
  const size_t work_baseline = work_messages->GetChannelCountForTest();
  const size_t personal_baseline = personal_messages->GetChannelCountForTest();
  const auto expect_channels = [&](size_t work_native, size_t personal_native) {
    ASSERT_TRUE(base::test::RunUntil([&] {
      return work_messages->GetChannelCountForTest() ==
                 work_baseline + work_native &&
             personal_messages->GetChannelCountForTest() ==
                 personal_baseline + personal_native;
    }));
  };
  ASSERT_EQ(1, barc_window_select(personal_id));
  EXPECT_EQ(base::Value(true), Worker(work, extension_id,
      "chrome.test.sendScriptResult(openNative());"));
  EXPECT_EQ(base::Value(true), Worker(personal, extension_id,
      "chrome.test.sendScriptResult(openNative());"));
  const auto echo = [&](Profile* profile, const char* marker, int round,
                        int expected_process_sequence) {
    auto response = Worker(profile, extension_id, content::JsReplace(R"(
      echoNative({profile: $1, round: $2}).then(
        message => chrome.test.sendScriptResult(message),
        error => chrome.test.sendScriptResult({error: String(error)}));
    )", marker, round));
    ASSERT_TRUE(response.is_dict()) << response;
    const auto& object = response.GetDict();
    EXPECT_EQ(expected_process_sequence, object.FindInt("id")) << response;
    const auto* payload = object.FindDict("echo");
    ASSERT_TRUE(payload) << response;
    ASSERT_NE(nullptr, payload->FindString("profile")) << response;
    EXPECT_EQ(marker, *payload->FindString("profile"));
    EXPECT_EQ(round, payload->FindInt("round"));
    ASSERT_NE(nullptr, object.FindString("caller_url")) << response;
    EXPECT_EQ(extension->url().spec(), *object.FindString("caller_url"));
  };
  // Independent subprocess counters both begin at one; later traffic must keep
  // Personal's same long-lived port/counter after Work disconnects/unloads.
  ASSERT_NO_FATAL_FAILURE(echo(work, kWork, 1, 1));
  ASSERT_NO_FATAL_FAILURE(echo(personal, kPersonal, 1, 1));
  ASSERT_NO_FATAL_FAILURE(expect_channels(1, 1));
  const std::string denied = R"(
    denyNative().then(error => chrome.test.sendScriptResult(error),
      error => chrome.test.sendScriptResult({error: String(error)}));
  )";
  EXPECT_EQ(base::Value(extensions::NativeMessageHost::kForbiddenError),
            Worker(work, extension_id, denied));
  EXPECT_EQ(base::Value(extensions::NativeMessageHost::kForbiddenError),
            Worker(personal, extension_id, denied));
  ASSERT_NO_FATAL_FAILURE(echo(work, kWork, 2, 2));
  ASSERT_NO_FATAL_FAILURE(echo(personal, kPersonal, 2, 2));
  ASSERT_NO_FATAL_FAILURE(expect_channels(1, 1));

  const std::string disconnect = R"(
    nativePort.disconnect();
    try {
      nativePort.postMessage({unexpected: true});
      chrome.test.sendScriptResult('Disconnected port accepted a message');
    } catch (error) {
      chrome.test.sendScriptResult(String(error).includes('disconnected port'));
    }
  )";
  EXPECT_EQ(base::Value(true), Worker(work, extension_id, disconnect));
  ASSERT_NO_FATAL_FAILURE(expect_channels(0, 1));
  ASSERT_NO_FATAL_FAILURE(echo(personal, kPersonal, 3, 3));
  EXPECT_EQ(base::Value(true), Worker(work, extension_id,
      "chrome.test.sendScriptResult(openNative());"));
  ASSERT_NO_FATAL_FAILURE(echo(work, kWork, 3, 1));
  ASSERT_NO_FATAL_FAILURE(expect_channels(1, 1));
  auto* work_registry = extensions::ExtensionRegistry::Get(work);
  auto* personal_registry = extensions::ExtensionRegistry::Get(personal);
  extensions::TestExtensionRegistryObserver unloaded(work_registry, extension_id);
  extensions::ExtensionRegistrar::Get(work)->DisableExtension(
      extension_id, {extensions::disable_reason::DISABLE_USER_ACTION});
  ASSERT_TRUE(unloaded.WaitForExtensionUnloaded());
  ASSERT_NO_FATAL_FAILURE(expect_channels(0, 1));
  EXPECT_TRUE(work_registry->disabled_extensions().Contains(extension_id));
  EXPECT_TRUE(personal_registry->enabled_extensions().Contains(extension_id));
  ASSERT_NO_FATAL_FAILURE(echo(personal, kPersonal, 4, 4));

  ExtensionTestMessageListener work_restarted("native-worker-ready");
  work_restarted.set_browser_context(work);
  work_restarted.set_extension_id(extension_id);
  extensions::ExtensionRegistrar::Get(work)->EnableExtension(extension_id);
  ASSERT_TRUE(work_restarted.WaitUntilSatisfied());
  EXPECT_EQ(base::Value(true), Worker(work, extension_id,
      "chrome.test.sendScriptResult(openNative());"));
  ASSERT_NO_FATAL_FAILURE(echo(work, kWork, 4, 1));
  ASSERT_NO_FATAL_FAILURE(echo(personal, kPersonal, 5, 5));
  ASSERT_NO_FATAL_FAILURE(expect_channels(1, 1));
  EXPECT_TRUE(personal_window->IsSelectedForNativeWindow());
  EXPECT_EQ(base::Value(true), Worker(work, extension_id, disconnect));
  EXPECT_EQ(base::Value(true), Worker(personal, extension_id, disconnect));
  ASSERT_NO_FATAL_FAILURE(expect_channels(0, 0));
}
