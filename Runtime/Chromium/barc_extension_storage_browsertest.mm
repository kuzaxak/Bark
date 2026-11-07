// Synthetic routing/storage/consent mechanics. Test-assisted CRX updates do
// not qualify ordinary install/update or Chrome Web Store flows.
#include "chrome/browser/ui/views/frame/barc_bridge.h"
#include "chrome/browser/ui/views/frame/barc_profiles.h"

#include <array>
#include <optional>
#include <string>

#include "base/command_line.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "base/values.h"
#include "chrome/browser/extensions/chrome_test_extension_loader.h"
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/extensions/extension_install_prompt_show_params.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/extensions/extension_install_dialog_view.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "components/sessions/core/session_id.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "extensions/browser/api/management/management_api_constants.h"
#include "extensions/browser/background_script_executor.h"
#include "extensions/browser/browsertest_util.h"
#include "extensions/browser/crx_installer.h"
#include "extensions/browser/extension_dialog_auto_confirm.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/install/crx_install_error.h"
#include "extensions/browser/process_manager.h"
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
  const auto widget_alive = BrowserView::GetBrowserViewForBrowser(work_window)
                                ->GetWidget()
                                ->GetWeakPtr();
  const auto owner_alive = work_window->GetWeakPtr();
  EXPECT_EQ(1, barc_window_close(work_id));
  EXPECT_EQ(ExtensionInstallPrompt::Result::USER_CANCELED, closed.Get().result);
  ASSERT_TRUE(base::test::RunUntil([&] { return !consent && !owner_alive; }));
  ASSERT_TRUE(widget_alive);
  ASSERT_TRUE(Window(personal_id));
  ASSERT_TRUE(Window(peer_id));
  EXPECT_EQ(
      widget_alive.get(),
      BrowserView::GetBrowserViewForBrowser(Window(personal_id))->GetWidget());
  EXPECT_EQ(
      widget_alive.get(),
      BrowserView::GetBrowserViewForBrowser(Window(peer_id))->GetWidget());
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
      BrowserView::GetBrowserViewForBrowser(work_window)->GetWidget(),
      BrowserView::GetBrowserViewForBrowser(Window(peer_id))->GetWidget());
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
