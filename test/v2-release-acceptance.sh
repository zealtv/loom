#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

new_test_repo
rm -rf -- "$TEST_REPO/.loom"
"$TEST_ROOT/install.sh" "$TEST_REPO" >/dev/null
LOOM="$TEST_REPO/.loom/loom.sh"

assert_file "$LOOM"
assert_file "$TEST_REPO/.loom/README.md"
assert_file "$TEST_REPO/.loom/docs/protocol-v2.md"
assert_eq "2" "$(<"$TEST_REPO/.loom/format-version")" \
  "fresh install format marker"
"$LOOM" new release-check >/dev/null
assert_eq "release-check" "$("$LOOM" next)" \
  "fresh installed loom lifecycle"
"$LOOM" map --json > "$TEST_TMP/fresh-map.json"
assert_contains "$(<"$TEST_TMP/fresh-map.json")" \
  '"format_version":2' "fresh installed map"
before_reads="$(
  cd "$TEST_REPO"
  find .loom -printf '%P|%y|%s|%T@\n' | LC_ALL=C sort
)"
"$LOOM" status >/dev/null
"$LOOM" next >/dev/null
"$LOOM" loose-ends >/dev/null
"$LOOM" waiting >/dev/null
"$LOOM" tending >/dev/null
"$LOOM" map >/dev/null
"$LOOM" map --json >/dev/null
after_reads="$(
  cd "$TEST_REPO"
  find .loom -printf '%P|%y|%s|%T@\n' | LC_ALL=C sort
)"
assert_eq "$before_reads" "$after_reads" \
  "release read commands changed paths, bytes, or mtimes"

new_test_repo
mkdir -p \
  "$TEST_REPO/.loom/threads/active.waiting" \
  "$TEST_REPO/.loom/tied/old-tied" \
  "$TEST_REPO/.loom/dropped/old-drop"
write_instructions "$TEST_REPO/.loom/threads/active.waiting" active
write_instructions "$TEST_REPO/.loom/tied/old-tied" old-tied
write_instructions "$TEST_REPO/.loom/dropped/old-drop" old-drop
printf 'retired\n' > "$TEST_REPO/.loom/dropped/old-drop.reason.md"

"$TEST_ROOT/install.sh" "$TEST_REPO" >/dev/null
LOOM="$TEST_REPO/.loom/loom.sh"
assert_no_path "$TEST_REPO/.loom/format-version"
assert_dir "$TEST_REPO/.loom/threads/active.waiting"
assert_dir "$TEST_REPO/.loom/tied/old-tied"
assert_file "$TEST_REPO/.loom/docs/protocol-v2.md"
assert_fails_with "migrate-v2 --dry-run" "$LOOM" new forbidden

before_dry_run="$(
  cd "$TEST_REPO"
  find .loom -printf '%P|%y|%s|%T@\n' | LC_ALL=C sort
)"
"$LOOM" migrate-v2 --dry-run > "$TEST_TMP/migrate-plan.txt"
after_dry_run="$(
  cd "$TEST_REPO"
  find .loom -printf '%P|%y|%s|%T@\n' | LC_ALL=C sort
)"
assert_eq "$before_dry_run" "$after_dry_run" \
  "release migration dry-run changed deployed state"

"$LOOM" migrate-v2 >/dev/null
assert_eq "2" "$(<"$TEST_REPO/.loom/format-version")" \
  "migrated install format marker"
assert_dir "$TEST_REPO/.loom/threads/active.waiting"
assert_dir "$TEST_REPO/.loom/legacy-v1/tied/old-tied"
assert_file "$TEST_REPO/.loom/legacy-v1/dropped/old-drop/reason.md"
"$LOOM" map --json > "$TEST_TMP/migrated-map.json"
assert_contains "$(<"$TEST_TMP/migrated-map.json")" \
  '"legacy":true' "migrated map legacy label"

# The whole point, end to end: a loom committed before its first tie or drop
# must still have its trays after a clone, and must tie a goal there without the
# terminal move failing on a directory git could not carry.
if command -v git >/dev/null 2>&1; then
  new_test_repo
  rm -rf -- "$TEST_REPO/.loom"
  "$TEST_ROOT/install.sh" "$TEST_REPO" >/dev/null
  LOOM="$TEST_REPO/.loom/loom.sh"
  "$LOOM" new survives-clone >/dev/null

  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.email loom@example.invalid
  git -C "$TEST_REPO" config user.name "Loom Test"
  git -C "$TEST_REPO" add -A
  git -C "$TEST_REPO" -c commit.gpgsign=false commit -qm "loom before first tie"

  clone="$TEST_TMP/clone"
  git clone -q "$TEST_REPO" "$clone"
  assert_dir "$clone/.loom/tied"
  assert_dir "$clone/.loom/dropped"
  assert_not_contains "$("$clone/.loom/loom.sh" status)" \
    "missing archive trays" "cloned loom"
  "$clone/.loom/loom.sh" tie survives-clone >/dev/null
  assert_dir "$clone/.loom/tied/survives-clone"
  assert_no_path "$clone/.loom/threads/survives-clone"
fi

echo "v2 release acceptance: ok"
