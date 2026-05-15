#!/usr/bin/env bash
set -euo pipefail

file="${1:-}"
key="${2:-}"

if [[ -z "$file" || -z "$key" || ! -f "$file" ]]; then
  exit 0
fi

value="$(awk -F '=' -v key="$key" '
  $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
    value = $2
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    print value
    exit
  }
' "$file")"

if [[ "$key" =~ (_HOST|_HOST_NAME)$ && "$value" == *"://"* ]]; then
  printf 'error: %s in %s must be a hostname only, got %s\n' "$key" "$file" "$value" >&2
  exit 2
fi

if [[ -n "$value" ]]; then
  printf '%s\n' "$value"
fi
