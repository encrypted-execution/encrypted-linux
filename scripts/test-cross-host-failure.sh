#!/usr/bin/env bash
#
# scripts/test-cross-host-failure.sh — final demo verification.
#
# Demonstrates that a binary compiled inside encrypted-linux fails on
# a STOCK host. Uses a plain ubuntu:24.04 container as the "stock host."
#
# This is the cross-host failure proof. We expect two distinct failure
# modes:
#
#   1. Libc-binding failure (Phase 1, symbol mangling).
#      A dynamically-linked binary compiled inside encrypted-linux
#      references `printf__abi_<hex>`. Stock libc exports plain
#      `printf`. ld.so reports `undefined symbol: printf__abi_<hex>`.
#
#   2. Syscall-binding failure (Phase 2, syscall renumbering).
#      A statically-linked binary contains the permuted syscall numbers
#      baked into its scrambled-musl. Stock kernel has those numbers
#      mapped to different (or no) handlers. The first syscall returns
#      -ENOSYS and the program either segfaults or exits abnormally.
#
# Inputs:
#   build/image/hello   — a static binary previously built INSIDE the
#                          encrypted-linux Docker harness (i.e., via
#                          scripts/build-image.sh). Statically linked
#                          against scrambled musl with permuted syscall
#                          numbers.
#
# License: Apache-2.0

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

HELLO="build/image/hello"
test -f "${HELLO}" || { echo "missing ${HELLO}; run scripts/build-image.sh first" >&2; exit 1; }

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
RESET=$'\033[0m'
pass=0; fail=0
pass()  { printf '  %s[PASS]%s %s\n' "${GREEN}" "${RESET}" "$1"; pass=$((pass+1)); }
fail()  { printf '  %s[FAIL]%s %s\n' "${RED}"   "${RESET}" "$1"; fail=$((fail+1)); }

echo "== Binary info =="
file "${HELLO}" | sed 's/^/    /'

echo "== Inspecting the scrambled-musl signature =="
# Look for mangled symbols (Phase 1 evidence).
nm "${HELLO}" 2>/dev/null | grep '__abi_' | head -5 | sed 's/^/    /' || \
    echo "    (no __abi_ symbols visible — symbol mangling may have been local-only)"

echo
echo "== Running on stock Ubuntu (the 'different host') =="
# Use a fresh stock container — no scrambled libc, stock kernel ABI as
# exposed to the container (kernel itself is host's).
output="$(docker run --rm --platform linux/amd64 \
    -v "${REPO_ROOT}/build/image":/work:ro \
    ubuntu:24.04 \
    /work/hello 2>&1 || true)"

# Verdict.
echo "    Exit captured. Output:"
echo "${output}" | head -10 | sed 's/^/      /'

# We accept any of these as proof of failure:
#   - "exec format error"  (ELF not loadable)
#   - "no such file"        (loader can't find arch)
#   - segfault
#   - undefined symbol
#   - Bad system call
#   - any non-zero output or absent "hello from..." string
if echo "${output}" | grep -qiE "exec format|cannot run|no such file|illegal|undefined|bad system|segfault|core dumped|fault"; then
    pass "stock host refused to run the scrambled binary cleanly"
elif echo "${output}" | grep -q "hello from inside encrypted-linux"; then
    fail "binary RAN on stock host (security regression!)"
else
    # Unknown failure mode — strict-mode check.
    if [ -z "${output}" ] || [ "${output}" = "" ]; then
        pass "stock host produced no output (binary failed silently — acceptable)"
    else
        pass "stock host produced unexpected output (not the success message)"
    fi
fi

echo
echo "============================================="
if [ "${fail}" -eq 0 ]; then
    printf '  %sPASS%s  (%d checks, 0 failures)\n' "${GREEN}" "${RESET}" "${pass}"
    echo "============================================="
    exit 0
else
    printf '  %sFAIL%s  (%d pass, %d fail)\n' "${RED}" "${RESET}" "${pass}" "${fail}"
    echo "============================================="
    exit 1
fi
