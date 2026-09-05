#!/bin/zsh
set -euo pipefail

source_root="$(cd "$(dirname "$0")/../.." && pwd)"
audit_script="$source_root/scripts/audit-public-release.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-director-audit-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT INT TERM

pass_count=0

new_fixture() {
    local name="$1"
    local fixture="$test_root/$name"
    mkdir -p "$fixture"
    git -C "$fixture" init -q -b main
    git -C "$fixture" config user.name "Audit Test"
    git -C "$fixture" config user.email "audit@example.invalid"
    print "$fixture"
}

commit_fixture() {
    local fixture="$1"
    git -C "$fixture" add -A
    git -C "$fixture" commit -q -m "Fixture"
}

expect_pass() {
    local name="$1"
    local fixture="$2"
    shift 2
    if ! output="$(cd "$fixture" && "$audit_script" "$@" 2>&1)"; then
        print -u2 "FAIL: $name should pass"
        print -u2 "$output"
        exit 1
    fi
    (( pass_count += 1 ))
}

expect_failure() {
    local name="$1"
    local fixture="$2"
    local expected="$3"
    shift 3
    if output="$(cd "$fixture" && "$audit_script" "$@" 2>&1)"; then
        print -u2 "FAIL: $name should fail"
        exit 1
    fi
    if ! grep -Fq -- "$expected" <<< "$output"; then
        print -u2 "FAIL: $name did not report $expected"
        print -u2 "$output"
        exit 1
    fi
    (( pass_count += 1 ))
}

clean_fixture="$(new_fixture clean)"
mkdir -p "$clean_fixture/Sources"
print 'Paths may use /Users/example and {{HOME}} in documentation.' > "$clean_fixture/Sources/example.txt"
print 'github_pat_EXAMPLE00000000000000000000' >> "$clean_fixture/Sources/example.txt"
commit_fixture "$clean_fixture"
expect_pass "safe examples" "$clean_fixture" --all

home_fixture="$(new_fixture home-path)"
mkdir -p "$home_fixture/docs"
private_home_prefix="/Users"
print "Installed from ${private_home_prefix}/private-person/Library/Application Support/App" > "$home_fixture/docs/install.md"
commit_fixture "$home_fixture"
expect_failure "personal Home path" "$home_fixture" "personal-home-path: docs/install.md" --tracked

temp_fixture="$(new_fixture private-temp)"
private_temp_prefix="/private"
print "artifact=${private_temp_prefix}/tmp/private-build/result.app" > "$temp_fixture/build.txt"
commit_fixture "$temp_fixture"
expect_failure "private temporary path" "$temp_fixture" "private-temporary-path: build.txt" --tracked

credential_fixture="$(new_fixture credentials)"
bearer_prefix="Bearer"
print "authorization: ${bearer_prefix} abcdefghijklmnopqrstuvwxyz123456" > "$credential_fixture/config.txt"
commit_fixture "$credential_fixture"
expect_failure "credential" "$credential_fixture" "credential-pattern: config.txt" --tracked

key_fixture="$(new_fixture private-key)"
key_header='-----BEGIN'
print '%s\n' "${key_header} PRIVATE KEY-----" 'not-a-real-key' > "$key_fixture/example.txt"
commit_fixture "$key_fixture"
expect_failure "private key" "$key_fixture" "credential-pattern: example.txt" --tracked

sensitive_file_fixture="$(new_fixture sensitive-file)"
print 'synthetic' > "$sensitive_file_fixture/local.sqlite"
commit_fixture "$sensitive_file_fixture"
expect_failure "sensitive file" "$sensitive_file_fixture" "sensitive-file-type: local.sqlite" --tracked

large_fixture="$(new_fixture large-file)"
dd if=/dev/zero of="$large_fixture/large.bin" bs=1048576 count=6 2>/dev/null
commit_fixture "$large_fixture"
expect_failure "unregistered large file" "$large_fixture" "unregistered-large-file: large.bin" --tracked
print 'large.bin' > "$large_fixture/.public-release-large-files"
commit_fixture "$large_fixture"
expect_pass "registered large file" "$large_fixture" --tracked

history_fixture="$(new_fixture history)"
print "old path ${private_home_prefix}/private-person/secret" > "$history_fixture/old.txt"
commit_fixture "$history_fixture"
rm "$history_fixture/old.txt"
commit_fixture "$history_fixture"
expect_pass "deleted secret absent from tree" "$history_fixture" --tracked
expect_failure "deleted secret present in history" "$history_fixture" "personal-home-path: git-history" --history

print "Public release audit tests passed: $pass_count"
