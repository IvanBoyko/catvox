#!/usr/bin/env bash
# Shared xcconfig value validator. Sourced (not executed) by
# scripts/lib/read-xcconfig-value.sh and scripts/lib/emit-xcconfig-env.sh.
#
# Validation rules:
# - keys ending in _HOST or _HOST_NAME must be hostnames only: no scheme, path,
#   or trailing slash. config/environments/<env>.xcconfig stores hostnames
#   only; full URLs are composed downstream (Makefile, project.yml). xcconfig
#   also truncates "https://..." values at the "//" because "//" starts a
#   comment, so an unvalidated scheme silently corrupts the value.
# - retired duplicate aliases must not be reintroduced. CATVOX_PROJECT_ID and
#   CATVOX_IOS_BUNDLE_ID are the canonical committed keys.
#
# Usage:
#   if ! err=$(xcconfig_validate_value "$file" "$key" "$value"); then
#     printf '%s\n' "$err" >&2
#     exit 2
#   fi

xcconfig_validate_value() {
  local file="$1" key="$2" value="$3"
  case "$key" in
    GCP_PROJECT_ID|FIREBASE_PROJECT)
      printf 'error: %s in %s is retired; use CATVOX_PROJECT_ID' \
        "$key" "$file"
      return 1
      ;;
    CATVOX_PRODUCT_BUNDLE_IDENTIFIER)
      printf 'error: %s in %s is retired; use CATVOX_IOS_BUNDLE_ID' \
        "$key" "$file"
      return 1
      ;;
  esac

  if [[ "$key" =~ (_HOST|_HOST_NAME)$ && "$value" == *"/"* ]]; then
    printf 'error: %s in %s must be a hostname only, got %s' \
      "$key" "$file" "$value"
    return 1
  fi
  return 0
}
