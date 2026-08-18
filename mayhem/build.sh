#!/usr/bin/env bash
#
# goawk/mayhem/build.sh — build two libFuzzer targets over the AWK interpreter
# plus the project's KAT probe.
#
# Targets produced (one Mayhemfile each):
#   /mayhem/fuzz_source — FuzzMayhemSource: parse+interpret an untrusted AWK
#                         PROGRAM (lexer/parser/resolver/interpreter surface).
#   /mayhem/fuzz_input  — FuzzMayhemInput:  run a FIXED, known-good AWK
#                         program over untrusted INPUT DATA (record/field
#                         splitting + number parsing surface).
#   /mayhem/kat         — dynamically-linked known-answer probe used by
#                         mayhem/test.sh.
#
# Upstream is NOT an OSS-Fuzz project; it ships two native Go fuzz targets
# (FuzzSource, FuzzInput in interp/fuzz_test.go) that are ALREADY file-I/O
# free (their seed corpus comes from an in-memory Go slice, not a file read)
# and already bound execution via interp.Config{NoExec,NoFileWrites,
# NoFileReads} + a context timeout. We still build our OWN harnesses
# (mayhem/harness_*_test.go.src) with the same shape rather than pointing
# go-118-fuzz-build straight at FuzzSource/FuzzInput, for TWO reasons: (1) it
# keeps this integration independent of any future edit to fuzz_test.go, and
# (2, load-bearing) upstream's interp/ directory mixes internal-test files
# (package interp) and external-test files (package interp_test), which
# go-118-fuzz-build's package loader cannot build ("found packages interp
# ... and interp_test ... in /mayhem/interp") regardless of which Fuzz
# function is targeted. So our harnesses are copied into their OWN fresh
# per-target directories under mayhem-build/ instead of into interp/ — see
# the comment blocks in harness_*_test.go.src for the full story.
#
# Go path is ASan-only for the libFuzzer link (as OSS-Fuzz's Go path is): the
# .a archive carries the Go fuzz code instrumented by go-118-fuzz-build, then
# clang++ links it against the libFuzzer engine.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 with no
# downgrade knob. The C/CGO shims clang compiles (the LLVMFuzzerTestOneInput
# wrapper, the CGO bridge) default to DWARF5 under clang-19, so we force them
# — and the final link — to DWARF3 via $GO_DEBUG_FLAGS. verify-repo reads the
# FIRST CU's DWARF version, which is the C shim at DWARF3, satisfying the < 4
# gate.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs this script
# OFFLINE. This first (online) build populates $GOMODCACHE under
# /opt/toolchains; the cache doubles as a file proxy, which GOPROXY prefers,
# so the offline re-run resolves from it. Re-running on an already-built tree
# must succeed (idempotent).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# ASan-only for the Go libFuzzer link. An explicit empty --build-arg SANITIZER_FLAGS=
# yields a no-sanitizer (natural-crash) build, so default with `=` not `:=`.
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS

# DWARF3 for every clang-compiled shim + the final link (see header).
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Offline-first module resolution. $(go env GOMODCACHE) reads the pinned ENV
# from the Dockerfile, so this path is right under ANY $HOME (CI or the PATCH
# re-run).
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

cd "$SRC"
go version

# go-118-fuzz-build rewrites the stdlib `testing` import to its own shim,
# which must be on the module graph. Order matters: tidy FIRST, then `go get`
# the shim — a trailing tidy would prune it again (nothing imports it until
# the builder generates the entrypoint). Both resolve from the module cache
# when offline.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build/fuzz_source" "$SRC/mayhem-build/fuzz_input"

# The harnesses ship as .go.src so they are never compiled as ordinary
# package files; copy each into its OWN fresh package directory (NOT
# interp/ — see the header comment) as a real _test.go file for the builder.
# Idempotent (cp -f).
cp -f "$SRC/mayhem/harness_source_test.go.src" "$SRC/mayhem-build/fuzz_source/harness_test.go"
cp -f "$SRC/mayhem/harness_input_test.go.src"  "$SRC/mayhem-build/fuzz_input/harness_test.go"

# build_target <output-name> <fuzz-func> <package-dir>
build_target() {
  local target="$1" func="$2" pkgdir="$3"
  echo "=== building $target ($func, go-118-fuzz-build) ==="
  go-118-fuzz-build -o "$SRC/mayhem-build/$target.a" -func "$func" "$pkgdir"
  # shellcheck disable=SC2086  # word-splitting of the flag lists is intended
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS \
      "$SRC/mayhem-build/$target.a" -o "/mayhem/$target"
  echo "built /mayhem/$target"
}

build_target fuzz_source FuzzMayhemSource "$SRC/mayhem-build/fuzz_source"
build_target fuzz_input  FuzzMayhemInput  "$SRC/mayhem-build/fuzz_input"

# ── The KAT probe used by mayhem/test.sh (NORMAL flags — it is a functional
#    oracle, not a triage artifact, so no sanitizer/fuzz instrumentation
#    here). ───────────────────────────────────────────────────────────────
# CGO_ENABLED=1 + the `import "C"` file force EXTERNAL linking so the probe
# is DYNAMICALLY linked and therefore reachable by verify-repo's LD_PRELOAD
# sabotage shim (SPEC §6.3). Assert that, so a toolchain change can't
# silently turn the probe static and weaken the oracle to a `go test`-only
# pass.
echo "=== building /mayhem/kat (KAT probe, cgo => dynamically linked) ==="
CGO_ENABLED=1 CGO_CFLAGS="$GO_DEBUG_FLAGS" go build -o /mayhem/kat ./mayhem/kat
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi
echo "built /mayhem/kat (dynamically linked)"

# Go's `go test` compiles on demand, so there is no separate test-suite build
# step; mayhem/test.sh runs `go test ./...` with the project's normal flags.

echo "build.sh complete:"
ls -la /mayhem/fuzz_source /mayhem/fuzz_input /mayhem/kat
