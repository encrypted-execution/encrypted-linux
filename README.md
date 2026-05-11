# encrypted-linux

A Linux distribution built with a scrambling GCC, such that programs built outside the closure of the build cannot execute on the target.

This is an instantiation of the **Encrypted Execution** thesis (Gore, 2025) at the
`<compiler-codegen-backend, ISA>` layer — the extreme case the paper itself names
(whitepaper p. 10, item 4).

## Status

**Research phase.** No code yet. Six parallel research dossiers have been
collected. The next step is to synthesize them into a phased plan of action and
build the smallest demonstrable PoC.

See `STATE.md` for the current state and the next steps for any agent that
resumes this work.

## Layout

- `STATE.md` — current state, what's done, what's next
- `research/` — research dossiers (one file per topic, each ≤2000 words)
- `plan/` — phased plan documents (to be authored next)

## Goals

**Phase 1 — Userland scrambling.**
A scrambling GCC + scrambled musl + scrambled BusyBox + stock kernel,
booting in QEMU. A stock-built ELF run on the target fails cleanly at
dynamic-linker symbol resolution. Core kernel syscall ABI is preserved.

**Phase 2 — Kernel scrambling.**
Per-build syscall renumbering and per-build kernel-internal calling
convention scrambling. Closes the static-binary gap. External kernel
modules cannot load. Defeats pre-canned ROP / kernel-exploit chains.

## License

To be decided. The Encrypted Execution patent (USPTO 10,733,303) is pledged
to the public domain by the author. Default proposal: Apache-2.0 for new
code; upstream licenses preserved where applicable.
