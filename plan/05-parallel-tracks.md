# Plan 05 — Parallel Tracks

Phase 1 (userland scrambling) and Phase 2 (kernel scrambling) run as
**parallel tracks**, not series. This document is the dependency graph
and schedule.

## Why parallel works

The hardest single artifact in the project — the scrambling GCC patch
— is shared by both phases. Phase 1 needs it to compile userspace;
Phase 2 needs it (with a different sub-seed) to compile the kernel.
Several Phase 2 milestones have **zero dependency** on the GCC patch
and can begin day 1:

- **Phase 2 M1** (`unistd_seeded.h` generator) reads `syscall_64.tbl`
  + the seed and emits two text files. No GCC involvement.
- **Phase 2 M4** (modversions CRC seed-fold) is a one-line change to
  `scripts/genksyms` / `gendwarfksyms`. No GCC involvement.

Conversely, Phase 1's later milestones (rebuild musl, BusyBox,
Buildroot integration, demo) have a hard dependency on the GCC patch
landing and don't begin until then.

## Dependency graph

```
                         ┌────────────────────────────┐
                         │ scripts/seed-lib (shared)  │  ← starts day 1
                         │  HMAC-derived sub-seeds:   │
                         │  user, kernel, syscalls    │
                         └─────┬───────────────┬──────┘
                               │               │
              ┌────────────────┘               └─────────────────┐
              ▼                                                  ▼
   ╔═══════════════════════════╗                  ╔═══════════════════════════╗
   ║  TRACK A — Userland       ║                  ║  TRACK B — Kernel         ║
   ║  (plan/01)                ║                  ║  (plan/02)                ║
   ╠═══════════════════════════╣                  ╠═══════════════════════════╣
   ║                           ║                  ║                           ║
   ║  A1  GCC: arg-reg perm   ─╬──── shared GCC ──╬─►  B3  Kernel-internal ABI║
   ║      + symbol mangling    ║      patch       ║      scramble (needs A1+  ║
   ║      (= patch v0)         ║                  ║      A3 to land)          ║
   ║              │            ║                  ║                           ║
   ║              ▼            ║                  ║  B1  unistd_seeded.h ◄────╬── INDEPENDENT
   ║  A3  GCC: callee-saved   ─╬──── shared GCC ──╬─►                         ║   (starts day 1)
   ║      permutation + CFI    ║                  ║  B2  musl syscall stubs   ║
   ║              │            ║                  ║      consume B1 ─────────┐║
   ║              ▼            ║                  ║                          ║║
   ║  A4  Rebuild libgcc + musl║                  ║  B4  modversions CRC ◄───╬╬── INDEPENDENT
   ║              │            ║                  ║      seed-fold            ║   (starts day 1)
   ║              ▼            ║                  ║              │            ║
   ║  A5  BusyBox + Buildroot  ║                  ║              ▼            ║
   ║              │            ║                  ║  B5  vDSO thunk in libc   ║
   ║              ▼            ║                  ║              │            ║
   ║  A6  ELF-note seed tag    ║                  ║              ▼            ║
   ║      + loader check       ║                  ║  B6  eBPF JIT (defer OK)  ║
   ║              │            ║                  ║              │            ║
   ║              ▼            ║                  ║              ▼            ║
   ║  A7  Dual-hello demo      ║                  ║  B7  Static-stock-fails   ║
   ║      (= PoC, plan/04)     ║                  ║      demo + insmod-fails  ║
   ║                           ║                  ║      demo                 ║
   ╚════════════╤══════════════╝                  ╚═════════════╤═════════════╝
                │                                                │
                └────────────────────┬───────────────────────────┘
                                     ▼
                         ╔═══════════════════════════╗
                         ║  M8 — Joint demo          ║
                         ║  scrambled userland       ║
                         ║  + scrambled kernel       ║
                         ║  + dual-stock-fail asciicast║
                         ╚═══════════════════════════╝
```

Renaming for clarity: Phase 1 milestones M1–M7 → A1–A7. Phase 2
milestones M1–M7 → B1–B7. (The plan/01 and plan/02 documents keep
their original M-numbering; this doc maps them.)

## What's on the critical path

**The GCC patch (A1).** It gates:

- A4 (rebuild musl) → A5 (Buildroot) → A6 (loader check) → A7 (demo)
- B3 (kernel-internal ABI) → B5 (vDSO) → B6 (eBPF) → B7 (demo)

Total downstream-blocked milestones: 8 of the 14. So engineer
priority is: ship the smallest A1 patch fast (PoC scope, plan/04
step 1), even if it lacks A3 (callee-saved permutation).

## What's off the critical path (start immediately, in parallel)

**B1, B4, and the shared `scripts/seed-lib` helper.**

| Milestone | Effort | Dependencies | Output |
|---|---|---|---|
| `seed-lib` | 1 day | seed file format spec | shared Python/Go module deriving sub-seeds via HMAC-SHA256 |
| B1 (`unistd_seeded.h` generator) | 2 days | seed-lib, `syscall_64.tbl` | renumbered header + kernel dispatch table |
| B4 (modversions CRC seed-fold) | 1 day | seed-lib | one-line patch to `scripts/genksyms/checksum.c` |

These three can ship before A1 lands. They produce demo-able artifacts
(the renumbered header is human-readable; the CRC fold can be tested
against a stock kernel without scrambling anywhere else).

## Suggested allocation

### Solo engineer

Sequential with overlap:

```
Week 1:  A1 (GCC patch v0)                  [primary]
         seed-lib + B1 generator            [end of week, when blocked on A1 testing]
Week 2:  A1 polish + A2 (symbol mangling)   [primary]
         B4 modversions CRC seed-fold       [parallel]
Week 3:  A3 callee-saved + CFI test
         A4 rebuild musl                    [end of week]
Week 4:  A4 + A5 Buildroot                  [primary]
         B2 musl consumes B1                [parallel — both touch musl, sequence in same engineer-day]
Week 5:  A6 ELF-note loader check
         A7 dual-hello demo + asciicast     [Track A done — PoC ships]
Week 6+: B3 kernel-internal ABI scramble    [now A1+A3 have landed]
         B5 vDSO thunk
         B6 eBPF (or defer)
         B7 + M8 joint demo
```

PoC ships end of week 5. Phase 2 in flight by week 6. Joint demo
around week 9–10.

### Two engineers

Engineer 1 (compiler): A1, A2, A3, A4, A5, A6, A7. Owns Track A end-
to-end. ~4–5 weeks to A7.

Engineer 2 (kernel + tooling): seed-lib, B1, B2, B4, B3 (waits on
A1+A3 from Eng 1), B5, B6, B7. ~6–7 weeks total since B3 waits.

Joint demo M8: week 7.

### Three engineers (compiler / kernel / userland-integration)

Engineer 3 takes A4, A5, A6, A7 (rebuilds + Buildroot + demo). Frees
Eng 1 to start B3 sooner. PoC asciicast end of week 3. Joint demo
end of week 5.

## Sync points

| Sync | Topic | Frequency |
|---|---|---|
| seed-lib API freeze | Both tracks share this; lock the HMAC tags and salt strings on day 2 | once |
| GCC patch interface stable | What `__attribute__((target("abi=encrypted_linux")))` looks like, what `TARGET_MANGLE_DECL_ASSEMBLER_NAME` emits | once, end of week 1 |
| Buildroot defconfig | Tracks A and B both consume the harness | weekly |
| Test harness | `qemu.sh` runs the smoke tests; both tracks contribute | weekly |

## What if A1 slips

If the GCC patch takes 2 weeks instead of 1 (CFI complications, GCC
backend surprises), the parallel tracks de-risk the slip:

- B1/B2/B4 still ship; the renumbered-syscall artifact is independently
  demo-able. (`./gen-unistd-seeded | head` is a real artifact.)
- A7 PoC asciicast slips a week, but A7 isn't blocking Phase 2.
- Joint demo M8 slips proportionally; not catastrophic.

If the GCC patch takes 4 weeks (a real possibility — backend work is
unforgiving), revisit Polyverse's choice to skip the calling convention
in plan/00 §9. We may need to scope down A1 to *just* symbol mangling
(no register permutation) for the PoC asciicast, and treat full ABI
scrambling as a v2 deliverable. The mangling alone is enough to
demonstrate the load-time-failure property.

## Notes on shared seed material

A single `seed` file in the repo root drives everything. The seed-lib
derives three sub-seeds:

```
USER_ABI_SEED   = HMAC-SHA256(seed, "user.abi")
KERNEL_ABI_SEED = HMAC-SHA256(seed, "kernel.abi")
SYSCALL_SEED    = HMAC-SHA256(seed, "syscall.numbers")
```

This isolates failure domains. An attacker who recovers the user-ABI
permutation from a userspace binary learns nothing about the kernel
internal ABI. (They can recover the kernel sub-seed from
vmlinux+debuginfo separately — see plan/03 §3.8 — but the seeds
remain independent.)

Possible v2 extensions:
```
VDSO_SEED       = HMAC-SHA256(seed, "vdso.abi")   # if B5 path 2 is taken
EBPF_SEED       = HMAC-SHA256(seed, "ebpf.abi")
IOCTL_SEED      = HMAC-SHA256(seed, "ioctl.numbers")
```
