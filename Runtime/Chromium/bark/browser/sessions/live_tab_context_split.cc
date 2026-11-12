// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "components/sessions/core/live_tab_context.h"

namespace sessions {

void LiveTabContext::ReconstructSplitTabs(
    base::span<LiveTab* const> tabs,
    split_tabs::SplitTabId split_id,
    const split_tabs::SplitTabVisualData& visual_data) {
  if (tabs.size() == 2) {
    ReconstructSplit(tabs[0], tabs[1], split_id, visual_data);
  }
}

}  // namespace sessions
