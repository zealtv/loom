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
  loom.sh queue <stitch-id>
  loom.sh first <stitch-id>
  loom.sh before <stitch-id> <anchor-stitch-id>
  loom.sh after <stitch-id> <anchor-stitch-id>
  loom.sh unqueue <stitch-id>
  loom.sh loose-ends
  loom.sh tending
  loom.sh waiting
  loom.sh next
  loom.sh status
  loom.sh migrate-v2 [--dry-run|--rollback]
  loom.sh sweep [days]

notes:
  - this script operates on the .loom/ directory it lives in
  - stitches are directories with an instructions.md file
  - root entries in .loom/threads/ are goal stitches
  - child stitches are the decomposition of their parent
  - a loose end is a plain stitch whose children and hard dependencies resolve
  - queue order is a sparse preference; blocked entries never block ready work
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

format_version_state() {
  local marker="$LOOM_DIR/format-version"
  if [[ ! -e "$marker" && ! -L "$marker" ]]; then
    printf 'v1\n'
  elif [[ ! -f "$marker" || -L "$marker" ]]; then
    printf 'invalid\n'
  elif [[ "$(cat "$marker"; printf x)" == $'2\nx' ]]; then
    printf 'v2\n'
  else
    printf 'invalid\n'
  fi
}

loom_has_tray_entries() {
  local tray entry
  for tray in threads tied dropped; do
    [[ -d "$LOOM_DIR/$tray" ]] || continue
    shopt -s nullglob dotglob
    for entry in "$LOOM_DIR/$tray"/*; do
      [[ "$(basename "$entry")" != .gitkeep ]] || continue
      shopt -u nullglob dotglob
      return 0
    done
    shopt -u nullglob dotglob
  done
  return 1
}

require_v2_mutation() {
  local state
  state="$(format_version_state)"
  if [[ -e "$LOOM_DIR/.migrate-v2-staging" ||
        -L "$LOOM_DIR/.migrate-v2-staging" ]]; then
    if [[ "$state" == v2 ]]; then
      die "v2 migration committed but staging cleanup remains; run 'loom.sh migrate-v2' to finish cleanup"
    fi
    die "unfinished v2 migration staging exists; run 'loom.sh migrate-v2' to resume or 'loom.sh migrate-v2 --rollback' to restore v1"
  fi
  case "$state" in
    v2) ;;
    v1)
      if loom_has_tray_entries; then
        die "markerless loom is format v1; inspect with 'loom.sh migrate-v2 --dry-run', then run 'loom.sh migrate-v2'"
      fi
      die "loom has no format marker; run 'loom.sh init' before changing it"
      ;;
    invalid)
      die "invalid format-version marker (expected a regular file containing exactly '2')"
      ;;
  esac
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
  for tray in tied dropped; do
    [[ -d "$LOOM_DIR/legacy-v1/$tray" ]] || continue
    recognized_children "$LOOM_DIR/legacy-v1/$tray"
  done
}

INDEX_BUILT=false
INDEX_ERRORS=()
INDEX_CYCLES=()
QUEUE_LINES=()
QUEUE_IDS=()
QUEUE_ERRORS=()
EDGE_DEPENDENTS=()
EDGE_TARGETS=()
EDGE_STATES=()
EDGE_CAUSES=()
declare -A INDEX_COUNT=()
declare -A INDEX_PATH=()
declare -A INDEX_STATE=()
declare -A INDEX_DIRECT_STATE=()
declare -A INDEX_ROOT=()
declare -A INDEX_PARENT=()
declare -A INDEX_ANCESTORS=()
declare -A INDEX_WAITING_ANCESTOR=()
declare -A INDEX_TERMINAL_ANCESTOR=()
declare -A INDEX_UNRESOLVED_CHILDREN=()
declare -A INDEX_INVALID=()
declare -A INDEX_CYCLIC=()
declare -A QUEUE_POSITION=()
QUEUE_LOCK_DIR=""
QUEUE_TEMP=""

reset_index() {
  INDEX_BUILT=false
  INDEX_ERRORS=()
  INDEX_CYCLES=()
  QUEUE_LINES=()
  QUEUE_IDS=()
  QUEUE_ERRORS=()
  EDGE_DEPENDENTS=()
  EDGE_TARGETS=()
  EDGE_STATES=()
  EDGE_CAUSES=()
  INDEX_COUNT=()
  INDEX_PATH=()
  INDEX_STATE=()
  INDEX_DIRECT_STATE=()
  INDEX_ROOT=()
  INDEX_PARENT=()
  INDEX_ANCESTORS=()
  INDEX_WAITING_ANCESTOR=()
  INDEX_TERMINAL_ANCESTOR=()
  INDEX_UNRESOLVED_CHILDREN=()
  INDEX_INVALID=()
  INDEX_CYCLIC=()
  QUEUE_POSITION=()
}

queue_id_is_active() {
  local id="$1"
  [[ "${INDEX_COUNT[$id]:-0}" == 1 ]] || return 1
  [[ "${INDEX_PATH[$id]}" == "$LOOM_DIR/threads/"* ]] || return 1
  case "${INDEX_STATE[$id]}" in
    tied|dropped|abandoned) return 1 ;;
  esac
  return 0
}

parse_queue() {
  QUEUE_LINES=()
  QUEUE_IDS=()
  QUEUE_ERRORS=()
  QUEUE_POSITION=()
  [[ -f "$LOOM_DIR/queue" ]] || return 0

  mapfile -t QUEUE_LINES < "$LOOM_DIR/queue"
  local line position=0 count
  declare -A seen=()
  for line in "${QUEUE_LINES[@]}"; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    position=$((position + 1))
    QUEUE_IDS+=("$line")
    if ! is_valid_id "$line"; then
      QUEUE_ERRORS+=("invalid queue entry at position $position: '$line'")
      continue
    fi
    if [[ -n "${seen[$line]:-}" ]]; then
      QUEUE_ERRORS+=("duplicate queue entry '$line' at position $position")
      continue
    fi
    seen["$line"]=1
    QUEUE_POSITION["$line"]="$position"
    count="${INDEX_COUNT[$line]:-0}"
    if (( count == 0 )); then
      QUEUE_ERRORS+=("unknown queue entry '$line' at position $position")
    elif (( count > 1 )); then
      QUEUE_ERRORS+=("ambiguous queue entry '$line' at position $position")
    elif ! queue_id_is_active "$line"; then
      QUEUE_ERRORS+=("terminal queue entry '$line' at position $position")
    fi
  done
}

index_effective_state() {
  local dir="$1" direct="$2"
  if [[ "$direct" == tied || "$direct" == dropped ]]; then
    printf '%s\n' "$direct"
    return
  fi

  case "$dir" in
    "$LOOM_DIR/legacy-v1/tied"/*)
      printf 'tied\n'
      return
      ;;
    "$LOOM_DIR/legacy-v1/dropped"/*)
      printf 'dropped\n'
      return
      ;;
    "$LOOM_DIR/tied"/*)
      [[ "$(dirname "$dir")" == "$LOOM_DIR/tied" ]] &&
        { printf 'tied\n'; return; }
      ;;
    "$LOOM_DIR/dropped"/*)
      [[ "$(dirname "$dir")" == "$LOOM_DIR/dropped" ]] &&
        { printf 'dropped\n'; return; }
      printf 'abandoned\n'
      return
      ;;
  esac

  local parent
  parent="$(dirname "$dir")"
  while [[ "$parent" != "$LOOM_DIR/threads" &&
           "$parent" != "$LOOM_DIR/tied" &&
           "$parent" != "$LOOM_DIR/dropped" ]]; do
    if [[ "$(state_of_name "$(basename "$parent")")" == dropped ]]; then
      printf 'abandoned\n'
      return
    fi
    parent="$(dirname "$parent")"
  done
  printf '%s\n' "$direct"
}

index_add_edge() {
  EDGE_DEPENDENTS+=("$1")
  EDGE_TARGETS+=("$2")
  EDGE_STATES+=("$3")
  EDGE_CAUSES+=("$4")
}

index_detect_cycles() {
  local result kind members member
  while IFS=$'\t' read -r kind members; do
    [[ "$kind" == C && -n "$members" ]] || continue
    INDEX_CYCLES+=("$members")
    IFS=',' read -ra cycle_members <<< "$members"
    for member in "${cycle_members[@]}"; do
      INDEX_CYCLIC["$member"]=1
    done
  done < <(
    {
      for member in "${!INDEX_COUNT[@]}"; do
        [[ "${INDEX_COUNT[$member]}" == 1 ]] &&
          printf 'N\t%s\n' "$member"
      done
      local i
      for (( i=0; i<${#EDGE_DEPENDENTS[@]}; i++ )); do
        [[ -n "${INDEX_COUNT[${EDGE_DEPENDENTS[$i]}]:-}" &&
           "${INDEX_COUNT[${EDGE_DEPENDENTS[$i]}]}" == 1 &&
           -n "${INDEX_COUNT[${EDGE_TARGETS[$i]}]:-}" &&
           "${INDEX_COUNT[${EDGE_TARGETS[$i]}]}" == 1 ]] || continue
        printf 'E\t%s\t%s\n' \
          "${EDGE_DEPENDENTS[$i]}" "${EDGE_TARGETS[$i]}"
      done
    } | sort | awk -F '\t' '
      function visit(v,    count, parts, i, w, n, j, tmp, line) {
        next_index++
        dfs_index[v] = next_index
        low[v] = next_index
        stack[++stack_size] = v
        on_stack[v] = 1

        count = split(edges[v], parts, "\034")
        for (i = 1; i <= count; i++) {
          w = parts[i]
          if (w == "")
            continue
          if (!(w in dfs_index)) {
            visit(w)
            if (low[w] < low[v])
              low[v] = low[w]
          } else if (on_stack[w] && dfs_index[w] < low[v]) {
            low[v] = dfs_index[w]
          }
        }

        if (low[v] == dfs_index[v]) {
          n = 0
          do {
            w = stack[stack_size--]
            on_stack[w] = 0
            component[++n] = w
          } while (w != v)
          if (n > 1 || self_edge[v]) {
            for (i = 1; i <= n; i++)
              for (j = i + 1; j <= n; j++)
                if (component[j] < component[i]) {
                  tmp = component[i]
                  component[i] = component[j]
                  component[j] = tmp
                }
            line = component[1]
            for (i = 2; i <= n; i++)
              line = line "," component[i]
            cycles[line] = 1
          }
          for (i = 1; i <= n; i++)
            delete component[i]
        }
      }
      $1 == "N" { nodes[$2] = 1 }
      $1 == "E" {
        nodes[$2] = nodes[$3] = 1
        edges[$2] = edges[$2] "\034" $3
        if ($2 == $3)
          self_edge[$2] = 1
      }
      END {
        for (node in nodes)
          if (!(node in dfs_index))
            visit(node)
        for (cycle in cycles)
          print "C\t" cycle
      }
    ' | sort
  )
}

build_index() {
  reset_index
  local dir name id direct state relative root parent ancestors cursor
  local immediate_parent waiting_ancestor terminal_ancestor
  local all_paths=()

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    all_paths+=("$dir")
    name="$(basename "$dir")"
    id="$(strip_state_suffix "$name")"
    relative="${dir#$LOOM_DIR/}"
    if ! is_valid_id "$id"; then
      INDEX_ERRORS+=("malformed stitch directory '$relative'")
      continue
    fi

    INDEX_COUNT["$id"]=$(( ${INDEX_COUNT[$id]:-0} + 1 ))
    if [[ "${INDEX_COUNT[$id]}" == 1 ]]; then
      direct="$(state_of_name "$name")"
      state="$(index_effective_state "$dir" "$direct")"
      INDEX_PATH["$id"]="$dir"
      INDEX_DIRECT_STATE["$id"]="$direct"
      INDEX_STATE["$id"]="$state"

      cursor="$dir"
      ancestors=""
      parent=""
      immediate_parent=""
      waiting_ancestor=""
      terminal_ancestor=""
      root="$id"
      while :; do
        cursor="$(dirname "$cursor")"
        case "$cursor" in
          "$LOOM_DIR/threads"|"$LOOM_DIR/tied"|"$LOOM_DIR/dropped"|\
          "$LOOM_DIR/legacy-v1/tied"|"$LOOM_DIR/legacy-v1/dropped")
            break
            ;;
        esac
        parent="$(strip_state_suffix "$(basename "$cursor")")"
        [[ -n "$immediate_parent" ]] || immediate_parent="$parent"
        if [[ -z "$waiting_ancestor" &&
              "$(state_of_name "$(basename "$cursor")")" == waiting ]]; then
          waiting_ancestor="$cursor"
        fi
        case "$(state_of_name "$(basename "$cursor")")" in
          tied|dropped)
            [[ -n "$terminal_ancestor" ]] || terminal_ancestor="$cursor"
            ;;
        esac
        ancestors="${parent}${ancestors:+,$ancestors}"
        root="$parent"
      done
      INDEX_PARENT["$id"]="$immediate_parent"
      INDEX_ROOT["$id"]="$root"
      INDEX_ANCESTORS["$id"]="$ancestors"
      INDEX_WAITING_ANCESTOR["$id"]="$waiting_ancestor"
      INDEX_TERMINAL_ANCESTOR["$id"]="$terminal_ancestor"
    else
      INDEX_INVALID["$id"]=1
      INDEX_ERRORS+=("duplicate stitch id '$id': '${INDEX_PATH[$id]#$LOOM_DIR/}' and '$relative'")
    fi
  done < <(walk_all_stitches)

  local child_parent child_state
  for dir in "${all_paths[@]}"; do
    child_parent="$(dirname "$dir")"
    case "$child_parent" in
      "$LOOM_DIR/threads"|"$LOOM_DIR/tied"|"$LOOM_DIR/dropped"|\
      "$LOOM_DIR/legacy-v1/tied"|"$LOOM_DIR/legacy-v1/dropped")
        continue
        ;;
    esac
    parent="$(strip_state_suffix "$(basename "$child_parent")")"
    is_valid_id "$parent" || continue
    child_state="$(state_of_name "$(basename "$dir")")"
    if [[ "$child_state" != tied && "$child_state" != dropped ]]; then
      INDEX_UNRESOLVED_CHILDREN["$parent"]=$(( ${INDEX_UNRESOLVED_CHILDREN[$parent]:-0} + 1 ))
    fi
  done

  local needs entry target target_count edge_state cause
  for dir in "${all_paths[@]}"; do
    id="$(strip_state_suffix "$(basename "$dir")")"
    is_valid_id "$id" || continue
    needs="$dir/needs"
    if [[ -e "$needs" && ! -d "$needs" ]]; then
      INDEX_ERRORS+=("invalid dependency storage for '$id': needs must be a directory")
      INDEX_INVALID["$id"]=1
      continue
    fi
    [[ -d "$needs" ]] || continue
    shopt -s nullglob dotglob
    for entry in "$needs"/*; do
      [[ "$(basename "$entry")" != "." && "$(basename "$entry")" != ".." ]] ||
        continue
      target="$(basename "$entry")"
      if [[ ! -f "$entry" || -L "$entry" ]]; then
        INDEX_ERRORS+=("invalid dependency entry for '$id': every immediate needs/ entry must be a regular file")
        INDEX_INVALID["$id"]=1
        continue
      fi
      if ! is_valid_id "$target"; then
        INDEX_ERRORS+=("invalid dependency '$id -> $target': invalid target id")
        INDEX_INVALID["$id"]=1
        continue
      fi

      edge_state=blocked
      cause=""
      target_count="${INDEX_COUNT[$target]:-0}"
      if [[ "$target" == "$id" ]]; then
        INDEX_ERRORS+=("invalid self-dependency '$id -> $target'")
        INDEX_INVALID["$id"]=1
      fi
      if [[ "$target_count" == 0 ]]; then
        edge_state=broken
        cause=missing
      elif [[ "$target_count" != 1 ]]; then
        edge_state=broken
        cause=ambiguous
      else
        case "${INDEX_STATE[$target]}" in
          tied) edge_state=satisfied ;;
          dropped|abandoned)
            edge_state=broken
            cause=dropped
            ;;
          *) edge_state=blocked ;;
        esac
      fi
      index_add_edge "$id" "$target" "$edge_state" "$cause"
    done
    shopt -u nullglob dotglob
  done

  index_detect_cycles
  parse_queue
  INDEX_BUILT=true
}

ensure_index() {
  [[ "$INDEX_BUILT" == true ]] || build_index
}

index_path_for_id() {
  local id="$1"
  ensure_index
  local count="${INDEX_COUNT[$id]:-0}"
  (( count > 0 )) || return 1
  if (( count > 1 )); then
    die "multiple stitches found for id '$id'"
  fi
  printf '%s\n' "${INDEX_PATH[$id]}"
}

dependencies_ready() {
  local id="$1" i
  [[ -z "${INDEX_INVALID[$id]:-}" ]] || return 1
  [[ -z "${INDEX_CYCLIC[$id]:-}" ]] || return 1
  for (( i=0; i<${#EDGE_DEPENDENTS[@]}; i++ )); do
    [[ "${EDGE_DEPENDENTS[$i]}" == "$id" ]] || continue
    [[ "${EDGE_STATES[$i]}" == satisfied ]] || return 1
  done
  return 0
}

is_effectively_ready() {
  local id="$1" dir="${INDEX_PATH[$1]:-}"
  [[ -n "$dir" && "${INDEX_COUNT[$id]:-0}" == 1 ]] || return 1
  [[ "${INDEX_DIRECT_STATE[$id]}" == plain ]] || return 1
  [[ "${INDEX_STATE[$id]}" == plain ]] || return 1
  [[ "$dir" == "$LOOM_DIR/threads/"* ]] || return 1
  [[ -z "${INDEX_WAITING_ANCESTOR[$id]:-}" ]] || return 1
  (( ${INDEX_UNRESOLVED_CHILDREN[$id]:-0} == 0 )) || return 1
  dependencies_ready "$id"
}

has_terminal_ancestor() {
  local dir="$1"
  if [[ "$INDEX_BUILT" == true ]]; then
    local indexed_id
    indexed_id="$(strip_state_suffix "$(basename "$dir")")"
    [[ -n "${INDEX_TERMINAL_ANCESTOR[$indexed_id]:-}" ]]
    return
  fi
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
  if [[ "$INDEX_BUILT" == true ]]; then
    local indexed_id
    indexed_id="$(strip_state_suffix "$(basename "$dir")")"
    [[ -n "${INDEX_WAITING_ANCESTOR[$indexed_id]:-}" ]] || return 1
    printf '%s\n' "${INDEX_WAITING_ANCESTOR[$indexed_id]}"
    return 0
  fi
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
    "$LOOM_DIR/tied"/*|"$LOOM_DIR/legacy-v1/tied"/*)
      die "cannot $3 a tied stitch"
      ;;
    "$LOOM_DIR/dropped"/*|"$LOOM_DIR/legacy-v1/dropped"/*)
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

find_unique_stitch_anywhere() {
  local id="$1"
  index_path_for_id "$id"
}

ensure_unique_new_id() {
  local id="$1"
  ensure_index
  if (( ${INDEX_COUNT[$id]:-0} > 0 )); then
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
  local state
  state="$(format_version_state)"
  [[ "$state" != invalid ]] ||
    die "invalid format-version marker (expected a regular file containing exactly '2')"
  if [[ -e "$LOOM_DIR/.migrate-v2-staging" ||
        -L "$LOOM_DIR/.migrate-v2-staging" ]]; then
    if [[ "$state" == v2 ]]; then
      die "v2 migration committed but staging cleanup remains; run 'loom.sh migrate-v2' to finish cleanup"
    fi
    die "unfinished v2 migration staging exists; run 'loom.sh migrate-v2' to resume or 'loom.sh migrate-v2 --rollback' to restore v1"
  fi
  local had_v1_entries=false
  loom_has_tray_entries && had_v1_entries=true
  mkdir -p "$LOOM_DIR/threads" "$LOOM_DIR/tied" "$LOOM_DIR/dropped"
  if [[ "$state" == v1 && "$had_v1_entries" == false ]]; then
    local marker_tmp="$LOOM_DIR/.format-version.tmp.$$"
    printf '2\n' > "$marker_tmp"
    mv "$marker_tmp" "$LOOM_DIR/format-version"
  fi
  echo "initialized $LOOM_DIR"
}

cmd_new() {
  require_loom
  require_v2_mutation
  build_index
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
      "$LOOM_DIR/dropped"/*|"$LOOM_DIR/legacy-v1/dropped"/*)
        die "cannot add child to dropped stitch '$parent_id'"
        ;;
      "$LOOM_DIR/tied"/*|"$LOOM_DIR/legacy-v1/tied"/*)
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
  require_v2_mutation
  build_index
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
  if [[ "${INDEX_DIRECT_STATE[$id]}" == plain ]] &&
     ! dependencies_ready "$id"; then
    die "'$id' is not ready — dependency blockage, broken dependency, or dependency cycle"
  fi
  set_stitch_state "$id" stitching loose claim "already stitching" claimed
}

cmd_tend() {
  require_loom
  require_v2_mutation
  build_index
  local id="${1:-}"
  [[ -n "$id" ]] || die "tend requires <stitch-id>"
  validate_id "$id"
  set_stitch_state "$id" tending parent tend "already tending" "tending"
}

cmd_release() {
  require_loom
  require_v2_mutation
  build_index
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
  require_v2_mutation
  build_index
  local id="${1:-}"
  [[ -n "$id" ]] || die "tie requires <stitch-id>"
  validate_id "$id"

  local src
  src="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$src" ]] || die "stitch '$id' not found"

  case "$src" in
    "$LOOM_DIR/tied"/*|"$LOOM_DIR/legacy-v1/tied"/*)
      echo "already tied: $id"
      return 0
      ;;
    "$LOOM_DIR/dropped"/*|"$LOOM_DIR/legacy-v1/dropped"/*)
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
  local waiting_ancestor
  waiting_ancestor="$(has_waiting_ancestor "$src" || true)"
  [[ -z "$waiting_ancestor" ]] ||
    die "cannot tie '$id' beneath waiting stitch '$(strip_state_suffix "$(basename "$waiting_ancestor")")'"

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
  if ! dependencies_ready "$id"; then
    die "cannot tie '$id' — dependency blockage, broken dependency, or dependency cycle"
  fi

  local canonical parent_dir
  local terminal_ids=()
  mapfile -t terminal_ids < <(subtree_stitch_ids "$src")
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
  queue_remove_terminal_ids "${terminal_ids[@]}"
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
    elif is_effectively_ready "$(strip_state_suffix "$name")"; then
      tag=" (loose end)"
    fi
    printf '%s%s %s%s\n' "$prefix" "$branch" "$name" "$tag"
    print_stitch_tree \
      "$entry" "$prefix$child_prefix" "$child_abandoned" "$child_waiting"
  done
}

has_unresolved_children() {
  local dir="$1"
  ensure_index
  local id
  id="$(strip_state_suffix "$(basename "$dir")")"
  (( ${INDEX_UNRESOLVED_CHILDREN[$id]:-0} > 0 ))
}

list_goals() {
  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    basename "$dir"
  done < <(recognized_children "$LOOM_DIR/threads")
}

list_loose_ends() {
  ensure_index
  local dir id
  declare -A emitted=()

  for id in "${QUEUE_IDS[@]}"; do
    [[ -z "${emitted[$id]:-}" ]] || continue
    is_valid_id "$id" || continue
    if is_effectively_ready "$id"; then
      dir="${INDEX_PATH[$id]}"
      printf '%s\n' "${dir#$LOOM_DIR/threads/}"
      emitted["$id"]=1
    fi
  done

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    id="$(strip_state_suffix "$(basename "$dir")")"
    if [[ -z "${emitted[$id]:-}" ]] && is_effectively_ready "$id"; then
      printf '%s\n' "${dir#$LOOM_DIR/threads/}"
    fi
  done < <(walk_recognized "$LOOM_DIR/threads")
}

queue_state_label() {
  local id="$1"
  if ! is_valid_id "$id"; then
    printf 'invalid\n'
  elif (( ${INDEX_COUNT[$id]:-0} == 0 )); then
    printf 'unknown\n'
  elif (( ${INDEX_COUNT[$id]:-0} > 1 )); then
    printf 'ambiguous\n'
  elif ! queue_id_is_active "$id"; then
    printf 'terminal\n'
  elif is_effectively_ready "$id"; then
    printf 'ready\n'
  elif [[ -n "${INDEX_WAITING_ANCESTOR[$id]:-}" ]]; then
    printf 'waiting inherited\n'
  else
    case "${INDEX_DIRECT_STATE[$id]}" in
      stitching) printf 'claimed\n' ;;
      waiting) printf 'waiting\n' ;;
      tending) printf 'tended\n' ;;
      *) printf 'blocked\n' ;;
    esac
  fi
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

cmd_status() {
  require_loom
  build_index
  local health=0
  local diagnostic cycle i
  if (( ${#INDEX_ERRORS[@]} > 0 )); then
    health=1
    echo "❌ structural errors"
    for diagnostic in "${INDEX_ERRORS[@]}"; do
      printf -- '- %s\n' "$diagnostic"
    done
    echo
  fi

  if (( ${#QUEUE_ERRORS[@]} > 0 )); then
    health=1
    echo "📋 queue errors"
    for diagnostic in "${QUEUE_ERRORS[@]}"; do
      printf -- '- %s\n' "$diagnostic"
    done
    echo
  fi

  local has_broken=false
  for (( i=0; i<${#EDGE_DEPENDENTS[@]}; i++ )); do
    [[ "${EDGE_STATES[$i]}" == broken ]] || continue
    if [[ "$has_broken" == false ]]; then
      echo "💔 broken dependencies"
      has_broken=true
    fi
    printf -- '- %s -> %s (%s)\n' \
      "${EDGE_DEPENDENTS[$i]}" "${EDGE_TARGETS[$i]}" "${EDGE_CAUSES[$i]}"
    health=1
  done
  [[ "$has_broken" == false ]] || echo

  local has_blocked=false
  for (( i=0; i<${#EDGE_DEPENDENTS[@]}; i++ )); do
    [[ "${EDGE_STATES[$i]}" == blocked ]] || continue
    if [[ "$has_blocked" == false ]]; then
      echo "⛔ blocked dependencies"
      has_blocked=true
    fi
    printf -- '- %s -> %s (unresolved)\n' \
      "${EDGE_DEPENDENTS[$i]}" "${EDGE_TARGETS[$i]}"
  done
  [[ "$has_blocked" == false ]] || echo

  echo "📋 sparse queue"
  if (( ${#QUEUE_IDS[@]} == 0 )); then
    echo "(empty)"
  else
    local queue_id queue_position=0
    for queue_id in "${QUEUE_IDS[@]}"; do
      queue_position=$((queue_position + 1))
      printf -- '- %s. %s (%s)\n' \
        "$queue_position" "$queue_id" "$(queue_state_label "$queue_id")"
    done
  fi
  echo

  if (( ${#INDEX_CYCLES[@]} > 0 )); then
    echo "🔄 dependency cycles"
    for cycle in "${INDEX_CYCLES[@]}"; do
      printf -- '- %s\n' "${cycle//,/, }"
    done
    echo
    health=1
  fi

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
  build_index
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
  build_index
  local loose
  loose="$(list_loose_ends)"
  [[ -z "$loose" ]] || printf '%s\n' "${loose%%$'\n'*}"
}

queue_cleanup_lock() {
  [[ -z "$QUEUE_TEMP" || ! -e "$QUEUE_TEMP" ]] || rm -f -- "$QUEUE_TEMP"
  [[ -z "$QUEUE_LOCK_DIR" || ! -d "$QUEUE_LOCK_DIR" ]] ||
    rmdir -- "$QUEUE_LOCK_DIR" 2>/dev/null || true
  QUEUE_TEMP=""
  QUEUE_LOCK_DIR=""
}

queue_acquire_lock() {
  QUEUE_LOCK_DIR="$LOOM_DIR/.queue.lock"
  local attempt=0
  until mkdir "$QUEUE_LOCK_DIR" 2>/dev/null; do
    attempt=$((attempt + 1))
    (( attempt < 200 )) ||
      die "timed out waiting for another queue mutation"
    sleep 0.05
  done
  trap queue_cleanup_lock EXIT
  trap 'queue_cleanup_lock; exit 1' HUP INT TERM
}

queue_release_lock() {
  queue_cleanup_lock
  trap - EXIT HUP INT TERM
}

queue_write_lines() {
  local -a lines=("$@")
  QUEUE_TEMP="$(mktemp "$LOOM_DIR/.queue.tmp.XXXXXX")"
  local line
  {
    for line in "${lines[@]}"; do
      printf '%s\n' "$line"
    done
  } > "$QUEUE_TEMP"
  if [[ "${LOOM_TEST_FAIL_QUEUE_WRITE:-}" == before-rename ]]; then
    return 1
  fi
  mv "$QUEUE_TEMP" "$LOOM_DIR/queue"
  QUEUE_TEMP=""
}

queue_validate_records_for_mutation() {
  local exempt="${1:-}"
  local line count
  declare -A seen=()
  for line in "${QUEUE_IDS[@]}"; do
    if ! is_valid_id "$line"; then
      die "cannot update queue: invalid entry '$line'"
    fi
    [[ -z "${seen[$line]:-}" ]] || continue
    seen["$line"]=1
    [[ "$line" != "$exempt" ]] || continue
    count="${INDEX_COUNT[$line]:-0}"
    (( count > 0 )) ||
      die "cannot update queue: unknown entry '$line'"
    (( count == 1 )) ||
      die "cannot update queue: ambiguous entry '$line'"
    queue_id_is_active "$line" ||
      die "cannot update queue: terminal entry '$line'"
  done
}

queue_require_active_id() {
  local id="$1"
  validate_id "$id"
  local count="${INDEX_COUNT[$id]:-0}"
  (( count > 0 )) || die "unknown active stitch '$id'"
  (( count == 1 )) || die "ambiguous stitch id '$id'"
  queue_id_is_active "$id" ||
    die "stitch '$id' is terminal or archived, not active"
}

cmd_queue_mutation() {
  local action="$1"
  shift
  require_loom
  require_v2_mutation
  build_index

  local id="${1:-}" anchor="${2:-}"
  case "$action" in
    queue|first|unqueue)
      (( $# == 1 )) || die "$action requires <stitch-id>"
      ;;
    before|after)
      (( $# == 2 )) || die "$action requires <stitch-id> <anchor-stitch-id>"
      ;;
  esac

  if [[ "$action" == unqueue ]]; then
    validate_id "$id"
  else
    queue_require_active_id "$id"
  fi
  if [[ "$action" == before || "$action" == after ]]; then
    validate_id "$anchor"
    [[ "$id" != "$anchor" ]] ||
      die "$action requires different stitch and anchor IDs"
  fi

  queue_acquire_lock
  # Rebuild after taking the lock so a concurrent lifecycle operation cannot
  # make the target terminal between our initial command check and this write.
  build_index
  if [[ "$action" != unqueue ]]; then
    queue_require_active_id "$id"
  fi
  queue_validate_records_for_mutation \
    "$([[ "$action" == unqueue ]] && printf '%s' "$id")"

  if [[ "$action" == before || "$action" == after ]]; then
    local anchor_found=false queued_id
    for queued_id in "${QUEUE_IDS[@]}"; do
      if [[ "$queued_id" == "$anchor" ]]; then
        anchor_found=true
        break
      fi
    done
    [[ "$anchor_found" == true ]] ||
      die "queue anchor '$anchor' not found"
  fi

  local -a filtered=()
  local line inserted=false
  declare -A retained=()
  for line in "${QUEUE_LINES[@]}"; do
    if [[ -z "$line" || "$line" == \#* ]]; then
      filtered+=("$line")
      continue
    fi
    [[ "$line" != "$id" ]] || continue
    [[ -z "${retained[$line]:-}" ]] || continue
    retained["$line"]=1
    if [[ "$action" == before && "$line" == "$anchor" ]]; then
      filtered+=("$id")
      inserted=true
    fi
    filtered+=("$line")
    if [[ "$action" == after && "$line" == "$anchor" ]]; then
      filtered+=("$id")
      inserted=true
    fi
  done

  case "$action" in
    first) filtered=("$id" "${filtered[@]}") ;;
    queue) filtered+=("$id") ;;
    before|after)
      [[ "$inserted" == true ]] ||
        die "queue anchor '$anchor' could not be positioned"
      ;;
  esac

  queue_write_lines "${filtered[@]}" ||
    die "injected queue write failure before atomic rename"
  queue_release_lock
  echo "$action $id"
}

queue_remove_terminal_ids() {
  (( $# > 0 )) || return 0
  [[ -f "$LOOM_DIR/queue" ]] || return 0
  local -a removed_ids=("$@")
  queue_acquire_lock
  mapfile -t QUEUE_LINES < "$LOOM_DIR/queue"
  local -a retained=()
  local line removed
  for line in "${QUEUE_LINES[@]}"; do
    removed=false
    local id
    for id in "${removed_ids[@]}"; do
      if [[ "$line" == "$id" ]]; then
        removed=true
        break
      fi
    done
    [[ "$removed" == true ]] || retained+=("$line")
  done
  queue_write_lines "${retained[@]}" ||
    die "failed to clean terminal stitches from queue"
  queue_release_lock
}

subtree_stitch_ids() {
  local root="$1" dir
  printf '%s\n' "$(strip_state_suffix "$(basename "$root")")"
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    printf '%s\n' "$(strip_state_suffix "$(basename "$dir")")"
  done < <(walk_recognized "$root")
}

cmd_wait() {
  require_loom
  require_v2_mutation
  build_index
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
  require_v2_mutation
  build_index
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
  require_v2_mutation
  build_index
  local id="${1:-}"
  shift || true
  [[ -n "$id" ]] || die "drop requires <stitch-id>"
  validate_id "$id"

  local src
  src="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$src" ]] || die "stitch '$id' not found"
  case "$src" in
    "$LOOM_DIR/tied"/*|"$LOOM_DIR/legacy-v1/tied"/*)
      die "cannot drop a tied stitch"
      ;;
    "$LOOM_DIR/dropped"/*|"$LOOM_DIR/legacy-v1/dropped"/*)
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
  local terminal_ids=()
  mapfile -t terminal_ids < <(subtree_stitch_ids "$src")
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
  queue_remove_terminal_ids "${terminal_ids[@]}"

  echo "dropped $canonical"
  if (( $# == 0 )); then
    echo "next: read, then edit $dest/reason.md (agent harnesses refuse to overwrite unread files)"
  fi
}

MIGRATION_KINDS=()
MIGRATION_SOURCES=()
MIGRATION_DESTINATIONS=()
MIGRATION_BACKUPS=()
MIGRATION_ACTIVE_COUNT=0
MIGRATION_TIED_COUNT=0
MIGRATION_DROPPED_COUNT=0
MIGRATION_REASON_COUNT=0
MIGRATION_WARNINGS=()

migration_add_plan() {
  local kind="$1" source="$2" destination="$3"
  MIGRATION_KINDS+=("$kind")
  MIGRATION_SOURCES+=("$source")
  MIGRATION_DESTINATIONS+=("$destination")
  MIGRATION_BACKUPS+=("backup/$source")
}

migration_fail_at() {
  local point="$1"
  if [[ "${LOOM_TEST_FAIL_MIGRATION_AT:-}" == "$point" ]]; then
    die "injected migration failure at $point"
  fi
}

migration_validate_id_from_name() {
  local name="$1" context="$2" id
  id="$(strip_state_suffix "$name")"
  is_valid_id "$id" ||
    die "malformed v1 stitch directory '$context'"
  printf '%s\n' "$id"
}

migration_validate_and_plan() {
  MIGRATION_KINDS=()
  MIGRATION_SOURCES=()
  MIGRATION_DESTINATIONS=()
  MIGRATION_BACKUPS=()
  MIGRATION_ACTIVE_COUNT=0
  MIGRATION_TIED_COUNT=0
  MIGRATION_DROPPED_COUNT=0
  MIGRATION_REASON_COUNT=0
  MIGRATION_WARNINGS=()

  local tray entry relative name id sidecar destination
  declare -A identities=()
  declare -A dropped_ids=()

  for tray in threads tied dropped; do
    [[ ! -e "$LOOM_DIR/$tray" || -d "$LOOM_DIR/$tray" ]] ||
      die "v1 tray '$tray' is not a directory"
  done

  if [[ -d "$LOOM_DIR/threads" ]]; then
    while IFS= read -r -d '' entry; do
      relative="${entry#$LOOM_DIR/}"
      [[ -f "$entry/instructions.md" && ! -L "$entry/instructions.md" ]] ||
        die "v1 directory '$relative' lacks a regular instructions.md; classify it as support or repair the ambiguity before migration"
      name="$(basename "$entry")"
      id="$(migration_validate_id_from_name "$name" "$relative")"
      [[ -z "${identities[$id]:-}" ]] ||
        die "duplicate v1 stitch id '$id': '${identities[$id]}' and '$relative'"
      identities["$id"]="$relative"
      MIGRATION_ACTIVE_COUNT=$((MIGRATION_ACTIVE_COUNT + 1))
    done < <(find "$LOOM_DIR/threads" -mindepth 1 -type d -print0 | sort -z)

    while IFS= read -r -d '' entry; do
      relative="${entry#$LOOM_DIR/}"
      die "unsupported symbolic link in active v1 loom: '$relative'"
    done < <(find "$LOOM_DIR/threads" -mindepth 1 -type l -print0 | sort -z)
  fi

  for tray in tied dropped; do
    [[ -d "$LOOM_DIR/$tray" ]] || continue
    while IFS= read -r -d '' entry; do
      relative="${entry#$LOOM_DIR/}"
      name="$(basename "$entry")"
      if [[ -L "$entry" ]]; then
        die "unsupported symbolic link in v1 $tray tray: '$relative'"
      fi
      if [[ -d "$entry" ]]; then
        [[ -f "$entry/instructions.md" && ! -L "$entry/instructions.md" ]] ||
          die "v1 $tray record '$relative' lacks a regular instructions.md"
        id="$(migration_validate_id_from_name "$name" "$relative")"
        [[ "$id" == "$name" ]] ||
          die "v1 $tray archive '$relative' has a lifecycle suffix"
        [[ -z "${identities[$id]:-}" ]] ||
          die "duplicate v1 stitch id '$id': '${identities[$id]}' and '$relative'"
        identities["$id"]="$relative"
        destination="legacy-v1/$tray/$name"
        [[ ! -e "$LOOM_DIR/$destination" && ! -L "$LOOM_DIR/$destination" ]] ||
          die "migration destination collision at '$destination'"
        migration_add_plan "$tray" "$relative" "$destination"
        if [[ "$tray" == tied ]]; then
          MIGRATION_TIED_COUNT=$((MIGRATION_TIED_COUNT + 1))
        else
          MIGRATION_DROPPED_COUNT=$((MIGRATION_DROPPED_COUNT + 1))
          dropped_ids["$id"]=1
        fi
      elif [[ "$tray" == dropped && "$name" == *.reason.md ]]; then
        :
      else
        MIGRATION_WARNINGS+=("top-level v1 support entry retained unchanged: $relative")
      fi
    done < <(find "$LOOM_DIR/$tray" -mindepth 1 -maxdepth 1 -print0 | sort -z)
  done

  if [[ -d "$LOOM_DIR/dropped" ]]; then
    while IFS= read -r -d '' sidecar; do
      relative="${sidecar#$LOOM_DIR/}"
      name="$(basename "$sidecar")"
      id="${name%.reason.md}"
      [[ -f "$sidecar" && ! -L "$sidecar" ]] ||
        die "drop reason sidecar '$relative' is not a regular file"
      is_valid_id "$id" ||
        die "malformed drop reason sidecar '$relative'"
      [[ -n "${dropped_ids[$id]:-}" ]] ||
        die "orphan drop reason sidecar '$relative' has no corresponding dropped stitch"
      [[ ! -e "$LOOM_DIR/dropped/$id/reason.md" ]] ||
        die "migration destination collision: '$relative' and 'dropped/$id/reason.md' both map to the legacy reason"
      destination="legacy-v1/dropped/$id/reason.md"
      [[ ! -e "$LOOM_DIR/$destination" && ! -L "$LOOM_DIR/$destination" ]] ||
        die "migration destination collision at '$destination'"
      migration_add_plan reason "$relative" "$destination"
      MIGRATION_REASON_COUNT=$((MIGRATION_REASON_COUNT + 1))
    done < <(
      find "$LOOM_DIR/dropped" -mindepth 1 -maxdepth 1 \
        -type f -name '*.reason.md' -print0 | sort -z
    )
  fi

  if [[ -e "$LOOM_DIR/legacy-v1" || -L "$LOOM_DIR/legacy-v1" ]]; then
    [[ -d "$LOOM_DIR/legacy-v1" ]] ||
      die "migration destination collision at 'legacy-v1'"
    while IFS= read -r -d '' entry; do
      relative="${entry#$LOOM_DIR/}"
      [[ -f "$entry/instructions.md" && ! -L "$entry/instructions.md" ]] ||
        die "existing legacy record '$relative' lacks a regular instructions.md"
      id="$(migration_validate_id_from_name "$(basename "$entry")" "$relative")"
      [[ -z "${identities[$id]:-}" ]] ||
        die "duplicate v1 stitch id '$id': '${identities[$id]}' and '$relative'"
      identities["$id"]="$relative"
    done < <(
      find "$LOOM_DIR/legacy-v1" -mindepth 2 -maxdepth 2 \
        -type d -print0 | sort -z
    )
  fi
}

migration_print_plan() {
  local i warning
  echo "v1 -> v2 migration plan"
  echo "validate active v1 stitch directories and flat history"
  echo "mkdir .migrate-v2-staging"
  echo "write .migrate-v2-staging/plan"
  echo "write .migrate-v2-staging/completed (atomic step journal)"
  echo "mkdir legacy-v1/tied legacy-v1/dropped"
  for (( i=0; i<${#MIGRATION_SOURCES[@]}; i++ )); do
    printf 'copy %s -> .migrate-v2-staging/%s\n' \
      "${MIGRATION_SOURCES[$i]}" "${MIGRATION_BACKUPS[$i]}"
  done
  for (( i=0; i<${#MIGRATION_SOURCES[@]}; i++ )); do
    printf 'move %s -> %s\n' \
      "${MIGRATION_SOURCES[$i]}" "${MIGRATION_DESTINATIONS[$i]}"
  done
  echo "write format-version = 2 (last)"
  echo "cleanup .migrate-v2-staging after marker commit"
  printf 'summary: active=%s legacy-tied=%s legacy-dropped=%s reasons=%s warnings=%s\n' \
    "$MIGRATION_ACTIVE_COUNT" "$MIGRATION_TIED_COUNT" \
    "$MIGRATION_DROPPED_COUNT" "$MIGRATION_REASON_COUNT" \
    "${#MIGRATION_WARNINGS[@]}"
  for warning in "${MIGRATION_WARNINGS[@]}"; do
    printf 'warning: %s\n' "$warning"
  done
}

migration_write_plan() {
  local stage="$LOOM_DIR/.migrate-v2-staging"
  local plan_tmp="$stage/.plan.tmp.$$" i
  {
    printf 'loom-migrate-v2-plan\t1\n'
    for (( i=0; i<${#MIGRATION_SOURCES[@]}; i++ )); do
      printf '%s\t%s\t%s\t%s\n' \
        "${MIGRATION_KINDS[$i]}" "${MIGRATION_SOURCES[$i]}" \
        "${MIGRATION_DESTINATIONS[$i]}" "${MIGRATION_BACKUPS[$i]}"
    done
  } > "$plan_tmp"
  mv "$plan_tmp" "$stage/plan"
  : > "$stage/completed"
}

migration_validate_loaded_step() {
  local kind="$1" source="$2" destination="$3" backup="$4"
  local id
  case "$kind" in
    tied|dropped)
      [[ "$source" == "$kind/"* && "$source" != */*/* ]] ||
        die "migration staging plan has unsafe $kind source '$source'"
      id="${source#*/}"
      is_valid_id "$id" ||
        die "migration staging plan has invalid stitch id '$id'"
      [[ "$destination" == "legacy-v1/$kind/$id" ]] ||
        die "migration staging plan has mismatched destination '$destination'"
      ;;
    reason)
      [[ "$source" == dropped/*.reason.md && "$source" != */*/* ]] ||
        die "migration staging plan has unsafe reason source '$source'"
      id="${source#dropped/}"
      id="${id%.reason.md}"
      is_valid_id "$id" ||
        die "migration staging plan has invalid reason id '$id'"
      [[ "$destination" == "legacy-v1/dropped/$id/reason.md" ]] ||
        die "migration staging plan has mismatched reason destination '$destination'"
      ;;
    *)
      die "migration staging plan has unknown step kind '$kind'"
      ;;
  esac
  [[ "$backup" == "backup/$source" ]] ||
    die "migration staging plan has mismatched backup '$backup'"
}

migration_load_plan() {
  local stage="$LOOM_DIR/.migrate-v2-staging"
  [[ -f "$stage/plan" && ! -L "$stage/plan" ]] ||
    die "migration staging is missing its recovery plan; preserve '$stage' and restore from its backup/ tree manually"
  MIGRATION_KINDS=()
  MIGRATION_SOURCES=()
  MIGRATION_DESTINATIONS=()
  MIGRATION_BACKUPS=()
  local kind source destination backup header=true
  while IFS=$'\t' read -r kind source destination backup; do
    if [[ "$header" == true ]]; then
      [[ "$kind" == loom-migrate-v2-plan && "$source" == 1 ]] ||
        die "migration staging plan has an unsupported format"
      header=false
      continue
    fi
    [[ -n "$kind" && -n "$source" && -n "$destination" && -n "$backup" ]] ||
      die "migration staging plan is malformed"
    migration_validate_loaded_step "$kind" "$source" "$destination" "$backup"
    MIGRATION_KINDS+=("$kind")
    MIGRATION_SOURCES+=("$source")
    MIGRATION_DESTINATIONS+=("$destination")
    MIGRATION_BACKUPS+=("$backup")
  done < "$stage/plan"
  [[ "$header" == false ]] || die "migration staging plan is empty"
}

migration_record_completed() {
  local record="$1" stage="$LOOM_DIR/.migrate-v2-staging"
  local completed_tmp="$stage/.completed.tmp.$$"
  {
    [[ ! -f "$stage/completed" ]] || cat "$stage/completed"
    printf '%s\n' "$record"
  } > "$completed_tmp"
  mv "$completed_tmp" "$stage/completed"
}

migration_is_completed() {
  local record="$1"
  [[ -f "$LOOM_DIR/.migrate-v2-staging/completed" ]] &&
    grep -Fqx "$record" "$LOOM_DIR/.migrate-v2-staging/completed"
}

migration_execute() {
  local stage="$LOOM_DIR/.migrate-v2-staging"
  local i kind source destination backup record
  mkdir -p "$LOOM_DIR/legacy-v1/tied" "$LOOM_DIR/legacy-v1/dropped"

  for (( i=0; i<${#MIGRATION_SOURCES[@]}; i++ )); do
    kind="${MIGRATION_KINDS[$i]}"
    source="${MIGRATION_SOURCES[$i]}"
    backup="${MIGRATION_BACKUPS[$i]}"
    record="backup:$i"
    if ! migration_is_completed "$record"; then
      migration_fail_at "backup-$kind"
      if [[ ! -e "$stage/$backup" ]]; then
        [[ -e "$LOOM_DIR/$source" ]] ||
          die "cannot back up missing migration source '$source'"
        local backup_parent backup_name backup_partial
        backup_parent="$(dirname "$stage/$backup")"
        backup_name="$(basename "$stage/$backup")"
        backup_partial="$backup_parent/.$backup_name.partial"
        mkdir -p "$backup_parent"
        rm -rf -- "$backup_partial"
        cp -a "$LOOM_DIR/$source" "$backup_partial"
        mv "$backup_partial" "$stage/$backup"
      fi
      migration_record_completed "$record"
      migration_fail_at "after-backup-$kind"
    fi
  done

  for (( i=0; i<${#MIGRATION_SOURCES[@]}; i++ )); do
    kind="${MIGRATION_KINDS[$i]}"
    source="${MIGRATION_SOURCES[$i]}"
    destination="${MIGRATION_DESTINATIONS[$i]}"
    record="move:$i"
    if migration_is_completed "$record"; then
      continue
    fi
    migration_fail_at "move-$kind"
    if [[ -e "$LOOM_DIR/$source" && ! -e "$LOOM_DIR/$destination" ]]; then
      mkdir -p "$(dirname "$LOOM_DIR/$destination")"
      mv "$LOOM_DIR/$source" "$LOOM_DIR/$destination"
    elif [[ ! -e "$LOOM_DIR/$source" && -e "$LOOM_DIR/$destination" ]]; then
      :
    else
      die "cannot resume migration step '$source' -> '$destination'; expected exactly one path to exist"
    fi
    migration_record_completed "$record"
    migration_fail_at "after-move-$kind"
  done

  migration_fail_at marker
  local marker_tmp="$LOOM_DIR/.format-version.tmp.$$"
  printf '2\n' > "$marker_tmp"
  mv "$marker_tmp" "$LOOM_DIR/format-version"
  migration_fail_at after-marker
  rm -rf -- "$stage"
}

migration_rollback() {
  local stage="$LOOM_DIR/.migrate-v2-staging"
  [[ -d "$stage" ]] ||
    die "no interrupted migration staging directory to roll back"
  [[ "$(format_version_state)" != v2 ]] ||
    die "cannot roll back after the v2 format marker was committed"
  migration_load_plan
  local i source destination backup
  for (( i=${#MIGRATION_SOURCES[@]}-1; i>=0; i-- )); do
    source="${MIGRATION_SOURCES[$i]}"
    destination="${MIGRATION_DESTINATIONS[$i]}"
    backup="${MIGRATION_BACKUPS[$i]}"
    if [[ -e "$LOOM_DIR/$destination" && ! -e "$LOOM_DIR/$source" ]]; then
      mkdir -p "$(dirname "$LOOM_DIR/$source")"
      mv "$LOOM_DIR/$destination" "$LOOM_DIR/$source"
    elif [[ -e "$LOOM_DIR/$destination" && -e "$LOOM_DIR/$source" ]]; then
      die "rollback collision: both '$source' and '$destination' exist"
    elif [[ ! -e "$LOOM_DIR/$source" ]]; then
      [[ -e "$stage/$backup" ]] ||
        die "rollback cannot recover '$source'; preserve '$stage' for manual recovery"
      local source_parent source_name source_partial
      source_parent="$(dirname "$LOOM_DIR/$source")"
      source_name="$(basename "$LOOM_DIR/$source")"
      source_partial="$source_parent/.$source_name.rollback-partial"
      mkdir -p "$source_parent"
      rm -rf -- "$source_partial"
      cp -a "$stage/$backup" "$source_partial"
      mv "$source_partial" "$LOOM_DIR/$source"
    fi
  done
  rmdir "$LOOM_DIR/legacy-v1/tied" 2>/dev/null || true
  rmdir "$LOOM_DIR/legacy-v1/dropped" 2>/dev/null || true
  rmdir "$LOOM_DIR/legacy-v1" 2>/dev/null || true
  rm -rf -- "$stage"
  echo "rolled back migrate-v2; the markerless v1 layout is restored"
}

migration_finish_committed() {
  local stage="$LOOM_DIR/.migrate-v2-staging"
  migration_load_plan
  local i source destination
  for (( i=0; i<${#MIGRATION_SOURCES[@]}; i++ )); do
    source="${MIGRATION_SOURCES[$i]}"
    destination="${MIGRATION_DESTINATIONS[$i]}"
    [[ ! -e "$LOOM_DIR/$source" && -e "$LOOM_DIR/$destination" ]] ||
      die "v2 marker is committed but migration paths are inconsistent at '$source' -> '$destination'; preserve '$stage' for manual recovery"
  done
  rm -rf -- "$stage"
  echo "finished cleanup for the already committed v2 migration"
}

cmd_migrate_v2() {
  require_loom
  local mode="${1:-}"
  (( $# <= 1 )) || die "migrate-v2 accepts only --dry-run or --rollback"
  case "$mode" in
    ""|--dry-run|--rollback) ;;
    *) die "migrate-v2 accepts only --dry-run or --rollback" ;;
  esac

  if [[ "$mode" == --rollback ]]; then
    migration_rollback
    return
  fi

  local state
  state="$(format_version_state)"
  if [[ "$state" == v2 ]]; then
    if [[ -e "$LOOM_DIR/.migrate-v2-staging" ||
          -L "$LOOM_DIR/.migrate-v2-staging" ]]; then
      [[ "$mode" != --rollback ]] ||
        die "cannot roll back after the v2 format marker was committed"
      [[ "$mode" != --dry-run ]] ||
        die "v2 marker is committed and cleanup remains; run 'loom.sh migrate-v2' to finish cleanup"
      migration_finish_committed
      return
    fi
    echo "already format v2; nothing to migrate"
    return
  fi
  [[ "$state" != invalid ]] ||
    die "invalid format-version marker (expected a regular file containing exactly '2')"

  if [[ -e "$LOOM_DIR/.migrate-v2-staging" ||
        -L "$LOOM_DIR/.migrate-v2-staging" ]]; then
    [[ -d "$LOOM_DIR/.migrate-v2-staging" ]] ||
      die "migration staging path exists but is not a directory"
    if [[ "$mode" == --dry-run ]]; then
      die "unfinished migration staging exists; run 'loom.sh migrate-v2' to resume or 'loom.sh migrate-v2 --rollback' to restore v1"
    fi
    echo "resuming interrupted migrate-v2 (use 'loom.sh migrate-v2 --rollback' instead to restore v1)"
    migration_load_plan
    migration_execute
    echo "migration resumed and completed; legacy v1 history is under legacy-v1/"
    return
  fi

  migration_validate_and_plan
  migration_print_plan
  [[ "$mode" != --dry-run ]] || return 0

  mkdir "$LOOM_DIR/.migrate-v2-staging" ||
    die "could not create migration staging directory"
  migration_write_plan
  migration_execute
  echo "migration complete; legacy v1 history is under legacy-v1/"
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
  require_v2_mutation
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
    queue|first|before|after|unqueue)
      shift
      cmd_queue_mutation "$cmd" "$@"
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
    migrate-v2)
      shift
      cmd_migrate_v2 "$@"
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
