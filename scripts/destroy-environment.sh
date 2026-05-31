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
#   5. delete the GitHub Environment + its secrets (before the state bucket, so a
#      gh failure leaves the state bucket intact for a re-run to retry);
#   6. delete the Terraform state bucket LAST (after both destroys, which need the
#      state it holds, AND the GitHub cleanup — nothing recoverable runs after it).
#
# Idempotent: absent resources are skipped, so a re-run after a partial teardown
# converges. Only not-found / no-state conditions are tolerated — a genuine
# failure (terraform destroy, a bucket that survives deletion or whose status
# probe fails for any reason other than not-found, PostHog destroy while its
# state exists, a PostHog state probe that fails for any reason other than an
# empty prefix, or a non-404 GitHub API error) aborts loudly rather than
# reporting a clean teardown. In particular, if the core terraform destroy
# (step 2) or the PostHog destroy/probe (step 3) fails, the script stops before
# deleting the state bucket so the operator can retry. gh is required up front so
# step 6 cannot be silently skipped.

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
require_tool gh   # step 6 deletes the GitHub Environment + secrets; a partial
                  # teardown that silently skips it is worse than failing fast.

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

# --all-versions so a versioned bucket (the Terraform state bucket is created with
# versioning) is fully emptied: the `**` wildcard alone deletes only live
# versions, leaving noncurrent ones that would block the subsequent bucket delete.
empty_bucket() { gcloud storage rm --recursive --all-versions "gs://$1/**" >/dev/null 2>&1 || true; }

# Classify a bucket as exists | absent | error. A describe that fails for any
# reason OTHER than not-found (permission, auth, transient) is "error" — callers
# must treat it as indeterminate and abort, never as "absent", so a probe failure
# cannot silently skip cleanup or mask a failed delete.
bucket_status() {
  local out
  if out="$(gcloud storage buckets describe "gs://$1" --project "$PROJECT_ID" 2>&1)"; then
    echo exists
  elif printf '%s' "$out" | grep -qiE 'not found|does not exist|404|no such bucket'; then
    echo absent
  else
    echo error
  fi
}

# Empty + delete a script-created bucket, then verify (tri-state) it is gone.
# Aborts on an indeterminate describe or a surviving bucket rather than reporting
# a clean teardown while the bucket remains.
purge_bucket() {  # $1 = bucket name
  case "$(bucket_status "$1")" in
    absent) echo "  gs://$1 not present; skipping"; return 0 ;;
    error)  echo "  ERROR: could not determine the status of gs://$1 (describe failed); aborting" >&2; return 1 ;;
  esac
  empty_bucket "$1"
  gcloud storage buckets delete "gs://$1" --project "$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  case "$(bucket_status "$1")" in
    absent) echo "  deleted gs://$1"; return 0 ;;
    *)      echo "  ERROR: gs://$1 still present or unverifiable after delete (non-empty, retained, permission-denied, or probe failed); aborting" >&2; return 1 ;;
  esac
}

# 1 — Empty the force_destroy=false raw-videos bucket (Terraform deletes the
#     bucket itself in step 2, but only once it is empty).
echo "1/6 Emptying raw-videos bucket ${RAW_VIDEOS_BUCKET} ..."
case "$(bucket_status "$RAW_VIDEOS_BUCKET")" in
  exists) empty_bucket "$RAW_VIDEOS_BUCKET"; echo "  emptied (or already empty)" ;;
  absent) echo "  not present; skipping" ;;
  error)  echo "  ERROR: could not determine the status of ${RAW_VIDEOS_BUCKET} (describe failed); aborting" >&2; exit 1 ;;
esac

# 2 — Core Terraform destroy. set -e stops the script here on failure, before any
#     bucket is deleted, so the state stays intact for a retry.
echo "2/6 terraform destroy (core) ..."
make terraform-destroy CONFIRM=destroy \
  CATVOX_ENVIRONMENT="$ENVIRONMENT" \
  CATVOX_PROJECT_ID="$PROJECT_ID" \
  CATVOX_TF_VARS_FILE="$TFVARS_FILE"

# 3 — PostHog Terraform destroy. Gate on whether PostHog state actually exists
#     (positively identified by the state object under the shared bucket), rather
#     than tolerating every failure: a destroy that fails for a real reason
#     (credentials, provider/API error) must abort here, BEFORE step 5 deletes
#     the bucket that holds posthog/state — otherwise PostHog resources are
#     orphaned with no state to retry from. Many environments have no PostHog
#     state yet (deferred — see #37); those are skipped.
echo "3/6 terraform destroy (PostHog) ..."
POSTHOG_STATE_PREFIX="${CATVOX_POSTHOG_TF_STATE_PREFIX:-posthog/state}"
posthog_glob="gs://${STATE_BUCKET}/${POSTHOG_STATE_PREFIX}/**"
# Three outcomes, distinguished so a failed probe is never mistaken for "no
# state": objects present -> destroy (fail-hard); an empty prefix (the listing
# positively matched nothing) -> skip; any other probe failure (transient/auth/
# permission) -> abort, rather than skip-then-delete the bucket and orphan state.
if posthog_ls="$(gcloud storage ls "$posthog_glob" 2>&1)"; then
  echo "  PostHog state present — destroying (a failure aborts before the state bucket is deleted)"
  make posthog-terraform-destroy CONFIRM=destroy \
    CATVOX_ENVIRONMENT="$ENVIRONMENT" \
    CATVOX_PROJECT_ID="$PROJECT_ID"
elif printf '%s' "$posthog_ls" | grep -qiE 'matched no objects|not found|does not exist'; then
  echo "  no PostHog state under ${posthog_glob}; skipping"
else
  echo "  ERROR: could not determine PostHog state — the probe failed: ${posthog_ls}" >&2
  echo "  Aborting before the state bucket is deleted; resolve and re-run." >&2
  exit 1
fi

# 4 — Delete the script-created Cloud Functions Gen2 sources bucket (outside the
#     Terraform graph — Terraform manages only its IAM, removed in step 2).
echo "4/6 Deleting Cloud Functions sources bucket ..."
if [[ -n "$PROJECT_NUMBER" && -n "$REGION" ]]; then
  src_bucket="gcf-v2-sources-${PROJECT_NUMBER}-${REGION}"
  purge_bucket "$src_bucket"
else
  echo "  project number or region unavailable; skipping sources bucket"
fi

# 5 — Delete the GitHub Environment and its secrets, BEFORE the state bucket. gh
#     is a required tool (checked up front), so reaching here means it is present.
#     Tolerate only a genuine 404 (already gone); a 403 / auth / network /
#     malformed error aborts. Doing this before the irreversible state-bucket
#     deletion means a gh failure leaves the state bucket intact, so a re-run can
#     still terraform-init and retry the GitHub cleanup.
echo "5/6 Deleting GitHub Environment '${ENVIRONMENT}' ..."
if gh_out="$(gh api --method DELETE "repos/${REPO}/environments/${ENVIRONMENT}" 2>&1)"; then
  echo "  deleted"
elif printf '%s' "$gh_out" | grep -qiE 'HTTP 404|Not Found'; then
  echo "  not present or already deleted; skipping"
else
  echo "  ERROR: could not delete the '${ENVIRONMENT}' GitHub Environment: ${gh_out}" >&2
  exit 1
fi

# 6 — Delete the Terraform state bucket LAST — after both destroys (which
#     read/write it) AND the GitHub cleanup, so nothing recoverable-by-rerun
#     happens once it is gone. The operator's own credentials delete it (the CI
#     SA's bucket IAM is already gone with step 2).
echo "6/6 Deleting Terraform state bucket ${STATE_BUCKET} (last) ..."
purge_bucket "$STATE_BUCKET"

echo
echo "Done. '${ENVIRONMENT}' torn down; the GCP project ${PROJECT_ID} was kept (now empty)."
echo "To also delete the project and rotate to a fresh one for a new cycle, see #111."
