# Plan 00 — Design Principles

Load-bearing decisions, with cross-references to the research dossiers that
justify them. If a future contributor wants to deviate from one of these,
they should reread the cited dossier first.

## 1. Closure is the security primitive

The defense is *per-system uniqueness produced over a finite closure of
source code*, not per-binary obfuscation. The encrypted-linux closure is
"every translation unit reaching the running system" — kernel, libc,
busybox, all userspace, the bootloader stubs, the demo program. Anything
introduced from outside the closure cannot execute. Anything that *was*
in the closure works at native performance.

This is the paper's framing (`research/01` §4) and the PHP scrambler's
practical posture (`research/02` §5: "*if you want to download plugins or
add any php source code to your sites, this needs to be done with
polyscripting turned off*"). It is also exactly the operational stance
Polyverse's `DISALLOW_FILE_MODS=true` enforced for WordPress
(`research/07` §7).

**Operational consequence:** `dlopen()` of a non-closure `.so` must fail
closed (load-time error), not silently. Static-only Phase 1 trivializes
this; dynamic linking is reintroduced in Phase 2 with ELF-note seed checks.

## 2. Determinism per seed; the seed is `SOURCE_DATE_EPOCH`-equivalent

The build is a pure function of `(source, seed)`. No PID, time, ASLR, or
locale inputs. Same source + same seed → byte-identical artifact, every
time. Treat the scramble seed as a peer to `SOURCE_DATE_EPOCH`: one
environment variable, baked into every build, no implicit fallback.
(`research/05` §7.)

This is what makes GCC's stage2/stage3 compare-debug work
(`research/05` §3) and what makes the modversions-CRC trick work for
kernel module ABI tying (`research/06` §2). It is also the conceptual
distinction that puts encrypted-linux in the Reproducible Builds family,
not the obfuscation family.

The seed lives in `/etc/encrypted-linux/seed` on the build host and in an
ELF note (`.note.encrypted-linux.seed_hash`) on every emitted object.
**The seed is not a runtime secret.** Polyverse never delivered per-VM
seeds to the customer VM (`research/07` §3); we shouldn't either.

## 3. Symbol mangling is the load-time detection surface

Every external C function name emitted by the scrambled GCC carries a
suffix derived from `HMAC(seed, mangled_signature || canonical_name)`.
`printf` becomes `printf__abi_<hex>`. This routes every ABI mismatch
through `_dl_fixup`'s existing "undefined symbol" path — a clean
load-time abort instead of a silent register-mismatch crash.
(`research/06` §1, §2.)

Precedent is already shipping in mainline:
- Kernel `modversions` CRC32 mangles `printk` → `printk_R<crc>`.
- glibc symbol versioning (`GLIBC_2.x`) is mangling-by-side-table.
- C++ Itanium ABI mangling is the obvious analog.

**Don't mangle static/internal functions.** Their convention is
already private to the TU; mangling them adds bloat without any
detection surface.

## 4. Per-system uniqueness, not confidentiality

The seed is recoverable from a single function prologue in any scrambled
binary on disk (`research/06` §6). We do not claim secrecy. The defense
is that:

- Pre-canned exploit chains targeting the standard SysV ABI fail
  everywhere.
- Universal exploits stop working; attackers must possess a copy of the
  scrambled compiler to ship new working code.
- Mismatches surface as load-time errors, not silent corruption.

This is the same posture as Larsen et al.'s "Automated Software
Diversity" SoK and the same posture Polyverse marketed publicly
(`research/07` §11). It is **not** a confidentiality boundary. The plan
documents must say this everywhere; the README must say it; we do not
market what we cannot deliver.

## 5. Fail-closed at load, not silent corruption at runtime

Every layer of the system rejects mismatched objects loudly:

- The dynamic linker refuses to bind a `.so` whose ELF-note seed hash
  doesn't match the host's.
- The kernel's `insmod` already rejects modversions-CRC mismatch; we add
  the seed into the CRC formula (`research/06` §4).
- The PT_NOTE in every executable carries the seed hash; an `execve()`
  hook (kernel patch) refuses to map an ELF whose note is absent or
  wrong, returning ENOEXEC.

Polyverse's mirror silently downgraded to upstream on failure
(`research/07` §7, point 3). For an availability product that was
correct; for a hardening product it's a footgun. We default to
fail-closed and surface availability as a config flag, not a default.

## 6. Two-tier ABI in Phase 1; one-tier in Phase 2

- **External (cross-TU) ABI:** scrambled and mangled. RDI/RSI/RDX/RCX/R8/R9
  permuted per seed; callee-saved set permuted per seed; symbols suffixed.
- **Syscall ABI (Phase 1):** unchanged. Glibc/musl syscall stubs translate
  from scrambled user convention into canonical syscall convention
  (`research/04` §6). This is the right cleavage plane (`research/05` §5).
- **Phase 2** abolishes this distinction by scrambling the syscall numbers
  themselves and the kernel-internal convention. Static stock binaries
  stop running too.

## 7. Reuse GCC's existing dual-ABI infrastructure

GCC already carries two complete x86_64 calling conventions
(`sysv_abi`/`ms_abi`) and switches between them per function via the
`ix86_function_abi` machinery (`research/04` §5). Add a *third* variant
parameterized by seed; do not invent a new mechanism. Touching:

- `gcc/config/i386/i386.cc` — `ix86_function_arg`, `ix86_function_value`,
  `ix86_return_in_memory`, `ix86_compute_frame_layout`,
  `ix86_expand_prologue`/`epilogue`, varargs hooks.
- `gcc/config/i386/i386.h` — `CALL_USED_REGISTERS`, `FUNCTION_ARG_REGNO_P`.
- Symbol mangling: `TARGET_MANGLE_DECL_ASSEMBLER_NAME` hook.

DWARF CFI is data-driven — `dwarf2cfi.cc` consumes whatever `REG_CFA_*`
notes the prologue emits. So as long as the scrambled prologue attaches
correct CFI, C++ EH, libunwind, gdb, and `_Unwind_Backtrace` all keep
working without further patches (`research/04` §4).

## 8. Explicit non-targets — what we deliberately do NOT scramble

| Surface | Reason | Phase |
|---|---|---|
| UAPI structs (`include/uapi/`) | Kernel/userspace contract; randstruct refuses to touch them for the same reason (`research/03` §5) | All |
| Syscall ABI (registers, numbers) | Kernel boundary; preserved Phase 1, scrambled Phase 2 (`research/05` §5) | Phase 1 only |
| vDSO entry points | Kernel-built, not toolchain-built; wrap with seeded thunk in libc (`research/04` §6) | All |
| `__LINE__`, `__FILE__`-class compiler-resolved macros | Engine-resolved, not user code (analogous to PHP magic constants, `research/02` §1) | All |
| Inline asm constraint letters (`"D"`, `"S"`, etc.) | Independent of the calling convention; binding still works (`research/04` §4) | All |
| The build-system contract | `make`, `cmake`, `meson` invocations themselves; only the *output* changes | All |

If a contributor proposes scrambling one of these, the burden is on them
to demonstrate why the operational cost is worth it. Default: no.

## 9. Single-distro pilot, not a seven-distro mirror business

Polyverse's mirror covered Alpine + CentOS + Debian + Fedora + RHEL +
SUSE + Ubuntu (`research/07` §4). The fixed cost of maintaining seven
rebuild farms was a material part of why they wound down (`research/07` §8).

We pick **one** upstream. Alpine is the obvious choice: musl + BusyBox,
already aports-forked by Polyverse, smallest closure, easiest scrambled
rebuild. (`research/05` §10.) Anyone who wants to apply the same
techniques to Debian or RHEL can fork; we don't ship that.

## 10. Trust bootstrap is acknowledged, not solved (Phase 1)

Stage1 of the scrambling GCC is built by the host's stock GCC. Thompson
"trusting trust" is unresolved at this layer. Phase 1 PoC uses
`--disable-bootstrap` for speed (`research/05` §3). A defensible trust
story requires bootstrapping the scrambling GCC from Mes/TinyCC + an
audited patch series — that is a v2 milestone, not Phase 2 of the
runtime story (`research/05` §8). Document the gap; don't paper over it.

## 11. License & posture

- **Code:** Apache-2.0. Compatible with GCC's GPLv3, musl's MIT, BusyBox's
  GPLv2; specific files inherit upstream license where derived.
- **Patents:** USPTO 10,733,303 already pledged to public domain by Gore.
  Polyverse joined the Open Invention Network in 2018 placing the binary-
  scrambling patents under Linux-system non-aggression (`research/07` §9).
- **Marketing posture:** diversity defense, not confidentiality. See
  principle 4.
