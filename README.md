# 🪡 loom

A tiny, file-based protocol for planning and tending chains of work.

A stitch is one small intention. Stitches form threads.

When you open `.loom/threads/`, you are looking at the work that is ready now.

```text
.loom/
  threads/
  tied/
  dropped/
```

## How loom works

A stitch is a directory with an `instructions.md` file.

```text
.loom/
  threads/
    stitch-001/
      instructions.md
      stitch-002/
        instructions.md
```

- root entries in `threads/` are ready now
- child stitch directories are continuations
- a stitch has zero or one predecessor
- branches are allowed

## Rules

1. One stitch, one place.
2. Claim by suffix: `stitch-001/` → `stitch-001.stitching/`
3. Tie off by move: move a ready stitch to `tied/`
4. When a stitch is tied, move its direct child stitches up to `threads/`
5. Drop by move: move a stitch to `dropped/` and write `stitch-001.reason.md`

The file system is the protocol.

## Agent loop

1. Look at `.loom/threads/`
2. Pick one stitch
3. Read `instructions.md`
4. Claim it by renaming the directory with `.stitching`
5. Work
6. Either:
   - tie it off and promote its continuations
   - drop it with a reason
   - or create a continuation stitch inside it

Keep stitches small. Split a stitch when it starts doing too much.

## instructions.md

`instructions.md` is the conventional file that tells a human or agent what the stitch is for.

Keep it short. Keep it concrete.

It can contain:
- a brief
- notes
- links
- constraints
- a checklist

## Commands

```text
./loom.sh init
./loom.sh new <stitch-id> [after-stitch-id]
./loom.sh claim <stitch-id>
./loom.sh tie <stitch-id>
./loom.sh drop <stitch-id> [reason...]
./loom.sh status
```
