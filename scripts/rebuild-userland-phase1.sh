#!/usr/bin/env bash
#
# scripts/rebuild-userland-phase1.sh — rebuild hello + busybox with
# the scrambling GCC, so caller-side matches the Phase-1-scrambled
# musl produced by scripts/rebuild-musl-phase1.sh.
#
# After this, the resulting hello binary has:
#   - permuted syscall numbers (Phase 2)
#   - permuted argument-register ABI in calls to libc (Phase 1)
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

test -x build/native-gcc/install/bin/x86_64-linux-gnu-gcc || {
    echo "ERROR: native-gcc missing"; exit 1; }
test -f build/image/sysroot/usr/lib/libc.a || {
    echo "ERROR: musl libc.a missing"; exit 1; }

cat > tmp-userland-p1-driver.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail

NATIVE_GCC=/work/build/native-gcc/install/bin/x86_64-linux-gnu-gcc
SYSROOT=/work/build/image/sysroot

# Wrapper that drives the scrambling GCC against our musl sysroot.
cat > /tmp/musl-scramble-gcc <<WRAP
#!/bin/sh
exec ${NATIVE_GCC} \
    -static \
    -nostdinc \
    -nodefaultlibs \
    -isystem /work/build/image/sysroot/usr/include \
    -B /work/build/image/sysroot/usr/lib \
    -L /work/build/image/sysroot/usr/lib \
    -nostartfiles \
    /work/build/image/sysroot/usr/lib/crt1.o \
    /work/build/image/sysroot/usr/lib/crti.o \
    "\$@" \
    /work/build/image/sysroot/usr/lib/crtn.o \
    -lc
WRAP
chmod +x /tmp/musl-scramble-gcc

# Hello demo.
echo "=== Building hello.c with scrambling GCC + Phase-1 musl ==="
cat > /tmp/hello.c <<'HC'
#include <unistd.h>
#include <string.h>
int main(void) {
    const char msg[] = "hello from encrypted-linux (Phase 1+2)!\n";
    write(1, msg, sizeof(msg) - 1);
    return 0;
}
HC
/tmp/musl-scramble-gcc /tmp/hello.c -o /work/build/image/hello-phase1plus2
file /work/build/image/hello-phase1plus2

echo
echo "=== Dump strlen call site to verify Phase-1 register-permutation ==="
# Caller-side: when hello's main calls into musl's `write`, it must
# pass the buffer pointer in %rdx (our permuted arg0), not %rdi.
# Look at any call site that takes a pointer argument.
objdump -d /work/build/image/hello-phase1plus2 \
    | awk '/<main>:/{found=1} found' \
    | head -30
INSIDE
chmod +x tmp-userland-p1-driver.sh

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD":/work \
    encrypted-linux-image-build \
    bash /work/tmp-userland-p1-driver.sh

rm -f tmp-userland-p1-driver.sh
echo ""
echo "Built: build/image/hello-phase1plus2"
