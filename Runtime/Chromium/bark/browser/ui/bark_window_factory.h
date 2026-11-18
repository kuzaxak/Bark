#ifndef BARK_BROWSER_UI_BARK_WINDOW_FACTORY_H_
#define BARK_BROWSER_UI_BARK_WINDOW_FACTORY_H_

#include <memory>

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

// Marks browsers opened by an explicit app action for native discovery.
class ScopedAppWindowCreation {
 public:
  ScopedAppWindowCreation();
  ScopedAppWindowCreation(const ScopedAppWindowCreation&) = delete;
  ScopedAppWindowCreation& operator=(const ScopedAppWindowCreation&) = delete;
  ~ScopedAppWindowCreation();
};

}  // namespace bark

#endif  // BARK_BROWSER_UI_BARK_WINDOW_FACTORY_H_
