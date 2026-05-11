# Research Dossier 01 — Encrypted Execution Thesis

**Primary source:** https://www.encrypted-execution.com → `whitepaper.pdf`
("Encrypted Execution Whitepaper - 07/27/2025", 11 pages, Archis Gore,
archis@encrypted-execution.com).
**Reference implementations:** `/Users/archisgore/github/encrypted-execution/php/`
and `/php-v2/` (READMEs, SYMBOL_SCRAMBLING.md, SYMBOL_SCRAMBLING_ANALYSIS.md).

The landing page is a one-line marketing stub; substance is in the PDF.

## 1. Core thesis

**Eliminate the need for decryption.** Gore frames every classical defense
(signatures, Trusted Computing, code signing) as broken by the fact that
encrypted/signed code must be decrypted/verified before execution — opening
three windows: sign-time hijack, verifier hijack, post-verification injection.
Encrypted Execution sidesteps this by **encrypting the runtime itself** so the
encrypted form *is* the executable form — analogous to Navajo Code Talkers,
or to homomorphic encryption applied to code rather than data.

> "This paper proposes Encrypted Execution, a methodology to produce infinite
> matched pairs of encrypted execution runtimes and encrypted code, without
> incurring runtime performance penalties, allowing each instance to be made
> unique." (p. 2)

> "Encrypted Execution is the code equivalent of homomorphic encryption." (p. 4)

Foundational premise: **"all execution runtimes are Languages, and there can
be an infinite number of languages to represent the same semantics"** (p. 2).
Generate fresh language E per system, transform program LP → EP; only the
matched pair (EP, E) produces correct execution. Same Big-O complexity (RDP
stays RDP, LL stays LL, etc., p. 8).

The Klingon-PHP analogy (p. 3) is the load-bearing intuition: a Klingon-syntax
PHP runtime works fine for natives but breaks any visitor's input immediately.

## 2. Threat model

The paper enumerates three vectors that decryption-before-execution exposes
(pp. 1–2):

1. **Hijacking encryption/signing (supply chain)** — SolarWinds.
2. **Hijacking the decryption/verification mechanism** — BootHole ("the
   canonical vulnerability that broke all Trusted/Secure Computing").
3. **Post-verification injection** — "the simplest and most common of all
   exploits ... analogous to simply screen-recording a DRM-protected
   movie AKA 'The Analog Loophole'." Examples: PHP code injection in
   WordPress, cross-origin JS, `eval()` of fetched code.

EE is positioned against OWASP Top 10 Code Injection (#1 for 15+ years) and
Software/Data Integrity Failures.

**Explicit non-goals / failure modes** (p. 9, §VII):
- Stolen encryption key → fails (true of any encryption).
- Authorized-but-buggy/malicious code → "an Encrypted Execution Malware is
  still Malware."
- Given infinite compute/examples, any encryption breaks.

**Attacker context:** Best case attacker has the encrypted runtime + an
encrypted sample program + known semantics, and must craft an input parsed by
the encrypted runtime. AST isomorphism normalization is not-yet-polynomial and
worsens if the graph is a *semantic* isomorph rather than a strict one
(invoking Church-Turing/halting). Attackers get a single-shot try with no
feedback; failures emit a defender signal.

## 3. The PHP scrambler PoC technique (paper §III–IV)

Three orthogonal transformation axes (pp. 5–7):

**a) Vocabulary** (1:1 token rename) — `int → goobledygook`, `if → fndcv`,
`else → kfef`, `{ → *`, `} → /`, `( → [`, `) → ]`.

**b) Syntax** (n:m structural rewrites) — `<x> += <n>` becomes `& <n> <x> -`;
`if (<cond>) {` becomes `(<cond>) fndcv *`. Breaks statistical/correlational
analysis because mappings are not bijective at the token level.

**c) Semantics** (meaning-preserving AST rewrites):
- Double-negation: `<cond>` → `not (not <cond>)`.
- Construct swaps: `if/else` ↔ `switch/case` with reordered keyword
  positions.
- Function merge/split: `f(g(x)) → e(x)`; `h(x) → i(j(x))`.
- **Landmine keywords** inspired by INTERCAL's `PLEASE` — required tokens
  injected at deterministic positions (e.g. exactly ⌊N/2⌋ `please`s per
  statement, no two consecutive). Attackers reliably trip them.
- Contextual keyword meaning: `if` is a conditional only when a specific
  neighboring keyword is present.

**Shipped implementation reality** (from the local code): The PHP PoC
implements vocabulary scrambling only. `SYMBOL_SCRAMBLING_ANALYSIS.md`
concludes lexer-level symbol scrambling is **fundamentally incompatible with
PHP's grammar** (array access `[]`, multi-char operators `===`/`&&`/`->`,
string interpolation `"{$x}"`). Final recommendation: ship keyword scrambling
only. See dossier 02 for implementation detail.

## 4. Key invariants and properties

From §V "Ensuring Correctness in a Closure" (p. 8) and §VI "Performance":

- **Closure over a finite program set.** EE does *not* claim to translate
  arbitrary L → E for all programs. It transforms only over a *closure* — the
  finite (even if large, "including an entire Linux distribution with
  extended repos") set of programs targeted for that instance.
- **Step-wise invariant.** After each transform n: `Pn = En` (transformed
  code runs on transformed runtime with semantics preserved). Both AST and
  parser are transformed together; never one without the other.
- **Performance invariant.** Parser complexity class is preserved: "a
  Recursive-Descent Parser will remain an RDP, as will LL, LR, shift-reduce
  and any of the others." Only constants may shift.
- **Determinism per system, non-reproducibility across systems.** "Given
  the highly parallelized transformation implementation, it is more
  difficult in practice to reproduce a particular scramble, given the same
  seed" (p. 7). 52-card-shuffle analogy: search space large, collisions
  never occur in practice.
- **Hardness root.** Attacker must solve AST graph isomorphism on a
  non-strict (semantic) isomorph — not-yet-polynomial; semantic equivalence
  runs into Church-Turing/halting.
- **Strictly non-worsening security.** "An Encrypted Execution runtime is
  strictly at least as secure as an Unencrypted Execution runtime and only
  improves on the baseline security posture" (p. 3, claim 6; p. 9).
- **What keeps working:** any program inside the closure (WordPress,
  Laravel, Symfony) at unchanged Big-O.
- **What breaks:** anything introduced from outside — injected PHP, `eval`'d
  remote payloads, cross-instance malware hops.

## 5. Acknowledged limitations

- **Translation hardness.** "Language translation is hard, and transforming
  arbitrary programs from L to E is arbitrarily hard." Mitigated only by the
  finite-closure framing.
- **Silicon cost.** Custom ISAs are expensive — only feasible for narrow
  scenarios (embassies, military, satellites, self-driving cars), possibly
  via FPGAs reprogrammed on the fly.
- **Generic encryption failure modes** apply: stolen key, compromised
  authorized code, sufficient compute breaks any cipher.
- **Implementation gap** (from local repos): symbol-level scrambling
  infeasible in PHP because of tight lexer/parser coupling around `[]`,
  string interpolation, multi-char operators. Shipping PoC scrambles
  keywords only.

## 6. Prior art the paper cites

Citations in §IX "Patents, Copyrights and Prior Art" (pp. 10–11) and inline:

- **USPTO 10,733,303** — patent owned by Gore, **pledged into the public
  domain.**
- **Trusted Computing** and **OWASP Top 10 / Code Injection** — framed as
  the failure case EE replaces.
- **SolarWinds** — supply-chain exemplar.
- **BootHole** — Trusted/Secure-Computing breaker.
- **Homomorphic Encryption** — explicit analogy ("code equivalent of HE").
- **INTERCAL** — landmine keyword / `PLEASE` technique.
- **Data Structure Randomization in the Linux kernel since ~2017** — Kees
  Cook's randstruct.
- **Purdue ESORICS 2015** — `friends.cs.purdue.edu/pubs/ESORICS15.pdf`
  (FG-ASLR / code randomization).
- **Prior "Encrypted Execution" literature on number-theoretic crypto** —
  IEEE 7011332 and IACR ePrint 2023/641 — Gore distinguishes his
  linguistic/AST approach.
- **Abstract Syntax Trees, isomorphic graph comparison, Church-Turing,
  recursive-descent parsing** — theoretical hardness backbone.

The paper does **not** explicitly cite kASLR or Instruction Set
Randomization (ISR) by name, though §III's "the same difference that exists
between an ARM, an x86, and a RISC-V processor" and §VIII.4's
`<compiler-codegen-backend, ISA>` pair are direct ISR-style framings.

## 7. Direct quotes for citation

All from `whitepaper.pdf`:

- p. 1: "The fundamental problem with all Encryption mechanisms is that any
  encrypted data, especially executable code, must be decrypted to be
  useful. This paper suggests eliminating the need for decryption
  altogether."
- p. 2: "A methodology to produce infinite matched pairs of encrypted
  execution runtimes and encrypted code, without incurring runtime
  performance penalties, allowing each instance to be made unique."
- p. 2: "Encrypted Execution is built on the idea that all execution
  runtimes are Languages, and there can be an infinite number of languages
  to represent the same semantics."
- p. 3 (six claims): "A language L at any layer (microprocessor, OS APIs,
  calling conventions, bytecode, symbols, and interpreter) can be
  transformed into a never-before-seen language E generated dynamically."
- p. 3: "Simply knowing EP and E, it is computationally difficult to write
  a new program or modify EP such that it runs on E, since isomorphic
  graph comparisons are already non-trivial."
- p. 3: "An Encrypted Execution runtime is strictly at least as secure as
  an Unencrypted Execution runtime."
- p. 4: "Encrypted Execution is the code equivalent of homomorphic
  encryption."
- p. 4: "Encryption is a Translation from a Readable Language into an
  Unreadable one. Instead of Decrypting the Unreadable Program, we encrypt
  the Runtime to make it Usable in Encrypted form. This is the programmatic
  equivalent of the Navajo Code Talkers."
- p. 6 (landmines): "We can learn from esoteric languages like INTERCAL
  which introduced the idea of requiring a program to say 'PLEASE' a
  certain amount but not too much. We call these landmine keywords."
- p. 8: "Pn = En (i.e. transformed code Pn executes on En, and is
  semantically same as the original P)."
- p. 8: "The Big-Oh complexity of the parser remains identical."
- p. 9: "Normalizing an isomorphic graph (in this case the Abstract Syntax
  Tree) is not-yet-Polynomial. This gets more expensive if the graph isn't
  a strict isomorph but a semantic one."
- p. 9: "Our approach is at best significantly stronger than running plain
  code, and at worst introduces no additional vulnerabilities."
- **p. 10 (the encrypted-linux precedent):** "Taking this to the extreme,
  it is conceivable to produce pairs of <compiler-codegen-backend, ISA>
  such that the compiler is able to target a custom ISA. This would mean
  the silicon itself would execute programs in the Encrypted Domain, and
  only the possessor of the compiler codegen backend would be able to
  target it."
- p. 10: "Nation-State digital sovereignty: Nations may develop x86/ARM-
  transformed ISAs and may insist on compiling critical OS and software
  code on their soil."

## 8. Key takeaways for the encrypted-linux plan

1. The paper *already* names the encrypted-linux extreme (p. 10, item 4) —
   `<compiler-codegen-backend, ISA>` pairs where "the silicon itself would
   execute programs in the Encrypted Domain." Scrambling GCC's C calling
   convention is a direct instantiation, sitting between the paper's
   "API encryption … dynamic linking calling conventions" (p. 10, item 2)
   and full custom-ISA territory.
2. The **closure** framing is load-bearing: you don't need to translate
   arbitrary C — you need to translate the closure of source for that
   distribution.
3. The PHP PoC's hard-won lesson: scrambling lexer tokens the grammar
   implicitly depends on (operators, brackets, string interpolation) is
   intractable. For C, the analogous risk surface is the ABI/structure
   layout vs. inline asm, `va_list`, and any code that introspects the
   stack frame.
4. Prior-art positioning: distinguish encrypted-linux from kASLR
   (address-level) and ISR (instruction-encoding-level) by emphasizing
   **ABI / calling-convention** as the scrambled surface.
5. **Patent USPTO 10,733,303 is pledged to the public domain**;
   implementation code is Apache 2.0 except where upstream licenses (PHP
   License) apply; copyright resides with Polyverse Corporation
   (relicensing blocked, but clean-room reimplementation is straightforward).
