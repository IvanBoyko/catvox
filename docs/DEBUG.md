# CatVox AI — Backend Debugging Guide

This document covers how to diagnose backend failures that surface to the user
as a generic error screen in the app as "Upload failed. The operation couldn't be completed. (NSURLErrorDomain error -1011.)", and how to move beyond manual log triage to proactive observability.

---

## 1. The Symptom

The user sees a failure screen. The iOS app knows the HTTP status code (500,
429, etc.) but has no access to the server-side root cause. The root cause
lives in Cloud Run logs.

---

## 2. Manual Debugging Workflow

### Step 1 — Get a quick overview of recent errors

```bash
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND resource.labels.service_name=("getSignedUploadURL" OR "analysevideo")
   AND severity>=ERROR' \
  --project=kathelix-catvox-dev \
  --limit=50 \
  --freshness=1h \
  --format='table(timestamp, resource.labels.service_name, severity, textPayload)'
```

**What this does:** queries Cloud Logging for ERROR or CRITICAL entries from
both Cloud Run services in the last hour, formatted as a table.

**Notes:**
- GCP lowercases service names in logs — use `analysevideo`, not `analyseVideo`.
- `--freshness` accepts `1h`, `30m`, `24h`, etc. Widen it if the incident was older.
- `resource.type="cloud_run_revision"` is correct for Firebase Functions 2nd gen,
  which run on Cloud Run.

---

### Step 2 — Get the full payload of a specific error

The table view truncates long messages. Use `--format=json` and pipe through
Python to pretty-print:

```bash
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND resource.labels.service_name="analysevideo"
   AND severity=ERROR' \
  --project=kathelix-catvox-dev \
  --limit=5 \
  --freshness=1h \
  --format=json \
| python3 -c "
import json, sys
for e in json.load(sys.stdin):
    print('--- TIME:', e.get('timestamp'))
    print('SEVERITY:', e.get('severity'))
    p = e.get('textPayload') or e.get('jsonPayload') or e.get('protoPayload', {})
    print('PAYLOAD:', json.dumps(p, indent=2) if isinstance(p, dict) else p)
    print()
"
```

**What this does:** fetches the 5 most recent errors in full JSON and extracts
the relevant payload fields.

For the malformed-Vertex hotfix path specifically, query both the retry warning
and the final controlled error:

```bash
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND resource.labels.service_name="analysevideo"
   AND severity>=WARNING
   AND (
     jsonPayload.message="Retrying malformed Vertex AI analysis payload"
     OR jsonPayload.message="Vertex AI returned malformed analysis payload"
   )' \
  --project=kathelix-catvox-dev \
  --limit=50 \
  --freshness=24h \
  --format=json
```

**How to read it:**
- `attempt: 1` warning = first Gemini response was malformed and the backend retried.
- final error `Vertex AI returned malformed analysis payload` after the retry warning = both attempts were malformed and the request returned a controlled HTTP `502`.
- `issues` tells you whether the failure was truncated / invalid JSON or missing / invalid required fields.
- `rawResponsePreview` gives the start of the bad model output without dumping the full payload into logs.

**Important:** this hotfix no longer relies on an unhandled exception for this
failure mode. Debug it from Cloud Logging, not from expecting the same Error
Reporting email path as a crashing `500`.

---

### Step 3 — Correlate a specific request end-to-end

If you know roughly when the failure occurred, pull all log lines (not just
errors) for that time window to see the full request lifecycle:

```bash
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND resource.labels.service_name=("getSignedUploadURL" OR "analysevideo")
   AND timestamp>="2026-04-21T05:35:00Z"
   AND timestamp<="2026-04-21T05:37:00Z"' \
  --project=kathelix-catvox-dev \
  --format='table(timestamp, resource.labels.service_name, severity, textPayload)'
```

Replace the timestamps with the window around the failure (visible in Xcode
console from the iOS Logger output).

---

### Step 4 — Check for cold-start contributions

A new Cloud Run instance being spun up adds ~3–5 s of latency. Look for
`Starting new instance` entries in the same window:

```bash
gcloud logging read \
  'resource.type="cloud_run_revision"
   AND textPayload:"Starting new instance"' \
  --project=kathelix-catvox-dev \
  --limit=20 \
  --freshness=6h \
  --format='table(timestamp, resource.labels.service_name, textPayload)'
```

---

### Step 5 — Check the GCS upload bucket directly

If the failure is at the upload stage (iOS PUT to GCS), verify whether the
object landed:

```bash
gcloud storage ls -l gs://catvox-raw-videos-kathelix-catvox-dev/
```

If the object is absent, the signed URL upload itself failed. If it is present,
the failure was downstream (Vertex AI call).

### Step 6 — Run Dev backend integration tests

Use this against the current Dev backend after deploying Functions changes. The
current integration suite exchanges the registered App Check debug token,
verifies both HTTP Functions reject missing App Check tokens, checks the
Firestore quota reservation race contract with temporary `usage/{userId}` data,
then runs the daily-quota contract test: it writes a temporary usage document
with `count: 5`, calls `getSignedUploadURL`, verifies the machine-readable HTTP
`429` response, checks for the structured `quota_exceeded` log entry, and
deletes temporary Firestore documents in a `finally` block.

Prefer the Makefile target because it accepts `CATVOX_APP_CHECK_DEBUG_TOKEN`,
`TF_VAR_app_check_debug_token`, or the selected local `terraform/env/<environment>.tfvars`
fallback:

```bash
make functions-integration
```

The underlying npm command is:

```bash
npm --prefix functions run test:integration
```

If Cloud Logging is slow or unavailable and you only need the HTTP response
contract:

```bash
npm --prefix functions run test:integration -- --skip-log
```

---

## 3. iOS App Check Debug Failures

If the app shows **Verification Failed**, or an older Debug build shows a
connection failure whose detail includes `firebaseappcheck.googleapis.com`,
`exchangeDebugToken`, HTTP `403`, and `App attestation failed`, the request
failed before CatVox reached its backend Functions.

For Debug builds on a physical iPhone, launch once with the registered debug
token so the app can persist it locally:

```bash
CATVOX_APP_CHECK_DEBUG_TOKEN=<registered-token> make ios-device-launch
```

`make ios-device-launch` also accepts `TF_VAR_app_check_debug_token` and falls
back to the selected local `terraform/env/<environment>.tfvars` when present. It passes the token to
`devicectl` without printing it. After that launch, later Debug app-icon
launches reuse the locally persisted token for Firebase App Check refreshes.

If Firebase rejects the locally persisted Debug token, CatVox clears it and asks
for a fresh registered token. Relaunching from the app icon without a launch
token will not repair that state; reinstall via Xcode or run
`CATVOX_APP_CHECK_DEBUG_TOKEN=<fresh-registered-token> make ios-device-launch`.

Deleting and reinstalling the app clears the local App Check state, which can
temporarily hide the issue, but it is not the durable fix. If the error returns,
verify that the registered debug token still exchanges successfully and has not
been revoked in Firebase App Check.

---

## 4. Known Error Signatures

| Log message | Root cause | Fix |
|---|---|---|
| Xcode Signing & Capabilities shows `Unknown Name (QYT76L5836)`, `No Accounts`, or build fails with `No profiles for 'com.kathelix.catvox.dev' were found` | Xcode has no Apple Developer account that can access the configured team, or the exact environment bundle ID does not have a local development provisioning profile yet | Add the Apple Developer account in Xcode Settings → Accounts, verify team `QYT76L5836`, register the exact bundle ID/App ID if needed, then let automatic signing create the development profile or create one manually |
| iOS alert says `Verification Failed`, or older Debug build alert includes `firebaseappcheck.googleapis.com`, `exchangeDebugToken`, HTTP `403`, and `App attestation failed` | Debug iPhone build refreshed App Check without a registered debug token in the process environment or local Debug token cache, or Firebase rejected the locally persisted Debug token | Launch once with `CATVOX_APP_CHECK_DEBUG_TOKEN=<fresh-registered-token> make ios-device-launch`, then retry from the app icon. If it still fails, confirm the token is registered and not revoked in Firebase App Check |
| `Vertex AI returned invalid JSON: { "primary_emotion": ...` (truncated) | `MAX_OUTPUT_TOKENS` too low — thinking model consumed budget before finishing JSON | Raise `MAX_OUTPUT_TOKENS` in `functions/src/gemini.ts` |
| `Retrying malformed Vertex AI analysis payload` then `Vertex AI returned malformed analysis payload` | First Gemini response was malformed, retry also failed, and the backend converted the request to a controlled `502` instead of crashing | Inspect `issues`, `attempt`, and `rawResponsePreview` in logs; if frequent, revisit prompt / output constraints or `MAX_OUTPUT_TOKENS` |
| `FirebaseAppError: Invalid contents in the credentials file` in GitHub Actions integration tests | The test harness initialized Firebase Admin SDK against the WIF external-account Application Default Credentials (ADC) file. Google Cloud clients such as `@google-cloud/firestore` accept that CI auth path, but Firebase Admin ADC loading may reject it. | Keep direct Firestore integration probes on `@google-cloud/firestore`, or explicitly verify Firebase Admin initialization under GitHub Actions WIF before using it in `functions/integration/**`. Deployed Functions may still use Firebase Admin normally. |
| `Empty response from Vertex AI` | Response had only `thought` parts, no output part | Check `finishReason` in the error summary; may indicate safety block or token exhaustion |
| `The VertexAI class and all its dependencies are deprecated` | Backend was using the deprecated `@google-cloud/vertexai` generative AI module | Migrate Functions Gemini calls to `@google/genai` configured for Vertex AI; see ADR-0012 |
| `signBlob` permission denied | Cloud Run running as wrong service account | Verify `serviceAccount:` is set in both function options; redeploy |
| GCS PUT returns HTTP 403 | `catvox-backend-sa` missing `storage.objectCreator` | Check IAM bindings via `gcloud projects get-iam-policy` |
| `daily_scan_quota_exceeded` (HTTP 429) | Expected — user hit the 5-scan/day cap | Not a bug; visible in app as quota exceeded screen. For alerting, filter by structured log fields such as `jsonPayload.event="quota_exceeded"` and `jsonPayload.quotaType="daily_scan"` rather than by HTTP status alone |
| `service agents being provisioned` | Vertex AI service agent not yet granted bucket access | Wait and retry; persistent → check `google_storage_bucket_iam_member.vertexai_sa_raw_videos_viewer` in Terraform |

---

## 5. Observability Options

The manual workflow above requires someone to notice a failure, then dig into
logs reactively. Below are the options for moving to proactive detection.

---

### Option A — Cloud Monitoring log-match alert (implemented in IaC)

A Cloud Monitoring alerting policy fires directly on ERROR-level log entries
from either Cloud Function, with no manual console steps required.

**This is already implemented in `terraform/monitoring.tf`.** Add your email
to the selected ignored `terraform/env/<environment>.tfvars` and the next
`terraform apply` (or CI merge) activates it:

```hcl
# terraform/env/dev.tfvars
alert_email = "you@example.com"
```

**What you get:** an email within ~1 minute of any unhandled exception, with a
link to the alert and the documentation note pointing to `docs/DEBUG.md`.
Rate-limited to one email per 5 minutes to prevent alert storms.

**Important:** the malformed-Vertex hotfix in `analysevideo` now returns a
handled `502` with application logs instead of an unhandled exception, so do
not assume this specific failure mode will arrive via the same email path.

**What the alert email contains:** timestamp, service name, link to Cloud
Logging filtered to the error window, and the documentation snippet from
`monitoring.tf`. From there, run the Step 2 command in §2 to get the full
payload.

**Limitation:** one email per alert wave, not per individual error. For
per-error detail you still need `gcloud logging read` (§2).

---

### Option B — Cloud Monitoring alert on 5xx rate (built-in metrics)

Cloud Run exports `run.googleapis.com/request_count` broken down by
`response_code_class`. A Cloud Monitoring alerting policy can fire when the
5xx rate exceeds a threshold.

```bash
# Create an alert policy via gcloud (or use the GCP Console UI)
gcloud monitoring policies create \
  --notification-channels=CHANNEL_ID \
  --display-name="CatVox analyseVideo 5xx spike" \
  --condition-display-name="5xx > 5% of requests over 5 min" \
  --condition-filter='resource.type="cloud_run_revision"
    AND resource.labels.service_name="analysevideo"
    AND metric.type="run.googleapis.com/request_count"
    AND metric.labels.response_code_class="5xx"' \
  --condition-threshold-value=0.05 \
  --condition-threshold-duration=300s \
  --condition-aggregations-aligner=ALIGN_RATE \
  --condition-comparison=COMPARISON_GT
```

**What you get:** alert on the symptom (elevated error rate), not the root
cause. Good as a catch-all. Pair with Option A to get the "why".

**Notification channels** (create first in Cloud Monitoring → Alerting →
Notification channels): email, Slack webhook, PagerDuty, OpsGenie.

---

### Option C — Log-based metric + alert (most targeted)

Create a metric that counts log lines matching `severity=ERROR` in the
Cloud Functions services, then alert on it. More targeted than Option B
because it fires on application errors, not just HTTP 5xx.

```bash
# 1. Create a log-based metric
gcloud logging metrics create catvox_function_errors \
  --description="Unhandled errors in CatVox Cloud Functions" \
  --log-filter='resource.type="cloud_run_revision"
    AND resource.labels.service_name=("getSignedUploadURL" OR "analysevideo")
    AND severity=ERROR'

# 2. Create an alerting policy on it (via Console: Monitoring → Alerting → Create policy)
#    Metric: logging.googleapis.com/user/catvox_function_errors
#    Condition: count > 0 over 5-minute rolling window
```

This is the recommended baseline for a small production service.

---

### Option D — Expose root cause to the iOS app (developer experience)

The iOS app currently receives `HTTP 500` with no body when an unhandled error
occurs. Adding a structured error body allows the iOS `Logger` to print the
root cause directly in Xcode, eliminating the need to open `gcloud` for
development-time failures.

**Backend change** (`functions/src/analyse.ts`):

```typescript
// Wrap the Vertex AI call in a catch that returns a structured error body
try {
  const rawJson = await callGemini(projectId, gcsUri);
  // ... parse and return
} catch (err: unknown) {
  const message = err instanceof Error ? err.message : String(err);
  // Only include detail in non-production, or always — the message contains
  // no user data and no secrets; it is safe to surface.
  res.status(500).json({ error: 'Analysis failed', detail: message });
  return;
}
```

**iOS change** (`GCPService.swift`, in `triggerAnalysis`):

```swift
guard (200...299).contains(http.statusCode) else {
    let body = String(data: data, encoding: .utf8) ?? "(no body)"
    logger.error("analyseVideo: HTTP \(http.statusCode) — \(body)")
    throw URLError(.badServerResponse)
}
```

The `detail` field from the server lands in Xcode's console via `logger.error`,
giving the exact Vertex AI error message without opening a terminal.

**Limitation:** this is a developer-experience improvement, not a production
alerting solution. It does not notify anyone proactively — you still need to
be running the app with Xcode attached to see it.

---

### Option E — Firebase Crashlytics non-fatal reporting

Integrate Firebase Crashlytics (already in the Firebase project) into the iOS
app. When `analyseVideo` returns a non-2xx response, log a non-fatal event with
the status code and any error detail from the response body.

```swift
// In GCPService.swift after receiving a non-2xx from analyseVideo:
import FirebaseCrashlytics
Crashlytics.crashlytics().record(
    error: NSError(
        domain: "com.kathelix.catvox.backend",
        code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: body]
    )
)
```

**What you get:** every backend failure recorded in the Firebase Crashlytics
dashboard with device context, iOS version, and frequency across all users.
Crashlytics sends email digests and can be configured to alert on new issue
types.

**Limitation:** only captures what the server sends back. Pair with a
structured error response (Option D) to get the full root cause into
Crashlytics.

---

## 6. Recommendation

For the current stage of CatVox (single developer, low user volume):

| Priority | Action | Effort |
|---|---|---|
| **Do now** | Enable GCP Error Reporting email alerts (Option A) | 5 min, no code |
| **Do now** | Add structured error body to `analyseVideo` + log in iOS (Option D) | 30 min, two files |
| **Soon** | Add log-based metric alert (Option C) | 20 min, one gcloud command |
| **When users grow** | Integrate Firebase Crashlytics (Option E) | ~2 hours, SDK + wiring |

Options A + D together give the shortest path from "user sees error" to "engineer
knows root cause" — Error Reporting alerts the engineer proactively, and the
structured response means the root cause is available in Xcode during
development without any log triage.
