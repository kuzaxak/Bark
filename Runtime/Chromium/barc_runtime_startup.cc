#include "chrome/browser/ui/views/frame/barc_runtime_startup.h"

#include <pthread.h>

#include <utility>
#include <algorithm>
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
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/ui/views/frame/browser_widget.h"
#include "components/tabs/public/tab_interface.h"
#include "ui/display/screen.h"
#include "url/url_constants.h"

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
  void (*window_request_callback)(int32_t, void*) = nullptr;
  raw_ptr<void> window_request_user_data = nullptr;
  int32_t (*browser_target_callback)(int32_t, const char*, int32_t, int32_t, BarcApplicationTarget*, void*) = nullptr;
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
  state.window_request_callback = nullptr;
  state.window_request_user_data = nullptr;
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

void barc_set_runtime_window_request_callback(void (*callback)(int32_t, void*),
                                              void* user_data) {
  CHECK(pthread_main_np());
  auto& state = State();
  CHECK(state.phase == Phase::kEmpty || state.phase == Phase::kRegistered);
  CHECK(callback);
  CHECK(!state.window_request_callback);
  state.window_request_callback = callback;
  state.window_request_user_data = user_data;
}

void barc_set_runtime_browser_target_callback(
    int32_t (*callback)(int32_t, const char*, int32_t, int32_t,
                        BarcApplicationTarget*, void*),
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
         !state.close_user_data && !state.window_request_callback &&
         !state.window_request_user_data && !state.browser_target_callback &&
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
        if (CanResolveApplicationBrowser()) DrainApplicationPageIntents();
      }));
}
base::FilePath ApplicationLaunchDirectory() {
  return State().launch_directory;
}
bool IsPageCommand(int command_id) {
  switch (command_id) {
    case IDC_BACK:
    case IDC_FORWARD:
    case IDC_RELOAD:
    case IDC_RELOAD_BYPASSING_CACHE:
    case IDC_RELOAD_CLEARING_CACHE:
    case IDC_STOP:
    case IDC_FIND:
    case IDC_FIND_NEXT:
    case IDC_FIND_PREVIOUS:
    case IDC_CLOSE_FIND_OR_STOP:
    case IDC_ZOOM_PLUS:
    case IDC_ZOOM_NORMAL:
    case IDC_ZOOM_MINUS:
    case IDC_PRINT:
    case IDC_BASIC_PRINT:
    case IDC_DEV_TOOLS:
    case IDC_DEV_TOOLS_CONSOLE:
    case IDC_DEV_TOOLS_DEVICES:
    case IDC_DEV_TOOLS_INSPECT:
    case IDC_DEV_TOOLS_TOGGLE:
    case IDC_VIEW_SOURCE:
      return true;
    default:
      return false;
  }
}
bool ApplicationOwnsKeyCommand(int command_id) {
  if (!IsNativeApplicationMode() || IsPageCommand(command_id)) {
    return false;
  }
  switch (command_id) {
    case IDC_CUT:
    case IDC_COPY:
    case IDC_PASTE:
    case IDC_NEW_WINDOW:
    case IDC_NEW_INCOGNITO_WINDOW:
      return false;
    default:
      return true;
  }
}
bool KeyCommandBelongsToApplication(gfx::NativeWindow window, int command_id) {
  if (ApplicationOwnsKeyCommand(command_id)) {
    return true;
  }
  if (!IsNativeApplicationMode() || !IsPageCommand(command_id) || !window) {
    return false;
  }
  auto* view = BrowserView::GetBrowserViewForNativeWindow(window);
  return view && view->browser_widget() &&
         view->browser_widget()->barc_page_hidden();
}
void RequestApplicationWindow(int32_t request) {
  CHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& state = State();
  if (!IsNativeApplicationRegistered() || !state.window_request_callback ||
      browser_shutdown::IsTryingToQuit()) {
    return;
  }
  state.window_request_callback(request, state.window_request_user_data.get());
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
  BarcApplicationTarget value{};
  bool opening = false;
};
std::optional<std::string> TargetUUID(const char (&value)[37]) {
  if (value[36] != '\0') return std::nullopt;
  if (!value[0]) return std::string();
  const auto uuid = base::Uuid::ParseCaseInsensitive(value);
  if (!uuid.is_valid() || uuid.AsLowercaseString() != value ||
      uuid.AsLowercaseString() == "00000000-0000-0000-0000-000000000000")
    return std::nullopt;
  return uuid.AsLowercaseString();
}
std::optional<ApplicationTarget> ResolveTarget(int32_t kind, const std::string& url,
                                               int32_t pending_window,
                                               int32_t pending_tab) {
  if (!CanResolveApplicationBrowser() || kind < 0 || kind > 3) return std::nullopt;
  BarcApplicationTarget value{};
  auto callback = State().browser_target_callback;
  const int32_t result = callback(kind, url.empty() ? nullptr : url.c_str(),
      pending_window, pending_tab, &value, State().browser_target_user_data.get());
  if (!CanResolveApplicationBrowser() || State().browser_target_callback != callback)
    return std::nullopt;
  if (result == -1 && (kind == 0 || kind == 3)) {
    ApplicationTarget target; target.opening = true; return target;
  }
  if (result != 1 || value.presentation > BARC_APPLICATION_MINI)
    return std::nullopt;
  const auto regular = TargetUUID(value.regular_profile_uuid);
  const auto space = TargetUUID(value.space_uuid);
  if (!regular || !space || (kind == 0 && !url.empty() &&
      value.presentation == BARC_APPLICATION_CURRENT_SPACE && space->empty()))
    return std::nullopt;
  if (value.window > 0) {
    auto* browser = GlobalBrowserCollection::GetInstance()->FindBrowserWithID(
        SessionID::FromSerializedValue(value.window));
    if (!browser || browser->IsDeleteScheduled() || !browser->GetWindow() ||
        (kind != 3 && !browser->IsSelectedForNativeWindow()) ||
        (browser->GetType() != BrowserWindowInterface::TYPE_NORMAL &&
         !(value.presentation == BARC_APPLICATION_MINI && IsApplicationMini(browser))))
      return std::nullopt;
    if (kind == 3 && (value.window != pending_window ||
        !barc_tab_copy_title(pending_window, pending_tab, nullptr, 0)))
      return std::nullopt;
    std::array<char, 37> actual{};
    if (barc_window_profile_uuid(value.window, actual.data(), actual.size()) == 37) {
      if (kind == 3 && !regular->empty() && *regular != actual.data())
        return std::nullopt;
      const auto uuid = regular->empty() ? std::string(actual.data()) : *regular;
      if (regular->empty()) base::span(value.regular_profile_uuid).copy_from(base::span(actual));
      return ApplicationTarget{browser->GetWeakPtr(), uuid, value};
    }
    if (regular->empty() && (kind != 0 || value.presentation == BARC_APPLICATION_MINI) &&
        barc_window_private_session_uuid(value.window, actual.data(), actual.size()) == 37)
      return ApplicationTarget{browser->GetWeakPtr(), {}, value};
    return std::nullopt;
  }
  if (value.window || regular->empty() || kind == 3) return std::nullopt;
  return ApplicationTarget{nullptr, *regular, value};
}
}  // namespace
void RunInApplicationBrowser(int32_t kind,
    base::OnceCallback<void(ApplicationBrowserResult, BrowserWindowInterface*, Profile*)> callback) {
  RunInApplicationBrowser(kind, {}, 0, 0,
      base::BindOnce([](base::OnceCallback<void(ApplicationBrowserResult,
                           BrowserWindowInterface*, Profile*)> callback,
                        ApplicationBrowserResult result, BrowserWindowInterface* browser,
                        Profile* profile, BarcApplicationTarget) {
        std::move(callback).Run(result, browser, profile);
      }, std::move(callback)));
}
void RunInApplicationBrowser(int32_t kind, std::string url,
    int32_t pending_window, int32_t pending_tab,
    base::OnceCallback<void(ApplicationBrowserResult, BrowserWindowInterface*,
                            Profile*, BarcApplicationTarget)> callback) {
  CHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto target = ResolveTarget(kind, url, pending_window, pending_tab);
  if (!target || target->opening) {
    std::move(callback).Run(target ? ApplicationBrowserResult::kOpening
                                  : ApplicationBrowserResult::kUnavailable,
                            nullptr, nullptr, {});
    return;
  }
  if (target->browser) {
    std::array<char, 37> actual{};
    const auto id = target->browser->GetSessionID().id();
    if (target->regular_uuid.empty() ||
        (barc_window_profile_uuid(id, actual.data(), actual.size()) == 37 &&
         target->regular_uuid == actual.data())) {
      std::move(callback).Run(ApplicationBrowserResult::kReady, target->browser.get(),
                              target->browser->GetProfile(), target->value);
      return;
    }
  }
  WithRegularProfileForApplication(target->regular_uuid,
      base::BindOnce([](int32_t kind, std::string url, int32_t pending_window,
                        int32_t pending_tab, ApplicationTarget expected,
                        base::OnceCallback<void(ApplicationBrowserResult,
                            BrowserWindowInterface*, Profile*, BarcApplicationTarget)> callback,
                        Profile* profile) {
        auto current = ResolveTarget(kind, url, pending_window, pending_tab);
        if (profile && current && current->opening) {
          std::move(callback).Run(ApplicationBrowserResult::kOpening, nullptr, nullptr, {});
          return;
        }
        if (!profile || !current || current->regular_uuid != expected.regular_uuid ||
            current->value.presentation != expected.value.presentation ||
            std::string(current->value.space_uuid) != expected.value.space_uuid ||
            (expected.value.window && (!expected.browser ||
                current->browser.get() != expected.browser.get()))) {
          std::move(callback).Run(ApplicationBrowserResult::kUnavailable, nullptr, nullptr, {});
          return;
        }
        std::move(callback).Run(ApplicationBrowserResult::kReady, current->browser.get(),
                                profile, current->value);
      }, kind, std::move(url), pending_window, pending_tab, *target, std::move(callback)));
}

bool IsApplicationMini(const BrowserWindowInterface* browser) {
  const auto* view = browser && !browser->IsDeleteScheduled()
      ? BrowserView::GetBrowserViewForBrowser(browser) : nullptr;
  return IsNativeApplicationRegistered() && view && view->barc_compact_shell() &&
      browser->GetType() == BrowserWindowInterface::TYPE_POPUP;
}
ApplicationPage CreateApplicationPage(Profile* profile, BrowserWindowInterface* owner,
    const BarcApplicationTarget& target, uint64_t request) {
  CHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!CanResolveApplicationBrowser() || !profile || !request ||
      GetBrowserWindowCreationStatusForProfile(*profile) !=
          BrowserWindowInterface::CreationStatus::kOk) return {};
  auto profile_alive = profile->GetWeakPtr();
  auto owner_alive = owner ? owner->GetWeakPtr() : base::WeakPtr<BrowserWindowInterface>();
  auto keep_alive = ScopedProfileKeepAlive::TryAcquire(profile->GetOriginalProfile(),
      ProfileKeepAliveOrigin::kProfileCreationFlow);
  if (!keep_alive) return {};
  const bool mini = target.presentation == BARC_APPLICATION_MINI;
  const bool create = mini || !owner || owner->GetProfile() != profile;
  base::WeakPtr<BrowserWindowInterface> selected_before;
  if (!mini && owner) {
    if (owner->IsDeleteScheduled() || !owner->GetWindow() ||
        !BrowserWindow::CanCreateInNativeWindow(owner->GetSessionID())) return {};
    auto* selected = GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
        owner->GetWindow()->GetNativeWindow());
    if (!selected) return {};
    selected_before = selected->GetWeakPtr();
  }
  BrowserWindowInterface* browser = owner;
  if (create) {
    BrowserWindowCreateParams params(mini ? BrowserWindowInterface::TYPE_POPUP
                                        : BrowserWindowInterface::TYPE_NORMAL, profile, true);
    params.should_trigger_session_restore = false;
    if (!mini && owner) params.native_window_owner = owner->GetSessionID();
    if (mini) {
      auto* screen = display::Screen::Get();
      const auto display = owner && owner->GetWindow()
          ? screen->GetDisplayNearestWindow(owner->GetWindow()->GetNativeWindow())
          : screen->GetDisplayForNewWindows();
      const auto area = display.work_area();
      const int width = std::clamp(area.width() * 3 / 4, 640, 1280);
      const int height = std::clamp(area.height() * 85 / 100, 480, 900);
      params.initial_bounds = gfx::Rect(area.CenterPoint().x() - width / 2,
          area.CenterPoint().y() - height / 2, width, height);
    }
    browser = CreateBrowserWindow(std::move(params));
  }
  if (!browser) return {};
  auto alive = browser->GetWeakPtr();
  const auto valid = [&] {
    if (!CanResolveApplicationBrowser() || !profile_alive || !alive ||
        alive->IsDeleteScheduled() || alive->GetProfile() != profile_alive.get() ||
        !alive->GetWindow() || (target.window && (!owner_alive || owner_alive->IsDeleteScheduled())))
      return false;
    if (!mini && owner_alive) {
      if (!owner_alive->GetWindow() || owner_alive->GetWindow()->GetNativeWindow() !=
          alive->GetWindow()->GetNativeWindow()) return false;
    }
    return true;
  };
  const auto cancel_empty = [&] {
    if (create && alive && !alive->IsDeleteScheduled() && alive->GetWindow() &&
        alive->GetTabStripModel()->empty()) alive->GetWindow()->Close();
  };
  if (!valid() || (mini && !ConfigureNativeMini(alive.get()))) {
    cancel_empty(); return {};
  }
  if (!mini && selected_before &&
      GlobalBrowserCollection::GetInstance()->FindBrowserWithWindow(
          alive->GetWindow()->GetNativeWindow()) != selected_before.get()) {
    cancel_empty(); return {};
  }
  const int32_t id = alive->GetSessionID().id();
  if (!barc_window_select(id) || !valid()) { cancel_empty(); return {}; }
  auto* returned = chrome::AddAndReturnTabAt(alive.get(), GURL(url::kAboutBlankURL), -1, true);
  if (!valid() || !returned) { cancel_empty(); return {}; }
  auto* strip = alive->GetTabStripModel();
  const int index = strip->GetIndexOfWebContents(returned);
  if (index == TabStripModel::kNoTab) return {};
  const int32_t tab = strip->GetTabAtIndex(index)->GetHandle().raw_value();
  if (!MarkApplicationPage(id, tab, request, target.space_uuid)) {
    barc_tab_close(id, tab); return {};
  }
  alive->GetWindow()->Show();  // New clients defer presentation until header admission.
  if (!valid() || !ApplicationPageMatches(id, tab, request)) {
    // Show can transfer/close the resource. No captured pending handle will
    // reach AppController on this path, so retire only this intrinsic request.
    CloseUnusedApplicationPage(ApplicationPage{id, tab, request});
    return {};
  }
  return ApplicationPage{id, tab, request};
}
bool IsPendingApplicationPage(ApplicationPage page) {
  if (!CanResolveApplicationBrowser() || !ApplicationPageMatches(page.window, page.tab, page.request))
    return false;
  auto* tab = tabs::TabHandle(page.tab).Get();
  const auto& visible_url = tab->GetContents()->GetVisibleURL();
  return visible_url.is_empty() || visible_url == GURL(url::kAboutBlankURL);
}
void CloseUnusedApplicationPage(ApplicationPage page) {
  bool close = IsPendingApplicationPage(page);
  if (close) {
    auto* tab = tabs::TabHandle(page.tab).Get();
    auto* browser = tab->GetBrowserWindowInterface();
    if (IsApplicationMini(browser)) {
      auto* view = BrowserView::GetBrowserViewForBrowser(browser);
      close = barc_window_native_shell_is_owned(page.window, nullptr) ||
          view->HasConfirmedBarcCompactShell();
    }
  }
  AbandonApplicationPageRequest(page.tab, page.request);
  if (close) barc_tab_close(page.window, page.tab);
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
