# encrypted-linux — Current State

**Last updated:** 2026-05-11 (afternoon — saved mid-build)
**Phase:** Phase-2 QEMU image **partially built**. bzImage and a
471-MB initramfs (with bundled scrambling GCC + glibc libs) exist in
`build/image/`. **Not yet booted/verified.** Next session: boot it
in QEMU and run the cross-host failure verification.

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

### Track A — symbol mangling (shipped, two paths)

Symbol mangling is the load-bearing piece of Phase 1 (plan/00 §3).
Now ships in TWO interchangeable forms:

1. **Post-compile pass** (`scripts/scramble-mangle.sh`) — bash + `nm`
   + `objcopy --redefine-syms`. Operates on any ELF object regardless
   of how it was compiled. Useful for third-party prebuilt objects
   and as the reference oracle.
2. **GCC plugin** (`patches/gcc-plugin-scramble-mangle/`) — ~150 LOC
   C++. Loaded via `gcc -fplugin=./scramble-mangle.so`. Hooks
   `PLUGIN_FINISH_DECL` (extern decls, caller side) and
   `PLUGIN_PRE_GENERICIZE` (function bodies, callee side). Mangles
   at compile time, before the symbol enters the symbol table.

**Parity verified**: both paths produce byte-identical output. A
test that mixes plugin-built objects with post-pass-built objects
links and runs correctly (test-plugin.sh Test 3).

Shipped artifacts:
- `scripts/seed-lib.sh` — bash HMAC-SHA256 sub-seed derivation
- `scripts/scramble-mangle.sh` — post-compile mangler
- `patches/gcc-plugin-scramble-mangle/{scramble-mangle.cc,Makefile,README.md}`
  — compile-time mangler
- `scripts/scramble-mangle-test/test.sh` — three link cases via post-pass
- `scripts/scramble-mangle-test/test-plugin.sh` — three link cases via plugin + parity
- `docker/Dockerfile.test` — Ubuntu 24.04 + `gcc-13-plugin-dev` + `libssl-dev`
- `docker/Dockerfile.gcc-build` — staged GCC 14 source for the future
  real backend patch (~1.2 GB image, not yet built)

Joint demo: `make test` → 5/5 (post-pass) + 12/12 (plugin) = 17/17
Track A checks PASS. Both cross-link cases fail with
`undefined reference to compute__abi_15e2ce22` — proof of the
fail-closed property plan/00 §5 requires.

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

### Track A — GCC backend patch (shipped)

Phase 1 M1 (argument-register permutation) — the actual GCC backend
patch, no longer a plugin or post-pass.

Shipped artifacts:
- `patches/scramble-gcc-v0.patch` (84 lines) — externalizes
  `x86_64_int_parameter_registers[6]` in i386.cc to a generated
  header. Default header is identity (byte-identical to upstream).
- `scripts/gen-gcc-arg-perm.py` — header generator. Reads master
  seed, derives `USER_ABI_SEED = HMAC(master, "user.abi")` then
  `ARG_REG_SEED = HMAC(USER_ABI_SEED, "x86_64.arg_regs")`, applies
  Fisher-Yates to [0..5].
- `scripts/build-scramble-gcc.sh` — builds the patched
  cross-targeting GCC inside `encrypted-linux-gcc` Docker image.
  Configure: `--target=x86_64-linux-gnu --disable-bootstrap
  --enable-languages=c --without-headers`. ~15-30 min wall-time.
- `scripts/scramble-gcc-test/{test.sh,README.md}` — compiles six
  identity functions, disassembles, verifies each reads its
  argument from the expected permuted register.
- `scripts/gen-gcc-patch.sh` + `_apply-gcc-patch.py` +
  `_gcc-patch-msg.txt` — regenerate the .patch file from inside the
  staged GCC source (proper context, real line numbers).

PoC-seed permutation:
```
arg0 RDI -> RDX    (3-cycle)
arg1 RSI -> RSI
arg2 RDX -> RCX    (3-cycle)
arg3 RCX -> RDI    (3-cycle)
arg4 R8  -> R8
arg5 R9  -> R9
```

Verified: `id0(int a) { return a; }` compiles to `movl %edx, %eax;
ret` instead of `movl %edi, %eax; ret`. All six identity functions
read from the seed-derived permuted register. `make demo-gcc` →
9/9 PASS.

### QEMU image build pipeline (committed, partially executed)

Target: `bash scripts/run-qemu.sh` boots a Linux image with permuted
syscall numbers. Inside the VM, `hello` works; copied to a stock host
it fails (-ENOSYS / segfault) because the stock kernel doesn't know
the renumbered syscalls.

Shipped artifacts (this session):
- `docker/Dockerfile.gcc-amd64` — stages GCC 14 source under
  `--platform linux/amd64` for building a NATIVE x86_64 patched GCC.
- `docker/Dockerfile.image-build` — stages Linux kernel 6.6.30 +
  musl 1.2.5 + BusyBox 1.36.1 source for the rootfs build.
- `scripts/build-native-gcc.sh` — builds patched GCC as a native
  x86_64 binary deployable to the VM. **COMPLETED**: artifact at
  `build/native-gcc/install/bin/x86_64-linux-gnu-gcc` (dynamically
  linked against glibc; needs its libs bundled into the rootfs).
- `scripts/gen-kernel-syscall-tbl.py` — writes a permuted
  `syscall_64.tbl` sorted by new number (required by the kernel
  build). Uses the same HMAC convention as gen-unistd-seeded.py, so
  kernel and userspace numbers always agree. **WORKS** (write 1→639,
  read 0→853, execve 59→448, etc.).
- `scripts/build-image.sh` — top-level image builder. Builds kernel
  with permuted `syscall_64.tbl`, builds musl with stock x86_64 GCC
  using permuted kernel headers, then static busybox + static
  `hello` against that musl. **COMPLETED** through busybox + hello
  build; the chrooted `busybox --install` step hung under QEMU TCG
  emulation. Separated into:
- `scripts/assemble-initramfs.sh` — host-side assembly using
  `ln -sf` instead of `busybox --install`. **COMPLETED**: produces
  `build/image/rootfs.cpio.gz` (471 MB, bundles the native
  scrambling GCC + glibc loader/libs).
- `scripts/run-qemu.sh` — `qemu-system-x86_64` runner. **NOT YET
  EXECUTED** (this session ended mid-boot).
- `scripts/test-cross-host-failure.sh` — runs `hello` inside a
  stock ubuntu:24.04 amd64 container; expects ENOSYS / segfault /
  exec-format-error. **NOT YET EXECUTED.**

Built artifacts in `build/image/` (gitignored):
- `bzImage` (1.5 MB) — Linux 6.6.30 with permuted syscall_64.tbl
- `rootfs.cpio.gz` (471 MB) — initramfs with busybox, hello, native
  scrambling GCC + glibc libs, hello.c source, init script
- `hello` (16 KB) — static, x86-64, links against scrambled musl
  with permuted syscall numbers
- `busybox` (1 MB) — static, linked against scrambled musl
- `sysroot/usr/lib/libc.a` — scrambled musl (permuted syscall #s)
- `sysroot/usr/include/asm/unistd_64.h` — permuted kernel headers

Built artifacts in `build/native-gcc/` (gitignored):
- `install/bin/x86_64-linux-gnu-gcc` — native x86_64 scrambling
  GCC binary. Dynamically linked. Suitable for use inside the QEMU
  guest (glibc libs are bundled into the initramfs).

### Known gaps before the QEMU boot demo passes

1. **Image not yet booted.** First time the user runs
   `bash scripts/run-qemu.sh` will be the smoke test. The kernel
   was built with `tinyconfig` + minimum adds; if it can't even
   reach userspace, switch to `defconfig` in `build/build-image.sh`.
2. **GCC inside VM** — bundled but not yet tested. The patched
   x86_64 GCC needs glibc to run (the bundled libs in
   `/lib/x86_64-linux-gnu/` should make this work). To validate:
   inside the VM, `gcc /src/hello.c -o /tmp/hello && /tmp/hello`.
3. **Phase 1 ABI scrambling NOT in the rootfs binaries.** musl in
   the image was built with **stock** x86_64 GCC + the
   syscall-renumbered kernel headers (Phase 2 only). The bundled
   native scrambling GCC would add Phase 1 to programs compiled
   inside the VM, but the busybox / hello already in the image
   use canonical SysV ABI. So:
     - hello copied out → fails on stock kernel (-ENOSYS) ✓ Phase 2
     - hello inspected with `nm` → no `__abi_*` symbols (Phase 1
       integration with musl deferred — see plan/01 M3+M4).
4. **Cross-host failure verification** needs both the boot and a
   stock ubuntu:24.04 container test. `scripts/test-cross-host-
   failure.sh` is staged.

### What unblocks now

With both Track A paths (post-pass + plugin + backend patch) and Track B all green:
- The dual-hello + load-time-failure asciicast (plan/04) is reachable
  with another ~2 days of work — the demo binaries are already
  produced by `make demo-plugin`; just need to record + caption.
- The plugin is suitable for any C source we control. Building
  scrambled musl (plan/01 M4) is now mechanical: drop the plugin
  into musl's CFLAGS via Buildroot's `BR2_TARGET_OPTIMIZATION` knob.
- Phase 2 M2 (consume the renumbered header in musl) is unblocked
  (just needs musl source + the existing `unistd_seeded.h`).
- Phase 2 M4 (modversions CRC seed-fold) is independent and shippable
  next.

The real GCC **backend** patch — argument-register permutation,
callee-saved permutation, ELF-note seed tag — remains the
critical-path long-pole (plan/01 M1+M3). It is what gives us the
full ABI scrambling that the plugin alone cannot provide. Estimated
2–4 weeks of dedicated GCC backend work; needs a checkout of GCC 14
source inside the `encrypted-linux-gcc` Docker image. The plugin
makes this no longer blocking for the PoC asciicast.

## Reproducing the research (agent IDs may be stale by resume time)

- `a4e3c9e89771c4596` — Encrypted Execution paper
- `ae59942b4d6ed20cf` — PHP scrambler codebase
- `ac7775d1cfc1cb697` — randstruct prior art
- `aa05eb3d7a245f4a4` — GCC calling convention internals
- `a3639813e3e0a1c3a` — distro bootstrap options
- `a7748a7cc227b94e2` — dynamic linking / threat model
- `a5cc2245a90312e3c` — Polyverse / Polymorphic Linux / Polyscripting
