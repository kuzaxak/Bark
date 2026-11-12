#include "bark/browser/ui/bark_native_widget_mac.h"

#import <AppKit/AppKit.h>

#include "bark/bridge/barc_runtime_startup.h"
#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_window_host.h"
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

@interface BarkNSWindow : NativeWidgetMacNSWindow
@end

@implementation BarkNSWindow
@end

namespace bark {

BarkNativeWidgetMac::BarkNativeWidgetMac(base::WeakPtr<BarkWindowHost> host,
                                         views::Widget* widget)
    : NativeWidgetMac(widget), host_(std::move(host)) {}

BarkNativeWidgetMac::~BarkNativeWidgetMac() = default;

BrowserWindowInterface* BarkNativeWidgetMac::SelectedBrowser() const {
  auto* selected = host_ ? host_->selected() : nullptr;
  return selected ? selected->browser() : nullptr;
}

void BarkNativeWidgetMac::ValidateUserInterfaceItem(
    int32_t command,
    remote_cocoa::mojom::ValidateUserInterfaceItemResult* result) {
  auto* browser = SelectedBrowser();
  result->enable = browser && chrome::SupportsCommand(browser, command) &&
                   chrome::IsCommandEnabled(browser, command);
}

bool BarkNativeWidgetMac::WillExecuteCommand(
    int32_t command,
    WindowOpenDisposition window_open_disposition,
    bool is_before_first_responder) {
  auto* browser = SelectedBrowser();
  if (!browser ||
      barc::KeyCommandBelongsToApplication(GetNativeWindow(), command)) {
    return false;
  }
  if (!is_before_first_responder) {
    return true;
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
