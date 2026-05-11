# encrypted-linux — Current State

**Last updated:** 2026-05-11
**Phase:** Plan locked. Pre-implementation decisions confirmed. Repo
scaffolding in progress. Next: GCC patch v0 + Phase 2 M1 generator
(parallel tracks).

## Decisions (confirmed by user 2026-05-11)

| # | Decision | Choice |
|---|---|---|
| 1 | Build harness | **Buildroot** |
| 2 | Libc | **musl** |
| 3 | Demo includes one dynamic library (libc.so) for load-time-failure asciicast | **Yes** |
| 4 | GCC bootstrap discipline for PoC | **`--disable-bootstrap`** (self-host deferred to v2) |
| 5 | License | **Apache-2.0** |
| 6 | Single-distro pilot | **Alpine** (Polyverse already aports-forked it) |
| 7 | Phase 1 / Phase 2 scheduling | **Parallel** (not series — see plan/05) |

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

### Implementation kickoff — parallel tracks

See `plan/05-parallel-tracks.md` for the dependency graph and schedule.

The two starting items that can begin immediately, **simultaneously**:

1. **Track A — GCC patch v0** (`patches/scramble-gcc-v0.patch`).
   200–400 LOC GCC backend patch adding the `ENCRYPTED_LINUX_ABI`
   variant: arg-register permutation + symbol mangling. Plan/04 step 1
   lists the five touchpoints in `gcc/config/i386/i386.cc`. ~1 engineer-
   week. Demo-able with a hand-written test case before any musl /
   Buildroot infrastructure exists. Gates Track A milestones M4 onward
   AND Track B kernel-internal ABI scrambling.

2. **Track B — `unistd_seeded.h` generator** (`scripts/gen-unistd-seeded`).
   Independent of the GCC patch entirely; needs only the seed file and
   the canonical `syscall_64.tbl`. Outputs the renumbered kernel
   header and the kernel-side dispatch table. ~2 engineer-days.

Suggested starting allocation:
- If one engineer: Track A first (it unblocks more), Track B in the
  background.
- If two engineers: split, sync weekly on the seed-derivation library
  (shared between both).

## Reproducing the research (agent IDs may be stale by resume time)

- `a4e3c9e89771c4596` — Encrypted Execution paper
- `ae59942b4d6ed20cf` — PHP scrambler codebase
- `ac7775d1cfc1cb697` — randstruct prior art
- `aa05eb3d7a245f4a4` — GCC calling convention internals
- `a3639813e3e0a1c3a` — distro bootstrap options
- `a7748a7cc227b94e2` — dynamic linking / threat model
- `a5cc2245a90312e3c` — Polyverse / Polymorphic Linux / Polyscripting
