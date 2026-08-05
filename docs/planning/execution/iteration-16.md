# Iteration execution record

- Iteration: 16 — local cluster lifecycle contract (`talos-lab` as first consumer)
- Repository: `talos-toolchain`
- Status: `IMPLEMENTED` (pending independent review)
- Base branch: `lab`
- Baseline commit: `e66b26f1fd34b1db0b8aad2fa3a8905464838195`
- Working branch: `fix/iteration-015-local-cilium-lifecycle`
- Implementer: `Claude Code`
- Reviewer: `Codex`
- Optional GitHub issue: none
- Optional pull request: none
- VMware validation: `not required`

## Scope

Adapt the Docker/Colima local backend so a local cluster has an explicit,
maintained file-based patch contract and preserves the Talos lifecycle:
role-specific machine configuration, bootstrap, Kubernetes API readiness,
post-bootstrap Cilium, then Cilium/CoreDNS validation. `talos-dev` in the
provisioning repository is read-only historical/reference material.

The patch contract landed as a **cluster-name-agnostic default model that is
materialized per cluster**, not as a single hand-named `talos-lab/` project.
`--name=<anything>` therefore yields its own editable patch project; `talos-lab`
is simply the first consumer. See "Deviations from the original task" below.

### Files

- `scripts/talos/local-cluster.sh` — patch model wiring, `/readyz` gate,
  Colima logfmt socket parsing.
- `scripts/talos/local-cluster-patches/defaults/{cni,cp,worker}.patch.yaml`
  (new; untracked) — the maintained default patch model.
- `scripts/talos/phase-network-bringup.sh` — **modified** (OCI Helm chatter
  filter; see below). The original task assumed no change was needed here;
  that assumption was wrong.
- `scripts/talos/tests/test-local-cluster-cilium.sh`,
  `scripts/talos/tests/test-local-cluster.sh`
- `scripts/talos/tests/fixtures/local-cluster/{colima,helm,kubectl}` — stub
  fidelity corrections; **no `curl` stub was added** (see below).
- `docs/en/local-cluster.md`, `docs/pt-br/local-cluster.md`
- this execution record

### Acceptance criteria

- [x] Local cluster configuration is selected/generated from maintained patch
      files; no inline hand-authored patch remains its source of truth. The
      previous inline `cilium_cni_none_config_patch()` printf helper was
      removed.
- [x] CNI, control-plane, and worker patches are passed with their correct
      Talos scope — `--config-patch`, `--config-patch-controlplanes`,
      `--config-patch-workers`, the plural forms `talosctl cluster create
      docker` requires (the singular `gen config` forms fail in a way that
      looks silent, before any container exists); `talos-dev` is neither read
      nor modified at runtime.
- [x] Cilium begins only after a bounded, **authenticated** Kubernetes
      `/readyz` gate, not merely after a Docker port mapping or Talos gRPC
      response.
- [x] `cni: none` remains intentional; Cilium stays post-bootstrap and before
      final Cilium/CoreDNS/node readiness validation.
- [x] Failure logs are durable and redacted; failed creation preserves state.
- [x] Offline regression tests cover patch materialization/scoping, readiness
      ordering, Colima socket parsing, and OCI render filtering; no live
      Docker/Talos/Helm/Kubernetes action runs without a new owner
      authorization.

## Implementation handoff

- Implementation commits: none; commits require separate owner authorization.
  The entire iteration is an uncommitted working tree on
  `fix/iteration-015-local-cilium-lifecycle`.

### Uncommitted changes included

1. **File-based patch model** (`local-cluster.sh`). `PATCH_TEMPLATE_DIR`
   (`local-cluster-patches/defaults`) holds the maintained model;
   `require_patch_template_project` validates it during cilium-mode preflight;
   `materialize_cluster_patch_project` copies it into
   `<cluster-dir>/patches/{cni,cp,worker}.patch.yaml` on first create and
   **never overwrites** an existing per-cluster patch. The patches are then
   passed with role-correct Talos scopes. The inline
   `cilium_cni_none_config_patch()` printf helper was deleted.

2. **Authenticated `/readyz` gate** (`wait_for_kubernetes_api_readyz`,
   `local-cluster.sh`). Cilium day-1 is blocked until the Kubernetes API
   reports ready, with a budget configurable through
   `TALOS_LOCAL_CLUSTER_API_READYZ_WAIT_SECONDS` and progress logged along the
   way. Timeout leaves state in place for diagnostics.

   The probe uses `kubectl get --raw=/readyz` with the cluster's own
   kubeconfig, **not** `curl -k`. Talos disables anonymous authentication on
   kube-apiserver, so an unauthenticated probe receives HTTP 401 for the full
   budget against a control plane that is entirely healthy. An earlier
   `curl`-based version of this gate did exactly that and reported a false
   timeout. Consequently there is no `curl` preflight requirement and no
   `curl` fixture; the original task description's mention of both is
   obsolete.

3. **OCI Helm render filter** (`phase-network-bringup.sh`). The canonical
   Cilium release is an OCI chart (`oci://quay.io/cilium/charts/cilium`).
   Helm prints `Pulled:` / `Digest:` progress on **stdout**, ahead of the
   manifest. Unfiltered, those lines parse as a leading YAML document with no
   `apiVersion`/`kind`, and the mandatory server-side dry-run rejects the
   whole render with "apiVersion not set, kind not set". The filter strips
   that chatter only where it occurs (leading lines), so no real manifest
   content can be dropped. **This is a second, independent defect** from the
   iteration-15 diagnostic, distinct from the ordering bug the `/readyz` gate
   fixes; both had to be corrected for the flow to proceed.

4. **Colima logfmt socket parsing** (`local-cluster.sh`). Real Colima reports
   the Docker socket inside a logfmt line
   (`time="..." level=info msg="docker socket: unix://..."`), not as a bare
   `docker: <uri>` field. The parser now accepts both forms and no longer
   captures trailing quote characters into the socket path.

5. **Stub fidelity corrections** (fixtures). Each stub was corrected to mirror
   real tool output rather than an invented convenience form, because the
   previous fixtures let broken parsers pass a fully green suite:
   - `colima`: emits real logfmt status by default;
     `STUB_COLIMA_STATUS_FORMAT=plain` still covers the plainer form.
   - `helm`: emits OCI `Pulled:`/`Digest:` chatter plus a manifest carrying a
     real `apiVersion`/`kind`; `STUB_HELM_OCI_CHATTER=false` covers the
     non-OCI path.
   - `kubectl`: answers `get --raw=/readyz`; `STUB_KUBECTL_READYZ_FAIL=true`
     covers the gate's timeout path.

6. **Documentation**: EN/PT-BR `local-cluster.md` updated for the materialized
   patch project, the two-stage timing, and the deliberate `cni: none`
   interval. Neither file describes the local backend as VMware/VIP/hardware
   validation.

### What is already proven to work (2026-08-04 run, pre-fix)

Recorded from
`~/.local/state/talos-toolchain/local-clusters/talos-lab/create.log`. The
previous run reached far further than the iteration-15 diagnostic implied, and
this must not be re-derived again:

```
etcd healthy: OK               etcd members consistent: OK
etcd members are cp nodes: OK  apid ready: OK
node memory + disk sizes: OK   no diagnostics: OK
kubelet healthy: OK            all nodes finish boot sequence: OK
all k8s nodes to report: can't find expected node with IPs ["10.5.0.2"]
context canceled
```

`talosctl cluster create docker` therefore succeeds through the **entire Talos
layer**: it created both containers, applied the machine config, bootstrapped
the cluster, converged etcd from `Preparing` to healthy, and completed the node
boot sequence. It produced `talosconfig`, `kubeconfig`, the materialized
patches, and Talos state.

The single failing step is `waiting for all k8s nodes to report`, which
**cannot** pass under `cni: none`: with no CNI the node never becomes Ready, so
the create waits on a health state only the post-bootstrap Cilium install can
produce. The containers then exited 137/130 — SIGKILL/SIGINT from this
wrapper's own EXIT trap reaping the backgrounded create, not a Talos fault.

Consequences for review: the containers, the Docker backend, and the Talos
bootstrap are **not** suspect. Only the ordering is, which is exactly what this
iteration's `/readyz` gate targets. Do not treat the local backend as unproven,
and do not propose reimplementing container creation by hand.

### Local validation performed

Re-run on 2026-08-05 against the current working tree; the counts below are
the ones this tree actually produces.

- `bash scripts/talos/tests/test-syntax.sh` — pass, 0 failing checks
  (`bash -n` over maintained entrypoints + shellcheck over the scoped list).
- `bash scripts/talos/tests/test-local-cluster.sh` — pass, 64/64.
- `bash scripts/talos/tests/test-local-cluster-cilium.sh` — pass, 66/66
  (includes patch-materialization, `/readyz`-gate, Colima-logfmt and
  OCI-chatter coverage).
- `bash scripts/talos/tests/test-bash-preflight.sh` — pass, 16/16
  (unaffected regression check).
- `bash scripts/talos/tests/test-cilium-handoff.sh` — pass, 6/6
  (unaffected regression check).
- `bash scripts/talos/tests/test-yaml-config.sh` — pass, 68/68 (unaffected
  regression check).
- `bash scripts/talos/tests/test-yaml-style.sh` — **not run**: `yamllint` is
  not installed on this host (pre-existing environment gap, unrelated to this
  iteration; the tool does not reference `local-cluster-patches/`).
- No Docker, Colima, Talos, Helm, Kubernetes, registry, GitHub, VMware, or
  credential command was run, per scope.

**No live `local-cluster.sh create` has been executed.** The `/readyz` gate,
the OCI filter, and the Colima parser are covered only by offline stubs. A
live run requires separate owner authorization and is the only thing that
proves the end-to-end fix.

### Deviations from the original task

The task in `.agent-runs/iteration-016-local-cilium-lifecycle-task.md`
specified name-scoped `talos-lab` patch files. Implementation diverged in
three places, all of which the reviewer should judge explicitly:

1. **Patch layout**: a cluster-name-agnostic `defaults/` model materialized
   per cluster, instead of a hand-named `talos-lab/` project. Rationale: a
   name-scoped directory makes every new cluster name a repository edit, and
   the toolchain must stay environment-agnostic.
2. **File naming**: `{cni,cp,worker}.patch.yaml` rather than
   `{common,controlplane,worker}.patch.yaml`, because the cluster-wide patch's
   sole current content is the `cni: none` override.
3. **`phase-network-bringup.sh` was modified**, contrary to the task's
   assumption that the existing `--helm-root` phase already sufficed.

### Known limitations

- **The patch directory location is provisional and pending an owner
  decision.** `scripts/talos/local-cluster-patches/defaults/` is not a
  committed-to home; the owner has flagged intent to propose a better one, and
  to give Helm values the same model→materialize treatment. Review of the
  mechanism should not be read as acceptance of the path.
- The `cp.patch.yaml` / `worker.patch.yaml` patches are currently identical
  (host-DNS overrides only). They exist as separately maintained,
  correctly-scoped files even though their content does not yet diverge by
  role.
- The Docker backend adaptation must remain environment-agnostic and must not
  claim VMware/VIP/hardware equivalence.
- `local-cluster-patches/` and this record are untracked; a `git add` is
  required before any commit so they are not silently lost.

## Independent review

- Reviewer: Codex
- Exact commit reviewed: pending
- Diff range: pending
- Checks rerun: pending
- Verdict: `PENDING`
- Corrections requested: pending
- Follow-up work: pending

## Owner decision

- Accepted for local `lab`: pending
- Patch directory location: pending (see Known limitations)
- Live `create` authorization: pending
- Remote publication authorized: no
- Notes: no alteration of `provision-talos-vsphere`,
  `talos-vsphere-gitops`, `talos-dev`, or the partial live `talos-lab` state.
