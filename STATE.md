# encrypted-linux — Current State

**Last updated:** 2026-05-11
**Phase:** Plan complete. Ready for implementation review.

## What's done

### Research (all 7 dossiers in `research/`)

1. `01-encrypted-execution-thesis.md` — The Encrypted Execution paper
   (Gore 2025). Core thesis, threat model, closure framing.
2. `02-php-scrambler-lessons.md` — How the PHP scrambler at
   `/Users/archisgore/github/encrypted-execution/php-v2/` actually works,
   with lessons for C/GCC.
3. `03-randstruct-prior-art.md` — Linux randstruct GCC plugin; closest
   prior art. Explicit "why it doesn't randomize calling conventions"
   analysis.
4. `04-gcc-calling-convention-internals.md` — Where in GCC the SysV
   AMD64 psABI lives. Recommended attachment point:
   `ms_abi`/`sysv_abi` dual-ABI infrastructure.
5. `05-distro-bootstrap-options.md` — Recommendation: fork Buildroot,
   target musl + BusyBox + static-only.
6. `06-dynamic-linking-and-threat-model.md` — Honest threat model.
   Symbol-name mangling as the load-bearing piece.
7. `07-polyverse-polymorphic-linux.md` — Polyverse's prior commercial
   work. Key insight: Polymorphic Linux's seven transformations
   *preserved* the calling convention; encrypted-linux's novelty is
   exactly that boundary.

### Plan (all 5 documents in `plan/`)

- `00-design-principles.md` — 11 load-bearing decisions. Closure as
  primitive, determinism per seed (SOURCE_DATE_EPOCH model), symbol
  mangling as detection surface, fail-closed at load, reuse GCC dual-
  ABI infrastructure, single-distro pilot (Alpine), trust bootstrap
  acknowledged not solved.
- `01-phase1-userland-scrambling.md` — 7 milestones, 3–6 weeks.
  Scrambling GCC + scrambled musl + scrambled BusyBox + stock kernel
  in QEMU. Static-only with one dynamic library to demo the load-time
  failure.
- `02-phase2-kernel-scrambling.md` — 7 milestones, 4–8 weeks beyond
  Phase 1. Syscall renumbering + kernel-internal ABI scrambling +
  modversions-CRC seed folding + vDSO + eBPF.
- `03-risks-and-honest-limitations.md` — What encrypted-linux is and
  is NOT. Comparison against Polyverse's record. The Thompson "trusting
  trust" gap acknowledged.
- `04-smallest-proof-of-concept.md` — 4-week single-engineer path from
  zero to demo asciicast. Stock kernel, userland only, arg-register
  permutation + symbol mangling only. One scrambled `hello` + one
  stock-built `hello`; the demo is the load-time `undefined symbol`
  failure side-by-side with the working scrambled binary.

### Build-up artifacts

- GitHub repo: `github.com/encrypted-execution/encrypted-linux` (public).
- README.md, STATE.md (this file).
- Two commits: initial 6 dossiers + dossier 07.
- This update will be the third commit.

## What's queued next

### Pre-implementation user decisions (the open questions from the
previous STATE.md, now refined)

The plan documents bake in strong recommendations. If you want to
deviate from any of these, push back BEFORE the patch series starts;
deviation costs less now than at week 3.

1. **Confirm Buildroot.** Plan/04 assumes it. Alternatives: LFS (too
   many packages), Yocto (slow iteration), custom Makefile (extra
   work for no benefit).
2. **Confirm musl.** Plan/01 M4 assumes it. Glibc is ~20× the asm
   audit effort (`research/05` §4).
3. **Confirm dynamic library in the PoC demo.** Plan/04 has the
   dual-hello demo using *one* dynamic library (libc) to show the
   load-time failure mode. Alternative: pure static demo with kernel
   ENOSYS (requires pulling Phase 2 forward). The dual-hello approach
   is simpler and demos faster.
4. **Confirm `--disable-bootstrap` for PoC.** Plan/00 §10 documents
   the gap; Mes/TinyCC self-host is a v2 milestone.
5. **License: Apache-2.0.** Plan/00 §11 documents the patent posture.
6. **Single-distro pilot (Alpine).** Plan/00 §9 — explicit reversal of
   Polyverse's seven-distro mistake.
7. **Phase split: userland → kernel.** Plan/01 vs plan/02 as separate
   milestones. Alternative: parallel tracks. Series-first is safer.

### Once decisions are confirmed: implementation kickoff

The smallest single deliverable that starts the engineering work is:

`patches/scramble-gcc-v0.patch` — the 200–400 LOC GCC backend patch
that adds the `ENCRYPTED_LINUX_ABI` variant with arg-register
permutation + symbol mangling.

Plan/04 step 1 lists the five touchpoints inside i386.cc. A
single-engineer week of focused work; demo-able with a
hand-written test case before any musl/Buildroot infrastructure
exists.

After that:
- Week 2 of plan/04: integrate into Buildroot.
- Weeks 3–4 of plan/04: musl rebuild, busybox, dual-hello demo,
  asciicast, README update.

Then plan/01 M3 onward (callee-saved permutation, CFI tests, libgcc
soundness, ELF-note seed tag) — the path to a real Phase 1, not just
a PoC.

## Reproducing the research (agent IDs may be stale by resume time)

- `a4e3c9e89771c4596` — Encrypted Execution paper
- `ae59942b4d6ed20cf` — PHP scrambler codebase
- `ac7775d1cfc1cb697` — randstruct prior art
- `aa05eb3d7a245f4a4` — GCC calling convention internals
- `a3639813e3e0a1c3a` — distro bootstrap options
- `a7748a7cc227b94e2` — dynamic linking / threat model
- `a5cc2245a90312e3c` — Polyverse / Polymorphic Linux / Polyscripting
