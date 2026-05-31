#!/usr/bin/env bash
# Behaviour test for scripts/destroy-environment.sh.
#
# Runs the real script against PATH-mocked `gcloud`, `gh`, and `make` (hermetic
# env via `env -i`). The mocks log each destructive call to $DLOG so the test can
# assert the safety gate blocks before anything is deleted, and that the teardown
# order is correct — crucially, the Terraform state bucket is deleted only AFTER
# `terraform destroy`, which reads/writes it.

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

cat > "$SANDBOX/bin/gcloud" <<'SH'
#!/usr/bin/env bash
gsurl=""
for a in "$@"; do case "$a" in gs://*) gsurl="$a";; esac; done
args="$*"
case "$args" in
  *"projects describe"*) printf '%s\n' "${MOCK_PROJECT_NUMBER-123456}";;
  *"storage buckets describe"*) [[ -n "${MOCK_NO_BUCKETS:-}" ]] && exit 1; exit 0;;
  *"storage buckets delete"*) echo "delbucket:${gsurl}" >> "$DLOG"; exit 0;;
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
echo "gh-delenv" >> "$DLOG"
exit 0
SH
chmod +x "$SANDBOX/bin/gcloud" "$SANDBOX/bin/make" "$SANDBOX/bin/gh"

PATH_HERMETIC="$SANDBOX/bin:/usr/bin:/bin"

run() {  # trailing KEY=val overrides
  : > "$DLOG"
  env -i PATH="$PATH_HERMETIC" DLOG="$DLOG" \
    CATVOX_ENVIRONMENT=sbx CATVOX_PROJECT_ID=proj CATVOX_FUNCTION_REGION=us-central1 \
    CATVOX_TF_STATE_BUCKET=catvox-tf-state-proj \
    "$@" bash "$SCRIPT"
}
line_of() { grep -nF "$1" "$DLOG" | head -1 | cut -d: -f1; }

# 1. No CONFIRM -> refuse before any destructive call.
if run >"$SANDBOX/o1" 2>&1; then fail "S1 expected refusal without CONFIRM"; fi
grep -q "make:terraform-destroy" "$DLOG" && fail "S1 must not destroy without CONFIRM"
grep -q "Re-run with: make environment-destroy" "$SANDBOX/o1" || fail "S1 should print the re-run hint"
ok "refuses without CONFIRM=destroy (nothing destroyed)"

# 2. Protected + CONFIRM but no ALLOW_PROTECTED_DESTROY -> refuse.
if run CATVOX_ENVIRONMENT_PROTECTED=true CONFIRM=destroy >"$SANDBOX/o2" 2>&1; then fail "S2 expected refusal"; fi
grep -q "make:terraform-destroy" "$DLOG" && fail "S2 must not destroy a protected env without ack"
grep -q "PROTECTED environment" "$SANDBOX/o2" || fail "S2 should explain the protected gate"
ok "refuses protected env without ALLOW_PROTECTED_DESTROY"

# 3. Protected + CONFIRM + wrong ALLOW value -> refuse.
if run CATVOX_ENVIRONMENT_PROTECTED=true CONFIRM=destroy ALLOW_PROTECTED_DESTROY=prod >/dev/null 2>&1; then
  fail "S3 expected refusal when ALLOW_PROTECTED_DESTROY != environment"
fi
grep -q "make:terraform-destroy" "$DLOG" && fail "S3 must not destroy with a mismatched ack"
ok "refuses protected env when ack does not match the env name"

# 4. Mutable + CONFIRM=destroy -> proceeds in the correct order.
run CONFIRM=destroy >"$SANDBOX/o4" 2>&1 || fail "S4 mutable destroy should succeed: $(cat "$SANDBOX/o4")"
grep -q "make:terraform-destroy" "$DLOG" || fail "S4 should run terraform destroy"
grep -q "gh-delenv" "$DLOG" || fail "S4 should delete the GitHub Environment"
raw=$(line_of "rm:gs://catvox-raw-videos-proj"); td=$(line_of "make:terraform-destroy")
gcf=$(line_of "delbucket:gs://gcf-v2-sources-123456-us-central1"); st=$(line_of "delbucket:gs://catvox-tf-state-proj")
[ -n "$raw" ] && [ -n "$td" ] && [ "$raw" -lt "$td" ] || fail "S4 raw-videos must be emptied before terraform destroy (raw=$raw td=$td)"
[ -n "$st" ] && [ "$td" -lt "$st" ] || fail "S4 state bucket must be deleted AFTER terraform destroy (td=$td st=$st)"
[ -n "$gcf" ] && [ "$gcf" -lt "$st" ] || fail "S4 state bucket must be deleted last, after the sources bucket (gcf=$gcf st=$st)"
ok "mutable destroy runs in order: empty raw -> tf destroy -> ... -> state bucket last"

# 5. Protected + CONFIRM + matching ALLOW -> proceeds.
run CATVOX_ENVIRONMENT_PROTECTED=true CONFIRM=destroy ALLOW_PROTECTED_DESTROY=sbx >"$SANDBOX/o5" 2>&1 \
  || fail "S5 protected destroy with matching ack should succeed: $(cat "$SANDBOX/o5")"
grep -q "make:terraform-destroy" "$DLOG" || fail "S5 should run terraform destroy"
ok "protected env destroys with a matching ALLOW_PROTECTED_DESTROY"

# 6. Absent buckets -> tolerated; terraform destroy still runs, exit 0.
run CONFIRM=destroy MOCK_NO_BUCKETS=1 >"$SANDBOX/o6" 2>&1 || fail "S6 should tolerate absent buckets: $(cat "$SANDBOX/o6")"
grep -q "make:terraform-destroy" "$DLOG" || fail "S6 should still run terraform destroy"
grep -q "delbucket:" "$DLOG" && fail "S6 should not delete buckets that are absent"
ok "absent buckets are skipped (idempotent re-run safe)"

# 7. PostHog destroy failure is tolerated (core teardown continues).
run CONFIRM=destroy MOCK_POSTHOG_FAIL=1 >"$SANDBOX/o7" 2>&1 || fail "S7 should tolerate a PostHog destroy failure: $(cat "$SANDBOX/o7")"
grep -q "delbucket:gs://catvox-tf-state-proj" "$DLOG" || fail "S7 should still reach state-bucket deletion"
ok "PostHog destroy failure does not abort the teardown"

echo "PASS ($pass cases)"
