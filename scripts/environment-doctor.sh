#!/usr/bin/env bash
# Read-only preflight for a CatVox environment: assert the provisioning
# prerequisites that, when missing, otherwise surface only as a mid-deploy
# failure. Fails fast with an actionable hint instead. Issue #109.
#
# Environment-agnostic: keyed entirely off CATVOX_ENVIRONMENT and the matching
# config/environments/<env>.xcconfig values; no literal environment names.
# Mutates nothing — safe to run anytime.
#
# Checks (each PASS / WARN / FAIL):
#   - billing linked on the project
#   - required GCP APIs enabled
#   - catvox-ci-sa holds the expected roles (incl. roles/cloudfunctions.admin,
#     the one a first new-function deploy needs and roles/editor lacks)
#   - the WIF pool is ACTIVE and its provider is scoped to this environment
#   - (WARN-only) the Functions Artifact Registry cleanup policy
#   - the Terraform state bucket is reachable
#
# Exit non-zero if any check FAILs; WARNs do not fail the run.

set -uo pipefail

ENVIRONMENT="${CATVOX_ENVIRONMENT:?CATVOX_ENVIRONMENT is required}"
PROJECT_ID="${CATVOX_PROJECT_ID:?CATVOX_PROJECT_ID is required}"
REGION="${CATVOX_FUNCTION_REGION:-}"
GITHUB_REPO="${CATVOX_GITHUB_REPO:-kathelix/catvox}"
CI_SA="${CATVOX_GCP_CI_SERVICE_ACCOUNT:-catvox-ci-sa@${PROJECT_ID}.iam.gserviceaccount.com}"
STATE_BUCKET="${CATVOX_TF_STATE_BUCKET:-catvox-tf-state-${PROJECT_ID}}"
WIF_PROVIDER_RESOURCE="${CATVOX_GCP_WIF_PROVIDER:-}"

command -v gcloud >/dev/null 2>&1 || { echo "Missing required tool: gcloud" >&2; exit 1; }

# Roles catvox-ci-sa must hold (keep in sync with terraform/iam.tf).
# cloudfunctions.admin is the one roles/editor excludes (it grants
# cloudfunctions.functions.setIamPolicy, required to deploy a *new* function).
REQUIRED_ROLES=(
  roles/editor
  roles/resourcemanager.projectIamAdmin
  roles/iam.serviceAccountAdmin
  roles/secretmanager.secretAccessor
  roles/cloudfunctions.admin
)

# Required GCP APIs (keep in sync with terraform/main.tf google_project_service).
REQUIRED_APIS=(
  aiplatform.googleapis.com
  cloudfunctions.googleapis.com
  cloudbuild.googleapis.com
  run.googleapis.com
  eventarc.googleapis.com
  pubsub.googleapis.com
  firestore.googleapis.com
  storage.googleapis.com
  secretmanager.googleapis.com
  firebase.googleapis.com
  firebaseextensions.googleapis.com
  firebaseappcheck.googleapis.com
  iam.googleapis.com
  artifactregistry.googleapis.com
  cloudbilling.googleapis.com
  compute.googleapis.com
  monitoring.googleapis.com
  clouderrorreporting.googleapis.com
)

# Derive the WIF pool/provider ids from the committed resource name when present,
# else fall back to the Terraform defaults (terraform/variables.tf).
WIF_POOL=""
WIF_PROVIDER=""
if [[ -n "$WIF_PROVIDER_RESOURCE" ]]; then
  WIF_POOL="$(printf '%s' "$WIF_PROVIDER_RESOURCE" | sed -nE 's#.*/workloadIdentityPools/([^/]+)/providers/.*#\1#p')"
  WIF_PROVIDER="$(printf '%s' "$WIF_PROVIDER_RESOURCE" | sed -nE 's#.*/providers/([^/]+).*#\1#p')"
fi
WIF_POOL="${WIF_POOL:-github-actions-pool}"
WIF_PROVIDER="${WIF_PROVIDER:-github-actions-provider}"

problems=0
warns=0
pass() { printf '  PASS: %s\n' "$*"; }
warn() { printf '  WARN: %s\n' "$*" >&2; warns=$((warns + 1)); }
fail() { printf '  FAIL: %s\n' "$*" >&2; problems=$((problems + 1)); }

echo "environment-doctor: ${ENVIRONMENT} (${PROJECT_ID})"
echo

# 1 — Billing linked.
echo "Billing:"
billing="$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || true)"
if [[ "$billing" == "True" ]]; then
  pass "billing is linked"
else
  fail "billing is not linked to ${PROJECT_ID} — link a billing account before deploy"
fi

# 2 — Required APIs enabled.
echo "APIs:"
enabled_apis="$(gcloud services list --enabled --project "$PROJECT_ID" --format='value(config.name)' 2>/dev/null || true)"
missing_apis=()
for api in "${REQUIRED_APIS[@]}"; do
  printf '%s\n' "$enabled_apis" | grep -qxF "$api" || missing_apis+=("$api")
done
if [[ "${#missing_apis[@]}" -eq 0 ]]; then
  pass "all ${#REQUIRED_APIS[@]} required APIs enabled"
else
  fail "disabled APIs: ${missing_apis[*]} — enable via terraform apply (google_project_service.apis)"
fi

# 3 — CI service account roles (the cloudfunctions.admin gap lives here).
echo "CI service account roles (${CI_SA}):"
ci_roles="$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten='bindings[].members' \
  --filter="bindings.members:serviceAccount:${CI_SA}" \
  --format='value(bindings.role)' 2>/dev/null || true)"
missing_roles=()
for role in "${REQUIRED_ROLES[@]}"; do
  printf '%s\n' "$ci_roles" | grep -qxF "$role" || missing_roles+=("$role")
done
if [[ "${#missing_roles[@]}" -eq 0 ]]; then
  pass "all ${#REQUIRED_ROLES[@]} required roles present"
else
  fail "missing roles: ${missing_roles[*]} — grant via terraform apply (terraform/iam.tf)"
fi

# 4 — WIF pool ACTIVE + provider scoped to this environment.
echo "Workload Identity Federation (pool=${WIF_POOL}, provider=${WIF_PROVIDER}):"
wif_state="$(gcloud iam workload-identity-pools describe "$WIF_POOL" \
  --location=global --project "$PROJECT_ID" --format='value(state)' 2>/dev/null || true)"
case "$wif_state" in
  ACTIVE) pass "WIF pool is ACTIVE" ;;
  DELETED) fail "WIF pool is soft-deleted — undelete it, or use a fresh project (see docs/CREATE_NEW_ENVIRONMENT.md)" ;;
  *) fail "WIF pool '${WIF_POOL}' not found in ${PROJECT_ID}" ;;
esac

wif_cond="$(gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
  --workload-identity-pool="$WIF_POOL" --location=global --project "$PROJECT_ID" \
  --format='value(attributeCondition)' 2>/dev/null || true)"
if [[ -z "$wif_cond" ]]; then
  fail "WIF provider '${WIF_PROVIDER}' not found or has no attribute condition"
else
  if printf '%s' "$wif_cond" | grep -qF "assertion.environment == '${ENVIRONMENT}'" \
     && printf '%s' "$wif_cond" | grep -qF "assertion.repository == '${GITHUB_REPO}'"; then
    pass "WIF provider is scoped to environment '${ENVIRONMENT}' and repo '${GITHUB_REPO}'"
  else
    fail "WIF provider attribute condition is not scoped to environment '${ENVIRONMENT}' + repo '${GITHUB_REPO}'"
  fi
fi
echo "  note: WIF pool/provider/binding changes must be applied operator-local (catvox-ci-sa lacks workloadIdentityPoolAdmin)."

# 5 — Functions Artifact Registry cleanup policy (informational; set by deploy).
echo "Artifact Registry (Functions images):"
if [[ -z "$REGION" ]]; then
  warn "CATVOX_FUNCTION_REGION unset — skipped Artifact Registry check"
elif gcloud artifacts repositories describe catvox-functions \
       --location="$REGION" --project "$PROJECT_ID" --format='value(name)' >/dev/null 2>&1; then
  policy="$(gcloud artifacts repositories describe catvox-functions \
    --location="$REGION" --project "$PROJECT_ID" --format='value(cleanupPolicies)' 2>/dev/null || true)"
  if [[ -n "$policy" ]]; then
    pass "Functions artifact repo has a cleanup policy"
  else
    warn "Functions artifact repo has no cleanup policy — 'make functions-deploy' sets it"
  fi
else
  warn "Functions artifact repo not present yet — created on first deploy; 'make functions-deploy' sets the cleanup policy"
fi

# 6 — Terraform state bucket reachable.
echo "Terraform state bucket (${STATE_BUCKET}):"
if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project "$PROJECT_ID" >/dev/null 2>&1; then
  pass "state bucket is reachable"
else
  fail "state bucket gs://${STATE_BUCKET} is not reachable — create it before init (see scripts/create-environment.sh)"
fi

echo
echo "Summary for ${ENVIRONMENT}: ${problems} problem(s), ${warns} warning(s)."
if [[ "$problems" -ne 0 ]]; then
  echo "environment-doctor FAILED — resolve the FAIL items above before deploying." >&2
  exit 1
fi
echo "environment-doctor passed."
