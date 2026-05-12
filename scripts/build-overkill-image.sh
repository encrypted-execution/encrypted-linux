#!/usr/bin/env bash
#
# scripts/build-overkill-image.sh — top-level orchestrator for the
# 64-bit overkill encrypted-linux image.
#
# Differences from build-image.sh:
#   - syscall numbers are 64-bit (HMAC-derived), not 10-bit slot indices
#   - kernel keeps canonical syscall_64.tbl (not replaced)
#   - kernel is patched to use el_syscall_lookup() in do_syscall_x64
#   - musl uses ULL-suffixed __NR_* + movabsq in hardcoded asm
#
# Output: build/overkill/{bzImage,rootfs.cpio.gz,hello}
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

echo "=== Step 1a: generate 64-bit overkill syscall headers ==="
python3 scripts/gen-overkill-syscalls.py >/dev/null
echo "=== Step 1b: generate kernel randstruct seed ==="
python3 scripts/gen-randstruct-seed.py >/dev/null
head -5 build/generated/asm/el_syscall_lookup.h
echo "..."
grep -E "0x[0-9a-f]+ULL.*write |0x[0-9a-f]+ULL.*read |0x[0-9a-f]+ULL.*execve " \
    build/generated/asm/unistd_seeded.h || \
grep -E "__NR_(write|read|execve|exit_group) " build/generated/asm/unistd_seeded.h

mkdir -p build/overkill

cat > tmp-overkill-driver.sh <<'INSIDE'
#!/bin/bash
set -euo pipefail
cd /work

echo "================================================="
echo "=== Build kernel with overkill lookup + randstruct ==="
echo "================================================="

# gcc-plugin-dev is needed for CONFIG_GCC_PLUGIN_RANDSTRUCT_*.
# Enable Ubuntu universe (where gcc-13-plugin-dev lives) first.
echo "=== Install gcc-13-plugin-dev (for randstruct) ==="
sed -i 's/Components: main$/Components: main universe/' \
    /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
apt-get update -qq >/dev/null 2>&1
apt-get install -y --no-install-recommends gcc-13-plugin-dev >/dev/null

cd /opt/linux

# Apply our kernel patch (installs lookup header + patches common.c).
KERNEL_SRC=/opt/linux \
LOOKUP_HEADER_SRC=/work/build/generated/asm/el_syscall_lookup.h \
    python3 /work/scripts/apply-kernel-overkill.py

# Install our deterministic randstruct seed so struct-layout
# randomization is per-encrypted-linux-build reproducible.
echo "=== Install randstruct seed ==="
cp /work/build/generated/randstruct.seed scripts/gcc-plugins/randstruct.seed
echo "  $(head -c 16 scripts/gcc-plugins/randstruct.seed)..."

# Standard kernel config (tinyconfig + serial/init essentials, same as before).
make mrproper >/dev/null 2>&1 || make distclean >/dev/null 2>&1 || true
make tinyconfig >/dev/null
cat <<'KC' >> .config
CONFIG_64BIT=y
CONFIG_X86_64=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
# GCC plugins + randstruct full mode (Linux struct layout randomization).
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
# Verify randstruct survived the choice resolution; if not, force via scripts/config.
if ! grep -q "^CONFIG_RANDSTRUCT_FULL=y" .config; then
    scripts/config --disable RANDSTRUCT_NONE
    scripts/config --enable RANDSTRUCT_FULL
    yes "" | make oldconfig >/dev/null 2>&1
fi
echo "Effective randstruct config:"
grep -E "^CONFIG_(GCC_PLUGIN|RANDSTRUCT)" .config | head -6
echo "=== Building bzImage ==="
make -j$(nproc) bzImage 2>&1 | tail -3
cp arch/x86/boot/bzImage /work/build/overkill/bzImage
make INSTALL_HDR_PATH=/work/build/overkill/sysroot/usr headers_install 2>&1 | tail -1

echo "================================================="
echo "=== Build musl with 64-bit __NR_* (overkill) ==="
echo "================================================="
cd /opt/musl

# Apply overkill patches.
MUSL_SRC=/opt/musl \
UNISTD_SEEDED=/work/build/generated/asm/unistd_seeded.h \
    python3 /work/scripts/patch-musl-overkill.py

# Build musl.
make distclean >/dev/null 2>&1 || true
CC=gcc ./configure \
    --prefix=/work/build/overkill/sysroot/usr \
    --syslibdir=/work/build/overkill/sysroot/lib \
    --disable-shared \
    > /work/build/overkill/musl-configure.log 2>&1
make -j$(nproc) > /work/build/overkill/musl-build.log 2>&1
make install > /work/build/overkill/musl-install.log 2>&1
ls -la /work/build/overkill/sysroot/usr/lib/libc.a

echo "================================================="
echo "=== Build hello with overkill musl ==="
echo "================================================="
cat > /tmp/hello.c <<'HC'
#include <unistd.h>
#include <string.h>
int main(void) {
    const char msg[] = "hello from encrypted-linux OVERKILL (64-bit syscalls)!\n";
    write(1, msg, sizeof(msg) - 1);
    return 0;
}
HC
/work/build/overkill/sysroot/usr/bin/musl-gcc -static /tmp/hello.c \
    -o /work/build/overkill/hello
file /work/build/overkill/hello

echo "=== Inspect baked-in syscall numbers (should be 64-bit hex) ==="
objdump -d /work/build/overkill/hello | grep -B1 syscall | grep -E "movabs|movq.*%rax" | head -10

echo "================================================="
echo "=== Build busybox (same musl) ==="
echo "================================================="
cd /opt/busybox
make distclean >/dev/null 2>&1 || true
make defconfig >/dev/null
sed -i 's|^# CONFIG_STATIC.*|CONFIG_STATIC=y|' .config
for cfg in CONFIG_FEATURE_WTMP CONFIG_FEATURE_UTMP CONFIG_TC; do
    sed -i "s|^${cfg}=y|# ${cfg} is not set|" .config
done
make -j$(nproc) CC=/work/build/overkill/sysroot/usr/bin/musl-gcc \
    > /work/build/overkill/busybox-build.log 2>&1
cp busybox /work/build/overkill/busybox
file /work/build/overkill/busybox
INSIDE
chmod +x tmp-overkill-driver.sh

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD":/work \
    encrypted-linux-image-build \
    bash /work/tmp-overkill-driver.sh

rm -f tmp-overkill-driver.sh
echo ""
ls -la build/overkill/{bzImage,hello,busybox}
