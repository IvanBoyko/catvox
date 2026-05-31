#!/usr/bin/env bash
# Behaviour test for scripts/provision-posthog-environment.sh.
#
# Runs the real script against PATH-mocked `gh` and `make`, with a sandbox
# xcconfig parsed by the real xcconfig reader. Asserts ordering: configure
# GitHub Environment, store POSTHOG_API_KEY, plan/apply PostHog Terraform, then
# write PostHog config.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/provision-posthog-environment.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; pass=$((pass + 1)); }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

cat > "$SANDBOX/bin/gh" <<'SH'
#!/usr/bin/env bash
cmd="$1"; shift
case "$cmd" in
  api)
    method="GET"; path=""; have_input=0; fval=""; jq=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --method) method="$2"; shift 2;;
        --jq) jq="$2"; shift 2;;
        --input) have_input=1; shift 2;;
        -f|-F) fval="$2"; shift 2;;
        *) [[ -z "$path" ]] && path="$1"; shift;;
      esac
    done
    case "$path" in
      users/*) echo "${MOCK_USER_ID:-4242}";;
      *deployment-branch-policies/*) [[ "$method" == "DELETE" ]] && echo "DELETE ${path##*/}" >> "$GH_LOG";;
      *deployment-branch-policies)
        if [[ "$method" == "POST" ]]; then echo "POST ${fval#name=}" >> "$GH_LOG";
        elif [[ "$jq" == *name* ]]; then echo "${MOCK_READBACK_BRANCHES:-}";
        else printf '%s\n' ${MOCK_EXISTING_POLICIES:-}; fi;;
      *environments/*)
        if [[ "$method" == "PUT" && $have_input -eq 1 ]]; then
          body="$(cat)"; echo "PUT $(printf '%s' "$body" | tr -d ' \n\t')" >> "$GH_LOG";
        else echo "${MOCK_READBACK_REVIEWERS:-}"; fi;;
    esac
    ;;
  secret)
    [[ "$1" == "set" && "$2" == "POSTHOG_API_KEY" ]] || exit 1
    env_name=""; repo=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --env) env_name="$2"; shift 2;;
        --repo) repo="$2"; shift 2;;
        *) shift;;
      esac
    done
    body="$(cat)"
    echo "SECRET env=${env_name} repo=${repo} body=${body}" >> "$GH_LOG"
    ;;
  *) exit 1;;
esac
exit 0
SH

cat > "$SANDBOX/bin/make" <<'SH'
#!/usr/bin/env bash
echo "MAKE $* POSTHOG_API_KEY=${POSTHOG_API_KEY:-}" >> "$MAKE_LOG"
exit 0
SH

for stub in terraform gcloud; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/bin/$stub"
done
chmod +x "$SANDBOX/bin/gh" "$SANDBOX/bin/make" "$SANDBOX/bin/terraform" "$SANDBOX/bin/gcloud"

PATH_HERMETIC="$SANDBOX/bin:/usr/bin:/bin"

fixture() {
  CFG="$SANDBOX/$1.xcconfig"
  cat > "$CFG" <<'EOF'
CATVOX_PROJECT_ID = sbx-project
CATVOX_ENVIRONMENT = sbx
CATVOX_ENVIRONMENT_PROTECTED = false
CATVOX_GCP_WIF_GITHUB_REF =
CATVOX_POSTHOG_API_HOST_NAME = us.posthog.com
CATVOX_POSTHOG_PROJECT_ID = replace-with-posthog-project-id
CATVOX_POSTHOG_ORGANIZATION_ID = org-sample
EOF
}

# 1. Existing POSTHOG_API_KEY configures GitHub env, stores the secret, applies, then writes config.
fixture happy
GH_LOG="$SANDBOX/gh1"; MAKE_LOG="$SANDBOX/make1"; : > "$GH_LOG"; : > "$MAKE_LOG"
env -i PATH="$PATH_HERMETIC" GH_LOG="$GH_LOG" MAKE_LOG="$MAKE_LOG" GITHUB_REPO=kathelix/catvox \
  MOCK_READBACK_REVIEWERS= MOCK_READBACK_BRANCHES= POSTHOG_API_KEY=phx_test_key \
  CATVOX_ENVIRONMENT=sbx CATVOX_ENV_CONFIG="$CFG" \
  bash "$SCRIPT" >/dev/null 2>&1 || fail "S1 provision run errored"
grep -Fxq 'PUT {"reviewers":null,"deployment_branch_policy":null}' "$GH_LOG" \
  || fail "S1 expected GitHub Environment PUT"
grep -Fxq 'SECRET env=sbx repo=kathelix/catvox body=phx_test_key' "$GH_LOG" \
  || fail "S1 expected POSTHOG_API_KEY secret storage"
grep -Fxq "MAKE posthog-terraform-plan CATVOX_ENVIRONMENT=sbx CATVOX_ENV_CONFIG=$CFG POSTHOG_API_KEY=phx_test_key" "$MAKE_LOG" \
  || fail "S1 missing plan call"
grep -Fxq "MAKE posthog-terraform-ci-apply CATVOX_ENVIRONMENT=sbx CATVOX_ENV_CONFIG=$CFG POSTHOG_API_KEY=phx_test_key" "$MAKE_LOG" \
  || fail "S1 missing apply call"
grep -Fxq "MAKE environment-write-config CATVOX_ENVIRONMENT=sbx CATVOX_ENV_CONFIG=$CFG PHASE=posthog POSTHOG_API_KEY=phx_test_key" "$MAKE_LOG" \
  || fail "S1 missing posthog writeback call"
ok "provision stores secret, applies PostHog Terraform, and writes config"

# 2. Missing POSTHOG_API_KEY in non-interactive mode fails before API calls.
fixture nokey
GH_LOG="$SANDBOX/gh2"; MAKE_LOG="$SANDBOX/make2"; : > "$GH_LOG"; : > "$MAKE_LOG"
if env -i PATH="$PATH_HERMETIC" GH_LOG="$GH_LOG" MAKE_LOG="$MAKE_LOG" GITHUB_REPO=kathelix/catvox \
   CATVOX_ENVIRONMENT=sbx CATVOX_ENV_CONFIG="$CFG" \
   bash "$SCRIPT" >/dev/null 2>&1; then
  fail "S2 expected missing key failure"
fi
[[ ! -s "$GH_LOG" && ! -s "$MAKE_LOG" ]] || fail "S2 should not call gh/make when key is missing"
ok "missing key fails before side effects in non-interactive mode"

echo "PASS ($pass cases)"
