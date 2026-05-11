#!/usr/bin/env python3
"""
scripts/patch-musl-syscalls.py — rewrite musl's hardcoded x86_64 syscall
numbers (in inline asm and in bits/syscall.h.in) to the permuted numbers
from build/generated/asm/unistd_seeded.h.

musl has SEVEN x86_64 asm files that issue `syscall` with a hardcoded
canonical number rather than via the __NR_* macro. We rewrite them in
place. Required for the syscall renumbering (Phase 2) to actually take
effect for static binaries.

Inputs:
  - $MUSL_SRC (e.g. /opt/musl) — musl source tree, mutated in place
  - $UNISTD_SEEDED (default build/generated/asm/unistd_seeded.h) —
    map from canonical name to permuted number

Outputs:
  - in-place edits to:
      arch/x86_64/bits/syscall.h.in
      src/thread/x86_64/__set_thread_area.s
      src/thread/x86_64/__unmapself.s
      src/process/x86_64/vfork.s
      src/signal/x86_64/restore.s
      src/thread/x86_64/clone.s

Run inside the build container (where /opt/musl exists).

License: Apache-2.0
"""
import os
import re
import sys
from pathlib import Path

MUSL_SRC = Path(os.environ.get("MUSL_SRC", "/opt/musl"))
UNISTD_SEEDED = Path(os.environ.get(
    "UNISTD_SEEDED",
    "/work/build/generated/asm/unistd_seeded.h"))

# Hard-coded canonical syscall numbers found in musl x86_64 asm files
# (verified for musl 1.2.5). Each entry: (file, canonical_name).
# We replace the literal numeric immediate at the matching line.
HARDCODED = [
    # (relative path, canonical syscall name, regex to anchor on)
    ("src/thread/x86_64/__set_thread_area.s", "arch_prctl",
     re.compile(r'(\bmovl?\s*\$)158\b')),
    ("src/thread/x86_64/__unmapself.s", "munmap",
     re.compile(r'(\bmovl?\s*\$)11\b')),
    ("src/thread/x86_64/__unmapself.s", "exit",
     re.compile(r'(\bmovl?\s*\$)60\b')),
    ("src/process/x86_64/vfork.s", "vfork",
     re.compile(r'(\bmovl?\s*\$)58\b')),
    ("src/signal/x86_64/restore.s", "rt_sigreturn",
     re.compile(r'(\bmovl?\s*\$)15\b')),
    ("src/thread/x86_64/clone.s", "clone",
     re.compile(r'(\bmovl?\s+\$)56\b')),
    # clone.s also has `mov $60, %al` for exit (after clone).
    ("src/thread/x86_64/clone.s", "exit",
     re.compile(r'(\bmovl?\s+\$)60\b')),
]


def parse_permuted_numbers(unistd_h: Path) -> dict[str, int]:
    """Read unistd_seeded.h, return {syscall_name: number}."""
    mapping: dict[str, int] = {}
    with open(unistd_h) as f:
        for line in f:
            m = re.match(r'#define\s+__NR_(\w+)\s+(\d+)', line)
            if m:
                mapping[m.group(1)] = int(m.group(2))
    return mapping


def patch_file_anchor(path: Path, anchor: re.Pattern, new_number: int) -> bool:
    """Replace the first occurrence of the canonical number (matched by
    `anchor`) with `new_number`. Returns True if an edit was made."""
    txt = path.read_text()
    new_txt, n = anchor.subn(rf'\g<1>{new_number}', txt, count=1)
    if n == 0:
        return False
    path.write_text(new_txt)
    return True


def patch_syscall_h_in(syscall_h: Path, perm: dict[str, int]) -> int:
    """Rewrite every `#define __NR_<name> <num>` line in syscall.h.in to
    use the permuted number from `perm`."""
    out_lines: list[str] = []
    count = 0
    src = syscall_h.read_text()
    for line in src.splitlines():
        m = re.match(r'(#define\s+__NR_)(\w+)(\s+)(\d+)(.*)', line)
        if m and m.group(2) in perm:
            new_num = perm[m.group(2)]
            out_lines.append(f"{m.group(1)}{m.group(2)}{m.group(3)}{new_num}{m.group(5)}")
            count += 1
        else:
            out_lines.append(line)
    syscall_h.write_text("\n".join(out_lines) + "\n")
    return count


def main() -> int:
    if not MUSL_SRC.is_dir():
        sys.exit(f"musl source not found at {MUSL_SRC}")
    if not UNISTD_SEEDED.is_file():
        sys.exit(f"permuted header not found at {UNISTD_SEEDED}")

    perm = parse_permuted_numbers(UNISTD_SEEDED)
    print(f"Loaded {len(perm)} permuted syscall numbers from {UNISTD_SEEDED}")

    # 1. bits/syscall.h.in — rewrite all __NR_*.
    syscall_h = MUSL_SRC / "arch/x86_64/bits/syscall.h.in"
    n = patch_syscall_h_in(syscall_h, perm)
    print(f"  {syscall_h}: {n} __NR_* rewritten")

    # 2. The 7 hardcoded inline asm sites.
    for rel, name, anchor in HARDCODED:
        if name not in perm:
            print(f"  SKIP {rel}: {name} not in permuted map", file=sys.stderr)
            continue
        path = MUSL_SRC / rel
        if not path.is_file():
            print(f"  SKIP {rel}: file missing", file=sys.stderr)
            continue
        ok = patch_file_anchor(path, anchor, perm[name])
        status = "OK" if ok else "NOT FOUND"
        print(f"  {rel}: {name} -> {perm[name]} [{status}]")

    return 0


if __name__ == "__main__":
    sys.exit(main())
