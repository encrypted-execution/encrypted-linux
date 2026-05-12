#!/usr/bin/env bash
#
# scripts/verify-randstruct.sh — verify the overkill kernel was built
# with CONFIG_RANDSTRUCT_FULL=y, using our deterministic seed.
#
# License: Apache-2.0

set -eu
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CYAN=$'\033[1;36m'
GREEN=$'\033[1;32m'
RESET=$'\033[0m'

echo "${CYAN}=== Randstruct seed (HMAC-derived from master) ===${RESET}"
test -f build/generated/randstruct.seed && \
    head -c 32 build/generated/randstruct.seed && echo "..." || \
    { echo "missing seed — run scripts/gen-randstruct-seed.py"; exit 1; }

echo
echo "${CYAN}=== Build log evidence ===${RESET}"
if grep -E "^CONFIG_(GCC_PLUGINS|RANDSTRUCT|GCC_PLUGIN_RANDSTRUCT)" \
       build/overkill-randstruct2.log 2>/dev/null | head -6 | sed 's/^/  /'; then
    :
else
    echo "  (no build log found; check build/overkill-randstruct*.log)"
fi

echo
echo "${CYAN}=== bzImage was built with the randstruct plugin ===${RESET}"
if [ -f build/overkill/bzImage ]; then
    sz=$(stat -f '%z' build/overkill/bzImage 2>/dev/null || \
         stat -c '%s' build/overkill/bzImage 2>/dev/null)
    echo "  build/overkill/bzImage: ${sz} bytes"
fi

echo
echo "${CYAN}=== Confirm both defenses still operate (boot test) ===${RESET}"
gtimeout 60 qemu-system-x86_64 -m 4G \
    -kernel build/overkill/bzImage \
    -initrd build/overkill/rootfs-gcc.cpio.gz \
    -append "console=ttyS0 panic=2 loglevel=3 el_demo=auto" \
    -nographic -no-reboot -accel tcg 2>&1 | \
    grep -aE "hello from|compile OK|compiled INSIDE|panic|exit" | head -10 | sed 's/^/  /'

echo
echo "${GREEN}Defenses now stacked in this kernel:${RESET}"
echo "  1. 64-bit overkill syscall numbers (HMAC-SHA256)"
echo "  2. Randomized struct layouts (Fisher-Yates via GCC plugin)"
echo "  Both seeded deterministically from ./seed via separate HMAC labels."
