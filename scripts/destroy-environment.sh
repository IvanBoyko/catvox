#!/usr/bin/env bash
# Tear down a named CatVox environment: terraform destroy (+ PostHog) plus the
# out-of-Terraform-graph cleanup, behind a config-gated safety guard. Issue #110.
#
# This is the "keep the project" teardown — it removes the environment's
# resources but leaves the GCP project itself. Deleting the whole project and
# rotating to a fresh one for a new create/destroy cycle is a separate capability
# (#111). Operator-run (needs GCP-admin + repo-admin); never wired into CI.
#
# Environment-agnostic: keyed off CATVOX_ENVIRONMENT and the committed
# config/environments/<env>.xcconfig values; no literal environment names.
#
# Safety (mirrors the apply CONFIRM gate, stricter for protected envs):
#   CONFIRM=destroy                      required for ANY environment.
#   ALLOW_PROTECTED_DESTROY=<env>        additionally required, and must equal
#                                        CATVOX_ENVIRONMENT, when the environment
#                                        is protected (CATVOX_ENVIRONMENT_PROTECTED=true).
#
# Order matters and is load-bearing:
#   1. empty the force_destroy=false raw-videos bucket so Terraform can delete it;
#   2. terraform destroy (core) — honours the iOS app deletion_policy (ABANDON/DELETE);
#   3. terraform destroy (PostHog) — tolerant of empty/absent state;
#   4. delete the script-created Cloud Functions Gen2 sources bucket;
#   5. delete the Terraform state bucket LAST (after both destroys — it holds the
#      state both need);
#   6. delete the GitHub Environment + its secrets.
#
# Idempotent: absent resources are skipped, so a re-run after a partial teardown
# converges. If the core terraform destroy (step 2) fails, the script stops
# before deleting the state bucket so the operator can retry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

ENVIRONMENT="${CATVOX_ENVIRONMENT:?CATVOX_ENVIRONMENT is required}"
PROJECT_ID="${CATVOX_PROJECT_ID:?CATVOX_PROJECT_ID is required}"
REGION="${CATVOX_FUNCTION_REGION:-}"
STATE_BUCKET="${CATVOX_TF_STATE_BUCKET:-catvox-tf-state-${PROJECT_ID}}"
PROTECTED="${CATVOX_ENVIRONMENT_PROTECTED:-false}"
TFVARS_FILE="${CATVOX_TF_VARS_FILE:-terraform/env/${ENVIRONMENT}.tfvars}"
CONFIRM="${CONFIRM:-}"
ALLOW_PROTECTED_DESTROY="${ALLOW_PROTECTED_DESTROY:-}"
REPO="${GITHUB_REPO:-kathelix/catvox}"

require_tool() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }
}
require_tool gcloud
require_tool make

# ── Safety gate ─────────────────────────────────────────────────────────────
if [[ "$CONFIRM" != "destroy" ]]; then
  echo "Refusing to destroy '${ENVIRONMENT}' — this deletes its infrastructure." >&2
  echo "Re-run with: make environment-destroy CATVOX_ENVIRONMENT=${ENVIRONMENT} CONFIRM=destroy" >&2
  exit 1
fi
if [[ "$PROTECTED" == "true" && "$ALLOW_PROTECTED_DESTROY" != "$ENVIRONMENT" ]]; then
  echo "'${ENVIRONMENT}' is a PROTECTED environment (CATVOX_ENVIRONMENT_PROTECTED=true)." >&2
  echo "Refusing without an explicit acknowledgement. Re-run with:" >&2
  echo "  make environment-destroy CATVOX_ENVIRONMENT=${ENVIRONMENT} CONFIRM=destroy ALLOW_PROTECTED_DESTROY=${ENVIRONMENT}" >&2
  exit 1
fi

echo "Destroying environment '${ENVIRONMENT}' (project ${PROJECT_ID})."
echo "Keeps the GCP project; removes Terraform-managed resources, the script-created"
echo "state + Functions-source buckets, and the GitHub Environment."
echo

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null || true)"
RAW_VIDEOS_BUCKET="catvox-raw-videos-${PROJECT_ID}"

# Terraform requires alert_email (no default). Its value is irrelevant when
# destroying; supply a placeholder so destroy can evaluate the config when the
# gitignored tfvars is absent. A real -var-file (if present) overrides this.
export TF_VAR_alert_email="${TF_VAR_alert_email:-teardown-noop@example.invalid}"

bucket_exists() { gcloud storage buckets describe "gs://$1" --project "$PROJECT_ID" >/dev/null 2>&1; }
empty_bucket() { gcloud storage rm --recursive "gs://$1/**" >/dev/null 2>&1 || true; }
delete_bucket() { gcloud storage buckets delete "gs://$1" --project "$PROJECT_ID" --quiet >/dev/null 2>&1 || true; }

# 1 — Empty the force_destroy=false raw-videos bucket (Terraform deletes the
#     bucket itself in step 2, but only once it is empty).
echo "1/6 Emptying raw-videos bucket ${RAW_VIDEOS_BUCKET} ..."
if bucket_exists "$RAW_VIDEOS_BUCKET"; then
  empty_bucket "$RAW_VIDEOS_BUCKET"
  echo "  emptied (or already empty)"
else
  echo "  not present; skipping"
fi

# 2 — Core Terraform destroy. set -e stops the script here on failure, before any
#     bucket is deleted, so the state stays intact for a retry.
echo "2/6 terraform destroy (core) ..."
make terraform-destroy CONFIRM=destroy \
  CATVOX_ENVIRONMENT="$ENVIRONMENT" \
  CATVOX_PROJECT_ID="$PROJECT_ID" \
  CATVOX_TF_VARS_FILE="$TFVARS_FILE"

# 3 — PostHog Terraform destroy. Tolerant: many environments have no PostHog
#     state yet (deferred — see #37), so an empty/uninitialised root is fine.
echo "3/6 terraform destroy (PostHog) ..."
if ! make posthog-terraform-destroy CONFIRM=destroy \
  CATVOX_ENVIRONMENT="$ENVIRONMENT" \
  CATVOX_PROJECT_ID="$PROJECT_ID"; then
  echo "  PostHog destroy reported an issue (commonly: no PostHog state) — continuing"
fi

# 4 — Delete the script-created Cloud Functions Gen2 sources bucket (outside the
#     Terraform graph — Terraform manages only its IAM, removed in step 2).
echo "4/6 Deleting Cloud Functions sources bucket ..."
if [[ -n "$PROJECT_NUMBER" && -n "$REGION" ]]; then
  src_bucket="gcf-v2-sources-${PROJECT_NUMBER}-${REGION}"
  if bucket_exists "$src_bucket"; then
    empty_bucket "$src_bucket"
    delete_bucket "$src_bucket"
    echo "  deleted ${src_bucket}"
  else
    echo "  ${src_bucket} not present; skipping"
  fi
else
  echo "  project number or region unavailable; skipping sources bucket"
fi

# 5 — Delete the Terraform state bucket LAST. Both destroys above read/write it,
#     so it must outlive them. The operator's own credentials delete it (the CI
#     SA's bucket IAM is already gone with step 2).
echo "5/6 Deleting Terraform state bucket ${STATE_BUCKET} (last) ..."
if bucket_exists "$STATE_BUCKET"; then
  empty_bucket "$STATE_BUCKET"
  delete_bucket "$STATE_BUCKET"
  echo "  deleted ${STATE_BUCKET}"
else
  echo "  ${STATE_BUCKET} not present; skipping"
fi

# 6 — Delete the GitHub Environment and its secrets.
echo "6/6 Deleting GitHub Environment '${ENVIRONMENT}' ..."
if command -v gh >/dev/null 2>&1; then
  if gh api --method DELETE "repos/${REPO}/environments/${ENVIRONMENT}" >/dev/null 2>&1; then
    echo "  deleted"
  else
    echo "  not present or already deleted; skipping"
  fi
else
  echo "  gh not installed — delete the '${ENVIRONMENT}' GitHub Environment manually"
fi

echo
echo "Done. '${ENVIRONMENT}' torn down; the GCP project ${PROJECT_ID} was kept (now empty)."
echo "To also delete the project and rotate to a fresh one for a new cycle, see #111."
