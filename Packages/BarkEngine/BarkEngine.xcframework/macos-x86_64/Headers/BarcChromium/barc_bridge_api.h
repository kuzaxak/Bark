#ifndef BARC_CHROMIUM_BRIDGE_API_H_
#define BARC_CHROMIUM_BRIDGE_API_H_

#include <stddef.h>
#include <stdint.h>

// Versioned C boundary built into the pinned Chromium framework. Call every
// entry point on Chromium's browser UI thread, after browser startup. Handles
// are process-local IDs, never C++ or Objective-C pointers; closed IDs fail.
#ifdef __cplusplus
extern "C" {
#endif
#define BARC_API __attribute__((visibility("default")))
// Version 6 adds document-bound Peek request and discovery fields. Structs cross
// this boundary without size arguments; the app requires this exact ABI.
#define BARC_BRIDGE_VERSION 6
BARC_API uint32_t barc_bridge_version(void);
// The app enters the engine through this symbol, not ChromeMain. A new bridge
// version renames it, so an app and framework built for different versions fail
// at dlsym, as Chromium's ChromeAppModeStart_v<N> does. Update the name in
// chrome/app/framework.exports and framework.order with it.
#define BARC_ENGINE_MAIN_SYMBOL "barc_engine_main_v6"
BARC_API int barc_engine_main_v6(int argc, const char** argv);
// Static NUL-terminated engine version, valid for the process lifetime.
BARC_API const char* barc_chromium_version(void);
// Creates an empty same-profile peer for immediate page insertion/transfer.
// Close it if the insertion fails. It becomes visible once populated.
BARC_API int32_t barc_window_new_peer(int32_t source_window);
// Empty inactive normal client in an existing product's physical window,
// inheriting the source's exact native Profile/private context. Both owners
// are revalidated across creation. No tab, selection, focus, or showing occurs.
// Zero is refusal; caller closes only its returned empty client on failure.
BARC_API int32_t barc_window_new_peer_in_native_window(int32_t source_window,
                                                        int32_t physical_owner);
// Returns whether a valid request was dispatched; Chrome may delay/deny close.
BARC_API int barc_window_close(int32_t window);
BARC_API size_t barc_window_tab_count(int32_t window);
BARC_API int32_t barc_window_tab_at(int32_t window, size_t index);
BARC_API int32_t barc_tab_create(int32_t window,
                                 const char* url,
                                 int foreground);
BARC_API int barc_tab_select(int32_t window, int32_t tab);
BARC_API int barc_tab_search(int32_t window, int32_t tab, const char* query,
    const char* kagi_session_token);
BARC_API int barc_tab_navigate(int32_t window, int32_t tab, const char* url);
// Returns whether a valid request was dispatched; Chrome may delay/deny close.
// A tab ID stops resolving only after actual destruction.
BARC_API int barc_tab_close(int32_t window, int32_t tab);
// Cross-profile transfer is rejected; reassignment requires a new document.
// Transfer during a navigation callback is refused; callers may post a UI task.
BARC_API int barc_tab_transfer(int32_t source_window,
                               int32_t tab,
                               int32_t destination_window);
// Metadata for the one native application launch awaiting model admission.
// No hint returns 0; a hint returns required bytes including NUL (37). These
// queries never create/select/focus a page or consult another profile.
BARC_API size_t barc_tab_copy_launch_space(int32_t window, int32_t tab,
                                          char* output, size_t capacity);
BARC_API int barc_tab_application_pending(int32_t window, int32_t tab);
// UI commands target only this exact selected logical owner and active tab.
// No selection/focus or fallback retargeting is performed. Return dispatch
// acceptance, not completion of a dialog, find result, print job or DevTools.
// Refused during bridge callbacks; callers may post a browser UI task.
// CLEAR_BACK_FORWARD_CACHE alone also admits an exact background tab; it
// drops cached history documents without selecting/reloading its live page.
enum BarcPageCommand {
  BARC_PAGE_FIND = 0, BARC_PAGE_FIND_NEXT = 1, BARC_PAGE_FIND_PREVIOUS = 2,
  BARC_PAGE_ZOOM_IN = 3, BARC_PAGE_ZOOM_OUT = 4, BARC_PAGE_ZOOM_RESET = 5,
  BARC_PAGE_PRINT = 6, BARC_PAGE_DEVTOOLS = 7, BARC_PAGE_HARD_RELOAD = 8,
  BARC_PAGE_DEVTOOLS_INSPECT = 9,
  // Normal MediaSession action; refuses active document PiP. A site handler
  // may choose its own PiP presentation under upstream permission rules.
  BARC_PAGE_VIDEO_PIP_TOGGLE = 10,
  BARC_PAGE_CLEAR_BACK_FORWARD_CACHE = 11,
  BARC_PAGE_DEVTOOLS_CONSOLE = 12,
  BARC_PAGE_DEVTOOLS_NETWORK = 13,
  BARC_PAGE_DEVTOOLS_PERFORMANCE = 14
};
BARC_API int barc_tab_execute_command(int32_t window, int32_t tab,
                                     int32_t command);
// Explicit tab mute, including background tabs; never changes selection or
// site sound settings. muted must be 0 or 1. Return actual helper acceptance
// for the still-live exact owner; actual state is reported by observation.
BARC_API int barc_tab_set_muted(int32_t window, int32_t tab, int muted);
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
// One browser-UI subscription to loaded Barc profiles' existing download
// managers. Strings/snapshot are borrowed only during callbacks, delivered in
// posted non-nestable UI tasks. Initial/history items may repeat; identity is
// actual profile/session UUID + private flag + GUID. manager is a process-local
// source lifetime token, not a Profile pointer. Unknown profiles are excluded.
enum BarcDownloadEvent { BARC_DOWNLOAD_ITEM = 0, BARC_DOWNLOAD_REMOVED = 1,
                         BARC_DOWNLOAD_MANAGER_ENDED = 2 };
enum BarcDownloadState { BARC_DOWNLOAD_PROGRESS = 0, BARC_DOWNLOAD_COMPLETE = 1,
                         BARC_DOWNLOAD_CANCELLED = 2, BARC_DOWNLOAD_INTERRUPTED = 3 };
enum BarcDownloadFlags { BARC_DOWNLOAD_PRIVATE = 1, BARC_DOWNLOAD_UNSAFE = 2,
                         BARC_DOWNLOAD_SAFE_FILE = 4 };
struct BarcDownloadSnapshot {
  uint64_t manager;
  const char* profile_uuid;
  const char* guid;
  const char* url;
  const char* target_path;
  const char* filename;
  int32_t state;
  int32_t error;
  uint32_t flags;
  int64_t received_bytes;
  int64_t total_bytes;
  double started_unix;
};
typedef void (*BarcDownloadCallback)(void* context, uint64_t observation,
                                    int32_t event,
                                    const struct BarcDownloadSnapshot* snapshot);
BARC_API uint64_t barc_downloads_observe(BarcDownloadCallback callback, void* context);
BARC_API void barc_downloads_unobserve(uint64_t observation);
enum BarcDownloadAction { BARC_DOWNLOAD_CANCEL = 0, BARC_DOWNLOAD_REMOVE = 1 };
// Resolve GUID only in the exact still-live subscribed manager. CANCEL accepts
// in-progress items; REMOVE accepts terminal history items and never trashes a
// file. Returns dispatch/queue acceptance; events confirm state/removal.
BARC_API int barc_download_action(uint64_t observation, uint64_t manager,
                                  const char* guid, int32_t action);
// Pure current safe-complete target, required bytes including NUL; 0 means
// unavailable/stale/unsafe. Same short-buffer contract as tab_copy_title.
BARC_API size_t barc_download_copy_safe_target(uint64_t observation,
    uint64_t manager, const char* guid, char* buffer, size_t capacity);

// Live splits preserve each tab's actual logical/Profile owner. Same-owner
// panes use the native collection; multiple regular owners in one physical
// Widget borrow their existing containers without changing Chrome collections.
// Private panes remain confined to one exact owner/context.
// count is 2..4; orientation is 0 side-by-side, 1 stacked; count-1 dividers
// increase strictly in (0,1). Set requires active_tab owned by the selected
// normal logical owner; other handles must belong to that same physical group.
// The caller admits the requested active owner/header through normal selection
// before Set. Local collection pin/group follow its first pane.
// Dividers are stored proportions; minimum sizes can clamp actual pixel bounds.
// collection is the native collection identity, zero for physical presentation.
// kind/generation identify actual mounted presentation, never a fake collection.
// Set ignores identities; Get returns them; Clear compares them exactly.
// Get(member=0) reads the current tab; another member reads its existing split
// without selection. active_tab is0 when the current tab lies outside that split.
// Get is pure; unavailable/unsplit returns0 without modifying output.
// Clear requires the exact expected identity, order, geometry and active member;
// stale expectations return0. It can dissolve an inactive collection without
// selecting/showing/loading/closing its tabs. Explicit physical Clear also
// dissolves only the selected pane's unchanged underlying native collection,
// leaving that pane singly displayed; other owners' parked collections remain.
// Automatic detach/rollback only return views. Member0 means the current tab.
// Set/Clear refuse navigation callbacks; they do not promise arbitrary reentry.
typedef struct BarcSplitLayout {
  uint32_t count;
  uint32_t orientation;
  int32_t tabs[4];
  double dividers[3];
  int32_t active_tab;
  int32_t collection;
  // 0: native TabStrip collection, 1: borrowed physical presentation.
  // Set ignores identities; Get returns the actual kind and identity. Clear
  // compares both. A mounted presentation never impersonates a collection.
  uint32_t kind;
  uint64_t generation;
} BarcSplitLayout;
BARC_API int barc_window_set_split(int32_t window, const BarcSplitLayout* layout);
BARC_API int barc_window_get_split(int32_t window, int32_t member,
                                  BarcSplitLayout* layout);
BARC_API int barc_window_clear_split(int32_t window, int32_t member,
                                    const BarcSplitLayout* expected);

// Navigation observation is UI-thread-only. One observer per live tab; duplicate
// binding fails. Strings are UTF-8, borrowed only during the callback. INITIAL
// is synchronous; return is 0 if that callback unobserves. A queued close request
// leaves the token active until deletion is admitted or the caller unobserves.
// Unobserve is idempotent and prevents every subsequent callback. CLOSED is
// terminal (once), emitted when deletion is admitted, before final destruction.
// Tab/window close during callbacks queues a non-nestable UI request and returns
// queue acceptance; exact IDs are revalidated when it runs. This permits modal
// nested loops and unsubscribe-then-close without destroying notifying contents.
// CLOSE_CANCELLED reports explicit refusal and keeps the live observation.
// Pending unload/download dialogs do not complete a close request.
// Other mutation APIs do not promise unrestricted callback reentrancy.
// Same-profile transfers retain observation; event window follows current owner
// (0 while detached). Contents replacement emits STATE for the replacement.
// Lifecycle STARTED/FINISHED/FAILED cover only navigations started after binding.
// Mid-load binding reports INITIAL/STATE and actual subsequent primary commits;
// it never invents a historical start, finish or failure. Bind before navigating
// a newly created blank tab for complete lifecycle coverage.
// FAILED URL is the displayed last committed URL (not the rejected target).
// Same-document changes emit COMMITTED with SAME_DOCUMENT, without STARTED.
// Error is net::Error; ABORTED is cancellation, not a user-visible failure.
enum BarcTabEvent {
  BARC_TAB_INITIAL = 0, BARC_TAB_STARTED = 1, BARC_TAB_COMMITTED = 2,
  BARC_TAB_FINISHED = 3, BARC_TAB_FAILED = 4, BARC_TAB_TITLE = 5,
  BARC_TAB_STATE = 6, BARC_TAB_CLOSED = 7, BARC_TAB_CLOSE_CANCELLED = 8,
  // Explicit link-menu intent, not navigation. URL is the clicked link; error
  // is a positive observation-local request serial, consumed at most once.
  BARC_TAB_PEEK_REQUESTED = 9,
  // Exact native main-frame denial and its native InfoBar action. URL is the
  // rejected target, never a replacement navigation-state snapshot. Extension
  // errors do not produce either event; the action grants no native exemption.
  BARC_TAB_NATIVE_BLOCKED = 10, BARC_TAB_CONTINUE_NATIVE_BLOCK = 11
};
enum BarcTabFlags {
  BARC_TAB_LOADING = 1, BARC_TAB_BACK = 2, BARC_TAB_FORWARD = 4,
  BARC_TAB_RELOAD = 8, BARC_TAB_SAME_DOCUMENT = 16,
  BARC_TAB_PROVISIONAL = 32, BARC_TAB_ABORTED = 64,
  // CLOSED reflects owner shutdown; retain saved app tab metadata.
  BARC_TAB_OWNER_ENDED = 128,
  // Actual WebContents output mute/audibility, not capture or work eligibility.
  BARC_TAB_MUTED = 256, BARC_TAB_AUDIBLE = 512,
  BARC_TAB_VIDEO_PIP = 1024, BARC_TAB_DOCUMENT_PIP = 2048,
  // Without this bit the PiP fields are unavailable, not known-inactive.
  BARC_TAB_PIP_STATE_KNOWN = 4096
};
typedef void (*BarcTabCallback)(void* context, uint64_t observation,
                               int32_t event, int32_t window, int32_t tab,
                               const char* url, const char* title,
                               int32_t error, uint32_t flags);
BARC_API uint64_t barc_tab_observe(int32_t window, int32_t tab,
                                  BarcTabCallback callback, void* context);
BARC_API void barc_tab_unobserve(uint64_t observation);
// Pawl is opt-in per model-bound page. focus=0 cancels the previous capability.
// Strings/view are borrowed only during this UI-thread callback. kind:0 password,1 OTP.
typedef void (*BarcVaultCallback)(void* context, uint64_t observation,
    uint64_t focus, const char* origin, int32_t kind, void* native_view,
    double x, double y, double width, double height);
BARC_API int barc_tab_observe_vault(uint64_t observation, BarcVaultCallback callback);
BARC_API int barc_tab_vault_focus_is_current(uint64_t observation, uint64_t focus);
// Document/field identity only, for validating the application's own picker.
// Never authorizes a secret fill; fill still requires actual native focus.
BARC_API int barc_tab_vault_field_is_current(uint64_t observation, uint64_t focus);
BARC_API int barc_tab_cancel_vault_focus(uint64_t observation, uint64_t focus);
// Consumes exact focused-field capability; returns admission, not a renderer acknowledgement.
BARC_API int barc_tab_fill_vault(uint64_t observation, uint64_t focus,
    const char* username, const char* secret);

// Validated password-manager submission, not a renderer form event. submission=0
// retires the previous offer. Strings/view are borrowed only for this UI callback.
// Normal login redirects do not revoke submission identity; owner transfer/close do.
typedef void (*BarcVaultSaveCallback)(void* context, uint64_t observation,
    uint64_t submission, const char* origin, const char* username,
    const char* password, void* native_view);
BARC_API int barc_tab_observe_vault_save(uint64_t observation, BarcVaultSaveCallback callback);
BARC_API int barc_tab_vault_save_is_current(uint64_t observation, uint64_t submission);
BARC_API int barc_tab_cancel_vault_save(uint64_t observation, uint64_t submission);

// Request-owned Pawl authenticator transport. Only Chromium-validated register(0)
// and modal assertion(1) reach this consumer, after explicit provider choice.
// request=0 retires current UI. JSON/view borrowed only during the UI callback.
typedef void (*BarcVaultPasskeyCallback)(void* context, uint64_t observation,
    uint64_t request, int32_t operation, const char* arguments, void* native_view);
BARC_API int barc_tab_observe_vault_passkeys(uint64_t observation, BarcVaultPasskeyCallback callback);
BARC_API int barc_tab_vault_passkey_is_current(uint64_t observation, uint64_t request);
// Consumes the exact outstanding request. accepted=0 is refusal/cancellation.
// Replies are validated and passed through Chromium's ordinary CTAP response checks.
BARC_API int barc_tab_complete_vault_passkey(uint64_t observation, uint64_t request,
    int32_t accepted, const char* result);

// Consumer capability, initially disabled. Only an actual PageSession/model
// binding enables the explicit menu; utility-only observers leave it disabled.
// Independent of intrinsic Peek role: promotion can clear that role without
// rebinding. Disable/unobserve cancels the outstanding document intent.
BARC_API int barc_tab_enable_peek(uint64_t observation, int enabled);

// Bounded PNG capture of an already-presented tab. One in flight per existing
// observation. Bytes are borrowed during callback; nullptr/0 means failure.
// Context is the observation's existing context. Unobserve/terminal teardown
// cancels publication. Acceptance never loads, selects, shows or wakes a page.
// One media sink on an existing page observation; all strings are borrowed
// through the callback only (each bounded to 1024 UTF-16 code units). A missing
// KNOWN bit is unavailable state, not inactive playback. Unobserve cancels it.
enum BarcMediaFlags {
  BARC_MEDIA_KNOWN = 1, BARC_MEDIA_CONTROLLABLE = 2,
  BARC_MEDIA_PLAYING = 4, BARC_MEDIA_VIDEO = 8,
  BARC_MEDIA_PREVIOUS = 16, BARC_MEDIA_NEXT = 32,
  BARC_MEDIA_CAN_PLAY = 64, BARC_MEDIA_CAN_PAUSE = 128,
  BARC_MEDIA_AUDIBLE = 256
};
typedef void (*BarcMediaCallback)(void* context, uint64_t observation,
    int32_t window, int32_t tab, uint32_t flags, const char* title,
    const char* artist, const char* album);
// Like page observation, registration may occur inside another observer
// callback. Transport actions below still refuse during bridge callbacks.
BARC_API int barc_tab_observe_media(uint64_t observation, BarcMediaCallback callback);
enum BarcMediaAction {
  BARC_MEDIA_PLAY = 0, BARC_MEDIA_PAUSE = 1,
  BARC_MEDIA_PREVIOUS_TRACK = 2, BARC_MEDIA_NEXT_TRACK = 3
};
// Exact attached page, including background tabs; never selects/focuses. Return
// advertised action dispatch acceptance, never optimistic playback completion.
BARC_API int barc_tab_media_action(int32_t window, int32_t tab, int32_t action);

typedef void (*BarcTabThumbnailCallback)(void* context, uint64_t observation,
                                        uint64_t request, const uint8_t* png, size_t length);
BARC_API int barc_tab_capture_thumbnail(uint64_t observation, uint64_t request,
                                       BarcTabThumbnailCallback callback);
// JPEG of the last rendered viewport, including a hidden retained surface.
// No renderer show/wake/painting request. max_width: 1..4096 pixels; output
// dimensions <=4096, <=8 Mi pixels, encoded <=8 MiB. Shares thumbnail slot.
// Accepted delivery uses the existing observation context; stale/unavailable
// results deliver zero bytes. Explicit cancel suppresses delivery; the shared
// slot stays busy until the underlying compositor/encoder work retires.
BARC_API int barc_tab_capture_screenshot(uint64_t observation, uint64_t request,
    int32_t max_width, BarcTabThumbnailCallback callback);
BARC_API int barc_tab_cancel_capture(uint64_t observation, uint64_t request);

// Existing authorized DevMCP download job only. Exact observed document/profile;
// HTTPS GET, real partition cookies, no save-cookie/login prompts. Up to six
// requests per observation; streams <=100MiB to an owned same-directory temp.
// directory must be absolute, existing and canonical. Success transfers the
// unique temp path plus an owned parent directory descriptor to the caller.
// Caller revalidates identity and exclusively renames, or unlinks the basename
// through that descriptor, then closes it. Never cleans an old absolute path.
// Accepted callback once while observation lives; terminal teardown/unobserve
// cancels publication. Explicit request cancellation reports CANCELLED.
enum BarcFileResult { BARC_FILE_OK=0, BARC_FILE_CANCELLED=1,
  BARC_FILE_FAILED=2, BARC_FILE_TOO_LARGE=3, BARC_FILE_HTTP=4 };
typedef void (*BarcFileCallback)(void* context, uint64_t observation,
    uint64_t request, int32_t result, int32_t http_status, const char* temporary,
    const char* content_type, int64_t bytes, int32_t directory_descriptor);
BARC_API int barc_tab_download_file(uint64_t observation, uint64_t request,
    const char* url, const char* directory, BarcFileCallback callback);
BARC_API int barc_tab_cancel_file(uint64_t observation, uint64_t request);

// Exact current-document site data commands. Return dispatch acceptance; the
// callback reports deletion completion/cancellation/failure on the UI thread.
// COOKIES_AND_RELOAD waits for deletion, then reports reload dispatch acceptance.
// Cookie scope is host/.host and current top-level partition keys; CACHE never
// deletes cookies/DOM storage or globally flushes renderer memory resources. Unobserve/terminal teardown cancels publication.
enum BarcSiteDataAction {
  BARC_SITE_COOKIES = 0, BARC_SITE_CACHE = 1, BARC_SITE_COOKIES_AND_RELOAD = 2
};
enum BarcSiteDataResult {
  BARC_SITE_COMPLETED = 0, BARC_SITE_CANCELLED = 1, BARC_SITE_FAILED = 2
};
// Style application is scoped to an existing observation's exact top document.
// Request IDs increase per observation; new requests supersede confirmation of old ones.
// Result: 0 applied, 1 cancelled/stale, 2 failed. Empty CSS removes the sheet.
// Fixed translation channel. Payload is bounded JSON text/sample or node pairs,
// never executable code. request0 reports mutation batches; result2 aborts the
// current translation and asks the host to restore original text.
// Exact existing HTTP(S) top document. No activation, navigation or cold creation.
// mode0 preserves script completion; mode1 is an async function body.
// world0 page, world1 isolated automation. Return0 refuses without callback.
// Accepted requests settle once; cancellation does not undo JavaScript effects.
enum BarcScriptResult {
  BARC_SCRIPT_VALUE = 0, BARC_SCRIPT_UNDEFINED = 1, BARC_SCRIPT_EXCEPTION = 2,
  BARC_SCRIPT_REJECTED = 3, BARC_SCRIPT_UNAVAILABLE = 4, BARC_SCRIPT_BUSY = 5,
  BARC_SCRIPT_CANCELLED = 6, BARC_SCRIPT_UNSERIALIZABLE = 7
};
typedef void (*BarcScriptCallback)(void* context, uint64_t observation,
    uint64_t request, int32_t result, const char* text, size_t text_length,
    const char* json, size_t json_length, int32_t is_string);
BARC_API int barc_tab_evaluate_script(uint64_t observation, uint64_t request,
    int32_t mode, int32_t world, const char* source, BarcScriptCallback callback);
BARC_API int barc_tab_cancel_script(uint64_t observation, uint64_t request);
// Fixed document-bound element picker. UI thread, current visible HTTP(S) top
// document only; no navigation or arbitrary code. Accepted start replies once;
// selector is borrowed UTF-8 <=2048 bytes, empty on cancellation/unavailability.
// Cancelling retires DOM handlers as well as the reply. Requests increase per observation.
typedef void (*BarcPickerCallback)(void* context, uint64_t observation,
    uint64_t request, const char* selector, size_t length);
BARC_API int barc_tab_start_boost_picker(uint64_t observation, uint64_t request,
    BarcPickerCallback callback);
BARC_API int barc_tab_cancel_boost_picker(uint64_t observation, uint64_t request);


typedef void (*BarcTranslationCallback)(void* context, uint64_t observation,
    uint64_t generation, uint64_t request, int32_t result, const char* payload);
// operation0 sample,1 start,2 apply,3 restore; pairs contains only [{id,text}].
// Accepted calls complete once unless observation/runtime ends; new generation
// must begin with sample. Result0 applied,1 stale/cancelled,2 failed.
BARC_API int barc_tab_translate(uint64_t observation, uint64_t generation, uint64_t request,
    int32_t operation, const char* pairs, BarcTranslationCallback callback);

typedef void (*BarcStyleCallback)(void* context, uint64_t observation,
                                 uint64_t request, int32_t result);
BARC_API int barc_tab_set_user_css(uint64_t observation, uint64_t request,
                                   const char* committed_url, const char* css,
                                   BarcStyleCallback callback);

typedef void (*BarcSiteDataCallback)(void* context, uint64_t observation,
                                    uint64_t request, int32_t result);
BARC_API int barc_tab_clear_site_data(uint64_t observation, uint64_t request,
                                      int32_t action, BarcSiteDataCallback callback);

// Bounded nearest-first snapshot (at most100 entries); excludes current entry.
// direction:0 back,1 forward. UTF-8 JSON [{id,title,url}], required bytes include
// NUL. No write if capacity is insufficient. Stable IDs resolve live at dispatch;
// intervening navigation is allowed, but pruned IDs/changed owners refuse.
BARC_API size_t barc_tab_copy_history(int32_t window, int32_t tab, int32_t direction,
    char* output, size_t capacity);
BARC_API int barc_tab_go_to_history_entry(int32_t window, int32_t tab, int32_t entry);
BARC_API int barc_tab_go_back(int32_t window, int32_t tab);
BARC_API int barc_tab_go_forward(int32_t window, int32_t tab);
BARC_API int barc_tab_reload(int32_t window, int32_t tab);
BARC_API int barc_tab_stop(int32_t window, int32_t tab);
// Synchronous same-profile promotion. The source's empty notification is held
// until admission returns. Return nonzero only after publishing the exact live
// page/session in the destination. Refusal restores the still-owned source;
// an explicit newer close/transfer wins. Callback/context are borrowed only for
// this call. No callback occurs on preflight refusal. Null admission is invalid.
typedef int (*BarcTransferAdmission)(void* context, int32_t window, int32_t tab);
BARC_API int barc_tab_transfer_with_admission(int32_t source_window, int32_t tab,
                                             int32_t destination_window,
                                             BarcTransferAdmission admission,
                                             void* context);
// Consume one explicit document-bound link-menu intent. Creates an untouched
// blank in a hidden same-Widget exact-profile logical peer, then calls admission
// synchronously before its single target navigation. Admission only binds the
// existing page/slot; select/present must wait until this call returns. Refusal
// closes only that untouched owned blank. No caller URL or profile fallback.
BARC_API int barc_tab_create_peek(uint64_t source_observation, int32_t request,
                                BarcTransferAdmission admission, void* context);
// Return0 may follow admission1: retain that bound page until terminal/adoption.
// Refusal closes only a still-owned initial blank without pending navigation;
// newer moved/navigated contents survive with the old Peek role cleared.
//
// Native card over the unchanged base layout. Same exact Profile/OTR + physical
// group only. Selection and expected-sidebar relocation are admitted here;
// callers must NOT preselect the peer (which would clear the base split).
// Both NSViews are borrowed for this call and retained by native hosts while
// mounted. Header32px; actions28x96px, gap8px; card82% web width (clamped to fit),
// top/bottom8px. The native page lies below header; no transparent input overlay.
// No navigation/new page/NSWindow, physical activation or global focus occurs.
// Nonzero is this actual mount generation; repeat requires exact same views.
BARC_API uint64_t barc_tab_present_peek(int32_t source_window, int32_t source_tab,
    int32_t peek_window, int32_t peek_tab, void* expected_sidebar,
    void* header, void* actions);
// Exact mounted-view identity guards stale controls. Hide returns containers,
// parks/pauses the Peek and releases its two control hosts, never closes it.
// Pure is_presented has the same identity check without mutations/callbacks.
BARC_API int barc_tab_hide_peek(int32_t source_window, int32_t source_tab,
    int32_t peek_window, int32_t peek_tab, uint64_t generation,
    void* expected_header, void* expected_actions);
BARC_API int barc_tab_is_peek_presented(int32_t source_window, int32_t source_tab,
    int32_t peek_window, int32_t peek_tab, uint64_t generation,
    void* expected_header, void* expected_actions);

// Selects the admitted logical owner, then shows its normal Chromium window.
BARC_API int barc_window_show(int32_t window);
// native_view is an NSView* (including NSHostingView), retained by the native
// host until replacement, nullptr detach, or window close. Chromium retains
// window ownership. Detach restores the space reserved for the native shell.
// Nested attachment is refused (0); close requests may be deferred until this
// attachment returns. Native destruction or changed attachment returns 0.
BARC_API int barc_window_attach_native_shell(int32_t window, void* native_view);
// Regular product header, above stock chrome/page content. Both identities are
// mandatory expectations (expected_header may be null). Null replacement with
// height0 clears; otherwise height is1..128 logical pixels. Retained with the
// sidebar and moved synchronously with it, including Peek. Compact refuses.
BARC_API int barc_window_set_native_header(int32_t window, void* expected_sidebar,
    void* expected_header, void* replacement_header, int32_t height);
// Pure native-host identity query; null matches an existing empty host.
// Missing host, mismatched view or stale window returns 0.
BARC_API int barc_window_native_shell_is_owned(int32_t window,
                                             void* expected_view);
// Detach only the exact currently attached NSView; null/mismatch/stale returns 0.
BARC_API int barc_window_detach_native_shell_if_owned(int32_t window,
                                                    void* expected_view);
enum BarcDiscoveryWindowKind {
  BARC_DISCOVERY_NORMAL = 0, BARC_DISCOVERY_POPUP = 1,
  BARC_DISCOVERY_APP = 2, BARC_DISCOVERY_DEVTOOLS = 3,
  BARC_DISCOVERY_OTHER_WINDOW = 4
};
enum BarcDiscoveryProfileKind {
  BARC_DISCOVERY_REGULAR = 0, BARC_DISCOVERY_INCOGNITO = 1,
  BARC_DISCOVERY_GUEST = 2, BARC_DISCOVERY_OTHER_PROFILE = 3
};
enum BarcDiscoveryWindowFlags {
  BARC_DISCOVERY_PHYSICAL_ACTIVE = 1,
  BARC_DISCOVERY_PHYSICAL_VISIBLE = 2,
  BARC_DISCOVERY_SELECTED_CLIENT = 4,
  BARC_DISCOVERY_WINDOW_APP_FACTORY = 8,
  BARC_DISCOVERY_AWAITING_ADMISSION = 16,
  BARC_DISCOVERY_OWNER_ENDING = 32,
  BARC_DISCOVERY_COMPACT_MINI = 64
};
enum BarcDiscoveryTabFlags {
  BARC_DISCOVERY_ACTIVE_TAB = 1,
  BARC_DISCOVERY_TAB_APP_FACTORY = 2,
  BARC_DISCOVERY_TAB_PEEK = 4
};

typedef struct BarcDiscoveryWindow {
  uint64_t physical_group;  // Opaque; not a live window handle. Zero is invalid.
  int32_t window;
  int32_t active_tab;       // Actual selection in this logical tab strip, or 0.
  int32_t selected_client;  // Authoritative logical client for physical_group.
  uint32_t kind;
  uint32_t profile_kind;
  uint32_t flags;
  // Existing barc_window_profile_uuid result, NUL-terminated. Empty for every
  // nonregular/unknown profile; no default-profile inference.
  char regular_profile_uuid[37];
} BarcDiscoveryWindow;

typedef struct BarcDiscoveryTab {
  int32_t window;
  int32_t tab;
  int32_t opener_tab;  // Live JS opener TabHandle, or 0 (including noopener).
  int32_t index;
  // Intrinsic owning source, independent of the live JS opener/noopener state.
  int32_t peek_source_tab;
  uint32_t flags;      // ACTIVE_TAB does not imply physical activation/focus.
} BarcDiscoveryTab;

typedef struct BarcDiscoverySnapshot {
  uint64_t revision;
  size_t window_count;
  size_t tab_count;
} BarcDiscoverySnapshot;

enum BarcDiscoveryReadStatus {
  BARC_DISCOVERY_READ_OK = 0,
  BARC_DISCOVERY_READ_CAPACITY = 1,
  BARC_DISCOVERY_READ_UNAVAILABLE = 2,
  BARC_DISCOVERY_READ_INVALID_ARGUMENT = 3
};
// Pure live enumeration; no callbacks, selection, focus, navigation or showing.
// out_snapshot is required. Null arrays with zero capacity query needed counts.
// Insufficient capacity writes counts/revision only, never partial array rows.
// Run both calls on UI without yielding; retry capacity only if caller yielded.
BARC_API int32_t barc_discovery_snapshot(BarcDiscoveryWindow* windows,
                                size_t window_capacity,
                                BarcDiscoveryTab* tabs,
                                size_t tab_capacity,
                                BarcDiscoverySnapshot* out_snapshot);

typedef void (*BarcDiscoveryCallback)(void* context, uint64_t observation,
                                     uint64_t revision);
// One observer; duplicate registration returns0. Initial and later invalidations
// are coalesced posted NON-nestable tasks, never inline mutation callbacks.
// Revision changes cover ownership/membership, logical/active-tab selection,
// physical active/visible and admission state; not title/loading/progress.
// Callback is invalidation only: read a fresh snapshot. It may unobserve/close.
// Unobserve clears borrowed context and cancels every pending delivery; caller
// keeps context alive until unobserve (which is safe from inside its callback).
BARC_API uint64_t barc_discovery_observe(BarcDiscoveryCallback callback, void* context);
BARC_API void barc_discovery_unobserve(uint64_t observation);

// Pure single-window row lookup using the same authoritative row builder as
// snapshot, without enumerating/copying the catalog or invoking callbacks.
// out_window is required; returns 0 if unavailable. No selection/focus/show.
BARC_API int barc_window_discovery_state(int32_t window,
                                        BarcDiscoveryWindow* out_window);

// Chrome-created NORMAL windows only: attach/admit model first. Checks exact
// nonnull currently attached NSView before releasing deferred first Show mode.
// Refusal/stale/reentrant replacement returns0; never adopts/reloads/focuses a
// different logical client. Preserve Show/ShowInactive/Activate intent; do not
// replay over a newer intent or later native selection. Repeated admission of
// the same admitted view succeeds without replaying presentation.
// POPUP display/opener behavior is untouched.
// Factory-origin windows/tabs must be deduplicated against their own completion;
// consumers must not auto-adopt them from an earlier catalog notification.
BARC_API int barc_window_admit_discovered(int32_t window, void* expected_native_view);

// Additive C declarations for the existing barc_bridge.h. No context lookup map.
enum BarcBlockerPolicy {
  BARC_BLOCKER_UNRESOLVED = -1,
  BARC_BLOCKER_DISABLED = 0,
  BARC_BLOCKER_ENABLED = 1
};
enum BarcBlockerResult {
  BARC_BLOCKER_READY = 0,
  BARC_BLOCKER_INVALID_RULES = 1,
  BARC_BLOCKER_SUPERSEDED = 2,
  BARC_BLOCKER_OWNER_ENDED = 3
};
typedef void (*BarcBlockerCallback)(void* context, uint64_t native_revision,
                                   int32_t result);
typedef struct BarcBlockerState {
  uint64_t context_id;            // Actual keyed-service instance, never UUID.
  uint64_t publication_revision;  // Current accepted factory rule publication.
  uint64_t installed_revision;    // This context's acknowledged rule publication.
  uint64_t source_generation;     // Accepted process-monotonic source token.
  uint64_t required_source_generation; // Current atomic policy requirement.
  uint64_t pending_revision;      // This context's pending parse, or zero.
  int32_t ready;                  // Explicitly disabled, or current matcher ready.
  int32_t requested_policy;       // -1 unresolved, 0 disabled, 1 enabled.
} BarcBlockerState;

// Browser main thread. Register UNRESOLVED before ChromeMain; only the initial
// policy may be unresolved (domains must be null/count zero). This registration
// does not create stores, contexts or workers. Its required generation is zero.
// Publish the real saved policy at
// the existing runtime-ready point. Unknown intercepts eligible website traffic;
// explicit disabled releases it without requiring rule bytes. Other calls run
// on the initialized browser UI thread. Stock/nonregistered Chrome is untouched.
// Enabled policy requires a nonzero source token allocated by the existing
// manager build authority before producer work; disabled uses zero and releases
// requests/preparations independently of any build or validation. Domains and
// this requirement publish atomically. Settings never cancel/reparse rules.
// A token denotes one immutable source result, and is process-monotonic across
// producer recreation. Ordinary no-op update checks retain the accepted token.
// If a new intent was already announced, no-op success republishes retained
// bytes under that token; failed production publishes the failure marker below.
BARC_API int barc_blocker_set_policy(int32_t policy,
    uint64_t required_source_generation, const char* const* allowed_domains,
    size_t count);

// Global authoritative source publication. Return 0 rejects synchronously with
// no callback. Return 1 borrows stable immutable bytes until the callback runs
// exactly once on the browser UI thread, including shutdown/supersession. A
// worker copies bytes once to
// native-owned shared storage and validates them before acceptance; no context
// parser retains caller memory. Invalid/superseded input preserves accepted
// rules. Native revision is assigned on arrival, independently of the source
// token. source_generation is the same process-monotonic token required by the
// atomic policy, never a producer-local counter. READY acknowledges this source,
// not all context parsers. A stale token cannot displace a newer required source.
// bytes=null/length=0 declares producer failure for that token (UI INVALID_RULES
// completion); it preserves accepted bytes but fails an exact unmet requirement
// rather than stranding preparation. It never qualifies older rules as the
// failed generation. No-op success must publish real retained bytes, not null.
BARC_API int barc_blocker_publish_rules(const uint8_t* bytes, size_t length,
    uint64_t source_generation, BarcBlockerCallback callback, void* context);

// Captures the exact Profile/OTR of this live logical window synchronously.
// Return 1 owns one UI completion, even if the window/context ends; no retarget.
// READY acknowledges current native revision (zero is valid when disabled).
// Unknown waits for the initial real setting; enabled waits for exactly its
// required source generation and accepted rules
// and this context's own parser. Newer rules may complete SUPERSEDED. Peer calls
// join existing preparation, never duplicate parsing. Policy changes do not
// cancel a rule parse or turn blocking on after a later disable.
BARC_API int barc_blocker_prepare(int32_t window, BarcBlockerCallback callback,
    void* context);

// Pure existing-service query; never creates a context. Fully zeroes output and
// returns 0 on unavailable/invalid. Readiness belongs to actual context_id and
// acknowledged required source/publication, never regular UUID or another OTR
// context. An enabled ready result has source_generation equal to the current
// required_source_generation and installed_revision == publication_revision.
BARC_API int barc_blocker_state(int32_t window, BarcBlockerState* out_state);

// Exact live tab/context policy, copied before return. continued_host is the
// approved destination and is retained before its first load; clear on a later
// top-level attempt to a different host. Duration is relative monotonic time.
// Successful publication, including unchanged policy, posts the existing
// coalesced/non-nestable pending-application drain after the caller returns.
BARC_API int barc_blocker_set_tab_policy(int32_t window, int32_t tab,
    int32_t oauth, const char* continued_host, uint64_t disabled_for_ms);

#ifdef __cplusplus
}
#endif
#endif
