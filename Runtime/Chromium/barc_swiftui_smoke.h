#ifndef BARC_CHROMIUM_SWIFTUI_SMOKE_H_
#define BARC_CHROMIUM_SWIFTUI_SMOKE_H_

#ifdef __cplusplus
extern "C" {
#endif
// Browser UI/main thread only, after BrowserCrApplication initialization.
// Returns +1 retained NSHostingView. Consume exactly once using
// (__bridge_transfer NSView*) before attaching to the existing NativeViewHost.
// Does not start NSApplication or own any Chromium window/helper lifecycle.
void* barc_create_swiftui_smoke_view(void);
#ifdef __cplusplus
}
#endif
#endif
