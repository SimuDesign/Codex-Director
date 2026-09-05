#!/bin/zsh
set -euo pipefail

source_root="$(cd "$(dirname "$0")/../.." && pwd)"
tag_validator="$source_root/scripts/validate-release-tag.sh"
entry_validator="$source_root/scripts/validate-zip-entry-list.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-director-release-contract.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT INT TERM

pass_count=0
fixture="$test_root/project.yml"
cat > "$fixture" <<'EOF'
name: Fixture
targets:
  Fixture:
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.example.Fixture
        MARKETING_VERSION: 1.2.3
        CURRENT_PROJECT_VERSION: 45
        MACOSX_DEPLOYMENT_TARGET: "26.0"
EOF

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

expect_pass "matching release tag" "$tag_validator" --project "$fixture" v1.2.3
expect_failure "mismatched release tag" "$tag_validator" --project "$fixture" v1.2.4
expect_failure "missing v prefix" "$tag_validator" --project "$fixture" 1.2.3
expect_failure "non-semantic tag" "$tag_validator" --project "$fixture" v1.2

safe_entries="$test_root/safe-entries.txt"
unsafe_parent_entries="$test_root/unsafe-parent-entries.txt"
unsafe_absolute_entries="$test_root/unsafe-absolute-entries.txt"
unsafe_backslash_entries="$test_root/unsafe-backslash-entries.txt"
cat > "$safe_entries" <<'EOF'
Codex Director.app/
Codex Director.app/Contents/
Codex Director.app/Contents/MacOS/Codex Director
EOF
print -r -- 'Codex Director.app/../escape' > "$unsafe_parent_entries"
print -r -- '/absolute/escape' > "$unsafe_absolute_entries"
print -r -- 'Codex Director.app\..\escape' > "$unsafe_backslash_entries"
expect_pass "safe ZIP entries" "$entry_validator" "$safe_entries"
expect_failure "parent ZIP escape" "$entry_validator" "$unsafe_parent_entries"
expect_failure "absolute ZIP escape" "$entry_validator" "$unsafe_absolute_entries"
expect_failure "backslash ZIP escape" "$entry_validator" "$unsafe_backslash_entries"

ci_workflow="$source_root/.github/workflows/ci.yml"
release_workflow="$source_root/.github/workflows/release.yml"
[[ -s "$ci_workflow" && -s "$release_workflow" ]] || { print -u2 "FAIL: workflow files are missing"; exit 1; }

if rg -q 'pull_request_target' "$source_root/.github/workflows"; then
  print -u2 "FAIL: pull_request_target is forbidden"
  exit 1
fi
(( pass_count += 1 ))

action_pattern='uses:[[:space:]]+[^@[:space:]]+@[0-9a-f]{40}([[:space:]]+#.*)?$'
while IFS= read -r action_line; do
  if ! [[ "$action_line" =~ $action_pattern ]]; then
    print -u2 "FAIL: action is not pinned to a full commit SHA: $action_line"
    exit 1
  fi
done < <(rg --no-filename '^[[:space:]]*-?[[:space:]]*uses:' "$source_root/.github/workflows")
(( pass_count += 1 ))

rg -Uq '^permissions:\n  contents: read\n' "$ci_workflow" || { print -u2 "FAIL: CI does not default to contents: read"; exit 1; }
rg -q 'runs-on: macos-26' "$ci_workflow" "$release_workflow" || { print -u2 "FAIL: workflows do not use the macOS 26 runner"; exit 1; }
rg -q 'audit-public-release\.sh --all' "$release_workflow" || { print -u2 "FAIL: release does not audit full public history"; exit 1; }
rg -q 'validate-release-tag\.sh' "$release_workflow" || { print -u2 "FAIL: release does not validate its tag"; exit 1; }
rg -q 'subject-checksums:' "$release_workflow" || { print -u2 "FAIL: release archive is not attested"; exit 1; }
rg -q "github\.event\.repository\.private == false" "$release_workflow" || { print -u2 "FAIL: release is not restricted to the public repository"; exit 1; }
rg -q -- '--verify-tag' "$release_workflow" || { print -u2 "FAIL: release creation does not verify the tag"; exit 1; }
rg -q -- '--draft' "$release_workflow" || { print -u2 "FAIL: release is not created as a draft"; exit 1; }
rg -q -- '--prerelease' "$release_workflow" || { print -u2 "FAIL: release is not marked as a prerelease"; exit 1; }
(( pass_count += 8 ))

print "Release contract tests passed: $pass_count"
