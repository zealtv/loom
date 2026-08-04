#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
require_v2_stage 5 "sparse preference queue"

queue_ids() {
  grep -v -e '^$' -e '^#' "$TEST_REPO/.loom/queue" 2>/dev/null || true
}

new_test_loom
for id in alpha beta gamma delta; do
  "$LOOM" new "$id" >/dev/null
done

"$LOOM" queue beta >/dev/null
"$LOOM" queue gamma >/dev/null
"$LOOM" first alpha >/dev/null
assert_eq $'alpha\nbeta\ngamma' "$(queue_ids)" "first and append order"

"$LOOM" before delta beta >/dev/null
assert_eq $'alpha\ndelta\nbeta\ngamma' "$(queue_ids)" \
  "before uses moved ID then anchor"
"$LOOM" after alpha gamma >/dev/null
assert_eq $'delta\nbeta\ngamma\nalpha' "$(queue_ids)" \
  "after repositions an existing ID"
"$LOOM" queue beta >/dev/null
"$LOOM" queue beta >/dev/null
assert_eq $'delta\ngamma\nalpha\nbeta' "$(queue_ids)" \
  "queue is idempotent and moves to end"
"$LOOM" unqueue beta >/dev/null
"$LOOM" unqueue beta >/dev/null
assert_eq $'delta\ngamma\nalpha' "$(queue_ids)" "unqueue is idempotent"

"$LOOM" wait delta >/dev/null
"$LOOM" claim gamma >/dev/null
assert_eq "alpha" "$("$LOOM" next)" \
  "waiting and claimed queue heads must be skipped"
assert_eq $'alpha\nbeta' "$("$LOOM" loose-ends)" \
  "loose-ends uses queue preference then deterministic fallback"
status_output="$("$LOOM" status)"
assert_contains "$status_output" "- 1. delta (waiting)" \
  "status shows queue position and waiting state"
assert_contains "$status_output" "- 2. gamma (claimed)" \
  "status shows claimed queue entries"
assert_contains "$status_output" "- 3. alpha (ready)" \
  "status shows ready queue entries"

"$LOOM" new prerequisite >/dev/null
mkdir -p "$TEST_REPO/.loom/threads/alpha/needs"
: > "$TEST_REPO/.loom/threads/alpha/needs/prerequisite"
"$LOOM" claim beta >/dev/null
assert_eq "prerequisite" "$("$LOOM" next)" \
  "dependencies override queue and fallback is deterministic"
warning_status="$("$LOOM" status)"
assert_contains "$warning_status" "alpha is queued but its unsatisfied dependency prerequisite is not queued" \
  "status warns when a queued stitch depends on unqueued work"
"$LOOM" queue prerequisite >/dev/null
"$LOOM" after prerequisite alpha >/dev/null
warning_status="$("$LOOM" status)"
assert_contains "$warning_status" "alpha is queued before its unsatisfied dependency prerequisite" \
  "status warns when queue order contradicts a dependency"
"$LOOM" first prerequisite >/dev/null
assert_not_contains "$("$LOOM" status)" "queue dependency warnings" \
  "a dependency queued first does not warn"

printf '# keep this comment\nalpha\nalpha\nunknown\n' > \
  "$TEST_REPO/.loom/queue"
queue_before="$(cksum < "$TEST_REPO/.loom/queue")"
assert_fails_with "duplicate" "$LOOM" status
assert_fails_with "unknown" "$LOOM" status
assert_fails_with "unknown" "$LOOM" first prerequisite
assert_eq "$queue_before" "$(cksum < "$TEST_REPO/.loom/queue")" \
  "failed queue mutation must preserve bytes"
"$LOOM" unqueue unknown >/dev/null
assert_eq "alpha" "$(queue_ids)" \
  "unqueue repairs a stale ID and de-duplicates retained entries"

printf 'alpha\nbad id\n' > "$TEST_REPO/.loom/queue"
assert_fails_with "invalid" "$LOOM" status
"$LOOM" unqueue "bad id" >/dev/null 2>&1 &&
  fail "unqueue must still require syntactically valid IDs"

printf 'alpha\nprerequisite\n' > "$TEST_REPO/.loom/queue"
"$LOOM" tie prerequisite >/dev/null
assert_not_contains "$(queue_ids)" "prerequisite" \
  "terminal operations clean queue entries"

printf 'alpha\ncompleted\n' > "$TEST_REPO/.loom/queue"
write_instructions "$TEST_REPO/.loom/tied/completed" completed
assert_fails_with "terminal" "$LOOM" status

printf 'alpha\n' > "$TEST_REPO/.loom/queue"
queue_before="$(cksum < "$TEST_REPO/.loom/queue")"
if LOOM_TEST_FAIL_QUEUE_WRITE=before-rename \
  "$LOOM" queue delta >/dev/null 2>&1; then
  fail "injected queue write failure must fail"
fi
assert_eq "$queue_before" "$(cksum < "$TEST_REPO/.loom/queue")" \
  "injected atomic write failure changed queue bytes"

new_test_loom
for id in alpha beta gamma; do
  "$LOOM" new "$id" >/dev/null
done
printf '# first comment\n\nalpha\n# second comment\n' > "$TEST_REPO/.loom/queue"
"$LOOM" before beta alpha >/dev/null
assert_eq $'# first comment\n\n# second comment' \
  "$(grep -e '^$' -e '^#' "$TEST_REPO/.loom/queue")" \
  "queue mutations preserve blank/comment record order and bytes"
assert_eq $'beta\nalpha' "$(queue_ids)" \
  "before positions the moved ID without renaming stitches"
assert_dir "$TEST_REPO/.loom/threads/alpha"
assert_dir "$TEST_REPO/.loom/threads/beta"

"$LOOM" new parent >/dev/null
"$LOOM" new child parent >/dev/null
"$LOOM" queue parent >/dev/null
"$LOOM" queue child >/dev/null
"$LOOM" drop parent "no longer needed" >/dev/null
assert_not_contains "$(queue_ids)" "parent" \
  "archiving a goal cleans its root queue entry"
assert_not_contains "$(queue_ids)" "child" \
  "archiving a goal cleans descendant queue entries"

new_test_loom
for id in alpha beta gamma delta; do
  "$LOOM" new "$id" >/dev/null
done
pids=()
for id in alpha beta gamma delta; do
  "$LOOM" queue "$id" >/dev/null &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
done
assert_eq $'alpha\nbeta\ndelta\ngamma' "$(queue_ids | sort)" \
  "concurrent queue mutations retain every update exactly once"

new_test_loom
for id in alpha beta gamma delta; do
  "$LOOM" new "$id" >/dev/null
done
printf '# first\nalpha\n\n# second\nbeta\n' > "$TEST_REPO/.loom/queue"
"$LOOM" queue --set gamma gamma alpha delta >/dev/null
assert_eq $'gamma\nalpha\ndelta' "$(queue_ids)" \
  "queue --set replaces the effective order and retains first duplicates"
assert_eq $'# first\n\n# second' \
  "$(grep -e '^$' -e '^#' "$TEST_REPO/.loom/queue")" \
  "queue --set preserves comments and blanks in relative order"

queue_before="$(cksum < "$TEST_REPO/.loom/queue")"
queue_mtime_before="$(stat -c %Y "$TEST_REPO/.loom/queue")"
"$LOOM" queue --set gamma alpha delta >/dev/null
assert_eq "$queue_before" "$(cksum < "$TEST_REPO/.loom/queue")" \
  "repeating queue --set preserves bytes"
assert_eq "$queue_mtime_before" "$(stat -c %Y "$TEST_REPO/.loom/queue")" \
  "repeating queue --set is a filesystem no-op"
"$LOOM" queue --set >/dev/null
assert_eq "" "$(queue_ids)" "queue --set with no IDs clears the queue"

printf 'gamma\nghost\n' > "$TEST_REPO/.loom/queue"
queue_before="$(cksum < "$TEST_REPO/.loom/queue")"
assert_fails_with "unknown entry" "$LOOM" queue --set alpha beta
assert_eq "$queue_before" "$(cksum < "$TEST_REPO/.loom/queue")" \
  "invalid existing records fail queue --set without changing bytes"

printf 'gamma\n' > "$TEST_REPO/.loom/queue"
queue_before="$(cksum < "$TEST_REPO/.loom/queue")"
assert_fails_with "unknown active stitch" "$LOOM" queue --set alpha ghost
assert_eq "$queue_before" "$(cksum < "$TEST_REPO/.loom/queue")" \
  "invalid requested records fail queue --set without changing bytes"

if LOOM_TEST_FAIL_QUEUE_WRITE=before-rename \
  "$LOOM" queue --set beta alpha >/dev/null 2>&1; then
  fail "injected queue --set write failure must fail"
fi
assert_eq "$queue_before" "$(cksum < "$TEST_REPO/.loom/queue")" \
  "failed queue --set atomic write changed queue bytes"

echo "v2 queue: ok"
