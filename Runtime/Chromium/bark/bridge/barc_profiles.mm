#include "bark/bridge/barc_profiles.h"
#include "bark/bridge/barc_bridge.h"
#include "bark/browser/ui/bark_window_factory.h"

#include <algorithm>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

#include "base/json/json_reader.h"
#include "base/hash/sha1.h"
#include "base/strings/string_number_conversions.h"
#include "components/search_engines/default_search_manager.h"
#include "base/json/json_writer.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "components/search_engines/template_url_service.h"
#include "components/search_engines/template_url_service_observer.h"
#include "components/search_engines/template_url.h"
#include "components/search_engines/template_url_data.h"
#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/bind_post_task.h"
#include "base/uuid.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/timer/timer.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "content/public/browser/storage_partition.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/base/isolation_info.h"
#include "net/cookies/site_for_cookies.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/origin.h"

#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/delete_profile_helper.h"
#include "chrome/browser/profiles/nuke_profile_directory_utils.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "components/sessions/core/session_id.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/base_window.h"
#include "url/gurl.h"

namespace {
constexpr char kPrefix[] = "Barc-";
void CancelLiveRequestsForProfilePath(const base::FilePath& path);
constexpr char kNilUUID[] = "00000000-0000-0000-0000-000000000000";

std::string CanonicalUUID(std::string_view value) {
  auto uuid = base::Uuid::ParseCaseInsensitive(value);
  return uuid.is_valid() && uuid.AsLowercaseString() != kNilUUID
             ? uuid.AsLowercaseString()
             : std::string();
}

const char* Destination(barc_profile_destination destination) {
  switch (destination) {
    case BARC_PROFILE_SETTINGS:
      return "chrome://settings/";
    case BARC_PROFILE_EXTENSIONS:
      return "chrome://extensions/";
    case BARC_PROFILE_PRIVACY:
      return "chrome://settings/privacy";
    case BARC_PROFILE_SITE_SETTINGS:
      return "chrome://settings/content";
    case BARC_PROFILE_CLEAR_DATA:
      return "chrome://settings/clearBrowserData";
    case BARC_PROFILE_BLANK:
      return "about:blank";
  }
  return nullptr;
}

ProfileManager* Manager() {
  return g_browser_process && !g_browser_process->IsShuttingDown()
             ? g_browser_process->profile_manager()
             : nullptr;
}

// Only request state, not a profile/browser registry. ProfileManager owns every
// Profile; normal CreateBrowserWindow owns every window. Destroying an unrun
// Chromium callback releases the keepalive. Cancellation is delivered only on
// UI, best effort if shutdown has stopped the UI task runner.
struct OpenRequest {
  OpenRequest(std::string uuid,
              const char* destination,
              barc_profile_window_callback callback,
              void* user_data,
              std::optional<base::WeakPtr<BrowserWindowInterface>>
                  native_owner = std::nullopt)
      : uuid(std::move(uuid)),
        destination(destination),
        callback(callback),
        user_data(user_data),
        native_owner(std::move(native_owner)),
        ui_runner(base::SingleThreadTaskRunner::GetCurrentDefault()) {}
  ~OpenRequest() {
    auto completion = std::exchange(callback, nullptr);
    void* data = user_data.get();
    user_data = nullptr;
    if (!completion)
      return;
    if (content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) {
      completion(BARC_PROFILE_CANCELLED, 0, data);
    } else {
      ui_runner->PostTask(
          FROM_HERE, base::BindOnce(
                         [](barc_profile_window_callback callback, void* data) {
                           if (content::BrowserThread::CurrentlyOn(
                                   content::BrowserThread::UI))
                             callback(BARC_PROFILE_CANCELLED, 0, data);
                         },
                         completion, data));
    }
  }

  void Complete(barc_profile_status status, int32_t window) {
    auto completion = std::exchange(callback, nullptr);
    void* data = user_data.get();
    user_data = nullptr;
    if (completion)
      completion(status, window, data);
  }

  bool private_session = false;
  bool show_after_creation = true;
  std::string uuid;
  const char* destination;
  barc_profile_window_callback callback;
  raw_ptr<void> user_data;
  std::optional<base::WeakPtr<BrowserWindowInterface>> native_owner;
  scoped_refptr<base::SingleThreadTaskRunner> ui_runner;
  base::FilePath path;
  std::unique_ptr<ScopedProfileKeepAlive> keep_alive;
};

bool CanJoinRegularWindow(BrowserWindowInterface* owner) {
  return bark::HostToJoin(owner) && !owner->GetProfile()->IsOffTheRecord();
}

void ProfileReady(std::unique_ptr<OpenRequest> request, Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* manager = Manager();
  if (!manager) {
    request->Complete(BARC_PROFILE_UNAVAILABLE, 0);
    return;
  }
  if (request->private_session) {
    if (!profile || !profile->IsGuestSession() ||
        !profile->IsPrimaryOTRProfile() ||
        !ProfileManager::IsPrivateSessionProfilePath(profile->GetPath()) ||
        manager->GetProfileByPath(profile->GetPath()) !=
            profile->GetOriginalProfile() ||
        profile->GetOriginalProfile()->GetPrimaryOTRProfile(false) != profile) {
      request->Complete(BARC_PROFILE_FAILED, 0);
      return;
    }
    request->path = profile->GetPath();
  } else if (IsProfileDirectoryPendingDeletion(request->path) ||
             !profile || !profile->IsRegularProfile() ||
             profile->GetPath() != request->path ||
             manager->GetProfileByPath(request->path) != profile) {
    request->Complete(BARC_PROFILE_FAILED, 0);
    return;
  }
  request->keep_alive = ScopedProfileKeepAlive::TryAcquire(
      request->private_session ? profile->GetOriginalProfile() : profile,
      ProfileKeepAliveOrigin::kProfileCreationFlow);
  if (!request->keep_alive ||
      GetBrowserWindowCreationStatusForProfile(*profile) !=
          BrowserWindowInterface::CreationStatus::kOk) {
    request->Complete(BARC_PROFILE_UNAVAILABLE, 0);
    return;
  }

  // This runs inside the queued async request, after async profile readiness.
  // Use the normal synchronous desktop factory here so no raw window pointer
  // crosses another task boundary. The native browser owns its own keepalive.
  BrowserWindowCreateParams params(*profile, true);
  base::WeakPtr<BrowserWindowInterface> owner_alive;
  auto selected_owner = [&]() -> base::WeakPtr<BrowserWindowInterface> {
    if (!owner_alive || owner_alive->IsDeleteScheduled() ||
        !owner_alive->GetWindow()) {
      return {};
    }
    auto* collection = GlobalBrowserCollection::GetInstance();
    auto* selected = collection
                         ? collection->FindBrowserWithWindow(
                               owner_alive->GetWindow()->GetNativeWindow())
                         : nullptr;
    return selected ? selected->GetWeakPtr()
                    : base::WeakPtr<BrowserWindowInterface>();
  };
  if (request->native_owner) {
    owner_alive = *request->native_owner;
    if (!CanJoinRegularWindow(owner_alive.get())) {
      request->Complete(BARC_PROFILE_UNAVAILABLE, 0);
      return;
    }
    params.native_window_owner = owner_alive->GetSessionID();
  }
  const auto selection_before = selected_owner();
  BrowserWindowInterface* created = nullptr;
  {
    std::optional<bark::ScopedAppWindowCreation> app_window;
    if (!request->private_session && !params.native_window_owner)
      app_window.emplace();
    created = CreateBrowserWindow(std::move(params));
  }
  if (!created) {
    request->Complete(BARC_PROFILE_UNAVAILABLE, 0);
    return;
  }
  auto window_alive = created->GetWeakPtr();
  auto valid_context = [&] {
    if (!Manager() || !window_alive || window_alive->IsDeleteScheduled() ||
        window_alive->GetProfile() != profile || !window_alive->GetWindow()) {
      return false;
    }
    if (!request->native_owner) {
      return true;
    }
    return owner_alive && !owner_alive->IsDeleteScheduled() &&
           owner_alive->GetWindow() &&
           owner_alive->GetWindow()->GetNativeWindow() &&
           owner_alive->GetWindow()->GetNativeWindow() ==
               window_alive->GetWindow()->GetNativeWindow();
  };
  auto cancel_creation = [&](barc_profile_status status) {
    // Close only an unused browser created by this request. Nested user-created
    // tabs must not be destroyed as a side effect of reporting cancellation.
    if (window_alive && !window_alive->IsDeleteScheduled() &&
        window_alive->GetProfile() == profile && window_alive->GetWindow() &&
        window_alive->GetTabStripModel()->empty()) {
      window_alive->GetWindow()->Close();
    }
    request->Complete(status, 0);
  };
  if (!valid_context()) {
    cancel_creation(BARC_PROFILE_UNAVAILABLE);
    return;
  }
  auto* returned = chrome::AddAndReturnTabAt(
      window_alive.get(), GURL(request->destination), -1, true);
  // Insertion observers may close the browser or move/delete the returned raw
  // contents. Resolve pointer identity in the surviving real tab strip first.
  if (!valid_context() || !returned) {
    cancel_creation(BARC_PROFILE_CANCELLED);
    return;
  }
  auto* strip = window_alive->GetTabStripModel();
  const int index = strip->GetIndexOfWebContents(returned);
  if (index == TabStripModel::kNoTab) {
    cancel_creation(BARC_PROFILE_CANCELLED);
    return;
  }
  static_cast<tabs::TabModel*>(strip->GetTabAtIndex(index))->set_barc_app_factory_origin();
  barc::BrowserDiscoveryChanged();
  auto contents_alive = strip->GetWebContentsAt(index)->GetWeakPtr();
  if (contents_alive->GetBrowserContext() != profile) {
    cancel_creation(BARC_PROFILE_FAILED);
    return;
  }
  auto current_selection = selected_owner();
  const bool nested_selection_wins =
      request->native_owner &&
      current_selection.get() != selection_before.get() &&
      current_selection.get() != window_alive.get();
  if (request->show_after_creation && !nested_selection_wins) {
    window_alive->GetWindow()->Show();
  }
  if (!valid_context() || !contents_alive ||
      contents_alive->GetBrowserContext() != profile ||
      window_alive->GetTabStripModel()->GetIndexOfWebContents(
          contents_alive.get()) == TabStripModel::kNoTab) {
    cancel_creation(BARC_PROFILE_CANCELLED);
    return;
  }
  // Creation may complete in the background when a nested user selection won.
  // No second Show/Activate is used to override that newer intent.
  request->Complete(BARC_PROFILE_OK, window_alive->GetSessionID().id());
}

void BeginPrivateSession(std::unique_ptr<OpenRequest> request) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* manager = Manager();
  if (!manager) {
    request->Complete(BARC_PROFILE_UNAVAILABLE, 0);
    return;
  }
  manager->CreatePrivateSessionAsync(
      base::BindOnce(&ProfileReady, std::move(request)));
}

void BeginOpen(std::unique_ptr<OpenRequest> request) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (request->uuid.empty() || !request->destination) {
    request->Complete(BARC_PROFILE_INVALID_ARGUMENT, 0);
    return;
  }
  if (request->native_owner) {
    auto owner = *request->native_owner;
    if (!CanJoinRegularWindow(owner.get())) {
      request->Complete(BARC_PROFILE_UNAVAILABLE, 0);
      return;
    }
  }
  auto* manager = Manager();
  if (!manager) {
    request->Complete(BARC_PROFILE_UNAVAILABLE, 0);
    return;
  }
  request->path = manager->user_data_dir().AppendASCII(kPrefix + request->uuid);
  const auto path = request->path;
  if (IsProfileDirectoryPendingDeletion(path)) {
    request->Complete(BARC_PROFILE_UNAVAILABLE, 0);
    return;
  }
  manager->CreateProfileAsync(
      path, base::BindOnce(&ProfileReady, std::move(request)));
}
}  // namespace

void barc_profile_open_window(const char* profile_uuid,
                              barc_profile_destination destination,
                              barc_profile_window_callback callback,
                              void* user_data) {
  CHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback)
    return;
  auto request = std::make_unique<OpenRequest>(
      CanonicalUUID(profile_uuid ? profile_uuid : ""), Destination(destination),
      callback, user_data);
  request->show_after_creation = destination != BARC_PROFILE_BLANK;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&BeginOpen, std::move(request)));
}

void barc_profile_open_in_native_window(int32_t native_owner,
                                        const char* profile_uuid,
                                        barc_profile_destination destination,
                                        barc_profile_window_callback callback,
                                        void* user_data) {
  CHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) {
    return;
  }
  auto* collection = GlobalBrowserCollection::GetInstance();
  auto* owner = collection && native_owner > 0
                    ? collection->FindBrowserWithID(
                          SessionID::FromSerializedValue(native_owner))
                    : nullptr;
  auto request = std::make_unique<OpenRequest>(
      CanonicalUUID(profile_uuid ? profile_uuid : ""), Destination(destination),
      callback, user_data,
      std::optional(owner ? owner->GetWeakPtr()
                          : base::WeakPtr<BrowserWindowInterface>()));
  request->show_after_creation = destination != BARC_PROFILE_BLANK;
  // Validate again after asynchronous profile readiness; only the native weak
  // identity is retained across that boundary, never an unchecked host pointer.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&BeginOpen, std::move(request)));
}

void barc_private_session_open_window(barc_profile_window_callback callback,
                                      void* user_data) {
  CHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) {
    return;
  }
  auto request = std::make_unique<OpenRequest>(
      std::string(), "about:blank", callback, user_data);
  request->private_session = true;
  request->show_after_creation = false;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&BeginPrivateSession, std::move(request)));
}

size_t barc_window_profile_uuid(int32_t id, char* buffer, size_t capacity) {
  base::span<char> output;
  if (buffer && capacity) {
    // SAFETY: This C ABI requires the caller to supply a writable allocation
    // containing at least capacity chars. Only the conversion trusts that
    // contract; all subsequent writes are bounded span operations.
    output = UNSAFE_BUFFERS(base::span<char>(buffer, capacity));
    output[0] = '\0';
  }
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      id <= 0)
    return 0;
  auto* manager = Manager();
  if (!manager)
    return 0;
  auto* collection = GlobalBrowserCollection::GetInstance();
  if (!collection)
    return 0;
  auto* window =
      collection->FindBrowserWithID(SessionID::FromSerializedValue(id));
  if (!window || window->IsDeleteScheduled())
    return 0;
  auto* profile = window->GetProfile();
  if (!profile->IsRegularProfile() ||
      profile->GetPath().DirName() != manager->user_data_dir() ||
      manager->GetProfileByPath(profile->GetPath()) != profile)
    return 0;
  const auto basename = profile->GetPath().BaseName().AsUTF8Unsafe();
  if (!basename.starts_with(kPrefix))
    return 0;
  const auto uuid = CanonicalUUID(
      std::string_view(basename).substr(std::string_view(kPrefix).size()));
  if (uuid.empty() || basename != kPrefix + uuid)
    return 0;
  if (buffer && capacity) {
    const size_t count = std::min(capacity - 1, uuid.size());
    output.first(count).copy_from(base::span(uuid).first(count));
    output[count] = '\0';
  }
  return uuid.size() + 1;
}

size_t barc_window_private_session_uuid(int32_t id,
                                        char* buffer,
                                        size_t capacity) {
  base::span<char> output;
  if (buffer && capacity) {
    // SAFETY: The C caller supplies capacity writable bytes.
    output = UNSAFE_BUFFERS(base::span<char>(buffer, capacity));
    output[0] = '\0';
  }
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) ||
      id <= 0) {
    return 0;
  }
  auto* manager = Manager();
  auto* collection = GlobalBrowserCollection::GetInstance();
  auto* window =
      manager && collection
          ? collection->FindBrowserWithID(SessionID::FromSerializedValue(id))
          : nullptr;
  if (!window || window->IsDeleteScheduled()) {
    return 0;
  }
  auto* profile = window->GetProfile();
  auto* parent = profile->GetOriginalProfile();
  if (!profile->IsGuestSession() || !profile->IsPrimaryOTRProfile() ||
      !ProfileManager::IsPrivateSessionProfilePath(parent->GetPath()) ||
      manager->GetProfileByPath(parent->GetPath()) != parent ||
      parent->GetPrimaryOTRProfile(/*create_if_needed=*/false) != profile) {
    return 0;
  }
  constexpr std::string_view prefix = "BarcPrivate-";
  const auto basename = parent->GetPath().BaseName().AsUTF8Unsafe();
  const auto uuid =
      CanonicalUUID(std::string_view(basename).substr(prefix.size()));
  if (uuid.empty() || basename != std::string(prefix) + uuid) {
    return 0;
  }
  if (!output.empty()) {
    const size_t count = std::min(output.size() - 1, uuid.size());
    output.first(count).copy_from(base::span(uuid).first(count));
    output[count] = '\0';
  }
  return uuid.size() + 1;
}

namespace barc {
void WithRegularProfileForApplication(
    std::string uuid,
    base::OnceCallback<void(Profile*)> callback) {
  CHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* manager = Manager();
  if (!manager || CanonicalUUID(uuid) != uuid || uuid.empty()) {
    std::move(callback).Run(nullptr);
    return;
  }
  const auto path = manager->user_data_dir().AppendASCII(kPrefix + uuid);
  if (IsProfileDirectoryPendingDeletion(path)) {
    std::move(callback).Run(nullptr);
    return;
  }
  manager->CreateProfileAsync(
      path,
      base::BindOnce(
          [](base::FilePath path, base::OnceCallback<void(Profile*)> callback,
             Profile* profile) {
            auto* manager = Manager();
            if (!manager || IsProfileDirectoryPendingDeletion(path) ||
                !profile || !profile->IsRegularProfile() ||
                profile->GetPath() != path ||
                manager->GetProfileByPath(path) != profile) {
              std::move(callback).Run(nullptr);
              return;
            }
            auto keep_alive = ScopedProfileKeepAlive::TryAcquire(
                profile, ProfileKeepAliveOrigin::kProfileCreationFlow);
            if (!keep_alive) {
              std::move(callback).Run(nullptr);
              return;
            }
            auto alive = profile->GetWeakPtr();
            std::move(callback).Run(profile);
            // A changed model can defer/refuse after loading. Do not clear the
            // initial reference inside ProfileManager's RunCallbacks loop:
            // another callback from that same initialization still borrows this
            // Profile.
            base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
                FROM_HERE,
                base::BindOnce(
                    [](base::WeakPtr<Profile> alive, base::FilePath path) {
                      auto* manager = Manager();
                      if (manager && alive &&
                          manager->GetProfileByPath(path) == alive.get()) {
                        manager->ClearFirstBrowserWindowKeepAlive(alive.get());
                      }
                    },
                    alive, path));
          },
          path, std::move(callback)));
}
}  // namespace barc

namespace {
void CompleteProfileDeletion(barc_profile_delete_callback callback, void* data,
                             DeleteProfileHelper::ExplicitDeletionResult result) {
  switch (result) {
    case DeleteProfileHelper::ExplicitDeletionResult::kDeleted:
      callback(BARC_PROFILE_DELETED, data); break;
    case DeleteProfileHelper::ExplicitDeletionResult::kCancelled:
      callback(BARC_PROFILE_DELETE_CANCELLED, data); break;
    case DeleteProfileHelper::ExplicitDeletionResult::kPending:
      callback(BARC_PROFILE_DELETE_PENDING, data); break;
    case DeleteProfileHelper::ExplicitDeletionResult::kCloseAdmitted:
      callback(BARC_PROFILE_CLOSE_ADMITTED, data); break;
  }
}
void BeginProfileDeletion(const char* target_uuid, const char* survivor_uuid,
                          int32_t reconcile_only, bool defer_wipe,
                          barc_profile_delete_callback callback, void* user_data) {
  CHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) { return; }
  const auto target = target_uuid ? CanonicalUUID(target_uuid) : std::string();
  const auto survivor = survivor_uuid ? CanonicalUUID(survivor_uuid) : std::string();
  if (target.empty() || survivor.empty() || target == survivor ||
      (reconcile_only != 0 && reconcile_only != 1)) {
    callback(BARC_PROFILE_DELETE_CANCELLED, user_data);
    return;
  }
  auto* manager = Manager();
  if (!manager) { callback(BARC_PROFILE_DELETE_PENDING, user_data); return; }
  const auto target_path = manager->user_data_dir().AppendASCII(kPrefix + target);
  const auto survivor_path = manager->user_data_dir().AppendASCII(kPrefix + survivor);
  manager->GetDeleteProfileHelper().DeleteProfileWithExplicitSurvivor(
      target_path, survivor_path, reconcile_only != 0,
      base::BindPostTaskToCurrentDefault(base::BindOnce(
          &CompleteProfileDeletion, callback, user_data)), defer_wipe);
  if (IsProfileDirectoryPendingDeletion(target_path)) {
    CancelLiveRequestsForProfilePath(target_path);
    barc::CancelDocumentDownloadsForProfilePath(target_path);
  }
}
}  // namespace

extern "C" void barc_profile_delete_kept(
    const char* target_uuid, const char* survivor_uuid, int32_t reconcile_only,
    barc_profile_delete_callback callback, void* user_data) {
  BeginProfileDeletion(target_uuid, survivor_uuid, reconcile_only, false,
                       callback, user_data);
}
extern "C" void barc_profile_prepare_reassignment(
    const char* target_uuid, const char* survivor_uuid, int32_t reconcile_only,
    barc_profile_delete_callback callback, void* user_data) {
  BeginProfileDeletion(target_uuid, survivor_uuid, reconcile_only, true,
                       callback, user_data);
}
extern "C" void barc_profile_continue_deletion(
    const char* target_uuid, const char* survivor_uuid,
    barc_profile_delete_callback callback, void* user_data) {
  CHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) { return; }
  auto* manager = Manager();
  const auto target = target_uuid ? CanonicalUUID(target_uuid) : std::string();
  const auto survivor = survivor_uuid ? CanonicalUUID(survivor_uuid) : std::string();
  if (!manager || target.empty() || survivor.empty() || target == survivor) {
    callback(BARC_PROFILE_DELETE_PENDING, user_data); return;
  }
  manager->GetDeleteProfileHelper().ContinueExplicitDeletion(
      manager->user_data_dir().AppendASCII(kPrefix + target),
      manager->user_data_dir().AppendASCII(kPrefix + survivor),
      base::BindPostTaskToCurrentDefault(base::BindOnce(
          &CompleteProfileDeletion, callback, user_data)));
}

extern "C" int barc_profile_delete_cancel_ack(
    const char* target_uuid, const char* survivor_uuid) {
  CHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* manager = Manager();
  const auto target = target_uuid ? CanonicalUUID(target_uuid) : std::string();
  const auto survivor = survivor_uuid ? CanonicalUUID(survivor_uuid) : std::string();
  if (!manager || target.empty() || survivor.empty() || target == survivor) { return 0; }
  return manager->GetDeleteProfileHelper().AcknowledgeExplicitDeletionCancellation(
      manager->user_data_dir().AppendASCII(kPrefix + target),
      manager->user_data_dir().AppendASCII(kPrefix + survivor));
}

namespace {
constexpr size_t kLiveBodyLimit = 4 * 1024 * 1024;

class LiveRequest;
using LiveRequests = std::map<uint64_t, std::shared_ptr<LiveRequest>>;
LiveRequests& PendingLiveRequests() {
  static base::NoDestructor<LiveRequests> requests;
  return *requests;
}
struct LiveRoute { GURL url; bool github_json = false; bool html = false; bool json = false; };
std::optional<LiveRoute> ResolveLiveRoute(int32_t source, std::string_view argument) {
  const bool decimal = !argument.empty() && argument.size() <= 64 &&
      std::ranges::all_of(argument, [](char c) { return c >= '0' && c <= '9'; });
  switch (source) {
    case BARC_LIVE_GITHUB_PULLS:
      if (!argument.empty()) return std::nullopt;
      return LiveRoute{GURL("https://github.com/pulls?q=is%3Apr%20is%3Aopen%20(author%3A%40me%20OR%20review-requested%3A%40me)%20sort%3Aupdated-desc"), true};
    case BARC_LIVE_GITHUB_ISSUES:
      if (!argument.empty()) return std::nullopt;
      return LiveRoute{GURL("https://github.com/issues?q=is%3Aissue%20is%3Aopen%20assignee%3A%40me%20sort%3Aupdated-desc"), true};
    case BARC_LIVE_GITHUB_NOTIFICATIONS:
      if (!argument.empty()) return std::nullopt;
      return LiveRoute{GURL("https://github.com/notifications?query=is%3Aunread"), false, true};
    case BARC_LIVE_ASANA_WORKSPACES:
      if (!argument.empty()) return std::nullopt;
      return LiveRoute{GURL("https://app.asana.com/api/1.0/users/me?opt_fields=workspaces"), false, false, true};
    case BARC_LIVE_ASANA_TASKS:
      if (!decimal) return std::nullopt;
      return LiveRoute{GURL("https://app.asana.com/api/1.0/tasks?assignee=me&workspace=" +
          std::string(argument) + "&completed_since=now&opt_fields=name,permalink_url,due_on,completed"), false, false, true};
    case BARC_LIVE_GMAIL:
      if (!decimal) return std::nullopt;
      return LiveRoute{GURL("https://mail.google.com/mail/u/" + std::string(argument) + "/feed/atom")};
    default: return std::nullopt;
  }
}
class LiveRequest : public ProfileObserver, public ProfileManagerObserver,
                    public std::enable_shared_from_this<LiveRequest> {
 public:
  LiveRequest(uint64_t token, std::string uuid, base::FilePath path, LiveRoute route,
              barc_live_callback callback, void* context)
      : token_(token), uuid_(std::move(uuid)), path_(std::move(path)),
        route_(std::move(route)), callback_(callback), context_(context) {}
  const std::string& uuid() const { return uuid_; }
  void Start(ProfileManager* manager) {
    manager_observation_.Observe(manager);
    deadline_.Start(FROM_HERE, base::Seconds(20), base::BindOnce(
        [](std::weak_ptr<LiveRequest> weak) {
          if (auto request = weak.lock()) request->Finish(BARC_LIVE_TIMEOUT);
        }, weak_from_this()));
    barc::WithRegularProfileForApplication(uuid_, base::BindOnce(
        [](std::weak_ptr<LiveRequest> weak, Profile* profile) {
          if (auto request = weak.lock(); request && !request->done_)
            request->Resolved(profile);
        }, weak_from_this()));
  }
  void Finish(barc_live_result result, int status = 0, std::string body = {}) {
    if (done_) return;
    auto keep_alive = shared_from_this();
    done_ = true;
    auto callback = std::exchange(callback_, nullptr);
    void* context = context_.get();
    context_ = nullptr;
    // Revoke table/observer ownership before destructors or the Swift callout
    // can reenter and admit another request for this same profile.
    PendingLiveRequests().erase(token_);
    deadline_.Stop();
    profile_observation_.Reset();
    manager_observation_.Reset();
    loader_.reset();
    keep_alive_.reset();
    callback(context, token_, result, status,
             reinterpret_cast<const uint8_t*>(body.data()), body.size());
  }
  void OnProfileMarkedForPermanentDeletion(Profile* profile) override {
    if (profile->GetPath() == path_) Finish(BARC_LIVE_CANCELLED);
  }
  void OnProfileWillBeDestroyed(Profile*) override { Finish(BARC_LIVE_CANCELLED); }
  void OnProfileManagerDestroying() override { Finish(BARC_LIVE_CANCELLED); }
 private:
  bool Current() const {
    auto* manager = Manager();
    return !done_ && manager && profile_ && !profile_->ShutdownStarted() && !profile_->IsOffTheRecord() &&
        profile_->GetPath() == path_ && manager->GetProfileByPath(path_) == profile_.get() &&
        !IsProfileDirectoryPendingDeletion(path_);
  }
  void Resolved(Profile* profile) {
    auto self = shared_from_this();
    if (!profile || profile->ShutdownStarted() || !profile->IsRegularProfile() || profile->GetPath() != path_ ||
        IsProfileDirectoryPendingDeletion(path_)) { Finish(BARC_LIVE_CANCELLED); return; }
    profile_ = profile->GetWeakPtr();
    keep_alive_ = ScopedProfileKeepAlive::TryAcquire(profile, ProfileKeepAliveOrigin::kProfileCreationFlow);
    if (!keep_alive_ || !Current()) { Finish(BARC_LIVE_CANCELLED); return; }
    profile_observation_.Observe(profile);
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = route_.url;
    request->method = "GET";
    const auto origin = url::Origin::Create(route_.url);
    request->site_for_cookies = net::SiteForCookies::FromOrigin(origin);
    request->request_initiator = origin;
    request->trusted_params.emplace();
    request->trusted_params->isolation_info = net::IsolationInfo::CreateForInternalRequest(origin);
    request->credentials_mode = network::mojom::CredentialsMode::kInclude;
    request->redirect_mode = network::mojom::RedirectMode::kManual;
    request->do_not_prompt_for_login = true;
    // Match the existing read-only, cookie-free-storage URLSession behavior:
    // Chromium selects cookies; response Set-Cookie/cache never changes state.
    request->load_flags = net::LOAD_DO_NOT_SAVE_COOKIES | net::LOAD_DISABLE_CACHE;
    if (route_.github_json) {
      request->headers.SetHeader("Accept", "application/json");
      request->headers.SetHeader("X-Requested-With", "XMLHttpRequest");
      request->headers.SetHeader("GitHub-Verified-Fetch", "true");
    } else if (route_.html) request->headers.SetHeader("Accept", "text/html");
    else if (route_.json) request->headers.SetHeader("Accept", "application/json");
    static constexpr net::NetworkTrafficAnnotationTag annotation = net::DefineNetworkTrafficAnnotation(
        "barc_live_profile_get", R"(
          semantics {
            sender: "Nook live folders and Gmail favorites"
            description: "Reads a fixed user-selected GitHub, Asana or Gmail source in its owning regular profile."
            trigger: "Opening or refreshing a configured live folder or favorite."
            data: "Only Chromium-selected cookies for the fixed destination; no request body."
            destination: WEBSITE
          }
          policy {
            cookies_allowed: YES
            cookies_store: "The exact owning profile's default storage partition."
            setting: "Removing the live source stops future reads."
            policy_exception_justification: "User-configured browser feature using ordinary profile cookie policy."
          })");
    loader_ = network::SimpleURLLoader::Create(std::move(request), annotation);
    loader_->SetAllowHttpErrorResults(true);
    loader_->SetOnRedirectCallback(base::BindRepeating(
        [](std::weak_ptr<LiveRequest> weak, const GURL&, const net::RedirectInfo&,
           const network::mojom::URLResponseHead& response, std::vector<std::string>*) {
          if (auto request = weak.lock()) request->Finish(
              request->Current() ? BARC_LIVE_OK : BARC_LIVE_CANCELLED,
              response.headers ? response.headers->response_code() : 0);
        }, weak_from_this()));
    auto factory = profile->GetDefaultStoragePartition()->GetURLLoaderFactoryForBrowserProcess();
    if (!Current()) { Finish(BARC_LIVE_CANCELLED); return; }
    loader_->DownloadToString(factory.get(),
        base::BindOnce([](std::weak_ptr<LiveRequest> weak, std::optional<std::string> body) {
          auto request = weak.lock();
          if (!request || request->done_) return;
          if (!request->Current()) { request->Finish(BARC_LIVE_CANCELLED); return; }
          const auto* response = request->loader_->ResponseInfo();
          const int status = response && response->headers ? response->headers->response_code() : 0;
          const int error = request->loader_->NetError();
          // The loader reports the connection's error when it ends before the
          // body passes the limit, whatever size the response declared.
          const bool too_large = error == net::ERR_INSUFFICIENT_RESOURCES ||
              (response &&
               response->content_length > static_cast<int64_t>(kLiveBodyLimit));
          request->Finish(too_large ? BARC_LIVE_TOO_LARGE :
              (error == net::OK && body && status ? BARC_LIVE_OK : BARC_LIVE_FAILED),
              status, too_large || !body ? std::string() : std::move(*body));
        }, weak_from_this()), kLiveBodyLimit);
  }
  const uint64_t token_;
  const std::string uuid_;
  const base::FilePath path_;
  const LiveRoute route_;
  barc_live_callback callback_;
  raw_ptr<void> context_;
  bool done_ = false;
  base::WeakPtr<Profile> profile_;
  std::unique_ptr<ScopedProfileKeepAlive> keep_alive_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
  base::OneShotTimer deadline_;
  base::ScopedObservation<Profile, ProfileObserver> profile_observation_{this};
  base::ScopedObservation<ProfileManager, ProfileManagerObserver> manager_observation_{this};
};
void CancelLiveRequestsForProfilePath(const base::FilePath& path) {
  std::vector<std::shared_ptr<LiveRequest>> cancel;
  for (const auto& entry : PendingLiveRequests()) {
    if (Manager() && Manager()->user_data_dir().AppendASCII(kPrefix + entry.second->uuid()) == path)
      cancel.push_back(entry.second);
  }
  for (auto& request : cancel) request->Finish(BARC_LIVE_CANCELLED);
}
}  // namespace

uint64_t barc_profile_live_get(const char* uuid, int32_t source, const char* argument,
                               barc_live_callback callback, void* context) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI) || !uuid ||
      !argument || !callback || !Manager()) return 0;
  const auto canonical = CanonicalUUID(uuid);
  auto route = ResolveLiveRoute(source, argument);
  if (canonical.empty() || !route || PendingLiveRequests().size() >= 8) return 0;
  const auto private_path = Manager()->user_data_dir().AppendASCII("BarcPrivate-" + canonical);
  if (Manager()->IsProfileLoadedOrLoading(private_path) ||
      Manager()->IsProfilePendingDestruction(private_path)) return 0;
  if (std::ranges::count_if(PendingLiveRequests(), [&](const auto& entry) {
        return entry.second->uuid() == canonical;
      }) >= 2) return 0;
  const auto path = Manager()->user_data_dir().AppendASCII(kPrefix + canonical);
  if (IsProfileDirectoryPendingDeletion(path)) return 0;
  static uint64_t next = 0;
  CHECK_NE(next, UINT64_MAX);
  const uint64_t token = ++next;
  auto request = std::make_shared<LiveRequest>(token, canonical, path, std::move(*route), callback, context);
  PendingLiveRequests().emplace(token, request);
  request->Start(Manager());
  return token;
}
void barc_profile_live_cancel(uint64_t token) {
  if (!content::BrowserThread::CurrentlyOn(content::BrowserThread::UI)) return;
  auto found = PendingLiveRequests().find(token);
  if (found != PendingLiveRequests().end()) found->second->Finish(BARC_LIVE_CANCELLED);
}

namespace {
constexpr char kSearchImported[] = "barc.search_imported";
class BarcSearchRequest : public ProfileObserver,
                         public TemplateURLServiceObserver,
                         public std::enable_shared_from_this<BarcSearchRequest> {
 public:
  BarcSearchRequest(std::string uuid, int32_t window, bool is_private,
                   std::string seed, std::string selection, bool choices,
                   barc_search_callback callback, void* context)
      : uuid_(std::move(uuid)), seed_(std::move(seed)),
        selection_(std::move(selection)), window_(window), private_(is_private), choices_(choices),
        callback_(callback), context_(context) {}
  ~BarcSearchRequest() override {
    if (service_) service_->RemoveObserver(this);
    if (profile_) profile_->RemoveObserver(this);
  }
  void Begin(Profile* profile) {
    if (!profile || !Manager()) { Finish(1); return; }
    keep_alive_ = ScopedProfileKeepAlive::TryAcquire(
        profile->GetOriginalProfile(), ProfileKeepAliveOrigin::kProfileCreationFlow);
    if (!keep_alive_) { Finish(1); return; }
    profile_ = profile;
    profile_->AddObserver(this);
    if (!Current()) { Finish(1); return; }
    service_ = TemplateURLServiceFactory::GetForProfile(profile);
    if (!service_) { Finish(1); return; }
    service_->AddObserver(this);
    if (service_->loaded()) { Loaded(); return; }
    loaded_ = service_->RegisterOnLoadedCallback(base::BindOnce(
        [](std::shared_ptr<BarcSearchRequest> self) { self->Loaded(); },
        shared_from_this()));
    service_->Load();
  }
  void OnTemplateURLServiceChanged() override {}
  void OnTemplateURLServiceShuttingDown() override {
    auto alive = shared_from_this();
    Finish(1);
  }
  void OnProfileWillBeDestroyed(Profile*) override {
    auto alive = shared_from_this();
    Finish(1);
  }
 private:
  bool Current() const {
    if (!profile_ || !Manager() || profile_->ShutdownStarted() || IsProfileDirectoryPendingDeletion(
            profile_->GetOriginalProfile()->GetPath())) return false;
    if (window_ > 0) {
      char identity[37] = {};
      const size_t count = private_
          ? barc_window_private_session_uuid(window_, identity, sizeof(identity))
          : barc_window_profile_uuid(window_, identity, sizeof(identity));
      auto* collection = GlobalBrowserCollection::GetInstance();
      auto* owner = collection ? collection->FindBrowserWithID(
          SessionID::FromSerializedValue(window_)) : nullptr;
      return count == sizeof(identity) && uuid_ == identity && owner &&
             owner->GetProfile() == profile_;
    }
    return !private_ && profile_->IsRegularProfile() &&
        profile_->GetPath() == Manager()->user_data_dir().AppendASCII(kPrefix + uuid_) &&
        !IsProfileDirectoryPendingDeletion(profile_->GetPath());
  }
  void Loaded() {
    if (!Current()) { Finish(1); return; }
    // Loaded native state is the authority after this one-time app choice.
    // Managed/extension defaults are never replaced, including on first use.
    if (!profile_->GetPrefs()->GetBoolean(kSearchImported)) {
      if (service_->GetDefaultSearchManager()->GetDefaultSearchEngineSource() ==
          DefaultSearchManager::FROM_FALLBACK) {
        if (seed_.empty()) { Finish(3); return; }
        auto seed = base::JSONReader::ReadDict(seed_, base::JSON_PARSE_RFC);
        const auto* engines = seed ? seed->FindList("engines") : nullptr;
        const auto* selected = seed ? seed->FindString("selected") : nullptr;
        if (!engines || !selected || engines->size() > 128) { Finish(1); return; }
        TemplateURL* choice = nullptr;
        for (const auto& value : *engines) {
          const auto* data = value.GetIfDict();
          const auto* id = data ? data->FindString("id") : nullptr;
          const auto* name = data ? data->FindString("name") : nullptr;
          const auto* url = data ? data->FindString("url") : nullptr;
          if (!id || !name || !url || id->size() > 128 || name->size() > 256 ||
              url->size() > 8192) { Finish(1); return; }
          TemplateURLData entry;
          entry.SetShortName(base::UTF8ToUTF16(*name));
          entry.SetKeyword(base::UTF8ToUTF16("barc-" + *id));
          entry.SetURL(*url);
          auto candidate = std::make_unique<TemplateURL>(entry);
          const GURL check(candidate->url_ref().ReplaceSearchTerms(
              TemplateURLRef::SearchTermsArgs(u"test"), service_->search_terms_data()));
          if (!candidate->SupportsReplacement(service_->search_terms_data()) ||
              !check.SchemeIsHTTPOrHTTPS() || check.has_username() || check.has_password() ||
              (check.DomainIs("kagi.com") && check.query().find("token=") != std::string::npos)) {
            Finish(1); return;
          }
          TemplateURL* existing = nullptr;
          for (const auto& item : service_->GetTemplateURLs()) {
            if (item->type() == TemplateURL::NORMAL && item->url() == *url &&
                item->url_ref().GetPostParamsString().empty()) {
              existing = item.get(); break;
            }
          }
          if (!existing) existing = service_->Add(std::move(candidate));
          if (!Current()) { Finish(1); return; }
          if (*id == *selected) choice = existing;
        }
        if (!choice) { Finish(1); return; }
        if (choice != service_->GetDefaultSearchProvider()) {
          if (!service_->CanMakeDefault(choice)) { Finish(1); return; }
          service_->SetUserSelectedDefaultSearchProvider(choice);
        }
        if (!Current()) { Finish(1); return; }
      }
      profile_->GetPrefs()->SetBoolean(kSearchImported, true);
      if (!Current()) { Finish(1); return; }
    }
    if (!selection_.empty()) {
      auto* selected = service_->GetTemplateURLForGUID(selection_);
      if (!selected) { Finish(2); return; }
      if (selected != service_->GetDefaultSearchProvider()) {
        if (!service_->CanMakeDefault(selected)) { Finish(2); return; }
        service_->SetUserSelectedDefaultSearchProvider(selected);
      }
      if (!Current()) { Finish(1); return; }
    }
    const auto* effective = service_->GetDefaultSearchProvider();
    base::DictValue result;
    result.Set("controlled", service_->is_default_search_managed() ||
                             service_->IsExtensionControlledDefaultSearch());
    result.Set("managed", service_->is_default_search_managed());
    result.Set("selected", effective ? effective->sync_guid() : "");
    result.Set("name", effective ? base::UTF16ToUTF8(effective->short_name()) : "Search disabled");
    const std::string identity = effective ? effective->sync_guid() + effective->url() +
        effective->url_ref().GetPostParamsString() : "disabled";
    result.Set("version", base::HexEncode(base::SHA1HashString(identity)));
    base::ListValue options;
    if (choices_) for (const auto& entry : service_->GetTemplateURLs()) {
      if (!entry->SupportsReplacement(service_->search_terms_data())) continue;
      base::DictValue item;
      item.Set("id", entry->sync_guid());
      item.Set("name", base::UTF16ToUTF8(entry->short_name()));
      options.Append(std::move(item));
    }
    result.Set("providers", std::move(options));
    // Suggestions have a stricter endpoint contract than search navigation.
    // Unknown/custom/controlled engines send no third-party suggestion query.
    result.Set("kagiSession", effective &&
        effective->url() == "https://kagi.com/search?q={searchTerms}" &&
        effective->url_ref().GetPostParamsString().empty() &&
        !service_->is_default_search_managed() && !service_->IsExtensionControlledDefaultSearch());
    std::string suggestions;
    if (effective && profile_->GetPrefs()->GetBoolean(prefs::kSearchSuggestEnabled) &&
        !service_->is_default_search_managed() && !service_->IsExtensionControlledDefaultSearch()) {
      if (effective->url() == "https://www.google.com/search?q={searchTerms}") suggestions = "google";
      if (effective->url() == "https://kagi.com/search?q={searchTerms}") suggestions = "kagi";
    }
    result.Set("suggestions", suggestions);
    auto json = base::WriteJson(result);
    Finish(json ? 0 : 1, json.value_or(""));
  }
  void Finish(int32_t status, std::string json = {}) {
    auto callback = std::exchange(callback_, nullptr);
    void* context = context_.get();
    context_ = nullptr;
    loaded_ = {};
    if (service_) { service_->RemoveObserver(this); service_ = nullptr; }
    if (profile_) { profile_->RemoveObserver(this); profile_ = nullptr; }
    auto keep_alive = std::move(keep_alive_);
    if (callback) callback(context, status, json.c_str());
  }
  std::unique_ptr<ScopedProfileKeepAlive> keep_alive_;
  std::string uuid_, seed_, selection_;
  int32_t window_;
  bool private_;
  bool choices_;
  raw_ptr<Profile> profile_ = nullptr;
  raw_ptr<TemplateURLService> service_ = nullptr;
  base::CallbackListSubscription loaded_;
  barc_search_callback callback_;
  raw_ptr<void> context_;
};
}  // namespace

void barc_profile_search_state(const char* uuid, int32_t window,
    int32_t is_private, const char* seed, const char* selection, int32_t choices,
    barc_search_callback callback, void* context) {
  CHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) return;
  const std::string identity = uuid ? CanonicalUUID(uuid) : std::string();
  if (identity.empty() || (seed && strlen(seed) > 131072) ||
      (is_private != 0 && is_private != 1) || (choices != 0 && choices != 1) || window < 0 || (is_private && !window)) {
    callback(context, 1, ""); return;
  }
  auto request = std::make_shared<BarcSearchRequest>(identity, window, is_private,
      seed ? seed : "", selection ? selection : "", choices != 0, callback, context);
  if (window > 0) {
    auto* collection = GlobalBrowserCollection::GetInstance();
    auto* owner = collection ? collection->FindBrowserWithID(
        SessionID::FromSerializedValue(window)) : nullptr;
    request->Begin(owner ? owner->GetProfile() : nullptr);
  } else {
    barc::WithRegularProfileForApplication(identity, base::BindOnce(
        [](std::shared_ptr<BarcSearchRequest> request, Profile* profile) {
          request->Begin(profile);
        }, std::move(request)));
  }
}
