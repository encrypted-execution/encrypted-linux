# Research Dossier 04 — GCC Calling Convention Internals

## 1. System V AMD64 psABI

**Authoritative:** `https://gitlab.com/x86-psABIs/x86-64-ABI` (HPE site is
down; canonical PDF built from this repo). Widely-cited mirror:
`https://www.uclibc.org/docs/psABI-x86_64.pdf`.

**Register layout (§3.2.3):**
- Integer/pointer args in order: RDI, RSI, RDX, RCX, R8, R9 → then stack
  (right-to-left, caller cleans).
- SSE args: XMM0–XMM7.
- Return: RAX (and RDX for 128-bit / two-eightbyte); XMM0/XMM1 for SSE;
  ST0/ST1 for x87.
- Callee-saved: RBX, RBP, R12, R13, R14, R15, plus RSP. MXCSR control bits
  and x87 control word also callee-saved.
- Caller-saved: RAX, RCX, RDX, RSI, RDI, R8–R11, all XMM/YMM/ZMM, x87 stack,
  MXCSR status.
- Stack alignment: 16-byte at call site (RSP ≡ 8 mod 16 on entry, before the
  pushed return address aligns the local frame). 32 for `__m256`, 64 for
  `__m512`.
- Red zone: 128 bytes below RSP, usable by leaf functions without adjusting
  RSP; not preserved across signals when kernel honors it (Linux user-space
  does).
- Varargs: AL holds the number of XMM regs used for floats (0–8). Callee
  uses this to spill XMM0–XMM7 into `__va_list` save area (§3.5.7).
- Aggregate classification: each eightbyte classified as INTEGER, SSE,
  SSEUP, X87, X87UP, COMPLEX_X87, NO_CLASS, MEMORY; aggregates >16B or with
  unaligned fields passed in MEMORY.

## 2. Where in GCC

x86 backend lives in `gcc/config/i386/`. Files to touch:

- **`gcc/config/i386/i386.cc`** (renamed from `i386.c` in GCC 12):
  - `ix86_function_arg` — `TARGET_FUNCTION_ARG`; picks register per arg.
  - `ix86_function_arg_advance` — `TARGET_FUNCTION_ARG_ADVANCE`; advances
    cumulative-args state.
  - `ix86_function_value`, `ix86_function_value_regno_p`,
    `ix86_libcall_value` — return-register selection.
  - `ix86_return_in_memory` — `TARGET_RETURN_IN_MEMORY`.
  - `ix86_function_arg_regno_p` — backs `FUNCTION_ARG_REGNO_P`.
  - `init_cumulative_args` / `INIT_CUMULATIVE_ARGS` — initializes per-call
    `CUMULATIVE_ARGS` (`ix86_args`).
  - `classify_argument`, `examine_argument` — implement psABI eightbyte
    classification.
  - `ix86_compute_frame_layout` — locals, callee-saved spill area,
    alignment padding, red zone.
  - `ix86_expand_prologue` / `ix86_expand_epilogue` — emit push/pop of
    callee-saved, frame-pointer setup, stack realignment, CFI notes
    (`REG_FRAME_RELATED_EXPR`, `REG_CFA_*`).
  - `ix86_setup_incoming_varargs`, `ix86_va_start`, `ix86_gimplify_va_arg`
    — varargs handling, `va_list` reg-save block.
  - `ix86_function_ok_for_sibcall` — tail-call legality.
- **`gcc/config/i386/i386.h`:** `REG_PARM_STACK_SPACE`,
  `OUTGOING_REG_PARM_STACK_SPACE`, `STACK_BOUNDARY`,
  `PREFERRED_STACK_BOUNDARY_DEFAULT`, `FIRST_PSEUDO_REGISTER`,
  `CALL_USED_REGISTERS`, `FUNCTION_ARG_REGNO_P`, `STATIC_CHAIN_REGNUM`.
- **`gcc/config/i386/i386.md`:** `call`, `call_value`, `sibcall`,
  `prologue`, `epilogue`, `return` patterns.
- **`gcc/config/i386/i386-options.cc`:** parses `-mregparm`, `-mabi=`,
  attribute strings.
- **`gcc/dwarf2cfi.cc`, `gcc/dwarf2out.cc`:** convert `REG_CFA_*` notes
  from the prologue into `.cfi_*` / `.eh_frame`. The x86 backend must emit
  notes matching whatever scrambled prologue it generates.

## 3. Scrambleable dimensions

| Dimension | Effort | Risk |
|---|---|---|
| **Permute arg registers** | Low | Breaks every inline asm naming arg regs; varargs save-area layout (`__va_list_tag.gp_offset` indexing assumes canonical order) |
| **Permute callee-saved set** | Medium — `CALL_USED_REGISTERS`, frame layout, prologue/epilogue, `.eh_frame` | Breaks `setjmp`/`longjmp`, `swapcontext`, `_dl_runtime_resolve` save block, libunwind, libgcc unwinder. Rebuild glibc setjmp.S, makecontext, ucontext, dl-trampoline.S |
| **Shuffle stack-arg order** | Medium | Breaks variadic functions hard |
| **Reorder prologue pushes / frame pointer** | Low if CFI tracks it | Safest dimension; only breaks hand-written .S without `.cfi_*` |
| **Return-register choice** | Low edit, big radius | Every asm caller; IFUNC resolvers; PLT lazy resolver writes resolved address but caller still reads RAX |
| **Stack alignment offset shift** | Low — `INCOMING_STACK_BOUNDARY` | SIMD spills, signal-frame layout, vfork/clone. Probably not worth it |
| **Name-mangling suffix** | Very low — wrap `ASM_OUTPUT_LABEL` / `TARGET_MANGLE_DECL_ASSEMBLER_NAME` | **Cleanest hardening; recommended belt-and-suspenders.** Stock vs. scrambled binaries can't even link. Doesn't break inline asm |

## 4. The hard parts

- **libgcc / libgcc_s** — bakes in the convention. `_Unwind_Resume`,
  `__gcc_personality_v0`, soft-float helpers, `__divti3`. libgcc_s.so.1
  carries the unwinder used by C++ EH and `pthread_cancel`. **Rebuilt per
  seed.** Cross-bootstrap dance (gcc → libc headers → libgcc → glibc →
  libgcc) repeats per seed.
- **stdarg.h / `__builtin_va_arg`** — `ix86_gimplify_va_arg` and the
  `va_list` reg-save block layout (gp_offset, fp_offset, overflow_arg_area,
  reg_save_area) is fixed by psABI §3.5.7. Permuting integer arg regs
  requires permuting the reg_save_area slots and gp_offset arithmetic. Both
  sides of va_arg expansion are emitted by the same compiler so internally
  consistent, but mixed-seed varargs reads garbage.
- **setjmp/longjmp** — glibc `sysdeps/x86_64/setjmp.S` hard-codes RBX, RBP,
  R12, R13, R14, R15, RSP, RIP (with PTR_MANGLE on RBP/RSP/RIP). Permuted
  callee-saved set requires regenerating. Same for `__sigsetjmp`,
  `getcontext`, `setcontext`, `swapcontext`, `makecontext`, `_longjmp_unwind`.
- **DWARF CFI / `.eh_frame`** — GCC emits CFI from `REG_CFA_*` notes
  attached by `ix86_expand_prologue`. As long as scrambled prologue
  attaches correct notes, `dwarf2cfi.cc`/`dwarf2out.cc` produce correct
  unwind tables — C++ EH, `_Unwind_Backtrace`, libunwind, gdb all consume
  CFI rather than assume layout. **Saving grace** for prologue scrambling.
  Recent `REG_CFA_UNDEFINED` work (gcc-patches Jan 2024) confirms machinery
  handles non-default callee-saved sets.
- **PLT / GOT / `_dl_runtime_resolve`** — glibc
  `sysdeps/x86_64/dl-trampoline.{S,h}` saves *all* argument registers
  (RDI/RSI/RDX/RCX/R8/R9/RAX + XMM0–7) across lazy resolution. If
  user-space arg-register set changes, the trampoline's save mask must
  change. ld.so itself must be built with scrambled convention.
- **IFUNC resolvers** — x86_64 resolvers take no args (hwcap not passed
  on x86_64) and return a function pointer in RAX. Cleaner than other
  arches but return-register choice still matters.
- **Inline asm** — `asm("..." : : "D"(x))` (D = RDI), `"S"`, `"d"`, `"c"`,
  `"a"` constraints lock a value to a specific register *by name*. GCC's
  constraint letter table is independent of the calling convention so
  constraint still binds correctly — but if the programmer wrote inline
  asm believing RDI is arg1, and you've moved arg1 to R9, the asm reads
  the wrong value. Same for naked functions and hand-written .S in glibc,
  OpenSSL, ffmpeg, libgcrypt, kernel vDSO.
- **C++ EH** — depends entirely on CFI + personality routine +
  `_Unwind_Resume`. Works as long as libgcc_s is rebuilt with same seed
  and CFI is correct.

## 5. Existing GCC mechanisms to leverage

- **GCC plugins** (`gcc/plugin.cc`, `gcc-plugin.h`): expose events
  (`PLUGIN_PASS_MANAGER_SETUP`, `PLUGIN_FINISH_TYPE`, `PLUGIN_PRE_GENERICIZE`,
  `PLUGIN_ATTRIBUTES`). Target hooks (`targetm.calls.function_arg`) are
  function pointers in a struct and *can* in principle be replaced from a
  plugin's init — but plugin runs after target init and after many internal
  tables (`CALL_USED_REGISTERS`, hard-reg sets) are frozen. **A plugin
  cannot cleanly replace the calling convention; needs a backend patch.**
  Plugins usable for the name-mangling suffix.
- **`-mregparm` / `__attribute__((regparm(n)))`** — i386-only (silently
  ignored on x86_64). Prior art for "compile-flag-controlled arg-passing
  change with ABI break warning."
- **`__attribute__((ms_abi))` / `((sysv_abi))`** — GCC already carries two
  complete x86_64 calling conventions in one compiler and switches between
  them per function. Mechanism: `ix86_function_abi` + per-function
  `function_abi` records consulted by `ix86_function_arg`. **This is the
  cleanest integration point.** Add a third (or N-th) ABI family
  parameterized by seed, registered in the same machinery.
- **`no_caller_saved_registers`** — forces all regs to be callee-saved
  across a call (interrupt handlers). Demonstrates GCC already supports
  radical save-mask permutation including correct CFI.
- **Function multiversioning / `target_clones`** — dispatch by CPU features
  at runtime via IFUNC. Shows the symbol-mangling and dispatch
  infrastructure that could host per-seed symbol suffixes.

**Recommended combination:** patch `ix86_function_arg` and friends to read
a seed-derived permutation table (new ABI variant alongside SYSV/MS), reuse
`ms_abi`/`sysv_abi` dispatch infrastructure, add a
`TARGET_MANGLE_DECL_ASSEMBLER_NAME` hook to suffix symbols, rebuild libgcc
+ glibc per seed.

## 6. Syscalls — clean boundary

**Yes, mostly.** Linux x86_64 syscall ABI (RAX=nr, args in
RDI/RSI/RDX/R10/R8/R9, kernel clobbers RCX/R11) is defined by the kernel
independently of user-space C ABI. Lives in glibc
`sysdeps/unix/sysv/linux/x86_64/sysdep.h` and per-syscall stubs (`syscall.S`,
`clone.S`) as hand-written asm. **As long as those stubs translate from the
scrambled user-space convention into the canonical syscall convention, the
kernel boundary is unaffected.** psABI MR !25 ("syscalls don't clobber
argument regs") clarifies the kernel preserves arg registers — changing
user-space arg regs doesn't change kernel guarantees.

Caveats: vDSO (`linux-vdso.so.1`) exports `__vdso_clock_gettime` etc. using
stock SysV — the kernel builds the vDSO, not your toolchain. **Wrap vDSO
calls** with a per-seed thunk in glibc, or disable vDSO use.

## 7. Inline-asm survey

- **glibc** — ~5–8% of source files. Concentrated in `sysdeps/x86_64/`
  (math, string, syscalls, setjmp, dl-trampoline, makecontext), plus inline
  asm in `atomic-machine.h`, `tls.h`, `lowlevellock.h`. **All
  calling-convention-sensitive.** Estimate: 100% need per-seed regeneration;
  ~30 files in `sysdeps/x86_64/`.
- **coreutils** — <1%, mostly portable C.
- **busybox** — <1%, similar.
- **OpenSSL / libgcrypt / zlib / ffmpeg / kernel** — heavy hand-written .S
  in crypto and codec hot paths, often containing function entry points by
  hand. Need per-seed regeneration (OpenSSL generates from perlasm) or hand
  patching.

**"Would never work" categories:**
1. Pre-built proprietary binaries (NVIDIA driver, commercial libs) — embed
   stock convention, cannot be relinked.
2. JIT compilers in the tree (V8, LuaJIT, sljit, **libffi**, GHC RTS) emit
   machine code at runtime assuming stock SysV. Each needs per-seed
   codegen patch. **libffi in particular is everywhere** (Python ctypes,
   Ruby FFI, GObject) — highest-priority single dependency.
3. `dlsym` + cast-to-function-pointer assumes resolved symbol uses host
   convention — fine within one seed, broken across (which is what we want).
4. Go runtime, Rust `extern "C"`, OCaml C stubs — every FFI surface needs
   the seed.

**Bottom line:** technically achievable with bounded compiler work
(`i386.cc` + libgcc + glibc syscall/setjmp/dl-trampoline regen per seed),
DWARF CFI gives C++ EH and unwinding for free, existing `ms_abi`/`sysv_abi`
infrastructure is the natural attachment point. Blast radius: hand-written
asm (regenerable from perlasm or template), JITs (one patch per JIT,
libffi highest-priority), vDSO (wrap in glibc), pre-built closed-source
binaries (incompatible by design — the point).

## Sources

- [System V AMD64 psABI repo](https://gitlab.com/x86-psABIs/x86-64-ABI)
- [psABI PDF mirror](https://www.uclibc.org/docs/psABI-x86_64.pdf)
- [psABI MR !25 — syscalls don't clobber args](https://gitlab.com/x86-psABIs/x86-64-ABI/-/merge_requests/25)
- [System V ABI — OSDev Wiki](https://wiki.osdev.org/System_V_ABI)
- [x86 calling conventions — Wikipedia](https://en.wikipedia.org/wiki/X86_calling_conventions)
- [GCC Internals: Register Arguments](https://gcc.gnu.org/onlinedocs/gccint/Register-Arguments.html)
- [GCC Internals: Frame Layout](https://gcc.gnu.org/onlinedocs/gccint/Frame-Layout.html)
- [GCC Internals: Varargs](https://gcc.gnu.org/onlinedocs/gccint/Varargs.html)
- [GCC Internals: Plugins](https://gcc.gnu.org/onlinedocs/gccint/Plugins.html)
- [GCC Internals: Plugin API](https://gcc.gnu.org/onlinedocs/gccint/Plugin-API.html)
- [gcc-mirror i386.h](https://github.com/gcc-mirror/gcc/blob/master/gcc/config/i386/i386.h)
- [gcc-mirror i386.cc (codebrowser)](https://codebrowser.dev/gcc/gcc/config/i386/i386.cc.html)
- [GCC target.def](https://github.com/gcc-mirror/gcc/blob/master/gcc/target.def)
- [GCC x86 Function Attributes](https://gcc.gnu.org/onlinedocs/gcc/x86-Function-Attributes.html)
- [GCC x86 Options](https://gcc.gnu.org/onlinedocs/gcc/x86-Options.html)
- [libgcc unwind-dw2.c](https://github.com/gcc-mirror/gcc/blob/master/libgcc/unwind-dw2.c)
- [gcc-patches: REG_CFA_UNDEFINED](https://www.mail-archive.com/gcc-patches@gcc.gnu.org/msg332898.html)
- [glibc setjmp.S](https://github.com/bminor/glibc/blob/master/sysdeps/x86_64/setjmp.S)
- [glibc dl-trampoline.h](https://github.com/bminor/glibc/blob/master/sysdeps/x86_64/dl-trampoline.h)
- [Peilin Ye — _dl_runtime_resolve](https://ypl.coffee/dl-resolve/)
- [MaskRay — GNU IFUNC](https://maskray.me/blog/2021-01-18-gnu-indirect-function)
- [MaskRay — Stack unwinding](https://maskray.me/blog/2020-11-08-stack-unwinding)
- [Eli Bendersky — stack frame x86-64](https://eli.thegreenplace.net/2011/09/06/stack-frame-layout-on-x86-64)
- [libstdc++ ABI Policy](https://gcc.gnu.org/onlinedocs/libstdc++/manual/abi.html)
- [syscall(2) man page](https://man7.org/linux/man-pages/man2/syscall.2.html)
