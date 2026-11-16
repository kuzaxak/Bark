#ifndef BARK_BROWSER_UI_BARK_BROWSER_WINDOW_H_
#define BARK_BROWSER_UI_BARK_BROWSER_WINDOW_H_

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/unload_controller.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/base/unowned_user_data/scoped_unowned_user_data.h"

namespace content {
class WebContents;
}  // namespace content

namespace autofill {
class AutofillBubbleHandlerImpl;
}  // namespace autofill

namespace views {
class Widget;
}  // namespace views

namespace bark {

class BarkExclusiveAccessContext;
class BarkFindBarOwner;
class BarkModalDialogHost;
class BarkSidePanelUI;
class BarkStubLocationBar;
class BarkToolbarButtonProvider;
class BarkWindowHost;

// The BrowserWindow of one Browser shown in a Bark window host. It builds no
// toolbar, tab strip, contents view or BrowserWidget: the app lays out the
// page views itself, in the host's root view.
class BarkBrowserWindow : public BrowserWindow,
                          public ui::AcceleratorProvider,
                          public TabStripModelObserver {
 public:
  DECLARE_USER_DATA(BarkBrowserWindow);
  static BarkBrowserWindow* FromBrowser(const BrowserWindowInterface* browser);

  // With `join`, the window is another client of that host.
  BarkBrowserWindow(BrowserWindowInterface* browser, BarkWindowHost* join);
  BarkBrowserWindow(const BarkBrowserWindow&) = delete;
  BarkBrowserWindow& operator=(const BarkBrowserWindow&) = delete;
  ~BarkBrowserWindow() override;

  BrowserWindowInterface* browser() const { return browser_.get(); }
  BarkWindowHost* host() const { return host_.get(); }
  base::WeakPtr<BarkBrowserWindow> GetWeakPtr() {
    return weak_factory_.GetWeakPtr();
  }

  // The rectangle the selected page view occupies, in screen coordinates.
  gfx::Rect GetPageBoundsInScreen() const;
  void OnHostActivationChanged(bool active);
  void OnHostBoundsChanged();
  void OnHostFullscreenChanged();

  // BrowserWindow:
  bool IsSelectedForNativeWindow() const override;
  gfx::NativeWindow GetNativeWindow() const override;
  bool IsOnCurrentWorkspace() const override;
  bool IsVisibleOnScreen() const override;
  void SetTopControlsShownRatio(content::WebContents* web_contents,
                                float ratio) override;
  bool DoBrowserControlsShrinkRendererSize(
      const content::WebContents* contents) const override;
  ui::NativeTheme* GetNativeTheme() override;
  const ui::ThemeProvider* GetThemeProvider() const override;
  const ui::ColorProvider* GetColorProvider() const override;
  int GetTopControlsHeight() const override;
  void SetTopControlsGestureScrollInProgress(bool in_progress) override;
  std::vector<StatusBubble*> GetStatusBubbles() override;
  void UpdateTitleBar() override;
  void UpdateLoadingAnimations(bool is_visible) override;
  void OnActiveTabChanged(content::WebContents* old_contents,
                          content::WebContents* new_contents,
                          int index,
                          int reason) override;
  void OnTabDetached(content::WebContents* contents, bool was_active) override;
  gfx::Size GetContentsSize() const override;
  void SetContentsSize(const gfx::Size& size) override;
  autofill::AutofillBubbleHandler* GetAutofillBubbleHandler() override;
  LocationBar* GetLocationBar() const override;
  ui::AcceleratorProvider* GetAcceleratorProvider() override;
  PinnedToolbarActions* GetPinnedToolbarActions() override;
  void SetFocusToLocationBar(bool is_user_initiated) override;
  void UpdateReloadStopState(bool is_loading, bool force) override;
  void UpdateToolbar(content::WebContents* contents) override;
  bool UpdateToolbarSecurityState() override;
  void UpdateCustomTabBarVisibility(bool visible, bool animate) override;
  void ResetToolbarTabState(content::WebContents* contents) override;
  void FocusToolbar() override;
  void ToolbarSizeChanged(bool is_animating) override;
  void TabDraggingStatusChanged(bool is_dragging) override;
  void LinkOpeningFromGesture(WindowOpenDisposition disposition) override;
  void FocusAppMenu() override;
  bool IsTabStripEditable() const override;
  void DisableTabStripEditingForTesting() override;
  bool IsToolbarVisible() const override;
  bool IsToolbarShowing() const override;
  bool IsLocationBarVisible() const override;
  void ShowUpdateChromeDialog() override;
  void ShowIntentPickerBubble(
      std::vector<apps::IntentPickerAppInfo> app_info,
      bool show_stay_in_chrome,
      bool show_remember_selection,
      apps::IntentPickerBubbleType bubble_type,
      const std::optional<url::Origin>& initiating_origin,
      IntentPickerResponse callback) override;
  void ShowBookmarkBubble(const GURL& url, bool already_bookmarked) override;
  ShowTranslateBubbleResult ShowTranslateBubble(
      content::WebContents* contents,
      translate::TranslateStep step,
      const std::string& source_language,
      const std::string& target_language,
      translate::TranslateErrors error_type,
      bool is_user_gesture) override;
  DownloadBubbleUIController* GetDownloadBubbleUIController() override;
  void ConfirmBrowserCloseWithPendingDownloads(
      int download_count,
      UnloadController::DownloadCloseType dialog_type,
      base::OnceCallback<void(bool)> callback) override;
  void ShowAppMenu() override;
  void PreHandleDragUpdate(const content::DropData& drop_data,
                           const gfx::PointF& point) override;
  void PreHandleDragExit() override;
  void HandleDragEnded() override;
  content::KeyboardEventProcessingResult PreHandleKeyboardEvent(
      const input::NativeWebKeyboardEvent& event) override;
  bool HandleKeyboardEvent(const input::NativeWebKeyboardEvent& event) override;
  std::unique_ptr<FindBar> CreateFindBar() override;
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHost()
      override;
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHostFor(
      content::WebContents* web_contents) override;
  void ShowAvatarBubbleFromAvatarButton(bool is_source_accelerator) override;
  void MaybeShowProfileSwitchIPH() override;
  void MaybeShowSupervisedUserProfileSignInIPH() override;
  void ShowHatsDialog(
      const std::string& site_id,
      const std::optional<std::string>& hats_histogram_name,
      const std::optional<uint64_t> hats_survey_ukm_id,
      base::OnceClosure success_callback,
      base::OnceClosure failure_callback,
      const SurveyBitsData& product_specific_bits_data,
      const SurveyStringData& product_specific_string_data) override;
  ExclusiveAccessContext* GetExclusiveAccessContext() override;
  std::string GetWorkspace() const override;
  bool IsVisibleOnAllWorkspaces() const override;
  void ShowEmojiPanel() override;
  std::unique_ptr<content::EyeDropper> OpenEyeDropper(
      content::RenderFrameHost* frame,
      content::EyeDropperListener* listener) override;
  void ShowCaretBrowsingDialog() override;
  void CreateTabSearchBubble() override;
  void CloseTabSearchBubble() override;
  void ShowIncognitoClearBrowsingDataDialog() override;
  void ShowIncognitoHistoryDisclaimerDialog() override;
  bool IsUnframedModeEnabled() const override;
  bool GetCanResize() override;
  ui::mojom::WindowShowState GetWindowShowState() const override;
  void ShowChromeLabs() override;
  BrowserView* AsBrowserView() override;

  // ui::BaseWindow:
  void Show() override;
  void ShowInactive() override;
  void Hide() override;
  bool IsVisible() const override;
  void SetBounds(const gfx::Rect& bounds) override;
  void Close() override;
  void Activate() override;
  void Deactivate() override;
  bool IsActive() const override;
  gfx::Rect GetBounds() const override;
  bool IsMaximized() const override;
  bool IsMinimized() const override;
  bool IsFullscreen() const override;
  gfx::Rect GetRestoredBounds() const override;
  ui::mojom::WindowShowState GetRestoredState() const override;
  void Maximize() override;
  void Minimize() override;
  void Restore() override;
  void FlashFrame(bool flash) override;
  ui::ZOrderLevel GetZOrderLevel() const override;
  void SetZOrderLevel(ui::ZOrderLevel order) override;

  void CancelPendingDownloadWarning() override;

  // ui::AcceleratorProvider:
  bool GetAcceleratorForCommandId(int command_id,
                                  ui::Accelerator* accelerator) const override;

  // TabStripModelObserver:
  void OnTabStripModelChanged(TabStripModel* tab_strip_model,
                              const TabStripModelChange& change,
                              const TabStripSelectionChange& selection) override;

 protected:
  // BrowserWindow:
  void DeleteBrowserWindow() final;

 private:
  class CrashWatcher;

  void EnsureActiveTabHasNonZeroSize();
  void WatchForCrash(content::WebContents* contents);
  void NotifyPageCrashed(content::WebContents* contents, bool crashed);

  const raw_ptr<BrowserWindowInterface> browser_;
  scoped_refptr<BarkWindowHost> host_;
  std::unique_ptr<BarkStubLocationBar> location_bar_;
  std::unique_ptr<BarkModalDialogHost> modal_dialog_host_;
  std::unique_ptr<BarkExclusiveAccessContext> exclusive_access_context_;
  std::unique_ptr<BarkFindBarOwner> find_bar_owner_;
  std::unique_ptr<BarkSidePanelUI> side_panel_ui_;
  std::unique_ptr<BarkToolbarButtonProvider> toolbar_button_provider_;
  std::unique_ptr<autofill::AutofillBubbleHandlerImpl> autofill_bubble_handler_;
  std::map<content::WebContents*, std::unique_ptr<CrashWatcher>>
      crash_watchers_;
  base::WeakPtr<views::Widget> pending_download_warning_;
  ui::ScopedUnownedUserData<BarkBrowserWindow> scoped_user_data_;
  base::WeakPtrFactory<BarkBrowserWindow> weak_factory_{this};
};

}  // namespace bark

#endif  // BARK_BROWSER_UI_BARK_BROWSER_WINDOW_H_
