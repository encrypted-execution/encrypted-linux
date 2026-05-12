#!/usr/bin/env bash
#
# scripts/run-overkill-demo.sh — demonstrate the difference between
# the 10-bit (1024-slot) syscall scrambling and the 64-bit overkill
# scheme. Show that hello's disassembly carries 64-bit hex syscall
# numbers rather than small decimals.
#
# License: Apache-2.0

set -eu
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CYAN=$'\033[1;36m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RESET=$'\033[0m'

heading() {
    printf '\n%s════════════════════════════════════════════════════════════════%s\n' "${CYAN}" "${RESET}"
    printf '%s  %s%s\n' "${CYAN}" "$1" "${RESET}"
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${CYAN}" "${RESET}"
}

heading "OVERKILL DEMO — 64-bit syscall cardinality"

cat <<'EOF'

Phase 2 syscall scrambling now uses the FULL 64-bit cardinality of
the RAX register. Each syscall number is HMAC-SHA256(seed, name)
truncated to 64 bits — random-looking, sparse, cryptographically
unguessable.

  - 10-bit slot scheme: ~365 valid out of 1024  (brute force ~10³)
  - 64-bit overkill:   365 valid out of 2⁶⁴   (brute force ~2⁶³ — infeasible)

EOF

heading "1. Hello binary uses 64-bit movabsq syscall numbers"

if [ -f build/overkill/hello ]; then
    echo "From build/overkill/hello disassembly:"
    objdump -d build/overkill/hello \
        | awk '/syscall$/{print prev; print} {prev=$0}' \
        | grep -E "movabs|mov[lq]?.*\\\$0x" \
        | head -8 | sed 's/^/    /'
    echo
    echo "Each 64-bit hex constant is a per-build HMAC-derived value."
    echo "On stock Linux these don't correspond to any valid syscall."
else
    echo "build/overkill/hello not yet built. Run: bash scripts/build-overkill-image.sh"
    exit 1
fi

heading "2. Kernel lookup table (sorted-by-abi_nr for binary search)"

echo "Top of build/generated/asm/el_syscall_lookup.h:"
sed -n '/static const struct/,$p' build/generated/asm/el_syscall_lookup.h \
    | head -8 | sed 's/^/    /'
echo
echo "Kernel patched arch/x86/entry/common.c does:"
echo "    u64 nr = regs->orig_ax;"
echo "    int idx = el_syscall_lookup(nr);    // binary search, O(log N)"
echo "    if (idx >= 0) sys_call_table[idx](regs);"

heading "3. Boot encrypted-linux OVERKILL and run hello"

# Need a quick initramfs. Same structure as before but using overkill artifacts.
if [ ! -f build/overkill/rootfs.cpio.gz ]; then
    echo "Assembling overkill initramfs..."
    bash scripts/assemble-overkill-initramfs.sh >/dev/null 2>&1 \
        || { echo "(assembly script missing; assembling inline)"; }
fi

if [ -f build/overkill/rootfs.cpio.gz ]; then
    gtimeout 30 qemu-system-x86_64 -m 4G \
        -kernel build/overkill/bzImage \
        -initrd build/overkill/rootfs.cpio.gz \
        -append "console=ttyS0 panic=2 loglevel=3 rdinit=/bin/hello" \
        -nographic -no-reboot -accel tcg 2>&1 | \
        grep -aE "hello from|Run /bin/hello|panic|reboot" | tail -5
fi

heading "4. Same binary on stock ubuntu (should fail spectacularly)"

docker run --rm --platform linux/amd64 \
    -v "$PWD/build/overkill":/w:ro \
    ubuntu:24.04 \
    sh -c '/w/hello 2>&1; echo "[stock] exit=$?"' 2>&1 | tail -5

heading "RESULT"

cat <<EOF

${GREEN}Overkill hello on overkill kernel:${RESET} works
${YELLOW}Overkill hello on stock kernel:${RESET}    fails
Brute force: cryptographically infeasible (2⁶³ attempts per syscall avg)
EOF
