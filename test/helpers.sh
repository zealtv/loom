#!/usr/bin/env bash

# Shared black-box test support. Test files may source this file; they must not
# source .loom/loom.sh or call its private functions.

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=""
TEST_REPO=""
LOOM=""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cleanup_test_repo() {
  if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
    rm -rf -- "$TEST_TMP"
  fi
}

trap cleanup_test_repo EXIT

new_test_repo() {
  cleanup_test_repo
  TEST_TMP="$(mktemp -d)"
  TEST_REPO="$TEST_TMP/repo"
  mkdir -p "$TEST_REPO/.loom"
  cp "$TEST_ROOT/.loom/loom.sh" "$TEST_REPO/.loom/loom.sh"
  chmod +x "$TEST_REPO/.loom/loom.sh"
  LOOM="$TEST_REPO/.loom/loom.sh"
}

new_test_loom() {
  new_test_repo
  "$LOOM" init >/dev/null
}

require_v2_stage() {
  local required="$1"
  local name="$2"
  local enabled="${LOOM_V2_STAGE:-1}"

  [[ "$enabled" =~ ^[0-9]+$ ]] ||
    fail "LOOM_V2_STAGE must be a non-negative integer"
  if (( enabled < required )); then
    echo "SKIP v2 stage $required: $name (set LOOM_V2_STAGE=$required to exercise)"
    exit 0
  fi
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local context="${3:-values differ}"
  [[ "$actual" == "$expected" ]] ||
    fail "$context: expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local context="${3:-output}"
  [[ "$haystack" == *"$needle"* ]] ||
    fail "$context did not contain '$needle': $haystack"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local context="${3:-output}"
  [[ "$haystack" != *"$needle"* ]] ||
    fail "$context unexpectedly contained '$needle': $haystack"
}

assert_file() {
  [[ -f "$1" ]] || fail "expected regular file: $1"
}

assert_dir() {
  [[ -d "$1" ]] || fail "expected directory: $1"
}

assert_no_path() {
  [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

assert_fails_with() {
  local needle="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "expected command to fail: $*"
  fi
  assert_contains "$output" "$needle" "failure from '$*'"
}

write_instructions() {
  local dir="$1"
  local id="$2"
  mkdir -p "$dir"
  printf '# %s\n' "$id" > "$dir/instructions.md"
}

assert_iso8601_seconds() {
  local value="$1"
  [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$ ]] ||
    fail "not local ISO-8601 seconds with numeric offset: '$value'"
}
