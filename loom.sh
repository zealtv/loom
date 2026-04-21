#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage:
  loom.sh init
  loom.sh new <stitch-id> [after-stitch-id]
  loom.sh claim <stitch-id>
  loom.sh tie <stitch-id>
  loom.sh drop <stitch-id> [reason...]
  loom.sh status

notes:
  - this script operates on the .loom/ directory it lives in
  - stitches are directories with an instructions.md file
  - root entries in .loom/threads/ are ready now
  - child stitch directories are continuations
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
  local after_id="${2:-}"
  [[ -n "$id" ]] || die "new requires <stitch-id>"
  validate_id "$id"
  ensure_unique_new_id "$id"

  local target_parent
  if [[ -z "$after_id" ]]; then
    target_parent="$LOOM_DIR/threads"
  else
    validate_id "$after_id"
    local predecessor
    predecessor="$(find_unique_stitch_anywhere "$after_id" || true)"
    [[ -n "$predecessor" ]] || die "predecessor '$after_id' not found"

    case "$predecessor" in
      "$LOOM_DIR/dropped"/*)
        die "cannot continue from dropped stitch '$after_id'"
        ;;
      "$LOOM_DIR/tied"/*)
        target_parent="$LOOM_DIR/threads"
        ;;
      *)
        target_parent="$predecessor"
        ;;
    esac
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

  local plain="$LOOM_DIR/threads/$id"
  local claimed="$LOOM_DIR/threads/$id.stitching"

  if [[ -d "$claimed" ]]; then
    echo "already stitching: $id"
    return 0
  fi
  [[ -d "$plain" ]] || die "claim only works on ready stitches at .loom/threads/"
  mv "$plain" "$claimed"
  echo "claimed $id"
}

promote_children() {
  local dir="$1"
  local child
  shopt -s nullglob
  for child in "$dir"/*; do
    [[ -d "$child" ]] || continue
    local name
    name="$(basename "$child")"
    [[ ! -e "$LOOM_DIR/threads/$name" ]] || die "cannot promote '$name': already exists at .loom/threads/"
    mv "$child" "$LOOM_DIR/threads/$name"
  done
  shopt -u nullglob
}

cmd_tie() {
  require_loom
  local id="${1:-}"
  [[ -n "$id" ]] || die "tie requires <stitch-id>"
  validate_id "$id"

  local src
  if [[ -d "$LOOM_DIR/threads/$id.stitching" ]]; then
    src="$LOOM_DIR/threads/$id.stitching"
  elif [[ -d "$LOOM_DIR/threads/$id" ]]; then
    src="$LOOM_DIR/threads/$id"
  else
    die "tie only works on ready stitches at .loom/threads/"
  fi

  local canonical
  canonical="$(strip_state_suffix "$(basename "$src")")"
  promote_children "$src"
  mv "$src" "$LOOM_DIR/tied/$canonical"
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
    printf '%s%s %s\n' "$prefix" "$branch" "$name"
    print_stitch_tree "$entry" "$prefix$child_prefix"
  done
}

cmd_status() {
  require_loom

  echo "🧵 threads"
  if find "$LOOM_DIR/threads" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    print_stitch_tree "$LOOM_DIR/threads"
  else
    echo "(empty)"
  fi

  echo
  echo "✅ tied"
  if find "$LOOM_DIR/tied" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    find "$LOOM_DIR/tied" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | sed 's/^/- /'
  else
    echo "(empty)"
  fi

  echo
  echo "🗑️  dropped"
  if find "$LOOM_DIR/dropped" -mindepth 1 -maxdepth 1 -type d | grep -q .; then
    find "$LOOM_DIR/dropped" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | sed 's/^/- /'
  else
    echo "(empty)"
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
