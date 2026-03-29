# Day-1 Project Variables (`cluster.sh`)

This document explains the project variables consumed by
`scripts/talos/cluster.sh`.

## Scope

These variables live inside each generated project directory (for example
`clusters/talos-dev/vars.sh` and `vars.local.sh`).

`cluster.sh` does not use `--env`. The project itself is the source of truth.

## File Model

- `vars.sh`: committed baseline for the project.
- `vars.local.sh`: local overrides (sensitive or machine-specific values), not committed.

`cluster.sh` loads `vars.sh` first, then `vars.local.sh` if it exists.

## Required Command Mapping Variables

These are mandatory for day-1 action execution:

- `TALOS_DAY1_GENERATE_CMD`
- `TALOS_DAY1_PROVISION_CMD`
- `TALOS_DAY1_PREPARE_BOOTSTRAP_CMD`
- `TALOS_DAY1_APPLY_CONFIG_CMD`
- `TALOS_DAY1_BOOTSTRAP_CMD`
- `TALOS_DAY1_SYNC_ACCESS_CMD`

If one is empty, `cluster.sh` fails with an explicit error for that action.

## Baseline Addon Variables (`apply-post-bootstrap`)

- `TALOS_CLUSTER_BASELINE_ADDONS`
  - JSON list of addons to install in post-bootstrap baseline.
  - Default generated value: `["cilium"]`.
- `TALOS_DAY1_REQUIRE_CILIUM`
  - `true`/`false`.
  - If `true`, `cilium` must exist in baseline list.
- `TALOS_DAY1_MANIFEST_ROOT_DIR`
  - Root directory that contains addon manifests/charts.
- `TALOS_DAY1_KUBE_CONTEXT`
  - Kube context used to execute post-bootstrap addon installation.

You can override these at runtime with:

- `--addons=...`
- `--manifest-root-dir=...`
- `--kube-context=...`

## Image Variables (`refresh-schematics`)

- `TALOS_CONTROL_PLANE_INSTALLER_IMAGE`
- `TALOS_WORKER_INSTALLER_IMAGE`
- `TALOS_OVA_PATH`

`refresh-schematics` updates these values using Talos Factory schematic IDs.

## Common Topology / Network Variables

Generated defaults include:

- `TALOS_CLUSTER_NAME`
- `TALOS_CLUSTER_ENDPOINT`
- `TALOS_GATEWAY`
- `TALOS_NETMASK_PREFIX`
- `TALOS_NODE_INTERFACE`
- `TALOS_NAMESERVERS`
- `TALOS_CONTROL_PLANE_COUNT`
- `TALOS_WORKER_COUNT`
- `TALOS_CONTROL_PLANE_IPS`
- `TALOS_WORKER_IPS`
- `TALOS_CONTROL_PLANE_NAME_PREFIX`
- `TALOS_WORKER_NAME_PREFIX`

These are project-level inputs for your adapter commands.

## Practical Example

`vars.sh` baseline:

```bash
export TALOS_DAY1_GENERATE_CMD="talosctl gen config ..."
export TALOS_DAY1_PROVISION_CMD="./scripts/provision.sh"
export TALOS_DAY1_PREPARE_BOOTSTRAP_CMD="./scripts/prepare-bootstrap.sh"
export TALOS_DAY1_APPLY_CONFIG_CMD="./scripts/apply-config.sh"
export TALOS_DAY1_BOOTSTRAP_CMD="talosctl bootstrap -n 192.168.0.61"
export TALOS_DAY1_SYNC_ACCESS_CMD="./scripts/sync-access.sh"

export TALOS_DAY1_MANIFEST_ROOT_DIR="/home/user/talos-vsphere-gitops"
export TALOS_DAY1_KUBE_CONTEXT="talos-dev"
export TALOS_CLUSTER_BASELINE_ADDONS='["cilium","longhorn"]'
```

`vars.local.sh` machine override:

```bash
export TALOS_DAY1_KUBE_CONTEXT="talos-dev-admin"
```

## Execution Order Reference

1. `cluster.sh create-project --project-dir=...`
2. Fill `vars.sh` and optionally `vars.local.sh`
3. `cluster.sh refresh-schematics --project-dir=... --talos-version=vX.Y.Z`
4. `cluster.sh generate --project-dir=...`
5. `cluster.sh provision --project-dir=...`
6. `cluster.sh prepare-bootstrap --project-dir=...`
7. `cluster.sh bootstrap --project-dir=...`
8. `cluster.sh apply-post-bootstrap --project-dir=...`
9. `cluster.sh sync-access --project-dir=...`

