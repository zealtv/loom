#!/usr/bin/env bash
# usage: ./install.sh <host-dir>
# Upgrades the .loom/ at the host directory (it also makes one if absent).
# To install, copy the .loom/ directory; this script is the upgrade path.
# It refreshes what loom ships (loom.sh, README.md, docs/protocol-v2.md),
# seeds what is absent (the trays, and the format-version marker of a loom
# with no history), and never touches threads/, tied/, dropped/, queue or an
# existing format-version. A markerless v1 loom with history stays markerless;
# loom.sh migrate-v2 is the only way to change it. Re-running changes nothing.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:?usage: install.sh <host-dir>}"
[ -d "$target" ] || { echo "no such host dir: $target" >&2; exit 1; }

dest="$target/.loom"
mkdir -p "$dest"
# Source and destination can be the same file (./install.sh .): skip the copy.
[ "$REPO_DIR/.loom/loom.sh" -ef "$dest/loom.sh" ] ||
  cp -f "$REPO_DIR/.loom/loom.sh" "$dest/loom.sh"
chmod +x "$dest/loom.sh"
[ "$REPO_DIR/.loom/README.md" -ef "$dest/README.md" ] ||
  cp -f "$REPO_DIR/.loom/README.md" "$dest/README.md"
mkdir -p "$dest/docs"
[ "$REPO_DIR/.loom/docs/protocol-v2.md" -ef "$dest/docs/protocol-v2.md" ] ||
  cp -f "$REPO_DIR/.loom/docs/protocol-v2.md" "$dest/docs/protocol-v2.md"
"$dest/loom.sh" init

echo "installed $dest"
