# TODO

## Infrastructure / Runtime Maintenance

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
