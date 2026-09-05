#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_file="$(cd -- "$script_dir/.." && pwd)/project.yml"
field=""

usage() {
  print -u2 "Usage: $0 [--project FILE] (--marketing|--build|--minimum-macos|--bundle-id)"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --project)
      (( $# >= 2 )) || usage
      project_file="$2"
      shift 2
      ;;
    --marketing|--build|--minimum-macos|--bundle-id)
      [[ -z "$field" ]] || usage
      field="$1"
      shift
      ;;
    *) usage ;;
  esac
done

[[ -n "$field" && -f "$project_file" ]] || usage

case "$field" in
  --marketing) key="MARKETING_VERSION" ;;
  --build) key="CURRENT_PROJECT_VERSION" ;;
  --minimum-macos) key="MACOSX_DEPLOYMENT_TARGET" ;;
  --bundle-id) key="PRODUCT_BUNDLE_IDENTIFIER" ;;
esac

values="$(awk -v key="$key" '
  $1 == key ":" {
    sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
    sub(/[[:space:]]*#[[:space:]].*$/, "")
    gsub(/^"|"$/, "")
    print
  }
' "$project_file")"

count="$(print -r -- "$values" | awk 'NF { count += 1 } END { print count + 0 }')"
if [[ "$count" != "1" ]]; then
  print -u2 "Expected exactly one $key in $project_file; found $count"
  exit 1
fi

value="$(print -r -- "$values" | awk 'NF { print; exit }')"
case "$field" in
  --marketing)
    [[ "$value" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "Invalid MARKETING_VERSION: $value"; exit 1; }
    ;;
  --build)
    [[ "$value" =~ '^[1-9][0-9]*$' ]] || { print -u2 "Invalid CURRENT_PROJECT_VERSION: $value"; exit 1; }
    ;;
  --minimum-macos)
    [[ "$value" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { print -u2 "Invalid MACOSX_DEPLOYMENT_TARGET: $value"; exit 1; }
    ;;
  --bundle-id)
    [[ "$value" =~ '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$' ]] || { print -u2 "Invalid PRODUCT_BUNDLE_IDENTIFIER: $value"; exit 1; }
    ;;
esac

print -r -- "$value"
