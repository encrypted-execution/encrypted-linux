# scramble-gcc-test

End-to-end test for `patches/scramble-gcc-v0.patch` — the actual GCC
backend patch (not the post-compile mangler, not the GCC plugin —
this is the real-backend version).

## What it tests

Compiles six trivial identity functions:

```c
int id0(int a)                                                   { return a; }
int id1(int a, int b)                                            { ...; return b; }
int id2(int a, int b, int c)                                     { ...; return c; }
int id3(int a, int b, int c, int d)                              { ...; return d; }
int id4(int a, int b, int c, int d, int e)                       { ...; return e; }
int id5(int a, int b, int c, int d, int e, int f)                { ...; return f; }
```

Each is a single-instruction function whose body is `mov %<argN>, %eax;
ret`. Under stock SysV AMD64, the argN register is always one of
`%edi, %esi, %edx, %ecx, %r8d, %r9d` in that order.

Under the patched GCC with the PoC seed, the test confirms each idN
reads from the register dictated by:

```
USER_ABI_SEED = HMAC-SHA256(master, "user.abi")
ARG_REG_SEED  = HMAC-SHA256(USER_ABI_SEED, "x86_64.arg_regs")
perm          = Fisher-Yates([0..5], ARG_REG_SEED)
```

For the project seed `7f3da9...006392`, this produces a 3-cycle:
```
arg0 RDI -> RDX
arg1 RSI -> RSI  (fixed)
arg2 RDX -> RCX
arg3 RCX -> RDI
arg4 R8  -> R8   (fixed)
arg5 R9  -> R9   (fixed)
```

So `id0(int a)` compiles to `movl %edx, %eax; ret` instead of
`movl %edi, %eax; ret`. Same for the other shifted slots.

## Prerequisites

- `make gcc-image` — staged GCC 14 source image
- `make gcc-build` — actually compiles the patched cross-compiler
  (~15-30 min wall-time, single-engineer-week of work compressed
  into a build)

## Run

```
make demo-gcc
```

or directly:

```
docker run --rm --user root -v "$PWD":/work -w /work encrypted-linux-gcc \
    bash scripts/scramble-gcc-test/test.sh
```

Expected output: 9 PASS / 0 FAIL.

## Interpreting the output

The test prints both the expected permutation (from
`scripts/gen-gcc-arg-perm.py`) and the actual register usage
disassembled from the patched compiler's output. The two must agree;
that's the proof.
