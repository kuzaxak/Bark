#include "bark/browser/ui/bark_native_widget_mac.h"

#import <AppKit/AppKit.h>

#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_command_policy.h"
#include "bark/browser/ui/bark_window_host.h"
#include "base/apple/foundation_util.h"
#include "chrome/browser/ui/browser_command_controller.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#import "chrome/browser/ui/cocoa/browser_window_command_handler.h"
#import "chrome/browser/ui/cocoa/chrome_command_dispatcher_delegate.h"
#include "components/input/native_web_keyboard_event.h"
#import "components/remote_cocoa/app_shim/native_widget_mac_nswindow.h"
#import "components/remote_cocoa/app_shim/native_widget_ns_window_bridge.h"
#include "components/remote_cocoa/common/native_widget_ns_window.mojom.h"
#include "components/remote_cocoa/common/native_widget_ns_window_host.mojom.h"
#include "ui/base/accelerators/global_accelerator_listener/global_accelerator_listener.h"
#import "ui/base/cocoa/window_size_constants.h"
#include "ui/base/window_open_disposition.h"

@interface NSWindow (BarkPrivateAppKit)
+ (Class)frameViewClassForStyleMask:(NSUInteger)style_mask;
- (BOOL)_hasActiveAppearanceForStandardWindowButton:(NSWindowButton)button;
@end

@interface NSThemeFrame (BarkPrivateAppKit)
- (CGFloat)_titlebarHeight;
- (CGFloat)_minXTitlebarWidgetInset;
- (BOOL)_shouldCenterTrafficLights;
- (void)_updateButtonPositions;
@end

@interface BarkNSWindow : NativeWidgetMacNSWindow
// The app's titlebar height and first light's inset; 0 height leaves AppKit's.
@property(nonatomic) CGFloat barkTitlebarHeight;
@property(nonatomic) CGFloat barkLeadingInset;
@end

// AppKit reads these while it lays out the titlebar, as it does for
// BrowserWindowFrame in browser_native_widget_window_mac.mm.
@interface BarkWindowFrame : NativeWidgetMacNSWindowTitledFrame
@end

@implementation BarkWindowFrame

- (BarkNSWindow*)barkWindow {
  return base::apple::ObjCCast<BarkNSWindow>(self.window);
}

- (BOOL)usesAppChrome {
  return [self barkWindow].barkTitlebarHeight > 0;
}

- (CGFloat)_titlebarHeight {
  return [self usesAppChrome] ? [self barkWindow].barkTitlebarHeight
                              : [super _titlebarHeight];
}

- (CGFloat)_minXTitlebarWidgetInset {
  return [self usesAppChrome] ? [self barkWindow].barkLeadingInset
                              : [super _minXTitlebarWidgetInset];
}

- (BOOL)_shouldCenterTrafficLights {
  return [self usesAppChrome] || [super _shouldCenterTrafficLights];
}

@end

@implementation BarkNSWindow

@synthesize barkTitlebarHeight = _barkTitlebarHeight;
@synthesize barkLeadingInset = _barkLeadingInset;

+ (Class)frameViewClassForStyleMask:(NSUInteger)style_mask {
  if (style_mask & NSWindowStyleMaskTitled) {
    return [BarkWindowFrame class];
  }
  return [super frameViewClassForStyleMask:style_mask];
}

// The lights draw as in an inactive window, grey, until the pointer is over
// them, when AppKit draws them coloured with their glyphs, as Arc's do.
- (BOOL)_hasActiveAppearanceForStandardWindowButton:(NSWindowButton)button {
  return NO;
}

@end

namespace bark {

bool SetWindowChrome(gfx::NativeWindow native_window,
                     double titlebar_height,
                     double leading_inset) {
  BarkNSWindow* window =
      base::apple::ObjCCast<BarkNSWindow>(native_window.GetNativeNSWindow());
  if (!window) {
    return false;
  }
  window.barkTitlebarHeight = titlebar_height;
  window.barkLeadingInset = leading_inset;
  NSView* frame = window.contentView.superview;
  if ([frame respondsToSelector:@selector(_updateButtonPositions)]) {
    [(NSThemeFrame*)frame _updateButtonPositions];
  }
  return true;
}

BarkNativeWidgetMac::BarkNativeWidgetMac(base::WeakPtr<BarkWindowHost> host,
                                         views::Widget* widget)
    : NativeWidgetMac(widget), host_(std::move(host)) {}

BarkNativeWidgetMac::~BarkNativeWidgetMac() = default;

BrowserWindowInterface* BarkNativeWidgetMac::SelectedBrowser() const {
  auto* selected = host_ ? host_->selected() : nullptr;
  return selected && !selected->browser()->IsDeleteScheduled()
             ? selected->browser()
             : nullptr;
}

void BarkNativeWidgetMac::ValidateUserInterfaceItem(
    int32_t command,
    remote_cocoa::mojom::ValidateUserInterfaceItemResult* result) {
  if (!HostWindowOffersCommand(command)) {
    result->enable = false;
    result->set_hidden_state = true;
    result->new_hidden_state = true;
    return;
  }
  auto* browser = SelectedBrowser();
  result->enable = browser && chrome::SupportsCommand(browser, command) &&
                   chrome::IsCommandEnabled(browser, command);
}

bool BarkNativeWidgetMac::WillExecuteCommand(
    int32_t command,
    WindowOpenDisposition window_open_disposition,
    bool is_before_first_responder) {
  auto* browser = SelectedBrowser();
  if (!browser) {
    return false;
  }
  if (!is_before_first_responder) {
    return HostWindowOffersCommand(command);
  }
  if (ui::GlobalAcceleratorListener::GetInstance() &&
      ui::GlobalAcceleratorListener::GetInstance()
          ->IsShortcutHandlingSuspended()) {
    return false;
  }
  // IsReservedCommandOrKey does not read its event on macOS.
  input::NativeWebKeyboardEvent unused_event(
      blink::WebInputEvent::Type::kKeyDown, 0, base::TimeTicks());
  return chrome::BrowserCommandController::From(browser)
      ->IsReservedCommandOrKey(command, unused_event);
}

bool BarkNativeWidgetMac::ExecuteCommand(
    int32_t command,
    WindowOpenDisposition window_open_disposition,
    bool is_before_first_responder) {
  if (!WillExecuteCommand(command, window_open_disposition,
                          is_before_first_responder)) {
    return false;
  }
  chrome::ExecuteCommandWithDisposition(SelectedBrowser(), command,
                                        window_open_disposition);
  return true;
}

views::internal::NativeWidgetPrivate*
BarkNativeWidgetMac::AsNativeWidgetPrivate() {
  return this;
}

void BarkNativeWidgetMac::PopulateCreateWindowParams(
    const views::Widget::InitParams& widget_params,
    remote_cocoa::mojom::CreateWindowParams* params) {
  params->style_mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                       NSWindowStyleMaskMiniaturizable |
                       NSWindowStyleMaskResizable |
                       NSWindowStyleMaskFullSizeContentView;
  params->window_class = remote_cocoa::mojom::WindowClass::kBrowser;
  params->titlebar_appears_transparent = true;
  params->window_title_hidden = true;
  params->animation_enabled = true;
}

NativeWidgetMacNSWindow* BarkNativeWidgetMac::CreateNSWindow(
    const remote_cocoa::mojom::CreateWindowParams* params) {
  BarkNSWindow* window =
      [[BarkNSWindow alloc] initWithContentRect:ui::kWindowSizeDeterminedLater
                                      styleMask:params->style_mask
                                        backing:NSBackingStoreBuffered
                                          defer:NO];
  window.releasedWhenClosed = NO;
  window.titlebarAppearsTransparent = YES;
  window.titleVisibility = NSWindowTitleHidden;
  window.animationBehavior = NSWindowAnimationBehaviorDocumentWindow;
  return window;
}

void BarkNativeWidgetMac::OnWindowInitialized() {
  if (auto* bridge = GetInProcessNSWindowBridge()) {
    bridge->SetCommandDispatcher(
        [[ChromeCommandDispatcherDelegate alloc] init],
        [[BrowserWindowCommandHandler alloc] init]);
  }
}

}  // namespace bark
