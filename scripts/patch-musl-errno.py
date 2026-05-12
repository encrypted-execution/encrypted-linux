#!/usr/bin/env python3
"""
scripts/patch-musl-errno.py — apply errno permutation to musl source.

musl puts errno values in arch/generic/bits/errno.h. We replace that
file with our generated permuted version.

License: Apache-2.0
"""
import os
import shutil
import sys
from pathlib import Path

MUSL_SRC = Path(os.environ.get("MUSL_SRC", "/opt/musl"))
GENERATED = Path(os.environ.get("GENERATED", "/work/build/generated"))


def main() -> int:
    src = GENERATED / "musl-errno.h"
    if not src.is_file():
        sys.exit(f"missing {src} — run gen-errno-permutation.py first")

    # musl's primary errno header.
    dst = MUSL_SRC / "arch" / "generic" / "bits" / "errno.h"
    if not dst.is_file():
        sys.exit(f"musl errno header missing at {dst}")

    shutil.copy2(src, dst)
    print(f"  musl: replaced {dst.relative_to(MUSL_SRC)}")
    # Sample.
    txt = dst.read_text()
    for line in txt.splitlines()[2:8]:
        print(f"    {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
