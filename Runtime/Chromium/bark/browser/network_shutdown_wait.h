// Licensed under GPL-3.0. See LICENSE.

#ifndef BARK_BROWSER_NETWORK_SHUTDOWN_WAIT_H_
#define BARK_BROWSER_NETWORK_SHUTDOWN_WAIT_H_

#include "content/common/content_export.h"

namespace base {
class TimeDelta;
class TimeTicks;
}  // namespace base

namespace content {

// The macOS shutdown watchdog may call these functions concurrently with
// content teardown. The monotonic deadline is null outside the child-wait
// phase and its immediate child cleanup.
CONTENT_EXPORT base::TimeTicks GetNetworkServiceShutdownWaitDeadline();
CONTENT_EXPORT base::TimeDelta GetNetworkServiceShutdownWaitTimeout();

}  // namespace content

#endif  // BARK_BROWSER_NETWORK_SHUTDOWN_WAIT_H_
