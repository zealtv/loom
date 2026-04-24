#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage:
  loom.sh init
  loom.sh new <stitch-id> [parent-stitch-id]
  loom.sh claim <stitch-id>
  loom.sh tie <stitch-id>
  loom.sh drop <stitch-id> [reason...]
  loom.sh tips
  loom.sh status

notes:
  - this script operates on the .loom/ directory it lives in
  - stitches are directories with an instructions.md file
  - root entries in .loom/threads/ are goals
  - child stitches are the decomposition of their parent
  - leaf stitches are the work ready now
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_loom() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ "$(basename "$script_dir")" == ".loom" ]] || die "loom.sh must live inside a .loom/ directory"
  LOOM_DIR="$script_dir"
  REPO_ROOT="$(dirname "$LOOM_DIR")"
}

validate_id() {
  local id="$1"
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid stitch id '$id' (use letters, numbers, ., _, -)"
  [[ "$id" != *"/"* ]] || die "stitch id cannot contain /"
}

strip_state_suffix() {
  local name="$1"
  name="${name%.stitching}"
  printf '%s\n' "$name"
}

find_stitch_anywhere() {
  local id="$1"
  local base="$2"
  find "$base" \
    -type d \
    \( -name "$id" -o -name "$id.stitching" \) \
    -print
}

find_unique_stitch_anywhere() {
  local id="$1"
  local matches
  mapfile -t matches < <(find_stitch_anywhere "$id" "$LOOM_DIR")
  if (( ${#matches[@]} == 0 )); then
    return 1
  fi
  if (( ${#matches[@]} > 1 )); then
    printf '%s\n' "${matches[@]}" >&2
    die "multiple stitches found for id '$id'"
  fi
  printf '%s\n' "${matches[0]}"
}

ensure_unique_new_id() {
  local id="$1"
  if find_unique_stitch_anywhere "$id" >/dev/null 2>&1; then
    die "stitch '$id' already exists"
  fi
}

create_stitch_dir() {
  local parent="$1"
  local id="$2"
  local dir="$parent/$id"
  mkdir -p "$dir"
  cat > "$dir/instructions.md" <<EOF_STITCH
# $id

Describe the intention here.
EOF_STITCH
  printf '%s\n' "$dir"
}

cmd_init() {
  mkdir -p .loom/threads .loom/tied .loom/dropped
  echo "initialized .loom/"
}

cmd_new() {
  require_loom
  local id="${1:-}"
  local parent_id="${2:-}"
  [[ -n "$id" ]] || die "new requires <stitch-id>"
  validate_id "$id"
  ensure_unique_new_id "$id"

  local target_parent
  if [[ -z "$parent_id" ]]; then
    target_parent="$LOOM_DIR/threads"
  else
    validate_id "$parent_id"
    local parent
    parent="$(find_unique_stitch_anywhere "$parent_id" || true)"
    [[ -n "$parent" ]] || die "parent '$parent_id' not found"

    case "$parent" in
      "$LOOM_DIR/dropped"/*)
        die "cannot add child to dropped stitch '$parent_id'"
        ;;
      "$LOOM_DIR/tied"/*)
        die "cannot add child to tied stitch '$parent_id'"
        ;;
    esac
    target_parent="$parent"
  fi

  local created
  created="$(create_stitch_dir "$target_parent" "$id")"
  echo "new $created"
}

cmd_claim() {
  require_loom
  local id="${1:-}"
  [[ -n "$id" ]] || die "claim requires <stitch-id>"
  validate_id "$id"

  local existing
  existing="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$existing" ]] || die "stitch '$id' not found"

  case "$existing" in
    "$LOOM_DIR/tied"/*)
      die "cannot claim a tied stitch"
      ;;
    "$LOOM_DIR/dropped"/*)
      die "cannot claim a dropped stitch"
      ;;
  esac

  local name
  name="$(basename "$existing")"
  if [[ "$name" == *.stitching ]]; then
    echo "already stitching: $id"
    return 0
  fi

  local parent_dir
  parent_dir="$(dirname "$existing")"
  local claimed="$parent_dir/$id.stitching"
  mv "$existing" "$claimed"
  echo "claimed $id"
}

cmd_tie() {
  require_loom
  local id="${1:-}"
  [[ -n "$id" ]] || die "tie requires <stitch-id>"
  validate_id "$id"

  local src
  src="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$src" ]] || die "stitch '$id' not found"

  case "$src" in
    "$LOOM_DIR/tied"/*)
      echo "already tied: $id"
      return 0
      ;;
    "$LOOM_DIR/dropped"/*)
      die "cannot tie a dropped stitch"
      ;;
    "$LOOM_DIR/threads"/*|"$LOOM_DIR/threads")
      ;;
    *)
      die "stitch '$id' is not under threads/"
      ;;
  esac

  local child
  local unresolved=()
  shopt -s nullglob
  for child in "$src"/*/; do
    child="${child%/}"
    [[ -d "$child" ]] || continue
    unresolved+=("$(basename "$child")")
  done
  shopt -u nullglob

  if (( ${#unresolved[@]} > 0 )); then
    echo "error: cannot tie '$id' — unresolved children in threads/:" >&2
    printf '  - %s\n' "${unresolved[@]}" >&2
    echo "tie or drop each child before tying its parent." >&2
    exit 1
  fi

  local canonical
  canonical="$(strip_state_suffix "$(basename "$src")")"
  local dest="$LOOM_DIR/tied/$canonical"
  [[ ! -e "$dest" ]] || die "destination already exists: $dest"
  mv "$src" "$dest"
  echo "tied $canonical"
}

print_stitch_tree() {
  local dir="$1"
  local prefix="${2:-}"
  local entries=()
  local entry
  shopt -s nullglob
  for entry in "$dir"/*; do
    [[ -d "$entry" ]] || continue
    entries+=("$entry")
  done
  shopt -u nullglob

  local count="${#entries[@]}"
  local i=0
  for entry in "${entries[@]}"; do
    i=$((i + 1))
    local name
    name="$(basename "$entry")"
    local branch="├──"
    local child_prefix="│   "
    if (( i == count )); then
      branch="└──"
      child_prefix="    "
    fi
    local tag=""
    if [[ "$name" == *.stitching ]]; then
      tag=" (claimed)"
    elif has_child_dirs "$entry"; then
      :
    else
      tag=" (leaf)"
    fi
    printf '%s%s %s%s\n' "$prefix" "$branch" "$name" "$tag"
    print_stitch_tree "$entry" "$prefix$child_prefix"
  done
}

has_child_dirs() {
  local dir="$1"
  local child
  shopt -s nullglob
  for child in "$dir"/*/; do
    shopt -u nullglob
    return 0
  done
  shopt -u nullglob
  return 1
}

list_goals() {
  find "$LOOM_DIR/threads" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

list_unclaimed_leaves() {
  find "$LOOM_DIR/threads" -mindepth 1 -type d ! -name '*.stitching' | while read -r dir; do
    local base
    base="$(basename "$dir")"
    [[ "$base" == *.stitching ]] && continue
    if ! has_child_dirs "$dir"; then
      printf '%s\n' "${dir#$LOOM_DIR/threads/}"
    fi
  done | sort
}

list_claimed() {
  find "$LOOM_DIR/threads" -mindepth 1 -type d -name '*.stitching' | while read -r dir; do
    printf '%s\n' "${dir#$LOOM_DIR/threads/}"
  done | sort
}

count_entries() {
  local dir="$1"
  find "$dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

cmd_status() {
  require_loom

  echo "🎯 goals"
  if [[ -n "$(list_goals)" ]]; then
    list_goals | sed 's/^/- /'
  else
    echo "(none)"
  fi

  echo
  echo "🍃 unclaimed leaves (ready to work)"
  local leaves
  leaves="$(list_unclaimed_leaves)"
  if [[ -n "$leaves" ]]; then
    printf '%s\n' "$leaves" | sed 's/^/- /'
  else
    echo "(none)"
  fi

  echo
  echo "🧵 claimed"
  local claimed
  claimed="$(list_claimed)"
  if [[ -n "$claimed" ]]; then
    printf '%s\n' "$claimed" | sed 's/^/- /'
  else
    echo "(none)"
  fi

  echo
  echo "🌳 tree"
  if find "$LOOM_DIR/threads" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    print_stitch_tree "$LOOM_DIR/threads"
  else
    echo "(empty)"
  fi

  echo
  printf '✅ tied: %s\n' "$(count_entries "$LOOM_DIR/tied")"
  printf '🗑️  dropped: %s\n' "$(count_entries "$LOOM_DIR/dropped")"
}

cmd_tips() {
  require_loom
  local leaves
  leaves="$(list_unclaimed_leaves)"
  if [[ -n "$leaves" ]]; then
    printf '%s\n' "$leaves"
  fi
}

cmd_drop() {
  require_loom
  local id="${1:-}"
  shift || true
  [[ -n "$id" ]] || die "drop requires <stitch-id>"
  validate_id "$id"

  local src
  src="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$src" ]] || die "stitch '$id' not found"
  case "$src" in
    "$LOOM_DIR/tied"/*)
      die "cannot drop a tied stitch"
      ;;
    "$LOOM_DIR/dropped"/*)
      echo "already dropped: $id"
      return 0
      ;;
  esac

  local canonical
  canonical="$(strip_state_suffix "$(basename "$src")")"
  local dest="$LOOM_DIR/dropped/$canonical"
  [[ ! -e "$dest" ]] || die "destination already exists: $dest"
  mv "$src" "$dest"

  local reason_file="$LOOM_DIR/dropped/$canonical.reason.md"
  {
    echo "# why $canonical was dropped"
    echo
    if (( $# > 0 )); then
      printf '%s\n' "$*"
    else
      echo "Add the reason here."
    fi
  } > "$reason_file"

  echo "dropped $canonical"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    init)
      shift
      cmd_init "$@"
      ;;
    new)
      shift
      cmd_new "$@"
      ;;
    add)
      shift
      cmd_new "$@"
      ;;
    claim)
      shift
      cmd_claim "$@"
      ;;
    tie)
      shift
      cmd_tie "$@"
      ;;
    drop)
      shift
      cmd_drop "$@"
      ;;
    tips)
      shift
      cmd_tips "$@"
      ;;
    status)
      shift
      cmd_status "$@"
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      die "unknown command '$cmd'"
      ;;
  esac
}

main "$@"
