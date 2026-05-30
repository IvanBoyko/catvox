#!/usr/bin/env bash
# Idempotency + correctness test for scripts/import-preexisting-resources.sh.
#
# Runs the real script (and the real find-firebase-ios-app-id.mjs + real node)
# against PATH-mocked external CLIs (terraform / gcloud / firebase / make) whose
# behaviour is driven by MOCK_* env vars. The mock `make terraform-import`
# records each ADDRESS/ID it is asked to import so we can assert exactly which
# imports the script attempts in each project state.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/import-preexisting-resources.sh"

APP_ID="1:953500951129:ios:1595a4c27cd8f3f7964748"
FIREBASE_JSON="{\"result\":[{\"appId\":\"${APP_ID}\",\"platform\":\"IOS\",\"namespace\":\"com.kathelix.catvox\"}]}"

pass_count=0
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; pass_count=$((pass_count + 1)); }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT
mkdir -p "${SANDBOX}/bin"

cat > "${SANDBOX}/bin/terraform" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "-chdir=terraform" && "$2" == "state" && "$3" == "list" ]]; then
  printf '%s\n' ${MOCK_TF_STATE:-}
  exit 0
fi
exit 0
SH

cat > "${SANDBOX}/bin/gcloud" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "firestore" && "$2" == "databases" && "$3" == "describe" ]]; then
  [[ "${MOCK_FIRESTORE_EXISTS:-0}" == "1" ]] && exit 0 || exit 1
fi
exit 0
SH

cat > "${SANDBOX}/bin/firebase" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "apps:list" ]]; then
  [[ "${MOCK_FIREBASE_FAIL:-0}" == "1" ]] && exit 1
  printf '%s' "${MOCK_FIREBASE_JSON:-}"
  exit 0
fi
exit 0
SH

cat > "${SANDBOX}/bin/make" <<'SH'
#!/usr/bin/env bash
target="${1:-}"; shift || true
if [[ "${target}" == "terraform-import" ]]; then
  addr=""; id=""
  for arg in "$@"; do
    case "$arg" in
      ADDRESS=*) addr="${arg#ADDRESS=}" ;;
      ID=*) id="${arg#ID=}" ;;
    esac
  done
  printf '%s\t%s\n' "${addr}" "${id}" >> "${IMPORT_LOG}"
fi
exit 0
SH

chmod +x "${SANDBOX}/bin/"*

export CATVOX_ENVIRONMENT="prod"
export CATVOX_PROJECT_ID="kathelix-catvox-prod"
export CATVOX_IOS_BUNDLE_ID="com.kathelix.catvox"
export CATVOX_TF_VARS_FILE="terraform/env/prod.tfvars"

run_case() {
  : > "${IMPORT_LOG}"
  PATH="${SANDBOX}/bin:${PATH}" bash "${SCRIPT}" >/dev/null 2>&1
}

FS_IMPORT="google_firestore_database.default	projects/kathelix-catvox-prod/databases/(default)"
APP_IMPORT="google_firebase_apple_app.ios	projects/kathelix-catvox-prod/iosApps/${APP_ID}"

# 1. Preserved project: firestore exists, app discoverable, nothing in state → import both.
export IMPORT_LOG="${SANDBOX}/log1"
export MOCK_TF_STATE="" MOCK_FIRESTORE_EXISTS=1 MOCK_FIREBASE_JSON="${FIREBASE_JSON}"; unset MOCK_FIREBASE_FAIL
run_case
grep -Fqx "${FS_IMPORT}" "${IMPORT_LOG}" || fail "preserved: firestore import missing"
grep -Fqx "${APP_IMPORT}" "${IMPORT_LOG}" || fail "preserved: ios app import missing"
[[ "$(grep -c . "${IMPORT_LOG}")" -eq 2 ]] || fail "preserved: expected exactly 2 imports, got $(cat "${IMPORT_LOG}")"
pass "preserved project imports firestore + ios app"

# 2. Fresh project: nothing exists → import nothing.
export IMPORT_LOG="${SANDBOX}/log2"
export MOCK_TF_STATE="" MOCK_FIRESTORE_EXISTS=0 MOCK_FIREBASE_JSON="{\"result\":[]}"; unset MOCK_FIREBASE_FAIL
run_case
[[ ! -s "${IMPORT_LOG}" ]] || fail "fresh: expected no imports, got $(cat "${IMPORT_LOG}")"
pass "fresh project imports nothing"

# 3. Already provisioned: both already in state → idempotent no-op.
export IMPORT_LOG="${SANDBOX}/log3"
export MOCK_TF_STATE="google_firestore_database.default google_firebase_apple_app.ios"
export MOCK_FIRESTORE_EXISTS=1 MOCK_FIREBASE_JSON="${FIREBASE_JSON}"; unset MOCK_FIREBASE_FAIL
run_case
[[ ! -s "${IMPORT_LOG}" ]] || fail "idempotent: expected no imports, got $(cat "${IMPORT_LOG}")"
pass "already-in-state run is an idempotent no-op"

# 4. Partial: firestore already in state, app not → import only the app.
export IMPORT_LOG="${SANDBOX}/log4"
export MOCK_TF_STATE="google_firestore_database.default"
export MOCK_FIRESTORE_EXISTS=1 MOCK_FIREBASE_JSON="${FIREBASE_JSON}"; unset MOCK_FIREBASE_FAIL
run_case
grep -Fqx "${APP_IMPORT}" "${IMPORT_LOG}" || fail "partial: ios app import missing"
[[ "$(grep -c . "${IMPORT_LOG}")" -eq 1 ]] || fail "partial: expected exactly 1 import, got $(cat "${IMPORT_LOG}")"
pass "partial state imports only the missing resource"

# 5. Firebase discovery fails → skip app import without aborting.
export IMPORT_LOG="${SANDBOX}/log5"
export MOCK_TF_STATE="" MOCK_FIRESTORE_EXISTS=0 MOCK_FIREBASE_FAIL=1; unset MOCK_FIREBASE_JSON
run_case
[[ ! -s "${IMPORT_LOG}" ]] || fail "discovery-fail: expected no imports, got $(cat "${IMPORT_LOG}")"
pass "firebase discovery failure skips app import without error"

# 6. App present but bundle id does not match → no app import (no prefix collision).
export IMPORT_LOG="${SANDBOX}/log6"
export MOCK_TF_STATE="" MOCK_FIRESTORE_EXISTS=0
export MOCK_FIREBASE_JSON="{\"result\":[{\"appId\":\"1:x:ios:dev\",\"platform\":\"IOS\",\"namespace\":\"com.kathelix.catvox.dev\"}]}"
unset MOCK_FIREBASE_FAIL
run_case
[[ ! -s "${IMPORT_LOG}" ]] || fail "no-match: expected no imports, got $(cat "${IMPORT_LOG}")"
pass "non-matching bundle id does not import a foreign app"

echo "PASS (${pass_count} cases)"
