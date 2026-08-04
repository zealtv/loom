#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'USAGE'
usage:
  loom.sh init
  loom.sh new [--json] <stitch-id> [parent-stitch-id]
  loom.sh claim [--json] <stitch-id>
  loom.sh tend [--json] <stitch-id>
  loom.sh release [--json] <stitch-id>
  loom.sh wait [--json] <stitch-id>
  loom.sh resume [--json] <stitch-id>
  loom.sh tie [--json] <stitch-id>
  loom.sh drop [--json] <stitch-id> [reason...]
  loom.sh queue [--json] <stitch-id>
  loom.sh queue --set <stitch-id>...
  loom.sh first [--json] <stitch-id>
  loom.sh before [--json] <stitch-id> <anchor-stitch-id>
  loom.sh after [--json] <stitch-id> <anchor-stitch-id>
  loom.sh unqueue [--json] <stitch-id>
  loom.sh anchor [--json] <stitch-id> <target-stitch-id>
  loom.sh unanchor [--json] <stitch-id> <target-stitch-id>
  loom.sh loose-ends
  loom.sh tending
  loom.sh waiting
  loom.sh next
  loom.sh status
  loom.sh revision
  loom.sh map [--json] [--active]
  loom.sh migrate-v2 [--dry-run|--rollback]
  loom.sh sweep [days]

notes:
  - this script operates on the .loom/ directory it lives in
  - format v2 is declared by a regular format-version file containing 2
  - stitches are directories with an instructions.md file
  - root entries in .loom/threads/ are goal stitches
  - only immediate child directories with instructions.md are decomposition
  - a loose end is a plain stitch whose children and hard dependencies resolve
  - queue order is a sparse preference; blocked entries never block ready work
  - .stitching means claimed; .waiting explicitly parks a stitch and its subtree
  - .tending means a child-bearing stitch has a steward; children stay claimable
  - child completion is retained in place; only complete goals enter archive trays
  - tie/drop write completed-at; drop also keeps reason.md inside the stitch
  - map and map --json are read-only derived views
  - revision is a cheap read-only change token for polling consumers
  - mutating --json goes before the stitch id and replaces that command's
    stdout prose with one result object; failures emit one error object
  - markerless non-empty looms require an explicit migrate-v2 after dry-run
USAGE
}

# Mutating commands accept --json and then report their result as one JSON
# object instead of prose. The human output is the default and is unchanged.
MUTATION_JSON=false
MUTATION_COMMAND=""
MUTATION_ARGS=()
MUTATION_ID=""
MUTATION_ERROR_CODE=failed
MUTATION_ERROR_IDS=()

die() {
  if [[ "$MUTATION_JSON" == true ]]; then
    mutation_emit_error "$*"
  fi
  echo "error: $*" >&2
  exit 1
}

# die with a stable machine-readable code. The code is only emitted under
# --json; every caller still reads as an ordinary die.
die_as() {
  local code="$1"
  shift
  MUTATION_ERROR_CODE="$code"
  die "$@"
}

# --json is recognised only before the first positional argument, so
# 'drop <id> <reason...>' keeps a reason that may say anything at all.
mutation_begin() {
  MUTATION_COMMAND="$1"
  shift
  MUTATION_JSON=false
  MUTATION_ARGS=()
  MUTATION_ID=""
  MUTATION_ERROR_CODE=failed
  MUTATION_ERROR_IDS=()

  local arg positional=false
  for arg in "$@"; do
    if [[ "$positional" == false ]]; then
      case "$arg" in
        --json)
          MUTATION_JSON=true
          continue
          ;;
        --*)
          die_as usage "$MUTATION_COMMAND accepts only --json"
          ;;
      esac
      positional=true
    fi
    MUTATION_ARGS+=("$arg")
  done
}

mutation_tray_of() {
  case "$1" in
    legacy-v1/tied/*) printf 'legacy-tied' ;;
    legacy-v1/dropped/*) printf 'legacy-dropped' ;;
    tied/*) printf 'tied' ;;
    dropped/*) printf 'dropped' ;;
    threads/*) printf 'threads' ;;
  esac
}

# Read the queue file directly. A mutation must not pay for a second index
# build to learn the position of the one ID it just touched.
queue_position_of() {
  local id="$1" line position=0
  [[ -f "$LOOM_DIR/queue" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" && "$line" != \#* ]] || continue
    position=$((position + 1))
    if [[ "$line" == "$id" ]]; then
      printf '%s' "$position"
      return 0
    fi
  done < "$LOOM_DIR/queue"
}

# The outcome of a mutation, derived from what the command already knows.
# changed is false for the idempotent no-op cases; path and state are empty
# only where the stitch is not on disk, which just unqueue's repair path
# reaches.
mutation_result() {
  local id="$1" changed="$2" path="$3" state="$4"
  shift 4
  if [[ "$MUTATION_JSON" != true ]]; then
    printf '%s\n' "$*"
    return 0
  fi

  local relative="" tray="" position completed=""
  if [[ -n "$path" ]]; then
    relative="${path#"$LOOM_DIR"/}"
    tray="$(mutation_tray_of "$relative")"
    [[ ! -f "$path/completed-at" ]] || read -r completed < "$path/completed-at"
  fi
  position="$(queue_position_of "$id")"

  printf '{"schema_version":1,"format_version":2,"command":'
  json_string "$MUTATION_COMMAND"
  printf ',"ok":true,"changed":%s' "$changed"
  printf ',"id":'; json_string "$id"
  printf ',"state":'; json_nullable_string "$state"
  printf ',"path":'; json_nullable_string "$relative"
  printf ',"tray":'; json_nullable_string "$tray"
  if [[ -n "$position" ]]; then
    printf ',"queue_position":%s' "$position"
  else
    printf ',"queue_position":null'
  fi
  printf ',"completed_at":'; json_nullable_string "$completed"
  printf '}\n'
}

# Errors go to stdout as JSON and stay on stderr as prose: a UI gets a code,
# a terminal keeps the message it always had.
mutation_emit_error() {
  local message="$1" first=true stitch_id
  printf '{"schema_version":1,"format_version":2,"command":'
  json_string "$MUTATION_COMMAND"
  printf ',"ok":false,"id":'; json_nullable_string "$MUTATION_ID"
  printf ',"error":{"code":'; json_string "$MUTATION_ERROR_CODE"
  printf ',"message":'; json_string "$message"
  printf ',"stitch_ids":['
  for stitch_id in ${MUTATION_ERROR_IDS[@]+"${MUTATION_ERROR_IDS[@]}"}; do
    [[ "$first" == true ]] || printf ','
    json_string "$stitch_id"
    first=false
  done
  printf ']}}\n'
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
      die_as format "v2 migration committed but staging cleanup remains; run 'loom.sh migrate-v2' to finish cleanup"
    fi
    die_as format "unfinished v2 migration staging exists; run 'loom.sh migrate-v2' to resume or 'loom.sh migrate-v2 --rollback' to restore v1"
  fi
  case "$state" in
    v2) ;;
    v1)
      if loom_has_tray_entries; then
        die_as format "markerless loom is format v1; inspect with 'loom.sh migrate-v2 --dry-run', then run 'loom.sh migrate-v2'"
      fi
      die_as format "loom has no format marker; run 'loom.sh init' before changing it"
      ;;
    invalid)
      die_as format "invalid format-version marker (expected a regular file containing exactly '2')"
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
    die_as invalid_id "invalid stitch id '$id' (use letters, numbers, ., _, - and no reserved state suffix)"
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
MAP_ACTIVE_ONLY=false
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
declare -A INDEX_RELATIVE=()
declare -A INDEX_STATE=()
declare -A INDEX_DIRECT_STATE=()
declare -A INDEX_ROOT=()
declare -A INDEX_PARENT=()
declare -A INDEX_TRAY=()
declare -A INDEX_ARCHIVED=()
declare -A INDEX_LEGACY=()
declare -A INDEX_COMPLETED_AT=()
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
  INDEX_RELATIVE=()
  INDEX_STATE=()
  INDEX_DIRECT_STATE=()
  INDEX_ROOT=()
  INDEX_PARENT=()
  INDEX_TRAY=()
  INDEX_ARCHIVED=()
  INDEX_LEGACY=()
  INDEX_COMPLETED_AT=()
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
  local tray archived legacy completed_at completed_raw
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
      INDEX_RELATIVE["$id"]="$relative"
      INDEX_DIRECT_STATE["$id"]="$direct"
      INDEX_STATE["$id"]="$state"

      archived=false
      legacy=false
      case "$relative" in
        threads/*) tray=threads ;;
        tied/*) tray=tied; archived=true ;;
        dropped/*) tray=dropped; archived=true ;;
        legacy-v1/tied/*) tray=legacy-tied; archived=true; legacy=true ;;
        legacy-v1/dropped/*) tray=legacy-dropped; archived=true; legacy=true ;;
        *) tray=threads ;;
      esac
      INDEX_TRAY["$id"]="$tray"
      INDEX_ARCHIVED["$id"]="$archived"
      INDEX_LEGACY["$id"]="$legacy"

      completed_at=""
      if [[ -e "$dir/completed-at" || -L "$dir/completed-at" ]]; then
        if [[ ! -f "$dir/completed-at" || -L "$dir/completed-at" ]]; then
          INDEX_ERRORS+=("invalid completed-at for '$id': expected a regular file")
          INDEX_INVALID["$id"]=1
        else
          completed_raw="$(cat "$dir/completed-at"; printf x)"
          if [[ "$completed_raw" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2})$'\n'x$ ]]; then
            completed_at="${BASH_REMATCH[1]}"
          else
            INDEX_ERRORS+=("invalid completed-at for '$id': expected one ISO-8601 seconds line")
            INDEX_INVALID["$id"]=1
          fi
        fi
      fi
      INDEX_COMPLETED_AT["$id"]="$completed_at"

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
        edge_state=broken
        cause=invalid
      elif [[ "$target_count" == 0 ]]; then
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
    die_as ambiguous "multiple stitches found for id '$id'"
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

dependency_path_exists() {
  local start="$1" sought="$2" current i
  local -a frontier=("$start")
  declare -A seen=()
  while (( ${#frontier[@]} > 0 )); do
    current="${frontier[${#frontier[@]}-1]}"
    unset 'frontier[${#frontier[@]}-1]'
    [[ "$current" != "$sought" ]] || return 0
    [[ -z "${seen[$current]:-}" ]] || continue
    seen["$current"]=1
    for (( i=0; i<${#EDGE_DEPENDENTS[@]}; i++ )); do
      [[ "${EDGE_DEPENDENTS[$i]}" == "$current" ]] || continue
      [[ "${INDEX_COUNT[${EDGE_TARGETS[$i]}]:-0}" == 1 ]] || continue
      frontier+=("${EDGE_TARGETS[$i]}")
    done
  done
  return 1
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
      die_as terminal "cannot $3 a tied stitch"
      ;;
    "$LOOM_DIR/dropped"/*|"$LOOM_DIR/legacy-v1/dropped"/*)
      die_as terminal "cannot $3 a dropped stitch"
      ;;
    "$LOOM_DIR/threads"/*|"$LOOM_DIR/threads")
      ;;
    *)
      die_as not_under_threads "stitch '$id' is not under threads/"
      ;;
  esac
}

set_stitch_state() {
  local id="$1" new_state="$2" scope="$3" action="$4" already="$5" output="$6"
  local existing name current parent_dir dest

  existing="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$existing" ]] || die_as not_found "stitch '$id' not found"
  ensure_under_threads "$existing" "$id" "$action"

  name="$(basename "$existing")"
  current="$(state_of_name "$name")"
  if [[ "$current" == "$new_state" ]]; then
    mutation_result "$id" false "$existing" "$new_state" "$already: $id"
    return 0
  fi
  if [[ "$current" == tied || "$current" == dropped ]]; then
    die_as terminal "cannot $action terminal stitch '$id' ($current)"
  fi
  has_terminal_ancestor "$existing" &&
    die_as terminal "cannot $action abandoned stitch '$id' beneath a terminal ancestor"

  if [[ "$current" == tending ]]; then
    die_as tended "'$id' is tended. release it before you $action it."
  fi

  case "$scope" in
    loose)
      if has_unresolved_children "$existing"; then
        die_as not_loose_end "'$id' is not a loose end — it has unresolved children. only loose ends can $action."
      fi
      ;;
    parent)
      if ! has_unresolved_children "$existing"; then
        die_as not_child_bearing "'$id' has no children requiring work. only child-bearing stitches can $action."
      fi
      ;;
    *)
      die "unknown state scope '$scope'"
      ;;
  esac

  parent_dir="$(dirname "$existing")"
  dest="$parent_dir/$id.$new_state"
  [[ ! -e "$dest" ]] || die_as destination_exists "destination already exists: $dest"
  mv "$existing" "$dest"
  mutation_result "$id" true "$dest" "$new_state" "$output $id"
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
  mkdir -p "$LOOM_DIR/threads"
  # An unmigrated v1 loom carrying history is left byte-for-byte alone: init
  # never touches it, so it does not get seeded either. migrate-v2 seeds the
  # trays as part of migrating it.
  if [[ "$state" != v1 || "$had_v1_entries" == false ]]; then
    ensure_trays
  else
    mkdir -p "$LOOM_DIR/tied" "$LOOM_DIR/dropped"
  fi
  if [[ "$state" == v1 && "$had_v1_entries" == false ]]; then
    local marker_tmp="$LOOM_DIR/.format-version.tmp.$$"
    printf '2\n' > "$marker_tmp"
    mv "$marker_tmp" "$LOOM_DIR/format-version"
  fi
  echo "initialized $LOOM_DIR"
}

cmd_new() {
  mutation_begin new "$@"
  set -- "${MUTATION_ARGS[@]}"
  require_loom
  require_v2_mutation
  build_index
  local id="${1:-}"
  local parent_id="${2:-}"
  [[ -n "$id" ]] || die_as usage "new requires <stitch-id>"
  (( $# <= 2 )) || die_as usage "new accepts <stitch-id> [parent-stitch-id]"
  validate_id "$id"
  MUTATION_ID="$id"
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
  mutation_result "$id" true "$created" plain \
    $'new '"$created"$'\nnext: read, then edit '"$created"$'/instructions.md (agent harnesses refuse to overwrite unread files)'
}

cmd_claim() {
  mutation_begin claim "$@"
  set -- "${MUTATION_ARGS[@]}"
  require_loom
  require_v2_mutation
  build_index
  local id="${1:-}"
  [[ -n "$id" ]] || die_as usage "claim requires <stitch-id>"
  (( $# == 1 )) || die_as usage "claim accepts only <stitch-id>"
  validate_id "$id"
  MUTATION_ID="$id"

  local existing waiting_ancestor waiting_id
  existing="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$existing" ]] || die_as not_found "stitch '$id' not found"
  if [[ "$(state_of_name "$(basename "$existing")")" == waiting ]]; then
    die_as waiting "'$id' is waiting. run 'loom resume $id' before claiming it."
  fi
  waiting_ancestor="$(has_waiting_ancestor "$existing" || true)"
  if [[ -n "$waiting_ancestor" ]]; then
    waiting_id="$(strip_state_suffix "$(basename "$waiting_ancestor")")"
    MUTATION_ERROR_IDS=("$waiting_id")
    die_as waiting "'$id' is beneath waiting stitch '$waiting_id'. run 'loom resume $waiting_id' first."
  fi
  if [[ "${INDEX_DIRECT_STATE[$id]}" == plain ]] &&
     ! dependencies_ready "$id"; then
    die_as not_ready "'$id' is not ready — dependency blockage, broken dependency, or dependency cycle"
  fi
  set_stitch_state "$id" stitching loose claim "already stitching" claimed
}

cmd_tend() {
  mutation_begin tend "$@"
  set -- "${MUTATION_ARGS[@]}"
  require_loom
  require_v2_mutation
  build_index
  local id="${1:-}"
  [[ -n "$id" ]] || die_as usage "tend requires <stitch-id>"
  (( $# == 1 )) || die_as usage "tend accepts only <stitch-id>"
  validate_id "$id"
  MUTATION_ID="$id"
  set_stitch_state "$id" tending parent tend "already tending" "tending"
}

cmd_release() {
  mutation_begin release "$@"
  set -- "${MUTATION_ARGS[@]}"
  require_loom
  require_v2_mutation
  build_index
  local id="${1:-}"
  [[ -n "$id" ]] || die_as usage "release requires <stitch-id>"
  (( $# == 1 )) || die_as usage "release accepts only <stitch-id>"
  validate_id "$id"
  MUTATION_ID="$id"

  local existing name current parent_dir dest
  existing="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$existing" ]] || die_as not_found "stitch '$id' not found"
  ensure_under_threads "$existing" "$id" release

  name="$(basename "$existing")"
  current="$(state_of_name "$name")"
  if [[ "$current" == plain ]]; then
    mutation_result "$id" false "$existing" plain "already released: $id"
    return 0
  fi
  [[ "$current" == tending ]] || die_as not_tended "'$id' is not tended"

  parent_dir="$(dirname "$existing")"
  dest="$parent_dir/$id"
  [[ ! -e "$dest" ]] || die_as destination_exists "destination already exists: $dest"
  mv "$existing" "$dest"
  mutation_result "$id" true "$dest" plain "released $id"
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
  mutation_begin tie "$@"
  set -- "${MUTATION_ARGS[@]}"
  require_loom
  require_v2_mutation
  ensure_trays
  build_index
  local id="${1:-}"
  [[ -n "$id" ]] || die_as usage "tie requires <stitch-id>"
  (( $# == 1 )) || die_as usage "tie accepts only <stitch-id>"
  validate_id "$id"
  MUTATION_ID="$id"

  local src
  src="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$src" ]] || die_as not_found "stitch '$id' not found"

  case "$src" in
    "$LOOM_DIR/tied"/*|"$LOOM_DIR/legacy-v1/tied"/*)
      mutation_result "$id" false "$src" tied "already tied: $id"
      return 0
      ;;
    "$LOOM_DIR/dropped"/*|"$LOOM_DIR/legacy-v1/dropped"/*)
      die_as terminal "cannot tie a dropped stitch"
      ;;
    "$LOOM_DIR/threads"/*|"$LOOM_DIR/threads")
      ;;
    *)
      die_as not_under_threads "stitch '$id' is not under threads/"
      ;;
  esac

  local direct_state
  direct_state="$(state_of_name "$(basename "$src")")"
  if [[ "$direct_state" == tied ]]; then
    mutation_result "$id" false "$src" tied "already tied: $id"
    return 0
  fi
  [[ "$direct_state" != dropped ]] || die_as terminal "cannot tie a dropped stitch"
  [[ "$direct_state" != waiting ]] || die_as waiting "cannot tie a waiting stitch"
  has_terminal_ancestor "$src" &&
    die_as terminal "cannot tie abandoned stitch '$id' beneath a terminal ancestor"
  local waiting_ancestor
  waiting_ancestor="$(has_waiting_ancestor "$src" || true)"
  if [[ -n "$waiting_ancestor" ]]; then
    local blocking_id
    blocking_id="$(strip_state_suffix "$(basename "$waiting_ancestor")")"
    MUTATION_ERROR_IDS=("$blocking_id")
    die_as waiting "cannot tie '$id' beneath waiting stitch '$blocking_id'"
  fi

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
    if [[ "$MUTATION_JSON" == true ]]; then
      MUTATION_ERROR_CODE=unresolved_children
      MUTATION_ERROR_IDS=("${unresolved[@]}")
      mutation_emit_error "cannot tie '$id' — unresolved child stitches"
    fi
    echo "error: cannot tie '$id' — unresolved child stitches:" >&2
    printf '  - %s\n' "${unresolved[@]}" >&2
    echo "tie or drop each child before tying its parent." >&2
    exit 1
  fi
  if ! dependencies_ready "$id"; then
    die_as not_ready "cannot tie '$id' — dependency blockage, broken dependency, or dependency cycle"
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
  [[ ! -e "$dest" ]] || die_as destination_exists "destination already exists: $dest"
  write_completed_at "$src"
  mv "$src" "$dest"
  queue_remove_terminal_ids "${terminal_ids[@]}"
  mutation_result "$canonical" true "$dest" tied "tied $canonical"
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
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    printf '%s\n' "${INDEX_PATH[$id]#$LOOM_DIR/threads/}"
  done < <(list_ready_ids)
}

list_ready_ids() {
  ensure_index
  local dir id
  declare -A emitted=()

  for id in "${QUEUE_IDS[@]}"; do
    [[ -z "${emitted[$id]:-}" ]] || continue
    is_valid_id "$id" || continue
    if is_effectively_ready "$id"; then
      printf '%s\n' "$id"
      emitted["$id"]=1
    fi
  done

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    id="$(strip_state_suffix "$(basename "$dir")")"
    if [[ -z "${emitted[$id]:-}" ]] && is_effectively_ready "$id"; then
      printf '%s\n' "$id"
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

# Git cannot track an empty directory, so a loom committed before its first tie
# or drop loses `tied/` and `dropped/` on clone. Nothing notices until the first
# goal tie, which fails on the terminal move after completed-at is already
# written. `.gitkeep` keeps an empty tray in the commit; `mkdir -p` heals looms
# already cloned without one.
#
# `.gitkeep` is a plain file, so it is never a recognized child: it does not
# count as a tray entry, and sweep only removes directories.
ensure_trays() {
  local tray
  for tray in "$LOOM_DIR/tied" "$LOOM_DIR/dropped"; do
    mkdir -p "$tray"
    [[ -e "$tray/.gitkeep" || -L "$tray/.gitkeep" ]] || : > "$tray/.gitkeep"
  done
}

# Trays that are absent entirely. Reported by status and map, never repaired by
# them: both are strictly read-only. Emitted in tray-path order.
missing_trays() {
  local tray
  for tray in dropped tied; do
    [[ -d "$LOOM_DIR/$tray" ]] || printf '%s\n' "$tray"
  done
}

json_string() {
  local value="$1" output="" char code i
  for (( i=0; i<${#value}; i++ )); do
    char="${value:i:1}"
    case "$char" in
      '"') output+='\"' ;;
      \\) output+='\\' ;;
      $'\b') output+='\b' ;;
      $'\f') output+='\f' ;;
      $'\n') output+='\n' ;;
      $'\r') output+='\r' ;;
      $'\t') output+='\t' ;;
      *)
        printf -v code '%d' "'$char"
        if (( code < 32 )); then
          printf -v char '\\u%04x' "$code"
        fi
        output+="$char"
        ;;
    esac
  done
  printf '"%s"' "$output"
}

json_nullable_string() {
  if [[ -n "$1" ]]; then
    json_string "$1"
  else
    printf 'null'
  fi
}

map_ids_by_path() {
  local id
  for id in "${!INDEX_PATH[@]}"; do
    [[ "${INDEX_COUNT[$id]:-0}" == 1 ]] || continue
    [[ "$MAP_ACTIVE_ONLY" != true || "${INDEX_TRAY[$id]}" == threads ]] || continue
    printf '%s\t%s\n' "${INDEX_RELATIVE[$id]}" "$id"
  done | sort -t $'\t' -k1,1 | cut -f2
}

map_recent_ids() {
  local id state timestamp
  {
    for id in "${!INDEX_PATH[@]}"; do
      [[ "${INDEX_COUNT[$id]:-0}" == 1 ]] || continue
      [[ "$MAP_ACTIVE_ONLY" != true || "${INDEX_TRAY[$id]}" == threads ]] || continue
      state="${INDEX_STATE[$id]}"
      [[ "$state" == tied || "$state" == dropped ]] || continue
      timestamp="${INDEX_COMPLETED_AT[$id]:-}"
      if [[ -n "$timestamp" ]]; then
        printf '0\t%s\t%s\n' "$timestamp" "$id"
      else
        printf '1\t\t%s\n' "$id"
      fi
    done
  } | awk -F '\t' '
    function epoch(value,    year, month, day, hour, minute, second,
                                  offset_sign, offset_hour, offset_minute,
                                  era, year_of_era, day_of_year, day_of_era,
                                  days, offset) {
      year = substr(value, 1, 4) + 0
      month = substr(value, 6, 2) + 0
      day = substr(value, 9, 2) + 0
      hour = substr(value, 12, 2) + 0
      minute = substr(value, 15, 2) + 0
      second = substr(value, 18, 2) + 0
      offset_sign = substr(value, 20, 1)
      offset_hour = substr(value, 21, 2) + 0
      offset_minute = substr(value, 24, 2) + 0

      if (month <= 2)
        year--
      era = int(year / 400)
      year_of_era = year - era * 400
      day_of_year = int((153 * (month + (month > 2 ? -3 : 9)) + 2) / 5) + day - 1
      day_of_era = year_of_era * 365 + int(year_of_era / 4) - int(year_of_era / 100) + day_of_year
      days = era * 146097 + day_of_era - 719468
      offset = (offset_hour * 60 + offset_minute) * 60
      if (offset_sign == "-")
        offset = -offset
      return days * 86400 + hour * 3600 + minute * 60 + second - offset
    }
    $1 == 0 { printf "0\t%.0f\t%s\n", epoch($2), $3 }
    $1 == 1 { printf "1\t0\t%s\n", $3 }
  ' | sort -t $'\t' -k1,1n -k2,2nr -k3,3 | cut -f3
}

map_health() {
  local i
  (( ${#INDEX_ERRORS[@]} == 0 && ${#QUEUE_ERRORS[@]} == 0 &&
     ${#INDEX_CYCLES[@]} == 0 )) || return 1
  for (( i=0; i<${#EDGE_DEPENDENTS[@]}; i++ )); do
    [[ "${EDGE_STATES[$i]}" != broken ]] || return 1
  done
  return 0
}

queue_dependency_warnings() {
  local i dependent target dependent_position target_position code
  for (( i=0; i<${#EDGE_DEPENDENTS[@]}; i++ )); do
    [[ "${EDGE_STATES[$i]}" == blocked ]] || continue
    dependent="${EDGE_DEPENDENTS[$i]}"
    target="${EDGE_TARGETS[$i]}"
    dependent_position="${QUEUE_POSITION[$dependent]:-}"
    [[ -n "$dependent_position" ]] || continue
    target_position="${QUEUE_POSITION[$target]:-}"
    if [[ -z "$target_position" ]]; then
      code=queue_dependency_unqueued
    elif (( target_position > dependent_position )); then
      code=queue_dependency_inversion
    else
      continue
    fi
    printf '%s\t%s\t%s\n' "$dependent" "$target" "$code"
  done | sort -t $'\t' -k1,1 -k2,2 -k3,3
}

map_stitch_cycle() {
  local id="$1" cycle member
  local members=()
  for cycle in "${INDEX_CYCLES[@]}"; do
    IFS=',' read -ra members <<< "$cycle"
    for member in "${members[@]}"; do
      if [[ "$member" == "$id" ]]; then
        printf '%s\n' "$cycle"
        return
      fi
    done
  done
}

map_emit_id_array() {
  local values=("$@") value first=true
  printf '['
  for value in "${values[@]}"; do
    [[ -n "$value" ]] || continue
    [[ "$first" == true ]] || printf ','
    json_string "$value"
    first=false
  done
  printf ']'
}

map_emit_csv_id_array() {
  local csv="$1"
  local values=()
  [[ -z "$csv" ]] || IFS=',' read -ra values <<< "$csv"
  map_emit_id_array "${values[@]}"
}

map_child_ids() {
  local parent="$1" id
  for id in "${!INDEX_PARENT[@]}"; do
    [[ "${INDEX_COUNT[$id]:-0}" == 1 &&
       "${INDEX_PARENT[$id]:-}" == "$parent" ]] || continue
    printf '%s\n' "$id"
  done | sort
}

map_edge_indexes_for() {
  local dependent="$1" i
  for (( i=0; i<${#EDGE_DEPENDENTS[@]}; i++ )); do
    [[ "${EDGE_DEPENDENTS[$i]}" == "$dependent" ]] || continue
    printf '%s\t%s\n' "${EDGE_TARGETS[$i]}" "$i"
  done | sort -t $'\t' -k1,1 -k2,2n | cut -f2
}

map_emit_dependency() {
  local i="$1" cause="${EDGE_CAUSES[$1]}"
  printf '{"from":'
  json_string "${EDGE_DEPENDENTS[$i]}"
  printf ',"to":'
  json_string "${EDGE_TARGETS[$i]}"
  printf ',"status":'
  json_string "${EDGE_STATES[$i]}"
  printf ',"reason":'
  json_nullable_string "$cause"
  printf '}'
}

map_emit_stitch_dependencies() {
  local id="$1" i first=true
  printf '['
  while IFS= read -r i; do
    [[ -n "$i" ]] || continue
    [[ "$first" == true ]] || printf ','
    map_emit_dependency "$i"
    first=false
  done < <(map_edge_indexes_for "$id")
  printf ']'
}

map_emit_stitch() {
  local id="$1" parent="${INDEX_PARENT[$1]:-}"
  local completed="${INDEX_COMPLETED_AT[$1]:-}"
  local cycle ready=false waiting=false queue_position="${QUEUE_POSITION[$1]:-}"
  local children=()
  is_effectively_ready "$id" && ready=true
  [[ -n "${INDEX_WAITING_ANCESTOR[$id]:-}" ]] && waiting=true
  cycle="$(map_stitch_cycle "$id")"
  mapfile -t children < <(map_child_ids "$id")

  printf '{"id":'; json_string "$id"
  printf ',"root_id":'; json_string "${INDEX_ROOT[$id]}"
  printf ',"parent_id":'; json_nullable_string "$parent"
  printf ',"path":'; json_string "${INDEX_RELATIVE[$id]}"
  printf ',"tray":'; json_string "${INDEX_TRAY[$id]}"
  printf ',"state":'; json_string "${INDEX_STATE[$id]}"
  printf ',"ready":%s' "$ready"
  printf ',"waiting_inherited":%s' "$waiting"
  if [[ -n "$queue_position" ]]; then
    printf ',"queue_position":%s' "$queue_position"
  else
    printf ',"queue_position":null'
  fi
  printf ',"completed_at":'; json_nullable_string "$completed"
  printf ',"archived":%s' "${INDEX_ARCHIVED[$id]}"
  printf ',"legacy":%s' "${INDEX_LEGACY[$id]}"
  printf ',"children":'; map_emit_id_array "${children[@]}"
  printf ',"dependencies":'; map_emit_stitch_dependencies "$id"
  printf ',"cycle":'; map_emit_csv_id_array "$cycle"
  printf '}'
}

map_emit_diagnostic() {
  local severity="$1" code="$2" message="$3"
  local stitch_id="${4:-}" target_id="${5:-}"
  printf '{"severity":'; json_string "$severity"
  printf ',"code":'; json_string "$code"
  printf ',"message":'; json_string "$message"
  printf ',"stitch_id":'; json_nullable_string "$stitch_id"
  printf ',"target_id":'; json_nullable_string "$target_id"
  printf '}'
}

map_emit_diagnostics() {
  local first=true i message cycle dependent target code
  printf '['

  while IFS=$'\t' read -r _ i; do
    [[ -n "$i" ]] || continue
    [[ "$first" == true ]] || printf ','
    map_emit_diagnostic error broken_dependency \
      "broken dependency '${EDGE_DEPENDENTS[$i]} -> ${EDGE_TARGETS[$i]}' (${EDGE_CAUSES[$i]})" \
      "${EDGE_DEPENDENTS[$i]}" "${EDGE_TARGETS[$i]}"
    first=false
  done < <(
    for (( i=0; i<${#EDGE_DEPENDENTS[@]}; i++ )); do
      [[ "${EDGE_STATES[$i]}" == broken ]] || continue
      printf '%s/%s\t%s\n' "${EDGE_DEPENDENTS[$i]}" "${EDGE_TARGETS[$i]}" "$i"
    done | sort
  )

  for cycle in "${INDEX_CYCLES[@]}"; do
    [[ "$first" == true ]] || printf ','
    map_emit_diagnostic error dependency_cycle \
      "dependency cycle: ${cycle//,/, }"
    first=false
  done

  local tray
  while IFS= read -r tray; do
    [[ -n "$tray" ]] || continue
    [[ "$first" == true ]] || printf ','
    map_emit_diagnostic warning missing_tray \
      "archive tray '$tray' is missing; a tie or drop of a goal stitch will recreate it"
    first=false
  done < <(missing_trays)

  while IFS=$'\t' read -r dependent target code; do
    [[ -n "$dependent" ]] || continue
    [[ "$first" == true ]] || printf ','
    if [[ "$code" == queue_dependency_inversion ]]; then
      message="queued stitch '$dependent' appears before its unsatisfied dependency '$target'"
    else
      message="queued stitch '$dependent' has unqueued unsatisfied dependency '$target'"
    fi
    map_emit_diagnostic warning "$code" "$message" "$dependent" "$target"
    first=false
  done < <(queue_dependency_warnings)

  while IFS= read -r message; do
    [[ -n "$message" ]] || continue
    [[ "$first" == true ]] || printf ','
    map_emit_diagnostic error queue_error "$message"
    first=false
  done < <(printf '%s\n' "${QUEUE_ERRORS[@]}" | sort)

  while IFS= read -r message; do
    [[ -n "$message" ]] || continue
    [[ "$first" == true ]] || printf ','
    map_emit_diagnostic error structural_error "$message"
    first=false
  done < <(printf '%s\n' "${INDEX_ERRORS[@]}" | sort)

  printf ']'
}

map_emit_json() {
  local ids=() ready=() recent=() id parent child first i cycle
  mapfile -t ids < <(map_ids_by_path)
  mapfile -t ready < <(list_ready_ids)
  mapfile -t recent < <(map_recent_ids)

  printf '{"schema_version":1,"format_version":2,"loom_root":'
  json_string "$LOOM_DIR"

  printf ',"stitches":['
  first=true
  for id in "${ids[@]}"; do
    [[ "$first" == true ]] || printf ','
    map_emit_stitch "$id"
    first=false
  done
  printf ']'

  printf ',"decomposition_edges":['
  first=true
  while IFS=$'\t' read -r parent child; do
    [[ -n "$parent" && -n "$child" ]] || continue
    [[ "$first" == true ]] || printf ','
    printf '{"parent":'; json_string "$parent"
    printf ',"child":'; json_string "$child"
    printf '}'
    first=false
  done < <(
    for id in "${ids[@]}"; do
      parent="${INDEX_PARENT[$id]:-}"
      [[ -n "$parent" ]] && printf '%s\t%s\n' "$parent" "$id"
    done | sort -t $'\t' -k1,1 -k2,2
  )
  printf ']'

  printf ',"dependency_edges":['
  first=true
  while IFS=$'\t' read -r _ i; do
    [[ -n "$i" ]] || continue
    [[ "$first" == true ]] || printf ','
    map_emit_dependency "$i"
    first=false
  done < <(
    for (( i=0; i<${#EDGE_DEPENDENTS[@]}; i++ )); do
      if [[ "$MAP_ACTIVE_ONLY" == true ]]; then
        [[ "${INDEX_TRAY[${EDGE_DEPENDENTS[$i]}]:-}" == threads &&
           "${INDEX_TRAY[${EDGE_TARGETS[$i]}]:-}" == threads ]] || continue
      fi
      printf '%s/%s\t%s\n' "${EDGE_DEPENDENTS[$i]}" "${EDGE_TARGETS[$i]}" "$i"
    done | sort
  )
  printf ']'

  printf ',"cycles":['
  first=true
  for cycle in "${INDEX_CYCLES[@]}"; do
    if [[ "$MAP_ACTIVE_ONLY" == true ]]; then
      local cycle_active=true member cycle_members=()
      IFS=',' read -ra cycle_members <<< "$cycle"
      for member in "${cycle_members[@]}"; do
        [[ "${INDEX_TRAY[$member]:-}" == threads ]] || cycle_active=false
      done
      [[ "$cycle_active" == true ]] || continue
    fi
    [[ "$first" == true ]] || printf ','
    map_emit_csv_id_array "$cycle"
    first=false
  done
  printf ']'

  printf ',"frontier":'; map_emit_id_array "${ready[@]}"
  printf ',"recently_completed":'; map_emit_id_array "${recent[@]}"
  printf ',"diagnostics":'; map_emit_diagnostics
  printf '}\n'
}

map_block_reason() {
  local id="$1" i ancestor
  if [[ -n "${INDEX_WAITING_ANCESTOR[$id]:-}" ]]; then
    ancestor="$(strip_state_suffix "$(basename "${INDEX_WAITING_ANCESTOR[$id]}")")"
    printf 'waiting under %s\n' "$ancestor"
    return
  fi
  case "${INDEX_DIRECT_STATE[$id]}" in
    stitching) printf 'claimed\n'; return ;;
    waiting) printf 'waiting\n'; return ;;
    tending) printf 'tended\n'; return ;;
  esac
  if [[ -n "${INDEX_CYCLIC[$id]:-}" ]]; then
    printf 'dependency cycle\n'
    return
  fi
  if [[ -n "${INDEX_INVALID[$id]:-}" ]]; then
    printf 'invalid structure\n'
    return
  fi
  if (( ${INDEX_UNRESOLVED_CHILDREN[$id]:-0} > 0 )); then
    printf '%s unresolved child stitch(es)\n' \
      "${INDEX_UNRESOLVED_CHILDREN[$id]}"
    return
  fi
  for (( i=0; i<${#EDGE_DEPENDENTS[@]}; i++ )); do
    [[ "${EDGE_DEPENDENTS[$i]}" == "$id" &&
       "${EDGE_STATES[$i]}" != satisfied ]] || continue
    if [[ "${EDGE_STATES[$i]}" == broken ]]; then
      printf 'needs %s (%s)\n' "${EDGE_TARGETS[$i]}" "${EDGE_CAUSES[$i]}"
    else
      printf 'needs %s\n' "${EDGE_TARGETS[$i]}"
    fi
    return
  done
  printf 'not ready\n'
}

map_tree_children() {
  local parent="$1" tray="$2" id
  for id in "${!INDEX_PATH[@]}"; do
    [[ "${INDEX_COUNT[$id]:-0}" == 1 &&
       "${INDEX_PARENT[$id]:-}" == "$parent" &&
       "${INDEX_TRAY[$id]}" == "$tray" ]] || continue
    printf '%s\t%s\n' "${INDEX_RELATIVE[$id]}" "$id"
  done | sort -t $'\t' -k1,1 | cut -f2
}

map_has_tray() {
  local tray="$1" id
  for id in "${!INDEX_TRAY[@]}"; do
    [[ "${INDEX_TRAY[$id]}" != "$tray" ]] || return 0
  done
  return 1
}

map_print_tree() {
  local parent="$1" tray="$2" prefix="${3:-}" id state tag
  local entries=()
  mapfile -t entries < <(map_tree_children "$parent" "$tray")

  local count="${#entries[@]}" i=0 branch child_prefix
  for id in "${entries[@]}"; do
    i=$((i + 1))
    branch="├──"; child_prefix="│   "
    if (( i == count )); then
      branch="└──"; child_prefix="    "
    fi
    state="${INDEX_STATE[$id]}"
    tag=" [$state]"
    if is_effectively_ready "$id"; then
      tag=" [ready]"
    elif [[ -n "${INDEX_WAITING_ANCESTOR[$id]:-}" ]]; then
      tag=" [waiting inherited]"
    fi
    printf '%s%s %s%s\n' "$prefix" "$branch" "$id" "$tag"
    map_print_tree "$id" "$tray" "$prefix$child_prefix"
  done
}

map_emit_plain() {
  local recent=() ready=() id timestamp state has_coming=false
  mapfile -t recent < <(map_recent_ids)
  mapfile -t ready < <(list_ready_ids)

  echo "recently completed"
  if (( ${#recent[@]} == 0 )); then
    echo "(none)"
  else
    for id in "${recent[@]}"; do
      timestamp="${INDEX_COMPLETED_AT[$id]:-unknown}"
      printf -- '- %s  %s  %s\n' "$timestamp" "$id" "${INDEX_STATE[$id]}"
    done
  fi

  echo
  echo "current frontier"
  if (( ${#ready[@]} == 0 )); then
    echo "(none)"
  else
    for id in "${ready[@]}"; do
      if [[ -n "${QUEUE_POSITION[$id]:-}" ]]; then
        printf -- '- %s  (queue %s)\n' "$id" "${QUEUE_POSITION[$id]}"
      else
        printf -- '- %s\n' "$id"
      fi
    done
  fi

  echo
  echo "coming / blocked"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ "${INDEX_TRAY[$id]}" == threads ]] || continue
    state="${INDEX_STATE[$id]}"
    [[ "$state" != tied && "$state" != dropped &&
       "$state" != abandoned ]] || continue
    is_effectively_ready "$id" && continue
    printf -- '- %s  (%s)\n' "$id" "$(map_block_reason "$id")"
    has_coming=true
  done < <(map_ids_by_path)
  [[ "$has_coming" == true ]] || echo "(none)"

  echo
  echo "decomposition tree"
  echo "active"
  map_print_tree "" threads
  echo "tied archives"
  map_print_tree "" tied
  echo "dropped archives"
  map_print_tree "" dropped
  if map_has_tray legacy-tied || map_has_tray legacy-dropped; then
    echo "legacy v1"
    map_print_tree "" legacy-tied
    map_print_tree "" legacy-dropped
  fi
}

cmd_map() {
  require_loom
  [[ "$(format_version_state)" == v2 ]] ||
    die "map requires a format v2 loom (run migrate-v2 first)"
  local mode=plain arg
  MAP_ACTIVE_ONLY=false
  for arg in "$@"; do
    case "$arg" in
      --json)
        [[ "$mode" == plain ]] || die "map accepts --json only once"
        mode=json
        ;;
      --active)
        [[ "$MAP_ACTIVE_ONLY" == false ]] || die "map accepts --active only once"
        MAP_ACTIVE_ONLY=true
        ;;
      *) die "map accepts only --json and --active" ;;
    esac
  done
  build_index
  if [[ "$mode" == json ]]; then
    map_emit_json
  else
    map_emit_plain
  fi
  map_health
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

  # A warning, not an error: the loom is usable and the next tie or drop
  # repairs it. Status is read-only and does not repair it here.
  local tray missing=()
  mapfile -t missing < <(missing_trays)
  if (( ${#missing[@]} > 0 )); then
    echo "⚠️  missing archive trays"
    for tray in "${missing[@]}"; do
      printf -- "- %s/ is absent; git cannot track an empty directory, so a clone\n" "$tray"
      printf -- "  loses it. A tie or drop of a goal stitch recreates it.\n"
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

  local queue_warning_dependent queue_warning_target queue_warning_code
  local has_queue_warning=false
  while IFS=$'\t' read -r queue_warning_dependent queue_warning_target queue_warning_code; do
    [[ -n "$queue_warning_dependent" ]] || continue
    if [[ "$has_queue_warning" == false ]]; then
      echo "⚠️  queue dependency warnings"
      has_queue_warning=true
    fi
    if [[ "$queue_warning_code" == queue_dependency_inversion ]]; then
      printf -- "- %s is queued before its unsatisfied dependency %s\n" \
        "$queue_warning_dependent" "$queue_warning_target"
    else
      printf -- "- %s is queued but its unsatisfied dependency %s is not queued\n" \
        "$queue_warning_dependent" "$queue_warning_target"
    fi
  done < <(queue_dependency_warnings)
  [[ "$has_queue_warning" == false ]] || echo

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
      die_as queue_locked "timed out waiting for another queue mutation"
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
      die_as queue_records "cannot update queue: invalid entry '$line'"
    fi
    [[ -z "${seen[$line]:-}" ]] || continue
    seen["$line"]=1
    [[ "$line" != "$exempt" ]] || continue
    count="${INDEX_COUNT[$line]:-0}"
    (( count > 0 )) ||
      die_as queue_records "cannot update queue: unknown entry '$line'"
    (( count == 1 )) ||
      die_as queue_records "cannot update queue: ambiguous entry '$line'"
    queue_id_is_active "$line" ||
      die_as queue_records "cannot update queue: terminal entry '$line'"
  done
}

queue_require_active_id() {
  local id="$1"
  validate_id "$id"
  local count="${INDEX_COUNT[$id]:-0}"
  (( count > 0 )) || die_as not_found "unknown active stitch '$id'"
  (( count == 1 )) || die_as ambiguous "ambiguous stitch id '$id'"
  queue_id_is_active "$id" ||
    die_as terminal "stitch '$id' is terminal or archived, not active"
}

cmd_queue_mutation() {
  local action="$1"
  shift
  mutation_begin "$action" "$@"
  set -- "${MUTATION_ARGS[@]}"
  require_loom
  require_v2_mutation
  build_index

  local id="${1:-}" anchor="${2:-}"
  case "$action" in
    queue|first|unqueue)
      (( $# == 1 )) || die_as usage "$action requires <stitch-id>"
      ;;
    before|after)
      (( $# == 2 )) || die_as usage "$action requires <stitch-id> <anchor-stitch-id>"
      ;;
  esac
  MUTATION_ID="$id"

  if [[ "$action" == unqueue ]]; then
    validate_id "$id"
  else
    queue_require_active_id "$id"
  fi
  if [[ "$action" == before || "$action" == after ]]; then
    validate_id "$anchor"
    [[ "$id" != "$anchor" ]] ||
      die_as usage "$action requires different stitch and anchor IDs"
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
      die_as queue_anchor "queue anchor '$anchor' not found"
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
        die_as queue_anchor "queue anchor '$anchor' could not be positioned"
      ;;
  esac

  local changed=false i
  if (( ${#filtered[@]} != ${#QUEUE_LINES[@]} )); then
    changed=true
  else
    for (( i=0; i<${#filtered[@]}; i++ )); do
      [[ "${filtered[$i]}" == "${QUEUE_LINES[$i]}" ]] && continue
      changed=true
      break
    done
  fi

  queue_write_lines "${filtered[@]}" ||
    die_as write_failed "injected queue write failure before atomic rename"
  queue_release_lock
  mutation_result "$id" "$changed" "${INDEX_PATH[$id]:-}" \
    "${INDEX_STATE[$id]:-}" "$action $id"
}

cmd_queue_set() {
  require_loom
  require_v2_mutation

  local requested id line i changed=false noun=stitches
  local -a requested_ids=() rewritten=()
  declare -A requested_seen=()
  for requested in "$@"; do
    validate_id "$requested"
    [[ -z "${requested_seen[$requested]:-}" ]] || continue
    requested_seen["$requested"]=1
    requested_ids+=("$requested")
  done

  build_index
  for id in "${requested_ids[@]}"; do
    queue_require_active_id "$id"
  done

  queue_acquire_lock
  build_index
  queue_validate_records_for_mutation
  for id in "${requested_ids[@]}"; do
    queue_require_active_id "$id"
  done

  i=0
  for line in "${QUEUE_LINES[@]}"; do
    if [[ -z "$line" || "$line" == \#* ]]; then
      rewritten+=("$line")
    elif (( i < ${#requested_ids[@]} )); then
      rewritten+=("${requested_ids[$i]}")
      i=$((i + 1))
    fi
  done
  while (( i < ${#requested_ids[@]} )); do
    rewritten+=("${requested_ids[$i]}")
    i=$((i + 1))
  done

  if (( ${#rewritten[@]} != ${#QUEUE_LINES[@]} )); then
    changed=true
  else
    for (( i=0; i<${#rewritten[@]}; i++ )); do
      [[ "${rewritten[$i]}" == "${QUEUE_LINES[$i]}" ]] && continue
      changed=true
      break
    done
  fi

  if [[ "$changed" == true ]]; then
    queue_write_lines "${rewritten[@]}" ||
      die_as write_failed "injected queue write failure before atomic rename"
  fi
  queue_release_lock
  (( ${#requested_ids[@]} != 1 )) || noun=stitch
  printf 'set queue (%s %s)\n' "${#requested_ids[@]}" "$noun"
}

dependency_create_edge() {
  local stitch_dir="$1" target="$2" needs="$1/needs" temp
  if [[ -d "$needs" ]]; then
    temp="$(mktemp "$needs/.anchor.tmp.XXXXXX")"
    if [[ "${LOOM_TEST_FAIL_ANCHOR_WRITE:-}" == before-rename ]]; then
      rm -f -- "$temp"
      return 1
    fi
    mv "$temp" "$needs/$target"
    return
  fi

  temp="$(mktemp -d "$stitch_dir/.needs.tmp.XXXXXX")"
  : > "$temp/$target"
  if [[ "${LOOM_TEST_FAIL_ANCHOR_WRITE:-}" == before-rename ]]; then
    rm -rf -- "$temp"
    return 1
  fi
  mv "$temp" "$needs"
}

cmd_dependency_mutation() {
  local action="$1"
  shift
  mutation_begin "$action" "$@"
  set -- "${MUTATION_ARGS[@]}"
  require_loom
  require_v2_mutation
  (( $# == 2 )) || die_as usage "$action requires <stitch-id> <target-stitch-id>"

  local id="$1" target="$2" stitch_dir target_count target_state
  local needs entry changed=false
  validate_id "$id"
  MUTATION_ID="$id"
  validate_id "$target"
  [[ "$id" != "$target" ]] || {
    MUTATION_ERROR_IDS=("$target")
    die_as dependency_cycle "anchoring '$id' to itself would create a dependency cycle"
  }

  build_index
  queue_require_active_id "$id"
  stitch_dir="${INDEX_PATH[$id]}"
  needs="$stitch_dir/needs"
  [[ -z "${INDEX_INVALID[$id]:-}" ]] ||
    die_as structural "stitch '$id' has invalid dependency storage"

  if [[ -e "$needs" || -L "$needs" ]]; then
    [[ -d "$needs" && ! -L "$needs" ]] ||
      die_as structural "dependency storage for '$id' is not a directory"
  fi
  entry="$needs/$target"
  if [[ -e "$entry" || -L "$entry" ]]; then
    [[ -f "$entry" && ! -L "$entry" ]] ||
      die_as structural "dependency '$id -> $target' is not a regular file"
    if [[ "$action" == anchor ]]; then
      mutation_result "$id" false "$stitch_dir" "${INDEX_STATE[$id]}" \
        "already anchored $id -> $target"
      return
    fi
  elif [[ "$action" == unanchor ]]; then
    mutation_result "$id" false "$stitch_dir" "${INDEX_STATE[$id]}" \
      "already unanchored $id -> $target"
    return
  fi

  if [[ "$action" == anchor ]]; then
    target_count="${INDEX_COUNT[$target]:-0}"
    (( target_count > 0 )) || {
      MUTATION_ERROR_IDS=("$target")
      die_as not_found "dependency target '$target' not found"
    }
    (( target_count == 1 )) || {
      MUTATION_ERROR_IDS=("$target")
      die_as ambiguous "dependency target '$target' is ambiguous"
    }
    target_state="${INDEX_STATE[$target]}"
    [[ "$target_state" != dropped && "$target_state" != abandoned ]] || {
      MUTATION_ERROR_IDS=("$target")
      die_as terminal "dependency target '$target' is dropped"
    }
    if dependency_path_exists "$target" "$id"; then
      MUTATION_ERROR_IDS=("$target")
      die_as dependency_cycle "anchoring '$id -> $target' would create a dependency cycle"
    fi
    dependency_create_edge "$stitch_dir" "$target" ||
      die_as write_failed "injected dependency write failure before atomic rename"
    changed=true
    mutation_result "$id" "$changed" "$stitch_dir" "${INDEX_STATE[$id]}" \
      "anchored $id -> $target"
    return
  fi

  rm -f -- "$entry"
  rmdir -- "$needs" 2>/dev/null || true
  changed=true
  mutation_result "$id" "$changed" "$stitch_dir" "${INDEX_STATE[$id]}" \
    "unanchored $id -> $target"
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
  mutation_begin wait "$@"
  set -- "${MUTATION_ARGS[@]}"
  require_loom
  require_v2_mutation
  build_index
  local id="${1:-}"
  [[ -n "$id" ]] || die_as usage "wait requires <stitch-id>"
  (( $# == 1 )) || die_as usage "wait accepts only <stitch-id>"
  validate_id "$id"
  MUTATION_ID="$id"

  local existing current parent_dir dest descendant descendant_path descendant_id
  local conflicts=() conflict_ids=()
  existing="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$existing" ]] || die_as not_found "stitch '$id' not found"
  ensure_under_threads "$existing" "$id" wait

  current="$(state_of_name "$(basename "$existing")")"
  if [[ "$current" == waiting ]]; then
    mutation_result "$id" false "$existing" waiting "already waiting: $id"
    return 0
  fi
  if [[ "$current" == tied || "$current" == dropped ]]; then
    die_as terminal "cannot wait terminal stitch '$id' ($current)"
  fi
  has_terminal_ancestor "$existing" &&
    die_as terminal "cannot wait abandoned stitch '$id' beneath a terminal ancestor"

  while IFS= read -r descendant; do
    [[ -n "$descendant" ]] || continue
    [[ "$(state_of_name "$(basename "$descendant")")" == stitching ]] ||
      continue
    descendant_id="$(strip_state_suffix "$(basename "$descendant")")"
    descendant_path="${descendant#$LOOM_DIR/threads/}"
    conflicts+=("$descendant_id ($descendant_path)")
    conflict_ids+=("$descendant_id")
  done < <(walk_recognized "$existing")

  if (( ${#conflicts[@]} > 0 )); then
    if [[ "$MUTATION_JSON" == true ]]; then
      MUTATION_ERROR_CODE=claimed_descendants
      MUTATION_ERROR_IDS=("${conflict_ids[@]}")
      mutation_emit_error "cannot wait '$id' — claimed descendant stitches"
    fi
    echo "error: cannot wait '$id' — claimed descendant stitches:" >&2
    printf '  - %s\n' "${conflicts[@]}" >&2
    echo "tie, drop, or otherwise relinquish each claim before waiting the subtree." >&2
    exit 1
  fi

  parent_dir="$(dirname "$existing")"
  dest="$parent_dir/$id.waiting"
  [[ ! -e "$dest" ]] || die_as destination_exists "destination already exists: $dest"
  mv "$existing" "$dest"
  mutation_result "$id" true "$dest" waiting "waiting $id"
}

cmd_resume() {
  mutation_begin resume "$@"
  set -- "${MUTATION_ARGS[@]}"
  require_loom
  require_v2_mutation
  build_index
  local id="${1:-}"
  [[ -n "$id" ]] || die_as usage "resume requires <stitch-id>"
  (( $# == 1 )) || die_as usage "resume accepts only <stitch-id>"
  validate_id "$id"
  MUTATION_ID="$id"

  local existing current parent_dir dest
  existing="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$existing" ]] || die_as not_found "stitch '$id' not found"
  ensure_under_threads "$existing" "$id" resume
  has_terminal_ancestor "$existing" &&
    die_as terminal "cannot resume abandoned stitch '$id' beneath a terminal ancestor"

  current="$(state_of_name "$(basename "$existing")")"
  [[ "$current" == waiting ]] ||
    die_as not_waiting "'$id' is not directly waiting"

  parent_dir="$(dirname "$existing")"
  dest="$parent_dir/$id"
  [[ ! -e "$dest" ]] || die_as destination_exists "destination already exists: $dest"
  mv "$existing" "$dest"
  mutation_result "$id" true "$dest" plain "resumed $id"
}

cmd_drop() {
  mutation_begin drop "$@"
  set -- "${MUTATION_ARGS[@]}"
  require_loom
  require_v2_mutation
  ensure_trays
  build_index
  local id="${1:-}"
  shift || true
  [[ -n "$id" ]] || die_as usage "drop requires <stitch-id>"
  validate_id "$id"
  MUTATION_ID="$id"

  local src
  src="$(find_unique_stitch_anywhere "$id" || true)"
  [[ -n "$src" ]] || die_as not_found "stitch '$id' not found"
  case "$src" in
    "$LOOM_DIR/tied"/*|"$LOOM_DIR/legacy-v1/tied"/*)
      die_as terminal "cannot drop a tied stitch"
      ;;
    "$LOOM_DIR/dropped"/*|"$LOOM_DIR/legacy-v1/dropped"/*)
      mutation_result "$id" false "$src" dropped "already dropped: $id"
      return 0
      ;;
  esac

  local direct_state
  direct_state="$(state_of_name "$(basename "$src")")"
  [[ "$direct_state" != tied ]] || die_as terminal "cannot drop a tied stitch"
  if [[ "$direct_state" == dropped ]]; then
    mutation_result "$id" false "$src" dropped "already dropped: $id"
    return 0
  fi
  has_terminal_ancestor "$src" &&
    die_as terminal "cannot drop abandoned stitch '$id' beneath a terminal ancestor"

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
  [[ ! -e "$dest" ]] || die_as destination_exists "destination already exists: $dest"

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

  mutation_result "$canonical" true "$dest" dropped "dropped $canonical"
  if (( $# == 0 )) && [[ "$MUTATION_JSON" != true ]]; then
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
  echo "seed tied/ and dropped/ with .gitkeep after marker commit"
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
  # Every flat record has just moved to legacy-v1/, leaving both trays empty.
  # Seed them after the marker: before it, rollback is still available and must
  # restore the markerless v1 layout without stray files.
  ensure_trays
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
  # Sweeping the last archive empties the tray, which would lose it on the next
  # clone exactly as a pre-first-tie commit does.
  ensure_trays
}

revision_file_record() {
  local path="$1" relative="${1#"$LOOM_DIR"/}" sum
  if [[ -L "$path" ]]; then
    printf 'link\t%s\n' "$relative"
  elif [[ -f "$path" ]]; then
    sum="$(cksum < "$path")"
    printf 'file\t%s\t%s\n' "$relative" "$sum"
  elif [[ -e "$path" ]]; then
    printf 'other\t%s\n' "$relative"
  else
    printf 'missing\t%s\n' "$relative"
  fi
}

revision_manifest() {
  local tray dir relative file needs entry kind
  revision_file_record "$LOOM_DIR/format-version"
  revision_file_record "$LOOM_DIR/queue"
  for tray in threads tied dropped legacy-v1/tied legacy-v1/dropped; do
    if [[ -d "$LOOM_DIR/$tray" ]]; then
      printf 'tray\t%s\n' "$tray"
    elif [[ -e "$LOOM_DIR/$tray" || -L "$LOOM_DIR/$tray" ]]; then
      printf 'invalid-tray\t%s\n' "$tray"
    else
      printf 'missing-tray\t%s\n' "$tray"
    fi
  done

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    relative="${dir#"$LOOM_DIR"/}"
    printf 'stitch\t%s\n' "$relative"
    for file in instructions.md completed-at reason.md; do
      [[ -e "$dir/$file" || -L "$dir/$file" ]] || continue
      revision_file_record "$dir/$file"
    done
    needs="$dir/needs"
    if [[ -d "$needs" ]]; then
      printf 'needs\t%s/needs\n' "$relative"
      shopt -s nullglob dotglob
      for entry in "$needs"/*; do
        [[ "$(basename "$entry")" != . && "$(basename "$entry")" != .. ]] || continue
        if [[ -L "$entry" ]]; then kind=link
        elif [[ -f "$entry" ]]; then kind=file
        elif [[ -d "$entry" ]]; then kind=directory
        else kind=other
        fi
        printf 'need\t%s\t%s\n' "$kind" "${entry#"$LOOM_DIR"/}"
      done
      shopt -u nullglob dotglob
    elif [[ -e "$needs" || -L "$needs" ]]; then
      printf 'invalid-needs\t%s/needs\n' "$relative"
    fi
  done < <(walk_all_stitches | sort)
}

cmd_revision() {
  require_loom
  [[ $# -eq 0 ]] || die "revision takes no arguments"
  [[ "$(format_version_state)" == v2 ]] ||
    die "revision requires a format v2 loom (run migrate-v2 first)"
  revision_manifest | cksum | awk '{ printf "%s-%s\n", $1, $2 }'
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
      if [[ "$cmd" == queue && "${1:-}" == --set ]]; then
        shift
        cmd_queue_set "$@"
      else
        cmd_queue_mutation "$cmd" "$@"
      fi
      ;;
    anchor|unanchor)
      shift
      cmd_dependency_mutation "$cmd" "$@"
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
    revision)
      shift
      cmd_revision "$@"
      ;;
    map)
      shift
      cmd_map "$@"
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
