#!/bin/bash
# Licensed under GPL-3.0. See LICENSE.
#
# Runs scripts/cloudkit/check-production-schema.sh --compare against made-up production exports:
# one lacking fields and a record type schema.ckdb declares fails and names them, one with all
# of them, in a different layout and with extra fields, passes. No token, nothing reaches CloudKit.
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
check=scripts/cloudkit/check-production-schema.sh

cp scripts/cloudkit/schema.ckdb "$test_dir/complete.ckdb"
cat >> "$test_dir/complete.ckdb" <<'SHARE'
    RECORD TYPE "cloudkit.share" (
        "cloudkit.title" STRING,
        GRANT CREATE TO "_icloud"
    );
SHARE

if "$check" --compare scripts/cloudkit/schema.ckdb > "$test_dir/out" 2>&1; then
  echo "FAIL: the app schema alone passed without Apple's share type"
  exit 1
fi
grep -Fxq '  cloudkit.share' "$test_dir/out"

sed '/"cloudkit.title" STRING/d' "$test_dir/complete.ckdb" > "$test_dir/no-share-title.ckdb"
if "$check" --compare "$test_dir/no-share-title.ckdb" > "$test_dir/out" 2>&1; then
  echo "FAIL: a share type without a title passed"
  exit 1
fi
grep -Fxq '  cloudkit.share.cloudkit.title' "$test_dir/out"

sed 's/"cloudkit.title" STRING/"cloudkit.title" BYTES/' "$test_dir/complete.ckdb" > "$test_dir/wrong-share-title.ckdb"
if "$check" --compare "$test_dir/wrong-share-title.ckdb" > "$test_dir/out" 2>&1; then
  echo "FAIL: a share title with the wrong type passed"
  exit 1
fi
grep -Fxq '  cloudkit.share.cloudkit.title: expected STRING, found BYTES' "$test_dir/out"

grep -v '"device"\|"movedTo"' scripts/cloudkit/schema.ckdb | awk '/RECORD TYPE Item/ { skip = 1 } !skip { print } skip && /\);/ { skip = 0 }' \
  > "$test_dir/behind.ckdb"
status=0
"$check" --compare "$test_dir/behind.ckdb" > "$test_dir/out" 2>&1 || status=$?
[[ "$status" == 1 ]] || { echo "FAIL: a production schema without new fields passed: $(<"$test_dir/out")"; exit 1; }
for missing in Space.device Space.movedTo Item; do
  grep -qx "  $missing" "$test_dir/out" || { echo "FAIL: $missing not named: $(<"$test_dir/out")"; exit 1; }
done
if grep -q "  Space.name" "$test_dir/out"; then echo "FAIL: a field production has was named: $(<"$test_dir/out")"; exit 1; fi

sed -e 's/"\([A-Za-z_]*\)"/\1/' -e 's/^    RECORD TYPE \(.*\) ($/RECORD TYPE \1(/' "$test_dir/complete.ckdb" \
  | sed '/^[[:space:]]*level[[:space:]]/a\
        "extra"         STRING,' > "$test_dir/ahead.ckdb"
grep -q '"extra"' "$test_dir/ahead.ckdb"
"$check" --compare "$test_dir/ahead.ckdb" > "$test_dir/out" 2>&1 || { echo "FAIL: a production schema with every field failed: $(<"$test_dir/out")"; exit 1; }

sed -e 's/"___recordID"   REFERENCE QUERYABLE/"___recordID"   REFERENCE/' \
    -e 's/"name"          ENCRYPTED STRING/"name"          STRING/' \
    -e 's/"url"           ENCRYPTED STRING/"url"           ENCRYPTED BYTES/' \
    -e 's/GRANT CREATE TO "_icloud"/GRANT CREATE TO "_creator"/' \
    scripts/cloudkit/schema.ckdb > "$test_dir/incompatible.ckdb"
status=0
"$check" --compare "$test_dir/incompatible.ckdb" > "$test_dir/out" 2>&1 || status=$?
[[ "$status" == 1 ]]
for diagnostic in 'Space.name: expected ENCRYPTED STRING, found STRING' \
  'Item.url: expected ENCRYPTED STRING, found ENCRYPTED BYTES' \
  'Space.___recordID: missing QUERYABLE' 'Item: missing GRANT CREATE TO "_icloud"' \
  'Item: unexpected GRANT CREATE TO "_creator"'; do
  grep -Fxq "  $diagnostic" "$test_dir/out" || { echo "FAIL: missing $diagnostic"; cat "$test_dir/out"; exit 1; }
done

# Simulate saved, environment and file-backed credentials with no actual token.
# No argument may contain either token, and no operation may target Nook.
cat > "$test_dir/xcrun" <<'MOCK'
#!/bin/bash
set -eu
printf '%s\n' "$@" > "$CLOUDKIT_FIXTURE/arguments"
printf '%s\n' "${CLOUDKIT_MANAGEMENT_TOKEN-<saved>}" > "$CLOUDKIT_FIXTURE/token"
if [[ "$2" == export-schema ]]; then
  cp "$CLOUDKIT_FIXTURE/complete.ckdb" "${!#}"
fi
MOCK
chmod +x "$test_dir/xcrun"
export CLOUDKIT_FIXTURE="$test_dir"
export PATH="$test_dir:$PATH"
unset CLOUDKIT_MANAGEMENT_TOKEN
"$check" > "$test_dir/out"
grep -Fxq 'export-schema' "$test_dir/arguments"
grep -Fxq 'iCloud.ee.qdo.bark' "$test_dir/arguments"
grep -Fxq '<saved>' "$test_dir/token"

scripts/cloudkit/import-schema.sh > "$test_dir/out"
grep -Fxq 'import-schema' "$test_dir/arguments"
grep -Fxq -- '--validate' "$test_dir/arguments"
grep -Fxq 'development' "$test_dir/arguments"
grep -Fxq 'iCloud.ee.qdo.bark' "$test_dir/arguments"
grep -Fxq '<saved>' "$test_dir/token"

CLOUDKIT_MANAGEMENT_TOKEN=fixture-env-token scripts/cloudkit/import-schema.sh --validate-only > "$test_dir/out"
grep -Fxq 'validate-schema' "$test_dir/arguments"
if grep -Fxq 'import-schema' "$test_dir/arguments"; then exit 1; fi
grep -Fxq 'fixture-env-token' "$test_dir/token"
if grep -Fq 'fixture-env-token' "$test_dir/arguments"; then exit 1; fi

printf 'fixture-file-token\n' > "$test_dir/token-file"
"$check" "$test_dir/token-file" > "$test_dir/out"
grep -Fxq 'export-schema' "$test_dir/arguments"
grep -Fxq 'production' "$test_dir/arguments"
grep -Fxq 'iCloud.ee.qdo.bark' "$test_dir/arguments"
grep -Fxq 'fixture-file-token' "$test_dir/token"
if grep -Fq 'fixture-file-token' "$test_dir/arguments"; then exit 1; fi
echo "PASS: production schema check and Bark-only cktool routing"
