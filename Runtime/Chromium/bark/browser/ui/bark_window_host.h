#ifndef BARK_BROWSER_UI_BARK_WINDOW_HOST_H_
#define BARK_BROWSER_UI_BARK_WINDOW_HOST_H_

#include <stdint.h>

#include <memory>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/memory/ref_counted.h"
#include "base/memory/weak_ptr.h"
#include "base/observer_list.h"
#include "base/observer_list_types.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_observer.h"

class BrowserWindowInterface;

namespace views {
class NativeViewHost;
class View;
}  // namespace views

namespace bark {

class BarkBrowserWindow;

enum class HostFullscreen { kNone, kWindow, kPage };

// One physical window. It owns the views::Widget, the NSWindow behind it and
// the one view host that shows the app's root NSView. Every BarkBrowserWindow
// shown in the window holds a reference; the last one to go closes it.
class BarkWindowHost : public base::RefCounted<BarkWindowHost>,
                       public views::WidgetObserver {
 public:
  class Observer : public base::CheckedObserver {
   public:
    // Sent before `tab`'s page view leaves this window: the tab is closing,
    // moving to another window or replacing its contents. `window` is the
    // session id of the client that held the tab.
    virtual void OnPageViewRetiring(int32_t window,
                                    int32_t tab,
                                    gfx::NativeView view) {}
    // `window` is the selected client's session id.
    virtual void OnFullscreenChanged(int32_t window, HostFullscreen kind) {}
    // `tab`'s renderer died (`crashed`) or its page has one again.
    virtual void OnPageCrashed(int32_t window,
                               int32_t tab,
                               gfx::NativeView view,
                               bool crashed) {}
  };

  static BarkWindowHost* ForBrowser(const BrowserWindowInterface* browser);
  static BarkWindowHost* ForNativeWindow(gfx::NativeWindow window);

  explicit BarkWindowHost(BarkBrowserWindow* first_client);
  BarkWindowHost(const BarkWindowHost&) = delete;
  BarkWindowHost& operator=(const BarkWindowHost&) = delete;

  views::Widget* widget() { return widget_.get(); }
  const views::Widget* widget() const { return widget_.get(); }
  uint64_t physical_group() const { return physical_group_; }

  BarkBrowserWindow* selected() const { return selected_; }
  const std::vector<raw_ptr<BarkBrowserWindow>>& clients() const {
    return clients_;
  }
  // False once the window is closing.
  bool AddClient(BarkBrowserWindow* client);
  void RemoveClient(BarkBrowserWindow* client);
  // Makes `client` the one the window shows and answers for: lookups by
  // window, activation, the title and full-screen events follow it.
  bool Select(BarkBrowserWindow* client);

  // The app's root view is set once. Setting the same view again succeeds; a
  // different one is refused.
  bool SetRootView(gfx::NativeView root);
  gfx::NativeView root_view() const;

  // Places the traffic lights; see bark::SetWindowChrome.
  bool SetChrome(double titlebar_height, double leading_inset);

  // True once the widget began closing for good; no client may reopen it.
  bool closing() const { return closing_; }

  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);
  void NotifyPageViewRetiring(int32_t window, int32_t tab, gfx::NativeView view);
  void NotifyPageCrashed(int32_t window,
                         int32_t tab,
                         gfx::NativeView view,
                         bool crashed);
  base::WeakPtr<BarkWindowHost> GetWeakPtr() {
    return weak_factory_.GetWeakPtr();
  }

  // Applies a full-screen request from a client's exclusive-access context.
  void SetFullscreen(BarkBrowserWindow* client, bool fullscreen);
  HostFullscreen fullscreen_kind() const { return fullscreen_kind_; }
  // Reads the window's and the selected client's full-screen state again.
  void UpdateFullscreen();

  // A view with no size at `screen_point`, for bubbles that would hang off a
  // toolbar. Null once the widget is gone.
  views::View* AnchorAt(const gfx::Point& screen_point);

  // views::WidgetObserver:
  void OnWidgetBoundsChanged(views::Widget* widget,
                             const gfx::Rect& new_bounds) override;
  void OnWidgetShowStateChanged(views::Widget* widget) override;
  void OnWidgetActivationChanged(views::Widget* widget, bool active) override;
  void OnWidgetDestroying(views::Widget* widget) override;

 private:
  friend class base::RefCounted<BarkWindowHost>;
  class ClientView;
  class Delegate;
  ~BarkWindowHost() override;

  void ArmClose();
  void OnCloseRequested(views::Widget::ClosedReason reason);
  void SetSelected(BarkBrowserWindow* client, bool previous_stays);
  HostFullscreen CurrentFullscreenKind() const;
  // Closes every client once each one's beforeunload handlers agreed; one
  // refusal keeps them all.
  void CloseClients();
  void OnClientsCloseConfirmed(bool proceed);

  const uint64_t physical_group_;
  std::vector<raw_ptr<BarkBrowserWindow>> clients_;
  raw_ptr<BarkBrowserWindow> selected_ = nullptr;
  std::unique_ptr<Delegate> delegate_;
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<views::NativeViewHost> root_host_ = nullptr;
  raw_ptr<views::View> anchor_ = nullptr;
  bool closing_ = false;
  bool resetting_close_ = false;
  bool widget_fullscreen_ = false;
  HostFullscreen fullscreen_kind_ = HostFullscreen::kNone;
  base::ObserverList<Observer> observers_;
  base::WeakPtrFactory<BarkWindowHost> weak_factory_{this};
};

}  // namespace bark

#endif  // BARK_BROWSER_UI_BARK_WINDOW_HOST_H_
