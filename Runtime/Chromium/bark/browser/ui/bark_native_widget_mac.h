#ifndef BARK_BROWSER_UI_BARK_NATIVE_WIDGET_MAC_H_
#define BARK_BROWSER_UI_BARK_NATIVE_WIDGET_MAC_H_

#include "base/memory/weak_ptr.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/views/widget/native_widget_mac.h"

class BrowserWindowInterface;

namespace bark {

class BarkWindowHost;

// Centres the window's traffic lights in a titlebar `titlebar_height` tall,
// the first one `leading_inset` from the window's leading edge. False for a
// window that is not a Bark host window.
bool SetWindowChrome(gfx::NativeWindow window,
                     double titlebar_height,
                     double leading_inset);

// The host widget's native side: Bark's NSWindow class, the command
// dispatcher and the app's key filter, after WebUIBrowserNativeWidgetMac.
class BarkNativeWidgetMac : public views::NativeWidgetMac {
 public:
  BarkNativeWidgetMac(base::WeakPtr<BarkWindowHost> host,
                      views::Widget* widget);
  BarkNativeWidgetMac(const BarkNativeWidgetMac&) = delete;
  BarkNativeWidgetMac& operator=(const BarkNativeWidgetMac&) = delete;
  ~BarkNativeWidgetMac() override;

 private:
  // views::NativeWidgetMac:
  void ValidateUserInterfaceItem(
      int32_t command,
      remote_cocoa::mojom::ValidateUserInterfaceItemResult* result) override;
  bool WillExecuteCommand(int32_t command,
                          WindowOpenDisposition window_open_disposition,
                          bool is_before_first_responder) override;
  bool ExecuteCommand(int32_t command,
                      WindowOpenDisposition window_open_disposition,
                      bool is_before_first_responder) override;
  views::internal::NativeWidgetPrivate* AsNativeWidgetPrivate() override;
  void PopulateCreateWindowParams(
      const views::Widget::InitParams& widget_params,
      remote_cocoa::mojom::CreateWindowParams* params) override;
  NativeWidgetMacNSWindow* CreateNSWindow(
      const remote_cocoa::mojom::CreateWindowParams* params) override;
  void OnWindowInitialized() override;

  BrowserWindowInterface* SelectedBrowser() const;

  base::WeakPtr<BarkWindowHost> host_;
};

}  // namespace bark

#endif  // BARK_BROWSER_UI_BARK_NATIVE_WIDGET_MAC_H_
