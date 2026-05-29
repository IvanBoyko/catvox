# ADR-0026: Classify Environments by Security Tier in Config

- Status: Accepted
- Date: 2026-05-29
- Owners: Kathelix / CatVox
- Related docs: `docs/CREATE_NEW_ENVIRONMENT.md`, `docs/TRD.md`
- Related ADRs: ADR-0017 (Environment Configuration Model), ADR-0021 (Store
  Non-Secret Environment Values in xcconfig), ADR-0024 (Scope CI WIF Trust),
  ADR-0025 (Enforce App Check on Firestore)

## Context

CatVox is growing from one live environment (Dev) toward several (Prod now, and
plausibly Staging later). Environments fall into two security tiers:

- **Mutable / integration-safe** (Dev-like): debug App Check token allowed, App
  Check may be unenforced, WIF trusts any ref, Firestore-mutating integration
  tests permitted.
- **Protected** (Prod/Staging-like): no debug token, App Check enforced, WIF ref
  pinned, protected GitHub Environment, non-invasive smoke only.

AGENTS.md already says to treat the environment name as data (ADR-0017). In
practice some tooling had drifted from that: env-specific script files
(`scripts/prod-smoke.mjs`, `scripts/validate-prod-environment-config.mjs`) and a
hard-coded per-environment "golden values" map (`exactProdValues`) baked literal
environment identity into code. That does not scale to more environments and
duplicates values that already live in `config/environments/<env>.xcconfig`.

## Decision

1. **Declare the security tier in config.** Add
   `CATVOX_ENVIRONMENT_PROTECTED` (`true`/`false`) to
   `config/environments/<env>.xcconfig`. It is the single switch that classifies
   an environment's tier.

2. **Validate generically.** Replace `validate-prod-environment-config.mjs` with
   an environment-agnostic `scripts/validate-environment-config.mjs <env>` and
   `prod-smoke.mjs` with `scripts/smoke.mjs`. The validator checks
   environment-agnostic invariants for any environment — required keys, internal
   consistency of identifiers derived from `CATVOX_PROJECT_ID`, hostname/enum/
   boolean format, deferred-placeholder policy, and no references to another
   environment — and, when `CATVOX_ENVIRONMENT_PROTECTED=true`, the protected
   invariants: App Check `ENFORCED`, a pinned `CATVOX_GCP_WIF_GITHUB_REF`, the
   `ABANDON` deletion policy, and absence from
   `CATVOX_INTEGRATION_SAFE_ENVIRONMENTS`.

3. **No env-specific code or filenames; no golden values in code.** The only
   literals in shared scripts are generic key names and enum values. The
   `exactProdValues` golden map is removed in favour of derived-consistency
   checks.

4. **Literal environment names live only in the CI/CD promotion pipeline.**
   Workflows that encode promotion between environments may name `dev`/`prod`
   (for example `build.yml` running `make ios-validate-env-config-structure
   CATVOX_ENVIRONMENT=prod`). Everywhere else, the environment name is data.

## Rationale

- A future Staging environment inherits the entire protected posture by setting
  `CATVOX_ENVIRONMENT_PROTECTED=true` and the matching config values — no new
  code, no new script, no new golden map.
- Behaviour differences live in reviewable committed config, consistent with
  ADR-0017 and ADR-0021.
- Centralizing the tier decision in one flag makes the protected invariants
  enforceable by a single generic validator and testable as a pure function.

## Consequences

### Positive

- Adding an environment is a config change, not a code change.
- The protected-posture invariants are enforced uniformly and unit-tested
  (`scripts/test/validate-environment-config.test.mjs`).
- Removes per-environment golden values from code.

### Negative / Trade-offs

- Every environment config must now declare `CATVOX_ENVIRONMENT_PROTECTED`; the
  validator requires it.
- The generic validator must be careful with identifier collisions (e.g. a
  protected bundle id that is a prefix of a Dev bundle id); it matches project
  ids as substrings but bundle ids exactly.

## Rejected Options

### Option A: Keep env-specific scripts and a golden-values map

Rejected: does not scale to more environments, duplicates config in code, and
contradicts ADR-0017's "environment name as data".

### Option B: Derive the tier from `CATVOX_INTEGRATION_SAFE_ENVIRONMENTS`

Rejected: that key is specifically about mutable integration tests. Overloading
it to mean "security tier" couples two concepts; an explicit
`CATVOX_ENVIRONMENT_PROTECTED` flag states intent directly.

## Implementation Notes

- `config/environments/<env>.xcconfig`: `CATVOX_ENVIRONMENT_PROTECTED`
  (Dev `false`, Prod `true`).
- `scripts/validate-environment-config.mjs`, `scripts/smoke.mjs`: generic.
- `Makefile`: `make smoke`, `make ios-validate-env-config-structure` (both take
  `CATVOX_ENVIRONMENT`); `CATVOX_ENVIRONMENT_PROTECTED ?= false` fallback.
- `.github/workflows/build.yml`: runs the structural validator with
  `CATVOX_ENVIRONMENT=prod` (CI/CD pipeline literal).
- Tests: `scripts/test/validate-environment-config.test.mjs`.

## Review Trigger

Revisit if a third security tier is needed (beyond mutable/protected), or if
environment classification needs to depend on more than one config property.
