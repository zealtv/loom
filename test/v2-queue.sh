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

"$LOOM" new prerequisite >/dev/null
mkdir -p "$TEST_REPO/.loom/threads/alpha/needs"
: > "$TEST_REPO/.loom/threads/alpha/needs/prerequisite"
assert_eq "prerequisite" "$("$LOOM" next)" \
  "dependencies override queue and fallback is deterministic"

printf '# keep this comment\nalpha\nalpha\nunknown\n' > \
  "$TEST_REPO/.loom/queue"
queue_before="$(cksum < "$TEST_REPO/.loom/queue")"
assert_fails_with "duplicate" "$LOOM" status
assert_fails_with "unknown" "$LOOM" status
assert_fails_with "unknown" "$LOOM" first prerequisite
assert_eq "$queue_before" "$(cksum < "$TEST_REPO/.loom/queue")" \
  "failed queue mutation must preserve bytes"
"$LOOM" unqueue unknown >/dev/null
assert_eq $'alpha\nalpha' "$(queue_ids)" \
  "unqueue may repair a stale syntactically valid ID"

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

echo "v2 queue: ok"
