#!/usr/bin/env bash
#
# scripts/run-qemu.sh — boot the encrypted-linux image in QEMU.
#
# Inputs:
#   build/image/bzImage      — patched kernel
#   build/image/rootfs.cpio.gz — initramfs with patched musl, busybox, hello
#
# License: Apache-2.0

set -eu
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

KERNEL="build/image/bzImage"
INITRD="build/image/rootfs.cpio.gz"

test -f "${KERNEL}" || { echo "missing ${KERNEL} — run scripts/build-image.sh first" >&2; exit 1; }
test -f "${INITRD}" || { echo "missing ${INITRD} — run scripts/build-image.sh first" >&2; exit 1; }

# On arm64 macOS we use the system qemu-system-x86_64 (TCG emulation).
qemu-system-x86_64 \
    -m 512M \
    -kernel "${KERNEL}" \
    -initrd "${INITRD}" \
    -append "console=ttyS0 quiet" \
    -nographic \
    -no-reboot \
    -accel tcg
