#!/usr/bin/env bash
# usage: ./install.sh <host-dir>
# Lays down a .loom/ at the host directory — a sanctioned standalone install
# for scopes that are not delivered by any bundle (a workspace root, a fleet
# root). Idempotent: re-running repairs the executable and documentation and
# re-seeds missing trays; it never migrates or edits tray contents.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:?usage: install.sh <host-dir>}"
[ -d "$target" ] || { echo "no such host dir: $target" >&2; exit 1; }

dest="$target/.loom"
mkdir -p "$dest"
cp -f "$REPO_DIR/.loom/loom.sh" "$dest/loom.sh"
chmod +x "$dest/loom.sh"
cp -f "$REPO_DIR/README.md" "$dest/README.md"
mkdir -p "$dest/docs"
cp -f "$REPO_DIR/docs/protocol-v2.md" "$dest/docs/protocol-v2.md"
"$dest/loom.sh" init

echo "installed $dest"
