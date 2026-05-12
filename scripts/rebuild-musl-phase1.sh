#!/usr/bin/env bash
#
# scripts/rebuild-musl-phase1.sh — rebuild musl using the SCRAMBLING
# GCC (build/native-gcc/install) so the resulting libc.a has Phase 1
# argument-register permutation applied to its internal functions.
#
# Combined with the existing Phase 2 syscall renumbering (which we
# already have working), this gives BOTH defenses in the rootfs musl.
#
# Output: build/image/sysroot/usr/lib/libc.a — rebuilt
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

test -x build/native-gcc/install/bin/x86_64-linux-gnu-gcc || {
    echo "ERROR: native-gcc not built. Run scripts/build-native-gcc.sh first."
    exit 1
}

cat > tmp-musl-phase1-driver.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail
cd /opt/musl

# Reset musl to upstream + reapply our patches (syscall numbers).
echo "=== Re-applying musl syscall-number patches ==="
MUSL_SRC=/opt/musl \
UNISTD_SEEDED=/work/build/generated/asm/unistd_seeded.h \
    python3 /work/scripts/patch-musl-syscalls.py

# Patch musl's _start asm to pass argc in the PERMUTED arg0 register
# (the asm->C bridge that Phase-1-aware scrambling GCC expects).
echo "=== Patching musl crt_arch.h for permuted arg0 register ==="
# Stage the perm header so the patcher can read it.
ENCRYPTED_LINUX_SEED="$(cat /work/seed)" python3 /work/scripts/gen-gcc-arg-perm.py \
    --seed "$(cat /work/seed)" \
    -o /tmp/encrypted-linux-perm.h
MUSL_SRC=/opt/musl \
ENCRYPTED_LINUX_PERM=/tmp/encrypted-linux-perm.h \
    python3 /work/scripts/patch-musl-crt-arch.py

# Build musl with the SCRAMBLING GCC. The native-gcc binary itself
# is glibc-linked (won't run inside our VM), but it works on the
# build host. The CODE it emits uses our permuted argument-register
# convention.
NATIVE_GCC=/work/build/native-gcc/install/bin/x86_64-linux-gnu-gcc
echo "=== Configuring musl with scrambling GCC ==="
make distclean >/dev/null 2>&1 || true
CC="${NATIVE_GCC}" \
    ./configure \
    --prefix=/work/build/image/sysroot/usr \
    --syslibdir=/work/build/image/sysroot/lib \
    --disable-shared \
    > /work/build/image/musl-phase1-configure.log 2>&1

echo "=== Building musl (Phase 1 register-perm applied) ==="
make -j$(nproc) > /work/build/image/musl-phase1-build.log 2>&1
make install > /work/build/image/musl-phase1-install.log 2>&1

echo "=== Verifying musl.a has permuted register ABI ==="
# Pick one musl function and look at its prologue. If Phase 1 worked,
# the function reads args from permuted registers (DI->DX etc.).
ar x /work/build/image/sysroot/usr/lib/libc.a __strlen.o 2>/dev/null \
    || ar x /work/build/image/sysroot/usr/lib/libc.a strlen.o
objdump -d *.o 2>&1 | head -30
INSIDE
chmod +x tmp-musl-phase1-driver.sh

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD":/work \
    encrypted-linux-image-build \
    bash /work/tmp-musl-phase1-driver.sh

rm -f tmp-musl-phase1-driver.sh
echo ""
echo "musl rebuilt with Phase 1 + Phase 2."
echo "Next: bash scripts/rebuild-image-userland.sh   # rebuild hello/busybox"
echo "Then: bash scripts/assemble-initramfs.sh"
