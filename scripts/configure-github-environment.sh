#!/usr/bin/env bash
# Configure a CatVox environment's GitHub Environment from committed config.
#
# Environment-agnostic: the per-environment values in
# config/environments/<env>.xcconfig dictate the GitHub Environment's protection,
# so the same command works for mutable (dev-like) and protected (prod-like)
# environments with no per-environment branching here. Literal environment names
# never appear in this script.
#
#   CATVOX_ENVIRONMENT            GitHub Environment name (= CatVox env name).
#   CATVOX_ENVIRONMENT_PROTECTED  true  -> required reviewers + branch restriction.
#                                 false -> no reviewers, no branch restriction.
#   CATVOX_GCP_WIF_GITHUB_REF     refs/heads/<branch> -> restrict deploys to that
#                                 branch (mirrors the WIF ref pin, ADR-0024);
#                                 empty -> any branch.
#   GITHUB_ENVIRONMENT_REVIEWERS  comma-separated GitHub usernames; required when
#                                 CATVOX_ENVIRONMENT_PROTECTED=true.
#   GITHUB_REPO                   owner/repo (default kathelix/catvox).
#
# Idempotent: re-running converges the environment to the configured state.

set -euo pipefail

ENVIRONMENT="${CATVOX_ENVIRONMENT:?CATVOX_ENVIRONMENT is required}"
PROTECTED="${CATVOX_ENVIRONMENT_PROTECTED:?CATVOX_ENVIRONMENT_PROTECTED is required}"
WIF_REF="${CATVOX_GCP_WIF_GITHUB_REF:-}"
REVIEWERS="${GITHUB_ENVIRONMENT_REVIEWERS:-}"
REPO="${GITHUB_REPO:-kathelix/catvox}"

if ! command -v gh >/dev/null 2>&1; then
  echo "Missing required tool: gh" >&2
  exit 1
fi

case "$PROTECTED" in
  true | false) ;;
  *) echo "CATVOX_ENVIRONMENT_PROTECTED must be 'true' or 'false' (got: $PROTECTED)" >&2; exit 1 ;;
esac

# Derive the allowed branch from the WIF ref pin (refs/heads/main -> main). A
# protected environment without a ref pin is reviewer-gated but branch-open.
branch=""
if [[ -n "$WIF_REF" ]]; then
  branch="${WIF_REF#refs/heads/}"
  if [[ "$branch" == "$WIF_REF" || -z "$branch" ]]; then
    echo "CATVOX_GCP_WIF_GITHUB_REF must be a refs/heads/<branch> ref (got: $WIF_REF)" >&2
    exit 1
  fi
fi

# Reviewers are required only for a protected environment.
reviewers_json="null"
if [[ "$PROTECTED" == "true" ]]; then
  if [[ -z "$REVIEWERS" ]]; then
    echo "GITHUB_ENVIRONMENT_REVIEWERS is required when CATVOX_ENVIRONMENT_PROTECTED=true" >&2
    exit 1
  fi
  items=()
  IFS=',' read -ra _names <<< "$REVIEWERS"
  for raw in "${_names[@]}"; do
    name="$(printf '%s' "$raw" | xargs)"
    [[ -z "$name" ]] && continue
    id="$(gh api "users/${name}" --jq '.id')"
    items+=("{\"type\":\"User\",\"id\":${id}}")
  done
  reviewers_json="[$(IFS=','; printf '%s' "${items[*]}")]"
fi

# Branch policy: a custom policy for the pinned branch, or no restriction.
if [[ -n "$branch" ]]; then
  branch_policy_json='{"protected_branches": false, "custom_branch_policies": true}'
else
  branch_policy_json='null'
fi

echo "Configuring GitHub Environment '${ENVIRONMENT}' (${REPO}):"
echo "  protected=${PROTECTED}  branch=${branch:-<any>}  reviewers=${REVIEWERS:-<none>}"

gh api --method PUT "repos/${REPO}/environments/${ENVIRONMENT}" --input - >/dev/null <<JSON
{
  "reviewers": ${reviewers_json},
  "deployment_branch_policy": ${branch_policy_json}
}
JSON

# Reconcile custom branch policies to exactly the pinned branch (idempotent):
# drop any existing policies, then add the single configured branch.
if [[ -n "$branch" ]]; then
  ids="$(gh api "repos/${REPO}/environments/${ENVIRONMENT}/deployment-branch-policies" \
           --jq '.branch_policies[]?.id' 2>/dev/null || true)"
  for id in $ids; do
    gh api --method DELETE \
      "repos/${REPO}/environments/${ENVIRONMENT}/deployment-branch-policies/${id}" >/dev/null
  done
  gh api --method POST \
    "repos/${REPO}/environments/${ENVIRONMENT}/deployment-branch-policies" \
    -f "name=${branch}" >/dev/null
  echo "  deploys restricted to branch '${branch}'"
fi

echo "Done."
