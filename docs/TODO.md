# TODO

## Early user testing

### Connect Gemini output to Notion

Rework prompt in `docs/USER_TEST_GEMINI_REVIEW_PROMPT.md` so that Gemini returns JSON.
Then we can use the JSON response in automated way to ingest into Notion API.
Example of the JSON that we need in Notion:

```json
{
  "language": "Russian",
  "understood_product": "Partial",
  "delight": 4,
  "friction": ["Language barrier", "Scan limit"],
  "would_use_again": "Likely yes",
  "would_share": "Likely yes"
}
```

## Infrastructure / Runtime Maintenance

### Dev / Production Environment Split Before Launch
Before public launch, keep active development in `kathelix-catvox-dev` and reserve `kathelix-catvox-prod` for the future real production environment. Use the generic named-environment configuration model from ADR-0017 and ADR-0018 so future environments can be added without hard-coding only Dev and Prod.

Subtasks:
* [x] Decide the environment model: named environments, initially `dev` and `prod`, with environment name treated as configuration data. See ADR-0017.
* [x] Parameterize the single-environment code path before creating new cloud resources.
* [x] Decide final environment naming: `kathelix-catvox-dev` is active Dev; `kathelix-catvox-prod` is preserved, not deleted, for future Prod. See ADR-0018.
* [x] Create the separate Dev GCP/Firebase project with separate Firebase app, App Check configuration, Firestore database, GCS buckets, Secret Manager secrets, Artifact Registry repo, Cloud Functions deployment, and Terraform state.
* [x] Split Terraform state and variables by environment for active Dev (`terraform/backend/dev.hcl.example`, `terraform/env/dev.tfvars.example`).
* [x] Split GitHub Actions Dev secrets into the GitHub Environment named `dev`; PR and merge-to-main deploys target Dev.
* [x] Split Dev iOS configuration, including Firebase plist selection/validation, Dev bundle ID, App Check debug token handling, and backend endpoint selection.
* [x] After a real Debug device scan passes against `kathelix-catvox-dev`, clean Dev leftovers from preserved `kathelix-catvox-prod` and record a cleanup report. See `docs/archive/LEGACY_PRESPLIT_CLEANUP_REPORT_2026-05-16.md`.
* [ ] Create the future real Prod environment in preserved `kathelix-catvox-prod`, with protected GitHub Environment and explicit release path.
* Split analytics configuration so Dev/test traffic cannot pollute production PostHog dashboards.
* Restrict Firestore-mutating integration tests to Dev only; define a separate protected production smoke-test runbook for minimal non-invasive checks after future Prod deployments.
* Define launch cutover and rollback steps, including how to handle any pre-launch Firestore usage data, GCS objects, and deployed function revisions.

### Firebase Functions Node.js Runtime Review
Review this around **2026-06-01** before changing the Cloud Functions runtime.

Current position as of 2026-05-01:
* Keep CatVox Functions on Node.js 22 for now. The main Firebase Functions "Manage functions" page was last updated on 2026-04-30 and still lists Node.js 22, Node.js 20, and Node.js 18 (deprecated) as the supported Firebase SDK for Cloud Functions runtime choices.
* Google Cloud runtime support already lists Cloud Run functions support for `nodejs24`, with Node.js 24 deprecating on 2028-04-30 and decommissioning on 2028-10-31.
* Node.js 22 remains safe for now. Google Cloud runtime support lists Node.js 22 deprecation on 2027-04-30 and decommissioning on 2027-10-31.
* Local developer Node versions, such as Node.js 25.8.1, should not drive the deployed Functions runtime. Firebase-supported runtime guidance should remain the source of truth.

When revisiting:
* Re-check the Firebase Functions "Manage functions" page, Firebase CLI release notes, and Google Cloud Functions runtime support.
* If Node.js 24 is clearly supported and recommended for Cloud Functions for Firebase, update `functions/package.json`, `functions/package-lock.json`, `.github/workflows/functions.yml`, `docs/TRD.md`, and `AGENTS.md`.
* Consider adding `.nvmrc` or `.node-version` with the selected runtime so local validation does not drift to unsupported versions.
* Validate with `npm --prefix functions test` under the selected runtime and `firebase deploy --only functions --dry-run`.
