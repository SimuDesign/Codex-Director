#!/bin/zsh
set -euo pipefail

source_root="$(cd "$(dirname "$0")/../.." && pwd)"
reader="$source_root/scripts/read-project-version.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-director-version-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT INT TERM

pass_count=0

write_valid_project() {
  local target="$1"
  local marketing="${2:-1.2.3}"
  local build="${3:-45}"
  local minimum="${4:-26.0}"
  cat > "$target" <<EOF
name: Example
targets:
  Example:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.example.Product
        MARKETING_VERSION: $marketing
        CURRENT_PROJECT_VERSION: $build
        MACOSX_DEPLOYMENT_TARGET: "$minimum"
EOF
}

expect_value() {
  local name="$1"
  local expected="$2"
  shift 2
  local actual
  actual="$($reader "$@")"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 "FAIL: $name expected '$expected', got '$actual'"
    exit 1
  fi
  (( pass_count += 1 ))
}

expect_failure() {
  local name="$1"
  shift
  if "$reader" "$@" >/dev/null 2>&1; then
    print -u2 "FAIL: $name should fail"
    exit 1
  fi
  (( pass_count += 1 ))
}

fixture="$test_root/project.yml"
write_valid_project "$fixture"
expect_value "marketing version" "1.2.3" --project "$fixture" --marketing
expect_value "build version" "45" --project "$fixture" --build
expect_value "minimum macOS" "26.0" --project "$fixture" --minimum-macos
expect_value "bundle identifier" "com.example.Product" --project "$fixture" --bundle-id

write_valid_project "$fixture" "1.2" "45" "26.0"
expect_failure "invalid marketing version" --project "$fixture" --marketing

write_valid_project "$fixture" "1.2.3" "0" "26.0"
expect_failure "invalid build version" --project "$fixture" --build

write_valid_project "$fixture" "1.2.3" "45" "latest"
expect_failure "invalid deployment target" --project "$fixture" --minimum-macos

write_valid_project "$fixture"
print '        MARKETING_VERSION: 9.9.9' >> "$fixture"
expect_failure "duplicate version key" --project "$fixture" --marketing

print 'name: MissingSettings' > "$fixture"
expect_failure "missing version key" --project "$fixture" --marketing

expect_failure "unknown option" --project "$fixture" --unknown

build_script="$source_root/scripts/build-local-app.sh"
if rg -q 'short_version" == "[0-9]+\.[0-9]+\.[0-9]+"|build_version" == "[0-9]+"|minimum_system" == "[0-9]+\.[0-9]+"' "$build_script"; then
  print -u2 "FAIL: build-local-app.sh still duplicates version literals"
  exit 1
fi
(( pass_count += 1 ))

print "Version contract tests passed: $pass_count"
