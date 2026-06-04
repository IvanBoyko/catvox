# ADR-0028: Extract ai-loop to a Standalone Repository Consumed as a Submodule

- Status: Accepted
- Date: 2026-06-04
- Owners: Kathelix / CatVox
- Related ADRs: ADR-0023 (Adopt Hybrid Agent Review Loop), ADR-0014 (Makefile as
  Command Facade)
- Related repo: [`kathelix/ai-loop`](https://github.com/kathelix/ai-loop)

## Context

ADR-0023 introduced the Option B local agent review loop as "a small Python
script under `tools/ai-loop/`". It has since matured into a self-contained,
stdlib-only controller (`ai_loop.py` + `ai_loop_test.py` + `hooks/` + `prompts/`)
with no runtime dependency on any CatVox code: it discovers the repository root
at runtime (`git rev-parse --show-toplevel`) and resolves every path relative to
the consuming repository. The only coupling is the instruction files the loop
reads from the consumer (`AGENTS.md`, `.codex/AGENTS.md`, `CLAUDE.md`) and the
`docs/ai-loop/` log directory it writes — both consumer-owned by design.

Two drivers motivated extraction:

- The tool is only loosely coupled to CatVox and bloats this repository's history
  and CI surface with changes that are conceptually independent.
- We want to reuse the same loop across other projects.

## Decision

Extract `tools/ai-loop/` into its own public repository,
[`kathelix/ai-loop`](https://github.com/kathelix/ai-loop) (GPL-3.0, the same
license as CatVox), preserving the relevant git history with `git filter-repo`
(`--path tools/ai-loop/ --path-rename tools/ai-loop/:`, which re-roots the files
to the new repository root). CatVox consumes it back as a **git submodule mounted
at `tools/ai-loop/`**.

The mount path is deliberately unchanged. The controller hard-codes the
`tools/ai-loop/` location relative to the consumer root (for prompt files, the
hook directory, and the `core.hooksPath` setting), so mounting the submodule at
exactly that path requires **zero changes to the runtime code**. The Makefile
targets (`setup-local-ai-loop`, `ai-loop-start`, `ai-loop-answer`), the
post-commit hook, and `docs/ai-loop/` logging all keep working unchanged.

Scope of this decision (the "minimal" reuse model):

- Keep the `tools/ai-loop/` mount convention. Any project reusing the loop mounts
  the submodule at that same path.
- Making the mount path configurable so the submodule can live anywhere is a
  larger change deferred to v2.0 and tracked separately.

## Consequences

- **Runtime is unchanged.** No edits to `ai_loop.py`. The only code change in the
  extracted repository is making the test resolve its own directory instead of a
  fixed `parents[2]/tools/ai-loop`, so the suite runs from the new repo root.
- **CI ownership.** The loop's primary test and markdownlint runs live in
  `kathelix/ai-loop`'s CI. CatVox drops `tools/ai-loop/**` from the `scripts.yml`
  and `markdownlint.yml` path filters and removes `ai_loop_test.py` from
  `make scripts-test`, so those generic jobs no longer initialize or run the
  submodule. A dedicated consumer-side gate
  (`.github/workflows/ai-loop-submodule.yml`) still does: on changes to the
  `tools/ai-loop` gitlink or `.gitmodules` it checks out the pinned submodule and
  runs its suite, so a pointer- or URL-only bump cannot land an untested loop.
- **Submodule UX.** Contributors clone CatVox with `--recurse-submodules` (or run
  `git submodule update --init tools/ai-loop`); `make setup-local-ai-loop`
  performs the init before configuring hooks. Updating to a newer ai-loop is
  `git submodule update --remote tools/ai-loop` followed by committing the moved
  pointer.
- **History.** The extracted commits reference CatVox PR/issue numbers (e.g. #68,
  #86); they remain meaningful as provenance but resolve against CatVox, not the
  new repository.
- **Reuse.** Other projects adopt the loop by adding the submodule at
  `tools/ai-loop/` and providing the three instruction files.

## Follow-up

- v2.0: generalize the controller's path resolution so the submodule can be
  mounted at an arbitrary path (removing the hard-coded `tools/ai-loop/`
  assumption), enabling looser placement in consumer repositories.
