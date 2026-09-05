#!/bin/zsh
set -euo pipefail

director_cache_root=/tmp/codex-director
director_module_cache="$director_cache_root/module-cache"
director_build_path="$director_cache_root/build"

mkdir -p "$director_module_cache" "$director_build_path"
export CLANG_MODULE_CACHE_PATH="$director_module_cache"
export SWIFT_MODULECACHE_PATH="$director_module_cache"

"$PWD/Tests/Scripts/test-audit-public-release.sh"
"$PWD/Tests/Scripts/test-version-contract.sh"
"$PWD/Tests/Scripts/test-release-contract.sh"
"$PWD/Tests/Scripts/test-performance-contract.sh"
"$PWD/scripts/audit-public-release.sh" --tracked
"$PWD/scripts/verify-public-contract.sh"

# NB: --disable-sandbox is required when SwiftPM runs inside a nested file
# sandbox (manifest sandbox-exec is otherwise denied). Harmless on a normal
# terminal; remove only with an environment that permits nested sandboxing.
swift test --disable-sandbox --scratch-path "$director_build_path"
swift build --disable-sandbox --scratch-path "$director_build_path"
