# encrypted-linux — Current State

**Last updated:** 2026-05-11
**Phase:** Research → about to enter Plan-of-Action authoring.

## What's done

Six parallel research agents completed dossiers (all in `research/`):

1. `research/01-encrypted-execution-thesis.md` — The Encrypted Execution
   paper (Gore 2025). Core thesis, threat model, closure framing, prior art
   it cites (randstruct, FG-ASLR, ISR). Key fact: the paper explicitly names
   the encrypted-linux extreme on p. 10 (`<compiler-codegen-backend, ISA>`
   pairs). Patent USPTO 10,733,303 is pledged to the public domain.

2. `research/02-php-scrambler-lessons.md` — How the PHP scrambler at
   `/Users/archisgore/github/encrypted-execution/php-v2/` actually works.
   Edits `zend_language_scanner.l` and `zend_language_parser.y`, regenerates
   re2c/bison, incremental `make` (~30s). Dictionary at
   `/var/lib/encrypted-execution/token-map.json` is the closure key. Key
   lessons for C/GCC: modify grammar source not bytecode; closure must close
   at build time; tokenize with the same engine that executes; fail-closed
   at parse/load.

3. `research/03-randstruct-prior-art.md` — Linux randstruct GCC plugin at
   `scripts/gcc-plugins/randomize_layout_plugin.c`. Hooks `PLUGIN_FINISH_TYPE`
   before `finalize_type_size`. Seed at `scripts/gcc-plugins/randstruct.seed`,
   baked into plugin binary. Survives `make clean`, not `make mrproper`.
   Randstruct **does NOT scramble calling conventions** — only struct field
   order — because calling conventions are *external by definition* (they
   exist to glue independently compiled code). That is precisely the gap
   encrypted-linux must fill.

4. `research/04-gcc-calling-convention-internals.md` — Where in GCC the
   SysV AMD64 psABI lives: `gcc/config/i386/i386.cc` (`ix86_function_arg`,
   `ix86_function_arg_advance`, `ix86_function_value`, `ix86_return_in_memory`,
   `ix86_compute_frame_layout`, prologue/epilogue, varargs). The clean
   integration point is GCC's existing `ms_abi`/`sysv_abi` dual-ABI
   infrastructure — add a third ABI variant parameterized by seed. DWARF
   CFI is data-driven, so unwinding/C++ EH come for free if prologue notes
   are emitted correctly. Hard parts: libgcc, glibc `setjmp.S`, glibc
   `dl-trampoline.S`, varargs save-area layout, libffi, JITs (V8/LuaJIT),
   inline asm in glibc/OpenSSL/kernel. Kernel syscall ABI is a clean
   boundary (defined by kernel, not user-space C ABI).

5. `research/05-distro-bootstrap-options.md` — **Recommendation: fork
   Buildroot, target musl + BusyBox + static-only, modeled on Oasis/Stali.**
   Five binaries total (kernel + musl + busybox + init + demo). Slackware
   is the wrong choice (too big, glibc-bound, dynamic). Disable GCC
   3-stage bootstrap (`--disable-bootstrap`) for PoC. Treat scramble seed
   as `SOURCE_DATE_EPOCH`-equivalent for determinism. Defer Guix/Mes
   full-source bootstrap to v2 trust story.

6. `research/06-dynamic-linking-and-threat-model.md` — Honest threat model.
   **Symbol-name mangling is the load-bearing piece** that converts silent
   ABI mismatches into deterministic load-time errors. Precedent already
   shipping: kernel `modversions` CRC, glibc symbol versioning, C++
   Itanium mangling. ROP gadgets still exist but their semantics shift —
   `pop %rdi; ret` no longer means "load arg1." This is a moving-target /
   unique-target defense, **not** a confidentiality defense — a single
   target binary reveals the convention. Defends against blind/universal
   exploits and forces attacker to possess the compiler. Stacks cleanly
   with kCFI/FineIBT/Secure Boot. Phase 2 syscall renumbering has clear
   research prior art (Chen/Pande/Ramachandran; ISR by Kc/Keromytis) but
   **no mainline implementation found** — encrypted-linux as scoped is
   novel as a productized distro.

## What's queued next (high priority)

**The user added a follow-up research item right before asking us to save state:**

> "Also go through all the polyverse documents and anything you can find on
> Polymorphic Linux or Polyscripting. To add to your research."

This is **research/07-polyverse-polymorphic-linux.md** — NOT YET WRITTEN.
The agent that resumes must do this first. Specifically search:

- The author's own historical work at Polyverse Corporation (the paper's
  copyright holder).
- "Polymorphic Linux" — Polyverse's commercial product (~2017–2020). Public
  blog posts, GitHub orgs (`Polyverse-Security`, `polyverse`,
  `polyverse-research`), white papers, recorded talks (DEF CON, BlackHat,
  RSA, OSCON).
- "Polyscripting" as a Polyverse trademark / product line — find their
  whitepapers, slide decks, blog posts on RubyGems, npm, WordPress, PHP
  scrambling commercializations.
- Patents assigned to Polyverse beyond USPTO 10,733,303. Search USPTO and
  Google Patents for "Polyverse Corporation" assignee.
- Academic papers citing Polymorphic Linux (Google Scholar, IEEE, ACM).

Why this matters: Polymorphic Linux was the commercial precursor that
randomized symbol names across **every binary in the distro**, distributed
nightly. Lessons learned there — what worked, what hit production walls,
what they did about glibc and the kernel, why the company pivoted — are
directly applicable. The PHP scrambler we already studied is the
educational descendant; Polymorphic Linux is the production ancestor.

Write that dossier (≤1800 words, with URLs and direct quotes) before
authoring `plan/`.

## What's queued after that

Author the phased plan in `plan/`:

- `plan/00-design-principles.md` — closure, determinism, fail-closed,
  symbol mangling as detection surface, what we explicitly do NOT scramble
  (UAPI structs, syscall ABI in Phase 1, the build-system contract).
- `plan/01-phase1-userland-scrambling.md` — milestones, smallest PoC,
  exit criteria.
- `plan/02-phase2-kernel-scrambling.md` — syscall renumbering,
  kernel-internal ABI scrambling, module ABI tying.
- `plan/03-risks-and-honest-limitations.md` — copy of §3–6 from
  `research/06`, expanded to acknowledge: not a confidentiality boundary,
  seed extractable from any on-disk binary, doesn't stop data-only or
  logic-bug attacks, supply-chain attack on the build farm owns the seed.
- `plan/04-smallest-proof-of-concept.md` — five-binary Buildroot PoC,
  `qemu-system-x86_64` demo, exit criterion: stock-built `hello` either
  fails to load (`undefined symbol`) or SIGILLs at the first scrambled
  call, while the encrypted-linux-built `hello` runs cleanly.

## Reproducing the research

Each agent's full transcript is summarized in its dossier file. The
agents are still addressable by ID for follow-up questions:

- `a4e3c9e89771c4596` — Encrypted Execution paper
- `ae59942b4d6ed20cf` — PHP scrambler codebase
- `ac7775d1cfc1cb697` — randstruct prior art
- `aa05eb3d7a245f4a4` — GCC calling convention internals
- `a3639813e3e0a1c3a` — distro bootstrap options
- `a7748a7cc227b94e2` — dynamic linking / threat model

(Agent IDs may have expired by the time work resumes; treat as
"who to re-spawn with this dossier as context" rather than "send a
message to.")

## Open questions to bring to the user before writing code

1. **Buildroot vs LFS vs custom build harness** — research recommends
   Buildroot strongly. Confirm before writing build scripts.
2. **musl vs glibc** — research recommends musl strongly. Confirm.
3. **Static-only vs dynamic** — research recommends static-only for PoC,
   noting that this means Phase 1 doesn't actually break dynamic linking
   (because there is none). If demonstrating *broken dynamic linking* is
   the headline, we need at least one dynamic library in the PoC. Ask the
   user whether the demo is "static binaries with mangled syscalls/symbols
   fail" or "stock .so won't load into scrambled binary."
4. **Stage1 bootstrap discipline** — for the PoC, run the scrambling GCC
   from a stock host GCC build (no self-hosting). For v2, do we want
   self-hosting + Mes full-source bootstrap? This is the trust story.
5. **License** — Apache-2.0 confirmed?
6. **Repo visibility** — public on GitHub under
   `github.com/encrypted-execution/encrypted-linux`?
