# Research Dossier 02 — PHP Scrambler: Lessons for C/GCC

Studied: `/Users/archisgore/github/encrypted-execution/php-v2/` (active),
`/php/` (predecessor), `/Users/archisgore/github/archisgore/polyscripted-wordpress/`.

## 1. Mechanism: what gets renamed

The scrambler renames **PHP reserved keywords** (multi-character identifiers
like `if`, `class`, `function`, `echo`, `foreach`, `return`, `instanceof`) to
cryptographically random alphabetic strings 6–15 chars long.

- Keyword list defined by a big regex in
  `php-v2/tools/scrambler/dictionaryHandler.go:18-34`. Each match replaced
  with `randomStringGen()` from `randomizeString.go` (alphabet `a-zA-Z`,
  length 6–15, drawn from `crypto/rand`).
- Single-character symbols (`(`, `)`, `;`, `,`, `@`, `~`) were attempted via
  permutation cipher, **disabled by default** in v2 (`scrambler.go:30`,
  `charFlag` default `false`). Symbol scrambling breaks PHP because brackets
  are hard-coded in the lexer and multi-char operators (`===`, `&&`, `++`,
  `->`) collapse if components are remapped. See `SYMBOL_SCRAMBLING_ANALYSIS.md`.
- **Magic constants are explicitly NOT scrambled** — `MagicConstants` in
  `dictionaryHandler.go:38-47` blacklists `__LINE__`, `__FILE__`, `__DIR__`,
  `__FUNCTION__`, `__CLASS__`, `__TRAIT__`, `__METHOD__`, `__NAMESPACE__`.

## 2. Where scrambling happens in the pipeline

**Build time, against the lexer/parser grammar source — not bytecode, not AST.**

Scrambler edits two Zend engine source files before re2c / bison run:
- `$PHP_SRC_PATH/Zend/zend_language_scanner.l` (re2c lexer rules) — only
  `<ST_IN_SCRIPTING>` lines, only string-literal contents.
- `$PHP_SRC_PATH/Zend/zend_language_parser.y` (bison grammar) — only `%token
  T_` declarations and grammar rules where keywords appear as terminals.

Pipeline (`scripts/recompile-php.sh`):
1. Go scrambler edits `.l` and `.y` in place (backups to `.orig`).
2. `re2c --case-inverted -cbdFt zend_language_scanner_defs.h -o
   zend_language_scanner.c zend_language_scanner.l`.
3. `bison -y -d zend_language_parser.y -o zend_language_parser.c`.
4. `make -j$(nproc)` — incremental, ~30 seconds.
5. `make install-cli install-build install-headers install-programs install-sapi`.
6. PEAR sources transformed via the dictionary (`install-pear-scrambled.sh`).

Scrambling lives **above the lexer**: a new PHP binary recognizing scrambled
keywords is built each time. Opcode VM, AST, and bytecode are untouched.

## 3. Key / seed management

**No exposed key.** The "key" is the dictionary itself — a fresh permutation
generated per build from `crypto/rand`. After scrambling, dictionary written
to `/var/lib/encrypted-execution/token-map.json`
(`dictionaryHandler.go:16, SerializeMap()`).

- The same JSON file is read by every downstream transformer
  (`tools/transformer/transform-php.php`, `tools/scrambler/transform-php.py`,
  `transform-php-file.php`) to rewrite user PHP, PEAR, and WordPress files.
- Dictionary reusable across rebuilds via `--dict=<path>` so multiple
  containers can share a scramble.
- The dictionary is **not required at runtime** to execute scrambled code,
  only to translate fresh code — "the default becomes the secure,
  Polyscripted state" (`polyscripted-wordpress/README.md:170-174`).

## 4. Dictionary format

Flat JSON, original→scrambled:
```json
{ "if":"xKpQmWv", "else":"TnBmqXzP", "function":"gctYobNePm", ";":")" }
```

Consistency is enforced by using the same dictionary as single source of
truth during build. The userland transformer uses PHP's own `token_get_all()`
to tokenize source — guaranteeing the same tokenization rules the
(scrambled) parser applies later (`transform-php.php:117-140`). The Python
transformer is a simpler `\b<keyword>\b` regex fallback.

## 5. Closure problem (third-party libraries)

Anything that runs through the scrambled interpreter must be transformed
with the same dictionary:

- **PEAR/PECL**: `scripts/install-pear-scrambled.sh:39-54` walks
  `/usr/local/lib/php` and `/usr/local/bin`, backs up each `.php`, re-runs
  the transformer per file. Invoked from `recompile-php.sh` after rebuild.
- **WordPress core + plugins/themes**: `scripts/scramble.sh:73` runs
  `s_php tok-php-transformer.php -d scrambled.json -p /var/www/temp --replace`
  against the entire copy.
- **Plugin install lockout**: When polyscripted, WordPress is configured
  `define('DISALLOW_FILE_MODS', true)` so users can't add unscrambled
  plugins through admin (`scramble.sh:59`).
- **Closure must be closed transitively at build time** — anything not
  present and transformed before scrambling cannot execute: "*if you want
  to download plugins or add any php source code to your sites, this needs
  to be done with polyscripting turned off*" (`README.md:176`).

## 6. What breaks if unscrambled PHP runs on a scrambled runtime

The lexer no longer recognizes `if`, `function`, `class` — they become bare
identifiers. Parser fires a **syntax error at parse time**. Untransformed
injected code, uploaded webshells, `eval()` of attacker-controlled strings
fail to parse: "*with Polyscripting a syntax error gets thrown and no
malicious code is run*" (`polyscripted-wordpress/README.md:129`).

Note this is parse-time, not execute-time — defense applies to file
inclusion, `eval`, and most file-upload-then-execute vectors, but
`assert()`-style or dynamically-constructed identifiers that happen to
match scrambled tokens could in theory leak.

## 7. What the scrambler explicitly does NOT touch

- **Magic constants** — preserved.
- **Symbols / operators / brackets** — disabled by default; multi-char
  operators and string-interpolation grammar are too tightly coupled
  (`SYMBOL_SCRAMBLING_ANALYSIS.md`).
- **String literal contents** — `inMatchingQuotes` quote-state machine
  (`scrambler.go:208-246`) ensures replacements happen only inside quoted
  token definitions in `.l`/`.y` files.
- **C code action blocks in lex/yacc files** — context-aware scanning
  means only token-definition lines change; grammar action bodies stay
  intact. The bash scrambler's fatal flaw (`SCRAMBLER_FIX.md:6-22`).
- **Built-in functions, class names, opcodes, the Zend VM, FFI** — only
  the lexer's keyword table changes. `phpinfo()`, `strlen()` still work
  because they're identifiers parsed under `T_STRING`, not reserved keywords.
- **The runtime ABI** — PHP extensions (`.so`) load unchanged.

## 8. Concrete patterns to lift for C/GCC

1. **Modify the grammar source, regenerate the parser, incrementally
   rebuild.** The `.l`/`.y` + re2c/bison + `make -j$(nproc)` pattern maps
   directly to: modify GCC's calling-convention emission in
   `gcc/config/i386/i386.cc`, then `make -j` GCC.

2. **Build seed as a JSON dictionary, written to a well-known path,
   optionally fed back via `--dict=`.** For C/GCC the analog: a build-time
   seed (e.g. `/var/lib/encrypted-linux/abi-map.json`) driving both the
   code generator and any post-processing tool that must understand the
   scrambled ABI. Treat as build artifact, not runtime secret.

3. **Context-aware editing, never naive `sed`.** `SCRAMBLER_FIX.md` is a
   cautionary tale: the original bash `sed` scrambler corrupted action
   blocks. For GCC, calling-convention scrambling done as text rewrites
   against `config/i386/i386-options.cc` will fail similarly. Better:
   parameterize the emission logic so a seed drives runtime choices in
   `ix86_function_arg`, `function_arg_advance`, register-allocation order,
   prologue/epilogue layout.

4. **Magic-constants blacklist analog.** Do not scramble the calling
   convention of functions exposed across an immutable boundary:
   - syscalls (must match kernel ABI),
   - libc symbols crossing a non-scrambled `.so`,
   - `extern "C"` boundaries to assembly,
   - ifunc resolvers,
   - signal handlers,
   - `setjmp`/`longjmp` save areas.

5. **Closure must be closed at build time.** Every object file or static
   lib reaching the scrambled binary needs to be compiled with the same
   seed. Mixing a stock-`glibc.a` with a scrambled binary will crash on
   the first inter-TU call. `DISALLOW_FILE_MODS` is the equivalent of
   forbidding `dlopen()` of unscrambled `.so` files.

6. **Tokenize with the same engine that will execute.** Use `token_get_all()`
   not regex. The GCC analog: rewriting must happen inside GCC's own
   front-end (after `cpp` has run, before code generation), not via
   source-text munging — otherwise macros, `#include` boundaries, and
   `_Generic` produce subtle mismatches.

7. **The seed/dictionary is not a runtime secret.** "*The default becomes
   the secure, Polyscripted state*" — diversity is the defense, not
   concealment. No KDF, HSM, or sealed storage needed; need per-build
   uniqueness and build-time closure.

8. **Fail-closed at parse/load.** PHP's syntax error is "loud" — blocking
   and detectable. C/GCC analog: a loader that refuses to map a `.so`
   whose embedded ABI-seed tag doesn't match the host's. **Stamp the seed
   hash into an ELF note so the dynamic linker can refuse mismatched
   objects** — extends the closure-enforcement pattern. The PHP code does
   not do this; encrypted-linux should.

## Key file references

- `php-v2/tools/scrambler/scrambler.go` — main scrambling loop, context-aware
  line scanning, quote state machine.
- `php-v2/tools/scrambler/dictionaryHandler.go` — keyword regex, magic-constants
  blacklist, dictionary serialization, symbol permutation.
- `php-v2/tools/scrambler/randomizeString.go` — crypto/rand token generation.
- `php-v2/scripts/recompile-php.sh` — re2c + bison + incremental make.
- `php-v2/scripts/install-pear-scrambled.sh` — closure enforcement for PEAR.
- `php-v2/tools/transformer/transform-php.php` — `token_get_all()` userland
  transformer.
- `php-v2/SCRAMBLER_FIX.md` — why naive `sed` failed.
- `php/SYMBOL_SCRAMBLING_ANALYSIS.md` — failure analysis of operator scrambling.
- `polyscripted-wordpress/scripts/scramble.sh` — temp-dir scramble + atomic swap.
- `polyscripted-wordpress/scripts/docker-entrypoint.sh` — closure enforcement.
- `polyscripted-wordpress/scripts/dispatch.sh` — "merge mode" re-scrambling.
