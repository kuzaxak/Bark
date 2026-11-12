#include "bark/browser/ui/bark_window_parts.h"

#include <utility>

#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_window_host.h"
#include "base/functional/bind.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_command_controller.h"
#include "chrome/browser/ui/views/bubble_anchor_util_views.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/find_bar/find_bar_controller.h"
#include "chrome/browser/ui/fullscreen/browser_window_fullscreen_controller.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/exclusive_access/exclusive_access_bubble_views.h"
#include "chrome/browser/ui/views/translate/translate_bubble_controller.h"
#include "chrome/browser/ui/window_metadata/window_metadata_controller.h"
#include "components/strings/grit/components_strings.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/views/widget/widget.h"

namespace bark {

// BarkSidePanelUI -------------------------------------------------------------

BarkSidePanelUI::BarkSidePanelUI(BrowserWindowInterface* browser)
    : scoped_user_data_(browser->GetUnownedUserDataHost(), *this) {}

BarkSidePanelUI::~BarkSidePanelUI() = default;

void BarkSidePanelUI::Show(SidePanelEntryId entry_id,
                           std::optional<SidePanelOpenTrigger> open_trigger,
                           bool suppress_animations) {}
void BarkSidePanelUI::Show(SidePanelEntryKey entry_key,
                           std::optional<SidePanelOpenTrigger> open_trigger,
                           bool suppress_animations) {}
void BarkSidePanelUI::ShowFrom(
    SidePanelEntryKey entry_key,
    gfx::Rect starting_bounds_in_browser_coordinates) {}
void BarkSidePanelUI::Close(SidePanelEntryHideReason hide_reason,
                            bool suppress_animations) {}
void BarkSidePanelUI::Toggle(SidePanelEntryKey key,
                             SidePanelOpenTrigger open_trigger) {}
std::optional<SidePanelEntryId> BarkSidePanelUI::GetCurrentEntryId() const {
  return std::nullopt;
}
int BarkSidePanelUI::GetCurrentEntryDefaultContentWidth() const {
  return 0;
}
bool BarkSidePanelUI::IsSidePanelShowing() const {
  return false;
}
bool BarkSidePanelUI::IsSidePanelEntryShowing(
    const SidePanelEntryKey& entry_key) const {
  return false;
}
bool BarkSidePanelUI::IsSidePanelEntryShowing(
    const SidePanelEntryKey& entry_key,
    bool for_tab) const {
  return false;
}
base::CallbackListSubscription BarkSidePanelUI::RegisterSidePanelShown(
    ShownCallback callback) {
  return shown_callbacks_.Add(std::move(callback));
}
void BarkSidePanelUI::OnActiveTabChanged(content::WebContents* old_contents,
                                         content::WebContents* new_contents,
                                         bool tab_removed_for_deletion) {}
content::WebContents* BarkSidePanelUI::GetWebContentsForTest(
    SidePanelEntryId id) {
  return nullptr;
}
void BarkSidePanelUI::DisableAnimationsForTesting() {}
void BarkSidePanelUI::SetNoDelaysForTesting(bool no_delays_for_testing) {}

// BarkStubLocationBar ---------------------------------------------------------

BarkStubLocationBar::BarkStubLocationBar(BarkBrowserWindow* window)
    : LocationBar(chrome::BrowserCommandController::From(window->browser())),
      window_(window) {}

BarkStubLocationBar::~BarkStubLocationBar() = default;

void BarkStubLocationBar::FocusLocation(bool is_user_initiated,
                                        bool clear_focus_if_failed) {}
void BarkStubLocationBar::FocusSearch() {}
void BarkStubLocationBar::UpdateFocusBehavior(bool toolbar_visible) {}
void BarkStubLocationBar::UpdateContentSettingsIcons() {}
void BarkStubLocationBar::SaveStateToContents(content::WebContents* contents) {}
void BarkStubLocationBar::Revert() {}
OmniboxView* BarkStubLocationBar::GetOmniboxView() {
  return nullptr;
}
OmniboxPopupView* BarkStubLocationBar::GetOmniboxPopupView() {
  return nullptr;
}
OmniboxController* BarkStubLocationBar::GetOmniboxController() {
  return nullptr;
}
bool BarkStubLocationBar::ShouldCloseOmniboxPopup(ui::MouseEvent* event) {
  return false;
}
content::WebContents* BarkStubLocationBar::GetWebContents() {
  return window_->browser()->GetTabStripModel()->GetActiveWebContents();
}
LocationBarModel* BarkStubLocationBar::GetLocationBarModel() {
  return nullptr;
}
std::optional<bubble_anchor_util::AnchorConfiguration>
BarkStubLocationBar::GetChipAnchor() {
  gfx::Point corner = window_->GetPageBoundsInScreen().origin();
  corner.Offset(bubble_anchor_util::kNoToolbarLeftOffset, 0);
  views::View* anchor = window_->host()->AnchorAt(corner);
  if (!anchor) {
    return std::nullopt;
  }
  return bubble_anchor_util::AnchorConfiguration{
      views::BubbleAnchor(anchor), std::nullopt, views::BubbleBorder::TOP_LEFT};
}
ChipController* BarkStubLocationBar::GetChipController() {
  return nullptr;
}
void BarkStubLocationBar::AnnounceAlert(const std::u16string& announcement) {}
void BarkStubLocationBar::OnChanged() {}
void BarkStubLocationBar::UpdateWithoutTabRestore() {}
ui::TrackedElement* BarkStubLocationBar::GetAnchorOrNull() {
  return nullptr;
}
BrowserWindowInterface* BarkStubLocationBar::GetBrowser() {
  return window_->browser();
}
Profile* BarkStubLocationBar::GetProfile() {
  return window_->browser()->GetProfile();
}
bool BarkStubLocationBar::IsInitialized() const {
  return true;
}
bool BarkStubLocationBar::IsVisible() const {
  return false;
}
bool BarkStubLocationBar::IsDrawn() const {
  return false;
}
bool BarkStubLocationBar::IsFullscreen() const {
  return window_->IsFullscreen();
}
bool BarkStubLocationBar::IsEditingOrEmpty() const {
  return false;
}
bool BarkStubLocationBar::IsMouseHovered() const {
  return false;
}
bool BarkStubLocationBar::IsFocusWithin() const {
  return false;
}
void BarkStubLocationBar::InvalidateLayout() {}
gfx::Rect BarkStubLocationBar::Bounds() const {
  return gfx::Rect();
}
gfx::Rect BarkStubLocationBar::BoundsInScreen() const {
  return gfx::Rect();
}
gfx::Size BarkStubLocationBar::MinimumSize() const {
  return gfx::Size();
}
gfx::Size BarkStubLocationBar::PreferredSize() const {
  return gfx::Size();
}
void BarkStubLocationBar::Update(content::WebContents* contents) {}
void BarkStubLocationBar::ResetTabState(content::WebContents* contents) {}
bool BarkStubLocationBar::HasSecurityStateChanged() {
  return false;
}
LocationBarTesting* BarkStubLocationBar::GetLocationBarForTesting() {
  return nullptr;
}

// BarkModalDialogHost ---------------------------------------------------------

BarkModalDialogHost::BarkModalDialogHost(BarkBrowserWindow* window)
    : window_(window) {}

BarkModalDialogHost::~BarkModalDialogHost() {
  observers_.Notify(&web_modal::ModalDialogHostObserver::OnHostDestroying);
}

void BarkModalDialogHost::NotifyPositionRequiresUpdate() {
  observers_.Notify(
      &web_modal::ModalDialogHostObserver::OnPositionRequiresUpdate);
}

gfx::Rect BarkModalDialogHost::PageBoundsInWindow() const {
  return window_->GetPageBoundsInScreen() -
         window_->GetBounds().OffsetFromOrigin();
}

gfx::NativeView BarkModalDialogHost::GetHostView() const {
  auto* widget = window_->host()->widget();
  return widget ? widget->GetNativeView() : gfx::NativeView();
}

gfx::Point BarkModalDialogHost::GetDialogPosition(const gfx::Size& size) {
  const gfx::Rect page = PageBoundsInWindow();
  return gfx::Point(page.x() + (page.width() - size.width()) / 2, page.y());
}

bool BarkModalDialogHost::ShouldActivateDialog() const {
  return GlobalBrowserCollection::GetInstance()->GetLastActiveBrowser() ==
         window_->browser();
}

gfx::Size BarkModalDialogHost::GetMaximumDialogSize() {
  return PageBoundsInWindow().size();
}

void BarkModalDialogHost::AddObserver(
    web_modal::ModalDialogHostObserver* observer) {
  observers_.AddObserver(observer);
}

void BarkModalDialogHost::RemoveObserver(
    web_modal::ModalDialogHostObserver* observer) {
  observers_.RemoveObserver(observer);
}

// BarkExclusiveAccessContext --------------------------------------------------

BarkExclusiveAccessContext::BarkExclusiveAccessContext(
    BarkBrowserWindow* window)
    : window_(window) {}

BarkExclusiveAccessContext::~BarkExclusiveAccessContext() = default;

Profile* BarkExclusiveAccessContext::GetProfile() {
  return window_->browser()->GetProfile();
}

void BarkExclusiveAccessContext::EnterFullscreen(
    const url::Origin& origin,
    ExclusiveAccessBubbleType bubble_type,
    FullscreenTabParams fullscreen_tab_params) {
  window_->host()->SetFullscreen(window_, true);
}

void BarkExclusiveAccessContext::ExitFullscreen() {
  if (BrowserWindowFullscreenController::From(window_->browser())
          ->IsForceFullscreen() ||
      !IsFullscreen()) {
    return;
  }
  window_->host()->SetFullscreen(window_, false);
}

void BarkExclusiveAccessContext::UpdateExclusiveAccessBubble(
    const ExclusiveAccessBubbleParams& params,
    ExclusiveAccessBubbleHideCallback first_hide_callback) {
  UpdateBubble(params, std::move(first_hide_callback));
  // FullscreenController tells the window about a switch between window and
  // page full screen only through the bubble, and when a page leaves full
  // screen it updates the bubble before it leaves the window.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&BarkWindowHost::UpdateFullscreen,
                                window_->host()->GetWeakPtr()));
}

void BarkExclusiveAccessContext::UpdateBubble(
    const ExclusiveAccessBubbleParams& params,
    ExclusiveAccessBubbleHideCallback first_hide_callback) {
  const bool close_bubble =
      !params.has_download && params.type == EXCLUSIVE_ACCESS_BUBBLE_TYPE_NONE;
  if (close_bubble) {
    if (first_hide_callback) {
      std::move(first_hide_callback)
          .Run(ExclusiveAccessBubbleHideReason::kNotShown);
    }
    if (!bubble_ || bubble_destruction_task_) {
      return;
    }
    bubble_->HideImmediately();
    // ExclusiveAccessBubbleViews calls back into this method while it updates
    // (crbug.com/40063714).
    bubble_destruction_task_ = bubble_tasks_.PostTask(
        base::SingleThreadTaskRunner::GetCurrentDefault().get(), FROM_HERE,
        base::BindOnce(
            &BarkExclusiveAccessContext::DestroyAnyExclusiveAccessBubble,
            weak_factory_.GetWeakPtr()));
    return;
  }
  if (bubble_) {
    if (bubble_destruction_task_) {
      bubble_tasks_.TryCancel(*bubble_destruction_task_);
      bubble_destruction_task_.reset();
    }
    bubble_->Update(params, std::move(first_hide_callback));
    return;
  }
  bubble_ = std::make_unique<ExclusiveAccessBubbleViews>(
      this, params, std::move(first_hide_callback));
}

bool BarkExclusiveAccessContext::IsExclusiveAccessBubbleDisplayed() const {
  return bubble_ && (bubble_->IsShowing() || bubble_->IsVisible());
}

void BarkExclusiveAccessContext::OnExclusiveAccessUserInput() {
  if (bubble_) {
    bubble_->OnUserInput();
  }
}

content::WebContents*
BarkExclusiveAccessContext::GetWebContentsForExclusiveAccess() {
  return window_->browser()->GetTabStripModel()->GetActiveWebContents();
}

bool BarkExclusiveAccessContext::CanUserEnterFullscreen() const {
  return true;
}

bool BarkExclusiveAccessContext::CanUserExitFullscreen() const {
  return true;
}

bool BarkExclusiveAccessContext::IsFullscreen() const {
  return window_->IsFullscreen();
}

ExclusiveAccessManager*
BarkExclusiveAccessContext::GetExclusiveAccessManager() {
  return ExclusiveAccessManager::From(window_->browser());
}

ui::AcceleratorProvider* BarkExclusiveAccessContext::GetAcceleratorProvider() {
  return window_;
}

gfx::NativeView BarkExclusiveAccessContext::GetBubbleParentView() const {
  auto* widget = window_->host()->widget();
  return widget ? widget->GetNativeView() : gfx::NativeView();
}

gfx::Rect BarkExclusiveAccessContext::GetClientAreaBoundsInScreen() const {
  return window_->GetPageBoundsInScreen();
}

bool BarkExclusiveAccessContext::IsImmersiveModeEnabled() const {
  return false;
}

gfx::Rect BarkExclusiveAccessContext::GetTopContainerBoundsInScreen() {
  return gfx::Rect();
}

void BarkExclusiveAccessContext::DestroyAnyExclusiveAccessBubble() {
  bubble_.reset();
  bubble_destruction_task_.reset();
}

// BarkFindBarOwner ------------------------------------------------------------

BarkFindBarOwner::BarkFindBarOwner(BarkBrowserWindow* window)
    : FindBarOwner(window->browser()->GetUnownedUserDataHost()),
      window_(window) {}

BarkFindBarOwner::~BarkFindBarOwner() = default;

views::Widget* BarkFindBarOwner::GetOwnerWidget() {
  return window_->host()->widget();
}

gfx::Rect BarkFindBarOwner::GetFindBarBoundingBox() {
  return window_->GetPageBoundsInScreen() -
         window_->GetBounds().OffsetFromOrigin();
}

gfx::Rect BarkFindBarOwner::GetFindBarClippingBox() {
  return GetFindBarBoundingBox();
}

bool BarkFindBarOwner::IsOffTheRecord() const {
  return window_->browser()->GetProfile()->IsOffTheRecord();
}

views::Widget* BarkFindBarOwner::GetWidgetForAnchoring() {
  return window_->host()->widget();
}

std::u16string BarkFindBarOwner::GetFindBarAccessibleWindowTitle() {
  return l10n_util::GetStringFUTF16(
      IDS_FIND_IN_PAGE_ACCESSIBLE_TITLE,
      WindowMetadataController::From(window_->browser())
          ->GetWindowTitleForCurrentTab(false));
}

void BarkFindBarOwner::OnFindBarVisibilityChanged(gfx::Rect visible_bounds) {
  FindBarController::From(window_->browser())->OnFindBarVisibilityChanged();
}

void BarkFindBarOwner::CloseOverlappingBubbles() {
  if (auto* controller = TranslateBubbleController::From(window_->browser())) {
    controller->CloseBubble();
  }
}

}  // namespace bark
