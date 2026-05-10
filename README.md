# CatVox

## Systems used

### GitHub

- Git source control
- PR review cycle
- GitHub Actions with WIF to GCP

### Google Cloud Platform (GCP)

- Vertex AI (Gemini Flash)
- Cloud Storage (GCS)
- Firestore
- Secret Manager
- Artifact Registry
- IAM

### Firebase

- App Check
- Cloud Functions deployment target (2nd Gen, TypeScript)

### Apple Developer Program

- App Attest enablement, code signing certificates, provisioning profiles, and eventual App Store / TestFlight distribution
- StoreKit 2

### PostHog

[PostHog](https://us.posthog.com/project/402530/dashboard/1524032) is used in CatVox to track product analytics across the core user journey. It helps validate hypotheses from user testing with real behavioural data.

### Notion

[Notion](https://www.notion.so/35c42f730ae9804b91cdc07772b62b82?v=35c42f730ae9809fbb24000c67afdbab&source=copy_link) is used for evolving product learning from real users and decision system.

Notion was chosen over Airtable (for now) because CatVox currently needs:

- rich text
- embedded markdown
- qualitative analysis
- linked thinking
- flexible structure
- AI assistance
- Codex integration

More than:

- rigid relational analytics
- spreadsheet-first workflows

We will need to connect PostHog analytics to Notion.
PostHog later validates whether hypotheses are true in production.
