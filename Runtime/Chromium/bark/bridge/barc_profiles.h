#ifndef BARC_CHROMIUM_PROFILES_H_
#define BARC_CHROMIUM_PROFILES_H_

#include <string>

#include "bark/bridge/barc_bridge_functions.h"
#include "base/functional/callback_forward.h"
class Profile;
namespace barc {
// Exact regular Barc UUID only. Callback borrows manager-owned Profile; it must
// synchronously establish browser ownership or acquire a scoped profile
// keepalive. Failed/cancelled loads return
// null.
void WithRegularProfileForApplication(
    std::string uuid,
    base::OnceCallback<void(Profile*)> callback);
}  // namespace barc
#endif
