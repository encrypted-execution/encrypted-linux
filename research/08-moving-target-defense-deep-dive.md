# Research Dossier 08 — Moving Target Defense: Beyond Single-Axis Diversification

## 1. Why encrypted-linux is right but incomplete

The framing — *"as different from another Linux the way MacOS is
different from Windows"* — names the gap the MTD literature has refused
to confront. Existing diversification is **single-axis** by construction.
ASLR randomizes one number (base address). RANDSTRUCT randomizes one
number per struct. ISR randomizes one opcode XOR key. Even Polyverse's
Polymorphic Linux applies seven small-radius transformations *inside a
preserved C ABI* (dossier 07). Each axis adds 20–30 bits and is
defeated by a single information leak (§7). The reason MacOS exploits
don't run on Windows is **not** that one number differs — it's that
*every layer was designed by a different team against a different
contract*: Mach traps vs syscall, Mach-O vs PE, libSystem vs ucrt,
BSD-derived VFS vs Object Manager, entitlements vs ACLs, kqueue vs IOCP.
The attacker re-implements the kit; they don't adapt it.

Encrypted-linux already extends along five axes — syscall numbers,
64-bit syscall arg width, RANDSTRUCT_FULL, calling-convention register
allocation, symbol mangling — using musl so mangling mismatches abort
at load (dossier 06 §2). Further than anything shipped publicly. The
thesis here: **five axes is not enough** if the goal is making a stock
tool kit useless on first contact. Target is "attacker recompiles the
kit per target" — raise every exploit primitive (gadget chain, syscall
wrapper, libc bypass, kernel exploit, persistence) from "download" to
"per-target reverse-engineer." Needs enough independent axes that no
single leak collapses the space.

## 2. Existing academic MTD: survey + what's missing

The canonical reference is **Larsen, Homescu, Brunthaler, Franz** —
*SoK: Automated Software Diversity* (IEEE S&P 2014,
[PDF](https://oaklandsok.github.io/papers/larsen2014.pdf)). The
taxonomy is three-dimensional: **what** is diversified (instruction set,
registers, code layout, data layout, system interface), **when**
(compile/link/install/load/runtime), and **how** uniformly variants are
distributed. Larsen et al. note that *"diversity techniques are
typically evaluated against a single class of attacks"* — a gap a
decade later still mostly unfilled. Significant single-axis prior work:

- **Instruction-Set Randomization.** Kc, Keromytis, Prevelakis (CCS
  2003, [Semantic Scholar](https://www.semanticscholar.org/paper/3d06bc310afc5ca8b04930a03514d1430a87ec37)).
  Per-process key XORed into the instruction stream; injected code
  decodes to garbage. Killed by Sovarel/Evans 2005 derandomization with
  few-thousand queries. Hu et al.'s ACSAC 2010
  ([ACM](https://dl.acm.org/doi/10.1145/1920261.1920268)) revived with
  HW support. Encrypted-linux's scrambled GCC is a conceptual relative,
  but the seed never reaches the host (dossier 07 §3), neutralizing
  derandomization-via-feedback.

- **Address Obfuscation.** Bhatkar, DuVarney, Sekar (USENIX 2003,
  [PDF](https://www.usenix.org/legacy/event/sec03/tech/full_papers/bhatkar/bhatkar.pdf)).
  The ASLR superset: not just bases but intra-segment globals,
  stack-frame layout, heap metadata. Half shipped as glibc ASLR; the
  more radical proposals (per-function relocation, randomized struct
  layout) waited a decade for FGKASLR/randstruct.

- **System Call Randomization.** Chen, Pande, Ramachandran
  ([IJITCS](https://www.mecs-press.org/ijitcs/ijitcs-v1-n1/v1n1-1.html));
  *MTD: Run-time System Call Mapping Randomization* (IEEE 2021,
  [Xplore](https://ieeexplore.ieee.org/document/9644278)). Permute
  `sys_call_table`. Open problem they call out: *"diversified system
  call numbers in the operating system kernel have to be propagated to
  libraries that employ system calls."* Encrypted-linux solves this by
  rebuilding musl against the same seed.

- **PaX/Grsecurity.** Most aggressive shipping single-stack:
  RANDSTRUCT ([H2HC12](https://pax.grsecurity.net/docs/PaXTeam-H2HC12-PaX-kernel-self-protection.pdf)),
  RAP (XOR ret addresses with per-task register-resident key,
  [H2HC15](https://pax.grsecurity.net/docs/PaXTeam-H2HC15-RAP-RIP-ROP.pdf)),
  KERNEXEC, UDEREF. RANDSTRUCT upstreamed in 4.13; RAP remains
  proprietary. kCFI (LLVM 16+) is upstream's answer but works on type
  signatures rather than per-task keys.

- **Multi-Variant Execution.** Cox's *N-variant systems* (USENIX 2006);
  Salamat's **Orchestra** (EuroSys 2009, ptrace syscall sync). Modern:
  **ReMon** ([VUSec DSN 2016](https://download.vusec.net/papers/dsn-2016.pdf)),
  **MvArmor** ([vusec/mvarmor](https://github.com/vusec/mvarmor)),
  **kMVX** (ASPLOS 2019,
  [ACM](https://dl.acm.org/doi/10.1145/3297858.3304054)), sMVX
  (Middleware 2024). Cost 2× CPU min; latency dominated by syscall
  serialization. Catches *divergent* attacks only — transparent to
  data-only attacks that succeed identically across variants (§7).

- **DARPA CFAR** (2014–2018,
  [darpa.mil](https://www.darpa.mil/research/programs/cyber-fault-tolerant-attack-recovery)).
  Production-engineered MVX. Trail of Bits' *Double Helix* shipped
  recompilation-based diversification + runtime variant monitoring
  ([trailofbits.com](https://www.trailofbits.com/services/published-research/cyber-fault-tolerant-attack-recovery-cfar/),
  [blog](https://blog.trailofbits.com/2018/09/10/protecting-software-against-exploitation-with-darpas-cfar/));
  Weimer/Forrest's *RAVEN* described the variant-monitoring/recovery
  architecture ([PDF](https://web.eecs.umich.edu/~weimerw/p/weimer-cisr2016.pdf)).
  No deployed product line emerged; the engineering was the result.

- **White-box cryptography.** Chow, Eisen, Johnson, van Oorschot
  (SAC 2002, [eprint 2013/104](https://eprint.iacr.org/2013/104.pdf)).
  Embed AES key into obfuscated lookup-table network. **Broken** by
  the BGE attack at 2³⁰ work, now 2²² with improvements
  ([eprint 2013/450](https://eprint.iacr.org/2013/450)). Lesson for
  encrypted-linux: any defense reducing to "the attacker can't
  structurally cryptanalyze our table lookups" gets cryptanalyzed.
  Lean on *information cost of physical recovery* (seed on build farm,
  never on host), not algebraic hardness.

- **Anti-debug / anti-RE / packers.** Themida and VMProtect ship
  control-flow flattening, virtualized ISA, anti-debug, anti-VM
  ([oreans](https://www.oreans.com/Themida.php),
  [unprotect.it](https://unprotect.it/technique/themida/)). These are
  *concealment*, not diversity — same protected binary everywhere, so
  one RE benefits everyone. UnThemida (Suk 2018,
  [Wiley](https://onlinelibrary.wiley.com/doi/abs/10.1002/spe.2622))
  showed full devirtualization is feasible. Principled takeaway:
  Themida's *fresh-VM-per-build* is structurally the encrypted-
  execution move, and survived two decades commercially against
  motivated REs — useful existence proof.

## 3. Live self-modifying code: review of production techniques

SMC has a bad reputation because malware uses it badly. But mainline
Linux already ships principled SMC mechanisms that can carry
diversification state:

- **Kernel `alternatives`** (`arch/x86/kernel/alternative.c`,
  [LWN](https://lwn.net/Articles/164121/),
  [Oracle/arm64](https://blogs.oracle.com/linux/exploring-arm64-runtime-patching-alternatives)).
  `apply_alternatives()` rewrites `.text` at boot based on CPU
  features. Production SMC in every Linux today. Could emit N
  seed-alternates of every hot syscall entry; pick at boot.

- **STATIC_CALL** (5.10+, [LWN](https://lwn.net/Articles/771209/),
  [yossarian.net](https://blog.yossarian.net/2020/12/16/Static-calls-in-Linux-5-10)).
  Patched direct calls replacing function pointers, originally for
  Spectre v2. Each call site is a natural hook for seed-derived
  per-call dispatch.

- **kpatch / kGraft / livepatch** (4.0+,
  [docs.kernel.org/livepatch](https://docs.kernel.org/livepatch/livepatch.html)).
  ftrace-based whole-function live replacement. For MTD: scheduled
  re-scrambling of selected functions at runtime — the *Container
  Cycler* Polyverse marketed but never shipped for the kernel
  (dossier 07 §3).

- **eBPF** ([ebpf.io](https://ebpf.io/what-is-ebpf/)). Runtime-loaded
  verified bytecode JIT-compiled to native. A seeded JIT could emit
  different native code per host for the same bytecode — raises the
  cost of weaponizing verifier bugs.

- **LD_AUDIT / DT_AUDIT** ([rtld-audit(7)](https://man7.org/linux/man-pages/man7/rtld-audit.7.html)).
  Per-process audit library intercepting every symbol resolution;
  `la_symbind*` may rewrite resolved addresses. A seeded `la_symbind`
  could resolve `printf` to one of N variants per invocation.

- **binfmt_misc** ([kernel docs](https://docs.kernel.org/admin-guide/binfmt-misc.html)).
  Magic-byte → interpreter mapping; trivially demands seed-derived
  prefixes (§5 idea 2).

- **vDSO** ([man7](https://man7.org/linux/man-pages/man7/vdso.7.html)).
  Per-process ELF the kernel injects; ASLR randomizes only its base.
  Nothing prevents per-build randomization of internal layout and
  symbol set.

**Linux already ships the machinery for runtime self-modification.**
Encrypted-linux v2 can carry seed state through these hooks without
inventing kernel infrastructure.

## 4. The MacOS/Windows analogy: orthogonal axes of difference

What makes a Windows exploit fail on macOS, mapped to whether Linux
can plausibly differ per-build. offlinemark's
[*Syscall ABI compatibility: Linux vs Windows/macOS*](https://offlinemark.com/syscall-abi-compatibility-linux-vs-windows-macos/)
captures the key point: *"macOS and Windows do not guarantee syscall
ABI stability, making cross-version exploits more fragile than on
Linux."*

| Axis | MacOS vs Windows | Linux per-build differentiable? | Cost |
|---|---|---|---|
| Syscall numbers + ABI | Mach trap negative ids vs Windows positive | **Yes** — encrypted-linux v1 | Low (already done) |
| Executable format | Mach-O LC_* commands vs PE COFF | **Yes** — extend ELF magic, e_ident[EI_OSABI], add seed-derived section names | Medium |
| Calling convention | System V AMD64 vs MS x64 | **Yes** — encrypted-linux v1 (GCC backend) | High (already done) |
| Dynamic linker | dyld vs ntdll/ldr | **Partially** — musl, swap LD_AUDIT, custom interp string | Low |
| C library | libSystem vs ucrt | **Yes** — musl rebuild + mangling | Medium |
| Filesystem semantics | HFS+/APFS vs NTFS | Partial — VFS namespace remap | Medium |
| Process model | task/thread Mach ports vs HANDLEs | No — both have `pid_t` task abstraction | n/a |
| Code signing / entitlements | AMFI / SIP vs Authenticode | Yes — IMA + ELF-note seed tag | Medium |
| Kernel architecture | XNU hybrid Mach vs NT hybrid | No (single kernel) | n/a |
| Pseudo-FS for introspection | sysctl + IORegistry vs Registry | **Yes** — `/proc` schema (§5 idea 4) | Medium |
| Endian / word | identical on amd64 / arm64 | n/a | n/a |
| Page size | 16K (Apple Silicon) vs 4K (Win) | **Yes** — boot-time selectable on arm64 ([LWN](https://lwn.net/Articles/993990/)) | Low |
| Error codes | mach_error_t vs NTSTATUS / HRESULT | **Yes** — errno permutation (§5 idea 6) | Low |

Of the things that make MacOS exploits fail on Windows, **at least
eight are achievable per-build on Linux.** Five of those are missing
from encrypted-linux v1. That's the gap.

## 5. Original ideas for additional Linux differentiation

These are sketched at the level of "could a competent kernel engineer
implement this in a quarter," with attacker-cost stories and tradeoffs.

### Idea 1 — Per-build ELF format extension (the "Mach-O move")

**What.** Choose per-build random `e_ident[EI_OSABI]` (256-valued,
mostly unassigned), a `PT_<random>` program-header in the
`PT_LOOS..PT_HIOS` range, and a `DT_<random>` dynamic tag in
`DT_LOOS..DT_HIOS`. Every host ELF carries a `PT_<random>` segment
holding HMAC(seed, build-id). Patch `binfmt_elf` to reject ELFs
lacking it with `ENOEXEC`.

**Attacker cost.** Stock attacker ELF (musl-built dropper, static
busybox, anything off a stock Ubuntu) fails at `execve` before any
syscall. Attacker needs seed *and* a build tool emitting the segment.
Orthogonal to calling-convention mangling (which only protects calls)
and syscall renumbering (which only protects after exec).

**Cost to us.** ~250 LoC across `binfmt_elf.c` and the linker. Breaks
external ELF tools (`readelf`, `gdb`, `perf`) unless rebuilt against
the seed; debug-time unmangling shim needed. **Cheap; high impact.**

### Idea 2 — Seed-derived binfmt_misc envelope

**What.** Register a `binfmt_misc` rule at boot demanding a per-build
16-byte magic prefix on every executable. Stub interpreter validates,
strips, hands off to ELF loader. File-format-level exec policy.

**Attacker cost.** Same shape as idea 1 at a different layer; defense
in depth.

**Cost to us.** Trivial; `binfmt_misc` already exists
([kernel docs](https://docs.kernel.org/admin-guide/binfmt-misc.html)).
**Cheap; medium impact.**

### Idea 3 — Per-process libc copy with permuted exports

**What.** Replace the shared `libc.so.6` mapping with a fresh
`libc-<PID>.so` per-exec — keep `.text` shared, but permute the symbol
table indirection per process so each process's `printf` resolves via
`printf__<HMAC(host_seed, PID)>`.

**Attacker cost.** Even full RE of the host libc doesn't yield a
cross-process gadget chain — universal-libc-chain becomes per-PID
chain generation.

**Cost to us.** `execve` path needs a mini-mangler; some GOT/PLT
per-process duplication (~tens of KB, not the full 30MB if `.text`
stays shared). **Medium effort; high impact.**

### Idea 4 — Per-build /proc schema

**What.** `/proc/[pid]/maps`, `/proc/[pid]/status`, `/proc/[pid]/stat`
have standardized field orderings every Linux post-exploitation tool
depends on. Rename per build: `VmRSS:` → `<seed-derived word>:`.
Reorder. Change the 52-field space-separated `stat` format. Ship a
per-build `procps-ng`.

**Attacker cost.** Every tool that scrapes `/proc` for fingerprinting,
process enumeration, or kASLR-defeat (via `[pid]/maps` libc base)
breaks. kallsyms-scrapers already lose to hidepid; this closes the
maps-scraping branch.

**Cost to us.** ~1000 LoC in `fs/proc/`. Breaks `ps`/`top`/`htop`,
container runtimes, monitoring agents unless rebuilt. **Medium effort;
high impact for post-exploitation.**

### Idea 5 — Per-build VFS path translation layer

**What.** Seeded path-permutation at the VFS level: a build dictionary
maps `/etc/shadow → /<hash1>/<hash2>`, `/bin/sh → ...`, applied at
`path_lookup`. Hardcoded-path attackers see `ENOENT`. Recovery requires
reading the path dictionary, which itself needs a path.

**Attacker cost.** Most metasploit modules (~99% with hardcoded paths)
and every `execve("/bin/sh", ...)` payload fail.

**Cost to us.** Either LSM hook in `path_lookup` (~2000 LoC) or a
stacked FS (~500 LoC, cleaner). Introspection / mount tooling /
namespaces all break. **High effort; very high impact.** Defer to v3.

### Idea 6 — Per-build errno permutation

**What.** POSIX requires *names* (EAGAIN, ENOENT) but the *numeric
values* are implementation-defined ([POSIX](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/errno.h.html)).
Linux pinned 1–133 to SUSv4 values for 30 years; nothing in the
standard requires this. Permute per-build via regenerated kernel and
libc headers.

**Attacker cost.** Every exploit primitive that branches on errno
fails. `if (errno == EAGAIN) retry` misbehaves. Most importantly,
**libc itself tests `errno` in dozens of places** — shellcode mixing
inline syscalls (raw negative-errno) with libc calls trips immediately.

**Cost to us.** ~50 lines of header generation. Every userspace must
rebuild against the same permutation — encrypted-linux already requires
this (dossier 06 §3). **Cheap; medium impact. Ship in v2.**

### Idea 7 — Per-build filesystem magic numbers

**What.** `EXT4_SUPER_MAGIC = 0xEF53`. `BTRFS_SUPER_MAGIC = 0x9123683E`.
`TMPFS_MAGIC = 0x01021994`. Returned via `statfs(2)`'s `f_type` —
canonical FS fingerprint for container-escape decisions. Permute.

**Attacker cost.** Container-escape that fingerprints `f_type` to
choose technique fails. Modest standalone; composes with idea 4.

**Cost to us.** Trivial; rebuild `mke2fs`, `btrfs-progs`, `findmnt`,
container runtimes. **Cheap; low-medium impact.**

### Idea 8 — Per-build kernel-userspace timing quanta

**What.** `HZ` (250 or 1000 default), `sysctl_sched_min_granularity_ns`
(3ms), `CLOCK_MONOTONIC` resolution — all tunable. Permute. Also:
per-build `getrandom()` rate-limit so randomness-exhaustion timing
fingerprints differ.

**Attacker cost.** Defeats a narrow but real class: timing-based
side-channel attacks (TaskShuffler addresses the same surface,
[IEEE](https://ieeexplore.ieee.org/document/7461362/)); cache-eviction
attacks; Spectre v2 harnesses calibrated to a specific HZ.

**Cost to us.** Already Kconfig knobs. Some RT apps may misbehave.
**Cheap; low-medium impact.**

### Idea 9 — Per-build vDSO symbol set and layout

**What.** vDSO exports a fixed set (`__vdso_clock_gettime`,
`__vdso_gettimeofday`, `__vdso_getcpu`, `__vdso_time`). Permute order,
add random padding, mangle names with host seed. Optionally include
*decoy* exports that segfault when called — shellcode resolving by
hash-comparison hits a tripwire.

**Attacker cost.** vDSO is the fast path for syscall-less timing
(critical for Spectre/Meltdown harnesses). Mangled exports + decoys
force per-host dynamic resolution.

**Cost to us.** Low; vDSO is already a per-kernel mini-ELF — modify
`arch/x86/entry/vdso/` Makefile. **Cheap; medium impact.**

### Idea 10 — Per-build kernel `task_struct` indirection

**What.** Every kernel privesc finds `current->cred` and overwrites
`cred->uid`. RANDSTRUCT permutes `task_struct` fields, but `current`
is a fixed-offset access (`gs:0` on x86_64). Replace direct `current`
deref with seed-derived indirection: `base[seed_index_table[per_cpu_id]]`,
where the table itself lives in a randstruct'd struct.

**Attacker cost.** Every kernel exploit primitive relying on `current`
resolution needs per-host RE. Composes well with kallsyms restriction.

**Cost to us.** `current` is the hottest possible path (every syscall,
every preempt). One added load indirection costs ~1–3%. **Hard; high
impact.** Defer to v3.

### Bonus ideas

- **Per-build inline-asm register scrubbing.** GCC `asm volatile` in
  kernel/glibc carries hard-coded register names; replace with
  seed-permuted macros so hand-written asm hot paths vary per-build.

- **Per-build `auxv` schema.** Permute `AT_PHDR`, `AT_BASE`, `AT_ENTRY`
  codes (subset of idea 1).

- **Per-build coredump format.** Stock `gdb` cannot mine an exfiltrated
  core dump.

- **Per-build loopback protocol numbers.** UDP/TCP numbers permuted on
  `lo` only; lateral-movement-within-host changes shape. Expensive
  because every TCP/IP app needs awareness.

## 6. Composition: stacking diversification axes

The crucial multi-axis argument: **bit budgets add when axes are
orthogonal.** ASLR alone gives ~20 bits of code-base entropy on amd64;
information leaks reduce this rapidly (the [USENIX CAIN paper](https://www.usenix.org/conference/woot15/workshop-program/presentation/barresi)
showed cloud-side derandomization in minutes; [Sleak ACSAC 2019](https://sites.cs.ucsb.edu/~vigna/publications/2019_ACSAC_Sleak.pdf)
automates it). RANDSTRUCT adds ~12–60 bits depending on struct.
Syscall permutation adds ~533 bits (log2(335!)). Calling-convention
permutation adds ~16 bits per scrambled function signature.

For independent axes the attacker faces a multiplicative search; for
correlated axes the leak of one axis informs the others. The design
target should be:

1. **No single information leak collapses more than one axis.** This
   means seed material should be derived per axis via HMAC(master_seed,
   axis_id) so that leaking one axis-key doesn't leak the master.
2. **Failure modes should be axes-independent.** A symbol-mangling
   mismatch should produce a different failure than an errno mismatch
   so an attacker can't conflate diagnostic information.
3. **Stack so the cheapest-to-verify axis fails first.** ELF format
   check (idea 1) at `execve` is microseconds; syscall renumber check
   is per-syscall. Fail at exec where possible.

Larsen et al.'s SoK warning about *"implementation-disclosure attacks"*
applies: every axis must be evaluated against what a single leak of
that axis reveals. The encrypted-linux mirror-distribution model
(dossier 07 §3) keeps the seed off the host, which is the strongest
mitigation: even arbitrary memory disclosure on the running host
reveals only the resulting binary, not the seed.

## 7. Limitations: what no amount of MTD can fix

This section is the price of intellectual honesty. The user is a
security researcher who already wrote (whitepaper p. 9): *"Our approach
is at best significantly stronger than running plain code, and at
worst introduces no additional vulnerabilities."* The honest
limitations of multi-axis MTD:

- **Logic bugs are unchanged.** A SQL-injectable app on encrypted-linux
  is just as SQL-injectable. MTD raises *exploit-primitive* cost, not
  *application-flaw* cost.

- **Data-only attacks survive.** Per the
  [USENIX login article](https://www.usenix.org/publications/loginonline/data-only-attacks-are-easier-you-think)
  and the [Hu et al. survey](https://arxiv.org/pdf/1902.08359), modern
  exploitation increasingly skips code injection and control-flow
  hijack entirely — it corrupts data structures (privilege flags, fds,
  type confusions) the program then misuses against itself. None of
  the ten ideas touches this class; CFI/kCFI/RAP is the orthogonal
  defense.

- **Information disclosure derandomizes.** Snow et al.
  [*Information Leaks Without Memory Disclosures*](https://www.researchgate.net/publication/280567953)
  (CCS 2015) and follow-ups show timing/cache side channels recover
  diversification keys remotely. MVX addresses this by aborting on
  divergence; encrypted-linux currently does not.

- **Below the diversification layer.** Spectre, Meltdown, MDS,
  Hertzbleed; firmware (BootHole, LogoFAIL); microcode; hypervisor
  escapes — none touched. Trusted Computing's failure (whitepaper's
  canonical example) applies here too.

- **Format-string / `eval`-class bugs.** `printf(user)` or `eval(user)`
  is exploitable regardless of runtime permutation — the runtime is
  *being told* to interpret attacker input as itself. (Whitepaper §III:
  Polyscripting is the answer; Polymorphic Linux is not.)

- **Build farm compromise.** The seed lives there. Polyverse's design
  kept *"per-VM seeds … not delivered to the VM"* (dossier 07 §3); same
  applies here. Build-farm compromise is the irreducible SPOF —
  classical supply-chain hardening (reproducible builds across a quorum,
  transparency logs, HSMs) is the only defense and is *orthogonal* to
  MTD.

- **Physical access.** Disk, memory, microarchitecture all readable.
  Nothing in this dossier helps.

- **Stock-Linux downgrade.** Polyverse shipped *"100% drop-in compliant
  with existing package repositories, so if Polymorphic Linux service
  goes down, the APK just defaults to standard Alpine repos upstream"*
  ([netdata#5034](https://github.com/netdata/netdata/issues/5034)).
  Great for availability, catastrophic for hardening. Encrypted-linux
  v2 must refuse downgrade — an ELF without the seed-tagged note simply
  fails (idea 1 enforces this).

- **MTD complicates; it does not detect.** Larsen et al. flag error
  reporting separately: crash-on-mismatch gives the attacker a free
  oracle; alert+quarantine turns crashes into intelligence. Every
  fail-fast axis should hook into `zerotect`-style telemetry
  ([polyverse/zerotect](https://github.com/polyverse/zerotect)) so
  diversification doubles as an intrusion sensor.

## 8. A practical roadmap: what to do first in encrypted-linux v2

Order by (impact / effort), highest first. Tractable in the next
research cycle:

1. **Idea 6 — errno permutation.** ~50 LoC header generation, real
   defensive value, breaks nothing if the closure-of-build invariant
   already holds. **Ship in v2.**
2. **Idea 1 — ELF format extension.** ~250 LoC across `binfmt_elf` and
   the linker. The Mach-O move. **Ship in v2.**
3. **Idea 9 — vDSO mangling.** ~100 LoC in `arch/x86/entry/vdso/`.
   Composes cleanly with v1 symbol mangling. **Ship in v2.**
4. **Idea 7 — filesystem magic numbers.** ~30 LoC. Free win.
5. **Idea 8 — HZ + scheduler quanta.** Kconfig knobs already exist.
6. **Idea 4 — /proc schema permutation.** ~1000 LoC; defer to v2.1.
7. **Idea 3 — per-process libc.** Significant memory cost; defer to v3.
8. **Idea 5 — VFS path translation.** Highest impact, hardest engineering;
   v3 or research project.
9. **Idea 10 — `task_struct` indirection.** Hot-path cost; v3, gated on
   performance budget.

The cumulative effect of axes 1–5 above is roughly: **a stock attacker's
shellcode payload fails at `execve` (idea 1), again at the magic-bytes
binfmt check (idea 2), again at first syscall (encrypted-linux v1
syscall renumbering), again at first errno-dependent branch (idea 6),
again at first vDSO call (idea 9).** Each independent failure mode is
a separate piece of attacker reverse-engineering work.

That is the multi-axis story. Not "MacOS vs Windows" yet — encrypted-
linux is still recognizably Linux at the VFS level, the process-model
level, and the kernel-architecture level — but along enough orthogonal
dimensions that "download a kit, run it" becomes "study the host for
a week, build a custom kit, deploy it, and hope no axis has been
re-seeded in the meantime."

## Sources

- [Larsen, Homescu, Brunthaler, Franz — SoK: Automated Software Diversity (IEEE S&P 2014)](https://oaklandsok.github.io/papers/larsen2014.pdf)
- [Kc, Keromytis, Prevelakis — Countering code-injection attacks with instruction-set randomization (CCS 2003)](https://www.semanticscholar.org/paper/3d06bc310afc5ca8b04930a03514d1430a87ec37)
- [Hu et al. — Fast and practical instruction-set randomization (ACSAC 2010)](https://dl.acm.org/doi/10.1145/1920261.1920268)
- [Bhatkar, DuVarney, Sekar — Address Obfuscation (USENIX Security 2003)](https://www.usenix.org/legacy/event/sec03/tech/full_papers/bhatkar/bhatkar.pdf)
- [Chen et al. — A System Call Randomization Based Method](https://www.mecs-press.org/ijitcs/ijitcs-v1-n1/v1n1-1.html)
- [MTD: Run-time System Call Mapping Randomization (IEEE 2021)](https://ieeexplore.ieee.org/document/9644278)
- [PaXTeam — PaX kernel self-protection (H2HC12)](https://pax.grsecurity.net/docs/PaXTeam-H2HC12-PaX-kernel-self-protection.pdf)
- [PaXTeam — RAP: RIP ROP (H2HC15)](https://pax.grsecurity.net/docs/PaXTeam-H2HC15-RAP-RIP-ROP.pdf)
- [grsecurity — RAP announcement](https://grsecurity.net/rap_announce_full)
- [grsecurity — RAP FAQ](https://grsecurity.net/rap_faq)
- [hardenedlinux — Linux kernel mitigation checklist](https://hardenedlinux.github.io/system-security/2016/12/13/kernel_mitigation_checklist.html)
- [Cox et al. — N-Variant Systems (USENIX 2006)](https://www.cs.virginia.edu/~evans/pubs/usenix06/)
- [Salamat et al. — Orchestra (EuroSys 2009)](https://dl.acm.org/doi/10.1145/1519065.1519071)
- [ReMon — VUSec DSN 2016](https://download.vusec.net/papers/dsn-2016.pdf)
- [MvArmor on GitHub](https://github.com/vusec/mvarmor)
- [kMVX (ASPLOS 2019)](https://dl.acm.org/doi/10.1145/3297858.3304054)
- [sMVX (Middleware 2024)](https://dl.acm.org/doi/10.1145/3652892.3654794)
- [DARPA CFAR program page](https://www.darpa.mil/research/programs/cyber-fault-tolerant-attack-recovery)
- [Trail of Bits — CFAR program writeup](https://www.trailofbits.com/services/published-research/cyber-fault-tolerant-attack-recovery-cfar/)
- [Trail of Bits blog — Protecting Software Against Exploitation with CFAR (2018)](https://blog.trailofbits.com/2018/09/10/protecting-software-against-exploitation-with-darpas-cfar/)
- [Weimer, Forrest — RAVEN: Double Helix paper (CISR 2016 PDF)](https://web.eecs.umich.edu/~weimerw/p/weimer-cisr2016.pdf)
- [Chow, Eisen, Johnson, van Oorschot — White-Box AES tutorial (eprint 2013/104)](https://eprint.iacr.org/2013/104.pdf)
- [Revisiting the BGE Attack on a White-Box AES Implementation (eprint 2013/450)](https://eprint.iacr.org/2013/450)
- [White-box cryptography — Wikipedia](https://en.wikipedia.org/wiki/White-box_cryptography)
- [Oreans — Themida overview](https://www.oreans.com/Themida.php)
- [Unprotect — Themida technique](https://unprotect.it/technique/themida/)
- [Suk — UnThemida (Software: Practice and Experience 2018)](https://onlinelibrary.wiley.com/doi/abs/10.1002/spe.2622)
- [Blazytko et al. — Syntia: Breaking State-of-the-Art Binary Obfuscation (Black Hat Asia 2018 WP)](https://i.blackhat.com/briefings/asia/2018/asia-18-Blazytko-Breaking-State-Of-The-Art-Binary-Code-Obfuscation-Via-Program-Synthesis-wp.pdf)
- [LWN — SMP alternatives (2005)](https://lwn.net/Articles/164121/)
- [Oracle blog — ARM64 runtime patching alternatives](https://blogs.oracle.com/linux/exploring-arm64-runtime-patching-alternatives)
- [torvalds/linux — arch/x86/kernel/alternative.c](https://github.com/torvalds/linux/blob/master/arch/x86/kernel/alternative.c)
- [LWN — Static calls](https://lwn.net/Articles/771209/)
- [yossarian.net — Static calls in Linux 5.10](https://blog.yossarian.net/2020/12/16/Static-calls-in-Linux-5-10)
- [docs.kernel.org — Livepatch](https://docs.kernel.org/livepatch/livepatch.html)
- [kpatch — Wikipedia](https://en.wikipedia.org/wiki/Kpatch)
- [kGraft — Wikipedia](https://en.wikipedia.org/wiki/KGraft)
- [ebpf.io — What is eBPF?](https://ebpf.io/what-is-ebpf/)
- [docs.kernel.org — eBPF verifier](https://docs.kernel.org/bpf/verifier.html)
- [man7.org — rtld-audit(7)](https://man7.org/linux/man-pages/man7/rtld-audit.7.html)
- [VanessaSaurus — rtld-audit and LD_AUDIT](https://vsoch.github.io/2021/ldaudit/)
- [Oracle — Runtime Linker Auditing Interface](https://docs.oracle.com/cd/E23824_01/html/819-0690/chapter6-1242.html)
- [binfmt_misc — Wikipedia](https://en.wikipedia.org/wiki/Binfmt_misc)
- [kernel.org — binfmt_misc admin guide](https://docs.kernel.org/admin-guide/binfmt-misc.html)
- [man7.org — vdso(7)](https://man7.org/linux/man-pages/man7/vdso.7.html)
- [LWN — On vsyscalls and the vDSO](https://lwn.net/Articles/446528/)
- [offlinemark — Syscall ABI compatibility: Linux vs Windows/macOS](https://offlinemark.com/syscall-abi-compatibility-linux-vs-windows-macos/)
- [XNU — Wikipedia](https://en.wikipedia.org/wiki/XNU)
- [Elastic — macOS vs Windows kernels for endpoint security](https://www.elastic.co/blog/macos-windows-what-kernels-tell-you-about-security-events-part-1)
- [POSIX errno.h](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/errno.h.html)
- [man7.org — errno(3)](https://man7.org/linux/man-pages/man3/errno.3.html)
- [LWN — Boot-time page size selection for arm64](https://lwn.net/Articles/993990/)
- [Ampere — Memory page sizes on Arm64](https://amperecomputing.com/tuning-guides/understanding-memory-page-sizes-on-arm64)
- [man7.org — proc(5)](https://man7.org/linux/man-pages/man5/proc.5.html)
- [docs.kernel.org — /proc filesystem](https://docs.kernel.org/filesystems/proc.html)
- [Snow et al. — Information Leaks Without Memory Disclosures (CCS 2015)](https://www.researchgate.net/publication/280567953_Information_Leaks_Without_Memory_Disclosures_Remote_Side_Channel_Attacks_on_Diversified_Code)
- [Sleak — Automating ASLR derandomization (ACSAC 2019)](https://sites.cs.ucsb.edu/~vigna/publications/2019_ACSAC_Sleak.pdf)
- [Barresi et al. — CAIN: Silently Breaking ASLR in the Cloud (WOOT 2015)](https://www.usenix.org/conference/woot15/workshop-program/presentation/barresi)
- [Hu et al. — Exploitation Techniques and Defenses for Data-Oriented Attacks](https://arxiv.org/pdf/1902.08359)
- [USENIX login — Data-Only Attacks Are Easier than You Think](https://www.usenix.org/publications/loginonline/data-only-attacks-are-easier-you-think)
- [TaskShuffler — IEEE 2016](https://ieeexplore.ieee.org/document/7461362/)
- [MDPI — A Survey on Moving Target Defense (2023)](https://www.mdpi.com/2076-3417/13/9/5367)
- [polyverse/zerotect](https://github.com/polyverse/zerotect)
- [netdata #5034 — Introduce Polymorphic Linux in Docker](https://github.com/netdata/netdata/issues/5034)
