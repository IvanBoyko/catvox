# Architecture Decision Records

This directory stores the Architecture Decision Records (ADRs) for the CatVox project.

ADRs capture important technical and architectural decisions in a lightweight, versioned, reviewable form. They help explain not just *what* was decided, but *why*.

## Purpose

Use ADRs to record decisions such as:

- architecture and infrastructure choices
- security and identity approaches
- data storage and lifecycle decisions
- platform and framework selections
- major trade-offs affecting future development

## Rules

- One ADR per decision.
- ADRs are immutable records of decisions made at a point in time.
- If a decision changes later, create a new ADR that supersedes the earlier one rather than rewriting history.
- Keep ADRs short, concrete, and focused on the decision and its consequences.
- ADRs live in Git and should be reviewed through normal pull requests.

## Naming Convention

Files use a numeric prefix followed by a short kebab-case title:

- `0001-use-adr.md`
- `0002-...`

The numbering is sequential and permanent.

## Suggested Template

Each ADR should usually contain:

- Title
- Status
- Date
- Context
- Decision
- Consequences
- Supersedes / Superseded by (when relevant)

## Index

| ADR | Title | Status |
|---|---|---|
| 0001 | Use Architecture Decision Records | Accepted |
| 0002 | Use App Attest for Firebase App Check | Accepted |
| 0003 | Use Firebase Cloud Functions 2nd Gen as Backend Proxy | Accepted |
| 0004 | Store Terraform Remote State in GCS | Accepted |
| 0005 | Use Workload Identity Federation for Terraform CI | Accepted |
| 0006 | Split Runtime and CI Service Accounts | Accepted |
| 0007 | Persistent Anonymous userId via UserDefaults for Quota Enforcement | Accepted |
| 0008 | Load AI System Prompt from Markdown at Build Time | Accepted |
| 0009 | Render Share Videos On Device | Accepted |
| 0010 | Separate Vertex Response Schema from System Instruction | Accepted |
| 0011 | Use PostHog for Product Analytics | Accepted |
| 0012 | Use Google Gen AI SDK for Vertex Gemini Calls | Accepted |
| 0013 | Treat Current GCP Project as Dev Until Production Split | Accepted |
| 0014 | Use Makefile as Local and CI Command Facade | Accepted |
| 0015 | Reserve Quota Before Vertex Analysis | Accepted |
| 0016 | Persist App Check Debug Token for Local iPhone Builds | Accepted |
| 0017 | Environment Configuration Model | Accepted |
| 0018 | Create Dedicated Dev Environment | Accepted |
| 0019 | Use Separate PostHog Projects per Environment | Accepted (updated by ADR-0020) |
| 0020 | Bind PostHog Projects 1:1 to CatVox Environments | Accepted |
| 0021 | Store Non-Secret Environment Values in xcconfig | Accepted (updated by ADR-0022) |
| 0022 | Use CATVOX_PROJECT_ID as Canonical Project ID | Accepted |

## Workflow

1. Create a new numbered ADR when a meaningful technical or architectural decision is made.
2. Review it in the same PR as the related design or implementation change where possible.
3. Mark the ADR status clearly.
4. If a later decision replaces it, create a new ADR and cross-reference both records.
