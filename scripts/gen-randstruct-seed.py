#!/usr/bin/env python3
"""
scripts/gen-randstruct-seed.py — derive the kernel's randstruct seed
from our master seed so struct-layout randomization is deterministic
per encrypted-linux build.

The kernel build looks for the seed at
    scripts/gcc-plugins/randstruct.seed
formatted as 64 hex characters on one line. We derive it via
    HMAC-SHA256(master, "kernel.randstruct")[:32 hex chars]

Reusing our existing seed_lib.derive labels would conflict with the
syscall path, so we use a fresh label.

License: Apache-2.0
"""
from __future__ import annotations
import hashlib
import hmac
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import seed_lib  # noqa: E402

# Allow our specific label without modifying seed_lib's KNOWN_LABELS list.
def derive_randstruct(master: bytes) -> str:
    return hmac.new(master, b"kernel.randstruct", hashlib.sha256).hexdigest()


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        HERE.parent / "build" / "generated" / "randstruct.seed"
    master = seed_lib.read_seed()
    digest = derive_randstruct(master)  # 64 hex chars
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(digest + "\n")
    print(f"wrote {out}: {digest[:16]}...")
    return 0


if __name__ == "__main__":
    sys.exit(main())
