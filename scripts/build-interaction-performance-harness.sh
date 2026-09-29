#!/bin/zsh
set -euo pipefail

# Builds the real root view with the opt-in performance flag. This is a local
# diagnostic build only; the flag is never enabled by the normal app scheme.
readonly project_root="${0:A:h:h}"
readonly build_root="$(mktemp -d "/tmp/codex-director-interaction-perf-build.XXXXXX")"
readonly log_path="$build_root/xcodebuild.log"
package_args=()

# Optional pre-resolved local SwiftPM cache for an offline diagnostic build.
# Normal CI and clean-checkout builds keep Xcode's default resolution path.
if [[ -n "${CODEX_DIRECTOR_PACKAGE_CACHE:-}" ]]; then
  [[ -d "$CODEX_DIRECTOR_PACKAGE_CACHE/checkouts/ZIPFoundation" && -d "$CODEX_DIRECTOR_PACKAGE_CACHE/repositories" ]] || {
    print -u2 'error=interaction_package_cache_invalid'
    exit 2
  }
  package_args=(-clonedSourcePackagesDirPath "$CODEX_DIRECTOR_PACKAGE_CACHE" -disableAutomaticPackageResolution)
fi

if [[ ! -d "$project_root/CodexDirector.xcodeproj" ]]; then
  print -u2 'error=project_unavailable'
  exit 2
fi

cleanup_failed_build() {
  if [[ "$build_root" == /tmp/codex-director-interaction-perf-build.* && -d "$build_root" && ! -L "$build_root" ]]; then
    /bin/rm -rf "$build_root"
  fi
}
trap cleanup_failed_build EXIT INT TERM

if ! DIRECTOR_INTERACTION_PERFORMANCE=1 /usr/bin/xcodebuild \
  -project "$project_root/CodexDirector.xcodeproj" \
  -scheme 'Codex Director' \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$build_root/derived-data" \
  "${package_args[@]}" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=DIRECTOR_INTERACTION_PERFORMANCE \
  INFOPLIST_KEY_DirectorInteractionPerformanceMode=YES \
  PRODUCT_BUNDLE_IDENTIFIER=com.peiweitang.CodexDirector.InteractionPerformance \
  INFOPLIST_KEY_CFBundleDisplayName='Codex Director Interaction Performance' \
  build >"$log_path" 2>&1; then
  print -u2 "Release interaction harness build failed. Last output:"
  /usr/bin/tail -80 "$log_path" >&2
  exit 1
fi

# Verify the dedicated compile condition was actually passed to Swift. A
# normal Release app must not be mistaken for the synthetic harness.
/usr/bin/grep -q 'DIRECTOR_INTERACTION_PERFORMANCE' "$log_path" || {
  print -u2 'error=interaction_performance_compile_flag_missing'
  exit 1
}

app_path="$build_root/derived-data/Build/Products/Release/Codex Director.app"
executable="$app_path/Contents/MacOS/Codex Director"
[[ -d "$app_path" && -x "$executable" ]] || {
  print -u2 'error=interaction_harness_product_unavailable'
  exit 1
}
# Xcode's INFOPLIST_KEY_ convention ignores arbitrary keys in some toolchain
# versions. Fail closed unless the bundle explicitly identifies this diagnostic
# build. Re-sign the disposable bundle after this metadata-only mutation.
plist_path="$app_path/Contents/Info.plist"
[[ -f "$plist_path" && ! -L "$plist_path" ]] || { print -u2 'error=interaction_harness_plist_missing'; exit 1; }
/usr/libexec/PlistBuddy -c "Delete :DirectorInteractionPerformanceMode" "$plist_path" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :DirectorInteractionPerformanceMode bool true" "$plist_path" >/dev/null
/usr/libexec/PlistBuddy -c "Set :DirectorInteractionPerformanceMode true" "$plist_path" >/dev/null
/usr/bin/codesign --force --deep --sign - "$app_path" >/dev/null
/usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 || {
  print -u2 'error=interaction_harness_signature_verification_failed'
  exit 1
}
plist_mode="$(/usr/libexec/PlistBuddy -c 'Print :DirectorInteractionPerformanceMode' "$plist_path" 2>/dev/null || true)"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path" 2>/dev/null || true)"
[[ "$plist_mode" == "true" && "$bundle_id" == "com.peiweitang.CodexDirector.InteractionPerformance" ]] || {
  print -u2 'error=interaction_harness_identity_verification_failed'
  exit 1
}

# A small, path-free contract stamp lets a later viewport run reuse exactly
# this disposable Release bundle without trusting an arbitrary app path.
print -r -- 'schema=2;bundle=com.peiweitang.CodexDirector.InteractionPerformance;mode=true;configuration=Release;signature=ad-hoc' > "$build_root/interaction-harness-contract.txt"

trap - EXIT INT TERM
print "stage=interaction_harness_built optimization=release synthetic=true"
print "build_root=$build_root"
print "app_path=$app_path"
print "executable=$executable"
