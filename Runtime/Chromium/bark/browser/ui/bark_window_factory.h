#ifndef BARK_BROWSER_UI_BARK_WINDOW_FACTORY_H_
#define BARK_BROWSER_UI_BARK_WINDOW_FACTORY_H_

#include <memory>

#include "chrome/browser/ui/browser_window_deleter.h"

class BrowserWindow;
class BrowserWindowInterface;

namespace bark {

// True when the process runs with --bark-window=host.
bool IsHostWindowMode();

// Bark's window for a normal browser the app creates while host mode is on;
// null for every other browser, which keeps upstream's BrowserView.
std::unique_ptr<BrowserWindow, BrowserWindowDeleter> MaybeCreateHostWindow(
    BrowserWindowInterface* browser,
    bool in_tab_dragging);

// Browsers created while one of these lives are the app's own.
class ScopedAppWindowCreation {
 public:
  ScopedAppWindowCreation();
  ScopedAppWindowCreation(const ScopedAppWindowCreation&) = delete;
  ScopedAppWindowCreation& operator=(const ScopedAppWindowCreation&) = delete;
  ~ScopedAppWindowCreation();
};

}  // namespace bark

#endif  // BARK_BROWSER_UI_BARK_WINDOW_FACTORY_H_
