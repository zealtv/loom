#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
require_v2_stage 7 "deterministic read-only map snapshot"

new_test_loom
"$LOOM" new release >/dev/null
for id in design build docs package parked discarded broken cycle-a cycle-b; do
  "$LOOM" new "$id" release >/dev/null
done

mkdir -p \
  "$TEST_REPO/.loom/threads/release/build/needs" \
  "$TEST_REPO/.loom/threads/release/docs/needs" \
  "$TEST_REPO/.loom/threads/release/package/needs" \
  "$TEST_REPO/.loom/threads/release/broken/needs" \
  "$TEST_REPO/.loom/threads/release/cycle-a/needs" \
  "$TEST_REPO/.loom/threads/release/cycle-b/needs" \
  "$TEST_REPO/.loom/threads/release/notes/deep"
: > "$TEST_REPO/.loom/threads/release/build/needs/design"
: > "$TEST_REPO/.loom/threads/release/docs/needs/design"
: > "$TEST_REPO/.loom/threads/release/package/needs/build"
: > "$TEST_REPO/.loom/threads/release/package/needs/docs"
: > "$TEST_REPO/.loom/threads/release/broken/needs/missing-id"
: > "$TEST_REPO/.loom/threads/release/cycle-a/needs/cycle-b"
: > "$TEST_REPO/.loom/threads/release/cycle-b/needs/cycle-a"
printf '# opaque\n' > \
  "$TEST_REPO/.loom/threads/release/notes/deep/instructions.md"

"$LOOM" queue package >/dev/null
"$LOOM" queue design >/dev/null
"$LOOM" new parked-descendant parked >/dev/null
"$LOOM" wait parked >/dev/null
"$LOOM" tie design >/dev/null
"$LOOM" drop discarded unused >/dev/null
"$LOOM" claim build >/dev/null
"$LOOM" tend release >/dev/null

"$LOOM" new abandoned >/dev/null
"$LOOM" new never-finished abandoned >/dev/null
"$LOOM" drop abandoned stopped >/dev/null
"$LOOM" new completed >/dev/null
"$LOOM" tie completed >/dev/null

mkdir -p "$TEST_REPO/.loom/legacy-v1/tied/old"
printf '# old\n' > \
  "$TEST_REPO/.loom/legacy-v1/tied/old/instructions.md"

before_manifest="$(
  find "$TEST_REPO/.loom" -printf '%P|%y|%s|%T@\n' | LC_ALL=C sort
)"
json_one="$("$LOOM" map --json 2>/dev/null || true)"
json_two="$("$LOOM" map --json 2>/dev/null || true)"
plain_map="$("$LOOM" map 2>/dev/null || true)"
after_manifest="$(
  find "$TEST_REPO/.loom" -printf '%P|%y|%s|%T@\n' | LC_ALL=C sort
)"

assert_eq "$json_one" "$json_two" "JSON map must be deterministic"
assert_eq "$before_manifest" "$after_manifest" "map commands changed the loom"
assert_contains "$plain_map" "recent" "plain map recent section"
assert_contains "$plain_map" "frontier" "plain map frontier section"
assert_contains "$plain_map" "blocked" "plain map blocked section"
assert_contains "$plain_map" "release" "plain map tree"

if command -v python3 >/dev/null 2>&1; then
  MAP_JSON="$json_one" python3 - <<'PY'
import json
import os

doc = json.loads(os.environ["MAP_JSON"])
required_top = {
    "schema_version", "format_version", "loom_root", "stitches",
    "decomposition_edges", "dependency_edges", "cycles", "frontier",
    "recently_completed", "diagnostics",
}
missing = required_top - set(doc)
if missing:
    raise SystemExit(f"missing top-level map fields: {sorted(missing)}")

required_stitch = {
    "id", "root_id", "parent_id", "path", "tray", "state", "ready",
    "waiting_inherited", "queue_position", "completed_at", "archived",
    "legacy", "children", "dependencies", "cycle",
}
for stitch in doc["stitches"]:
    missing = required_stitch - set(stitch)
    if missing:
        raise SystemExit(
            f"{stitch.get('id', '<unknown>')} missing fields: {sorted(missing)}"
        )

by_id = {stitch["id"]: stitch for stitch in doc["stitches"]}
assert by_id["parked"]["state"] == "waiting"
assert by_id["parked-descendant"]["waiting_inherited"] is True
assert by_id["design"]["state"] == "tied"
assert by_id["discarded"]["state"] == "dropped"
assert by_id["build"]["state"] == "stitching"
assert by_id["never-finished"]["state"] == "abandoned"
assert by_id["release"]["state"] == "tending"
assert by_id["old"]["legacy"] is True
assert by_id["old"]["completed_at"] is None
assert by_id["package"]["queue_position"] == 1
assert any(edge["reason"] == "missing" for edge in doc["dependency_edges"])
assert any(set(cycle) == {"cycle-a", "cycle-b"} for cycle in doc["cycles"])
assert all("deep" != stitch["id"] for stitch in doc["stitches"])
PY
else
  echo "NOTE: python3 unavailable; detailed map schema assertions skipped"
fi

echo "v2 map: ok"
