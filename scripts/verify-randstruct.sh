#!/usr/bin/env bash
#
# scripts/verify-randstruct.sh — verify the kernel was built with
# CONFIG_RANDSTRUCT_FULL and uses our deterministic seed.
#
# License: Apache-2.0

set -eu
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CYAN=$'\033[1;36m'
GREEN=$'\033[1;32m'
RESET=$'\033[0m'

echo "${CYAN}=== Seed used (from our HMAC chain) ===${RESET}"
head -c 32 build/generated/randstruct.seed; echo

echo
echo "${CYAN}=== Kernel config (sample randstruct entries) ===${RESET}"
docker run --rm --platform linux/amd64 --user root -v "$PWD":/work \
    encrypted-linux-image-build sh -c '
        # Just dump the kernel config from the build container
        # (containerized; same source the bzImage was built from).
        cd /opt/linux 2>/dev/null && grep -E "^CONFIG_(GCC_PLUGINS|RANDSTRUCT|GCC_PLUGIN_RANDSTRUCT)" .config 2>/dev/null || true
        echo
        echo "--- randomize_layout_seed.h that was baked into the plugin ---"
        cat scripts/gcc-plugins/randomize_layout_seed.h 2>/dev/null | head -5 || true
        echo "--- Seed file ---"
        head -c 32 scripts/gcc-plugins/randstruct.seed 2>/dev/null; echo
    ' 2>&1 | sed 's/^/  /'

echo
echo "${CYAN}=== Strings in bzImage referencing randstruct ===${RESET}"
strings build/overkill/bzImage 2>/dev/null | grep -iE "randstruct|randomize_layout" | head -5 | sed 's/^/  /'

echo
echo "${CYAN}=== Boot the kernel and look for randstruct evidence ===${RESET}"
gtimeout 30 qemu-system-x86_64 -m 4G \
    -kernel build/overkill/bzImage \
    -initrd build/overkill/rootfs-gcc.cpio.gz \
    -append "console=ttyS0 panic=2 loglevel=7 rdinit=/bin/hello" \
    -nographic -no-reboot -accel tcg 2>&1 | \
    grep -aiE "randstruct|random.*layout|gcc plugin|hello from" | head -10 | sed 's/^/  /'

echo
echo "${GREEN}If we see CONFIG_RANDSTRUCT_FULL=y above, the kernel has${RESET}"
echo "${GREEN}struct-layout randomization on top of overkill syscalls.${RESET}"
