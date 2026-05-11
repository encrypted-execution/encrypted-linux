# buildroot/

Buildroot integration. The encrypted-linux build harness lives here as
a Buildroot "BR2_EXTERNAL" tree, so we never fork Buildroot itself —
we just point it at this directory.

Structure (planned):

```
buildroot/
├── README.md                          (this file)
├── external.desc                      (Buildroot BR2_EXTERNAL metadata)
├── external.mk                        (Buildroot package includes)
├── Config.in                          (Buildroot menuconfig entries)
├── configs/
│   └── encrypted_linux_defconfig      (the PoC config)
├── package/
│   ├── scramble-gcc/                  (custom toolchain pkg)
│   ├── scrambled-musl/                (musl with our patches)
│   ├── scrambled-busybox/             (just BusyBox + scramble-gcc dep)
│   └── hello-demo/                    (the dual-hello demo binary)
├── board/
│   └── encrypted-linux/
│       ├── linux.config               (kernel config)
│       └── post-build.sh              (assembles rootfs.cpio)
└── docs/
    └── using-this-tree.md             (engineer onboarding)
```

## Usage (planned)

```
git clone https://github.com/encrypted-execution/encrypted-linux
cd encrypted-linux

# one-time
git clone --depth 1 -b 2025.02 https://gitlab.com/buildroot.org/buildroot.git
make -C buildroot O=$PWD/build \
    BR2_EXTERNAL=$PWD/buildroot \
    encrypted_linux_defconfig
make -C buildroot O=$PWD/build

# output:
./build/images/bzImage
./build/images/rootfs.cpio.gz

# demo:
./scripts/qemu.sh
```

## Why Buildroot over LFS / Yocto / NixOS

See `research/05-distro-bootstrap-options.md`. Buildroot wins on
iteration speed (~15 min full rebuilds), single-target focus, and
zero dependency-resolution machinery (a feature, not a bug, for our
closure model).
