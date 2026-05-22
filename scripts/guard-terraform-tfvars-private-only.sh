#!/usr/bin/env bash
set -euo pipefail

tfvars_file="${1:-}"
environment="${2:-}"

if [[ -z "$tfvars_file" || ! -f "$tfvars_file" ]]; then
  exit 0
fi

invalid_keys="$(awk '
  function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
  }

  {
    line = trim($0)
    if (line == "" || line ~ /^#/ || line ~ /^\/\//) {
      next
    }
    if (line ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) {
      key = line
      sub(/[[:space:]]*=.*/, "", key)
      if (key != "app_check_debug_token" && key != "alert_email") {
        print key
      }
    }
  }
' "$tfvars_file" | sort -u)"

if [[ -z "$invalid_keys" ]]; then
  exit 0
fi

if [[ -n "$environment" ]]; then
  printf '%s must contain only private Terraform values for CATVOX_ENVIRONMENT=%s: app_check_debug_token and alert_email.\n' "$tfvars_file" "$environment" >&2
  printf 'Move non-secret values to config/environments/%s.xcconfig.\n' "$environment" >&2
else
  printf '%s must contain only private Terraform values: app_check_debug_token and alert_email.\n' "$tfvars_file" >&2
  printf 'Move non-secret values to the matching config/environments/<env>.xcconfig file.\n' >&2
fi
printf 'Disallowed key(s):\n' >&2
printf '%s\n' "$invalid_keys" | while IFS= read -r key; do
  printf '  %s\n' "$key" >&2
done
exit 1
