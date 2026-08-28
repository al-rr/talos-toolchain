# talos-toolchain

Reusable toolchain to bootstrap and operate Talos clusters with a clear day-1
and day-2 contract.

## Scope

- Day-1 lifecycle orchestration (`cluster.sh`)
- Day-2 platform/GitOps operations (`talos-gitops.sh`)
- Local Docker/Colima Talos lifecycle (`local-cluster.sh`)
- Reusable shell libraries for Talos workflows

## Documentation

- Documentation index: `docs/en/README.md` / `docs/pt-br/README.md`
- macOS host setup: `docs/en/host-setup.md` / `docs/pt-br/host-setup.md`
- Shell requirements: `docs/en/shell-requirements.md` /
  `docs/pt-br/shell-requirements.md`
- Day-1 project variables: `docs/en/day1-project-vars.md` /
  `docs/pt-br/day1-project-vars.md`
- XDG environment configuration: `docs/en/environment-config.md` /
  `docs/pt-br/environment-config.md`
- Local Docker/Colima cluster: `docs/en/local-cluster.md` /
  `docs/pt-br/local-cluster.md`
- Cilium and Argo CD handoff: `docs/en/cilium-gitops-handoff.md` /
  `docs/pt-br/cilium-gitops-handoff.md`

## Shell Requirements

`cluster.sh` and `talos-gitops.sh` require Bash 5+. On macOS (stock Bash 3.2),
both entrypoints locate a Homebrew Bash 5 at fixed candidate paths and re-exec
under it, or stop with an actionable `brew install bash` message before any
Bash-5-only syntax runs. See `docs/en/shell-requirements.md` for the full
contract. `local-cluster.sh` is a separate, implemented Docker/Colima
entrypoint; it has its own Bash 5 preflight and never loads VMware/vSphere
variables. See `docs/en/local-cluster.md` for its lifecycle and safety guards.

## Current capabilities

- `cluster.sh` creates a project scaffold, generates Talos configuration,
  applies machine configuration, bootstraps a control plane, and performs the
  supported day-1 lifecycle actions. Run `scripts/talos/cluster.sh --help` for
  the current action and option contract.
- `local-cluster.sh` creates, inspects, and safely destroys an isolated local
  Docker-backed cluster. It supports the default Talos CNI or a documented
  Cilium bootstrap path; it does not provision VMware infrastructure.
- `config.sh` manages the documented XDG YAML environment contract, including
  separate non-secret configuration and local credentials handling.
- `talos-gitops.sh` performs the documented day-2 Helm and Argo CD bootstrap
  operations using a selected manifest root.

## Boundaries

- The toolchain remains environment-agnostic. VMware/vSphere VM provisioning,
  lab topology, and VIP validation belong to `provision-talos-vsphere`.
- GitOps desired state belongs to `talos-vsphere-gitops`; after Argo CD takes
  ownership, use GitOps changes rather than continuing imperative addon
  installation.
