#!/usr/bin/env python3
"""
scripts/gen-proc-rename.py — pick per-build names for /proc/[pid]/status
fields (Idea #4 from research/08).

POSIX says nothing about /proc's schema (it's Linux-specific). We
rename the most fingerprinted fields. Attacker tooling that
scrapes /proc/[pid]/status or /proc/[pid]/maps breaks.

For v1 we rename only VmSize/VmRSS/VmData/VmStk/VmExe/VmLib/VmPeak/VmHWM
in /proc/[pid]/status. Full /proc/[pid]/stat reordering (Idea #4's
real bulk) and /proc/[pid]/maps reformatting are deferred to v2 of
this defense.

Outputs:
  build/generated/proc_rename.json — { canonical_name: new_name }
  build/generated/proc_rename.sed  — sed script to apply to kernel src

License: Apache-2.0
"""
from __future__ import annotations
import hashlib
import hmac
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import seed_lib  # noqa: E402

OUT = HERE.parent / "build" / "generated"

# Fields in /proc/[pid]/status worth renaming. These are the ones that
# every fingerprinting / privesc-prep tool scrapes.
CANONICAL_FIELDS = [
    "VmPeak",   # peak virtual memory size
    "VmSize",   # current virtual memory size — fingerprinted constantly
    "VmHWM",    # peak resident set size
    "VmRSS",    # current resident set size — fingerprinted constantly
    "VmData",   # data segment size
    "VmStk",    # stack size
    "VmExe",    # text segment size
    "VmLib",    # shared lib size
]

# A small word list — readable but seed-derived. Replacement names
# pulled deterministically from this pool via HMAC.
WORD_POOL = [
    "Goobledygook", "Splanck", "Vorpal", "Frabjous", "Brillig", "Slithy",
    "Mimsy", "Borogoves", "Mome", "Raths", "Outgrabe", "Galumph",
    "Chortled", "Tulgey", "Beamish", "Manxome", "Snickersnack",
    "Frumious", "Bandersnatch", "Jubjub", "Tumtum", "Whiffling",
    "Burbled", "Mwop", "Splork", "Zibble", "Quazzle", "Fnord",
    "Quux", "Plugh", "Xyzzy", "Frob", "Grok", "Twonk", "Wibble",
    "Wobble", "Bibble", "Spliff", "Splat", "Glark",
]


def derive_proc_seed(master: bytes) -> bytes:
    return hmac.new(master, b"kernel.proc_schema", hashlib.sha256).digest()


def pick_unique_names(canonical: list[str], seed: bytes) -> dict[str, str]:
    """For each canonical field, pick a unique replacement word. The
    replacement is `<pool-word><N>` where N is a small differentiator
    so the same word can be reused once-modified."""
    used: set[str] = set()
    result: dict[str, str] = {}
    for i, name in enumerate(canonical):
        # Per-field HMAC for stability across canonical-list changes.
        h = hmac.new(seed, name.encode("ascii"), hashlib.sha256).digest()
        for offset in range(256):
            word_idx = (h[0] + offset) % len(WORD_POOL)
            suffix = h[1] + offset
            candidate = f"{WORD_POOL[word_idx]}{suffix:03d}"
            if candidate not in used:
                used.add(candidate)
                result[name] = candidate
                break
    return result


def emit_sed(rename: dict[str, str]) -> str:
    """Emit a sed program that rewrites canonical field names to the
    new ones in C string literals. The kernel's fs/proc/task_mmu.c
    contains lines like `seq_put_decimal_ull_width(m, "VmPeak:\t", ...)`.
    """
    lines = []
    for old, new in rename.items():
        # Match the C string-literal form `"VmPeak:"` keeping the colon
        # so we don't accidentally hit a variable named `VmPeak`.
        lines.append(f's|"{old}:|"{new}:|g')
    return "\n".join(lines) + "\n"


def main() -> int:
    seed = seed_lib.read_seed()
    proc_seed = derive_proc_seed(seed)
    rename = pick_unique_names(CANONICAL_FIELDS, proc_seed)

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "proc_rename.json").write_text(
        json.dumps(rename, indent=2, sort_keys=True) + "\n")
    (OUT / "proc_rename.sed").write_text(emit_sed(rename))

    print(f"proc_schema seed: {proc_seed.hex()[:16]}...")
    print("Renames:")
    for old, new in rename.items():
        print(f"  {old:<8} -> {new}")
    print(f"Wrote {OUT}/proc_rename.{{json,sed}}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
