# 🪡 loom

A tiny, file-based protocol for planning and tending chains of work.

Loom keeps work small and visible. A stitch is one intention. Stitches form threads.

Loom is for planning as much as tracking. You can lay out a handful of stitches, shape them into threads, spot loose ends, and see what is ready without needing a database or a thick layer of tooling.

When you open `.loom/threads/`, you should see the work that is ready now.

```text
                              .loom/
                 ┌──────────────┬───────────┬────────────┐
                 │   threads/   │   tied/   │  dropped/  │
                 └──────┬───────┴────▲──────┴─────▲──────┘
                        │            │            │
                        ▼            │            │
                     stitch       tie off       drop
```

Anyone — a script, an AI, or a human — can create, stitch, tie off, drop, or inspect the current loom.

## ✨ Install

Clone the repo.

That is enough to begin.

There is no database, no daemon, no hidden state, and no scaffolder.

## 🌿 Terminology

- **loom** — a `.loom/` folder at the root of a project.
- **stitch** — one small intention, stored as a directory.
- **thread** — a chain of stitches.
- **instructions.md** — the conventional file describing what a stitch is for.
- **stitching** — a claimed stitch; off limits to others.
- **tie off** — complete a stitch by moving it to `tied/`.
- **drop** — abandon a stitch by moving it to `dropped/`, with a reason file.

## 🧵 The protocol

A loom is a `.loom/` folder:

```text
.loom/
  threads/     ready stitches at the heads of threads
  tied/        completed stitches
  dropped/     abandoned stitches, each with a .reason.md sibling
```

A stitch is a directory:

```text
stitch-001/
  instructions.md
  stitch-002/
    instructions.md
```

A stitch may have zero or one predecessor.

If a stitch follows another stitch, place it inside that stitch.

This means:
- root entries in `threads/` are ready now
- child stitch directories are continuations
- branches are allowed
- merges are not part of v1

## 📏 Rules

1. **One stitch, one place** — a stitch exists in exactly one place at a time.
2. **Claim by suffix** — to claim a stitch, rename `stitch-001/` to `stitch-001.stitching/`.
3. **Tie off by move** — when a stitch is complete, move it to `.loom/tied/`.
4. **Promote continuations** — when a stitch is tied, move its direct child stitches to the parent thread level so they become visible as ready.
5. **Drop on failure** — move the stitch to `.loom/dropped/` and write a sibling `.reason.md` file explaining why.

The file system is the protocol.

## 🔄 Stitch states

```text
.loom/threads/    stitch-001/             → stitch-001.stitching/
.loom/tied/       stitch-001/
.loom/dropped/    stitch-001/             + stitch-001.reason.md
```

## 🪄 instructions.md

`instructions.md` is the conventional file that tells a human, script, or AI what the stitch is for.

Keep it short. Keep it concrete. Split a stitch when it starts doing too much.

A stitch can contain notes, a short brief, links, constraints, or a checklist — whatever helps it be tended well.
