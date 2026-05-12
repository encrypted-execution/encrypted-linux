#!/usr/bin/env bash
#
# scripts/build-static-musl-binutils.sh — build binutils (ld, as, ar)
# statically linked against our PERMUTED musl. Required for in-VM
# compilation, since the gcc driver invokes ld/as as subprocesses.
#
# Same approach as build-static-musl-gcc.sh: configure with Alpine's
# stock libc.so (so configure tests work), then replace libc.a and
# make with LDFLAGS=-static.
#
# Output: build/static-binutils/install/  — static binutils
#
# Wall time: 15-30 min under QEMU emulation.
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

test -f /Users/archisgore/github/encrypted-execution/encrypted-linux/build/image/sysroot/usr/lib/libc.a 2>/dev/null || \
test -f build/image/sysroot/usr/lib/libc.a || {
    echo "ERROR: build/image/sysroot/usr/lib/libc.a missing — run scripts/build-image.sh first"
    exit 1
}

mkdir -p build/static-binutils

cat > tmp-binutils-driver.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail

# Download binutils inside the container (don't pre-stage to keep
# the image small).
cd /opt
if [ ! -d binutils ]; then
    apk add --no-cache bzip2 >/dev/null 2>&1 || true
    BU_VERSION=2.42
    BU_URL=https://ftp.gnu.org/gnu/binutils/binutils-${BU_VERSION}.tar.xz
    wget -q "${BU_URL}" -O /tmp/binutils.tar.xz
    tar -xJf /tmp/binutils.tar.xz
    mv binutils-${BU_VERSION} binutils
    rm /tmp/binutils.tar.xz
fi

echo "=== Configure binutils (Alpine stock musl) ==="
mkdir -p /tmp/bu-build && cd /tmp/bu-build
/opt/binutils/configure \
    --target=x86_64-linux-musl \
    --prefix=/work/build/static-binutils/install \
    --disable-multilib \
    --disable-werror \
    --disable-nls \
    --enable-static \
    --disable-shared \
    > /work/build/static-binutils/configure.log 2>&1
echo "  configure complete"

echo "=== Replace Alpine's musl with our PERMUTED version ==="
cp -af /work/build/image/sysroot/usr/include/. /usr/include/
cp /work/build/image/sysroot/usr/lib/libc.a /usr/lib/libc.a

echo "=== make LDFLAGS=-static ==="
make -j$(nproc) LDFLAGS="-static" > /work/build/static-binutils/build.log 2>&1
make install > /work/build/static-binutils/install.log 2>&1

file /work/build/static-binutils/install/bin/x86_64-linux-musl-ld
file /work/build/static-binutils/install/bin/x86_64-linux-musl-as
INSIDE
chmod +x tmp-binutils-driver.sh

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD":/work \
    encrypted-linux-gcc-static-musl \
    bash /work/tmp-binutils-driver.sh

rm -f tmp-binutils-driver.sh
echo ""
ls -la build/static-binutils/install/bin/ 2>&1 | head -5
