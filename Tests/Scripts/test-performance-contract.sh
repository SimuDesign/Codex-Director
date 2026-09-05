#!/bin/zsh
set -euo pipefail

source_root="$(cd "$(dirname "$0")/../.." && pwd)"
runner="$source_root/scripts/run-startup-performance.sh"
verifier="$source_root/scripts/verify-startup-performance-report.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-director-performance-contract.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT INT TERM

pass_count=0

expect_pass() {
  local name="$1"
  shift
  if ! output="$("$@" 2>&1)"; then
    print -u2 "FAIL: $name should pass"
    print -u2 "$output"
    exit 1
  fi
  (( pass_count += 1 ))
}

expect_failure() {
  local name="$1"
  shift
  if output="$("$@" 2>&1)"; then
    print -u2 "FAIL: $name should fail"
    exit 1
  fi
  (( pass_count += 1 ))
}

[[ -x "$runner" && -x "$verifier" ]] || {
  print -u2 "FAIL: performance runner and verifier must be executable"
  exit 1
}

make_report() {
  local output_file="$1"
  local scenario="$2"
  local samples="$3"
  local p95="$4"
  local cache_hits="$5"
  local zero_gate="${6:-not_applicable}"
  cat > "$output_file" <<EOF
scenario=$scenario
valid_samples=$samples
invalid_metric_files=0
duplicate_process_samples=0
failure_samples=0
unsupported_samples=0
marker.root_appeared.present_samples=$samples missing_samples=0 median_ms=100.000 p95_ms=120.000 max_ms=130.000
marker.cache_visible.present_samples=$cache_hits missing_samples=$(( samples - cache_hits )) median_ms=300.000 p95_ms=$p95 max_ms=$p95
marker.startup_ready.present_samples=$samples missing_samples=0 median_ms=500.000 p95_ms=$p95 max_ms=$p95
process_to_root.present_samples=$samples missing_bridge=0 missing_marker=0 median_ms=120.000 p95_ms=140.000 max_ms=150.000
process_to_cache.present_samples=$cache_hits missing_bridge=0 missing_marker=$(( samples - cache_hits )) median_ms=320.000 p95_ms=$p95 max_ms=$p95
process_to_startup_ready.present_samples=$samples missing_bridge=0 missing_marker=0 median_ms=520.000 p95_ms=$p95 max_ms=$p95
cache_hits=$cache_hits cache_misses_or_unobserved=$(( samples - cache_hits ))
cached_zero_aggregation_gate=$zero_gate observer_ready=$samples unverifiable_samples=0 violating_samples=0
EOF
}

cached="$test_root/cached.txt"
make_report "$cached" cachedIndexed 20 650.000 20 all_given_valid_samples
expect_pass "cached threshold" "$verifier" --scenario cachedIndexed --samples 20 --report "$cached"

uncached="$test_root/uncached.txt"
make_report "$uncached" uncachedIndexed 20 1700.000 0
expect_pass "uncached indexed threshold" "$verifier" --scenario uncachedIndexed --samples 20 --report "$uncached"

no_index="$test_root/no-index.txt"
make_report "$no_index" uncachedNoIndex 20 1700.000 0
expect_pass "uncached no-index threshold" "$verifier" --scenario uncachedNoIndex --samples 20 --report "$no_index"

slow="$test_root/slow.txt"
make_report "$slow" cachedIndexed 20 701.000 20 all_given_valid_samples
expect_failure "cached p95 over threshold" "$verifier" --scenario cachedIndexed --samples 20 --report "$slow"

short="$test_root/short.txt"
make_report "$short" cachedIndexed 19 650.000 19 all_given_valid_samples
expect_failure "missing sample" "$verifier" --scenario cachedIndexed --samples 20 --report "$short"

failed="$test_root/failed.txt"
make_report "$failed" uncachedIndexed 20 1700.000 0
sed -i '' 's/failure_samples=0/failure_samples=1/' "$failed"
expect_failure "failed launch" "$verifier" --scenario uncachedIndexed --samples 20 --report "$failed"

violating="$test_root/violating.txt"
make_report "$violating" cachedIndexed 20 650.000 20 all_given_valid_samples
sed -i '' 's/violating_samples=0/violating_samples=1/' "$violating"
expect_failure "cached aggregation regression" "$verifier" --scenario cachedIndexed --samples 20 --report "$violating"

oversized="$test_root/oversized.txt"
make_report "$oversized" uncachedNoIndex 20 1700.000 0
/bin/dd if=/dev/zero bs=1048576 count=1 >> "$oversized" 2>/dev/null
expect_failure "oversized aggregate report" "$verifier" --scenario uncachedNoIndex --samples 20 --report "$oversized"

rg -q 'CODEX_DIRECTOR_PERF_AUTO_QUIT=1' "$runner" || { print -u2 "FAIL: runner does not require harness auto-quit"; exit 1; }
rg -q 'prepare-startup-perf-fixture\.sh.*--preflight' "$runner" || { print -u2 "FAIL: runner omits fixture preflight"; exit 1; }
rg -q 'summarize-startup-metrics\.swift' "$runner" || { print -u2 "FAIL: runner omits aggregate summarizer"; exit 1; }
rg -q 'source_tree_state=dirty' "$runner" || { print -u2 "FAIL: runner does not disclose dirty source state"; exit 1; }
rg -q 'sample_count >= 20' "$runner" || { print -u2 "FAIL: runner does not protect release evidence from dirty trees"; exit 1; }
if rg -q '\$HOME|\$CODEX_HOME|NSHomeDirectory|Application Support' "$runner" "$verifier"; then
  print -u2 "FAIL: performance scripts may not derive production data paths"
  exit 1
fi
(( pass_count += 6 ))

print "Performance contract tests passed: $pass_count"
