#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# scripts/gen-unistd-seeded.py
#
# Read the canonical Linux x86_64 syscall table plus the seeded
# SYSCALL_SEED (HMAC-SHA256(seed, "syscall.numbers")), and emit:
#
#   build/generated/asm/unistd_seeded.h
#     #define __NR_<name> <new-number>
#
#   build/generated/asm/syscall_seeded_table.S
#     a sequence of __SYSCALL(<new-number>, __x64_sys_<name>) entries
#     in NEW-number order, with explicit gaps for unmapped slots.
#
#   build/generated/syscall_map.json
#     debug/audit artifact: canonical -> new-number mapping plus
#     collision-probe statistics.
#
# Algorithm:
#
#   For each canonical native syscall (abi in {"common", "64"}):
#     slot = HMAC-SHA256(SYSCALL_SEED, name)[:2 bytes] (big-endian uint16) & 0x3FF
#     If slot is occupied, linear-probe forward (slot+1, slot+2, ... mod 1024)
#     until an empty slot is found.
#
#   Iteration order: canonical syscall number ascending. Deterministic.
#
# Scope: native (common + 64) only. x32 entries (canonical numbers
# 512-547) are out of scope for the PoC, matching plan/02 M1
# ("32-bit and 64-bit numbers permuted independently") and plan/04
# (no x32 binary in the demo). They are recorded as "skipped" in the
# JSON audit artifact for completeness.
#
# Pure Python 3 stdlib. No third-party deps.

import hashlib
import hmac
import json
import sys
from pathlib import Path

# Make seed_lib (sibling) importable.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import seed_lib  # noqa: E402


# ----------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------

# 1024-slot syscall table. 10-bit slot index.
SLOT_COUNT = 1024
SLOT_MASK = SLOT_COUNT - 1  # 0x3FF

UPSTREAM_TBL = (
    Path(__file__).resolve().parent / "upstream" / "syscall_64.tbl"
)
OUT_DIR = (
    Path(__file__).resolve().parent.parent / "build" / "generated"
)
OUT_HEADER = OUT_DIR / "asm" / "unistd_seeded.h"
OUT_TABLE = OUT_DIR / "asm" / "syscall_seeded_table.S"
OUT_JSON = OUT_DIR / "syscall_map.json"


# ----------------------------------------------------------------------
# Table parsing
# ----------------------------------------------------------------------


def parse_syscall_tbl(path: Path) -> list[dict]:
    """
    Parse arch/x86/entry/syscalls/syscall_64.tbl.

    Format:  <number> <abi> <name> <entry-point>?
    Comments (`# ...`) and blank lines ignored. Entry-point may be
    absent for placeholder rows (none in v6.6 native rows, but be
    defensive).

    Returns a list of dicts with keys: number, abi, name, entry.
    """
    entries = []
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 3:
            raise ValueError(
                f"{path}:{lineno}: malformed row {raw!r}"
            )
        number = int(parts[0])
        abi = parts[1]
        name = parts[2]
        entry = parts[3] if len(parts) >= 4 else ""
        entries.append(
            dict(number=number, abi=abi, name=name, entry=entry)
        )
    return entries


# ----------------------------------------------------------------------
# Renumbering
# ----------------------------------------------------------------------


def desired_slot(syscall_seed: bytes, name: str) -> int:
    """HMAC-SHA256(seed, name)[:2 bytes] interpreted big-endian, masked to 10 bits."""
    mac = hmac.new(syscall_seed, name.encode("ascii"), hashlib.sha256).digest()
    top16 = (mac[0] << 8) | mac[1]
    return top16 & SLOT_MASK


def renumber(
    entries: list[dict], syscall_seed: bytes
) -> tuple[dict[int, dict], dict]:
    """
    Produce the bijective canonical-number -> new-number mapping.

    Returns:
        slot_map:   dict[new_number -> entry-with-extra-keys]
                    Entry dicts include their original fields plus
                    'new_number', 'desired_slot', 'probe_steps'.
        stats:      collision/probe statistics.

    Inputs (entries) must include only canonical syscalls to be
    placed; iterate in canonical-number ascending order for
    deterministic collision resolution.
    """
    # Sort defensively: same input order across runs.
    sorted_entries = sorted(entries, key=lambda e: e["number"])

    if len(sorted_entries) > SLOT_COUNT:
        raise ValueError(
            f"cannot fit {len(sorted_entries)} syscalls into "
            f"{SLOT_COUNT}-slot table"
        )

    slot_map: dict[int, dict] = {}
    total_probes = 0
    max_probes = 0
    collisions = 0  # number of entries that needed any probing at all

    for e in sorted_entries:
        d = desired_slot(syscall_seed, e["name"])
        probes = 0
        slot = d
        while slot in slot_map:
            probes += 1
            slot = (d + probes) & SLOT_MASK
            if probes >= SLOT_COUNT:
                # Defensive; can't happen given the size check above.
                raise RuntimeError(
                    "linear probing failed to find a free slot for "
                    f"{e['name']!r} (desired={d}); table is full"
                )
        slot_map[slot] = {
            **e,
            "new_number": slot,
            "desired_slot": d,
            "probe_steps": probes,
        }
        total_probes += probes
        max_probes = max(max_probes, probes)
        if probes > 0:
            collisions += 1

    stats = {
        "total_entries": len(sorted_entries),
        "slot_count": SLOT_COUNT,
        "load_factor": round(len(sorted_entries) / SLOT_COUNT, 4),
        "collisions": collisions,
        "max_probes": max_probes,
        "total_probes": total_probes,
        "mean_probes": (
            round(total_probes / len(sorted_entries), 4)
            if sorted_entries else 0.0
        ),
    }
    return slot_map, stats


# ----------------------------------------------------------------------
# Emission
# ----------------------------------------------------------------------


def _seed_hash_short(seed: bytes) -> str:
    """First 8 bytes (16 hex) of SHA-256(seed). For header banner only."""
    return hashlib.sha256(seed).hexdigest()[:16]


def emit_header(
    slot_map: dict[int, dict],
    seed_hash_short: str,
    syscall_seed: bytes,
) -> str:
    """Render build/generated/asm/unistd_seeded.h."""
    lines: list[str] = []
    lines.append("/*")
    lines.append(" * unistd_seeded.h -- per-build renumbered x86_64 syscall numbers.")
    lines.append(" *")
    lines.append(" * GENERATED FILE. Do not edit. Regenerate via")
    lines.append(" *   python3 scripts/gen-unistd-seeded.py")
    lines.append(" *")
    lines.append(f" * Seed-file SHA-256 (truncated): {seed_hash_short}")
    lines.append(
        f" * SYSCALL_SEED SHA-256 (truncated): "
        f"{hashlib.sha256(syscall_seed).hexdigest()[:16]}"
    )
    lines.append(f" * Upstream table: {UPSTREAM_TBL.name} (Linux v6.6)")
    lines.append(" *")
    lines.append(" * See plan/02-phase2-kernel-scrambling.md (M1).")
    lines.append(" */")
    lines.append("")
    lines.append("#ifndef _ASM_X86_UNISTD_SEEDED_H")
    lines.append("#define _ASM_X86_UNISTD_SEEDED_H")
    lines.append("")
    # Emit in canonical-name ascending order for stable diffs.
    by_name = sorted(slot_map.values(), key=lambda v: v["name"])
    for v in by_name:
        lines.append(f"#define __NR_{v['name']} {v['new_number']}")
    lines.append("")
    lines.append(f"#define ENCRYPTED_LINUX_SYSCALL_SLOT_COUNT {SLOT_COUNT}")
    lines.append("")
    lines.append("#endif /* _ASM_X86_UNISTD_SEEDED_H */")
    lines.append("")
    return "\n".join(lines)


def emit_table(
    slot_map: dict[int, dict],
    seed_hash_short: str,
) -> str:
    """Render build/generated/asm/syscall_seeded_table.S."""
    lines: list[str] = []
    lines.append("/*")
    lines.append(" * syscall_seeded_table.S -- kernel-side seeded dispatch table.")
    lines.append(" *")
    lines.append(" * GENERATED FILE. Do not edit. Regenerate via")
    lines.append(" *   python3 scripts/gen-unistd-seeded.py")
    lines.append(" *")
    lines.append(f" * Seed-file SHA-256 (truncated): {seed_hash_short}")
    lines.append(" *")
    lines.append(
        " * Slots not present in this build map to "
        "__x64_sys_ni_syscall, returning -ENOSYS."
    )
    lines.append(
        " * Consumers: the kernel-side regen of arch/x86/entry/syscalls/"
        "syscall_64.tbl"
    )
    lines.append(" * substitutes these entries into the existing __SYSCALL() dispatch.")
    lines.append(" */")
    lines.append("")
    for slot in range(SLOT_COUNT):
        if slot in slot_map:
            v = slot_map[slot]
            lines.append(
                f"__SYSCALL({slot}, __x64_sys_{v['name']}) "
                f"/* canonical {v['number']}, desired {v['desired_slot']}, "
                f"probes {v['probe_steps']} */"
            )
        else:
            lines.append(f"__SYSCALL({slot}, __x64_sys_ni_syscall)")
    lines.append("")
    return "\n".join(lines)


def emit_json(
    slot_map: dict[int, dict],
    stats: dict,
    skipped: list[dict],
    seed_hash_short: str,
) -> str:
    """Render build/generated/syscall_map.json."""
    by_canonical = sorted(slot_map.values(), key=lambda v: v["number"])
    out = {
        "upstream_table": str(UPSTREAM_TBL.name),
        "upstream_version": "linux-v6.6",
        "seed_hash_short": seed_hash_short,
        "stats": stats,
        "mapping": [
            {
                "canonical_number": v["number"],
                "abi": v["abi"],
                "name": v["name"],
                "entry": v["entry"],
                "new_number": v["new_number"],
                "desired_slot": v["desired_slot"],
                "probe_steps": v["probe_steps"],
            }
            for v in by_canonical
        ],
        "skipped": skipped,
    }
    # sort_keys=True for stable byte-output across Python runs.
    return json.dumps(out, indent=2, sort_keys=True) + "\n"


# ----------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------


def main() -> int:
    if not UPSTREAM_TBL.exists():
        sys.stderr.write(
            f"error: upstream syscall table not found at {UPSTREAM_TBL}\n"
            "       (re-vendor it from "
            "https://raw.githubusercontent.com/torvalds/linux/v6.6/"
            "arch/x86/entry/syscalls/syscall_64.tbl)\n"
        )
        return 1

    all_entries = parse_syscall_tbl(UPSTREAM_TBL)
    native = [e for e in all_entries if e["abi"] in ("common", "64")]
    skipped = [
        {
            "canonical_number": e["number"],
            "abi": e["abi"],
            "name": e["name"],
            "entry": e["entry"],
            "reason": "x32 ABI out of scope for PoC",
        }
        for e in all_entries
        if e["abi"] == "x32"
    ]

    # Derive seed and SYSCALL_SEED.
    seed_bytes = seed_lib.read_seed()
    syscall_seed_hex = seed_lib.derive("syscall.numbers", seed=seed_bytes)
    syscall_seed = syscall_seed_hex.encode("ascii")
    seed_hash_short = _seed_hash_short(seed_bytes)

    slot_map, stats = renumber(native, syscall_seed)

    # Sanity: bijection invariants.
    assert len(slot_map) == len(native), (
        "slot_map size mismatch -- not a bijection"
    )
    assert len(set(slot_map.keys())) == len(slot_map), (
        "duplicate new-numbers -- not a bijection"
    )
    names_in = {e["name"] for e in native}
    names_out = {v["name"] for v in slot_map.values()}
    assert names_in == names_out, (
        "name set mismatch -- a syscall was dropped or duplicated"
    )

    OUT_HEADER.parent.mkdir(parents=True, exist_ok=True)
    OUT_TABLE.parent.mkdir(parents=True, exist_ok=True)
    OUT_JSON.parent.mkdir(parents=True, exist_ok=True)

    OUT_HEADER.write_text(emit_header(slot_map, seed_hash_short, syscall_seed))
    OUT_TABLE.write_text(emit_table(slot_map, seed_hash_short))
    OUT_JSON.write_text(emit_json(slot_map, stats, skipped, seed_hash_short))

    sys.stdout.write(
        f"gen-unistd-seeded: wrote {OUT_HEADER}\n"
        f"gen-unistd-seeded: wrote {OUT_TABLE}\n"
        f"gen-unistd-seeded: wrote {OUT_JSON}\n"
        f"gen-unistd-seeded: {stats['total_entries']} native syscalls, "
        f"{stats['collisions']} probed, max_probes={stats['max_probes']}, "
        f"mean_probes={stats['mean_probes']}\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
