#!/usr/bin/env bash
#
# scripts/build-overkill-musl-shared.sh — rebuild overkill musl with
# --enable-shared so we get libc.so + ld-musl-x86_64.so.1 in addition
# to libc.a. Needed for bundling a dynamically-linked toolchain
# (Alpine's gcc) into our VM rootfs.
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

cat > tmp-musl-shared.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail
cd /opt/musl

# Re-apply overkill patches (idempotent).
MUSL_SRC=/opt/musl \
UNISTD_SEEDED=/work/build/generated/asm/unistd_seeded.h \
    python3 /work/scripts/patch-musl-overkill.py

# Rebuild WITH shared.
make distclean >/dev/null 2>&1 || true
CC=gcc ./configure \
    --prefix=/work/build/overkill/sysroot/usr \
    --syslibdir=/work/build/overkill/sysroot/lib \
    > /work/build/overkill/musl-shared-configure.log 2>&1

# musl tries to build libc.so which needs libgcc symbols (__muldc3 etc.)
# from complex math. With Ubuntu's stock gcc + glibc-built libgcc this
# works (libgcc has those symbols and the link succeeds).
make -j$(nproc) > /work/build/overkill/musl-shared-build.log 2>&1
make install > /work/build/overkill/musl-shared-install.log 2>&1

echo "=== Built shared libs ==="
ls -la /work/build/overkill/sysroot/lib/ 2>&1 | head -10
ls -la /work/build/overkill/sysroot/usr/lib/libc.* 2>&1 | head -5
file /work/build/overkill/sysroot/lib/ld-musl-x86_64.so.1 2>&1 | head -2
INSIDE
chmod +x tmp-musl-shared.sh

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD":/work \
    encrypted-linux-image-build \
    bash /work/tmp-musl-shared.sh

rm -f tmp-musl-shared.sh
