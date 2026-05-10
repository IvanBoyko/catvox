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
Before public launch, split the current live GCP/Firebase environment from the real production environment. Until that split, treat `kathelix-catvox-prod` operationally as the Dev environment despite the current project name. See ADR-0013.

Subtasks:
* Decide final environment naming and whether `kathelix-catvox-prod` is kept, renamed by convention only, or replaced during launch cutover.
* Create separate GCP/Firebase projects for Dev and Prod, with separate Firebase apps, App Check configuration, Firestore databases, GCS buckets, Secret Manager secrets, Artifact Registry repos, and Cloud Functions deployments.
* Split Terraform state and variables per environment so Dev and Prod can be planned/applied independently.
* Split GitHub Actions environments and secrets; keep PR and merge-to-main deploys pointed at Dev, and require an explicit protected release path for Prod.
* Split iOS configuration per environment, including Firebase plist handling, bundle IDs or schemes if needed, App Check providers/debug tokens, and backend endpoint selection.
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
