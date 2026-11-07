#ifndef BARC_CHROMIUM_PROFILES_H_
#define BARC_CHROMIUM_PROFILES_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
#define BARC_PROFILES_API __attribute__((visibility("default")))

typedef enum {
  BARC_PROFILE_SETTINGS = 0,
  BARC_PROFILE_EXTENSIONS = 1,
  BARC_PROFILE_PRIVACY = 2,
  BARC_PROFILE_SITE_SETTINGS = 3,
  BARC_PROFILE_CLEAR_DATA = 4,
  BARC_PROFILE_BLANK = 5,
} barc_profile_destination;

typedef enum {
  BARC_PROFILE_OK = 0,
  BARC_PROFILE_INVALID_ARGUMENT = 1,
  BARC_PROFILE_UNAVAILABLE = 2,
  BARC_PROFILE_FAILED = 3,
  BARC_PROFILE_CANCELLED = 4,
} barc_profile_status;

typedef void (*barc_profile_window_callback)(barc_profile_status status,
                                             int32_t window,
                                             void* user_data);

// Browser UI thread only, after startup. UUID is copied before return, accepts
// either case, and must identify an existing app-owned profile (caller checks
// its app model). Nil UUID is rejected. No display name or path is accepted.
// Creates a normal Chromium window in that profile; never uses the active or
// default profile. Window is a process-local SessionID, 0 on failure.
// BLANK constructs an inactive about:blank owner without Show; the caller
// admits its model/native attachment before selecting/presenting it.
// Completion is queued on UI and occurs once while the browser UI loop remains
// operational. Cancellation during shutdown is best effort: no callback is
// delivered on another thread, but once UI stops accepting tasks delivery is
// not guaranteed. callback must be non-null. Its code and user_data must remain
// valid until completion or until native runtime shutdown has fully completed.
// A stopped UI task runner may report cancellation before this call returns.
// Successful completion establishes ownership/navigation request, not page-load
// completion. Deletion, reassignment and cross-profile native hosting are not
// implemented by this feasibility boundary.
BARC_PROFILES_API void barc_profile_open_window(
    const char* profile_uuid,
    barc_profile_destination destination,
    barc_profile_window_callback callback,
    void* user_data);

// Explicit feasibility opt-in only (--barc-shared-native-window). Creates a
// normal profile-bound logical Chrome window inside the live native owner,
// returning its own SessionID. Stale/refused hosts fail; never opens a fallback
// native window. Same async UUID/lifetime/callback contract as open_window.
BARC_PROFILES_API void barc_profile_open_in_native_window(
    int32_t native_owner,
    const char* profile_uuid,
    barc_profile_destination destination,
    barc_profile_window_callback callback,
    void* user_data);

// Explicit fresh-private-session entrypoint. Browser UI thread only;
// same async callback/user-data lifetime as open_window. Creates a fresh private
// session with a manager-owned Guest parent and primary OTR, initially blank.
// The callback result stays hidden; the caller must admit its model/native
// header before explicitly showing the returned window.
// No path/regular UUID is accepted, no persistent-profile fallback. Child
// windows/popups must reuse the returned window's exact Profile. Closing all
// session windows destroys OTR before releasing/deleting its ephemeral parent.
// Native New Incognito uses independent sessions in registered Barc mode.
// Native New Guest and other profile-picker entrypoints remain unintegrated.
BARC_PROFILES_API void barc_private_session_open_window(
    barc_profile_window_callback callback,
    void* user_data);

// Browser UI thread only. Returns bytes required including NUL (37), or 0 for
// stale/non-Barc/off-record windows or unavailable runtime. Short buffers are
// NUL-terminated. Output is the canonical lowercase UUID derived from the
// actual manager-owned window Profile, never a cached caller label. A non-null
// buffer must point to at least capacity writable chars; nullptr queries size.
BARC_PROFILES_API size_t barc_window_profile_uuid(int32_t window,
                                                  char* buffer,
                                                  size_t capacity);
// Same UI-thread/buffer contract as the regular query, but accepts only a live
// manager-owned Barc private Guest primary OTR. Returns its canonical session
// UUID (37 bytes including NUL), never a regular-profile UUID or filesystem
// path. Children sharing the exact private Profile return the same session
// identity.
BARC_PROFILES_API size_t barc_window_private_session_uuid(int32_t window,
                                                        char* buffer,
                                                        size_t capacity);
#ifdef __cplusplus
}
#include <string>
#include "base/functional/callback_forward.h"
class Profile;
namespace barc {
// Exact regular Barc UUID only. Callback borrows manager-owned Profile; it must
// synchronously establish browser ownership. Failed/cancelled loads return
// null.
void WithRegularProfileForApplication(
    std::string uuid,
    base::OnceCallback<void(Profile*)> callback);
}  // namespace barc
#endif
#endif
