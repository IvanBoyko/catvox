#!/usr/bin/env bash
# Guarded helper for cleaning Dev leftovers from the preserved old project ID.
#
# This script intentionally does not delete the GCP/Firebase project. The
# project ID must remain available for the future real Prod slice.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-kathelix-catvox-prod}"
EXPECTED_PROJECT_ID="kathelix-catvox-prod"
CONFIRM="${CONFIRM:-}"
REGION="${REGION:-us-central1}"
STATE_BUCKET="${STATE_BUCKET:-catvox-tf-state-kathelix-catvox-prod}"
WIF_POOL_ID="${WIF_POOL_ID:-github-actions-pool}"

if [[ "${PROJECT_ID}" != "${EXPECTED_PROJECT_ID}" ]]; then
  echo "Refusing to clean unexpected project: ${PROJECT_ID}" >&2
  exit 1
fi

if [[ "${CONFIRM}" != "cleanup-${EXPECTED_PROJECT_ID}" ]]; then
  cat >&2 <<EOF
Refusing to clean ${EXPECTED_PROJECT_ID}.
Re-run with:
  CONFIRM=cleanup-${EXPECTED_PROJECT_ID} ./scripts/cleanup-legacy-presplit-project.sh

Run this only after kathelix-catvox-dev deploy, integration, and device-scan
proof are complete and active GitHub Dev secrets no longer point at this project.
EOF
  exit 1
fi

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

require_tool gcloud
require_tool firebase
require_tool curl
require_tool node

echo "Cleaning preserved legacy project ${PROJECT_ID}; project will not be deleted."

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"

if gcloud functions list --project="${PROJECT_ID}" --regions="${REGION}" --format='value(name)' | grep -q .; then
  while read -r function_name; do
    [[ -z "${function_name}" ]] && continue
    gcloud functions delete "${function_name}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --quiet || true
  done < <(gcloud functions list --project="${PROJECT_ID}" --regions="${REGION}" --format='value(name)')
fi

for bucket_pattern in \
  "^catvox-raw-videos-${PROJECT_ID}$" \
  "^gcf-v2-sources-[0-9]+-${REGION}$" \
  "^gcf-v2-uploads-[0-9]+\\.${REGION}\\.cloudfunctions\\.appspot\\.com$"; do
  while read -r bucket_name; do
    [[ -z "${bucket_name}" ]] && continue
    gcloud storage rm --recursive "gs://${bucket_name}/" --quiet || true
  done < <(gcloud storage buckets list --project="${PROJECT_ID}" --format='value(name)' | grep -E "${bucket_pattern}" || true)
done

if gcloud artifacts repositories describe catvox-functions \
  --project="${PROJECT_ID}" --location="${REGION}" >/dev/null 2>&1; then
  gcloud artifacts repositories delete catvox-functions \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --quiet || true
fi

for secret in APP_CHECK_DEBUG_TOKEN GCP_PROJECT_ID; do
  if gcloud secrets describe "${secret}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud secrets delete "${secret}" --project="${PROJECT_ID}" --quiet || true
  fi
done

for service_account in catvox-backend-sa catvox-ci-sa; do
  email="${service_account}@${PROJECT_ID}.iam.gserviceaccount.com"
  if gcloud iam service-accounts describe "${email}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud iam service-accounts delete "${email}" --project="${PROJECT_ID}" --quiet || true
  fi
done

if gcloud iam workload-identity-pools describe "${WIF_POOL_ID}" \
  --project="${PROJECT_ID}" --location=global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools delete "${WIF_POOL_ID}" \
    --project="${PROJECT_ID}" \
    --location=global \
    --quiet || true
fi

while read -r app_id; do
  [[ -z "${app_id}" ]] && continue
  token_list="$(
    curl --silent --fail \
      --header "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://firebaseappcheck.googleapis.com/v1/projects/${PROJECT_NUMBER}/apps/${app_id}/debugTokens" || true
  )"
  while read -r token_name; do
    [[ -z "${token_name}" ]] && continue
    curl --silent --fail \
      --request DELETE \
      --header "Authorization: Bearer $(gcloud auth print-access-token)" \
      "https://firebaseappcheck.googleapis.com/v1/${token_name}" >/dev/null || true
    echo "Deleted App Check debug token ${token_name}"
  done < <(printf '%s' "${token_list}" | node -e '
let raw = "";
process.stdin.on("data", chunk => raw += chunk);
process.stdin.on("end", () => {
  if (!raw.trim()) {
    return;
  }
  const parsed = JSON.parse(raw);
  for (const token of parsed.debugTokens || []) {
    console.log(token.name);
  }
});
')
  echo "Firebase iOS app still exists and must be removed through Firebase console/API if safe: ${app_id}"
done < <(firebase apps:list IOS --project "${PROJECT_ID}" --json | node -e '
let raw = "";
process.stdin.on("data", chunk => raw += chunk);
process.stdin.on("end", () => {
  const parsed = JSON.parse(raw);
  for (const app of parsed.result || []) {
    console.log(app.appId);
  }
});
')

if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Leaving state bucket deletion for the final manual step after the cleanup report: gs://${STATE_BUCKET}"
fi

echo "Legacy cleanup command pass complete. Verify the cleanup report before future Prod work."
