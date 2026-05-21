# ADR-0019: Use Separate PostHog Projects per Environment

- Status: Accepted
- Date: 2026-05-21
- Owners: Kathelix / CatVox
- Related docs: `docs/HLD.md`, `docs/TRD.md`, `docs/CREATE_NEW_ENVIRONMENT.md`, `docs/posthog-setup-report.md`, `docs/adr/0011-use-posthog-for-product-analytics.md`, `docs/adr/0017-environment-configuration-model.md`, `docs/adr/0018-create-dedicated-dev-environment.md`, GitHub issue #37

## Context

CatVox uses PostHog for MVP product analytics. ADR-0011 selected PostHog and
defined the privacy boundary, event taxonomy, SDK configuration, and anonymous
identity model.

The first PostHog project was created during MVP development and is now named
`CatVox Dev`. At the time, the PostHog free tier was a practical fit for a solo
developer and a small pre-launch user base, but it only supports one project.

CatVox has since adopted stronger environment isolation across the rest of the
stack:

- separate GCP/Firebase projects
- separate Firebase iOS apps and App Check configuration
- separate backend deployments and endpoints
- separate GitHub Environment secrets
- separate Terraform state per environment

Analytics should follow the same operational model before significant public
production traffic exists. The key choice is whether to keep one PostHog
project and rely on an `app_environment` event property, or to use separate
PostHog projects for Dev and Prod.

The current PostHog pricing page was checked on 2026-05-21. It states that the
Free plan has one project, while Pay-as-you-go keeps the monthly free volume and
allows more projects. See <https://posthog.com/pricing>.

At CatVox scale, expected PostHog costs remain negligible because the
Pay-as-you-go plan preserves generous free monthly quotas while unlocking
multiple projects. The architectural clarity and analytics isolation benefits
outweigh the expected near-zero operational cost increase.

## Decision

CatVox will use separate PostHog projects per real environment.

Initial projects:

- `CatVox Dev` for internal development, local device testing, TestFlight-style
  pre-production validation if routed to Dev, and mutable analytics testing
- `CatVox Prod` for real App Store production analytics

The existing `CatVox Dev` project remains the Dev analytics project. A dedicated
`CatVox Prod` project is required before real production analytics are enabled.

Each real environment owns its own:

- PostHog project
- public app ingestion project token
- app ingestion host
- dashboards and insights
- person profiles and event history
- feature flags, experiments, surveys, and error-intake configuration if those
  PostHog capabilities are adopted later

CatVox will still include a mandatory `app_environment` property on every
captured product event. This property is defense-in-depth metadata for filtering,
debugging, and future environments such as `local`, `staging`, or `testflight`.
It is not the primary isolation boundary between Dev and Prod analytics.

Event taxonomy must remain environment-agnostic. Event names such as
`analysis_completed`, `scan_shared`, and `quota_exceeded` are shared across
environments and must not include environment suffixes such as `_dev`, `_prod`,
or `_testflight`. Environment separation must happen through separate PostHog
projects as the primary isolation mechanism and `app_environment` as
supplementary metadata, not through different event names.

App-facing configuration remains limited to public ingestion configuration such
as `CATVOX_POSTHOG_PROJECT_TOKEN` and `CATVOX_POSTHOG_HOST_NAME`. Operational
PostHog API credentials such as `POSTHOG_API_KEY`, `POSTHOG_ORGANIZATION_ID`,
`POSTHOG_HOST`, and `POSTHOG_PROJECT_ID` are CI/local automation inputs for
future PostHog Terraform work and must not be committed to app config.

PostHog infrastructure-as-code work will live in a dedicated Terraform root such
as `terraform/posthog/`, with its own state prefix and CI workflow. It must not
be mixed into the GCP infrastructure root.

## Consequences

### Positive

- Dev, QA, and debug traffic cannot pollute production analytics dashboards by
  forgetting a filter.
- PostHog person profiles and event history are isolated between Dev and Prod.
- Production funnels, retention, quota-pressure, and share/export metrics are
  simpler to query and safer to trust.
- Analytics isolation now matches the project-wide named-environment model from
  ADR-0017 and the dedicated Dev environment from ADR-0018.
- Future PostHog feature flags, experiments, surveys, and error intake can be
  introduced without crossing Dev and Prod user populations.
- Separate projects reduce operational and analytical cognitive overhead because
  dashboards, funnels, retention queries, and feature-flag analysis no longer
  require permanent environment-filtering discipline.

### Negative / Trade-offs

- CatVox must move beyond the one-project free setup before enabling real Prod
  analytics.
- Dashboard and insight definitions need to be duplicated or managed through
  reusable infrastructure-as-code.
- Configuration management becomes broader because app-visible PostHog tokens
  and operational PostHog API credentials have different lifecycles.
- Future Terraform import and dashboard normalization work needs careful review
  so existing Dev analytics are not accidentally deleted or rewritten.

## Alternatives Considered

### Single PostHog project with `app_environment`

This would keep setup simple and avoid immediate billing/plan changes.

It was rejected as the long-term strategy because it relies on every event,
dashboard, funnel, retention query, and future feature-flag rule being filtered
correctly. A single missed filter could contaminate production analytics, and
Dev person profiles could be mixed with real production users if identities ever
overlap.

CatVox will still keep `app_environment` as supplementary metadata, but not as
the primary Dev/Prod isolation control.

### Separate PostHog organizations

This would provide even stronger administrative isolation.

It was rejected for now because CatVox does not need separate billing,
membership, or organization-level access boundaries for Dev and Prod analytics.
Separate projects inside the same PostHog organization match the current scale
and keep Terraform/dashboard management simpler.

## Future Work

- Create/import the `CatVox Prod` PostHog project before real production
  analytics are enabled.
- Add a separate `terraform/posthog/` root, state prefix, and CI workflow.
- Import the existing `CatVox Dev` project, dashboard, and wizard-created
  insights into Terraform.
- Normalize dashboard-as-code for the core MVP tiles: scan conversion, Photos
  validation failures, share/export conversion, save-to-Photos conversion, and
  quota pressure.
- Add analytics event taxonomy checks and guardrails so every event continues
  to include `app_environment`.
- Evaluate PostHog feature flags, experiments, surveys, and error tracking only
  through later TRD/ADR updates.
- Decide privacy-safe in-app feedback and error intake in a separate follow-up.
