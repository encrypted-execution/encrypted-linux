#!/usr/bin/env bash
#
# scripts/assemble-overkill-initramfs.sh — assemble rootfs.cpio.gz
# from the overkill build artifacts (build/overkill/{busybox,hello}).
#
# Same shape as scripts/assemble-initramfs.sh but uses build/overkill/.
# Smaller (no bundled GCC — overkill demo is binary-cross-host only).
#
# License: Apache-2.0

set -eu
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

test -f build/overkill/busybox || { echo "missing busybox"; exit 1; }
test -f build/overkill/hello   || { echo "missing hello";   exit 1; }
test -f build/overkill/bzImage || { echo "missing bzImage"; exit 1; }

cat > tmp-asm-overkill.sh <<'INSIDE'
#!/bin/bash
set -eu
ROOT=/tmp/rootfs-overkill
rm -rf "${ROOT}"
mkdir -p "${ROOT}"/{bin,sbin,etc,proc,sys,dev,tmp,root,src}

cp /work/build/overkill/busybox "${ROOT}/bin/busybox"
chmod +x "${ROOT}/bin/busybox"
APPLETS="ash sh ls cat cp mv rm mkdir mount umount echo printf find grep
        sed awk head tail wc sort uniq tee dd stty tty whoami id ps top
        kill killall sleep dmesg lsmod insmod rmmod modprobe poweroff
        reboot halt init"
for a in $APPLETS; do ln -sf busybox "${ROOT}/bin/${a}"; done

cp /work/build/overkill/hello "${ROOT}/bin/hello"
chmod +x "${ROOT}/bin/hello"

# Bundle the 10-bit-slot hello (build/image/hello) too, so the overkill VM
# can demonstrate cross-scheme failure: the slot-scheme binary uses
# small syscall numbers that the overkill kernel doesn't know.
if [ -f /work/build/image/hello-seedA ]; then
    cp /work/build/image/hello-seedA "${ROOT}/bin/hello-10bit"
elif [ -f /work/build/image/hello ]; then
    cp /work/build/image/hello "${ROOT}/bin/hello-10bit"
fi

cat > "${ROOT}/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox mount -t devtmpfs none /dev
CMDLINE=$(/bin/busybox cat /proc/cmdline)
echo
echo "============================================================="
echo "  encrypted-linux OVERKILL (64-bit syscall numbers)"
echo "============================================================="
echo
if /bin/busybox echo "${CMDLINE}" | /bin/busybox grep -q "el_demo=auto"; then
    echo "[overkill] /bin/hello (64-bit syscalls):"
    /bin/hello; echo "  -> exit $?"
    if [ -f /bin/hello-10bit ]; then
        echo
        echo "[overkill] /bin/hello-10bit (old 10-bit-slot syscalls — should fail):"
        /bin/hello-10bit; echo "  -> exit $?"
    fi
    /bin/busybox poweroff -f
else
    echo "Try /bin/hello (overkill) and /bin/hello-10bit (slot scheme)."
    exec /bin/busybox sh +m
fi
INIT
chmod +x "${ROOT}/init"
ln -sf init "${ROOT}/sbin/init"

cd "${ROOT}"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null \
    | gzip -9 > /work/build/overkill/rootfs.cpio.gz
ls -la /work/build/overkill/rootfs.cpio.gz
INSIDE
chmod +x tmp-asm-overkill.sh

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD":/work \
    encrypted-linux-image-build \
    bash /work/tmp-asm-overkill.sh

rm -f tmp-asm-overkill.sh
ls -la build/overkill/{bzImage,rootfs.cpio.gz}
