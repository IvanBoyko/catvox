#!/usr/bin/env bash
# Bootstrap a named CatVox GCP/Firebase environment.
#
# This script is intentionally environment-name based. It creates or verifies
# the GCP/Firebase project, bootstraps remote Terraform state and Functions
# source storage, prepares ignored local Terraform config files, and can
# optionally apply Terraform, export the Firebase plist, and deploy Functions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENVIRONMENT="${CATVOX_ENVIRONMENT:-}"
PROJECT_ID="${CATVOX_PROJECT_ID:-}"
PROJECT_DISPLAY_NAME="${PROJECT_DISPLAY_NAME:-}"
REGION="${CATVOX_FUNCTION_REGION:-}"
FIRESTORE_LOCATION="${CATVOX_FIRESTORE_LOCATION:-}"
STATE_BUCKET="${CATVOX_TF_STATE_BUCKET:-}"
STATE_PREFIX="${CATVOX_TF_STATE_PREFIX:-}"
TFVARS_FILE="${CATVOX_TF_VARS_FILE:-}"
IOS_BUNDLE_ID="${CATVOX_IOS_BUNDLE_ID:-}"
IOS_APP_DISPLAY_NAME="${CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME:-}"
IOS_APP_DELETION_POLICY="${CATVOX_FIREBASE_IOS_APP_DELETION_POLICY:-}"
APPLE_TEAM_ID="${CATVOX_FIREBASE_APPLE_TEAM_ID:-}"
RUN_TERRAFORM_APPLY="${RUN_TERRAFORM_APPLY:-}"
RUN_FUNCTIONS_DEPLOY="${RUN_FUNCTIONS_DEPLOY:-}"
RUN_POSTHOG_TERRAFORM_APPLY="${RUN_POSTHOG_TERRAFORM_APPLY:-}"
MANAGE_GCF_SOURCES_BUCKET_IAM="${CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM:-}"

cd "${REPO_ROOT}"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

require_value() {
  local name="$1"
  local value="$2"

  if [[ -z "$value" ]]; then
    echo "${name} is required." >&2
    exit 1
  fi
}

normalize_bool() {
  local name="$1"
  local value="$2"
  local normalized

  normalized="$(printf '%s' "$value" | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print tolower($0); }')"
  case "$normalized" in
    true|false)
      printf '%s' "$normalized"
      ;;
    *)
      echo "${name} must be true or false." >&2
      exit 1
      ;;
  esac
}

quote_tf_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

require_value CATVOX_ENVIRONMENT "${ENVIRONMENT}"
require_value CATVOX_PROJECT_ID "${PROJECT_ID}"
require_value PROJECT_DISPLAY_NAME "${PROJECT_DISPLAY_NAME}"
require_value CATVOX_FUNCTION_REGION "${REGION}"
require_value CATVOX_FIRESTORE_LOCATION "${FIRESTORE_LOCATION}"
require_value CATVOX_TF_STATE_BUCKET "${STATE_BUCKET}"
require_value CATVOX_TF_STATE_PREFIX "${STATE_PREFIX}"
require_value CATVOX_TF_VARS_FILE "${TFVARS_FILE}"
require_value CATVOX_IOS_BUNDLE_ID "${IOS_BUNDLE_ID}"
require_value CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME "${IOS_APP_DISPLAY_NAME}"
require_value CATVOX_FIREBASE_IOS_APP_DELETION_POLICY "${IOS_APP_DELETION_POLICY}"
require_value CATVOX_FIREBASE_APPLE_TEAM_ID "${APPLE_TEAM_ID}"
require_value RUN_TERRAFORM_APPLY "${RUN_TERRAFORM_APPLY}"
require_value RUN_FUNCTIONS_DEPLOY "${RUN_FUNCTIONS_DEPLOY}"
require_value RUN_POSTHOG_TERRAFORM_APPLY "${RUN_POSTHOG_TERRAFORM_APPLY}"
require_value CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM "${MANAGE_GCF_SOURCES_BUCKET_IAM}"

MANAGE_GCF_SOURCES_BUCKET_IAM="$(normalize_bool CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM "${MANAGE_GCF_SOURCES_BUCKET_IAM}")"

case "${RUN_POSTHOG_TERRAFORM_APPLY}" in
  0|1)
    ;;
  *)
    echo "RUN_POSTHOG_TERRAFORM_APPLY must be 0 or 1." >&2
    exit 1
    ;;
esac

require_tool gcloud
require_tool firebase
require_tool terraform
require_tool node

echo "Environment : ${ENVIRONMENT}"
echo "Project     : ${PROJECT_ID}"
echo "Region      : ${REGION}"
echo "State bucket: gs://${STATE_BUCKET}/${STATE_PREFIX}"
echo ""

case "${IOS_APP_DELETION_POLICY}" in
  ABANDON|DELETE)
    ;;
  *)
    echo "FIREBASE_IOS_APP_DELETION_POLICY must be ABANDON or DELETE." >&2
    exit 1
    ;;
esac

if gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "GCP project ${PROJECT_ID} already exists."
else
  create_args=(projects create "${PROJECT_ID}" "--name=${PROJECT_DISPLAY_NAME}")
  if [[ -n "${ORGANIZATION_ID:-}" ]]; then
    create_args+=("--organization=${ORGANIZATION_ID}")
  elif [[ -n "${FOLDER_ID:-}" ]]; then
    create_args+=("--folder=${FOLDER_ID}")
  fi
  gcloud "${create_args[@]}"
fi

if [[ -n "${BILLING_ACCOUNT_ID:-}" ]]; then
  gcloud billing projects link "${PROJECT_ID}" --billing-account="${BILLING_ACCOUNT_ID}"
else
  echo "BILLING_ACCOUNT_ID not set; skipping billing link."
fi

if firebase projects:list --json --non-interactive | grep -q "\"projectId\": \"${PROJECT_ID}\""; then
  echo "Firebase is already enabled for ${PROJECT_ID}."
else
  firebase projects:addfirebase "${PROJECT_ID}" --non-interactive
fi

if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Terraform state bucket ${STATE_BUCKET} already exists."
else
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
  gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
fi

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
GCF_SOURCES_BUCKET="gcf-v2-sources-${PROJECT_NUMBER}-${REGION}"

if gcloud storage buckets describe "gs://${GCF_SOURCES_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Cloud Functions source bucket ${GCF_SOURCES_BUCKET} already exists."
else
  gcloud storage buckets create "gs://${GCF_SOURCES_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
fi

mkdir -p "$(dirname "${TFVARS_FILE}")"

if [[ ! -f "${TFVARS_FILE}" ]]; then
  require_value ALERT_EMAIL "${ALERT_EMAIL:-}"

  app_check_line='app_check_debug_token             = null'
  if [[ -n "${APP_CHECK_DEBUG_TOKEN:-}" ]]; then
    app_check_line="app_check_debug_token             = \"$(quote_tf_string "${APP_CHECK_DEBUG_TOKEN}")\""
  fi
  cat > "${TFVARS_FILE}" <<EOF
${app_check_line}
alert_email           = "$(quote_tf_string "${ALERT_EMAIL}")"
EOF
  echo "Created ${TFVARS_FILE}"
else
  echo "Keeping existing ${TFVARS_FILE}"
fi

export CATVOX_ENVIRONMENT="${ENVIRONMENT}"
export CATVOX_PROJECT_ID="${PROJECT_ID}"
export CATVOX_FUNCTION_REGION="${REGION}"
export CATVOX_FIRESTORE_LOCATION="${FIRESTORE_LOCATION}"
export CATVOX_TF_STATE_BUCKET="${STATE_BUCKET}"
export CATVOX_TF_STATE_PREFIX="${STATE_PREFIX}"
export CATVOX_TF_VARS_FILE="${TFVARS_FILE}"
export CATVOX_IOS_BUNDLE_ID="${IOS_BUNDLE_ID}"
export CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME="${IOS_APP_DISPLAY_NAME}"
export CATVOX_FIREBASE_IOS_APP_DELETION_POLICY="${IOS_APP_DELETION_POLICY}"
export CATVOX_FIREBASE_APPLE_TEAM_ID="${APPLE_TEAM_ID}"
export CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM="${MANAGE_GCF_SOURCES_BUCKET_IAM}"

make terraform-init \
  CATVOX_ENVIRONMENT="${ENVIRONMENT}" \
  CATVOX_PROJECT_ID="${PROJECT_ID}" \
  CATVOX_TF_VARS_FILE="${TFVARS_FILE}"

# Import pre-existing resources (idempotent) so applying into a project that
# already contains them succeeds instead of failing ALREADY_EXISTS. No-op for a
# brand-new project. See docs/CREATE_NEW_ENVIRONMENT.md and issue #38 Step 3 (S5).
./scripts/import-preexisting-resources.sh

make terraform-plan \
  CATVOX_ENVIRONMENT="${ENVIRONMENT}" \
  CATVOX_PROJECT_ID="${PROJECT_ID}" \
  CATVOX_TF_VARS_FILE="${TFVARS_FILE}"

if [[ "${RUN_TERRAFORM_APPLY}" == "1" ]]; then
  make terraform-ci-apply \
    CATVOX_ENVIRONMENT="${ENVIRONMENT}" \
    CATVOX_PROJECT_ID="${PROJECT_ID}" \
    CATVOX_TF_VARS_FILE="${TFVARS_FILE}"

  make terraform-output-firebase-plist \
    CATVOX_ENVIRONMENT="${ENVIRONMENT}" \
    CATVOX_PROJECT_ID="${PROJECT_ID}" \
    CATVOX_TF_VARS_FILE="${TFVARS_FILE}"
else
  echo "RUN_TERRAFORM_APPLY is not 1; skipped terraform apply and plist export."
fi

if [[ "${RUN_POSTHOG_TERRAFORM_APPLY}" == "1" ]]; then
  make posthog-environment-provision \
    CATVOX_ENVIRONMENT="${ENVIRONMENT}"
else
  echo "RUN_POSTHOG_TERRAFORM_APPLY is not 1; skipped PostHog Terraform apply."
fi

if [[ "${RUN_FUNCTIONS_DEPLOY}" == "1" ]]; then
  # make functions-deploy sets the Artifact Registry cleanup policy itself.
  make functions-deploy \
    CATVOX_ENVIRONMENT="${ENVIRONMENT}" \
    CATVOX_PROJECT_ID="${PROJECT_ID}"
else
  echo "RUN_FUNCTIONS_DEPLOY is not 1; skipped Functions deploy."
fi

cat <<EOF

Remaining secrets to add to the GitHub Environment named '${ENVIRONMENT}':
  TF_VAR_ALERT_EMAIL=<same alert email used in ${TFVARS_FILE}>
  TF_VAR_APP_CHECK_DEBUG_TOKEN=<Dev only; same UUID used in ${TFVARS_FILE}>
  POSTHOG_API_KEY=<already set by RUN_POSTHOG_TERRAFORM_APPLY=1, otherwise set manually>

After Terraform apply and Functions deploy, update config/environments/${ENVIRONMENT}.xcconfig with:
  CATVOX_PROJECT_ID=${PROJECT_ID}
  CATVOX_ENVIRONMENT=${ENVIRONMENT}
  CATVOX_FUNCTION_REGION=${REGION}
  CATVOX_FIRESTORE_LOCATION=${FIRESTORE_LOCATION}
  CATVOX_TF_STATE_BUCKET=${STATE_BUCKET}
  CATVOX_GCP_CI_SERVICE_ACCOUNT=catvox-ci-sa@${PROJECT_ID}.iam.gserviceaccount.com
  CATVOX_GCP_WIF_PROVIDER=projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider
  CATVOX_IOS_BUNDLE_ID=${IOS_BUNDLE_ID}
  CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME=${IOS_APP_DISPLAY_NAME}
  CATVOX_FIREBASE_IOS_APP_DELETION_POLICY=${IOS_APP_DELETION_POLICY}
  CATVOX_FIREBASE_APPLE_TEAM_ID=${APPLE_TEAM_ID}
  CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM=${MANAGE_GCF_SOURCES_BUCKET_IAM}
  CATVOX_SIGNED_UPLOAD_URL_HOST=<getSignedUploadURL Cloud Run host only>
  CATVOX_ANALYSE_VIDEO_HOST=<analyseVideo Cloud Run host only>
EOF
