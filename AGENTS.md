# Project Agent Instructions

## Purpose

This repository is the reusable Talos toolchain.

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
