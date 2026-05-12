#!/usr/bin/env python3
"""
scripts/stamp-elf-osabi.py — rewrite e_ident[EI_OSABI] (byte 7) of an
ELF file in place with the per-build value.

Usage:
    python3 stamp-elf-osabi.py <elf-file> [<elf-file>...]

Reads the per-build byte from build/generated/elf_osabi.txt (generated
by scripts/gen-elf-osabi.py).

License: Apache-2.0
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OSABI_FILE = HERE.parent / "build" / "generated" / "elf_osabi.txt"


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: stamp-elf-osabi.py <elf-file> ...", file=sys.stderr)
        return 2
    if not OSABI_FILE.is_file():
        print(f"error: {OSABI_FILE} missing — run gen-elf-osabi.py first",
              file=sys.stderr)
        return 1

    osabi = int(OSABI_FILE.read_text().strip())

    for path_s in sys.argv[1:]:
        path = Path(path_s)
        if not path.is_file():
            print(f"  skip: {path} (not a file)", file=sys.stderr)
            continue
        data = bytearray(path.read_bytes())
        # ELF magic: \x7fELF (bytes 0-3). Sanity check.
        if data[:4] != b"\x7fELF":
            print(f"  skip: {path} (not ELF)", file=sys.stderr)
            continue
        old = data[7]
        data[7] = osabi
        path.write_bytes(bytes(data))
        print(f"  stamped {path}: EI_OSABI 0x{old:02x} -> 0x{osabi:02x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
