#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
require_v2_stage 3 "subtree waiting and explicit resume"

new_test_loom
"$LOOM" new goal >/dev/null
"$LOOM" new parked goal >/dev/null
"$LOOM" new parked-leaf parked >/dev/null
"$LOOM" new sibling goal >/dev/null

"$LOOM" wait parked >/dev/null
assert_dir "$TEST_REPO/.loom/threads/goal/parked.waiting"
assert_eq "goal/sibling" "$("$LOOM" loose-ends)" \
  "inherited waiting must hide descendants"
assert_eq "goal/sibling" "$("$LOOM" next)" \
  "a ready sibling must remain next"
assert_fails_with "resume parked" "$LOOM" claim parked
assert_fails_with "resume parked" "$LOOM" claim parked-leaf
status_output="$("$LOOM" status)"
assert_contains "$status_output" "parked.waiting (waiting)" \
  "status waiting branch"
assert_contains "$status_output" "parked-leaf (waiting inherited)" \
  "status inherited waiting"

"$LOOM" wait parked-leaf >/dev/null
assert_fails_with "resume parked-leaf" "$LOOM" claim parked-leaf
"$LOOM" resume parked >/dev/null
assert_dir "$TEST_REPO/.loom/threads/goal/parked/parked-leaf.waiting"
assert_eq "goal/parked/parked-leaf.waiting" "$("$LOOM" waiting)" \
  "resume must preserve explicitly waiting descendants"
"$LOOM" resume parked-leaf >/dev/null
assert_fails_with "not directly waiting" "$LOOM" resume parked-leaf
"$LOOM" claim parked-leaf >/dev/null

assert_fails_with "parked-leaf" "$LOOM" wait goal
assert_dir "$TEST_REPO/.loom/threads/goal"
assert_dir "$TEST_REPO/.loom/threads/goal/parked/parked-leaf.stitching"

"$LOOM" tie parked-leaf >/dev/null
"$LOOM" new steward-child parked >/dev/null
"$LOOM" tend parked >/dev/null
"$LOOM" wait parked >/dev/null
assert_dir "$TEST_REPO/.loom/threads/goal/parked.waiting"
assert_no_path "$TEST_REPO/.loom/threads/goal/parked.tending"

"$LOOM" new added-while-parked parked >/dev/null
assert_dir "$TEST_REPO/.loom/threads/goal/parked.waiting/added-while-parked"
assert_eq "goal/parked.waiting" "$("$LOOM" waiting)" \
  "adding a child must not resume its waiting parent"

new_test_loom
"$LOOM" new whole-goal >/dev/null
"$LOOM" wait whole-goal >/dev/null
assert_eq "whole-goal.waiting" "$("$LOOM" waiting)"
"$LOOM" resume whole-goal >/dev/null
assert_eq "whole-goal" "$("$LOOM" loose-ends)"

new_test_loom
"$LOOM" new conflict >/dev/null
"$LOOM" new claimed-a conflict >/dev/null
"$LOOM" new claimed-b conflict >/dev/null
"$LOOM" claim claimed-a >/dev/null
"$LOOM" claim claimed-b >/dev/null
conflict_output="$("$LOOM" wait conflict 2>&1)" &&
  fail "waiting a branch with claimed descendants must fail"
assert_contains "$conflict_output" "claimed-a" "first wait conflict"
assert_contains "$conflict_output" "claimed-b" "second wait conflict"
assert_dir "$TEST_REPO/.loom/threads/conflict"

echo "v2 subtree waiting: ok"
