#!/usr/bin/env bash
#
# scripts/build-v3-image.sh — build the v3 encrypted-linux image with
# all defenses layered:
#
#   v2 baseline (already shipping):
#     - 64-bit overkill syscall numbers
#     - CONFIG_RANDSTRUCT_FULL (kernel struct layouts)
#     - musl with permuted syscalls + Phase-1 register ABI
#
#   v3 additions (from research/08):
#     - Idea #1: per-build ELF EI_OSABI gate (kernel rejects mismatched)
#     - Idea #4: per-build /proc/[pid]/status field renames
#     - Idea #6: per-build errno permutation
#
# Output:
#   build/v3/{bzImage, hello, busybox, rootfs.cpio.gz}
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

echo "=== Step 1: generate all v3 headers ==="
python3 scripts/gen-overkill-syscalls.py >/dev/null
python3 scripts/gen-randstruct-seed.py    >/dev/null
python3 scripts/gen-errno-permutation.py  | head -10
python3 scripts/gen-elf-osabi.py
python3 scripts/gen-proc-rename.py | head -15

mkdir -p build/v3

cat > tmp-v3-driver.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail
cd /work

echo "=================================================="
echo "=== Build kernel: overkill + randstruct + v3 ==="
echo "=================================================="

# Enable universe and install plugin headers (for randstruct).
sed -i 's/Components: main$/Components: main universe/' \
    /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
apt-get update -qq >/dev/null 2>&1
apt-get install -y --no-install-recommends gcc-13-plugin-dev >/dev/null

cd /opt/linux

# Apply existing overkill kernel patch.
KERNEL_SRC=/opt/linux \
LOOKUP_HEADER_SRC=/work/build/generated/asm/el_syscall_lookup.h \
    python3 /work/scripts/apply-kernel-overkill.py

# Apply v3 kernel patches (errno, ELF OSABI, /proc rename).
KERNEL_SRC=/opt/linux \
GENERATED=/work/build/generated \
    python3 /work/scripts/apply-v3-kernel-patches.py

# Install randstruct seed.
cp /work/build/generated/randstruct.seed scripts/gcc-plugins/randstruct.seed

# Kernel config.
make mrproper >/dev/null 2>&1 || true
make tinyconfig >/dev/null
cat <<'KC' >> .config
CONFIG_64BIT=y
CONFIG_X86_64=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_HAVE_GCC_PLUGINS=y
CONFIG_GCC_PLUGINS=y
CONFIG_GCC_PLUGIN_RANDSTRUCT=y
# CONFIG_RANDSTRUCT_NONE is not set
CONFIG_RANDSTRUCT_FULL=y
CONFIG_RANDSTRUCT=y
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
# Force randstruct full if the choice resolution defaulted to NONE.
if ! grep -q "^CONFIG_RANDSTRUCT_FULL=y" .config; then
    scripts/config --disable RANDSTRUCT_NONE
    scripts/config --enable RANDSTRUCT_FULL
    yes "" | make oldconfig >/dev/null 2>&1
fi

echo "=== Building bzImage ==="
make -j$(nproc) bzImage 2>&1 | tail -3
cp arch/x86/boot/bzImage /work/build/v3/bzImage

# Install kernel headers (with permuted errno + unistd).
make INSTALL_HDR_PATH=/work/build/v3/sysroot/usr headers_install 2>&1 | tail -1

echo "=================================================="
echo "=== Build musl: overkill + errno permutation ==="
echo "=================================================="
cd /opt/musl

# Apply existing patches (syscall numbers + crt_arch).
MUSL_SRC=/opt/musl \
UNISTD_SEEDED=/work/build/generated/asm/unistd_seeded.h \
    python3 /work/scripts/patch-musl-overkill.py

# Apply v3 errno patch.
MUSL_SRC=/opt/musl \
GENERATED=/work/build/generated \
    python3 /work/scripts/patch-musl-errno.py

make distclean >/dev/null 2>&1 || true
CC=gcc ./configure \
    --prefix=/work/build/v3/sysroot/usr \
    --syslibdir=/work/build/v3/sysroot/lib \
    --disable-shared \
    > /work/build/v3/musl-configure.log 2>&1
make -j$(nproc) > /work/build/v3/musl-build.log 2>&1
make install > /work/build/v3/musl-install.log 2>&1
ls -la /work/build/v3/sysroot/usr/lib/libc.a

echo "=================================================="
echo "=== Build hello + busybox ==="
echo "=================================================="
cat > /tmp/hello.c <<'HC'
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>

static void itoa(int n, char *buf) {
    int i = 0;
    if (n < 0) { buf[i++] = '-'; n = -n; }
    char tmp[16]; int t = 0;
    do { tmp[t++] = '0' + (n % 10); n /= 10; } while (n);
    while (t > 0) buf[i++] = tmp[--t];
    buf[i] = '\0';
}

int main(void) {
    const char msg[] = "hello from encrypted-linux V3 (overkill + errno + OSABI + /proc)!\n";
    write(1, msg, sizeof(msg) - 1);
    // Demonstrate permuted errno: open a non-existent file.
    int rc = open("/nonexistent-evidence-of-errno-permutation", O_RDONLY);
    if (rc < 0) {
        char b1[] = "errno after open(/nonexistent): ";
        write(1, b1, sizeof(b1) - 1);
        char numbuf[16];
        itoa(errno, numbuf);
        write(1, numbuf, sizeof(numbuf) - 1 < 16 ? sizeof(numbuf)-1 : 16);
        // Actually write the strlen.
        int len = 0; while (numbuf[len]) len++;
        write(1, numbuf, len);
        write(1, "\n", 1);
        write(1, "  (canonical ENOENT=2; if you see something else, errno is permuted)\n",
              sizeof("  (canonical ENOENT=2; if you see something else, errno is permuted)\n") - 1);
    }
    return 0;
}
HC
/work/build/v3/sysroot/usr/bin/musl-gcc -static /tmp/hello.c -o /work/build/v3/hello

cd /opt/busybox
make distclean >/dev/null 2>&1 || true
make defconfig >/dev/null
sed -i 's|^# CONFIG_STATIC.*|CONFIG_STATIC=y|' .config
for cfg in CONFIG_FEATURE_WTMP CONFIG_FEATURE_UTMP CONFIG_TC; do
    sed -i "s|^${cfg}=y|# ${cfg} is not set|" .config
done
make -j$(nproc) CC=/work/build/v3/sysroot/usr/bin/musl-gcc \
    > /work/build/v3/busybox-build.log 2>&1
cp busybox /work/build/v3/busybox

echo "=================================================="
echo "=== Stamp all ELFs with per-build EI_OSABI ==="
echo "=================================================="
python3 /work/scripts/stamp-elf-osabi.py \
    /work/build/v3/hello \
    /work/build/v3/busybox

# Verify the stamp worked.
od -An -tx1 -N9 /work/build/v3/hello | head -1

echo "=================================================="
echo "=== Assemble initramfs ==="
echo "=================================================="
ROOT=/tmp/rootfs-v3
rm -rf "${ROOT}"
mkdir -p "${ROOT}"/{bin,sbin,etc,proc,sys,dev,tmp,root,src}
cp /work/build/v3/busybox "${ROOT}/bin/busybox"
for a in ash sh ls cat mount echo poweroff init grep printf; do
    ln -sf busybox "${ROOT}/bin/${a}"
done
cp /work/build/v3/hello "${ROOT}/bin/hello"

# Bundle a stock (OSABI=0) hello for cross-test.
gcc -static /tmp/hello.c -o /tmp/hello-stock 2>/dev/null || true
[ -f /tmp/hello-stock ] && cp /tmp/hello-stock "${ROOT}/bin/hello-stock-osabi" || true

cat > "${ROOT}/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys 2>/dev/null
/bin/busybox mount -t devtmpfs none /dev
echo
echo "============================================================="
echo "  encrypted-linux V3"
echo "  - Overkill 64-bit syscalls + randstruct"
echo "  - errno values permuted (POSIX-compliant)"
echo "  - per-build EI_OSABI gate in binfmt_elf"
echo "  - /proc/[pid]/status fields renamed"
echo "============================================================="
echo
CMDLINE=$(/bin/busybox cat /proc/cmdline)
if /bin/busybox echo "${CMDLINE}" | /bin/busybox grep -q "el_demo=auto"; then
    echo "[v3] /bin/hello (stamped OSABI):"
    /bin/hello; echo "  -> exit $?"
    echo
    echo "[v3] /bin/hello-stock-osabi (canonical OSABI=0):"
    /bin/hello-stock-osabi 2>&1
    echo "  -> exit $?"
    echo "  (kernel should reject this with ENOEXEC; success means binfmt_elf check failed)"
    echo
    echo "[v3] /proc/self/status (renamed fields):"
    /bin/busybox cat /proc/self/status 2>/dev/null | /bin/busybox head -25
    /bin/busybox poweroff -f
else
    exec /bin/busybox sh +m
fi
INIT
chmod +x "${ROOT}/init"
ln -sf /init "${ROOT}/sbin/init"

cd "${ROOT}"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null \
    | gzip -9 > /work/build/v3/rootfs.cpio.gz
ls -la /work/build/v3/rootfs.cpio.gz
INSIDE
chmod +x tmp-v3-driver.sh

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD":/work \
    encrypted-linux-image-build \
    bash /work/tmp-v3-driver.sh

rm -f tmp-v3-driver.sh
echo ""
ls -la build/v3/{bzImage,hello,busybox,rootfs.cpio.gz}
echo
echo "Boot: gtimeout 90 qemu-system-x86_64 -m 4G -kernel build/v3/bzImage -initrd build/v3/rootfs.cpio.gz -append 'console=ttyS0 panic=5 loglevel=3 el_demo=auto' -nographic -no-reboot -accel tcg"
