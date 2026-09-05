#!/bin/zsh
set -euo pipefail

scenario=""
expected_samples=""
report=""
smoke=0

usage() {
  print -u2 "Usage: $0 --scenario cachedIndexed|uncachedIndexed|uncachedNoIndex --samples COUNT --report PATH [--smoke]"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --scenario)
      (( $# >= 2 )) || usage
      scenario="$2"
      shift 2
      ;;
    --samples)
      (( $# >= 2 )) || usage
      expected_samples="$2"
      shift 2
      ;;
    --report)
      (( $# >= 2 )) || usage
      report="$2"
      shift 2
      ;;
    --smoke)
      smoke=1
      shift
      ;;
    *) usage ;;
  esac
done

case "$scenario" in
  cachedIndexed|uncachedIndexed|uncachedNoIndex) ;;
  *) usage ;;
esac
[[ "$expected_samples" =~ '^[1-9][0-9]*$' && "$expected_samples" -le 50 ]] || usage
[[ -f "$report" && ! -L "$report" && -s "$report" ]] || usage
report_size="$(/usr/bin/stat -f '%z' "$report")"
[[ "$report_size" =~ '^[0-9]+$' && "$report_size" -le 1048576 ]] || {
  print -u2 "Startup performance report exceeds the 1 MiB aggregate-report limit"
  exit 1
}
if (( smoke == 0 && expected_samples < 20 )); then
  print -u2 "A release performance gate requires at least 20 samples; use --smoke for plumbing checks"
  exit 1
fi

scalar() {
  local key="$1"
  awk -v key="$key" '
    { split($1, pair, "=") }
    pair[1] == key { count += 1; value = pair[2] }
    END { if (count != 1) exit 1; print value }
  ' "$report"
}

field() {
  local line_key="$1"
  local field_key="$2"
  awk -v line_key="$line_key" -v field_key="$field_key" '
    index($1, line_key ".") == 1 || index($1, line_key "=") == 1 {
      lines += 1
      for (i = 1; i <= NF; i += 1) {
        split($i, pair, "=")
        if (pair[1] == field_key || pair[1] == line_key "." field_key) {
          values += 1
          value = pair[2]
        }
      }
    }
    END { if (lines != 1 || values != 1) exit 1; print value }
  ' "$report"
}

require_scalar() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(scalar "$key")" || { print -u2 "Missing or duplicate report key: $key"; exit 1; }
  [[ "$actual" == "$expected" ]] || { print -u2 "Unexpected $key: $actual (expected $expected)"; exit 1; }
}

require_field() {
  local line_key="$1"
  local field_key="$2"
  local expected="$3"
  local actual
  actual="$(field "$line_key" "$field_key")" || { print -u2 "Missing or duplicate report field: $line_key.$field_key"; exit 1; }
  [[ "$actual" == "$expected" ]] || { print -u2 "Unexpected $line_key.$field_key: $actual (expected $expected)"; exit 1; }
}

require_threshold() {
  local line_key="$1"
  local field_key="$2"
  local maximum="$3"
  local actual
  actual="$(field "$line_key" "$field_key")" || { print -u2 "Missing or duplicate report field: $line_key.$field_key"; exit 1; }
  awk -v value="$actual" -v maximum="$maximum" 'BEGIN {
    if (value !~ /^[0-9]+([.][0-9]+)?$/ || value + 0 > maximum + 0) exit 1
  }' || { print -u2 "$line_key.$field_key exceeded ${maximum}ms: $actual"; exit 1; }
}

require_scalar scenario "$scenario"
require_scalar valid_samples "$expected_samples"
require_scalar invalid_metric_files 0
require_scalar duplicate_process_samples 0
require_scalar failure_samples 0
require_scalar unsupported_samples 0
require_field marker.root_appeared present_samples "$expected_samples"
require_field marker.root_appeared missing_samples 0
require_field process_to_root present_samples "$expected_samples"
require_field process_to_root missing_bridge 0
require_field process_to_root missing_marker 0

case "$scenario" in
  cachedIndexed)
    require_scalar cache_hits "$expected_samples"
    require_field marker.cache_visible present_samples "$expected_samples"
    require_field process_to_cache present_samples "$expected_samples"
    require_field process_to_cache missing_bridge 0
    require_field process_to_cache missing_marker 0
    require_field cached_zero_aggregation_gate observer_ready "$expected_samples"
    require_field cached_zero_aggregation_gate unverifiable_samples 0
    require_field cached_zero_aggregation_gate violating_samples 0
    require_threshold process_to_cache p95_ms 700
    threshold="process_to_cache.p95_ms<=700"
    ;;
  uncachedIndexed)
    require_scalar cache_hits 0
    require_field marker.startup_ready present_samples "$expected_samples"
    require_field process_to_startup_ready present_samples "$expected_samples"
    require_field process_to_startup_ready missing_bridge 0
    require_field process_to_startup_ready missing_marker 0
    require_threshold process_to_startup_ready p95_ms 1800
    threshold="process_to_startup_ready.p95_ms<=1800"
    ;;
  uncachedNoIndex)
    require_scalar cache_hits 0
    require_threshold process_to_root p95_ms 1800
    threshold="process_to_root.p95_ms<=1800"
    ;;
esac

print "Startup performance report passed: scenario=$scenario samples=$expected_samples mode=$([[ $smoke == 1 ]] && print smoke || print release-gate) threshold=$threshold"
