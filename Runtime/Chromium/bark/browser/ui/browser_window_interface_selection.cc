// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"

#include <utility>

BrowserWindowInterface::BrowserWindowInterface() = default;
BrowserWindowInterface::~BrowserWindowInterface() = default;

bool BrowserWindowInterface::IsSelectedForNativeWindow() const {
  return true;
}

base::CallbackListSubscription
BrowserWindowInterface::RegisterNativeWindowSelectionChanged(
    base::RepeatingClosure callback) {
  return native_window_selection_changed_callbacks_.Add(std::move(callback));
}

void BrowserWindowInterface::NotifyNativeWindowSelectionChanged() {
  native_window_selection_changed_callbacks_.Notify();
}
