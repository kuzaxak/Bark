#include "bark/browser/ui/bark_window_host.h"

#import <AppKit/AppKit.h>

#include <utility>

#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_native_widget_mac.h"
#include "base/functional/bind.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window_state.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/exclusive_access/fullscreen_controller.h"
#include "chrome/browser/ui/window_metadata/window_metadata_controller.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/layout/fill_layout.h"
#include "ui/views/view.h"
#include "ui/views/view_class_properties.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/window/client_view.h"

namespace bark {

namespace {
constexpr char kBarkWindowHostKey[] = "__BARK_WINDOW_HOST__";
}  // namespace

// AppKit's close button asks the client view before closing the NSWindow; the
// host answers by running its clients' close, which may prompt.
class BarkWindowHost::ClientView : public views::ClientView {
 public:
  ClientView(views::Widget* widget,
             views::View* contents,
             BarkWindowHost* host)
      : views::ClientView(widget, contents), host_(host) {}

  views::CloseRequestResult OnWindowCloseRequested() override {
    host_->OnCloseRequested(views::Widget::ClosedReason::kCloseButtonClicked);
    return views::CloseRequestResult::kCannotClose;
  }

 private:
  raw_ptr<BarkWindowHost> host_;
};

class BarkWindowHost::Delegate : public views::WidgetDelegate {
 public:
  explicit Delegate(BarkWindowHost* host) : host_(host) {
    SetCanResize(true);
    SetCanMaximize(true);
    SetCanFullscreen(true);
    SetCanMinimize(true);
  }

  bool ShouldSaveWindowPlacement() const override {
    auto* browser = Browser();
    return browser && !host_->widget()->IsFullscreen() &&
           chrome::ShouldSaveWindowPlacement(browser);
  }
  void SaveWindowPlacement(const gfx::Rect& bounds,
                           ui::mojom::WindowShowState show_state) override {
    views::WidgetDelegate::SaveWindowPlacement(bounds, show_state);
    if (auto* browser = Browser()) {
      chrome::SaveWindowPlacement(browser, bounds, show_state);
    }
  }
  bool GetSavedWindowPlacement(
      const views::Widget* widget,
      gfx::Rect* bounds,
      ui::mojom::WindowShowState* show_state) const override {
    auto* browser = Browser();
    if (!browser) {
      return false;
    }
    chrome::GetSavedWindowBoundsAndShowState(browser, bounds, show_state);
    return true;
  }
  views::ClientView* CreateClientView(views::Widget* widget) override {
    return new ClientView(widget, TransferOwnershipOfContentsView(), host_);
  }
  std::u16string GetWindowTitle() const override {
    auto* browser = Browser();
    return browser ? WindowMetadataController::From(browser)
                         ->GetWindowTitleForCurrentTab(true)
                   : std::u16string();
  }

 private:
  BrowserWindowInterface* Browser() const {
    auto* selected = host_->selected();
    return selected ? selected->browser() : nullptr;
  }

  raw_ptr<BarkWindowHost> host_;
};

// static
BarkWindowHost* BarkWindowHost::ForBrowser(
    const BrowserWindowInterface* browser) {
  auto* window = BarkBrowserWindow::FromBrowser(browser);
  return window ? window->host() : nullptr;
}

// static
BarkWindowHost* BarkWindowHost::ForNativeWindow(gfx::NativeWindow window) {
  auto* widget = window ? views::Widget::GetWidgetForNativeWindow(window)
                        : nullptr;
  return widget ? static_cast<BarkWindowHost*>(
                      widget->GetNativeWindowProperty(kBarkWindowHostKey))
                : nullptr;
}

BarkWindowHost::BarkWindowHost(BarkBrowserWindow* first_client)
    : physical_group_(
          static_cast<uint64_t>(first_client->browser()->GetSessionID().id())),
      selected_(first_client),
      delegate_(std::make_unique<Delegate>(this)),
      widget_(std::make_unique<views::Widget>()) {
  clients_.push_back(first_client);
  auto contents = std::make_unique<views::View>();
  contents->SetLayoutManager(std::make_unique<views::FillLayout>());
  root_host_ =
      contents->AddChildView(std::make_unique<views::NativeViewHost>());
  anchor_ = contents->AddChildView(std::make_unique<views::View>());
  anchor_->SetProperty(views::kViewIgnoredByLayoutKey, true);
  delegate_->SetContentsView(std::move(contents));
  views::Widget::InitParams params(
      views::Widget::InitParams::CLIENT_OWNS_WIDGET);
  params.name = "BarkWindowHost";
  chrome::GetSavedWindowBoundsAndShowState(first_client->browser(),
                                           &params.bounds, &params.show_state);
  params.delegate = delegate_.get();
  params.native_widget =
      new BarkNativeWidgetMac(weak_factory_.GetWeakPtr(), widget_.get());
  widget_->Init(std::move(params));
  widget_->AddObserver(this);
  widget_->SetNativeWindowProperty(kBarkWindowHostKey, this);
  ArmClose();
}

BarkWindowHost::~BarkWindowHost() {
  closing_ = true;
  root_host_ = nullptr;
  anchor_ = nullptr;
  if (widget_) {
    widget_->RemoveObserver(this);
    widget_->SetNativeWindowProperty(kBarkWindowHostKey, nullptr);
  }
  widget_.reset();
}

void BarkWindowHost::RemoveClient(BarkBrowserWindow* client) {
  std::erase(clients_, client);
  if (selected_ == client) {
    selected_ = clients_.empty() ? nullptr : clients_.front().get();
  }
}

bool BarkWindowHost::Select(BarkBrowserWindow* client) {
  if (closing_ || !std::ranges::contains(clients_, client)) {
    return false;
  }
  selected_ = client;
  return true;
}

bool BarkWindowHost::SetRootView(gfx::NativeView root) {
  NSView* view = root.GetNativeNSView();
  if (closing_ || !root_host_ || !view) {
    return false;
  }
  NSView* current = root_host_->native_view().GetNativeNSView();
  if (current) {
    return current == view;
  }
  NSWindow* window = widget_->GetNativeWindow().GetNativeNSWindow();
  if (view.window && view.window != window) {
    return false;
  }
  root_host_->Attach(root);
  return root_host_ && root_host_->native_view().GetNativeNSView() == view;
}

gfx::NativeView BarkWindowHost::root_view() const {
  return root_host_ ? root_host_->native_view() : gfx::NativeView();
}

bool BarkWindowHost::SetChrome(double titlebar_height, double leading_inset) {
  return !closing_ && widget_ &&
         SetWindowChrome(widget_->GetNativeWindow(), titlebar_height,
                         leading_inset);
}

void BarkWindowHost::AddObserver(Observer* observer) {
  observers_.AddObserver(observer);
}

void BarkWindowHost::RemoveObserver(Observer* observer) {
  observers_.RemoveObserver(observer);
}

void BarkWindowHost::NotifyPageViewRetiring(int32_t window,
                                            int32_t tab,
                                            gfx::NativeView view) {
  observers_.Notify(&Observer::OnPageViewRetiring, window, tab, view);
}

void BarkWindowHost::NotifyPageCrashed(int32_t window,
                                       int32_t tab,
                                       gfx::NativeView view,
                                       bool crashed) {
  observers_.Notify(&Observer::OnPageCrashed, window, tab, view, crashed);
}

void BarkWindowHost::SetFullscreen(BarkBrowserWindow* client,
                                   bool fullscreen) {
  if (closing_ || client != selected_) {
    return;
  }
  widget_->SetFullscreen(fullscreen);
  UpdateFullscreen();
}

void BarkWindowHost::UpdateFullscreen() {
  if (closing_ || !widget_) {
    return;
  }
  const bool widget_fullscreen = widget_->IsFullscreen();
  HostFullscreen kind = HostFullscreen::kNone;
  if (widget_fullscreen) {
    auto* manager =
        selected_ ? ExclusiveAccessManager::From(selected_->browser())
                  : nullptr;
    kind = manager && manager->fullscreen_controller()->IsTabFullscreen()
               ? HostFullscreen::kPage
               : HostFullscreen::kWindow;
  }
  const bool widget_changed = widget_fullscreen != widget_fullscreen_;
  const bool kind_changed = kind != fullscreen_kind_;
  widget_fullscreen_ = widget_fullscreen;
  fullscreen_kind_ = kind;
  if (kind_changed && selected_) {
    observers_.Notify(&Observer::OnFullscreenChanged,
                      selected_->browser()->GetSessionID().id(), kind);
  }
  if (!widget_changed) {
    return;
  }
  scoped_refptr<BarkWindowHost> keep_alive(this);
  std::vector<base::WeakPtr<BarkBrowserWindow>> clients;
  for (auto& client : clients_) {
    clients.push_back(client->GetWeakPtr());
  }
  for (auto& client : clients) {
    if (client) {
      client->OnHostFullscreenChanged();
    }
  }
}

views::View* BarkWindowHost::AnchorAt(const gfx::Point& screen_point) {
  if (!anchor_) {
    return nullptr;
  }
  gfx::Point point = screen_point;
  views::View::ConvertPointFromScreen(anchor_->parent(), &point);
  anchor_->SetBoundsRect(gfx::Rect(point, gfx::Size()));
  return anchor_;
}

void BarkWindowHost::OnWidgetBoundsChanged(views::Widget* widget,
                                           const gfx::Rect& new_bounds) {
  for (auto& client : clients_) {
    client->OnHostBoundsChanged();
  }
}

void BarkWindowHost::OnWidgetShowStateChanged(views::Widget* widget) {
  UpdateFullscreen();
}

void BarkWindowHost::OnWidgetActivationChanged(views::Widget* widget,
                                               bool active) {
  if (selected_) {
    selected_->OnHostActivationChanged(active);
  }
}

void BarkWindowHost::OnWidgetDestroying(views::Widget* widget) {
  closing_ = true;
  root_host_ = nullptr;
  anchor_ = nullptr;
}

void BarkWindowHost::ArmClose() {
  widget_->MakeCloseSynchronous(base::BindOnce(
      &BarkWindowHost::OnCloseRequested, weak_factory_.GetWeakPtr()));
}

void BarkWindowHost::OnCloseRequested(views::Widget::ClosedReason reason) {
  ArmClose();
  scoped_refptr<BarkWindowHost> keep_alive(this);
  std::vector<base::WeakPtr<BarkBrowserWindow>> clients;
  for (auto& client : clients_) {
    clients.push_back(client->GetWeakPtr());
  }
  for (auto& client : clients) {
    if (client) {
      client->Close();
    }
  }
}

}  // namespace bark
