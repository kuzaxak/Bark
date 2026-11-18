// Licensed under GPL-3.0. See LICENSE.

#ifndef BARK_BROWSER_SHUTDOWN_WATCHDOG_BUDGET_H_
#define BARK_BROWSER_SHUTDOWN_WATCHDOG_BUDGET_H_

#include <algorithm>
#include <cstdint>

namespace bark {

// All inputs share the same monotonic clock and units. Only extend an expired
// UI watchdog when it finds the Network Service's bounded wait still active.
// Never grant a second full watchdog interval after that wait.
constexpr int64_t NetworkShutdownGrace(int64_t now,
                                       int64_t watchdog_deadline,
                                       int64_t network_wait_deadline,
                                       int64_t maximum_network_wait,
                                       int64_t after_wait_grace) {
  if (network_wait_deadline == 0)
    return 0;
  const int64_t end =
      std::min(network_wait_deadline, watchdog_deadline + maximum_network_wait) +
      after_wait_grace;
  return std::max<int64_t>(0, end - now);
}

}  // namespace bark

#endif  // BARK_BROWSER_SHUTDOWN_WATCHDOG_BUDGET_H_
