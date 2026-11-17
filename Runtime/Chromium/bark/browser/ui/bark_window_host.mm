#include "bark/browser/ui/bark_window_host.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <utility>

#include "bark/bridge/barc_bridge.h"
#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_native_widget_mac.h"
#include "base/apple/foundation_util.h"
#include "base/auto_reset.h"
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/ui/browser_element_identifiers.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/bubble_anchor_util_views.h"
#include "chrome/browser/ui/views/chrome_layout_provider.h"
#include "content/public/browser/web_contents.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window_state.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/exclusive_access/fullscreen_controller.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/ui/window_metadata/window_metadata_controller.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/layout/fill_layout.h"
#include "ui/views/view.h"
#include "ui/views/view_class_properties.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/window/client_view.h"

namespace bark {

namespace {
constexpr char kBarkWindowHostKey[] = "__BARK_WINDOW_HOST__";
constexpr int kTrailingAnchorInset = 8;
}  // namespace

// Tells the host when the page view it last saw selected changes its frame:
// the app lays the page out again on sidebar toggle and Library without the
// window moving.
class BarkWindowHost::PageWatch {
 public:
  PageWatch(NSView* page, BarkWindowHost* host) : page_(page) {
    page.postsFrameChangedNotifications = YES;
    observer_ = [NSNotificationCenter.defaultCenter
        addObserverForName:NSViewFrameDidChangeNotification
                    object:page
                     queue:nil
                usingBlock:^(NSNotification*) {
                  host->OnSelectedPageChanged();
                }];
  }
  ~PageWatch() { [NSNotificationCenter.defaultCenter removeObserver:observer_]; }
  NSView* page() const { return page_; }

 private:
  __weak NSView* page_;
  id observer_;
};

// Gives the window's keys back when it is key again and nobody in it has them:
// to the app's view that had them, or else to the selected client's page.
// Views takes the keys from the window's views when it stops being key and
// gives them back only to its own views, and AppKit makes no window key when a
// key child, such as one of the window's dialogs, closes.
class BarkWindowHost::KeyReturn {
 public:
  KeyReturn(NSWindow* window, BarkWindowHost* host)
      : window_(window), host_(host) {
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    __weak NSWindow* weak_window = window;
    resign_observer_ = [center
        addObserverForName:NSWindowDidResignKeyNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* notification) {
                  NSWindow* resigned = notification.object;
                  if (resigned == weak_window) {
                    WindowResigned();
                  } else if (resigned == child_) {
                    ChildResigned();
                  }
                }];
    become_observer_ = [center
        addObserverForName:NSWindowDidBecomeKeyNotification
                    object:window
                     queue:nil
                usingBlock:^(NSNotification*) {
                  // Chromium sets the window's keys while it handles becoming
                  // key; give them back after it.
                  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
                      FROM_HERE, base::BindOnce(&KeyReturn::GiveBack,
                                                weak_factory_.GetWeakPtr()));
                }];
  }
  ~KeyReturn() {
    [NSNotificationCenter.defaultCenter removeObserver:resign_observer_];
    [NSNotificationCenter.defaultCenter removeObserver:become_observer_];
  }

 private:
  bool Empty(NSResponder* responder) const {
    return responder == window_ || responder == window_.contentView;
  }

  // The new key window is known only once AppKit has finished the change.
  void WindowResigned() {
    NSResponder* responder = window_.firstResponder;
    if (auto* editor = base::apple::ObjCCast<NSTextView>(responder);
        editor && editor.fieldEditor) {
      responder = base::apple::ObjCCast<NSResponder>(editor.delegate);
    }
    NSView* holder = base::apple::ObjCCast<NSView>(responder);
    holder_ =
        holder && !Empty(holder) &&
                ![holder isKindOfClass:NSClassFromString(
                                           @"RenderWidgetHostViewCocoa")]
            ? holder
            : nil;
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](base::WeakPtr<KeyReturn> self) {
                         if (self &&
                             NSApp.keyWindow.parentWindow == self->window_) {
                           self->child_ = NSApp.keyWindow;
                         }
                       },
                       weak_factory_.GetWeakPtr()));
  }

  void ChildResigned() {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](base::WeakPtr<KeyReturn> self) {
                         if (self && !NSApp.keyWindow &&
                             NSApp.active && self->window_.visible &&
                             !self->window_.miniaturized) {
                           [self->window_ makeKeyWindow];
                         }
                       },
                       weak_factory_.GetWeakPtr()));
  }

  void GiveBack() {
    NSView* holder = holder_;
    holder_ = nil;
    child_ = nil;
    if (!window_.keyWindow || !Empty(window_.firstResponder)) {
      return;
    }
    if (holder && holder.window == window_ &&
        [window_ makeFirstResponder:holder]) {
      return;
    }
    host_->FocusSelectedPage();
  }

  __weak NSWindow* window_;
  raw_ptr<BarkWindowHost> host_;
  // The app's view that had the keys when the window stopped being key.
  __weak NSView* holder_ = nil;
  // The child window that took the keys from the window.
  __weak NSWindow* child_ = nil;
  id resign_observer_ = nil;
  id become_observer_ = nil;
  base::WeakPtrFactory<KeyReturn> weak_factory_{this};
};

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
  for (auto* anchor : {&leading_anchor_, &trailing_anchor_, &page_anchor_}) {
    *anchor = contents->AddChildView(std::make_unique<views::View>());
    (*anchor)->SetProperty(views::kViewIgnoredByLayoutKey, true);
  }
  page_anchor_->SetProperty(views::kElementIdentifierKey,
                            kTopContainerElementId);
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
  key_return_ = std::make_unique<KeyReturn>(
      widget_->GetNativeWindow().GetNativeNSWindow(), this);
  ArmClose();
}

BarkWindowHost::~BarkWindowHost() {
  closing_ = true;
  key_return_.reset();
  page_watch_.reset();
  root_host_ = nullptr;
  leading_anchor_ = trailing_anchor_ = page_anchor_ = nullptr;
  if (widget_) {
    widget_->RemoveObserver(this);
    widget_->SetNativeWindowProperty(kBarkWindowHostKey, nullptr);
  }
  widget_.reset();
}

bool BarkWindowHost::AddClient(BarkBrowserWindow* client) {
  if (closing_ || !widget_) {
    return false;
  }
  clients_.push_back(client);
  return true;
}

void BarkWindowHost::RemoveClient(BarkBrowserWindow* client) {
  std::erase(clients_, client);
  if (selected_ != client) {
    return;
  }
  selected_ = nullptr;
  if (!clients_.empty() && !closing_) {
    SetSelected(clients_.front(), false);
  }
}

bool BarkWindowHost::Select(BarkBrowserWindow* client) {
  if (closing_ || !std::ranges::contains(clients_, client) ||
      client->browser()->IsDeleteScheduled()) {
    return false;
  }
  if (client != selected_) {
    SetSelected(client, true);
  }
  return selected_ == client;
}

void BarkWindowHost::SetSelected(BarkBrowserWindow* client,
                                 bool previous_stays) {
  scoped_refptr<BarkWindowHost> keep_alive(this);
  auto previous = previous_stays && selected_ ? selected_->GetWeakPtr()
                                              : base::WeakPtr<BarkBrowserWindow>();
  auto incoming = client->GetWeakPtr();
  selected_ = client;
  if (client->browser()->IsDeleteScheduled()) {
    return;
  }
  const bool active = widget_ && widget_->IsActive();
  if (previous && active) {
    previous->OnHostActivationChanged(false);
  }
  if (incoming && active && selected_ == incoming.get()) {
    incoming->OnHostActivationChanged(true);
  }
  if (!incoming || selected_ != incoming.get() || closing_) {
    return;
  }
  OnSelectedPageChanged();
  widget_->UpdateWindowTitle();
  fullscreen_kind_ = CurrentFullscreenKind();
  observers_.Notify(&Observer::OnFullscreenChanged,
                    incoming->browser()->GetSessionID().id(), fullscreen_kind_);
  barc::BrowserDiscoveryChanged();
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
  const HostFullscreen kind = CurrentFullscreenKind();
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

HostFullscreen BarkWindowHost::CurrentFullscreenKind() const {
  if (!widget_ || !widget_->IsFullscreen()) {
    return HostFullscreen::kNone;
  }
  auto* manager =
      selected_ ? ExclusiveAccessManager::From(selected_->browser()) : nullptr;
  return manager && manager->fullscreen_controller()->IsTabFullscreen()
             ? HostFullscreen::kPage
             : HostFullscreen::kWindow;
}

views::View* BarkWindowHost::LeadingAnchor() {
  UpdateAnchors();
  return leading_anchor_;
}

views::View* BarkWindowHost::TrailingAnchor() {
  UpdateAnchors();
  return trailing_anchor_;
}

views::View* BarkWindowHost::PageAnchor() {
  UpdateAnchors();
  return page_anchor_;
}

void BarkWindowHost::UpdateAnchors() {
  if (!page_anchor_ || !selected_) {
    return;
  }
  gfx::Rect page = selected_->GetPageBoundsInScreen();
  gfx::Point origin = page.origin();
  views::View::ConvertPointFromScreen(page_anchor_->parent(), &origin);
  page.set_origin(origin);
  // Chromium's toast hangs from the bottom of this view, up to its full
  // height below it in page full screen; the strip left off the page's foot
  // keeps the pill inside the page in both cases.
  const int toast_strip =
      ChromeLayoutProvider::Get()->GetDistanceMetric(
          DISTANCE_TOAST_BUBBLE_HEIGHT) -
      views::BubbleBorder::kShadowBlur + kTrailingAnchorInset;
  page_anchor_->SetBoundsRect(gfx::Rect(
      page.x(), page.y(), page.width(), std::max(0, page.height() - toast_strip)));
  leading_anchor_->SetBoundsRect(gfx::Rect(
      page.x() + bubble_anchor_util::kNoToolbarLeftOffset, page.y(), 0, 0));
  trailing_anchor_->SetBoundsRect(
      gfx::Rect(page.right() - kTrailingAnchorInset, page.y(), 0, 0));
}

void BarkWindowHost::WatchSelectedPage() {
  auto* contents =
      selected_ ? selected_->browser()->GetTabStripModel()->GetActiveWebContents()
                : nullptr;
  NSView* page = contents ? contents->GetNativeView().GetNativeNSView() : nil;
  if (page_watch_ && page_watch_->page() == page) {
    return;
  }
  page_watch_ = page ? std::make_unique<PageWatch>(page, this) : nullptr;
}

void BarkWindowHost::FocusSelectedPage() {
  auto* contents =
      selected_ ? selected_->browser()->GetTabStripModel()->GetActiveWebContents()
                : nullptr;
  if (contents) {
    contents->Focus();
  }
}

void BarkWindowHost::OnSelectedPageChanged() {
  if (closing_) {
    return;
  }
  WatchSelectedPage();
  UpdateAnchors();
  if (selected_) {
    selected_->OnHostBoundsChanged();
  }
}

void BarkWindowHost::OnClientActiveTabChanged(BarkBrowserWindow* client) {
  if (client == selected_) {
    OnSelectedPageChanged();
  }
}

void BarkWindowHost::OnWidgetBoundsChanged(views::Widget* widget,
                                           const gfx::Rect& new_bounds) {
  UpdateAnchors();
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
  barc::BrowserDiscoveryChanged();
}

void BarkWindowHost::OnWidgetDestroying(views::Widget* widget) {
  closing_ = true;
  key_return_.reset();
  page_watch_.reset();
  root_host_ = nullptr;
  leading_anchor_ = trailing_anchor_ = page_anchor_ = nullptr;
}

void BarkWindowHost::ArmClose() {
  widget_->MakeCloseSynchronous(base::BindOnce(
      &BarkWindowHost::OnCloseRequested, weak_factory_.GetWeakPtr()));
}

void BarkWindowHost::OnCloseRequested(views::Widget::ClosedReason reason) {
  ArmClose();
  if (clients_.size() > 1) {
    for (auto& client : clients_) {
      if (UnloadController::From(client->browser())
              ->is_attempting_to_close_browser()) {
        return;
      }
    }
    CloseClients();
    return;
  }
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

void BarkWindowHost::CloseClients() {
  scoped_refptr<BarkWindowHost> keep_alive(this);
  std::vector<base::WeakPtr<BarkBrowserWindow>> clients;
  for (auto& client : clients_) {
    clients.push_back(client->GetWeakPtr());
  }
  for (auto& client : clients) {
    if (client && !closing_ &&
        UnloadController::From(client->browser())->RunBeforeUnloadForShutdown(
            false, base::BindRepeating(&BarkWindowHost::OnClientsCloseConfirmed,
                                       weak_factory_.GetWeakPtr()))) {
      return;
    }
  }
  if (widget_ && !closing_) {
    widget_->Hide();
  }
  for (auto& client : clients) {
    if (client) {
      client->Close();
    }
  }
}

void BarkWindowHost::OnClientsCloseConfirmed(bool proceed) {
  if (proceed) {
    CloseClients();
    return;
  }
  if (resetting_close_) {
    return;
  }
  scoped_refptr<BarkWindowHost> keep_alive(this);
  base::AutoReset<bool> resetting(&resetting_close_, true);
  std::vector<base::WeakPtr<BarkBrowserWindow>> clients;
  for (auto& client : clients_) {
    clients.push_back(client->GetWeakPtr());
  }
  for (auto& client : clients) {
    if (client) {
      UnloadController::From(client->browser())->ResetBeforeUnloadForShutdown();
    }
  }
}

}  // namespace bark
