# 🪡 loom

A tiny, file-based protocol for planning and tending chains of work.

A **stitch** is one small intention. A **thread** is a goal and everything that decomposes from it.

When you open `.loom/threads/`, you are looking at the work you have on the loom.

```
.loom/
  loom.sh
  threads/
  tied/
  dropped/
```

## Quickstart

To install from GitHub run:

```sh
mkdir -p .loom && curl -fsSL https://raw.githubusercontent.com/zealtv/loom/main/.loom/loom.sh -o .loom/loom && curl -fsSL https://raw.githubusercontent.com/zealtv/loom/main/README.md -o .loom/README.md && chmod +x .loom/loom && (cd .loom && ./loom init)
```

This copies `loom` and `README.md` into the
project's newly created `.loom/` directory, then runs `./loom init` to seed the
trays.

For a fresh loom, `init` creates `threads/`, `tied/`, and `dropped/` next to
itself and writes `format-version` with value `2`. It does not mark a
markerless loom containing existing history as v2.
`loom.sh` operates on the `.loom/` directory it lives in, so each copy is self-contained.


## What a loom is for

A loom holds work that has shape.

Every thread has a **goal stitch** at its root — the outcome you want. The
goal decomposes into child stitches. A **loose end** is a plain stitch whose
children are resolved, whose hard dependencies are tied, and whose ancestors
are not waiting — a concrete action ready to be worked.

To work a loom, pick a loose end, tend it, and tie it off. When every sibling of a stitch is resolved, its parent becomes a loose end in turn. You keep tying off up the thread until the goal stitch is tied — then the thread is done.

## Structure

A stitch is a directory with an `instructions.md` file.

```
.loom/
  threads/
    goal-stitch/
      instructions.md
      child-stitch/
        instructions.md
```

* Top-level entries in `threads/` are goal stitches — one per thread.
* Only immediate child directories containing `instructions.md` are
  decomposition children. Other directories are opaque supporting material.
* A stitch has zero or one parent.
* Threads may branch.

## Rules

1. One stitch, one place.
2. Claim by suffix: `stitch-001/` → `stitch-001.stitching/`. Only loose ends can be claimed.
3. Wait by suffix: `stitch-001/` → `stitch-001.waiting/`. A waiting stitch explicitly parks that stitch and its whole subtree.
4. Tend by suffix: `parent/` → `parent.tending/`. A tended stitch has children and a visible steward; it does not lock its branch.
5. Tie off in place: a child becomes `stitch-001.tied/`; a completed goal and
   its whole tree move to `tied/stitch-001/`. A stitch can only be tied off
   when all its children are tied or dropped.
6. Drop in place: a child becomes `stitch-001.dropped/`; a dropped goal and
   its whole tree move to `dropped/stitch-001/`. The stitch contains
   `reason.md`.
7. Every tie or drop writes `completed-at` in local ISO-8601 seconds before
   the terminal rename or move.

The file system is the protocol.

## Claims and waits

The `.stitching` suffix is a claim — *"this one is mine."* POSIX `mv` is atomic, so claims are race-free. Only loose ends are claimed; the claim moves down with the work as you split.

The `.waiting` suffix explicitly parks a leaf, branch, or whole goal — for
example while blocked on a build, a review, or another person. Waiting is
inherited: every descendant beneath a waiting ancestor is excluded from
`loose-ends` and `next`, while siblings outside that subtree remain available.

Resume a directly waiting stitch with `resume <stitch-id>`. Resuming removes
only that stitch's `.waiting` suffix and leaves it unclaimed. It does not
silently resume an explicitly waiting descendant; resume that descendant
separately when appropriate. `claim` never resumes waiting work.

## Tending a branch

The `.tending` suffix means *"I am stewarding this branch."* It is only for stitches with children. Stewardship is visible coordination, not an exclusive lock: loose-end children beneath a tended parent remain visible in `loose-ends` and `next`, and other workers may claim them normally.

Use `tend <stitch-id>` to take stewardship and `release <stitch-id>` to return
the parent to its plain state. Adding another child preserves the parent's
`.tending` suffix. Waiting a tended branch ends its stewardship and parks the
subtree without changing descendant state.

After the final child is tied or dropped, a tended parent becomes childless. Either tie it directly if no final work remains, or release it and then claim it for final work. Claiming does not implicitly convert `.tending` to `.stitching`.

## Agent loop

1. Run `./loom.sh next` (or `./loom.sh loose-ends` to see all of them).
   Ready stitches named in `.loom/queue` come first in queue order, followed
   deterministically by the unqueued ready work (see **Ordering**).
2. Claim it: `./loom.sh claim <stitch-id>`.
3. Read its `instructions.md`. Ask: *what is the next concrete action?*
4. Decide:
   * the outcome is no longer wanted → **drop** with a reason
   * you can name the next action → **do it and tie off**
   * the next step or subtree is blocked on something external → **wait** (excluded from loose ends until explicitly resumed)
   * you can't yet name the next step → **split** into child stitches; the parent is unclaimed automatically, then claim one of the children

For longer decomposed work, `tend` the parent to make stewardship visible while its child loose ends remain available.

Keep loose ends small and direct. If a stitch is trying to do too much, split it.

## Sequence and parallel

Siblings are parallel. A parent waits for its children.

Nesting means decomposition only. To express *A must finish before B*, create
an empty regular file named for A's globally unique ID:

```text
<B>/needs/<A>
```

The file contents are reserved and ignored. A tied child or tied archived goal
satisfies the dependency. Active or waiting targets block B; missing, dropped,
or ambiguous targets are broken and reported by `status`. Dependency cycles
are reported once per cycle, and their members are never ready.

`needs/` is supporting material, not decomposition. This lets dependencies
cross branches and threads and represent fan-out and diamond-shaped work
without inventing parentage.

When siblings can happen in either order, do not add dependency files between
them.

## Ordering

Stitch IDs should be stable and semantic: `fetch-source`, `parse-catalog`, or
`publish-report`. Use `needs/<stitch-id>` when one stitch truly cannot proceed
until another is tied.

For softer preference, keep only the IDs that matter in `.loom/queue`:

```sh
./loom.sh queue parse-catalog
./loom.sh first urgent-repair
./loom.sh before publish-report parse-catalog
./loom.sh after fetch-source urgent-repair
./loom.sh unqueue urgent-repair
```

The first argument to `before` and `after` is the ID being moved. A queued
stitch that is waiting, claimed, or dependency-blocked is skipped, so it never
prevents later ready work. Unqueued ready stitches follow in lexical path
order. Reprioritising therefore never requires renaming an ID or repairing
dependency references.

## Read-only map

`loom.sh map` gives a compact human view of recently completed work, the
current ready frontier, coming or blocked work, and the complete decomposition
tree. `loom.sh map --json` emits the deterministic schema documented in
[`docs/protocol-v2.md`](docs/protocol-v2.md).

The JSON snapshot is the sole supported integration boundary for a future
browser, TUI, or other viewer. Viewers derive their display from that snapshot
and perform mutations by invoking Loom commands; they never edit or maintain a
second state model. Both map forms are strictly read-only.

## Artifacts

Notes, logs, decisions, intermediate files — put them inside the stitch
directory. Supporting directories do not become stitches merely because they
contain deeper directories or files named `instructions.md`. Artifacts travel
with retained terminal children and with the complete goal archive, leaving a
durable record of what happened.

## Migrating a v1 loom

A deployed markerless loom stays v1 until an operator explicitly migrates it.
`init`, `status`, `next`, install/update, and lifecycle commands never trigger
migration. Lifecycle and queue mutations on a non-empty markerless loom stop
with a migration hint.

First inspect the complete plan:

```sh
./loom.sh migrate-v2 --dry-run
```

The dry run validates the source and prints every backup, move, and marker
write without changing file bytes, paths, mtimes, or the format marker. Resolve
every reported orphan reason, name collision, malformed archive, or ambiguous
active directory before proceeding. V1 treated every directory under
`threads/` as a stitch, so a directory without `instructions.md` cannot be
silently reclassified during migration: either add instructions if it really
is a stitch, or move it aside and restore it as v2 support material after the
migration.

Then migrate:

```sh
./loom.sh migrate-v2
```

Active `threads/` remain in place with their lifecycle suffixes and artifacts.
Flat v1 history moves to `legacy-v1/tied/` and `legacy-v1/dropped/`; old
`dropped/<id>.reason.md` sidecars move inside the corresponding legacy record
as `reason.md`. Legacy records do not receive invented ancestry or
`completed-at` values. The summary counts active and legacy records and prints
warnings for top-level support entries retained unchanged.

### Interrupted migration and rollback

Before the first move, migration creates `.migrate-v2-staging/` containing an
immutable plan, an atomic completed-step journal, and recoverable copies of
every path it will move. If a run stops before `format-version` is committed,
ordinary mutations remain blocked:

```sh
./loom.sh migrate-v2              # validate the journal and resume
./loom.sh migrate-v2 --rollback   # restore the original markerless v1 paths
```

Rollback processes moves in reverse order, so an embedded dropped reason is
restored before its containing directory. Keep the staging directory intact
until one of these commands succeeds; it is the recovery material. If the v2
marker was committed but final staging cleanup was interrupted, rerun
`migrate-v2` to validate all destinations and finish cleanup. At that point
rollback is intentionally unavailable because the loom is already declared
v2.

## instructions.md

`instructions.md` is the conventional file that tells a human or agent what a stitch is for.

Keep it short. Keep it concrete.

It can contain:

* a brief
* notes
* links
* constraints
* a checklist


## Commands

```
./loom.sh init
./loom.sh new <stitch-id> [parent-stitch-id]
./loom.sh claim <stitch-id>
./loom.sh tend <stitch-id>
./loom.sh release <stitch-id>
./loom.sh wait <stitch-id>
./loom.sh resume <stitch-id>
./loom.sh tie <stitch-id>
./loom.sh drop <stitch-id> [reason...]
./loom.sh queue <stitch-id>
./loom.sh first <stitch-id>
./loom.sh before <stitch-id> <anchor-stitch-id>
./loom.sh after <stitch-id> <anchor-stitch-id>
./loom.sh unqueue <stitch-id>
./loom.sh loose-ends
./loom.sh tending
./loom.sh waiting
./loom.sh next
./loom.sh status
./loom.sh map [--json]
./loom.sh migrate-v2 [--dry-run|--rollback]
./loom.sh sweep [days]   # remove whole goal archives older than N days (default 14)
```

## Verification

Run the complete test entry point from the repository root:

```sh
./test/run.sh
```

The runner preserves the current lifecycle coverage and prints a loud skip for
each not-yet-implemented v2 stage. Set `LOOM_V2_STAGE=<stage-number>` while
implementing a stage to enable its contract tests and all earlier stages.

The frozen format contract is
[`docs/protocol-v2.md`](docs/protocol-v2.md). The test runner stages later v2
features independently while keeping every implemented stage covered.
