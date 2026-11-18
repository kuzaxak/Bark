#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Check watchdog deadline arithmetic without a browser or wall-clock waits."""

from pathlib import Path
import subprocess
import unittest


class ShutdownWatchdogBudgetTests(unittest.TestCase):
    def test_only_the_bounded_network_phase_extends_the_deadline(self):
        # Seconds are enough for the examples; the production call uses the
        # same arithmetic with monotonic microseconds.
        source = """
#include "bark/browser/shutdown_watchdog_budget.h"
using bark::NetworkShutdownGrace;

// Unrelated hangs get no extension at the normal deadline.
static_assert(NetworkShutdownGrace(110, 110, 0, 10, 2) == 0);

// The child started its full 10-second flush at 102. The watchdog's
// original deadline at 110 leaves time for its remaining flush and cleanup.
static_assert(NetworkShutdownGrace(110, 110, 112, 10, 2) == 4);
static_assert(NetworkShutdownGrace(113, 110, 112, 10, 2) == 1);
static_assert(NetworkShutdownGrace(114, 110, 112, 10, 2) == 0);

// Even a stuck or unexpectedly distant deadline grants at most one
// Network Service interval and the short cleanup allowance.
static_assert(NetworkShutdownGrace(110, 110, 200, 10, 2) == 12);
static_assert(NetworkShutdownGrace(122, 110, 200, 10, 2) == 0);
"""
        subprocess.run(
            ["clang++", "-std=c++17", "-fsyntax-only", "-x", "c++",
             "-I", str(Path(__file__).resolve().parent), "-"],
            check=True, input=source, text=True,
        )


if __name__ == "__main__":
    unittest.main()
