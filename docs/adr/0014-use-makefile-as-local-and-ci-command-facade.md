# ADR-0014: Use Makefile as Local and CI Command Facade

**Status:** Accepted
**Date:** 5 May 2026

## Context

CatVox has several command-heavy workflows: iOS simulator validation, physical-device launch, Firebase Functions build/deploy/test, Terraform plan/apply, and one-time infrastructure bootstrap scripts.

Before this decision, local developers had to remember the underlying command shape for each workflow, while GitHub Actions duplicated many of those command bodies directly in YAML. That made local/CI drift more likely as workflows evolved.

## Decision

Add a repository-root `Makefile` as a thin command facade for local developer automation and reusable CI command bodies.

The Makefile owns stable command entrypoints such as `make ios-test`, `make functions-deploy`, `make functions-integration`, `make terraform-plan`, and `make bootstrap-wif`.

GitHub Actions should call Makefile targets for command bodies where practical, while still owning CI-specific concerns:

- checkout
- toolchain installation
- dependency caches
- Workload Identity Federation authentication
- GitHub PR comments and step-output presentation
- branch/event/path triggers

Terraform apply remains deliberately explicit. Local `make terraform-apply` requires `CONFIRM=apply` and still runs an interactive `terraform apply`; CI uses the separate `make terraform-ci-apply` target with `-auto-approve`.

## Consequences

Local developers get short, discoverable commands through `make help`.

CI and local workflows share more of the same command surface without turning the Makefile into a replacement for GitHub Actions orchestration.

Workflow changes must keep the Makefile, GitHub Actions YAML, and TRD §7 aligned.

The Makefile should stay thin. Larger workflow logic should remain in purpose-built scripts such as `scripts/run-on-iphone.sh` or the Terraform bootstrap scripts.
