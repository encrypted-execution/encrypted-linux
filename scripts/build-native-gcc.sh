#!/usr/bin/env bash
#
# scripts/build-native-gcc.sh — build the patched scrambling GCC as a
# NATIVE x86_64 binary so it can run inside the encrypted-linux QEMU VM.
#
# Builds inside the encrypted-linux-gcc:amd64 Docker image, which runs
# under linux/amd64 (QEMU emulation on arm64 macOS hosts). Wall time:
# 60-120 min under emulation. On a native x86_64 host: 15-25 min.
#
# Output:
#   build/native-gcc/install/  — installed cross-compiler-as-self-host
#                                (target=x86_64-linux-gnu but it's a
#                                native x86_64 binary, deployable to
#                                the QEMU guest).
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

SEED="${ENCRYPTED_LINUX_SEED:-$(cat seed 2>/dev/null || true)}"
echo "Building NATIVE x86_64 scrambling GCC with seed: ${SEED:0:16}..."

mkdir -p build/native-gcc/install

cat > tmp-native-driver.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail
cd /opt/gcc-14

# Apply the encrypted-linux patch + run the permuted-header generator.
echo "=== patches/scramble-gcc-v0.patch ==="
patch -p1 < /work/patches/scramble-gcc-v0.patch

echo "=== Generating permuted encrypted-linux-perm.h ==="
ENCRYPTED_LINUX_SEED="${SEED}" python3 /work/scripts/gen-gcc-arg-perm.py \
    --seed "${SEED}" \
    -o gcc/config/i386/encrypted-linux-perm.h --verbose

mkdir -p /tmp/build && cd /tmp/build
echo "=== Configuring NATIVE x86_64 GCC (target-libs disabled) ==="
/opt/gcc-14/configure \
    --target=x86_64-linux-gnu \
    --prefix=/work/build/native-gcc/install \
    --disable-bootstrap \
    --disable-multilib \
    --disable-libssp \
    --disable-libquadmath \
    --disable-libstdcxx \
    --disable-libgomp \
    --disable-libatomic \
    --disable-libitm \
    --disable-libada \
    --disable-libvtv \
    --disable-libsanitizer \
    --without-headers \
    --with-newlib \
    --enable-languages=c \
    > /work/build/native-gcc/configure.log 2>&1
echo "configure done"

echo "=== make all-gcc (compiler only — no target libs) ==="
make -j"$(nproc)" all-gcc > /work/build/native-gcc/build.log 2>&1
echo "make all-gcc done"

echo "=== make install-gcc ==="
make install-gcc > /work/build/native-gcc/install.log 2>&1
echo "install done"

/work/build/native-gcc/install/bin/x86_64-linux-gnu-gcc --version | head -2
INSIDE
chmod +x tmp-native-driver.sh

docker run --rm --platform linux/amd64 --user root \
    -e SEED="${SEED}" \
    -v "$PWD":/work \
    encrypted-linux-gcc:amd64 \
    bash /work/tmp-native-driver.sh

rm -f tmp-native-driver.sh
echo "Built: build/native-gcc/install/bin/gcc"
