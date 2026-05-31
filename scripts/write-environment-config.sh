#!/usr/bin/env bash
# Write the resolved non-secret values for a CatVox environment into its
# committed config/environments/<env>.xcconfig, reading them from Terraform
# outputs, the generated Firebase plist, and (post-deploy) the deployed Cloud Run
# hosts — so the operator never hand-pastes them. Replaces the manual copy steps
# in docs/CREATE_NEW_ENVIRONMENT.md. Issue #108.
#
# Environment-agnostic: the same command works for mutable (dev-like) and
# protected (prod-like) environments. Literal environment names never appear
# here — everything is keyed off CATVOX_ENVIRONMENT.
#
#   WRITE_CONFIG_PHASE   identity | hosts | all   (default: identity)
#     identity  values that exist after `terraform apply` + plist export:
#               CATVOX_GCP_CI_SERVICE_ACCOUNT, CATVOX_GCP_WIF_PROVIDER,
#               CATVOX_FIREBASE_APP_ID (Terraform outputs) and
#               CATVOX_FIREBASE_API_KEY (read from the plist — Terraform exposes
#               only the key *id*, not its value).
#     hosts     the two Cloud Run host keys, which exist only after the Functions
#               deploy: CATVOX_SIGNED_UPLOAD_URL_HOST, CATVOX_ANALYSE_VIDEO_HOST.
#     all       identity, then hosts.
#
# Writes the working tree only. It never stages or commits — the operator
# reviews the diff and commits (this keeps committed config, especially a
# protected environment's xcconfig, under operator control). Idempotent:
# re-running converges the managed keys and leaves every other line untouched, so
# an unchanged re-run produces no diff.
#
# Identity reads are strict (a missing Terraform output or plist fails the run —
# the precondition is that apply + plist export already happened). Host reads are
# lenient (a function that is not deployed yet is reported and skipped, not an
# error — the operator re-runs PHASE=hosts after the deploy).
#
# Expects the same environment the Makefile terraform targets read, and that
# `make terraform-init` (and apply) has already run for this environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

ENVIRONMENT="${CATVOX_ENVIRONMENT:?CATVOX_ENVIRONMENT is required}"
ENV_CONFIG="${CATVOX_ENV_CONFIG:-config/environments/${ENVIRONMENT}.xcconfig}"
PHASE="${WRITE_CONFIG_PHASE:-identity}"
PROJECT_ID="${CATVOX_PROJECT_ID:-}"
REGION="${CATVOX_FUNCTION_REGION:-}"
PLIST="${CATVOX_FIREBASE_PLIST_OUTPUT:-CatVox/Resources/Firebase/GoogleService-Info-${ENVIRONMENT}.plist}"

# Cloud Run function names are part of the backend contract and identical in
# every environment (TRD §6.2). Each maps to the host-only xcconfig key it fills.
FUNCTION_GETSIGNEDUPLOADURL="getSignedUploadURL"
FUNCTION_ANALYSEVIDEO="analyseVideo"

case "$PHASE" in
  identity | hosts | all) ;;
  *) echo "WRITE_CONFIG_PHASE must be 'identity', 'hosts', or 'all' (got: $PHASE)" >&2; exit 1 ;;
esac

if [[ ! -f "$ENV_CONFIG" ]]; then
  echo "ERROR: environment config not found: ${ENV_CONFIG}" >&2
  echo "Create the xcconfig skeleton first (see docs/CREATE_NEW_ENVIRONMENT.md)." >&2
  exit 1
fi

require_tool() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }
}

# Collapse a single-token value to itself with all surrounding whitespace and any
# stray CR/newline removed. The xcconfig values handled here (emails, app ids,
# resource names, hostnames) contain no internal whitespace, so stripping all of
# it is safe and immune to the `terraform output -raw` trailing-`%`/newline trap.
clean_token() { printf '%s' "$1" | tr -d '[:space:]'; }

# Replace KEY's value in the xcconfig (canonical `KEY = VALUE` form), or append
# the key if it is absent. Whole-file rewrite into a temp file, then an in-place
# content overwrite that preserves the file's permissions and inode. A no-op when
# the value already matches, so re-runs leave a clean git diff. KEY and VALUE are
# passed through the environment (not awk -v) so backslashes are never reinterpreted.
set_xcconfig_value() {
  local key="$1" val="$2" tmp existed
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$ENV_CONFIG"; then existed=1; else existed=0; fi
  tmp="$(mktemp "${ENV_CONFIG}.XXXXXX")"
  WC_KEY="$key" WC_VAL="$val" awk '
    BEGIN { k = ENVIRON["WC_KEY"]; v = ENVIRON["WC_VAL"]; seen = 0 }
    {
      if (!seen && $0 ~ ("^[ \t]*" k "[ \t]*=")) { print k " = " v; seen = 1 }
      else { print }
    }
    END { if (!seen) print k " = " v }
  ' "$ENV_CONFIG" > "$tmp"
  if cmp -s "$tmp" "$ENV_CONFIG"; then
    rm -f "$tmp"
    echo "  unchanged: ${key}"
    return 0
  fi
  cat "$tmp" > "$ENV_CONFIG"
  rm -f "$tmp"
  if [[ "$existed" == "1" ]]; then echo "  updated:   ${key}"; else echo "  added:     ${key} (was absent)"; fi
}

# Strict read of a Terraform output. `$(...)` already strips the trailing newline,
# so the value lands clean with no `%` end-of-line marker.
tf_output() {
  local name="$1" val
  if ! val="$(terraform -chdir="${REPO_ROOT}/terraform" output -raw "$name" 2>/dev/null)"; then
    echo "ERROR: could not read Terraform output '${name}'." >&2
    echo "Run 'make terraform-init' (and apply) for ${ENVIRONMENT} first." >&2
    return 1
  fi
  clean_token "$val"
}

write_identity() {
  require_tool terraform
  require_tool plutil
  if [[ ! -f "$PLIST" ]]; then
    echo "ERROR: Firebase plist not found: ${PLIST}" >&2
    echo "Run 'make terraform-output-firebase-plist' for ${ENVIRONMENT} first." >&2
    exit 1
  fi

  local ci_sa wif_provider app_id api_key
  ci_sa="$(tf_output ci_service_account_email)"
  wif_provider="$(tf_output github_actions_wif_provider)"
  app_id="$(tf_output firebase_ios_app_id)"
  if ! api_key="$(plutil -extract API_KEY raw "$PLIST" 2>/dev/null)"; then
    echo "ERROR: could not read API_KEY from ${PLIST}." >&2
    exit 1
  fi
  api_key="$(clean_token "$api_key")"

  echo "Writing identity values into ${ENV_CONFIG}:"
  set_xcconfig_value CATVOX_GCP_CI_SERVICE_ACCOUNT "$ci_sa"
  set_xcconfig_value CATVOX_GCP_WIF_PROVIDER "$wif_provider"
  set_xcconfig_value CATVOX_FIREBASE_APP_ID "$app_id"
  set_xcconfig_value CATVOX_FIREBASE_API_KEY "$api_key"
}

# Lenient read of a deployed Cloud Run function host. Prints the hostname only
# (no scheme/path) on success; returns non-zero if the function is not deployed
# yet or cannot be read, so the caller can warn and skip rather than fail.
function_host() {
  local name="$1" uri host
  if ! uri="$(gcloud functions describe "$name" --v2 \
        --project "$PROJECT_ID" --region "$REGION" \
        --format='value(serviceConfig.uri)' 2>/dev/null)"; then
    return 1
  fi
  uri="$(clean_token "$uri")"
  [[ -n "$uri" ]] || return 1
  host="${uri#https://}"
  host="${host#http://}"
  host="${host%%/*}"
  printf '%s' "$host"
}

write_hosts() {
  require_tool gcloud
  [[ -n "$PROJECT_ID" ]] || { echo "ERROR: CATVOX_PROJECT_ID is required for the hosts phase." >&2; exit 1; }
  [[ -n "$REGION" ]] || { echo "ERROR: CATVOX_FUNCTION_REGION is required for the hosts phase." >&2; exit 1; }

  echo "Writing backend host values into ${ENV_CONFIG}:"
  local host
  if host="$(function_host "$FUNCTION_GETSIGNEDUPLOADURL")"; then
    set_xcconfig_value CATVOX_SIGNED_UPLOAD_URL_HOST "$host"
  else
    echo "  skipped:   CATVOX_SIGNED_UPLOAD_URL_HOST (${FUNCTION_GETSIGNEDUPLOADURL} not deployed yet; re-run PHASE=hosts after deploy)" >&2
  fi
  if host="$(function_host "$FUNCTION_ANALYSEVIDEO")"; then
    set_xcconfig_value CATVOX_ANALYSE_VIDEO_HOST "$host"
  else
    echo "  skipped:   CATVOX_ANALYSE_VIDEO_HOST (${FUNCTION_ANALYSEVIDEO} not deployed yet; re-run PHASE=hosts after deploy)" >&2
  fi
}

if [[ "$PHASE" == "identity" || "$PHASE" == "all" ]]; then
  write_identity
fi
if [[ "$PHASE" == "hosts" || "$PHASE" == "all" ]]; then
  write_hosts
fi

echo "Done. Review the diff and commit ${ENV_CONFIG} when it looks right."
