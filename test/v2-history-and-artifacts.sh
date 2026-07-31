#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
require_v2_stage 2 "history, artifacts, and stitch recognition"

new_test_loom
assert_eq "2" "$(<"$TEST_REPO/.loom/format-version")" "format marker"

"$LOOM" new goal >/dev/null
"$LOOM" new kept goal >/dev/null
"$LOOM" new nested kept >/dev/null
"$LOOM" new omitted goal >/dev/null

mkdir -p "$TEST_REPO/.loom/threads/goal/notes/example-payloads/deep"
printf '# not-a-stitch\n' > \
  "$TEST_REPO/.loom/threads/goal/notes/example-payloads/deep/instructions.md"
mkdir -p "$TEST_REPO/.loom/threads/goal/kept/fixtures"
printf 'artifact\n' > \
  "$TEST_REPO/.loom/threads/goal/kept/fixtures/payload.txt"

assert_eq $'goal/kept/nested\ngoal/omitted' "$("$LOOM" loose-ends)" \
  "support directories must be opaque"

"$LOOM" tie nested >/dev/null
"$LOOM" claim kept >/dev/null
"$LOOM" tie kept >/dev/null
assert_dir "$TEST_REPO/.loom/threads/goal/kept.tied"
assert_dir "$TEST_REPO/.loom/threads/goal/kept.tied/nested.tied"
assert_file "$TEST_REPO/.loom/threads/goal/kept.tied/completed-at"
assert_iso8601_seconds "$(<"$TEST_REPO/.loom/threads/goal/kept.tied/completed-at")"
assert_file "$TEST_REPO/.loom/threads/goal/kept.tied/fixtures/payload.txt"

"$LOOM" drop omitted "not required" >/dev/null
assert_dir "$TEST_REPO/.loom/threads/goal/omitted.dropped"
assert_file "$TEST_REPO/.loom/threads/goal/omitted.dropped/reason.md"
assert_contains \
  "$(<"$TEST_REPO/.loom/threads/goal/omitted.dropped/reason.md")" \
  "not required" "in-stitch drop reason"
assert_eq "goal" "$("$LOOM" loose-ends)" "terminal children resolve parent"

"$LOOM" tie goal >/dev/null
assert_dir "$TEST_REPO/.loom/tied/goal"
assert_dir "$TEST_REPO/.loom/tied/goal/kept.tied"
assert_dir "$TEST_REPO/.loom/tied/goal/omitted.dropped"
assert_file "$TEST_REPO/.loom/tied/goal/notes/example-payloads/deep/instructions.md"

new_test_loom
"$LOOM" new abandoned >/dev/null
"$LOOM" new unfinished abandoned >/dev/null
assert_fails_with "unresolved" "$LOOM" tie abandoned
"$LOOM" drop abandoned "whole goal stopped" >/dev/null
assert_dir "$TEST_REPO/.loom/dropped/abandoned/unfinished"
assert_no_path "$TEST_REPO/.loom/dropped/abandoned/unfinished/completed-at"
assert_file "$TEST_REPO/.loom/dropped/abandoned/completed-at"
assert_file "$TEST_REPO/.loom/dropped/abandoned/reason.md"

new_test_loom
"$LOOM" new active >/dev/null
"$LOOM" new old-child active >/dev/null
"$LOOM" tie old-child >/dev/null
touch -t 200001010000 \
  "$TEST_REPO/.loom/threads/active/old-child.tied" \
  "$TEST_REPO/.loom/threads/active/old-child.tied/completed-at"
"$LOOM" sweep 0 >/dev/null
assert_dir "$TEST_REPO/.loom/threads/active/old-child.tied"

new_test_loom
"$LOOM" new archived-old >/dev/null
"$LOOM" tie archived-old >/dev/null
touch -t 200001010000 \
  "$TEST_REPO/.loom/tied/archived-old" \
  "$TEST_REPO/.loom/tied/archived-old/completed-at"
"$LOOM" sweep 0 >/dev/null
assert_no_path "$TEST_REPO/.loom/tied/archived-old"

new_test_loom
write_instructions "$TEST_REPO/.loom/threads/identity" identity
mkdir -p "$TEST_REPO/.loom/threads/identity/notes/identity/deeper"
printf '# opaque duplicate name\n' > \
  "$TEST_REPO/.loom/threads/identity/notes/identity/deeper/instructions.md"
"$LOOM" status >/dev/null

write_instructions "$TEST_REPO/.loom/threads/duplicate" duplicate
write_instructions "$TEST_REPO/.loom/threads/identity/duplicate" duplicate
assert_fails_with "duplicate" "$LOOM" status

echo "v2 history and artifacts: ok"
