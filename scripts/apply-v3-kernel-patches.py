#!/usr/bin/env python3
"""
scripts/apply-v3-kernel-patches.py — apply the three v3 defenses
to the Linux kernel source tree:
  - Idea #6 errno permutation (replace UAPI errno headers)
  - Idea #1 ELF OSABI verification (patch fs/binfmt_elf.c)
  - Idea #4 /proc field rename (sed fs/proc/task_mmu.c)

Runs inside the kernel build container, cwd = /opt/linux.

License: Apache-2.0
"""
from __future__ import annotations
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

KERNEL_SRC = Path(os.environ.get("KERNEL_SRC", "/opt/linux"))
GENERATED = Path(os.environ.get("GENERATED", "/work/build/generated"))


def apply_errno():
    """Replace kernel UAPI errno headers with our permuted versions."""
    src_base = GENERATED / "asm-generic" / "errno-base.h"
    src_full = GENERATED / "asm-generic" / "errno.h"
    dst_base = KERNEL_SRC / "include" / "uapi" / "asm-generic" / "errno-base.h"
    dst_full = KERNEL_SRC / "include" / "uapi" / "asm-generic" / "errno.h"

    if not src_base.is_file() or not src_full.is_file():
        sys.exit(f"missing generated errno headers in {GENERATED}/asm-generic")

    shutil.copy2(src_base, dst_base)
    shutil.copy2(src_full, dst_full)
    print(f"  errno: installed permuted UAPI headers")
    # Sample evidence.
    sample = (KERNEL_SRC / "include/uapi/asm-generic/errno-base.h").read_text()
    for m in re.findall(r"#define\s+(E\w+)\s+(\d+)", sample)[:3]:
        print(f"    {m[0]:<10} = {m[1]}")


def apply_elf_osabi():
    """Patch fs/binfmt_elf.c: reject ELFs whose EI_OSABI byte doesn't
    match ENCRYPTED_LINUX_ELF_OSABI."""
    osabi_h = GENERATED / "elf_osabi.h"
    if not osabi_h.is_file():
        sys.exit(f"missing {osabi_h}")

    # Install the header where binfmt_elf.c can find it.
    dst = KERNEL_SRC / "include" / "linux" / "encrypted_linux_osabi.h"
    shutil.copy2(osabi_h, dst)
    print(f"  ELF OSABI: header installed at {dst}")

    binfmt = KERNEL_SRC / "fs" / "binfmt_elf.c"
    txt = binfmt.read_text()

    if "encrypted_linux_osabi.h" in txt:
        print(f"  ELF OSABI: binfmt_elf.c already patched")
        return

    # Add the include after the last existing #include in the file's
    # header block. Find the first line that's not #include / blank /
    # comment near the top.
    new_include = '#include <linux/encrypted_linux_osabi.h>\n'
    # Insert after the existing #include block.
    txt = re.sub(
        r'(#include\s+<[^>]+>\n)(?!.*#include\s+<[^>]+>\n)',
        rf'\1{new_include}',
        txt,
        count=1,
        flags=re.DOTALL,
    )

    # Now add the OSABI check in load_elf_binary. The function starts
    # with `static int load_elf_binary(struct linux_binprm *bprm)`. We
    # add an early-return check right after the local declarations,
    # before the `if (elf_ex->e_type != ET_EXEC && elf_ex->e_type != ET_DYN)`
    # block.
    anchor = re.compile(
        r'(static int load_elf_binary\(struct linux_binprm \*bprm\)\s*\{[^\}]*?'
        r'struct elfhdr\s*\*elf_ex\s*=\s*\(struct elfhdr \*\)bprm->buf;\s*\n)',
        re.DOTALL,
    )
    m = anchor.search(txt)
    if not m:
        # Different kernel version layout; try a simpler anchor.
        anchor2 = re.compile(
            r'(elf_ex\s*=\s*\(struct elfhdr \*\)bprm->buf;\s*\n)',
        )
        m = anchor2.search(txt)
    if not m:
        print("  ELF OSABI: WARNING — couldn't find load_elf_binary anchor")
        return

    insertion = (
        "\n"
        "\t/* encrypted-linux: per-build EI_OSABI gate */\n"
        "\tif (elf_ex->e_ident[EI_OSABI] != ENCRYPTED_LINUX_ELF_OSABI)\n"
        "\t\treturn -ENOEXEC;\n"
        "\n"
    )
    txt = txt[:m.end()] + insertion + txt[m.end():]
    binfmt.write_text(txt)
    print(f"  ELF OSABI: load_elf_binary gated on EI_OSABI=={open(osabi_h).read().split('0x')[1][:2]}h")


def apply_proc_rename():
    """sed-rewrite /proc/[pid]/status field names in fs/proc/task_mmu.c.
    The renames live in build/generated/proc_rename.sed."""
    sed_script = GENERATED / "proc_rename.sed"
    if not sed_script.is_file():
        sys.exit(f"missing {sed_script}")

    # Targets: task_mmu.c (where VmRSS etc. are printed for status).
    targets = [
        KERNEL_SRC / "fs" / "proc" / "task_mmu.c",
    ]

    for t in targets:
        if not t.is_file():
            print(f"  proc rename: SKIP {t} (missing)")
            continue
        # Apply sed in place.
        result = subprocess.run(
            ["sed", "-i", "-f", str(sed_script), str(t)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"  proc rename: FAILED on {t}: {result.stderr}")
            continue
        # Verify a sample was changed.
        post = t.read_text()
        if "VmRSS:" in post or "VmSize:" in post:
            print(f"  proc rename: WARNING — some VmXXX:: literals remain in {t}")
        else:
            print(f"  proc rename: {t.name} OK")


def main() -> int:
    if not KERNEL_SRC.is_dir():
        sys.exit(f"kernel source not at {KERNEL_SRC}")
    print("=== Applying v3 kernel patches ===")
    apply_errno()
    apply_elf_osabi()
    apply_proc_rename()
    return 0


if __name__ == "__main__":
    sys.exit(main())
