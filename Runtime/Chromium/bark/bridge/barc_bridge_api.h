#ifndef BARC_CHROMIUM_BRIDGE_API_H_
#define BARC_CHROMIUM_BRIDGE_API_H_

#include <stddef.h>
#include <stdint.h>

// The app's only view of the engine. The framework exports three Bark symbols:
// the engine entry, the digest of this header and the bridge table. Every other
// call goes through struct BarcBridge, whose member types the app takes from
// this header. Call every member on Chromium's browser UI thread, after browser
// startup, unless its comment says otherwise. Handles are process-local IDs,
// never C++ or Objective-C pointers; closed IDs fail.
//
// Each struct that crosses the bridge starts with `size`, its size in bytes as
// the header of the side that allocated it declares it. The allocating side
// sets it: the app for a struct it passes in or asks the engine to fill, each
// row of an array included; the engine for the table and for a struct it hands
// to a callback. The receiving side refuses a struct smaller than it knows,
// touches only the fields it knows and never changes `size`. A field added at
// the end of a struct or of the table then needs no new version; a change to an
// existing field or member renames the versioned symbols below.
// Clang asks for nullability on every pointer of a header once one pointer has
// it. Only the table's members carry it: the engine fills every one.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#ifdef __cplusplus
extern "C" {
#endif
#define BARC_API __attribute__((visibility("default")))
// Version 10 moves every call into one table and gives each crossing struct a
// leading size. Version 11 adds the window host's calls. Version 12 adds
// explicit space switch outcomes. Version 13 requires Bark-owned browser windows on macOS.
#define BARC_BRIDGE_VERSION 13
// Lowercase hex SHA-256 of the line "<SHA-256 of header>  barc_bridge_api.h\n"
// for this header as the engine compiled it. The app's main compares it with
// BARC_PUBLIC_HEADERS_SHA256 from the header it compiled.
BARC_API const char* barc_public_headers_sha256(void);
// The app enters the engine through this symbol, not ChromeMain. A new bridge
// version renames it, so an app and framework built for different versions fail
// at dlsym, as Chromium's ChromeAppModeStart_v<N> does. Update the name in
// chrome/app/framework.exports and framework.order with it.
#define BARC_ENGINE_MAIN_SYMBOL "barc_engine_main_v13"
typedef int (*BarcEngineMain)(int argc, const char** argv);
BARC_API int barc_engine_main_v13(int argc, const char** argv);
// The table for this version, valid for the process lifetime. Its name changes
// with the entry's.
#define BARC_BRIDGE_SYMBOL "barc_bridge_v13"
struct BarcBridge;
typedef const struct BarcBridge* (*BarcBridgeEntry)(void);
BARC_API const struct BarcBridge* barc_bridge_v13(void);

// ---- Startup ----------------------------------------------------------------

// Where a person's New Window or New Private Window request comes from: a key,
// a menu, the Dock or a page's command.
enum BarcApplicationWindowRequest {
  BARC_APPLICATION_NEW_WINDOW = 1,
  BARC_APPLICATION_NEW_PRIVATE_WINDOW = 2
};
// A validated incoming URL chooses current-space or detached-mini presentation.
enum BarcApplicationPresentation {
  BARC_APPLICATION_CURRENT_SPACE = 0,
  BARC_APPLICATION_MINI = 1
};
// What the browser target callback is asked for.
enum BarcApplicationTargetKind {
  BARC_APPLICATION_TARGET_URL = 0,
  BARC_APPLICATION_TARGET_DOCK_REOPEN = 2,
  BARC_APPLICATION_TARGET_PENDING_PAGE = 3
};
// What the browser target callback answers.
enum BarcApplicationTargetResult {
  // Temporary ordinary-window opening, only for URL requests.
  BARC_APPLICATION_TARGET_ORDINARY_WINDOW = -1,
  BARC_APPLICATION_TARGET_REFUSED = 0,
  BARC_APPLICATION_TARGET_FOUND = 1
};
// UUID fields are canonical, NUL-terminated model identities, never paths.
// Native copies this value before the resolver returns.
typedef struct BarcApplicationTarget {
  size_t size;
  int32_t window;  // Exact logical owner, or zero for a regular-profile load.
  uint32_t presentation;
  char regular_profile_uuid[37];
  char space_uuid[37];
} BarcApplicationTarget;
typedef void (*BarcRuntimeReadyCallback)(void* user_data);
// accepted=1 follows current shutdown consent, before teardown; accepted=0
// reports a later veto only after that notification.
typedef void (*BarcRuntimeCloseCallback)(int32_t accepted, void* user_data);
typedef void (*BarcWindowRequestCallback)(int32_t request, void* user_data);
// kind is a BarcApplicationTargetKind; the result a BarcApplicationTargetResult.
// validated_url is null for profile-only lookup. Pending handles are zero except
// for PENDING_PAGE, which never selects, creates or navigates. The engine sets
// out_target's size and zeroes the rest; FOUND requires an initialized exact
// target. Never infer a default owner.
typedef int32_t (*BarcBrowserTargetCallback)(int32_t kind,
                                            const char* validated_url,
                                            int32_t pending_window,
                                            int32_t pending_tab,
                                            BarcApplicationTarget* out_target,
                                            void* user_data);

// ---- Profiles and private sessions -----------------------------------------

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

typedef enum {
  BARC_PROFILE_DELETED = 0,
  BARC_PROFILE_DELETE_CANCELLED = 1,
  BARC_PROFILE_DELETE_PENDING = 2,
  BARC_PROFILE_CLOSE_ADMITTED = 3,
} barc_profile_delete_result;
typedef void (*barc_profile_delete_callback)(barc_profile_delete_result result,
                                            void* user_data);

// status is a BarcSearchStatus.
typedef void (*barc_search_callback)(void* context, int32_t status, const char* json);
enum BarcSearchStatus {
  BARC_SEARCH_OK = 0,
  BARC_SEARCH_FAILED = 1,
  BARC_SEARCH_SELECTION_UNAVAILABLE = 2,
  // An untouched fallback profile asks for the import seed; retry once with it.
  BARC_SEARCH_NEEDS_SEED = 3
};

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

// ---- Page commands -----------------------------------------------------------

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
  BARC_PAGE_DEVTOOLS_PERFORMANCE = 14,
  // These target an exact visible page, including an attached split pane or Peek.
  BARC_PAGE_SHOW_CERTIFICATE = 15,
  // Returns a BarcCertificateState for the visible committed document.
  BARC_PAGE_CERTIFICATE_STATE = 16
};
enum BarcCertificateState {
  BARC_CERTIFICATE_UNAVAILABLE = 0,
  BARC_CERTIFICATE_AVAILABLE = 1,
  BARC_CERTIFICATE_SECURE = 2
};
enum BarcHistoryDirection { BARC_HISTORY_BACK = 0, BARC_HISTORY_FORWARD = 1 };

// ---- Downloads ---------------------------------------------------------------

enum BarcDownloadEvent { BARC_DOWNLOAD_ITEM = 0, BARC_DOWNLOAD_REMOVED = 1,
                         BARC_DOWNLOAD_MANAGER_ENDED = 2 };
enum BarcDownloadState { BARC_DOWNLOAD_PROGRESS = 0, BARC_DOWNLOAD_COMPLETE = 1,
                         BARC_DOWNLOAD_CANCELLED = 2, BARC_DOWNLOAD_INTERRUPTED = 3 };
enum BarcDownloadFlags { BARC_DOWNLOAD_PRIVATE = 1, BARC_DOWNLOAD_UNSAFE = 2,
                         BARC_DOWNLOAD_SAFE_FILE = 4 };
struct BarcDownloadSnapshot {
  size_t size;
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
enum BarcDownloadAction { BARC_DOWNLOAD_CANCEL = 0, BARC_DOWNLOAD_REMOVE = 1 };

// ---- Splits ------------------------------------------------------------------

// Live splits preserve each tab's actual logical/Profile owner. Same-owner
// panes use the native collection; multiple regular owners in one physical
// Widget borrow their existing containers without changing Chrome collections.
// Private panes remain confined to one exact owner/context.
// count is 2..4; count-1 dividers increase strictly in (0,1). Set requires
// active_tab owned by the selected normal logical owner; other handles must
// belong to that same physical group.
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
enum BarcSplitOrientation { BARC_SPLIT_SIDE_BY_SIDE = 0, BARC_SPLIT_STACKED = 1 };
// The app-positioned physical presentation of independent tabs.
enum BarcSplitKind { BARC_SPLIT_PHYSICAL = 1 };
typedef struct BarcSplitLayout {
  size_t size;
  uint32_t count;
  uint32_t orientation;  // BarcSplitOrientation.
  int32_t tabs[4];
  double dividers[3];
  int32_t active_tab;
  int32_t collection;
  // Always BARC_SPLIT_PHYSICAL; `collection` is always 0. Set ignores
  // identities; Get returns the actual generation; Clear compares it.
  uint32_t kind;
  uint64_t generation;
} BarcSplitLayout;

// ---- Tab observation ---------------------------------------------------------

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

// Pawl is opt-in per model-bound page. focus=0 cancels the previous capability.
// Strings/view are borrowed only during this UI-thread callback.
enum BarcVaultFieldKind { BARC_VAULT_PASSWORD = 0, BARC_VAULT_ONE_TIME_CODE = 1 };
typedef void (*BarcVaultCallback)(void* context, uint64_t observation,
    uint64_t focus, const char* origin, int32_t kind, void* native_view,
    double x, double y, double width, double height);
// Validated password-manager submission, not a renderer form event. submission=0
// retires the previous offer. Strings/view are borrowed only for this UI callback.
// Normal login redirects do not revoke submission identity; owner transfer/close do.
typedef void (*BarcVaultSaveCallback)(void* context, uint64_t observation,
    uint64_t submission, const char* origin, const char* username,
    const char* password, void* native_view);
// Request-owned Pawl authenticator transport. Only Chromium-validated register
// and modal assertion reach this consumer, after explicit provider choice.
// request=0 retires current UI. JSON/view borrowed only during the UI callback.
enum BarcVaultPasskeyOperation { BARC_PASSKEY_REGISTER = 0, BARC_PASSKEY_ASSERT = 1 };
typedef void (*BarcVaultPasskeyCallback)(void* context, uint64_t observation,
    uint64_t request, int32_t operation, const char* arguments, void* native_view);

// A mask: BARC_TAB_PEEK_CAPABLE allows the link menu and Option-click; with
// BARC_TAB_PEEK_ON_SHIFT_CLICK a Shift-click on a link requests Peek too.
enum { BARC_TAB_PEEK_CAPABLE = 1, BARC_TAB_PEEK_ON_SHIFT_CLICK = 2 };

// A missing KNOWN bit is unavailable state, not inactive playback.
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
enum BarcMediaAction {
  BARC_MEDIA_PLAY = 0, BARC_MEDIA_PAUSE = 1,
  BARC_MEDIA_PREVIOUS_TRACK = 2, BARC_MEDIA_NEXT_TRACK = 3
};

typedef void (*BarcTabThumbnailCallback)(void* context, uint64_t observation,
                                        uint64_t request, const uint8_t* png, size_t length);

enum BarcFileResult { BARC_FILE_OK=0, BARC_FILE_CANCELLED=1,
  BARC_FILE_FAILED=2, BARC_FILE_TOO_LARGE=3, BARC_FILE_HTTP=4 };
typedef void (*BarcFileCallback)(void* context, uint64_t observation,
    uint64_t request, int32_t result, int32_t http_status, const char* temporary,
    const char* content_type, int64_t bytes, int32_t directory_descriptor);

enum BarcSiteDataAction {
  BARC_SITE_COOKIES = 0, BARC_SITE_CACHE = 1, BARC_SITE_COOKIES_AND_RELOAD = 2
};
enum BarcSiteDataResult {
  BARC_SITE_COMPLETED = 0, BARC_SITE_CANCELLED = 1, BARC_SITE_FAILED = 2
};
typedef void (*BarcSiteDataCallback)(void* context, uint64_t observation,
                                    uint64_t request, int32_t result);

enum BarcStyleResult {
  BARC_STYLE_APPLIED = 0, BARC_STYLE_CANCELLED = 1, BARC_STYLE_FAILED = 2
};
typedef void (*BarcStyleCallback)(void* context, uint64_t observation,
                                 uint64_t request, int32_t result);

// Fixed translation channel. Payload is bounded JSON text/sample or node pairs,
// never executable code. Request 0 reports mutation batches; FAILED aborts the
// current translation and asks the host to restore original text.
enum BarcTranslateOperation {
  BARC_TRANSLATE_SAMPLE = 0, BARC_TRANSLATE_START = 1,
  BARC_TRANSLATE_APPLY = 2, BARC_TRANSLATE_RESTORE = 3
};
enum BarcTranslateResult {
  BARC_TRANSLATE_APPLIED = 0, BARC_TRANSLATE_STALE = 1, BARC_TRANSLATE_FAILED = 2
};
typedef void (*BarcTranslationCallback)(void* context, uint64_t observation,
    uint64_t generation, uint64_t request, int32_t result, const char* payload);

enum BarcScriptMode { BARC_SCRIPT_COMPLETION_VALUE = 0, BARC_SCRIPT_ASYNC_BODY = 1 };
enum BarcScriptWorld { BARC_SCRIPT_PAGE_WORLD = 0, BARC_SCRIPT_ISOLATED_WORLD = 1 };
enum BarcScriptResult {
  BARC_SCRIPT_VALUE = 0, BARC_SCRIPT_UNDEFINED = 1, BARC_SCRIPT_EXCEPTION = 2,
  BARC_SCRIPT_REJECTED = 3, BARC_SCRIPT_UNAVAILABLE = 4, BARC_SCRIPT_BUSY = 5,
  BARC_SCRIPT_CANCELLED = 6, BARC_SCRIPT_UNSERIALIZABLE = 7
};
typedef void (*BarcScriptCallback)(void* context, uint64_t observation,
    uint64_t request, int32_t result, const char* text, size_t text_length,
    const char* json, size_t json_length, int32_t is_string);

typedef void (*BarcPickerCallback)(void* context, uint64_t observation,
    uint64_t request, const char* selector, size_t length);

// Synchronous same-profile admission of a moved or created page. Return nonzero
// only after publishing the exact live page/session in the destination.
typedef int (*BarcTransferAdmission)(void* context, int32_t window, int32_t tab);

// ---- Discovery ---------------------------------------------------------------

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
  BARC_DISCOVERY_COMPACT_MINI = 64,
  BARC_DISCOVERY_EMPTY_STRIP = 128,
  BARC_DISCOVERY_APP_LIFETIME = 256,
  // The selected space presents no page despite any parked strip selection.
  BARC_DISCOVERY_SPACE_SUPPRESSED = 512
};
enum BarcDiscoveryTabFlags {
  BARC_DISCOVERY_ACTIVE_TAB = 1,
  BARC_DISCOVERY_TAB_APP_FACTORY = 2,
  BARC_DISCOVERY_TAB_PEEK = 4
};

typedef struct BarcDiscoveryWindow {
  size_t size;
  uint64_t physical_group;  // Opaque; not a live window handle. Zero is invalid.
  int32_t window;
  int32_t active_tab;       // Actual selection in this logical tab strip, or 0.
  int32_t selected_client;  // Authoritative logical client for physical_group.
  uint32_t kind;
  uint32_t profile_kind;
  uint32_t flags;
  // The window_profile_uuid result, NUL-terminated. Empty for every
  // nonregular/unknown profile; no default-profile inference.
  char regular_profile_uuid[37];
} BarcDiscoveryWindow;

typedef struct BarcDiscoveryTab {
  size_t size;
  int32_t window;
  int32_t tab;
  int32_t opener_tab;  // Live JS opener TabHandle, or 0 (including noopener).
  int32_t index;
  // Intrinsic owning source, independent of the live JS opener/noopener state.
  int32_t peek_source_tab;
  uint32_t flags;      // ACTIVE_TAB does not imply physical activation/focus.
} BarcDiscoveryTab;

typedef struct BarcDiscoverySnapshot {
  size_t size;
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
typedef void (*BarcDiscoveryCallback)(void* context, uint64_t observation,
                                     uint64_t revision);

// ---- Content blocking ----------------------------------------------------------

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
  size_t size;
  uint64_t context_id;            // Actual keyed-service instance, never UUID.
  uint64_t publication_revision;  // Current accepted factory rule publication.
  uint64_t installed_revision;    // This context's acknowledged rule publication.
  uint64_t source_generation;     // Accepted process-monotonic source token.
  uint64_t required_source_generation; // Current atomic policy requirement.
  uint64_t pending_revision;      // This context's pending parse, or zero.
  int32_t ready;                  // Explicitly disabled, or current matcher ready.
  int32_t requested_policy;       // BarcBlockerPolicy.
} BarcBlockerState;

// ---- Window host -------------------------------------------------------------
// A macOS browser window belongs to a Bark host. The app supplies its root view
// and places the tabs' native page views in it. Unsupported window requests fail
// without presenting another browser shell.

// Window chrome the app owns, in points.
typedef struct BarcWindowChrome {
  size_t size;
  double titlebar_height;
  // From the window's leading edge to the first window button's.
  double leading_inset;
} BarcWindowChrome;

// Kinds are appended without a new version; an app ignores a kind it does not
// know.
enum BarcWindowHostEventKind {
  // `tab`'s page view `view` leaves the window: the tab closes, moves to another
  // window or replaces its contents.
  BARC_WINDOW_HOST_PAGE_VIEW_RETIRED = 1,
  // The window entered or left full screen; `fullscreen` says which kind.
  BARC_WINDOW_HOST_FULLSCREEN_CHANGED = 2,
  // `tab`'s renderer is gone and its page view `view` shows nothing; the app
  // draws its own crashed state over it.
  BARC_WINDOW_HOST_PAGE_CRASHED = 3,
  // `tab`'s page has a renderer again, after a reload.
  BARC_WINDOW_HOST_PAGE_RESTORED = 4
};
enum BarcFullscreenKind {
  BARC_FULLSCREEN_NONE = 0,
  BARC_FULLSCREEN_WINDOW = 1,
  // A page asked for full screen: hide the sidebar and the page frame.
  BARC_FULLSCREEN_PAGE = 2
};
typedef struct BarcWindowHostEvent {
  size_t size;
  int32_t kind;        // BarcWindowHostEventKind.
  int32_t window;      // The logical window the event concerns.
  int32_t tab;         // The page events only, else 0.
  int32_t fullscreen;  // FULLSCREEN_CHANGED only: BarcFullscreenKind.
  // The page events only: the tab's page view, as tab_native_view returned it;
  // alive during the call. On PAGE_VIEW_RETIRED, remove it only if the app
  // still shows it there.
  void* view;
} BarcWindowHostEvent;
// Borrowed event, valid during the call. Delivered from a posted task, never
// inside the engine change that caused it.
typedef void (*BarcWindowHostCallback)(const BarcWindowHostEvent* event,
                                       void* context);

// ---- The table -----------------------------------------------------------------

// A space is resolved by the app. Window anchors the physical group, client
// names its requested logical owner, and tab is optional. With tab zero,
// the selected space presents no page and its native tab strip stays parked.
typedef struct BarcSpaceSwitchRequest {
  uint32_t size;
  uint64_t request;
  int32_t window;
  int32_t client;
  int32_t tab;
} BarcSpaceSwitchRequest;

typedef enum BarcSpaceSwitchStatus {
  BARC_SPACE_SWITCH_APPLIED = 1,
  BARC_SPACE_SWITCH_SUPERSEDED = 2,
  BARC_SPACE_SWITCH_REFUSED = 3,
  BARC_SPACE_SWITCH_CLOSED = 4,
} BarcSpaceSwitchStatus;

typedef enum BarcSpaceSwitchPromptKind {
  BARC_SPACE_SWITCH_PERMISSION = 1,
  BARC_SPACE_SWITCH_UPLOAD = 2,
  BARC_SPACE_SWITCH_TAB_MODAL = 3,
} BarcSpaceSwitchPromptKind;

typedef enum BarcSpaceSwitchPromptDisposition {
  BARC_SPACE_SWITCH_PROMPT_PARKED = 1,
  BARC_SPACE_SWITCH_PROMPT_RETAINED = 2,
  BARC_SPACE_SWITCH_PROMPT_RETIRED = 3,
  BARC_SPACE_SWITCH_PROMPT_CANCELLED = 4,
  BARC_SPACE_SWITCH_PROMPT_WAITING = 5,  // Live chooser preparing its panel.
} BarcSpaceSwitchPromptDisposition;

typedef struct BarcSpaceSwitchPrompt {
  uint32_t size;
  int32_t kind;
  int32_t disposition;
  int32_t client;
  int32_t tab;
  uint64_t document;
} BarcSpaceSwitchPrompt;

typedef struct BarcSpaceSwitchResult {
  uint32_t size;
  int32_t status;
  uint64_t request;
  uint64_t physical_group;
  int32_t selected_client;
  int32_t active_tab;
  // Observable outgoing renderer permissions, upload chooser callbacks and
  // WebContents-modal dialogs. OS-wide and other external dialogs have no
  // document-aware tracking here. A zero count describes the tracked kinds.
  const BarcSpaceSwitchPrompt* prompts;
  size_t prompt_count;
} BarcSpaceSwitchResult;

typedef void (*BarcSpaceSwitchCallback)(const BarcSpaceSwitchResult* result,
                                       void* context);

struct BarcBridge {
  size_t size;

  // Static NUL-terminated engine version, valid for the process lifetime.
  const char* (* _Nonnull chromium_version)(void);

  // -- Startup. Main thread, once each, before ChromeMain. Browser-process only;
  // never starts NSApplication. Each callback and its user_data are borrowed
  // until runtime stop or ChromeMain's return.
  void (* _Nonnull set_runtime_ready_callback)(BarcRuntimeReadyCallback callback,
                                               void* user_data);
  // Initial attempts, non-quit window close and post-stop work never notify.
  void (* _Nonnull set_runtime_close_callback)(BarcRuntimeCloseCallback callback,
                                               void* user_data);
  // In native application mode New Window and New Private Window requests come
  // here and Chromium opens nothing: the app opens the window it wants. Dock
  // reopen comes here as New Window when the browser target names no window.
  void (* _Nonnull set_runtime_window_request_callback)(
      BarcWindowRequestCallback callback, void* user_data);
  // The callback runs on browser UI.
  void (* _Nonnull set_runtime_browser_target_callback)(
      BarcBrowserTargetCallback callback, void* user_data);
  // Browser UI thread. Complete after successful native attachment with a live
  // window, or 0 on failure. Repeated completion is ignored. Failure requests
  // normal Chromium shutdown. After ChromeMain returns, 0 only clears callbacks.
  void (* _Nonnull runtime_complete_startup)(int32_t window);

  // -- Profiles and private sessions.
  // UUID is copied before return, accepts either case, and must identify an
  // existing app-owned profile (caller checks its app model). Nil UUID is
  // rejected. No display name or path is accepted. Creates a normal Chromium
  // window in that profile; never uses the active or default profile. Window is
  // a process-local SessionID, 0 on failure.
  // BLANK constructs an inactive about:blank owner without Show; the caller
  // admits its model/native attachment before selecting/presenting it.
  // Completion is queued on UI and occurs once while the browser UI loop remains
  // operational. Cancellation during shutdown is best effort: no callback is
  // delivered on another thread, but once UI stops accepting tasks delivery is
  // not guaranteed. callback must be non-null. Its code and user_data must remain
  // valid until completion or until native runtime shutdown has fully completed.
  // A stopped UI task runner may report cancellation before this call returns.
  // Successful completion establishes ownership/navigation request, not page-load
  // completion.
  void (* _Nonnull profile_open_window)(const char* profile_uuid,
                                        barc_profile_destination destination,
                                        barc_profile_window_callback callback,
                                        void* user_data);
  // Creates a normal profile-bound logical Chrome window inside the live native
  // owner, returning its own SessionID. Stale/refused hosts fail; never opens a
  // fallback native window. Same async UUID/lifetime/callback contract as
  // profile_open_window.
  void (* _Nonnull profile_open_in_native_window)(
      int32_t native_owner, const char* profile_uuid,
      barc_profile_destination destination,
      barc_profile_window_callback callback, void* user_data);
  // Same async callback/user-data lifetime as profile_open_window. Creates a
  // fresh private session with a manager-owned Guest parent and primary OTR,
  // initially blank. The callback result stays hidden; the caller must admit
  // its model/native header before explicitly showing the returned window.
  // No path/regular UUID is accepted, no persistent-profile fallback. Child
  // windows/popups must reuse the returned window's exact Profile. Closing all
  // session windows destroys OTR before releasing/deleting its ephemeral parent.
  void (* _Nonnull private_session_open_window)(
      barc_profile_window_callback callback, void* user_data);
  // Returns bytes required including NUL (37), or 0 for stale/non-Barc/off-record
  // windows or unavailable runtime. Short buffers are NUL-terminated. Output is
  // the canonical lowercase UUID derived from the actual manager-owned window
  // Profile, never a cached caller label. A non-null buffer must point to at
  // least capacity writable chars; nullptr queries size.
  size_t (* _Nonnull window_profile_uuid)(int32_t window, char* buffer,
                                          size_t capacity);
  // Same buffer contract as window_profile_uuid, but accepts only a live
  // manager-owned Barc private Guest primary OTR. Returns its canonical session
  // UUID, never a regular-profile UUID or filesystem path. Children sharing the
  // exact private Profile return the same session identity.
  size_t (* _Nonnull window_private_session_uuid)(int32_t window, char* buffer,
                                                  size_t capacity);
  // Both UUIDs must be existing app-model regular identities, distinct.
  // The caller durably records the intent before admission and keeps target
  // unavailable through PENDING/restart. CANCELLED proves no destructive mark;
  // DELETED confirms polite service/data wipe or proven absent unloaded bytes,
  // with marked directory removal possibly deferred to Chromium restart cleanup.
  // reconcile_only must be 0 or 1. 1 never starts deletion of a present
  // unmarked profile; only reconciles absence or an already marked cleanup.
  // No stock/default replacement is created. Same callback lifetime as factories.
  // CANCELLED retains a scheduling reservation until the caller has durably
  // cleared its intent and acknowledges it. No data is removed before that result.
  int (* _Nonnull profile_delete_cancel_ack)(const char* target_uuid,
                                             const char* survivor_uuid);
  void (* _Nonnull profile_delete_kept)(const char* target_uuid,
                                        const char* survivor_uuid,
                                        int32_t reconcile_only,
                                        barc_profile_delete_callback callback,
                                        void* user_data);
  // Active-profile reassignment. Uses the same bounded deletion request.
  // prepare closes target windows with ordinary veto handling, then reports
  // CLOSE_ADMITTED without marking/wiping/cancelling downloads. The caller must
  // durably commit exact destination assignment and retained source metadata
  // before continue. reconcile_only never starts unmarked/uncommitted deletion.
  void (* _Nonnull profile_prepare_reassignment)(
      const char* target_uuid, const char* survivor_uuid,
      int32_t reconcile_only, barc_profile_delete_callback callback,
      void* user_data);
  void (* _Nonnull profile_continue_deletion)(
      const char* target_uuid, const char* survivor_uuid,
      barc_profile_delete_callback callback, void* user_data);
  // Exact-profile search authority; borrowed JSON is copied before return.
  // window>0 must match uuid and is_private; window=0 loads only an existing
  // model-validated regular UUID. No active/default lookup.
  // seed is {selected,engines:[{id,name,url}]} with token-free templates. It is
  // imported once per regular profile; private import remains session-local.
  // null seed performs no catalog serialization. selection is an existing
  // native provider GUID or null (snapshot only). Callback JSON is borrowed for
  // the call; once on UI while runtime operational. Same shutdown lifetime
  // contract as profile factories.
  void (* _Nonnull profile_search_state)(const char* uuid, int32_t window,
                                         int32_t is_private, const char* seed,
                                         const char* selection,
                                         int32_t include_choices,
                                         barc_search_callback callback,
                                         void* context);
  // Fixed authenticated live-source GETs, regular app profiles only; no window,
  // caller-supplied URL/header/body, cookie export, redirects or Set-Cookie
  // writes. source is a barc_live_source. Accepted token completes exactly once
  // on UI, including cancel; refusal 0 has no callback. Byte view is borrowed for
  // the callback. Cancellation cannot undo an already-sent GET. Bounds: 8
  // global/2 per UUID, 4MiB, 20s including profile load.
  uint64_t (* _Nonnull profile_live_get)(const char* uuid, int32_t source,
                                         const char* argument,
                                         barc_live_callback callback,
                                         void* context);
  void (* _Nonnull profile_live_cancel)(uint64_t token);

  // -- Windows.
  // Creates an empty same-profile peer for immediate page insertion/transfer.
  // Close it if the insertion fails. It becomes visible once populated.
  int32_t (* _Nonnull window_new_peer)(int32_t source_window);
  // Empty inactive normal client in an existing product's physical window,
  // inheriting the source's exact native Profile/private context. Both owners
  // are revalidated across creation. No tab, selection, focus, or showing occurs.
  // Zero is refusal; caller closes only its returned empty client on failure.
  int32_t (* _Nonnull window_new_peer_in_native_window)(int32_t source_window,
                                                        int32_t physical_owner);
  // Returns whether a valid request was dispatched; Chrome may delay/deny close.
  int (* _Nonnull window_close)(int32_t window);
  // Hands the physical window holding this client to the app, for every client it
  // holds now or later. A client whose last tab closes or moves out then stays
  // open, keeps its selection and reports BARC_DISCOVERY_EMPTY_STRIP. The window
  // closes only through window_close of its last client, its close button or
  // quit, each with the usual prompts. Closing the selected client while others
  // remain still selects another one, so select first. Zero for an unknown,
  // closing or non-normal client.
  int (* _Nonnull window_set_app_lifetime)(int32_t window);
  // The app shows no page in the physical window holding this client, as on an
  // empty space. Page commands there then do nothing, from keys or the menu,
  // whichever client is selected, until the app passes hidden=0. Zero for an
  // unknown or closing client.
  int (* _Nonnull window_set_page_hidden)(int32_t window, int hidden);
  size_t (* _Nonnull window_tab_count)(int32_t window);
  int32_t (* _Nonnull window_tab_at)(int32_t window, size_t index);
  // Select this logical browser within its physical native window. Returns 0
  // for stale/refused admission; does not claim completed native
  // focus/activation.
  int (* _Nonnull window_select)(int32_t window);
  // Selects the admitted logical owner, then shows its normal Chromium window.
  int (* _Nonnull window_show)(int32_t window);
  // native_view is an NSView* (including NSHostingView), retained by the native
  // host until replacement, nullptr detach, or window close. Chromium retains
  // window ownership. Detach restores the space reserved for the native shell.
  // Nested attachment is refused (0); close requests may be deferred until this
  // attachment returns. Native destruction or changed attachment returns 0.
  int (* _Nonnull window_attach_native_shell)(int32_t window, void* native_view);
  // Regular product header, above stock chrome/page content. Both identities are
  // mandatory expectations (expected_header may be null). Null replacement with
  // height0 clears; otherwise height is1..128 logical pixels. Retained with the
  // sidebar and moved synchronously with it, including Peek. Compact refuses.
  int (* _Nonnull window_set_native_header)(int32_t window,
                                            void* expected_sidebar,
                                            void* expected_header,
                                            void* replacement_header,
                                            int32_t height);
  // Pure native-host identity query; null matches an existing empty host.
  // Missing host, mismatched view or stale window returns 0.
  int (* _Nonnull window_native_shell_is_owned)(int32_t window,
                                                void* expected_view);
  // Detach only the exact currently attached NSView; null/mismatch/stale returns 0.
  int (* _Nonnull window_detach_native_shell_if_owned)(int32_t window,
                                                       void* expected_view);

  // -- Tabs.
  int32_t (* _Nonnull tab_create)(int32_t window, const char* url, int foreground);
  // Refused (0) during bridge callbacks: they can run inside a tab strip change,
  // where Chromium's activation CHECKs. Callers may post a browser UI task.
  int (* _Nonnull tab_select)(int32_t window, int32_t tab);
  int (* _Nonnull tab_search)(int32_t window, int32_t tab, const char* query,
                              const char* kagi_session_token);
  int (* _Nonnull tab_navigate)(int32_t window, int32_t tab, const char* url);
  // Returns whether a valid request was dispatched; Chrome may delay/deny close.
  // A tab ID stops resolving only after actual destruction.
  int (* _Nonnull tab_close)(int32_t window, int32_t tab);
  // Cross-profile transfer is rejected; reassignment requires a new document.
  // Transfer during a navigation callback is refused; callers may post a UI task.
  int (* _Nonnull tab_transfer)(int32_t source_window, int32_t tab,
                                int32_t destination_window);
  // Synchronous same-profile promotion. The source's empty notification is held
  // until admission returns. Return nonzero only after publishing the exact live
  // page/session in the destination. Refusal restores the still-owned source;
  // an explicit newer close/transfer wins. Callback/context are borrowed only for
  // this call. No callback occurs on preflight refusal. Null admission is invalid.
  int (* _Nonnull tab_transfer_with_admission)(int32_t source_window,
                                               int32_t tab,
                                               int32_t destination_window,
                                               BarcTransferAdmission admission,
                                               void* context);
  // Metadata for the one native application launch awaiting model admission.
  // No hint returns 0; a hint returns required bytes including NUL (37). These
  // queries never create/select/focus a page or consult another profile.
  size_t (* _Nonnull tab_copy_launch_space)(int32_t window, int32_t tab,
                                            char* output, size_t capacity);
  int (* _Nonnull tab_application_pending)(int32_t window, int32_t tab);
  // command is a BarcPageCommand. UI commands normally target only this exact
  // selected logical owner and active tab. Certificate commands use the exact
  // attached visible page, including a split or Peek. No selection/focus or
  // fallback retargeting is performed. Return dispatch acceptance (or a
  // BarcCertificateState for CERTIFICATE_STATE), not completion of a dialog, find
  // result, print job or DevTools. Refused during bridge callbacks; callers may
  // post a browser UI task. CLEAR_BACK_FORWARD_CACHE also admits an exact
  // background tab; it drops cached history documents without
  // selecting/reloading its live page.
  int (* _Nonnull tab_execute_command)(int32_t window, int32_t tab,
                                       int32_t command);
  // Explicit tab mute, including background tabs; never changes selection or
  // site sound settings. muted must be 0 or 1. Return actual helper acceptance
  // for the still-live exact owner; actual state is reported by observation.
  int (* _Nonnull tab_set_muted)(int32_t window, int32_t tab, int muted);
  // Returns bytes required including NUL; 0 means stale/invalid handle. A short
  // buffer is NUL-terminated. Titles are UTF-8 and may be empty. A non-null
  // buffer must point to at least capacity writable chars; nullptr queries size.
  size_t (* _Nonnull tab_copy_title)(int32_t window, int32_t tab, char* buffer,
                                     size_t capacity);
  // Bounded nearest-first snapshot (at most100 entries); excludes current entry.
  // direction is a BarcHistoryDirection. UTF-8 JSON [{id,title,url}], required
  // bytes include NUL. No write if capacity is insufficient. Stable IDs resolve
  // live at dispatch; intervening navigation is allowed, but pruned IDs/changed
  // owners refuse.
  size_t (* _Nonnull tab_copy_history)(int32_t window, int32_t tab,
                                       int32_t direction, char* output,
                                       size_t capacity);
  int (* _Nonnull tab_go_to_history_entry)(int32_t window, int32_t tab,
                                           int32_t entry);
  int (* _Nonnull tab_go_back)(int32_t window, int32_t tab);
  int (* _Nonnull tab_go_forward)(int32_t window, int32_t tab);
  int (* _Nonnull tab_reload)(int32_t window, int32_t tab);
  int (* _Nonnull tab_stop)(int32_t window, int32_t tab);
  // action is a BarcMediaAction. Exact attached page, including background
  // tabs; never selects/focuses. Return advertised action dispatch acceptance,
  // never optimistic playback completion.
  int (* _Nonnull tab_media_action)(int32_t window, int32_t tab, int32_t action);

  // -- Tab observation. See BarcTabEvent.
  uint64_t (* _Nonnull tab_observe)(int32_t window, int32_t tab,
                                    BarcTabCallback callback, void* context);
  void (* _Nonnull tab_unobserve)(uint64_t observation);
  // Closes the observed tab as tab_close does. If it is still the active tab
  // when it actually closes, `successor`, a tab of the same client, becomes
  // active instead of Chromium's neighbour: before the close for a page without
  // beforeunload or unload handlers, else once its beforeunload lets the close go
  // ahead. A cancelled close forgets the successor. 0 for an unknown observation.
  int (* _Nonnull tab_close_selecting)(uint64_t observation, int32_t successor);
  // Consumer capability, initially disabled. Only an actual PageSession/model
  // binding enables the explicit menu; utility-only observers leave it disabled.
  // Independent of intrinsic Peek role: promotion can clear that role without
  // rebinding. Disable/unobserve cancels the outstanding document intent.
  // `enabled` is a BARC_TAB_PEEK_* mask.
  int (* _Nonnull tab_enable_peek)(uint64_t observation, int enabled);
  // One media sink on an existing page observation; all strings are borrowed
  // through the callback only (each bounded to 1024 UTF-16 code units).
  // Unobserve cancels it. Like page observation, registration may occur inside
  // another observer callback. Transport actions still refuse during bridge
  // callbacks.
  int (* _Nonnull tab_observe_media)(uint64_t observation,
                                     BarcMediaCallback callback);
  // Bounded PNG capture of an already-presented tab. One in flight per existing
  // observation. Bytes are borrowed during callback; nullptr/0 means failure.
  // Context is the observation's existing context. Unobserve/terminal teardown
  // cancels publication. Acceptance never loads, selects, shows or wakes a page.
  int (* _Nonnull tab_capture_thumbnail)(uint64_t observation, uint64_t request,
                                         BarcTabThumbnailCallback callback);
  // JPEG of the last rendered viewport, including a hidden retained surface.
  // No renderer show/wake/painting request. max_width: 1..4096 pixels; output
  // dimensions <=4096, <=8 Mi pixels, encoded <=8 MiB. Shares thumbnail slot.
  // Accepted delivery uses the existing observation context; stale/unavailable
  // results deliver zero bytes. Explicit cancel suppresses delivery; the shared
  // slot stays busy until the underlying compositor/encoder work retires.
  int (* _Nonnull tab_capture_screenshot)(uint64_t observation, uint64_t request,
                                          int32_t max_width,
                                          BarcTabThumbnailCallback callback);
  int (* _Nonnull tab_cancel_capture)(uint64_t observation, uint64_t request);
  // Existing authorized DevMCP download job only. Exact observed document/profile;
  // HTTPS GET, real partition cookies, no save-cookie/login prompts. Up to six
  // requests per observation; streams <=100MiB to an owned same-directory temp.
  // directory must be absolute, existing and canonical. Success transfers the
  // unique temp path plus an owned parent directory descriptor to the caller.
  // Caller revalidates identity and exclusively renames, or unlinks the basename
  // through that descriptor, then closes it. Never cleans an old absolute path.
  // Accepted callback once while observation lives; terminal teardown/unobserve
  // cancels publication. Explicit request cancellation reports CANCELLED.
  int (* _Nonnull tab_download_file)(uint64_t observation, uint64_t request,
                                     const char* url, const char* directory,
                                     BarcFileCallback callback);
  int (* _Nonnull tab_cancel_file)(uint64_t observation, uint64_t request);
  // Exact current-document site data commands; action is a BarcSiteDataAction.
  // Return dispatch acceptance; the callback reports deletion
  // completion/cancellation/failure on the UI thread. COOKIES_AND_RELOAD waits
  // for deletion, then reports reload dispatch acceptance. Cookie scope is
  // host/.host and current top-level partition keys; CACHE never deletes
  // cookies/DOM storage or globally flushes renderer memory resources.
  // Unobserve/terminal teardown cancels publication.
  int (* _Nonnull tab_clear_site_data)(uint64_t observation, uint64_t request,
                                       int32_t action,
                                       BarcSiteDataCallback callback);
  // Style application is scoped to an existing observation's exact top document.
  // Request IDs increase per observation; new requests supersede confirmation of
  // old ones. Result is a BarcStyleResult. Empty CSS removes the sheet.
  int (* _Nonnull tab_set_user_css)(uint64_t observation, uint64_t request,
                                    const char* committed_url, const char* css,
                                    BarcStyleCallback callback);
  // operation is a BarcTranslateOperation; pairs contains only [{id,text}].
  // Accepted calls complete once unless observation/runtime ends; a new
  // generation must begin with SAMPLE.
  int (* _Nonnull tab_translate)(uint64_t observation, uint64_t generation,
                                 uint64_t request, int32_t operation,
                                 const char* pairs,
                                 BarcTranslationCallback callback);
  // Exact existing HTTP(S) top document. No activation, navigation or cold
  // creation. mode is a BarcScriptMode, world a BarcScriptWorld. Return 0
  // refuses without callback. Accepted requests settle once; cancellation does
  // not undo JavaScript effects.
  int (* _Nonnull tab_evaluate_script)(uint64_t observation, uint64_t request,
                                       int32_t mode, int32_t world,
                                       const char* source,
                                       BarcScriptCallback callback);
  int (* _Nonnull tab_cancel_script)(uint64_t observation, uint64_t request);
  // Fixed document-bound element picker. Current visible HTTP(S) top document
  // only; no navigation or arbitrary code. Accepted start replies once;
  // selector is borrowed UTF-8 <=2048 bytes, empty on cancellation or
  // unavailability. Cancelling retires DOM handlers as well as the reply.
  // Requests increase per observation.
  int (* _Nonnull tab_start_boost_picker)(uint64_t observation, uint64_t request,
                                          BarcPickerCallback callback);
  int (* _Nonnull tab_cancel_boost_picker)(uint64_t observation,
                                           uint64_t request);

  // -- Vault. kind is a BarcVaultFieldKind.
  int (* _Nonnull tab_observe_vault)(uint64_t observation,
                                     BarcVaultCallback callback);
  int (* _Nonnull tab_vault_focus_is_current)(uint64_t observation,
                                              uint64_t focus);
  // Document/field identity only, for validating the application's own picker.
  // Never authorizes a secret fill; fill still requires actual native focus.
  int (* _Nonnull tab_vault_field_is_current)(uint64_t observation,
                                              uint64_t focus);
  int (* _Nonnull tab_cancel_vault_focus)(uint64_t observation, uint64_t focus);
  // Consumes exact focused-field capability; returns admission, not a renderer
  // acknowledgement.
  int (* _Nonnull tab_fill_vault)(uint64_t observation, uint64_t focus,
                                  const char* username, const char* secret);
  int (* _Nonnull tab_observe_vault_save)(uint64_t observation,
                                          BarcVaultSaveCallback callback);
  int (* _Nonnull tab_vault_save_is_current)(uint64_t observation,
                                             uint64_t submission);
  int (* _Nonnull tab_cancel_vault_save)(uint64_t observation,
                                         uint64_t submission);
  int (* _Nonnull tab_observe_vault_passkeys)(uint64_t observation,
                                              BarcVaultPasskeyCallback callback);
  int (* _Nonnull tab_vault_passkey_is_current)(uint64_t observation,
                                                uint64_t request);
  // Consumes the exact outstanding request. accepted=0 is refusal/cancellation.
  // Replies are validated and passed through Chromium's ordinary CTAP response
  // checks.
  int (* _Nonnull tab_complete_vault_passkey)(uint64_t observation,
                                              uint64_t request, int32_t accepted,
                                              const char* result);

  // -- Peek.
  // Consume one explicit document-bound link-menu intent. Creates an untouched
  // blank in a hidden same-Widget exact-profile logical peer, then calls admission
  // synchronously before its single target navigation. Admission only binds the
  // existing page/slot; select/present must wait until this call returns. Refusal
  // closes only that untouched owned blank. No caller URL or profile fallback.
  // Return 0 may follow admission 1: retain that bound page until
  // terminal/adoption. Refusal closes only a still-owned initial blank without
  // pending navigation; newer moved/navigated contents survive with the old Peek
  // role cleared.
  int (* _Nonnull tab_create_peek)(uint64_t source_observation, int32_t request,
                                   BarcTransferAdmission admission,
                                   void* context);
  // Native card over the unchanged base layout. Same exact Profile/OTR + physical
  // group only. Selection and expected-sidebar relocation are admitted here;
  // callers must NOT preselect the peer (which would clear the base split).
  // Both NSViews are borrowed for this call and retained by native hosts while
  // mounted. Header32px; actions28x96px, gap8px; card82% web width (clamped to fit),
  // top/bottom8px. The native page lies below header; no transparent input overlay.
  // No navigation/new page/NSWindow, physical activation or global focus occurs.
  // Nonzero is this actual mount generation; repeat requires exact same views.
  uint64_t (* _Nonnull tab_present_peek)(int32_t source_window,
                                         int32_t source_tab, int32_t peek_window,
                                         int32_t peek_tab, void* expected_sidebar,
                                         void* header, void* actions);
  // Exact mounted-view identity guards stale controls. Hide returns containers,
  // parks/pauses the Peek and releases its two control hosts, never closes it.
  // Pure is_presented has the same identity check without mutations/callbacks.
  int (* _Nonnull tab_hide_peek)(int32_t source_window, int32_t source_tab,
                                 int32_t peek_window, int32_t peek_tab,
                                 uint64_t generation, void* expected_header,
                                 void* expected_actions);
  int (* _Nonnull tab_is_peek_presented)(int32_t source_window,
                                         int32_t source_tab, int32_t peek_window,
                                         int32_t peek_tab, uint64_t generation,
                                         void* expected_header,
                                         void* expected_actions);

  // -- Splits. See BarcSplitLayout.
  int (* _Nonnull window_set_split)(int32_t window, const BarcSplitLayout* layout);
  int (* _Nonnull window_get_split)(int32_t window, int32_t member,
                                    BarcSplitLayout* layout);
  int (* _Nonnull window_clear_split)(int32_t window, int32_t member,
                                      const BarcSplitLayout* expected);

  // -- Downloads. One browser-UI subscription to loaded Barc profiles' existing
  // download managers. Strings/snapshot are borrowed only during callbacks,
  // delivered in posted non-nestable UI tasks. Initial/history items may repeat;
  // identity is actual profile/session UUID + private flag + GUID. manager is a
  // process-local source lifetime token, not a Profile pointer. Unknown profiles
  // are excluded.
  uint64_t (* _Nonnull downloads_observe)(BarcDownloadCallback callback,
                                          void* context);
  void (* _Nonnull downloads_unobserve)(uint64_t observation);
  // Resolve GUID only in the exact still-live subscribed manager. CANCEL accepts
  // in-progress items; REMOVE accepts terminal history items and never trashes a
  // file. Returns dispatch/queue acceptance; events confirm state/removal.
  int (* _Nonnull download_action)(uint64_t observation, uint64_t manager,
                                   const char* guid, int32_t action);
  // Pure current safe-complete target, required bytes including NUL; 0 means
  // unavailable/stale/unsafe. Same short-buffer contract as tab_copy_title.
  size_t (* _Nonnull download_copy_safe_target)(uint64_t observation,
                                                uint64_t manager,
                                                const char* guid, char* buffer,
                                                size_t capacity);

  // -- Discovery.
  // Pure live enumeration; no callbacks, selection, focus, navigation or showing.
  // out_snapshot is required. Null arrays with zero capacity query needed counts.
  // Rows are spaced by the size the caller set in the first row of each array.
  // Insufficient capacity writes counts/revision only, never partial array rows.
  // Run both calls on UI without yielding; retry capacity only if caller yielded.
  // Returns a BarcDiscoveryReadStatus.
  int32_t (* _Nonnull discovery_snapshot)(BarcDiscoveryWindow* windows,
                                          size_t window_capacity,
                                          BarcDiscoveryTab* tabs,
                                          size_t tab_capacity,
                                          BarcDiscoverySnapshot* out_snapshot);
  // One observer; duplicate registration returns0. Initial and later invalidations
  // are coalesced posted NON-nestable tasks, never inline mutation callbacks.
  // Revision changes cover ownership/membership, logical/active-tab selection,
  // physical active/visible and admission state; not title/loading/progress.
  // Callback is invalidation only: read a fresh snapshot. It may unobserve/close.
  // Unobserve clears borrowed context and cancels every pending delivery; caller
  // keeps context alive until unobserve (which is safe from inside its callback).
  uint64_t (* _Nonnull discovery_observe)(BarcDiscoveryCallback callback,
                                          void* context);
  void (* _Nonnull discovery_unobserve)(uint64_t observation);
  // Pure single-window row lookup using the same authoritative row builder as
  // snapshot, without enumerating/copying the catalog or invoking callbacks.
  // out_window is required; returns 0 if unavailable. No selection/focus/show.
  int (* _Nonnull window_discovery_state)(int32_t window,
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
  int (* _Nonnull window_admit_discovered)(int32_t window,
                                           void* expected_native_view);

  // -- Content blocking.
  // Browser main thread. Register UNRESOLVED before ChromeMain; only the initial
  // policy may be unresolved (domains must be null/count zero). This registration
  // does not create stores, contexts or workers. Its required generation is zero.
  // Publish the real saved policy at the existing runtime-ready point. Unknown
  // intercepts eligible website traffic; explicit disabled releases it without
  // requiring rule bytes. Other calls run on the initialized browser UI thread.
  // Stock/nonregistered Chrome is untouched.
  // Enabled policy requires a nonzero source token allocated by the existing
  // manager build authority before producer work; disabled uses zero and releases
  // requests/preparations independently of any build or validation. Domains and
  // this requirement publish atomically. Settings never cancel/reparse rules.
  // A token denotes one immutable source result, and is process-monotonic across
  // producer recreation. Ordinary no-op update checks retain the accepted token.
  // If a new intent was already announced, no-op success republishes retained
  // bytes under that token; failed production publishes the failure marker below.
  int (* _Nonnull blocker_set_policy)(int32_t policy,
                                      uint64_t required_source_generation,
                                      const char* const* allowed_domains,
                                      size_t count);
  // Global authoritative source publication. Return 0 rejects synchronously with
  // no callback. Return 1 borrows stable immutable bytes until the callback runs
  // exactly once on the browser UI thread, including shutdown/supersession. A
  // worker copies bytes once to native-owned shared storage and validates them
  // before acceptance; no context parser retains caller memory. Invalid or
  // superseded input preserves accepted rules. Native revision is assigned on
  // arrival, independently of the source token. source_generation is the same
  // process-monotonic token required by the atomic policy, never a
  // producer-local counter. READY acknowledges this source, not all context
  // parsers. A stale token cannot displace a newer required source.
  // bytes=null/length=0 declares producer failure for that token (UI INVALID_RULES
  // completion); it preserves accepted bytes but fails an exact unmet requirement
  // rather than stranding preparation. It never qualifies older rules as the
  // failed generation. No-op success must publish real retained bytes, not null.
  int (* _Nonnull blocker_publish_rules)(const uint8_t* bytes, size_t length,
                                         uint64_t source_generation,
                                         BarcBlockerCallback callback,
                                         void* context);
  // Captures the exact Profile/OTR of this live logical window synchronously.
  // Return 1 owns one UI completion, even if the window/context ends; no retarget.
  // READY acknowledges current native revision (zero is valid when disabled).
  // Unknown waits for the initial real setting; enabled waits for exactly its
  // required source generation and accepted rules and this context's own
  // parser. Newer rules may complete SUPERSEDED. Peer calls join existing
  // preparation, never duplicate parsing. Policy changes do not cancel a rule
  // parse or turn blocking on after a later disable.
  int (* _Nonnull blocker_prepare)(int32_t window, BarcBlockerCallback callback,
                                   void* context);
  // Pure existing-service query; never creates a context. Zeroes every field
  // after size and returns 0 on unavailable/invalid. Readiness belongs to actual
  // context_id and acknowledged required source/publication, never regular UUID
  // or another OTR context. An enabled ready result has source_generation equal
  // to the current required_source_generation and installed_revision ==
  // publication_revision.
  int (* _Nonnull blocker_state)(int32_t window, BarcBlockerState* out_state);
  // Exact live tab/context policy, copied before return. continued_host is the
  // approved destination and is retained before its first load; clear on a later
  // top-level attempt to a different host. Duration is relative monotonic time.
  // Successful publication, including unchanged policy, posts the existing
  // coalesced/non-nestable pending-application drain after the caller returns.
  int (* _Nonnull blocker_set_tab_policy)(int32_t window, int32_t tab,
                                          int32_t oauth,
                                          const char* continued_host,
                                          uint64_t disabled_for_ms);
  // After Barc registration. Fixed version 1 preference JSON, <=16MiB, copied
  // synchronously, 200 opt-in scripts maximum, <=64KiB each. Null/zero revokes
  // all configuration. Invalid input also revokes before returning 0, so failed
  // removal cannot retain stale script permission. No executable callbacks or
  // per-document IDs. Material changes take effect on the next load and retire
  // only affected cached documents/pending script continuations. Unchanged
  // publications are no-ops.
  int (* _Nonnull page_tweaks_publish)(const uint8_t* json, size_t length);

  // -- Window host (version 11). Each returns 0 or null for a window that is
  // not a Bark window host.
  // Gives the window the app's root view, which fills its content area. Set
  // once per physical window: the same view again returns 1, another view 0.
  // The engine retains the view until the window closes.
  int (* _Nonnull window_set_root_view)(int32_t window, void* root_view);
  // The tab's page view, an NSView the app places in its root view. Borrowed:
  // valid until the window's observers get PAGE_VIEW_RETIRED for this tab.
  // Placing it in the window shows the page; removing it hides it. Its frame is
  // the page's size.
  void* (* _Nonnull tab_native_view)(int32_t window, int32_t tab);
  // Not available until the window frame lands: returns 0 for every window.
  int (* _Nonnull window_set_chrome)(int32_t window,
                                     const BarcWindowChrome* chrome);
  // Observes the physical window `window` belongs to, for every client in it.
  // Returns a nonzero token; events keep arriving after the window closes
  // until unobserve, so the last PAGE_VIEW_RETIRED events reach the app.
  uint64_t (* _Nonnull window_host_observe)(int32_t window,
                                            BarcWindowHostCallback callback,
                                            void* context);
  // Stops delivery, including events already posted. Unknown tokens are ignored.
  void (* _Nonnull window_host_unobserve)(uint64_t observation);

  // Explicit space selection in a shared physical window (version 12). Returns zero
  // without a callback for invalid ABI input. Otherwise calls back exactly once
  // with the final owner and actual active tab, even when selection is refused.
  // Nested requests complete when the enclosing selection unwinds. The result
  // and its prompt records are immutable borrowed data during the callback.
  int (* _Nonnull window_switch_space)(const BarcSpaceSwitchRequest* request,
                                         BarcSpaceSwitchCallback callback,
                                         void* context);
};

#ifdef __cplusplus
}
#endif
#pragma clang diagnostic pop
#endif
