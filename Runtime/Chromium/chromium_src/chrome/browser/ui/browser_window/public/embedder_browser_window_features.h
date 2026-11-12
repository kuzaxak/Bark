#ifndef BARK_CHROMIUM_SRC_CHROME_BROWSER_UI_BROWSER_WINDOW_PUBLIC_EMBEDDER_BROWSER_WINDOW_FEATURES_H_
#define BARK_CHROMIUM_SRC_CHROME_BROWSER_UI_BROWSER_WINDOW_PUBLIC_EMBEDDER_BROWSER_WINDOW_FEATURES_H_

// Declares upstream's InitPostBrowserViewConstruction under another name, so
// the override can define the real one and call it.
#define InitPostBrowserViewConstruction                                     \
  InitPostBrowserViewConstruction_ChromiumImpl(BrowserView* browser_view); \
  void InitPostBrowserViewConstruction
#include_next "chrome/browser/ui/browser_window/public/embedder_browser_window_features.h"
#undef InitPostBrowserViewConstruction

#endif  // BARK_CHROMIUM_SRC_CHROME_BROWSER_UI_BROWSER_WINDOW_PUBLIC_EMBEDDER_BROWSER_WINDOW_FEATURES_H_
