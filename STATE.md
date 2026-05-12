# encrypted-linux — Current State

**Last updated:** 2026-05-12
**Phase:** **Full stack operational.** All original-spec features
working end-to-end. CI configured to validate the build.

## Defenses currently in the kernel + libc + toolchain

| Defense | Where | Verified |
|---|---|---|
| 64-bit syscall numbers (HMAC-derived) | kernel `arch/x86/entry/common.c` + `el_syscall_lookup.h` | `make demo-unistd`, boot tests |
| Sorted-binary-search syscall dispatch | kernel `do_syscall_x64` | boot tests pass |
| `CONFIG_RANDSTRUCT_FULL` struct-layout randomization | upstream GCC plugin | `bash scripts/verify-randstruct.sh` |
| musl using overkill syscall numbers (C macros + hand-patched asm) | `musl/arch/x86_64/bits/syscall.h.in` + 7 .s files | `make demo-unistd` cross-checks |
| musl as system dynamic loader (`/lib/ld-musl-x86_64.so.1`) | bundled in initramfs | in-VM hello + gcc work |
| GCC arg-register permutation (Phase 1) | `patches/scramble-gcc-v0.patch` | `make demo-gcc` 9/9 |
| Symbol mangling — bash post-pass | `scripts/scramble-mangle.sh` | `make demo-mangle` 5/5 |
| Symbol mangling — GCC plugin | `patches/gcc-plugin-scramble-mangle/` | `make demo-plugin` 12/12 |
| ELF entry bridge (`mov %rsp,%r<X>`) | `scripts/patch-musl-crt-arch.py` | boot succeeds with Phase-1 musl |
| In-VM compile (Alpine gcc + overkill musl loader) | `scripts/assemble-overkill-gcc-initramfs.sh` | boot test compiles hello.c |

## Verified cross-host failure matrix

| Binary | Native overkill VM | Stock ubuntu:24.04 | Different-seed VM | Old 10-bit-slot VM |
|---|---|---|---|---|
| Overkill hello (64-bit syscalls) | works | segfaults exit 139 | #GP fault, panic 0x0b | #GP fault |
| In-VM-compiled myhello | works | (not re-tested; same musl) | (not re-tested) | (not re-tested) |
| 10-bit slot hello | #GP fault | segfaults exit 139 | (different seed) | works |
| Phase-1+2 hello | works | segfaults | #GP fault | #GP fault |

## CI

`.github/workflows/ci.yml` runs on every push to main:
- **unit-tests** (~5 min): build test image, run make demo-mangle, demo-plugin, demo-unistd, demo-gcc.
- **overkill-build** (~25 min): build the full overkill image (kernel + musl + busybox), QEMU smoke-boot, assert hello prints.
- **in-vm-gcc** (~30 min): full toolchain image with Alpine gcc bundled, QEMU smoke-boot with `el_demo=auto`, assert in-VM compile + run works.

`.github/workflows/overkill.yml` runs the heavy in-VM-gcc test on
manual trigger or weekly schedule.

## Repo layout (current)

- `plan/`, `research/`, `docs/` — design + threat model + evidence
- `patches/` — GCC plugin source + scramble-gcc-v0.patch
- `scripts/` — generators, patchers, builders, demos, verifications
- `docker/` — Dockerfile.test (~150 MB), Dockerfile.image-build (~400 MB), Dockerfile.gcc-build (~1.2 GB unbuilt), Dockerfile.gcc-amd64 (~500 MB), Dockerfile.gcc-static-musl (~270 MB)
- `.github/workflows/` — CI definitions
- `seed`, `SEED.md`, `LICENSE`, `Makefile`, `README.md`, `STATE.md`

## Backlog (deferred design work)

- **Seed hardening** (`plan/06-seed-hardening.md`) — make the seed
  cryptographically undiscoverable rather than recoverable-but-unique.
  Five options ranked by cost; per-binary diversification (Option 1)
  is the suggested first step. The PoC deliberately ships with a
  plaintext seed; this plan opens the door to layering on
  cryptographic concealment.

## What's NOT here (deferred)

- **Module ABI tied to seed via modversions CRC** (plan/02 M4) — a
  one-line `scripts/genksyms` patch. The current overkill kernel
  doesn't build any modules (initramfs-only), so this would be a
  ~no-op for the demo but valuable for production.
- **Phase 1 register permutation IN the rootfs** — only used for
  `hello-phase1plus2`, not for the default `hello` shipped in
  `build/overkill/`. The two are equivalent for cross-host failure
  purposes (both fail), so we ship the simpler one.
- **In-tree static-against-musl GCC build** (the original
  `docs/IN-VM-GCC-PATH.md` path) — replaced by the much simpler
  "bundle Alpine's gcc + substitute the dynamic loader" approach.
  IN-VM-GCC-PATH.md retained for reference but no longer the
  recommended path.

## Reproducing from scratch

```
# On a clean amd64 Linux host with Docker + qemu-system-x86_64:
git clone https://github.com/encrypted-execution/encrypted-linux
cd encrypted-linux

# Pre-built tests: ~5 min
make test

# Full overkill kernel + musl + hello: ~15 min
docker build -t encrypted-linux-image-build -f docker/Dockerfile.image-build .
bash scripts/build-overkill-image.sh

# Add shared musl + bundled Alpine toolchain: ~10 min
bash scripts/build-overkill-musl-shared.sh
bash scripts/extract-alpine-toolchain.sh
bash scripts/assemble-overkill-gcc-initramfs.sh

# Boot with auto-demo (compiles + runs inside)
gtimeout 120 qemu-system-x86_64 -m 4G \
    -kernel build/overkill/bzImage \
    -initrd build/overkill/rootfs-gcc.cpio.gz \
    -append "console=ttyS0 panic=5 loglevel=3 el_demo=auto" \
    -nographic -no-reboot -accel tcg
```

On arm64 (Apple Silicon Macs): same commands work, but docker uses
QEMU emulation for the amd64 builds → ~2x slower. Total wall-time
under emulation: 1–2 hours.

## Memory / size

| Artifact | Size |
|---|---|
| `build/overkill/bzImage` | 898 KB |
| `build/overkill/hello` (static, overkill syscalls) | 17 KB |
| `build/overkill/busybox` (static) | 1.2 MB |
| `build/overkill/sysroot/usr/lib/libc.a` (overkill musl) | 2.7 MB |
| `build/overkill/sysroot/usr/lib/libc.so` (overkill musl) | 786 KB |
| `build/overkill/rootfs.cpio.gz` (no toolchain) | 730 KB |
| `build/overkill/rootfs-gcc.cpio.gz` (with bundled gcc + binutils) | 70 MB |
| `build/alpine-toolchain/` | 189 MB |
