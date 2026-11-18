#!/usr/bin/env bash
set -euo pipefail

# install.sh is the upgrade path: over an existing, customised .loom/ it
# refreshes what loom ships, leaves host-owned state byte for byte, and a
# second run changes nothing.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

shipped_same() {
  local dest="$1" label="$2" f
  for f in loom.sh README.md docs/protocol-v2.md; do
    cmp -s "$TEST_ROOT/.loom/$f" "$dest/.loom/$f" ||
      fail "$label: $f was not refreshed"
  done
  [[ -x "$dest/.loom/loom.sh" ]] || fail "$label: loom.sh is not executable"
}

tree_snapshot() {
  (cd "$1/.loom" && find . | LC_ALL=C sort | while IFS= read -r e; do
    if [[ -f "$e" ]]; then printf '%s %s\n' "$e" "$(cksum < "$e")"; else echo "$e"; fi
  done)
}

host_snapshot() {
  # Host-owned paths only: everything except what loom ships.
  (
    cd "$1/.loom" || exit 1
    find . -type f ! -path ./loom.sh ! -path ./README.md \
      ! -path ./docs/protocol-v2.md -exec cksum {} + | LC_ALL=C sort
  )
}

# A v2 loom with history, a queue, and an older script, README and doc.
new_test_loom
"$LOOM" new alpha >/dev/null
"$LOOM" new beta >/dev/null
"$LOOM" new gone >/dev/null
"$LOOM" tie gone >/dev/null
"$LOOM" queue alpha >/dev/null 2>&1 || true
printf 'host note\n' > "$TEST_REPO/.loom/threads/alpha/host-note.md"
assert_file "$TEST_REPO/.loom/format-version"
printf 'older script\n' > "$TEST_REPO/.loom/loom.sh"
printf 'older readme\n' > "$TEST_REPO/.loom/README.md"
mkdir -p "$TEST_REPO/.loom/docs"
printf 'older doc\n' > "$TEST_REPO/.loom/docs/protocol-v2.md"
before="$(host_snapshot "$TEST_REPO")"

"$TEST_ROOT/install.sh" "$TEST_REPO" >/dev/null
shipped_same "$TEST_REPO" "v2 upgrade"
assert_eq "$before" "$(host_snapshot "$TEST_REPO")" \
  "v2 upgrade changed host-owned files"
first="$(tree_snapshot "$TEST_REPO")"
"$TEST_ROOT/install.sh" "$TEST_REPO" >/dev/null
assert_eq "$first" "$(tree_snapshot "$TEST_REPO")" \
  "second upgrade changed paths or bytes"

# A markerless v1 loom with history never gains a format-version, and its
# trays and threads stay byte for byte.
new_test_repo
mkdir -p \
  "$TEST_REPO/.loom/threads/active.waiting" \
  "$TEST_REPO/.loom/tied/old-tied"
write_instructions "$TEST_REPO/.loom/threads/active.waiting" active
write_instructions "$TEST_REPO/.loom/tied/old-tied" old-tied
printf 'older readme\n' > "$TEST_REPO/.loom/README.md"
before="$(host_snapshot "$TEST_REPO")"
"$TEST_ROOT/install.sh" "$TEST_REPO" >/dev/null
assert_no_path "$TEST_REPO/.loom/format-version"
shipped_same "$TEST_REPO" "v1 upgrade"
assert_eq "$before" "$(host_snapshot "$TEST_REPO")" \
  "v1 upgrade changed host-owned files"
"$TEST_ROOT/install.sh" "$TEST_REPO" >/dev/null
assert_no_path "$TEST_REPO/.loom/format-version"
assert_eq "$before" "$(host_snapshot "$TEST_REPO")" \
  "second v1 upgrade changed host-owned files"

# Source and destination the same file (./install.sh . in a checkout).
new_test_repo
rm -rf -- "$TEST_REPO/.loom"
cp -R "$TEST_ROOT/.loom" "$TEST_ROOT/install.sh" "$TEST_REPO/"
before="$(tree_snapshot "$TEST_REPO")"
(cd "$TEST_REPO" && ./install.sh . >/dev/null)
assert_eq "$before" "$(tree_snapshot "$TEST_REPO")" \
  "self-copy install changed files"

echo "installer upgrade: ok"
