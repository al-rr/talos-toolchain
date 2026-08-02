# Iteration execution record

- Iteration: 09 (roadmap: Iteration 7 — Cilium and Argo bootstrap handoff)
- Repository: `talos-toolchain`
- Status: `CLAUDE_COMPLETED — awaiting Codex review`
- Base branch: `lab`
- Baseline commit: `3aece693d73d38f9198e9e452403041159c41c2c`
- Working branch: `feat/issue-017-cilium-handoff`
- Implementer: Claude Code
- Reviewer: Codex (pending)
- Optional GitHub issue: [#17](https://github.com/al-rr/talos-toolchain/issues/17)
- Optional pull request: none (local-first; not opened)
- VMware validation: `not required`

## Scope

Define and offline-validate the Cilium day-1 (imperative)/day-2 (Argo CD)
handoff contract: GitOps revision agreement, rendered Cilium identity
(chart/version/values/release/namespace), adoption readiness, and continued
exclusion of imperative Cilium reinstall after Argo CD adoption. Paired with
a separate `talos-vsphere-gitops` PR (issue #7) that documents/tests the
declarative side of the same contract.

### Files

- `scripts/talos/validate-cilium-handoff.sh` (new)
- `scripts/talos/tests/test-cilium-handoff.sh` (new)
- `scripts/talos/tests/fixtures/cilium-handoff/**` (new fixtures)
- `scripts/talos/tests/test-syntax.sh` (register new script)
- `docs/en/cilium-gitops-handoff.md`, `docs/pt-br/cilium-gitops-handoff.md` (new)
- `docs/en/README.md`, `docs/pt-br/README.md` (link new doc)
- `docs/planning/execution/iteration-09.md` (this record)

### Acceptance criteria

- [x] Mixed GitOps environment revision (day-2 values-ref `targetRevision` !=
      environment) is detected offline.
- [x] Mixed rendered Cilium identity (chart, chart version, release name,
      namespace, or values content) between day-1 and day-2 is detected
      offline.
- [x] Non-automated adoption sync policy (`prune`/`selfHeal` not both `true`)
      is detected offline.
- [x] Post-adoption imperative reinstall is excluded and covered by an
      offline test (`talos-gitops.sh install-addon --addon=cilium` refuses,
      pre-existing `SYSTEM_EXCLUDE_ADDONS_RAW` behavior, now regression
      tested).
- [x] EN/PT-BR docs agree on the contract and rollback guidance.

## Implementation handoff

- Implementation commits: none (uncommitted; commit requires explicit owner
  authorization per workspace policy).
- Uncommitted changes included: all files listed above.
- Local validation performed:
  - `bash scripts/talos/tests/test-syntax.sh` — all `bash -n` + ShellCheck
    targets pass, including the two new scripts.
  - `bash scripts/talos/tests/test-cilium-handoff.sh` — 6/6 assertions pass.
  - `bash scripts/talos/tests/test-local-cluster.sh`,
    `test-bash-preflight.sh`, `test-yaml-config.sh` — pre-existing suites,
    unaffected, rerun for regression safety.
- Known limitations:
  - `validate-cilium-handoff.sh` parses the known two-source Cilium
    `Application` shape with a line-oriented `awk` scanner (same pragmatic
    approach as `talos-vsphere-gitops/scripts/validate-argocd-revisions.sh`),
    not a general YAML parser; a structurally different `cilium.yaml` layout
    would need the parser extended.
  - No live Talos/Kubernetes/Helm/Argo CD/VMware validation was performed or
    authorized this iteration.

## Independent review

- Reviewer:
- Exact commit reviewed:
- Diff range:
- Checks rerun:
- Verdict: `PENDING`
- Corrections requested:
- Follow-up work:

## Owner decision

- Accepted for local `lab`:
- Remote publication authorized:
- Notes:
