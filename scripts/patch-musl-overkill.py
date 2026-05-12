#!/usr/bin/env python3
"""
scripts/patch-musl-overkill.py — patch musl source to use 64-bit
overkill syscall numbers.

Rewrites:
  arch/x86_64/bits/syscall.h.in       — __NR_* macros use ULL hex
  src/thread/x86_64/__set_thread_area.s — movabsq $..., %rax
  src/thread/x86_64/__unmapself.s
  src/process/x86_64/vfork.s
  src/signal/x86_64/restore.s
  src/thread/x86_64/clone.s

For the 32-bit `mov $N, %eax` instructions, we replace with
`movabsq $0x<64hex>, %rax` to fit our 64-bit values.

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


def parse_overkill_values(unistd_h: Path) -> dict[str, int]:
    """Read unistd_seeded.h (overkill format), return {name: u64}."""
    mapping = {}
    pat = re.compile(r'#define\s+__NR_(\w+)\s+(0x[0-9a-fA-F]+)ULL')
    with open(unistd_h) as f:
        for line in f:
            m = pat.match(line)
            if m:
                mapping[m.group(1)] = int(m.group(2), 16)
    return mapping


def patch_syscall_h_in(path: Path, perm: dict[str, int]) -> int:
    """Rewrite __NR_* defines in bits/syscall.h.in to use ULL hex."""
    src = path.read_text()
    out = []
    n = 0
    for line in src.splitlines():
        m = re.match(r'(#define\s+__NR_)(\w+)(\s+)(\d+)(.*)', line)
        if m and m.group(2) in perm:
            out.append(f"{m.group(1)}{m.group(2)}{m.group(3)}"
                       f"0x{perm[m.group(2)]:016x}ULL{m.group(5)}")
            n += 1
        else:
            out.append(line)
    path.write_text("\n".join(out) + "\n")
    return n


# Asm file hardcodes. Each line: (file, canonical_name, canonical_number).
# We replace `movl? $<canonical>, %eax/al/rax` with `movabsq $<64hex>, %rax`.
HARDCODED = [
    ("src/thread/x86_64/__set_thread_area.s", "arch_prctl", 158),
    ("src/thread/x86_64/__unmapself.s",       "munmap",      11),
    ("src/thread/x86_64/__unmapself.s",       "exit",        60),
    ("src/process/x86_64/vfork.s",            "vfork",       58),
    ("src/signal/x86_64/restore.s",           "rt_sigreturn", 15),
    ("src/thread/x86_64/clone.s",             "clone",       56),
    ("src/thread/x86_64/clone.s",             "exit",        60),
]


def patch_asm(path: Path, canonical_num: int, new_u64: int) -> bool:
    """Replace `mov<sz> $<canonical>, %<rax-family>` with
    `movabsq $0x<64hex>, %rax`. Handles movl/movq/mov + %eax/%al/%rax."""
    src = path.read_text()
    # Match: optional movl/movq/mov, then $N, then %eax / %al / %rax.
    # Anchor on the literal canonical number to scope it.
    pat = re.compile(
        rf'\bmov[lq]?\s+\${canonical_num}\b\s*,\s*%(?:eax|al|rax)\b',
    )
    new_inst = f'movabsq $0x{new_u64:016x}, %rax'
    new_src, count = pat.subn(new_inst, src, count=1)
    if count == 0:
        # Try the .al variant used in clone.s ("xor %eax,%eax; mov $56,%al").
        # In that pattern we have to also clear the high bits properly; rewrite
        # the surrounding two-instruction sequence.
        pat2 = re.compile(
            rf'\bxor\s+%eax\s*,\s*%eax\s*\n\s*mov\s+\${canonical_num}\b\s*,\s*%al',
        )
        new_src, count = pat2.subn(new_inst, src, count=1)
    if count == 0:
        return False
    path.write_text(new_src)
    return True


def main() -> int:
    if not MUSL_SRC.is_dir():
        sys.exit(f"missing {MUSL_SRC}")
    if not UNISTD_SEEDED.is_file():
        sys.exit(f"missing {UNISTD_SEEDED} — run gen-overkill-syscalls.py first")

    perm = parse_overkill_values(UNISTD_SEEDED)
    print(f"Loaded {len(perm)} overkill (64-bit) syscall numbers")

    # Rewrite syscall.h.in.
    sh = MUSL_SRC / "arch/x86_64/bits/syscall.h.in"
    n = patch_syscall_h_in(sh, perm)
    print(f"  {sh}: {n} __NR_* rewritten to ULL hex")

    # Rewrite the 7 hardcoded asm sites.
    for rel, name, canon in HARDCODED:
        if name not in perm:
            print(f"  SKIP {rel}: {name} not in map", file=sys.stderr)
            continue
        path = MUSL_SRC / rel
        if not path.is_file():
            print(f"  SKIP {rel}: missing", file=sys.stderr)
            continue
        ok = patch_asm(path, canon, perm[name])
        status = "OK" if ok else "FAIL"
        print(f"  {rel}: {name} (canonical {canon}) -> 0x{perm[name]:016x}  [{status}]")

    return 0


if __name__ == "__main__":
    sys.exit(main())
