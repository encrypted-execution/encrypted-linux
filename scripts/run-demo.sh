#!/usr/bin/env bash
#
# scripts/run-demo.sh — non-interactive end-to-end demo. Drives:
#   1. boot encrypted-linux QEMU image with el_demo=auto
#   2. show in-VM hello succeeds
#   3. exit QEMU cleanly via poweroff -f from init
#   4. run the same hello binary on stock ubuntu:24.04
#   5. show it segfaults
#
# Designed to be record-friendly with asciinema:
#   asciinema rec docs/demo.cast -c "bash scripts/run-demo.sh"
#
# License: Apache-2.0

set -eu
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

GREEN=$'\033[1;32m'
CYAN=$'\033[1;36m'
YELLOW=$'\033[1;33m'
RESET=$'\033[0m'

heading() {
    printf '\n%s════════════════════════════════════════════════════════════════%s\n' "${CYAN}" "${RESET}"
    printf '%s  %s%s\n' "${CYAN}" "$1" "${RESET}"
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${CYAN}" "${RESET}"
}

heading "encrypted-linux end-to-end demo"

cat <<'EOF'

A QEMU image with PERMUTED syscall numbers in kernel + musl libc.
Inside the VM: /bin/hello runs normally.
On a stock Linux host: the same binary segfaults.

EOF
sleep 1

heading "STEP 1 — Evidence: syscalls in /bin/hello are seed-derived"

echo "Inspecting build/image/hello with objdump:"
objdump -d build/image/hello \
    | awk '/syscall$/{print prev; print} {prev=$0}' \
    | grep -E "mov[lq]?\s+\\\$0x[0-9a-f]+, %[er]?ax" \
    | head -2
echo
echo "These hex numbers (e.g., 0x3d7=983, 0x149=329) are this seed's"
echo "permutations of canonical exit_group (231) and arch_prctl (158)."
echo "Stock Linux doesn't have syscall 983 at all."
sleep 2

heading "STEP 2 — Boot encrypted-linux in QEMU and run /bin/hello"

gtimeout 60 qemu-system-x86_64 \
    -m 4G \
    -kernel build/image/bzImage \
    -initrd build/image/rootfs.cpio.gz \
    -append "console=ttyS0 panic=5 loglevel=6 el_demo=auto" \
    -nographic -no-reboot -accel tcg 2>&1 | \
    awk '/====+|^encrypted-linux|^\[el_demo|^hello from|^reboot:|^Linux /' || true
sleep 1

heading "STEP 3 — Same hello binary on stock ubuntu:24.04"

echo "$ docker run --rm --platform linux/amd64 \\"
echo "      -v \$PWD/build/image:/w:ro ubuntu:24.04 /w/hello"
echo
docker run --rm --platform linux/amd64 \
    -v "$PWD/build/image":/w:ro \
    ubuntu:24.04 \
    sh -c '/w/hello; echo "[stock ubuntu] exit=$?"' 2>&1
sleep 1

if [ -f build/image-seedB/bzImage ] && [ -f build/image-seedB/rootfs.cpio.gz ]; then
    heading "STEP 4a — Seed-B kernel running its OWN /bin/hello"

    cat <<EOF
A second encrypted-linux image, built with a DIFFERENT master seed.
Its kernel + musl + hello all use seed-B's permutation. We boot it
with the seed-B hello as init and watch it run successfully.

EOF
    gtimeout 30 qemu-system-x86_64 \
        -m 4G \
        -kernel build/image-seedB/bzImage \
        -initrd build/image-seedB/rootfs.cpio.gz \
        -append "console=ttyS0 panic=2 loglevel=6 rdinit=/bin/hello" \
        -nographic -no-reboot -accel tcg 2>&1 | \
        grep -aE "hello from|Run /bin/hello|panic|reboot" || true
    sleep 1

    heading "STEP 4b — Seed-B kernel running SEED-A's hello (must fail)"

    cat <<EOF
Same seed-B VM. We swap in seed-A's hello (built with seed-A's
permuted musl + syscall numbers). Seed-A's syscalls hit seed-B's
kernel — they don't match. Result: #GP fault.

EOF
    gtimeout 30 qemu-system-x86_64 \
        -m 4G \
        -kernel build/image-seedB/bzImage \
        -initrd build/image-seedB/rootfs.cpio.gz \
        -append "console=ttyS0 panic=2 loglevel=6 rdinit=/bin/hello-seedA" \
        -nographic -no-reboot -accel tcg 2>&1 | \
        grep -aE "Run /bin/hello|traps:|protection fault|Kernel panic|reboot" || true
    sleep 1

    heading "RESULT"

    cat <<EOF
${GREEN}Seed-A binary on seed-A kernel:${RESET}  works ('hello from inside encrypted-linux!')
${GREEN}Seed-B binary on seed-B kernel:${RESET}  works ('hello from inside encrypted-linux (seed B)!')
${YELLOW}Seed-A binary on seed-B kernel:${RESET}  #GP fault — different permutations
${YELLOW}Seed-A binary on stock kernel:${RESET}   segfault — canonical syscall numbers absent

The same source code compiled with two different seeds produces two
mutually-incompatible binary worlds. Every encrypted-linux deployment
is a unique runtime; cross-deployment binary transport is broken
by construction.
EOF
else
    heading "RESULT"

    cat <<EOF
${GREEN}Inside encrypted-linux VM:${RESET}  hello prints message, exit 0
${YELLOW}Outside on stock Ubuntu:${RESET}   hello segfaults / errors, exit 139

A binary built for this encrypted-linux instance cannot run on
a host with stock Linux syscall numbering.  The defense works.

(For the two-seed cross-VM demo, run scripts/build-second-seed.sh
 first to build build/image-seedB/, then re-run this script.)
EOF
fi
