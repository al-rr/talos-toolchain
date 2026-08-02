# Cilium Day-1/Day-2 (Argo CD) Handoff Contract (EN)

## Contract

Cilium is installed twice, by design, in two different modes:

1. **Day-1 (imperative)**: `apply-post-bootstrap.sh` syncs the addon's Helm
   manifests from the GitOps repository (`environments/<env>/helm/`) into the
   cluster project, and `phase-network-bringup.sh` renders and installs
   Cilium via `helm upgrade --install` before Argo CD exists, because Cilium
   provides the CNI that Kubernetes networking (and later Argo CD itself)
   needs to run at all.
2. **Day-2 (declarative)**: once Argo CD is bootstrapped
   (`talos-gitops.sh deploy-argocd-root-app`), the GitOps repository's
   `addon-cilium` Application adopts and exclusively reconciles the same
   Helm release going forward.

Adoption is only safe if day-2 reconciles the **same** chart, chart version,
rendered values, Helm release identity, and Git revision that day-1
bootstrapped. A mismatch here (a stale sync, a values edit landed only on one
side, or a `lab`/`main` revision mix-up) can make Argo immediately try to
change or replace a running CNI right after bootstrap.

## Validating the handoff offline

`scripts/talos/validate-cilium-handoff.sh` checks this agreement without
contacting Talos, Kubernetes, Helm, Argo CD, or any live/VMware endpoint. It
compares:

- a synced day-1 `helm/cilium/release.yaml` (chart, version, release name,
  namespace, resolved values file), against
- the GitOps repository's `environments/<env>/argocd/apps/cilium.yaml` Argo CD
  `Application` (Helm OCI chart source, values-ref source, destination
  namespace, sync policy).

It fails on:

- **Environment revision mismatch**: the values-ref source's `targetRevision`
  does not equal `--environment` (the same `lab`/`main` contract documented in
  `talos-vsphere-gitops`'s `docs/en/branch-revision-promotion.md`).
- **Rendered identity mismatch**: chart, chart version, release name, or
  namespace differ between day-1 and the GitOps `Application`.
- **Values content mismatch**: the day-1 resolved values file and the
  GitOps-referenced values file do not hash identically.
- **Non-automated adoption**: `syncPolicy.automated.prune`/`selfHeal` are not
  both `true`, so Argo would not actually take over reconciliation on its
  own.

```bash
./scripts/talos/validate-cilium-handoff.sh \
  --day1-release=<project-dir>/helm/cilium/release.yaml \
  --gitops-repo-root=<path-to-talos-vsphere-gitops-checkout> \
  --environment=lab
```

Run before `talos-gitops.sh deploy-argocd-root-app` (or any Argo bootstrap
step) as a pre-adoption gate. A non-zero exit means fix the drift in one of
the two repositories before letting Argo adopt Cilium, not delete/pause the
generated resources.

## Readiness prerequisite before adoption

Argo CD adopts an existing Helm release in place (rather than installing a
second, conflicting one) only when the release name and namespace it will
manage already match what day-1 created. The identity checks above are
exactly that readiness prerequisite, checked offline before the operator ever
runs the Argo bootstrap step.

## Rollback / recovery if CNI reconciliation fails

If Argo CD's `addon-cilium` sync fails or degrades cluster networking after
adoption:

1. Do **not** re-run `apply-post-bootstrap.sh` / `phase-network-bringup.sh`
   for `cilium`, and do not call
   `talos-gitops.sh install-addon --addon=cilium` or
   `install-platform-helm` without an exclusion. `cilium` is a hard-coded
   `SYSTEM_EXCLUDE_ADDONS_RAW` entry in `talos-gitops.sh`, and
   `install-addon --addon=cilium` refuses to run
   (`Addon 'cilium' is system-excluded in day-2 flow.`) once Argo owns the
   release, precisely to prevent a second, conflicting imperative Helm write
   racing Argo CD's reconciliation.
2. Fix the drift declaratively instead: correct the values/chart-version in
   `talos-vsphere-gitops` and let Argo CD's `selfHeal` reconcile, or revert
   the offending commit/`targetRevision` on that repository and let Argo
   converge back to the last-known-good state.
3. Re-run `validate-cilium-handoff.sh` after the fix to confirm day-1/day-2
   agreement before considering the cluster healthy again.

## Testing

`scripts/talos/tests/test-cilium-handoff.sh` exercises the validator against
consistent and mismatched fixtures under
`scripts/talos/tests/fixtures/cilium-handoff/`, and confirms
`talos-gitops.sh install-addon --addon=cilium` is refused. No live
Kubernetes/Helm/VMware call is made; a stub `kubectl` fixture only answers
the preflight context check.

```bash
bash scripts/talos/tests/test-cilium-handoff.sh
```
