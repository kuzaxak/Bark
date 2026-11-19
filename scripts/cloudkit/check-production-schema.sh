#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Check the production schema in the Bark CloudKit container.
# Without a token file, cktool uses CLOUDKIT_MANAGEMENT_TOKEN or its saved token.
set -euo pipefail

usage="usage: scripts/cloudkit/check-production-schema.sh [management-token-file] | --compare exported.ckdb"
directory="$(cd "$(dirname "$0")" && pwd)"
schema="$directory/schema.ckdb"

if [[ "${1:-}" == --compare ]]; then
  [[ $# == 2 && -s "$2" ]] || { echo "$usage" >&2; exit 2; }
  exec python3 -B "$directory/compare-schema.py" "$schema" "$2"
fi

[[ $# -le 1 && "${1:-}" != --* ]] || { echo "$usage" >&2; exit 2; }
if [[ $# == 1 ]]; then
  [[ -s "$1" ]] || { echo "No such file, or it is empty: $1" >&2; exit 2; }
  CLOUDKIT_MANAGEMENT_TOKEN="$(tr -d '[:space:]' < "$1")"
  [[ -n "$CLOUDKIT_MANAGEMENT_TOKEN" ]] || { echo "Management token is empty" >&2; exit 2; }
  export CLOUDKIT_MANAGEMENT_TOKEN
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun cktool export-schema --team-id 538SB59LX4 --container-id iCloud.ee.qdo.bark \
  --environment production --output-file "$work/production.ckdb"
python3 -B "$directory/compare-schema.py" "$schema" "$work/production.ckdb"
