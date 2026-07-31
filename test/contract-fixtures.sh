#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTOCOL="$ROOT/docs/protocol-v2.md"
MAP_FIXTURE="$ROOT/test/fixtures/map-v2-shape.json"

[[ -f "$PROTOCOL" ]] || {
  echo "FAIL: missing v2 protocol document" >&2
  exit 1
}
[[ -f "$MAP_FIXTURE" ]] || {
  echo "FAIL: missing map JSON shape fixture" >&2
  exit 1
}

required_contract_terms=(
  ".loom/format-version"
  "completed-at"
  "legacy-v1"
  "waiting_inherited"
  "queue_position"
  "decomposition_edges"
  "dependency_edges"
  "recently_completed"
)

for term in "${required_contract_terms[@]}"; do
  grep -Fq "$term" "$PROTOCOL" ||
    {
      echo "FAIL: protocol does not define $term" >&2
      exit 1
    }
done

if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool "$MAP_FIXTURE" >/dev/null
else
  echo "NOTE: python3 unavailable; JSON parse check skipped"
fi

echo "contract fixtures: ok"
