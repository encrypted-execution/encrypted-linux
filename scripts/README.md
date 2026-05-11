# scripts/

Build-time helpers. Pure functions of `(input files, seed)` — no
network access, no nondeterminism.

| Script | Purpose | Track | Status |
|---|---|---|---|
| `seed-lib.py` (or `.go`) | Derive sub-seeds via HMAC-SHA256 | shared | not started |
| `gen-unistd-seeded` | Read `syscall_64.tbl` + seed; emit renumbered header + kernel dispatch table | B1 | not started |
| `gen-abi-perm` | Read seed; emit GCC backend constants (arg-register permutation, callee-saved permutation) for the scramble-gcc patch | A1+A3 | not started |
| `gen-elf-note` | Emit a `.note.encrypted-linux` PT_NOTE section payload (seed hash) | A6 | not started |
| `verify-determinism.sh` | Build twice, `diff -r` the outputs | CI | not started |

## Seed derivation contract

All scripts read a single seed file at `${REPO}/seed` (64 hex chars =
256 bits). All sub-seeds derive deterministically:

```
USER_ABI_SEED   = HMAC-SHA256(seed, "user.abi")
KERNEL_ABI_SEED = HMAC-SHA256(seed, "kernel.abi")
SYSCALL_SEED    = HMAC-SHA256(seed, "syscall.numbers")
```

The salt strings are frozen on day-two of implementation and never
changed. Changing a salt = breaking every downstream build.

## Determinism contract

- Same `seed` + same inputs → byte-identical outputs.
- No `$RANDOM`, no `date`, no `$$`, no `mktemp` in output paths, no
  iteration over `set` (Python pre-3.7 hash randomization, etc.).
- CI runs `verify-determinism.sh` on every PR.

## No runtime use

Nothing in `scripts/` ships on the target system. These run only on
the build host. The artifacts they produce are baked into binaries
(GCC backend constants, the seeded `unistd.h`, etc.).
