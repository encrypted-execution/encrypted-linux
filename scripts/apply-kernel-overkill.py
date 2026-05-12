#!/usr/bin/env python3
"""
scripts/apply-kernel-overkill.py — patch the Linux kernel source to
use the 64-bit overkill syscall numbering.

Two changes:
  1. Install build/generated/asm/el_syscall_lookup.h at
     arch/x86/include/generated/asm/el_syscall_lookup.h
  2. Patch arch/x86/entry/common.c so do_syscall_x64 reads the FULL
     64-bit regs->orig_ax, looks it up in el_syscall_table[], and
     dispatches via sys_call_table[<canonical idx>].

This sidesteps the kernel's existing `if (unr < NR_syscalls)` bounds
check (which would reject all our 64-bit values). The canonical
syscall_64.tbl is left untouched — kernel still has sys_call_table[0]
= sys_read, etc.

Runs inside the kernel build container with cwd = /opt/linux.

License: Apache-2.0
"""
from __future__ import annotations
import os
import re
import shutil
import sys
from pathlib import Path

KERNEL_SRC = Path(os.environ.get("KERNEL_SRC", "/opt/linux"))
LOOKUP_HEADER_SRC = Path(os.environ.get(
    "LOOKUP_HEADER_SRC",
    "/work/build/generated/asm/el_syscall_lookup.h"))

# Destination inside the kernel tree. "include/generated/asm/" works
# because the kernel auto-generates many headers there; ours just rides
# along. We use include/ rather than arch-specific path so the patched
# common.c can include it without arch-conditional logic.
LOOKUP_HEADER_DST = KERNEL_SRC / "arch" / "x86" / "include" / "asm" \
                                / "el_syscall_lookup.h"

COMMON_C = KERNEL_SRC / "arch" / "x86" / "entry" / "common.c"


def install_lookup_header():
    LOOKUP_HEADER_DST.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(LOOKUP_HEADER_SRC, LOOKUP_HEADER_DST)
    print(f"  installed {LOOKUP_HEADER_DST}")


def patch_common_c():
    """Replace the body of do_syscall_x64 with the overkill lookup."""
    src = COMMON_C.read_text()

    if "el_syscall_lookup.h" in src:
        print("  common.c already patched")
        return

    # Find the do_syscall_x64 function. The signature varies slightly
    # across kernel versions; anchor on 'do_syscall_x64' + 'pt_regs'.
    # Linux 6.6.30 has:
    #
    # static __always_inline bool do_syscall_x64(struct pt_regs *regs, int nr)
    # {
    # 	/* Returns true to return using SYSRET, or false to use IRET. */
    # 	CT_WARN_ON(...);
    # 	nr = syscall_enter_from_user_mode_work(regs, nr);
    #
    # 	if (likely((unsigned int)nr < NR_syscalls)) {
    # 		nr = array_index_nospec((unsigned int)nr, NR_syscalls);
    # 		regs->ax = x64_sys_call(regs, nr);
    # 		return true;
    # 	}
    # 	return false;
    # }
    #
    # We patch the body to call el_syscall_lookup() instead.
    pattern = re.compile(
        r'(static __always_inline bool do_syscall_x64\([^)]*\)\s*\{)'
        r'(.*?)'
        r'(\n\}\s*\n)',
        re.DOTALL
    )
    m = pattern.search(src)
    if not m:
        sys.exit("FATAL: couldn't locate do_syscall_x64 in common.c")

    new_body = '''
\t/* encrypted-linux overkill: full 64-bit regs->orig_ax, looked up
\t * via binary search against a per-build sorted authorized table. */
\t{
\t\tu64 abi_nr = regs->orig_ax;
\t\tint idx = el_syscall_lookup(abi_nr);
\t\tif (likely(idx >= 0)) {
\t\t\tregs->ax = x64_sys_call(regs, idx);
\t\t\treturn true;
\t\t}
\t\treturn false;
\t}
'''
    new_src = src[:m.start(2)] + new_body + src[m.end(2):]

    # Add include for our lookup header. Insert after the last #include.
    inc_pattern = re.compile(r'(#include\s+<[^>]+>\s*\n)(?!.*#include)', re.DOTALL)
    inc_m = inc_pattern.search(new_src)
    if inc_m:
        insert_at = inc_m.end()
        new_src = (new_src[:insert_at]
                   + '#include <asm/el_syscall_lookup.h>\n'
                   + new_src[insert_at:])
    else:
        sys.exit("FATAL: couldn't find a place to add #include")

    COMMON_C.write_text(new_src)
    print(f"  patched {COMMON_C}: do_syscall_x64 now uses el_syscall_lookup()")


def main() -> int:
    if not LOOKUP_HEADER_SRC.is_file():
        sys.exit(f"missing {LOOKUP_HEADER_SRC} — run gen-overkill-syscalls.py first")
    if not COMMON_C.is_file():
        sys.exit(f"missing {COMMON_C} — kernel source not where expected")
    install_lookup_header()
    patch_common_c()
    return 0


if __name__ == "__main__":
    sys.exit(main())
