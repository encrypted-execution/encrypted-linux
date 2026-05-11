# docker/

Container images used by the encrypted-linux build. None of these
ship to the target — they exist only on the build host.

| Image | Dockerfile | Purpose | Size |
|---|---|---|---|
| `encrypted-linux-test` | `Dockerfile.test` | Run the Track A + Track B smoke tests on a Linux host regardless of where you're developing | ~150 MB |
| `encrypted-linux-gcc` | `Dockerfile.gcc-build` | Stage GCC 14 source + build deps for the future scrambling-GCC patch | ~1.2 GB |

## Quick start — run the joint demo (works on macOS, Linux, WSL)

From the repo root:

```
docker build -t encrypted-linux-test -f docker/Dockerfile.test .
docker run --rm -v "$PWD":/work -w /work encrypted-linux-test
```

That builds the test image (once; cached afterward), bind-mounts the
repo, and runs both `scramble-mangle-test/test.sh` (Track A) and
`test/test-seed-lib.sh` (Track B). Expected: 3 PASS banners from
Track A, 14 PASS banners from Track B.

The `make demo` Make target (TODO) will wrap this.

## Running scramble-mangle.sh ad-hoc inside the test image

```
docker run --rm -v "$PWD":/work -w /work encrypted-linux-test \
    bash -c '
        cd scripts/scramble-mangle-test &&
        gcc -c libthing.c -o libthing.o &&
        ../scramble-mangle.sh libthing.o libthing.scr.o &&
        nm libthing.scr.o
    '
```

Should print a symbol table containing `compute__abi_<8hex>`.

## Building GCC with the scrambling patch (FUTURE)

The patch doesn't exist yet (`patches/scramble-gcc-v0.patch` is TODO,
see `patches/README.md`). When it does, the workflow is:

```
docker build -t encrypted-linux-gcc -f docker/Dockerfile.gcc-build .
docker run --rm \
    -v "$PWD/patches":/patches \
    -v "$PWD/build/toolchain":/build/toolchain \
    encrypted-linux-gcc bash -c '
        cd /opt/gcc-14 &&
        patch -p1 < /patches/scramble-gcc-v0.patch &&
        mkdir build && cd build &&
        ../configure --target=x86_64-encrypted-linux-musl \
                     --prefix=/build/toolchain \
                     --disable-bootstrap \
                     --disable-multilib \
                     --enable-languages=c,c++ \
                     ENCRYPTED_LINUX_SEED=$(cat /work/seed) &&
        make -j$(nproc) &&
        make install
    '
```

Build wall-time: 30–60 min single-threaded, 10–20 min on ≥8 cores.
Produces `./build/toolchain/bin/x86_64-encrypted-linux-musl-gcc` —
the scrambling cross-compiler.

## Why Docker

- **Faithful Linux ELF target** regardless of where the developer is.
  macOS arm64 hosts produce Mach-O by default; the encrypted-linux
  threat model is Linux ELF + ld.so. Docker pins this.
- **Hermetic toolchain.** `gcc` and `binutils` versions inside the
  container are fixed by the Ubuntu base image, so the same patches
  apply identically on every developer's machine.
- **No host pollution.** None of this touches the developer's `brew`,
  `apt`, or `/usr/local`.

## Determinism note

The Dockerfiles pin the Ubuntu base tag (`24.04`) and the GCC SHA256
hash. They don't pin every apt-installed transitive dependency by
hash — that's a future hardening step. For the PoC, `Dockerfile.test`
and `Dockerfile.gcc-build` are deterministic at the level of "same
Ubuntu image tag → same toolchain," which is enough for the demo
asciicast.
