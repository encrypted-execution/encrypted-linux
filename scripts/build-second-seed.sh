#!/usr/bin/env bash
#
# scripts/build-second-seed.sh — build a SECOND encrypted-linux image
# with a different master seed, so we can demonstrate cross-VM
# incompatibility (image A's hello fails on image B's kernel, even
# though both are "encrypted-linux"; only the SEED differs).
#
# Outputs:
#   build/image-seedB/bzImage
#   build/image-seedB/rootfs.cpio.gz
#   build/image-seedB/hello
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

# Seed B — different by 1 byte from seed A.
SEED_A="$(cat seed)"
SEED_B="$(printf '%s' 'encrypted-linux PoC seed v0 BETA' | shasum -a 256 | cut -d' ' -f1)"
echo "Seed A: ${SEED_A}"
echo "Seed B: ${SEED_B}"

mkdir -p build/image-seedB

# gen-unistd-seeded.py reads from ./seed; swap it temporarily.
mv seed seed.A.backup
printf '%s\n' "${SEED_B}" > seed
trap 'mv seed.A.backup seed' EXIT

# Generate permuted tables for seed B.
python3 scripts/gen-unistd-seeded.py >/dev/null
python3 scripts/gen-kernel-syscall-tbl.py >/dev/null
echo "Generated seed-B tables. Sampling renumbering:"
grep -E "__NR_(read|write|exit_group|set_tid_address) " build/generated/asm/unistd_seeded.h

# Drive a kernel + musl + busybox + hello rebuild inside the build container,
# using the same image-build container as before.
cat > tmp-seedB-driver.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail
cd /work

# --- Kernel rebuild with seed B ---
echo "=== Building seed-B kernel ==="
cd /opt/linux
make mrproper >/dev/null 2>&1 || make distclean >/dev/null 2>&1 || true
cp /work/build/generated/kernel/syscall_64.tbl arch/x86/entry/syscalls/syscall_64.tbl
make tinyconfig >/dev/null
cat <<'KC' >> .config
CONFIG_64BIT=y
CONFIG_X86_64=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
CONFIG_BINFMT_ELF=y
CONFIG_PRINTK=y
CONFIG_EARLY_PRINTK=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_TTY=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_PROC_FS=y
CONFIG_TMPFS=y
# CONFIG_X86_X32_ABI is not set
KC
make olddefconfig >/dev/null 2>&1
make -j$(nproc) bzImage 2>&1 | tail -3
cp arch/x86/boot/bzImage /work/build/image-seedB/bzImage
mkdir -p /work/build/image-seedB/sysroot/usr
make INSTALL_HDR_PATH=/work/build/image-seedB/sysroot/usr headers_install 2>&1 | tail -1

# --- musl rebuild with seed B ---
echo "=== Building seed-B musl ==="
cd /opt/musl
make distclean >/dev/null 2>&1
CC=gcc ./configure \
    --prefix=/work/build/image-seedB/sysroot/usr \
    --syslibdir=/work/build/image-seedB/sysroot/lib \
    > /work/build/image-seedB/musl-configure.log 2>&1
# First build to install headers.
make -j$(nproc) > /work/build/image-seedB/musl-build1.log 2>&1
make install > /work/build/image-seedB/musl-install1.log 2>&1

# Apply our patch script (rewrites musl's bits/syscall.h.in + the
# 7 hardcoded asm sites).
MUSL_SRC=/opt/musl \
UNISTD_SEEDED=/work/build/generated/asm/unistd_seeded.h \
    python3 /work/scripts/patch-musl-syscalls.py

# Rebuild musl with permuted numbers throughout.
make distclean >/dev/null 2>&1
CC=gcc ./configure \
    --prefix=/work/build/image-seedB/sysroot/usr \
    --syslibdir=/work/build/image-seedB/sysroot/lib \
    > /work/build/image-seedB/musl-configure2.log 2>&1
make -j$(nproc) > /work/build/image-seedB/musl-build2.log 2>&1
make install > /work/build/image-seedB/musl-install2.log 2>&1

# --- hello ---
echo "=== Building seed-B hello ==="
cat > /tmp/hello.c <<'HC'
#include <unistd.h>
#include <string.h>
int main(void) {
    const char msg[] = "hello from inside encrypted-linux (seed B)!\n";
    write(1, msg, sizeof(msg) - 1);
    return 0;
}
HC
/work/build/image-seedB/sysroot/usr/bin/musl-gcc -static /tmp/hello.c \
    -o /work/build/image-seedB/hello

# --- busybox rebuild with seed-B musl ---
echo "=== Building seed-B busybox ==="
cd /opt/busybox
make distclean >/dev/null 2>&1
make defconfig >/dev/null
sed -i 's|^# CONFIG_STATIC.*|CONFIG_STATIC=y|' .config
for cfg in CONFIG_FEATURE_WTMP CONFIG_FEATURE_UTMP CONFIG_TC; do
    sed -i "s|^${cfg}=y|# ${cfg} is not set|" .config
done
make -j$(nproc) CC=/work/build/image-seedB/sysroot/usr/bin/musl-gcc \
    > /work/build/image-seedB/busybox-build.log 2>&1
cp busybox /work/build/image-seedB/busybox

# --- initramfs assembly (smaller — no bundled GCC) ---
echo "=== Assembling seed-B initramfs ==="
ROOT=/tmp/rootfsB
rm -rf "${ROOT}"
mkdir -p "${ROOT}"/{bin,sbin,etc,proc,sys,dev,tmp,root,src}
cp /work/build/image-seedB/busybox "${ROOT}/bin/busybox"
APPLETS="ash sh ls cat cp mv rm mkdir mount umount echo printf find grep
        sed awk head tail wc sort uniq tee dd stty tty whoami id ps top
        kill killall sleep dmesg lsmod insmod rmmod modprobe poweroff
        reboot halt init"
for a in $APPLETS; do ln -sf busybox "${ROOT}/bin/${a}"; done
cp /work/build/image-seedB/hello "${ROOT}/bin/hello"
chmod +x "${ROOT}/bin/hello"

# Also bundle the seed-A hello to demo cross-VM failure.
if [ -f /work/build/image/hello-seedA ]; then
    cp /work/build/image/hello-seedA "${ROOT}/bin/hello-seedA"
    chmod +x "${ROOT}/bin/hello-seedA"
fi

cat > "${ROOT}/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox mount -t devtmpfs none /dev
CMDLINE=$(/bin/busybox cat /proc/cmdline)
echo
echo "============================================================="
echo "  encrypted-linux SEED B"
echo "============================================================="
echo
if /bin/busybox echo "${CMDLINE}" | /bin/busybox grep -q "el_demo=auto"; then
    echo "[seedB] running native /bin/hello (seed-B-compiled):"
    /bin/hello; rc=$?; echo "  -> exit ${rc}"
    echo
    echo "[seedB] running /bin/hello-seedA (compiled with seed A — expected to fail):"
    /bin/hello-seedA; rc=$?; echo "  -> exit ${rc}"
    echo
    echo "[seedB] halting."
    /bin/busybox poweroff -f
else
    echo "Try:  /bin/hello          (works — seed-B native)"
    echo "      /bin/hello-seedA    (must fail — seed-A binary on seed-B kernel)"
    exec /bin/busybox sh +m
fi
INIT
chmod +x "${ROOT}/init"
ln -sf init "${ROOT}/sbin/init"

cd "${ROOT}"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null \
    | gzip -9 > /work/build/image-seedB/rootfs.cpio.gz
ls -la /work/build/image-seedB/rootfs.cpio.gz
INSIDE
chmod +x tmp-seedB-driver.sh

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD":/work \
    encrypted-linux-image-build \
    bash /work/tmp-seedB-driver.sh

rm -f tmp-seedB-driver.sh
ls -la build/image-seedB/{bzImage,rootfs.cpio.gz,hello}
