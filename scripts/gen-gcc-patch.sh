#!/usr/bin/env bash
# scripts/gen-gcc-patch.sh
#
# Generate patches/scramble-gcc-v0.patch by running git format-patch
# inside the encrypted-linux-gcc Docker image (which has the GCC 14
# source unpacked at /opt/gcc-14). This guarantees the patch context
# matches upstream exactly — hand-written diffs are too fragile.
#
# Invoked from `make gcc-patch`.
#
# Output: patches/scramble-gcc-v0.patch (committed to repo).
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

docker run --rm --user root -v "$PWD":/work encrypted-linux-gcc bash -s <<'DOCKER_SCRIPT'
set -euo pipefail
cd /opt/gcc-14

# Initialize a git history so format-patch has a baseline.
if [ ! -d .git ]; then
    git init -q .
    git -c user.email=p@p -c user.name=p add -A
    git -c user.email=p@p -c user.name=p commit -q -m "baseline gcc-14.2.0"
fi

# Apply the encrypted-linux modification to i386.cc.
python3 <<'PY'
p = "gcc/config/i386/i386.cc"
with open(p) as f: s = f.read()
old = """/* Define parameter passing and return registers.  */

static int const x86_64_int_parameter_registers[6] =
{
  DI_REG, SI_REG, DX_REG, CX_REG, R8_REG, R9_REG
};"""
new = """/* Define parameter passing and return registers.
   encrypted-linux: x86_64_int_parameter_registers lives in a generated
   header so build-time scrambling can substitute a permutation.  The
   header shipped in-tree contains the canonical (identity) order, so
   stock builds are byte-identical to upstream.  */

#include "config/i386/encrypted-linux-perm.h" """
assert old in s, "anchor not found in i386.cc"
with open(p, "w") as f: f.write(s.replace(old, new))
PY

# Create the new header with canonical (identity) content.
cat > gcc/config/i386/encrypted-linux-perm.h <<'EOF'
/* encrypted-linux-perm.h
 *
 * Canonical (identity) version of the x86_64 SysV integer argument-
 * register table. When ENCRYPTED_LINUX_SEED is set during the GCC build,
 * scripts/gen-gcc-arg-perm.py overwrites this header with a permuted
 * version. Unmodified, this is bit-for-bit equivalent to the inline
 * definition that previously lived in i386.cc.  */

#ifndef GCC_ENCRYPTED_LINUX_PERM_H
#define GCC_ENCRYPTED_LINUX_PERM_H

static int const x86_64_int_parameter_registers[6] =
{
  DI_REG, SI_REG, DX_REG, CX_REG, R8_REG, R9_REG
};

#endif /* GCC_ENCRYPTED_LINUX_PERM_H */
EOF

git add -A
git -c user.email=archis@encrypted-execution.com -c user.name="Archis Gore" \
    commit -q -m "x86_64: external argument-register table for encrypted-linux ABI scrambling

Externalize x86_64_int_parameter_registers[6] to a generated header so
a build-time tool (scripts/gen-gcc-arg-perm.py in the encrypted-linux
repo) can substitute a seed-derived permutation. Default header content
emits the canonical SysV order, leaving stock builds bit-for-bit
identical to upstream.

With ENCRYPTED_LINUX_SEED set, the generator emits a permuted table
derived via:
    USER_ABI_SEED = HMAC-SHA256(master, \"user.abi\")
    ARG_REG_SEED  = HMAC-SHA256(USER_ABI_SEED, \"x86_64.arg_regs\")
    perm          = Fisher-Yates([0..5], ARG_REG_SEED)

Every consumer reads the same table (function_arg_64 caller side,
setup_incoming_varargs_64 callee side, ix86_function_arg_regno_p),
so a single permutation propagates everywhere.

Out of scope for v0: callee-saved permutation, return-register choice,
stack frame layout, MS_ABI table (kept canonical).

References:
 - plan/01-phase1-userland-scrambling.md M1
 - research/04-gcc-calling-convention-internals.md s2"

git format-patch --stdout HEAD~1..HEAD > /work/patches/scramble-gcc-v0.patch
echo "patch lines: $(wc -l < /work/patches/scramble-gcc-v0.patch)"
DOCKER_SCRIPT
