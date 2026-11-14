#!/usr/bin/env bash
# Binary smoke test: exercises every command and the documented exit codes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/bridge-gate"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_exit() {
  local expected="$1"
  shift
  local output status
  output="$("$@" 2>&1)" && status=0 || status=$?
  if [ "$status" -ne "$expected" ]; then
    printf '%s\n' "$output" >&2
    fail "expected exit $expected, got $status: $*"
  fi
}

[ -x "$BIN" ] || fail "missing executable $BIN (run make build)"

# --help must reach the application. Without :save-runtime-options the saved
# SBCL runtime prints its own help and still exits 0, which is a false pass.
if ! help_output="$("$BIN" --help)"; then
  fail "--help failed"
fi
case "$help_output" in
  *"Usage: bridge-gate"*) ;;
  *) fail "--help did not print bridge-gate usage" ;;
esac
case "$help_output" in
  *"Usage: sbcl"*) fail "--help was intercepted by the SBCL runtime" ;;
esac
expect_exit 0 "$BIN" --help
[ "$help_output" = "$("$BIN" -h)" ] || fail "-h and --help output differ"

expect_exit 2 "$BIN"
expect_exit 2 "$BIN" no-such-command
expect_exit 2 "$BIN" --no-such-option
expect_exit 2 "$BIN" tenable-scan --mock
expect_exit 2 "$BIN" enforce-gate --policy "$WORK/no-policy.edn" --input "$WORK/missing.json"

cred="$("$BIN" cyberark-auth --mock)"
case "$cred" in
  *'"username": "svc-deploy"'*) ;;
  *) fail "cyberark-auth --mock did not return the mock credential" ;;
esac
[ "$cred" = "$("$BIN" cyberark-auth --mock)" ] \
  || fail "cyberark-auth --mock output is not deterministic"

scan_out="$WORK/findings.json"
scan_json="$("$BIN" tenable-scan --target 10.10.50.12 --mock --out "$scan_out")"
[ -f "$scan_out" ] || fail "tenable-scan did not write $scan_out"
case "$scan_json" in
  *'"total": 6'*) ;;
  *) fail "tenable-scan summary did not report 6 findings" ;;
esac
[ "$scan_json" = "$("$BIN" tenable-scan --target 10.10.50.12 --mock --out "$scan_out")" ] \
  || fail "tenable-scan --mock output is not deterministic"

report="$WORK/block.json"
expect_exit 1 "$BIN" enforce-gate --input "$scan_out" --report "$report"
[ -f "$report" ] || fail "enforce-gate did not write $report"
grep -q '"event": "bridge-gate.policy-violation"' "$report" \
  || fail "block payload missing event"

clean="$WORK/clean.json"
cat > "$clean" <<'JSON'
{"target":"10.0.0.1","findings":[{"host":"10.0.0.1","plugin-id":"10180","severity":"info"}]}
JSON
clean_out="$("$BIN" enforce-gate --input "$clean")"
case "$clean_out" in
  *'"gate": "PASS"'*) ;;
  *) fail "clean findings did not report a PASS gate" ;;
esac
[ "$clean_out" = "$("$BIN" enforce-gate --input "$clean")" ] \
  || fail "enforce-gate PASS output is not deterministic"

expect_exit 2 "$BIN" enforce-gate --input "$WORK/missing.json"

printf 'OK: bridge-gate binary smoke test passed\n'
