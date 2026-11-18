# 🪡 loom

A loom holds work that has shape.

A stitch is one small intention. A thread is a goal and everything that decomposes from it.

## Get started

Copy `.loom/` into your project:

```sh
git clone https://github.com/zealtv/loom
cp -R loom/.loom my-project/
```

Lay out a goal, and a stitch beneath it:

```sh
cd my-project
./.loom/loom.sh new ship-site
./.loom/loom.sh new write-copy ship-site
```

Pick a loose end, claim it, and tie it off:

```sh
./.loom/loom.sh next
./.loom/loom.sh claim write-copy
./.loom/loom.sh tie write-copy
```

## The loom

```text
.loom/
  threads/   the work you have on the loom
  tied/      completed threads
  dropped/   abandoned threads, each with a reason
```

A stitch is a directory with an `instructions.md` file, which tells a human or agent what the stitch is for. A loose end is a concrete action ready to be worked.

To work a loom, pick a loose end, tend it, and tie it off. You keep tying off up the thread until the goal stitch is tied — then the thread is done.

## Notes

- To upgrade, run `loom/install.sh my-project`. It never touches your threads. Never copy `.loom/` over a project that already has one.
- The full protocol lives in [`.loom/README.md`](.loom/README.md).
- The file system is the protocol. No database, no daemon, no hidden state.
