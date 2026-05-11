# Research Dossier 05 — Distro Bootstrap Options

## 1. Linux From Scratch (LFS)

LFS 12.1 splits the build into staged chapters resolving the chicken-and-egg
of "GCC builds itself":

- **Chapter 5 — Cross-Toolchain (5 packages):** Binutils Pass 1, GCC Pass 1,
  Linux API Headers, Glibc, libstdc++. Built using *host* toolchain to
  produce cross-compiler targeting `$LFS_TGT`.
- **Chapter 6 — Cross Temporary Tools (~17 packages):** M4, Ncurses, Bash,
  Coreutils, Diffutils, File, Findutils, Gawk, Grep, Gzip, Make, Patch, Sed,
  Tar, Xz, plus Binutils Pass 2 and GCC Pass 2 (dynamically relinked against
  freshly built Glibc).
- **Chapter 7:** chroot into the temporary system.
- **Chapter 8 — Final System (~79 packages):** Native rebuild of everything
  including the third and final GCC.

Total ~100 packages minimum, ~72 upstream tarballs. The chicken-and-egg is
broken by **using host GCC to build cross-GCC, then using that cross-GCC to
build native GCC inside chroot** — three GCC builds total, plus GCC's internal
3-stage self-compare.

References: [LFS 12.1 PDF](https://www.linuxfromscratch.org/lfs/downloads/12.1/LFS-BOOK-12.1.pdf),
[Chapter 5 GCC Pass 1](https://www.linuxfromscratch.org/lfs/view/stable/chapter05/gcc-pass1.html).

## 2. Slackware vs alternatives

**Slackware's "simplicity"** is *operational*, not *structural*: Bourne-shell
**SlackBuild** scripts (configure/make/package tarball — no dependency
resolution, no metadata DB) and a full glibc + GNU userland. Slackware is
**the wrong choice for a PoC** — hundreds of packages, glibc-based, dynamically
linked.

| Distro | Libc | Userland | Pkg count (base) | PoC fit |
|---|---|---|---|---|
| Slackware | glibc | GNU | ~500+ | Poor |
| **Alpine** | musl | BusyBox | ~130 MB install | Good |
| **Tiny Core** | glibc | BusyBox | ~16 MB (Core) | Excellent boot footprint, but glibc |
| **Buildroot** | configurable | configurable | ~10–40 minimal | **Best for iteration** |
| Yocto | configurable | configurable | massive | Overkill, slow |
| NixOS | glibc | GNU | ~200+ closure | Wrong abstraction |

Alpine's per-package size (musl ≈572 KB vs glibc ≈3 MB) and BusyBox-everything
model makes it the right *runtime* template.
[Alpine about](https://alpinelinux.org/about/),
[Alpine musl switch](https://www.alpinelinux.org/posts/Alpine-Linux-has-switched-to-musl-libc.html).

## 3. GCC three-stage bootstrap & scrambling interaction

GCC's native bootstrap: stage1 (built by host CC) → stage2 (built by stage1)
→ stage3 (built by stage2). The `compare-debug` test **bytewise-compares
stage2 and stage3**; if they differ, build aborts as "potentially serious bug."
([GCC install/build.html](https://gcc.gnu.org/install/build.html))

**Critical implications:**
- Scrambling **must be deterministic given the seed** — pure function of
  (source, seed); no PID/time/aslr inputs.
- Seed **must be baked into GCC source** (or passed via env var captured into
  both stages) so stage2 and stage3 read the same value.
- Stage1 (built by un-scrambled host GCC) must still emit *runnable code under
  the scrambled ABI* — the scrambling logic operates inside whichever GCC is
  doing the codegen. Stage1's binary code is unscrambled (host built it), but
  its *codegen output* is scrambled.
- Alternative for PoC: **disable bootstrap** (`--disable-bootstrap`), build
  only stage1. Loses self-consistency check but sidesteps the question.
  Acceptable for PoC.

## 4. glibc vs musl under a scrambled GCC

**glibc is tightly coupled to GCC** — GNU extensions, ifunc, symbol
versioning, custom asm; explicitly does not support non-GCC compilers
(Linaro's LLVM-glibc effort has run for years).
[Linaro: glibc on LLVM](https://www.linaro.org/blog/building-glibc-with-llvm-the-how-and-why/),
[MaskRay: Everything about glibc](https://maskray.me/blog/2022-05-29-glibc).

**musl is dramatically more amenable:** ~30k LOC, POSIX-strict, static-link
oriented, fewer GNU-isms, simpler asm.
[musl FAQ](https://www.musl-libc.org/faq.html),
[tuxcare comparison](https://tuxcare.com/blog/musl-vs-glibc/).
Calling-convention scrambling affects any hand-written asm (syscall stubs,
setjmp, atomics) — musl has perhaps 20× less to audit/patch than glibc.

**Recommendation: musl.**

## 5. Kernel build under custom GCC

The kernel uses many GCC-specific flags (`-fno-stack-protector`,
`-fno-strict-aliasing`, `-fno-PIE`, `-mregparm=3` on i386, asm goto, named
address spaces). **GCC-portable but not compiler-portable** (Clang support
recent and ongoing).

**Key insight: Linux exposes two distinct ABIs:**
- **Userspace syscall ABI** (registers, syscall numbers) — *contractually
  stable forever.*
  [admin-guide/abi](https://docs.kernel.org/admin-guide/abi.html),
  [LWN](https://lwn.net/Articles/726021/)
- **In-kernel ABI** — *explicitly unstable.*

If you scramble the kernel internally but **preserve the syscall ABI**,
scrambled userspace binaries can still trap into the kernel normally. The
kernel becomes a self-contained scrambled blob, and only userspace must agree
with itself on calling conventions. **This is the right cleavage plane** for
Phase 1.

## 6. Static-linking everything

**Stali**, **Oasis**, **Morpheus** all ship 100% statically-linked distros.
[sta.li](https://sta.li/), [Oasis on GitHub](https://github.com/oasislinux/oasis).

Benefits for PoC:
- No dynamic linker — no ld-musl.so to scramble separately, no PLT/GOT/dlopen.
- Trivial proof: stock dynamic binary fails immediately (no compatible ld.so);
  stock static binary fails when its `syscall`/library asm hits the scrambled
  kernel/libc convention boundary.
- Cost: musl + BusyBox static ≈ 1–2 MB; full distro ~50 MB.

**Strongly recommend static-only** — eliminates an entire axis of complexity.

(Caveat: if demonstrating *broken dynamic linking* is the headline, we need
at least one dynamic library. See STATE.md open questions.)

## 7. Reproducible Builds

Canonical mitigation: `SOURCE_DATE_EPOCH`.
[reproducible-builds.org](https://reproducible-builds.org/docs/source-date-epoch/).

**Treat the scramble seed exactly like `SOURCE_DATE_EPOCH`** — single env
variable, baked into output, deterministic, no implicit fallback. Build same
package twice with same seed → byte-identical output. Also what makes GCC's
stage2/stage3 compare work (§3).

## 8. Bootstrappable Builds (Guix Mes)

Guix's full-source chain rises from a **357-byte hex0 binary** through
Stage0-POSIX → **GNU Mes** (~5k LOC C+Scheme) → MesCC → TinyCC → GCC →
22,000-package system.
[Guix 2023 blog](https://guix.gnu.org/en/blog/2023/the-full-source-bootstrap-building-from-source-all-the-way-down/),
[Mes manual](https://www.gnu.org/software/mes/manual/mes.html),
[LWN 983340](https://lwn.net/Articles/983340/),
[bootstrappable.org/mes](https://bootstrappable.org/projects/mes.html).

**Why it matters here:** threat model includes compiler trust (Thompson
"trusting trust"). The *only* defense is auditable bootstrap from a seed
small enough to verify by eye. For encrypted-linux to be **trustworthy at
the compiler level**, the scrambling GCC ideally bootstraps from Mes/TinyCC
with the scrambling patch applied at a layer auditable from hex0.

**PoC compromise:** build scrambling-GCC from an audited un-scrambled GCC
source tarball + your patch. Defer full Mes bootstrap to v2.

## 9. Fast iteration stack

**Buildroot** is the right development harness: ~10k LoC of Make, full minimal
build in ~15 min vs Yocto's hours, native QEMU image generation
(`qemu_x86_64_defconfig`), trivial to swap toolchain.
[Buildroot vs Yocto (Incredibuild)](https://www.incredibuild.com/blog/yocto-or-buildroot-which-to-use-when-building-your-custom-embedded-systems).

Recommended dev loop:
1. Patched scrambling-GCC built once → packaged as Buildroot external toolchain.
2. Buildroot `BR2_TOOLCHAIN_EXTERNAL_CUSTOM` + musl + static-only.
3. `make` → `output/images/bzImage` + rootfs.cpio.
4. `qemu-system-x86_64 -kernel … -initrd … -nographic` — boots in seconds.
5. Mount a stock Alpine static busybox as 9p share, attempt to exec it → must
   SIGILL / segfault. That's the demo.

## 10. Minimum PoC package set

To prove "stock binaries don't run":

| Component | Package | Notes |
|---|---|---|
| Kernel | linux (scrambled-built) | preserve userspace syscall ABI |
| Libc | **musl** (scrambled-built, static) | only libc |
| Shell + utils | **BusyBox** (scrambled-built, static) | sh, ls, cat, mount, init |
| Init | BusyBox init | no separate package |
| Demo binary | `hello` built both ways (scrambled vs stock) | proof artifact |

**Five binaries total** — below Tiny Core's footprint, within a single-day
Buildroot iteration cycle.

---

## Concrete recommendation

**Fork Buildroot as the build harness; target a musl + BusyBox + static-only
runtime modeled on Oasis/Morpheus.**

1. Buildroot — fastest scrambled-GCC iteration loop (~15 min full rebuilds,
   swap-in custom toolchain is one config switch, native QEMU).
2. musl — ~30× smaller than glibc, dramatically less coupled to GCC internals.
3. Static-only (Oasis/Morpheus/Stali model) — eliminates the dynamic linker
   as attack surface and porting problem. Demo becomes unambiguous.
4. BusyBox — collapses userland to one binary; scramble-build exactly libc +
   one program + kernel.
5. Disable GCC 3-stage bootstrap (`--disable-bootstrap`) for PoC; treat seed
   as `SOURCE_DATE_EPOCH`-equivalent; defer Mes/Stage0 bootstrap to v2.

Slackware, NixOS, LFS-proper, Yocto are wrong (too many packages, glibc-bound,
slow iteration, or wrong abstraction). Tiny Core is close but glibc.
Alpine is closest production reference but heavier than needed — borrow its
musl+BusyBox philosophy via Buildroot rather than forking Alpine.

## Sources

- [LFS 12.1 Book](https://www.linuxfromscratch.org/lfs/downloads/12.1/LFS-BOOK-12.1.pdf), [GCC Pass 1](https://www.linuxfromscratch.org/lfs/view/stable/chapter05/gcc-pass1.html)
- [GCC Install: Building / Bootstrap](https://gcc.gnu.org/install/build.html)
- [SlackBuilds.org](https://slackbuilds.org/), [SlackDocs](https://docs.slackware.com/slackware:slackbuild_scripts)
- [Alpine about](https://alpinelinux.org/about/), [Alpine→musl](https://www.alpinelinux.org/posts/Alpine-Linux-has-switched-to-musl-libc.html)
- [musl FAQ](https://www.musl-libc.org/faq.html), [functional differences](https://wiki.musl-libc.org/functional-differences-from-glibc.html), [tuxcare](https://tuxcare.com/blog/musl-vs-glibc/), [Linaro: glibc on LLVM](https://www.linaro.org/blog/building-glibc-with-llvm-the-how-and-why/), [MaskRay glibc](https://maskray.me/blog/2022-05-29-glibc)
- [sta.li](https://sta.li/), [Oasis](https://github.com/oasislinux/oasis)
- [SOURCE_DATE_EPOCH](https://reproducible-builds.org/docs/source-date-epoch/), [spec](https://reproducible-builds.org/specs/source-date-epoch/)
- [Guix bootstrap 2023](https://guix.gnu.org/en/blog/2023/the-full-source-bootstrap-building-from-source-all-the-way-down/), [Mes manual](https://www.gnu.org/software/mes/manual/mes.html), [LWN 983340](https://lwn.net/Articles/983340/), [bootstrappable.org/mes](https://bootstrappable.org/projects/mes.html)
- [Buildroot vs Yocto](https://www.incredibuild.com/blog/yocto-or-buildroot-which-to-use-when-building-your-custom-embedded-systems)
- [Tiny Core Linux](http://www.tinycorelinux.net/)
- [Kernel ABI README](https://www.kernel.org/doc/Documentation/ABI/README), [Kernel ABI docs](https://docs.kernel.org/admin-guide/abi.html), [LWN kernel ABI](https://lwn.net/Articles/726021/)
