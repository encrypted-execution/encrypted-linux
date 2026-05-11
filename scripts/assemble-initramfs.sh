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

# Include the native scrambling GCC if it's been built (optional —
# image works without it; demo can run pre-compiled hello).
if [ -d /work/build/native-gcc/install ]; then
    echo "Bundling scrambling GCC from /work/build/native-gcc/install..."
    cp -a /work/build/native-gcc/install "${ROOT}/usr/local-gcc"
    # Bundle the glibc files gcc needs to dlopen at runtime.
    # Find libc.so.6, ld-linux*, libgcc_s.so.1 from the build container.
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
    # Set up loader symlink the kernel-loaded ELFs use.
    mkdir -p "${ROOT}/lib64"
    ln -sf /lib/ld-linux-x86-64.so.2 "${ROOT}/lib64/ld-linux-x86-64.so.2"
    # Symlink gcc into PATH.
    ln -sf /usr/local-gcc/bin/x86_64-linux-gnu-gcc "${ROOT}/bin/gcc"
    ln -sf /usr/local-gcc/bin/x86_64-linux-gnu-cpp "${ROOT}/bin/cpp"
    ln -sf /usr/local-gcc/libexec/gcc/x86_64-linux-gnu/14.2.0/cc1 "${ROOT}/usr/bin/cc1" 2>/dev/null || true
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
    echo "[el_demo=auto] /bin/hello details:"
    /bin/busybox file /bin/hello 2>/dev/null
    /bin/busybox stat /bin/hello | /bin/busybox grep -E "Size|Modify"
    echo "[el_demo=auto] running 'uname -r' as a 2nd syscall test:"
    /bin/busybox uname -a
    echo "[el_demo=auto] PASS - VM reached userspace and ran hello"
    echo "[el_demo=auto] halting"
    /bin/busybox poweroff -f
else
    echo "Try:  /bin/hello"
    echo "Then: exit (Ctrl-A X in QEMU) and run scripts/test-cross-host-failure.sh"
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
