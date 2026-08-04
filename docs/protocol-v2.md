# Loom filesystem protocol v2

Status: released as Loom v2.0.1.

This document defines the authoritative on-disk protocol and observable CLI
behaviour for Loom format version 2. The filesystem is authoritative. Command
output and JSON maps are derived projections.

## Format and baseline

A v2 loom contains a regular file named `.loom/format-version` whose complete
contents are:

```text
2
```

The marker declares the interpretation of the filesystem; it is not a state
database. A fresh empty `loom init` writes it. `init` never upgrades a
non-empty markerless loom. Such a loom is v1 until an explicit
`migrate-v2`, and lifecycle mutations reject it with a migration hint.

The implementation baseline is Bash 4 or newer plus ordinary `find`, `sort`,
`mv`, `cp`, `date`, and `awk` implementations. JSON output must not require
`jq`. Ordering specified as lexical uses bytewise (`LC_ALL=C`) order.

## Layout and stitch recognition

The v2-owned entries are:

```text
.loom/
  format-version
  loom.sh
  queue                     # optional sparse preference
  threads/                  # active goal roots
  tied/                     # tied goal archives
  dropped/                  # dropped goal archives
  legacy-v1/                # migrated flat v1 history, if any
    tied/
    dropped/
```

### Tray survival

A loom normally lives in a version control repository, and git cannot track an
empty directory. An empty `tied/` or `dropped/` therefore does not survive a
commit and clone, and the loss is invisible until the first goal tie or drop
fails on the terminal move — after `completed-at` has already been written,
leaving a half-tied record in `threads/`.

Both trays therefore carry a `.gitkeep` placeholder. `init`, `migrate-v2`,
`tie`, `drop`, and `sweep` ensure both trays exist and are seeded:

* `init` seeds a fresh or already-v2 loom. It does not touch a non-empty
  markerless v1 loom, which it must leave byte-for-byte unchanged.
* `migrate-v2` seeds after the format marker commits, because migration moves
  every flat record into `legacy-v1/` and leaves both trays empty. Seeding
  after the marker keeps a rolled-back loom free of stray files.
* `tie` and `drop` seed before writing `completed-at`, which heals a loom
  already cloned without its trays.
* `sweep` seeds after pruning, since removing the last archive empties a tray.

`.gitkeep` is a plain file, so it is never a recognised stitch, never counts as
a tray entry, and is never swept.

Read-only commands never repair a missing tray. They report it: see the
`missing_tray` diagnostic.

### Cheap change detection

`revision` prints one deterministic checksum token derived from the recognised
stitch paths and protocol files, including instruction text, completion and
drop metadata, dependency entries, the format marker, and exact queue bytes.
The token changes whenever the state exposed to a viewer changes. It may be
polled to decide whether a full `map --json` projection is necessary.

`revision` is strictly read-only: it never repairs trays or changes bytes,
paths, or mtimes. The token is opaque and scoped to one Loom implementation;
consumers compare it for equality and must not parse or persist its checksum
algorithm as protocol state.

A goal stitch is an immediate child directory of `threads/`, `tied/`, or
`dropped/` that contains a regular `instructions.md`. A child stitch is only
an immediate child directory of a recognised stitch that itself contains a
regular `instructions.md`.

Traversal recurses only through recognised stitches. Every other directory is
supporting material and is opaque, even if a deeper descendant contains
`instructions.md`. In particular, `notes/`, `fixtures/`, and `needs/` never
contribute decomposition or identity merely because of their names or
contents.

Stitch IDs are globally unique across active stitches, goal archives, their
recognised descendants, and migrated legacy records. An ID matches
`[A-Za-z0-9._-]+`, but must not end in a reserved state suffix. A directory
basename is the ID plus zero or one of:

- `.stitching`
- `.waiting`
- `.tending`
- `.tied`
- `.dropped`

The suffix is lifecycle state, not part of the ID. Multiple state suffixes are
invalid. Supporting-directory names do not participate in ID uniqueness.

Goal archive roots are canonical unsuffixed directories. Their `tied/` or
`dropped/` tray supplies their terminal state. Recognised terminal descendants
retain their `.tied` or `.dropped` suffix.

Directory nesting answers only “what is this part of?” It never expresses
priority or a hard dependency.

## Lifecycle state and transitions

An active recognised stitch has one direct state:

| Name | Meaning |
| --- | --- |
| no suffix | active and unclaimed |
| `.stitching` | claimed for work |
| `.waiting` | this subtree is explicitly parked |
| `.tending` | this child-bearing branch has a steward |
| `.tied` | completed successfully in place |
| `.dropped` | completed as abandoned in place |

`.tied` and `.dropped` are terminal. A plain descendant preserved inside a
dropped ancestor or dropped goal archive is `abandoned` for derived views. It
was not individually completed and receives no invented terminal suffix or
timestamp.

Commands resolve IDs globally and fail on missing or duplicate recognised
IDs. State-changing commands use same-directory renames so their visible state
transition is atomic.

### `new <id> [parent-id]`

With no parent, create a plain goal under `threads/`. With a parent, create an
immediate child of an active recognised stitch. Archived or terminal parents
are rejected.

Adding a child preserves a plain, `.waiting`, or `.tending` parent state. A
`.stitching` parent becomes plain because a child-bearing stitch cannot retain
a leaf claim. The operation must not resume a waiting parent. New IDs are
checked for global uniqueness before any write.

### `claim <id>`

Claim succeeds only for an effectively ready plain stitch and renames it to
`.stitching`. Claiming an already claimed stitch is idempotent. Claiming a
directly waiting stitch fails with a `loom resume <id>` hint; claim never
resumes work.

### `tend <id>` and `release <id>`

`tend` accepts a plain active stitch with at least one unresolved
decomposition child and renames it `.tending`. Tending an already tended
stitch is idempotent. Waiting, claimed, terminal, archived, or childless
targets are rejected.

`release` changes `.tending` to plain. Releasing an already plain stitch is
idempotent; other direct states are rejected.

### `wait <id>` and `resume <id>`

`wait` may park a leaf, branch, or whole goal. It accepts a plain, claimed,
tended, or already waiting target. Before changing anything it scans all
proper recognised descendants and rejects the operation if any are
`.stitching`, listing every conflicting ID and relative path. The target
itself may be `.stitching`; parking it relinquishes that claim.

Waiting a tended node ends stewardship. The result has exactly one
`.waiting` suffix and preserves every descendant's direct state. Waiting an
already waiting node is idempotent.

`resume` is valid only for a directly `.waiting` stitch. It removes that
suffix and leaves the stitch plain; it neither claims the stitch nor resumes
any explicitly waiting descendant.

Waiting is inherited for effective readiness. A stitch beneath a waiting
ancestor is not ready even though its own direct state and suffix are
unchanged.

### `tie <id>`

Tie rejects waiting, dropped, archived, cyclic, broken, or dependency-blocked
targets. Every immediate child stitch must already be terminal. A tie may end
a plain, claimed, or tended active stitch.

For a non-root stitch, tie writes `completed-at` inside the stitch and then
renames the directory in place to `<id>.tied`. For a goal, it writes the
timestamp and atomically moves the complete, canonically unsuffixed root to
`tied/<id>/`. A goal archive preserves all descendants and supporting
material.

### `drop <id> [reason...]`

Drop is allowed for any active non-terminal stitch and does not require
readiness. It writes `completed-at` and `reason.md` inside the target. A
non-empty CLI reason is the body of `reason.md`; an omitted reason scaffolds
the file and prints the read-before-edit instruction.

A non-root target is renamed in place to `<id>.dropped`. A goal is moved as a
complete, canonically unsuffixed subtree to `dropped/<id>/`. Unfinished
descendants are preserved exactly and become abandoned by the ancestor; they
are not renamed, timestamped, or otherwise represented as completed. This
same rule applies when dropping a non-root branch with descendants.

### Completion timestamps and sweep

Every v2 tie or drop records `completed-at` before the terminal rename/move.
It is one line in local ISO-8601 seconds with a numeric UTC offset:

```text
YYYY-MM-DDTHH:MM:SS+HH:MM
YYYY-MM-DDTHH:MM:SS-HH:MM
```

Legacy records without an authoritative completion time omit the file and
emit `null` in the map. Filesystem mtimes are never promoted to completion
times.

`sweep [days]` removes only complete immediate-child goal archives from
`tied/` and `dropped/`. It never removes an individual terminal descendant or
anything beneath an active goal. Sweeping history can turn an external
dependency on a removed ID into a visibly broken missing dependency. Sweeping
the last archive out of a tray leaves the tray seeded, not empty.

## Decomposition and readiness

A direct child resolves decomposition when its direct state is `.tied` or
`.dropped`. All other direct child states are unresolved. A plain stitch is
effectively ready exactly when:

1. it is under `threads/` and has no terminal or dropped ancestor;
2. it has no waiting ancestor and is not directly waiting;
3. it is not claimed or tended;
4. every immediate child stitch is terminal;
5. every hard dependency is satisfied;
6. it is not a member of a dependency cycle; and
7. its identity and dependency records are structurally valid.

`loose-ends`, `next`, `claim`, `tie`, `status`, and `map` use one derived
index and this readiness definition. A support directory never blocks
readiness.

## Hard dependencies

A hard dependency is an immediate entry:

```text
<stitch-directory>/needs/<target-stitch-id>
```

The entry must be a regular file and its basename a valid stitch ID.
Canonical writers create an empty file; readers reserve and ignore its
contents. Directories, invalid IDs, and self-dependencies are errors.
`needs/` and all of its descendants are supporting material.

Dependency IDs resolve globally across recognised active stitches, retained
terminal children, goal archives, and migrated legacy records:

| Target | Edge state |
| --- | --- |
| tied child or tied goal archive | satisfied |
| authoritative legacy tied record | satisfied |
| active, claimed, tended, or waiting | blocked |
| dropped, abandoned, or legacy dropped | broken: dropped |
| absent | broken: missing |
| duplicated | broken: ambiguous |

A tied descendant remains satisfying even when retained in a dropped archive;
an unfinished descendant abandoned by that archive is broken.

Cycles are detected across all recognised IDs and are reported
deterministically. Each strongly connected cyclic component appears once,
with member IDs in bytewise order; a self-edge is both an invalid self-edge
and a one-member cycle. Cycle members are not ready.

`status` separates ordinary blocked edges from broken edges. It names the
dependent, target, and `missing`, `dropped`, or `ambiguous` cause. It exits
non-zero for malformed records, duplicate IDs, broken dependencies, or
cycles; ordinary unresolved dependencies do not make it fail.

## Sparse preference queue

`.loom/queue` is optional UTF-8 text. An ID record is one exact stitch ID per
line. Empty lines and lines whose first byte is `#` are ignored. Whitespace is
not trimmed from ID records. Duplicate, invalid, unknown, terminal, archived,
or abandoned ID records are diagnosed by `status`; these make its exit
non-zero.

Queue order is a soft preference, never a dependency. Commands are:

```text
loom queue <id>
loom queue --set <id>...
loom first <id>
loom before <id> <anchor-id>
loom after <id> <anchor-id>
loom unqueue <id>
```

The first argument to `before` and `after` is always the ID being moved. The
anchor must already occur in the queue and must differ from the moved ID.
`queue` moves/adds its ID at the end; `first` moves/adds it at the beginning.
All four require recognised active IDs. Repeating any operation has the same
result as running it once.

`unqueue` accepts any syntactically valid ID so it can repair a manually stale
queue. It removes every occurrence and is successful when none exists.

`queue --set` validates the entire existing queue and every requested ID, then
replaces the effective ID order in one atomic rename. Duplicate requested IDs
are removed, retaining their first occurrence. Existing blank and comment
records are preserved byte-for-byte in relative order: requested IDs fill the
existing ID slots from top to bottom, surplus slots disappear, and surplus IDs
are appended. An empty set clears every ID while retaining comments and blanks.
Repeating the same set is a filesystem no-op. Batch replacement is
human-output-only; the single-ID queue verbs retain the versioned mutation
result shape.

A mutation validates all records other than duplicate occurrences, removes
duplicates while retaining their first occurrence, performs the requested
move, and preserves comment/blank records byte-for-byte in their existing
relative order. An unrelated invalid or stale record makes the mutation fail
without changing the file. For repair, records equal to an `unqueue` target
are exempt from the unknown/terminal check and are all removed. The
implementation writes a sibling temporary file and atomically renames it over
`queue`; no portable fsync command is part of the baseline.

Normal tie/drop/archive operations atomically remove every ID made inactive
by that operation from the queue. Manually introduced stale records remain
visible diagnostics rather than being silently ignored.

`next` scans queued IDs in order and returns the first effectively ready ID,
skipping blocked or non-ready entries. It then falls back to unqueued ready
stitches in bytewise relative-path order. `loose-ends` lists all ready
stitches in that same effective preference order. Queue position is
one-based among ID records and is shown even when the item is currently
blocked.

`status` and `map --json` warn when a queued stitch has an unsatisfied direct
dependency that is either queued below it (`queue_dependency_inversion`) or
not queued (`queue_dependency_unqueued`). These are preference diagnostics:
they never change command health or prevent a deliberately unusual order.
Satisfied and transitive dependencies do not produce these warnings.

## Explicit v1 migration

`migrate-v2 --dry-run` validates and prints every planned move/write without
changing bytes or mtimes. `migrate-v2` validates the entire source before its
first mutation and never runs implicitly from `init`, install/update, status,
map, or a lifecycle command.

Migration preserves active `threads/` structure and suffixes. Every directory
that v1 traversal treated as a stitch must be inspected: a directory lacking
`instructions.md` is reported as support/ambiguity, never silently assigned
identity.

Flat v1 history moves without invented ancestry:

```text
.loom/tied/<id>/                  -> .loom/legacy-v1/tied/<id>/
.loom/dropped/<id>/               -> .loom/legacy-v1/dropped/<id>/
.loom/dropped/<id>.reason.md      -> .loom/legacy-v1/dropped/<id>/reason.md
```

Orphan sidecars, destination collisions, duplicate IDs, and malformed source
state abort validation. Legacy records preserve all bytes, omit
`completed-at` unless it already existed authoritatively, and are labelled
legacy in derived views.

Before moving source entries, migration creates
`.loom/.migrate-v2-staging/` with a manifest and recoverable copies. Completed
manifest steps are recorded atomically. The format marker is written via a
sibling temporary and rename only after every planned step succeeds. An
interrupted staging directory blocks ordinary mutations and gives exact
instructions to rerun `migrate-v2` to resume or
`migrate-v2 --rollback` to restore the v1 paths. Re-running after the marker
exists is a successful no-op.

The migration summary reports active stitches, legacy tied/dropped records,
moved reasons, and warnings. It never labels an mtime as completion time.

## Map projection

`map` and `map --json` are strictly read-only and use the same canonical
index as lifecycle and status commands. Neither command may alter bytes,
paths, or mtimes.

Plain `map` has four deterministic sections:

1. recently completed, newest authoritative `completed-at` first;
2. current frontier, in effective queue/fallback order;
3. coming/blocked work with reasons; and
4. the decomposition tree.

It is readable without ANSI control sequences. Missing legacy timestamps sort
after authoritative timestamps and then by ID; they are labelled unknown,
not guessed. Authoritative timestamps are ordered as instants after applying
their numeric UTC offsets. Equal instants use bytewise stitch ID as the
deterministic tie-break.

`map --json` emits one JSON object with this schema:

```text
schema_version       integer, currently 1
format_version       integer, currently 2
loom_root            absolute string path to .loom
stitches             array of stitch objects, sorted by relative path
decomposition_edges  array of {parent, child}, sorted by parent then child
dependency_edges     array of dependency objects, sorted by from then to
cycles               array of ID arrays, components then members bytewise
frontier             array of ready IDs in effective preference order
recently_completed   array of IDs in timestamp-descending order
diagnostics          array of diagnostic objects in stable code/path order
```

Every stitch object has:

```text
id                   string
root_id              string
parent_id            string or null
path                 slash-separated path relative to .loom
tray                 "threads", "tied", "dropped", "legacy-tied",
                     or "legacy-dropped"
state                "plain", "stitching", "waiting", "tending", "tied",
                     "dropped", or "abandoned"
ready                boolean
waiting_inherited    boolean
queue_position       one-based integer or null
completed_at         ISO-8601 string or null
archived             boolean
legacy               boolean
children             array of direct child IDs, bytewise
dependencies         array of dependency objects, sorted by target ID
cycle                 array of component member IDs, or []
```

Every dependency object has `from`, `to`, `status`, and `reason`.
`status` is `satisfied`, `blocked`, or `broken`; `reason` is null unless
broken, then `missing`, `dropped`, `ambiguous`, or `invalid`.

Every diagnostic has `severity` (`warning` or `error`), a stable `code`, a
human-readable `message`, and nullable `stitch_id` and `target_id`. JSON
strings use correct JSON escaping. `map --json` remains valid JSON even when
errors are present and exits non-zero under the same health rules as
`status`. Only `error` diagnostics affect health; a `warning` never changes an
exit code.

The codes in use are:

| Code | Severity | Meaning |
| --- | --- | --- |
| `broken_dependency` | error | a `needs/` target is missing, dropped, ambiguous, or invalid |
| `dependency_cycle` | error | a dependency cycle, reported once per cycle |
| `missing_tray` | warning | `tied/` or `dropped/` is absent; the next tie or drop recreates it |
| `queue_dependency_inversion` | warning | a queued stitch precedes its unsatisfied direct dependency |
| `queue_dependency_unqueued` | warning | a queued stitch has an unqueued unsatisfied direct dependency |
| `queue_error` | error | a malformed or unresolvable `queue` entry |
| `structural_error` | error | a malformed stitch, duplicate ID, or invalid `completed-at` |

Diagnostics are emitted in stable code order, then by the path or ID the
diagnostic concerns. The code set is open: consumers must tolerate an
unrecognised `code` rather than treat it as a parse failure. Adding a code is
therefore not a `schema_version` change; adding or removing a *field* is.

The JSON snapshot is the sole supported integration boundary for future
viewers. A viewer reads this projection and performs mutations only by
invoking Loom commands; it owns no protocol state.

`map --json --active` emits the same schema restricted to records in the
active `threads/` tray, including terminal children retained beneath an active
goal. Goal archives and migrated legacy records are omitted from `stitches`,
`decomposition_edges`, `dependency_edges`, and `recently_completed`; an edge
to an omitted terminal target remains visible in its active stitch's nested
`dependencies` array. `--active` is a projection option, not a schema change,
and may also be used with the plain map.

## Structured mutation results

Every lifecycle and queue mutation accepts `--json`: `claim`, `tend`,
`release`, `wait`, `resume`, `tie`, `drop`, `queue`, `first`, `before`,
`after`, and `unqueue`. The flag is recognised only before the first
positional argument, so a `drop` reason remains literal and may itself contain
`--json`.

The flag is additive. Without it every command's output is byte-for-byte what
it always was, which the agent loop and existing scripts depend on. With it,
that command's stdout is exactly one JSON object and nothing else, including
the read-before-edit hint `drop` prints when given no reason.

A successful mutation emits:

```text
schema_version       integer, currently 1
format_version       integer, currently 2
command              the command name as invoked
ok                   true
changed              false when the command was an accepted no-op
id                   the affected stitch ID
state                its state after the mutation, or null
path                 its path after the mutation, relative to .loom, or null
tray                 its tray after the mutation, or null
queue_position       its one-based queue position afterwards, or null
completed_at         ISO-8601 string for a tie or drop, otherwise null
```

`state`, `path`, and `tray` use the same vocabulary as a `map --json` stitch
object and are the mutation's own authoritative result, not a re-derived
projection: a viewer applies them directly instead of re-running `map`. They
are null only where the ID is not a stitch on disk, which just `unqueue`'s
repair path reaches. `queue_position` is recomputed from the queue file after
the write, so a tie or drop that evicts its ID reports null.

The idempotent cases — claiming a claimed stitch, tying a tied one, unqueueing
an absent record — are successes with `changed: false`. A queue mutation that
leaves the file byte-identical is likewise unchanged.

A failed mutation emits, on stdout, exit status non-zero:

```text
schema_version       integer, currently 1
format_version       integer, currently 2
command              the command name as invoked
ok                   false
id                   the target stitch ID, or null if none was parsed
error                {code, message, stitch_ids}
```

`message` is the same text the command writes to stderr, which it still writes
unchanged. `stitch_ids` names the other stitches implicated in the failure —
the unresolved children, the claimed descendants, the blocking waiting
ancestor — and is otherwise empty.

The codes in use are:

| Code | Meaning |
| --- | --- |
| `usage` | wrong argument count, or an unknown option |
| `format` | the loom is not v2, or a migration is unfinished |
| `invalid_id` | the ID is syntactically invalid |
| `not_found` | no stitch with that ID |
| `ambiguous` | more than one stitch with that ID |
| `not_under_threads` | the target is archived, not active |
| `terminal` | the target or an ancestor is tied or dropped |
| `waiting` | the target or an ancestor is parked |
| `tended` | the target has a steward; release it first |
| `not_tended` | the target is not tended |
| `not_waiting` | the target is not directly waiting |
| `not_ready` | dependency blockage, broken dependency, or cycle |
| `not_loose_end` | the target has unresolved children |
| `not_child_bearing` | the target has no children requiring work |
| `unresolved_children` | a tie whose children are not all terminal |
| `claimed_descendants` | a wait over a claimed descendant |
| `destination_exists` | the rename target already exists |
| `queue_anchor` | the `before`/`after` anchor is not in the queue |
| `queue_locked` | another queue mutation held the lock too long |
| `queue_records` | an unrelated queue record is invalid or stale |
| `write_failed` | the queue write failed before its atomic rename |
| `failed` | the fallback for a failure with no more specific code |

Like diagnostic codes, this set is open: a consumer must tolerate an
unrecognised `code` rather than treat it as a parse failure. Adding a code is
not a `schema_version` change; adding or removing a *field* is. The mutation
result carries its own `schema_version`, independent of the map projection's.
