#ifndef BARK_BROWSER_UI_BARK_WINDOW_PARTS_H_
#define BARK_BROWSER_UI_BARK_WINDOW_PARTS_H_

#include <memory>
#include <optional>
#include <string>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/callback_list.h"
#include "base/observer_list.h"
#include "base/task/cancelable_task_tracker.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_context.h"
#include "chrome/browser/ui/location_bar/location_bar.h"
#include "chrome/browser/ui/side_panel/side_panel_entry_id.h"
#include "chrome/browser/ui/side_panel/side_panel_entry_key.h"
#include "chrome/browser/ui/side_panel/side_panel_enums.h"
#include "chrome/browser/ui/side_panel/side_panel_ui.h"
#include "chrome/browser/ui/views/exclusive_access/exclusive_access_bubble_views_context.h"
#include "chrome/browser/ui/views/find_bar_owner.h"
#include "chrome/browser/ui/views/frame/toolbar_button_provider.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "ui/base/unowned_user_data/scoped_unowned_user_data.h"
#include "ui/gfx/geometry/rect.h"

class ExclusiveAccessBubbleViews;

namespace bark {

class BarkBrowserWindow;

// Each part answers for one BarkBrowserWindow, after its twin in
// chrome/browser/ui/webui_browser/.

// A side panel that never shows. Upstream features CHECK that a normal window
// has one, Read Anything on every active tab's detach.
class BarkSidePanelUI : public SidePanelUI {
 public:
  explicit BarkSidePanelUI(BrowserWindowInterface* browser);
  ~BarkSidePanelUI() override;

  void Show(SidePanelEntryId entry_id,
            std::optional<SidePanelOpenTrigger> open_trigger,
            bool suppress_animations) override;
  void Show(SidePanelEntryKey entry_key,
            std::optional<SidePanelOpenTrigger> open_trigger,
            bool suppress_animations) override;
  void ShowFrom(SidePanelEntryKey entry_key,
                gfx::Rect starting_bounds_in_browser_coordinates) override;
  void Close(SidePanelEntryHideReason hide_reason,
             bool suppress_animations) override;
  void Toggle(SidePanelEntryKey key,
              SidePanelOpenTrigger open_trigger) override;
  std::optional<SidePanelEntryId> GetCurrentEntryId() const override;
  int GetCurrentEntryDefaultContentWidth() const override;
  bool IsSidePanelShowing() const override;
  bool IsSidePanelEntryShowing(
      const SidePanelEntryKey& entry_key) const override;
  bool IsSidePanelEntryShowing(const SidePanelEntryKey& entry_key,
                               bool for_tab) const override;
  base::CallbackListSubscription RegisterSidePanelShown(
      ShownCallback callback) override;
  void OnActiveTabChanged(content::WebContents* old_contents,
                          content::WebContents* new_contents,
                          bool tab_removed_for_deletion) override;
  content::WebContents* GetWebContentsForTest(SidePanelEntryId id) override;
  void DisableAnimationsForTesting() override;
  void SetNoDelaysForTesting(bool no_delays_for_testing) override;

 private:
  base::RepeatingClosureList shown_callbacks_;
  ui::ScopedUnownedUserData<SidePanelUI> scoped_user_data_;
};

class BarkStubLocationBar : public LocationBar {
 public:
  explicit BarkStubLocationBar(BarkBrowserWindow* window);
  ~BarkStubLocationBar() override;

  void FocusLocation(bool is_user_initiated,
                     bool clear_focus_if_failed) override;
  void FocusSearch() override;
  void UpdateFocusBehavior(bool toolbar_visible) override;
  void UpdateContentSettingsIcons() override;
  void SaveStateToContents(content::WebContents* contents) override;
  void Revert() override;
  OmniboxView* GetOmniboxView() override;
  OmniboxPopupView* GetOmniboxPopupView() override;
  OmniboxController* GetOmniboxController() override;
  bool ShouldCloseOmniboxPopup(ui::MouseEvent* event) override;
  content::WebContents* GetWebContents() override;
  LocationBarModel* GetLocationBarModel() override;
  std::optional<bubble_anchor_util::AnchorConfiguration> GetChipAnchor()
      override;
  ChipController* GetChipController() override;
  void AnnounceAlert(const std::u16string& announcement) override;
  void OnChanged() override;
  void UpdateWithoutTabRestore() override;
  ui::TrackedElement* GetAnchorOrNull() override;
  BrowserWindowInterface* GetBrowser() override;
  Profile* GetProfile() override;
  bool IsInitialized() const override;
  bool IsVisible() const override;
  bool IsDrawn() const override;
  bool IsFullscreen() const override;
  bool IsEditingOrEmpty() const override;
  bool IsMouseHovered() const override;
  bool IsFocusWithin() const override;
  void InvalidateLayout() override;
  gfx::Rect Bounds() const override;
  gfx::Rect BoundsInScreen() const override;
  gfx::Size MinimumSize() const override;
  gfx::Size PreferredSize() const override;
  void Update(content::WebContents* contents) override;
  void ResetTabState(content::WebContents* contents) override;
  bool HasSecurityStateChanged() override;
  LocationBarTesting* GetLocationBarForTesting() override;

 private:
  const raw_ptr<BarkBrowserWindow> window_;
};

// Places tab-modal dialogs over the selected page view.
class BarkModalDialogHost : public web_modal::WebContentsModalDialogHost {
 public:
  explicit BarkModalDialogHost(BarkBrowserWindow* window);
  ~BarkModalDialogHost() override;

  void NotifyPositionRequiresUpdate() override;
  gfx::NativeView GetHostView() const override;
  gfx::Point GetDialogPosition(const gfx::Size& size) override;
  bool ShouldActivateDialog() const override;
  gfx::Size GetMaximumDialogSize() override;
  void AddObserver(web_modal::ModalDialogHostObserver* observer) override;
  void RemoveObserver(web_modal::ModalDialogHostObserver* observer) override;

 private:
  gfx::Rect PageBoundsInWindow() const;
  gfx::Rect DialogAreaInWindow() const;

  const raw_ptr<BarkBrowserWindow> window_;
  base::ObserverList<web_modal::ModalDialogHostObserver> observers_;
};

class BarkExclusiveAccessContext : public ExclusiveAccessContext,
                                   public ExclusiveAccessBubbleViewsContext {
 public:
  explicit BarkExclusiveAccessContext(BarkBrowserWindow* window);
  ~BarkExclusiveAccessContext() override;

  // ExclusiveAccessContext:
  Profile* GetProfile() override;
  void EnterFullscreen(const url::Origin& origin,
                       ExclusiveAccessBubbleType bubble_type,
                       FullscreenTabParams fullscreen_tab_params) override;
  void ExitFullscreen() override;
  void UpdateExclusiveAccessBubble(
      const ExclusiveAccessBubbleParams& params,
      ExclusiveAccessBubbleHideCallback first_hide_callback) override;
  bool IsExclusiveAccessBubbleDisplayed() const override;
  void OnExclusiveAccessUserInput() override;
  content::WebContents* GetWebContentsForExclusiveAccess() override;
  bool CanUserEnterFullscreen() const override;
  bool CanUserExitFullscreen() const override;
  bool IsFullscreen() const override;

  // ExclusiveAccessBubbleViewsContext:
  ExclusiveAccessManager* GetExclusiveAccessManager() override;
  ui::AcceleratorProvider* GetAcceleratorProvider() override;
  gfx::NativeView GetBubbleParentView() const override;
  gfx::Rect GetClientAreaBoundsInScreen() const override;
  bool IsImmersiveModeEnabled() const override;
  gfx::Rect GetTopContainerBoundsInScreen() override;
  void DestroyAnyExclusiveAccessBubble() override;

 private:
  void UpdateBubble(const ExclusiveAccessBubbleParams& params,
                    ExclusiveAccessBubbleHideCallback first_hide_callback);

  const raw_ptr<BarkBrowserWindow> window_;
  std::unique_ptr<ExclusiveAccessBubbleViews> bubble_;
  std::optional<base::CancelableTaskTracker::TaskId> bubble_destruction_task_;
  base::CancelableTaskTracker bubble_tasks_;
  base::WeakPtrFactory<BarkExclusiveAccessContext> weak_factory_{this};
};

// Answers bubbles that would hang off a toolbar with the page's trailing
// anchor; a host window has no toolbar object to return.
class BarkToolbarButtonProvider : public ToolbarButtonProvider {
 public:
  explicit BarkToolbarButtonProvider(BarkBrowserWindow* window);
  ~BarkToolbarButtonProvider() override;

  ExtensionsContainerViews* GetExtensionsContainerViews() override;
  PinnedToolbarActions* GetPinnedToolbarActions() override;
  gfx::Size GetToolbarButtonSize() const override;
  views::BubbleAnchor GetDefaultExtensionDialogAnchor() override;
  page_actions::PageActionViewInterface* GetPageActionViewInterface(
      actions::ActionId action_id) override;
  AppMenuControl* GetAppMenuControl() override;
  gfx::Rect GetFindBarBoundingBox(int contents_bottom) override;
  void FocusToolbar() override;
  views::AccessiblePaneView* GetAsAccessiblePaneView() override;
  views::BubbleAnchor GetBubbleAnchor(
      std::optional<actions::ActionId> action_id) override;
  views::BubbleAnchor GetPageActionBubbleAnchor(
      actions::ActionId action_id) override;
  void ZoomChangedForActiveTab(bool can_show_bubble) override;
  AvatarToolbarButtonInterface* GetAvatarToolbarButtonInterface() override;
  ToolbarButton* GetBackButton() override;
  ReloadControl* GetReloadButton() override;
  ToolbarButton* GetDownloadButton() override;
  WebUIToolbarWebView* GetWebUIToolbarViewForTesting() override;

 private:
  views::BubbleAnchor TrailingAnchor();

  const raw_ptr<BarkBrowserWindow> window_;
  ui::ScopedUnownedUserData<ToolbarButtonProvider> scoped_user_data_;
};

class BarkFindBarOwner : public FindBarOwner {
 public:
  explicit BarkFindBarOwner(BarkBrowserWindow* window);
  ~BarkFindBarOwner() override;

  views::Widget* GetOwnerWidget() override;
  gfx::Rect GetFindBarBoundingBox() override;
  gfx::Rect GetFindBarClippingBox() override;
  bool IsOffTheRecord() const override;
  views::Widget* GetWidgetForAnchoring() override;
  std::u16string GetFindBarAccessibleWindowTitle() override;
  void OnFindBarVisibilityChanged(gfx::Rect visible_bounds) override;
  void CloseOverlappingBubbles() override;

 private:
  const raw_ptr<BarkBrowserWindow> window_;
};

}  // namespace bark

#endif  // BARK_BROWSER_UI_BARK_WINDOW_PARTS_H_
