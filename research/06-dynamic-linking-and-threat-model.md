# Research Dossier 06 — Dynamic Linking & Honest Threat Model

## 1. Dynamic linking on Linux — where mismatch can fail safely

A `printf()` call from a dynamically-linked binary touches:

- **`.dynsym` / `.dynstr`** — dynamic symbol table & string heap. Each
  entry names an external symbol by string offset and carries an index into
  `.gnu.version_r`.
- **`.rela.plt`** — relocations for function calls; one per imported function
  symbol; resolved lazily.
- **`.rela.dyn`** — relocations for data references; usually resolved eagerly.
- **PLT** — small trampoline per imported function. First instruction
  `jmp *GOT[n]`. On first call, GOT slot still points back into PLT, which
  pushes a relocation index and jumps to `_dl_runtime_resolve`.
- **GOT** — writable table of resolved addresses. After first call, `GOT[n]`
  is patched to point directly at the resolved function.
- **`ld.so` resolver** — `_dl_runtime_resolve` (asm stub) saves caller-saved
  registers, calls `_dl_fixup`, which walks the link map (objects loaded via
  `DT_NEEDED`), looks up the symbol in each `.dynsym`, validates
  `.gnu.version_r` requirements against `.gnu.version_d`, and writes the
  result into the GOT.
- **`DT_NEEDED`** — "this binary requires libc.so.6, libpthread.so.0…"
- **Search order:** `DT_RPATH` (legacy, transitive) → `LD_LIBRARY_PATH` →
  `DT_RUNPATH` (only direct deps) → `/etc/ld.so.cache` → `/lib`,
  `/usr/lib`. `LD_PRELOAD` inserted *before* `DT_NEEDED`.
- **Eager vs lazy:** `LD_BIND_NOW=1` or `-z now` forces eager. RELRO +
  BIND_NOW also makes GOT read-only after load.

**Where mismatch can fail safely:** the only points where a mismatch is
*named and checked* are (a) symbol lookup in `_dl_fixup`, and (b) version
requirement matching against `.gnu.version_r`. Once the GOT is patched and
control jumps, nothing checks the convention — caller pushes args in one
order, callee reads them in another, silent corruption (most likely a
SIGSEGV via garbage pointer where an int was expected). **To fail safely,
the mismatch must surface at the symbol-name layer, before the jump.** That
points squarely at section 2.

Refs: [MaskRay — All about PLT](https://maskray.me/blog/2021-09-19-all-about-procedure-linkage-table),
[ld.so(8)](https://man7.org/linux/man-pages/man8/ld.so.8.html).

## 2. Symbol mangling as the failure surface

Mangling every C function name with a hash of the calling-convention seed
(`printf` → `printf__abi_<hash>`) routes every mismatch through the dynamic
linker check that already produces `undefined symbol: printf__abi_<hash>` —
a clean load-time abort rather than a runtime crash.

**Precedent:**

- **C++ Itanium ABI mangling** — every function's full type signature is
  encoded in its symbol name precisely so a caller compiled against one
  signature cannot accidentally link to a different signature with the same
  source name. Encrypted-Linux mangling is a stripped-down version applied
  to C, with the "signature" being a calling-convention seed instead of
  argument types. [Itanium ABI](https://itanium-cxx-abi.github.io/cxx-abi/abi.html).
- **glibc symbol versioning** (`GLIBC_2.x`) — Sun-originated, extended by
  GNU. `.gnu.version_d` in libc declares versioned symbol nodes;
  `.gnu.version_r` in the binary declares required versions. `_dl_fixup`
  enforces match. Essentially mangling-by-side-table.
  [MaskRay](https://maskray.me/blog/2020-11-26-all-about-symbol-versioning),
  [Red Hat developers](https://developers.redhat.com/blog/2019/08/01/how-the-gnu-c-library-handles-backward-compatibility).
- **Solaris symbol versioning** — Sun introduced in SVR4 ELF. Modern Solaris
  deprecated weak symbols as "fragile" and moved to direct bindings. Lesson:
  name-based binding contracts work; binding-by-fallback does not.
- **Kernel `modversions`** — already mangles every exported kernel symbol
  with a CRC32 of its full type prototype. `printk` becomes `printk_R<crc>`
  in the module's symbol table; mismatched modules rejected at `insmod`.
  **This is the exact precedent we want, already shipping in mainline.**
  [LWN](https://lwn.net/Articles/707520/),
  [kernel.org gendwarfksyms](https://www.kernel.org/doc/html/latest/kbuild/gendwarfksyms.html).

**Verdict:** mangling is the right detection surface. Mangle every external
symbol with HMAC(seed, symbol_name || signature). Don't mangle
internal/static functions — they don't cross the ABI boundary.

## 3. Phase 1 threat model (userland only)

- **LD_PRELOAD a malicious stock-built .so.** Attacker's library exports
  `printf`, but the victim's `.rela.plt` references `printf__abi_<hash>`.
  Preloaded library does not define that symbol, so `_dl_fixup` falls
  through to the next object — the real (scrambled) libc.
  **Cleanly defeated**; attacker can't fix without the compiler.
- **Stock ELF on the box.** Kernel happily `execve`s (Phase 1 doesn't touch
  the kernel). Runs until first `printf` call, at which `_dl_fixup` cannot
  find `printf__abi_<correct_hash>` in libc.so.6 and aborts with "undefined
  symbol." Eager failure at first dynamic call. **If statically linked, it
  executes fine until it issues a syscall — but its syscalls use the
  standard ABI, so they work. Phase 1 does not stop static binaries**; a
  known gap, addressed in Phase 2.
- **ROP against scrambled libc.** Gadgets are byte sequences inside
  scrambled libc. `5f c3` (`pop rdi; ret`) is still present and still pops
  into `rdi`. What *changes* is the meaning: if argument 1 lives in `r8`
  under the scrambled convention, `pop rdi; ret` no longer prepares the
  first argument to functions inside this libc. Attackers must rewrite
  gadget chains to target whichever register the scrambled ABI uses for
  argument 1. They can do this *if* they have the scrambled libc binary —
  argument-register assignment is recoverable in seconds from any function
  prologue (§6). **Scrambling raises the cost of a published universal ROP
  chain from "download" to "per-target chain generation," but does not
  eliminate ROP.** ROPfuscator and Marlin literature treat per-binary
  diversification as *delay* against generic exploits, not a fundamental
  block. [Marlin](https://w3.cs.jmu.edu/kirkpams/papers/nss13-marlin.pdf),
  [Carlini & Wagner — "ROP is Still Dangerous"](https://people.eecs.berkeley.edu/~daw/papers/rop-usenix14.pdf).
- **Reverse-engineering scrambled libc.** A motivated attacker with one
  copy recovers the seed trivially. **Defense's strength is not secrecy
  but per-system uniqueness plus possession of the build toolchain.** Honest
  framing: closer to instruction-set randomization (Kc & Keromytis) and
  compiler-driven software diversity (Larsen et al. — "SoK: Automated
  Software Diversity") than to cryptographic protection. Defends against
  *blind* attacks lacking a target binary; does not defend against an
  attacker who can read the target's files.

## 4. Phase 2 threat model (kernel)

- **Syscall renumbering.** Reassign syscall numbers per-build. Seed must
  reach glibc's syscall stubs (`sysdep.h`). Natural channel: the kernel
  headers emit a generated `asm/unistd_seeded.h` glibc consumes during its
  build, deriving syscall numbers via a keyed PRF of the canonical name.
  The seed never needs to be a runtime secret; just needs to be the same
  across kernel + glibc builds for that system. A user-supplied static
  binary built against stock `unistd.h` issues `mov eax, 0; syscall` for
  what it thinks is `read`; the kernel's syscall table sees opcode 0
  mapped to something else (or unmapped → `-ENOSYS`). **Closes the
  static-binary gap from §3.**
- **Kernel-internal calling conventions.** On i386 `regparm(3)` already
  used kernel-wide. On x86-64 stricter caller/callee-saved discipline.
  Per-build randomization is a compiler-attribute change (a custom GCC
  plugin sets regparm / pass-by-reg variants). Invasive: every inline-asm
  block in the kernel referencing register names by hand has to be
  regenerated. Win against kernel ROP same as §3: gadgets exist, but `pop
  %rdi; ret` no longer means "load arg1." Effective against pre-canned
  exploits, weak against on-target chain generation.
- **kCFI / FineIBT overlap.** kCFI (Clang, Linux 6.1+) checks an integer
  type-hash at every indirect call site against the hash placed
  immediately before each function's `endbr`
  ([LWN 893164](https://lwn.net/Articles/893164/),
  [Clang CFI docs](https://clang.llvm.org/docs/ControlFlowIntegrity.html)).
  FineIBT folds that check into the CET `endbr` prologue with hardware
  enforcement ([FineIBT — ACM](https://dl.acm.org/doi/fullHtml/10.1145/3607199.3607219)).
  Both restrict indirect *call targets*. Calling-convention scrambling
  restricts *gadget semantics* and *ABI compatibility*. **They stack:**
  kCFI/FineIBT say "this indirect call can only land at functions of this
  type"; scrambling says "even if you reach a function, your register
  setup is wrong."
- **Loadable modules + `EXPORT_SYMBOL`.** Already mangle-checked via
  `modversions` CRC. Folding the calling-convention seed into the
  modversions CRC formula is a **one-line change**: existing kABI
  machinery (`Module.symvers`, genksyms/gendwarfksyms) already rejects
  mismatched modules at `insmod`. Externally built modules cannot load —
  desired behavior, mirrors SUSE/RHEL kABI shipping discipline.

## 5. Position on the defense-in-depth ladder

| Layer | Mechanism | Relationship |
|---|---|---|
| Policy | SELinux, AppArmor | Orthogonal |
| Memory hygiene | W^X, PIE, ASLR, FORTIFY_SOURCE, stack canaries | Orthogonal |
| Control flow | kCFI, FineIBT, IBT, shadow stack | Overlapping at call sites; complementary on ABI |
| Code identity | Secure Boot, IMA, dm-verity | Complementary — prevents booting non-scrambled images |
| eBPF | verifier, signed programs | If eBPF helpers scrambled too, JIT'd programs need per-target regen |
| **Encrypted-Linux** | **ABI scrambling + symbol mangling** | **New layer** |

**Does not protect against:**
- Logic bugs (authn bypass, TOCTOU, command injection) — program runs with
  full intended privilege.
- Data-only / non-control-data attacks (Chen et al., USENIX 2005) — corrupt
  a uid_t or config pointer; no ABI crossed.
- Memory disclosure recovering the seed from any on-disk binary.
- Supply-chain compromise of the scrambled toolchain — owning the build
  farm owns the seed.
- Attacks expressed entirely as valid scrambled-ABI code (attacker has compiler).

## 6. Seed extraction

Argument-register assignment is recoverable from a single function with
two-plus parameters by disassembling the prologue: arguments live in
callee-readable registers before any local computation. With ~10 functions
you typically pin down the full 6-register permutation; with `objdump -d
/lib/libc.so.6` you have unlimited samples. **If scrambling is only a
permutation, the seed is effectively public per-target.**

Stronger variants — per-function shim instructions, varying which registers
are caller-saved, mangling stack-slot layouts — raise the cost but never to
cryptographic levels because the convention must be *executable*, i.e.,
recoverable by the CPU. ISR literature has the same conclusion: once the
attacker has the encrypted text and any oracle, the key falls (Sovarel &
Evans-style attacks on ISR).

**Honest framing: scrambling is a moving-target / unique-target defense,
not a confidentiality defense.** Real value:
(a) breaking universal pre-canned exploits and worms,
(b) raising the bar to "must own the compiler to ship new code,"
(c) routing all incompatibilities through clean load-time failures instead
of UB.

## 7. Prior implementations of scrambled syscall numbers

**No mainline Linux implementation found.** No widely deployed research
kernel actually renumbers syscalls per-build. Closest literature:

- **Chen, Pande, Ramachandran — "Against Code Injection with System Call
  Randomization"** [IEEE](https://ieeexplore.ieee.org/document/4908334/) —
  proposes randomizing syscall numbers at kernel and libc together.
  Research prototype.
- **Jiang, Wang et al. — IJITCS "A System Call Randomization Based Method"**
  [mecs-press](https://www.mecs-press.org/ijitcs/ijitcs-v1-n1/IJITCS-V1-N1-1.pdf).
- **Xu, Kalbarczyk, Iyer — "Transparent Runtime Randomization"**
  [Illinois](https://experts.illinois.edu/en/publications/transparent-runtime-randomization-for-security/)
  — memory layout, not syscall numbers.
- **Kc, Keromytis, Prevelakis — Instruction-Set Randomization**
  [CCS 2003](https://www.cs.columbia.edu/~angelos/Papers/2009/general-isr.pdf)
  — foundational; encrypts opcodes, not syscalls, but identical threat
  model.
- **Bhatkar, DuVarney, Sekar — "Address Obfuscation"**
  [USENIX 2003](https://www.usenix.org/legacy/event/sec03/tech/full_papers/bhatkar/bhatkar.pdf)
  — complementary.
- **Kennell & Jamieson — "Genuinity"**
  [USENIX 2003](https://www.usenix.org/conference/12th-usenix-security-symposium/establishing-genuinity-remote-computer-systems)
  — uses unique-per-machine computation as remote attestation primitive;
  related (attacker can't simulate without target quirks) but solves
  attestation, not local exploitation.
- **Larsen et al. — "SoK: Automated Software Diversity"**
  [ICS UCI](https://ics.uci.edu/~perl/automated_software_diversity.pdf) —
  canonical survey; treats per-build calling-convention diversification
  under "internal interface randomization"; notes underexplored relative to
  ASLR and ISR.

**Encrypted-linux as scoped (compiler-driven full-ABI scrambling + symbol
mangling + syscall renumbering, productized as a distro) has not been
built.** Components exist as research prototypes; the integration is novel.

## Bottom line

The design is sound *as a diversity defense* and stacks cleanly on top of
kCFI/FineIBT/Secure Boot. Symbol-name mangling is the load-bearing piece:
converts otherwise-silent ABI mismatches into deterministic load-time
errors, reusing infrastructure (`modversions`, glibc symbol versioning,
C++ Itanium mangling) already in mainline. Phase 2 syscall renumbering
closes the static-binary gap and has clear research prior art but no
mainline implementation.

**It is not a confidentiality boundary, and should not be marketed as one.**
Will not stop data-only attacks, logic bugs, or attackers who own the build
toolchain. Where it shines: breaking the economics of mass exploitation —
every target gets a unique ABI, universal exploits stop working, attacker
must possess the compiler to ship working payloads.
