#include "chrome/browser/ui/browser_window/public/embedder_browser_window_features.h"

#define InitPostBrowserViewConstruction InitPostBrowserViewConstruction_ChromiumImpl
#include "src/chrome/browser/ui/browser_window/internal/embedder_browser_window_features.cc"
#undef InitPostBrowserViewConstruction

void EmbedderBrowserWindowFeatures::InitPostBrowserViewConstruction(
    BrowserView* browser_view) {
  InitPostBrowserViewConstruction_ChromiumImpl(browser_view);
}
