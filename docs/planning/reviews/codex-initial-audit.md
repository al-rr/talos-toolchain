# Talos Repositories Audit and Incremental Correction Plan

## Review context

This document records a read-only audit of the three Talos-related checkouts in
this workspace. It is intended for joint review by Codex, Claude Code, and the
repository owner before any implementation starts.

Repositories examined:

- `talos-toolchain`
- `talos-vsphere-gitops`
- `provision-talos-vsphere`, which is cloned as `talos-vsphere-lab` in the
  documented clean-host workflow

No repository files were modified while producing the audit. No credentials or
secret values are reproduced here.

### Agreed execution priority

The work is intentionally divided into two independent milestones:

1. **Milestone A — local cluster and GitOps on macOS:** active now. Use the
   locally installed `talosctl`, Colima/Docker, `kubectl`, and Helm. The goal is
   to validate Talos/Kubernetes cluster behavior, CNI bootstrap, Argo CD, GitOps
   reconciliation, configuration generation, and portable validation.
2. **Milestone B — VMware provisioning and integration:** deferred to a
   separate Windows/VMware host. This covers `govc`, vSphere Terraform,
   Workstation-specific experiments, ESXi/vCenter, VM lifecycle, datastores,
   networks, boot media, real HA/VIP behavior, and storage validation.

VMware is not an availability requirement for Milestone A. A check that
requires VMware must be reported as `DEFERRED_VMWARE`, not failed or silently
passed. Local cluster work must not load, invoke, or require the VMware
provisioning backend.

When reviewing this plan, please distinguish:

- **Factual findings:** observed in the current files or confirmed by read-only
  validation.
- **Recommendations:** proposed target boundaries and incremental changes that
  still require owner approval.

## 1. Executive summary

### Factual findings

- The intended three-way responsibility split is documented but not yet
  consistently reflected in executable code:
  - `talos-toolchain`: reusable Talos lifecycle commands.
  - `provision-talos-vsphere`: vSphere/ESXi infrastructure, environment
    topology, and integration testing.
  - `talos-vsphere-gitops`: desired state for cluster add-ons.
- `provision-talos-vsphere` still contains a nearly complete copy of the Talos
  toolchain. Ten corresponding lifecycle scripts exist in both repositories;
  only `provision-cluster.sh` was byte-identical during the audit.
- The integration repository's `cluster.sh` has newer project command-mapping
  behavior than the standalone toolchain, so the supposed canonical toolchain
  is not currently the most advanced implementation.
- Cilium has two lifecycle owners: day-1 Helm installation through
  `apply-post-bootstrap.sh` and automated Argo CD reconciliation through the
  GitOps root application.
- Credential-bearing Talos and Kubernetes access files are tracked in the lab
  repository. Generated machine configurations are also tracked outside the
  ignored `generated/` paths.
- Terraform documentation says Talos credentials stay outside Terraform state,
  but the Talos Terraform module base64-encodes machine configurations into
  vSphere `guestinfo`; those values would be represented in Terraform state.
- Local macOS tooling is installed, but repository automation is not currently
  macOS-ready. `make lint-sh` fails under Apple Bash 3.2 because it uses
  `mapfile`. Other GNU assumptions include `timeout`, `base64 -w 0`, and fixed
  `/home/vagrant/...` defaults.
- The tracked machine configurations passed `talosctl v1.13.7 validate
  --strict --mode cloud`.
- The Talos commands used by the scripts (`gen config`, `apply-config`,
  `bootstrap`, and `machineconfig patch`) remain supported in Talos 1.13. No
  obsolete Talos CLI command was identified.
- No deprecated built-in Kubernetes API versions were found in the authored
  GitOps manifests. The GitOps repository currently contains infrastructure
  add-ons, not application workloads.

### Primary risks

1. Credential material committed to Git.
2. Ambiguous executable source of truth between toolchain and integration
   repositories.
3. Talos machine configuration entering Terraform state.
4. Dual Cilium ownership between imperative Helm and Argo CD.
5. Documented Terraform-first workflow differing from the currently mapped
   `govc` workflow.
6. macOS validation failing before useful checks run.
7. Large copied Helm values trees, approximately 23,000 lines in each location,
   that have already diverged.

## 2. Current repository map

| Responsibility | Current owner | Evidence and qualification |
| --- | --- | --- |
| Local CLI setup | Mainly `provision-talos-vsphere` | Linux/Vagrant installers are under `overlays/lab/controller/scripts/`; no macOS setup workflow exists. |
| VMware/vSphere provisioning | Mainly `provision-talos-vsphere`, duplicated in `talos-toolchain` | Active project mappings invoke integration-repository `govc` scripts. Terraform exists but parts of the workflow remain transitional. |
| Talos config generation | Both operational repositories | Both contain `cluster-bootstrap.sh`; their orchestration entrypoints have drifted. |
| Talos config application | Both operational repositories | Both call `talosctl apply-config`; initial maintenance-mode application uses `--insecure`, while later convergence uses authenticated access. |
| Talos/Kubernetes bootstrap | Both operational repositories | Both invoke `talosctl bootstrap`, retrieve access configuration, and perform readiness checks. |
| CNI installation | Both operational repositories plus GitOps | Day-1 installs Cilium with Helm; GitOps also defines an automated Cilium `Application`. |
| GitOps bootstrap | Both operational repositories consume `talos-vsphere-gitops` | `talos-gitops.sh` exists in both and installs Helm releases or applies the Argo root app. |
| Argo CD desired state | `talos-vsphere-gitops` | Chart metadata, values, root app, and child applications live there. |
| Infrastructure applications | `talos-vsphere-gitops`, with a copied tree in the lab repo | Cilium, Argo CD, cert-manager, Longhorn, and kube-prometheus-stack. |
| Application workloads | None currently | No workload/application manifests were found beyond infrastructure add-ons. |

## 3. Current end-to-end workflow

### Factual workflow

1. Prepare a Linux/Vagrant controller and install the required CLIs from the
   integration repository.
2. Load base, lab, project, and optional local variables. Several overlapping
   variable models currently exist.
3. Generate Talos secrets, machine configurations, node network patches, and
   Talos Factory image references.
4. Provision VMs:
   - Current project command mappings use integration-repository `govc`.
   - A separate Terraform workflow clones a template and injects common machine
     configurations through `guestinfo`.
5. Discover DHCP bootstrap addresses through VMware Tools and `govc` when ISO
   boot mode is used.
6. Apply initial machine configurations with `talosctl apply-config --insecure`.
7. Reconcile HAProxy backends and potentially configure Keepalived/VIP through
   an external `infra-gitops` dependency.
8. Run `talosctl bootstrap` on a selected control-plane node.
9. Optionally reapply machine configuration post-bootstrap and generate or
   synchronize kubeconfig and talosconfig.
10. Copy Helm content from the GitOps checkout into the project `helm/`
    directory and install Cilium, optionally Longhorn.
11. Install Argo CD imperatively and apply the root `Application`.
12. Argo CD reconciles Cilium, cert-manager, Longhorn, and prometheus-stack.

The documentation disagrees about whether post-bootstrap `apply-config` occurs
before or after `bootstrap`. This must be resolved into one canonical order.

## 4. Problems and risks

### Security and state handling

- Credential-bearing Talos and Kubernetes files are tracked. They must be
  considered exposed and rotated; adding ignore rules alone will not invalidate
  existing credentials.
- Default configuration includes placeholder/default passwords for HAProxy
  statistics and Keepalived authentication. These are not production-safe
  defaults.
- Terraform's `guestinfo.talos.config` contradicts the documented boundary that
  keeps Talos secrets outside Terraform state.
- The GitOps Secret example is correctly marked as an example, but the GitOps
  repository has no `.gitignore` protection for common local credential files.

### Duplication and unclear ownership

- Lifecycle scripts exist in both operational repositories and have already
  drifted.
- The integration `cluster.sh` supports mapped project actions; the standalone
  toolchain version directly invokes its own copied implementations.
- Documentation alternately identifies base scripts, transition wrappers, the
  standalone toolchain, Terraform, and `govc` as canonical.
- Helm release metadata and values are copied between GitOps and `talos-dev`.
  Some files remain identical while others have diverged without an explicit
  layering contract.
- Cilium is installed imperatively and reconciled by Argo CD, creating drift,
  prune, and ownership risks.

### Idempotency and destructive behavior

- VM creation skips existing VMs by default, which is reasonably idempotent.
- `overwrite=true` destroys an existing VM without an additional confirmation
  or cluster identity guard.
- The explicit `destroy` action destroys all names derived from configured
  prefixes without a typed confirmation.
- Helm synchronization defaults to overwrite and uses `rsync --delete`; its
  fallback recursively removes destination entries.
- kubeconfig synchronization deletes live target entries before producing and
  validating the merged replacement.
- talosconfig synchronization overwrites the target without an atomic
  replacement or backup.
- Argo applications use automated prune and self-heal; this should remain
  enabled only after ownership is unambiguous.

### Portability and validation

- Apple Bash 3.2 cannot run the lint entrypoint because of `mapfile`;
  `${value,,}` also requires newer Bash.
- `timeout` and GNU `base64 -w 0` are not portable macOS interfaces.
- Fixed `/home/vagrant/...` paths appear throughout scripts and documentation.
- Dry-run behavior is inconsistent. Some actions resolve real plans, while
  others only print a delegated command without validating generated content.
- Terraform validation requires provider initialization but not a vSphere
  connection. Terraform plan evaluates vSphere data sources and does require
  VMware access.
- Talos 1.12.4 is pinned in repository defaults while the audited local CLI is
  1.13.7. This is version drift rather than an obsolete command issue.

### Documentation drift

- Root layout documentation references missing paths such as
  `overlays/base/govc`.
- Multiple guides link to nonexistent `overlays/lab/talos/talos/README.md`.
- Absolute `/home/vagrant/...` Markdown links are not portable.
- `agenda.md` says VIP automation is missing, while current HAProxy scripts
  include a Keepalived flow delegated to external `infra-gitops`. The current
  support status is unclear rather than simply absent.
- GitOps documentation calls the toolchain "in preparation" although it now
  contains migrated scripts.
- The GitOps checkout is on `lab`, while every Argo application reconciles
  `main`. This may be deliberate deployment policy, but local branch testing
  does not validate the revision Argo will fetch.

## 5. Proposed target responsibilities

### `talos-toolchain`

Own:

- Portable CLI/version checks and macOS/Linux setup guidance.
- Project-oriented Talos lifecycle contract.
- Talos secrets and machine-config generation.
- Machine-config validation, application, bootstrap, health, and access sync.
- One-shot Kubernetes operations required before GitOps can function.
- Generic GitOps bootstrap commands that consume a manifest root.
- Backend hooks for infrastructure provisioning and address discovery.

Do not own:

- vSphere credentials, topology, static node IPs, HAProxy addresses, or lab
  paths.
- `govc`/Terraform implementation details.
- Copies of environment Helm values.

### `provision-talos-vsphere` / `talos-vsphere-lab`

Own:

- vSphere/ESXi Terraform and `govc` implementations.
- Talos VM lifecycle, boot media, guest hardware, VMware address discovery, and
  VMware-specific validation.
- HAProxy, Keepalived, DNS, datastore, network, and environment topology.
- Lab/prod project specs, node counts, IP assignments, patches, schematics, and
  infrastructure backend hooks.
- Cross-repository integration and acceptance scenarios.
- Compatibility wrappers during migration.

Do not own:

- A second generic implementation of Talos generation/application/bootstrap.
- Canonical Helm values or Argo applications.

### `talos-vsphere-gitops`

Own:

- Canonical Helm release metadata and minimal environment overrides.
- Argo CD bootstrap/root and child applications.
- Infrastructure add-ons and future workloads.
- Desired-state validation and environment promotion policy.

### Cilium ownership rule

- The toolchain performs a one-time bootstrap install from the GitOps repository
  because Argo CD cannot operate before cluster networking exists.
- After Argo CD becomes healthy, the Cilium `Application` adopts and exclusively
  reconciles the same chart version and values.
- No copied values tree should participate in the active workflow.

## 6. Proposed end-to-end workflow

Separate the flow into four explicit layers:

1. **Infrastructure provisioning**
   - The lab repository validates topology and provisions VMware VMs, load
     balancers, DNS, disks, and boot media.
   - Terraform creates infrastructure only and receives no Talos secret or
     machine-config payload.
2. **Talos machine configuration**
   - The toolchain generates secrets/configs into the lab project's ignored
     `generated/` directory.
   - It renders node patches from lab-owned project values, validates them, and
     applies them to discovered node addresses.
3. **Kubernetes cluster bootstrap**
   - The toolchain configures endpoints, bootstraps etcd/Kubernetes once,
     retrieves kubeconfig, and installs the minimum CNI from canonical GitOps
     values.
4. **GitOps reconciliation**
   - The toolchain installs Argo CD from the GitOps release descriptor and
     applies the root app.
   - Argo CD becomes the sole owner of Cilium and all subsequent infrastructure
     applications and workloads.

Canonical order:

```text
validate
  -> generate
  -> provision
  -> discover
  -> apply initial Talos config
  -> bootstrap
  -> converge Talos config
  -> sync access
  -> bootstrap Cilium
  -> bootstrap Argo CD
  -> verify reconciliation
```

## 7. Local macOS test strategy

### Offline and static tests

- Run `bash -n` and ShellCheck across all maintained scripts.
- Run `talosctl validate --strict` against generated machine configurations.
- Generate configs and apply patches in a temporary directory with
  `talosctl gen config` and `talosctl machineconfig patch`.
- Run Terraform formatting and validation after
  `terraform init -backend=false`.
- Render every GitOps release with `helm template`.
- Validate ordinary Kubernetes resources client-side and Argo resources
  structurally.
- Use temporary kubeconfig/talosconfig files for access-sync tests.
- Run argument, action, and dry-run tests with fake `govc`, `kubectl`, `helm`,
  and `talosctl` executables.

### Local Talos cluster

Use Colima as the Docker runtime and `talosctl cluster create docker` for local
behavioral testing.

Test locally:

- Talos API and kubeconfig acquisition.
- Bootstrap sequencing.
- Cilium bootstrap with a container-compatible patch set.
- Argo CD installation and app-of-apps reconciliation.
- cert-manager and prometheus-stack.
- Idempotent reruns and GitOps self-healing.
- Destruction only against a uniquely named temporary cluster.

Local Docker clusters do not validate VMware guestinfo, VM firmware, vSphere
networking, HAProxy VIPs, datastore behavior, or realistic Longhorn disks.

### Local HAProxy container scope

HAProxy should have a local container test in Milestone A, but it must be
treated as configuration and traffic-routing validation rather than a faithful
HA deployment.

The local test should:

- render the HAProxy configuration from the same backend model used by the
  cluster workflow;
- run `haproxy -c` inside a pinned HAProxy container image;
- start disposable TCP backends or use an explicitly reachable local cluster
  API endpoint;
- verify frontend connectivity, health checks, backend removal, and recovery;
- expose a stable host port for the test without requiring a LAN VIP;
- run on a dedicated Docker network and clean up only resources carrying the
  test's unique labels and names.

Keepalived and a real floating VIP should not be part of the required macOS
test. VRRP, multicast/unicast behavior, privileged network namespaces, L2
advertisement, and host failover are not faithfully represented through
Colima's Linux VM and macOS networking. A Linux-only privileged container test
may later validate configuration syntax and basic state transitions, but it
must not be accepted as proof of production VIP failover. Real Keepalived/VIP
acceptance remains in Milestone B on the VMware network.

### Bash portability decision

Standardize on Bash 5 through Homebrew on macOS rather than maintaining Apple
Bash 3.2 compatibility. Entrypoints should detect an unsupported Bash and fail
with one actionable installation message.

## 8. Work that still requires VMware/vSphere

- Provider-backed Terraform plan/apply and vSphere data-source lookup.
- `govc` authentication, inventory resolution, datastore upload, ISO
  attachment, OVA import, template clone, and VM deletion.
- VMware `guestinfo` behavior and VMware Tools IP discovery.
- UEFI/CD-ROM boot and DHCP-maintenance-to-static-network transition.
- Port-group, folder, host/cluster, resource-pool, and datastore behavior.
- Real control-plane and worker resource sizing.
- HAProxy backend connectivity, VIP ownership/failover, and Talos API
  reachability on port 50000.
- Static node networking and interface-name assumptions.
- Extra-disk discovery, Talos disk configuration, and production-like Longhorn
  behavior.
- VM reboot, node replacement, datastore persistence, and load-balancer
  failover recovery.

## 9. Incremental correction plan

Each commit should stay within one repository unless a cross-repository change
cannot safely be split. Do not merge or rename repositories.

Milestone A issues and commits are implemented first. Milestone B remains
documented but is not an acceptance dependency for local cluster work. No
VMware provisioning code should be changed merely to make a macOS test pass.

### Iteration 1: Credential containment

- Rotate credentials represented by tracked Talos/kubeconfig material.
- Replace credential-bearing tracked files with clearly nonfunctional examples
  at the same paths; keep real outputs under ignored `generated/` directories.
- Add secret scanning and ignore rules.
- Suggested commit: `security: replace tracked Talos credentials with safe examples`
- Any Git-history rewrite requires a separate plan and explicit approval.

### Iteration 2: Document the boundary

- Align the three root READMEs and handoff documents with the target ownership.
- Explain the checkout directory alias and label active, compatibility, and
  draft paths.
- Suggested commits:
  - `docs: define Talos toolchain responsibility boundary`
  - `docs: clarify vSphere lab integration ownership`
  - `docs: define GitOps source-of-truth contract`

### Iteration 3: Make the toolchain testable on macOS

- Require Bash 5, detect missing GNU dependencies, remove fixed workspace
  defaults, and document macOS setup/version checks.
- Add offline generation, validation, argument, and dry-run smoke tests.
- Suggested commit: `test: add portable Talos toolchain validation`

### Iteration 4: Reconcile lifecycle implementations

- Port the newer project-command contract into `talos-toolchain`.
- Make integration `cluster.sh` and `talos-gitops.sh` compatibility wrappers.
- Preserve existing files and mark noncanonical implementations deprecated
  rather than deleting them.
- Suggested commits:
  - `fix: align toolchain project command contract`
  - `refactor: delegate Talos lifecycle to talos-toolchain`

### Iteration 5: Separate infrastructure from Talos configuration

- Keep vSphere provisioning hooks in the lab repository.
- Remove Talos machine-config payloads from Terraform inputs/state and apply
  configuration afterward with `talosctl`.
- Add confirmation and identity guards to overwrite/destroy operations.
- Suggested commits:
  - `refactor: keep Talos credentials out of Terraform state`
  - `safety: guard destructive vSphere lifecycle actions`

### Iteration 6: Establish one variable model

- Make toolchain defaults environment-neutral.
- Keep topology and IPs in lab/project files.
- Keep credentials and host-local paths in ignored `vars.local.sh` files.
- Add validation for duplicate or conflicting assignments.
- Suggested commit: `refactor: separate reusable defaults from lab topology`

### Iteration 7: Resolve CNI and Helm ownership

- Bootstrap Cilium directly from the GitOps checkout without copying its tree.
- Verify exact chart/version/value parity before Argo adopts the release.
- Stop treating `talos-dev/helm` as canonical; preserve it only as a migration
  snapshot.
- Suggested commits:
  - `refactor: bootstrap Cilium from canonical GitOps values`
  - `gitops: define Cilium bootstrap adoption`

### Iteration 8: Validate GitOps artifacts

- Add `.gitignore`, YAML/schema checks, `helm template` tests, chart-version
  compatibility checks, and root/child path validation.
- Reduce full generated values files to intentional overrides in a later,
  isolated commit after rendered-manifest comparison.
- Suggested commits:
  - `test: validate GitOps applications and Helm releases`
  - `refactor: minimize generated Helm values`

### Iteration 9: Refresh operational documentation

- Repair missing and absolute links.
- Publish one canonical execution order.
- Reconcile Terraform/`govc` and HAProxy/Keepalived status with implementation.
- Update English and PT-BR documents together.
- Suggested commit: `docs: align Talos runbooks with current implementation`

### Iteration 10: Cross-repository acceptance

- Complete Milestone A first:
  - run macOS offline validation;
  - run Colima/Talos local-cluster bootstrap and GitOps reconciliation;
  - run the HAProxy container configuration and failover simulation;
  - record Longhorn and VMware-dependent cases as deferred.
- Complete Milestone B later on the Windows/VMware host:
  - run VMware dry-run/config checks;
  - run a controlled vSphere smoke deployment;
  - validate real HAProxy/Keepalived/VIP and storage behavior.
- Suggested commits:
  - `test: add macOS Talos and GitOps acceptance workflow`
  - `test: add local HAProxy container validation`
  - `test: add VMware integration acceptance workflow`

## 10. Files to review first

1. Credential-bearing and generated legacy files under
   `provision-talos-vsphere/overlays/lab/talos/k8s-*-lab/`.
2. `talos-toolchain/scripts/talos/cluster.sh`.
3. `provision-talos-vsphere/overlays/base/scripts/talos/cluster.sh`.
4. Both repositories' `scripts/talos/cluster-bootstrap.sh` implementations.
5. `talos-toolchain/scripts/talos/vars.sh` and the lab project vars files.
6. `provision-talos-vsphere/overlays/base/terraform/talos/main.tf`.
7. Both `apply-post-bootstrap.sh` and `talos-gitops.sh` implementations.
8. `talos-vsphere-gitops/environments/lab/argocd/root-app.yaml` and the Cilium
   child application.
9. Canonical GitOps Helm releases versus the copied `talos-dev/helm` tree.
10. `provision-talos-vsphere/agenda.md`, the platform architecture document,
    and the cross-repository handoff.

## 11. Issues, branches, commits, and collaboration strategy

### Tracking model

- Create one umbrella issue in `provision-talos-vsphere` to track the complete
  cross-repository correction program.
- Create one implementation issue per iteration and per affected repository.
  Do not use one issue to authorize unrelated changes across all repositories.
- Link every repository-specific issue to the umbrella issue and record its
  dependencies explicitly.
- Use issue checklists for acceptance criteria, validation evidence,
  documentation updates, and rollback notes.
- Treat the issue description as the approved scope. New findings that would
  materially expand the work should become follow-up issues instead of being
  silently added to an active branch.

Suggested umbrella issue title:

```text
Program: clarify Talos repository boundaries and validate the end-to-end workflow
```

Suggested issue labels:

- `security`
- `architecture`
- `documentation`
- `toolchain`
- `gitops`
- `vsphere`
- `testing`
- `blocked`
- `needs-review`

### Issue template for each iteration

Each implementation issue should contain:

1. **Problem:** factual current behavior, with file and line references.
2. **Repository:** exactly one primary repository.
3. **Objective:** the observable outcome of the issue.
4. **In scope:** files and behavior authorized for change.
5. **Out of scope:** related work intentionally deferred.
6. **Dependencies:** issues or decisions that must land first.
7. **Acceptance criteria:** commands and expected results.
8. **Safety notes:** credentials, destructive operations, rollback, and
   VMware requirements.
9. **Documentation impact:** English and PT-BR files that must stay aligned.
10. **Review evidence:** test output summaries without credentials or other
    sensitive values.

### Proposed issue breakdown and dependency order

| Order | Primary repository | Suggested issue | Depends on |
| --- | --- | --- | --- |
| 1 | `provision-talos-vsphere` | Contain and rotate tracked Talos credentials | Owner approval for credential rotation |
| 2 | All three, separate issues | Document repository ownership and canonical workflow | Audit approval |
| 3 | `talos-toolchain` | Add Bash 5/macOS validation contract and offline tests | Ownership documentation |
| 4 | `talos-toolchain` | Align the project command and backend-hook contract | Toolchain tests |
| 5 | `provision-talos-vsphere` | Delegate generic Talos lifecycle to the toolchain | Toolchain contract merged |
| 6 | `talos-vsphere-gitops` | Add manifest, chart, and secret-file validation | GitOps ownership documentation |
| 7 | Toolchain and GitOps, separate issues | Define Cilium bootstrap and Argo adoption | Toolchain contract and GitOps validation |
| 8 | Toolchain or integration test owner | Add local HAProxy container validation | Local test contract defined |
| 9 | All three, separate issues | Refresh Milestone A runbooks and repair links | Relevant local implementation issues merged |
| 10 | Toolchain and GitOps, separate issues | Add macOS Talos/GitOps acceptance | Milestone A behavior changes |
| 11 | `provision-talos-vsphere` | Remove Talos payloads from Terraform state | Milestone A complete; lifecycle boundary stable |
| 12 | `provision-talos-vsphere` | Guard destructive VMware operations | Toolchain/lab boundary defined |
| 13 | `provision-talos-vsphere` | Consolidate VMware environment and local vars | Toolchain contract merged |
| 14 | `provision-talos-vsphere` | Add VMware and real VIP acceptance | Milestone B implementation issues |

Security containment may proceed before the broader documentation work, but
credential history rewriting, if required, must be a separate issue and must
not be combined with normal source changes.

Issues 1 through 10 form Milestone A. Issues 11 through 14 form Milestone B and
remain open/deferred until work moves to the Windows/VMware host.

### Branch strategy

- Create one short-lived branch per issue in the repository that owns the
  change.
- Branch from the repository's intended PR base branch after confirming whether
  that base is `main` or `lab`. Do not infer the base from the current checkout
  alone.
- Do not reuse one branch across repositories. Related changes use distinct
  branches and linked PRs.
- Do not create a long-lived cross-repository migration branch.
- Rebase or update a dependent branch only after its prerequisite PR contract
  is stable.

Branch naming convention:

```text
<type>/<issue-number>-<short-description>
```

Examples:

```text
security/101-safe-talos-artifacts
docs/102-repository-boundaries
test/103-macos-toolchain-validation
refactor/104-toolchain-command-contract
refactor/105-lab-toolchain-delegation
refactor/106-talos-terraform-state
safety/107-vsphere-destroy-guards
gitops/108-cilium-adoption
```

Recommended branch types are `security`, `docs`, `test`, `fix`, `refactor`,
`safety`, and `gitops`.

### Commit strategy

- Keep every commit buildable or independently reviewable.
- Use imperative Conventional Commit-style subjects consistent with the
  suggested messages in this plan.
- Avoid mixing generated output, behavioral changes, formatting, and
  documentation cleanup in one commit.
- Keep English and PT-BR versions of the same operator document in the same
  commit.
- Include tests with the behavior they protect when practical. A separate test
  commit is acceptable when it first captures existing behavior before a
  refactor.
- Never commit real Talos machine configs, talosconfig, kubeconfig, local vars,
  Terraform state, or secret manifests.
- Before every commit, stage only the intended files and run a staged diff and
  whitespace check.

Preferred commit sequence inside a behavioral branch:

1. Add or adjust tests that describe the contract.
2. Implement the smallest behavior change.
3. Update the owning documentation and examples.
4. Apply isolated cleanup only when needed for the same issue.

### Pull request strategy

- Open one PR per issue and repository.
- Use draft PRs until local acceptance criteria pass.
- Link the implementation issue, umbrella issue, prerequisite PRs, and any
  dependent follow-up PRs.
- State whether the PR changes a public CLI, variable contract, generated
  artifact path, GitOps ownership, or destructive behavior.
- Include a concise validation matrix covering:
  - macOS/offline checks;
  - local Talos cluster checks, when applicable;
  - VMware dry-run or real-environment checks, when applicable;
  - documentation parity.
- Merge prerequisite PRs before dependent PRs. Do not merge a lab delegation PR
  before the required toolchain release or commit is available.
- For cross-repository transitions, keep compatibility behavior until every
  dependent repository has adopted the new contract.

### Codex and Claude Code collaboration

- Either agent may perform the initial issue analysis, but the other should
  independently review the factual findings and proposed acceptance criteria
  before implementation begins.
- Assign one agent as the implementer and the other as reviewer for an issue.
  Rotate roles between issues when useful.
- Do not let both agents modify the same branch or overlapping files at the
  same time.
- Before handing work between agents, record:
  - issue and branch;
  - files changed;
  - decisions made;
  - tests run and results;
  - remaining risks or blockers;
  - whether any VMware validation is still pending.
- Reviewers should inspect the actual diff and rerun proportionate checks rather
  than approving from a summary alone.
- Conflicting recommendations should be written into the issue as explicit
  alternatives with evidence. The repository owner makes the final decision
  before either agent implements the disputed choice.
- Neither agent may rotate credentials, rewrite Git history, destroy VMware
  resources, commit, push, or open/merge PRs without the corresponding explicit
  authorization.

### Definition of done for an issue

An issue is complete only when:

- its acceptance criteria pass;
- no secret value appears in the diff or validation output;
- affected public contracts and bilingual operator docs are aligned;
- compatibility and rollback behavior are documented;
- local checks pass, or failures are recorded with a justified environment
  limitation;
- required VMware validation is either complete or represented by a separate,
  clearly linked `DEFERRED_VMWARE` issue; VMware availability is not required
  to close a Milestone A issue;
- the reviewer has evaluated the final diff;
- follow-up work is captured as linked issues rather than hidden TODOs.

## 12. Decisions after the Claude Code review and `infra-gitops` inspection

This section records decisions made after the initial audit. It supersedes any
earlier wording that implies a fixed `main` revision for every environment.

### Git revision follows the selected environment

**Decision:** the GitOps revision must be explicit and environment-aware:

- `lab` reconciles the `lab` branch;
- `main` reconciles the `main` branch;
- a future environment must declare its revision explicitly rather than inherit
  whichever branch happens to be checked out locally.

The root Argo CD Application and every generated or child Application must use
the same resolved revision. Validation must fail if a rendered application has
a conflicting `targetRevision`. The checked-out working-tree branch is useful
as a warning or consistency check, but it must not silently determine desired
cluster state.

### Talos-owned environment configuration

**Factual findings:**

- `infra-gitops` is currently checked out on `lab` and defines a reusable,
  external operator configuration tree under `~/.config/infra-gitops`.
- `gitopsctl bootstrap-config` creates global base and environment overlays,
  keeps credentials outside Git, refuses execution as root, applies restrictive
  permissions, and does not overwrite existing files unless `--force` is used.
- vSphere connections are modeled as named targets under
  `overlays/<env>/targets/`, allowing Packer, Terraform, Ansible, and `govc` to
  refer to one operator-managed target definition.
- Module-specific configuration and precedence already exist, but the only
  module currently supported by `gitopsctl bootstrap-config --module` is
  `packer`; there is no Talos module yet.
- The `infra-gitops` security-hardening iteration is not complete. Adoption of
  the pattern does not remove the need to audit shell sourcing, permissions,
  log redaction, exported variables, and subprocess exposure.
- `platformctl` is not present in this workspace and was therefore not assessed.
  Milestone A must not depend on its installation or behavior.

**Decision:** `gitopsctl` and `platformctl` are reference implementations, not
dependencies or owners of Talos configuration. `talos-toolchain` is the CTL for
the Talos projects and must own the Talos-specific commands, configuration
schema, validation, precedence, and environment selection.

The reusable idea is the operator experience: persist local values by
environment below the user's home/config directory, outside every Git checkout.
The Talos implementation should be native to `talos-toolchain`; it must not add
a Talos module to `infra-gitops`, invoke another repository's CTL, or copy that
repository's internal loaders. Prefer an XDG-aware path such as
`${XDG_CONFIG_HOME:-$HOME/.config}/talos-toolchain`, with a documented migration
path if existing Talos local configuration already uses another location.

Keep the following separation:

- tracked repository configuration: non-secret cluster intent, environment
  name, topology, versions, feature flags, and Git revision mapping;
- external operator configuration: credentials, tokens, private keys, vSphere
  endpoints/targets, and machine-specific paths;
- generated state: `talosconfig`, `kubeconfig`, machine configurations, local
  cluster state, and rendered temporary manifests, stored in explicit ignored
  paths with restrictive permissions;
- CLI flags: intentional one-run overrides with the highest precedence.

Do not embed kubeconfig, talosconfig, certificates, or private keys directly in
shell credential files. Store them as protected files and configure only their
paths. Because configuration files are sourced as shell, loaders must verify
that paths are regular files, are owned by the current user, and are not
group/world writable before sourcing them.

For Milestone A on macOS, `talos-toolchain` should select `--env=lab` without
requiring a vSphere target. Named vSphere connection data remains a Milestone B
concern and can live in the same Talos-owned environment hierarchy when it is
needed. Neither `gitopsctl` nor `platformctl` is a prerequisite.

### Additional incremental issues

Add these issues to the existing iteration sequence without merging or renaming
repositories:

1. **`talos-toolchain`: define its environment configuration contract.**
   Document paths, variable names, secret classification, file permissions,
   precedence, generated state locations, and the distinction between
   configuration and credentials before adding code.
   Suggested commit: `docs(config): define Talos environment contract`
2. **`talos-toolchain`: implement environment bootstrap and loading.** Add an
   idempotent CTL command that scaffolds `base` and environment-specific files
   below the user's config directory, plus portable loading, validation,
   redacted diagnostics, and compatibility with existing environment-variable
   inputs during migration.
   Suggested commit: `feat(config): manage Talos environment settings`
3. **`talos-vsphere-lab`: declare tracked lab intent.** Keep non-secret lab
   topology and `gitRevision: lab` in the repository; remove duplicated secret
   ownership only after the loader is available.
   Suggested commit: `refactor(config): separate lab intent from operator data`
4. **`talos-vsphere-gitops`: render and validate revision consistently.** Ensure
   the root and child Argo CD Applications resolve `lab` to `lab` and `main` to
   `main`, with a validation command that detects mixed revisions.
   Suggested commit: `fix(argocd): align target revision with environment`
5. **Provisioning repository: consume Talos-owned environment data later.**
   Migrate vSphere credentials and connection variables to the contract exposed
   by `talos-toolchain` only in Milestone B, retaining a documented compatibility
   window.
   Suggested commit: `refactor(config): consume Talos environment settings`

Each issue remains a separate branch and PR against the repository's normal
integration branch. In the current workflow that branch is normally `lab`;
promotion from `lab` to `main` is a separate reviewed operation. Never combine
the configuration migration, Argo revision correction, and provisioning
migration in one cross-repository change.

## 13. Questions for Claude Code review

Claude Code should independently inspect the repositories and comment on:

1. Any factual finding above that is incorrect, incomplete, or no longer true.
2. Additional credential, state, destructive-operation, or supply-chain risks.
3. Whether applying Talos configuration after infrastructure creation is viable
   for every supported ISO/OVA/template path.
4. Whether the proposed Cilium bootstrap-to-Argo adoption is safe with the
   current Helm and Argo CD settings.
5. Any compatibility issue among the pinned Talos, Kubernetes, Cilium, Argo CD,
   cert-manager, Longhorn, and prometheus-stack versions.
6. Whether Bash 5 should be the explicit portability baseline or whether the
   maintained scripts should instead support Apple Bash 3.2.
7. Whether the suggested iteration order has hidden dependencies or should be
   reordered.
8. Any simpler correction that improves the existing architecture without
   merging or renaming repositories.
9. Whether the proposed HAProxy container test covers the useful local behavior
   without implying that Keepalived/VRRP/VIP failover was validated.
10. Whether any Milestone A issue still accidentally invokes or requires the
    VMware provisioning backend.

Claude Code should append or provide its review separately before either agent
modifies repository files. Findings should include file and line references and
must not reproduce secret values.
