#!/bin/zsh
set -euo pipefail

# Harness-only build. The checked-in source files and XcodeGen spec are copied
# into a disposable build root, so generation never dirties the checkout. The
# script only builds; it never launches the resulting app.
readonly script_root="${0:A:h:h}"
readonly harness_root="${script_root}/Tests/StartupPerformanceHarness"
if [[ ! -f "${harness_root}/project.yml" || -L "${harness_root}/project.yml" ]]; then
  print -u2 'error=harness_spec_unavailable'
  exit 2
fi
xcodegen_path="$(command -v xcodegen || true)"
[[ -n "$xcodegen_path" && -x "$xcodegen_path" ]] || { print -u2 'error=xcodegen_unavailable'; exit 2; }

build_root="$(mktemp -d "/tmp/codex-director-startup-perf-build.XXXXXX")"
build_succeeded=0
cleanup_failed_build() {
  if (( build_succeeded == 0 )) && [[ "$build_root" == /tmp/codex-director-startup-perf-build.* && -d "$build_root" && ! -L "$build_root" ]]; then
    /bin/rm -rf "$build_root"
  fi
}
trap cleanup_failed_build EXIT INT TERM
generated_root="$build_root/project"
/bin/mkdir "$generated_root"
for source_file in Info.plist StartupPerformanceHarnessApp.swift StartupPerformanceManifest.swift StartupPerformanceRecorder.swift StartupPerformancePassiveMarkers.swift; do
  /bin/cp "$harness_root/$source_file" "$generated_root/$source_file"
done
awk -v root="$script_root" '
  /^    path: [.][.][\/][.][.]$/ { print "    path: \"" root "\""; next }
  { print }
' "$harness_root/project.yml" > "$generated_root/project.yml"

"$xcodegen_path" generate --spec "$generated_root/project.yml" --project "$generated_root"
/usr/bin/xcodebuild -project "$generated_root/CodexDirectorStartupPerformanceHarness.xcodeproj" -scheme StartupPerformanceHarness -configuration Release \
  -derivedDataPath "$build_root/derived-data" -jobs 2 build
app_path="$build_root/derived-data/Build/Products/Release/Codex Director Startup Performance Harness.app"
[[ -d "$app_path" && -x "$app_path/Contents/MacOS/Codex Director Startup Performance Harness" ]] || {
  print -u2 'error=harness_product_unavailable'
  exit 1
}
build_succeeded=1
print "stage=harness_built optimization=release bundle=com.peiweitang.CodexDirector.StartupPerfHarness"
print "build_root=$build_root"
print "app_path=$app_path"
