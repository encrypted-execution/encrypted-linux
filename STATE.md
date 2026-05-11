# encrypted-linux — Current State

**Last updated:** 2026-05-11
**Phase:** First working code merged to `main`. Joint demo
end-to-end PASS (19/19 checks). Next: real GCC patch v0 to replace
the post-compile mangler; Buildroot integration; QEMU boot.

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

### Track A — symbol mangling (shipped)

Symbol mangling is the load-bearing piece of Phase 1 (plan/00 §3).
PoC scope deliberately scoped down from "real GCC backend patch" to
"post-compile pass using `objcopy --redefine-syms`" — same observable
property (load-time `undefined symbol` failure), 1000× less GCC work.

Shipped artifacts:
- `scripts/seed-lib.sh` — bash HMAC-SHA256 sub-seed derivation
- `scripts/scramble-mangle.sh` — main mangler
- `scripts/scramble-mangle-test/` — hello/libthing/main triple, test.sh
- `docker/Dockerfile.test` — Ubuntu 24.04 image, ~150 MB
- `docker/Dockerfile.gcc-build` — staged GCC 14 source for the future
  real patch, ~1.2 GB (image not yet built)

Joint demo: `make test` → 5/5 Track A checks PASS. The cross-link case
fails with `main.c:(.text+0xc): undefined reference to
\`compute__abi_15e2ce22'\`` — proof of the fail-closed property
plan/00 §5 requires.

### Track B — seed-lib + syscall renumbering (shipped)

Phase 2 M1 prerequisite (Track B in plan/05). Independent of any GCC
work; can already produce demo-able artifacts.

Shipped artifacts:
- `scripts/seed_lib.py` — pure-stdlib Python 3 HMAC-SHA256 module
- `scripts/seed-lib.py` — CLI shim
- `scripts/gen-unistd-seeded.py` — reads vendored `syscall_64.tbl` +
  seed, emits bijective renumbering (HMAC-mod-1024 with linear-probe
  collision resolution)
- `scripts/test/test-seed-lib.sh` — 14 checks: known-vector, bijection,
  determinism (byte-identical reruns)
- `scripts/upstream/syscall_64.tbl` — vendored from linux v6.6

Joint demo: `make test` → 14/14 Track B checks PASS. PoC-seed renumbering
on stable headline calls: `read 0→853`, `write 1→639`, `openat 257→555`,
`execve 59→448`, `exit_group 231→983`.

### What unblocks now

With Tracks A and B both green:
- The dual-hello + load-time-failure asciicast (plan/04) is reachable
  with another ~2 days of work (just wire the existing test into a
  scripted recording).
- Phase 2 M2 (consume the renumbered header in musl) is now unblocked
  (just needs musl source + the existing `unistd_seeded.h` artifact).
- Phase 2 M4 (modversions CRC seed-fold) is independent and shippable
  next.

The full GCC backend patch (real arg-register permutation, callee-saved
permutation, ELF-note seed tag) remains the critical-path long-pole —
plan/01 M1+M3, plan/05 §"What's on the critical path." Now that the
mangling-only PoC ships, the GCC patch is no longer blocking the
asciicast; it becomes the gateway to plan/01 M4+ (rebuild musl with
real ABI scrambling, not just mangling).

## Reproducing the research (agent IDs may be stale by resume time)

- `a4e3c9e89771c4596` — Encrypted Execution paper
- `ae59942b4d6ed20cf` — PHP scrambler codebase
- `ac7775d1cfc1cb697` — randstruct prior art
- `aa05eb3d7a245f4a4` — GCC calling convention internals
- `a3639813e3e0a1c3a` — distro bootstrap options
- `a7748a7cc227b94e2` — dynamic linking / threat model
- `a5cc2245a90312e3c` — Polyverse / Polymorphic Linux / Polyscripting
