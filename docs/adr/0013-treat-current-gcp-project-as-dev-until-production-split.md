# ADR-0013: Treat Current GCP Project as Dev Until Production Split

- Status: Accepted
- Date: 2026-05-01
- Owners: Kathelix / CatVox
- Related docs: `docs/HLD.md`, `docs/TRD.md`, `docs/TODO.md`, `.github/workflows/functions.yml`, `functions/integration/verifyQuotaContract.ts`

## Context

CatVox has a deployed GCP/Firebase environment named `kathelix-catvox-prod`, but
the product is not publicly live yet. During this pre-launch phase, the team
needs to validate deployed backend behavior against real Cloud Functions,
Firestore, and Cloud Logging rather than relying only on local unit tests or
mocked services.

The current quota-contract verification is a good example: it must seed a
temporary Firestore usage document, call the deployed `getSignedUploadURL`
function, verify the machine-readable HTTP `429` response, and confirm the
structured `quota_exceeded` log entry. That end-to-end behavior cannot be fully
proven inside the local unit-test suite.

Creating a separate Dev environment immediately would add infrastructure,
configuration, Firebase, App Check, analytics, and CI complexity before the app
has real production users. At the same time, integration tests that mutate
backend state must not become normal practice against a future real production
environment.

## Decision

Until public launch, CatVox will treat the current live GCP/Firebase project
`kathelix-catvox-prod` operationally as the Dev / integration testing
environment, despite the project name.

The Functions CI pipeline will keep live backend integration tests out of pull
requests. Pull requests run TypeScript build and backend unit tests only. After
a merge-to-main deploy, the pipeline may run backend integration tests against
the currently deployed Dev backend. Developers may also run the same tests
locally against the currently deployed Dev backend.

Terminology is intentionally split:

- **Integration testing** runs against Dev, may write temporary backend data, and
  must clean up after itself.
- **Smoke testing** is reserved for future real Prod deployments and must be a
  small, protected, non-invasive confidence check.

Live integration tests must follow these rules:

- use test-owned temporary identifiers and documents
- clean up temporary backend data in a `finally` path where practical
- avoid reading, modifying, or depending on real user data
- verify externally observable contracts that unit tests cannot fully cover
- stay narrow enough that failures identify a specific deployed contract issue
- use the same authentication path that GitHub Actions uses when the test
  performs direct GCP data-plane probes
- avoid initializing Firebase Admin SDK inside the CI integration test harness
  unless that exact path has been verified under GitHub Actions WIF; use
  Google Cloud client libraries such as `@google-cloud/firestore` for direct
  Firestore probes

Before public launch, CatVox must split the real production environment from
this Dev environment. After that split, Firestore-mutating integration tests
must run against Dev only. Any production smoke testing must be protected,
non-invasive, and documented in a separate runbook.

## Consequences

### Positive

- Gives the team real deployed-backend validation without prematurely building a
  multi-environment platform
- Keeps PR checks fast and safe by avoiding live backend writes before review
- Catches post-deploy contract drift in Cloud Functions, Firestore behavior,
  headers, response bodies, and Cloud Logging
- Establishes the rule that Dev integration tests must be narrow,
  temporary-data-only, and cleanup-aware
- Creates a clear pre-launch obligation to separate Dev and Prod before real
  users depend on the system

### Negative / Trade-offs

- The current project name includes `prod`, while its operational role is Dev
  until launch
- A merge-to-main integration failure happens after deployment, so rollback or a
  follow-up fix may be needed if a deployed contract is broken
- Auth differences between local Application Default Credentials (ADC) and
  GitHub Actions WIF can surface only in the post-merge integration job if the
  integration harness uses a client library path that PR checks and local runs
  do not exercise
- The Dev environment may contain temporary test logs and briefly contain
  temporary test Firestore documents
- Future App Check enforcement may require the integration test runner to supply
  a valid App Check token or approved debug token

## Implementation Notes

- Current integration baseline: App Check rejection checks for both HTTP
  Functions, a direct Firestore quota-reservation race probe, and the daily
  quota contract integration test for `getSignedUploadURL`
- The direct Firestore integration probe uses `@google-cloud/firestore` rather
  than Firebase Admin SDK so the test harness works with GitHub Actions WIF
  external-account Application Default Credentials (ADC)
- CI entry points:
  - post-deploy job in `.github/workflows/functions.yml`
- Local Dev command: `npm --prefix functions run test:integration`
- Future environment split is tracked in `docs/TODO.md`.
