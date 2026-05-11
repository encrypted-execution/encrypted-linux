# Makefile for the encrypted-linux scramble-mangle GCC plugin.
#
# Builds a shared object loadable via `gcc -fplugin=./scramble-mangle.so`.
# Compiles against the system GCC's plugin development headers (the
# gcc-NN-plugin-dev apt package on Debian/Ubuntu).
#
# Override the host GCC if you have multiple installed:
#   make GCC=gcc-13
#
# Requires:
#   - gcc-NN-plugin-dev for the matching GCC version
#   - libssl-dev (libcrypto for HMAC-SHA256)

GCC      ?= gcc
PLUGIN_DIR := $(shell $(GCC) -print-file-name=plugin)
CXX      ?= g++

CXXFLAGS := -O2 -Wall -Wextra \
            -fno-rtti -fPIC \
            -I$(PLUGIN_DIR)/include
LDFLAGS  := -shared
LDLIBS   := -lcrypto

TARGET := scramble-mangle.so
SOURCES := scramble-mangle.cc

.PHONY: all clean check
all: $(TARGET)

$(TARGET): $(SOURCES)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(SOURCES) -o $@ $(LDLIBS)

clean:
	rm -f $(TARGET) *.o

# Quick sanity: compile a trivial program with the plugin loaded, verify
# the expected mangled symbol comes out. Set ENCRYPTED_LINUX_SEED first.
check: $(TARGET)
	@test -n "$$ENCRYPTED_LINUX_SEED" || { \
	    echo "Set ENCRYPTED_LINUX_SEED before running 'make check'" >&2; exit 1; }
	@printf 'int compute(int x){return x+x;}\n' > /tmp/_smoke.c
	@$(GCC) -fplugin=./$(TARGET) -c /tmp/_smoke.c -o /tmp/_smoke.o
	@nm /tmp/_smoke.o | grep -E ' T compute__abi_[0-9a-f]{8}' \
	    && echo "OK — compute mangled" \
	    || { echo "FAIL — compute not mangled"; nm /tmp/_smoke.o; exit 1; }
	@rm -f /tmp/_smoke.c /tmp/_smoke.o
