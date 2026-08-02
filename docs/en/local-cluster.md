# Local Talos Cluster (Docker/Colima, Milestone A)

## Scope

`scripts/talos/local-cluster.sh` is a dedicated wrapper around `talosctl
cluster create docker` for a single, isolated local development cluster. It
uses the explicit Docker backend subcommand, not the deprecated generic
`talosctl cluster create --provisioner docker` spelling — with current
`talosctl` releases that deprecated form is redirected to `cluster create
dev`, which selects QEMU instead of Docker. It is a separate entrypoint from
the vSphere-oriented `cluster.sh`:

- It never sources vSphere/VMware variables and never invokes anything in
  `provision-talos-vsphere`.
- It never starts, stops, or reconfigures Colima or the Docker daemon. Start
  Colima yourself (`colima start`) before using `create`; the wrapper only
  detects and reports state.
- Every cluster it manages is isolated under its own directory, so its
  talosconfig/kubeconfig/Talos state never collide with each other or with
  your default `~/.talos` or `~/.kube/config`.

## Requirements

- **Bash 5+** (same preflight contract as `cluster.sh`; see
  `docs/en/shell-requirements.md`).
- `talosctl`, the Docker CLI, and the Colima CLI on `PATH`.
- A responsive Docker daemon. `create` and `status` check this with
  `docker info` and never attempt to start or configure Docker.

## State layout

Each cluster is keyed by a safe `--name` (lowercase alphanumeric and dashes
only; no `.`, `/`, or leading/trailing dash) and rooted at an XDG state
directory:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/talos-toolchain/local-clusters/<name>/
├── talos-state/                      # --state passed to talosctl
├── talosconfig                       # isolated talosconfig for this cluster
├── kubeconfig                        # isolated kubeconfig for this cluster
└── .talos-toolchain-local-cluster    # wrapper marker (create/destroy guard)
```

`--state-root` overrides the root directory (used by the offline test suite;
not needed for normal operator use). Names containing `..` or `/` are
rejected before any path is built or any directory is created.

## Actions

```bash
# Preview, then create (defaults: 1 control plane, 1 worker)
./scripts/talos/local-cluster.sh create --name=dev --dry-run
./scripts/talos/local-cluster.sh create --name=dev

# Read-only diagnostics: wrapper marker, Docker/Colima state, talosctl cluster show
./scripts/talos/local-cluster.sh status --name=dev

# Preview, then tear down
./scripts/talos/local-cluster.sh destroy --name=dev --dry-run
./scripts/talos/local-cluster.sh destroy --name=dev --confirm-destroy
```

- `create` refuses to run again once its marker file exists for that name;
  run `destroy` first (or pick a different `--name`).
- `status` is diagnostic-only: it never creates state and never starts
  Colima/Docker, whether or not the cluster exists yet.
- `destroy` requires `--confirm-destroy` to actually execute (`--dry-run`
  previews the planned `talosctl cluster destroy` command without it) and
  refuses to touch any directory that lacks this wrapper's own marker file,
  so it can never sweep unrelated Docker/Talos state.
- `--dry-run` never mutates the host on any action: no directory is created,
  no marker is written or read for a destructive decision, and no external
  command runs.

## Known limitations

- Milestone A only: `--workers` is configurable, but the Talos Docker backend
  (`talosctl cluster create docker`) exposes no control-plane-count flag and
  always creates exactly one control plane. `--controlplanes` is still
  accepted for symmetry with `cluster.sh` but the wrapper rejects any value
  other than `1` before invoking talosctl, instead of silently ignoring it.
  There is no upgrade, scaling, or multi-cluster orchestration beyond
  independent `--name`s.
- This wrapper does not manage Cilium, Argo CD, or any GitOps bootstrap;
  that remains `talos-vsphere-gitops` / `talos-gitops.sh` territory for
  non-local clusters, and is out of scope for the Docker backend here.
- If Colima is the intended Docker backend and is not running, `create`'s
  `docker info` preflight will fail with an actionable message; start Colima
  yourself and re-run.

## Recovering a partially created cluster

If `create` fails partway (for example, `talosctl` succeeds but the
kubeconfig fetch fails, or the process is interrupted), the wrapper leaves
whatever state it managed to write in place and does **not** attempt any
automatic cleanup or retry. Recovery is manual:

1. Run `status --name=<name>` to see what state exists (wrapper marker,
   Talos state directory, `talosctl cluster show` output).
2. If the wrapper marker at
   `.../local-clusters/<name>/.talos-toolchain-local-cluster` is present,
   `destroy --name=<name> --confirm-destroy` will tear it down and remove the
   isolated state directory.
3. If the marker is absent (for example, `talosctl cluster create docker`
   itself failed before the wrapper could write it), `destroy` refuses to
   touch the directory by design. Inspect
   `.../local-clusters/<name>/talos-state` yourself and, if you are sure it
   is safe, remove it manually before retrying `create` with the same
   `--name`.

The wrapper never deletes or inspects this state automatically outside of an
explicit, confirmed `destroy` run.
