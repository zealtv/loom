# 🪡 loom

A tiny, file-based protocol for planning and tending chains of work.

A stitch is one small intention. Stitches form threads.

When you open `.loom/threads/`, you are looking at the goals you are working toward.

```
.loom/
  threads/
  tied/
  dropped/
```

## What a loom is for

A loom holds work that has shape.

A stitch at the root of `threads/` is a goal. Its children are the stitches it decomposes into. The leaves are where real work happens.

To work a loom, you walk down a goal to a leaf, tend the leaf, and walk back up — tying off stitches as their children complete.

## How loom works

A stitch is a directory with an `instructions.md` file.

```
.loom/
  threads/
    stitch-001/
      instructions.md
      stitch-002/
        instructions.md
```

* root entries in `threads/` are goals
* child stitches are the decomposition
* a leaf stitch has no children — it is the work ready now
* a stitch has zero or one parent
* branches are allowed

## Rules

1. One stitch, one place.
2. Claim by suffix: `stitch-001/` → `stitch-001.stitching/`
3. Tie off by move: move a stitch to `tied/`
4. A stitch can only be tied off when all its children are tied off or dropped.
5. Drop by move: move a stitch to `dropped/` and write `stitch-001.reason.md`

The file system is the protocol.

## Agent loop

1. Look at `.loom/threads/` and pick a goal
2. Walk down into the goal to find a leaf stitch
3. Read its `instructions.md`
4. Claim it by renaming the directory with `.stitching`
5. Work
6. Either:
   * tie it off
   * drop it with a reason
   * or split it by creating child stitches inside it

When a stitch is tied off, walk up to its parent. If all siblings are resolved, the parent is now a leaf and can be tended.

Keep stitches small. Split a stitch when it starts doing too much.

## instructions.md

`instructions.md` is the conventional file that tells a human or agent what the stitch is for.

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
./loom.sh tie <stitch-id>
./loom.sh drop <stitch-id> [reason...]
./loom.sh tips
./loom.sh status
```
