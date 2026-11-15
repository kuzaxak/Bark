#import <AppKit/AppKit.h>

#include <cmath>
#include <map>
#include <memory>

#include "bark/bridge/barc_bridge_functions.h"
#include "bark/bridge/bridge_internal.h"
#include "bark/browser/ui/bark_browser_window.h"
#include "bark/browser/ui/bark_window_host.h"
#include "base/check.h"
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/web_contents.h"

using namespace barc::internal;

namespace {

bool OnUIThread() {
  return content::BrowserThread::CurrentlyOn(content::BrowserThread::UI);
}

BarcFullscreenKind Kind(bark::HostFullscreen fullscreen) {
  switch (fullscreen) {
    case bark::HostFullscreen::kNone:
      return BARC_FULLSCREEN_NONE;
    case bark::HostFullscreen::kWindow:
      return BARC_FULLSCREEN_WINDOW;
    case bark::HostFullscreen::kPage:
      return BARC_FULLSCREEN_PAGE;
  }
}

// One window_host_observe registration. It forwards the host's notices as
// posted events, which still arrive after the host is gone.
class HostObservation : public bark::BarkWindowHost::Observer {
 public:
  HostObservation(uint64_t token,
                  bark::BarkWindowHost* host,
                  BarcWindowHostCallback callback,
                  void* context)
      : token_(token),
        host_(host->GetWeakPtr()),
        callback_(callback),
        context_(context) {
    host->AddObserver(this);
  }
  ~HostObservation() override {
    if (host_) {
      host_->RemoveObserver(this);
    }
  }

  void OnPageViewRetiring(int32_t window,
                          int32_t tab,
                          gfx::NativeView view) override {
    Post(BarcWindowHostEvent{.size = sizeof(BarcWindowHostEvent),
                             .kind = BARC_WINDOW_HOST_PAGE_VIEW_RETIRED,
                             .window = window,
                             .tab = tab},
         view.GetNativeNSView());
  }
  void OnPageCrashed(int32_t window,
                     int32_t tab,
                     gfx::NativeView view,
                     bool crashed) override {
    Post(BarcWindowHostEvent{.size = sizeof(BarcWindowHostEvent),
                             .kind = crashed ? BARC_WINDOW_HOST_PAGE_CRASHED
                                             : BARC_WINDOW_HOST_PAGE_RESTORED,
                             .window = window,
                             .tab = tab},
         view.GetNativeNSView());
  }
  void OnFullscreenChanged(int32_t window,
                           bark::HostFullscreen fullscreen) override {
    Post(BarcWindowHostEvent{.size = sizeof(BarcWindowHostEvent),
                             .kind = BARC_WINDOW_HOST_FULLSCREEN_CHANGED,
                             .window = window,
                             .fullscreen = Kind(fullscreen)},
         nil);
  }

  void Deliver(const BarcWindowHostEvent& event) {
    callback_(&event, context_);
  }

 private:
  // Keeps the event's page view alive until it is delivered.
  void Post(BarcWindowHostEvent event, NSView* view);

  const uint64_t token_;
  base::WeakPtr<bark::BarkWindowHost> host_;
  const BarcWindowHostCallback callback_;
  const raw_ptr<void> context_;
};

std::map<uint64_t, std::unique_ptr<HostObservation>>& Observations() {
  static base::NoDestructor<std::map<uint64_t, std::unique_ptr<HostObservation>>>
      observations;
  return *observations;
}

void DeliverPosted(uint64_t token, BarcWindowHostEvent event, NSView* view) {
  auto& observations = Observations();
  auto found = observations.find(token);
  if (found != observations.end()) {
    event.view = (__bridge void*)view;
    found->second->Deliver(event);
  }
}

void HostObservation::Post(BarcWindowHostEvent event, NSView* view) {
  content::GetUIThreadTaskRunner({})->PostTask(
      FROM_HERE, base::BindOnce(&DeliverPosted, token_, event, view));
}

}  // namespace

int barc_window_set_root_view(int32_t id, void* root_view) {
  auto* window = Window(id);
  auto* host = bark::BarkWindowHost::ForBrowser(window);
  NSView* view = (__bridge NSView*)root_view;
  if (!host || !view || ![view isKindOfClass:[NSView class]]) {
    return 0;
  }
  return host->SetRootView(gfx::NativeView(view)) ? 1 : 0;
}

void* barc_tab_native_view(int32_t id, int32_t tab_id) {
  auto* window = Window(id);
  auto* tab = bark::BarkWindowHost::ForBrowser(window)
                  ? LookupTab(window, tab_id)
                  : nullptr;
  if (!tab || !tab->GetContents()) {
    return nullptr;
  }
  return (__bridge void*)tab->GetContents()->GetNativeView().GetNativeNSView();
}

int barc_window_set_chrome(int32_t id, const BarcWindowChrome* chrome) {
  if (!OnUIThread() || !chrome || chrome->size < sizeof(BarcWindowChrome) ||
      !std::isfinite(chrome->titlebar_height) ||
      !std::isfinite(chrome->leading_inset) || chrome->titlebar_height <= 0 ||
      chrome->leading_inset < 0) {
    return 0;
  }
  auto* host = bark::BarkWindowHost::ForBrowser(Window(id));
  return host && host->SetChrome(chrome->titlebar_height, chrome->leading_inset)
             ? 1
             : 0;
}

uint64_t barc_window_host_observe(int32_t id,
                                  BarcWindowHostCallback callback,
                                  void* context) {
  if (!OnUIThread() || !callback) {
    return 0;
  }
  auto* host = bark::BarkWindowHost::ForBrowser(Window(id));
  if (!host || host->closing()) {
    return 0;
  }
  static uint64_t next_token = 0;
  CHECK_NE(next_token, UINT64_MAX);
  const uint64_t token = ++next_token;
  Observations()[token] =
      std::make_unique<HostObservation>(token, host, callback, context);
  return token;
}

void barc_window_host_unobserve(uint64_t observation) {
  if (!OnUIThread()) {
    return;
  }
  Observations().erase(observation);
}
