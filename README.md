# talos-toolchain

Reusable toolchain to bootstrap and operate Talos clusters with a clear day-1
and day-2 contract.

## Scope

- Day-1 lifecycle orchestration (`cluster.sh`)
- Day-2 platform/GitOps operations (`talos-gitops.sh`)
- Reusable shell libraries for Talos workflows

## Documentation

- English: `docs/en/README.md`
- Portuguese (Brazil): `docs/pt-br/README.md`
- Day-1 project variables (EN): `docs/en/day1-project-vars.md`
- Variaveis de projeto day-1 (PT-BR): `docs/pt-br/day1-project-vars.md`
- Shell requirements (EN): `docs/en/shell-requirements.md`
- Requisitos de shell (PT-BR): `docs/pt-br/shell-requirements.md`

## Shell Requirements

`cluster.sh` and `talos-gitops.sh` require Bash 5+. On macOS (stock Bash 3.2),
both entrypoints locate a Homebrew Bash 5 at fixed candidate paths and re-exec
under it, or stop with an actionable `brew install bash` message before any
Bash-5-only syntax runs. See `docs/en/shell-requirements.md` for the full
contract. A local Docker/Colima execution backend is a later iteration, not
part of this contract.

## Current Status

Bootstrap phase in progress.

Implemented now:

- initial repository scaffold
- bilingual docs entrypoints (`docs/en`, `docs/pt-br`)
- shared Bash library (`scripts/talos/lib/common.sh`)
- day-2 entrypoint migrated baseline:
  - `scripts/talos/talos-gitops.sh`

Planned next:

- migrate day-1 `cluster.sh` and its reusable dependencies
- remove remaining lab-coupled assumptions from CLI examples and docs
