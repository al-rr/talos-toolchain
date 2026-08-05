# cluster-patches

The Talos machine-config patch model. These files are the **source**, not the
applied configuration.

`cluster.sh create-project --project-dir=<path>` copies each one into
`<project-dir>/patches/`. From then on the project's own copy is authoritative:
re-running the command **never overwrites** a file that already exists, so
operator edits survive. Edit `<project-dir>/patches/*.patch.yaml` to change one
cluster; edit this directory to change what every new cluster starts from.

| File | Scope | Purpose |
| --- | --- | --- |
| `cni.patch.yaml` | all nodes | `cni: none` + kube-proxy off, so Cilium owns networking |
| `cp.patch.yaml` | control plane | steady-state host DNS and time |
| `worker.patch.yaml` | workers | same, kept separate so roles can diverge |
| `cp-bootstrap.patch.yaml` | control plane, bootstrap phase | empty placeholder |
| `worker-bootstrap.patch.yaml` | workers, bootstrap phase | empty placeholder |
| `longhorn.patch.yaml` | workers | disk, kernel modules, kubelet mounts |

## The two bootstrap placeholders must stay empty

`cluster-bootstrap.sh` guards them with `[[ -s ... ]]` — non-empty — and only
passes them to `talosctl` if they have content. Adding so much as a comment
header makes them non-empty, at which point an effectively empty patch is
handed to `talosctl`. Leave them at zero bytes until there is real content to
put in them.

## What does not live here

- **`bootstrap.patch.yaml` and per-node network patches** are rendered at
  runtime by `cluster-bootstrap.sh` from the project's variables, because their
  content depends on per-node addressing. They are not templated here.
- **Environment-specific values** — static IPs, gateways, nameservers, disk
  layouts — belong in the project, not in the model.

## Longhorn spans both days

`longhorn.patch.yaml` is only the day-1 half: partitioning a disk and loading
kernel modules cannot be done by a chart after the fact. The Longhorn chart
itself is day-2, reconciled by Argo CD from `talos-vsphere-gitops`. It also
assumes `/dev/sdb`, which is wrong for any node with a different disk layout
and meaningless on container-based backends.
