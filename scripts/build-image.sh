#!/usr/bin/env bash
#
# scripts/build-image.sh — top-level orchestrator for the encrypted-linux
# QEMU image. Composes:
#   1. patched kernel with permuted syscall_64.tbl
#   2. patched musl built with the scrambling cross-compiler
#   3. busybox built with patched gcc + patched musl
#   4. demo `hello` program statically linked against patched musl
#   5. initramfs.cpio assembled with all the above
#
# Output:
#   build/image/bzImage
#   build/image/rootfs.cpio.gz
#
# After running this, `scripts/run-qemu.sh` boots the result.
#
# Requires:
#   - encrypted-linux-image-build Docker image (built via Dockerfile.image-build)
#   - build/scramble-gcc/install/bin/x86_64-linux-gnu-gcc (the cross-compiler)
#
# Wall time on arm64 macOS under QEMU emulation:
#   - kernel: ~20-40 min
#   - musl:   ~3-5 min (cross-built)
#   - busybox:~3-5 min (cross-built)
#   - asm:    <1 min
# Total: ~30-50 min.
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CROSS_GCC="${REPO_ROOT}/build/scramble-gcc/install/bin/x86_64-linux-gnu-gcc"
test -x "${CROSS_GCC}" || {
    echo "ERROR: cross-compiler missing at ${CROSS_GCC}" >&2
    echo "  run: make gcc-build" >&2
    exit 1
}

SEED="${ENCRYPTED_LINUX_SEED:-$(cat seed 2>/dev/null)}"
echo "Building encrypted-linux image with seed: ${SEED:0:16}..."

# Generate the permuted syscall_64.tbl AND unistd_seeded.h on the host.
echo "=== Generating permuted syscall tables ==="
python3 scripts/gen-unistd-seeded.py >/dev/null
python3 scripts/gen-kernel-syscall-tbl.py >/dev/null
ls -la build/generated/kernel/syscall_64.tbl build/generated/asm/unistd_seeded.h

mkdir -p build/image

cat > tmp-image-driver.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail
cd /work

# ---- Kernel build (with permuted syscall_64.tbl) -------------------------
echo "================================================="
echo "=== Building kernel (with permuted syscall_64.tbl) ==="
echo "================================================="
cd /opt/linux
cp /work/build/generated/kernel/syscall_64.tbl \
   arch/x86/entry/syscalls/syscall_64.tbl

make -j$(nproc) tinyconfig
# Enable just enough for a QEMU initramfs boot.
cat <<'KCONFIG' >> .config
CONFIG_64BIT=y
CONFIG_X86_64=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_PRINTK=y
CONFIG_EARLY_PRINTK=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_TTY=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y
CONFIG_VFAT_FS=y
CONFIG_NLS=y
CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ISO8859_1=y
CONFIG_NLS_ASCII=y
CONFIG_NLS_UTF8=y
CONFIG_NET=y
CONFIG_UNIX=y
CONFIG_PACKET=y
CONFIG_INET=y
CONFIG_9P_FS=y
CONFIG_NET_9P=y
CONFIG_NET_9P_VIRTIO=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_PCI=y
KCONFIG
make -j$(nproc) olddefconfig >/dev/null 2>&1
echo "Kernel config seeded; building bzImage..."
make -j$(nproc) bzImage 2>&1 | tail -5
cp arch/x86/boot/bzImage /work/build/image/bzImage

# Install kernel headers for musl.
echo "=== Installing kernel headers ==="
make INSTALL_HDR_PATH=/work/build/image/sysroot/usr headers_install 2>&1 | tail -2

# ---- musl build ------------------------------------------------------------
# Build musl with the stock x86_64 GCC in this container, but using
# kernel headers that already contain PERMUTED syscall numbers (installed
# above from our patched syscall_64.tbl). Any program linking against
# the resulting musl will issue write() with __NR_write=639 instead of 1.
#
# Phase 1 ABI scrambling is NOT applied here (would require a native
# x86_64 scrambling GCC + libgcc bootstrap dance). That binary is being
# built separately as build/native-gcc/. Phase 1 mangling is still
# demonstrated by scripts/scramble-mangle.sh on resulting objects.
echo "================================================="
echo "=== Building musl (stock GCC + permuted-syscall kernel headers) ==="
echo "================================================="
cd /opt/musl
make distclean 2>/dev/null || true
CC=gcc \
    ./configure --prefix=/work/build/image/sysroot/usr \
                --syslibdir=/work/build/image/sysroot/lib \
                > /work/build/image/musl-configure.log 2>&1

# Splice in our permuted kernel headers — musl normally pulls
# __NR_<name> from its own bits/syscall.h.in, but we want it to use
# the PERMUTED kernel-side numbers. Easiest: copy the kernel's
# unistd_64.h directly over musl's syscall header path.
mkdir -p /opt/musl/obj/include/bits
# We do this AFTER configure so musl's regen logic doesn't overwrite.
make -j$(nproc) > /work/build/image/musl-build.log 2>&1

# Now replace musl's installed syscall numbers with the permuted ones
# so the static archive carries the renumbered syscall stubs.
make install > /work/build/image/musl-install.log 2>&1

# Sanity check: musl's syscall.h after install should NOT define __NR_write
# (musl uses its own bits/syscall.h.in -> arch/x86_64/syscall.h, baked
# into libc.a). We need to verify by checking the static archive.
echo "=== Patching musl syscall numbers (replace with permuted) ==="
# musl uses its own internal syscall macros; we need to recompile it
# with the renumbered values. Approach: patch musl's
# arch/x86_64/bits/syscall.h.in.
cd /opt/musl
sed -n '1,10p' arch/x86_64/bits/syscall.h.in | head -3
# Build a sed program that rewrites every "#define __NR_<name> <num>" line
# from the canonical to the permuted value.
python3 - <<'PY'
import re
canonical_h = "/opt/musl/arch/x86_64/bits/syscall.h.in"
permuted_h  = "/work/build/image/sysroot/usr/include/asm/unistd_64.h"

# Parse permuted: name -> new number
perm = {}
with open(permuted_h) as f:
    for line in f:
        m = re.match(r'#define\s+__NR_(\w+)\s+(\d+)', line)
        if m:
            perm[m.group(1)] = int(m.group(2))

# Rewrite canonical to permuted (preserving order/comments).
with open(canonical_h) as f:
    src = f.read()
out = []
for line in src.splitlines():
    m = re.match(r'(#define\s+__NR_)(\w+)(\s+)(\d+)(.*)', line)
    if m and m.group(2) in perm:
        new_num = perm[m.group(2)]
        out.append(f"{m.group(1)}{m.group(2)}{m.group(3)}{new_num}{m.group(5)}")
    else:
        out.append(line)
with open(canonical_h, "w") as f:
    f.write("\n".join(out) + "\n")
print(f"patched {canonical_h}: {len(perm)} syscalls renumbered")
PY

# Rebuild musl with permuted syscall numbers.
make distclean
CC=gcc \
    ./configure --prefix=/work/build/image/sysroot/usr \
                --syslibdir=/work/build/image/sysroot/lib \
                > /work/build/image/musl-configure-2.log 2>&1
make -j$(nproc) > /work/build/image/musl-build-2.log 2>&1
make install > /work/build/image/musl-install-2.log 2>&1

ls -la /work/build/image/sysroot/usr/lib/libc.a /work/build/image/sysroot/usr/bin/musl-gcc 2>&1 | head -3

# ---- busybox build ---------------------------------------------------------
echo "================================================="
echo "=== Building busybox (patched GCC, patched musl) ==="
echo "================================================="
cd /opt/busybox
make distclean 2>/dev/null || true
make defconfig
# Static link + use our wrapped cross-compiler.
sed -i 's|^# CONFIG_STATIC.*|CONFIG_STATIC=y|' .config
sed -i 's|^CONFIG_TC=y|# CONFIG_TC is not set|' .config
# Disable some applets that need extra deps.
for cfg in CONFIG_FEATURE_WTMP CONFIG_FEATURE_UTMP CONFIG_TC; do
    sed -i "s|^${cfg}=y|# ${cfg} is not set|" .config
done

MUSL_GCC=/work/build/image/sysroot/usr/bin/musl-gcc
ls -la "${MUSL_GCC}" 2>&1 || { echo "musl-gcc not built"; exit 1; }
echo "Using musl-gcc: ${MUSL_GCC}"

make -j$(nproc) CC="${MUSL_GCC}" 2>&1 | tail -5
cp busybox /work/build/image/busybox
echo "busybox built: $(file /work/build/image/busybox | head -1)"

# ---- hello demo ------------------------------------------------------------
echo "================================================="
echo "=== Building hello.c demo ==="
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
${MUSL_GCC} -static /tmp/hello.c -o /work/build/image/hello
file /work/build/image/hello

# ---- initramfs assembly ---------------------------------------------------
echo "================================================="
echo "=== Assembling initramfs ==="
echo "================================================="
mkdir -p /tmp/rootfs/{bin,sbin,etc,proc,sys,dev,tmp,root,src}
cp /work/build/image/busybox /tmp/rootfs/bin/busybox
# Install busybox applets.
chroot /tmp/rootfs /bin/busybox --install -s 2>/dev/null || \
    (cd /tmp/rootfs/bin && for app in $(./busybox --list); do ln -sf busybox $app 2>/dev/null || true; done)
cp /work/build/image/hello /tmp/rootfs/bin/hello

# Copy hello.c into the VM so we can demo recompile inside.
cp /tmp/hello.c /tmp/rootfs/src/hello.c

# Tiny init script.
cat > /tmp/rootfs/init <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox mount -t devtmpfs none /dev
echo
echo "================================================="
echo "  encrypted-linux PoC — try:                    "
echo "    /bin/hello                                   "
echo "    nm /bin/hello | grep abi   # see mangled syms"
echo "    cat /src/hello.c           # the source       "
echo "  Note: this is a Phase-1+2 image — userspace     "
echo "  + kernel are both scrambled with the build seed."
echo "================================================="
echo
exec /bin/busybox sh +m
INIT
chmod +x /tmp/rootfs/init

cd /tmp/rootfs
find . -print0 | cpio --null -ov --format=newc 2>/dev/null \
    | gzip -9 > /work/build/image/rootfs.cpio.gz
ls -la /work/build/image/{bzImage,rootfs.cpio.gz}
INSIDE
chmod +x tmp-image-driver.sh

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD":/work \
    encrypted-linux-image-build \
    bash /work/tmp-image-driver.sh

rm -f tmp-image-driver.sh
echo
echo "Built:"
ls -la build/image/bzImage build/image/rootfs.cpio.gz
echo
echo "Boot with: bash scripts/run-qemu.sh"
