# encrypted-linux

[![CI](https://github.com/encrypted-execution/encrypted-linux/actions/workflows/ci.yml/badge.svg)](https://github.com/encrypted-execution/encrypted-linux/actions/workflows/ci.yml)
[![Overkill build](https://github.com/encrypted-execution/encrypted-linux/actions/workflows/overkill.yml/badge.svg)](https://github.com/encrypted-execution/encrypted-linux/actions/workflows/overkill.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A bootable Linux distribution where the kernel, libc, and compiler
toolchain are all scrambled per-build by a single master seed. Programs
built outside the closure cannot execute on the target.

Instantiation of the [Encrypted Execution](https://www.encrypted-execution.com)
thesis (Gore 2025) at the `<compiler-codegen-backend, ISA>` layer — the
extreme case the paper itself names (whitepaper p. 10, item 4).

## Status: shipping

**All defenses in the original spec are operational** and verified
end-to-end inside a QEMU VM:

```
$ make demo                                  # 19 unit checks, ~30 sec
$ bash scripts/run-overkill-demo.sh          # full QEMU boot + cross-host failure
$ bash scripts/verify-randstruct.sh          # confirm struct-layout randomization
```

Or boot the full image with a bundled toolchain and try it interactively:

```
gtimeout 120 qemu-system-x86_64 -m 4G \
    -kernel build/overkill/bzImage \
    -initrd build/overkill/rootfs-gcc.cpio.gz \
    -append "console=ttyS0 panic=5 loglevel=3 el_demo=auto" \
    -nographic -no-reboot -accel tcg
```

Expected output:

```
hello from encrypted-linux OVERKILL (64-bit syscalls)!
  -> exit 0
compile /src/hello.c inside VM:
  $ gcc /src/hello.c -o /tmp/myhello
  compile OK
compiled INSIDE the encrypted-linux VM!
  -> exit 0
```

### v3 additions (research/08 ideas 1, 4, 6)

Three additional MTD defenses are layered on top of the v2 stack and
verified booting in QEMU:

```
$ bash scripts/build-v3-image.sh             # ~15 min
$ gtimeout 90 qemu-system-x86_64 -m 4G \
      -kernel build/v3/bzImage \
      -initrd build/v3/rootfs.cpio.gz \
      -append "console=ttyS0 panic=5 loglevel=3 el_demo=auto" \
      -nographic -no-reboot -accel tcg
```

Sample boot output:

```
[v3] /bin/hello (stamped OSABI):
hello from encrypted-linux V3 (overkill + errno + OSABI + /proc)!
errno after open(/nonexistent): 88
  (canonical ENOENT=2; if you see something else, errno is permuted)
  -> exit 0

[v3] /bin/hello-stock-osabi (canonical OSABI=0):
/bin/hello-stock-osabi: line 1: ELF: not found            # kernel ENOEXEC
  -> exit 2

[v3] /proc/self/status (renamed fields):
Raths246:    1312 kB                                       # was VmPeak
Jubjub098:   1312 kB                                       # was VmSize
Galumph168:   516 kB                                       # was VmHWM
Zibble023:    516 kB                                       # was VmRSS
Fnord178:      24 kB                                       # was VmData
Chortled161:  132 kB                                       # was VmStk
Frob213:      932 kB                                       # was VmExe
```

## The full scrambling stack

Every defense layer is seed-derived from a single `./seed` file via
distinct HMAC-SHA256 labels. The stack:

| Layer | What it does | Seed label | Cardinality / mechanism |
|---|---|---|---|
| **Kernel syscall dispatch** | Every syscall number is a 64-bit HMAC-derived value. Kernel binary-searches a sorted table to translate to canonical idx, then dispatches via `sys_call_table[]`. | `syscall.numbers` | **2⁶⁴** (1 in ~5×10¹⁶ chance per brute-force attempt) |
| **Kernel struct layouts** | `CONFIG_RANDSTRUCT_FULL` — Fisher-Yates per struct via the upstream GCC plugin. Different field offsets per build. | `kernel.randstruct` | 256-bit seed, per-struct shuffle |
| **musl libc syscall numbers** | `bits/syscall.h.in` rewritten with 64-bit `__NR_*ULL` values; 7 hand-patched x86_64 asm files use `movabsq` for 64-bit immediates. | (uses kernel `syscall.numbers`) | matches kernel |
| **GCC argument-register ABI** | `gcc/config/i386/i386.cc` patched to externalize `x86_64_int_parameter_registers[6]` to a seed-permuted header. First arg moves from `%rdi` to whatever the seed says. | `user.abi` + `x86_64.arg_regs` | 6! = 720 permutations |
| **Symbol mangling** | Every external C function gets `__abi_<8hex>` suffixed via GCC plugin OR objcopy post-pass. Stock binaries can't link against scrambled libs. | `user.abi` (per symbol) | per-symbol unique |
| **ELF entry bridge** | musl's `_start` patched: `mov %rsp, %r<X>` where X is the seed's arg0 register. Bridges kernel→userspace canonical handoff to the scrambling-GCC's permuted C ABI. | (uses `user.abi`) | matches GCC |
| **Errno permutation** (v3) | UAPI `asm-generic/errno{,-base}.h` and musl's `bits/errno.h` replaced with a Fisher-Yates permutation of POSIX errno values. POSIX guarantees names, not numbers. | `kernel.errno` | 133! permutations (`>10²²⁵`) |
| **ELF EI_OSABI gate** (v3) | Per-build byte (64-255) stamped into byte 7 of every shipping ELF. `binfmt_elf.c` patched to `return -ENOEXEC` if the byte doesn't match. | `elf.osabi` | 192 values |
| **/proc/[pid]/status field rename** (v3) | `fs/proc/task_mmu.c` literals rewritten: `VmPeak` → `Raths246`, `VmRSS` → `Zibble023`, etc. Fingerprinting/privesc tooling that scrapes `/proc` breaks. | `kernel.proc_schema` | per-field seed-derived |

### What each defends against

- **Overkill syscalls** — attacker can't issue meaningful syscalls without the seed-derived numbers. 2⁶⁴ search space is cryptographically infeasible.
- **Randstruct** — attacker with a kernel write-where can't set `cred->uid = 0` because they don't know `uid`'s offset inside `struct cred`.
- **Symbol mangling** — attacker can't `LD_PRELOAD` a malicious `libc.so` with a `printf` override; the host binary doesn't reference `printf`, it references `printf__abi_<hex>`.
- **Register-ABI permutation** — even if attacker constructs a ROP chain inside the scrambled libc, the gadgets' calling convention is wrong; `pop %rdi; ret` no longer loads arg0.
- **Errno permutation** (v3) — exploit payloads that branch on errno values (e.g., `if (errno == EACCES) try_other_path()`) take the wrong branch; libc error-string tables look like garbage; CVE PoC scripts that grep for `ENOSYS` or `EPERM` in dmesg miss everything.
- **ELF EI_OSABI gate** (v3) — any binary not stamped by this build's `scripts/stamp-elf-osabi.py` is rejected at exec time by the kernel. Stock-distro tools (`/bin/sh`, `python3`, attacker-uploaded ELFs) all fail before the loader runs.
- **/proc field rename** (v3) — process/memory-info-scraping tooling (privesc enumerators like `linpeas`, observability agents, fingerprinting scripts) sees an unknown schema and either errors out or reports zero/blank fields.

### What it doesn't defend against (honest framing)

- Not a confidentiality boundary. The seed is recoverable from any scrambled binary on disk by disassembling a few function prologues.
- Not a defense against logic bugs, data-only attacks, or compromise of the build farm.
- Not for cross-binary diversity — see [docs/IN-VM-GCC-PATH.md](docs/IN-VM-GCC-PATH.md) discussion of moving-target vs unique-target.

See [plan/03-risks-and-honest-limitations.md](plan/03-risks-and-honest-limitations.md) for the full threat model.

## Cross-host failure matrix

The same `hello` binary built inside the VM:

| Target | Result |
|---|---|
| **Native overkill VM** (same seed) | works — `hello from encrypted-linux ...` |
| **Stock ubuntu:24.04** | segfaults, exit 139 |
| **Different-seed overkill VM** | #GP fault, kernel panic exitcode 0x0b |
| **Old 10-bit-slot VM** | #GP fault — different scheme entirely |

Repository [`docs/DEMO-EVIDENCE.md`](docs/DEMO-EVIDENCE.md) has captured terminal output for each.

## Quick build (clean amd64 Linux host, ~30 min)

```bash
git clone https://github.com/encrypted-execution/encrypted-linux
cd encrypted-linux

# Unit-level tests: post-pass mangling, GCC plugin, seed-lib determinism.
make test                                       # ~30 sec

# Phase 1 + Phase 2 + randstruct + bundled toolchain image.
docker build -t encrypted-linux-image-build -f docker/Dockerfile.image-build .
bash scripts/build-overkill-image.sh            # ~15 min
bash scripts/build-overkill-musl-shared.sh      # ~2 min
bash scripts/extract-alpine-toolchain.sh        # ~2 min
bash scripts/assemble-overkill-gcc-initramfs.sh # ~1 min

# Boot and watch the auto-demo (boot, hello, in-VM compile, in-VM run).
bash scripts/run-qemu.sh
```

On arm64 hosts (M-series Macs) builds run under Docker's amd64 emulation
— slower (1-2 hours total) but otherwise identical.

## Repository layout

```
encrypted-linux/
├── README.md                    (this file)
├── STATE.md                     (live status)
├── LICENSE                      (Apache-2.0)
├── SEED.md                      (how the seed flows)
├── seed                         (master scrambling key, public)
├── plan/                        (5 plan documents — design, phases, risks, PoC, parallel tracks)
├── research/                    (7 dossiers — paper, scrambler, randstruct, GCC, distro, threat, Polyverse)
├── patches/                     (GCC plugin source + the v0 backend patch)
├── scripts/                     (build orchestrators, seed-derivation, kernel patchers, demo scripts)
├── docker/                      (build environment Dockerfiles)
├── docs/                        (DEMO-EVIDENCE, IN-VM-GCC-PATH, asciinema cast)
└── .github/workflows/           (CI: unit tests + full overkill build + boot smoke)
```

## Documentation entry points

**Why does this exist?**
1. [research/01-encrypted-execution-thesis.md](research/01-encrypted-execution-thesis.md) — the paper, summarized
2. [research/07-polyverse-polymorphic-linux.md](research/07-polyverse-polymorphic-linux.md) — what Polyverse shipped, what encrypted-linux extends (the calling-convention boundary they explicitly avoided)
3. [research/06-dynamic-linking-and-threat-model.md](research/06-dynamic-linking-and-threat-model.md) — honest threat model

**How does the stack work?**
1. [plan/00-design-principles.md](plan/00-design-principles.md) — 11 load-bearing decisions
2. [plan/03-risks-and-honest-limitations.md](plan/03-risks-and-honest-limitations.md) — what this is NOT
3. [docs/DEMO-EVIDENCE.md](docs/DEMO-EVIDENCE.md) — captured terminal output proving each defense

**How is it built?**
1. [plan/04-smallest-proof-of-concept.md](plan/04-smallest-proof-of-concept.md) — the smallest credible demo
2. [plan/05-parallel-tracks.md](plan/05-parallel-tracks.md) — dependency graph
3. [plan/01-phase1-userland-scrambling.md](plan/01-phase1-userland-scrambling.md) and [plan/02-phase2-kernel-scrambling.md](plan/02-phase2-kernel-scrambling.md) — milestones
4. [research/04-gcc-calling-convention-internals.md](research/04-gcc-calling-convention-internals.md) — what to touch in GCC

## Make targets

```
make help                                     # list targets
make test                                     # full unit demo (Tracks A + B)
make demo-mangle                              # post-compile mangler (Track A bash)
make demo-plugin                              # compile-time GCC plugin (Track A)
make demo-unistd                              # syscall renumbering + determinism (Track B)
make demo-gcc                                 # GCC arg-register permutation (Phase 1)
make test-image                               # rebuild the test Docker image
```

## License & patents

Apache-2.0. See `LICENSE`.

Patent posture:
- USPTO 10,733,303 (Polymorphic Code Translation Systems and Methods, Gore et al.) is publicly pledged to the public domain by the author.
- Polyverse's binary-scrambling patents (US 10,127,160 and US 2019/0371209) are covered by the Open Invention Network's Linux-system non-aggression cross-license. See [research/07 §9](research/07-polyverse-polymorphic-linux.md).
