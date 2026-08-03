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
"$LOOM" new stopped-branch goal >/dev/null
"$LOOM" new unfinished stopped-branch >/dev/null

mkdir -p "$TEST_REPO/.loom/threads/goal/notes/example-payloads/deep"
printf '# not-a-stitch\n' > \
  "$TEST_REPO/.loom/threads/goal/notes/example-payloads/deep/instructions.md"
mkdir -p "$TEST_REPO/.loom/threads/goal/kept/fixtures"
printf 'artifact\n' > \
  "$TEST_REPO/.loom/threads/goal/kept/fixtures/payload.txt"

assert_eq \
  $'goal/kept/nested\ngoal/omitted\ngoal/stopped-branch/unfinished' \
  "$("$LOOM" loose-ends)" \
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

drop_hint="$("$LOOM" drop stopped-branch)"
assert_contains "$drop_hint" "stopped-branch.dropped/reason.md" \
  "reason scaffold edit hint"
assert_dir "$TEST_REPO/.loom/threads/goal/stopped-branch.dropped/unfinished"
assert_no_path \
  "$TEST_REPO/.loom/threads/goal/stopped-branch.dropped/unfinished/completed-at"
assert_file "$TEST_REPO/.loom/threads/goal/stopped-branch.dropped/reason.md"
assert_eq "goal" "$("$LOOM" loose-ends)" "terminal children resolve parent"
status_output="$("$LOOM" status)"
assert_contains "$status_output" "kept.tied (tied)" "tied child status"
assert_contains "$status_output" "omitted.dropped (dropped)" "dropped child status"
assert_contains "$status_output" "unfinished (abandoned)" \
  "unfinished descendant status"
assert_not_contains "$("$LOOM" waiting)" "omitted" \
  "terminal child listed as waiting"

"$LOOM" tie goal >/dev/null
assert_dir "$TEST_REPO/.loom/tied/goal"
assert_dir "$TEST_REPO/.loom/tied/goal/kept.tied"
assert_dir "$TEST_REPO/.loom/tied/goal/omitted.dropped"
assert_file "$TEST_REPO/.loom/tied/goal/notes/example-payloads/deep/instructions.md"
assert_file "$TEST_REPO/.loom/tied/goal/completed-at"
assert_iso8601_seconds "$(<"$TEST_REPO/.loom/tied/goal/completed-at")"

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
# Sweeping the last archive must not leave an untrackable empty tray behind.
assert_file "$TEST_REPO/.loom/tied/.gitkeep"
assert_file "$TEST_REPO/.loom/dropped/.gitkeep"

# init seeds both trays so a loom committed before its first tie or drop keeps
# them through a clone. The seed is a plain file, so it is not a tray entry.
new_test_loom
assert_file "$TEST_REPO/.loom/tied/.gitkeep"
assert_file "$TEST_REPO/.loom/dropped/.gitkeep"
assert_contains "$("$LOOM" status)" "✅ tied: 0" "seeded tray count"
assert_contains "$("$LOOM" status)" "🗑️  dropped: 0" "seeded tray count"
assert_not_contains "$("$LOOM" status)" "missing archive trays" "seeded loom"

# A loom cloned without its trays heals on the next tie instead of failing the
# terminal move with completed-at already written.
new_test_loom
"$LOOM" new cloned-goal >/dev/null
rm -rf "$TEST_REPO/.loom/tied" "$TEST_REPO/.loom/dropped"
"$LOOM" tie cloned-goal >/dev/null
assert_dir "$TEST_REPO/.loom/tied/cloned-goal"
assert_file "$TEST_REPO/.loom/tied/cloned-goal/completed-at"
assert_no_path "$TEST_REPO/.loom/threads/cloned-goal"
assert_file "$TEST_REPO/.loom/dropped/.gitkeep"

# Same for drop, which is the path a migrated loom is most likely to hit first.
new_test_loom
"$LOOM" new cloned-drop >/dev/null
rm -rf "$TEST_REPO/.loom/tied" "$TEST_REPO/.loom/dropped"
"$LOOM" drop cloned-drop "no longer wanted" >/dev/null
assert_dir "$TEST_REPO/.loom/dropped/cloned-drop"
assert_file "$TEST_REPO/.loom/dropped/cloned-drop/reason.md"
assert_file "$TEST_REPO/.loom/dropped/cloned-drop/completed-at"
assert_no_path "$TEST_REPO/.loom/threads/cloned-drop"
assert_file "$TEST_REPO/.loom/tied/.gitkeep"

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
