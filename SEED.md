# The `seed` file

A single file at the repo root, containing 64 hex characters (256 bits).
It is the project's master scrambling key.

## Properties

- **Public.** Checked into git. Anyone cloning the repo can see it.
- **Deterministic.** Same `seed` + same source = byte-identical builds.
- **Not a runtime secret.** The seed is not consulted at runtime by any
  shipped binary. It is consumed only by the build host.
- **Not a confidentiality boundary.** See `plan/03 §1`. The defense is
  per-system uniqueness; an attacker with one scrambled binary can
  recover the ABI permutation regardless of whether they have the seed.

## How the seed flows through the build

1. `scripts/seed-lib.py` reads `./seed` and derives three sub-seeds via
   HMAC-SHA256:
   - `USER_ABI_SEED`   = HMAC(seed, "user.abi")
   - `KERNEL_ABI_SEED` = HMAC(seed, "kernel.abi")
   - `SYSCALL_SEED`    = HMAC(seed, "syscall.numbers")
2. The scrambling GCC reads `ENCRYPTED_LINUX_SEED=$(cat seed)` at
   `configure` time and bakes the sub-seed-derived permutations into
   its binary.
3. `scripts/gen-unistd-seeded` reads the same seed and emits the
   renumbered syscall header for the kernel and matching glibc/musl
   stubs.
4. Every emitted ELF object carries a `.note.encrypted-linux` PT_NOTE
   containing the 32-bit hash of the seed; the dynamic linker (and,
   in Phase 2, the kernel `binfmt_elf`) refuses to load an ELF whose
   note doesn't match the host's.

## The PoC seed

`7f3da98edf5ba694c25fd3405776c0414f3815d448cbca81cae75b9213006392`

Derived as:

```
printf 'encrypted-linux PoC seed v0' | shasum -a 256
```

Anyone wanting to verify the PoC build reproduces should leave this
value untouched. To produce a *different* coherent system, replace
`./seed` with any 64 hex chars and rebuild. Two systems with different
seeds are mutually incompatible by design.

## Per-deployment seed

For a real deployment (post-PoC), the build farm holds a private seed
per customer / per tenant, not the public one in this repo. The farm
rebuilds the closure and publishes only the resulting binaries — the
seed never leaves the farm. This is the Polyverse repo-mirror model
(`research/07 §3`).
