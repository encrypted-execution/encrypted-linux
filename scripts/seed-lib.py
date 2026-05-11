#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# scripts/seed-lib.py
#
# CLI entry-point for the encrypted-linux seed-derivation library.
# The actual implementation lives in scripts/seed_lib.py (underscore
# spelling -- importable as `from seed_lib import derive`). This
# script is a thin shim that satisfies the documented invocation
# `python3 scripts/seed-lib.py derive <label>` (hyphen spelling, to
# match the repo's other helpers and Engineer A's seed-lib.sh).

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_lib  # noqa: E402

if __name__ == "__main__":
    sys.exit(seed_lib.main(sys.argv))
