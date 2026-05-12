#!/usr/bin/env bash
#
# scripts/extract-alpine-toolchain.sh — pull Alpine's gcc + binutils +
# libgcc + libstdc++ + glibc-equivalent libs out of a fresh Alpine
# container and stage them under build/alpine-toolchain/ for bundling
# into the encrypted-linux VM rootfs.
#
# These binaries are dynamically linked against Alpine's musl. We
# replace the dynamic loader (/lib/ld-musl-x86_64.so.1) with our
# OVERKILL musl, so that when these binaries run inside our VM, every
# libc call routes through scrambled syscalls.
#
# Output:
#   build/alpine-toolchain/  — staged tree mirroring the in-VM paths
#       usr/bin/{gcc,cc,cpp,ld,as,ar,...}
#       usr/lib/{libgcc_s.so.1, libstdc++.so.6, ...}
#       usr/lib/gcc/x86_64-alpine-linux-musl/<ver>/{libgcc.a,cc1,...}
#       usr/include/  (kernel + musl headers — useful for compiling)
#
# License: Apache-2.0

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

rm -rf build/alpine-toolchain
mkdir -p build/alpine-toolchain

cat > tmp-alpine-extract.sh <<'INSIDE'
#!/bin/sh
set -eu

apk add --no-cache gcc g++ musl-dev binutils make linux-headers \
    mpc1 mpfr4 gmp isl26 zlib zstd ssp-nonshared >/dev/null 2>&1 \
    || apk add --no-cache gcc g++ musl-dev binutils make linux-headers \
       mpc1 mpfr4 gmp isl26 zlib zstd >/dev/null

# Mirror the in-VM paths.
OUT=/out
mkdir -p $OUT/usr/bin $OUT/usr/lib $OUT/usr/libexec $OUT/usr/include

# Top-level toolchain binaries.
for b in gcc cc g++ c++ cpp as ld ar ranlib strip nm objdump objcopy \
         x86_64-alpine-linux-musl-gcc x86_64-alpine-linux-musl-g++ \
         x86_64-alpine-linux-musl-ld x86_64-alpine-linux-musl-as; do
    src=$(command -v $b 2>/dev/null) || continue
    cp -a "$src" "$OUT/usr/bin/$b"
done

# libgcc, libstdc++, libssp, etc, plus cc1's transitive deps.
# Bundle every .so* from /usr/lib and /lib. Larger but eliminates
# the whack-a-mole of tracking gcc/binutils transitive deps.
apk add --no-cache jansson zstd-libs zlib mpc1 mpfr4 gmp isl26 \
    libgcc libstdc++ binutils-dev binutils >/dev/null 2>&1 || true
for libdir in /lib /usr/lib; do
    [ -d "$libdir" ] || continue
    find "$libdir" -maxdepth 1 -name "*.so*" -type f | while read f; do
        cp -aL "$f" "$OUT/usr/lib/" 2>/dev/null || true
    done
    find "$libdir" -maxdepth 1 -name "*.so*" -type l | while read f; do
        cp -aL "$f" "$OUT/usr/lib/" 2>/dev/null || true
    done
done

# gcc's libexec dir contains cc1, cc1plus, collect2 — the actual
# compiler binaries.
GCC_LIBEXEC=$(find /usr/libexec -type d -name "x86_64-alpine-linux-musl" 2>/dev/null | head -1)
if [ -n "$GCC_LIBEXEC" ]; then
    mkdir -p "$OUT/usr/libexec/gcc/x86_64-alpine-linux-musl"
    cp -a "$GCC_LIBEXEC/." "$OUT/usr/libexec/gcc/x86_64-alpine-linux-musl/"
fi

# gcc's lib dir contains libgcc.a + specs + crtbegin.o etc.
GCC_LIB=$(find /usr/lib/gcc/x86_64-alpine-linux-musl -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
if [ -n "$GCC_LIB" ]; then
    mkdir -p "$OUT/usr/lib/gcc/x86_64-alpine-linux-musl"
    cp -aL "$GCC_LIB" "$OUT/usr/lib/gcc/x86_64-alpine-linux-musl/"
fi

# Alpine's gcc expects ld + crt files at /usr/x86_64-alpine-linux-musl/...
# (target-prefixed subtree). Bundle the whole thing.
if [ -d /usr/x86_64-alpine-linux-musl ]; then
    cp -a /usr/x86_64-alpine-linux-musl "$OUT/usr/"
fi

# Find libssp_nonshared.a wherever Alpine put it (musl-dev or ssp-nonshared).
for ssp in $(find / -name 'libssp_nonshared*' 2>/dev/null); do
    cp -aL "$ssp" "$OUT/usr/lib/" 2>/dev/null || true
    # Also into target-prefixed lib for gcc's search.
    cp -aL "$ssp" "$OUT/usr/x86_64-alpine-linux-musl/lib/" 2>/dev/null || true
done

# binutils ld scripts.
if [ -d /usr/lib/ldscripts ]; then
    cp -a /usr/lib/ldscripts "$OUT/usr/lib/" 2>/dev/null || true
fi

# Standard headers.
cp -a /usr/include "$OUT/usr/" 2>/dev/null || true

# crt files (Scrt1.o, crt1.o, crti.o, crtn.o, etc.) — needed for linking.
for crt in Scrt1.o crt1.o crti.o crtn.o gcrt1.o rcrt1.o; do
    src=$(find /usr/lib -name "$crt" 2>/dev/null | head -1) || continue
    [ -n "$src" ] && cp -aL "$src" "$OUT/usr/lib/" 2>/dev/null || true
done

# Report.
echo "=== Staged toolchain ==="
ls -la $OUT/usr/bin/ | head -10
echo "..."
echo "=== libs ==="
ls $OUT/usr/lib/*.so* 2>/dev/null | head -5
echo "=== cc1 etc ==="
find $OUT -name 'cc1' -o -name 'cc1plus' -o -name 'collect2' 2>/dev/null
echo "=== libgcc.a ==="
find $OUT -name 'libgcc.a' 2>/dev/null
INSIDE
chmod +x tmp-alpine-extract.sh

docker run --rm --platform linux/amd64 --user root \
    -v "$PWD/build/alpine-toolchain":/out \
    -v "$PWD":/work \
    alpine:3.20 \
    sh /work/tmp-alpine-extract.sh

rm -f tmp-alpine-extract.sh
echo
echo "Total size: $(du -sh build/alpine-toolchain 2>/dev/null | awk '{print $1}')"
