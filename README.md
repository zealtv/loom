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

`init` creates `threads/`, `tied/`, and `dropped/` next to itself.
`loom.sh` operates on the `.loom/` directory it lives in, so each copy is self-contained.


## What a loom is for

A loom holds work that has shape.

Every thread has a **goal stitch** at its root — the outcome you want. The goal decomposes into child stitches. A stitch with no children is a **loose end** — a concrete action ready to be worked.

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
* Children are the decomposition.
* A stitch has zero or one parent.
* Threads may branch.

## Rules

1. One stitch, one place.
2. Claim by suffix: `stitch-001/` → `stitch-001.stitching/`. Only loose ends can be claimed.
3. Own by suffix: `goal-stitch/` → `goal-stitch.owned/`. Only goal stitches can be owned.
4. Wait by suffix: `stitch-001/` → `stitch-001.waiting/`. A waiting stitch is a loose end blocked on something external.
5. Tie off by move: move a stitch to `tied/`. A stitch can only be tied off when all its children are tied or dropped.
6. Drop by move: move a stitch to `dropped/` and write `stitch-001.reason.md`.

The file system is the protocol.

## Claims and waits

The `.stitching` suffix is a claim — *"this one is mine."* POSIX `mv` is atomic, so claims are race-free. Only loose ends are claimed; the claim moves down with the work as you split.

The `.waiting` suffix marks a loose end blocked on something external — a build, a review, another person. Waiting stitches are excluded from `loose-ends` and `next`. To resume one, claim it again.

Waiting belongs on loose ends, not parent stitches. To block a whole parent or thread, add a concrete blocker child and mark that child waiting, for example `vendor-approval.waiting/`.

## Owned threads

The `.owned` suffix is a claim on a whole goal thread — useful when the loom lives on `main`, and the work happens on a feature branch.

Ownership is only for top-level goal stitches. It does not replace loose-end claims: child stitches under an owned thread are still claimed, waited, tied, and dropped normally.

One branch-friendly loop is:

```sh
git checkout main
./loom.sh own billing-refresh
git checkout -b feature/billing-refresh

./loom.sh next
./loom.sh claim first-child
# work, split, wait, tie, or drop loose ends as usual

git checkout main
git merge feature/billing-refresh
./loom.sh tie billing-refresh
```

## Agent loop

1. Run `./loom.sh next` (or `./loom.sh loose-ends` to see all of them). Loose ends are listed alphanumerically — if order matters, name stitches in the order you want them taken.
2. Claim it: `./loom.sh claim <stitch-id>`.
3. Read its `instructions.md`. Ask: *what is the next concrete action?*
4. Decide:
   * the outcome is no longer wanted → **drop** with a reason
   * you can name the next action → **do it and tie off**
   * the next step is blocked on something external → **wait** (excluded from loose ends until you claim it again)
   * you can't yet name the next step → **split** into child stitches; the parent is unclaimed automatically, then claim one of the children

Keep loose ends small and direct. If a stitch is trying to do too much, split it.

## Sequence and parallel

Siblings are parallel. A parent waits for its children.

To express *A must happen before B*: make B the parent and place A inside it as a child. A must be tied before B can be tied.

When two siblings both need to happen, name them so they sort in the order you want them taken. Loose ends are listed alphanumerically.

## Artifacts

Notes, logs, decisions, intermediate files — put them inside the stitch directory. They travel with the stitch into `tied/` or `dropped/`, leaving a durable record of what happened.

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
./loom.sh own <goal-stitch-id>
./loom.sh unown <goal-stitch-id>
./loom.sh wait <stitch-id>
./loom.sh tie <stitch-id>
./loom.sh drop <stitch-id> [reason...]
./loom.sh loose-ends
./loom.sh waiting
./loom.sh next
./loom.sh status
./loom.sh sweep [days]   # remove tied/dropped older than N days (default 14); prints one line per item
```
