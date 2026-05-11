#!/usr/bin/env bash
# scripts/seed-lib.sh
#
# Bash implementation of the encrypted-linux seed-derivation helpers.
#
# Mirrors scripts/seed-lib.py (Track B / Engineer B). For the same
# (seed-hex, label) pair, this script and seed-lib.py MUST produce
# byte-identical output. Cross-check:
#
#   seed_lib_hmac_hex "$(cat seed)" "user.abi"
#   python3 -c "import hmac, hashlib; \
#       print(hmac.new(bytes.fromhex(open('seed').read().strip()), \
#                      b'user.abi', hashlib.sha256).hexdigest())"
#
# Salt strings are frozen and never changed; see SEED.md / plan/05 §
# "Notes on shared seed material".
#
# Functions exposed (source this file):
#   seed_lib_hmac_hex SEED_HEX LABEL        -> 64 hex chars (full HMAC-SHA256)
#   seed_lib_hmac_prefix SEED_HEX LABEL N   -> first N hex chars of HMAC
#   seed_lib_user_abi_seed SEED_HEX         -> HMAC(seed, "user.abi")
#   seed_lib_kernel_abi_seed SEED_HEX       -> HMAC(seed, "kernel.abi")
#   seed_lib_syscall_seed SEED_HEX          -> HMAC(seed, "syscall.numbers")
#   seed_lib_symbol_suffix SEED_HEX NAME    -> first 8 hex chars of
#                                              HMAC(USER_ABI_SEED, NAME).
#                                              This is the per-symbol ABI tag
#                                              appended to mangled names.
#
# Host requirements: bash 3.2+, openssl (system openssl is fine; the
# scrypt path isn't used). No GNU coreutils dependency.
#
# License: Apache-2.0.

set -u

# Frozen salt strings — see plan/05 §"Notes on shared seed material".
# Changing these breaks every downstream build by design.
readonly SEED_LIB_LABEL_USER_ABI="user.abi"
readonly SEED_LIB_LABEL_KERNEL_ABI="kernel.abi"
readonly SEED_LIB_LABEL_SYSCALL="syscall.numbers"

# seed_lib_require_openssl: hard-fail if openssl isn't on PATH.
seed_lib_require_openssl() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo "seed-lib.sh: 'openssl' not found on PATH" >&2
        return 127
    fi
}

# seed_lib_hmac_hex SEED_HEX LABEL
#   Computes HMAC-SHA256(key = bytes.fromhex(SEED_HEX), message = LABEL).
#   Prints 64 hex characters on stdout. No trailing newline-stripping
#   needed by callers — the trailing newline is left as-is.
#
# Implementation note: openssl's "-mac HMAC -macopt hexkey:..." form
# takes the key as hex and the message on stdin. We strip openssl's
# "(stdin)= " prefix from the output (BSD/macOS LibreSSL emits it;
# GNU/OpenSSL 3.x does not depending on version — we handle both).
seed_lib_hmac_hex() {
    local seed_hex="$1"
    local label="$2"

    seed_lib_require_openssl || return $?

    # printf '%s' is critical — we hash the label WITHOUT a trailing
    # newline. Python's hmac.new(..., b"user.abi", ...) hashes exactly
    # 8 bytes; we must do the same.
    local out
    out=$(printf '%s' "$label" \
        | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${seed_hex}" \
        | tr -d '[:space:]')

    # Strip any "(stdin)=" prefix some openssl versions emit.
    out="${out#*(stdin)=}"
    out="${out#*=}"  # belt-and-braces: some builds emit "HMAC-SHA256(stdin)= ..."

    printf '%s\n' "$out"
}

# seed_lib_hmac_prefix SEED_HEX LABEL N
seed_lib_hmac_prefix() {
    local seed_hex="$1"
    local label="$2"
    local n="$3"
    local full
    full=$(seed_lib_hmac_hex "$seed_hex" "$label") || return $?
    printf '%s\n' "${full:0:$n}"
}

seed_lib_user_abi_seed() {
    seed_lib_hmac_hex "$1" "$SEED_LIB_LABEL_USER_ABI"
}

seed_lib_kernel_abi_seed() {
    seed_lib_hmac_hex "$1" "$SEED_LIB_LABEL_KERNEL_ABI"
}

seed_lib_syscall_seed() {
    seed_lib_hmac_hex "$1" "$SEED_LIB_LABEL_SYSCALL"
}

# seed_lib_symbol_suffix SEED_HEX SYMBOL_NAME
#   The per-symbol mangling tag. Layered:
#     USER_ABI_SEED = HMAC(seed, "user.abi")
#     tag           = HMAC(USER_ABI_SEED, symbol_name)[:8]
#   so the master seed never directly keys per-symbol material.
#   (See plan/05: "isolates failure domains".)
seed_lib_symbol_suffix() {
    local seed_hex="$1"
    local sym="$2"
    local user_abi
    user_abi=$(seed_lib_user_abi_seed "$seed_hex") || return $?
    seed_lib_hmac_prefix "$user_abi" "$sym" 8
}

# CLI entrypoint for ad-hoc shell use:
#   seed-lib.sh hmac SEED_HEX LABEL          -> full HMAC
#   seed-lib.sh user-abi SEED_HEX            -> USER_ABI_SEED
#   seed-lib.sh kernel-abi SEED_HEX          -> KERNEL_ABI_SEED
#   seed-lib.sh syscall SEED_HEX             -> SYSCALL_SEED
#   seed-lib.sh suffix SEED_HEX SYMBOL_NAME  -> 8-char tag
seed_lib_main() {
    case "${1:-}" in
        hmac)        seed_lib_hmac_hex      "$2" "$3" ;;
        user-abi)    seed_lib_user_abi_seed "$2" ;;
        kernel-abi)  seed_lib_kernel_abi_seed "$2" ;;
        syscall)     seed_lib_syscall_seed  "$2" ;;
        suffix)      seed_lib_symbol_suffix "$2" "$3" ;;
        ""|-h|--help|help)
            cat <<'USAGE' >&2
seed-lib.sh — encrypted-linux seed derivation (bash)

Usage:
  seed-lib.sh hmac        SEED_HEX LABEL
  seed-lib.sh user-abi    SEED_HEX
  seed-lib.sh kernel-abi  SEED_HEX
  seed-lib.sh syscall     SEED_HEX
  seed-lib.sh suffix      SEED_HEX SYMBOL_NAME

Or `source seed-lib.sh` and call seed_lib_* directly.

SEED_HEX is 64 hex characters (= 256 bits).
USAGE
            return 2 ;;
        *)
            echo "seed-lib.sh: unknown subcommand: $1" >&2
            return 2 ;;
    esac
}

# Run main only if executed directly, not when sourced.
# BASH_SOURCE[0] is set when this file is sourced; ${0} is the
# script being executed by the shell.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
    seed_lib_main "$@"
fi
