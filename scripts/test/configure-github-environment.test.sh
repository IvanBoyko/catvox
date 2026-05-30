#!/usr/bin/env bash
# Config-driven behaviour test for scripts/configure-github-environment.sh.
#
# Runs the real script against a PATH-mocked `gh` (hermetic env via `env -i` so a
# parent `make` environment can't leak CATVOX_* values). The mock records the
# environment PUT body and the branch-policy POST/DELETE calls, and answers the
# read-back queries from MOCK_READBACK_* so the script's self-verification can be
# exercised — including a drift case where the read-back disagrees.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/configure-github-environment.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; pass=$((pass + 1)); }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

cat > "$SANDBOX/bin/gh" <<'SH'
#!/usr/bin/env bash
shift  # drop the leading "api"
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
    elif [[ "$jq" == *name* ]]; then echo "${MOCK_READBACK_BRANCHES:-}";   # verify read-back (names)
    else printf '%s\n' ${MOCK_EXISTING_POLICIES:-}; fi;;                    # reconcile read (ids)
  *environments/*)
    if [[ "$method" == "PUT" && $have_input -eq 1 ]]; then
      b="$(cat)"; echo "PUT $(printf '%s' "$b" | tr -d ' \n\t')" >> "$GH_LOG";
    else echo "${MOCK_READBACK_REVIEWERS:-}"; fi;;                          # verify read-back (reviewers)
esac
exit 0
SH
chmod +x "$SANDBOX/bin/gh"

PATH_HERMETIC="$SANDBOX/bin:/usr/bin:/bin"

# 1. Protected + ref pin + reviewer -> required reviewer + custom main policy; verify passes.
LOG="$SANDBOX/log1"; : > "$LOG"
env -i PATH="$PATH_HERMETIC" GH_LOG="$LOG" GITHUB_REPO=kathelix/catvox \
  MOCK_READBACK_REVIEWERS=IvanBoyko MOCK_READBACK_BRANCHES=main \
  CATVOX_ENVIRONMENT=prod CATVOX_ENVIRONMENT_PROTECTED=true \
  CATVOX_GCP_WIF_GITHUB_REF=refs/heads/main GITHUB_ENVIRONMENT_REVIEWERS=IvanBoyko \
  bash "$SCRIPT" >/dev/null 2>&1 || fail "S1 script errored"
grep -Fxq 'PUT {"reviewers":[{"type":"User","id":4242}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' "$LOG" \
  || fail "S1 PUT body wrong: $(grep '^PUT' "$LOG")"
grep -Fxq "POST main" "$LOG" || fail "S1 missing POST main"
grep -q "DELETE" "$LOG" && fail "S1 unexpected DELETE"
ok "protected env -> required reviewer + custom main branch policy"

# 2. Mutable + no ref + no reviewer -> open environment; verify passes (empty/empty).
LOG="$SANDBOX/log2"; : > "$LOG"
env -i PATH="$PATH_HERMETIC" GH_LOG="$LOG" GITHUB_REPO=kathelix/catvox \
  MOCK_READBACK_REVIEWERS= MOCK_READBACK_BRANCHES= \
  CATVOX_ENVIRONMENT=dev CATVOX_ENVIRONMENT_PROTECTED=false \
  bash "$SCRIPT" >/dev/null 2>&1 || fail "S2 script errored"
grep -Fxq 'PUT {"reviewers":null,"deployment_branch_policy":null}' "$LOG" \
  || fail "S2 PUT body wrong: $(grep '^PUT' "$LOG")"
grep -qE "POST|DELETE" "$LOG" && fail "S2 unexpected branch-policy calls"
ok "mutable env -> no reviewers, no branch restriction"

# 3. Protected without reviewers -> fail fast (before any API call).
if env -i PATH="$PATH_HERMETIC" GH_LOG="$SANDBOX/log3" GITHUB_REPO=kathelix/catvox \
   CATVOX_ENVIRONMENT=prod CATVOX_ENVIRONMENT_PROTECTED=true \
   CATVOX_GCP_WIF_GITHUB_REF=refs/heads/main bash "$SCRIPT" >/dev/null 2>&1; then
  fail "S3 expected failure when protected without reviewers"
fi
ok "protected without reviewers fails"

# 4. Non-refs/heads ref -> fail fast.
if env -i PATH="$PATH_HERMETIC" GH_LOG="$SANDBOX/log4" GITHUB_REPO=kathelix/catvox \
   CATVOX_ENVIRONMENT=prod CATVOX_ENVIRONMENT_PROTECTED=false \
   CATVOX_GCP_WIF_GITHUB_REF=refs/tags/v1 bash "$SCRIPT" >/dev/null 2>&1; then
  fail "S4 expected failure on a non-branch ref"
fi
ok "non-refs/heads ref fails"

# 5. Protected with a stale existing policy -> reconcile (delete + re-add); verify passes.
LOG="$SANDBOX/log5"; : > "$LOG"
env -i PATH="$PATH_HERMETIC" GH_LOG="$LOG" GITHUB_REPO=kathelix/catvox \
  MOCK_EXISTING_POLICIES=999 MOCK_READBACK_REVIEWERS=IvanBoyko MOCK_READBACK_BRANCHES=main \
  CATVOX_ENVIRONMENT=prod CATVOX_ENVIRONMENT_PROTECTED=true \
  CATVOX_GCP_WIF_GITHUB_REF=refs/heads/main GITHUB_ENVIRONMENT_REVIEWERS=IvanBoyko \
  bash "$SCRIPT" >/dev/null 2>&1 || fail "S5 script errored"
grep -Fxq "DELETE 999" "$LOG" || fail "S5 missing DELETE 999"
grep -Fxq "POST main" "$LOG" || fail "S5 missing POST main"
ok "stale branch policy reconciled (delete + re-add)"

# 6. Verification catches drift: read-back branch disagrees with config -> non-zero exit.
LOG="$SANDBOX/log6"; : > "$LOG"
if env -i PATH="$PATH_HERMETIC" GH_LOG="$LOG" GITHUB_REPO=kathelix/catvox \
   MOCK_READBACK_REVIEWERS=IvanBoyko MOCK_READBACK_BRANCHES=master \
   CATVOX_ENVIRONMENT=prod CATVOX_ENVIRONMENT_PROTECTED=true \
   CATVOX_GCP_WIF_GITHUB_REF=refs/heads/main GITHUB_ENVIRONMENT_REVIEWERS=IvanBoyko \
   bash "$SCRIPT" >/dev/null 2>&1; then
  fail "S6 expected verification failure when read-back branch != config"
fi
ok "verification fails on read-back drift"

echo "PASS ($pass cases)"
