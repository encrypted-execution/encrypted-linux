#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# scripts/seed-lib.py
#
# Read the encrypted-linux master seed and derive sub-seeds via
# HMAC-SHA256(seed, label). Pure Python 3 stdlib, no third-party deps.
#
# ============================================================
#   FROZEN SALT STRINGS -- DO NOT CHANGE
# ------------------------------------------------------------
#   "user.abi"
#   "kernel.abi"
#   "syscall.numbers"
#
#   Changing these salts breaks every downstream build forever.
#   They are also referenced verbatim in plan/05-parallel-tracks.md
#   ("Notes on shared seed material"), in SEED.md, and in the bash
#   companion scripts/seed-lib.sh (Engineer A's track).
# ============================================================
#
# Cross-compatibility with scripts/seed-lib.sh:
#   This module treats the contents of the seed file (a 64-char hex
#   string) as the *literal byte string* keying HMAC, identical to
#   `openssl dgst -sha256 -mac HMAC -macopt key:<hex-string>`. The
#   hex is NOT unhexed before use. Engineer A's bash script must
#   agree on this point.
#
# Resolution of the seed file:
#   1. ${ENCRYPTED_LINUX_SEED_FILE} if set.
#   2. ./seed at the repo root (this file's parent directory's parent).

import hmac
import hashlib
import os
import sys
from pathlib import Path

# Known labels. Anything outside this set is rejected to prevent
# typos silently producing a bogus sub-seed in downstream tooling.
KNOWN_LABELS = frozenset({"user.abi", "kernel.abi", "syscall.numbers"})


def _repo_root() -> Path:
    """Return the repo root: parent of the scripts/ directory holding this file."""
    return Path(__file__).resolve().parent.parent


def seed_path() -> Path:
    """
    Resolve the seed file path.

    Precedence:
      1. ${ENCRYPTED_LINUX_SEED_FILE}
      2. <repo>/seed
    """
    env = os.environ.get("ENCRYPTED_LINUX_SEED_FILE")
    if env:
        return Path(env)
    return _repo_root() / "seed"


def read_seed() -> bytes:
    """
    Read the seed file and return its content as bytes (stripped of
    surrounding whitespace including trailing newline). Validates the
    seed is exactly 64 hex characters (256 bits).
    """
    p = seed_path()
    raw = p.read_text(encoding="ascii").strip()
    if len(raw) != 64:
        raise ValueError(
            f"seed file {p}: expected 64 hex chars, got {len(raw)}"
        )
    # Validate hex without consuming the bytes -- we still HMAC against
    # the ASCII representation.
    try:
        int(raw, 16)
    except ValueError as e:
        raise ValueError(f"seed file {p}: not valid hex: {e}") from e
    return raw.encode("ascii")


def derive(label: str, seed: bytes | None = None) -> str:
    """
    Derive the sub-seed for the given label.

    HMAC-SHA256(seed, label) -> 64-char hex string.

    The seed defaults to read_seed(); callers may pass an explicit
    seed (useful for tests).
    """
    if label not in KNOWN_LABELS:
        raise ValueError(
            f"unknown seed label {label!r}; "
            f"expected one of {sorted(KNOWN_LABELS)}"
        )
    if seed is None:
        seed = read_seed()
    return hmac.new(seed, label.encode("ascii"), hashlib.sha256).hexdigest()


def _selftest() -> None:
    """
    Self-test. Asserts a hand-computed vector for the PoC seed
    documented in SEED.md.

    Vector pre-computed via:
        hmac.new(
            b'7f3da98edf5ba694c25fd3405776c0414f3815d448cbca81cae75b9213006392',
            b'user.abi',
            hashlib.sha256,
        ).hexdigest()
    """
    seed = b"7f3da98edf5ba694c25fd3405776c0414f3815d448cbca81cae75b9213006392"
    expected = "8534268856bb281279586737ad7962c45820c9a39893852e925fab85d5d794d9"
    got = derive("user.abi", seed=seed)
    if got != expected:
        raise AssertionError(
            f"seed-lib self-test FAILED\n  expected: {expected}\n  got:      {got}"
        )


def _usage() -> int:
    sys.stderr.write(
        "usage: seed-lib.py derive <label>\n"
        "       seed-lib.py selftest\n"
        f"  labels: {', '.join(sorted(KNOWN_LABELS))}\n"
    )
    return 2


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        return _usage()
    cmd = argv[1]
    if cmd == "derive":
        if len(argv) != 3:
            return _usage()
        try:
            sys.stdout.write(derive(argv[2]) + "\n")
        except ValueError as e:
            sys.stderr.write(f"error: {e}\n")
            return 1
        return 0
    if cmd == "selftest":
        _selftest()
        sys.stdout.write("seed-lib selftest: PASS\n")
        return 0
    return _usage()


# Always run the self-test on import, so any downstream module that
# `from seed_lib import derive` gets a guaranteed-good library or a
# loud failure. Cost: one HMAC. The label check + vector match are
# the only invariants that have to hold.
_selftest()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
