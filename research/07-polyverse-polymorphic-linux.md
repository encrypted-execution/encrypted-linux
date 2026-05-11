# Research Dossier 07 — Polyverse, Polymorphic Linux, Polyscripting

**Status: NOT YET RESEARCHED.** Placeholder created during state save.

The user added this as a follow-up research item immediately before asking
the session to save state and exit. Whoever resumes this work should fill
out this file *first*, before authoring `plan/`.

## Charter for this dossier

Find and synthesize everything publicly available on:

- **Polyverse Corporation** (the paper's copyright holder; the company
  behind both Polymorphic Linux and the Polyscripting product line).
- **Polymorphic Linux** — Polyverse's commercial product circa 2017–2020.
  Distribution where every binary in the OS was rebuilt nightly with
  randomized symbols / register usage / inline-gadget layout, so any
  attacker-supplied ROP/code-injection chain stopped working from one
  nightly to the next.
- **Polyscripting** — Polyverse's trademark / product line covering PHP
  (the implementation we already studied), Ruby, npm, WordPress, and
  whatever else they shipped.

## What to find

- Polyverse public website archive (Wayback Machine for polyverse.io,
  polyverse.com).
- GitHub organizations: `Polyverse-Security`, `polyverse`,
  `polyverse-research`, and any forks under archisgore's personal account
  that were spun out of Polyverse work. Catalog repos, READMEs, design docs.
- Whitepapers and product datasheets — Polyverse published several
  "Polymorphic Linux" technical overviews.
- Recorded talks: Archis Gore and Alex Gounares at DEF CON, BlackHat,
  RSA, OSCON, Linux Foundation events, podcasts (2017–2020 window).
- US Patents assigned to Polyverse Corporation as assignee (USPTO,
  Google Patents). At minimum: USPTO 10,733,303 is already known. Look
  for sibling patents covering symbol scrambling, ABI scrambling, binary
  rewrites, distribution rebuilding.
- Academic citations of Polymorphic Linux (Google Scholar, IEEE, ACM,
  DBLP). The Larsen et al. SoK on Automated Software Diversity (UC Irvine,
  cited in dossier 06) almost certainly references it.
- Polyverse blog (Medium, dev.to, corporate blog) — case studies, post
  mortems, technical deep-dives.
- News coverage and product retrospectives — Phoronix, LWN, The Register,
  Dark Reading, Bleeping Computer.

## What to extract

1. **Mechanism.** What did Polymorphic Linux actually randomize per binary?
   Symbol names? Function ordering? Register allocation? Inline gadgets?
   Stack layout? Was it post-link binary rewriting or compile-time?
2. **Rebuild cadence and distribution.** Daily rebuilds? Per-tenant? How
   was the per-system seed delivered? How did `yum`/`apt` updates work
   when every binary changed every day?
3. **Compatibility scope.** Did Polymorphic Linux preserve the syscall
   ABI? Could you mix a stock Red Hat / Ubuntu kernel with Polymorphic
   userspace? What about prebuilt commercial software (Oracle, SAP)?
4. **Production lessons.** What broke that the team hadn't anticipated?
   Most relevant: hand-written asm in glibc/OpenSSL/JITs (this dossier's
   pet question), eBPF, kernel modules, third-party `.so`s.
5. **Why they pivoted / wound down.** Polyverse the company appears to
   have largely stopped shipping Polymorphic Linux around 2020. Was it
   technical, commercial, both? What does this say about productizing
   encrypted-linux today?
6. **What Polyscripting did differently from Polymorphic Linux.** PHP
   (and the other interpreted-language scramblers) operate at the language
   layer, not the binary layer — directly relevant because encrypted-linux
   sits between the two.
7. **Direct quotes** with URLs so the synthesis is citable.

## Why this matters before authoring `plan/`

Polymorphic Linux is **encrypted-linux's direct production ancestor**, in a
way the PHP scrambler (the educational descendant) is not. Anything they
shipped — and especially anything they wished they hadn't shipped, or had
to retract — is directly relevant to:

- Which axes of the calling convention are practical to scramble (dossier 04
  was forced to make engineering guesses; Polyverse has experiential answers).
- How to distribute per-system seeds without making them a runtime secret
  (dossier 02 captured the PHP design choice; Polyverse made a binary-distro
  version of the same choice at scale).
- What attacker behavior they actually observed in the wild — does
  scrambling break universal exploits in practice, or do attackers retool
  quickly?

If after this research the answer is "Polyverse already did half of what
we're proposing and shipped it for two years," the plan should explicitly
position encrypted-linux as *extending* that work to (a) the calling
convention proper, not just symbol names, and (b) the kernel syscall ABI
in Phase 2 — making clear what's new and what's continuation.

## Likely sources to start from

- `web.archive.org/web/2018*/polyverse.io`
- `github.com/Polyverse-Security` (or `polyverse-security`)
- `github.com/polyverse`
- Archis Gore's LinkedIn / public talk archive
- USPTO assignee search: "Polyverse"
- Larsen, Homescu, Brunthaler, Franz — "SoK: Automated Software Diversity"
  (UC Irvine) — bibliography
