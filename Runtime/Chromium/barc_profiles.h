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

typedef enum {
  BARC_PROFILE_DELETED = 0,
  BARC_PROFILE_DELETE_CANCELLED = 1,
  BARC_PROFILE_DELETE_PENDING = 2,
  BARC_PROFILE_CLOSE_ADMITTED = 3,
} barc_profile_delete_result;
typedef void (*barc_profile_delete_callback)(barc_profile_delete_result result,
                                            void* user_data);

// UI thread. Both UUIDs must be existing app-model regular identities, distinct.
// The caller durably records the intent before admission and keeps target
// unavailable through PENDING/restart. CANCELLED proves no destructive mark;
// DELETED confirms polite service/data wipe or proven absent unloaded bytes,
// with marked directory removal possibly deferred to Chromium restart cleanup.
// reconcile_only must be 0 or 1. 1 never starts deletion of a present
// unmarked profile; only reconciles absence or an already marked cleanup.
// No stock/default replacement is created. Same callback lifetime as factories.
// CANCELLED retains a scheduling reservation until the caller has durably
// cleared its intent and acknowledges it. No data is removed before that result.
BARC_PROFILES_API int barc_profile_delete_cancel_ack(
    const char* target_uuid, const char* survivor_uuid);
BARC_PROFILES_API void barc_profile_delete_kept(
    const char* target_uuid, const char* survivor_uuid, int32_t reconcile_only,
    barc_profile_delete_callback callback, void* user_data);

// Active-profile reassignment protocol. Uses the SAME bounded deletion request.
// prepare closes target windows with ordinary veto handling, then reports
// CLOSE_ADMITTED without marking/wiping/cancelling downloads. The caller must
// durably commit exact destination assignment and retained source metadata
// before continue. reconcile_only never starts unmarked/uncommitted deletion.
BARC_PROFILES_API void barc_profile_prepare_reassignment(
    const char* target_uuid, const char* survivor_uuid, int32_t reconcile_only,
    barc_profile_delete_callback callback, void* user_data);
BARC_PROFILES_API void barc_profile_continue_deletion(
    const char* target_uuid, const char* survivor_uuid,
    barc_profile_delete_callback callback, void* user_data);

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
// Exact-profile search authority. UI thread; borrowed JSON is copied before
// return. window>0 must match uuid and kind (0 regular, 1 private); window=0
// loads only an existing model-validated regular UUID. No active/default lookup.
// seed is {selected,engines:[{id,name,url}]} with token-free templates. It is
// imported once per regular profile; private import remains session-local.
// null seed performs no catalog serialization; status3 requests the import seed
// only for an untouched fallback profile. Retry once after revalidation.
// selection is an existing native provider GUID or null (snapshot only).
// Callback JSON is borrowed for the call; once on UI while runtime operational.
// Same shutdown lifetime contract as profile factories. status0 means success.
typedef void (*barc_search_callback)(void* context, int32_t status, const char* json);
BARC_PROFILES_API void barc_profile_search_state(const char* uuid, int32_t window,
    int32_t is_private, const char* seed, const char* selection, int32_t include_choices,
    barc_search_callback callback, void* context);

// Fixed authenticated live-source GETs, regular app profiles only; no window,
// caller-supplied URL/header/body, cookie export, redirects or Set-Cookie writes.
// Accepted token completes exactly once on UI, including cancel; refusal0 has
// no callback. Byte view is borrowed for the callback. Cancellation cannot undo
// an already-sent GET. Bounds: 8 global/2 per UUID, 4MiB, 20s including profile load.
enum barc_live_source {
  BARC_LIVE_GITHUB_PULLS = 0, BARC_LIVE_GITHUB_ISSUES = 1,
  BARC_LIVE_GITHUB_NOTIFICATIONS = 2, BARC_LIVE_ASANA_WORKSPACES = 3,
  BARC_LIVE_ASANA_TASKS = 4, BARC_LIVE_GMAIL = 5
};
typedef enum {
  BARC_LIVE_OK = 0, BARC_LIVE_CANCELLED = 1, BARC_LIVE_FAILED = 2,
  BARC_LIVE_TIMEOUT = 3, BARC_LIVE_TOO_LARGE = 4
} barc_live_result;
typedef void (*barc_live_callback)(void* context, uint64_t token, barc_live_result result,
    int32_t http_status, const uint8_t* body, size_t length);
BARC_PROFILES_API uint64_t barc_profile_live_get(const char* uuid, int32_t source,
    const char* argument, barc_live_callback callback, void* context);
BARC_PROFILES_API void barc_profile_live_cancel(uint64_t token);

#ifdef __cplusplus
}
#include <string>
#include "base/functional/callback_forward.h"
class Profile;
namespace barc {
// Exact regular Barc UUID only. Callback borrows manager-owned Profile; it must
// synchronously establish browser ownership or acquire a scoped profile
// keepalive. Failed/cancelled loads return
// null.
void WithRegularProfileForApplication(
    std::string uuid,
    base::OnceCallback<void(Profile*)> callback);
}  // namespace barc
#endif
#endif
