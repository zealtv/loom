#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
require_v2_stage 4 "dependency engine and unified readiness"

need() {
  local dependent="$1"
  local target="$2"
  local dir
  dir="$(find "$TEST_REPO/.loom" -type d \
    \( -name "$dependent" -o -name "$dependent.stitching" \
       -o -name "$dependent.waiting" -o -name "$dependent.tending" \
       -o -name "$dependent.tied" -o -name "$dependent.dropped" \) \
    -print -quit)"
  [[ -n "$dir" ]] || fail "dependent not found: $dependent"
  mkdir -p "$dir/needs"
  : > "$dir/needs/$target"
}

new_test_loom
for id in source left right join; do
  "$LOOM" new "$id" >/dev/null
done
need left source
need right source
need join left
need join right

assert_eq "source" "$("$LOOM" next)" "fan-out targets start blocked"
"$LOOM" tie source >/dev/null
assert_eq $'left\nright' "$("$LOOM" loose-ends)" \
  "tied archived goal must satisfy dependencies"
"$LOOM" tie left >/dev/null
assert_eq "right" "$("$LOOM" next)"
"$LOOM" tie right >/dev/null
assert_eq "join" "$("$LOOM" next)" "diamond fan-in"

new_test_loom
"$LOOM" new prerequisite >/dev/null
"$LOOM" new dependent >/dev/null
need dependent prerequisite
blocked_status="$("$LOOM" status)"
assert_contains "$blocked_status" "blocked dependencies" \
  "ordinary unresolved dependencies are visible"
assert_contains "$blocked_status" "dependent -> prerequisite" \
  "blocked edge names both endpoints"
assert_eq "prerequisite" "$("$LOOM" next)"
assert_fails_with "dependency" "$LOOM" claim dependent
assert_fails_with "dependency" "$LOOM" tie dependent
"$LOOM" wait prerequisite >/dev/null
assert_eq "" "$("$LOOM" loose-ends)" "waiting dependency targets block"
"$LOOM" resume prerequisite >/dev/null
"$LOOM" claim prerequisite >/dev/null
assert_eq "" "$("$LOOM" loose-ends)" "claimed dependency targets block"
"$LOOM" tie prerequisite >/dev/null
assert_eq "dependent" "$("$LOOM" next)"

new_test_loom
"$LOOM" new goal-a >/dev/null
"$LOOM" new child-a goal-a >/dev/null
"$LOOM" new goal-b >/dev/null
need goal-b child-a
"$LOOM" tie child-a >/dev/null
assert_eq $'goal-a\ngoal-b' "$("$LOOM" loose-ends)" \
  "retained tied child must satisfy cross-thread dependency"
"$LOOM" tie goal-a >/dev/null
assert_eq "goal-b" "$("$LOOM" next)" \
  "tied child retained in an archived goal remains satisfying"

new_test_loom
"$LOOM" new archived-drop >/dev/null
"$LOOM" new retained-tied archived-drop >/dev/null
"$LOOM" new unfinished archived-drop >/dev/null
"$LOOM" tie retained-tied >/dev/null
"$LOOM" drop archived-drop no-longer-needed >/dev/null
"$LOOM" new retained-user >/dev/null
need retained-user retained-tied
assert_eq "retained-user" "$("$LOOM" next)" \
  "tied child retained in a dropped archive remains satisfying"

new_test_loom
"$LOOM" new missing-user >/dev/null
need missing-user does-not-exist
assert_fails_with "missing-user" "$LOOM" status
assert_fails_with "does-not-exist" "$LOOM" status
assert_fails_with "missing" "$LOOM" status

"$LOOM" new dropped-target >/dev/null
"$LOOM" drop dropped-target abandoned >/dev/null
"$LOOM" new dropped-user >/dev/null
need dropped-user dropped-target
assert_fails_with "dropped" "$LOOM" status

new_test_loom
for id in self a b c x y; do
  "$LOOM" new "$id" >/dev/null
done
need self self
need a b
need b c
need c a
need x y
need y x
cycle_status="$("$LOOM" status 2>&1)" && fail "cycles must make status fail"
assert_contains "$cycle_status" "a" "three-node cycle"
assert_contains "$cycle_status" "b" "three-node cycle"
assert_contains "$cycle_status" "c" "three-node cycle"
assert_contains "$cycle_status" "x" "independent cycle"
assert_contains "$cycle_status" "y" "independent cycle"
assert_contains "$cycle_status" "self" "self dependency"
assert_eq "1" "$(grep -c -- '^- a, b, c$' <<< "$cycle_status")" \
  "one deterministic report for a three-node cycle"
assert_eq "1" "$(grep -c -- '^- x, y$' <<< "$cycle_status")" \
  "one deterministic report for an independent cycle"
assert_eq "" "$("$LOOM" loose-ends)" "cycle members are never ready"
assert_fails_with "dependency" "$LOOM" claim a
assert_fails_with "dependency" "$LOOM" tie a

new_test_loom
"$LOOM" new opaque >/dev/null
mkdir -p "$TEST_REPO/.loom/threads/opaque/needs/deeper"
printf '# hidden\n' > \
  "$TEST_REPO/.loom/threads/opaque/needs/deeper/instructions.md"
: > "$TEST_REPO/.loom/threads/opaque/needs/bad-target"
assert_fails_with "missing" "$LOOM" status
assert_not_contains "$("$LOOM" status 2>&1 || true)" "deeper" \
  "needs descendants are not stitches"

new_test_loom
"$LOOM" new malformed >/dev/null
mkdir -p "$TEST_REPO/.loom/threads/malformed/needs"
: > "$TEST_REPO/.loom/threads/malformed/needs/invalid.waiting"
assert_fails_with "invalid target id" "$LOOM" status
rm "$TEST_REPO/.loom/threads/malformed/needs/invalid.waiting"
ln -s nowhere "$TEST_REPO/.loom/threads/malformed/needs/link-target"
assert_fails_with "regular file" "$LOOM" status
rm "$TEST_REPO/.loom/threads/malformed/needs/link-target"
rm -r "$TEST_REPO/.loom/threads/malformed/needs"
: > "$TEST_REPO/.loom/threads/malformed/needs"
assert_fails_with "needs must be a directory" "$LOOM" status

new_test_loom
"$LOOM" new waiting-root >/dev/null
"$LOOM" new dependent waiting-root >/dev/null
"$LOOM" new prerequisite >/dev/null
need dependent prerequisite
"$LOOM" tie prerequisite >/dev/null
"$LOOM" wait waiting-root >/dev/null
assert_eq "" "$("$LOOM" loose-ends)" \
  "satisfied needs cannot override inherited waiting"

new_test_loom
"$LOOM" new dependent >/dev/null
need dependent duplicate-target
write_instructions "$TEST_REPO/.loom/threads/duplicate-target" duplicate-target
write_instructions \
  "$TEST_REPO/.loom/threads/dependent/duplicate-target" duplicate-target
assert_fails_with "ambiguous" "$LOOM" status

# Dependency mutations own needs/ writes, are idempotent, and refuse cycles.
new_test_loom
for id in a b c completed discarded; do
  "$LOOM" new "$id" >/dev/null
done
"$LOOM" tie completed >/dev/null
"$LOOM" drop discarded unused >/dev/null

assert_eq "anchored a -> b" "$("$LOOM" anchor a b)" "anchor prose"
assert_file "$TEST_REPO/.loom/threads/a/needs/b"
edge_before="$(cksum < "$TEST_REPO/.loom/threads/a/needs/b")"
assert_eq "already anchored a -> b" "$("$LOOM" anchor a b)" \
  "repeated anchor is a no-op"
assert_eq "$edge_before" "$(cksum < "$TEST_REPO/.loom/threads/a/needs/b")" \
  "repeated anchor preserves the edge"

"$LOOM" anchor b c >/dev/null
assert_fails_with "dependency cycle" "$LOOM" anchor c a
assert_no_path "$TEST_REPO/.loom/threads/c/needs"
assert_fails_with "itself" "$LOOM" anchor c c
assert_fails_with "not found" "$LOOM" anchor c missing
assert_no_path "$TEST_REPO/.loom/threads/c/needs"
assert_fails_with "dropped" "$LOOM" anchor c discarded
assert_no_path "$TEST_REPO/.loom/threads/c/needs"

"$LOOM" anchor c completed >/dev/null
assert_file "$TEST_REPO/.loom/threads/c/needs/completed"
"$LOOM" unanchor c completed >/dev/null
assert_no_path "$TEST_REPO/.loom/threads/c/needs"
assert_eq "already unanchored c -> completed" \
  "$("$LOOM" unanchor c completed)" "repeated unanchor is a no-op"

mkdir -p "$TEST_REPO/.loom/threads/c/needs"
: > "$TEST_REPO/.loom/threads/c/needs/vanished"
"$LOOM" unanchor c vanished >/dev/null
assert_no_path "$TEST_REPO/.loom/threads/c/needs"

if LOOM_TEST_FAIL_ANCHOR_WRITE=before-rename \
  "$LOOM" anchor c completed >/dev/null 2>&1; then
  fail "injected anchor write failure must fail"
fi
assert_no_path "$TEST_REPO/.loom/threads/c/needs"

echo "v2 dependencies: ok"
