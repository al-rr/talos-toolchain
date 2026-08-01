# Documentation Index (EN)

## Repository Purpose

`talos-toolchain` provides reusable Talos automation independent from a
specific lab repository.

## Local-First Boundary

The accepted Milestone A direction is for `talos-toolchain` to be the
canonical, portable Talos CTL for local macOS cluster work, running day-1 and
day-2 Talos lifecycle actions (`cluster.sh`, `talos-gitops.sh`) without
depending on VMware/vSphere provisioning. A first-class local Docker/Colima
Talos backend is not implemented yet — it is scheduled for Iteration 5, after
the macOS/Bash contract work in Iteration 3. Until then, `cluster.sh` does not
create or operate a local macOS cluster independently of VMware. VMware/vSphere
infrastructure provisioning is owned by `provision-talos-vsphere`; once the
local backend lands, that dependency will no longer be a prerequisite of the
local workflow. A later, user-scoped Talos configuration direction builds on
this same local-first boundary.

## Planned Sections

- Architecture and boundaries
- Day-1 workflow (`cluster.sh`)
- Day-2 workflow (`talos-gitops.sh`)
- Upgrade and migration guidance

## Available Guides

- Day-1 project variables: `docs/en/day1-project-vars.md`
- Cross-repository handoff: `provision-talos-vsphere/docs/en/cross-repo-handoff.md`
