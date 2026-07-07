#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage:
  loom.sh init
  loom.sh new <stitch-id> [parent-stitch-id]
  loom.sh claim <stitch-id>
  loom.sh tend <stitch-id>
  loom.sh release <stitch-id>
  loom.sh wait <stitch-id>
  loom.sh tie <stitch-id>
  loom.sh drop <stitch-id> [reason...]
  loom.sh loose-ends
  loom.sh tending
  loom.sh waiting
  loom.sh next
  loom.sh status
  loom.sh sweep [days]

notes:
  - this script operates on the .loom/ directory it lives in
  - stitches are directories with an instructions.md file
  - root entries in .loom/threads/ are goal stitches
  - child stitches are the decomposition of their parent
  - a stitch with no children is a loose end — the work ready now
  - .stitching means claimed; .waiting means blocked on something external
  - .tending means a child-bearing stitch has a steward; children stay claimable
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
  local state
  for state in stitching waiting tending; do
    name="${name%.$state}"
  done
  printf '%s\n' "$name"
}

state_of_name() {
  local name="$1"
  local state
  for state in stitching waiting tending; do
    if [[ "$name" == *".$state" ]]; then
      printf '%s\n' "$state"
      return 0
    fi
  done
  printf 'plain\n'
}

state_label() {
  case "$1" in
    stitching) printf 'claimed\n' ;;
    waiting) printf 'waiting\n' ;;
    tending) printf 'tended\n' ;;
    plain) printf 'loose end\n' ;;
  esac
}

ensure_under_threads() {
  local dir="$1" id="$2"
  case "$dir" in
    "$LOOM_DIR/tied"/*)
      die "cannot $3 a tied stitch"
      ;;
    "$LOOM_DIR/dropped"/*)
      die "cannot $3 a dropped stitch"
      ;;
    "$LOOM_DIR/threads"/*|"$LOOM_DIR/threads")
      ;;
    *)
      die "stitch '$id' is not under threads/"
      ;;
  esac
}

set_stitch_state() {
  local id="$1" new_state="$2" scope="$3" action="$4" already="$5" output="$6"
  local existing name current parent_dir dest

  existing="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$existing" ]] || die "stitch '$id' not found"
  ensure_under_threads "$existing" "$id" "$action"

  name="$(basename "$existing")"
  current="$(state_of_name "$name")"
  if [[ "$current" == "$new_state" ]]; then
    echo "$already: $id"
    return 0
  fi

  if [[ "$current" == tending ]]; then
    die "'$id' is tended. release it before you $action it."
  fi

  case "$scope" in
    loose)
      if has_child_dirs "$existing"; then
        die "'$id' is not a loose end — it has children. only loose ends can $action."
      fi
      ;;
    parent)
      if ! has_child_dirs "$existing"; then
        die "'$id' has no children. only child-bearing stitches can $action."
      fi
      ;;
    *)
      die "unknown state scope '$scope'"
      ;;
  esac

  parent_dir="$(dirname "$existing")"
  dest="$parent_dir/$id.$new_state"
  [[ ! -e "$dest" ]] || die "destination already exists: $dest"
  mv "$existing" "$dest"
  echo "$output $id"
}

find_stitch_anywhere() {
  local id="$1"
  local base="$2"
  find "$base" \
    -type d \
    \( -name "$id" -o -name "$id.stitching" -o -name "$id.waiting" -o -name "$id.tending" \) \
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
  require_loom
  mkdir -p "$LOOM_DIR/threads" "$LOOM_DIR/tied" "$LOOM_DIR/dropped"
  echo "initialized $LOOM_DIR"
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

    local parent_base
    parent_base="$(basename "$parent")"
    local parent_state
    parent_state="$(state_of_name "$parent_base")"
    if [[ "$parent_state" != plain && "$parent_state" != tending ]]; then
      local parent_dir unsuffixed
      parent_dir="$(dirname "$parent")"
      unsuffixed="$parent_dir/$parent_id"
      mv "$parent" "$unsuffixed"
      parent="$unsuffixed"
    fi

    target_parent="$parent"
  fi

  local created
  created="$(create_stitch_dir "$target_parent" "$id")"
  echo "new $created"
  echo "next: read, then edit $created/instructions.md (agent harnesses refuse to overwrite unread files)"
}

cmd_claim() {
  require_loom
  local id="${1:-}"
  [[ -n "$id" ]] || die "claim requires <stitch-id>"
  validate_id "$id"
  set_stitch_state "$id" stitching loose claim "already stitching" claimed
}

cmd_tend() {
  require_loom
  local id="${1:-}"
  [[ -n "$id" ]] || die "tend requires <stitch-id>"
  validate_id "$id"
  set_stitch_state "$id" tending parent tend "already tending" "tending"
}

cmd_release() {
  require_loom
  local id="${1:-}"
  [[ -n "$id" ]] || die "release requires <stitch-id>"
  validate_id "$id"

  local existing name current parent_dir dest
  existing="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$existing" ]] || die "stitch '$id' not found"
  ensure_under_threads "$existing" "$id" release

  name="$(basename "$existing")"
  current="$(state_of_name "$name")"
  if [[ "$current" == plain ]]; then
    echo "already released: $id"
    return 0
  fi
  [[ "$current" == tending ]] || die "'$id' is not tended"

  parent_dir="$(dirname "$existing")"
  dest="$parent_dir/$id"
  [[ ! -e "$dest" ]] || die "destination already exists: $dest"
  mv "$existing" "$dest"
  echo "released $id"
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
    local state
    state="$(state_of_name "$name")"
    if [[ "$state" != plain ]]; then
      tag=" ($(state_label "$state"))"
    elif has_child_dirs "$entry"; then
      :
    else
      tag=" (loose end)"
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
  find "$LOOM_DIR/threads" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

list_loose_ends() {
  find "$LOOM_DIR/threads" -mindepth 1 -type d | while read -r dir; do
    local base
    base="$(basename "$dir")"
    [[ "$(state_of_name "$base")" == plain ]] || continue
    if ! has_child_dirs "$dir"; then
      printf '%s\n' "${dir#$LOOM_DIR/threads/}"
    fi
  done | sort
}

list_claimed() {
  list_by_state stitching
}

list_waiting() {
  list_by_state waiting
}

list_tending() {
  list_by_state tending
}

list_by_state() {
  local state="$1" scope="${2:-any}"
  local maxdepth=()
  if [[ "$scope" == goal ]]; then
    maxdepth=(-maxdepth 1)
  fi

  find "$LOOM_DIR/threads" -mindepth 1 "${maxdepth[@]}" -type d -name "*.$state" | while read -r dir; do
    printf '%s\n' "${dir#$LOOM_DIR/threads/}"
  done | sort
}

count_entries() {
  local dir="$1"
  find "$dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

cmd_status() {
  require_loom

  echo "🎯 goal stitches"
  if [[ -n "$(list_goals)" ]]; then
    list_goals | sed 's/^/- /'
  else
    echo "(none)"
  fi

  echo
  echo "➰ loose ends (ready to work)"
  local loose
  loose="$(list_loose_ends)"
  if [[ -n "$loose" ]]; then
    printf '%s\n' "$loose" | sed 's/^/- /'
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
  echo "🪡 tending (stewardship; children remain claimable)"
  local tending
  tending="$(list_tending)"
  if [[ -n "$tending" ]]; then
    printf '%s\n' "$tending" | sed 's/^/- /'
  else
    echo "(none)"
  fi

  echo
  echo "⏳ waiting"
  local waiting
  waiting="$(list_waiting)"
  if [[ -n "$waiting" ]]; then
    printf '%s\n' "$waiting" | sed 's/^/- /'
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

cmd_loose_ends() {
  require_loom
  local loose
  loose="$(list_loose_ends)"
  if [[ -n "$loose" ]]; then
    printf '%s\n' "$loose"
  fi
}

cmd_waiting() {
  require_loom
  list_waiting
}

cmd_tending() {
  require_loom
  list_tending
}

cmd_next() {
  require_loom
  list_loose_ends | head -n 1
}

cmd_wait() {
  require_loom
  local id="${1:-}"
  [[ -n "$id" ]] || die "wait requires <stitch-id>"
  validate_id "$id"
  set_stitch_state "$id" waiting loose wait "already waiting" waiting
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
  if (( $# == 0 )); then
    echo "next: read, then edit $reason_file (agent harnesses refuse to overwrite unread files)"
  fi
}

sweep_dir() {
  local dir="$1" kind="$2" days="$3"
  [[ -d "$dir" ]] || return 0
  local entry name
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="$(basename "$entry")"
    rm -rf -- "$entry"
    if [[ "$kind" == "dropped" && -e "$dir/$name.reason.md" ]]; then
      rm -f -- "$dir/$name.reason.md"
    fi
    printf 'swept %s %s\n' "$kind" "$name"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -mtime +"$days" \
             ! -name '*.reason.md' | sort)
}

cmd_sweep() {
  require_loom
  local days="${1:-14}"
  [[ "$days" =~ ^[0-9]+$ ]] || die "sweep <days> must be a non-negative integer"
  sweep_dir "$LOOM_DIR/tied" tied "$days"
  sweep_dir "$LOOM_DIR/dropped" dropped "$days"
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
    tend)
      shift
      cmd_tend "$@"
      ;;
    release)
      shift
      cmd_release "$@"
      ;;
    wait)
      shift
      cmd_wait "$@"
      ;;
    tie)
      shift
      cmd_tie "$@"
      ;;
    drop)
      shift
      cmd_drop "$@"
      ;;
    loose-ends)
      shift
      cmd_loose_ends "$@"
      ;;
    waiting)
      shift
      cmd_waiting "$@"
      ;;
    tending)
      shift
      cmd_tending "$@"
      ;;
    next)
      shift
      cmd_next "$@"
      ;;
    status)
      shift
      cmd_status "$@"
      ;;
    sweep)
      shift
      cmd_sweep "$@"
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
