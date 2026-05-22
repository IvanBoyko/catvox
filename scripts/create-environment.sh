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

ENVIRONMENT="${CATVOX_ENVIRONMENT:-dev}"
PROJECT_ID="${GCP_PROJECT_ID:-${FIREBASE_PROJECT:-}}"
PROJECT_DISPLAY_NAME="${PROJECT_DISPLAY_NAME:-Kathelix CatVox ${ENVIRONMENT}}"
REGION="${CATVOX_FUNCTION_REGION:-us-central1}"
FIRESTORE_LOCATION="${CATVOX_FIRESTORE_LOCATION:-${FIRESTORE_LOCATION:-nam5}}"
STATE_BUCKET="${CATVOX_TF_STATE_BUCKET:-catvox-tf-state-${PROJECT_ID}}"
STATE_PREFIX="${CATVOX_TF_STATE_PREFIX:-catvox/state}"
BACKEND_CONFIG="${CATVOX_TF_BACKEND_CONFIG:-terraform/backend/${ENVIRONMENT}.hcl}"
TFVARS_FILE="${CATVOX_TF_VARS_FILE:-terraform/env/${ENVIRONMENT}.tfvars}"
IOS_BUNDLE_ID="${CATVOX_IOS_BUNDLE_ID:-com.kathelix.catvox.${ENVIRONMENT}}"
IOS_APP_DISPLAY_NAME="${CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME:-${FIREBASE_IOS_APP_DISPLAY_NAME:-CatVox ${ENVIRONMENT} iOS}}"
IOS_APP_DELETION_POLICY="${CATVOX_FIREBASE_IOS_APP_DELETION_POLICY:-${FIREBASE_IOS_APP_DELETION_POLICY:-ABANDON}}"
APPLE_TEAM_ID="${CATVOX_FIREBASE_APPLE_TEAM_ID:-${FIREBASE_APPLE_TEAM_ID:-QYT76L5836}}"
RUN_TERRAFORM_APPLY="${RUN_TERRAFORM_APPLY:-0}"
RUN_FUNCTIONS_DEPLOY="${RUN_FUNCTIONS_DEPLOY:-0}"
ENABLE_APP_CHECK_DEBUG_TOKEN="${CATVOX_ENABLE_APP_CHECK_DEBUG_TOKEN:-${ENABLE_APP_CHECK_DEBUG_TOKEN:-}}"
APP_CHECK_DEBUG_TOKEN_DISPLAY_NAME="${CATVOX_APP_CHECK_DEBUG_TOKEN_DISPLAY_NAME:-CatVox ${ENVIRONMENT} integration token}"
MANAGE_GCF_SOURCES_BUCKET_IAM="${CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM:-true}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "GCP_PROJECT_ID or FIREBASE_PROJECT is required." >&2
  exit 1
fi

cd "${REPO_ROOT}"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

quote_tf_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

require_tool gcloud
require_tool firebase
require_tool terraform

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

mkdir -p "$(dirname "${BACKEND_CONFIG}")" "$(dirname "${TFVARS_FILE}")"

if [[ ! -f "${BACKEND_CONFIG}" ]]; then
  cat > "${BACKEND_CONFIG}" <<EOF
bucket = "${STATE_BUCKET}"
prefix = "${STATE_PREFIX}"
EOF
  echo "Created ${BACKEND_CONFIG}"
else
  echo "Keeping existing ${BACKEND_CONFIG}"
fi

if [[ -z "${ENABLE_APP_CHECK_DEBUG_TOKEN}" ]]; then
  if [[ -n "${APP_CHECK_DEBUG_TOKEN:-}" ]]; then
    ENABLE_APP_CHECK_DEBUG_TOKEN="true"
  else
    ENABLE_APP_CHECK_DEBUG_TOKEN="false"
  fi
fi
case "$(printf '%s' "${ENABLE_APP_CHECK_DEBUG_TOKEN}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes)
    ENABLE_APP_CHECK_DEBUG_TOKEN="true"
    ;;
  0|false|no)
    ENABLE_APP_CHECK_DEBUG_TOKEN="false"
    ;;
  *)
    echo "CATVOX_ENABLE_APP_CHECK_DEBUG_TOKEN or ENABLE_APP_CHECK_DEBUG_TOKEN must be true or false." >&2
    exit 1
    ;;
esac

if [[ ! -f "${TFVARS_FILE}" ]]; then
  app_check_line='app_check_debug_token             = null'
  if [[ -n "${APP_CHECK_DEBUG_TOKEN:-}" ]]; then
    app_check_line="app_check_debug_token             = \"$(quote_tf_string "${APP_CHECK_DEBUG_TOKEN}")\""
  fi
  alert_email="${ALERT_EMAIL:-you@example.com}"
  cat > "${TFVARS_FILE}" <<EOF
${app_check_line}
alert_email           = "${alert_email}"
EOF
  echo "Created ${TFVARS_FILE}"
else
  echo "Keeping existing ${TFVARS_FILE}"
fi

export CATVOX_FUNCTION_REGION="${REGION}"
export CATVOX_FIRESTORE_LOCATION="${FIRESTORE_LOCATION}"
export CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME="${IOS_APP_DISPLAY_NAME}"
export CATVOX_FIREBASE_IOS_APP_DELETION_POLICY="${IOS_APP_DELETION_POLICY}"
export CATVOX_FIREBASE_APPLE_TEAM_ID="${APPLE_TEAM_ID}"
export CATVOX_ENABLE_APP_CHECK_DEBUG_TOKEN="${ENABLE_APP_CHECK_DEBUG_TOKEN}"
export CATVOX_APP_CHECK_DEBUG_TOKEN_DISPLAY_NAME="${APP_CHECK_DEBUG_TOKEN_DISPLAY_NAME}"
export CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM="${MANAGE_GCF_SOURCES_BUCKET_IAM}"

make terraform-init \
  CATVOX_ENVIRONMENT="${ENVIRONMENT}" \
  GCP_PROJECT_ID="${PROJECT_ID}" \
  CATVOX_TF_BACKEND_CONFIG="${BACKEND_CONFIG}" \
  CATVOX_TF_VARS_FILE="${TFVARS_FILE}"

make terraform-plan \
  CATVOX_ENVIRONMENT="${ENVIRONMENT}" \
  GCP_PROJECT_ID="${PROJECT_ID}" \
  CATVOX_TF_BACKEND_CONFIG="${BACKEND_CONFIG}" \
  CATVOX_TF_VARS_FILE="${TFVARS_FILE}"

if [[ "${RUN_TERRAFORM_APPLY}" == "1" ]]; then
  make terraform-ci-apply \
    CATVOX_ENVIRONMENT="${ENVIRONMENT}" \
    GCP_PROJECT_ID="${PROJECT_ID}" \
    CATVOX_TF_BACKEND_CONFIG="${BACKEND_CONFIG}" \
    CATVOX_TF_VARS_FILE="${TFVARS_FILE}"

  make terraform-output-firebase-plist \
    CATVOX_ENVIRONMENT="${ENVIRONMENT}" \
    GCP_PROJECT_ID="${PROJECT_ID}" \
    CATVOX_TF_BACKEND_CONFIG="${BACKEND_CONFIG}" \
    CATVOX_TF_VARS_FILE="${TFVARS_FILE}"
else
  echo "RUN_TERRAFORM_APPLY is not 1; skipped terraform apply and plist export."
fi

if [[ "${RUN_FUNCTIONS_DEPLOY}" == "1" ]]; then
  firebase functions:artifacts:setpolicy \
    --project "${PROJECT_ID}" \
    --location "${REGION}" \
    --days 7 \
    --non-interactive \
    --force

  make functions-deploy \
    CATVOX_ENVIRONMENT="${ENVIRONMENT}" \
    FIREBASE_PROJECT="${PROJECT_ID}" \
    GCP_PROJECT_ID="${PROJECT_ID}"
else
  echo "RUN_FUNCTIONS_DEPLOY is not 1; skipped Functions deploy."
fi

cat <<EOF

Remaining secrets to add to the GitHub Environment named '${ENVIRONMENT}':
  TF_VAR_ALERT_EMAIL=<same alert email used in ${TFVARS_FILE}>
  TF_VAR_APP_CHECK_DEBUG_TOKEN=<Dev only; same UUID used in ${TFVARS_FILE}>

After Terraform apply and Functions deploy, update config/environments/${ENVIRONMENT}.xcconfig with:
  GCP_PROJECT_ID=${PROJECT_ID}
  FIREBASE_PROJECT=${PROJECT_ID}
  CATVOX_PROJECT_ID=${PROJECT_ID}
  CATVOX_ENVIRONMENT=${ENVIRONMENT}
  CATVOX_FUNCTION_REGION=${REGION}
  CATVOX_FIRESTORE_LOCATION=${FIRESTORE_LOCATION}
  CATVOX_TF_STATE_BUCKET=${STATE_BUCKET}
  CATVOX_GCP_CI_SERVICE_ACCOUNT=catvox-ci-sa@${PROJECT_ID}.iam.gserviceaccount.com
  CATVOX_GCP_WIF_PROVIDER=projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider
  CATVOX_PRODUCT_BUNDLE_IDENTIFIER=${IOS_BUNDLE_ID}
  CATVOX_IOS_BUNDLE_ID=${IOS_BUNDLE_ID}
  CATVOX_FIREBASE_IOS_APP_DISPLAY_NAME=${IOS_APP_DISPLAY_NAME}
  CATVOX_FIREBASE_IOS_APP_DELETION_POLICY=${IOS_APP_DELETION_POLICY}
  CATVOX_FIREBASE_APPLE_TEAM_ID=${APPLE_TEAM_ID}
  CATVOX_ENABLE_APP_CHECK_DEBUG_TOKEN=${ENABLE_APP_CHECK_DEBUG_TOKEN}
  CATVOX_APP_CHECK_DEBUG_TOKEN_DISPLAY_NAME=${APP_CHECK_DEBUG_TOKEN_DISPLAY_NAME}
  CATVOX_MANAGE_GCF_SOURCES_BUCKET_IAM=${MANAGE_GCF_SOURCES_BUCKET_IAM}
  CATVOX_SIGNED_UPLOAD_URL_HOST=<getSignedUploadURL Cloud Run host only>
  CATVOX_ANALYSE_VIDEO_HOST=<analyseVideo Cloud Run host only>
EOF
