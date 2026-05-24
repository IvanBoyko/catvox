#!/usr/bin/env bash
# =============================================================================
# CatVox AI — Bootstrap Workload Identity Federation for GitHub Actions (Step 2 of 2)
# Kathelix Ltd
#
# Target SA: catvox-ci-sa — the dedicated Terraform CI identity (separate from
# the runtime SA catvox-backend-sa, which holds only Cloud Functions roles).
#
# Legacy helper. New environments manage WIF with Terraform through
# scripts/create-environment.sh / `make environment-create`.
#
# What this script does:
#   1. Validates catvox-ci-sa exists (created by terraform apply)
#   2. Creates a Workload Identity Pool (skips if already exists)
#   3. Creates an OIDC provider inside it, trusting GitHub's token issuer (skips if exists)
#   4. Binds catvox-ci-sa to tokens from this specific GitHub repo
#   5. Grants catvox-ci-sa object-level access to the Terraform state bucket
#   6. Prints the values to add as GitHub Actions secrets
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (`gcloud auth login`)
#   - terraform apply has been run (catvox-ci-sa must exist)
#   - bootstrap_remote_state.sh has been run (state bucket must exist)
#   - Sufficient IAM permissions: IAM Admin + Storage Admin on the project
#
# NOTE — two project IDs:
#   PROJECT_ID   = GCP project where Terraform resources live.
#                  Must match the selected environment project ID.
#                  Defaults to gcloud's active project; override if they differ:
#                    PROJECT_ID=my-project ./bootstrap_wif.sh
#   STATE_BUCKET = read automatically from the backend "gcs" block in main.tf.
#                  The state bucket may be in a different GCP project to the app
#                  resources — GCS IAM is cross-project so this works fine.
#
# Usage:
#   chmod +x terraform/bootstrap_wif.sh
#   ./terraform/bootstrap_wif.sh
#   # or, if your gcloud active project differs from var.project_id:
#   PROJECT_ID=kathelix-catvox-dev ./terraform/bootstrap_wif.sh
# =============================================================================

set -euo pipefail

echo "Deprecated helper: use 'make environment-create' for new environments." >&2

# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
GITHUB_ORG="kathelix"
GITHUB_REPO="catvox"
SA_NAME="catvox-ci-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL_ID="github-actions-pool"
PROVIDER_ID="github-actions-provider"

# Extract the state bucket name directly from the backend block in main.tf —
# it may be named after a different project ID than PROJECT_ID.
STATE_BUCKET=$(grep -A5 'backend "gcs"' "${SCRIPT_DIR}/main.tf" \
  | grep 'bucket' \
  | head -1 \
  | sed 's/.*"\(.*\)".*/\1/')

# ── Validation ────────────────────────────────────────────────────────────────

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: PROJECT_ID is not set and could not be read from gcloud config."
  echo "       Run: gcloud config set project YOUR_PROJECT_ID"
  echo "       Or:  PROJECT_ID=YOUR_PROJECT_ID ./bootstrap_wif.sh"
  exit 1
fi

if [[ -z "${STATE_BUCKET}" ]]; then
  echo "ERROR: Could not read state bucket name from terraform/main.tf."
  echo "       Ensure the backend \"gcs\" block is uncommented and has a bucket value."
  exit 1
fi

# WIF principal sets require the numeric project number, not the project ID.
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')

echo ""
echo "  Project ID     : ${PROJECT_ID}"
echo "  Project Number : ${PROJECT_NUMBER}"
echo "  GitHub repo    : ${GITHUB_ORG}/${GITHUB_REPO}"
echo "  Service Account: ${SA_EMAIL}"
echo "  State bucket   : gs://${STATE_BUCKET}"
echo "  WIF Pool       : ${POOL_ID}"
echo "  WIF Provider   : ${PROVIDER_ID}"
echo ""

# Verify catvox-backend-sa exists before proceeding — it is created by
# `terraform apply` (iam.tf) and must exist before we can bind WIF to it.
echo ">>> Verifying service account exists..."
if ! gcloud iam service-accounts describe "${SA_EMAIL}" \
     --project="${PROJECT_ID}" &>/dev/null; then
  echo ""
  echo "ERROR: Service account not found: ${SA_EMAIL}"
  echo "       catvox-ci-sa is provisioned by Terraform (iam.tf)."
  echo "       Ensure PROJECT_ID matches the selected environment project ID"
  echo "       (currently: ${PROJECT_ID}), then run 'terraform apply' and retry."
  exit 1
fi
echo "  ✓ ${SA_EMAIL} found."
echo ""

read -r -p "Proceed? [y/N] " confirm
if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ── Step 1: Create the Workload Identity Pool ─────────────────────────────────
# A pool is a container for external identity providers. One pool per
# environment (e.g. "github-actions-pool") is the standard pattern.
# Skips creation if the pool already exists (safe to re-run).

echo ""
echo ">>> Creating Workload Identity Pool..."
if gcloud iam workload-identity-pools describe "${POOL_ID}" \
   --project="${PROJECT_ID}" --location="global" &>/dev/null; then
  echo "  ✓ Pool '${POOL_ID}' already exists — skipping."
else
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --display-name="GitHub Actions Pool" \
    --description="Keyless auth pool for GitHub Actions CI/CD (CatVox)"
fi

# ── Step 2: Create the OIDC Provider ─────────────────────────────────────────
# Trusts tokens issued by GitHub's OIDC endpoint. The attribute mapping
# exposes repository, actor, and ref so IAM bindings can be scoped narrowly.
# The attribute condition restricts the pool to tokens from this repo only.
# Skips creation if the provider already exists (safe to re-run).

echo ""
echo ">>> Creating OIDC provider..."
if gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
   --project="${PROJECT_ID}" --location="global" \
   --workload-identity-pool="${POOL_ID}" &>/dev/null; then
  echo "  ✓ Provider '${PROVIDER_ID}' already exists — skipping."
else
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --project="${PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --display-name="GitHub Actions OIDC Provider" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository == '${GITHUB_ORG}/${GITHUB_REPO}'"
fi

# ── Step 3: Bind GitHub repo tokens to catvox-backend-sa ─────────────────────
# Only tokens whose `repository` claim matches kathelix/catvox can impersonate
# this SA. No other repo — even within the same GitHub org — can obtain access.
# add-iam-policy-binding is idempotent — safe to re-run.

echo ""
echo ">>> Binding GitHub repo to ${SA_NAME}..."
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${GITHUB_ORG}/${GITHUB_REPO}"

# ── Step 4: Grant SA read/write access to the Terraform state bucket ──────────
# The SA already has project-level roles (iam.tf) but those don't cover the
# state bucket, which is managed outside Terraform. objectAdmin is needed to
# read, write, and lock the state file during plan and apply.
# GCS IAM is cross-project — the bucket and SA can be in different GCP projects.
# add-iam-policy-binding is idempotent — safe to re-run.

echo ""
echo ">>> Granting objectAdmin on state bucket to ${SA_NAME}..."
gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin"

# ── Done — print follow-up config ─────────────────────────────────────────────

PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✓ Workload Identity Federation configured."
echo ""
echo "Add the following non-secret values to config/environments/<env>.xcconfig:"
echo ""
echo "  CATVOX_PROJECT_ID               = ${PROJECT_ID}"
echo "  CATVOX_GCP_WIF_PROVIDER        = ${PROVIDER_RESOURCE}"
echo "  CATVOX_GCP_CI_SERVICE_ACCOUNT  = ${SA_EMAIL}"
echo ""
echo "Remaining GitHub Environment secrets:"
echo "  TF_VAR_ALERT_EMAIL              = <alert recipient>"
echo "  TF_VAR_APP_CHECK_DEBUG_TOKEN    = <Dev-only App Check debug token>"
echo ""
echo "Next step: add .github/workflows/terraform.yml"
echo "════════════════════════════════════════════════════════════"
echo ""
