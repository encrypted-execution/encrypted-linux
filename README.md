# encrypted-linux

A Linux distribution built with a scrambling GCC, such that programs
built outside the closure of the build cannot execute on the target.

This is an instantiation of the **Encrypted Execution** thesis
([whitepaper](https://www.encrypted-execution.com), Gore 2025) at the
`<compiler-codegen-backend, ISA>` layer — the extreme case the paper
itself names (whitepaper p. 10, item 4).

## Status

**Plan complete. Implementation not started.**

Seven research dossiers in `research/` and five planning documents in
`plan/`. See `STATE.md` for the live state, including the locked-in
decisions and the parallel-track schedule from `plan/05`.

## What encrypted-linux is

A diversity defense. Every build of the system has a unique cross-TU
calling convention and unique external-symbol names, parameterized by
a seed checked into the repo (or held privately per-deployment for
real installations).

- A binary built with stock GCC cannot dynamically link against this
  system's `libc.so` — it fails at load time with `undefined symbol:
  printf__abi_<hex>`.
- (Phase 2) A static stock binary fails on its first syscall with
  `-ENOSYS`, because the syscall numbers have been renumbered too.
- (Phase 2) External kernel modules built against stock headers cannot
  load — the existing `modversions` CRC machinery rejects them.

The defense is the per-system uniqueness, not concealment of the seed.
See `plan/03-risks-and-honest-limitations.md` for the honest threat
model.

## What encrypted-linux is NOT

- Not a confidentiality boundary. The seed is recoverable from any
  scrambled binary on disk.
- Not a defense against logic bugs, data-only attacks, or attackers
  who own the build farm.
- Not a Polyverse rerun. Polyverse's Polymorphic Linux preserved the
  calling convention; encrypted-linux scrambles exactly that boundary,
  with all the new engineering risk that implies. See
  `research/07-polyverse-polymorphic-linux.md`.

## Repository layout

```
encrypted-linux/
├── README.md                    (this file)
├── STATE.md                     (live status, decisions, next steps)
├── LICENSE                      (Apache-2.0)
├── SEED.md                      (how the seed flows through the build)
├── seed                         (the master scrambling key, public)
├── plan/                        (5 documents — design, phases, risks, PoC)
├── research/                    (7 dossiers — paper, scrambler, randstruct, GCC, distro, threat model, Polyverse)
├── patches/                     (source patches for GCC, musl, kernel)
├── scripts/                     (build-time helpers; seed-lib, generators)
├── buildroot/                   (BR2_EXTERNAL tree)
└── docs/                        (user-facing docs, demo asciicast)
```

## Build the PoC (planned — not implemented yet)

```
git clone https://github.com/encrypted-execution/encrypted-linux
cd encrypted-linux
make
./scripts/qemu.sh
```

The demo:

```
encrypted-linux:~$ /bin/hello
hello, encrypted linux
encrypted-linux:~$ /bin/stock-hello
Error relocating /bin/stock-hello: printf: symbol not found
encrypted-linux:~$ cat /etc/encrypted-linux/seed
7f3da98edf5ba694c25fd3405776c0414f3815d448cbca81cae75b9213006392
```

See `plan/04-smallest-proof-of-concept.md` for the milestone-by-
milestone build sequence (4 weeks single-engineer to first asciicast).

## How to read this repo

If you want to understand **why** encrypted-linux exists, read in this
order:

1. `research/01-encrypted-execution-thesis.md` — the paper, summarized
2. `research/07-polyverse-polymorphic-linux.md` — Polyverse's prior
   commercial work, and what encrypted-linux extends
3. `research/06-dynamic-linking-and-threat-model.md` — honest threat
   model
4. `plan/00-design-principles.md` — the 11 load-bearing decisions
5. `plan/03-risks-and-honest-limitations.md` — what this is NOT

If you want to **build** encrypted-linux, read in this order:

1. `plan/04-smallest-proof-of-concept.md` — the 4-week PoC
2. `plan/05-parallel-tracks.md` — dependency graph for parallel work
3. `plan/01-phase1-userland-scrambling.md` — Track A
4. `plan/02-phase2-kernel-scrambling.md` — Track B
5. `research/04-gcc-calling-convention-internals.md` — what to touch
   in `gcc/config/i386/i386.cc`
6. `research/05-distro-bootstrap-options.md` — the harness story

## License

Apache-2.0. See `LICENSE`.

Patent posture: USPTO 10,733,303 (Polymorphic Code Translation Systems
and Methods, Gore et al.) is publicly pledged to the public domain by
the author. Polyverse's binary-scrambling patents (US 10,127,160 and
US 2019/0371209) are covered by the Open Invention Network's Linux-
system non-aggression cross-license, which Polyverse joined in 2018.
See `research/07 §9`.
