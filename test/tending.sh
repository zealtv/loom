#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

new_test_loom
"$LOOM" new parent >/dev/null
"$LOOM" new child-a parent >/dev/null
"$LOOM" tend parent >/dev/null

[[ -d "$TEST_REPO/.loom/threads/parent.tending" ]] || fail "tend did not add .tending"
assert_eq "parent.tending" "$("$LOOM" tending)"
status_output="$("$LOOM" status)"
grep -q -- "- parent.tending" <<<"$status_output" || fail "status did not show tended parent"
assert_fails_with "has no children" "$LOOM" tend child-a
assert_fails_with "tended" "$LOOM" claim parent
assert_eq "parent.tending/child-a" "$("$LOOM" loose-ends)"
assert_eq "parent.tending/child-a" "$("$LOOM" next)"

"$LOOM" new child-b parent >/dev/null
[[ -d "$TEST_REPO/.loom/threads/parent.tending/child-b" ]] || fail "new child did not preserve .tending"
"$LOOM" claim child-a >/dev/null
"$LOOM" wait child-b >/dev/null
assert_fails_with "tended" "$LOOM" claim parent
"$LOOM" tie child-a >/dev/null
"$LOOM" drop child-b test >/dev/null

assert_fails_with "tended" "$LOOM" claim parent
"$LOOM" release parent >/dev/null
[[ -d "$TEST_REPO/.loom/threads/parent" ]] || fail "release did not remove .tending"
"$LOOM" claim parent >/dev/null
"$LOOM" tie parent >/dev/null
[[ -d "$TEST_REPO/.loom/tied/parent" ]] || fail "tie did not strip state suffix"

"$LOOM" new tied-parent >/dev/null
"$LOOM" new tied-child tied-parent >/dev/null
"$LOOM" tend tied-parent >/dev/null
"$LOOM" tie tied-child >/dev/null
"$LOOM" tie tied-parent >/dev/null
[[ -d "$TEST_REPO/.loom/tied/tied-parent" ]] || fail "tie did not strip .tending"

"$LOOM" new dropped-parent >/dev/null
"$LOOM" new dropped-child dropped-parent >/dev/null
"$LOOM" tend dropped-parent >/dev/null
"$LOOM" drop dropped-parent test >/dev/null
[[ -d "$TEST_REPO/.loom/dropped/dropped-parent" ]] || fail "drop did not strip .tending"

echo "tending lifecycle: ok"
