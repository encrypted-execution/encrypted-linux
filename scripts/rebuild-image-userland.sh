#!/usr/bin/env bash
#
# scripts/rebuild-image-userland.sh — rebuild musl + busybox + hello
# without touching the kernel. Use this after fixing musl-patching bugs.
#
# Faster than scripts/build-image.sh (skips the 20+ min kernel build).
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

test -f build/image/bzImage || { echo "kernel missing — run scripts/build-image.sh"; exit 1; }
test -d build/image/sysroot/usr/include || { echo "kernel headers missing"; exit 1; }

cat > tmp-userland-driver.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail

# 1. Apply our patch script to musl.
echo "================================================="
echo "=== Patching musl (syscall.h.in + 7 .s files) ==="
echo "================================================="
cd /opt/musl

# Restore upstream copies of the files we'll patch (in case a prior
# run left them in some state). musl ships these files in its tarball;
# we don't need git. Just refetch them from upstream as a known-good
# baseline.
echo "(restoring upstream musl source files via curl)"
for f in arch/x86_64/bits/syscall.h.in \
         src/thread/x86_64/__set_thread_area.s \
         src/thread/x86_64/__unmapself.s \
         src/process/x86_64/vfork.s \
         src/signal/x86_64/restore.s \
         src/thread/x86_64/clone.s ; do
    url="https://git.musl-libc.org/cgit/musl/plain/${f}?h=v1.2.5"
    echo "  fetching ${f}..."
    if ! curl -fsSL --max-time 30 "${url}" -o "/opt/musl/${f}.new"; then
        echo "  WARN: failed to refetch ${f} — using current on-disk copy"
        rm -f "/opt/musl/${f}.new"
    else
        mv "/opt/musl/${f}.new" "/opt/musl/${f}"
    fi
done

# Now apply our patch.
MUSL_SRC=/opt/musl \
UNISTD_SEEDED=/work/build/generated/asm/unistd_seeded.h \
    python3 /work/scripts/patch-musl-syscalls.py

# Show the patch results so we know it worked (best-effort; don't fail
# the script if grep finds nothing).
echo
echo "=== After patching (sample syscall.h.in) ==="
{ grep -E "__NR_(write|read|exit_group|arch_prctl|set_tid_address) " \
    /opt/musl/arch/x86_64/bits/syscall.h.in || true; }

# 2. Rebuild musl.
echo "================================================="
echo "=== Building musl with patched sources ==="
echo "================================================="
cd /opt/musl
make distclean >/dev/null 2>&1
CC=gcc ./configure \
    --prefix=/work/build/image/sysroot/usr \
    --syslibdir=/work/build/image/sysroot/lib \
    > /work/build/image/musl-configure.log 2>&1
make -j$(nproc) > /work/build/image/musl-build.log 2>&1
make install > /work/build/image/musl-install.log 2>&1
echo "musl rebuilt."

# 3. Rebuild hello.
echo "================================================="
echo "=== Rebuilding hello ==="
echo "================================================="
cat > /tmp/hello.c <<'HC'
#include <unistd.h>
#include <string.h>
int main(void) {
    const char msg[] = "hello from inside encrypted-linux!\n";
    write(1, msg, sizeof(msg) - 1);
    return 0;
}
HC
/work/build/image/sysroot/usr/bin/musl-gcc -static /tmp/hello.c -o /work/build/image/hello

# 4. Rebuild busybox.
echo "================================================="
echo "=== Rebuilding busybox ==="
echo "================================================="
cd /opt/busybox
make distclean >/dev/null 2>&1
make defconfig >/dev/null
sed -i 's|^# CONFIG_STATIC.*|CONFIG_STATIC=y|' .config
for cfg in CONFIG_FEATURE_WTMP CONFIG_FEATURE_UTMP CONFIG_TC; do
    sed -i "s|^${cfg}=y|# ${cfg} is not set|" .config
done
make -j$(nproc) CC=/work/build/image/sysroot/usr/bin/musl-gcc \
    > /work/build/image/busybox-build.log 2>&1
cp busybox /work/build/image/busybox

# 5. Verify by dumping syscall numbers in the new hello.
echo
echo "================================================="
echo "=== Verification: syscall numbers in new hello ==="
echo "================================================="
echo "Expected: NO canonical numbers in arch_prctl/vfork/clone/exit:"
objdump -d /work/build/image/hello | awk '/syscall$/{print prev; print} {prev=$0}' \
    | grep -E "mov[lq]?\s+\\\$" | head -20
INSIDE
chmod +x tmp-userland-driver.sh

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD":/work \
    encrypted-linux-image-build \
    bash /work/tmp-userland-driver.sh

rm -f tmp-userland-driver.sh
echo
echo "Now reassemble initramfs: bash scripts/assemble-initramfs.sh"
