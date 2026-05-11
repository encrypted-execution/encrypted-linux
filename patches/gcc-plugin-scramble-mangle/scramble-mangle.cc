// patches/gcc-plugin-scramble-mangle/scramble-mangle.cc
//
// GCC plugin: encrypted-linux symbol mangling at compile time.
//
// This is the compile-time replacement for scripts/scramble-mangle.sh
// (which performs the same mangling as a post-link `objcopy --redefine-syms`
// pass). Same observable output, same exclusion rules — but the mangling
// is now native to the compiler, which is what plan/01 M2 requires.
//
// Mechanism:
//   - At plugin init: derive USER_ABI_SEED = HMAC-SHA256(master_seed, "user.abi")
//     from $ENCRYPTED_LINUX_SEED (a 64-hex-char string).
//   - On every PLUGIN_FINISH_DECL event, inspect the decl:
//       - skip non-FUNCTION_DECLs
//       - skip statics (TREE_PUBLIC == 0)
//       - skip decls whose assembler name was set explicitly via asm("...")
//         — the escape hatch for hand-written symbols
//       - skip the exclusion list: main, syscall, _*, .*, *__abi_*, _Z*
//   - For each surviving decl, set its assembler name to
//     <name>__abi_<tag>, where tag = HMAC-SHA256(USER_ABI_SEED, name)[:8 hex].
//
// What this is NOT:
//   - This plugin does NOT permute argument or callee-saved registers.
//     That is plan/01 M1+M3, requires a backend patch to gcc/config/i386/
//     i386.cc, and is many weeks of work. The mangling alone is enough
//     for the PoC asciicast (plan/04) because the load-time failure mode
//     is the headline value-prop.
//   - This plugin does NOT touch C++ Itanium-mangled symbols (_Z*); they
//     already have their own mangling that encodes types. Layering ours
//     on top would defeat C++ EH and friends.
//
// Usage:
//   ENCRYPTED_LINUX_SEED=<64 hex> gcc -fplugin=./scramble-mangle.so foo.c -c
//
// Cross-check vs the bash post-pass: for the same seed and the same
// translation unit, `gcc -fplugin=./scramble-mangle.so foo.c -c -o foo.o`
// produces a foo.o whose symbol table is byte-identical (in mangled
// names) to `gcc foo.c -c -o foo.o && scramble-mangle.sh foo.o foo.scr.o`.
// The plugin path is the one we ship; the post-pass exists for testing
// and for objects we don't compile ourselves.
//
// License: Apache-2.0

#include <gcc-plugin.h>
#include <plugin-version.h>
#include <tree.h>
#include <stringpool.h>     // get_identifier
#include <cgraph.h>
#include <openssl/hmac.h>
#include <openssl/evp.h>

#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <string>

// Required by GCC for plugin loading.
int plugin_is_GPL_compatible;

namespace {

// Derived once at plugin init from $ENCRYPTED_LINUX_SEED.
unsigned char user_abi_seed[32];
bool plugin_initialized = false;

// Compute first 8 hex chars of HMAC-SHA256(user_abi_seed, name).
std::string symbol_tag(const char *name, size_t len) {
    unsigned char digest[32];
    unsigned int digest_len = 32;
    HMAC(EVP_sha256(), user_abi_seed, 32,
         reinterpret_cast<const unsigned char *>(name), len,
         digest, &digest_len);

    static const char hex_chars[] = "0123456789abcdef";
    char buf[9];
    for (int i = 0; i < 4; i++) {
        buf[i * 2]     = hex_chars[(digest[i] >> 4) & 0xf];
        buf[i * 2 + 1] = hex_chars[digest[i]        & 0xf];
    }
    buf[8] = '\0';
    return std::string(buf);
}

// Exclusion list — must match scripts/scramble-mangle.sh and plan/00 §6.
bool should_skip(const char *name) {
    if (!name || !*name)             return true;
    if (strcmp(name, "main") == 0)   return true;   // runtime entry point
    if (strcmp(name, "syscall") == 0) return true;  // syscall escape hatch
    if (name[0] == '_')              return true;   // runtime/compiler internals: _init, _start, __libc_start_main, _Z* (C++ Itanium), etc.
    if (name[0] == '.')              return true;   // section names
    if (strstr(name, "__abi_"))      return true;   // idempotency
    return false;
}

// The actual rename. Idempotent — calling twice on the same decl is fine.
void maybe_mangle_decl(tree decl) {
    if (!decl) return;
    if (TREE_CODE(decl) != FUNCTION_DECL) return;
    if (!TREE_PUBLIC(decl)) return;

    tree name_id = DECL_NAME(decl);
    if (!name_id) return;

    const char *name = IDENTIFIER_POINTER(name_id);
    if (should_skip(name)) return;

    // If the assembler name was already set, check whether it matches what
    // we want. If it does (we set it on a prior pass), bail. If it's a
    // user-supplied asm("foo") override, also bail (escape hatch).
    if (DECL_ASSEMBLER_NAME_SET_P(decl)) {
        tree existing = DECL_ASSEMBLER_NAME(decl);
        const char *existing_str = IDENTIFIER_POINTER(existing);
        if (strstr(existing_str, "__abi_")) return;        // already mangled (us)
        if (strcmp(existing_str, name) != 0) return;        // user override
    }

    std::string mangled = std::string(name) + "__abi_" + symbol_tag(name, strlen(name));
    SET_DECL_ASSEMBLER_NAME(decl, get_identifier(mangled.c_str()));
}

// Fires after each declaration is parsed. Covers extern decls.
void on_finish_decl(void *gcc_data, void * /* user_data */) {
    maybe_mangle_decl(static_cast<tree>(gcc_data));
}

// Fires after each function body has been parsed, before genericization.
// Catches function DEFINITIONS that PLUGIN_FINISH_DECL misses (the body-
// completion path in the C front end does not always re-emit a
// PLUGIN_FINISH_DECL event for the FUNCTION_DECL).
void on_pre_genericize(void *gcc_data, void * /* user_data */) {
    maybe_mangle_decl(static_cast<tree>(gcc_data));
}

bool init_user_abi_seed_from_env() {
    const char *seed_hex = std::getenv("ENCRYPTED_LINUX_SEED");
    if (!seed_hex) {
        std::fprintf(stderr,
            "scramble-mangle: ENCRYPTED_LINUX_SEED is unset; refusing to load\n"
            "  set ENCRYPTED_LINUX_SEED=$(cat /path/to/seed) before invoking gcc\n");
        return false;
    }
    if (std::strlen(seed_hex) != 64) {
        std::fprintf(stderr,
            "scramble-mangle: ENCRYPTED_LINUX_SEED must be exactly 64 hex chars (got %zu)\n",
            std::strlen(seed_hex));
        return false;
    }

    unsigned char master_seed[32];
    for (int i = 0; i < 32; i++) {
        unsigned int b;
        if (std::sscanf(seed_hex + i * 2, "%2x", &b) != 1) {
            std::fprintf(stderr, "scramble-mangle: bad hex at byte %d of seed\n", i);
            return false;
        }
        master_seed[i] = static_cast<unsigned char>(b);
    }

    unsigned int len = 32;
    HMAC(EVP_sha256(), master_seed, 32,
         reinterpret_cast<const unsigned char *>("user.abi"), 8,
         user_abi_seed, &len);

    return true;
}

}  // namespace

extern "C"
int plugin_init(struct plugin_name_args *plugin_info,
                struct plugin_gcc_version *version) {
    if (!plugin_default_version_check(version, &gcc_version)) {
        std::fprintf(stderr,
            "scramble-mangle: GCC plugin version mismatch (built for %s, host is %s)\n",
            gcc_version.basever, version->basever);
        return 1;
    }

    if (!init_user_abi_seed_from_env()) return 1;
    plugin_initialized = true;

    register_callback(plugin_info->base_name,
                      PLUGIN_FINISH_DECL,
                      on_finish_decl,
                      nullptr);
    register_callback(plugin_info->base_name,
                      PLUGIN_PRE_GENERICIZE,
                      on_pre_genericize,
                      nullptr);

    if (std::getenv("SCRAMBLE_MANGLE_VERBOSE")) {
        std::fprintf(stderr,
            "scramble-mangle: loaded (PLUGIN_FINISH_DECL + PLUGIN_PRE_GENERICIZE hooked)\n");
    }
    return 0;
}
