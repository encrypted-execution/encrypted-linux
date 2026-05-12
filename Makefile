# encrypted-linux — top-level Make targets
#
# All real work happens inside Docker so the demo is host-portable.

REPO_ROOT := $(shell pwd)
DOCKER_TAG_TEST := encrypted-linux-test
DOCKER_TAG_GCC  := encrypted-linux-gcc

.PHONY: help test test-image demo demo-mangle demo-unistd demo-plugin \
        gcc-image gcc-build demo-gcc gcc-patch \
        overkill overkill-full demo-overkill demo-randstruct \
        clean

help:
	@echo "encrypted-linux make targets:"
	@echo "                                                          "
	@echo " === Unit tests (~5 min via Docker) ====================="
	@echo "  make test          — full joint smoke test (post-pass + Track B + plugin)"
	@echo "  make demo          — alias for test"
	@echo "  make demo-mangle   — post-compile mangling demo (Track A bash)"
	@echo "  make demo-plugin   — compile-time mangling demo (Track A GCC plugin)"
	@echo "  make demo-unistd   — syscall-renumbering demo (Track B)"
	@echo "  make demo-gcc      — patched-GCC arg-register permutation demo"
	@echo "                                                          "
	@echo " === Overkill stack (~20-40 min total) ===================="
	@echo "  make overkill      — build kernel + musl + busybox + hello (no toolchain)"
	@echo "  make overkill-full — full overkill image + bundled gcc + initramfs"
	@echo "  make demo-overkill — boot overkill in QEMU and run hello"
	@echo "  make demo-randstruct — verify CONFIG_RANDSTRUCT_FULL active"
	@echo "                                                          "
	@echo " === Docker image management ============================="
	@echo "  make test-image    — build encrypted-linux-test (~150 MB)"
	@echo "  make gcc-image     — build encrypted-linux-gcc (~1.2 GB)"
	@echo "  make gcc-build     — build the patched cross-compiler"
	@echo "  make gcc-patch     — regenerate patches/scramble-gcc-v0.patch"
	@echo "                                                          "
	@echo "  make clean         — remove build/ artifacts"

test-image:
	docker build -t $(DOCKER_TAG_TEST) -f docker/Dockerfile.test .

gcc-image:
	docker build -t $(DOCKER_TAG_GCC) -f docker/Dockerfile.gcc-build .

test: test-image
	docker run --rm -v "$(REPO_ROOT)":/work -w /work $(DOCKER_TAG_TEST)

demo: test

demo-mangle: test-image
	docker run --rm -v "$(REPO_ROOT)":/work -w /work $(DOCKER_TAG_TEST) \
	    bash scripts/scramble-mangle-test/test.sh

demo-unistd: test-image
	docker run --rm -v "$(REPO_ROOT)":/work -w /work $(DOCKER_TAG_TEST) \
	    bash scripts/test/test-seed-lib.sh

demo-plugin: test-image
	docker run --rm -v "$(REPO_ROOT)":/work -w /work $(DOCKER_TAG_TEST) \
	    bash scripts/scramble-mangle-test/test-plugin.sh

gcc-build: gcc-image
	bash scripts/build-scramble-gcc.sh

demo-gcc:
	@test -x build/scramble-gcc/install/bin/x86_64-linux-gnu-gcc \
	    || (echo "Run 'make gcc-build' first (~15-30 min)" >&2 && exit 1)
	docker run --rm --user root -v "$(REPO_ROOT)":/work -w /work $(DOCKER_TAG_GCC) \
	    bash scripts/scramble-gcc-test/test.sh

gcc-patch: gcc-image
	bash scripts/gen-gcc-patch.sh

# ─── Overkill stack ─────────────────────────────────────────────
overkill:
	docker build -t encrypted-linux-image-build -f docker/Dockerfile.image-build .
	bash scripts/build-overkill-image.sh

overkill-full: overkill
	bash scripts/build-overkill-musl-shared.sh
	bash scripts/extract-alpine-toolchain.sh
	bash scripts/assemble-overkill-gcc-initramfs.sh

demo-overkill:
	@test -f build/overkill/bzImage || (echo 'Run "make overkill" first'; exit 1)
	@test -f build/overkill/rootfs.cpio.gz || \
	    docker run --rm --platform linux/amd64 --user root \
	        -v "$(REPO_ROOT)":/work -w /work encrypted-linux-image-build \
	        bash scripts/assemble-overkill-initramfs.sh
	gtimeout 60 qemu-system-x86_64 -m 4G \
	    -kernel build/overkill/bzImage \
	    -initrd build/overkill/rootfs.cpio.gz \
	    -append "console=ttyS0 panic=5 loglevel=3 el_demo=auto" \
	    -nographic -no-reboot -accel tcg

demo-randstruct:
	bash scripts/verify-randstruct.sh

clean:
	rm -rf build/
