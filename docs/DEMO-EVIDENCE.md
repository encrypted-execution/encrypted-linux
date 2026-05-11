# DEMO-EVIDENCE.md

Captured terminal output proving the encrypted-linux Phase-2 PoC works
end-to-end: a binary built inside the encrypted-linux QEMU image runs
fine inside, but copying it to a stock Linux host fails because the
syscall numbers don't match.

Captured 2026-05-11. PoC seed:
`7f3da98edf5ba694c25fd3405776c0414f3815d448cbca81cae75b9213006392`

## Reproduce

```
make test-image                           # build encrypted-linux-test image
bash scripts/build-image.sh               # build kernel + musl + busybox + hello
bash scripts/rebuild-image-userland.sh    # patch musl hardcoded syscalls
bash scripts/assemble-initramfs.sh        # assemble rootfs.cpio.gz
gtimeout 60 qemu-system-x86_64 -m 4G \
    -kernel build/image/bzImage \
    -initrd build/image/rootfs.cpio.gz \
    -append "console=ttyS0 panic=5 el_demo=auto" \
    -nographic -no-reboot -accel tcg
```

## Step 1 — Permuted syscall numbers are baked into `hello`

```
$ objdump -d build/image/hello | \
    awk '/syscall$/{print prev; print} {prev=$0}' | \
    grep -E "mov[lq]?\s+\\\$0x[0-9a-f]+, %[er]?ax"

  4017e8: b8 d7 03 00 00    movl  $0x3d7, %eax    # 983 = exit_group (permuted from 231)
  40185e: b8 49 01 00 00    movl  $0x149, %eax    # 329 = arch_prctl (permuted from 158)
```

Two of the seven hardcoded-in-asm syscalls musl uses. Both have been
rewritten via `scripts/patch-musl-syscalls.py` to use the seed-permuted
numbers from `build/generated/asm/unistd_seeded.h`. Stock Linux has no
syscall 983, and 329 maps to `pkey_alloc`, not `arch_prctl`.

## Step 2 — Inside the encrypted-linux VM: hello runs successfully

```
$ gtimeout 60 qemu-system-x86_64 -m 4G \
    -kernel build/image/bzImage \
    -initrd build/image/rootfs.cpio.gz \
    -append "console=ttyS0 panic=5 el_demo=auto" \
    -nographic -no-reboot -accel tcg

...
Run /init as init process

=============================================================
  encrypted-linux PoC v0
  PERMUTED syscall numbers in kernel + musl
=============================================================

[el_demo=auto] auto-running /bin/hello...
hello from inside encrypted-linux!
[el_demo=auto] /bin/hello exited with rc=0
[el_demo=auto] /bin/hello details:
  Size: 16712     Blocks: 40         IO Block: 4096   regular file
Modify: 2026-05-11 23:00:27.146542913 +0000
[el_demo=auto] running 'uname -r' as a 2nd syscall test:
Linux (none) 6.6.30 #1 Mon May 11 22:09:37 UTC 2026 x86_64 GNU/Linux
[el_demo=auto] PASS - VM reached userspace and ran hello
[el_demo=auto] halting
reboot: System halted
```

Both kernel and userspace use the permuted syscall_64.tbl, so they
agree. `hello` calls `write(1, ...)` via musl's syscall stub. The
stub issues syscall **639** (permuted `write`). The kernel's
permuted dispatch table at slot 639 → `sys_write`. The write
succeeds, the string is printed, hello returns 0.

## Step 3 — Outside the VM (stock ubuntu:24.04): hello segfaults

```
$ docker run --rm --platform linux/amd64 \
    -v $PWD/build/image:/w:ro ubuntu:24.04 \
    sh -c 'echo running...; /w/hello; echo exit=$?'

running...
Segmentation fault
exit=139
```

Exit 139 = 128 + SIGSEGV. Stock Linux has no syscall 983 (or 329 in
the asm-hardcoded path), so the binary either fails -ENOSYS deep in
musl's init or gets back garbage that musl interprets as fatal. Either
way: **the binary does not run on a stock host.**

On Apple Silicon with Docker Desktop using Rosetta translation, the
failure mode varies — Rosetta sometimes prints
`rosetta error: Unimplemented syscall number 418` (our permuted
`set_tid_address`) and exits 133, sometimes silently hangs or
segfaults. All of these are correct: the binary is not portable to
non-encrypted-linux systems.

## Step 4 — Cross-VM (two seeds) failure mode

A SECOND encrypted-linux image was built with a different master
seed (`scripts/build-second-seed.sh`). Different seed → different
permuted syscall numbers in kernel + musl. Same source code, same
build pipeline, mutually incompatible binaries.

### 4a — Seed-B's own hello on seed-B's kernel (works)

```
$ gtimeout 30 qemu-system-x86_64 -m 4G \
    -kernel build/image-seedB/bzImage \
    -initrd build/image-seedB/rootfs.cpio.gz \
    -append "console=ttyS0 panic=2 rdinit=/bin/hello" \
    -nographic -no-reboot -accel tcg

Run /bin/hello as init process
hello from inside encrypted-linux (seed B)!
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
```

(The kernel panic at the end is normal — `/bin/hello` ran as PID 1
and exited cleanly with rc=0; the kernel doesn't allow init to exit
under any circumstances, so it panics with exitcode 0x00000000.)

### 4b — Seed-A's hello on seed-B's kernel (fails)

The seed-B initramfs bundles seed-A's hello at `/bin/hello-seedA`
specifically to demo cross-VM incompatibility.

```
$ gtimeout 30 qemu-system-x86_64 -m 4G \
    -kernel build/image-seedB/bzImage \
    -initrd build/image-seedB/rootfs.cpio.gz \
    -append "console=ttyS0 panic=2 rdinit=/bin/hello-seedA" \
    -nographic -no-reboot -accel tcg

Run /bin/hello-seedA as init process
traps: hello-seedA[1] general protection fault ip:4017de sp:7fff... error:0
Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b
```

`exitcode=0x0000000b` = 11 = SIGSEGV. The trap address `ip:4017de` is
the unreachable `hlt` instruction in musl's static_init_tls — musl
hit that path because an early syscall returned garbage (seed-B kernel
doesn't recognize seed-A's permuted numbers).

### Syscall mapping comparison

```
syscall      seed-A      seed-B
read         853         797
write        639         13
arch_prctl   329         140
exit_group   983         525
```

Two different cryptographic permutations of the same 365 canonical
syscalls. A binary from one is gibberish to the other.

## Step 5 — Phase 1 (symbol mangling) failure mode

Separate from the syscall failure: a dynamically-linked binary built
with the encrypted-linux toolchain references mangled symbol names
(`printf__abi_15e2ce22`) that don't exist in stock libc.

That demo lives in `scripts/scramble-mangle-test/test.sh` and
`test-plugin.sh`. Run via `make demo-mangle` and `make demo-plugin`.
Expected: 5 PASS for the post-pass mangling + 12 PASS for the GCC
plugin. Both paths produce the same mangled output by design.

## Summary

| Test | On its native kernel | On stock Linux | On a different-seed kernel |
|---|---|---|---|
| `/bin/hello` (static, scrambled musl, permuted syscalls) | **prints message, exits 0** | **segfaults, exits 139** | **#GP fault, panics** |
| Dynamic binary referencing `printf__abi_<hex>` | resolves via scrambled libc | `undefined symbol: printf__abi_<hex>` | symbol mismatch |
| Build new program inside VM with bundled `/usr/local-gcc/` | TODO: requires gcc statically linked to scrambled musl — see `docs/IN-VM-GCC-PATH.md` | n/a | n/a |

The first row is the Phase 2 value-prop: code that depends on a specific
encrypted-linux seed cannot be moved to ANY other environment (stock or
different-seeded). The second row is the Phase 1 value-prop: dynamic
binding fails cleanly at load time. Phase 1 + Phase 2 of the design
(plan/01, plan/02) — proven.

## Asciicast

A complete asciinema recording of the end-to-end demo is at
`docs/demo.cast`. Replay with:
```
asciinema play docs/demo.cast
```
