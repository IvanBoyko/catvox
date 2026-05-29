#!/usr/bin/env bash
# Idempotently import pre-existing GCP/Firebase resources into Terraform state
# before the first apply, so provisioning a project that already contains them
# (a preserved or previously-used project) succeeds instead of failing with
# ALREADY_EXISTS. Issue #38 Step 3 (S5).
#
# Scope (per the locked import decision): the two resources Terraform *creates*
# and would therefore fail to re-create — the Firestore "(default)" database and
# the Firebase iOS app. App Check singleton configs (app_attest_config,
# service_config) are PATCH-based, so apply reconciles them via update and they
# do not need importing.
#
# Idempotent and safe to re-run: a resource already in Terraform state is
# skipped, and a resource absent from the project is left for apply to create.
# Importing changes no infrastructure — it only records existing resources in
# state — but it does mutate remote state, so it runs as part of provisioning
# rather than a pure read-only preview.
#
# Expects the same environment the Makefile terraform targets read, and that
# `make terraform-init` has already run (backend + providers initialised).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

ENVIRONMENT="${CATVOX_ENVIRONMENT:?CATVOX_ENVIRONMENT is required}"
PROJECT_ID="${CATVOX_PROJECT_ID:?CATVOX_PROJECT_ID is required}"
IOS_BUNDLE_ID="${CATVOX_IOS_BUNDLE_ID:?CATVOX_IOS_BUNDLE_ID is required}"
TFVARS_FILE="${CATVOX_TF_VARS_FILE:-terraform/env/${ENVIRONMENT}.tfvars}"

terraform_state_has() {
  terraform -chdir=terraform state list 2>/dev/null | grep -Fxq "$1"
}

run_terraform_import() {
  local address="$1" import_id="$2"
  echo "  importing ${address} <- ${import_id}"
  make terraform-import \
    CATVOX_ENVIRONMENT="${ENVIRONMENT}" \
    CATVOX_PROJECT_ID="${PROJECT_ID}" \
    CATVOX_TF_VARS_FILE="${TFVARS_FILE}" \
    ADDRESS="${address}" \
    ID="${import_id}"
}

import_firestore_default() {
  local address="google_firestore_database.default"
  if terraform_state_has "${address}"; then
    echo "  ${address}: already in Terraform state; skipping."
    return 0
  fi
  if gcloud firestore databases describe --database='(default)' --project="${PROJECT_ID}" >/dev/null 2>&1; then
    run_terraform_import "${address}" "projects/${PROJECT_ID}/databases/(default)"
  else
    echo "  ${address}: no (default) database in project; apply will create it."
  fi
}

import_firebase_ios_app() {
  local address="google_firebase_apple_app.ios"
  if terraform_state_has "${address}"; then
    echo "  ${address}: already in Terraform state; skipping."
    return 0
  fi

  local apps_json discovered_app_id=""
  if apps_json="$(firebase apps:list IOS --project "${PROJECT_ID}" --json --non-interactive 2>/dev/null)"; then
    discovered_app_id="$(printf '%s' "${apps_json}" \
      | node "${SCRIPT_DIR}/find-firebase-ios-app-id.mjs" "${IOS_BUNDLE_ID}" || true)"
  else
    echo "  ${address}: WARNING — 'firebase apps:list' failed; skipping iOS app discovery." >&2
  fi

  if [[ -n "${discovered_app_id}" ]]; then
    run_terraform_import "${address}" "projects/${PROJECT_ID}/iosApps/${discovered_app_id}"
  else
    echo "  ${address}: no iOS app matching ${IOS_BUNDLE_ID}; apply will create it."
  fi
}

echo "Importing pre-existing resources into Terraform state (idempotent)..."
import_firestore_default
import_firebase_ios_app
echo "Pre-existing resource import phase complete."
