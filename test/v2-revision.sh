#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
require_v2_stage 7 "cheap revision probe"

new_test_loom
before_manifest="$(find "$TEST_REPO/.loom" -printf '%P|%y|%s|%T@\n' | LC_ALL=C sort)"
empty_revision="$("$LOOM" revision)"
assert_eq "$empty_revision" "$("$LOOM" revision)" \
  "revision is stable when the loom does not change"
after_manifest="$(find "$TEST_REPO/.loom" -printf '%P|%y|%s|%T@\n' | LC_ALL=C sort)"
assert_eq "$before_manifest" "$after_manifest" "revision changed the loom"

"$LOOM" new work >/dev/null
new_revision="$("$LOOM" revision)"
[[ "$new_revision" != "$empty_revision" ]] ||
  fail "creating a stitch did not change revision"

printf '# edited\n' > "$TEST_REPO/.loom/threads/work/instructions.md"
edited_revision="$("$LOOM" revision)"
[[ "$edited_revision" != "$new_revision" ]] ||
  fail "editing instructions did not change revision"

"$LOOM" queue work >/dev/null
queued_revision="$("$LOOM" revision)"
[[ "$queued_revision" != "$edited_revision" ]] ||
  fail "editing queue state did not change revision"

"$LOOM" new prerequisite >/dev/null
mkdir -p "$TEST_REPO/.loom/threads/work/needs"
: > "$TEST_REPO/.loom/threads/work/needs/prerequisite"
dependency_revision="$("$LOOM" revision)"
[[ "$dependency_revision" != "$queued_revision" ]] ||
  fail "adding a dependency did not change revision"

"$LOOM" claim prerequisite >/dev/null
claimed_revision="$("$LOOM" revision)"
[[ "$claimed_revision" != "$dependency_revision" ]] ||
  fail "changing stitch state did not change revision"

assert_fails_with "takes no arguments" "$LOOM" revision extra

echo "v2 revision: ok"
