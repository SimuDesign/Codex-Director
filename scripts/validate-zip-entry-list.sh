#!/bin/zsh
set -euo pipefail

[[ $# == 1 && -f "$1" ]] || {
  print -u2 "Usage: $0 ENTRY_LIST_FILE"
  exit 2
}

awk '
  /^$/ {
    unsafe = "<empty>"
    exit
  }
  /^\// || /\\/ {
    unsafe = $0
    exit
  }
  {
    count = split($0, components, "/")
    for (component_index = 1; component_index <= count; component_index += 1) {
      if (components[component_index] == ".." || components[component_index] == ".") {
        unsafe = $0
        exit
      }
    }
  }
  END {
    if (unsafe != "") {
      print "Unsafe archive entry: " unsafe > "/dev/stderr"
      exit 1
    }
  }
' "$1"
