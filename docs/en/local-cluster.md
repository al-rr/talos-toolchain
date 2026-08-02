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
- `--cni=cilium` additionally requires `helm`, `kubectl`, and `git` on `PATH`
  (see [Cilium local mode](#cilium-local-mode) below).

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

## Cilium local mode

`create --cni=cilium --gitops-repo-root=<path>` replaces the default
Talos-managed Flannel with a deliberate local Cilium day-1 bootstrap, using
the exact `talos-vsphere-gitops` `lab` release identity and values already
covered by `validate-cilium-handoff.sh`. This addresses a real failure on
Colima's Linux runtime: managed Flannel pods crash there because
`/proc/sys/net/bridge/bridge-nf-call-iptables` is absent, which leaves
CoreDNS unable to create its sandbox.

```bash
./scripts/talos/local-cluster.sh create --name=dev --cni=cilium \
  --gitops-repo-root=../talos-vsphere-gitops --dry-run
./scripts/talos/local-cluster.sh create --name=dev --cni=cilium \
  --gitops-repo-root=../talos-vsphere-gitops
```

What this mode does, in order:

1. **GitOps preflight** (read-only, no Colima/Docker interaction): verifies
   `--gitops-repo-root` is a Git checkout on branch `lab` with a clean
   working tree, and that its `environments/lab/helm/cilium/release.yaml`
   and `environments/lab/argocd/apps/cilium.yaml` exist. It never modifies
   this checkout.
2. **Talos CNI disabled, create runs in the background**: `talosctl cluster
   create docker` is invoked with a `--config-patch` that sets
   `cluster.network.cni.name` to `none`. The Docker backend exposes no
   `--wait=false` equivalent, and its internal readiness wait blocks until
   Kubernetes/CoreDNS is healthy — which can never happen on its own while
   CNI is `none`. So in `--cni=cilium` mode only, this command is started in
   the background (its output captured to `<cluster-dir>/create.log`) while
   the wrapper performs steps 3–6 below concurrently, ending with a `wait`
   on it in step 7. Default (`--cni=flannel`, or no `--cni` at all) still
   runs `talosctl cluster create docker` synchronously, completely
   unchanged.
3. **Kubeconfig fetch, retried**: `talosctl kubeconfig` is retried (every 3s,
   up to 120s) against the still-booting cluster until the Talos API
   answers, since it may not be reachable in the instant after the
   backgrounded create command starts.
4. **Loopback API publish**: the control-plane container's Kubernetes API
   port is published to a dynamically assigned `127.0.0.1` host port
   (`--host-ip 127.0.0.1 --exposed-ports 0:6443/tcp`), then discovered via
   `docker port` (polled for up to 60s) once the container is running.
5. **Isolated kubeconfig rewrite**: the wrapper's own isolated `kubeconfig`
   (never the operator's default `~/.kube/config`) has its `server:` field
   rewritten from the internal Docker network address `talosctl kubeconfig`
   would otherwise embed (for example `10.5.0.2:6443`) to the discovered
   `127.0.0.1:<published-port>` endpoint.
6. **Cilium day-1 bootstrap**: `validate-cilium-handoff.sh` runs against the
   same GitOps checkout before anything is installed (because Cilium day-1
   here reads `environments/lab/helm/cilium/{release,values}.yaml` directly
   from that checkout, not a synced copy, this identity match is
   structural, not just probable); then `phase-network-bringup.sh
   --helm-root=<gitops checkout>/environments/lab/helm --addon=cilium` (the
   same Helm phase used for vSphere clusters, in its new project-vars-free
   mode) renders, server-side dry-run validates, and `helm upgrade
   --install`s Cilium; then the wrapper waits for `deployment/coredns` in
   `kube-system` to finish rolling out. This is what makes the backgrounded
   create command's own health wait (step 2) able to succeed at all.
7. **Wait for and propagate the backgrounded create's result**: only after
   Cilium/CoreDNS are confirmed healthy does the wrapper `wait` on the
   backgrounded `talosctl cluster create docker` process and propagate its
   real exit status — success only if that process also exits `0`. On
   `SIGINT`/`SIGTERM` at any point during steps 3–7, the wrapper terminates
   and reaps that backgrounded process before exiting non-zero, instead of
   leaving it orphaned.

Day-2 GitOps adoption (Argo CD taking over Cilium reconciliation via
`talos-gitops.sh`) is unchanged and out of scope for this wrapper; this mode
only ever performs the day-1 imperative bootstrap.

On failure at any step (including an interrupt), nothing is auto-destroyed:
whatever Talos/Cilium state exists is left in place, together with
`<cluster-dir>/create.log` capturing the backgrounded create's own output
(see "Recovering a partially created cluster" below), and the wrapper
marker is only written after every step above succeeds and the backgrounded
create process has been reaped — so a partially failed `--cni=cilium`
create is never mistaken for a completed one, and no `talosctl` process is
ever left running unsupervised.

## Known limitations

- Milestone A only: `--workers` is configurable, but the Talos Docker backend
  (`talosctl cluster create docker`) exposes no control-plane-count flag and
  always creates exactly one control plane. `--controlplanes` is still
  accepted for symmetry with `cluster.sh` but the wrapper rejects any value
  other than `1` before invoking talosctl, instead of silently ignoring it.
  There is no upgrade, scaling, or multi-cluster orchestration beyond
  independent `--name`s.
- Outside `--cni=cilium` mode, this wrapper does not manage Cilium, Argo CD,
  or any GitOps bootstrap; that remains `talos-vsphere-gitops` /
  `talos-gitops.sh` territory for non-local clusters. `--cni=cilium` only
  performs the local day-1 bootstrap described above — it never touches
  Argo CD or the GitOps checkout's desired state.
- If Colima is the intended Docker backend and is not running, `create`'s
  `docker info` preflight will fail with an actionable message; start Colima
  yourself and re-run.

## Recovering a partially created cluster

If `create` fails partway (for example, `talosctl` succeeds but the
kubeconfig fetch fails, or the process is interrupted), the wrapper leaves
whatever state it managed to write in place and does **not** attempt any
automatic cleanup or retry. Recovery is manual:

1. Run `status --name=<name>` to see what state exists (wrapper marker,
   Talos state directory, `talosctl cluster show` output). For `--cni=cilium`,
   also check `.../local-clusters/<name>/create.log`, the captured output of
   the backgrounded `talosctl cluster create docker` process.
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
