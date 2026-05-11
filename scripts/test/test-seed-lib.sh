#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# scripts/test/test-seed-lib.sh
#
# End-to-end smoke test for Track B's seed-lib + gen-unistd-seeded.
#
# Asserts:
#   * seed-lib produces the known PoC vector for user.abi
#   * seed-lib derives kernel.abi and syscall.numbers (printed)
#   * gen-unistd-seeded produces all three outputs
#   * the renumbered header contains __NR_read/write/openat/exit_group/execve
#     and each is renumbered (not at its canonical position)
#   * all __NR_* numbers are unique (bijection check)
#   * the generator is deterministic (two runs byte-identical)
#
# Usage: scripts/test/test-seed-lib.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

SCRIPTS="$REPO_ROOT/scripts"
BUILD="$REPO_ROOT/build/generated"
HEADER="$BUILD/asm/unistd_seeded.h"
TABLE="$BUILD/asm/syscall_seeded_table.S"
JSON="$BUILD/syscall_map.json"

FAIL=0
PASS=0

note()  { printf '  %s\n' "$*"; }
ok()    { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }

# Known PoC vector: HMAC-SHA256("7f3da...92" ASCII string, "user.abi")
EXPECTED_USER_ABI="8534268856bb281279586737ad7962c45820c9a39893852e925fab85d5d794d9"

# ---------------------------------------------------------------------
echo "== Test 1: seed-lib.py derive user.abi vs known vector =="
GOT="$(python3 "$SCRIPTS/seed-lib.py" derive user.abi)"
if [ "$GOT" = "$EXPECTED_USER_ABI" ]; then
  ok "user.abi sub-seed matches known vector"
else
  bad "user.abi mismatch: got $GOT expected $EXPECTED_USER_ABI"
fi

# ---------------------------------------------------------------------
echo "== Test 2: seed-lib.py derive kernel.abi (printed) =="
KERNEL_ABI="$(python3 "$SCRIPTS/seed-lib.py" derive kernel.abi)"
note "kernel.abi   = $KERNEL_ABI"
if [ ${#KERNEL_ABI} -eq 64 ]; then
  ok "kernel.abi is 64 hex chars"
else
  bad "kernel.abi wrong length: ${#KERNEL_ABI}"
fi

# ---------------------------------------------------------------------
echo "== Test 3: seed-lib.py derive syscall.numbers (printed) =="
SYSCALL_NUMBERS="$(python3 "$SCRIPTS/seed-lib.py" derive syscall.numbers)"
note "syscall.numbers = $SYSCALL_NUMBERS"
if [ ${#SYSCALL_NUMBERS} -eq 64 ]; then
  ok "syscall.numbers is 64 hex chars"
else
  bad "syscall.numbers wrong length: ${#SYSCALL_NUMBERS}"
fi

# ---------------------------------------------------------------------
echo "== Test 4: gen-unistd-seeded.py produces 3 outputs =="
rm -rf "$BUILD"
if python3 "$SCRIPTS/gen-unistd-seeded.py" >/dev/null; then
  ok "generator exited 0"
else
  bad "generator exited non-zero"
fi
[ -f "$HEADER" ] && ok "header exists: $HEADER" || bad "missing $HEADER"
[ -f "$TABLE"  ] && ok "table exists:  $TABLE"  || bad "missing $TABLE"
[ -f "$JSON"   ] && ok "json exists:   $JSON"   || bad "missing $JSON"

# ---------------------------------------------------------------------
echo "== Test 5: header contains key syscalls, renumbered =="
# Canonical x86_64 numbers (Linux v6.6):
#   read=0  write=1  openat=257  exit_group=231  execve=59
declare -a NAMES=(read write openat exit_group execve)
declare -a CANON=(0    1     257    231        59)
i=0
while [ $i -lt ${#NAMES[@]} ]; do
  name="${NAMES[$i]}"
  canon="${CANON[$i]}"
  line="$(grep -E "^#define __NR_${name} " "$HEADER" || true)"
  if [ -z "$line" ]; then
    bad "__NR_${name} not present in header"
  else
    num="$(printf '%s\n' "$line" | awk '{print $3}')"
    if [ "$num" = "$canon" ]; then
      bad "__NR_${name} unchanged (still $canon) -- scrambler did nothing"
    else
      ok "__NR_${name} = $num (canonical was $canon)"
    fi
  fi
  i=$((i+1))
done

# ---------------------------------------------------------------------
echo "== Test 6: bijection -- all __NR_* numbers unique =="
# Extract the third token of every #define __NR_<x> line.
NUMS_TOTAL="$(grep -E '^#define __NR_[A-Za-z0-9_]+ ' "$HEADER" | awk '{print $3}' | wc -l | tr -d ' ')"
NUMS_UNIQUE="$(grep -E '^#define __NR_[A-Za-z0-9_]+ ' "$HEADER" | awk '{print $3}' | sort -u | wc -l | tr -d ' ')"
note "total __NR_* defines = $NUMS_TOTAL"
note "unique numbers       = $NUMS_UNIQUE"
if [ "$NUMS_TOTAL" -gt 0 ] && [ "$NUMS_TOTAL" = "$NUMS_UNIQUE" ]; then
  ok "bijection holds ($NUMS_TOTAL syscalls, all distinct numbers)"
else
  bad "bijection violated: $NUMS_TOTAL defines but $NUMS_UNIQUE distinct numbers"
fi

# ---------------------------------------------------------------------
echo "== Test 7: determinism -- two runs byte-identical =="
SNAP="$(mktemp -d)"
cp "$HEADER" "$SNAP/h1"
cp "$TABLE"  "$SNAP/t1"
cp "$JSON"   "$SNAP/j1"

python3 "$SCRIPTS/gen-unistd-seeded.py" >/dev/null

if diff -q "$SNAP/h1" "$HEADER" >/dev/null \
&& diff -q "$SNAP/t1" "$TABLE"  >/dev/null \
&& diff -q "$SNAP/j1" "$JSON"   >/dev/null; then
  ok "two consecutive runs produced byte-identical outputs"
else
  bad "outputs differ across runs -- determinism broken"
  diff "$SNAP/h1" "$HEADER" | head -20 || true
fi
rm -rf "$SNAP"

# ---------------------------------------------------------------------
echo
echo "==================================================="
if [ "$FAIL" -eq 0 ]; then
  echo "  PASS  (all $PASS checks)"
  echo "==================================================="
  exit 0
else
  echo "  FAIL  ($FAIL failures, $PASS passes)"
  echo "==================================================="
  exit 1
fi
