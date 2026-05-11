#!/usr/bin/env bash
#
# scripts/scramble-mangle-test/test-plugin.sh
#
# Same three link cases as test.sh, but compiled WITH THE GCC PLUGIN
# instead of going through the objcopy post-pass. Demonstrates that
# the compile-time path produces byte-identical mangled symbols.
#
# Additionally verifies cross-compatibility: an object built with the
# plugin can link against an object built with the post-pass (same
# seed). The plugin and the bash post-pass are interchangeable.
#
# Run inside a Linux container with gcc-13 + gcc-13-plugin-dev +
# libssl-dev + binutils + openssl. See docker/Dockerfile.test.
#
# License: Apache-2.0

set -u

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd ../.. && pwd)"
PLUGIN_DIR="${REPO_ROOT}/patches/gcc-plugin-scramble-mangle"
PLUGIN_SO="${PLUGIN_DIR}/scramble-mangle.so"
POST_PASS="${REPO_ROOT}/scripts/scramble-mangle.sh"
SEED_FILE="${ENCRYPTED_LINUX_SEED_FILE:-${REPO_ROOT}/seed}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export ENCRYPTED_LINUX_SEED="$(cat "${SEED_FILE}")"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
RESET=$'\033[0m'
pass=0; fail=0
pass()  { printf '  %s[PASS]%s %s\n' "${GREEN}" "${RESET}" "$1"; pass=$((pass+1)); }
fail()  { printf '  %s[FAIL]%s %s\n' "${RED}"   "${RESET}" "$1"; fail=$((fail+1)); }

# ---- Build the plugin -------------------------------------------------------
echo "== Build plugin =="
if make -C "${PLUGIN_DIR}" GCC=gcc-13 clean all >"${WORK}/plugin-build.log" 2>&1; then
    pass "plugin compiled"
else
    fail "plugin build failed:"
    sed 's/^/    /' "${WORK}/plugin-build.log" >&2
    echo "============================================="
    printf '  %sFAIL%s  (plugin build)\n' "${RED}" "${RESET}"
    echo "============================================="
    exit 1
fi
test -f "${PLUGIN_SO}" && pass "scramble-mangle.so present" || fail "scramble-mangle.so missing"

# ---- Compile via the plugin --------------------------------------------------
echo "== Compile sources via the plugin =="
gcc-13 -fplugin="${PLUGIN_SO}" -fno-pie -c main.c     -o "${WORK}/main.plugin.o"     2>"${WORK}/plugin-main.err"     && pass "main.c compiled via plugin"     || fail "main.c plugin compile failed"
gcc-13 -fplugin="${PLUGIN_SO}" -fno-pie -c libthing.c -o "${WORK}/libthing.plugin.o" 2>"${WORK}/plugin-libthing.err" && pass "libthing.c compiled via plugin" || fail "libthing.c plugin compile failed"

# ---- Symbol-table assertions -------------------------------------------------
echo "== Plugin emitted mangled symbols =="
if nm "${WORK}/libthing.plugin.o" | grep -E ' T compute__abi_[0-9a-f]{8}' >/dev/null; then
    pass "libthing.plugin.o defines compute__abi_<hex>"
    nm "${WORK}/libthing.plugin.o" | grep compute | sed 's/^/    /'
else
    fail "libthing.plugin.o does not define mangled compute"
    nm "${WORK}/libthing.plugin.o" | sed 's/^/    /'
fi
if nm "${WORK}/main.plugin.o" | grep -E ' U compute__abi_[0-9a-f]{8}' >/dev/null; then
    pass "main.plugin.o references compute__abi_<hex> (undefined ref)"
else
    fail "main.plugin.o does not reference mangled compute"
    nm "${WORK}/main.plugin.o" | sed 's/^/    /'
fi

# ---- Parity check: plugin output matches post-pass output --------------------
echo "== Parity vs. post-compile pass =="
gcc -fno-pie -c libthing.c -o "${WORK}/libthing.stock.o"
"${POST_PASS}" "${WORK}/libthing.stock.o" "${WORK}/libthing.postpass.o" "${ENCRYPTED_LINUX_SEED}" >/dev/null 2>&1

plugin_sym="$(nm "${WORK}/libthing.plugin.o"   | awk '/compute__abi_/{print $3}')"
postp_sym="$(nm  "${WORK}/libthing.postpass.o" | awk '/compute__abi_/{print $3}')"
if [ -n "${plugin_sym}" ] && [ "${plugin_sym}" = "${postp_sym}" ]; then
    pass "plugin and post-pass agree on tag: ${plugin_sym}"
else
    fail "plugin / post-pass disagree: plugin=${plugin_sym}  postpass=${postp_sym}"
fi

# ---- Three link cases via the plugin -----------------------------------------
gcc -fno-pie -c main.c     -o "${WORK}/main.stock.o"     # for cross-case below

echo "== Test 1: plugin-built main + plugin-built libthing =="
if gcc -fno-pie -no-pie -o "${WORK}/all_plugin" \
       "${WORK}/main.plugin.o" "${WORK}/libthing.plugin.o" 2>"${WORK}/link1.err"; then
    pass "linked"
    "${WORK}/all_plugin"; rc=$?
    [ "${rc}" -eq 42 ] && pass "exits 42" || fail "exited ${rc} (expected 42)"
else
    fail "link failed:"; sed 's/^/    /' "${WORK}/link1.err" >&2
fi

echo "== Test 2: plugin-built main + stock libthing (must fail) =="
if gcc -fno-pie -no-pie -o "${WORK}/cross_broken" \
       "${WORK}/main.plugin.o" "${WORK}/libthing.stock.o" 2>"${WORK}/link2.err"; then
    fail "link unexpectedly succeeded (security regression)"
else
    if grep -q 'compute__abi_' "${WORK}/link2.err"; then
        pass "link failed with undefined reference to compute__abi_<hex>"
        echo "    $(grep compute__abi_ "${WORK}/link2.err" | head -1)"
    else
        fail "link failed but not for the expected reason"
        sed 's/^/    /' "${WORK}/link2.err" >&2
    fi
fi

echo "== Test 3: cross-toolchain compat — plugin main + post-pass libthing =="
if gcc -fno-pie -no-pie -o "${WORK}/mixed" \
       "${WORK}/main.plugin.o" "${WORK}/libthing.postpass.o" 2>"${WORK}/link3.err"; then
    pass "plugin and post-pass paths are interchangeable"
    "${WORK}/mixed"; rc=$?
    [ "${rc}" -eq 42 ] && pass "mixed binary exits 42" || fail "mixed binary exited ${rc}"
else
    fail "mixed link failed (parity bug):"; sed 's/^/    /' "${WORK}/link3.err" >&2
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
