#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'USAGE'
usage:
  loom.sh init
  loom.sh new <stitch-id> [parent-stitch-id]
  loom.sh claim <stitch-id>
  loom.sh tend <stitch-id>
  loom.sh release <stitch-id>
  loom.sh wait <stitch-id>
  loom.sh resume <stitch-id>
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
  - .stitching means claimed; .waiting explicitly parks a stitch and its subtree
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

is_valid_id() {
  local id="$1"
  [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  local state
  for state in stitching waiting tending tied dropped; do
    [[ "$id" != *".$state" ]] || return 1
  done
  return 0
}

validate_id() {
  local id="$1"
  is_valid_id "$id" ||
    die "invalid stitch id '$id' (use letters, numbers, ., _, - and no reserved state suffix)"
}

strip_state_suffix() {
  local name="$1"
  local state
  for state in stitching waiting tending tied dropped; do
    if [[ "$name" == *".$state" ]]; then
      printf '%s\n' "${name%.$state}"
      return 0
    fi
  done
  printf '%s\n' "$name"
}

state_of_name() {
  local name="$1"
  local state
  for state in stitching waiting tending tied dropped; do
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
    tied) printf 'tied\n' ;;
    dropped) printf 'dropped\n' ;;
    plain) printf 'loose end\n' ;;
  esac
}

recognized_children() {
  local dir="$1"
  local entry
  shopt -s nullglob
  for entry in "$dir"/*; do
    [[ -d "$entry" && -f "$entry/instructions.md" ]] || continue
    printf '%s\n' "$entry"
  done
  shopt -u nullglob
}

walk_recognized() {
  local dir="$1"
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    printf '%s\n' "$entry"
    walk_recognized "$entry"
  done < <(recognized_children "$dir")
}

walk_all_stitches() {
  local tray
  for tray in threads tied dropped; do
    [[ -d "$LOOM_DIR/$tray" ]] || continue
    walk_recognized "$LOOM_DIR/$tray"
  done
}

has_terminal_ancestor() {
  local dir="$1"
  local parent
  parent="$(dirname "$dir")"
  while [[ "$parent" != "$LOOM_DIR/threads" ]]; do
    case "$(state_of_name "$(basename "$parent")")" in
      tied|dropped) return 0 ;;
    esac
    parent="$(dirname "$parent")"
  done
  return 1
}

has_waiting_ancestor() {
  local dir="$1"
  local parent
  parent="$(dirname "$dir")"
  while [[ "$parent" != "$LOOM_DIR/threads" ]]; do
    if [[ "$(state_of_name "$(basename "$parent")")" == waiting ]]; then
      printf '%s\n' "$parent"
      return 0
    fi
    parent="$(dirname "$parent")"
  done
  return 1
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
  if [[ "$current" == tied || "$current" == dropped ]]; then
    die "cannot $action terminal stitch '$id' ($current)"
  fi
  has_terminal_ancestor "$existing" &&
    die "cannot $action abandoned stitch '$id' beneath a terminal ancestor"

  if [[ "$current" == tending ]]; then
    die "'$id' is tended. release it before you $action it."
  fi

  case "$scope" in
    loose)
      if has_unresolved_children "$existing"; then
        die "'$id' is not a loose end — it has unresolved children. only loose ends can $action."
      fi
      ;;
    parent)
      if ! has_unresolved_children "$existing"; then
        die "'$id' has no children requiring work. only child-bearing stitches can $action."
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
  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    if [[ "$(strip_state_suffix "$(basename "$dir")")" == "$id" ]]; then
      printf '%s\n' "$dir"
    fi
  done < <(walk_all_stitches)
}

find_unique_stitch_anywhere() {
  local id="$1"
  local matches
  mapfile -t matches < <(find_stitch_anywhere "$id")
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
  local matches
  mapfile -t matches < <(find_stitch_anywhere "$id")
  if (( ${#matches[@]} > 0 )); then
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
  local had_v1_entries=false tray entry
  if [[ ! -e "$LOOM_DIR/format-version" ]]; then
    for tray in threads tied dropped; do
      [[ -d "$LOOM_DIR/$tray" ]] || continue
      shopt -s nullglob dotglob
      for entry in "$LOOM_DIR/$tray"/*; do
        had_v1_entries=true
        break 2
      done
      shopt -u nullglob dotglob
    done
    shopt -u nullglob dotglob
  fi
  mkdir -p "$LOOM_DIR/threads" "$LOOM_DIR/tied" "$LOOM_DIR/dropped"
  if [[ ! -e "$LOOM_DIR/format-version" && "$had_v1_entries" == false ]]; then
    printf '2\n' > "$LOOM_DIR/format-version"
  fi
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
    has_terminal_ancestor "$parent" &&
      die "cannot add child beneath terminal ancestor of '$parent_id'"

    local parent_base
    parent_base="$(basename "$parent")"
    local parent_state
    parent_state="$(state_of_name "$parent_base")"
    if [[ "$parent_state" == tied || "$parent_state" == dropped ]]; then
      die "cannot add child to terminal stitch '$parent_id'"
    fi
    if [[ "$parent_state" == stitching ]]; then
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

  local existing waiting_ancestor waiting_id
  existing="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$existing" ]] || die "stitch '$id' not found"
  if [[ "$(state_of_name "$(basename "$existing")")" == waiting ]]; then
    die "'$id' is waiting. run 'loom resume $id' before claiming it."
  fi
  waiting_ancestor="$(has_waiting_ancestor "$existing" || true)"
  if [[ -n "$waiting_ancestor" ]]; then
    waiting_id="$(strip_state_suffix "$(basename "$waiting_ancestor")")"
    die "'$id' is beneath waiting stitch '$waiting_id'. run 'loom resume $waiting_id' first."
  fi
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

write_completed_at() {
  local dir="$1"
  local offset timestamp tmp
  offset="$(date +%z)"
  timestamp="$(date +"%Y-%m-%dT%H:%M:%S")${offset:0:3}:${offset:3:2}"
  tmp="$dir/.completed-at.tmp.$$"
  printf '%s\n' "$timestamp" > "$tmp"
  mv "$tmp" "$dir/completed-at"
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

  local direct_state
  direct_state="$(state_of_name "$(basename "$src")")"
  if [[ "$direct_state" == tied ]]; then
    echo "already tied: $id"
    return 0
  fi
  [[ "$direct_state" != dropped ]] || die "cannot tie a dropped stitch"
  [[ "$direct_state" != waiting ]] || die "cannot tie a waiting stitch"
  has_terminal_ancestor "$src" &&
    die "cannot tie abandoned stitch '$id' beneath a terminal ancestor"

  local child child_state
  local unresolved=()
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    child_state="$(state_of_name "$(basename "$child")")"
    if [[ "$child_state" != tied && "$child_state" != dropped ]]; then
      unresolved+=("$(strip_state_suffix "$(basename "$child")")")
    fi
  done < <(recognized_children "$src")

  if (( ${#unresolved[@]} > 0 )); then
    echo "error: cannot tie '$id' — unresolved child stitches:" >&2
    printf '  - %s\n' "${unresolved[@]}" >&2
    echo "tie or drop each child before tying its parent." >&2
    exit 1
  fi

  local canonical parent_dir
  canonical="$(strip_state_suffix "$(basename "$src")")"
  parent_dir="$(dirname "$src")"
  local dest
  if [[ "$parent_dir" == "$LOOM_DIR/threads" ]]; then
    dest="$LOOM_DIR/tied/$canonical"
  else
    dest="$parent_dir/$canonical.tied"
  fi
  [[ ! -e "$dest" ]] || die "destination already exists: $dest"
  write_completed_at "$src"
  mv "$src" "$dest"
  echo "tied $canonical"
}

print_stitch_tree() {
  local dir="$1"
  local prefix="${2:-}"
  local abandoned="${3:-false}"
  local waiting_inherited="${4:-false}"
  local entries=()
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    entries+=("$entry")
  done < <(recognized_children "$dir")

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
    local child_abandoned="$abandoned"
    local child_waiting="$waiting_inherited"
    if [[ "$abandoned" == true ]]; then
      tag=" (abandoned)"
    elif [[ "$state" != plain ]]; then
      tag=" ($(state_label "$state"))"
      if [[ "$state" == dropped ]]; then
        child_abandoned=true
      elif [[ "$state" == waiting ]]; then
        child_waiting=true
      fi
      if [[ "$waiting_inherited" == true && "$state" != waiting &&
            "$state" != tied && "$state" != dropped ]]; then
        tag="${tag%)}; waiting inherited)"
      fi
    elif [[ "$waiting_inherited" == true ]]; then
      tag=" (waiting inherited)"
    elif has_unresolved_children "$entry"; then
      :
    else
      tag=" (loose end)"
    fi
    printf '%s%s %s%s\n' "$prefix" "$branch" "$name" "$tag"
    print_stitch_tree \
      "$entry" "$prefix$child_prefix" "$child_abandoned" "$child_waiting"
  done
}

has_unresolved_children() {
  local dir="$1"
  local child state
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    state="$(state_of_name "$(basename "$child")")"
    if [[ "$state" != tied && "$state" != dropped ]]; then
      return 0
    fi
  done < <(recognized_children "$dir")
  return 1
}

list_goals() {
  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    basename "$dir"
  done < <(recognized_children "$LOOM_DIR/threads")
}

list_loose_ends() {
  local dir base
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    base="$(basename "$dir")"
    [[ "$(state_of_name "$base")" == plain ]] || continue
    has_terminal_ancestor "$dir" && continue
    [[ -n "$(has_waiting_ancestor "$dir" || true)" ]] && continue
    if ! has_unresolved_children "$dir"; then
      printf '%s\n' "${dir#$LOOM_DIR/threads/}"
    fi
  done < <(walk_recognized "$LOOM_DIR/threads")
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
  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    [[ "$(state_of_name "$(basename "$dir")")" == "$state" ]] || continue
    has_terminal_ancestor "$dir" && continue
    if [[ "$scope" == goal && "$(dirname "$dir")" != "$LOOM_DIR/threads" ]]; then
      continue
    fi
    printf '%s\n' "${dir#$LOOM_DIR/threads/}"
  done < <(walk_recognized "$LOOM_DIR/threads")
}

count_entries() {
  local dir="$1"
  local count=0 entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    count=$((count + 1))
  done < <(recognized_children "$dir")
  printf '%s\n' "$count"
}

validate_unique_ids() {
  local dir id
  local failed=0
  declare -A first_path=()
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    id="$(strip_state_suffix "$(basename "$dir")")"
    if ! is_valid_id "$id"; then
      echo "error: malformed stitch directory '${dir#$LOOM_DIR/}'" >&2
      failed=1
      continue
    fi
    if [[ -n "${first_path[$id]:-}" ]]; then
      echo "error: duplicate stitch id '$id':" >&2
      printf '  - %s\n  - %s\n' \
        "${first_path[$id]#$LOOM_DIR/}" "${dir#$LOOM_DIR/}" >&2
      failed=1
    else
      first_path["$id"]="$dir"
    fi
  done < <(walk_all_stitches)
  (( failed == 0 ))
}

cmd_status() {
  require_loom
  local health=0
  validate_unique_ids || health=1

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
  if [[ -n "$(recognized_children "$LOOM_DIR/threads")" ]]; then
    print_stitch_tree "$LOOM_DIR/threads"
  else
    echo "(empty)"
  fi

  echo
  printf '✅ tied: %s\n' "$(count_entries "$LOOM_DIR/tied")"
  printf '🗑️  dropped: %s\n' "$(count_entries "$LOOM_DIR/dropped")"
  return "$health"
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

  local existing current parent_dir dest descendant descendant_path descendant_id
  local conflicts=()
  existing="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$existing" ]] || die "stitch '$id' not found"
  ensure_under_threads "$existing" "$id" wait

  current="$(state_of_name "$(basename "$existing")")"
  if [[ "$current" == waiting ]]; then
    echo "already waiting: $id"
    return 0
  fi
  if [[ "$current" == tied || "$current" == dropped ]]; then
    die "cannot wait terminal stitch '$id' ($current)"
  fi
  has_terminal_ancestor "$existing" &&
    die "cannot wait abandoned stitch '$id' beneath a terminal ancestor"

  while IFS= read -r descendant; do
    [[ -n "$descendant" ]] || continue
    [[ "$(state_of_name "$(basename "$descendant")")" == stitching ]] ||
      continue
    descendant_id="$(strip_state_suffix "$(basename "$descendant")")"
    descendant_path="${descendant#$LOOM_DIR/threads/}"
    conflicts+=("$descendant_id ($descendant_path)")
  done < <(walk_recognized "$existing")

  if (( ${#conflicts[@]} > 0 )); then
    echo "error: cannot wait '$id' — claimed descendant stitches:" >&2
    printf '  - %s\n' "${conflicts[@]}" >&2
    echo "tie, drop, or otherwise relinquish each claim before waiting the subtree." >&2
    exit 1
  fi

  parent_dir="$(dirname "$existing")"
  dest="$parent_dir/$id.waiting"
  [[ ! -e "$dest" ]] || die "destination already exists: $dest"
  mv "$existing" "$dest"
  echo "waiting $id"
}

cmd_resume() {
  require_loom
  local id="${1:-}"
  [[ -n "$id" ]] || die "resume requires <stitch-id>"
  validate_id "$id"

  local existing current parent_dir dest
  existing="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$existing" ]] || die "stitch '$id' not found"
  ensure_under_threads "$existing" "$id" resume
  has_terminal_ancestor "$existing" &&
    die "cannot resume abandoned stitch '$id' beneath a terminal ancestor"

  current="$(state_of_name "$(basename "$existing")")"
  [[ "$current" == waiting ]] ||
    die "'$id' is not directly waiting"

  parent_dir="$(dirname "$existing")"
  dest="$parent_dir/$id"
  [[ ! -e "$dest" ]] || die "destination already exists: $dest"
  mv "$existing" "$dest"
  echo "resumed $id"
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

  local direct_state
  direct_state="$(state_of_name "$(basename "$src")")"
  [[ "$direct_state" != tied ]] || die "cannot drop a tied stitch"
  if [[ "$direct_state" == dropped ]]; then
    echo "already dropped: $id"
    return 0
  fi
  has_terminal_ancestor "$src" &&
    die "cannot drop abandoned stitch '$id' beneath a terminal ancestor"

  local canonical parent_dir
  canonical="$(strip_state_suffix "$(basename "$src")")"
  parent_dir="$(dirname "$src")"
  local dest
  if [[ "$parent_dir" == "$LOOM_DIR/threads" ]]; then
    dest="$LOOM_DIR/dropped/$canonical"
  else
    dest="$parent_dir/$canonical.dropped"
  fi
  [[ ! -e "$dest" ]] || die "destination already exists: $dest"

  local reason_file="$src/reason.md"
  {
    echo "# why $canonical was dropped"
    echo
    if (( $# > 0 )); then
      printf '%s\n' "$*"
    else
      echo "Add the reason here."
    fi
  } > "$reason_file"
  write_completed_at "$src"
  mv "$src" "$dest"

  echo "dropped $canonical"
  if (( $# == 0 )); then
    echo "next: read, then edit $dest/reason.md (agent harnesses refuse to overwrite unread files)"
  fi
}

sweep_dir() {
  local dir="$1" kind="$2" days="$3"
  [[ -d "$dir" ]] || return 0
  local entry name
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ -d "$entry" && -f "$entry/instructions.md" ]] || continue
    name="$(basename "$entry")"
    rm -rf -- "$entry"
    printf 'swept %s %s\n' "$kind" "$name"
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" | sort)
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
    resume)
      shift
      cmd_resume "$@"
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
