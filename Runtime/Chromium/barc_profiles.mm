#include "chrome/browser/ui/views/frame/barc_profiles.h"
#include "chrome/browser/ui/views/frame/barc_bridge.h"

#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "base/uuid.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "components/sessions/core/session_id.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/base_window.h"
#include "url/gurl.h"

namespace {
constexpr char kPrefix[] = "Barc-";
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
  } else if (!profile || !profile->IsRegularProfile() ||
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
    if (!owner_alive || owner_alive->IsDeleteScheduled() ||
        !BrowserWindow::CanCreateInNativeWindow(owner_alive->GetSessionID())) {
      request->Complete(BARC_PROFILE_UNAVAILABLE, 0);
      return;
    }
    params.native_window_owner = owner_alive->GetSessionID();
  }
  const auto selection_before = selected_owner();
  auto* created = CreateBrowserWindow(std::move(params));
  if (!created) {
    request->Complete(BARC_PROFILE_UNAVAILABLE, 0);
    return;
  }
  auto window_alive = created->GetWeakPtr();
  if (auto* view = BrowserView::GetBrowserViewForBrowser(created))
    view->MarkBarcAppFactoryOrigin();
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
    if (!owner || owner->IsDeleteScheduled() ||
        !BrowserWindow::CanCreateInNativeWindow(owner->GetSessionID())) {
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
  manager->CreateProfileAsync(
      path,
      base::BindOnce(
          [](base::FilePath path, base::OnceCallback<void(Profile*)> callback,
             Profile* profile) {
            auto* manager = Manager();
            if (!manager || !profile || !profile->IsRegularProfile() ||
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
