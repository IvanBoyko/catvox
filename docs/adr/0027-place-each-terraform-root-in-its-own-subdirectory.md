# ADR-0027: Place Each Terraform Root in Its Own Subdirectory

- Status: Accepted
- Date: 2026-06-01
- Owners: Kathelix / CatVox
- Related docs: `terraform/README.md`, `docs/TRD.md`, `docs/CREATE_NEW_ENVIRONMENT.md`
- Related ADRs: ADR-0004 (Store Terraform Remote State in GCS), ADR-0014 (Makefile
  as Command Facade), ADR-0019 / ADR-0020 (separate PostHog root), ADR-0021
  (Store Non-Secret Environment Values in xcconfig)

## Context

CatVox has two Terraform roots: the GCP/Firebase foundation and the PostHog
analytics root. They have independent GCS state (prefixes `catvox/state` and
`posthog/state`) and separate CI workflows. Per ADR-0019/ADR-0020 the PostHog
root lives in its own subdirectory, `terraform/posthog/`.

The GCP/Firebase root, however, sat directly in `terraform/`, so `terraform/`
was playing two roles at once: the **container** for all roots *and* itself the
GCP root (its `.tf` files lived directly in it). That dual role forced several
special cases:

- The `terraform.yml` path filter had to carve PostHog out of its own parent:
  `terraform/**` plus a `!terraform/posthog/**` negation. Any third root added
  under `terraform/` would silently be swept into the GCP workflow and need
  another negation.
- The GCP root's `.gitignore` rules lived in the repo-root `.gitignore`
  (prefixed `terraform/...`), while the PostHog root owned its rules in
  `terraform/posthog/.gitignore` — an asymmetry.

There is no Terraform-level coupling between the roots (no `terraform_remote_state`
or cross data sources); the only dependency is operational and one-directional —
the PostHog root reuses the state bucket, `catvox-ci-sa`, and WIF pool the GCP
root creates.

## Decision

1. **Move the GCP/Firebase root into `terraform/core/`.** After the move,
   `terraform/` is a pure container holding `terraform/core/`,
   `terraform/posthog/`, and the umbrella `terraform/README.md`.

2. **Move its private inputs with it:** `terraform/env/` becomes
   `terraform/core/env/`. The core root is now self-contained, mirroring the
   PostHog root (which deliberately has no `env/`).

3. **Each root owns its `.gitignore`.** Add `terraform/core/.gitignore`
   (mirroring `terraform/posthog/.gitignore`) and remove the GCP-root rules from
   the repo-root `.gitignore`.

4. **Keep `terraform/README.md` as the umbrella.** It documents the layout for
   all roots and is not core-specific, so it stays at `terraform/README.md`
   (the living-doc contract test, markdownlint globs, and `scripts.yml` /
   `markdownlint.yml` path filters reference that path).

5. **The remote-state backend is unchanged.** The GCS bucket and the
   `catvox/state` prefix are passed via `-backend-config` (a Makefile constant),
   not derived from the directory name. No state migration is performed.

## Rationale

- The state prefix is configuration, not a function of the directory path, and
  the HCL is location-independent (no `path.module` / `..` references), so the
  rename is behaviour-free: `terraform init` + `plan` shows no resource diff.
- One honest convention — "one subdirectory per Terraform root; `terraform/` is a
  container" — replaces the special cases. The `terraform.yml` filter simplifies
  to `terraform/core/**` with no negation, and new roots are isolated by
  construction.
- The layout now matches the real dependency direction: `core/` is the
  foundation, `posthog/` is a dependent satellite.

## Consequences

### Positive

- Simpler, negation-free CI path filter; adding a future root cannot leak into
  the core workflow.
- Symmetric roots: each owns its `.tf`, lock file, and `.gitignore`.
- No state migration, no resource changes, no downtime.

### Negative / Trade-offs

- A wide, mechanical reference sweep across the Makefile, scripts, CI, and docs
  (one-time).
- Operators with a local working copy must re-run `terraform init` (the
  `.terraform/` cache is not relocated) and move any local
  `terraform/core/env/<env>.tfvars` from the old path.
- Historical ADRs, audits, and archived reports keep their original
  `terraform/...` paths as point-in-time records; they are not rewritten. Paths
  such as `terraform/env/<env>.tfvars` or `terraform/main.tf` in ADRs dated
  before this one refer to the pre-0027 layout.

## Rejected Options

### Option A: Keep the GCP root at `terraform/` and only special-case CI

Rejected: preserves the container/root dual role and the `!terraform/posthog/**`
negation, and does not scale to a third root.

### Option B: Move the `.tf` files but keep `terraform/env/` shared

Rejected: re-introduces the smell the move removes — the container would still
hold root-specific inputs, and `core/` would not be self-contained.

## Implementation Notes

- `git mv` `*.tf`, `tests/`, `env/*.tfvars.example`, and `.terraform.lock.hcl`
  into `terraform/core/`.
- `terraform/core/.gitignore` added; repo-root `.gitignore` trimmed.
- `Makefile`: `cd terraform` → `cd terraform/core`; `CATVOX_TF_VARS_FILE` and the
  `patsubst` helper re-prefixed; `terraform-output-firebase-plist` redirect
  `../` → `../../` (one level deeper).
- `scripts/{smoke.mjs,write-environment-config.sh,import-preexisting-resources.sh,destroy-environment.sh,lib/app-check-debug-token.sh,run-on-iphone.sh}`
  and the import-preexisting test mock updated to `terraform/core`.
- `.github/workflows/terraform.yml`: path filter → `terraform/core/**`.
- Living docs updated (`terraform/README.md`, `AGENTS.md`, `docs/TRD.md`,
  `docs/CREATE_NEW_ENVIRONMENT.md`, `docs/DEBUG.md`).

## Review Trigger

Revisit if a future root needs to share inputs with the core root, or if the
two roots ever need a Terraform-level dependency (which would argue for an
explicit `terraform_remote_state` data source rather than a directory change).
