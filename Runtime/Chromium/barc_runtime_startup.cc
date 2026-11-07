#include "chrome/browser/ui/views/frame/barc_runtime_startup.h"

#include <pthread.h>

#include <utility>
#include <array>
#include <string>
#include <optional>

#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/uuid.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/views/frame/barc_profiles.h"

#include "base/callback_list.h"
#include "base/check.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/memory/raw_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/views/frame/barc_bridge.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "components/os_crypt/common/keychain_password_mac.h"
#include "components/sessions/core/session_id.h"
#include "content/public/browser/browser_thread.h"
#include "ui/base/base_window.h"

namespace {
enum class Phase {
  kEmpty,
  kRegistered,
  kPosted,
  kAwaitingCompletion,
  kComplete,
  kStopped
};
struct Startup {
  Phase phase = Phase::kEmpty;
  void (*callback)(void*) = nullptr;
  raw_ptr<void> user_data = nullptr;
  void (*close_callback)(int32_t, void*) = nullptr;
  raw_ptr<void> close_user_data = nullptr;
  int32_t (*browser_target_callback)(int32_t, char*, size_t, void*) = nullptr;
  raw_ptr<void> browser_target_user_data = nullptr;
  base::RepeatingClosure launch_ready;
  bool launch_drain_posted = false;
  base::FilePath launch_directory;
  bool accepted_close_notified = false;
  base::CallbackListSubscription accepted_close_subscription;
  base::CallbackListSubscription closing_subscription;
};
Startup& State() {
  static base::NoDestructor<Startup> state;
  return *state;
}
void ClearCallbacks() {
  auto& state = State();
  state.callback = nullptr;
  state.user_data = nullptr;
  state.close_callback = nullptr;
  state.close_user_data = nullptr;
  state.browser_target_callback = nullptr;
  state.browser_target_user_data = nullptr;
  state.launch_ready.Reset();
  state.launch_drain_posted = false;
  state.launch_directory.clear();
  state.accepted_close_notified = false;
  state.accepted_close_subscription = {};
  state.closing_subscription = {};
}
}  // namespace

void barc_set_runtime_ready_callback(void (*callback)(void*), void* user_data) {
  auto& state = State();
  CHECK(pthread_main_np());
  CHECK_EQ(state.phase, Phase::kEmpty);
  CHECK(callback);
  // Registration precedes ChromeMain/provider initialization and worker reads.
  // The stock, non-embedded browser never changes its default namespace.
  KeychainPassword::GetServiceName() = "NookChromium Safe Storage";
  KeychainPassword::GetAccountName() = "NookChromium";
  state.callback = callback;
  state.user_data = user_data;
  state.phase = Phase::kRegistered;
}

void barc_set_runtime_close_callback(void (*callback)(int32_t, void*),
                                     void* user_data) {
  CHECK(pthread_main_np());
  auto& state = State();
  CHECK(state.phase == Phase::kEmpty || state.phase == Phase::kRegistered);
  CHECK(!state.close_callback);
  CHECK(callback);
  state.close_callback = callback;
  state.close_user_data = user_data;
  state.accepted_close_subscription =
      chrome::AddAllBrowsersCloseAcceptedCallback(base::BindRepeating([] {
        auto& state = State();
        if (!barc::IsNativeApplicationRegistered() ||
            !browser_shutdown::IsTryingToQuit() ||
            state.accepted_close_notified || !state.close_callback) {
          return;
        }
        state.accepted_close_notified = true;
        auto callback = state.close_callback;
        void* data = state.close_user_data.get();
        callback(1, data);
      }));
  state.closing_subscription = chrome::AddClosingAllBrowsersCallback(
      base::BindRepeating([](bool closing) {
        auto& state = State();
        if (closing || !state.accepted_close_notified ||
            !barc::IsNativeApplicationRegistered() || !state.close_callback) {
          return;
        }
        // Reset before client code can reenter another shutdown attempt.
        state.accepted_close_notified = false;
        auto callback = state.close_callback;
        void* data = state.close_user_data.get();
        callback(0, data);
        barc::NotifyApplicationBrowserAvailable();
      }));
}

void barc_set_runtime_browser_target_callback(
    int32_t (*callback)(int32_t, char*, size_t, void*),
    void* user_data) {
  CHECK(pthread_main_np());
  auto& state = State();
  CHECK(state.phase == Phase::kEmpty || state.phase == Phase::kRegistered);
  CHECK(callback);
  CHECK(!state.browser_target_callback);
  base::GetCurrentDirectory(&state.launch_directory);
  state.browser_target_callback = callback;
  state.browser_target_user_data = user_data;
}

void barc_runtime_complete_startup(int32_t window) {
  CHECK(pthread_main_np());
  auto& state = State();
  // Early ChromeMain failure never entered the browser loop. The caller must
  // still be able to release its callback storage without touching a dead UI.
  if (state.phase == Phase::kRegistered || state.phase == Phase::kPosted ||
      state.phase == Phase::kStopped) {
    ClearCallbacks();
    state.phase = Phase::kStopped;
    return;
  }
  if (state.phase != Phase::kAwaitingCompletion)
    return;
  CHECK(content::BrowserThread::CurrentlyOn(content::BrowserThread::UI));
  state.phase = Phase::kComplete;  // Before validation/shutdown can reenter.
  state.callback = nullptr;
  state.user_data = nullptr;
  auto* browser =
      window > 0 ? GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
                       SessionID::FromSerializedValue(window))
                 : nullptr;
  if (browser && !browser->IsDeleteScheduled() &&
      BrowserView::GetBrowserViewForBrowser(browser)) {
    // The caller has admitted its model and attached the native shell. Show is
    // the final callout: it may synchronously destroy the browser.
    browser->GetWindow()->Show();
    if (barc::CanResolveApplicationBrowser()) {
      barc::NotifyApplicationBrowserAvailable();
    }
    return;
  }
  chrome::AttemptExit();
}

namespace barc {
bool RuntimeCallbacksClearedForTesting() {
  const auto& state = State();
  return !state.callback && !state.user_data && !state.close_callback &&
         !state.close_user_data && !state.browser_target_callback &&
         !state.browser_target_user_data && state.launch_ready.is_null() &&
         !state.launch_drain_posted && state.launch_directory.empty() &&
         !state.accepted_close_notified && !state.accepted_close_subscription &&
         !state.closing_subscription;
}
bool IsNativeApplicationRegistered() {
  const auto phase = State().phase;
  return phase != Phase::kEmpty && phase != Phase::kStopped;
}
void SetApplicationLaunchReadyCallback(base::RepeatingClosure callback) {
  CHECK(content::BrowserThread::CurrentlyOn(content::BrowserThread::UI));
  if (!IsNativeApplicationRegistered()) {
    return;
  }
  CHECK(State().launch_ready.is_null());
  State().launch_ready = std::move(callback);
  if (CanResolveApplicationBrowser()) {
    NotifyApplicationBrowserAvailable();
  }
}
void NotifyApplicationBrowserAvailable() {
  auto& state = State();
  if (!CanResolveApplicationBrowser() || !state.launch_ready ||
      state.launch_drain_posted) {
    return;
  }
  state.launch_drain_posted = true;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostNonNestableTask(
      FROM_HERE, base::BindOnce([] {
        State().launch_drain_posted = false;
        if (!CanResolveApplicationBrowser() || !State().launch_ready) {
          return;
        }
        auto drain = State().launch_ready;
        drain.Run();
      }));
}
base::FilePath ApplicationLaunchDirectory() {
  return State().launch_directory;
}
bool IsNativeApplicationMode() {
  auto* command = base::CommandLine::ForCurrentProcess();
  return State().phase != Phase::kEmpty &&
         command->HasSwitch("barc-native-shell") &&
         command->HasSwitch("barc-shared-native-window");
}
bool CanResolveApplicationBrowser() {
  auto& state = State();
  return IsNativeApplicationMode() && state.phase == Phase::kComplete &&
         state.browser_target_callback && !browser_shutdown::IsTryingToQuit();
}

namespace {
struct ApplicationTarget {
  base::WeakPtr<BrowserWindowInterface> browser;
  std::string regular_uuid;
  bool opening = false;
};
std::optional<ApplicationTarget> ResolveTarget(int32_t kind) {
  if (!CanResolveApplicationBrowser() || kind < 0 || kind > 2) {
    return std::nullopt;
  }
  std::array<char, 37> uuid{};
  auto callback = State().browser_target_callback;
  const int32_t id = callback(kind, uuid.data(), uuid.size(),
                              State().browser_target_user_data.get());
  if (!CanResolveApplicationBrowser() ||
      State().browser_target_callback != callback) {
    return std::nullopt;
  }
  if (id == -1 && kind == 0 && uuid.front() == '\0') {
    return ApplicationTarget{nullptr, {}, true};
  }
  if (id > 0) {
    auto* browser = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
        SessionID::FromSerializedValue(id));
    if (!browser || browser->IsDeleteScheduled() || !browser->GetWindow() ||
        !browser->IsSelectedForNativeWindow() ||
        browser->GetType() != BrowserWindowInterface::Type::TYPE_NORMAL) {
      return std::nullopt;
    }
    std::array<char, 37> actual{};
    if (barc_window_profile_uuid(id, actual.data(), actual.size()) == 37) {
      return ApplicationTarget{browser->GetWeakPtr(), actual.data()};
    }
    if (kind != 0 && barc_window_private_session_uuid(id, actual.data(),
                                                      actual.size()) == 37) {
      return ApplicationTarget{browser->GetWeakPtr(), {}};
    }
    return std::nullopt;
  }
  if (id != 0 || uuid.back() != '\0') {
    return std::nullopt;
  }
  const auto parsed = base::Uuid::ParseCaseInsensitive(uuid.data());
  if (!parsed.is_valid() || parsed.AsLowercaseString() != uuid.data() ||
      parsed.AsLowercaseString() == "00000000-0000-0000-0000-000000000000") {
    return std::nullopt;
  }
  return ApplicationTarget{nullptr, parsed.AsLowercaseString()};
}
}  // namespace
void RunInApplicationBrowser(int32_t kind,
                             base::OnceCallback<void(ApplicationBrowserResult,
                                                     BrowserWindowInterface*,
                                                     Profile*)> callback) {
  CHECK(content::BrowserThread::CurrentlyOn(content::BrowserThread::UI));
  auto target = ResolveTarget(kind);
  if (!target) {
    std::move(callback).Run(ApplicationBrowserResult::kUnavailable, nullptr,
                            nullptr);
    return;
  }
  if (target->opening) {
    std::move(callback).Run(ApplicationBrowserResult::kOpening, nullptr,
                            nullptr);
    return;
  }
  if (target->browser) {
    std::move(callback).Run(ApplicationBrowserResult::kReady,
                            target->browser.get(),
                            target->browser->GetProfile());
    return;
  }
  WithRegularProfileForApplication(
      target->regular_uuid,
      base::BindOnce(
          [](int32_t kind, std::string uuid,
             base::OnceCallback<void(ApplicationBrowserResult,
                                     BrowserWindowInterface*, Profile*)>
                 callback,
             Profile* profile) {
            auto current = ResolveTarget(kind);
            if (profile && current && current->opening) {
              std::move(callback).Run(ApplicationBrowserResult::kOpening,
                                      nullptr, nullptr);
              return;
            }
            if (!profile || !current || current->regular_uuid != uuid ||
                (current->browser &&
                 current->browser->GetProfile() != profile)) {
              std::move(callback).Run(ApplicationBrowserResult::kUnavailable,
                                      nullptr, nullptr);
              return;
            }
            std::move(callback).Run(ApplicationBrowserResult::kReady,
                                    current->browser.get(), profile);
          },
          kind, target->regular_uuid, std::move(callback)));
}
void PostRuntimeReady() {
  auto& state = State();
  if (state.phase != Phase::kRegistered)
    return;
  CHECK(content::BrowserThread::CurrentlyOn(content::BrowserThread::UI));
  state.phase = Phase::kPosted;
  // AppController already owns APP_CONTROLLER/DISABLED keepalive on macOS,
  // including --no-startup-window. Do not duplicate its lifetime policy.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce([] {
        auto& state = State();
        if (state.phase != Phase::kPosted)
          return;
        state.phase = Phase::kAwaitingCompletion;
        auto callback = std::exchange(state.callback, nullptr);
        void* data = state.user_data.get();
        state.user_data = nullptr;
        callback(data);
      }));
}
void RuntimeStopped() {
  auto& state = State();
  state.phase = Phase::kStopped;
  ClearCallbacks();
  StopBrowserDiscovery();
}
}  // namespace barc
