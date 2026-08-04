#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
require_v2_stage 7 "structured output from mutating commands"

# One result object per successful mutation, one error object per failure.
# Every assertion here is on stdout: the prose on stderr is a separate stream
# and is asserted unchanged at the end of this file.
assert_json_field() {
  local doc="$1" expression="$2" expected="$3" context="${4:-json field}"
  local actual
  actual="$(DOC="$doc" python3 -c '
import json, os, sys
doc = json.loads(os.environ["DOC"])
value = eval(sys.argv[1], {"doc": doc})
print("null" if value is None else value if isinstance(value, str) else json.dumps(value))
' "$expression")"
  assert_eq "$expected" "$actual" "$context"
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP v2 mutation json: python3 unavailable"
  exit 0
fi

new_test_loom
created="$($LOOM new --json alpha)"
assert_json_field "$created" "doc['command']" "new" "new result command"
assert_json_field "$created" "doc['id']" "alpha" "new result id"
assert_json_field "$created" "doc['state']" "plain" "new result state"
assert_json_field "$created" "doc['path']" "threads/alpha" "new result path"
assert_json_field "$created" "doc['tray']" "threads" "new result tray"
assert_json_field "$created" "doc['changed']" "true" "new result changed"
"$LOOM" new beta >/dev/null
child_created="$($LOOM new --json child alpha)"
assert_json_field "$child_created" "doc['path']" "threads/alpha/child" \
  "new child result path"

# --- shape ------------------------------------------------------------------

result="$("$LOOM" claim --json child)"
for field in schema_version format_version command ok changed id state path \
             tray queue_position completed_at; do
  assert_json_field "$result" "'$field' in doc" "true" "claim result has $field"
done
assert_json_field "$result" "doc['schema_version']" "1" "result schema_version"
assert_json_field "$result" "doc['format_version']" "2" "result format_version"
assert_json_field "$result" "doc['command']" "claim" "result command"
assert_json_field "$result" "doc['ok']" "true" "result ok"
assert_json_field "$result" "doc['changed']" "true" "result changed"
assert_json_field "$result" "doc['id']" "child" "result id"
assert_json_field "$result" "doc['state']" "stitching" "result state"
assert_json_field "$result" "doc['path']" "threads/alpha/child.stitching" \
  "result path"
assert_json_field "$result" "doc['tray']" "threads" "result tray"
assert_json_field "$result" "doc['queue_position']" "null" "unqueued position"
assert_json_field "$result" "doc['completed_at']" "null" "active completed_at"

# The new path is the point: it is what an optimistic UI applies without
# re-running map.
assert_dir "$TEST_REPO/.loom/$(DOC="$result" python3 -c '
import json, os
print(json.loads(os.environ["DOC"])["path"])')"

# --- idempotent no-ops are ok, not changed ----------------------------------

repeat="$("$LOOM" claim --json child)"
assert_json_field "$repeat" "doc['ok']" "true" "repeat claim ok"
assert_json_field "$repeat" "doc['changed']" "false" "repeat claim changed"
assert_json_field "$repeat" "doc['state']" "stitching" "repeat claim state"

# --- queue position ---------------------------------------------------------

"$LOOM" queue beta >/dev/null
queued="$("$LOOM" queue --json child)"
assert_json_field "$queued" "doc['command']" "queue" "queue command"
assert_json_field "$queued" "doc['queue_position']" "2" "appended position"
assert_json_field "$queued" "doc['state']" "stitching" \
  "queue mutation reports the stitch's unchanged state"
promoted="$("$LOOM" first --json child)"
assert_json_field "$promoted" "doc['queue_position']" "1" "promoted position"
assert_json_field "$promoted" "doc['changed']" "true" "promotion changed"
again="$("$LOOM" first --json child)"
assert_json_field "$again" "doc['changed']" "false" "repeated first is a no-op"

# unqueue repairs a stale record, so it accepts an ID that is not on disk.
printf 'ghost\n' >> "$TEST_REPO/.loom/queue"
repaired="$("$LOOM" unqueue --json ghost)"
assert_json_field "$repaired" "doc['ok']" "true" "unqueue ghost ok"
assert_json_field "$repaired" "doc['changed']" "true" "unqueue ghost changed"
assert_json_field "$repaired" "doc['path']" "null" "unqueue ghost path"
assert_json_field "$repaired" "doc['state']" "null" "unqueue ghost state"
absent="$("$LOOM" unqueue --json ghost)"
assert_json_field "$absent" "doc['changed']" "false" "unqueue of absent record"

# --- terminal results carry the archive path and timestamp ------------------

tied="$("$LOOM" tie --json child)"
assert_json_field "$tied" "doc['state']" "tied" "tie state"
assert_json_field "$tied" "doc['path']" "threads/alpha/child.tied" "tie path"
assert_json_field "$tied" "doc['tray']" "threads" "in-place tie tray"
assert_json_field "$tied" "doc['queue_position']" "null" \
  "tie removes its stitch from the queue"
assert_iso8601_seconds "$(DOC="$tied" python3 -c '
import json, os
print(json.loads(os.environ["DOC"])["completed_at"])')"

goal="$("$LOOM" tie --json alpha)"
assert_json_field "$goal" "doc['path']" "tied/alpha" "goal tie path"
assert_json_field "$goal" "doc['tray']" "tied" "goal tie tray"

dropped="$("$LOOM" drop --json beta not wanted --json anywhere)"
assert_json_field "$dropped" "doc['state']" "dropped" "drop state"
assert_json_field "$dropped" "doc['path']" "dropped/beta" "drop path"
assert_json_field "$dropped" "doc['tray']" "dropped" "drop tray"
# --json is only an option before the first positional argument; after that the
# reason is literal.
assert_contains "$(cat "$TEST_REPO/.loom/dropped/beta/reason.md")" \
  "not wanted --json anywhere" "drop reason is taken literally"

# --- every remaining mutating command emits a result ------------------------

new_test_loom
"$LOOM" new goal >/dev/null
"$LOOM" new leaf goal >/dev/null
assert_json_field "$("$LOOM" tend --json goal)" "doc['state']" "tending" \
  "tend state"
assert_json_field "$("$LOOM" release --json goal)" "doc['state']" "plain" \
  "release state"
assert_json_field "$("$LOOM" wait --json goal)" "doc['state']" "waiting" \
  "wait state"
assert_json_field "$("$LOOM" resume --json goal)" "doc['state']" "plain" \
  "resume state"
"$LOOM" queue leaf >/dev/null
assert_json_field "$("$LOOM" before --json goal leaf)" "doc['queue_position']" \
  "1" "before position"
assert_json_field "$("$LOOM" after --json goal leaf)" "doc['queue_position']" \
  "2" "after position"

# --- failures are structured ------------------------------------------------

new_test_loom
"$LOOM" new parent >/dev/null
"$LOOM" new one parent >/dev/null
"$LOOM" new two parent >/dev/null
"$LOOM" new blocked >/dev/null
mkdir -p "$TEST_REPO/.loom/threads/blocked/needs"
: > "$TEST_REPO/.loom/threads/blocked/needs/one"

assert_error_code() {
  local code="$1"
  shift
  local output status=0
  output="$("$@" 2>/dev/null)" || status=$?
  (( status != 0 )) || fail "expected failure: $*"
  assert_json_field "$output" "doc['ok']" "false" "error ok flag from $*"
  assert_json_field "$output" "doc['error']['code']" "$code" "error code from $*"
  printf '%s' "$output"
}

assert_error_code not_found "$LOOM" claim --json missing >/dev/null
assert_error_code usage "$LOOM" new --json >/dev/null
assert_error_code usage "$LOOM" new --json extra one two >/dev/null
assert_error_code failed "$LOOM" new --json parent >/dev/null
assert_error_code invalid_id "$LOOM" claim --json 'bad id' >/dev/null
assert_error_code usage "$LOOM" claim --json >/dev/null
assert_error_code usage "$LOOM" claim --json one two >/dev/null
assert_error_code usage "$LOOM" claim --json --wat one >/dev/null
assert_error_code not_ready "$LOOM" claim --json blocked >/dev/null
assert_error_code not_loose_end "$LOOM" claim --json parent >/dev/null
assert_error_code not_child_bearing "$LOOM" tend --json one >/dev/null
assert_error_code not_waiting "$LOOM" resume --json one >/dev/null
assert_error_code queue_anchor "$LOOM" before --json one two >/dev/null

unresolved="$(assert_error_code unresolved_children "$LOOM" tie --json parent)"
assert_json_field "$unresolved" "doc['id']" "parent" "error names its target"
assert_json_field "$unresolved" "sorted(doc['error']['stitch_ids'])" \
  '["one", "two"]' "unresolved children are named individually"

"$LOOM" claim one >/dev/null
assert_error_code not_tended "$LOOM" release --json one >/dev/null
claimed="$(assert_error_code claimed_descendants "$LOOM" wait --json parent)"
assert_json_field "$claimed" "doc['error']['stitch_ids']" '["one"]' \
  "claimed descendants are named individually"

"$LOOM" tie one >/dev/null
assert_error_code terminal "$LOOM" claim --json one >/dev/null
"$LOOM" wait parent >/dev/null
waiting="$(assert_error_code waiting "$LOOM" claim --json two)"
assert_json_field "$waiting" "doc['error']['stitch_ids']" '["parent"]' \
  "the blocking waiting ancestor is named"

# A v1 loom has no JSON mutation surface either, and says so structurally.
new_test_repo
printf '1\n' > "$TEST_REPO/.loom/format-version"
assert_error_code format "$LOOM" claim --json anything >/dev/null

# --- the human surface is untouched -----------------------------------------

new_test_loom
new_prose="$($LOOM new solo)"
assert_contains "$new_prose" "new $TEST_REPO/.loom/threads/solo" \
  "prose new path unchanged"
assert_contains "$new_prose" "next: read, then edit" \
  "prose new advisory unchanged"
assert_eq "claimed solo" "$("$LOOM" claim solo)" "prose claim unchanged"
assert_eq "already stitching: solo" "$("$LOOM" claim solo)" \
  "prose idempotent claim unchanged"
assert_eq "tied solo" "$("$LOOM" tie solo)" "prose tie unchanged"
assert_fails_with "stitch 'nope' not found" "$LOOM" claim nope
assert_fails_with "stitch 'nope' not found" "$LOOM" claim --json nope

# JSON goes to stdout; the prose stays on stderr for the terminal.
new_test_loom
"$LOOM" new solo >/dev/null
stderr="$("$LOOM" claim --json missing 2>&1 >/dev/null || true)"
assert_eq "error: stitch 'missing' not found" "$stderr" \
  "failure keeps its stderr prose"
stdout="$("$LOOM" claim --json solo 2>/dev/null)"
assert_not_contains "$stdout" "claimed solo" "success stdout is json only"

echo "v2 mutation json: ok"
