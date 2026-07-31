#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tests=(
  tending.sh
  contract-fixtures.sh
  v2-history-and-artifacts.sh
  v2-subtree-waiting.sh
  v2-dependencies.sh
  v2-queue.sh
  v2-migration.sh
  v2-map.sh
)

for test_file in "${tests[@]}"; do
  echo "==> test/$test_file"
  "$ROOT/test/$test_file"
done

echo "test suite: ok"
