#!/usr/bin/env bash
#
# scripts/scramble-mangle-test/test.sh
#
# Demonstrates the encrypted-linux Phase-1 symbol-mangling failure mode.
#
# Three link cases:
#   1. stock main.o     + stock libthing.o     → links, runs, exits 42      (PASS)
#   2. scrambled main.o + stock libthing.o     → link fails (undefined ref) (PASS if fails)
#   3. scrambled main.o + scrambled libthing.o → links, runs, exits 42      (PASS)
#
# Run on a Linux host with gcc + binutils + openssl. For macOS hosts,
# invoke via docker/test.sh instead (this script makes ELF assumptions).
#
# License: Apache-2.0

set -u

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd ../.. && pwd)"
MANGLE="${REPO_ROOT}/scripts/scramble-mangle.sh"
SEED_FILE="${ENCRYPTED_LINUX_SEED_FILE:-${REPO_ROOT}/seed}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
RESET=$'\033[0m'
pass=0
fail=0
pass()  { printf '  %s[PASS]%s %s\n' "${GREEN}" "${RESET}" "$1"; pass=$((pass+1)); }
fail()  { printf '  %s[FAIL]%s %s\n' "${RED}"   "${RESET}" "$1"; fail=$((fail+1)); }

cc()    { gcc -fno-pie -no-pie -c "$@"; }
link()  { gcc -fno-pie -no-pie -o "$@"; }

# ---- Build object files ----------------------------------------------------
cc -o "${WORK}/main.stock.o"     main.c
cc -o "${WORK}/libthing.stock.o" libthing.c

# Mangled copies — use the seed-derived ABI tag for compute, main, etc.
"${MANGLE}" "${WORK}/main.stock.o"     "${WORK}/main.scr.o"     "$(cat "${SEED_FILE}")"
"${MANGLE}" "${WORK}/libthing.stock.o" "${WORK}/libthing.scr.o" "$(cat "${SEED_FILE}")"

# ---- Test 1: stock + stock --------------------------------------------------
echo "== Test 1: stock main + stock libthing =="
if link "${WORK}/all_stock" "${WORK}/main.stock.o" "${WORK}/libthing.stock.o" 2>"${WORK}/link1.err"; then
    pass "all-stock binary linked"
    "${WORK}/all_stock"; rc=$?
    if [ "${rc}" -eq 42 ]; then
        pass "all-stock binary exits 42"
    else
        fail "all-stock binary exited ${rc} (expected 42)"
    fi
else
    fail "all-stock link unexpectedly failed:"
    sed 's/^/    /' "${WORK}/link1.err" >&2
fi

# ---- Test 2: scrambled main + stock libthing (must fail) --------------------
echo "== Test 2: scrambled main + stock libthing (must fail to link) =="
if link "${WORK}/cross_broken" "${WORK}/main.scr.o" "${WORK}/libthing.stock.o" 2>"${WORK}/link2.err"; then
    fail "scrambled-main / stock-libthing UNEXPECTEDLY linked (this is a security bug)"
else
    # Confirm the failure is the mangled-symbol kind.
    if grep -q 'compute__abi_' "${WORK}/link2.err"; then
        pass "link failed with undefined reference to compute__abi_<hex>"
        echo "    $(grep compute__abi_ "${WORK}/link2.err" | head -1)"
    else
        fail "link failed but not for the expected reason:"
        sed 's/^/    /' "${WORK}/link2.err" >&2
    fi
fi

# ---- Test 3: scrambled main + scrambled libthing ----------------------------
echo "== Test 3: scrambled main + scrambled libthing =="
if link "${WORK}/all_scrambled" "${WORK}/main.scr.o" "${WORK}/libthing.scr.o" 2>"${WORK}/link3.err"; then
    pass "all-scrambled binary linked"
    "${WORK}/all_scrambled"; rc=$?
    if [ "${rc}" -eq 42 ]; then
        pass "all-scrambled binary exits 42 (same answer, scrambled ABI)"
    else
        fail "all-scrambled binary exited ${rc} (expected 42)"
    fi

    # Symbol-table evidence — confirm the function name was actually rewritten.
    echo "  Symbols visible in scrambled object:"
    nm "${WORK}/libthing.scr.o" | grep -E 'compute' | sed 's/^/    /' || true
else
    fail "all-scrambled link unexpectedly failed:"
    sed 's/^/    /' "${WORK}/link3.err" >&2
fi

# ---- Summary ----------------------------------------------------------------
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
