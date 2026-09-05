#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_file="$(cd -- "$script_dir/.." && pwd)/project.yml"
release_tag=""

usage() {
  print -u2 "Usage: $0 [--project FILE] TAG"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --project)
      (( $# >= 2 )) || usage
      project_file="$2"
      shift 2
      ;;
    -*) usage ;;
    *)
      [[ -z "$release_tag" ]] || usage
      release_tag="$1"
      shift
      ;;
  esac
done

[[ -n "$release_tag" && -f "$project_file" ]] || usage
[[ "$release_tag" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
  print -u2 "Release tag must use v<major>.<minor>.<patch>: $release_tag"
  exit 1
}

marketing_version="$($script_dir/read-project-version.sh --project "$project_file" --marketing)"
expected_tag="v$marketing_version"
[[ "$release_tag" == "$expected_tag" ]] || {
  print -u2 "Release tag $release_tag does not match MARKETING_VERSION $marketing_version (expected $expected_tag)"
  exit 1
}

print "Release tag matches project version: $release_tag"
