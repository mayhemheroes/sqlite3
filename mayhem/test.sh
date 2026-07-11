#!/usr/bin/env bash
#
# sqlite3/mayhem/test.sh — RUN a self-contained SQLite oracle and emit a CTRF summary.
# exit 0 iff every test passed.
#
# PRIMARY oracle (real, byte-exact, additive): the project's own `fuzzcheck` tool (built by
# mayhem/build.sh) replays SQLite's shipped regression corpora test/fuzzdata1..8.db through the
# full SQL/dbsql fuzz pipeline (parser + VDBE + recover/dbpage + the registered extensions) and
# asserts NO crash/abort across thousands of stored cases. This is SQLite's actual upstream
# `make fuzztest` oracle — a no-op/exit(0) patch to the engine cannot pass it.
#
# SECONDARY oracle (golden known-answer): a tiny set of SQL statements run through the sanitizer-
# free sqlite3 shell whose printed results are compared against hard-coded expected output. This
# guards the common front-end + arithmetic + aggregate path even if fuzzcheck is unavailable.
#
# This script only RUNS pre-built binaries; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

BUILD="$SRC/mayhem-build"
FUZZCHECK="$BUILD/fuzzcheck"
SHELL_BIN="$BUILD/sqlite3-shell"

# emit_ctrf <tool> <passed> <failed> [skipped]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}"
  local tests=$(( passed + failed + skipped ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": 0,
      "skipped": $skipped,
      "other": 0
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":0,"skipped":%d,"other":0}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$skipped"
  [ "$failed" -eq 0 ]
}

PASS=0; FAIL=0; SKIP=0

# ── 1) fuzzcheck over the shipped fuzzdata corpora (one logical test per corpus DB) ───────────────
if [ -x "$FUZZCHECK" ]; then
  for db in "$SRC"/test/fuzzdata1.db "$SRC"/test/fuzzdata2.db "$SRC"/test/fuzzdata3.db \
            "$SRC"/test/fuzzdata4.db "$SRC"/test/fuzzdata5.db "$SRC"/test/fuzzdata6.db \
            "$SRC"/test/fuzzdata7.db "$SRC"/test/fuzzdata8.db; do
    [ -f "$db" ] || { SKIP=$((SKIP+1)); continue; }
    echo "=== fuzzcheck $(basename "$db") ==="
    if "$FUZZCHECK" --limit-mem 100M "$db" >/tmp/fc.out 2>&1; then
      echo "  PASS $(basename "$db")"; PASS=$((PASS+1))
    else
      echo "  FAIL $(basename "$db")"; tail -8 /tmp/fc.out | sed 's/^/    /'; FAIL=$((FAIL+1))
    fi
  done
else
  echo "fuzzcheck not built — primary oracle unavailable" >&2
  FAIL=$((FAIL+1))
fi

# ── 2) golden known-answer SQL via the sqlite3 shell ──────────────────────────────────────────────
if [ -x "$SHELL_BIN" ]; then
  echo "=== golden SQL oracle (sqlite3 shell) ==="
  # known-answer pairs: "<sql>|<expected-output>"
  run_golden() {
    local sql="$1" want="$2" got
    got="$(printf '%s\n' "$sql" | "$SHELL_BIN" :memory: 2>/dev/null)"
    if [ "$got" = "$want" ]; then echo "  PASS [$sql] -> $got"; PASS=$((PASS+1))
    else echo "  FAIL [$sql] want='$want' got='$got'"; FAIL=$((FAIL+1)); fi
  }
  run_golden "SELECT 1+2;" "3"
  run_golden "SELECT hex(zeroblob(3));" "000000"
  run_golden "CREATE TABLE t(a); INSERT INTO t VALUES(1),(2),(3),(4); SELECT sum(a),count(*),avg(a) FROM t;" "10|4|2.5"
  run_golden "SELECT upper('abc')||lower('XYZ');" "ABCxyz"
  run_golden "WITH RECURSIVE c(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM c WHERE n<5) SELECT group_concat(n,',') FROM c;" "1,2,3,4,5"
  run_golden "SELECT typeof(1), typeof(1.0), typeof('x'), typeof(NULL);" "integer|real|text|null"
else
  echo "sqlite3 shell not built — golden oracle skipped" >&2
  SKIP=$((SKIP+1))
fi

emit_ctrf "sqlite3-oracle" "$PASS" "$FAIL" "$SKIP"
