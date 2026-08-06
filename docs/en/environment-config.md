# XDG YAML Environment Configuration (`config.sh`)

This document describes the data-only YAML configuration contract managed by
[`scripts/talos/config.sh`](/home/vagrant/talos-toolchain/scripts/talos/config.sh)
and implemented in
[`scripts/talos/lib/yaml-config.sh`](/home/vagrant/talos-toolchain/scripts/talos/lib/yaml-config.sh).

## Scope

Configuration is YAML data, never sourced as shell. It lives under
`XDG_CONFIG_HOME` (default `~/.config/talos-toolchain`), outside any Git
checkout:

```
${XDG_CONFIG_HOME:-~/.config}/talos-toolchain/
  base/config.yaml                       # non-secret shared defaults
  environments/<name>/config.yaml        # non-secret environment overrides
  environments/<name>/credentials.yaml   # protected secrets (mode 0600)
```

`vars.sh`/`vars.local.sh` remain a temporary compatibility path for existing
project layouts (see
[`day1-project-vars.md`](day1-project-vars.md)). They are read only after the
same secure-source checks described below.

## Bootstrap

```bash
scripts/talos/config.sh bootstrap --environment=lab
scripts/talos/config.sh bootstrap --environment=lab --force   # overwrite existing files
scripts/talos/config.sh show --environment=lab                # redacted diagnostic dump
```

Bootstrap is idempotent: existing, already-valid files are left untouched
unless `--force` is given. Directories are created mode `0700`;
`config.yaml` files are written mode `0600`; `credentials.yaml` is always
mode `0600`. Bootstrap refuses — before any `mkdir -p`, `chmod`, or write —
any pre-existing directory or file that is a symlink, not the expected type,
or otherwise fails the secure checks below. This applies at every
toolchain-managed ancestor level, not only the leaf directories: the
`talos-toolchain` root itself, its `environments` parent, `base/`, and
`environments/<name>/` are each checked/created in that order, root-first,
so a `mkdir -p` on a deeper path is never the first thing to touch a
shallower, unverified ancestor. `--force` may only overwrite a file that has
already passed those checks, never write through a symlink or replace an
unsafe file.

## Secure file checks

Before any YAML file (or legacy `vars.sh`/`vars.local.sh`) is read, the
loader verifies:

- the path is a real file, not a symlink;
- it is owned by the current user;
- `base/config.yaml` and `environments/<name>/config.yaml` are not
  group/world writable;
- `environments/<name>/credentials.yaml` is exactly mode `0600`;
- `base/` and `environments/<name>/` directories are exactly mode `0700`;
- the `talos-toolchain` root and its `environments` parent, if either
  already exists, are real (non-symlink) directories passing the same
  mode/ownership check — a file cannot be trusted just because it
  individually passes its own check while being reached only through a
  swapped-in ancestor symlink.

Any violation refuses the read with an actionable error instead of loading
the file. A YAML file that fails to parse (malformed syntax) is rejected
outright as well, before any value could be exported — schema validation
never treats a parse error as "no violations found".

## Allowlisted schema

Only the dotted paths declared in `TALOS_CONFIG_SCHEMA_TABLE` (non-secret)
and `TALOS_CONFIG_SECRET_SCHEMA_TABLE` (credentials-only) in
`lib/yaml-config.sh` are accepted. Every node in the document is checked, not
only scalar leaves: unknown keys, type mismatches (for example a string
where an integer is expected, or a float where an integer is expected), and
unsupported shapes at a known field — `null`, an empty or non-empty map, or
an empty or non-empty list where a scalar is expected — are all rejected
before any value is exported. A known namespace prefix (for example `talos`
or `haproxy`) may still be an empty mapping. Adding a new field means adding
one row to the relevant table.

Current non-secret fields map to existing environment variables, for
example:

| YAML path | Environment variable |
| --- | --- |
| `cluster.name` | `TALOS_CLUSTER_NAME` |
| `cluster.environment` | `TALOS_CLUSTER_ENVIRONMENT` |
| `cluster.endpoint` | `TALOS_CLUSTER_ENDPOINT` |
| `vsphere.endpoint` | `VSPHERE_ENDPOINT` |
| `ssh.user` | `SSH_USER` |
| `haproxy.vip` | `HAPROXY_VIP` |
| `talos.controlPlane.count` | `TALOS_CONTROL_PLANE_COUNT` |
| `talos.network.gateway` | `TALOS_GATEWAY` |

Credentials-only fields:

| YAML path | Environment variable |
| --- | --- |
| `vsphere.password` | `VSPHERE_PASSWORD` |
| `ssh.privateKeyFile` | `SSH_PRIVATE_KEY_FILE` |
| `ansible.privateKeyFile` | `ANSIBLE_PRIVATE_KEY_FILE` |
| `build.password` | `BUILD_PASSWORD` |

## Precedence

Values are applied in this order, later layers overriding earlier ones:

1. Defaults (empty/neutral values baked into the schema's generated files).
2. `base/config.yaml` (shared, non-secret).
3. Tracked project `config.yaml` (non-secret, committed with the cluster
   project, no site secrets).
4. `environments/<name>/config.yaml` (non-secret, environment-specific).
5. `environments/<name>/credentials.yaml` (secrets only).
6. Explicit CLI flags on the entrypoint invoking the loader (applied by the
   caller after `talos_config_load` returns).

`cluster.sh` sources legacy `vars.sh`/`vars.local.sh` first (compatibility
layer only) and then calls this loader, so the YAML environment/credentials
layers always win over anything legacy sets — legacy values never override
the resolved YAML configuration. The project's own `config.yaml` (if present)
is passed in as tracked intent. `cluster.sh`
requires `yq` for every action except `create-project` (which stays fully
offline); it fails with an actionable error rather than silently skipping the
YAML layer when `yq` is missing.

Environment names are restricted to a single, safe path component
(`[A-Za-z0-9][A-Za-z0-9._-]*`): empty names, slashes, dot-only names (`.`,
`..`), and any other path-traversal-shaped input are rejected before any
path is built from them.

## A cluster and its environment are different identities

Several clusters normally share one environment, so the environment is never
derived from the cluster's name. It resolves in this order:

1. `--environment=<name>` on the command line, for a one-run override.
2. `cluster.environment` in the project's own tracked `config.yaml`.
3. `lab`.

Two clusters reading the same environment is the normal case, not an
exception:

```yaml
# clusters/cluster-lab/config.yaml
cluster:
  name: "cluster-lab"          # container-backed
  environment: "lab"

# clusters/cluster-lab-vmware/config.yaml
cluster:
  name: "cluster-lab-vmware"   # vSphere, 3 control planes, 3 workers, HAProxy
  environment: "lab"
```

Both read the same `environments/lab/config.yaml` and
`environments/lab/credentials.yaml` — one set of endpoints, networks and
credentials, shared. What differs between them belongs in each project, not in
duplicated environment values.

Earlier versions defaulted the environment to the cluster name, which sent
every cluster looking for an environment named after itself and silently
finding none. A project created before `cluster.environment` existed falls
back to `lab` rather than to its own name.

## Redacted diagnostics

`config.sh show --environment=<name>` prints every resolved variable with
every credentials-schema value replaced by `[REDACTED]`. It never prints the
raw contents of `credentials.yaml`.

## Project scaffolding

`cluster.sh create-project` no longer bakes concrete site IPs, usernames, or
passwords into the generated `vars.sh`/`vars.local.example.sh` — those
values are left empty with inline guidance to use `vars.local.sh` or the XDG
environment credentials file. It also scaffolds a tracked, non-secret
`config.yaml` in the project directory for use as the project-intent layer
above.
