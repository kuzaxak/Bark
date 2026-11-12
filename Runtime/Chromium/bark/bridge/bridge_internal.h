#ifndef BARK_BRIDGE_BRIDGE_INTERNAL_H_
#define BARK_BRIDGE_BRIDGE_INTERNAL_H_

#import <AppKit/AppKit.h>

#include <stdint.h>

#include <set>
#include <string>

#include "base/callback_list.h"
#include "base/containers/linked_list.h"
#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/supports_user_data.h"
#include "bark/bridge/barc_bridge.h"
#include "bark/bridge/barc_runtime_startup.h"
#include "components/tabs/public/tab_interface.h"
#include "url/gurl.h"

class BrowserWindowInterface;
class Profile;

// Intrinsic view pairing, never a window/profile lookup registry. The header
// must not retain its sidebar through a callback; native hosts retain both.
@interface BarcPageHeader : NSObject
@property(nonatomic, strong) NSView* view;
@property(nonatomic) int height;
@end

// State and lookups the bridge's domain files share. UI thread only.
namespace barc::internal {

extern const char kNativePageHeaderKey;
BarcPageHeader* PageHeader(NSView* sidebar);
// The storage outlives all reentrant observer callouts.
extern int navigation_callback_depth;
extern bool attaching_native_shell;

extern const char kApplicationLaunchKey;
struct ApplicationLaunch : public base::SupportsUserData::Data,
                           public base::LinkNode<ApplicationLaunch> {
  ApplicationLaunch(uint64_t request, std::string space,
                    base::WeakPtr<Profile> profile);
  ~ApplicationLaunch() override;
  uint64_t request;
  std::string space;
  base::WeakPtr<Profile> profile;
  base::RepeatingClosure resume;
};
// An index of pending intrinsic records, not another URL/payload owner.
base::LinkedList<ApplicationLaunch>& PendingApplicationPageIntents();

BrowserWindowInterface* Window(int32_t id);
tabs::TabInterface* LookupTab(BrowserWindowInterface* window, int32_t id);

extern const char kPeekRoleKey;
extern const char kPeekSourceKey;
void ResetPeekConsent(base::SupportsUserData::Data* data, const void* key);
base::CallbackListSubscription PreservePeekDataAcrossDiscard(
    tabs::TabInterface* tab, const void* key);
struct PeekRole : public base::SupportsUserData::Data {
  PeekRole(tabs::TabInterface* tab, tabs::TabInterface* source);
  ~PeekRole() override;
  base::WeakPtr<tabs::TabInterface> source;
  bool close_committed = false;
  base::CallbackListSubscription discard;
};
struct PeekSource : public base::SupportsUserData::Data {
  PeekSource(tabs::TabInterface* source, tabs::TabInterface* peek);
  ~PeekSource() override;
  base::WeakPtr<tabs::TabInterface> peek;
  bool close_committed = false;
  base::CallbackListSubscription discard;
};
PeekRole* PeekRoleFor(tabs::TabInterface* tab);
void ClearPeekRole(tabs::TabInterface* tab);

GURL URL(const char* value);

// Catalog state owns only subscriptions, never browsers, tabs or profiles.
extern uint64_t discovery_revision;
extern bool discovery_stopped;

// Physical groups whose lifetime the app owns. Group ids are never reused.
std::set<uint64_t>& AppLifetimeGroups();
bool HasAppLifetime(BrowserWindowInterface* browser);
bool RetainsEmptyTabStrip(BrowserWindowInterface* browser);

void CancelDownloadObservation();

// The size rule of barc_bridge_api.h for a struct the app allocated: it is at
// least as large as the engine's, and the engine writes only its own fields.
template <typename T>
bool IsSized(const T* value) {
  return value && value->size >= sizeof(T);
}
template <typename T>
void WriteKnownFields(T* out, T value) {
  value.size = out->size;
  *out = value;
}

}  // namespace barc::internal

#endif  // BARK_BRIDGE_BRIDGE_INTERNAL_H_
