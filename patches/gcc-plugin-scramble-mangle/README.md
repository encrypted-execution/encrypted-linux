# gcc-plugin-scramble-mangle

A GCC plugin that mangles external C function symbol names at compile
time, using the same algorithm as `scripts/scramble-mangle.sh`.

## What it does

For each `extern` C function in the translation unit, the plugin
rewrites the symbol's assembler name from `foo` to
`foo__abi_<8hex>`, where `<8hex>` is the first 32 bits of
`HMAC-SHA256(USER_ABI_SEED, "foo")` and
`USER_ABI_SEED = HMAC-SHA256(master_seed, "user.abi")`.

The master seed is read from `$ENCRYPTED_LINUX_SEED` at plugin
init (64 hex chars). The salt strings are frozen and identical
to `scripts/seed-lib.py` and `scripts/seed-lib.sh`.

## What it replaces

`scripts/scramble-mangle.sh` (post-link `objcopy --redefine-syms`).
Both produce byte-identical mangled-symbol output for the same seed
and same source. The plugin path is what we ship; the bash post-pass
is kept for testing and for handling objects we did not compile
ourselves (third-party pre-built `.o` or `.a`).

## What it does NOT do

- Does not permute argument or callee-saved registers — that requires
  a real backend patch to `gcc/config/i386/i386.cc`. See plan/01 M1+M3.
- Does not touch C++ Itanium-mangled symbols (`_Z*`).
- Does not touch static (internal-linkage) functions.
- Does not touch decls whose assembler name was set explicitly via
  `asm("foo")` — that's the escape hatch for hand-written symbols and
  syscall stubs.
- Does not touch the exclusion list: `main`, `syscall`, `_*`, `.*`,
  already-`*__abi_*` (idempotency).

## Build

```
sudo apt-get install -y gcc-13-plugin-dev libssl-dev   # Debian/Ubuntu
make
```

`make` produces `scramble-mangle.so`.

## Usage

```
export ENCRYPTED_LINUX_SEED=$(cat /path/to/repo/seed)
gcc -fplugin=./scramble-mangle.so myprog.c -c -o myprog.o
nm myprog.o   # expect 'compute__abi_<hex>' etc.
```

Setting `SCRAMBLE_MANGLE_VERBOSE=1` prints a one-line load banner to
stderr.

## Smoke test

```
make check   # build + verify "compute" gets mangled
```

The full Phase-1 demo (three link cases via the plugin path) lives at
`scripts/scramble-mangle-test/test-plugin.sh` and runs as part of
`make demo-plugin` from the repo root.

## Plugin loading model

The plugin registers a `PLUGIN_FINISH_DECL` callback. GCC fires this
event once per declaration after parsing. We mangle there, which is
late enough that the front-end has resolved the C identifier and
early enough that subsequent middle/back-end passes see the renamed
assembler name.

## Why a plugin and not a real backend patch

Per `research/04-gcc-calling-convention-internals.md` §5: a plugin
cannot cleanly replace the *calling convention* (it runs after
hard-reg sets and target hooks are frozen). But name mangling is a
front-end operation, perfectly handled by `PLUGIN_FINISH_DECL`. The
plugin captures Phase 1 mangling (~150 LOC); the calling convention
itself comes later via a real backend patch.

## Determinism / reproducibility

Given the same `ENCRYPTED_LINUX_SEED` and the same source, `gcc
-fplugin=./scramble-mangle.so` is fully deterministic — no timestamps
or PIDs feed into the mangled names. Two builds → byte-identical
`.o`. Required for `SOURCE_DATE_EPOCH`-style reproducibility (plan/00
§2).
