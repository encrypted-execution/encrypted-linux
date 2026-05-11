#!/usr/bin/env python3
"""Internal helper: apply the encrypted-linux modifications to GCC source.

Called from scripts/gen-gcc-patch.sh inside the encrypted-linux-gcc
Docker image, with cwd = /opt/gcc-14.
"""
import os
import sys

assert os.path.isfile("gcc/config/i386/i386.cc"), "must run with cwd=/opt/gcc-14"

# --- Modify i386.cc ---
p = "gcc/config/i386/i386.cc"
with open(p) as f:
    s = f.read()
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
if old not in s:
    print("ERROR: anchor not found in i386.cc", file=sys.stderr)
    sys.exit(1)
with open(p, "w") as f:
    f.write(s.replace(old, new))
print(f"modified {p}")

# --- Create the new header with canonical content ---
hdr = "gcc/config/i386/encrypted-linux-perm.h"
with open(hdr, "w") as f:
    f.write("""\
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
""")
print(f"created {hdr}")
