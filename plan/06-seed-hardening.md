# Plan 06 — Seed Hardening (backlog)

**Status: BACKLOG. Not started.** Address after other features land.

The current encrypted-linux design treats the seed as
**recoverable-but-non-trivial-to-recover**. Anyone with one
scrambled binary on disk can disassemble a few function prologues
and reconstruct enough of the seed to (a) understand the per-system
permutations and (b) forge new valid syscalls.

This file scopes the cryptographic hardening work to push the
seed toward **undiscoverable** — defended-in-depth, not just
defended-by-uniqueness.

## Where the seed currently leaks

| Surface | What's leaked | Cost to recover |
|---|---|---|
| Userspace ELF prologues | Phase 1 arg-register permutation (6! = 720 possibilities). Single function with two-plus args narrows it. | Seconds, with any `objdump` |
| Userspace `movabsq` syscall stubs | Overkill syscall numbers (full 64-bit value per syscall name). | Single function call reveals which name maps to which u64 |
| `vmlinux` + debuginfo | Both syscall-number table AND struct layouts | Seconds, if attacker has vmlinux |
| Build artifacts (Docker images, intermediate `.o` files) | Same content, same recoverability | Seconds |
| The repo itself (`./seed`) | **Plaintext, public, intentional** for the PoC | Trivial |

The PoC chose plaintext seed on purpose — see `SEED.md`. The defense
is per-system **uniqueness**, not seed concealment. This file is
about what we'd add IF we wanted concealment too.

## Threat models to handle separately

### TM-A: Attacker has the running VM, no disk access

Today: can disassemble in-memory text segments, recover everything.
Future: same as TM-B (any on-disk binary equivalently leaks).

### TM-B: Attacker has any single scrambled binary on disk

Today: full seed-state recovery in seconds.
Goal: raise to cryptographic infeasibility.

### TM-C: Attacker has the build farm + master seed

Today: total compromise.
Goal: orthogonal (KMS / HSM territory; not addressed here).

## Hardening options, low to high cost

### Option 1 — Per-binary diversification (cheap, partial)

Instead of one seed driving all binaries on a system, have **each
binary** receive a unique sub-seed at link time. Add the sub-seed
as an ELF-note (encrypted with the master).

- Defeats: bulk-disassembly-based seed reconstruction. Each binary
  reveals only its own sub-permutation.
- Limit: attacker who collects enough binaries reconstructs the
  PRF tree.
- Cost: ~1 day. Linker patch to inject per-binary salt; build
  pipeline to invoke linker with `--seed <salt>` per .o set.

### Option 2 — Strip seed-derived state from binaries (medium)

Currently the 64-bit syscall numbers are visible as `movabsq`
immediates inside the binary. Same for the mangled symbol names.

Alternative: store the seed-derived values in a hash table inside
the binary, looked up at runtime via a small key (e.g., a CRC of
the canonical name). The values themselves never appear as
immediates.

- Defeats: simple disassembly recovery.
- Limit: an attacker who runs the binary AND watches its memory
  still recovers the values.
- Cost: 3-5 days. Custom linker pass + a tiny runtime stub.

### Option 3 — Whitebox crypto on the dispatch (hard)

Implement the syscall dispatch and ABI permutation as **whitebox
crypto** — i.e., the binary contains lookup tables whose contents
encode the permutation but cannot be inverted without enormous
effort even with full access to the binary.

- Defeats: static + dynamic recovery up to whitebox attack research
  literature's ~2¹⁰⁰ practical bound on AES whitebox.
- Limit: actively researched area; production-grade whitebox is
  proprietary; academic implementations are typically broken within
  months.
- Cost: weeks. Plus license/IP for any commercial whitebox library.

### Option 4 — Hardware root of trust (TPM / SEV-SNP / TDX)

Sealed measurement-based attestation. The seed is held inside a
TPM and never exposed to host RAM in plaintext. SEV-SNP / TDX
encrypts memory itself.

- Defeats: anyone without physical hardware access.
- Limit: hardware-specific, complicates portability and the
  Buildroot-style reproducibility story.
- Cost: weeks to months. Significant integration work + hardware
  inventory.

### Option 5 — Move the dispatch into encrypted code (very hard)

Run the kernel itself under HE-style encrypted execution. This is
the Encrypted Execution paper's ultimate vision (`research/01`).
The dispatch logic, including which syscall is which, lives only
in ciphertext.

- Defeats: everything short of breaking the underlying cipher.
- Limit: enormous performance cost; no known production-grade FHE
  scheme is fast enough for OS kernels.
- Cost: open research problem. Years.

## Concrete first step (when we resume this)

**Option 1, the per-binary sub-seed** is the highest leverage for
the lowest cost. It's compatible with everything else we've built:

1. Linker post-pass (script) generates a per-binary salt.
2. The sub-seed = HMAC(master, "binary." || hash(binary.path)).
3. Re-derive arg-register permutation and symbol mangling using
   the sub-seed instead of the master directly.
4. Store the sub-seed (or its hash) in an ELF note for diagnostic
   purposes (not for the loader — loader doesn't need it because
   the sub-seed only affects compile-time decisions).
5. Kernel-side: nothing changes; syscall numbers stay per-build,
   not per-binary.

This raises the cost of "one binary reveals all" to "one binary
reveals only itself, and the master seed remains protected by HMAC
preimage resistance."

## Decision pending

After this implementation, the project will be in this position:

- **Per-system uniqueness**: very strong (we have this today).
- **Per-binary uniqueness**: weak (one binary leaks the whole
  system).
- **Seed confidentiality**: nil (deliberate for PoC).

Next session: confirm whether to pursue Option 1 (per-binary
diversification), accept the current posture, or pivot to a
different goal entirely (e.g., production-hardening the build
pipeline, or shipping a usable distro).

## Related research (cite when implementing)

- Polyverse's "Container Cycler" (`research/07` §3) — re-scrambling
  every few seconds was their answer to seed disclosure. We could
  do the same for production deployments.
- Bhatkar et al. *Address Obfuscation* — per-execution diversity
  as a defense against static analysis.
- Larsen et al. *SoK: Automated Software Diversity* — the academic
  framing of "moving target vs unique target" — useful for
  positioning whatever we ship.
- whitebox crypto: Chow et al. *White-Box Cryptography and an AES
  Implementation* (2002) for the foundational design; recent
  literature on attacks (e.g., DCA, BGE) for the realistic bound.

## Why not now

Pursuing this before the user-visible demos all work would be
premature optimization. The PoC's threat model is "moving target /
unique target" — already valuable. Adding cryptographic
undiscoverability is a force multiplier, not a prerequisite.
