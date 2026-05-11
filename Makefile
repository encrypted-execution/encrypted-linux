# encrypted-linux — top-level Make targets
#
# All real work happens inside Docker so the demo is host-portable.

REPO_ROOT := $(shell pwd)
DOCKER_TAG_TEST := encrypted-linux-test
DOCKER_TAG_GCC  := encrypted-linux-gcc

.PHONY: help test test-image demo demo-mangle demo-unistd gcc-image clean

help:
	@echo "encrypted-linux make targets:"
	@echo "  make test          — full joint smoke test (Track A + Track B) inside Docker"
	@echo "  make demo          — alias for test"
	@echo "  make demo-mangle   — symbol-mangling demo only (Track A)"
	@echo "  make demo-unistd   — syscall-renumbering demo only (Track B)"
	@echo "  make test-image    — build the encrypted-linux-test Docker image"
	@echo "  make gcc-image     — build the encrypted-linux-gcc Docker image (~1.2 GB)"
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

clean:
	rm -rf build/
