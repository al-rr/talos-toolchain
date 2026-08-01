# Talos Projects — Consolidated Architecture and Execution Plan

## Document status

This is the consolidated working plan for the Talos repositories. It reconciles:

- `TALOS_REPOSITORIES_AUDIT_PLAN.md`, produced by Codex;
- `TALOS_REPOSITORIES_CLAUDE_REVIEW.md`, produced independently by Claude Code;
- decisions subsequently made by the repository owner.

The two source documents remain historical evidence. Where they disagree with
this document, this document records the current decision. This is still a
planning artifact: no repository implementation file was modified, no secret
was read or printed, and no commit, push, branch, issue, or pull request was
created while consolidating it.

Finding labels used below:

- **FACT**: observed in the current repositories or directly validated.
- **DECISION**: direction explicitly accepted by the repository owner.
- **RECOMMENDATION**: proposed implementation detail, still subject to review
  in the corresponding issue.
- **DEFERRED_VMWARE**: cannot be meaningfully validated during the current
  macOS milestone.

## 1. Executive summary

The three Talos repositories have a viable intended separation, but their
current implementation crosses boundaries:

- `talos-toolchain` is intended to be the reusable CTL for Talos cluster
  lifecycle and must become the only entrypoint for the current macOS work.
- `provision-talos-vsphere` contains VMware/vSphere implementation and lab
  topology, but also carries duplicated Talos lifecycle scripts, tracked
  credential-bearing generated files, and documentation that does not always
  match the live provisioner.
- `talos-vsphere-gitops` owns desired Kubernetes state after bootstrap, but its
  current `lab` manifests point Argo CD at `main`, and it vendors very large
  upstream values files with minimal customization.

**DECISION:** Milestone A focuses on the cluster itself on macOS. It must not
require VMware, vSphere, `govc`, Terraform vSphere, HAProxy VMs, Keepalived, or
the Windows host. Milestone B will validate provisioning and real VIP behavior
on the Windows/VMware environment.

**DECISION:** `talos-toolchain` is the CTL for all Talos projects. It will own
Talos-specific environment configuration under the user's config directory.
`gitopsctl` and `platformctl` are design references only, not runtime
dependencies and not owners of Talos configuration.

**DECISION:** GitOps revision follows the selected environment: `lab` uses
`lab`; `main` uses `main`. Root and child Argo CD Applications must agree.

The immediate safety priority is containing and rotating credentials represented
by generated Talos/Kubernetes files already tracked in
`provision-talos-vsphere`. Rotation is an owner-authorized external action and
must not be performed automatically by an agent.

## 2. Current repository map

### `talos-toolchain`

**Current responsibility — FACT**

- Reusable Talos cluster lifecycle scripts.
- Project scaffold and project-variable loading.
- Talos machine configuration generation and validation.
- Machine configuration application, cluster bootstrap, kubeconfig retrieval,
  CNI/day-1 bootstrap, and GitOps bootstrap helpers.
- Add-on scripts and day-2 GitOps support.

**Current boundary problems — FACT**

- Some lifecycle scripts are duplicated and have drifted in
  `provision-talos-vsphere`.
- The scaffold currently contains concrete lab-oriented defaults that should
  not be stamped into tracked project configuration.
- Active code uses Bash features unavailable in Apple's Bash 3.2, including
  `mapfile`, associative arrays, and lowercase parameter expansion.
- A first-class local Docker Talos cluster workflow is not yet present.
- Talos operator values are not yet consistently stored by environment under
  the user's home/config directory.

### `provision-talos-vsphere`

The original request referred to `talos-vsphere-lab`; the directory currently
present is `provision-talos-vsphere`. Repository renaming is outside this plan.
Documentation should use the real repository name or explicitly document any
intentional alias.

**Current responsibility — FACT**

- VMware/vSphere and ESXi provisioning through `govc` and Terraform code.
- Lab topology, vSphere variables, VM lifecycle, HAProxy automation, DNS hooks,
  Ansible, Packer-related integration, and deferred infrastructure validation.
- A transitional duplicate of much of the Talos cluster lifecycle.

**Current boundary problems — FACT**

- Talos generation, application, bootstrap, CNI, and GitOps logic overlap with
  `talos-toolchain`.
- Generated Talos machine configurations, talosconfig, and kubeconfig-shaped
  files are tracked in Git. Their contents were intentionally not inspected.
- Terraform places full Talos machine configuration in VM `guestinfo`, making
  it part of plan output and local state; relevant derived values are not
  marked sensitive and no remote/encrypted backend is configured.
- Live project defaults currently select `govc`, while policy documentation
  describes Terraform as the lifecycle owner.
- VM destruction/overwrite paths rely on flags but lack strong confirmation
  guards.
- A `.gitignore` rule for `vars.local.sh` does not match the actual nested
  project layout.
- The Keepalived role exists, but is not wired into the HAProxy playbook.
- The nominal `generate` action remains coupled to VMware installer-image
  validation and therefore is not the macOS-local generation path.

### `talos-vsphere-gitops`

**Current responsibility — FACT**

- Argo CD root app-of-apps and child Applications.
- Desired state for Cilium, cert-manager, Longhorn, and prometheus-stack.
- Helm release metadata, environment values, and GitOps reconciliation policy.

**Current boundary problems — FACT**

- The working environment is `lab`, while the current Applications reference
  `main`.
- Full upstream chart defaults are copied into large pairs of nearly identical
  values files, increasing review and upgrade cost.
- No repository `.gitignore` provides a backstop against accidentally adding a
  real Argo repository Secret.
- Documentation refers to stale repository/toolchain status.
- The repository lacks an `AGENTS.md`, unlike the other operational repos.

## 3. Current ownership matrix

| Capability | Current handler | Current assessment |
|---|---|---|
| Local tooling and CLI setup | Primarily `talos-toolchain`; host tools installed separately | Talos CTL behavior belongs here; host package management is not cluster lifecycle |
| VMware/vSphere provisioning | `provision-talos-vsphere` | Correct owner, but both `govc` and Terraform paths need policy clarification |
| Talos machine config generation | Both operational repositories | Duplicate; local path must move exclusively through `talos-toolchain` |
| Talos config validation | Both, inconsistently | Canonical validation belongs in `talos-toolchain` |
| Talos config application | Both | Canonical lifecycle belongs in `talos-toolchain`; provision repo delegates |
| Cluster bootstrap | Both | Canonical lifecycle belongs in `talos-toolchain` |
| Kubernetes bootstrap/kubeconfig | Both | Canonical lifecycle belongs in `talos-toolchain` |
| CNI installation | Day-1 scripts plus Argo desired state | Bootstrap/adoption contract must be explicit |
| GitOps bootstrap | Talos scripts consume `talos-vsphere-gitops` | Bootstrap command belongs in toolchain; desired state belongs in GitOps repo |
| Argo CD | `talos-vsphere-gitops`, invoked by Talos scripts | Desired state and revision policy belong in GitOps repo |
| Infrastructure applications | `talos-vsphere-gitops` | Correct owner after Kubernetes/API availability |
| Workloads | Intended for GitOps repo; little current workload content | Keep reconciled workloads out of toolchain and provision repo |

## 4. Current end-to-end workflow

The current combined workflow is approximately:

1. Select or create project variables.
2. Provision vSphere VMs using the active `govc` path or unfinished/alternative
   Terraform path.
3. Generate Talos machine configurations.
4. Apply machine configurations to control-plane and worker nodes.
5. Bootstrap etcd/Talos and obtain kubeconfig.
6. Install Cilium imperatively for initial Kubernetes networking.
7. Install/bootstrap Argo CD.
8. Point Argo CD at `talos-vsphere-gitops`.
9. Argo CD reconciles Cilium and the remaining platform applications.

This works as a conceptual sequence, but responsibility is duplicated in steps
3–8 and the branch mismatch can make the day-1 Cilium values differ from the
values Argo reconciles immediately afterward.

## 5. Target responsibility model

### `talos-toolchain`: portable Talos cluster CTL

Own:

- environment selection and Talos-specific local configuration;
- configuration bootstrap under the user's XDG config directory;
- project contract and non-vSphere cluster specification;
- Talos config generation, patching, validation, and rendering;
- local Docker/Colima cluster lifecycle;
- application of Talos config to already-addressable machines;
- Talos bootstrap, kubeconfig, health/wait operations;
- CNI bootstrap and explicit GitOps adoption checks;
- Argo CD bootstrap command and GitOps handoff orchestration;
- portable validation, dry-run, and redacted diagnostics.

Do not own:

- vSphere VM creation or deletion;
- vSphere credentials as code;
- canonical Kubernetes add-on desired state;
- application workloads.

### `provision-talos-vsphere`: infrastructure adapter and lab integration

Own:

- vSphere/ESXi endpoints and topology consumption;
- VM/template/datastore/network lifecycle;
- infrastructure preflight and destructive-operation guards;
- HAProxy VM and future Keepalived/VIP integration;
- infrastructure-specific DNS hooks;
- VMware integration tests and handoff of machine endpoints to
  `talos-toolchain`.

Do not own long-term copies of generic Talos lifecycle scripts. During
migration, compatibility wrappers may remain and delegate to a pinned,
documented `talos-toolchain` contract.

### `talos-vsphere-gitops`: canonical Kubernetes desired state

Own:

- Argo CD root and child Applications;
- environment-to-revision mapping;
- CNI desired state after bootstrap adoption;
- platform services and workloads;
- minimal maintained values overrides;
- reconciliation and promotion policy.

Do not provision VMs or generate/apply Talos machine configuration.

## 6. Talos environment configuration contract

**DECISION:** the implementation belongs entirely to `talos-toolchain`.

Recommended initial layout:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/talos-toolchain/
├── base/
│   ├── config.sh
│   └── credentials.sh
└── environments/
    ├── lab/
    │   ├── config.sh
    │   └── credentials.sh
    └── main/
        ├── config.sh
        └── credentials.sh
```

The exact filenames are an issue-level decision. Preserve these rules:

- Directories use mode `0700`; credential files use `0600`.
- Bootstrap is idempotent and never overwrites without an explicit force flag.
- Bootstrap refuses root/sudo to avoid writing into the wrong home directory.
- Before sourcing shell files, verify regular-file type, current-user ownership,
  and absence of group/world write permission.
- Diagnostic output redacts secret values.
- Generated talosconfig, kubeconfig, certificates, and machine configs are
  protected files, not multiline values embedded in `credentials.sh`.
- Existing environment-variable interfaces receive a documented compatibility
  window.

Recommended precedence, lowest to highest:

1. Toolchain safe defaults.
2. User base configuration.
3. Tracked project/environment intent containing no secrets.
4. User environment configuration and credentials.
5. Explicit one-run CLI flags.

The implementation issue must decide whether shell-sourced configuration is
retained or replaced with a data-only format. If shell sourcing remains, treat
every sourced file as executable code and apply the checks above.

## 7. Proposed end-to-end workflow

### Milestone A — macOS/local cluster

1. Run `talos-toolchain` with an explicit `lab` environment.
2. Bootstrap or validate the user's Talos environment configuration.
3. Create an isolated local Talos cluster through Docker/Colima with explicit
   state, talosconfig, and kubeconfig paths.
4. Generate and validate Talos configuration without VMware hooks.
5. Bootstrap Kubernetes and verify Talos/Kubernetes health.
6. Install Cilium as the day-1 networking dependency using the same release
   metadata and `lab` content later reconciled by Argo CD.
7. Bootstrap Argo CD.
8. Install the root Application with `targetRevision: lab`.
9. Validate that every child Application also resolves to `lab`.
10. Verify GitOps reconciliation and selected infrastructure applications that
    are meaningful in a local cluster.
11. Destroy only the explicitly named local cluster after a target/state check
    and confirmation appropriate to the command.

### Milestone B — Windows/VMware

1. Select the Talos environment and named vSphere connection data.
2. Provision VMs, network attachments, disks, and HAProxy infrastructure from
   `provision-talos-vsphere`.
3. Return explicit machine endpoints/inventory to `talos-toolchain`.
4. Generate, validate, apply, and bootstrap through `talos-toolchain`.
5. Validate the real API endpoint and HAProxy/Keepalived/VIP behavior.
6. Bootstrap GitOps with the selected environment revision.
7. Validate storage, failure behavior, reconciliation, and teardown guards.

## 8. Local macOS test strategy

### Host contract

**DECISION:** support the existing macOS workflow with Homebrew Bash 5 rather
than rewriting the maintained scripts for Apple Bash 3.2.

Entry points must:

- use a portable launcher or locate Bash 5 explicitly;
- fail early with a clear installation/version message under Bash 3.2;
- avoid assuming GNU userland commands where a portable form is practical;
- validate required CLIs without installing or changing the host automatically.

`readlink -f` is not a confirmed blocker on the audited modern macOS host. Real
confirmed portability hazards include `mapfile`, associative arrays,
`${value,,}`, GNU `find -printf`, `timeout`, and `base64 -w`.

### Offline and configuration-only checks

- `bash -n` and ShellCheck with the declared Bash version.
- CLI help and argument validation.
- Idempotent config bootstrap into a temporary `XDG_CONFIG_HOME`.
- Permission, ownership, overwrite, and redaction tests.
- Environment precedence tests for `base`, `lab`, and CLI overrides.
- Project scaffold tests proving no concrete credentials or site IPs are
  generated into tracked files.
- `talosctl gen config` into an ignored temporary output directory.
- `talosctl validate --mode metal` or the appropriate generated-config mode.
- Machine-config patch generation and deterministic diff checks.
- Argo/Application schema rendering and revision-consistency checks.
- Helm template/lint checks for owned overrides.
- Secret-pattern and ignored-path checks that report filenames only.

### Docker/Colima integration checks

- Start Colima manually as an operator prerequisite; scripts may detect it but
  should not silently change its configuration.
- Add a first-class `talosctl cluster create docker` flow with explicit cluster
  name and state/output locations.
- Exercise Kubernetes readiness, kubeconfig, Talos health, Cilium bootstrap,
  Argo CD bootstrap, and GitOps reconciliation.
- Test repeat runs for idempotency.
- Test deletion only against the exact locally created cluster and state path.

### Local HAProxy scope

A disposable HAProxy container can validate rendered configuration syntax,
backend formatting, health-check behavior, and a stable local API endpoint.
It cannot validate Keepalived/VRRP failover or a real vSphere network VIP.
Those claims remain deferred to Milestone B.

## 9. VMware-specific remaining work

The following require the Windows/VMware host:

- vCenter/ESXi authentication and permissions;
- datastore, resource pool, folder, network, and template discovery;
- ISO/OVA/guestinfo boot behavior;
- VM firmware, CPU, memory, disk, and NIC configuration;
- actual `govc` and Terraform vSphere plans/applies;
- HAProxy VM provisioning;
- Keepalived wiring and real VIP/VRRP failover;
- DNS integration hooks;
- control-plane and worker failure/replacement tests;
- realistic Longhorn disk behavior;
- protected teardown of real VMs and infrastructure.

VMware absence is not a failure of Milestone A. Any issue that otherwise
passes locally but needs infrastructure confirmation should create a linked
`DEFERRED_VMWARE` validation issue rather than importing provisioning into the
local workflow.

## 10. Problems and risks

### Critical

1. **Tracked credential-bearing generated files.** Treat represented Talos and
   Kubernetes credentials as exposed. Contain them, fix ignore coverage, and
   rotate them with explicit owner authorization before relying on the lab.
2. **Talos config in Terraform output/state.** Full machine configuration enters
   `guestinfo`, local state, and potentially console output.
3. **Unsafe infrastructure destruction.** Overwrite/destroy paths lack strong
   target display and confirmation controls.

### High

4. **Duplicated lifecycle ownership.** Two repositories implement divergent
   versions of generate/apply/bootstrap behavior.
5. **GitOps branch mismatch.** Current lab Applications point to `main`.
6. **macOS launcher incompatibility.** Stock Bash 3.2 cannot execute current hot
   paths, despite macOS being the active development environment.
7. **Policy drift.** Documentation says Terraform owns VM lifecycle while the
   live project path uses `govc`; Windows-first policy also needs to be scoped
   separately from macOS Milestone A.

### Medium

8. **CNI handoff risk.** Release identity is aligned, but branch/content drift
   can cause Argo to change Cilium immediately after bootstrap.
9. **Large vendored values.** Upstream defaults obscure the small set of owned
   changes and make upgrades difficult to review.
10. **Untrusted shell sourcing.** Local config files are executable when sourced;
    ownership and permission validation is required.
11. **Hard-coded scaffold defaults.** Concrete lab IP/user values can leak into
    newly tracked project configuration.
12. **Documentation/governance gaps.** Stale repository references, unwired
    Keepalived documentation, and missing GitOps `AGENTS.md` cause ambiguity.

## 11. Decisions closed by this plan

- Work normally starts from and targets the `lab` branch.
- Promotion from `lab` to `main` is a separate reviewed operation.
- Argo CD uses the revision selected by environment, never the incidental local
  checkout branch.
- Milestone A uses only `talos-toolchain` for cluster lifecycle.
- `talos-toolchain` owns Talos environment configuration in the user's home.
- `gitopsctl` and `platformctl` are examples, not dependencies.
- Provisioning stays separate and is deferred to the VMware milestone.
- Homebrew Bash 5 is the maintained macOS shell baseline; scripts must detect
  unsupported Bash clearly.
- A local HAProxy container is useful, but does not prove VIP failover.
- Repositories will not be merged, renamed, or automatically reorganized.

## 12. Remaining design decisions

Resolve these in their specific issues before implementation:

1. **Local cluster command shape:** a separate, thin local-cluster entrypoint is
   preferred initially to keep Docker behavior isolated from vSphere-coupled
   code. Confirm whether it later becomes a backend of the main cluster command.
2. **Day-1 command indirection:** decide whether to retain the simpler direct
   ownership deliberately implemented by `talos-toolchain` or retain a minimal
   backend hook contract for provisioning consumers. Do not automatically port
   the older `TALOS_DAY1_*` mapping layer back into the toolchain.
3. **Configuration format:** shell files preserve existing patterns but execute
   code; a data-only format is safer but adds parsing/dependency choices.
4. **Generated state location:** choose XDG state/cache paths versus an ignored
   project-local directory, while requiring explicit paths in every destructive
   local-cluster command.

These decisions do not block immediate credential containment and documentation
issues.

## 13. Incremental issue, branch, and commit plan

### Working rules

- Use this roadmap as the local program tracker. GitHub issues are optional and
  may be created later when remote coordination or publication is useful.
- Use one local execution record per independently reviewable behavior and
  repository under `docs/planning/execution/`.
- Create one short-lived branch per issue from that repository's `lab` branch.
- Review locally first. Pushes and PRs back to `lab` are optional publication
  steps requiring explicit authorization; promotion to `main` remains separate.
- Never let Codex and Claude Code edit the same branch or overlapping files at
  the same time. One implements; the other reviews the actual diff.
- Prefer multiple focused commits when tests, behavior, and documentation are
  independently reviewable.
- No commit, push, issue creation, PR, credential rotation, or destructive
  command occurs without explicit authorization.

Recommended branch form:

```text
fix/<issue>-<short-topic>
feat/<issue>-<short-topic>
docs/<issue>-<short-topic>
```

### Iteration 0 — establish local tracking without implementation

1. Version this roadmap and the two independent source reviews.
2. Add a local execution-record template.
3. Record dependencies and `DEFERRED_VMWARE` status.
4. Confirm implementation/reviewer assignment before each iteration.
5. Create GitHub issues only when the owner chooses to publish or coordinate
   that work remotely.

Suggested documentation commit, if desired:

```text
docs: record Talos repository correction plan
```

### Iteration 1 — immediate credential containment

Repository: `provision-talos-vsphere`.

- Inventory tracked generated credential-bearing paths without printing them.
- Add correct ignore coverage for nested project outputs and local vars.
- Replace tracked generated artifacts with safe documented generation paths;
  deletion from Git requires separate explicit approval despite being planned.
- Review the stray nested talosconfig-shaped artifact.
- Prepare a rotation checklist for the owner; never rotate automatically.
- Decide separately whether history cleanup is necessary and authorized.

Suggested commits:

```text
chore(security): ignore generated Talos credentials
docs(security): document credential containment and rotation
```

### Iteration 2 — align responsibilities and documentation

Repositories: all three, separate issues/branches.

- Declare Milestone A exclusively through `talos-toolchain`.
- Correct stale repository names and future-toolchain wording.
- Reconcile govc-versus-Terraform policy as current versus target state.
- Document that Keepalived exists but is not wired.
- Add `AGENTS.md` to GitOps only after agreeing its conventions.

Suggested commits:

```text
docs: define Talos repository responsibilities
docs: align vSphere lifecycle policy with implementation
docs: update GitOps repository relationships
```

### Iteration 3 — macOS/Bash contract

Repository: `talos-toolchain` first.

- Declare Bash 5 and required CLI versions.
- Add launcher/preflight behavior and portable command wrappers.
- Add offline tests for confirmed portability failures.
- Do not add the environment loader until this foundation passes on macOS.

Suggested commits:

```text
test(shell): cover macOS portability contract
fix(shell): require and locate Bash 5 on macOS
```

### Iteration 4 — Talos environment configuration

Repository: `talos-toolchain`.

- Document configuration schema, precedence, permissions, and state paths.
- Implement idempotent base/environment bootstrap.
- Add secure loading and redacted diagnostics.
- Fix project scaffolding so tracked files contain no real credentials or
  concrete site-specific defaults.
- Preserve existing environment variables through a documented migration
  window.

Suggested commits:

```text
docs(config): define Talos environment contract
test(config): cover environment precedence and permissions
feat(config): manage Talos environment settings
fix(scaffold): omit site-specific project defaults
```

### Iteration 5 — local Talos cluster backend

Repository: `talos-toolchain`.

- Add explicit Docker/Colima local-cluster create/status/destroy workflow.
- Isolate cluster name, state, talosconfig, and kubeconfig.
- Add generation/validation-only modes.
- Add target verification and safe teardown guards.

Suggested commits:

```text
feat(cluster): add local Docker Talos workflow
test(cluster): cover isolated local state and teardown guards
docs(cluster): document macOS local cluster lifecycle
```

### Iteration 6 — GitOps revision correction

Repository: `talos-vsphere-gitops`.

- Make `lab → lab` and `main → main` explicit.
- Ensure root and child Applications resolve the same revision.
- Add validation reproducing the current invalid case: lab manifests pointing
  at main.
- Do not infer desired revision silently from the checked-out branch.

Suggested commits:

```text
test(argocd): detect mixed environment revisions
fix(argocd): align target revision with environment
docs(argocd): document branch promotion model
```

### Iteration 7 — Cilium and Argo bootstrap handoff

Repositories: `talos-toolchain` and `talos-vsphere-gitops`, separate PRs.

- Verify identical environment revision and rendered Cilium content before
  bootstrap.
- Define readiness conditions before Argo adoption.
- Define rollback/recovery behavior if CNI reconciliation fails.
- Verify day-2 code continues to exclude imperative Cilium reinstallation.

Suggested commits:

```text
feat(bootstrap): validate Cilium GitOps handoff
docs(cilium): define bootstrap adoption contract
```

### Iteration 8 — local platform reconciliation

Repositories: toolchain and GitOps, separate PRs.

- Bootstrap Argo CD against `lab` in the local cluster.
- Validate cert-manager and monitoring where locally meaningful.
- Mark Longhorn or other topology-dependent validations as conditional rather
  than claiming VMware-equivalent coverage.
- Add an optional HAProxy config/container test without Keepalived claims.

Suggested commits:

```text
test(gitops): validate local Argo reconciliation
test(haproxy): validate rendered configuration locally
```

### Iteration 9 — reduce configuration duplication

Repository: `talos-vsphere-gitops`.

- Replace vendored upstream values with minimal owned overrides in small,
  separately reviewed chart-by-chart changes.
- Add schema/template validation and upgrade documentation.
- Add a safe `.gitignore` backstop for local secret manifests.

Suggested commits:

```text
refactor(cilium): keep only owned values overrides
refactor(cert-manager): keep only owned values overrides
refactor(monitoring): keep only owned values overrides
refactor(longhorn): keep only owned values overrides
chore(git): ignore local secret manifests
```

### Iteration 10 — delegate duplicated Talos lifecycle

Repositories: toolchain first, then provision repo.

- Resolve the day-1 command/backend-hook decision.
- Version and test the canonical toolchain contract.
- Convert provisioning copies into compatibility wrappers/delegation gradually.
- Keep rollback behavior until all project paths use the canonical toolchain.

Suggested commits:

```text
refactor(cluster): stabilize lifecycle command contract
refactor(talos): delegate lifecycle to talos-toolchain
docs(migration): document toolchain compatibility window
```

### Iteration 11 — VMware security and state design

Repository: `provision-talos-vsphere`; **DEFERRED_VMWARE** validation.

- Remove Talos machine configuration from Terraform state/guestinfo or document
  and implement an explicitly approved protected alternative.
- Align live provisioner and policy.
- Add plan/output redaction and state-backend requirements.
- Add destructive target summaries and confirmation/CI override rules.

Suggested commits:

```text
fix(terraform): keep Talos credentials out of state
feat(safety): guard destructive vSphere operations
docs(terraform): define protected state requirements
```

### Iteration 12 — real HA and VMware validation

Repository: `provision-talos-vsphere`; **DEFERRED_VMWARE**.

- Wire the existing Keepalived role only after reviewing its network contract.
- Validate HAProxy plus VIP failover on the real host/network.
- Validate provisioning, node replacement, DNS hooks, and protected teardown.

Suggested commits:

```text
feat(haproxy): integrate Keepalived role
test(vsphere): document HA and provisioning validation
```

## 14. Definition of done

An issue is done only when:

- acceptance criteria and proportionate tests pass;
- no secret value appears in diffs or logs;
- tracked/generated/operator configuration boundaries remain intact;
- relevant English and PT-BR operator documentation agree;
- macOS validation passes or the limitation is explicitly VMware-only;
- destructive behavior has target checks and documented recovery/rollback;
- a second agent reviews the actual diff;
- deferred work is represented by a linked issue rather than an implicit TODO.

Cross-repository work is complete only after consumers adopt the versioned
provider contract and compatibility code can be removed in a later,
separately-authorized issue.

## 15. Files to review first

Review in this order, without printing secret contents:

1. `provision-talos-vsphere/.gitignore`
2. Credential-bearing/generated paths under
   `provision-talos-vsphere/overlays/lab/talos/`
3. `provision-talos-vsphere/overlays/base/terraform/talos/main.tf`
4. `provision-talos-vsphere/overlays/base/terraform/talos/variables.tf`
5. `provision-talos-vsphere/docs/policies/infrastructure-tooling.md`
6. `provision-talos-vsphere/overlays/base/scripts/talos/cluster.sh`
7. `provision-talos-vsphere/overlays/base/scripts/talos/govc/provision-cluster.sh`
8. `provision-talos-vsphere/overlays/base/scripts/ha-proxy/govc/provision.sh`
9. `provision-talos-vsphere/overlays/base/ansible/roles/keepalived/`
10. `provision-talos-vsphere/overlays/base/ansible/haproxy/playbooks/provision_haproxy.yml`
11. `talos-toolchain/scripts/talos/cluster.sh`
12. `talos-toolchain/scripts/talos/lib/common.sh`
13. `talos-toolchain/scripts/talos/vars.sh`
14. `talos-toolchain/scripts/talos/cluster-bootstrap.sh`
15. `talos-toolchain/scripts/talos/apply-post-bootstrap.sh`
16. `talos-toolchain/scripts/talos/talos-gitops.sh`
17. `talos-toolchain/docs/en/day1-project-vars.md`
18. `talos-vsphere-gitops/environments/lab/argocd/root-app.yaml`
19. `talos-vsphere-gitops/environments/lab/argocd/apps/`
20. `talos-vsphere-gitops/environments/lab/helm/`
21. `talos-vsphere-gitops/README.md`
22. `talos-vsphere-gitops/docs/en/README.md`

## 16. Handoff protocol for Codex and Claude Code

Before implementation of each issue, record:

- repository, issue, base branch, and working branch;
- implementer and reviewer;
- exact files in scope;
- accepted design decision and acceptance criteria;
- commands permitted locally and commands deferred to VMware;
- secret-handling and destructive-operation constraints.

At handoff, record:

- files changed;
- tests run and results;
- decisions or deviations;
- unresolved risks;
- required `DEFERRED_VMWARE` follow-up.

The reviewer must inspect the actual diff and rerun appropriate checks. Neither
agent should modify overlapping files concurrently, and neither agent may
commit, push, open/merge a PR, rotate credentials, rewrite history, or execute
destructive infrastructure commands without explicit authorization.

## 17. Execution tracker

This section is the cross-repository status index. Detailed local execution and
review records live under `docs/planning/execution/`. GitHub issues and pull
requests are optional links, not requirements for agent collaboration. This
keeps implementation, tests, and review local until the owner authorizes remote
publication.

Status meanings:

- `PLANNED`: accepted scope, implementation has not started.
- `IN_PROGRESS`: the named implementer owns the active worktree/branch.
- `REVIEW`: implementation is complete and the named reviewer is independently
  inspecting the diff and rerunning proportionate checks.
- `CHANGES_REQUESTED`: reviewer found actionable corrections; ownership returns
  to the implementer unless the issue explicitly reassigns it.
- `DONE`: acceptance criteria passed, independent local review completed, and
  the accepted commits reached the agreed local target branch. A remote PR is
  not required.
- `DEFERRED_VMWARE`: local work is complete or not applicable, and the remaining
  acceptance test requires the VMware host.
- `BLOCKED`: progress requires an explicit owner decision or unavailable
  external dependency; the reason must be linked.

Rules for agent identity:

- `Implementer` names the agent currently authorized to modify the issue branch.
- `Reviewer` names a different agent responsible for independent review.
- An agent must write its identity into the execution record/tracker before
  changing files.
- The implementer must not mark its own work `DONE` without the assigned
  reviewer's result.
- A reviewer records `APPROVED`, `CHANGES_REQUESTED`, or `FOLLOW_UP_ISSUE` in
  the local review record. Separate findings receive a new local record and may
  later become GitHub issues.
- Only one implementer owns a branch at a time. Role changes must be recorded
  before the new agent continues.

| Iteration | Repository | Status | Local record | Branch | Implementer | Reviewer | GitHub issue/PR | VMware follow-up |
|---|---|---|---|---|---|---|---|---|
| 0 | Cross-repository | `IN_PROGRESS` | `execution/iteration-00.md` | `docs/talos-projects-roadmap` | Codex | Claude Code | optional | not required |
| 1 | `provision-talos-vsphere` | `PLANNED` | pending | pending | unassigned | unassigned | pending | credential rotation by owner |
| 2 | All, separate branches | `PLANNED` | pending | pending | unassigned | unassigned | pending | not required |
| 3 | `talos-toolchain` | `PLANNED` | pending | pending | unassigned | unassigned | pending | not required |
| 4 | `talos-toolchain` | `PLANNED` | pending | pending | unassigned | unassigned | pending | not required |
| 5 | `talos-toolchain` | `PLANNED` | pending | pending | unassigned | unassigned | pending | not required |
| 6 | `talos-vsphere-gitops` | `PLANNED` | pending | pending | unassigned | unassigned | pending | not required |
| 7 | Toolchain and GitOps | `PLANNED` | pending | pending | unassigned | unassigned | pending | optional follow-up |
| 8 | Toolchain and GitOps | `PLANNED` | pending | pending | unassigned | unassigned | pending | topology-dependent checks |
| 9 | `talos-vsphere-gitops` | `PLANNED` | pending | pending | unassigned | unassigned | pending | not required |
| 10 | Toolchain then provision repo | `PLANNED` | pending | pending | unassigned | unassigned | pending | integration follow-up |
| 11 | `provision-talos-vsphere` | `DEFERRED_VMWARE` | pending | pending | unassigned | unassigned | pending | required |
| 12 | `provision-talos-vsphere` | `DEFERRED_VMWARE` | pending | pending | unassigned | unassigned | pending | required |

Update this table only when status or ownership changes. Detailed checklists,
review comments, commands, results, and acceptance evidence belong in the local
execution record rather than making this roadmap an activity log.

Each execution record must contain at least:

```text
Iteration:
Repository:
Status:
Base branch and baseline commit:
Working branch:
Implementer:
Reviewer:
Files in scope:
Acceptance criteria:
Implementation commits:
Local validation performed:
Review verdict:
Corrections requested:
Follow-up work:
VMware validation:
Optional GitHub issue/PR:
```

The reviewer works from the local repository and reviews the committed branch
range (normally `lab...<working-branch>`) plus any uncommitted changes explicitly
included in the handoff. The reviewer reruns proportionate tests and records the
exact commit reviewed. GitHub's reviewer assignment may be used later for human
workflow visibility, but it does not replace this local independent review.
