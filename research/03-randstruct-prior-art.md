# Research Dossier 03 — Linux Randstruct: The Closest Prior Art

## 1. Mechanism

Randstruct is a **GCC plugin** (and now built-in Clang feature) that shuffles
the order of fields inside selected C structs at compile time. Source:
`scripts/gcc-plugins/randomize_layout_plugin.c` in the kernel tree.

**GCC integration points:**
- `PLUGIN_FINISH_TYPE` — `finish_type()` once a struct is fully parsed; primary
  hook where field reordering happens, before `finalize_type_size` lays out
  offsets.
- `PLUGIN_FINISH_DECL` — `randomize_layout_finish_decl()` validates declarations
  and catches unsafe initialization (positional initializers on randomized
  structs).
- `PLUGIN_ALL_IPA_PASSES_START` — `check_global_variables()` for cross-TU
  checking.
- `PLUGIN_ATTRIBUTES` — registers `__randomize_layout` / `__no_randomize_layout`.

**Algorithm:** Fisher-Yates shuffle of the struct's `FIELD_DECL` chain, keyed
by `(per-build seed XOR struct-name hash)`. A given struct in a given build
always randomizes the same way. Bitfields kept together; flexible array
members stay last. Clang 15 added the same feature with
`-frandomize-layout-seed=` / `-frandomize-layout-seed-file=` and a
`randomize_layout` attribute, integrated in Sema/AST rather than as a plugin.

## 2. Seed / key model

- **Generation:** 256 bits at kernel-config time, formatted as four 64-bit hex
  words. Plugin validates `"valid seed needs 64 hex chars:
  %016llx%016llx%016llx%016llx"` via `sscanf`.
- **Storage:** `scripts/gcc-plugins/randomize_layout_seed.h` plus
  `scripts/gcc-plugins/randstruct.seed`. Baked into the plugin binary at
  plugin-build time.
- **Incremental builds:** Seed **survives `make clean`** so out-of-tree
  modules can be built later. `make mrproper`/`make distclean` removes it.
  When the seed changes, `include/generated/randstruct_hash.h` is touched,
  pulled in from `compiler-version.h`, tracked by `fixdep` — forcing full
  tree rebuild. (Kees Cook's "Force full rebuild when seed changes" patch
  fixed Clang cases the GCC plugin caught.)

## 3. Which structs get randomized

Two selection paths:
- **Opt-in:** structs annotated `__randomize_layout`.
- **Automatic opt-out:** structs whose members are entirely function pointers
  (ops/vtable structs), detected by `is_pure_ops_struct()` / `is_fptr()`. Can
  be excluded with `__no_randomize_layout`.

Two Kconfigs: `RANDSTRUCT_FULL` (full shuffle), `RANDSTRUCT_PERFORMANCE`
(cacheline-aware, shuffles only within 64-byte groups, keeps bitfields).

**Why not all structs?** Many kernel structs:
- Cross UAPI (syscall args, ioctl payloads, netlink, ELF, perf events) —
  fixed ABI.
- Are accessed by hardware (DMA descriptors, MMIO register banks).
- Are accessed by asm with hard-coded offsets (`task_struct->thread_info`,
  `pt_regs`).
- Have `container_of` / type-punning patterns assuming sibling positions.

## 4. Performance and correctness costs

**Performance:** Full mode destroys cache locality (hot/cold grouping lost)
— "dramatic performance impact" per KSPP. Performance mode shuffles inside
cacheline groups, marginal overhead. FGKASLR comparison: ~1% kernel-compile
slowdown, ~4% in some workloads.

**Bugs/regressions:**
- **Positional initializers** — `struct foo x = {1, 2, 3};` silently
  misassigns fields. Randstruct rejects with `"casting between randomized
  structure pointer types (constructor)"`. Fixes (e.g. i915
  `intel_gt_debugfs_file`) converted to designated initializers.
- **Cross-struct casts / type punning** — code casting `struct A *` to
  "compatible" `struct B *` breaks when one side randomized. Plugin
  maintains a whitelist.
- **ARM corner cases** v4.10–v4.13.
- **NVIDIA out-of-tree driver:** `NvKmsKapiCallbacks` called wrong callback
  at shutdown when layout shuffled → panics.
- **Clang `-frandomize-layout-seed` bug (LLVM #60349):** implicit
  forward-declared structs skipped, miscompiling drivers in 6.2-rc5.
- **Debuginfo / forensics:** GCC bug 84052 — debuginfo didn't reflect
  randomized layout, breaking gdb/crash. Volatility broken by design.
- **GCC-15 ICE** compiling 6.14.5 with `CONFIG_RANDSTRUCT` (Debian #1104745).

Pattern: **implicit struct layout assumptions** — positional init, sibling-
field pointer arithmetic, sub/super-class casts, fixed offsets in asm,
fields assumed adjacent for cacheline reasons.

## 5. ABI implications

Randstruct **explicitly does not cross the kernel/userspace boundary.** UAPI
structs (`include/uapi/`) never annotated. Syscall numbers, ioctl encodings,
ELF, /proc, sysfs unaffected. External module ABI *is* affected — out-of-tree
drivers must be compiled against the same seed (seed file ships with
`linux-headers`). Linus called this "security theater" because public distros
must publish their seeds. Strongest threat model: **private in-house kernels**
(Google, Meta, Android verified-boot, GrapheneOS).

## 6. Plugin source pointers

- Plugin: `scripts/gcc-plugins/randomize_layout_plugin.c`
- Seed header: `scripts/gcc-plugins/randomize_layout_seed.h`
- Seed file: `scripts/gcc-plugins/randstruct.seed`
- Rebuild trigger: `include/generated/randstruct_hash.h` via
  `compiler-version.h`
- GCC hooks: `PLUGIN_FINISH_TYPE`, `PLUGIN_FINISH_DECL`,
  `PLUGIN_ALL_IPA_PASSES_START`, `PLUGIN_ATTRIBUTES`. Decisions before
  `finalize_type_size`.
- Clang equivalent: `clang::randstruct` namespace,
  `-frandomize-layout-seed[-file]=`.

## 7. Related techniques

| Technique | Granularity | Defeats | Defeated by |
|---|---|---|---|
| KASLR | Kernel base address | Hard-coded addresses | Single kernel pointer leak |
| FGKASLR | Per-function at boot | ROP gadgets at fixed offsets | Per-function leaks; relocation residue |
| Randstruct | Per-struct field order | Field-offset-aware read/write primitives | Per-build infoleak reconstructing layout |
| kCFI (Clang, Linux 6.1+) | Per-indirect-call type hash | Type-mismatched indirect call hijacks | Same-type gadget collisions |
| Intel IBT/CET ENDBR | Indirect branch targets | Arbitrary indirect jumps to non-ENDBR | Same-prototype gadgets at valid ENDBR |
| PaX RAP | Type-hashed indirect-call + XOR-keyed return | ROP and JOP | Same-type collisions; RAP cookie leak |
| Shadow stack (CET-SS) | Return addresses | ROP returns | Non-ROP attacks |

**Complementary, not redundant:** randstruct hides data layouts, FGKASLR hides
code layouts, kCFI/IBT restrict indirect call targets, shadow stack protects
returns.

## 8. Failures and bypasses

- **Info leaks reconstruct layout** — any read-where primitive that dumps a
  known struct lets the attacker recover offsets.
- **Public-build seed disclosure** — distros that ship `linux-headers` ship
  the seed. GrapheneOS analysis: an attacker can download all weekly
  releases per device model and pre-compute layouts.
- **Seed extractability from running kernel** — seed itself isn't stored
  in the running kernel image, only its *effects* are. But because
  randomization is deterministic from `seed XOR struct-name-hash`, observing
  enough struct offsets in memory (eBPF, dmesg leaks, infoleak gadget)
  reconstructs per-struct layouts without needing the seed.
- **Debugger / forensic visibility** — anyone with `vmlinux` + debuginfo
  trivially recovers layout — security depends on build artifacts being secret.
- **Same-type / function-pointer-only structs** — even shuffled, the *types*
  of slots don't change. "Call slot 3" still calls *some* function pointer.

## 9. Does randstruct randomize calling conventions?

**No.** Randstruct only touches `RECORD_TYPE` field ordering. It does not
alter argument register assignment, return register, caller- vs callee-saved
sets, stack alignment, red zone, frame layout, or name mangling.

**Why not — the technical barriers:**

1. **Whole-program consistency.** Every caller and callee must agree on
   argument passing. Struct field order is a property of the *type*, settled
   per-TU; the C ABI does cross-TU and includes asm, vDSO, KVM guests, BPF
   JITs, kernel modules, firmware, microcode interfaces. Randomizing per-
   function calling conventions requires either (a) whole-program LTO with
   global decision oracle, or (b) per-function thunks translating between a
   stable external ABI and the scrambled internal one — adding overhead
   exactly where it hurts most (every indirect call).
2. **Hand-written assembly.** Thousands of asm entry points (syscalls,
   interrupts, KVM VMENTRY/VMEXIT, context switch, copy_to_user, crypto).
   Each assumes fixed register convention. You cannot refuse to call a
   function the way you can refuse to touch a struct.
3. **Indirect calls through function pointers.** Once through `void (*fp)
   (args)`, the call site has no static knowledge of the target's randomized
   convention. Need runtime trampoline table — reinventing kCFI-style typed
   indirect calls *plus* per-callee permutation thunks.
4. **Interaction with CFI/IBT.** ENDBR/IBT pins indirect targets; kCFI pins
   type hashes. Per-function ABI permutation has to interlock with both.
5. **Debug/unwind/exception.** DWARF CFI, ORC unwinder, ftrace, livepatch,
   kprobes, `pt_regs` introspection all assume the standard ABI. Each needs
   per-function metadata.
6. **Performance.** Calling conventions are tuned. PaX H2HC13 paper and
   academic compile-time randomization work (MIT 6.858, Pagerando RFC) note
   register allocation *enforces* the convention — randomizing one requires
   perturbing the other.

In short: **randstruct succeeds because struct field layout is internal to
compiled code (sealed by `__randomize_layout` rules + designated
initializers). Calling conventions are external by definition — they exist
to glue independently compiled code together.** The encrypted-linux project
must solve precisely that whole-program consistency problem, with thunk-based
ABI bridges at module/asm boundaries, that randstruct sidesteps by simply
refusing.

## Sources

- [Randomizing structure layout, LWN](https://lwn.net/Articles/722293/)
- [Introduce struct layout randomization plugin, LWN](https://lwn.net/Articles/723997/)
- [Function Granular KASLR, LWN](https://lwn.net/Articles/824307/)
- [Indirect branch tracking for Intel CPUs, LWN](https://lwn.net/Articles/889475/)
- [Control-flow integrity for the kernel, LWN](https://lwn.net/Articles/810077/)
- [The grsecurity RAP patch set, LWN](https://lwn.net/Articles/713808/)
- [Kees Cook — security things in Linux v4.13](https://outflux.net/blog/archives/2017/09/05/security-things-in-linux-v4-13/)
- [Toolchain security features status update, LPC 2023](https://outflux.net/slides/2023/lpc/features.pdf)
- [scripts/gcc-plugins/randomize_layout_plugin.c](https://github.com/torvalds/linux/blob/master/scripts/gcc-plugins/randomize_layout_plugin.c)
- [PaX H2HC13 — gcc plugins](https://pax.grsecurity.net/docs/PaXTeam-H2HC13-PaX-gcc-plugins.pdf)
- [PaX RAP: RIP ROP H2HC15](https://pax.grsecurity.net/docs/PaXTeam-H2HC15-RAP-RIP-ROP.pdf)
- [grsecurity RAP FAQ](https://grsecurity.net/rap_faq)
- [Reflections on RANDSTRUCT in GrapheneOS](https://dustri.org/b/reflections-on-randstruct-in-grapheneos.html)
- [LLVM #60349](https://github.com/llvm/llvm-project/issues/60349)
- [NVIDIA open-gpu-kernel-modules #1033](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1033)
- [GCC Bugzilla 84052](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=84052)
- [Clang D121556 — randstruct](https://reviews.llvm.org/D121556)
- [Pagerando RFC (LLVM)](https://lists.llvm.org/pipermail/llvm-dev/2017-June/113794.html)
- [MIT 6.858 Compile Time Randomization](https://css.csail.mit.edu/6.858/2013/projects/an24021-sa23885.pdf)
- [Kernel CFI (AOSP)](https://source.android.com/docs/security/test/kcfi)
