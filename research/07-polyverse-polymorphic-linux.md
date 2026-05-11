# Research Dossier 07 — Polyverse, Polymorphic Linux, Polyscripting

## 1. The company

Polyverse Corporation — Bellevue, WA; founded 2015 by Alex Gounares
(ex-Microsoft VP, ex-AOL CTO; CEO) and grown by a team that included Archis
Gore (CTO, the user) and inventors Christopher W. Fraser and Steven C.
Venema. The product line had two pillars: **Polymorphic Linux** (binary-
level diversification of an entire Linux userspace, sold as a repo-mirror
subscription) and **Polyscripting** (source/lexer-level diversification of
interpreted languages — PHP first, then ambitions to Ruby, Node/npm,
SQL). Total funding ~$46.7M across 15 rounds; Crunchbase now lists the
cybersecurity entity as permanently closed. The CLI tooling repo
`sh.polyverse.io` and the Alpine fork `aports` both carry an explicit
deprecation banner: *"This repository has been deprecated and is no longer
actively maintained by Polyverse Corporation … may contain unpatched
security issues"* ([github.com/polyverse/sh.polyverse.io](https://github.com/polyverse/sh.polyverse.io),
[/aports](https://github.com/polyverse/aports)).

## 2. Polymorphic Linux — what it actually randomized

Polyverse's own patents are the most precise public record. US 10,127,160
B2 *Methods and Systems for Binary Scrambling* (filed 2017‑08‑24, priority
2016‑09‑20, inventors Gounares / Fraser / Venema, assignee Polyverse) lists
**seven transformations the compiler applies per source file** ([Google
Patents US10127160B2](https://patents.google.com/patent/US10127160B2/en)):

1. Register reallocation — "substituting equivalent hardware registers."
2. Function reordering — "randomizing layout order from source-code sequence."
3. Loop-unrolling variation — random unroll factors / partial unroll.
4. Obfuscation code — "no-ops and dummy code for entropy."
5. Instruction substitution — "replacing operations with semantically equivalent alternatives."
6. Expression evaluation reordering — commutative-operation reordering.
7. Import / lookup-table randomization.

US 2019/0371209 A1 *Pure Binary Scrambling* (inventors Gounares & Fraser)
covers the **post-link binary-rewriter variant**: "disassembling the
commercial software binary → converting to … register-transfer language →
applying transformations → recompiling into a new binary," explicitly
intended for closed-source binaries (Windows DLLs are cited) and using
emulated VMs "to assist disassembly, solving … the undecideability problem
in binary modification" ([Google Patents
US20190371209A1](https://patents.google.com/patent/US20190371209A1/en)).

The `polyscripted-wordpress` README — written by Polyverse staff —
describes the production product in the user's own words:

> *"Polyverse's flagship product … uses a custom compiler on the entirety
> of the Linux stack to scramble the binaries: changing register usage,
> function locations, import tables, and so on to produce individually
> unique binaries that are semantically equivalent."*
> ([README](https://github.com/polyverse/polyscripted-wordpress))

CEO Gounares positioned it explicitly as next-generation ASLR:

> *"Rather than just randomizing just the starting address of a dll, we
> randomize nearly everything on the inside of the dlls and the rest of
> the program — addresses, register usage, layout, instruction usage, and
> so forth."*
> ([rlbsystems](https://rlbsystems.com/scramble-cycle-repeat-polyverses-fascinating-take-computer-security/))

So: primarily **compile-time** diversification baked into a custom
compiler that ran inside Polyverse's build farm, with a complementary
**binary-rewriter** path for prebuilt third-party software. The
randomization is *inside* functions (register choice, instruction
substitution) and *between* functions (ordering, import-table layout) —
not at the calling-convention level. **Caller↔callee register / stack
agreement is preserved.** That distinction is the single most important
thing encrypted-linux extends.

## 3. Rebuild cadence and distribution model

Polymorphic Linux **did not ship as an ISO.** It shipped as a
**transparent yum/apt/apk mirror**:

> *"Polymorphic Linux shows up as a transparent and seamless 'mirror' to
> standard package manager repositories, and serves the exact same
> versions of packages, compiled from the same source code, but
> polymorphic (same thing malware does to avoid detection, but for good
> software)."* (Polyverse marketing copy, quoted in
> [netdata#5034](https://github.com/netdata/netdata/issues/5034) and
> [Polyverse blog](https://blog.polyverse.io/introducing-polyverse-polymorphic-linux-bee958c02877))

Subscribers ran `curl https://sh.polyverse.io | sh` which rewrote
`/etc/yum.repos.d`, `/etc/apt/sources.list`, or `/etc/apk/repositories` to
point at the per-customer Polyverse endpoint. *"Once the install script
has completed, your host is now preferentially subscribed to Polyverse's
periodically-scrambling repositories. Any packages you install on this
host will now preferentially come from the polymorphic endpoint, giving
you unique code and memory layouts."* The mirror was authenticated and
**served packages periodically rescrambled on Polyverse's side** —
authoritative cadences quoted by Polyverse range from "every five
seconds" (the Container Cycler product) up to "every 24 hours" for the
binary-scrambler; the Nasdaq writeup says "every quarter-second" was
theoretically possible (rlbsystems / Nasdaq).

Crucially, *"This operation is 100% drop-in compliant with existing
package repositories, so if Polymorphic Linux service goes down, the APK
just defaults to standard Alpine repos upstream"*
([netdata#5034](https://github.com/netdata/netdata/issues/5034)). So
**per-VM seeds were not delivered to the VM** — the VM held only a
subscription token. The diversity unit was the Polyverse build, not the
endpoint. Each customer subscription got its own ongoing stream of
freshly scrambled rebuilds; two VMs on the same subscription that
installed packages at different moments could already differ. Updates
worked because the mirror served *the same upstream version string* (e.g.
`openssl-1.1.1k-r0`); only the bits inside the `.rpm`/`.deb`/`.apk`
changed.

## 4. Supported distros — broad, not Gentoo-style

Polyverse explicitly supported **Alpine, CentOS, Debian, Fedora, RHEL,
SUSE, Ubuntu** ([Polymorphic Linux
cheatsheet](https://info.polyverse.io/polymorphic-linux-cheatsheet),
SUSE press release [prweb 2020](https://www.prweb.com/releases/Polyverse_Launches_Polymorphing_for_SUSE_Linux_Enterprise/prweb17124581.htm),
[Red Hat partnership](https://polyverse.io/news/pr-red-hat-partner/)).
Gentoo is not on the list. Polyverse's Alpine work lives in
[github.com/polyverse/aports](https://github.com/polyverse/aports) — a
straight fork of upstream Alpine `aports`, indicating the scrambling
happened in their build infrastructure (custom compiler + build farm),
**not in the package source recipes**. The recipes were upstream; the
toolchain was Polyverse's.

## 5. Compatibility scope — userspace only, kernel preserved

There is no evidence Polymorphic Linux randomized the kernel syscall
ABI. The product brief lists protection *"from the GRUB bootloader, to the
kernel, all the way to memory, application, and operational package
binaries themselves"* ([Intellyx
2020](https://intellyx.com/2020/10/13/polyverse-polymorphic-protection-from-bootloader-to-application-binaries/))
but the customer-facing repos shipped the same kernel package upstream
shipped — just rebuilt with the scrambling toolchain. Because the seven
transformations preserve the external C calling convention, a stock
Ubuntu kernel and a Polymorphic userspace coexist, and conversely a
Polymorphic kernel module can in principle load against a stock kernel.
Commercial prebuilt software (Oracle, SAP, NVIDIA drivers) was handled
via the *Pure Binary Scrambling* post-link rewriter — same patent family,
different code path.

## 6. The Polyscripting product line

Polyscripting is Polyverse's name for the language-layer cousin of
Polymorphic Linux. The mechanism, in Archis Gore's own description on
TFiR ([tfir.io](https://tfir.io/how-polyverse-protects-wordpress-sites-from-code-injection/)):

> *"We produce a brand new programming language that's based on PHP, but
> it's not PHP. And this new language can no longer understand the
> regular PHP. … We transform all of your code that you say, 'this is the
> approved code' into a new language and then we run it. … Unwanted code,
> whether it's through eval, through an injection, through a file upload
> doesn't matter. I don't speak PHP anymore."*

US 10,733,303 B1 *Polymorphic Code Translation Systems and Methods*
(inventors Gore / Gaston / Lim, filed 2020‑04‑23, granted 2020‑08‑04 —
the patent the user has publicly pledged to the public domain) is the
foundational Polyscripting patent. Its claims cover keyword substitution
("transforming 'String' into '$tring'"), grammar transposition (IF-THEN ↔
THEN-IF), interstitial-environment migration, and watermarking via
non-printing characters ([Google Patents
US10733303B1](https://patents.google.com/patent/US10733303B1/en)).

Shipped Polyscripting products: **PHP** (the v1/v2 implementations
dossier 02 studied — keyword rewriting in `zend_language_scanner.l`/
`.y`); **WordPress** (the v1 turnkey container); demos for **AWS
Lambda + Node.js** ([demo](https://info.polyverse.com/demo-polyscripting-for-wordpress)
and [TFiR](https://tfir.io/how-polyverse-protects-wordpress-sites-from-code-injection/)).
Ruby and SQL were on the roadmap but no public production code surfaced.
All ship with the same *keywords-only, not operators* shape the user
already shipped in PHP — dossier 02 documents that the symbol-permutation
path was disabled by default because re2c lexer rules and multi-char
operators (`===`, `++`, `->`) collapse if components are remapped.

## 7. Production lessons / what broke

Direct Polyverse postmortems are scarce — Polyverse's own engineering blog
disappeared with the corporate shutdown — but four classes of breakage
are documented:

1. **JIT/eval-style PHP features** were the Polyscripting Achilles heel.
   HN commenters in 2018 noted: *"This doesn't really do what it claims
   … only addresses eval-based attacks … doesn't address dynamically
   generated code or runtime string concatenation … breaks legitimate
   dynamic code generation features"*
   ([news.ycombinator.com/item?id=17460949](https://news.ycombinator.com/item?id=17460949)).
   Same point in the user's own README: *"if you want to download
   plugins or add any php source code to your sites, this needs to be
   done with polyscripting turned off"*
   ([polyscripted-wordpress README](https://github.com/polyverse/polyscripted-wordpress)).

2. **Closure-of-build requirement.** Polyscripted WordPress sets
   `DISALLOW_FILE_MODS = true` — once shipped, you cannot add a plugin
   from the WP admin UI; every PHP file reaching the interpreter must be
   transformed with the build's dictionary. This is the source-language
   analog of the binary-side closure problem.

3. **Mirror outage = silent downgrade.** The drop-in mirror design
   *"defaults to standard upstream"* on failure (netdata thread, above).
   For an availability product this is correct; for a hardening product
   it means an attacker who can DoS the Polyverse mirror gets a stock
   Linux as a fallback.

4. **No public posts** discussing hand-asm/glibc/eBPF breakage have been
   located. The absence is itself information: because Polymorphic Linux
   *preserved* the calling convention, asm/glibc didn't break, and the
   project never had to confront the cross-TU thunk problem encrypted-
   linux is taking on directly.

## 8. Why Polyverse wound down

No retrospective from Gounares or Gore is public. Inferable from the
record: the live polyverse.io / polyverse.com sites have collapsed (the
docs site `docs.polyverse.io` returns ECONNREFUSED; the marketing site
serves a single legacy page), the Polyverse-Security org has stopped
shipping (`sh.polyverse.io` deprecated 2022), Crunchbase records the
cybersecurity entity as *permanently closed*, and Gore has moved to Meta
([LinkedIn](https://www.linkedin.com/in/archis/)). The mirror-subscription
business model required Polyverse to maintain a hot rebuild farm for
seven major distros indefinitely — an enormous fixed-cost commitment
against a market that DoD validation alone did not unlock at scale. There
is no evidence of a single technical regression that killed it.

## 9. Patents — Polyverse and Gore

Confirmed Polyverse-assignee patents on the scrambling stack:

| Patent | Title | Inventors | Filed / Granted |
|---|---|---|---|
| [US 10,127,160 B2](https://patents.google.com/patent/US10127160B2/en) | Methods and Systems for Binary Scrambling | Gounares, Fraser, Venema | 2017‑08‑24 / 2018‑11‑13 |
| [US 2018/0081826 A1](https://patents.google.com/patent/US20180081826A1/en) | Methods and Systems for Binary Scrambling (publication of above) | Gounares, Fraser, Venema | pub. 2018‑03‑22 |
| [US 2019/0371209 A1](https://patents.google.com/patent/US20190371209A1/en) | Pure Binary Scrambling | Gounares, Fraser | pub. 2019‑12‑05 |
| [US 10,733,303 B1](https://patents.google.com/patent/US10733303B1/en) | Polymorphic Code Translation Systems and Methods | Gore, Gaston, Lim | 2020‑04‑23 / 2020‑08‑04 (publicly pledged to PD by Gore) |

Polyverse also joined the **Open Invention Network** (Nov 2018), placing
its patents under Linux-system non-aggression
([Business Wire](https://www.businesswire.com/news/home/20181105005825/en/Polyverse-Joins-Open-Invention-Network-Community))
and *"announced that it would provide free subscriptions to its
polymorphic version of Linux to open source projects"*
([Business Wire Jan 2019](https://www.businesswire.com/news/home/20190117005751/en/Polyverse-Donates-%E2%80%9CMoving-Target-Defense%E2%80%9D-Cybersecurity-Technology-to-Open-Source-Projects)).

## 10. Academic citations

Larsen / Homescu / Brunthaler / Franz, *SoK: Automated Software
Diversity* (IEEE S&P 2014) predates Polyverse's shipping product
(founded 2015) and does **not** cite it — the PDF text contains no
"Polyverse" or "Polymorphic Linux" string
([ics.uci.edu/~perl/automated_software_diversity.pdf](https://ics.uci.edu/~perl/automated_software_diversity.pdf)).
Polymorphic Linux is industrial productization of the diversification
literature the SoK summarizes; it doesn't appear to have generated its
own academic follow-up. The MTD literature
([mdpi 2023](https://www.mdpi.com/2076-3417/13/9/5367)) cites Polyverse
as the commercial reference point but engages no design specifics.

## 11. What encrypted-linux must take from this

- **The mirror model works and the seed never leaves the build farm.**
  Polymorphic Linux validated, at production scale, that a per-customer
  repo mirror is the right distribution shape, and that the *diversity*
  (not concealment) of the binaries is the defense. Encrypted-linux can
  copy this wholesale.
- **Polyverse stopped short of the calling convention.** Every public
  description randomizes inside or between functions, leaving cross-
  function register/stack agreement intact. That is precisely the
  boundary encrypted-linux extends — and the boundary at which the hard
  problems (kernel syscall ABI, asm entry points, indirect calls,
  unwinder, signal handlers, JITs) live.
- **Closure-of-build was the operational problem they survived.**
  `DISALLOW_FILE_MODS` for PHP and "no third-party prebuilt drivers
  without re-scrambling" for binaries. Encrypted-linux will need the
  same plus an ELF-note seed tag the dynamic linker checks (dossier 02 §8.8).
- **Production wind-down was commercial, not technical.** No public
  evidence of a calling-convention-class regression killing Polyverse;
  the cost of running seven hot rebuild farms forever did.

## Sources

- [Polyverse blog — Introducing Polymorphic Linux](https://blog.polyverse.io/introducing-polyverse-polymorphic-linux-bee958c02877)
- [Intellyx — Polyverse Polymorphic Protection from Bootloader to Application Binaries (2020)](https://intellyx.com/2020/10/13/polyverse-polymorphic-protection-from-bootloader-to-application-binaries/)
- [Intellyx — Polyverse: Moving OS Targets (2018)](https://intellyx.com/2018/12/07/polyverse-moving-os-targets-faster-than-cyber-threats-can-find-them/)
- [Nasdaq — Scramble, Cycle, Repeat: Polyverse's Take on Security (2018)](https://www.nasdaq.com/articles/scramble-cycle-repeat-polyverses-fascinating-take-computer-security-2018-01-06)
- [rlbsystems — Scramble, Cycle, Repeat](https://rlbsystems.com/scramble-cycle-repeat-polyverses-fascinating-take-computer-security/)
- [TFiR — How Polyverse Protects WordPress from Code Injection](https://tfir.io/how-polyverse-protects-wordpress-sites-from-code-injection/)
- [GeekWire — Bellevue's Polyverse raises $2M (2019)](https://www.geekwire.com/2019/bellevues-polyverse-brings-significant-strategic-investors-raises-2m-secure-linux-product-courts-pentagon/)
- [GeekWire — Geek of the Week: Alex Gounares (2018)](https://www.geekwire.com/2018/alexander-gounares/)
- [Business Wire — Polyverse Joins Open Invention Network (Nov 2018)](https://www.businesswire.com/news/home/20181105005825/en/Polyverse-Joins-the-Open-Invention-Network-Community)
- [Business Wire — Polyverse Donates MTD Tech to OSS (Jan 2019)](https://www.businesswire.com/news/home/20190117005751/en/Polyverse-Donates-%E2%80%9CMoving-Target-Defense%E2%80%9D-Cybersecurity-Technology-to-Open-Source-Projects)
- [Business Wire — Polyverse Thwarts PHP Vulnerabilities, WordPress Attacks (2018)](https://www.businesswire.com/news/home/20180822005200/en/Polyverse-Thwarts-PHP-Vulnerabilities-WordPress-Attacks)
- [Business Wire — Polymorphic Linux for VMware Cloud on AWS (2019)](https://www.businesswire.com/news/home/20190221005689/en/Polyverse-Announces-Polymorphic-Versions-of-Linux-for-VMware-Cloud-on-AWS)
- [prweb — Polyverse Launches Polymorphing for SUSE Linux Enterprise (2020)](https://www.prweb.com/releases/Polyverse_Launches_Polymorphing_for_SUSE_Linux_Enterprise/prweb17124581.htm)
- [Polymorphic Linux Cheatsheet](https://info.polyverse.io/polymorphic-linux-cheatsheet)
- [Polymorphic Linux product brief PDF](https://polyverse-pdfs.s3-us-west-2.amazonaws.com/Polyverse-Docs/polymorphing-for-linux-product-brief.pdf)
- [Polyverse / Red Hat partnership](https://polyverse.io/news/pr-red-hat-partner/)
- [polyverse/sh.polyverse.io (deprecated)](https://github.com/polyverse/sh.polyverse.io)
- [polyverse/aports (deprecated)](https://github.com/polyverse/aports)
- [polyverse/polyscripted-wordpress README](https://github.com/polyverse/polyscripted-wordpress)
- [polyverse/zerotect](https://github.com/polyverse/zerotect)
- [polyverse-security GitHub org](https://github.com/polyverse-security)
- [netdata #5034 — Introduce Polymorphic Linux in Docker](https://github.com/netdata/netdata/issues/5034)
- [Hacker News — Polyscripting (2018)](https://news.ycombinator.com/item?id=17460949)
- [USPTO 10,127,160 B2 — Methods and Systems for Binary Scrambling](https://patents.google.com/patent/US10127160B2/en)
- [USPTO 2018/0081826 A1 publication](https://patents.google.com/patent/US20180081826A1/en)
- [USPTO 2019/0371209 A1 — Pure Binary Scrambling](https://patents.google.com/patent/US20190371209A1/en)
- [USPTO 10,733,303 B1 — Polymorphic Code Translation](https://patents.google.com/patent/US10733303B1/en)
- [Larsen et al., SoK: Automated Software Diversity (IEEE S&P 2014)](https://ics.uci.edu/~perl/automated_software_diversity.pdf)
- [MDPI — A Survey on Moving Target Defense (2023)](https://www.mdpi.com/2076-3417/13/9/5367)
- [Archis Gore — Medium](https://medium.com/@archisgore)
- [Archis Gore — LinkedIn](https://www.linkedin.com/in/archis/)
- [Crunchbase — Polyverse Corporation](https://www.crunchbase.com/organization/polyverse-corporation)
