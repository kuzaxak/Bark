#include "bark/bridge/barc_bridge.h"
#include "bark/bridge/barc_profiles.h"

#include <utility>

#include "base/command_line.h"
#include "base/functional/callback_helpers.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "base/values.h"
#include "chrome/browser/extensions/extension_disabled_ui.h"
#include "chrome/browser/extensions/extension_uninstall_dialog.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_manager_service.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/extensions/extension_installed_watcher.h"
#include "chrome/browser/ui/extensions/extension_post_install_dialog.h"
#include "chrome/browser/ui/global_error/global_error.h"
#include "chrome/browser/ui/global_error/global_error_bubble_view_base.h"
#include "chrome/browser/ui/global_error/global_error_service.h"
#include "chrome/browser/ui/global_error/global_error_service_factory.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/extensions/extensions_container_views.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/toolbar_button_provider.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "components/sessions/core/session_id.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/test_utils.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_dialog_auto_confirm.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/common/extension_builder.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/test/widget_test.h"
#include "ui/views/widget/widget_delegate.h"

namespace {
using Result = base::test::TestFuture<barc_profile_status, int32_t>;
void Opened(barc_profile_status status, int32_t id, void* data) {
  static_cast<Result*>(data)->SetValue(status, id);
}
BrowserWindowInterface* Window(int32_t id) {
  return GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
      SessionID::FromSerializedValue(id));
}
class Cancellation : public extensions::ExtensionUninstallDialog::Delegate {
 public:
  void OnExtensionUninstallDialogClosed(bool started,
                                        const std::u16string&) override {
    ++calls;
    EXPECT_EQ(1, calls);
    result.SetValue(started);
  }
  int calls = 0;
  base::test::TestFuture<bool> result;
};
}  // namespace

class BarcExtensionDialogBrowserTest : public InProcessBrowserTest {
 public:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    InProcessBrowserTest::SetUpCommandLine(command_line);
    command_line->AppendSwitch("barc-shared-native-window");
  }

 protected:
  void OpenPair(int32_t& work_id,
                int32_t& personal_id,
                barc_profile_destination destination = BARC_PROFILE_SETTINGS) {
    Result first;
    barc_profile_open_window("057ae26c-6119-4bd8-8c51-04a22edc5a7e",
                             destination, Opened, &first);
    ASSERT_EQ(BARC_PROFILE_OK, first.Get<0>());
    work_id = first.Get<1>();
    Result second;
    barc_profile_open_in_native_window(work_id,
                                       "c4eda6be-411a-4d70-80f7-1317e2802463",
                                       destination, Opened, &second);
    ASSERT_EQ(BARC_PROFILE_OK, second.Get<0>());
    personal_id = second.Get<1>();
    auto* work = Window(work_id);
    auto* personal = Window(personal_id);
    ASSERT_TRUE(work);
    ASSERT_TRUE(personal);
    ASSERT_NE(work->GetProfile(), personal->GetProfile());
    ASSERT_EQ(BrowserView::GetBrowserViewForBrowser(work)->GetWidget(),
              BrowserView::GetBrowserViewForBrowser(personal)->GetWidget());
  }
  void CheckCancellation(bool destroy_owner) {
    int32_t work_id = 0;
    int32_t personal_id = 0;
    // Settings pages register pagehide listeners as their scripts load, and
    // Chromium closes a page with unload-time listeners asynchronously.
    ASSERT_NO_FATAL_FAILURE(OpenPair(work_id, personal_id, BARC_PROFILE_BLANK));
    auto* work = Window(work_id);
    auto* personal = Window(personal_id);
    ASSERT_TRUE(work);
    ASSERT_TRUE(personal);
    ASSERT_NE(work->GetProfile(), personal->GetProfile());
    ASSERT_EQ(BrowserView::GetBrowserViewForBrowser(work)->GetWidget(),
              BrowserView::GetBrowserViewForBrowser(personal)->GetWidget());
    ASSERT_EQ(1, barc_window_select(work_id));
    auto extension = extensions::ExtensionBuilder("Delayed uninstall").Build();
    extensions::ExtensionRegistrar::Get(work->GetProfile())
        ->AddExtension(extension.get());
    Cancellation canceled;
    auto dialog = extensions::ExtensionUninstallDialog::CreateForBrowser(
        work->GetProfile(), work, &canceled);
    bool icon_ready_hook = false;
    auto hook = base::BindLambdaForTesting([&] {
      icon_ready_hook = true;
      if (destroy_owner) {
        // The existing hook runs at icon delivery, before presentation. Keep
        // the shared physical Widget alive while destroying its logical owner.
        auto owner_alive = work->GetWeakPtr();
        auto host_alive = BrowserView::GetBrowserViewForBrowser(work)
                              ->GetWidget()
                              ->GetWeakPtr();
        ASSERT_FALSE(work->GetTabStripModel()->GetActiveWebContents()
                         ->NeedToFireBeforeUnloadOrUnloadEvents());
        ASSERT_EQ(1, barc_window_close(work_id));
        ASSERT_TRUE(owner_alive);
        ASSERT_TRUE(owner_alive->IsDeleteScheduled());
        ASSERT_TRUE(owner_alive->GetTabStripModel()->empty());
        // Finish the already-admitted deletion without nesting a RunLoop in
        // the icon task. Its posted deletion holds a weak pointer as well.
        BrowserManagerService::SynchronouslyDestroyBrowser(owner_alive.get());
        EXPECT_FALSE(owner_alive);
        ASSERT_TRUE(host_alive);
        ASSERT_TRUE(Window(personal_id));
        EXPECT_EQ(host_alive.get(),
                  BrowserView::GetBrowserViewForBrowser(Window(personal_id))
                      ->GetWidget());
      }
    });
    extensions::ExtensionUninstallDialog::SetOnShownCallbackForTesting(&hook);
    base::ScopedClosureRunner reset_hook(base::BindLambdaForTesting([] {
      extensions::ExtensionUninstallDialog::SetOnShownCallbackForTesting(
          nullptr);
    }));
    dialog->ConfirmUninstall(extension,
                             extensions::UNINSTALL_REASON_FOR_TESTING,
                             extensions::UNINSTALL_SOURCE_FOR_TESTING);
    ASSERT_FALSE(icon_ready_hook);
    ASSERT_FALSE(canceled.result.IsReady());
    if (!destroy_owner) {
      // Switch before the asynchronously delivered icon can present the UI.
      ASSERT_EQ(1, barc_window_select(personal_id));
    }
    EXPECT_FALSE(canceled.result.Get());
    EXPECT_EQ(1, canceled.calls);
    EXPECT_EQ(destroy_owner, icon_ready_hook);
    ASSERT_TRUE(Window(personal_id));
    if (!destroy_owner) {
      EXPECT_TRUE(personal->IsSelectedForNativeWindow());
      EXPECT_TRUE(extensions::ExtensionRegistry::Get(work->GetProfile())
                      ->enabled_extensions()
                      .Contains(extension->id()));
    } else {
      EXPECT_EQ(nullptr, Window(work_id));
    }
  }
  void CheckSelectedPresentation() {
    int32_t work_id = 0;
    int32_t personal_id = 0;
    ASSERT_NO_FATAL_FAILURE(OpenPair(work_id, personal_id));
    auto* work = Window(work_id);
    auto* personal = Window(personal_id);
    ASSERT_TRUE(work);
    ASSERT_TRUE(personal);
    ASSERT_EQ(1, barc_window_select(work_id));
    auto extension = extensions::ExtensionBuilder("Selected uninstall")
                         .SetManifestKey("action", base::DictValue())
                         .Build();
    extensions::ExtensionRegistrar::Get(work->GetProfile())
        ->AddExtension(extension.get());
    content::RunAllTasksUntilIdle();
    auto* work_view = BrowserView::GetBrowserViewForBrowser(work);
    auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
    auto* container =
        work_view->toolbar_button_provider()->GetExtensionsContainerViews();
    ASSERT_TRUE(container);
    const auto old_widgets = views::test::WidgetTest::GetAllWidgets();
    Cancellation canceled;
    auto dialog = extensions::ExtensionUninstallDialog::CreateForBrowser(
        work->GetProfile(), work, &canceled);
    dialog->ConfirmUninstall(extension,
                             extensions::UNINSTALL_REASON_FOR_TESTING,
                             extensions::UNINSTALL_SOURCE_FOR_TESTING);
    views::Widget* prompt = nullptr;
    ASSERT_TRUE(base::test::RunUntil([&] {
      for (const auto& widget : views::test::WidgetTest::GetAllWidgets()) {
        if (!old_widgets.contains(widget) && widget->IsVisible() &&
            widget->widget_delegate()->AsBubbleDialogDelegate()) {
          prompt = widget.get();
          return true;
        }
      }
      return false;
    }));
    ASSERT_FALSE(canceled.result.IsReady());
    auto* bubble = prompt->widget_delegate()->AsBubbleDialogDelegate();
    auto* anchor = bubble->GetAnchorView();
    ASSERT_TRUE(anchor);
    EXPECT_TRUE(work_view->Contains(anchor));
    EXPECT_FALSE(personal_view->Contains(anchor));
    EXPECT_EQ(
        container->GetReferenceButtonForPopup(extension->id()).GetIfView(),
        anchor);
    // A presented owned prompt blocks profile switching. Logical-owner close
    // must cancel the prompt rather than permit a later stale acceptance.
    EXPECT_EQ(0, barc_window_select(personal_id));
    EXPECT_EQ(1, barc_window_close(work_id));
    EXPECT_FALSE(canceled.result.Get());
    EXPECT_EQ(1, canceled.calls);
  }

  void CheckDelayedPostInstallCancellation() {
    int32_t work_id = 0;
    int32_t personal_id = 0;
    ASSERT_NO_FATAL_FAILURE(OpenPair(work_id, personal_id));
    auto* work = Window(work_id);
    ASSERT_TRUE(work);
    ASSERT_EQ(1, barc_window_select(work_id));
    auto extension = extensions::ExtensionBuilder("Delayed install").Build();
    auto* profile = work->GetProfile();
    const auto owner = work->GetWeakPtr();
    const auto widgets = views::test::WidgetTest::GetAllWidgets();
    bool target_requested = false;
    bool iph_requested = false;
    ExtensionInstalledWatcher observed_install(profile);
    base::test::TestFuture<bool> installed;
    observed_install.WaitForInstall(extension->id(), installed.GetCallback());
    extensions::TriggerPostInstallDialog(
        profile, extension, SkBitmap(),
        base::BindLambdaForTesting([&]() -> content::WebContents* {
          target_requested = true;
          return work->GetTabStripModel()->GetActiveWebContents();
        }),
        base::BindLambdaForTesting(
            [&](base::WeakPtr<content::WebContents>) { iph_requested = true; }),
        owner);
    ASSERT_FALSE(installed.IsReady());
    ASSERT_EQ(1, barc_window_select(personal_id));
    extensions::ExtensionRegistrar::Get(profile)->AddExtension(extension.get());
    ASSERT_TRUE(installed.Get());
    content::RunAllTasksUntilIdle();
    EXPECT_FALSE(target_requested);
    EXPECT_FALSE(iph_requested);
    // Switching profiles can close existing transient UI, but the canceled
    // installation must not add a prompt to the newly selected profile.
    for (const auto& widget : views::test::WidgetTest::GetAllWidgets()) {
      EXPECT_TRUE(widgets.contains(widget));
    }
    EXPECT_TRUE(Window(personal_id)->IsSelectedForNativeWindow());
  }
};

IN_PROC_BROWSER_TEST_F(BarcExtensionDialogBrowserTest,
                       SwitchBeforeIconDeliveryCancelsOriginPrompt) {
  CheckCancellation(false);
}
IN_PROC_BROWSER_TEST_F(BarcExtensionDialogBrowserTest,
                       DestroyedLogicalOwnerCancelsBeforePresentation) {
  CheckCancellation(true);
}
IN_PROC_BROWSER_TEST_F(BarcExtensionDialogBrowserTest,
                       ClosingLogicalOwnerCancelsWhileItsPageUnloads) {
  int32_t work_id = 0;
  int32_t personal_id = 0;
  ASSERT_NO_FATAL_FAILURE(OpenPair(work_id, personal_id, BARC_PROFILE_BLANK));
  ASSERT_EQ(1, barc_window_select(work_id));
  auto* work = Window(work_id);
  auto* page = work->GetTabStripModel()->GetActiveWebContents();
  ASSERT_TRUE(content::ExecJs(page, "addEventListener('pagehide', () => {})"));
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return page->NeedToFireBeforeUnloadOrUnloadEvents(); }));
  auto extension = extensions::ExtensionBuilder("Closing owner").Build();
  extensions::ExtensionRegistrar::Get(work->GetProfile())
      ->AddExtension(extension.get());
  auto* registry = extensions::ExtensionRegistry::Get(work->GetProfile());
  Cancellation canceled;
  auto dialog = extensions::ExtensionUninstallDialog::CreateForBrowser(
      work->GetProfile(), work, &canceled);
  extensions::ScopedTestDialogAutoConfirm accept(
      extensions::ScopedTestDialogAutoConfirm::ACCEPT);
  bool owner_was_unloading = false;
  auto hook = base::BindLambdaForTesting([&] {
    ASSERT_EQ(1, barc_window_close(work_id));
    owner_was_unloading = Window(work_id) && !Window(work_id)->IsDeleteScheduled();
  });
  extensions::ExtensionUninstallDialog::SetOnShownCallbackForTesting(&hook);
  base::ScopedClosureRunner reset_hook(base::BindLambdaForTesting([] {
    extensions::ExtensionUninstallDialog::SetOnShownCallbackForTesting(nullptr);
  }));
  dialog->ConfirmUninstall(extension, extensions::UNINSTALL_REASON_FOR_TESTING,
                           extensions::UNINSTALL_SOURCE_FOR_TESTING);
  EXPECT_FALSE(canceled.result.Get());
  EXPECT_EQ(1, canceled.calls);
  EXPECT_TRUE(owner_was_unloading);
  EXPECT_TRUE(registry->enabled_extensions().Contains(extension->id()));
  dialog.reset();
  EXPECT_TRUE(base::test::RunUntil([&] { return !Window(work_id); }));
}

IN_PROC_BROWSER_TEST_F(BarcExtensionDialogBrowserTest,
                       SelectedPromptAnchorsToOwnerAndBlocksSwitch) {
  CheckSelectedPresentation();
}
IN_PROC_BROWSER_TEST_F(BarcExtensionDialogBrowserTest,
                       SwitchBeforeInstallNotificationCancelsPostInstall) {
  CheckDelayedPostInstallCancellation();
}

IN_PROC_BROWSER_TEST_F(BarcExtensionDialogBrowserTest,
                       OriginalProfileDisabledErrorAdmitsOTROwner) {
  int32_t work_id = 0;
  int32_t personal_id = 0;
  ASSERT_NO_FATAL_FAILURE(OpenPair(work_id, personal_id));
  auto* work = Window(work_id);
  auto* personal = Window(personal_id);
  auto* profile = work->GetProfile();
  auto* otr_profile = profile->GetPrimaryOTRProfile(true);
  BrowserWindowCreateParams params(otr_profile, true);
  params.native_window_owner = work->GetSessionID();
  auto* otr = CreateBrowserWindow(std::move(params));
  ASSERT_TRUE(otr);
  const int32_t otr_id = otr->GetSessionID().id();
  ASSERT_NE(0, barc_tab_create(otr_id, "about:blank", 1));
  ASSERT_EQ(1, barc_window_select(otr_id));
  auto* otr_view = BrowserView::GetBrowserViewForBrowser(otr);
  auto* personal_view = BrowserView::GetBrowserViewForBrowser(personal);
  ASSERT_EQ(otr_view->GetWidget(), personal_view->GetWidget());
  auto extension = extensions::ExtensionBuilder("Original profile disabled")
                       .SetManifestKey("action", base::DictValue())
                       .Build();
  auto* registrar = extensions::ExtensionRegistrar::Get(profile);
  registrar->AddExtension(extension.get());
  registrar->DisableExtension(extension->id(),
                             {extensions::disable_reason::DISABLE_USER_ACTION});
  content::RunAllTasksUntilIdle();
  auto* errors = GlobalErrorServiceFactory::GetForProfile(profile);
  ASSERT_EQ(errors, GlobalErrorServiceFactory::GetForProfile(otr_profile));
  const size_t old_error_count = errors->errors().size();
  extensions::AddExtensionDisabledError(profile, extension.get(), false);
  ASSERT_EQ(old_error_count + 1, errors->errors().size());
  // This exact newly added error is ExtensionDisabledGlobalError, derived from
  // GlobalErrorWithStandardBubble; exercise its real deferred cancel callback.
  auto* error = static_cast<GlobalErrorWithStandardBubble*>(
      errors->errors().back().get());
  error->ExecuteMenuItem(otr);
  ASSERT_TRUE(error->GetBubbleView());
  error->GetBubbleView()->CloseBubbleView();
  content::RunAllTasksUntilIdle();
  const auto old_widgets = views::test::WidgetTest::GetAllWidgets();
  error->BubbleViewCancelButtonPressed(otr);
  views::Widget* prompt = nullptr;
  ASSERT_TRUE(base::test::RunUntil([&] {
    for (const auto& widget : views::test::WidgetTest::GetAllWidgets()) {
      if (!old_widgets.contains(widget) && widget->IsVisible() &&
          widget->widget_delegate()->AsBubbleDialogDelegate()) {
        prompt = widget.get();
        return true;
      }
    }
    return false;
  }));
  auto* anchor = prompt->widget_delegate()->AsBubbleDialogDelegate()
                     ->GetAnchorView();
  ASSERT_TRUE(anchor);
  EXPECT_TRUE(otr_view->Contains(anchor));
  EXPECT_FALSE(personal_view->Contains(anchor));
  auto prompt_alive = prompt->GetWeakPtr();
  ui_test_utils::BrowserDestroyedObserver closed(otr);
  EXPECT_EQ(1, barc_window_close(otr_id));
  closed.Wait();
  EXPECT_TRUE(base::test::RunUntil([&] { return !prompt_alive; }));
  ASSERT_TRUE(Window(work_id));
  ASSERT_TRUE(Window(personal_id));
  EXPECT_TRUE(extensions::ExtensionRegistry::Get(profile)
                  ->disabled_extensions().Contains(extension->id()));
  EXPECT_FALSE(extensions::ExtensionRegistry::Get(personal->GetProfile())
                   ->GetInstalledExtension(extension->id()));
}
