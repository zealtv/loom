# 🪡 loom

A tiny, file-based protocol for planning and tending chains of work.

A **stitch** is one small intention. A **thread** is a goal and everything that decomposes from it.

When you open `.loom/threads/`, you are looking at the work you have on the loom.

```
.loom/
  threads/
  tied/
  dropped/
```

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
3. Wait by suffix: `stitch-001/` → `stitch-001.waiting/`. A waiting stitch is a loose end blocked on something external.
4. Tie off by move: move a stitch to `tied/`. A stitch can only be tied off when all its children are tied or dropped.
5. Drop by move: move a stitch to `dropped/` and write `stitch-001.reason.md`.

The file system is the protocol.

## Claims and waits

The `.stitching` suffix is a claim — *"this one is mine."* POSIX `mv` is atomic, so claims are race-free. Only loose ends are claimed; the claim moves down with the work as you split.

The `.waiting` suffix marks a loose end blocked on something external — a build, a review, another person. Waiting stitches are excluded from `loose-ends` and `next`. To resume one, claim it again.

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
./loom.sh wait <stitch-id>
./loom.sh tie <stitch-id>
./loom.sh drop <stitch-id> [reason...]
./loom.sh loose-ends
./loom.sh waiting
./loom.sh next
./loom.sh status
```
