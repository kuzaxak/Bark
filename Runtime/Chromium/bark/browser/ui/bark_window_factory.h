#ifndef BARK_BROWSER_UI_BARK_WINDOW_FACTORY_H_
#define BARK_BROWSER_UI_BARK_WINDOW_FACTORY_H_

#include <memory>

#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "chrome/browser/ui/browser_window_deleter.h"

class BrowserWindow;
class BrowserWindowInterface;

namespace bark {

class BarkWindowHost;

// True when the process runs with --bark-window=host.
bool IsHostWindowMode();

// Bark's window for a normal browser the app creates while host mode is on;
// null for every other browser, which keeps upstream's BrowserView.
std::unique_ptr<BrowserWindow, BrowserWindowDeleter> MaybeCreateHostWindow(
    BrowserWindowInterface* browser,
    bool in_tab_dragging);

// The host window `owner` is shown in, while it can take another client.
BarkWindowHost* HostToJoin(BrowserWindowInterface* owner);

// Browsers created while one of these lives are the app's own. With `join`,
// the first one becomes a client of that host instead of opening a window.
class ScopedAppWindowCreation {
 public:
  explicit ScopedAppWindowCreation(BarkWindowHost* join = nullptr);
  ScopedAppWindowCreation(const ScopedAppWindowCreation&) = delete;
  ScopedAppWindowCreation& operator=(const ScopedAppWindowCreation&) = delete;
  ~ScopedAppWindowCreation();

 private:
  scoped_refptr<BarkWindowHost> join_;
  raw_ptr<BarkWindowHost> previous_join_;
};

}  // namespace bark

#endif  // BARK_BROWSER_UI_BARK_WINDOW_FACTORY_H_
