#!/usr/bin/env bash
#
# scripts/scramble-mangle.sh — symbol-mangling post-pass for ELF objects
#
# Reads an ELF .o / .a / executable, rewrites every external C symbol
# name to <name>__abi_<8hex>, where <8hex> = first 8 hex chars of
# HMAC-SHA256(USER_ABI_SEED, name), and USER_ABI_SEED = HMAC-SHA256
# (master_seed, "user.abi").
#
# This is the load-bearing piece of Phase 1 — see plan/00 §3 and
# research/06 §2. With mangling enabled, a stock-built binary that
# references plain `printf` will fail to resolve against this system's
# scrambled libc (which exports only `printf__abi_<hex>`). The failure
# happens at ld.so symbol-resolution time, not at runtime, giving the
# defender a clean signal.
#
# Phase 1 PoC scope: this is a POST-COMPILE pass using objcopy
# --redefine-syms, not a real GCC patch. The full ABI scrambling
# (arg-register permutation + callee-saved permutation) is plan/01 M3
# work and lives in `patches/scramble-gcc-v0.patch` (not yet written).
# Mangling alone is enough for the PoC demo asciicast in plan/04.
#
# Usage:
#   scramble-mangle.sh INPUT_OBJ OUTPUT_OBJ [SEED_HEX|--seed-file PATH]
#
# Defaults:
#   SEED_HEX is read from $ENCRYPTED_LINUX_SEED_FILE, falling back to
#   the repo-root `seed` file (auto-detected).
#
# Host requirements: bash 3.2+, openssl, binutils (`nm`, `objcopy`).
# On macOS, install via: brew install binutils; then prefix `gnm`/
# `gobjcopy`. This script does NOT support Mach-O — the demo is
# intended to run inside a Linux container (see docker/test.sh).
#
# Exclusions (preserve linkage; principle 0.8):
#   - local symbols (lowercase nm types)
#   - `main` (runtime entry point — `_start` in libc calls it)
#   - names starting with `_` (compiler/runtime internals: _init,
#     _fini, _start, __libc_start_main, __dso_handle, __cxa_*, etc.)
#   - names starting with `.` (section names)
#   - `syscall` (Phase 1 syscall escape hatch — preserves syscall ABI)
#
# License: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/seed-lib.sh
source "${SCRIPT_DIR}/seed-lib.sh"

usage() {
    cat >&2 <<'USAGE'
Usage: scramble-mangle.sh INPUT_OBJ OUTPUT_OBJ [SEED_HEX]

If SEED_HEX is omitted, reads $ENCRYPTED_LINUX_SEED_FILE or repo-root ./seed.

Examples:
  scramble-mangle.sh main.o main.scrambled.o
  scramble-mangle.sh libthing.o libthing.scrambled.o deadbeef...

Outputs the mangling map to ${OUTPUT_OBJ}.redefine-syms for inspection.
USAGE
}

if [ $# -lt 2 ]; then
    usage
    exit 2
fi

INPUT="$1"
OUTPUT="$2"
SEED_HEX="${3:-}"

# Resolve seed if not provided on the command line.
if [ -z "${SEED_HEX}" ]; then
    if [ -n "${ENCRYPTED_LINUX_SEED_FILE:-}" ] && [ -f "${ENCRYPTED_LINUX_SEED_FILE}" ]; then
        SEED_HEX="$(tr -d '[:space:]' < "${ENCRYPTED_LINUX_SEED_FILE}")"
    else
        # Walk up looking for ./seed
        d="$(pwd)"
        while [ "${d}" != "/" ]; do
            if [ -f "${d}/seed" ]; then
                SEED_HEX="$(tr -d '[:space:]' < "${d}/seed")"
                break
            fi
            d="$(dirname "${d}")"
        done
    fi
fi

if [ -z "${SEED_HEX}" ]; then
    echo "scramble-mangle: no seed found (set ENCRYPTED_LINUX_SEED_FILE or place ./seed in a parent dir)" >&2
    exit 1
fi

# Resolve tool names (binutils on Linux; gnm/gobjcopy on macOS+brew).
NM="${NM:-nm}"
OBJCOPY="${OBJCOPY:-objcopy}"
if ! command -v "${NM}" >/dev/null 2>&1; then
    if command -v gnm >/dev/null 2>&1; then NM=gnm; else
        echo "scramble-mangle: no nm on PATH" >&2; exit 127
    fi
fi
if ! command -v "${OBJCOPY}" >/dev/null 2>&1; then
    if command -v gobjcopy >/dev/null 2>&1; then OBJCOPY=gobjcopy; else
        echo "scramble-mangle: no objcopy on PATH" >&2; exit 127
    fi
fi

# Derive USER_ABI_SEED once.
USER_ABI_SEED="$(seed_lib_user_abi_seed "${SEED_HEX}")"

# Build the rename map by streaming through `nm`.
#   nm format (--no-sort to preserve order, optional):
#     0000000000000000 T compute
#                      U printf
# Type letter in column 2 (after the address+space). We grep for
# uppercase types: T U D B W V R G.
MAP_FILE="${OUTPUT}.redefine-syms"
: > "${MAP_FILE}"

# `nm -P` is portable POSIX format: "name type value size" — easier
# to parse than the default. Falls back to default `nm` if -P missing.
if "${NM}" -P "${INPUT}" >/dev/null 2>&1; then
    NM_CMD=("${NM}" -P "${INPUT}")
else
    NM_CMD=("${NM}" "${INPUT}")
fi

while read -r line; do
    # Skip blank / archive-section banners ("\nfile.o:\n").
    [ -z "${line}" ] && continue
    case "${line}" in *:) continue ;; esac

    if "${NM}" -P "${INPUT}" >/dev/null 2>&1; then
        # POSIX format: name type [value [size]]
        name="${line%% *}"
        rest="${line#* }"
        type_letter="${rest%% *}"
    else
        # BSD format: "[value ]type name"
        # Strip leading whitespace, split.
        cleaned="${line#"${line%%[![:space:]]*}"}"
        # Detect single-letter type vs. address+space+type+space+name.
        # Try the regex: "^[0-9a-fA-F]* *([A-Za-z?-]) (.*)$"
        if [[ "${cleaned}" =~ ^[0-9a-fA-F]*[[:space:]]*([A-Za-z?-])[[:space:]]+(.*)$ ]]; then
            type_letter="${BASH_REMATCH[1]}"
            name="${BASH_REMATCH[2]}"
        else
            continue
        fi
    fi

    # Skip if type is lowercase (local) or '?' (unknown) or '-' (debug).
    case "${type_letter}" in
        T|U|D|B|W|V|R|G|C) : ;;       # external — mangle
        *) continue ;;
    esac

    # Skip exclusion list (principle 0.8).
    case "${name}" in
        main|syscall) continue ;;
        _*) continue ;;
        .*) continue ;;
        @*) continue ;;               # GNU version refs like @GLIBC_2.2.5
    esac

    # Skip names that look like already-mangled (idempotency).
    case "${name}" in
        *__abi_*) continue ;;
    esac

    tag="$(seed_lib_hmac_prefix "${USER_ABI_SEED}" "${name}" 8)"
    printf '%s %s__abi_%s\n' "${name}" "${name}" "${tag}" >> "${MAP_FILE}"
done < <("${NM_CMD[@]}")

# Sort + dedup (a symbol may appear twice if defined-and-referenced).
sort -u -o "${MAP_FILE}" "${MAP_FILE}"

# Apply.
"${OBJCOPY}" --redefine-syms="${MAP_FILE}" "${INPUT}" "${OUTPUT}"

renamed=$(wc -l < "${MAP_FILE}" | tr -d ' ')
echo "scramble-mangle: ${INPUT} -> ${OUTPUT}  (${renamed} symbols mangled, map at ${MAP_FILE})" >&2
