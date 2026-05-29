# ADR-0024: Scope CI WIF Trust to GitHub Environment and Branch Ref

- Status: Accepted
- Date: 2026-05-29
- Owners: Kathelix / CatVox
- Related docs: `docs/CREATE_NEW_ENVIRONMENT.md`, `docs/TRD.md`
- Updates: ADR-0005 (Use Workload Identity Federation for Terraform CI)

## Context

ADR-0005 established keyless GitHub Actions → GCP authentication via Workload
Identity Federation (WIF), with the pool locked to `kathelix/catvox` through the
provider `attribute_condition` and the `catvox-ci-sa` binding scoped to
`attribute.repository/kathelix/catvox`.

Repository-wide trust was adequate while only Dev existed. Issue #38 introduces a
real Prod environment in `kathelix-catvox-prod` and a protected, manual-only
release path. Repository-wide trust is too broad for Prod: any workflow job in
`kathelix/catvox` — including a PR-triggered job or an unrelated workflow — could
in principle obtain credentials for the Prod CI service account. Prod needs the
CI identity to be reachable only from the protected `prod` GitHub Environment and
only from the `main` branch.

We also want this expressed as reusable, environment-name-as-data configuration
(ADR-0017), not a hard-coded Dev/Prod branch in Terraform.

## Decision

Scope each environment's WIF trust to the **GitHub Environment whose name equals
`CATVOX_ENVIRONMENT`**, and optionally to a **specific Git ref**.

- The provider `attribute_condition` always requires both
  `assertion.repository == kathelix/catvox` and
  `assertion.environment == <environment_name>`.
- When `github_ref` (sourced from `CATVOX_GCP_WIF_GITHUB_REF`) is non-empty, the
  condition additionally requires `assertion.ref == <github_ref>`.
- The `catvox-ci-sa` binding `principalSet` is scoped to
  `attribute.environment/<environment_name>` as a second enforcement layer.
- The provider `attribute_mapping` exposes `attribute.environment` and
  `attribute.ref` so both layers and any future scoping can reference them.

Per-environment values:

| Environment | `assertion.environment` | `github_ref` pin |
|---|---|---|
| `dev` | `dev` | (empty — any ref) |
| `prod` | `prod` | `refs/heads/main` |

Consequently, the GitHub Environment name MUST equal the CatVox environment name
(`dev` → `dev`, `prod` → `prod`), and every CI job that authenticates via WIF
MUST declare the matching `environment:`.

## Rationale

1. **Least privilege for Prod.** Prod credentials are reachable only from the
   protected `prod` Environment on `main`. Combined with required-reviewer
   protection on that Environment, this makes the Prod apply/deploy path manual
   and auditable.
2. **Defense in depth.** Enforcing the scope in both the provider
   `attribute_condition` and the SA `principalSet` means loosening one layer does
   not silently open the other.
3. **Environment names as data (ADR-0017).** The environment scope derives from
   `var.environment_name`; only the optional ref pin needs a dedicated key. No
   hard-coded Dev/Prod branching in Terraform.
4. **Universal, not Prod-only.** Applying environment scoping to Dev as well
   tightens Dev's previously repo-wide trust at no cost — all Dev WIF jobs
   already declare `environment: dev`.

## Consequences

### Positive

- Prod CI identity is unreachable outside the protected `prod` Environment on
  `main`.
- Dev trust is also tightened from repo-wide to environment-scoped.
- The trust model is uniform and data-driven across environments.

### Negative / Trade-offs

- Any workflow job that authenticates via WIF must set `environment:`; a job that
  forgets it is denied at token exchange. This is documented in `AGENTS.md` and
  `docs/CREATE_NEW_ENVIRONMENT.md`.
- Prod cannot run an automatic per-PR `terraform plan` under this trust, because
  PR jobs are not on `main` and are not in the `prod` Environment. This is
  intentional and consistent with the protected/manual-only Prod contract; Prod
  plan/apply runs via a manual, environment-gated workflow.
- The first Prod `terraform apply` (which creates the WIF pool and `catvox-ci-sa`)
  must be run by an operator locally, because CI cannot authenticate before that
  identity exists. Every subsequent apply and all Functions deploys go through the
  protected CI path.

## Rejected Options

### Option A: Keep repository-wide trust for Prod

Rejected: any job in the repo could obtain Prod credentials, defeating the
protected-release goal.

### Option B: Add a separate `github_environment` variable

Rejected: the GitHub Environment name is required to equal `CATVOX_ENVIRONMENT`,
so the value is already available as `var.environment_name`. A separate variable
would be a redundant input that could drift from the environment name.

### Option C: Scope by branch ref only (`refs/heads/main`)

Rejected as insufficient alone: it does not require the protected Environment, so
an unprotected job on `main` would still authenticate. Environment scoping is the
primary control; the ref pin is an additional Prod constraint.

## Implementation Notes

- `terraform/variables.tf`: add `github_ref` (default `""`).
- `terraform/iam.tf`: compute `local.wif_attribute_condition`; add
  `attribute.environment` / `attribute.ref` mappings; scope the `ci_sa_wif_binding`
  principalSet to `attribute.environment/<environment_name>`.
- `Makefile`: pass `TF_VAR_github_ref` from `CATVOX_GCP_WIF_GITHUB_REF`.
- `config/environments/<env>.xcconfig`: `CATVOX_GCP_WIF_GITHUB_REF` (empty for
  Dev, `refs/heads/main` for Prod).
- `terraform/tests/wif_and_app_check.tftest.hcl`: cover env-only, env+ref, and
  ref-trimming condition forms plus the environment-scoped principalSet.

## Required Document Updates

### HLD

Keep the keyless-WIF statement; no high-level direction change.

### TRD

Note that WIF trust is scoped per environment to the matching GitHub Environment
and, for Prod, to `main`.

## Review Trigger

Revisit if CI moves off GitHub Actions, if GitHub OIDC claim semantics change
(`environment`, `ref`), or if the environment-name ↔ GitHub-Environment-name
equality rule no longer holds.
