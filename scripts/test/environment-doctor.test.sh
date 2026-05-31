#!/usr/bin/env bash
# Behaviour test for scripts/environment-doctor.sh.
#
# Runs the real script against a PATH-mocked `gcloud` (hermetic env via `env -i`).
# The mock answers each check from MOCK_* variables. Asserts the all-good run
# passes, each FAIL condition exits non-zero with an actionable message, and the
# Artifact Registry check is WARN-only (does not fail the run).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/environment-doctor.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; pass=$((pass + 1)); }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

cat > "$SANDBOX/bin/gcloud" <<'SH'
#!/usr/bin/env bash
args="$*"
# Order matters: more-specific patterns first. The MOCK_* defaults below use the
# ${VAR-default} (unset-only) form so a case can override one to "" to force a
# FAIL while every other check stays green.
case "$args" in
  *"billing projects describe"*) printf '%s\n' "${MOCK_BILLING:-True}";;
  *projectNumber*) printf '%s\n' "${MOCK_PROJECT_NUMBER-123456}";;
  *"services list"*) printf '%s\n' "${MOCK_APIS:-}";;
  *"providers describe"*attributeMapping*) printf '%s\n' "${MOCK_WIF_MAP-assertion.environment}";;
  *"providers describe"*)
     printf '%s\n' "${MOCK_WIF_COND:-assertion.repository == 'kathelix/catvox' && assertion.environment == 'sbx'}";;
  *"workload-identity-pools describe"*) printf '%s\n' "${MOCK_WIF_STATE:-ACTIVE}";;
  *"service-accounts get-iam-policy"*catvox-ci-sa*)
     printf '%s\n' "${MOCK_WIF_BINDING-principalSet://iam.googleapis.com/projects/123456/locations/global/workloadIdentityPools/github-actions-pool/attribute.environment/sbx}";;
  *"service-accounts get-iam-policy"*catvox-backend-sa*)
     printf '%s\n' "${MOCK_BACKEND_SAU-serviceAccount:123456-compute@developer.gserviceaccount.com}";;
  *"buckets get-iam-policy"*) printf '%s\n' "${MOCK_SRC_IAM-serviceAccount:123456-compute@developer.gserviceaccount.com}";;
  *"get-iam-policy"*"-compute@developer"*) printf '%s\n' "${MOCK_COMPUTE_ROLES-roles/artifactregistry.writer
roles/logging.logWriter}";;
  *"get-iam-policy"*) printf '%s\n' "${MOCK_ROLES:-}";;
  *"artifacts repositories describe"*)
     [[ -n "${MOCK_NO_ARTIFACT:-}" ]] && exit 1
     case "$args" in
       *cleanupPolicies*) printf '%s\n' "${MOCK_ARTIFACT_POLICY:-keep-7d}";;
       *) printf 'projects/proj/locations/us-central1/repositories/catvox-functions\n';;
     esac;;
  *"buckets describe"*gcf-v2-sources*) [[ -n "${MOCK_NO_SRCBUCKET:-}" ]] && exit 1; exit 0;;
  *"buckets describe"*) [[ -n "${MOCK_NO_BUCKET:-}" ]] && exit 1; exit 0;;
  *) exit 1;;
esac
SH
chmod +x "$SANDBOX/bin/gcloud"

PATH_HERMETIC="$SANDBOX/bin:/usr/bin:/bin"

# Full "everything present" fixtures — keep in sync with the script's arrays.
ALL_APIS="aiplatform.googleapis.com
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
clouderrorreporting.googleapis.com"
ALL_ROLES="roles/editor
roles/resourcemanager.projectIamAdmin
roles/iam.serviceAccountAdmin
roles/secretmanager.secretAccessor
roles/cloudfunctions.admin"

run() {  # trailing KEY=val overrides win over the all-good defaults
  env -i PATH="$PATH_HERMETIC" \
    CATVOX_ENVIRONMENT=sbx CATVOX_PROJECT_ID=proj CATVOX_FUNCTION_REGION=us-central1 \
    CATVOX_GCP_CI_SERVICE_ACCOUNT=catvox-ci-sa@proj.iam.gserviceaccount.com \
    CATVOX_GCP_WIF_PROVIDER="projects/123/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider" \
    CATVOX_TF_STATE_BUCKET=catvox-tf-state-proj \
    MOCK_APIS="$ALL_APIS" MOCK_ROLES="$ALL_ROLES" \
    "$@" bash "$SCRIPT"
}

# 1. All good -> exit 0, reports passed.
run >"$SANDBOX/out1" 2>&1 || fail "S1 all-good run should pass: $(cat "$SANDBOX/out1")"
grep -q "environment-doctor passed." "$SANDBOX/out1" || fail "S1 missing pass line"
ok "all-good environment passes"

# 2. Missing cloudfunctions.admin -> fail, names the role.
ROLES_NO_CF="roles/editor
roles/resourcemanager.projectIamAdmin
roles/iam.serviceAccountAdmin
roles/secretmanager.secretAccessor"
if run MOCK_ROLES="$ROLES_NO_CF" >"$SANDBOX/out2" 2>&1; then fail "S2 expected failure"; fi
grep -q "roles/cloudfunctions.admin" "$SANDBOX/out2" || fail "S2 should name the missing role"
ok "missing cloudfunctions.admin fails with the role named"

# 3. WIF provider not scoped to this environment -> fail.
if run MOCK_WIF_COND="assertion.repository == 'kathelix/catvox'" >"$SANDBOX/out3" 2>&1; then fail "S3 expected failure"; fi
grep -q "not scoped to environment" "$SANDBOX/out3" || fail "S3 should report scoping failure"
ok "WIF provider not env-scoped fails"

# 4. WIF pool soft-deleted -> fail with undelete hint.
if run MOCK_WIF_STATE=DELETED >"$SANDBOX/out4" 2>&1; then fail "S4 expected failure"; fi
grep -q "soft-deleted" "$SANDBOX/out4" || fail "S4 should report soft-delete"
ok "soft-deleted WIF pool fails"

# 5. A disabled API -> fail.
APIS_MISSING="$(printf '%s\n' "$ALL_APIS" | grep -v '^run.googleapis.com$')"
if run MOCK_APIS="$APIS_MISSING" >"$SANDBOX/out5" 2>&1; then fail "S5 expected failure"; fi
grep -q "disabled APIs" "$SANDBOX/out5" || fail "S5 should report disabled APIs"
ok "a disabled API fails"

# 6. Artifact repo absent -> WARN only, run still passes.
run MOCK_NO_ARTIFACT=1 >"$SANDBOX/out6" 2>&1 || fail "S6 artifact-absent should not fail the run"
grep -q "not present yet" "$SANDBOX/out6" || fail "S6 expected artifact WARN"
ok "absent artifact repo is WARN-only"

# 7. Billing not linked -> fail.
if run MOCK_BILLING=False >"$SANDBOX/out7" 2>&1; then fail "S7 expected failure"; fi
grep -q "billing is not linked" "$SANDBOX/out7" || fail "S7 should report billing"
ok "unlinked billing fails"

# 8. State bucket unreachable -> fail.
if run MOCK_NO_BUCKET=1 >"$SANDBOX/out8" 2>&1; then fail "S8 expected failure"; fi
grep -q "state bucket" "$SANDBOX/out8" || fail "S8 should report bucket"
ok "unreachable state bucket fails"

# 9. Missing WIF impersonation binding (the #101 break) -> fail (G1).
if run MOCK_WIF_BINDING= >"$SANDBOX/out9" 2>&1; then fail "S9 expected failure"; fi
grep -q "roles/iam.workloadIdentityUser" "$SANDBOX/out9" || fail "S9 should name the impersonation binding"
ok "missing WIF impersonation binding fails"

# 10. WIF provider attribute_mapping drops attribute.environment -> fail (G2).
if run MOCK_WIF_MAP= >"$SANDBOX/out10" 2>&1; then fail "S10 expected failure"; fi
grep -q "attribute_mapping" "$SANDBOX/out10" || fail "S10 should report the mapping gap"
ok "missing attribute.environment mapping fails"

# 11. Compute SA missing a Gen2-build role -> fail, names it (G3).
if run MOCK_COMPUTE_ROLES=roles/logging.logWriter >"$SANDBOX/out11" 2>&1; then fail "S11 expected failure"; fi
grep -q "roles/artifactregistry.writer" "$SANDBOX/out11" || fail "S11 should name the missing compute-SA role"
ok "compute SA missing artifactregistry.writer fails"

# 12. Compute SA cannot actAs the backend SA -> fail (G3).
if run MOCK_BACKEND_SAU= >"$SANDBOX/out12" 2>&1; then fail "S12 expected failure"; fi
grep -q "serviceAccountUser" "$SANDBOX/out12" || fail "S12 should report the actAs gap"
ok "compute SA missing actAs on backend SA fails"

# 13. gcf-v2-sources objectAdmin missing -> WARN only, run still passes (G3).
run MOCK_SRC_IAM= >"$SANDBOX/out13" 2>&1 || fail "S13 source-bucket IAM should be WARN-only: $(cat "$SANDBOX/out13")"
grep -q "storage.objectAdmin" "$SANDBOX/out13" || fail "S13 expected a source-bucket WARN"
ok "missing gcf-sources objectAdmin is WARN-only"

# 14. Project number unresolved -> compute-SA checks skipped (WARN), run passes.
run MOCK_PROJECT_NUMBER= >"$SANDBOX/out14" 2>&1 || fail "S14 should degrade gracefully: $(cat "$SANDBOX/out14")"
grep -q "skipped compute-SA" "$SANDBOX/out14" || fail "S14 expected compute-SA skip WARN"
ok "unresolved project number skips compute-SA checks (WARN)"

echo "PASS ($pass cases)"
