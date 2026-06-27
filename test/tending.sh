#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/.loom"
cp "$ROOT/.loom/loom.sh" "$TMP/repo/.loom/loom.sh"
LOOM="$TMP/repo/.loom/loom.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2"
  [[ "$actual" == "$expected" ]] || fail "expected '$expected', got '$actual'"
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    fail "expected command to fail: $*"
  fi
}

"$LOOM" init >/dev/null
"$LOOM" new parent >/dev/null
"$LOOM" new child-a parent >/dev/null
"$LOOM" tend parent >/dev/null

[[ -d "$TMP/repo/.loom/threads/parent.tending" ]] || fail "tend did not add .tending"
assert_eq "parent.tending" "$("$LOOM" tending)"
status_output="$("$LOOM" status)"
grep -q -- "- parent.tending" <<<"$status_output" || fail "status did not show tended parent"
assert_fails "$LOOM" tend child-a
assert_fails "$LOOM" claim parent
assert_fails "$LOOM" wait parent
assert_eq "parent.tending/child-a" "$("$LOOM" loose-ends)"
assert_eq "parent.tending/child-a" "$("$LOOM" next)"

"$LOOM" new child-b parent >/dev/null
[[ -d "$TMP/repo/.loom/threads/parent.tending/child-b" ]] || fail "new child did not preserve .tending"
"$LOOM" claim child-a >/dev/null
"$LOOM" wait child-b >/dev/null
assert_fails "$LOOM" claim parent
assert_fails "$LOOM" wait parent
"$LOOM" tie child-a >/dev/null
"$LOOM" drop child-b test >/dev/null

assert_fails "$LOOM" claim parent
"$LOOM" release parent >/dev/null
[[ -d "$TMP/repo/.loom/threads/parent" ]] || fail "release did not remove .tending"
"$LOOM" claim parent >/dev/null
"$LOOM" tie parent >/dev/null
[[ -d "$TMP/repo/.loom/tied/parent" ]] || fail "tie did not strip state suffix"

"$LOOM" new tied-parent >/dev/null
"$LOOM" new tied-child tied-parent >/dev/null
"$LOOM" tend tied-parent >/dev/null
"$LOOM" tie tied-child >/dev/null
"$LOOM" tie tied-parent >/dev/null
[[ -d "$TMP/repo/.loom/tied/tied-parent" ]] || fail "tie did not strip .tending"

"$LOOM" new dropped-parent >/dev/null
"$LOOM" new dropped-child dropped-parent >/dev/null
"$LOOM" tend dropped-parent >/dev/null
"$LOOM" drop dropped-parent test >/dev/null
[[ -d "$TMP/repo/.loom/dropped/dropped-parent" ]] || fail "drop did not strip .tending"

echo "tending lifecycle: ok"
