# Path to a working in-VM GCC (TODO for next iteration)

The current encrypted-linux image bundles a native x86_64 scrambling GCC
at `/usr/local-gcc/`. When invoked inside the VM it segfaults during
`ld-linux-x86-64.so.2` initialization. **The bundled gcc was dynamically
linked against glibc, and glibc's loader issues canonical syscall
numbers — but our kernel has only the permuted ones.** Result: every
syscall during loader init goes to the wrong handler and crashes.

## Why this is the same problem as Phase 1 musl rebuild

Both require the same step: produce a GCC binary that itself uses the
PERMUTED syscall ABI. That means:

- The gcc binary must be linked against **our** permuted musl (not
  glibc, not unpermuted musl).
- Building it requires libgcc to exist against musl headers/libs.

## The path forward

Use the existing scrambled musl at `build/image/sysroot/` as the
"target libc" when building a new gcc.

```
# Inside the encrypted-linux-image-build container:
CC=/work/build/image/sysroot/usr/bin/musl-gcc \
LDFLAGS="-static" \
/opt/gcc-14/configure \
    --target=x86_64-linux-gnu \
    --prefix=/work/build/permuted-gcc/install \
    --disable-bootstrap \
    --disable-multilib \
    --disable-libstdcxx \
    --disable-libgomp \
    --disable-libatomic \
    --disable-libsanitizer \
    --with-sysroot=/work/build/image/sysroot \
    --enable-static \
    --enable-languages=c
make -j$(nproc) all-gcc
make install-gcc
```

The catch: GCC's own configure runs many feature-detection programs.
Each tries to link a tiny test against the host C library. With
`CC=musl-gcc -static`, the tests link our scrambled musl statically.
Some tests may fail or produce false negatives. Hand-tuned configure
flags will be needed.

Estimated effort: 1-2 days of single-engineer work, mostly debugging
configure issues. The result is a GCC binary statically linked against
scrambled musl that:
- Runs on our permuted-kernel VM
- Compiles programs that also run on our permuted-kernel VM
- Optionally: applies Phase 1 register permutation via the existing
  scrambling-gcc patch (currently active in
  `build/native-gcc/install/`).

## Workaround for now

Programs are pre-compiled on the host (using
`scripts/build-image.sh` and `scripts/rebuild-image-userland.sh`)
and shipped INTO the image via the initramfs. Users cannot compile
new programs inside the VM with the current image.

The pre-compiled hello and busybox both work correctly and demonstrate
the cross-host failure mode.

## Same path solves Phase 1 ABI scrambling

Today the rootfs musl uses canonical SysV ABI plus permuted syscalls.
To add Phase 1 register permutation (RDI→RDX, RDX→RCX, etc.) to musl's
own internal C functions, build musl with the scrambling GCC at
`build/native-gcc/install/bin/x86_64-linux-gnu-gcc`. This requires the
SAME libgcc-against-musl bootstrap step above.

After the bootstrap lands, build pipeline becomes:

1. Stage1: kernel + scrambled-musl-with-canonical-ABI (current state)
2. Stage2: libgcc against stage-1 musl (new step)
3. Stage3: scrambled-musl-with-permuted-ABI using stage-1 gcc + stage-2 libgcc
4. Stage4: final gcc statically linked against stage-3 musl
5. Stage5: rebuild rootfs userland with stage-4 gcc + stage-3 musl

This is the standard musl-cross-make dance, applied to our patches.

## Why we punted on this for v0

`build-image.sh` + `rebuild-image-userland.sh` already demonstrate the
Phase 2 syscall-renumbering failure end-to-end. Adding Phase 1 ABI
scrambling to the rootfs would not add a new VISIBLE failure mode
(both binaries already fail on stock hosts). Phase 1's *value* is the
load-time `undefined symbol` failure mode for dynamic libraries, which
is already demonstrated by `make demo-mangle` and `make demo-plugin`
in the separate test suites.

The integration is mechanical once the bootstrap lands; it doesn't
require new design work. Logging here so the next engineer can pick
it up cleanly.
