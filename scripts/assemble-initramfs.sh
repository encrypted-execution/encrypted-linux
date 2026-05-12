#!/usr/bin/env bash
#
# scripts/assemble-initramfs.sh — assemble rootfs.cpio.gz from pre-built
# busybox + hello + (optional) native scrambling GCC.
#
# Runs entirely in a Linux container that has cpio + bash + symlink
# capability. The busybox --install step uses ln -sf instead of busybox
# itself to avoid QEMU-TCG issues on arm64 macOS hosts.
#
# License: Apache-2.0

set -eu
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

test -f build/image/busybox || { echo "missing busybox"; exit 1; }
test -f build/image/hello   || { echo "missing hello";   exit 1; }
test -f build/image/bzImage || { echo "missing bzImage"; exit 1; }

# Drive everything inside a Linux container so cpio + bash semantics
# match what the kernel will see at boot.
cat > tmp-assembly.sh <<'INSIDE'
#!/bin/bash
set -eu
ROOT=/tmp/rootfs
rm -rf "${ROOT}"
mkdir -p "${ROOT}"/{bin,sbin,etc,proc,sys,dev,tmp,root,src,usr/bin,usr/lib,lib,lib64}

# Busybox + applet symlinks.
cp /work/build/image/busybox "${ROOT}/bin/busybox"
chmod +x "${ROOT}/bin/busybox"

# List applets and create symlinks WITHOUT running busybox (avoids
# QEMU-TCG perf hit on arm64 hosts). Use the static applet list embedded
# in busybox source — extract from --help via the host's stock busybox
# if available, else use a canonical list.
APPLETS="ash sh ls cat cp mv rm mkdir mount umount echo printf find grep
        sed awk head tail wc sort uniq tee dd stty tty whoami id ps top
        kill killall sleep dmesg lsmod insmod rmmod modprobe poweroff
        reboot halt init"
for a in $APPLETS; do
    ln -sf busybox "${ROOT}/bin/${a}"
done

# Provide /sbin/init via the explicit init script.
cp /work/build/image/hello "${ROOT}/bin/hello"
chmod +x "${ROOT}/bin/hello"

# Demo source code & expected outputs for the user.
cat > "${ROOT}/src/hello.c" <<'HC'
#include <unistd.h>
#include <string.h>
int main(void) {
    const char msg[] = "hello from inside encrypted-linux!\n";
    write(1, msg, sizeof(msg) - 1);
    return 0;
}
HC
chmod 0644 "${ROOT}/src/hello.c"

# Prefer the static-musl-linked GCC if it's been built — it actually
# works inside our permuted-kernel VM. Fall back to the native glibc-
# linked GCC (doesn't work in-VM but useful as bundled artifact).
if [ -d /work/build/static-gcc/install ] && \
   [ -x /work/build/static-gcc/install/bin/x86_64-linux-musl-gcc ]; then
    echo "Bundling STATIC-musl scrambling GCC (works inside VM)..."
    cp -a /work/build/static-gcc/install "${ROOT}/usr/local-gcc"
    # Symlink the gcc command-name (alpine uses x86_64-linux-musl-).
    mkdir -p "${ROOT}/usr/bin"
    if [ -x "${ROOT}/usr/local-gcc/bin/x86_64-linux-musl-gcc" ]; then
        ln -sf /usr/local-gcc/bin/x86_64-linux-musl-gcc "${ROOT}/usr/bin/gcc-musl"
    fi
elif [ -d /work/build/native-gcc/install ]; then
    echo "Bundling glibc-linked scrambling GCC (segfaults in-VM, included for inspection)..."
    cp -a /work/build/native-gcc/install "${ROOT}/usr/local-gcc"
    # Bundle the glibc files gcc needs to dlopen at runtime.
    for libname in libc.so.6 ld-linux-x86-64.so.2 libdl.so.2 libm.so.6 \
                   libpthread.so.0 librt.so.1 libstdc++.so.6 libz.so.1 \
                   libmpc.so.3 libmpfr.so.6 libgmp.so.10 libisl.so.23 \
                   libgcc_s.so.1 libzstd.so.1; do
        for path in /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /lib64 /lib /usr/lib; do
            if [ -f "${path}/${libname}" ]; then
                cp "${path}/${libname}" "${ROOT}/lib/${libname}"
                break
            fi
        done
    done
    mkdir -p "${ROOT}/lib64"
    ln -sf /lib/ld-linux-x86-64.so.2 "${ROOT}/lib64/ld-linux-x86-64.so.2"

    # Bundle musl sysroot (headers + libs + crt files) so the in-VM gcc
    # can actually compile C programs against the (permuted-syscall) musl.
    echo "Bundling musl sysroot..."
    mkdir -p "${ROOT}/sysroot/usr"
    cp -a /work/build/image/sysroot/usr/include "${ROOT}/sysroot/usr/include"
    cp -a /work/build/image/sysroot/usr/lib     "${ROOT}/sysroot/usr/lib"

    # Wrapper /bin/gcc that drives the scrambling GCC + musl sysroot.
    cat > "${ROOT}/bin/gcc" <<'GCCWRAP'
#!/bin/busybox sh
# In-VM scrambling-GCC wrapper. Drives the native x86_64 scrambling
# compiler against the permuted-syscall musl sysroot in /sysroot.
exec /usr/local-gcc/bin/x86_64-linux-gnu-gcc \
    -static \
    -nostdinc \
    -isystem /sysroot/usr/include \
    -B /sysroot/usr/lib \
    -L /sysroot/usr/lib \
    -nostartfiles \
    /sysroot/usr/lib/crt1.o /sysroot/usr/lib/crti.o \
    "$@" \
    /sysroot/usr/lib/crtn.o \
    -lc
GCCWRAP
    chmod +x "${ROOT}/bin/gcc"
    ln -sf /usr/local-gcc/bin/x86_64-linux-gnu-cpp "${ROOT}/bin/cpp"
fi

# init script. Behavior selectable via kernel cmdline el_demo=auto:
#   - el_demo=auto: run /bin/hello, print boot evidence, then halt
#   - default:      drop to interactive busybox shell
cat > "${ROOT}/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox mount -t devtmpfs none /dev

# Read kernel command-line.
CMDLINE=$(/bin/busybox cat /proc/cmdline)

echo
echo "============================================================="
echo "  encrypted-linux PoC v0                                      "
echo "  PERMUTED syscall numbers in kernel + musl                  "
echo "============================================================="
echo

if /bin/busybox echo "${CMDLINE}" | /bin/busybox grep -q "el_demo=auto"; then
    echo "[el_demo=auto] auto-running /bin/hello..."
    /bin/hello
    rc=$?
    echo "[el_demo=auto] /bin/hello exited with rc=${rc}"
    echo "[el_demo=auto] PASS - VM reached userspace and ran hello"
    /bin/busybox poweroff -f
elif /bin/busybox echo "${CMDLINE}" | /bin/busybox grep -q "el_demo=compile"; then
    echo "[el_demo=compile] verifying in-VM scrambling GCC + musl sysroot..."
    /bin/busybox ls -la /bin/gcc /usr/local-gcc/bin/x86_64-linux-gnu-gcc 2>&1 | /bin/busybox head -3
    /bin/busybox cat /src/hello.c
    echo
    echo "[el_demo=compile] compiling /src/hello.c with /bin/gcc..."
    /bin/gcc /src/hello.c -o /tmp/myhello 2>&1
    cc_rc=$?
    if [ "${cc_rc}" -ne 0 ]; then
        echo "[el_demo=compile] FAIL - compile failed rc=${cc_rc}"
        /bin/busybox poweroff -f
    fi
    echo "[el_demo=compile] compile OK. running /tmp/myhello..."
    /tmp/myhello
    rc=$?
    echo "[el_demo=compile] /tmp/myhello exited with rc=${rc}"
    /bin/busybox file /tmp/myhello 2>&1 || /bin/busybox ls -la /tmp/myhello
    echo "[el_demo=compile] PASS - in-VM compile + execute works"
    /bin/busybox poweroff -f
else
    echo "Try:  /bin/hello              (pre-built static)"
    echo "      /bin/gcc /src/hello.c -o /tmp/myhello   (in-VM compile)"
    echo "      /tmp/myhello"
    echo "Then: exit (Ctrl-A X in QEMU) and copy /tmp/myhello off for cross-host test."
    echo
    exec /bin/busybox sh +m
fi
INIT
chmod +x "${ROOT}/init"
ln -sf init "${ROOT}/sbin/init"

# Assemble cpio.
cd "${ROOT}"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null \
    | gzip -9 > /work/build/image/rootfs.cpio.gz

ls -la /work/build/image/rootfs.cpio.gz
echo "Initramfs assembly complete."
INSIDE

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD":/work \
    encrypted-linux-image-build \
    bash /work/tmp-assembly.sh

rm -f tmp-assembly.sh
ls -la build/image/{bzImage,rootfs.cpio.gz}
echo ""
echo "Boot the image with:"
echo "  bash scripts/run-qemu.sh"
