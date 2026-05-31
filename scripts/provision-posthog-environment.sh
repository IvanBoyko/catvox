#!/usr/bin/env bash
# Provision the PostHog project/dashboard for one CatVox environment.
#
# This is the PostHog half of `make environment-create`: it prompts the operator
# for a PostHog personal API key when one is not already exported, configures and
# verifies the matching GitHub Environment, stores the key as that environment's
# `POSTHOG_API_KEY` secret for CI, applies terraform/posthog, then writes the
# public project ID/token back into config/environments/<env>.xcconfig.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

ENVIRONMENT="${CATVOX_ENVIRONMENT:?CATVOX_ENVIRONMENT is required}"
ENV_CONFIG="${CATVOX_ENV_CONFIG:-config/environments/${ENVIRONMENT}.xcconfig}"
REPO="${GITHUB_REPO:-kathelix/catvox}"

require_tool() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }
}

require_tool gh
require_tool make
require_tool terraform
require_tool gcloud

if [[ ! -f "$ENV_CONFIG" ]]; then
  echo "ERROR: environment config not found: ${ENV_CONFIG}" >&2
  exit 1
fi

config_fragment="$(mktemp)"
trap 'rm -f "$config_fragment"' EXIT
scripts/lib/emit-xcconfig-env.sh --format=sh "$ENV_CONFIG" > "$config_fragment"
# shellcheck source=/dev/null
. "$config_fragment"

: "${CATVOX_ENVIRONMENT_PROTECTED:?CATVOX_ENVIRONMENT_PROTECTED must be set in ${ENV_CONFIG}}"
: "${CATVOX_GCP_WIF_GITHUB_REF:=}"

if [[ -z "${POSTHOG_API_KEY:-}" ]]; then
  if [[ ! -t 0 ]]; then
    echo "POSTHOG_API_KEY is required. Re-run interactively or export it in the environment." >&2
    exit 1
  fi
  read -r -s -p "PostHog API key for ${ENVIRONMENT}: " POSTHOG_API_KEY
  echo
fi

if [[ -z "$POSTHOG_API_KEY" ]]; then
  echo "POSTHOG_API_KEY must not be empty." >&2
  exit 1
fi

echo "Configuring GitHub Environment '${ENVIRONMENT}' before storing PostHog credentials..."
CATVOX_ENVIRONMENT="$ENVIRONMENT" \
CATVOX_ENVIRONMENT_PROTECTED="$CATVOX_ENVIRONMENT_PROTECTED" \
CATVOX_GCP_WIF_GITHUB_REF="$CATVOX_GCP_WIF_GITHUB_REF" \
GITHUB_ENVIRONMENT_REVIEWERS="${GITHUB_ENVIRONMENT_REVIEWERS:-}" \
GITHUB_REPO="$REPO" \
  ./scripts/configure-github-environment.sh

echo "Storing POSTHOG_API_KEY in GitHub Environment '${ENVIRONMENT}'..."
printf '%s' "$POSTHOG_API_KEY" | gh secret set POSTHOG_API_KEY --env "$ENVIRONMENT" --repo "$REPO" >/dev/null

echo "Planning PostHog Terraform for '${ENVIRONMENT}'..."
POSTHOG_API_KEY="$POSTHOG_API_KEY" \
  make posthog-terraform-plan CATVOX_ENVIRONMENT="$ENVIRONMENT" CATVOX_ENV_CONFIG="$ENV_CONFIG"

echo "Applying PostHog Terraform for '${ENVIRONMENT}'..."
POSTHOG_API_KEY="$POSTHOG_API_KEY" \
  make posthog-terraform-ci-apply CATVOX_ENVIRONMENT="$ENVIRONMENT" CATVOX_ENV_CONFIG="$ENV_CONFIG"

echo "Writing PostHog project ID/token into ${ENV_CONFIG}..."
POSTHOG_API_KEY="$POSTHOG_API_KEY" \
  make environment-write-config CATVOX_ENVIRONMENT="$ENVIRONMENT" CATVOX_ENV_CONFIG="$ENV_CONFIG" PHASE=posthog

echo "Done. Review and commit ${ENV_CONFIG} when the PostHog values look right."
