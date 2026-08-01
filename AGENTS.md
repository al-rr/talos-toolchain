# Project Agent Instructions

## Purpose

This repository is the reusable Talos toolchain.

## Cross-Repository Planning

- Read `docs/planning/talos-projects-roadmap.md` before cross-repository or
  roadmap work.
- Treat that roadmap as the canonical decision and status document; the files
  under `docs/planning/reviews/` are preserved source reviews, not competing
  plans.
- Before implementing an iteration, create or update its local record under
  `docs/planning/execution/` with the implementer, reviewer, branch, baseline
  commit, scope, and acceptance criteria.
- Implementation and independent review are local-first. GitHub issues, pushes,
  and pull requests are optional and require explicit owner authorization.
- The implementer and reviewer must be different agents. Do not edit the same
  branch concurrently.

## Language Policy

- Script internals are English-only:
  - comments
  - CLI help
  - log and error messages
- Operator-facing documentation is bilingual:
  - English in `docs/en/`
  - Portuguese (Brazil) in `docs/pt-br/`
- Do not mix both languages in the same document file.

## Scope Boundaries

- Keep this repository environment-agnostic.
- Do not embed lab-specific values, static host IP maps, or local-only paths.
- Keep wrappers for specific environments outside this repository.

## Script Standards

- Use Bash with strict mode: `set -euo pipefail`.
- Use `shdoc` in maintained entrypoints.
- Keep actions explicit and reproducible.
