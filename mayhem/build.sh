#!/usr/bin/env bash
#
# sqlite3/mayhem/build.sh — build SQLite's OSS-Fuzz `ossfuzz` harness as a sanitized libFuzzer
# target (+ a standalone reproducer), AND the `fuzzcheck` test tool used by mayhem/test.sh.
#
# The fuzzed surface is SQLite's SQL front end + VDBE: test/ossfuzz.c (LLVMFuzzerTestOneInput)
# takes a one-byte selector (when input[1]=='\n') controlling FK enforcement + an output-row cap,
# then runs the REST OF THE INPUT AS SQL via sqlite3_exec() against an in-memory database. So the
# harness exercises the tokenizer, parser, code generator, the VDBE bytecode engine, the query
# planner, built-in functions and the in-memory pager/btree — a premier SQL parser/engine target.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We build the sqlite3 amalgamation WITH $SANITIZER_FLAGS so the engine
# itself (not just the thin harness) is instrumented, exactly as OSS-Fuzz does, and replicate the
# OSS-Fuzz -DSQLITE_ defines that bound input/memory/page sizes (avoids irrelevant OOM/timeouts).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: -gdwarf-3 overrides clang-19's default DWARF-5 so Mayhem triage can read the symbols.
# Placed AFTER $SANITIZER_FLAGS in every compile so it wins over any -g/-gdwarf-N already in there.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# OSS-Fuzz disables leak detection at runtime (sqlite intentionally leaks on some error paths). We
# bake the same default into the binary via a weak __asan_default_options so it survives without a
# Mayhemfile ASAN_OPTIONS override (Mayhem owns the runtime ASAN_OPTIONS set).
ASAN_OPT_SRC="$SRC/mayhem-build/asan_default_options.c"

# OSS-Fuzz CFLAGS additions (test/build.sh): bound input/SQL/memory/page sizes so the fuzzer does
# not chase irrelevant OOM/timeouts; SQLITE_DEBUG=1 turns on the engine's internal assert()s
# (extra invariant checks = a richer oracle for the sanitizers).
SQLITE_DEFS="-DSQLITE_MAX_LENGTH=128000000 \
  -DSQLITE_MAX_SQL_LENGTH=128000000 \
  -DSQLITE_MAX_MEMORY=25000000 \
  -DSQLITE_PRINTF_PRECISION_LIMIT=1048576 \
  -DSQLITE_DEBUG=1 \
  -DSQLITE_MAX_PAGE_COUNT=16384"

BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"

# ── 1) Generate the sqlite3 amalgamation (sqlite3.c / sqlite3.h) exactly as OSS-Fuzz does ──────────
#    configure --shared=0 then `make sqlite3.c`. This needs tclsh (installed in the Dockerfile).
( cd "$BUILD" && "$SRC/configure" --shared=0 >/dev/null && make -j"$MAYHEM_JOBS" sqlite3.c >/dev/null )
test -f "$BUILD/sqlite3.c"

# ── 2) Compile the amalgamation WITH sanitizers + the OSS-Fuzz defines ─────────────────────────────
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $SQLITE_DEFS -I"$BUILD" -c "$BUILD/sqlite3.c" -o "$BUILD/sqlite3.o"

cat > "$ASAN_OPT_SRC" <<'EOF'
/* Weak default so Mayhem's runtime ASAN_OPTIONS still wins, but absent any override we match
   OSS-Fuzz (sqlite intentionally leaks on some error paths). */
__attribute__((weak)) const char *__asan_default_options(void) {
  return "detect_leaks=0";
}
EOF
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$ASAN_OPT_SRC" -o "$BUILD/asan_default_options.o"

# ── 3) Build the `ossfuzz` harness twice: libFuzzer target + standalone reproducer ────────────────
# libFuzzer target -> /mayhem/ossfuzz
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $SQLITE_DEFS -I"$BUILD" \
    "$SRC/test/ossfuzz.c" "$BUILD/sqlite3.o" "$BUILD/asan_default_options.o" \
    $LIB_FUZZING_ENGINE -o "/mayhem/ossfuzz"

# standalone reproducer (no libFuzzer runtime; reads one input file) -> /mayhem/ossfuzz-standalone
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $SQLITE_DEFS -I"$BUILD" \
    "$SRC/test/ossfuzz.c" "$STANDALONE_FUZZ_MAIN" "$BUILD/sqlite3.o" "$BUILD/asan_default_options.o" \
    -o "/mayhem/ossfuzz-standalone"

echo "built ossfuzz (+ standalone)"

# ── 4) Build the `fuzzcheck` known-answer test tool for mayhem/test.sh ─────────────────────────────
# fuzzcheck replays sqlite's own test/fuzzdata*.db corpora through the SQL/dbsql fuzz logic and
# asserts no crash/abort — a real, self-contained functional oracle. We build it via the project's
# own Makefile target (FUZZCHECK_SRC/FUZZCHECK_OPT pull in ~20 sources + ~30 defines; let the build
# system own that list) with NORMAL flags — env -u CFLAGS/CXXFLAGS/SANITIZER_FLAGS so the oracle is
# not perturbed by the fuzz sanitizers and stays an honest PATCH oracle.
( cd "$BUILD" && env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    make -j"$MAYHEM_JOBS" fuzzcheck >/dev/null 2>&1 ) \
  && cp -f "$BUILD/fuzzcheck" "$BUILD/fuzzcheck" \
  || echo "WARNING: fuzzcheck build failed — test.sh will report the failure loudly" >&2

# Build the sqlite3 shell (sanitizer-free) via make as a secondary golden oracle for test.sh.
( cd "$BUILD" && env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    make -j"$MAYHEM_JOBS" sqlite3 >/dev/null 2>&1 ) \
  && cp -f "$BUILD/sqlite3" "$BUILD/sqlite3-shell" 2>/dev/null \
  || echo "WARNING: sqlite3 shell build skipped" >&2

echo "build.sh complete:"
ls -la /mayhem/ossfuzz /mayhem/ossfuzz-standalone "$BUILD/fuzzcheck" "$BUILD/sqlite3-shell" 2>&1 || true
