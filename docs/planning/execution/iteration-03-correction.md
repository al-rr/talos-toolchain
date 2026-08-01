# Iteration 03 corrective run — CLI version compatibility contract

- Roadmap iteration: 3
- Operational run: 013
- Repository: `talos-toolchain`
- Status: `IMPLEMENTED`
- Base branch: `lab`
- Baseline commit: `723b3845ba826f0c78ae8eecc47e75c91af3c03f`
- Working branch: `fix/issue-007-macos-bash-preflight`
- Implementer: `Claude Code`
- Reviewer: `Codex`
- GitHub issue: [#7](https://github.com/al-rr/talos-toolchain/issues/7)
- Optional pull request: not authorized
- VMware validation: not required

## Scope

### Files

- `docs/en/shell-requirements.md`
- `docs/pt-br/shell-requirements.md`
- Documentation indexes only if required for discoverability.
- This execution record and the Iteration 03 record's correction evidence.

### Acceptance criteria

- [x] EN/PT-BR documentation states the compatibility/version-selection rule
  for `talosctl`, `kubectl`, `helm`, `govc`, and `curl`.
- [x] No unsupported repository-wide version pin is invented; rules use the
  selected Talos/Kubernetes/environment contract where applicable.
- [x] Runtime preflight remains diagnostic-only and no host, network, VMware,
  or cluster operation is performed.
- [x] No file outside `talos-toolchain` changes.

## Implementation handoff

- Implementation commits: pending; commits are not authorized.
- Uncommitted changes included: the accepted Iteration 03 implementation diff
  is the acknowledged baseline and must not be reverted or expanded, plus:
  - `docs/en/shell-requirements.md`: new "CLI version/compatibility contract"
    section stating, per CLI (`talosctl`, `kubectl`, `helm`, `govc`, `curl`),
    a compatibility rule grounded in the per-project `--talos-version`
    selection and each tool's own upstream skew/compatibility policy, instead
    of a repository-wide version pin.
  - `docs/pt-br/shell-requirements.md`: matching PT-BR section, same
    structure and content, no language mixing.
  - This execution record.
- Local validation performed: read `scripts/talos/cluster.sh` (action-to-CLI
  mapping at lines 172-176, `--talos-version`/`detect_talos_version_from_vars`
  handling, factory installer-image tagging) and
  `docs/en/day1-project-vars.md` to confirm the Talos/Kubernetes version is
  always selected per-project via `vars.sh`/`--talos-version`, never pinned
  in this repository; confirmed `talos-vsphere-gitops` owns Helm chart/addon
  versioning and `provision-talos-vsphere` owns the vSphere/vCenter/ESXi
  target, so `helm` and `govc` rules reference those repositories'
  responsibility rather than inventing a version here.
- Commands run:
  - `rtk git diff --check` (talos-toolchain) — no whitespace errors.
  - `rtk git status` (talos-toolchain, provision-talos-vsphere,
    talos-vsphere-gitops) — confirmed only `talos-toolchain` has changes and
    the other two repositories remain untouched.
- Not run: `test-bash-preflight.sh`/`test-syntax.sh` (unchanged by this
  correction; no script or test file was modified) and any
  Talos/Kubernetes/Helm/VMware/govc/network operation (excluded by scope).
- Known limitations: the corrective Claude session must execute outside the
  sandbox because its authenticated credential store is unavailable inside it.

## Independent review

- Reviewer: Codex
- Exact commit reviewed: baseline commit
  `723b3845ba826f0c78ae8eecc47e75c91af3c03f` plus the complete uncommitted
  Iteration 03 and corrective documentation diff.
- Diff range: accepted Iteration 03 uncommitted baseline plus this corrective
  documentation delta.
- Checks rerun: `rtk git diff --check`; both EN/PT-BR compatibility sections;
  `rtk bash scripts/talos/tests/test-bash-preflight.sh` (14 passed); and
  `rtk bash scripts/talos/tests/test-syntax.sh` (13 syntax checks and scoped
  ShellCheck passed). Confirmed the other two coordinated repositories clean.
- Verdict: `APPROVED`
- Corrections requested (cycle 1): the Helm rule stated an unsupported global
  major-version pin ("Helm 3.x"), conflicting with the no-invented-pin
  constraint and a local audit observation of Helm 4.2.3.
- Correction applied (cycle 1): replaced the Helm rule in both
  `docs/en/shell-requirements.md` and `docs/pt-br/shell-requirements.md`
  with a major-version-neutral statement — use a Helm release compatible
  with the target cluster's Kubernetes version per Helm's own support
  matrix. No other compatibility rule, script, test, runtime behavior,
  repository, or record was changed. `rtk git diff --check` re-run after the
  fix: clean, no whitespace errors.
- Codex verification: approved the major-version-neutral Helm rule in both
  languages; no runtime behavior or out-of-scope repository changed.
- Follow-up work: Iteration 4 environment configuration remains separate.

## Owner decision

- Accepted for local `lab`: implementation/review accepted; commit still
  requires explicit owner authorization.
- Remote publication authorized: no.
