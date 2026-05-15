#!/usr/bin/env bash
set -euo pipefail

file="${1:-}"
key="${2:-}"

if [[ -z "$file" || -z "$key" || ! -f "$file" ]]; then
  exit 0
fi

awk -F '=' -v key="$key" '
  $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
    value = $2
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    gsub(/\/\$\(\)\//, "//", value)
    print value
    exit
  }
' "$file"
