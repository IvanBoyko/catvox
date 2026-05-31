#!/usr/bin/env bash
# Behaviour test for scripts/write-environment-config.sh.
#
# Runs the real script against PATH-mocked `terraform`, `plutil`, and `gcloud`
# (hermetic env via `env -i` so a parent `make` cannot leak CATVOX_* values),
# writing into a sandbox xcconfig. Asserts: identity values land verbatim
# (slashes/colons preserved, no trailing-`%`/whitespace), idempotent re-runs,
# host-only stripping, lenient skip when a function is not deployed, and append
# of an absent key.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/write-environment-config.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; pass=$((pass + 1)); }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

# ── Mocked CLIs ─────────────────────────────────────────────────────────────
# terraform: echo a canned value for the output name following `-raw`. Trailing
# whitespace is intentional — clean_token must strip it (the `%`/newline trap).
cat > "$SANDBOX/bin/terraform" <<'SH'
#!/usr/bin/env bash
name=""; prev=""
for a in "$@"; do [[ "$prev" == "-raw" ]] && name="$a"; prev="$a"; done
case "$name" in
  ci_service_account_email)    printf 'catvox-ci-sa@proj.iam.gserviceaccount.com  ' ;;
  github_actions_wif_provider) printf 'projects/123/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider\n' ;;
  firebase_ios_app_id)         printf '1:123:ios:abc964748' ;;
  project_id)                  printf '402530\n' ;;
  project_api_token)           printf 'phc_testtoken123\n' ;;
  *) exit 1 ;;
esac
SH

# plutil: echo the API key value for `-extract API_KEY raw <plist>`.
cat > "$SANDBOX/bin/plutil" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${MOCK_API_KEY:-AIzaSyTESTKEY1234567890}"
SH

# gcloud: echo the Cloud Run URI for `functions describe <name>`; exit non-zero
# when MOCK_NODEPLOY is set (function not deployed yet).
cat > "$SANDBOX/bin/gcloud" <<'SH'
#!/usr/bin/env bash
[[ -n "${MOCK_NODEPLOY:-}" ]] && exit 1
name=""; want=0
for a in "$@"; do [[ $want -eq 1 ]] && { name="$a"; want=0; }; [[ "$a" == "describe" ]] && want=1; done
case "$name" in
  getSignedUploadURL) printf 'https://getsigneduploadurl-abc-uc.a.run.app\n' ;;
  analyseVideo)       printf 'https://analysevideo-abc-uc.a.run.app/\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$SANDBOX/bin/terraform" "$SANDBOX/bin/plutil" "$SANDBOX/bin/gcloud"

PATH_HERMETIC="$SANDBOX/bin:/usr/bin:/bin"

# Build a fresh sandbox xcconfig (with placeholders) and plist for a case.
fixture() {
  CFG="$SANDBOX/$1.xcconfig"
  PLIST="$SANDBOX/$1.plist"
  cat > "$CFG" <<'EOF'
CATVOX_PROJECT_ID = proj
CATVOX_ENVIRONMENT = sbx
CATVOX_GCP_CI_SERVICE_ACCOUNT = replace-with-ci-sa
CATVOX_GCP_WIF_PROVIDER = replace-with-wif-provider
CATVOX_FIREBASE_APP_ID = replace-with-app-id
CATVOX_FIREBASE_API_KEY = replace-with-api-key
CATVOX_SIGNED_UPLOAD_URL_HOST = replace-with-upload-host
CATVOX_ANALYSE_VIDEO_HOST = replace-with-analyse-host
CATVOX_POSTHOG_PROJECT_ID = replace-with-posthog-project-id
CATVOX_POSTHOG_PROJECT_TOKEN = replace-with-posthog-project-token
EOF
  : > "$PLIST"  # presence is enough; plutil is mocked
}

run() {  # phase extra_env...
  local phase="$1"; shift
  env -i PATH="$PATH_HERMETIC" \
    CATVOX_ENVIRONMENT=sbx CATVOX_ENV_CONFIG="$CFG" \
    CATVOX_PROJECT_ID=proj CATVOX_FUNCTION_REGION=us-central1 \
    CATVOX_FIREBASE_PLIST_OUTPUT="$PLIST" WRITE_CONFIG_PHASE="$phase" \
    "$@" bash "$SCRIPT"
}
val() { grep -E "^[[:space:]]*$1[[:space:]]*=" "$CFG" | head -1 | sed -E 's/^[^=]*=[[:space:]]*//'; }

# 1. Identity phase writes all four values, clean (no trailing %/space), slashes/colons intact.
fixture id
run identity >/dev/null 2>&1 || fail "S1 identity run errored"
[[ "$(val CATVOX_GCP_CI_SERVICE_ACCOUNT)" == "catvox-ci-sa@proj.iam.gserviceaccount.com" ]] || fail "S1 ci-sa: [$(val CATVOX_GCP_CI_SERVICE_ACCOUNT)]"
[[ "$(val CATVOX_GCP_WIF_PROVIDER)" == "projects/123/locations/global/workloadIdentityPools/github-actions-pool/providers/github-actions-provider" ]] || fail "S1 wif: [$(val CATVOX_GCP_WIF_PROVIDER)]"
[[ "$(val CATVOX_FIREBASE_APP_ID)" == "1:123:ios:abc964748" ]] || fail "S1 app-id: [$(val CATVOX_FIREBASE_APP_ID)]"
[[ "$(val CATVOX_FIREBASE_API_KEY)" == "AIzaSyTESTKEY1234567890" ]] || fail "S1 api-key: [$(val CATVOX_FIREBASE_API_KEY)]"
ok "identity writes clean values (slashes/colons preserved, no %/whitespace)"

# 2. Idempotent: a second identity run produces an identical file.
cp "$CFG" "$SANDBOX/id.before"
run identity >/dev/null 2>&1 || fail "S2 second run errored"
diff -q "$SANDBOX/id.before" "$CFG" >/dev/null || fail "S2 re-run changed the file"
ok "identity re-run is a no-op (clean diff)"

# 3. Hosts phase strips scheme + path to hostname only.
fixture hosts
run hosts >/dev/null 2>&1 || fail "S3 hosts run errored"
[[ "$(val CATVOX_SIGNED_UPLOAD_URL_HOST)" == "getsigneduploadurl-abc-uc.a.run.app" ]] || fail "S3 upload host: [$(val CATVOX_SIGNED_UPLOAD_URL_HOST)]"
[[ "$(val CATVOX_ANALYSE_VIDEO_HOST)" == "analysevideo-abc-uc.a.run.app" ]] || fail "S3 analyse host: [$(val CATVOX_ANALYSE_VIDEO_HOST)]"
ok "hosts phase stores hostname only (scheme + path stripped)"

# 4. Hosts lenient: not-deployed -> exit 0, key left at placeholder, warning emitted.
fixture nodeploy
run hosts MOCK_NODEPLOY=1 >/dev/null 2>"$SANDBOX/err4" || fail "S4 should not fail when functions are absent"
[[ "$(val CATVOX_SIGNED_UPLOAD_URL_HOST)" == "replace-with-upload-host" ]] || fail "S4 host should be untouched"
grep -q "not deployed yet" "$SANDBOX/err4" || fail "S4 expected a skip warning"
ok "hosts phase is lenient when functions are not deployed"

# 5. Absent key is appended (then idempotent on re-run).
fixture append
grep -v '^CATVOX_FIREBASE_API_KEY' "$SANDBOX/append.xcconfig" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
run identity >/dev/null 2>&1 || fail "S5 run errored"
[[ "$(val CATVOX_FIREBASE_API_KEY)" == "AIzaSyTESTKEY1234567890" ]] || fail "S5 absent key not appended"
cp "$CFG" "$SANDBOX/append.before"
run identity >/dev/null 2>&1 || fail "S5 second run errored"
diff -q "$SANDBOX/append.before" "$CFG" >/dev/null || fail "S5 re-run after append changed the file"
ok "absent key is appended, then idempotent"

# 6. Missing xcconfig fails fast.
if env -i PATH="$PATH_HERMETIC" CATVOX_ENVIRONMENT=sbx \
   CATVOX_ENV_CONFIG="$SANDBOX/does-not-exist.xcconfig" WRITE_CONFIG_PHASE=identity \
   bash "$SCRIPT" >/dev/null 2>&1; then
  fail "S6 expected failure on missing xcconfig"
fi
ok "missing xcconfig fails fast"

# 7. PostHog phase writes project id + public ingestion token from terraform/posthog outputs.
fixture posthog
run posthog >/dev/null 2>&1 || fail "S7 posthog run errored"
[[ "$(val CATVOX_POSTHOG_PROJECT_ID)" == "402530" ]] || fail "S7 project id: [$(val CATVOX_POSTHOG_PROJECT_ID)]"
[[ "$(val CATVOX_POSTHOG_PROJECT_TOKEN)" == "phc_testtoken123" ]] || fail "S7 project token: [$(val CATVOX_POSTHOG_PROJECT_TOKEN)]"
ok "posthog phase writes project id and public project token"

echo "PASS ($pass cases)"
