#import <AppKit/AppKit.h>

#include "chrome/browser/ui/views/frame/barc_bridge.h"

#include <algorithm>
#include <array>
#include <memory>
#include <string>
#include <string_view>

#include "base/command_line.h"
#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/strings/utf_string_conversions.h"
#include "base/version_info/version_info.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/ui/views/frame/browser_widget.h"
#include "components/sessions/core/session_id.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/referrer.h"
#include "ui/base/base_window.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/views/controls/native/native_view_host.h"
#include "url/gurl.h"

namespace {
BrowserWindowInterface* Window(int32_t id) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      id <= 0)
    return nullptr;
  auto* collection = GlobalBrowserCollection::GetInstance();
  auto* window =
      collection
          ? collection->FindBrowserWithID(SessionID::FromSerializedValue(id))
          : nullptr;
  return window && !window->IsDeleteScheduled() ? window : nullptr;
}
tabs::TabInterface* LookupTab(BrowserWindowInterface* window, int32_t id) {
  if (!window || id == 0)
    return nullptr;
  auto* tab = tabs::TabHandle(id).Get();
  return tab && tab->GetBrowserWindowInterface() == window ? tab : nullptr;
}
GURL URL(const char* value) {
  return value ? GURL(value) : GURL();
}
}  // namespace

uint32_t barc_bridge_version() {
  return 1;
}
const char* barc_chromium_version() {
  return version_info::GetVersionNumber().data();
}
int32_t barc_window_new_peer(int32_t source) {
  auto* window = Window(source);
  if (!window)
    return 0;
  auto* peer = CreateBrowserWindow(
      BrowserWindowCreateParams(*window->GetProfile(), true));
  return peer ? peer->GetSessionID().id() : 0;
}
int barc_window_close(int32_t id) {
  auto* window = Window(id);
  if (!window)
    return 0;
  window->GetWindow()->Close();
  return 1;
}
size_t barc_window_tab_count(int32_t id) {
  auto* window = Window(id);
  return window ? window->GetTabStripModel()->count() : 0;
}
int32_t barc_window_tab_at(int32_t id, size_t index) {
  auto* window = Window(id);
  if (!window ||
      index >= static_cast<size_t>(window->GetTabStripModel()->count()))
    return 0;
  return window->GetTabStripModel()
      ->GetTabAtIndex(static_cast<int>(index))
      ->GetHandle()
      .raw_value();
}
int32_t barc_tab_create(int32_t id, const char* value, int foreground) {
  auto* window = Window(id);
  GURL url = URL(value);
  if (!window || !url.is_valid())
    return 0;
  const bool present = window->GetTabStripModel()->empty() || foreground;
  if (present && !barc_window_select(id))
    return 0;
  window = Window(id);
  if (!window)
    return 0;
  auto* contents = chrome::AddAndReturnTabAt(window, url, -1, foreground != 0);
  // Insertion observers can close or move the new tab. Compare the returned
  // address against the surviving strip before dereferencing its contents.
  window = Window(id);
  if (!window || !contents)
    return 0;
  auto* strip = window->GetTabStripModel();
  const int index = strip->GetIndexOfWebContents(contents);
  if (index == TabStripModel::kNoTab)
    return 0;
  const int32_t tab_id = strip->GetTabAtIndex(index)->GetHandle().raw_value();
  // A nested profile selection wins over this request's original foreground
  // intent. Show itself can also invoke callbacks, so resolve once more after it.
  if (present && window->IsSelectedForNativeWindow())
    window->GetWindow()->Show();
  return LookupTab(Window(id), tab_id) ? tab_id : 0;
}
int barc_tab_select(int32_t id, int32_t tab_id) {
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab || !barc_window_select(id))
    return 0;
  // Admission can invoke native/profile callbacks; resolve the existing handles
  // again before mutating selection or focusing the requested document.
  window = Window(id);
  tab = LookupTab(window, tab_id);
  if (!tab)
    return 0;
  auto contents = tab->GetContents()->GetWeakPtr();
  auto* strip = window->GetTabStripModel();
  strip->ActivateTabAt(strip->GetIndexOfWebContents(tab->GetContents()));
  if (!contents)
    return 0;
  window = Window(id);
  tab = LookupTab(window, tab_id);
  if (!tab || tab->GetContents() != contents.get() ||
      !window->IsSelectedForNativeWindow())
    return 0;
  contents->Focus();
  return 1;
}
int barc_tab_navigate(int32_t id, int32_t tab_id, const char* value) {
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  GURL url = URL(value);
  if (!tab || !url.is_valid())
    return 0;
  tab->GetContents()->GetController().LoadURL(
      url, content::Referrer(), ui::PAGE_TRANSITION_TYPED, std::string());
  return 1;
}
int barc_tab_close(int32_t id, int32_t tab_id) {
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab)
    return 0;
  window->GetTabStripModel()->CloseWebContents(
      tab->GetContents(), TabCloseTypes::CLOSE_USER_GESTURE |
                              TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
  return 1;
}
int barc_tab_transfer(int32_t source_id,
                      int32_t tab_id,
                      int32_t destination_id) {
  auto* source = Window(source_id);
  auto* destination = Window(destination_id);
  auto* tab = LookupTab(source, tab_id);
  if (!tab || !destination || source == destination ||
      source->GetProfile() != destination->GetProfile())
    return 0;
  if (!barc_window_select(destination_id))
    return 0;
  source = Window(source_id);
  destination = Window(destination_id);
  tab = LookupTab(source, tab_id);
  if (!tab || !destination ||
      source->GetProfile() != destination->GetProfile())
    return 0;
  auto* from = source->GetTabStripModel();
  const int source_index = from->GetIndexOfWebContents(tab->GetContents());
  const int pinned = from->IsTabPinned(source_index) ? AddTabTypes::ADD_PINNED : 0;
  const int rollback_types =
      pinned | (from->active_index() == source_index ? AddTabTypes::ADD_ACTIVE : 0);
  // The ordinary empty-strip notification closes the source, so defer it until
  // the live tab is safely inserted or returned. Explicit closes still win.
  base::ScopedClosureRunner complete_detach(base::BindOnce(
      [](base::WeakPtr<BrowserWindowInterface> source) {
        if (source && !source->IsDeleteScheduled())
          source->GetTabStripModel()->NotifyEmptyAfterDeferredDetach();
      },
      source->GetWeakPtr()));
  auto detached = from->DetachTabAtForInsertion(source_index,
                                               /*notify_empty=*/false);
  if (!detached)
    return 0;
  // Detach notifies observers, which may close the destination. Restore to the
  // surviving source when possible; do not retain a dead destination strip.
  destination = Window(destination_id);
  if (!destination) {
    if (auto* surviving_source = Window(source_id)) {
      auto* strip = surviving_source->GetTabStripModel();
      strip->InsertDetachedTabAt(std::min(source_index, strip->count()),
                                std::move(detached), rollback_types);
    }
    return 0;
  }
  auto* to = destination->GetTabStripModel();
  to->InsertDetachedTabAt(to->count(), std::move(detached),
                         AddTabTypes::ADD_ACTIVE | pinned);
  destination = Window(destination_id);
  if (!LookupTab(destination, tab_id))
    return 0;
  if (destination->IsSelectedForNativeWindow())
    destination->GetWindow()->Show();
  return LookupTab(Window(destination_id), tab_id) ? 1 : 0;
}
int barc_window_select(int32_t id) {
  auto* window = Window(id);
  auto* view = window ? BrowserView::GetBrowserViewForBrowser(window) : nullptr;
  return view && view->browser_widget()->SelectLogicalBrowserView(view);
}
size_t barc_tab_copy_title(int32_t id,
                           int32_t tab_id,
                           char* buffer,
                           size_t capacity) {
  base::span<char> output;
  if (buffer && capacity) {
    // SAFETY: This C ABI requires the caller to supply a writable allocation
    // containing at least capacity chars. Only the conversion trusts that
    // contract; all subsequent writes are bounded span operations.
    output = UNSAFE_BUFFERS(base::span<char>(buffer, capacity));
    output[0] = '\0';
  }
  auto* window = Window(id);
  auto* tab = LookupTab(window, tab_id);
  if (!tab)
    return 0;
  const std::string title = base::UTF16ToUTF8(tab->GetContents()->GetTitle());
  if (buffer && capacity) {
    const size_t count = std::min(title.size(), capacity - 1);
    output.first(count).copy_from(base::span(title).first(count));
    output[count] = '\0';
  }
  return title.size() + 1;
}
int barc_window_attach_native_shell(int32_t id, void* native_view) {
  auto* window = Window(id);
  if (!window)
    return 0;
  auto* browser_view = BrowserView::GetBrowserViewForBrowser(window);
  auto* host = browser_view ? browser_view->barc_native_shell() : nullptr;
  if (!host)
    return 0;
  if (!native_view) {
    host->Detach();
    host->SetVisible(false);
    browser_view->InvalidateLayout();
    return 1;
  }
  NSView* view = (__bridge NSView*)native_view;
  if (view.window &&
      view.window !=
          browser_view->GetWidget()->GetNativeWindow().GetNativeNSWindow())
    return 0;
  host->Detach();
  host->Attach(gfx::NativeView(view));
  host->SetVisible(true);
  browser_view->InvalidateLayout();
  return 1;
}

@class BarcNativeShell;
namespace {
class ShellObserver final : public TabStripModelObserver {
 public:
  explicit ShellObserver(BarcNativeShell* shell, TabStripModel* strip);
  ~ShellObserver() override;
  void OnTabStripModelChanged(TabStripModel*,
                              const TabStripModelChange&,
                              const TabStripSelectionChange&) override;
  void OnTabChangedAt(tabs::TabInterface*, TabChangeType) override;
  void OnTabStripModelDestroyed(TabStripModel*) override;

 private:
  __weak BarcNativeShell* shell_;
  raw_ptr<TabStripModel> strip_;
};
}  // namespace

@interface BarcNativeShell : NSView {
  int32_t window_id_;
  NSPopUpButton* tabs_;
  NSTextField* address_;
  std::unique_ptr<ShellObserver> observer_;
}
- (instancetype)initWithBrowser:(BrowserWindowInterface*)browser;
- (void)refreshTabs;
@end

@implementation BarcNativeShell
- (BOOL)isFlipped {
  return YES;
}
- (instancetype)initWithBrowser:(BrowserWindowInterface*)browser {
  if ((self = [super initWithFrame:NSMakeRect(0, 0, 240, 600)])) {
    window_id_ = browser->GetSessionID().id();
    NSTextField* label = [NSTextField labelWithString:@"Barc native shell"];
    label.frame = NSMakeRect(12, 16, 216, 24);
    [self addSubview:label];
    address_ = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 52, 216, 26)];
    address_.placeholderString = @"URL";
    address_.target = self;
    address_.action = @selector(navigate:);
    [self addSubview:address_];
    tabs_ = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(12, 92, 216, 26)
                                       pullsDown:NO];
    tabs_.target = self;
    tabs_.action = @selector(selectTab:);
    [self addSubview:tabs_];
    NSArray<NSString*>* labels = @[
      @"New tab", @"Chromium Settings", @"Extensions", @"Move tab to new window"
    ];
    const std::array<SEL, 4> actions = {
        @selector(newTab:), @selector(settings:), @selector(extensions:),
        @selector(moveTab:)};
    for (NSUInteger index = 0; index < labels.count; ++index) {
      NSButton* button = [NSButton buttonWithTitle:labels[index]
                                            target:self
                                            action:actions[index]];
      button.frame = NSMakeRect(12, 138 + index * 40, 216, 30);
      [self addSubview:button];
    }
    observer_ =
        std::make_unique<ShellObserver>(self, browser->GetTabStripModel());
    [self refreshTabs];
  }
  return self;
}
- (void)refreshTabs {
  auto* browser = Window(window_id_);
  [tabs_ removeAllItems];
  if (!browser)
    return;
  auto* strip = browser->GetTabStripModel();
  for (int i = 0; i < strip->count(); ++i) {
    auto* tab = strip->GetTabAtIndex(i);
    NSString* title = [NSString
        stringWithUTF8String:base::UTF16ToUTF8(tab->GetContents()->GetTitle())
                                 .c_str()];
    NSMenuItem* item =
        [[NSMenuItem alloc] initWithTitle:title.length ? title : @"Untitled"
                                   action:nil
                            keyEquivalent:@""];
    item.representedObject = @(tab->GetHandle().raw_value());
    [tabs_.menu addItem:item];
  }
  if (strip->active_index() >= 0)
    [tabs_ selectItemAtIndex:strip->active_index()];
}
- (int32_t)selectedTab {
  return [tabs_.selectedItem.representedObject intValue];
}
- (void)selectTab:(id)sender {
  barc_tab_select(window_id_, [self selectedTab]);
}
- (void)navigate:(id)sender {
  barc_tab_navigate(window_id_, [self selectedTab],
                    address_.stringValue.UTF8String);
}
- (void)newTab:(id)sender {
  barc_tab_create(window_id_, "about:blank", 1);
}
- (void)settings:(id)sender {
  barc_tab_create(window_id_, "chrome://settings/", 1);
}
- (void)extensions:(id)sender {
  barc_tab_create(window_id_, "chrome://extensions/", 1);
}
- (void)moveTab:(id)sender {
  const int32_t tab = [self selectedTab];
  if (!tab)
    return;
  const int32_t peer = barc_window_new_peer(window_id_);
  if (peer && !barc_tab_transfer(window_id_, tab, peer))
    barc_window_close(peer);
}
@end

namespace {
ShellObserver::ShellObserver(BarcNativeShell* shell, TabStripModel* strip)
    : shell_(shell), strip_(strip) {
  strip_->AddObserver(this);
}
ShellObserver::~ShellObserver() {
  if (strip_)
    strip_->RemoveObserver(this);
}
void ShellObserver::OnTabStripModelChanged(TabStripModel*,
                                           const TabStripModelChange&,
                                           const TabStripSelectionChange&) {
  [shell_ refreshTabs];
}
void ShellObserver::OnTabChangedAt(tabs::TabInterface*, TabChangeType) {
  [shell_ refreshTabs];
}
void ShellObserver::OnTabStripModelDestroyed(TabStripModel*) {
  strip_ = nullptr;
}
}  // namespace

namespace barc {
int NativeShellWidth(const BrowserView* browser_view) {
  auto* shell = browser_view->barc_native_shell();
  return shell && shell->GetVisible() ? kNativeShellWidth : 0;
}
views::NativeViewHost* CreateNativeShell(BrowserView* browser_view) {
  if (!base::CommandLine::ForCurrentProcess()->HasSwitch("barc-native-shell") ||
      browser_view->browser()->GetType() != BrowserWindowInterface::TYPE_NORMAL)
    return nullptr;
  auto* host =
      browser_view->AddChildView(std::make_unique<views::NativeViewHost>());
  BarcNativeShell* shell =
      [[BarcNativeShell alloc] initWithBrowser:browser_view->browser()];
  host->Attach(gfx::NativeView(shell));
  return host;
}
void LayoutNativeShell(views::NativeViewHost* shell,
                       views::View* browser_view) {
  if (!shell || !shell->GetVisible())
    return;
  const gfx::Rect bounds = browser_view->GetLocalBounds();
  shell->SetBounds(bounds.x(), bounds.y(), kNativeShellWidth, bounds.height());
}
}  // namespace barc
