#!/usr/bin/env bash
#
# scripts/assemble-overkill-gcc-initramfs.sh — assemble an initramfs
# with Alpine's gcc toolchain bundled INSIDE, using our overkill musl
# as the dynamic loader.
#
# When the VM boots:
#   - gcc starts up
#   - Linux loads gcc's ELF, sees PT_INTERP = /lib/ld-musl-x86_64.so.1
#   - Loads OUR overkill musl as the loader
#   - Loader resolves gcc's libc symbols (write, mmap, etc.) against
#     our overkill libc.so
#   - Every syscall gcc issues uses our scrambled numbers
#
# License: Apache-2.0

set -eu
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

test -f build/overkill/bzImage      || { echo "missing bzImage"; exit 1; }
test -f build/overkill/busybox      || { echo "missing busybox"; exit 1; }
test -f build/overkill/hello        || { echo "missing hello"; exit 1; }
test -f build/overkill/sysroot/usr/lib/libc.so || \
    { echo "missing overkill libc.so — run scripts/build-overkill-musl-shared.sh"; exit 1; }
test -d build/alpine-toolchain      || \
    { echo "missing Alpine toolchain — run scripts/extract-alpine-toolchain.sh"; exit 1; }

cat > tmp-asm-gcc.sh <<'INSIDE'
#!/bin/bash
set -eu
ROOT=/tmp/rootfs-overkill-gcc
rm -rf "${ROOT}"
mkdir -p "${ROOT}"/{bin,sbin,etc,proc,sys,dev,tmp,root,src,usr,lib,lib64}

# 1. Busybox + applet symlinks.
cp /work/build/overkill/busybox "${ROOT}/bin/busybox"
chmod +x "${ROOT}/bin/busybox"
APPLETS="ash sh ls cat cp mv rm mkdir mount umount echo printf find grep
        sed awk head tail wc sort uniq tee dd stty tty whoami id ps top
        kill killall sleep dmesg lsmod insmod rmmod modprobe poweroff
        reboot halt init env which time"
for a in $APPLETS; do ln -sf busybox "${ROOT}/bin/${a}"; done

# 2. Pre-built hello (works statically, no gcc needed).
cp /work/build/overkill/hello "${ROOT}/bin/hello"
chmod +x "${ROOT}/bin/hello"

# 3. Overkill musl as the system loader + libc.so.
mkdir -p "${ROOT}/lib"
cp /work/build/overkill/sysroot/usr/lib/libc.so "${ROOT}/lib/ld-musl-x86_64.so.1"
chmod +x "${ROOT}/lib/ld-musl-x86_64.so.1"
ln -sf /lib/ld-musl-x86_64.so.1 "${ROOT}/lib/libc.so"
ln -sf /lib/ld-musl-x86_64.so.1 "${ROOT}/lib/libc.musl-x86_64.so.1"

# Bundle the musl headers + static libc.a + crt files for compilation.
mkdir -p "${ROOT}/usr/include" "${ROOT}/usr/lib"
cp -r /work/build/overkill/sysroot/usr/include/. "${ROOT}/usr/include/"
cp /work/build/overkill/sysroot/usr/lib/*.{a,o,so} "${ROOT}/usr/lib/" 2>/dev/null || true

# 4. Alpine toolchain.
cp -a /work/build/alpine-toolchain/usr/bin/.       "${ROOT}/usr/bin/"     2>/dev/null || mkdir -p "${ROOT}/usr/bin"
cp -a /work/build/alpine-toolchain/usr/bin/.       "${ROOT}/usr/bin/"
cp -a /work/build/alpine-toolchain/usr/lib/.       "${ROOT}/usr/lib/"
cp -a /work/build/alpine-toolchain/usr/libexec/.   "${ROOT}/usr/libexec/" 2>/dev/null || \
    { mkdir -p "${ROOT}/usr/libexec"; cp -a /work/build/alpine-toolchain/usr/libexec/. "${ROOT}/usr/libexec/"; }
# Alpine's headers (override our musl headers in /usr/include since
# Alpine's are what gcc was compiled against).
cp -a /work/build/alpine-toolchain/usr/include/.   "${ROOT}/usr/include/"
# Alpine's gcc expects ld + crt files at /usr/x86_64-alpine-linux-musl/.
if [ -d /work/build/alpine-toolchain/usr/x86_64-alpine-linux-musl ]; then
    cp -a /work/build/alpine-toolchain/usr/x86_64-alpine-linux-musl "${ROOT}/usr/"
fi

# But re-overlay our overkill kernel headers (asm/unistd_64.h with our
# 64-bit ULL values) so gcc-compiled programs see the right __NR_*.
cp -a /work/build/overkill/sysroot/usr/include/asm "${ROOT}/usr/include/" 2>/dev/null || true
cp -a /work/build/overkill/sysroot/usr/include/asm-generic "${ROOT}/usr/include/" 2>/dev/null || true
cp -a /work/build/overkill/sysroot/usr/include/linux "${ROOT}/usr/include/" 2>/dev/null || true

# Symlink /bin/gcc -> /usr/bin/gcc for convenience.
ln -sf /usr/bin/gcc "${ROOT}/bin/gcc"
ln -sf /usr/bin/cc  "${ROOT}/bin/cc"

# collect2 (gcc's link driver) looks for the linker by various names.
# Provide target-prefixed symlinks so the search succeeds.
for tool in ld as ar nm objdump objcopy ranlib strip; do
    if [ -e "${ROOT}/usr/bin/${tool}" ] && [ ! -e "${ROOT}/usr/bin/x86_64-alpine-linux-musl-${tool}" ]; then
        ln -sf "/usr/bin/${tool}" "${ROOT}/usr/bin/x86_64-alpine-linux-musl-${tool}"
    fi
done

# Useful sample to compile.
cat > "${ROOT}/src/hello.c" <<'HC'
#include <unistd.h>
#include <string.h>
int main(void) {
    const char msg[] = "compiled INSIDE the encrypted-linux VM!\n";
    write(1, msg, sizeof(msg) - 1);
    return 0;
}
HC
chmod 0644 "${ROOT}/src/hello.c"

# 5. Init script — supports el_demo=auto for non-interactive boot.
cat > "${ROOT}/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox mount -t devtmpfs none /dev
CMDLINE=$(/bin/busybox cat /proc/cmdline)
echo
echo "============================================================="
echo "  encrypted-linux OVERKILL + in-VM GCC"
echo "  - kernel: 64-bit overkill syscall dispatch"
echo "  - libc:   overkill musl (scrambled syscalls)"
echo "  - gcc:    Alpine's binary, dynamic-linked to overkill libc"
echo "============================================================="
echo

if /bin/busybox echo "${CMDLINE}" | /bin/busybox grep -q "el_demo=auto"; then
    echo "[step 1] /bin/hello (pre-built):"
    /bin/hello; echo "  -> exit $?"
    echo
    echo "[step 2] compile /src/hello.c inside VM:"
    echo "  $ gcc /src/hello.c -o /tmp/myhello"
    /usr/bin/gcc /src/hello.c -o /tmp/myhello 2>&1
    cc_rc=$?
    if [ "${cc_rc}" -ne 0 ]; then
        echo "  COMPILE FAILED rc=${cc_rc}"
        /bin/busybox poweroff -f
    fi
    echo "  compile OK"
    echo
    echo "[step 3] run the in-VM-compiled binary:"
    /tmp/myhello; echo "  -> exit $?"
    /bin/busybox file /tmp/myhello 2>/dev/null || /bin/busybox ls -la /tmp/myhello
    /bin/busybox poweroff -f
else
    echo "Try: gcc /src/hello.c -o /tmp/myhello && /tmp/myhello"
    exec /bin/busybox sh +m
fi
INIT
chmod +x "${ROOT}/init"
ln -sf init "${ROOT}/sbin/init"

cd "${ROOT}"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null \
    | gzip -9 > /work/build/overkill/rootfs-gcc.cpio.gz
ls -la /work/build/overkill/rootfs-gcc.cpio.gz
INSIDE
chmod +x tmp-asm-gcc.sh

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD":/work \
    encrypted-linux-image-build \
    bash /work/tmp-asm-gcc.sh

rm -f tmp-asm-gcc.sh
ls -la build/overkill/rootfs-gcc.cpio.gz
echo "Boot: gtimeout 90 qemu-system-x86_64 -m 4G -kernel build/overkill/bzImage -initrd build/overkill/rootfs-gcc.cpio.gz -append 'console=ttyS0 panic=5 loglevel=3 el_demo=auto' -nographic -no-reboot -accel tcg"
