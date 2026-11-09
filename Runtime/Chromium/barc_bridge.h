#ifndef BARC_CHROMIUM_BRIDGE_H_
#define BARC_CHROMIUM_BRIDGE_H_

#include "chrome/browser/ui/views/frame/barc_bridge_api.h"

namespace views {
class NativeViewHost;
class View;
}  // namespace views
namespace base { class ScopedClosureRunner; class FilePath; }
class BrowserView;
class BrowserWindowInterface;
namespace content { class RenderFrameHost; class WebContents; struct OpenURLParams; }
namespace tabs { class TabInterface; }
namespace barc {
void CancelDocumentDownloadsForProfilePath(const base::FilePath& path);
// Explicit native link-menu intent. The existing observer owns one replaceable
// document-bound request; no URL is loaded or page created in this callback.
bool CanRequestPeek(content::RenderFrameHost* frame);
// Pure exact intrinsic pair; no lookup by selected native window/profile.
bool IsPeekPair(tabs::TabInterface* source, tabs::TabInterface* peek);
tabs::TabInterface* PeekForSource(tabs::TabInterface* source);
// Actual exact-pair coordinator refusal, delivered to the existing observation.
void NotifyPeekCloseCancelled(tabs::TabInterface* tab);
bool CommitPeekPairClose(tabs::TabInterface* source, tabs::TabInterface* peek);
bool IsPeekCloseCommitted(tabs::TabInterface* source);
void ResetPeekCloseCommitted(tabs::TabInterface* tab, content::WebContents* expected);
// Moves only the captured current native sidebar between exact same-context peers.
bool MovePeekNativeShell(BrowserWindowInterface* from, BrowserWindowInterface* to);
void AttachPeekBackdrop(views::NativeViewHost* host, tabs::TabInterface* source,
                        tabs::TabInterface* peek);
void RequestPeek(content::RenderFrameHost* frame, const content::OpenURLParams& params);
// Reuses the existing UI-only bridge callback guard: closes post non-nestable
// exact-ID requests, transfer/other structural commands refuse during mutation.
base::ScopedClosureRunner ProtectNativeViewMutation();
// Internal Chrome-view hooks; no foreign callbacks are invoked inline.
void BrowserDiscoveryChanged();
void StopBrowserDiscovery();
inline constexpr int kNativeShellWidth = 240;
int NativeShellWidth(const BrowserView* browser_view);
int NativeShellHeight(const BrowserView* browser_view);
// Explicit external-link mini only; never changes ordinary Chrome popups.
bool ConfigureNativeMini(BrowserWindowInterface* browser);
views::NativeViewHost* CreateNativeShell(BrowserView* browser_view);
void LayoutNativeShell(views::NativeViewHost* shell, BrowserView* browser_view);
}  // namespace barc
#endif
