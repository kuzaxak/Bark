#import <AppKit/AppKit.h>

#include "testing/gtest/include/gtest/gtest.h"

namespace {

// AppKit queues these for the Mac's own pointer, wherever it is. A page that
// shrinks or moves from under it gets mouseExited and drops its link's status
// bubble; a page under it takes its hover. content::Simulate* input does not
// pass through this queue.
constexpr NSEventMask kRealPointerEvents =
    NSEventMaskMouseMoved | NSEventMaskMouseEntered | NSEventMaskMouseExited;

class RealPointerIsolation : public testing::EmptyTestEventListener {
 public:
  void OnTestStart(const testing::TestInfo&) override {
    monitor_ = [NSEvent addLocalMonitorForEventsMatchingMask:kRealPointerEvents
                                                     handler:^NSEvent*(NSEvent*) {
                                                       return nil;
                                                     }];
  }
  void OnTestEnd(const testing::TestInfo&) override {
    [NSEvent removeMonitor:monitor_];
    monitor_ = nil;
  }

 private:
  id monitor_;
};

[[maybe_unused]] const bool kRegistered = [] {
  testing::UnitTest::GetInstance()->listeners().Append(new RealPointerIsolation);
  return true;
}();

}  // namespace
