# Plan 03 — Risks and Honest Limitations

This document is what we tell anyone who asks "but does it really work?"
It is also what the README links to from its security-claims section.
The point is to be clear-eyed; security marketing that overpromises is
how products get pwned in public.

## 1. What encrypted-linux is NOT

**Not a confidentiality boundary.** The seed is recoverable from any
function prologue in any scrambled binary on disk. An attacker who can
read `/lib/libc.so.6` recovers the argument-register permutation in
seconds (`research/06` §6). The whole point is per-system uniqueness,
not per-binary opacity.

**Not a panacea for logic bugs.** A scrambled WordPress with an
authentication-bypass vulnerability has the same vulnerability after
scrambling. The attacker who exploits it gets a working session in the
scrambled language — they don't care about the ABI. The PHP scrambler's
own README is explicit on this point and ours must be too.

**Not protection against data-only attacks.** Chen/Pande/Sekar
"Non-Control-Data Attacks" (USENIX 2005) showed that corrupting a
`uid_t` or a config pointer is exploitable without ever crossing an
ABI boundary. Encrypted-linux does nothing against this class.

**Not a defense against an attacker who owns the build farm.** Supply
chain is its own problem space. The seed material, the patched GCC, the
build pipeline — all are high-value targets. Compromise of any of them
is game over. Phase 1 / Phase 2 of this project do not address this;
the trust-bootstrap milestone (v2, plan/00 §10) starts to.

**Not a defense against an attacker who has the compiler.** Possession
of the scrambling GCC + seed lets the attacker produce binaries
indistinguishable from legitimate ones. This is by design — the
defense is "must possess the compiler to ship working code," not "code
is unforgeable."

## 2. What it provides

A *diversity defense* and *moving-target* layer that:

- **Breaks the economics of universal pre-canned exploits.** A
  Metasploit module that targets `system()` via the standard SysV ABI
  fails on every encrypted-linux box. The attacker must build their
  payload against the target's specific seed, which means accessing the
  target's scrambled binaries first.
- **Routes ABI mismatches through clean load-time failures.** Drop a
  stock `.so`; get an `undefined symbol` instead of a segfault on the
  first call (`research/06` §1, §2). Defenders see telemetry; attackers
  see no useful oracle.
- **Forces external kernel modules to be rebuilt for the target.** Phase
  2 ties this to the existing `modversions` CRC machinery
  (`research/06` §4). Identical to how SUSE/RHEL kABI shipping already
  works in spirit.
- **Stacks cleanly on top of kCFI, FineIBT, Secure Boot, IMA, dm-verity,
  shadow stack, ASLR, W^X, FORTIFY_SOURCE.** It is one more layer in
  defense-in-depth, not a replacement.

The threat profile is: a remote attacker who has scanned a target with
known vulnerabilities and is choosing between targets. Encrypted-linux
shifts the cost from "drop a pre-canned exploit" to "obtain a copy of
the target's scrambled binaries, reverse-engineer the ABI, build a
custom payload, deliver it before the next scramble rotation."
Polyverse positioned this as Moving-Target Defense
(`research/07` §11) and shipped it commercially for ~5 years; the
defense category is real, but bounded.

## 3. Technical risks in this implementation

### 3.1 Scrambled GCC produces incorrect code

**Risk:** any bug in the i386.cc patches miscompiles musl or BusyBox in
ways that pass smoke tests but fail under stress. GCC backend changes
are notoriously subtle; recall Clang's `randomize-layout-seed` bug
miscompiling drivers in 6.2-rc5 (`research/03` §4).

**Mitigation:** GCC's `compare-debug` self-test is a partial check;
testsuite under `gcc/testsuite/` must pass with a non-zero seed; smoke
tests in QEMU under multiple seeds; bisection harness to localize any
regression to a specific (seed, source-file) pair.

**Residual:** GCC compiler regressions are a permanent risk surface.
Plan ships only an x86-64 target; ARM/RISC-V are future work and each
brings its own ABI quirks.

### 3.2 DWARF CFI emission gets out of sync with prologue

**Risk:** the permuted prologue saves callee-saved regs in a different
order than the CFI notes claim. C++ EH fails to unwind, libunwind dies,
`_Unwind_Resume` segfaults. Hard to detect without explicit testing.

**Mitigation:** every backend test that touches prologue emission must
exercise the `gcc/testsuite/g++.dg/eh/` suite under a non-default seed.
Add a project-specific test: compile a C++ program that throws across
N stack frames, runs in QEMU, exits 0 if caught.

### 3.3 libgcc / glibc-libgcc circular-build break

**Risk:** the cross-bootstrap dance (gcc → libc headers → libgcc →
glibc → libgcc; `research/05` §1) breaks subtly when scrambling enters
the loop. Stage1 GCC built by stock host emits scrambled code; libgcc
is rebuilt by stage1; if stage1 is wrong about scrambling, libgcc is
wrong; everything downstream silently miscompiles.

**Mitigation:** disable bootstrap (`--disable-bootstrap`) in Phase 1 PoC.
Document the gap. Re-enable self-host as a v2 milestone with explicit
self-compare validation.

### 3.4 Inline asm in dependencies

**Risk:** any C source in the closure that contains inline asm
referencing arg registers by name will read wrong values once arg-
registers are permuted (`research/04` §4). musl has limited inline asm
in `atomic-machine.h`, `tls.h`, `lowlevellock.h`. BusyBox almost none.
OpenSSL, libffi, V8, LuaJIT, ffmpeg, libgcrypt are minefields.

**Mitigation:** Phase 1 closure is deliberately tiny (musl + busybox +
kernel + hello). Document any dependency added later as needing an inline-
asm audit. libffi specifically is the highest-priority dependency because
it transitively underlies Python ctypes, Ruby FFI, GObject Introspection.

**Residual:** any future package addition triggers an asm audit. There
is no automated tool for this; it is human review.

### 3.5 vDSO compatibility

**Risk:** kernel ships the vDSO as part of the kernel image, not the
toolchain build. Phase 1 sidesteps by either disabling vDSO use in libc
or wrapping vDSO calls with seed-aware thunks (`research/04` §6).

**Mitigation:** Phase 1 M5 covers the wrapper path; in Phase 2 the
scrambled kernel build also emits a scrambled vDSO.

### 3.6 Build determinism gets violated by accident

**Risk:** A future contributor adds a feature that introduces
non-determinism (timestamp into a header, hostname into a build
artifact, random number that isn't seed-derived). Two builds of the
same source + seed produce different binaries; the closure breaks
silently for downstream consumers.

**Mitigation:** CI runs every build twice and `diff -r` the outputs.
Adopt the Reproducible Builds project's tooling (`diffoscope`) as a
hard gate.

### 3.7 ABI escape via dlsym + cast

**Risk:** C code that does `void *p = dlsym(handle, "printf"); ((int(*)
(const char*, ...))p)("hi")` may *appear* to work in some seeds because
the mangling hook doesn't apply to dlsym lookups — symbol names passed
to `dlsym` are user-supplied strings. The cast then calls the resolved
function with the scrambled convention while the resolved function
expects… also the scrambled convention, because it lives in scrambled
libc. So this case happens to work *within* the closure.

What breaks: `dlsym(stock_libc_handle, "printf")` then calling it would
mis-call. But `dlopen` of `stock_libc_handle` already fails because the
loader refused to map a stock libc whose ELF-note seed doesn't match.

**Residual:** programs that pass non-mangled strings to `dlsym` and call
the result trip the wrong-convention case only if the loader was
already bypassed. Document; do not engineer around.

### 3.8 Seed disclosure via crash dumps / debuginfo

**Risk:** Anyone with a copy of an encrypted-linux binary has the seed
(modulo recovery effort). Crashes ship to vendor support with full
register state. `vmlinux` + debuginfo trivially reveal the permutation.

**Mitigation:** strip aggressively from shipped binaries; tag
debuginfo with "do not share outside the build farm." But fundamentally
this is the principle 0.4 limitation: not a confidentiality boundary.

### 3.9 Tooling ecosystem fragility

**Risk:** strace, perf, ftrace, gdb, pwndbg, Ghidra, IDA Pro all assume
the standard SysV ABI. Many will give wrong arg-register names in their
disassembly views; gdb's `bt` should still work because it consumes CFI;
perf may give wrong symbol names if it doesn't follow the mangling
suffix.

**Mitigation:** Phase 1 targets QEMU only; tooling brokenness is
expected. Document the fix for each tool — most need only an ABI-table
patch.

## 4. Operational risks

- **Build-farm scale.** Polyverse's commercial failure was the fixed
  cost of seven hot rebuild farms (`research/07` §8). Encrypted-linux
  pilots one upstream. Resist scope creep.
- **Update story.** A new upstream musl release needs scrambling-rebuild
  before deployment. Make sure CI can do this in <1 hour for the PoC,
  <4 hours for production.
- **Tooling for users.** A real distro needs a package manager that
  rebuilds-on-install. `apk`-fork that holds the seed in a build-side
  daemon, serves rescrambled `.apk`s on demand. v2 work.
- **Secure Boot integration.** A signed bootloader + signed kernel +
  scrambling-built userspace is a coherent stack. The signing keys and
  the scrambling seed are both build-farm-side. Same threat surface,
  different artifact types.

## 5. The Thompson "trusting trust" gap

Acknowledged unresolved. The scrambling-GCC source is auditable; the
*compiled* scrambling-GCC sits on top of whatever GCC the host had,
which may itself be compromised. The defensible path is Mes/TinyCC full-
source bootstrap with the scrambling patch applied at a layer
auditable from hex0 (`research/05` §8). That is v2 work; document the
gap; do not claim trustworthiness we don't have.

## 6. Comparison against Polyverse's actual record

Polyverse shipped Polymorphic Linux to Linux Foundation, the DoD, and
SUSE customers for several years (`research/07` §1, §4). No public
record of a calling-convention-class regression killing the project —
because Polyverse *preserved* the calling convention and avoided the
hard cases. Encrypted-linux takes on that surface. Therefore:

- The base distribution model (mirror, per-customer scramble, drop-in)
  has been validated at production scale.
- The cross-TU calling-convention boundary has *not* been productized
  anywhere; we are first.
- The mitigations above are speculative against attacker behavior we
  have not yet observed.

The honest framing for any external audience: *Polyverse showed
diversification ships; encrypted-linux extends the surface in a way
Polyverse explicitly didn't, with all the new risks that implies.*
