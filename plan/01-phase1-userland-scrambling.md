# Plan 01 — Phase 1: Userland Scrambling

**Goal:** A scrambling GCC + scrambled musl + scrambled BusyBox + stock
Linux kernel, booting in QEMU. A stock-built static ELF placed on the
target either fails to load (dynamic case: undefined-symbol abort at
`_dl_fixup`) or runs the kernel syscall path fine but cannot call any
scrambled library function. Core kernel syscall ABI is preserved.

**Exit criterion:** A `hello` program built with the scrambled GCC prints
`hello, encrypted linux`. A `hello` program built with the host's stock
GCC, dropped into the same rootfs, fails with `Error loading shared
library libc.so: undefined symbol: printf__abi_<hash>` (dynamic case) or
runs but mis-calls into libc (static case — and the test artifact links
dynamically so the failure is the clean one).

Estimated single-engineer effort: 3–6 focused weeks for the PoC,
substantially longer for production hardening.

## Milestones

### M1 — Scrambling-GCC: argument-register permutation (week 1)

Patch `gcc/config/i386/i386.cc` to add a third ABI variant alongside
`sysv_abi`/`ms_abi`, parameterized by a permutation of the six
integer argument registers (RDI, RSI, RDX, RCX, R8, R9). The
permutation is derived from `HMAC-SHA256(seed, "x86_64.arg_regs")` at
GCC build time and baked into the binary.

Touchpoints:
- `ix86_function_arg`, `ix86_function_arg_advance` — emit the permuted
  register choice.
- `init_cumulative_args`, `INIT_CUMULATIVE_ARGS` — initialize ix86_args
  with the new ABI tag.
- `ix86_setup_incoming_varargs`, `ix86_va_start`, `ix86_gimplify_va_arg`
  — permute the va_list reg-save area slots and gp_offset arithmetic
  to match.

Seed delivery: env var `ENCRYPTED_LINUX_SEED=<256-bit hex>` consumed at
GCC `configure` time, written into a generated header
`gcc/config/i386/encrypted-linux-seed.h` (mirroring randstruct's
`scripts/gcc-plugins/randomize_layout_seed.h`, `research/03` §2).

**Exit:** `int f(int a, int b) { return a - b; }` compiled with the
scrambling GCC; `objdump -d` shows args read from permuted registers.
Smoke-test: two functions compiled with the *same* scrambling GCC can
call each other correctly via a tiny test harness.

### M2 — Symbol mangling (week 1, parallel to M1)

Add a `TARGET_MANGLE_DECL_ASSEMBLER_NAME` hook that suffixes every
non-static external C symbol with `__abi_<8-hex>` where `<8-hex>` is
the leading 32 bits of `HMAC-SHA256(seed, canonical_name || arg_count)`.

Static/internal functions: not mangled (principle 0.3).
`asm("printf")` and explicit `asm volatile` symbol references:
deliberately *not* rewritten — they're the escape hatch for asm
entry points that must keep canonical names. Document this.

**Exit:** `nm` on the same `f` shows `f__abi_<hex>`. A second
scrambled object that calls `f` resolves through the mangled name. A
stock-linked object cannot resolve `f`.

### M3 — Callee-saved set permutation + CFI (week 2)

Permute the callee-saved register set (RBX, RBP, R12, R13, R14, R15)
with a second HMAC tag. Update `CALL_USED_REGISTERS` and
`ix86_compute_frame_layout`. Verify `REG_CFA_*` notes emitted by
`ix86_expand_prologue` are correct for the new save mask (this is
`research/04` §4's "saving grace" — once CFI notes are right, libunwind
and C++ EH ride along for free).

Smoke test: a scrambled C++ program that throws across two TUs and
catches at the top frame still unwinds correctly.

**Risk window:** this is the milestone most likely to surface latent
GCC backend assumptions. Budget a week for surprise fixes.

### M4 — Rebuild libgcc and musl per seed (week 3)

- libgcc: rebuilds automatically once GCC is rebuilt; just confirm the
  unwinder (`unwind-dw2.c`) consumes CFI rather than assuming register
  layout. (It does — `research/04` §4.)
- musl: patch `src/setjmp/x86_64/setjmp.S` and `longjmp.S` to save/restore
  the *permuted* callee-saved set. Same for `swapcontext`, `getcontext`,
  `makecontext`. Patch `src/internal/syscall.h` so syscall stubs read
  arguments from the *permuted* user-convention registers and load them
  into the canonical syscall registers (RDI/RSI/RDX/R10/R8/R9). The
  permutation map is generated from the seed at musl `configure` time.

Musl chosen over glibc per `research/05` §4: ~30k LOC, ~30 sysdeps files,
vs. glibc's vast inline-asm surface.

**Exit:** musl builds clean with the scrambled GCC. `static int main()
{ return 42; }` linked statically against the scrambled musl runs in
QEMU and exits 42.

### M5 — Scrambled BusyBox + Buildroot integration (week 3–4)

- Buildroot fork: `BR2_TOOLCHAIN_EXTERNAL_CUSTOM` pointing at the
  scrambled GCC tarball. `BR2_PACKAGE_BUSYBOX=y`. `BR2_STATIC_LIBS=y`.
- BusyBox: <1% inline asm; should build with no patches.
- Confirm `init`, `sh`, `ls`, `cat`, `mount` all work in a QEMU
  initramfs.

**Exit:** `qemu-system-x86_64 -kernel bzImage -initrd rootfs.cpio
-append "console=ttyS0" -nographic` drops to a busybox shell, all
binaries are scrambled-built.

### M6 — ELF-note seed tag + loader check (week 4)

GCC emits a `.note.encrypted-linux` PT_NOTE in every object containing
the 32-bit seed hash. Add a tiny kernel `binfmt_elf` patch (or initially
an LD_AUDIT shim for fewer moving parts) that refuses to map an ELF
whose note is absent or mismatched, returning ENOEXEC.

For the PoC, start with the LD_AUDIT shim (userspace, easy to iterate).
Promote to a kernel patch once the shim is stable.

**Exit:** Drop a stock-built static `hello` into the rootfs. `./hello`
prints `Permission denied` or `ENOEXEC` cleanly. The scrambled `hello`
prints `hello, encrypted linux`.

### M7 — The dynamic-linking demo (week 4–5)

Bring up a single dynamic library — `libhello.so` — to demonstrate the
load-time failure mode for unauthorized `.so`s.

Build two `libhello.so`:
1. Scrambled. Exports `hello_print__abi_<hash>`.
2. Stock. Exports `hello_print`.

Build the consumer (scrambled) `hello` that calls `hello_print`. With
the scrambled `libhello.so` on `LD_LIBRARY_PATH`, it prints. Swap in
the stock `libhello.so`: `Error relocating ./hello: hello_print__abi_
<hash>: symbol not found`. Demo recorded for the README.

**Exit:** README has a 30-second asciicast showing both runs.

## Build-host operational story

Single VM, single seed, single Buildroot config. The seed lives in
`./seed` checked into the repo (we want reproducibility, not secrecy
— principle 0.4). `make` invokes Buildroot which:

1. Builds the scrambling GCC with `ENCRYPTED_LINUX_SEED=$(cat seed)`.
2. Builds musl with the same seed.
3. Builds BusyBox.
4. Builds the kernel (stock, not scrambled in Phase 1).
5. Assembles `bzImage` + `rootfs.cpio`.
6. Drops a `qemu.sh` for the demo.

Anyone who clones the repo and runs `make` gets the same artifacts
byte-identical. Changing one byte of `seed` invalidates every build
artifact downstream — by design.

## What this phase deliberately does NOT do

- **Scramble syscall numbers.** Phase 2.
- **Scramble kernel-internal calling convention.** Phase 2.
- **Self-host the scrambling GCC.** PoC uses `--disable-bootstrap`.
  Self-hosting is a v2 deliverable that proves the scrambling GCC can
  reproduce itself byte-for-byte under its own scrambling.
- **Boot from a real disk.** initramfs in QEMU only.
- **Run on real hardware.** QEMU only.
- **Build a third-party package** (Python, sqlite, openssl). Each adds
  its own ABI assumptions; demonstrate the closure principle first, then
  expand.

## Open dependencies on user decisions

These are flagged in STATE.md as well; restating here so the plan is
self-contained:

1. **Confirm musl over glibc.** Plan above assumes musl. Glibc is ~20×
   the porting effort (`research/05` §4).
2. **Confirm static-only PoC.** Plan above is static-by-default with M7
   bringing in *one* dynamic library to demo the load-time check. If the
   demo headline is "dynamic libraries fail to load," M7 becomes M3 and
   the rest pushes back.
3. **Confirm kernel stays stock in Phase 1.** Plan above assumes yes.
   Scrambling the kernel under stock-ABI syscalls is in scope for Phase 2.
