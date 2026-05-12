#!/usr/bin/env bash
#
# scripts/build-static-musl-gcc.sh — build a scrambling GCC binary that
# is STATICALLY linked against our permuted musl, so it can run inside
# the encrypted-linux QEMU image (where the kernel has permuted syscall
# numbers).
#
# Builds inside encrypted-linux-gcc-static-musl (Alpine + build-base).
# Alpine ships gcc/g++ already linked against musl; we replace Alpine's
# musl with our PERMUTED musl, then build gcc statically. Result: gcc
# binary uses permuted syscalls.
#
# Output: build/static-gcc/install/  — the static scrambling GCC.
#
# Wall time: 30-90 min under QEMU emulation on arm64 macOS.
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

SEED="${ENCRYPTED_LINUX_SEED:-$(cat seed)}"
echo "Building static scrambling GCC with seed: ${SEED:0:16}..."

test -d build/image/sysroot/usr/include || {
    echo "ERROR: musl sysroot not built. Run scripts/build-image.sh first."
    exit 1
}

mkdir -p build/static-gcc

cat > tmp-static-driver.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail

echo "=== Apply scrambling-GCC patch ==="
cd /opt/gcc-14
if ! grep -q encrypted-linux-perm.h gcc/config/i386/i386.cc; then
    patch -p1 < /work/patches/scramble-gcc-v0.patch
fi

echo "=== Generate permuted arg-register header ==="
ENCRYPTED_LINUX_SEED="${SEED}" python3 /work/scripts/gen-gcc-arg-perm.py \
    --seed "${SEED}" \
    -o gcc/config/i386/encrypted-linux-perm.h --verbose 2>&1 | head -10

echo "=== Configure GCC (uses Alpine's stock libc.so dynamically for configure tests) ==="
mkdir -p /tmp/build && cd /tmp/build
/opt/gcc-14/configure \
    --target=x86_64-linux-musl \
    --prefix=/work/build/static-gcc/install \
    --disable-bootstrap \
    --disable-multilib \
    --disable-libssp \
    --disable-libquadmath \
    --disable-libgomp \
    --disable-libatomic \
    --disable-libitm \
    --disable-libvtv \
    --disable-libsanitizer \
    --disable-libstdcxx \
    --disable-libstdcxx-pch \
    --without-headers \
    --with-newlib \
    --enable-languages=c \
    --enable-static \
    --disable-shared \
    > /work/build/static-gcc/configure.log 2>&1
echo "  configure complete"

# NOW replace Alpine's musl with our permuted version, AFTER configure
# but BEFORE the static-link make.
echo "=== Replace Alpine's musl with our PERMUTED musl ==="
cp -af /work/build/image/sysroot/usr/include/. /usr/include/
cp /work/build/image/sysroot/usr/lib/libc.a /usr/lib/libc.a
echo "  installed permuted asm/unistd_64.h: $(grep '__NR_write ' /usr/include/asm/unistd_64.h | head -1)"
echo "  installed permuted libc.a:          $(ls -l /usr/lib/libc.a | awk '{print $5, $9}')"

echo "=== make all-gcc LDFLAGS=-static (30-90 min under QEMU emulation) ==="
make -j$(nproc) all-gcc LDFLAGS="-static" \
    > /work/build/static-gcc/build.log 2>&1
echo "  make complete"

echo "=== install ==="
make install-gcc > /work/build/static-gcc/install.log 2>&1
echo "  install complete"

echo "=== Inspect resulting binaries ==="
ls -la /work/build/static-gcc/install/bin/ 2>&1 | head -5
file /work/build/static-gcc/install/bin/x86_64-linux-musl-gcc 2>&1
INSIDE
chmod +x tmp-static-driver.sh

docker run --rm --platform linux/amd64 --user root \
    -e SEED="${SEED}" \
    -v "$PWD":/work \
    encrypted-linux-gcc-static-musl \
    bash /work/tmp-static-driver.sh

rm -f tmp-static-driver.sh
echo ""
file build/static-gcc/install/bin/x86_64-linux-musl-gcc 2>&1
echo ""
echo "If the binary above says 'statically linked', it's ready to bundle"
echo "into the rootfs. Next: re-run scripts/assemble-initramfs.sh."
