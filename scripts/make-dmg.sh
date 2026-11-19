#!/bin/sh
# Licensed under GPL-3.0. See LICENSE.
# Package an existing signed Bark app using its matching Chromium SDK.
set -eu
exec python3 -B "$(dirname "$0")/bark-check.py" dmg "$@"
