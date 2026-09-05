#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(cd -- "$script_dir/.." && pwd)"
derived_data="${DERIVED_DATA_PATH:-/tmp/codex-director-xcode}"
app_path="$derived_data/Build/Products/Release/Codex Director.app"
install_path="/Applications/Codex Director.app"

installed_app_running() {
  pgrep -f '^/Applications/Codex Director\.app/Contents/MacOS/Codex Director$' >/dev/null 2>&1
}

zsh "$script_dir/build-local-app.sh"

if [[ ! -d "$app_path" ]]; then
  print -u2 "Verified build is missing: $app_path"
  exit 1
fi

if installed_app_running; then
  osascript -e 'tell application id "com.peiweitang.CodexDirector" to quit'
  for _ in {1..50}; do
    installed_app_running || break
    sleep 0.2
  done
  if installed_app_running; then
    print -u2 "Codex Director did not quit; the verified update was not installed."
    exit 2
  fi
fi

if [[ -e "$install_path" ]]; then
  account_name="$(id -un)"
  account_home="$(dscl . -read "/Users/$account_name" NFSHomeDirectory | awk '{print $2}')"
  trash_dir="$account_home/.Trash"
  [[ -d "$trash_dir" ]] || { print -u2 "User Trash is unavailable; existing app was not moved."; exit 2; }
  backup_name="Codex Director-previous-$(date +%Y%m%d-%H%M%S)-$$.app"
  backup_path="$trash_dir/$backup_name"
  [[ ! -e "$backup_path" ]] || { print -u2 "Unique Trash destination already exists."; exit 2; }
  mv "$install_path" "$backup_path"
  print "Previous application moved to Trash and remains recoverable: $backup_path"
fi

ditto "$app_path" "$install_path"
codesign --verify --deep --strict "$install_path"
diff -qr "$app_path" "$install_path" >/dev/null
build_executable_hash="$(shasum -a 256 "$app_path/Contents/MacOS/Codex Director" | awk '{print $1}')"
installed_executable_hash="$(shasum -a 256 "$install_path/Contents/MacOS/Codex Director" | awk '{print $1}')"
[[ "$build_executable_hash" == "$installed_executable_hash" ]] || {
  print -u2 "Installed executable does not match the verified build."
  exit 1
}
open "$install_path"
print "Installed, matched and opened: $install_path"
print "Executable SHA-256: $installed_executable_hash"
