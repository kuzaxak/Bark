#include "bark/browser/ui/bark_browser_window.h"

#import <AppKit/AppKit.h>
#include <Carbon/Carbon.h>

#include <utility>

#include "bark/bridge/barc_runtime_startup.h"
#include "bark/browser/ui/bark_window_factory.h"
#include "bark/browser/ui/bark_window_host.h"
#include "bark/browser/ui/bark_window_parts.h"
#include "base/functional/bind.h"
#include "base/notimplemented.h"
#include "chrome/browser/enterprise/data_protection/data_protection_navigation_controller.h"
#include "chrome/browser/global_keyboard_shortcuts_mac.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/themes/theme_service.h"
#include "chrome/browser/ui/browser_active_state_manager/browser_active_state_manager.h"
#include "chrome/browser/ui/browser_init_state.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/exclusive_access/fullscreen_controller.h"
#include "chrome/browser/ui/find_bar/find_bar.h"
#include "chrome/browser/ui/interaction/browser_elements.h"
#include "chrome/browser/ui/sad_tab.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/ui/views/accessibility/caret_browsing_dialog_delegate.h"
#include "chrome/browser/ui/views/autofill/autofill_bubble_handler_impl.h"
#include "chrome/browser/ui/views/eye_dropper/eye_dropper.h"
#include "chrome/browser/ui/views/download/download_in_progress_dialog_view.h"
#include "chrome/browser/ui/views/find_bar_host.h"
#include "chrome/browser/ui/views/interaction/browser_elements_views_impl.h"
#include "components/enterprise/buildflags/buildflags.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/javascript_dialogs/tab_modal_dialog_manager.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "ui/base/mojom/window_show_state.mojom.h"
#include "ui/display/screen.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/mac/coordinate_conversion.h"
#include "ui/native_theme/native_theme.h"
#include "ui/views/cocoa/native_widget_mac_ns_window_host.h"
#include "ui/views/widget/widget.h"

namespace {
[[gnu::used, gnu::retain, gnu::section("__TEXT,__barkhostonly")]]
const char kBarkHostOnlyCapability[] = "BARK_MAC_HOST_ONLY_FACTORY_V1";
}  // namespace

bool BrowserWindow::CanCreateInNativeWindow(const SessionID& owner) {
  return bark::HostToJoin(owner) != nullptr;
}

std::unique_ptr<BrowserWindow, BrowserWindowDeleter>
BrowserWindow::CreateBrowserWindow(BrowserWindowInterface* browser,
                                   bool user_gesture,
                                   bool in_tab_dragging) {
  return bark::CreateHostWindow(browser);
}

namespace bark {

namespace {

int g_app_window_creation_depth = 0;

// Whether the event AppKit is handling is the person moving the keys into
// `page`: a click on it, or Tab through the window's key views.
bool PersonMovesKeysInto(NSView* page) {
  NSEvent* event = NSApp.currentEvent;
  if (!event || event.window != page.window) {
    return false;
  }
  switch (event.type) {
    case NSEventTypeLeftMouseDown:
    case NSEventTypeRightMouseDown:
    case NSEventTypeOtherMouseDown: {
      NSView* content = page.window.contentView;
      NSView* hit = [content
          hitTest:[content.superview convertPoint:event.locationInWindow
                                         fromView:nil]];
      return [hit isDescendantOf:page];
    }
    case NSEventTypeKeyDown:
      return event.keyCode == kVK_Tab;
    default:
      return false;
  }
}

bool ShouldHandleKeyboardEvent(const input::NativeWebKeyboardEvent& event) {
  if (event.skip_if_unhandled ||
      event.GetType() == input::NativeWebKeyboardEvent::Type::kChar) {
    return false;
  }
  return event.os_event && event.os_event.Get().type == NSEventTypeKeyDown;
}

}  // namespace

bool UsesCompactHost(const BrowserWindowInterface* browser) {
  switch (browser->GetType()) {
    case BrowserWindowInterface::TYPE_POPUP:
    case BrowserWindowInterface::TYPE_APP:
    case BrowserWindowInterface::TYPE_APP_POPUP:
    case BrowserWindowInterface::TYPE_DEVTOOLS:
      return true;
    default:
      return false;
  }
}

bool CanCreateHostWindowForProfile(const Profile& profile) {
  // Bark presents ephemeral Guest sessions with their own native identity.
  return !profile.IsOffTheRecord() || profile.IsGuestSession();
}

bool CanCreateHostWindow(const BrowserWindowCreateParams& params) {
  if (params.window ||
      !CanCreateHostWindowForProfile(*params.profile)) {
    return false;
  }
  switch (params.type) {
    case BrowserWindowInterface::TYPE_NORMAL:
    case BrowserWindowInterface::TYPE_POPUP:
    case BrowserWindowInterface::TYPE_APP:
    case BrowserWindowInterface::TYPE_APP_POPUP:
    case BrowserWindowInterface::TYPE_DEVTOOLS:
      break;
    default:
      return false;
  }
  if (!params.native_window_owner) {
    return true;
  }
  if (params.type != BrowserWindowInterface::TYPE_NORMAL ||
      params.in_tab_dragging) {
    return false;
  }
  auto* collection = GlobalBrowserCollection::GetInstance();
  auto* owner = collection
                    ? collection->FindBrowserWithID(*params.native_window_owner)
                    : nullptr;
  if (!HostToJoin(owner)) {
    return false;
  }
  Profile* source = &*params.profile;
  Profile* destination = owner->GetProfile();
  return source == destination ||
         (!source->IsOffTheRecord() && !destination->IsOffTheRecord());
}

std::unique_ptr<BrowserWindow, BrowserWindowDeleter> CreateHostWindow(
    BrowserWindowInterface* browser) {
  const auto& params = BrowserInitState::From(browser)->create_params();
  if (!CanCreateHostWindow(params)) {
    return nullptr;
  }

  BarkWindowHost* join = nullptr;
  if (params.native_window_owner) {
    join = HostToJoin(*params.native_window_owner);
    if (!join) {
      return nullptr;
    }
  }
  const bool app_created =
      g_app_window_creation_depth != 0 || params.native_window_owner.has_value();
  return std::unique_ptr<BrowserWindow, BrowserWindowDeleter>(
      new BarkBrowserWindow(browser, join, app_created));
}

BarkWindowHost* HostToJoin(BrowserWindowInterface* owner) {
  if (!owner || owner->IsDeleteScheduled() ||
      owner->GetType() != BrowserWindowInterface::TYPE_NORMAL) {
    return nullptr;
  }
  auto* host = BarkWindowHost::ForBrowser(owner);
  return host && !host->closing() && host->widget() ? host : nullptr;
}

BarkWindowHost* HostToJoin(const SessionID& owner) {
  auto* collection = GlobalBrowserCollection::GetInstance();
  return HostToJoin(collection ? collection->FindBrowserWithID(owner) : nullptr);
}

ScopedAppWindowCreation::ScopedAppWindowCreation() {
  ++g_app_window_creation_depth;
}

ScopedAppWindowCreation::~ScopedAppWindowCreation() {
  --g_app_window_creation_depth;
}

DEFINE_USER_DATA(BarkBrowserWindow);

// static
BarkBrowserWindow* BarkBrowserWindow::FromBrowser(
    const BrowserWindowInterface* browser) {
  return browser ? const_cast<BarkBrowserWindow*>(
                       Get(browser->GetUnownedUserDataHost()))
                 : nullptr;
}

// Tells the app when a page's renderer dies and when the page has one again,
// by SadTabHelper's rule; a host window has no sad tab of its own. A placed page
// that takes the keys becomes its client's active tab, as a pane of a split.
class BarkBrowserWindow::TabWatcher : public content::WebContentsObserver {
 public:
  TabWatcher(BarkBrowserWindow* window, content::WebContents* contents)
      : content::WebContentsObserver(contents),
        window_(window),
        crashed_(contents->IsCrashed()) {
#if BUILDFLAG(ENTERPRISE_SCREENSHOT_PROTECTION)
    if (auto* controller =
            enterprise_data_protection::DataProtectionNavigationController::
                FromWebContents(contents)) {
      capture_subscription_ = controller->RegisterScreenshotAllowedUpdatedCallback(
          base::BindRepeating(&TabWatcher::OnCapturePolicyChanged,
                              base::Unretained(this)));
    }
#endif
  }

  void PrimaryMainFrameRenderProcessGone(
      base::TerminationStatus status) override {
    if (SadTab::ShouldShow(status)) {
      crashed_ = true;
      window_->NotifyPageCrashed(web_contents(), true);
    }
  }
  void RenderViewReady() override {
    if (std::exchange(crashed_, false)) {
      window_->NotifyPageCrashed(web_contents(), false);
    }
  }
  void OnWebContentsFocused(content::RenderWidgetHost*) override {
    window_->OnPageFocused(web_contents());
  }
  void OnVisibilityChanged(content::Visibility visibility) override {
    window_->host_->UpdateCaptureProtection();
    if (visibility == content::Visibility::VISIBLE) {
      window_->OnPageShown(web_contents());
    }
  }

 private:
#if BUILDFLAG(ENTERPRISE_SCREENSHOT_PROTECTION)
  void OnCapturePolicyChanged(bool) {
    window_->host_->UpdateCaptureProtection();
  }

  base::CallbackListSubscription capture_subscription_;
#endif
  const raw_ptr<BarkBrowserWindow> window_;
  bool crashed_;
};

BarkBrowserWindow::BarkBrowserWindow(BrowserWindowInterface* browser,
                                     BarkWindowHost* join,
                                     bool app_created)
    : browser_(browser),
      app_created_(app_created),
      scoped_user_data_(browser->GetUnownedUserDataHost(), *this) {
  if (join && join->AddClient(this)) {
    host_ = join;
  } else {
    host_ = base::MakeRefCounted<BarkWindowHost>(this);
  }
  location_bar_ = std::make_unique<BarkStubLocationBar>(this);
  modal_dialog_host_ = std::make_unique<BarkModalDialogHost>(this);
  exclusive_access_context_ =
      std::make_unique<BarkExclusiveAccessContext>(this);
  find_bar_owner_ = std::make_unique<BarkFindBarOwner>(this);
  side_panel_ui_ = std::make_unique<BarkSidePanelUI>(browser_);
  toolbar_button_provider_ = std::make_unique<BarkToolbarButtonProvider>(this);
  autofill_bubble_handler_ = std::make_unique<autofill::AutofillBubbleHandlerImpl>(
      browser_, toolbar_button_provider_.get());
  BrowserElements::From(browser_)->AsA<BrowserElementsViewsImpl>()->Init(
      host_->widget()->GetClientContentsView());
  browser_->GetTabStripModel()->AddObserver(this);
}

BarkBrowserWindow::~BarkBrowserWindow() {
  tab_watchers_.clear();
  browser_->GetFeatures().TearDownPreBrowserWindowDestruction();
  if (auto warning = std::exchange(pending_download_warning_, {})) {
    warning->CloseNow();
  }
  autofill_bubble_handler_.reset();
  toolbar_button_provider_.reset();
  side_panel_ui_.reset();
  find_bar_owner_.reset();
  exclusive_access_context_.reset();
  page_dialog_hosts_.clear();
  modal_dialog_host_.reset();
  location_bar_.reset();
  host_->RemoveClient(this);
  host_.reset();
}

bool BarkBrowserWindow::MarkApplicationMini() {
  if (!app_created_ || browser_->GetType() != BrowserWindowInterface::TYPE_POPUP ||
      browser_->IsDeleteScheduled()) {
    return false;
  }
  application_mini_ = true;
  return true;
}

gfx::Rect BarkBrowserWindow::GetPageBoundsInScreen() const {
  return GetPageBoundsInScreen(
      browser_->GetTabStripModel()->GetActiveWebContents());
}

gfx::Rect BarkBrowserWindow::GetPageBoundsInScreen(
    content::WebContents* contents) const {
  NSView* page = contents ? contents->GetNativeView().GetNativeNSView() : nil;
  NSWindow* window = GetNativeWindow().GetNativeNSWindow();
  NSView* area = page.window == window && !page.isHiddenOrHasHiddenAncestor
                     ? page
                     : host_->root_view().GetNativeNSView();
  if (!area || area.window != window) {
    return host_->widget()->GetClientAreaBoundsInScreen();
  }
  return gfx::ScreenRectFromNSRect(
      [window convertRectToScreen:[area convertRect:area.bounds toView:nil]]);
}

void BarkBrowserWindow::OnHostActivationChanged(bool active) {
  if (browser_->IsDeleteScheduled()) {
    return;
  }
  if (active) {
    BrowserActiveStateManager::From(browser_)->DidBecomeActive();
  } else {
    BrowserActiveStateManager::From(browser_)->DidBecomeInactive();
  }
}

void BarkBrowserWindow::OnHostBoundsChanged() {
  if (modal_dialog_host_) {
    modal_dialog_host_->NotifyPositionRequiresUpdate();
  }
  for (const auto& [contents, host] : page_dialog_hosts_) {
    host->NotifyPositionRequiresUpdate();
  }
}

void BarkBrowserWindow::OnHostFullscreenChanged() {
  if (auto* manager = ExclusiveAccessManager::From(browser_)) {
    manager->fullscreen_controller()->WindowFullscreenStateChanged();
  }
}

void BarkBrowserWindow::EnsureActiveTabHasNonZeroSize() {
  auto* contents = browser_->GetTabStripModel()->GetActiveWebContents();
  if (!contents || !contents->GetContainerBounds().size().IsEmpty()) {
    return;
  }
  gfx::Size size = GetPageBoundsInScreen().size();
  if (size.IsEmpty()) {
    size = GetRestoredBounds().size();
  }
  contents->Resize(gfx::Rect(size));
}

bool BarkBrowserWindow::IsSelectedForNativeWindow() const {
  return host_ && host_->selected() == this;
}

gfx::NativeWindow BarkBrowserWindow::GetNativeWindow() const {
  return host_->widget() ? host_->widget()->GetNativeWindow()
                         : gfx::NativeWindow();
}

bool BarkBrowserWindow::IsOnCurrentWorkspace() const {
  NSWindow* window = GetNativeWindow().GetNativeNSWindow();
  return !window || window.isOnActiveSpace;
}

bool BarkBrowserWindow::IsVisibleOnScreen() const {
  return IsVisible() && !IsMinimized();
}

void BarkBrowserWindow::SetTopControlsShownRatio(
    content::WebContents* web_contents,
    float ratio) {}

bool BarkBrowserWindow::DoBrowserControlsShrinkRendererSize(
    const content::WebContents* contents) const {
  return false;
}

ui::NativeTheme* BarkBrowserWindow::GetNativeTheme() {
  return ui::NativeTheme::GetInstanceForNativeUi();
}

const ui::ThemeProvider* BarkBrowserWindow::GetThemeProvider() const {
  return &ThemeService::GetThemeProviderForProfile(browser_->GetProfile());
}

const ui::ColorProvider* BarkBrowserWindow::GetColorProvider() const {
  return host_->widget() ? host_->widget()->GetColorProvider() : nullptr;
}

int BarkBrowserWindow::GetTopControlsHeight() const {
  return 0;
}

void BarkBrowserWindow::SetTopControlsGestureScrollInProgress(
    bool in_progress) {}

std::vector<StatusBubble*> BarkBrowserWindow::GetStatusBubbles() {
  return {};
}

void BarkBrowserWindow::UpdateTitleBar() {
  if (IsSelectedForNativeWindow() && host_->widget()) {
    host_->widget()->UpdateWindowTitle();
  }
}

void BarkBrowserWindow::UpdateLoadingAnimations(bool is_visible) {}

void BarkBrowserWindow::OnActiveTabChanged(content::WebContents* old_contents,
                                           content::WebContents* new_contents,
                                           int index,
                                           int reason) {
  if (old_contents && new_contents->GetContainerBounds().size().IsEmpty()) {
    const gfx::Size old_size = old_contents->GetContainerBounds().size();
    if (!old_size.IsEmpty()) {
      new_contents->Resize(gfx::Rect(old_size));
    }
  }
  if (host_->widget()) {
    new_contents->SetColorProviderSource(host_->widget());
  }
  EnsureActiveTabHasNonZeroSize();
  UpdateTitleBar();
  host_->OnClientActiveTabChanged(this);
  // Chromium shows a held alert when its tab comes to the front, which it
  // learns from the tab turning visible. A pane of a split is already visible.
  if (new_contents->GetVisibility() == content::Visibility::VISIBLE) {
    if (auto* dialogs = javascript_dialogs::TabModalDialogManager::FromWebContents(
            new_contents)) {
      dialogs->BrowserActiveStateChanged();
    }
  }
}

void BarkBrowserWindow::OnTabDetached(content::WebContents* contents,
                                      bool was_active) {}

gfx::Size BarkBrowserWindow::GetContentsSize() const {
  return GetPageBoundsInScreen().size();
}

void BarkBrowserWindow::SetContentsSize(const gfx::Size& size) {
  if (!host_->widget() || (UsesCompactHost(browser_) && size.IsEmpty())) {
    return;
  }
  const gfx::Size current = GetContentsSize();
  if (size == current) {
    return;
  }
  gfx::Rect bounds = GetBounds();
  bounds.set_size(bounds.size() + size - current);
  SetBounds(bounds);
}

autofill::AutofillBubbleHandler* BarkBrowserWindow::GetAutofillBubbleHandler() {
  return autofill_bubble_handler_.get();
}

LocationBar* BarkBrowserWindow::GetLocationBar() const {
  return location_bar_.get();
}

ui::AcceleratorProvider* BarkBrowserWindow::GetAcceleratorProvider() {
  return this;
}

PinnedToolbarActions* BarkBrowserWindow::GetPinnedToolbarActions() {
  return nullptr;
}

void BarkBrowserWindow::SetFocusToLocationBar(bool is_user_initiated) {}

void BarkBrowserWindow::UpdateReloadStopState(bool is_loading, bool force) {}

void BarkBrowserWindow::UpdateToolbar(content::WebContents* contents) {}

bool BarkBrowserWindow::UpdateToolbarSecurityState() {
  return false;
}

void BarkBrowserWindow::UpdateCustomTabBarVisibility(bool visible,
                                                     bool animate) {}

void BarkBrowserWindow::ResetToolbarTabState(content::WebContents* contents) {}

void BarkBrowserWindow::FocusToolbar() {}

void BarkBrowserWindow::ToolbarSizeChanged(bool is_animating) {}

void BarkBrowserWindow::TabDraggingStatusChanged(bool is_dragging) {}

void BarkBrowserWindow::LinkOpeningFromGesture(
    WindowOpenDisposition disposition) {}

void BarkBrowserWindow::FocusAppMenu() {}

bool BarkBrowserWindow::IsTabStripEditable() const {
  return true;
}

void BarkBrowserWindow::DisableTabStripEditingForTesting() {}

bool BarkBrowserWindow::IsToolbarVisible() const {
  return false;
}

bool BarkBrowserWindow::IsToolbarShowing() const {
  return false;
}

bool BarkBrowserWindow::IsLocationBarVisible() const {
  return false;
}

void BarkBrowserWindow::ShowUpdateChromeDialog() {}

void BarkBrowserWindow::ShowIntentPickerBubble(
    std::vector<apps::IntentPickerAppInfo> app_info,
    bool show_stay_in_chrome,
    bool show_remember_selection,
    apps::IntentPickerBubbleType bubble_type,
    const std::optional<url::Origin>& initiating_origin,
    IntentPickerResponse callback) {
  NOTIMPLEMENTED_LOG_ONCE();
}

void BarkBrowserWindow::ShowBookmarkBubble(const GURL& url,
                                           bool already_bookmarked) {}

ShowTranslateBubbleResult BarkBrowserWindow::ShowTranslateBubble(
    content::WebContents* contents,
    translate::TranslateStep step,
    const std::string& source_language,
    const std::string& target_language,
    translate::TranslateErrors error_type,
    bool is_user_gesture) {
  return ShowTranslateBubbleResult::kBrowserWindowNotValid;
}

DownloadBubbleUIController* BarkBrowserWindow::GetDownloadBubbleUIController() {
  return nullptr;
}

void BarkBrowserWindow::ConfirmBrowserCloseWithPendingDownloads(
    int download_count,
    UnloadController::DownloadCloseType dialog_type,
    base::OnceCallback<void(bool)> callback) {
  auto alive = weak_factory_.GetWeakPtr();
  auto* widget = DownloadInProgressDialogView::Create(
      GetNativeWindow(), download_count, dialog_type, std::move(callback));
  auto warning = widget->GetWeakPtr();
  if (!alive) {
    warning->Close();
    return;
  }
  pending_download_warning_ = warning;
  warning->Show();
}

void BarkBrowserWindow::CancelPendingDownloadWarning() {
  if (auto warning = std::exchange(pending_download_warning_, {})) {
    warning->Close();
  }
}

void BarkBrowserWindow::ShowAppMenu() {}

void BarkBrowserWindow::PreHandleDragUpdate(const content::DropData& drop_data,
                                            const gfx::PointF& point) {}

void BarkBrowserWindow::PreHandleDragExit() {}

void BarkBrowserWindow::HandleDragEnded() {}

content::KeyboardEventProcessingResult
BarkBrowserWindow::PreHandleKeyboardEvent(
    const input::NativeWebKeyboardEvent& event) {
  NSEvent* ns_event = event.os_event.Get();
  if (ns_event && EventUsesPerformKeyEquivalent(ns_event)) {
    int command_id = CommandForKeyEvent(ns_event).chrome_command;
    if (command_id == -1) {
      command_id = DelayedWebContentsCommandForKeyEvent(ns_event);
    }
    if (command_id != -1 &&
        !barc::KeyCommandBelongsToApplication(GetNativeWindow(), command_id)) {
      return content::KeyboardEventProcessingResult::NOT_HANDLED_IS_SHORTCUT;
    }
  }
  return content::KeyboardEventProcessingResult::NOT_HANDLED;
}

bool BarkBrowserWindow::HandleKeyboardEvent(
    const input::NativeWebKeyboardEvent& event) {
  if (!ShouldHandleKeyboardEvent(event)) {
    return false;
  }
  auto* window_host =
      views::NativeWidgetMacNSWindowHost::GetFromNativeWindow(GetNativeWindow());
  if (window_host && window_host->RedispatchKeyEvent(event.os_event.Get())) {
    return true;
  }
  views::Widget* widget = host_->widget();
  if (widget && widget->GetFocusManager() &&
      unhandled_keyboard_event_handler_.HandleKeyboardEvent(
          event, widget->GetFocusManager())) {
    return true;
  }
  // The app's views above the page take Esc as AppKit's cancelOperation:.
  NSEvent* key = event.os_event.Get();
  NSResponder* page = GetNativeWindow().GetNativeNSWindow().firstResponder;
  const NSEventModifierFlags held =
      NSEventModifierFlagShift | NSEventModifierFlagControl |
      NSEventModifierFlagOption | NSEventModifierFlagCommand;
  return key.keyCode == kVK_Escape && !(key.modifierFlags & held) && page &&
         [page.nextResponder tryToPerform:@selector(cancelOperation:)
                                     with:nil];
}

std::unique_ptr<FindBar> BarkBrowserWindow::CreateFindBar() {
  return std::make_unique<FindBarHost>(find_bar_owner_.get());
}

web_modal::WebContentsModalDialogHost*
BarkBrowserWindow::GetWebContentsModalDialogHost() {
  return modal_dialog_host_.get();
}

web_modal::WebContentsModalDialogHost*
BarkBrowserWindow::GetWebContentsModalDialogHostFor(
    content::WebContents* web_contents) {
  if (!modal_dialog_host_ ||
      browser_->GetTabStripModel()->GetIndexOfWebContents(web_contents) ==
          TabStripModel::kNoTab) {
    return modal_dialog_host_.get();
  }
  auto& host = page_dialog_hosts_[web_contents];
  if (!host) {
    host = std::make_unique<BarkModalDialogHost>(this, web_contents);
  }
  return host.get();
}

void BarkBrowserWindow::ShowAvatarBubbleFromAvatarButton(
    bool is_source_accelerator) {}

void BarkBrowserWindow::MaybeShowProfileSwitchIPH() {}

void BarkBrowserWindow::MaybeShowSupervisedUserProfileSignInIPH() {}

void BarkBrowserWindow::ShowHatsDialog(
    const std::string& site_id,
    const std::optional<std::string>& hats_histogram_name,
    const std::optional<uint64_t> hats_survey_ukm_id,
    base::OnceClosure success_callback,
    base::OnceClosure failure_callback,
    const SurveyBitsData& product_specific_bits_data,
    const SurveyStringData& product_specific_string_data) {
  std::move(failure_callback).Run();
}

ExclusiveAccessContext* BarkBrowserWindow::GetExclusiveAccessContext() {
  return exclusive_access_context_.get();
}

std::string BarkBrowserWindow::GetWorkspace() const {
  return std::string();
}

bool BarkBrowserWindow::IsVisibleOnAllWorkspaces() const {
  return host_->widget() && host_->widget()->IsVisibleOnAllWorkspaces();
}

void BarkBrowserWindow::ShowEmojiPanel() {
  [NSApp orderFrontCharacterPalette:nil];
}

std::unique_ptr<content::EyeDropper> BarkBrowserWindow::OpenEyeDropper(
    content::RenderFrameHost* frame,
    content::EyeDropperListener* listener) {
  return ShowEyeDropper(frame, listener);
}

void BarkBrowserWindow::ShowCaretBrowsingDialog() {
  CaretBrowsingDialogDelegate::Show(GetNativeWindow(),
                                    browser_->GetProfile()->GetPrefs());
}

void BarkBrowserWindow::CreateTabSearchBubble() {}

void BarkBrowserWindow::CloseTabSearchBubble() {}

void BarkBrowserWindow::ShowIncognitoClearBrowsingDataDialog() {}

void BarkBrowserWindow::ShowIncognitoHistoryDisclaimerDialog() {}

bool BarkBrowserWindow::IsUnframedModeEnabled() const {
  return false;
}

bool BarkBrowserWindow::GetCanResize() {
  return true;
}

ui::mojom::WindowShowState BarkBrowserWindow::GetWindowShowState() const {
  if (IsMaximized()) {
    return ui::mojom::WindowShowState::kMaximized;
  }
  if (IsMinimized()) {
    return ui::mojom::WindowShowState::kMinimized;
  }
  if (IsFullscreen()) {
    return ui::mojom::WindowShowState::kFullscreen;
  }
  return ui::mojom::WindowShowState::kDefault;
}

void BarkBrowserWindow::ShowChromeLabs() {}

BrowserView* BarkBrowserWindow::AsBrowserView() {
  return nullptr;
}

void BarkBrowserWindow::Show() {
  auto* widget = host_->widget();
  if (!widget || host_->closing() || !host_->Select(this)) {
    return;
  }
  if (host_->DeferPresentation(BarkWindowHost::Presentation::kShow)) {
    return;
  }
  auto alive = GetWeakPtr();
  BrowserActiveStateManager::From(browser_)->DidBecomeActive();
  if (!alive || host_->closing() || !IsSelectedForNativeWindow() ||
      browser_->IsDeleteScheduled()) {
    return;
  }
  if (widget->IsVisible()) {
    widget->Activate();
  } else {
    widget->Show();
  }
  if (alive) {
    EnsureActiveTabHasNonZeroSize();
  }
}

void BarkBrowserWindow::ShowInactive() {
  if (host_->widget() && !host_->closing() && host_->Select(this) &&
      !host_->DeferPresentation(BarkWindowHost::Presentation::kShowInactive)) {
    host_->widget()->ShowInactive();
  }
}

void BarkBrowserWindow::Hide() {
  if (host_->widget() && IsSelectedForNativeWindow()) {
    host_->CancelPendingPresentation();
    host_->widget()->Hide();
  }
}

bool BarkBrowserWindow::IsVisible() const {
  return host_->widget() && IsSelectedForNativeWindow() &&
         host_->widget()->IsVisible();
}

void BarkBrowserWindow::SetBounds(const gfx::Rect& bounds) {
  if (auto* widget = host_->widget()) {
    if (UsesCompactHost(browser_)) {
      if (!bounds.IsEmpty()) {
        widget->SetBounds(BarkWindowHost::ConstrainCompactBounds(
            bounds, *display::Screen::Get()));
      }
    } else {
      widget->SetBounds(bounds);
    }
  }
}

void BarkBrowserWindow::Close() {
  if (IsSelectedForNativeWindow()) {
    host_->CancelPendingPresentation();
  }
  auto* unload = UnloadController::From(browser_);
  if (!unload || unload->is_delete_scheduled()) {
    return;
  }
  auto alive = weak_factory_.GetWeakPtr();
  if (!unload->HandleBeforeClose() || !alive) {
    return;
  }
  if (host_->clients().size() == 1 && host_->widget() &&
      !browser_->GetTabStripModel()->empty()) {
    host_->widget()->Hide();
  }
  unload->OnWindowClosing();
}

void BarkBrowserWindow::Activate() {
  if (host_->widget() && host_->Select(this) &&
      !host_->DeferPresentation(BarkWindowHost::Presentation::kActivate)) {
    host_->widget()->Activate();
  }
}

void BarkBrowserWindow::Deactivate() {
  if (host_->widget() && IsSelectedForNativeWindow()) {
    host_->widget()->Deactivate();
  }
}

bool BarkBrowserWindow::IsActive() const {
  return host_->widget() && IsSelectedForNativeWindow() &&
         host_->widget()->IsActive();
}

gfx::Rect BarkBrowserWindow::GetBounds() const {
  return host_->widget() ? host_->widget()->GetWindowBoundsInScreen()
                         : gfx::Rect();
}

bool BarkBrowserWindow::IsMaximized() const {
  return host_->widget() && host_->widget()->IsMaximized();
}

bool BarkBrowserWindow::IsMinimized() const {
  return host_->widget() && host_->widget()->IsMinimized();
}

bool BarkBrowserWindow::IsFullscreen() const {
  return host_->widget() && host_->widget()->IsFullscreen();
}

gfx::Rect BarkBrowserWindow::GetRestoredBounds() const {
  return host_->widget() ? host_->widget()->GetRestoredBounds() : gfx::Rect();
}

ui::mojom::WindowShowState BarkBrowserWindow::GetRestoredState() const {
  return IsMaximized() ? ui::mojom::WindowShowState::kMaximized
                       : ui::mojom::WindowShowState::kDefault;
}

void BarkBrowserWindow::Maximize() {
  if (host_->widget()) {
    host_->widget()->Maximize();
  }
}

void BarkBrowserWindow::Minimize() {
  if (host_->widget()) {
    host_->widget()->Minimize();
  }
}

void BarkBrowserWindow::Restore() {
  if (host_->widget()) {
    host_->widget()->Restore();
  }
}

void BarkBrowserWindow::FlashFrame(bool flash) {
  if (host_->widget()) {
    host_->widget()->FlashFrame(flash);
  }
}

ui::ZOrderLevel BarkBrowserWindow::GetZOrderLevel() const {
  return host_->widget() ? host_->widget()->GetZOrderLevel()
                         : ui::ZOrderLevel::kNormal;
}

void BarkBrowserWindow::SetZOrderLevel(ui::ZOrderLevel order) {
  if (host_->widget()) {
    host_->widget()->SetZOrderLevel(order);
  }
}

bool BarkBrowserWindow::GetAcceleratorForCommandId(
    int command_id,
    ui::Accelerator* accelerator) const {
  return GetDefaultMacAcceleratorForCommandId(command_id, accelerator);
}

void BarkBrowserWindow::OnTabStripModelChanged(
    TabStripModel* tab_strip_model,
    const TabStripModelChange& change,
    const TabStripSelectionChange& selection) {
  if (change.type() == TabStripModelChange::kInserted) {
    for (const auto& inserted : change.GetInsert()->contents) {
      WatchTab(inserted.contents);
    }
  } else if (change.type() == TabStripModelChange::kRemoved) {
    for (const auto& removed : change.GetRemove()->contents) {
      tab_watchers_.erase(removed.contents);
      page_dialog_hosts_.erase(removed.contents);
      if (removed.tab && removed.contents) {
        host_->NotifyPageViewRetiring(browser_->GetSessionID().id(),
                                      removed.tab->GetHandle().raw_value(),
                                      removed.contents->GetNativeView());
      }
    }
  } else if (change.type() == TabStripModelChange::kReplaced) {
    const auto* replace = change.GetReplace();
    tab_watchers_.erase(replace->old_contents);
    page_dialog_hosts_.erase(replace->old_contents);
    WatchTab(replace->new_contents);
    if (replace->tab && replace->old_contents) {
      host_->NotifyPageViewRetiring(browser_->GetSessionID().id(),
                                    replace->tab->GetHandle().raw_value(),
                                    replace->old_contents->GetNativeView());
    }
  }
  host_->UpdateCaptureProtection();
}

void BarkBrowserWindow::OnPageShown(content::WebContents* contents) {
  if (contents == browser_->GetTabStripModel()->GetActiveWebContents()) {
    host_->OnClientActiveTabChanged(this);
  }
}

void BarkBrowserWindow::OnPageFocused(content::WebContents* contents) {
  if (browser_->IsDeleteScheduled() ||
      UnloadController::From(browser_)->owner_close_admitted() ||
      !host_->widget() || host_->closing()) {
    return;
  }
  TabStripModel* tabs = browser_->GetTabStripModel();
  NSView* page = contents->GetNativeView().GetNativeNSView();
  if (tabs->GetIndexOfWebContents(contents) == TabStripModel::kNoTab ||
      page.window != GetNativeWindow().GetNativeNSWindow() ||
      page.hiddenOrHasHiddenAncestor || !PersonMovesKeysInto(page)) {
    return;
  }
  if (host_->selected() != this && !host_->Select(this)) {
    return;
  }
  const int index = tabs->GetIndexOfWebContents(contents);
  if (index != TabStripModel::kNoTab && index != tabs->active_index()) {
    tabs->ActivateTabAt(index);
  }
}

void BarkBrowserWindow::WatchTab(content::WebContents* contents) {
  if (!contents) {
    return;
  }
  tab_watchers_[contents] = std::make_unique<TabWatcher>(this, contents);
  if (contents->IsCrashed()) {
    NotifyPageCrashed(contents, true);
  }
}

void BarkBrowserWindow::NotifyPageCrashed(content::WebContents* contents,
                                          bool crashed) {
  auto* tab = tabs::TabInterface::MaybeGetFromContents(contents);
  if (tab && host_) {
    host_->NotifyPageCrashed(browser_->GetSessionID().id(),
                             tab->GetHandle().raw_value(),
                             contents->GetNativeView(), crashed);
  }
}

void BarkBrowserWindow::DeleteBrowserWindow() {
  delete this;
}

}  // namespace bark
