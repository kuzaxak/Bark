// Unpacked MV3 routing/storage mechanics only; no signed-install or CWS claim.
#include "chrome/browser/ui/views/frame/barc_bridge.h"
#include "chrome/browser/ui/views/frame/barc_profiles.h"

#include <array>
#include <string>

#include "base/command_line.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "base/values.h"
#include "chrome/browser/extensions/chrome_test_extension_loader.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "components/sessions/core/session_id.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "extensions/browser/api/management/management_api_constants.h"
#include "extensions/browser/background_script_executor.h"
#include "extensions/browser/browsertest_util.h"
#include "extensions/browser/extension_dialog_auto_confirm.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/process_manager.h"
#include "extensions/common/error_utils.h"
#include "extensions/common/extension.h"
#include "extensions/test/extension_test_message_listener.h"
#include "extensions/test/test_extension_dir.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "ui/views/widget/any_widget_observer.h"
#include "url/gurl.h"

namespace {
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
    ASSERT_EQ(BrowserView::GetBrowserViewForBrowser(first)->GetWidget(),
              BrowserView::GetBrowserViewForBrowser(second)->GetWidget());
    std::array<char, 37> uuid{};
    EXPECT_EQ(uuid.size(),
              barc_window_profile_uuid(work_id, uuid.data(), uuid.size()));
    EXPECT_STREQ(kWork, uuid.data());
    EXPECT_EQ(uuid.size(),
              barc_window_profile_uuid(personal_id, uuid.data(), uuid.size()));
    EXPECT_STREQ(kPersonal, uuid.data());
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
};

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
