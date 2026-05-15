#!/usr/bin/env bash

trim_app_check_debug_token() {
  local token="$1"
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%"${token##*[![:space:]]}"}"
  token="${token%\"}"
  token="${token#\"}"
  printf '%s' "${token}"
}

is_valid_app_check_debug_token() {
  local token
  token="$(trim_app_check_debug_token "$1")"
  local lower_token
  lower_token="$(printf '%s' "${token}" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "${token}" ]]; then
    return 1
  fi

  if [[ "${#token}" -lt 16 ]]; then
    return 1
  fi

  if [[ "${token}" == *$'\n'* || "${token}" == *$'\r'* ]]; then
    return 1
  fi

  case "${lower_token}" in
    your-app-check-debug-token|replace-me|*\$\(*|*\<*|*\>*|*placeholder*)
      return 1
      ;;
  esac

  return 0
}

read_tfvars_app_check_debug_token() {
  local tfvars_path="${1:-terraform/terraform.tfvars}"
  if [[ ! -f "${tfvars_path}" ]]; then
    return 0
  fi

  awk -F '=' '
    /^[[:space:]]*app_check_debug_token[[:space:]]*=/ {
      value=$2;
      sub(/^[[:space:]]+/, "", value);
      sub(/[[:space:]]+#.*/, "", value);
      sub(/[[:space:]]+$/, "", value);
      if (value ~ /^".*"$/) {
        sub(/^"/, "", value);
        sub(/"$/, "", value);
      }
      print value;
      exit;
    }
  ' "${tfvars_path}"
}

read_catvox_app_check_debug_token() {
  local token="${CATVOX_APP_CHECK_DEBUG_TOKEN:-${TF_VAR_app_check_debug_token:-}}"
  local tfvars_path="${1:-${CATVOX_TFVARS_PATH:-terraform/terraform.tfvars}}"

  if ! is_valid_app_check_debug_token "${token}"; then
    token="$(read_tfvars_app_check_debug_token "${tfvars_path}")"
  fi

  if is_valid_app_check_debug_token "${token}"; then
    trim_app_check_debug_token "${token}"
  fi
}
