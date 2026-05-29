# ADR-0025: Enforce App Check on Cloud Firestore per Environment

- Status: Accepted
- Date: 2026-05-29
- Owners: Kathelix / CatVox
- Related docs: `docs/TRD.md`, `docs/CREATE_NEW_ENVIRONMENT.md`
- Related ADRs: ADR-0002 (Use App Attest for Firebase App Check)

## Context

ADR-0002 chose App Attest as the App Check provider for the iOS app, with no
DeviceCheck fallback. App Check is enforced in the Cloud Functions in code (the
backend rejects requests without a valid `X-Firebase-AppCheck` token with
`401 app_check_unauthorized`).

Cloud Firestore itself has had no App Check enforcement configured. Today the iOS
client never talks to Firestore directly — it calls the Cloud Functions, which
access Firestore via the Admin SDK as `catvox-backend-sa`. Admin SDK and
service-account access bypasses App Check entirely. So Firestore-level App Check
enforcement is defense-in-depth against direct Firebase client SDK access to
Firestore (for example with a leaked `GoogleService-Info` config), and a
forward-looking guard if the client ever adopts direct Firestore access.

Issue #38 stands up real Prod and asks for App Check to be secure-by-default from
the start. We need an enforcement posture that is safe for Prod without breaking
Dev's integration tests, which write `usage` documents directly — but via
`@google-cloud/firestore` using the CI service account (ADR/AGENTS guidance),
which bypasses App Check.

## Decision

Manage Firestore App Check enforcement in Terraform via
`google_firebase_app_check_service_config` for `firestore.googleapis.com`, with
the enforcement mode set **per environment** from
`CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT` (Terraform variable
`firestore_app_check_enforcement`):

| Environment | Mode | Reason |
|---|---|---|
| `prod` | `ENFORCED` | Secure-by-default; client SDK access requires a valid App Attest token. |
| `dev` | `UNENFORCED` | Keep the debug-token developer path frictionless. |

Allowed values are `OFF`, `UNENFORCED`, `ENFORCED`. There is no Terraform default
— each environment must declare its posture in xcconfig (the same explicit-choice
discipline as `firebase_ios_app_deletion_policy`).

App Attest remains the only client attestation provider; no DeviceCheck config is
added.

## Rationale

1. **Secure-by-default for Prod.** Enforced from first provisioning, before any
   public traffic, rather than retrofitted later.
2. **No impact on the backend or CI.** `catvox-backend-sa` (runtime) and the CI
   integration probe (`@google-cloud/firestore`) use service-account credentials,
   which bypass App Check regardless of enforcement mode. Verified: the iOS client
   has no direct Firestore SDK usage, and `functions/integration/verifyQuotaContract.ts`
   reaches Firestore through `@google-cloud/firestore`.
3. **Per-environment choice, data-driven.** Dev stays `UNENFORCED` so the
   debug-token loop is unaffected; the value is committed config (ADR-0017,
   ADR-0021), not hard-coded.

## Consequences

### Positive

- Direct Firebase client SDK access to Prod Firestore without a valid App Check
  token is rejected at the platform layer.
- Posture is explicit and reviewable per environment.

### Negative / Trade-offs

- If the iOS client later adopts direct Firestore access, it must obtain an App
  Check token before the first Firestore request in Prod, or requests will be
  rejected. This is the intended secure-by-default behavior and must be covered
  when such a feature is designed.
- Enforcement state is now Terraform-managed; manual console changes would drift
  and be reverted on the next apply.

## Rejected Options

### Option A: No Firestore App Check enforcement (rely only on Functions-layer App Check)

Rejected: leaves direct Firestore client access unguarded and misses the
secure-by-default goal for Prod.

### Option B: Enforce universally (Dev `ENFORCED` too)

Not adopted for this slice: it changes Dev behavior with no current benefit (no
direct client Firestore access in Dev) and adds risk to the Dev developer loop.
Dev can be raised to `ENFORCED` later by flipping one xcconfig value if direct
client Firestore access is introduced.

## Implementation Notes

- `terraform/main.tf`: `google_firebase_app_check_service_config.firestore`
  (`service_id = "firestore.googleapis.com"`), depending on the Firestore
  database and enabled APIs.
- `terraform/variables.tf`: `firestore_app_check_enforcement` with
  `OFF|UNENFORCED|ENFORCED` validation, no default.
- `Makefile` / xcconfig: `CATVOX_FIREBASE_FIRESTORE_APP_CHECK_ENFORCEMENT`
  (Dev `UNENFORCED`, Prod `ENFORCED`).
- `terraform/tests/wif_and_app_check.tftest.hcl`: assert enforced/unenforced
  modes and rejection of an invalid mode.
- iOS: App Attest entitlement is `production` in `CatVox/CatVox.entitlements`;
  release builds use App Attest only (no DeviceCheck) per ADR-0002.

## Review Trigger

Revisit if the iOS client adopts direct Firestore access, if a non-Functions
client path to Firestore is added, or if App Check enforcement modes change in
the Firebase API.
