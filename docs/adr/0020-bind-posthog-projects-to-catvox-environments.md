# ADR-0020: Bind PostHog Projects 1:1 to CatVox Environments

- Status: Accepted
- Date: 2026-05-22
- Owners: Kathelix / CatVox
- Supersedes: the "mapping does not need to be one-to-one" clause in ADR-0019
- Related docs: `docs/HLD.md`, `docs/TRD.md`, `docs/CREATE_NEW_ENVIRONMENT.md`, `docs/CI_BOOTSTRAP.md`, `docs/posthog-setup-report.md`, `docs/adr/0011-use-posthog-for-product-analytics.md`, `docs/adr/0017-environment-configuration-model.md`, `docs/adr/0018-create-dedicated-dev-environment.md`, `docs/adr/0019-use-separate-posthog-projects-per-environment.md`, GitHub issue #37

## Context

ADR-0019 established that CatVox uses separate PostHog projects per real
environment (`CatVox Dev` and a future `CatVox Prod`). It explicitly left the
project-to-environment mapping permissive — future test or staging GCP/Firebase
projects could intentionally share the Dev analytics project unless a later
decision created a separate analytics isolation tier.

When designing the issue #37 Slice 3 Terraform scaffolding for PostHog, the
permissive clause pointed at an organisation-scoped Terraform root: a single
state managing both Dev and Prod, a new dedicated GCS state bucket, a new
`posthog` GitHub Environment, new IAM, and a new Workload Identity Federation
auth path — all parallel to the existing per-environment GCP infrastructure.

Reconsidering the coupling: app code defines events, and PostHog dashboards
visualise those events. The unit of change that ships to users is
`(app build + backend deploy + analytics schema)` together. Splitting analytics
state from app state means a Prod app deploy and a Prod dashboard update happen
against different Terraform state, different secrets, and different review
chains — accidental complexity that produces drift over time.

The PostHog provider also makes `posthog_project` an organisation-scoped
resource: any Terraform-managing API key needs organisation-level
`project:write` scope. That single fact rules out perfectly sealing Dev and Prod
credentials from each other at the PostHog API-key layer. Practical isolation
must therefore come from Terraform state separation, CI identity separation,
and per-environment scoped API keys — exactly what the per-environment GCP
infrastructure already provides.

## Decision

PostHog environments map 1:1 to CatVox environments:

- Debug iOS build + Dev GCP backend + Dev PostHog project
  (`kathelix-catvox-dev` ↔ `CatVox Dev`)
- Release iOS build + Prod GCP backend + Prod PostHog project
  (future `kathelix-catvox-prod` ↔ future `CatVox Prod`)

The "mapping does not need to be one-to-one" clause of ADR-0019 is superseded.
Future test, staging, or TestFlight environments each get their own PostHog
project by default. Pointing a future ephemeral environment at the existing Dev
PostHog project remains possible as a deliberate per-environment override, but
is no longer the default.

Operational implications:

- PostHog Terraform state for each environment lives in the same GCS bucket as
  that environment's GCP infrastructure state, with prefix `posthog/state` (vs
  `catvox/state` for GCP infrastructure). No new state bucket is introduced.
- PostHog CI authentication reuses the existing per-environment `catvox-ci-sa`
  and Workload Identity Federation pool. No new service account, no new WIF
  pool, no new GitHub Environment is introduced.
- PostHog secrets (`POSTHOG_API_KEY`, `POSTHOG_ORGANIZATION_ID`) land in the
  existing per-environment GitHub Environments — `dev` today, future `prod`
  later. The PostHog API host and project ID remain in
  `config/environments/<env>.xcconfig` as `CATVOX_POSTHOG_API_HOST_NAME` and
  `CATVOX_POSTHOG_PROJECT_ID` and are passed to Terraform by the Makefile.
- Each environment's PostHog API key is a scoped key limited to that
  environment's PostHog project, with the minimum organisation-level scope
  needed to manage the project resource. Organisation-level `project:write` is
  the one cross-environment privilege the keys cannot avoid because creating
  `posthog_project` resources requires it.
- PostHog Terraform code lives in a separate root (`terraform/posthog/`) and a
  separate CI workflow (`.github/workflows/posthog-terraform.yml`). This keeps
  PostHog change cadence independent from GCP infrastructure change cadence and
  keeps `terraform plan`/`apply` runtimes short.
- Per-environment values for PostHog Terraform are driven from
  `config/environments/<env>.xcconfig` (the existing authoritative environment
  definition) and per-environment GitHub Environment secrets/variables. The
  PostHog Terraform root intentionally does not introduce a parallel
  `terraform/posthog/env/<env>.tfvars` directory.

## Consequences

### Positive

- App, backend, and analytics ship together per environment. Event additions in
  a Dev feature land in Dev PostHog; the same change reaching Prod lands in
  Prod PostHog. No cross-environment coordination is required to keep
  dashboards in sync with code.
- Operational simplification: the existing per-environment GCS bucket, CI
  service account, WIF pool, and GitHub Environment cover PostHog Terraform
  with zero new infrastructure.
- Tighter practical blast radius: a misconfigured Dev PostHog deploy cannot
  reach Prod resources beyond the unavoidable organisation-level
  project-creation privilege, because state, credentials, and CI identity are
  all per environment.
- Adding a future TestFlight or staging environment automatically gets its own
  PostHog project under this convention, with no further architectural decision
  required.
- `config/environments/<env>.xcconfig` remains the single authoritative
  environment definition; PostHog Terraform reads from the same source rather
  than introducing a parallel "what is Dev?" file that could drift.

### Negative / Trade-offs

- Cannot quickly stand up a shared-Dev-PostHog ephemeral environment as
  ADR-0019 originally allowed without an explicit per-environment override.
- PostHog Terraform changes for Prod cannot ship until Prod GCP exists (state
  bucket, CI service account, WIF). Slice 3 of issue #37 therefore lands Dev
  PostHog Terraform only; Prod PostHog Terraform follows whenever future Prod
  GCP provisioning happens.
- Dashboards and insights are defined per environment in Terraform code, which
  requires careful use of locals/modules in later slices to keep the
  definitions DRY across Dev and Prod.

## Alternatives Considered

### Organisation-scoped PostHog Terraform (Codex's original Slice 3 plan)

A single PostHog Terraform root managing both Dev and Prod projects via
organisation-wide credentials, with a new dedicated GCS state bucket and a new
`posthog` GitHub Environment.

Rejected as the primary direction because it decouples PostHog deploy lifecycle
from GCP/app deploy lifecycle, requires new state-bucket and GitHub Environment
infrastructure that 1:1 alignment avoids, and creates a credential model where
one API key has authority over both projects from the same Terraform run.

### Per-environment PostHog tfvars files

Mirroring the GCP root by introducing `terraform/posthog/env/<env>.tfvars`
alongside `config/environments/<env>.xcconfig`.

Rejected because it duplicates the authoritative environment definition.
PostHog Terraform has no Terraform-only secrets that need a committed tfvars
shape (its secrets all live in GitHub Environment), so the existing xcconfig +
GitHub Environment value model is sufficient.

## Future Work

- Slice 4 of issue #37: import the existing `CatVox Dev` PostHog project, its
  dashboard, and its wizard-created insights into the Dev PostHog Terraform
  state.
- Slice 5 of issue #37: normalise the imported dashboard/insight definitions
  into reusable Terraform that produces the same MVP dashboard shape for Dev
  and future Prod.
- When future Prod GCP provisioning happens, set up the Prod PostHog Terraform
  state prefix (`posthog/state` in `catvox-tf-state-kathelix-catvox-prod`) and
  Prod-scoped PostHog credentials in the same change.
- Consider whether to migrate the GCP Terraform root toward the same
  xcconfig-driven environment definition model in a future cleanup, retiring
  `terraform/env/<env>.tfvars` for non-secret values.
