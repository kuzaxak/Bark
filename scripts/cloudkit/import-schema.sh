#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Import the tracked schema into Bark development. Deploy to production
# separately in CloudKit Console. --validate-only makes no schema changes.
# Without a token file, cktool uses CLOUDKIT_MANAGEMENT_TOKEN or its saved token.
set -euo pipefail

usage="usage: scripts/cloudkit/import-schema.sh [--validate-only] [management-token-file]"
operation=(import-schema --validate)
message="Imported schema.ckdb into Bark development. Deploy it to production in CloudKit Console."
if [[ "${1:-}" == --validate-only ]]; then
  operation=(validate-schema)
  message="Validated schema.ckdb against Bark development."
  shift
fi
[[ $# -le 1 && "${1:-}" != --* ]] || { echo "$usage" >&2; exit 2; }
if [[ $# == 1 ]]; then
  [[ -s "$1" ]] || { echo "No such file, or it is empty: $1" >&2; exit 2; }
  CLOUDKIT_MANAGEMENT_TOKEN="$(tr -d '[:space:]' < "$1")"
  [[ -n "$CLOUDKIT_MANAGEMENT_TOKEN" ]] || { echo "Management token is empty" >&2; exit 2; }
  export CLOUDKIT_MANAGEMENT_TOKEN
fi

schema="$(cd "$(dirname "$0")" && pwd)/schema.ckdb"
xcrun cktool "${operation[@]}" --team-id 538SB59LX4 --container-id iCloud.ee.qdo.bark \
  --environment development --file "$schema"
echo "$message"
