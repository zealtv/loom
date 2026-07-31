#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
require_v2_stage 6 "explicit and recoverable v1 migration"

make_v1_base() {
  new_test_repo
  mkdir -p \
    "$TEST_REPO/.loom/threads" \
    "$TEST_REPO/.loom/tied" \
    "$TEST_REPO/.loom/dropped"
}

make_v1_base
write_instructions "$TEST_REPO/.loom/threads/active.waiting" active
printf 'preserve me byte-for-byte\n' > \
  "$TEST_REPO/.loom/threads/active.waiting/artifact.bin"
write_instructions "$TEST_REPO/.loom/tied/old-tied" old-tied
write_instructions "$TEST_REPO/.loom/dropped/old-drop" old-drop
printf '# old reason\n\nNo longer wanted.\n' > \
  "$TEST_REPO/.loom/dropped/old-drop.reason.md"

before_dry_run="$(
  find "$TEST_REPO/.loom" -type f -print0 |
    LC_ALL=C sort -z |
    xargs -0 cksum
)"
dry_output="$("$LOOM" migrate-v2 --dry-run)"
assert_contains "$dry_output" "old-tied" "dry-run planned moves"
assert_contains "$dry_output" "old-drop.reason.md" "dry-run reason move"
after_dry_run="$(
  find "$TEST_REPO/.loom" -type f -print0 |
    LC_ALL=C sort -z |
    xargs -0 cksum
)"
assert_eq "$before_dry_run" "$after_dry_run" "dry-run changed files"
assert_no_path "$TEST_REPO/.loom/format-version"

migrate_output="$("$LOOM" migrate-v2)"
assert_contains "$migrate_output" "legacy" "migration summary"
assert_eq "2" "$(<"$TEST_REPO/.loom/format-version")"
assert_dir "$TEST_REPO/.loom/legacy-v1/tied/old-tied"
assert_dir "$TEST_REPO/.loom/legacy-v1/dropped/old-drop"
assert_file "$TEST_REPO/.loom/legacy-v1/dropped/old-drop/reason.md"
assert_no_path "$TEST_REPO/.loom/legacy-v1/tied/old-tied/completed-at"
assert_eq "preserve me byte-for-byte" \
  "$(<"$TEST_REPO/.loom/threads/active.waiting/artifact.bin")"
assert_contains "$("$LOOM" migrate-v2)" "already" \
  "second migration must be a clear no-op"

make_v1_base
write_instructions "$TEST_REPO/.loom/dropped/lonely" lonely
printf 'orphan\n' > "$TEST_REPO/.loom/dropped/orphan.reason.md"
assert_fails_with "orphan" "$LOOM" migrate-v2 --dry-run
assert_no_path "$TEST_REPO/.loom/format-version"

make_v1_base
mkdir -p "$TEST_REPO/.loom/threads/ambiguous-directory"
assert_fails_with "instructions.md" "$LOOM" migrate-v2 --dry-run

make_v1_base
"$LOOM" migrate-v2 --dry-run >/dev/null
"$LOOM" migrate-v2 >/dev/null
assert_eq "2" "$(<"$TEST_REPO/.loom/format-version")" "empty v1 migration"

make_v1_base
write_instructions "$TEST_REPO/.loom/threads/claimed.stitching" claimed
write_instructions "$TEST_REPO/.loom/threads/waiting.waiting" waiting
write_instructions "$TEST_REPO/.loom/threads/tended.tending" tended
write_instructions "$TEST_REPO/.loom/threads/tended.tending/child" child
write_instructions "$TEST_REPO/.loom/dropped/no-reason" no-reason
"$LOOM" migrate-v2 >/dev/null
assert_dir "$TEST_REPO/.loom/threads/claimed.stitching"
assert_dir "$TEST_REPO/.loom/threads/waiting.waiting"
assert_dir "$TEST_REPO/.loom/threads/tended.tending"
assert_dir "$TEST_REPO/.loom/legacy-v1/dropped/no-reason"
assert_no_path "$TEST_REPO/.loom/legacy-v1/dropped/no-reason/reason.md"

make_v1_base
write_instructions "$TEST_REPO/.loom/tied/collision" collision
mkdir -p "$TEST_REPO/.loom/legacy-v1/tied/collision"
assert_fails_with "collision" "$LOOM" migrate-v2 --dry-run

for failure_point in backup-tied move-tied move-dropped move-reason marker; do
  make_v1_base
  write_instructions "$TEST_REPO/.loom/tied/old" old
  write_instructions "$TEST_REPO/.loom/dropped/gone" gone
  printf 'reason\n' > "$TEST_REPO/.loom/dropped/gone.reason.md"
  if LOOM_TEST_FAIL_MIGRATION_AT="$failure_point" \
    "$LOOM" migrate-v2 >/dev/null 2>&1; then
    fail "injected migration failure '$failure_point' must fail"
  fi
  assert_no_path "$TEST_REPO/.loom/format-version"
  assert_dir "$TEST_REPO/.loom/.migrate-v2-staging"
  recovery="$("$LOOM" migrate-v2 2>&1 || true)"
  assert_contains "$recovery" "resume" "migration recovery hint"
  assert_contains "$recovery" "rollback" "migration rollback hint"
  "$LOOM" migrate-v2 --rollback >/dev/null
  assert_dir "$TEST_REPO/.loom/tied/old"
  assert_dir "$TEST_REPO/.loom/dropped/gone"
  assert_file "$TEST_REPO/.loom/dropped/gone.reason.md"
done

new_test_loom
assert_eq "2" "$(<"$TEST_REPO/.loom/format-version")" \
  "fresh empty init is v2"

echo "v2 migration: ok"
