# Documentation Index (EN)

## Repository Purpose

`talos-toolchain` provides reusable Talos automation independent from a
specific lab repository.

## Local-First Boundary

The accepted Milestone A direction is for `talos-toolchain` to be the
canonical, portable Talos CTL for local macOS cluster work, running day-1 and
day-2 Talos lifecycle actions (`cluster.sh`, `talos-gitops.sh`) without
depending on VMware/vSphere provisioning. A first-class local Docker/Colima
Talos backend now exists as a separate Milestone-A entrypoint,
`scripts/talos/local-cluster.sh` (see `docs/en/local-cluster.md`); `cluster.sh`
itself remains vSphere-oriented and does not create or operate a local macOS
cluster. VMware/vSphere infrastructure provisioning is owned by
`provision-talos-vsphere` and is not a prerequisite of the local Docker
workflow. A later, user-scoped Talos configuration direction builds on this
same local-first boundary.

## Planned Sections

- Architecture and boundaries
- Day-1 workflow (`cluster.sh`)
- Day-2 workflow (`talos-gitops.sh`)
- Upgrade and migration guidance

## Available Guides

- macOS host tooling setup (`scripts/host/setup-macos.sh`): `docs/en/host-setup.md`
- Day-1 project variables: `docs/en/day1-project-vars.md`
- XDG YAML environment configuration (`config.sh`): `docs/en/environment-config.md`
- Shell requirements (Bash 5 / macOS preflight contract): `docs/en/shell-requirements.md`
- Local Talos cluster (Docker/Colima, `local-cluster.sh`): `docs/en/local-cluster.md`
- YAML style policy and local/CI lint check: `docs/en/yaml-style.md`
- Cilium day-1/day-2 (Argo CD) handoff contract: `docs/en/cilium-gitops-handoff.md`
- Cross-repository handoff: `provision-talos-vsphere/docs/en/cross-repo-handoff.md`
