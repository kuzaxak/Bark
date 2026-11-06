#ifndef BARC_CHROMIUM_BRIDGE_H_
#define BARC_CHROMIUM_BRIDGE_H_

#include <stddef.h>
#include <stdint.h>

// Versioned C boundary built into the pinned Chromium framework. All calls are
// synchronous on Chromium's browser UI thread, after browser startup. Handles
// are process-local IDs, never C++ or Objective-C pointers; closed IDs fail.
#ifdef __cplusplus
extern "C" {
#endif
#define BARC_API __attribute__((visibility("default")))
BARC_API uint32_t barc_bridge_version(void);
// Static NUL-terminated engine version, valid for the process lifetime.
BARC_API const char* barc_chromium_version(void);
// Creates an empty same-profile peer for immediate page insertion/transfer.
// Close it if the insertion fails. It becomes visible once populated.
BARC_API int32_t barc_window_new_peer(int32_t source_window);
// Returns whether a valid request was dispatched; Chrome may delay/deny close.
BARC_API int barc_window_close(int32_t window);
BARC_API size_t barc_window_tab_count(int32_t window);
BARC_API int32_t barc_window_tab_at(int32_t window, size_t index);
BARC_API int32_t barc_tab_create(int32_t window,
                                 const char* url,
                                 int foreground);
BARC_API int barc_tab_select(int32_t window, int32_t tab);
BARC_API int barc_tab_navigate(int32_t window, int32_t tab, const char* url);
// Returns whether a valid request was dispatched; Chrome may delay/deny close.
// A tab ID stops resolving only after actual destruction.
BARC_API int barc_tab_close(int32_t window, int32_t tab);
// Cross-profile transfer is rejected; reassignment requires a new document.
BARC_API int barc_tab_transfer(int32_t source_window,
                               int32_t tab,
                               int32_t destination_window);
// Select this logical browser within its physical native window. Returns 0
// for stale/refused admission; does not claim completed native
// focus/activation.
BARC_API int barc_window_select(int32_t window);
// Returns bytes required including NUL; 0 means stale/invalid handle. A short
// buffer is NUL-terminated. Titles are UTF-8 and may be empty. A non-null
// buffer must point to at least capacity writable chars; nullptr queries size.
BARC_API size_t barc_tab_copy_title(int32_t window,
                                    int32_t tab,
                                    char* buffer,
                                    size_t capacity);
// native_view is an NSView* (including NSHostingView), retained by the native
// host until replacement, nullptr detach, or window close. Chromium retains
// window ownership. Detach restores the space reserved for the native shell.
BARC_API int barc_window_attach_native_shell(int32_t window, void* native_view);
#ifdef __cplusplus
}

namespace views {
class NativeViewHost;
class View;
}  // namespace views
class BrowserView;
namespace barc {
inline constexpr int kNativeShellWidth = 240;
int NativeShellWidth(const BrowserView* browser_view);
views::NativeViewHost* CreateNativeShell(BrowserView* browser_view);
void LayoutNativeShell(views::NativeViewHost* shell, views::View* browser_view);
}  // namespace barc
#endif
#endif
