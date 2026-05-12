#!/usr/bin/env python3
"""
scripts/gen-elf-osabi.py — pick a per-build ELF OSABI byte (Idea #1
from research/08).

ELF's e_ident[EI_OSABI] is a single byte. Standard values:
    0  = SYSV (the default; what Linux uses)
    3  = LINUX (rarely set)
    64-127 = "Architecture-specific"
    128-255 = "Application-specific"

We pick a per-build byte in 64-255 (unassigned territory) and require
that all loaded ELFs carry it. Stock x86_64 binaries on stock Linux
have EI_OSABI=0; they fail to execve on our kernel.

Outputs:
  build/generated/elf_osabi.h    — C header with ENCRYPTED_LINUX_OSABI
  build/generated/elf_osabi.txt  — raw byte for shell scripts

License: Apache-2.0
"""
from __future__ import annotations
import hashlib
import hmac
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import seed_lib  # noqa: E402

OUT = HERE.parent / "build" / "generated"


def derive_osabi(master: bytes) -> int:
    """HMAC-SHA256(master, "elf.osabi")[0] mapped into 64..255 range
    (avoiding assigned values 0..63)."""
    h = hmac.new(master, b"elf.osabi", hashlib.sha256).digest()
    return 64 + (h[0] % (256 - 64))


def main() -> int:
    seed = seed_lib.read_seed()
    osabi = derive_osabi(seed)
    OUT.mkdir(parents=True, exist_ok=True)

    (OUT / "elf_osabi.h").write_text(
        f"/* GENERATED. Per-build ELF EI_OSABI byte. */\n"
        f"#ifndef _ENCRYPTED_LINUX_ELF_OSABI_H\n"
        f"#define _ENCRYPTED_LINUX_ELF_OSABI_H\n"
        f"#define ENCRYPTED_LINUX_ELF_OSABI 0x{osabi:02x}\n"
        f"#endif\n"
    )
    (OUT / "elf_osabi.txt").write_text(f"{osabi}\n")
    print(f"Per-build EI_OSABI byte: 0x{osabi:02x} ({osabi})")
    print(f"Wrote {OUT}/elf_osabi.{{h,txt}}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
