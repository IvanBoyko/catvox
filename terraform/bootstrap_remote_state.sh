#!/usr/bin/env bash
# =============================================================================
# CatVox AI — Bootstrap GCS Remote Terraform State (Step 1 of 2)
# Kathelix Ltd
#
# Run this script ONCE, manually, before any CI/CD pipeline is configured.
# It creates a dedicated GCS bucket to hold Terraform state so that both
# local `terraform apply` and GitHub Actions target the same state file.
#
# Prerequisites:
#   - gcloud CLI installed and authenticated (`gcloud auth login`)
#   - Sufficient IAM permissions on the GCP project (Owner or Storage Admin)
#
# Usage:
#   chmod +x terraform/bootstrap_remote_state.sh
#   ./terraform/bootstrap_remote_state.sh
# =============================================================================

set -euo pipefail

echo "Deprecated helper: use 'make environment-create' for new environments." >&2

# ── Configuration ─────────────────────────────────────────────────────────────
# Legacy helper. New environments should use scripts/create-environment.sh via
# `make environment-create`, which also sets up the environment properly.
# PROJECT_ID must match the selected environment project ID. Override via env
# var if needed:
#   PROJECT_ID=kathelix-catvox-dev ./bootstrap_remote_state.sh

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="us-central1"
STATE_BUCKET="catvox-tf-state-${PROJECT_ID}"

# ── Validation ────────────────────────────────────────────────────────────────

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: PROJECT_ID is not set and could not be read from gcloud config."
  echo "       Run: gcloud config set project YOUR_PROJECT_ID"
  echo "       Or:  PROJECT_ID=YOUR_PROJECT_ID ./bootstrap_remote_state.sh"
  exit 1
fi

echo ""
echo "  Project : ${PROJECT_ID}"
echo "  Region  : ${REGION}"
echo "  Bucket  : gs://${STATE_BUCKET}"
echo ""
read -r -p "Proceed? [y/N] " confirm
if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ── Step 1: Create the state bucket ──────────────────────────────────────────
# Separate from catvox-raw-videos — this bucket is infrastructure-only and
# must never be managed by Terraform itself (bootstrap dependency).

echo ""
echo ">>> Creating GCS state bucket..."
gcloud storage buckets create "gs://${STATE_BUCKET}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --uniform-bucket-level-access

# ── Step 2: Enable versioning ─────────────────────────────────────────────────
# Versioning lets you recover a previous good state if the current one is
# corrupted (e.g. interrupted apply). Strongly recommended for all state buckets.

echo ""
echo ">>> Enabling object versioning..."
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "✓ State bucket ready: gs://${STATE_BUCKET}"
echo ""
echo "Next steps:"
echo "  1. Prefer make environment-create for new environments."
echo "  2. The Makefile will automatically use this bucket name for the environment."
echo ""
