#!/usr/bin/env bash
set -euo pipefail

file="${1:-}"
key="${2:-}"

if [[ -z "$file" || -z "$key" || ! -f "$file" ]]; then
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/xcconfig-validate.sh
. "${script_dir}/xcconfig-validate.sh"

value="$(awk -f "${script_dir}/xcconfig-parse.awk" -v mode=single -v key="$key" "$file")"

if ! err="$(xcconfig_validate_value "$file" "$key" "$value")"; then
  printf '%s\n' "$err" >&2
  exit 2
fi

if [[ -n "$value" ]]; then
  printf '%s\n' "$value"
fi
