// mayhem/kat — known-answer-test probe for mayhem/test.sh.
//
// WHY A SEPARATE BINARY (SPEC §6.3 anti-reward-hacking):
// `go test` links a STATIC binary, so the verify-repo sabotage check (which
// LD_PRELOADs a shim whose constructor calls _exit(0) for non-system
// executables) cannot neuter it — a suite that only runs `go test` is immune
// to the sabotage check and does NOT prove the oracle is behavioral. This
// probe is built with cgo (see cgo_dynamic.go) so it is DYNAMICALLY linked:
// the shim reaches it, the process becomes an instant no-op, it prints
// nothing, and test.sh's exact string assertions fail. That is what makes
// the oracle sabotage-detecting.
//
// It is also a real KAT, not a liveness check: it runs three fixed AWK
// programs over fixed input through the SAME public interp/parser API the
// fuzz harnesses use, and asserts the exact computed output — arithmetic +
// printf formatting, a column-sum accumulator, and CSV-style field
// splitting via a custom FS. A patch that stubs the interpreter to "fix" a
// crash (e.g. make Execute always return empty output) cannot produce these
// values, so it fails the oracle.
//
// Usage: kat   (no args; all inputs are fixed literals baked into this file)
// Prints three lines, which test.sh matches EXACTLY:
//
//	KAT_ARITH=<result of BEGIN{printf "%.3f", 22/7}>
//	KAT_SUM=<result of summing column 2 over 3 fixed records>
//	KAT_CSV_FIELD=<result of field-splitting on FS="," and printing field 2>
package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/benhoyt/goawk/interp"
	"github.com/benhoyt/goawk/parser"
)

// runAWK parses and executes a fixed AWK program over fixed stdin, returning
// its stdout. NORMAL (non-sanitized, non-fuzz) build — this is a functional
// oracle, not a triage artifact.
func runAWK(src, stdin string) (string, error) {
	prog, err := parser.ParseProgram([]byte(src), nil)
	if err != nil {
		return "", fmt.Errorf("parse: %w", err)
	}
	interpreter, err := interp.New(prog)
	if err != nil {
		return "", fmt.Errorf("interp.New: %w", err)
	}
	var out bytes.Buffer
	config := &interp.Config{
		Stdin:  strings.NewReader(stdin),
		Output: &out,
		Error:  io.Discard,
	}
	if _, err := interpreter.Execute(config); err != nil {
		return "", fmt.Errorf("execute: %w", err)
	}
	return out.String(), nil
}

func main() {
	// 1) arithmetic + printf formatting (no input).
	arith, err := runAWK(`BEGIN { printf "%.3f", 22/7 }`, "")
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: arith: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("KAT_ARITH=%s\n", strings.TrimSpace(arith))

	// 2) field splitting (default FS) + a column-sum accumulator.
	sum, err := runAWK(`{ total += $2 } END { print total }`, "a 10\nb 20\nc 12\n")
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: sum: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("KAT_SUM=%s\n", strings.TrimSpace(sum))

	// 3) CSV-style field splitting via a custom FS.
	field, err := runAWK(`BEGIN { FS = "," } NR == 1 { print $2 }`, "Bob,42\nJill,37\n")
	if err != nil {
		fmt.Fprintf(os.Stderr, "kat: csv field: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("KAT_CSV_FIELD=%s\n", strings.TrimSpace(field))
}
