#!/usr/bin/env bash
#
# scripts/scramble-gcc-test/test.sh
#
# Demonstrates that the patched GCC produces assembly with permuted
# argument-register usage, matching the permutation derived from
# $ENCRYPTED_LINUX_SEED.
#
# Prerequisites:
#   build/scramble-gcc/install/bin/x86_64-linux-gnu-gcc
# Built via: bash scripts/build-scramble-gcc.sh
#
# Method:
#   1. Compile a tiny test.c with one 1-arg function via the patched GCC.
#   2. Disassemble with objdump -d.
#   3. Verify the function reads its argument from the EXPECTED PERMUTED
#      register (per scripts/gen-gcc-arg-perm.py output for the same seed).
#
# Exit 0 on PASS, non-zero on FAIL.
#
# License: Apache-2.0

set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd ../.. && pwd)"
GCC="${REPO_ROOT}/build/scramble-gcc/install/bin/x86_64-linux-gnu-gcc"
SEED="$(cat "${REPO_ROOT}/seed")"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
RESET=$'\033[0m'
pass=0; fail=0
pass()  { printf '  %s[PASS]%s %s\n' "${GREEN}" "${RESET}" "$1"; pass=$((pass+1)); }
fail()  { printf '  %s[FAIL]%s %s\n' "${RED}"   "${RESET}" "$1"; fail=$((fail+1)); }

# --- Prerequisite ------------------------------------------------------------
echo "== Prerequisite =="
if [ ! -x "${GCC}" ]; then
    fail "patched GCC not built: ${GCC}"
    echo "    Run: bash scripts/build-scramble-gcc.sh"
    exit 1
fi
pass "patched GCC binary present: $(${GCC} -dumpversion 2>/dev/null)"

# --- Derive expected permutation via the Python helper ----------------------
echo "== Expected permutation (from gen-gcc-arg-perm.py) =="
python3 "${REPO_ROOT}/scripts/gen-gcc-arg-perm.py" --seed "${SEED}" \
    -o "${WORK}/expected-perm.h" --verbose 2>&1 | sed 's/^/    /'

# Extract the 6 GCC register macro names from the generated header,
# in order, by joining all lines between the brace pair and tokenizing.
perm_tokens="$(awk '
    /^static int const x86_64_int_parameter_registers/,/};/ {
        gsub(/[{};,]/, " "); print
    }
' "${WORK}/expected-perm.h" \
    | tr -s '[:space:]' ' ' \
    | grep -oE '[A-Z][A-Z]?[0-9]?_REG' \
    | head -6)"

# Map GCC's internal REG_NAME to the x86-64 ABI assembly mnemonic for 32-bit args.
declare -A REG_TO_ASM=(
    [DI_REG]=edi
    [SI_REG]=esi
    [DX_REG]=edx
    [CX_REG]=ecx
    [R8_REG]=r8d
    [R9_REG]=r9d
)

expected_regs=()
while read -r r; do
    [ -z "${r}" ] && continue
    expected_regs+=("${REG_TO_ASM[$r]:-${r}}")
done <<< "${perm_tokens}"

if [ "${#expected_regs[@]}" -ne 6 ]; then
    fail "could not parse 6 register tokens (got ${#expected_regs[@]}): ${perm_tokens}"
    exit 1
fi
pass "parsed permuted register list: ${expected_regs[*]}"

# --- Compile the test ------------------------------------------------------
cat > "${WORK}/test.c" <<'TC'
/* identity functions for each of the 6 arg slots. They should compile
 * to a single `mov %<perm-reg>, %eax; ret` (or near-equivalent). */
int id0(int a) { return a; }
int id1(int a, int b) { (void)a; return b; }
int id2(int a, int b, int c) { (void)a; (void)b; return c; }
int id3(int a, int b, int c, int d) { (void)a; (void)b; (void)c; return d; }
int id4(int a, int b, int c, int d, int e) {
    (void)a; (void)b; (void)c; (void)d; return e;
}
int id5(int a, int b, int c, int d, int e, int f) {
    (void)a; (void)b; (void)c; (void)d; (void)e; return f;
}
TC

echo "== Compiling test.c with patched GCC (assembly only) =="
# Use -S to stop after asm generation; the cross-compiler ships without a
# cross-targeting `as`, but -S doesn't need one. We're inspecting the asm
# anyway, so -S is exactly what we want.
if "${GCC}" -O2 -S "${WORK}/test.c" -o "${WORK}/test.s" 2>"${WORK}/cc.err"; then
    pass "compilation succeeded"
else
    fail "compilation failed:"; sed 's/^/    /' "${WORK}/cc.err"; exit 1
fi

# --- Assembly-level inspection ---------------------------------------------
echo "== Assembly of each identity function =="

for i in 0 1 2 3 4 5; do
    expected="${expected_regs[$i]}"
    # Grab body of idN: stop at next non-debug label or ret.
    body="$(awk -v fn="^id${i}:$" '
        $0 ~ fn {found=1; next}
        found && /^[ \t]*ret/ {print; found=0; next}
        found {print}
    ' "${WORK}/test.s")"

    # Look for a mov of the expected register into eax/rax. Use a simple
    # substring search to avoid ERE/anchor pitfalls.
    if echo "${body}" | grep -qF "%${expected}," ; then
        asm_line=$(echo "${body}" | grep -F "%${expected}," | head -1)
        pass "id${i}: arg ${i} read from %${expected}"
        echo "    $(echo "${asm_line}" | sed 's/^[[:space:]]*//')"
    else
        fail "id${i}: did NOT read arg ${i} from %${expected}"
        echo "    function body was:"; echo "${body}" | sed 's/^/      /'
    fi
done

# --- Negative control: stock GCC reads from canonical registers ------------
# Skip on arm64 hosts where the system gcc is arm-targeting; we only
# verify the canonical reference on x86_64 systems where it's meaningful.
echo "== Negative control: stock gcc reads from canonical registers =="
if gcc -dumpmachine 2>/dev/null | grep -q x86_64; then
    canonical=(edi esi edx ecx r8d r9d)
    if gcc -O2 -S "${WORK}/test.c" -o "${WORK}/test.stock.s" 2>/dev/null; then
        for i in 0 1 2 3 4 5; do
            c="${canonical[$i]}"
            body="$(awk -v fn="^id${i}:$" '
                $0 ~ fn {found=1; next}
                found && /^[ \t]*ret/ {print; found=0; next}
                found {print}
            ' "${WORK}/test.stock.s")"
            if echo "${body}" | grep -qF "%${c}," ; then
                pass "stock id${i}: canonical register %${c} confirmed"
            else
                fail "stock id${i}: did NOT read from canonical %${c}"
            fi
        done
    fi
else
    echo "  (skipping — host gcc is $(gcc -dumpmachine 2>/dev/null || echo unknown), not x86_64)"
fi

echo
echo "================================================="
if [ "${fail}" -eq 0 ]; then
    printf '  %sPASS%s  (%d checks, 0 failures)\n' "${GREEN}" "${RESET}" "${pass}"
    echo "================================================="
    exit 0
else
    printf '  %sFAIL%s  (%d pass, %d fail)\n' "${RED}" "${RESET}" "${pass}" "${fail}"
    echo "================================================="
    exit 1
fi
