#!/usr/bin/env bash
#
# goawk/mayhem/test.sh — RUN the project's own Go test suite and a
# known-answer probe, and emit a CTRF summary. exit 0 iff nothing failed.
#
# PATCH-grade oracle (SPEC §6.3). Two parts, and the SECOND is the
# load-bearing one:
#
#  1) `go test ./...` — upstream's suite (interp_test.go's interpTests table,
#     lexer/parser tests, etc.) is a genuine known-answer suite: fixed AWK
#     programs + fixed input feed an expected exact output string, asserted
#     with string/DeepEqual comparisons. So it asserts BEHAVIOUR, not "exits
#     0".
#
#  2) The KAT probe /mayhem/kat — because `go test` links a STATIC binary,
#     the verify-repo sabotage check (LD_PRELOAD a shim whose constructor
#     _exit(0)s every non-system executable) CANNOT neuter it. A
#     `go test`-only oracle therefore survives sabotage while proving
#     nothing, which is exactly the reward-hackable case the spec forbids.
#     /mayhem/kat is built with cgo => DYNAMICALLY linked, so the shim does
#     neuter it; it then prints nothing and the exact-match assertions below
#     fail. The probe asserts three VALUES computed by three fixed AWK
#     programs run through the same public interp/parser API the fuzz
#     harnesses use (printf/arithmetic formatting, a column-sum accumulator,
#     and FS-based field splitting), so a patch that stubs the interpreter to
#     stop a crash cannot satisfy it either.
#
# This script only RUNS things; mayhem/build.sh did the building.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PASSED=0; FAILED=0; SKIPPED=0

# ── 1) the project's own Go suite ───────────────────────────────────────────
if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 2
fi

echo "=== running: go test -json ./... ==="
mkdir -p "$SRC/mayhem-build"
JSON="$SRC/mayhem-build/gotest.json"
go test -json ./... > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?
go test ./... 2>&1 | tail -30 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events only (lines carrying a non-empty "Test" field);
# package-level pass/fail lines have no "Test" field. Subtests count — they
# are real asserted cases.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "FAIL: no test events parsed — the suite did not run (go exit $rc)" >&2
  emit_ctrf "go-test+kat" 0 1 0; exit 1
fi
# A non-zero go exit with zero counted failures means a build/vet error: stay honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=$(( FAILED + 1 )); fi

# ── 2) the KAT probe (sabotage-detecting; see header) ───────────────────────
# UNCONDITIONAL by design: a missing binary is a FAILURE, never a skip. A
# `[ -f ... ]` guard here is how a probe silently stops running and the
# oracle quietly degrades to the go-test-only (reward-hackable) case. All
# three of this probe's inputs are literals baked into mayhem/kat/main.go, so
# there is no fixture to go missing.
echo "=== KAT probe: /mayhem/kat (dynamically linked; asserts parsed VALUES) ==="
KAT_OUT="$(/mayhem/kat 2>&1)"; kat_rc=$?
echo "$KAT_OUT"

# Expected values, computed directly from the fixed AWK source in
# mayhem/kat/main.go:
#   BEGIN{printf "%.3f", 22/7}                              -> 3.143
#   {total+=$2} END{print total}  over "a 10\nb 20\nc 12\n"  -> 42
#   BEGIN{FS=","} NR==1{print $2} over "Bob,42\nJill,37\n"   -> 42
kat_expect() {
  local label="$1" line="$2"
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    echo "KAT PASS: $label"
    PASSED=$(( PASSED + 1 ))
  else
    echo "KAT FAIL: $label — expected exact line: $line" >&2
    FAILED=$(( FAILED + 1 ))
  fi
}

if [ "$kat_rc" -ne 0 ]; then
  echo "KAT FAIL: /mayhem/kat exited $kat_rc (neutered, missing, or interpreter broken)" >&2
  FAILED=$(( FAILED + 1 ))
fi
kat_expect "arithmetic + printf formatting (22/7)" 'KAT_ARITH=3.143'
kat_expect "field splitting + column-sum accumulator" 'KAT_SUM=42'
kat_expect "CSV-style field splitting via custom FS" 'KAT_CSV_FIELD=42'

emit_ctrf "go-test+kat" "$PASSED" "$FAILED" "$SKIPPED"
