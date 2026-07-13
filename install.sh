#!/usr/bin/env bash
# usage: ./install.sh <host-dir>
# Lays down a .loom/ at the host directory — a sanctioned standalone install
# for scopes that are not delivered by any bundle (a workspace root, a fleet
# root). Idempotent: re-running repairs loom.sh and README.md and re-seeds
# missing trays; it never touches tray contents.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:?usage: install.sh <host-dir>}"
[ -d "$target" ] || { echo "no such host dir: $target" >&2; exit 1; }

dest="$target/.loom"
mkdir -p "$dest"
cp -f "$REPO_DIR/.loom/loom.sh" "$dest/loom.sh"
chmod +x "$dest/loom.sh"
cp -f "$REPO_DIR/README.md" "$dest/README.md"
"$dest/loom.sh" init

echo "installed $dest"
