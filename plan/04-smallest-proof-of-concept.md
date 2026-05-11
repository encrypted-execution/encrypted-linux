# Plan 04 — Smallest Proof of Concept

The shortest credible path from "no code" to "demo video that
demonstrates the value proposition." Scoped tighter than plan/01 so
the PoC can ship before Phase 1 is anywhere near complete.

## The PoC headline

> A 5-binary Linux system booting in QEMU. Built with a single
> scrambling GCC binary, a single seed. Drop a stock `hello` into the
> rootfs and it fails to run with `undefined symbol: printf__abi_<hash>`.
> Drop the same source compiled with the scrambling GCC and it prints
> `hello, encrypted linux`. Change one byte of the seed and the whole
> system rebuilds incompatibly with itself.

That is the demo. 30 seconds of asciicast. Everything else is
infrastructure to produce that 30 seconds.

## Scope (minimum)

- Userland only. **Stock kernel.** Plan/02 Phase-2 work explicitly out
  of scope here.
- Argument-register permutation only. **Callee-saved permutation
  deferred** to Phase 1 proper (plan/01 M3). The simplest scramble that
  produces a visible ABI break is enough for the demo.
- Symbol mangling **on**. This is the load-bearing piece that makes the
  failure mode clean (`research/06` §2); without it the demo is "stock
  hello segfaults somewhere unpredictable" which is unconvincing.
- Static-only userland. **No dynamic linker work.** Make the failure
  case a static binary that calls `printf` and gets a link-time
  `undefined symbol` against the scrambled musl archive.

Actually — make the demo *dynamic*. A static stock hello won't fail
under just userland scrambling (its syscalls work). A *dynamic* stock
hello against scrambled `libc.so` fails cleanly at `_dl_fixup`. So:

- musl built **two ways** for the PoC: `libc.a` (static) for our
  binaries, and `libc.so` (dynamic) so we can demo the load-time
  failure against a stock-built dynamic binary.
- The scrambled `hello` is statically linked → boots cleanly.
- A stock-built dynamic `hello` (built on the host) is dropped into
  `/bin/stock-hello`. It immediately fails because libc.so doesn't
  export `printf` — it exports `printf__abi_<hex>`.

That's the smallest fully-coherent demo.

## Deliverables

| Artifact | What it is | Where |
|---|---|---|
| `scramble-gcc` | Patched GCC binary (single seed baked in) | `build/toolchain/` |
| `seed` | 256-bit hex seed | repo root |
| `bzImage` | Stock 6.x Linux kernel from Buildroot | `build/images/` |
| `rootfs.cpio` | initramfs: musl + busybox + hello, all scrambled | `build/images/` |
| `stock-hello` | Same source built with host's stock gcc (dynamic) | embedded in rootfs at `/bin/stock-hello` |
| `qemu.sh` | One command to run the demo | repo root |
| `demo.cast` | asciicast of the run | `docs/demo.cast` |

## Step-by-step build

### Step 0 — Fork Buildroot

```
git clone https://gitlab.com/buildroot.org/buildroot.git
git -C buildroot checkout 2025.02
```

Add a defconfig: `configs/encrypted_linux_defconfig`:
```
BR2_x86_64=y
BR2_TOOLCHAIN_EXTERNAL=y
BR2_TOOLCHAIN_EXTERNAL_CUSTOM=y
BR2_TOOLCHAIN_EXTERNAL_PATH="$(BR2_EXTERNAL_ENCRYPTED_LINUX_PATH)/toolchain"
BR2_TOOLCHAIN_EXTERNAL_PREFIX="x86_64-encrypted-linux-musl"
BR2_TOOLCHAIN_EXTERNAL_CXX=y
BR2_PACKAGE_BUSYBOX=y
BR2_STATIC_LIBS=y
BR2_INIT_BUSYBOX=y
BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_LATEST_VERSION=y
BR2_LINUX_KERNEL_DEFCONFIG="x86_64"
BR2_TARGET_GENERIC_GETTY_PORT="ttyS0"
BR2_TARGET_ROOTFS_CPIO=y
BR2_TARGET_ROOTFS_CPIO_GZIP=y
```

### Step 1 — Build the scrambling GCC

Buildroot's `package/gcc/` builds the cross-toolchain. For the PoC,
*don't* use Buildroot for the toolchain — build it once, by hand,
external. Then point Buildroot at it via `BR2_TOOLCHAIN_EXTERNAL_CUSTOM`.

```
git clone git://gcc.gnu.org/git/gcc.git -b releases/gcc-14
cd gcc
git apply ../patches/scramble-gcc-v0.patch    # the scrambling patch
./configure \
  --target=x86_64-encrypted-linux-musl \
  --prefix=$PWD/../build/toolchain \
  --disable-bootstrap \
  --disable-multilib \
  --enable-languages=c,c++
ENCRYPTED_LINUX_SEED=$(cat ../seed) make -j$(nproc)
make install
```

The patch is the deliverable here. Smallest viable patch:

1. Add `gcc/config/i386/encrypted-linux.h` containing the per-seed
   argument-register permutation (an array `[1, 0, 4, 3, 2, 5]` say,
   meaning "what was RDI is now RSI" etc.) generated from the seed by
   a tiny helper at build time.
2. Modify `ix86_function_arg` to apply the permutation when the active
   ABI is `ENCRYPTED_LINUX_ABI` (a new value alongside `SYSV_ABI`,
   `MS_ABI`).
3. Modify `ix86_setup_incoming_varargs` and `ix86_va_start` to
   permute the va_list reg-save area to match.
4. Set `ENCRYPTED_LINUX_ABI` as the default for the x86_64-encrypted-
   linux-musl target.
5. Add a `TARGET_MANGLE_DECL_ASSEMBLER_NAME` hook that appends
   `__abi_<8hex>` to every external function name. Derive `<8hex>`
   from `HMAC-SHA256(seed, name)[:4]`.

Estimated patch size: 200–400 LOC of GCC backend code. Most of it is
deterministic seed-derivation boilerplate; the actual ABI-permutation
code is ~50 LOC.

### Step 2 — Build musl

Buildroot's `package/musl/musl.mk`. Apply our patch:

- musl's `arch/x86_64/syscall_arch.h` annotated so syscall stubs are
  marked with the *canonical* SysV ABI (escape hatch from the scrambling
  default). Implementation: a function attribute `__attribute__
  ((target("abi=sysv")))` recognized by our patched GCC.
- musl's `src/setjmp/x86_64/*.S` left as-is for the PoC since callee-
  saved permutation is deferred (Phase 1 M3 only).

### Step 3 — Build BusyBox

No source changes; just rebuild against scrambled musl.

### Step 4 — `hello`

```c
#include <stdio.h>
int main(void) { printf("hello, encrypted linux\n"); return 0; }
```

Two builds:
- Scrambled, static: `scramble-gcc -static -o hello hello.c` —
  goes into rootfs at `/bin/hello`.
- Stock, dynamic: `gcc -o stock-hello hello.c` — goes into rootfs at
  `/bin/stock-hello`. Bundle the host's stock `ld-linux-x86-64.so.2`
  and `libc.so.6` alongside it under `/stock/`, with `RPATH=/stock/`,
  so the *only* binary that fails the load-time check is the call into
  *our* scrambled `libc.so` — keeps the demo clean.

Hmm, actually that's not quite right — if the stock-hello is linked
against the host's libc.so.6 and we ship that libc.so.6 in the rootfs,
it'll just work and we lose the demo. Better:

- Build stock-hello against an `ld.so` and `libc.so` symlink that
  points at our *scrambled* libc.so. The stock-built binary therefore
  has unmangled `printf` references in its `.rela.plt`, and our
  scrambled libc.so exports only mangled `printf__abi_<hex>`.
  `_dl_fixup` reports `undefined symbol: printf` and aborts.

That's the demo.

### Step 5 — `qemu.sh`

```
qemu-system-x86_64 \
  -kernel build/images/bzImage \
  -initrd build/images/rootfs.cpio.gz \
  -append "console=ttyS0 quiet" \
  -nographic -m 256M
```

### Step 6 — Recording

asciinema:
```
asciinema rec docs/demo.cast
# inside QEMU:
/bin/hello                 # → "hello, encrypted linux"
/bin/stock-hello           # → "Error relocating ./stock-hello: printf: symbol not found"
echo "yes, the same source code"
diff /src/hello.c /src/hello.c
```

## Timeline

| Week | Deliverable |
|---|---|
| 1 | GCC patch: arg-register permutation working on a hand-written test case |
| 2 | GCC patch: symbol mangling; musl builds clean |
| 3 | Buildroot integration; rootfs boots in QEMU; busybox shell works |
| 4 | The dual-hello demo works; asciicast recorded; README + plan docs updated to point at the demo |

4 weeks single-engineer to first credible demo. Real Phase 1 (callee-
saved permutation, full musl asm audit, CFI test, libgcc rebuild
correctness, ELF-note seed tag and loader check) is plan/01 work that
follows the PoC.

## Out of scope

Everything in plan/02 (kernel scrambling, syscall renumbering, kernel-
internal ABI, modversions CRC seed-folding). The PoC demo is userland-
only and uses a stock kernel.

## What "done" looks like

```
$ make demo
... [builds happen] ...
$ ./qemu.sh
Linux version 6.x.x ...
Welcome to encrypted-linux PoC
encrypted-linux:~$ /bin/hello
hello, encrypted linux
encrypted-linux:~$ /bin/stock-hello
Error relocating /bin/stock-hello: printf: symbol not found
encrypted-linux:~$ cat /etc/encrypted-linux/seed
0xdeadbeef...
encrypted-linux:~$ poweroff
```

That's the value proposition demonstrated end-to-end. Everything in
the plan/ tree exists to scale this up to a real distro; this demo
exists to make the value visible in 30 seconds before any of that
investment.
