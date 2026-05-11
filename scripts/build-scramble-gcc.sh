#!/usr/bin/env bash
#
# scripts/build-scramble-gcc.sh — build the patched cross-targeting GCC
# inside the encrypted-linux-gcc Docker image.
#
# Configures GCC as: host=arm64/x86_64 native, target=x86_64-linux-gnu,
# C-only, single-stage (--disable-bootstrap), no libc target (since we're
# only testing -S assembly output, not linking). Builds only the compiler
# proper (`all-gcc`), not libgcc/libstdc++/libgomp — ~15-30 min.
#
# Inputs:
#   $ENCRYPTED_LINUX_SEED — 64 hex chars. If unset, default falls back to
#     ./seed at the repo root. If still unset, identity permutation
#     (= byte-identical to stock GCC).
#
# Outputs:
#   build/scramble-gcc/install/bin/x86_64-linux-gnu-gcc — the patched
#     cross-compiler. Use it as:
#       build/scramble-gcc/install/bin/x86_64-linux-gnu-gcc -S foo.c -o foo.s
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

SEED="${ENCRYPTED_LINUX_SEED:-$(cat seed 2>/dev/null || true)}"
if [ -n "${SEED}" ]; then
    echo "Building patched GCC with seed: ${SEED:0:16}..."
else
    echo "Building patched GCC with IDENTITY permutation (no seed)"
fi

mkdir -p build/scramble-gcc/{src,build,install}

cat > tmp-build-driver.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail
cd /opt/gcc-14

# 1. Apply the encrypted-linux patch.
echo "=== Applying patches/scramble-gcc-v0.patch ==="
patch -p1 < /work/patches/scramble-gcc-v0.patch

# 2. Run the header generator with the seed (if any).
if [ -n "${SEED:-}" ]; then
    echo "=== Generating permuted encrypted-linux-perm.h ==="
    ENCRYPTED_LINUX_SEED="${SEED}" python3 /work/scripts/gen-gcc-arg-perm.py \
        --seed "${SEED}" \
        -o gcc/config/i386/encrypted-linux-perm.h \
        --verbose
fi

# 3. Configure.
mkdir -p /build && cd /build
echo "=== Configuring cross-targeting GCC ==="
/opt/gcc-14/configure \
    --target=x86_64-linux-gnu \
    --prefix=/work/build/scramble-gcc/install \
    --disable-bootstrap \
    --disable-multilib \
    --disable-libssp \
    --disable-libquadmath \
    --disable-libstdcxx \
    --disable-libgomp \
    --disable-libatomic \
    --disable-libsanitizer \
    --without-headers \
    --enable-languages=c \
    --with-newlib \
    > /work/build/scramble-gcc/configure.log 2>&1
echo "configure done"

# 4. Build only the compiler proper.
echo "=== make all-gcc (this is the long step, ~15-30 min) ==="
make -j"$(nproc)" all-gcc > /work/build/scramble-gcc/build.log 2>&1
echo "make all-gcc done"

# 5. Install.
echo "=== make install-gcc ==="
make install-gcc > /work/build/scramble-gcc/install.log 2>&1
echo "install done"

# 6. Smoke check.
echo "=== Smoke check ==="
/work/build/scramble-gcc/install/bin/x86_64-linux-gnu-gcc --version | head -2
INSIDE
chmod +x tmp-build-driver.sh

docker run --rm --user root \
    -e SEED="${SEED}" \
    -v "$PWD":/work \
    encrypted-linux-gcc \
    bash /work/tmp-build-driver.sh

rm -f tmp-build-driver.sh
echo ""
echo "Built: build/scramble-gcc/install/bin/x86_64-linux-gnu-gcc"
