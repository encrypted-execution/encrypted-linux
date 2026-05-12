#!/usr/bin/env python3
"""
scripts/gen-overkill-syscalls.py — emit FULL 64-bit syscall numbers
derived directly from HMAC-SHA256(seed, name)[:8] little-endian.

This is the "overkill" path. Instead of mapping syscalls into a 1024-
slot table (10-bit cardinality, brute-forceable in ~1000 tries), each
syscall gets a random-looking 64-bit value. With 365 syscalls in a
2^64 space, an attacker brute-forcing has a probability of 365/2^64
≈ 2×10⁻¹⁷ per attempt — cryptographically infeasible.

The 64-bit value also serves as Knob 3 (authentication): an attacker
cannot forge a new valid syscall number without knowing the seed
(would require finding an HMAC-SHA256 preimage). The kernel's
"validity check" reduces to "is this u64 in our sorted lookup
table?" — sorted, binary-searchable, O(log N) at runtime.

Outputs:
  build/generated/asm/unistd_seeded.h
      Userspace header. Defines __NR_<name> = 0xXXXXXXXXXXXXXXXXULL
      for each canonical syscall.
  build/generated/asm/el_syscall_lookup.h
      Kernel header. Defines a sorted (u64 abi_nr, u16 canonical_idx)
      table for binary-search dispatch.
  build/generated/syscall_map_overkill.json
      Debug / audit artifact.

Kernel side: ship build/generated/asm/el_syscall_lookup.h plus a small
patch to arch/x86/entry/common.c (see scripts/apply-kernel-overkill.sh).
The kernel keeps its CANONICAL syscall_64.tbl unchanged; our patch
just adds a lookup layer that translates the obscure u64 from rax
into the canonical small index before normal dispatch.

License: Apache-2.0
"""
from __future__ import annotations
import hashlib
import hmac
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import seed_lib  # noqa: E402

UPSTREAM_TBL = HERE / "upstream" / "syscall_64.tbl"
OUT_DIR = HERE.parent / "build" / "generated"
OUT_HEADER = OUT_DIR / "asm" / "unistd_seeded.h"
OUT_LOOKUP = OUT_DIR / "asm" / "el_syscall_lookup.h"
OUT_JSON = OUT_DIR / "syscall_map_overkill.json"


def parse_syscall_tbl(path: Path) -> list[dict]:
    entries = []
    for raw in path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        entries.append({
            "number": int(parts[0]),
            "abi": parts[1],
            "name": parts[2],
            "entry": parts[3] if len(parts) > 3 else "",
        })
    return entries


def derive_value(syscall_seed: bytes, name: str, salt: int = 0) -> int:
    """64-bit HMAC-SHA256 output, little-endian. Salt is appended if we
    ever need to break a (vanishingly unlikely) collision."""
    msg = name.encode("ascii")
    if salt:
        msg += f"#{salt}".encode("ascii")
    mac = hmac.new(syscall_seed, msg, hashlib.sha256).digest()
    return int.from_bytes(mac[:8], "little")


def renumber(entries: list[dict], syscall_seed: bytes) -> list[dict]:
    """Return entries augmented with `abi_nr` (u64). Reject collisions
    (probability ~ 365²/2^65 ≈ 1.8×10⁻¹⁴ — won't happen in this
    universe, but we check anyway)."""
    seen: dict[int, str] = {}
    result = []
    for e in sorted(entries, key=lambda x: x["number"]):
        salt = 0
        while True:
            v = derive_value(syscall_seed, e["name"], salt)
            if v not in seen:
                break
            salt += 1
            if salt > 100:
                raise RuntimeError(f"impossible collision storm on {e['name']}")
        seen[v] = e["name"]
        result.append({**e, "abi_nr": v, "salt": salt})
    return result


def emit_userspace_header(entries: list[dict], seed_short: str) -> str:
    lines = [
        "/*",
        " * unistd_seeded.h -- per-build 64-bit overkill syscall numbers.",
        " *",
        " * GENERATED. Regenerate via scripts/gen-overkill-syscalls.py",
        f" * Seed (SHA-256 truncated): {seed_short}",
        " * Cardinality: 2^64. Brute-force probability per attempt: ~2e-17.",
        " */",
        "",
        "#ifndef _ASM_X86_UNISTD_SEEDED_H",
        "#define _ASM_X86_UNISTD_SEEDED_H",
        "",
    ]
    by_name = sorted(entries, key=lambda e: e["name"])
    for e in by_name:
        lines.append(f"#define __NR_{e['name']} 0x{e['abi_nr']:016x}ULL")
    lines.append("")
    lines.append("#endif")
    lines.append("")
    return "\n".join(lines)


def emit_kernel_lookup(entries: list[dict], seed_short: str) -> str:
    """Sorted-by-abi_nr table: (u64, u16) for kernel binary search.

    The u16 idx is the CANONICAL syscall number — same as the
    upstream syscall_64.tbl. The kernel keeps its sys_call_table[]
    indexed by canonical number; our patched dispatch translates
    the obscure 64-bit value from rax into that canonical idx."""
    by_value = sorted(entries, key=lambda e: e["abi_nr"])
    lines = [
        "/*",
        " * el_syscall_lookup.h -- kernel-side overkill syscall lookup.",
        " *",
        " * GENERATED. Regenerate via scripts/gen-overkill-syscalls.py",
        f" * Seed (SHA-256 truncated): {seed_short}",
        " *",
        " * Drop into arch/x86/include/generated/asm/. Consumed by",
        " * arch/x86/entry/common.c (patched)."
        " */",
        "",
        "#ifndef _ASM_X86_EL_SYSCALL_LOOKUP_H",
        "#define _ASM_X86_EL_SYSCALL_LOOKUP_H",
        "",
        "#include <linux/types.h>",
        "",
        "struct el_syscall_entry {",
        "\tu64 abi_nr;",
        "\tu16 canonical_idx;",
        "};",
        "",
        f"#define EL_SYSCALL_COUNT {len(by_value)}",
        "",
        "static const struct el_syscall_entry el_syscall_table[EL_SYSCALL_COUNT] = {",
    ]
    for e in by_value:
        lines.append(
            f"\t{{ 0x{e['abi_nr']:016x}ULL, {e['number']:3d} }}, "
            f"/* {e['name']} */"
        )
    lines.append("};")
    lines.append("")
    lines.append("/* O(log N) binary-search lookup. Returns the canonical")
    lines.append(" * syscall index (suitable for sys_call_table[]), or -1")
    lines.append(" * if the u64 is not in our authorized set. */")
    lines.append("static inline int el_syscall_lookup(u64 nr)")
    lines.append("{")
    lines.append("\tint lo = 0, hi = EL_SYSCALL_COUNT - 1;")
    lines.append("\twhile (lo <= hi) {")
    lines.append("\t\tint mid = (lo + hi) >> 1;")
    lines.append("\t\tu64 v = el_syscall_table[mid].abi_nr;")
    lines.append("\t\tif (v == nr) return el_syscall_table[mid].canonical_idx;")
    lines.append("\t\tif (v < nr) lo = mid + 1; else hi = mid - 1;")
    lines.append("\t}")
    lines.append("\treturn -1;")
    lines.append("}")
    lines.append("")
    lines.append("#endif")
    lines.append("")
    return "\n".join(lines)


def emit_json(entries: list[dict], seed_short: str) -> str:
    by_canonical = sorted(entries, key=lambda e: e["number"])
    return json.dumps({
        "scheme": "64-bit-overkill",
        "cardinality_bits": 64,
        "seed_hash_short": seed_short,
        "count": len(entries),
        "mapping": [
            {
                "canonical_number": e["number"],
                "name": e["name"],
                "abi": e["abi"],
                "abi_nr_hex": f"0x{e['abi_nr']:016x}",
                "salt_used": e["salt"],
            }
            for e in by_canonical
        ],
    }, indent=2, sort_keys=True) + "\n"


def main() -> int:
    if not UPSTREAM_TBL.exists():
        sys.exit(f"missing {UPSTREAM_TBL}")

    seed_bytes = seed_lib.read_seed()
    syscall_seed_hex = seed_lib.derive("syscall.numbers", seed=seed_bytes)
    syscall_seed = syscall_seed_hex.encode("ascii")  # match gen-unistd convention
    seed_short = hashlib.sha256(seed_bytes).hexdigest()[:16]

    all_entries = parse_syscall_tbl(UPSTREAM_TBL)
    native = [e for e in all_entries if e["abi"] in ("common", "64")]
    renumbered = renumber(native, syscall_seed)

    OUT_HEADER.parent.mkdir(parents=True, exist_ok=True)
    OUT_LOOKUP.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)

    OUT_HEADER.write_text(emit_userspace_header(renumbered, seed_short))
    OUT_LOOKUP.write_text(emit_kernel_lookup(renumbered, seed_short))
    OUT_JSON.write_text(emit_json(renumbered, seed_short))

    print(f"gen-overkill-syscalls: {len(renumbered)} syscalls, cardinality 2^64")
    print(f"  wrote {OUT_HEADER}")
    print(f"  wrote {OUT_LOOKUP}")
    print(f"  wrote {OUT_JSON}")

    # Show a few examples to make the change obvious.
    sample = sorted(renumbered, key=lambda e: e["name"])
    for e in sample[:5]:
        print(f"    __NR_{e['name']:<20} = 0x{e['abi_nr']:016x}  "
              f"(canonical {e['number']})")
    print(f"    ... {len(renumbered)} total")
    return 0


if __name__ == "__main__":
    sys.exit(main())
