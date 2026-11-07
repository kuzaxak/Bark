#include "chrome/browser/ui/views/frame/barc_runtime_startup.h"

#include <pthread.h>

#include <utility>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/memory/raw_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/views/frame/barc_bridge.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
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
};
Startup& State() {
  static base::NoDestructor<Startup> state;
  return *state;
}
}  // namespace

void barc_set_runtime_ready_callback(void (*callback)(void*), void* user_data) {
  auto& state = State();
  CHECK(pthread_main_np());
  CHECK_EQ(state.phase, Phase::kEmpty);
  CHECK(callback);
  state.callback = callback;
  state.user_data = user_data;
  state.phase = Phase::kRegistered;
}

void barc_runtime_complete_startup(int32_t window) {
  CHECK(pthread_main_np());
  auto& state = State();
  // Early ChromeMain failure never entered the browser loop. The caller must
  // still be able to release its callback storage without touching a dead UI.
  if (state.phase == Phase::kRegistered || state.phase == Phase::kPosted ||
      state.phase == Phase::kStopped) {
    state.callback = nullptr;
    state.user_data = nullptr;
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
    return;
  }
  chrome::AttemptExit();
}

namespace barc {
bool IsNativeApplicationRegistered() {
  const auto phase = State().phase;
  return phase != Phase::kEmpty && phase != Phase::kStopped;
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
  StopBrowserDiscovery();
  auto& state = State();
  state.callback = nullptr;
  state.user_data = nullptr;
  state.phase = Phase::kStopped;
}
}  // namespace barc
