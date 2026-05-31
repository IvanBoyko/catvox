#!/usr/bin/env bash
# Behaviour test for scripts/destroy-environment.sh.
#
# Runs the real script against PATH-mocked `gcloud`, `gh`, and `make` (hermetic
# env via `env -i`). The gcloud mock is stateful: it records bucket deletions so
# the script's delete-then-verify-absence step behaves like the real API. Asserts
# the safety gate, the load-bearing order (state bucket deleted only AFTER
# terraform destroy), and — per the PR #118 review — that genuine failures abort
# loudly instead of being masked as a clean teardown.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/destroy-environment.sh"

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; pass=$((pass + 1)); }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"
DLOG="$SANDBOX/log"
DELETED="$SANDBOX/deleted"

cat > "$SANDBOX/bin/gcloud" <<'SH'
#!/usr/bin/env bash
gsurl=""
for a in "$@"; do case "$a" in gs://*) gsurl="$a";; esac; done
bkt="${gsurl#gs://}"; bkt="${bkt%%/*}"
args="$*"
case "$args" in
  *"projects describe"*) printf '%s\n' "${MOCK_PROJECT_NUMBER-123456}";;
  *"storage ls"*)  # PostHog state existence probe (3-way, like real gcloud)
    [[ -n "${MOCK_POSTHOG_STATE:-}" ]] && { echo "${gsurl%/**}/default.tfstate"; exit 0; }
    [[ -n "${MOCK_POSTHOG_LS_FAIL:-}" ]] && { echo "ERROR: (gcloud.storage.ls) caller does not have permission" >&2; exit 1; }
    echo "One or more URLs matched no objects." >&2; exit 1;;
  *"storage buckets describe"*)
    [[ -n "${MOCK_NO_BUCKETS:-}" ]] && exit 1
    [[ -f "$DELETED" ]] && grep -qxF "$bkt" "$DELETED" && exit 1   # already deleted -> absent
    exit 0;;
  *"storage buckets delete"*)
    echo "delbucket:${gsurl}" >> "$DLOG"
    [[ -z "${MOCK_BUCKET_DELETE_FAILS:-}" ]] && echo "$bkt" >> "$DELETED"   # records only on "success"
    exit 0;;
  *"storage rm"*) echo "rm:${gsurl}" >> "$DLOG"; exit 0;;
  *) exit 0;;
esac
SH

cat > "$SANDBOX/bin/make" <<'SH'
#!/usr/bin/env bash
echo "make:$1" >> "$DLOG"
[[ "$1" == "posthog-terraform-destroy" && -n "${MOCK_POSTHOG_FAIL:-}" ]] && exit 1
exit 0
SH

cat > "$SANDBOX/bin/gh" <<'SH'
#!/usr/bin/env bash
[[ -n "${MOCK_GH_403:-}" ]] && { echo "gh: Forbidden (HTTP 403)" >&2; exit 1; }
[[ -n "${MOCK_GH_404:-}" ]] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
echo "gh-delenv" >> "$DLOG"
exit 0
SH
chmod +x "$SANDBOX/bin/gcloud" "$SANDBOX/bin/make" "$SANDBOX/bin/gh"

PATH_HERMETIC="$SANDBOX/bin:/usr/bin:/bin"

# A PATH variant WITHOUT gh, to exercise the required-tool check. It must be
# self-contained (NO /usr/bin or /bin): CI runners ship a real `gh` on the system
# PATH, so leaving those in would defeat the "gh absent" case (it passed locally
# only because Homebrew's gh isn't under /usr/bin). Symlink just the coreutils the
# script reaches before the gh check.
mkdir -p "$SANDBOX/nogh"
cp "$SANDBOX/bin/gcloud" "$SANDBOX/bin/make" "$SANDBOX/nogh/"
for t in bash dirname grep; do ln -s "$(command -v "$t")" "$SANDBOX/nogh/$t"; done
PATH_NOGH="$SANDBOX/nogh"

run() {  # trailing KEY=val overrides
  : > "$DLOG"; : > "$DELETED"
  env -i PATH="$PATH_HERMETIC" DLOG="$DLOG" DELETED="$DELETED" \
    CATVOX_ENVIRONMENT=sbx CATVOX_PROJECT_ID=proj CATVOX_FUNCTION_REGION=us-central1 \
    CATVOX_TF_STATE_BUCKET=catvox-tf-state-proj \
    "$@" bash "$SCRIPT"
}
line_of() { grep -nF "$1" "$DLOG" | head -1 | cut -d: -f1; }

# 1. No CONFIRM -> refuse before any destructive call.
if run >"$SANDBOX/o1" 2>&1; then fail "S1 expected refusal without CONFIRM"; fi
grep -q "make:terraform-destroy" "$DLOG" && fail "S1 must not destroy without CONFIRM"
ok "refuses without CONFIRM=destroy (nothing destroyed)"

# 2. Protected + CONFIRM but no ALLOW_PROTECTED_DESTROY -> refuse.
if run CATVOX_ENVIRONMENT_PROTECTED=true CONFIRM=destroy >"$SANDBOX/o2" 2>&1; then fail "S2 expected refusal"; fi
grep -q "make:terraform-destroy" "$DLOG" && fail "S2 must not destroy a protected env without ack"
grep -q "PROTECTED environment" "$SANDBOX/o2" || fail "S2 should explain the protected gate"
ok "refuses protected env without ALLOW_PROTECTED_DESTROY"

# 3. Protected + CONFIRM + mismatched ack -> refuse.
if run CATVOX_ENVIRONMENT_PROTECTED=true CONFIRM=destroy ALLOW_PROTECTED_DESTROY=prod >/dev/null 2>&1; then
  fail "S3 expected refusal when ALLOW_PROTECTED_DESTROY != environment"
fi
grep -q "make:terraform-destroy" "$DLOG" && fail "S3 must not destroy with a mismatched ack"
ok "refuses protected env when ack does not match the env name"

# 4. Mutable + CONFIRM (no PostHog state) -> proceeds in order; PostHog skipped.
run CONFIRM=destroy >"$SANDBOX/o4" 2>&1 || fail "S4 mutable destroy should succeed: $(cat "$SANDBOX/o4")"
grep -q "make:terraform-destroy" "$DLOG" || fail "S4 should run terraform destroy"
grep -q "make:posthog-terraform-destroy" "$DLOG" && fail "S4 should skip PostHog when no state"
grep -q "gh-delenv" "$DLOG" || fail "S4 should delete the GitHub Environment"
raw=$(line_of "rm:gs://catvox-raw-videos-proj"); td=$(line_of "make:terraform-destroy")
gcf=$(line_of "delbucket:gs://gcf-v2-sources-123456-us-central1"); st=$(line_of "delbucket:gs://catvox-tf-state-proj")
[ -n "$raw" ] && [ -n "$td" ] && [ "$raw" -lt "$td" ] || fail "S4 raw-videos emptied before terraform destroy (raw=$raw td=$td)"
[ -n "$st" ] && [ "$td" -lt "$st" ] || fail "S4 state bucket deleted AFTER terraform destroy (td=$td st=$st)"
[ -n "$gcf" ] && [ "$gcf" -lt "$st" ] || fail "S4 state bucket deleted last, after sources bucket (gcf=$gcf st=$st)"
ok "mutable destroy: empty raw -> tf destroy -> ... -> state bucket last; PostHog skipped"

# 5. Protected + CONFIRM + matching ack -> proceeds.
run CATVOX_ENVIRONMENT_PROTECTED=true CONFIRM=destroy ALLOW_PROTECTED_DESTROY=sbx >"$SANDBOX/o5" 2>&1 \
  || fail "S5 protected destroy with matching ack should succeed: $(cat "$SANDBOX/o5")"
grep -q "make:terraform-destroy" "$DLOG" || fail "S5 should run terraform destroy"
ok "protected env destroys with a matching ALLOW_PROTECTED_DESTROY"

# 6. Absent buckets -> tolerated; terraform destroy still runs, exit 0, no deletes.
run CONFIRM=destroy MOCK_NO_BUCKETS=1 >"$SANDBOX/o6" 2>&1 || fail "S6 should tolerate absent buckets: $(cat "$SANDBOX/o6")"
grep -q "make:terraform-destroy" "$DLOG" || fail "S6 should still run terraform destroy"
grep -q "delbucket:" "$DLOG" && fail "S6 should not delete buckets that are absent"
ok "absent buckets are skipped (idempotent re-run safe)"

# 7. [P1 fix] PostHog state present + destroy FAILS -> abort BEFORE the state bucket.
if run CONFIRM=destroy MOCK_POSTHOG_STATE=1 MOCK_POSTHOG_FAIL=1 >"$SANDBOX/o7" 2>&1; then
  fail "S7 expected abort when PostHog destroy fails with state present"
fi
grep -q "make:posthog-terraform-destroy" "$DLOG" || fail "S7 should have attempted PostHog destroy"
grep -q "delbucket:gs://catvox-tf-state-proj" "$DLOG" && fail "S7 must NOT delete the state bucket after a PostHog destroy failure"
ok "PostHog destroy failure (state present) aborts before deleting the state bucket"

# 8. PostHog state present + destroy OK -> PostHog destroyed, teardown completes.
run CONFIRM=destroy MOCK_POSTHOG_STATE=1 >"$SANDBOX/o8" 2>&1 || fail "S8 should succeed: $(cat "$SANDBOX/o8")"
grep -q "make:posthog-terraform-destroy" "$DLOG" || fail "S8 should destroy PostHog when state exists"
grep -q "delbucket:gs://catvox-tf-state-proj" "$DLOG" || fail "S8 should reach state-bucket deletion"
ok "PostHog state present + clean destroy completes the teardown"

# 9. [P2 fix] Bucket delete that does not take effect -> abort (verify-absence).
if run CONFIRM=destroy MOCK_BUCKET_DELETE_FAILS=1 >"$SANDBOX/o9" 2>&1; then
  fail "S9 expected abort when a bucket survives deletion"
fi
grep -q "still present after delete" "$SANDBOX/o9" || fail "S9 should report the surviving bucket"
ok "a bucket that survives deletion aborts loudly (not masked)"

# 10. [P2 fix] gh DELETE 404 -> tolerated (already gone), run succeeds.
run CONFIRM=destroy MOCK_GH_404=1 >"$SANDBOX/o10" 2>&1 || fail "S10 should tolerate a 404: $(cat "$SANDBOX/o10")"
grep -q "not present or already deleted" "$SANDBOX/o10" || fail "S10 should report the env as already gone"
ok "gh Environment 404 is tolerated"

# 11. [P2 fix] gh DELETE 403 -> abort (do not report success).
if run CONFIRM=destroy MOCK_GH_403=1 >"$SANDBOX/o11" 2>&1; then
  fail "S11 expected abort on a non-404 gh failure"
fi
grep -q "could not delete the" "$SANDBOX/o11" || fail "S11 should surface the gh error"
ok "gh Environment 403 aborts (not falsely reported as deleted)"

# 12. [round-2 P2] PostHog state probe fails (transient/auth) -> abort, do NOT skip.
if run CONFIRM=destroy MOCK_POSTHOG_LS_FAIL=1 >"$SANDBOX/o12" 2>&1; then
  fail "S12 expected abort when the PostHog state probe fails"
fi
grep -q "probe failed" "$SANDBOX/o12" || fail "S12 should report a failed probe"
grep -q "delbucket:gs://catvox-tf-state-proj" "$DLOG" && fail "S12 must NOT delete the state bucket on a failed probe"
ok "indeterminate PostHog state probe aborts before deleting the state bucket"

# 13. [round-2 P2] gh not installed -> required-tool check fails fast.
if env -i PATH="$PATH_NOGH" DLOG="$DLOG" DELETED="$DELETED" \
   CATVOX_ENVIRONMENT=sbx CATVOX_PROJECT_ID=proj CATVOX_FUNCTION_REGION=us-central1 \
   CATVOX_TF_STATE_BUCKET=catvox-tf-state-proj CONFIRM=destroy \
   bash "$SCRIPT" >"$SANDBOX/o13" 2>&1; then
  fail "S13 expected failure when gh is not installed"
fi
grep -q "Missing required tool: gh" "$SANDBOX/o13" || fail "S13 should require gh"
ok "gh is required up front (no silent skip of the GitHub Environment)"

echo "PASS ($pass cases)"
