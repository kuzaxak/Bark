#ifndef BARK_BROWSER_UI_BARK_WINDOW_FACTORY_H_
#define BARK_BROWSER_UI_BARK_WINDOW_FACTORY_H_

#include <memory>

#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "chrome/browser/ui/browser_window_deleter.h"

class BrowserWindow;
class BrowserWindowInterface;
class Profile;
class SessionID;
struct BrowserWindowCreateParams;

namespace bark {

class BarkWindowHost;

bool CanCreateHostWindowForProfile(const Profile& profile);
bool CanCreateHostWindow(const BrowserWindowCreateParams& params);
std::unique_ptr<BrowserWindow, BrowserWindowDeleter> CreateHostWindow(
    BrowserWindowInterface* browser);
bool UsesCompactHost(const BrowserWindowInterface* browser);

// The host window `owner` is shown in, while it can take another client.
BarkWindowHost* HostToJoin(BrowserWindowInterface* owner);
BarkWindowHost* HostToJoin(const SessionID& owner);

// Browsers created while one of these lives are the app's own. With `join`,
// the first one becomes a client of that host instead of opening a window.
class ScopedAppWindowCreation {
 public:
  explicit ScopedAppWindowCreation(BarkWindowHost* join = nullptr);
  ScopedAppWindowCreation(const ScopedAppWindowCreation&) = delete;
  ScopedAppWindowCreation& operator=(const ScopedAppWindowCreation&) = delete;
  ~ScopedAppWindowCreation();

 private:
  scoped_refptr<BarkWindowHost> join_;
  raw_ptr<BarkWindowHost> previous_join_;
};

}  // namespace bark

#endif  // BARK_BROWSER_UI_BARK_WINDOW_FACTORY_H_
