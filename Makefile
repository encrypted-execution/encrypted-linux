# encrypted-linux — top-level Make targets
#
# All real work happens inside Docker so the demo is host-portable.

REPO_ROOT := $(shell pwd)
DOCKER_TAG_TEST := encrypted-linux-test
DOCKER_TAG_GCC  := encrypted-linux-gcc

.PHONY: help test test-image demo demo-mangle demo-unistd demo-plugin \
        gcc-image gcc-build demo-gcc gcc-patch clean

help:
	@echo "encrypted-linux make targets:"
	@echo "  make test          — full joint smoke test (post-pass + Track B + plugin) inside Docker"
	@echo "  make demo          — alias for test"
	@echo "  make demo-mangle   — post-compile mangling demo (Track A bash)"
	@echo "  make demo-plugin   — compile-time mangling demo (Track A GCC plugin)"
	@echo "  make demo-unistd   — syscall-renumbering demo (Track B)"
	@echo "  make demo-gcc      — patched-GCC arg-register permutation demo (Track A backend patch)"
	@echo "  make test-image    — build the encrypted-linux-test Docker image"
	@echo "  make gcc-image     — build the encrypted-linux-gcc Docker image (staging only, ~1.2 GB)"
	@echo "  make gcc-build     — actually BUILD the patched cross-compiler (~15-30 min)"
	@echo "  make gcc-patch     — regenerate patches/scramble-gcc-v0.patch via git format-patch"
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

clean:
	rm -rf build/
