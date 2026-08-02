# Iteration execution record

- Iteration: 08 (roadmap: Iteration 8 — local platform reconciliation)
- Repository: `talos-toolchain` (implementation); `talos-vsphere-gitops`
  (read-only source of truth)
- Status: `REVIEWED_PENDING_OWNER_PUBLICATION`
- Base branch: `lab`
- Baseline commit: `91b214117392fc3968587e887fb38398924000aa`
- Working branch: `feat/issue-021-local-cilium-bootstrap`
- Implementer: Claude Code (planned)
- Reviewer: Codex (planned)
- Optional GitHub issue: [#21](https://github.com/al-rr/talos-toolchain/issues/21)
- Optional pull request: none
- VMware validation: `not required`

## Scope

Provide a safe local Docker/Colima Cilium day-1 path. Talos must not install
managed Flannel, Cilium must use the existing GitOps `lab` release identity,
and host tools must use Docker-published endpoints. The existing day-2 Argo
adoption contract remains authoritative.

### Acceptance criteria

- [x] Local Cilium mode disables Talos-managed Flannel.
- [x] Cilium day-1 is identity/values-compatible with GitOps `lab`.
- [x] The operator kubeconfig uses a published host endpoint.
- [x] Offline validation covers command construction and safety guards.
- [x] No live infrastructure operation is performed by implementation/tests.

## Implementation handoff

- Implementation commits: none yet (uncommitted working-tree changes only;
  no commit created without explicit owner authorization per workspace
  instructions).
- Uncommitted changes included:
  - `scripts/talos/local-cluster.sh`: added `--cni=<flannel|cilium>` and
    `--gitops-repo-root=<path>` to `create`. Default (`flannel`/no `--cni`)
    is byte-for-byte unchanged in every code path exercised by the existing
    `test-local-cluster.sh` suite (all 52 prior assertions still pass).
    Cilium mode adds: a GitOps `lab` checkout preflight (Git repo, branch
    `lab`, clean tree, required files present) that never mutates the
    checkout; a `--config-patch` setting `cluster.network.cni.name` to
    `none`; `--host-ip 127.0.0.1 --exposed-ports 0:<port>/tcp` to publish
    the control-plane API port to a dynamically assigned loopback host
    port; `docker port` polling (60s timeout, overridable via
    `TALOS_LOCAL_CLUSTER_API_PORT_WAIT_SECONDS` for tests) to discover the
    actual mapping; an isolated-kubeconfig `server:` rewrite from the
    internal Docker network address to the discovered loopback endpoint
    (never touches the operator's default `~/.kube/config`); a
    `validate-cilium-handoff.sh` gate run before Helm install; a
    `phase-network-bringup.sh --helm-root=<gitops>/environments/lab/helm`
    invocation to install Cilium day-1 directly from the GitOps checkout's
    own files (not a synced copy, so identity is structural); and a
    CoreDNS rollout wait before the wrapper marker (now also recording
    `cni=<mode>`) is written. On any failure, nothing is auto-cleaned up —
    consistent with the wrapper's pre-existing recovery model.
  - `scripts/talos/phase-network-bringup.sh`: added `--helm-root` and
    `--render-dir`, mutually exclusive with `--project-dir`. When
    `--helm-root` is given, the vSphere project-dir/vars-file/
    `load_overlay_vars` path is skipped entirely; `--kubeconfig` and
    `--render-dir` become required instead. The default `--project-dir`
    path (used by `cluster.sh`/`apply-post-bootstrap.sh` for vSphere
    clusters) is unchanged. Also restored the script's executable bit
    (it was `644` before this change, which would have made any direct
    invocation — including the pre-existing `apply-post-bootstrap.sh`
    call path — fail with "Permission denied"; `validate-cilium-handoff.sh`
    and `local-cluster.sh` were already `755` for comparison).
  - `scripts/talos/tests/fixtures/local-cluster/`: extended the `docker`
    stub with a `port` subcommand (`STUB_DOCKER_PORT_MAPPING`,
    `STUB_DOCKER_PORT_FAIL`) and the `talosctl` stub's `kubeconfig` output
    to emit a realistic internal-address kubeconfig
    (`server: https://10.5.0.2:6443`) so the rewrite path is actually
    exercised; added new `helm` and `kubectl` stub fixtures.
  - `scripts/talos/tests/test-local-cluster-cilium.sh` (new): 23 offline
    assertions — default-mode regression, `--cni` validation, GitOps
    preflight (missing root, non-Git, wrong branch, dirty tree), dry-run
    command-construction previews (CNI-none patch, loopback publish flags,
    validator + Helm bring-up invocations, GitOps checkout left untouched),
    a full stubbed real run (kubeconfig rewritten, internal address never
    present, Helm/CoreDNS invoked, marker records `cni=cilium`), and a
    published-port-discovery-timeout failure path (create fails, Talos
    state retained for diagnostics, marker never written).
  - `scripts/talos/tests/test-syntax.sh`: registered the new test file for
    `bash -n`.
  - `docs/en/local-cluster.md`, `docs/pt-br/local-cluster.md`: documented
    `--cni`/`--gitops-repo-root`, the Cilium local mode step sequence, and
    updated the "known limitations" sections.
- Local validation performed (all offline, no live Docker/Colima/Talos/
  Kubernetes/Helm/VMware operation):
  - `bash scripts/talos/tests/test-local-cluster.sh` — 52 passed, 0 failed
    (pre-existing suite, confirms no regression to default/flannel mode).
  - `bash scripts/talos/tests/test-local-cluster-cilium.sh` — 23 passed,
    0 failed (new suite for `--cni=cilium`).
  - `bash scripts/talos/tests/test-cilium-handoff.sh` — 6 passed, 0 failed
    (pre-existing suite, confirms the handoff validator and day-2 exclusion
    are unaffected).
  - `bash scripts/talos/tests/test-syntax.sh` — 0 failing checks (`bash -n`
    over all maintained entrypoints including the new test file, plus
    `shellcheck` over the touched entrypoints).
  - Manual sanity check: `local-cluster.sh create --cni=cilium
    --gitops-repo-root=../talos-vsphere-gitops --dry-run` against the real
    local `talos-vsphere-gitops` `lab` checkout in this workspace, and
    `phase-network-bringup.sh --helm-root=... --dry-run` directly — both
    confirmed the expected command sequence with no live calls, then the
    manual throwaway `--state-root` scratch directory was removed.
  - `git diff --check` — clean (no whitespace errors) across
    `talos-toolchain`.
- Known limitations:
  - The loopback port-publish flags (`--host-ip`, `--exposed-ports`, and
    `docker port` discovery) are exercised only against stub fixtures in
    this environment; they were not verified against a live `talosctl
    cluster create docker` run (out of scope: "no live Docker, Colima,
    Talos, Kubernetes, Helm, or VMware operation" per the approved plan).
    First live use should start with `--dry-run`, then a real `create`,
    confirming `docker port <cluster>-controlplane-1 6443/tcp` returns a
    single mapping before relying on the rewritten kubeconfig.
  - `--gitops-repo-root` preflight requires an exact `git rev-parse
    --abbrev-ref HEAD` of `lab` and a fully clean `git status --porcelain`;
    a detached-HEAD or worktree checkout of `lab` is rejected by design
    (matches the plan's "clean GitOps checkout on `lab`" requirement) but
    is a stricter check than some operators might expect.
  - `phase-network-bringup.sh --helm-root` mode does not yet have its own
    dedicated offline test file; it is covered indirectly through
    `test-local-cluster-cilium.sh`'s stubbed real-run assertions and a
    manual `--dry-run` sanity check, plus `test-syntax.sh` (`bash -n`).

## Correction cycle 1

- Review verdict on the cycle-0 implementation above: `CORRECTIONS_REQUIRED`.
- Blocker addressed: `talosctl cluster create docker` has no `--wait=false`
  equivalent, so it blocks internally until Kubernetes/CoreDNS is healthy —
  which can never happen on its own while `--cni=cilium` sets CNI to `none`.
  `do_create`'s cilium-mode path (`scripts/talos/local-cluster.sh`) now runs
  that command in the background via a new `supervise_cilium_async_create`
  helper: it launches `"${create_cmd[@]}" > "${CLUSTER_DIR}/create.log" 2>&1
  &`, installs an `INT`/`TERM` trap that kills and `wait`s the backgrounded
  PID (retaining all state, never destroying) before re-exiting non-zero,
  fetches the isolated kubeconfig with a new retry helper
  (`fetch_kubeconfig_with_retry`, 3s interval / 120s timeout, overridable via
  `TALOS_LOCAL_CLUSTER_KUBECONFIG_FETCH_WAIT_SECONDS` for tests) since the
  Talos API may not answer the instant the backgrounded process starts,
  discovers/rewrites the published loopback endpoint, runs the existing
  `bootstrap_cilium_day1` (validator gate, Helm install, CoreDNS wait) — all
  of this concurrently with the still-running backgrounded create — and only
  then `wait`s on the backgrounded PID and propagates its real exit status
  as the final result. Every failure branch (kubeconfig-fetch timeout,
  port-discovery timeout, Cilium bootstrap failure, or the backgrounded
  create itself failing) kills+waits the child first, then `die`s with state
  left in place; the wrapper marker is written only after that final `wait`
  succeeds. The default `--cni=flannel` path is untouched: it still runs
  `create_cmd`/`kubeconfig_cmd` synchronously exactly as before.
- Test coverage added (`scripts/talos/tests/test-local-cluster-cilium.sh`,
  now 33 assertions, up from 23): extended the `talosctl` stub fixture
  (`scripts/talos/tests/fixtures/local-cluster/talosctl`) to special-case
  `cluster create docker` — it writes the `--talosconfig-destination` file
  immediately (mirroring real talosctl generating config well before its
  health wait), then optionally sleeps
  (`STUB_TALOSCTL_CREATE_SLEEP_SECONDS`) to simulate the blocked health
  wait, then optionally touches a completion sentinel
  (`STUB_TALOSCTL_CREATE_DONE_FILE`) and/or fails
  (`STUB_TALOSCTL_CREATE_FAIL`), independent of the pre-existing generic
  `STUB_TALOSCTL_FAIL`. New assertions: (1) with a 3s simulated create,
  polls `helm.log` and proves the Cilium day-1 Helm phase starts while the
  create-done sentinel does not yet exist — i.e. bootstrap starts before the
  simulated create's CoreDNS-ready completion; (2) proves the create-done
  sentinel file is older than the wrapper marker file (`-ot`) — i.e. the
  backgrounded child is reaped (`wait`ed) strictly before the success marker
  is written; (3) confirms the stub `talosctl cluster create docker`
  invocation is still actually made; (4) with `STUB_TALOSCTL_CREATE_FAIL`,
  confirms Cilium day-1 still bootstraps (Helm invoked) but the backgrounded
  create's failure is what ultimately makes `create` exit non-zero, with a
  diagnostic naming the failure, no wrapper marker, and Talos state
  retained. All pre-existing suites re-verified unaffected: 52/52 in
  `test-local-cluster.sh` (default/flannel path untouched) and 6/6 in
  `test-cilium-handoff.sh`. Ran the full cilium suite 3x back-to-back to
  check for timing flakiness in the new polling-based assertions; stable at
  33/33 each time.
- Docs updated (`docs/en/local-cluster.md`, `docs/pt-br/local-cluster.md`):
  rewrote the "Cilium local mode" step list to describe the async
  background-create/concurrent-bootstrap/final-wait flow and the
  interrupt-reaping behavior, and pointed "Recovering a partially created
  cluster" at the new `<cluster-dir>/create.log`.
- Local validation performed for this cycle (all offline, no live
  Docker/Colima/Talos/Kubernetes/Helm/VMware operation):
  - `bash scripts/talos/tests/test-local-cluster.sh` — 52 passed, 0 failed.
  - `bash scripts/talos/tests/test-local-cluster-cilium.sh` — 33 passed,
    0 failed (run 3x to rule out flakiness in the new timing-based
    assertions).
  - `bash scripts/talos/tests/test-cilium-handoff.sh` — 6 passed, 0 failed.
  - `bash scripts/talos/tests/test-syntax.sh` — 0 failing checks (`bash -n`
    plus `shellcheck`, which now also covers the new `trap`/background-job
    constructs in `local-cluster.sh`).
  - `git diff --check` — clean.
- Known limitations carried over from cycle 0 remain valid (see above); one
  addition: the interrupt/reap path (`SIGINT`/`SIGTERM` during the async
  window) is implemented per the blocker's requirement but is not covered
  by an automated offline test in this cycle — correction item 2 only
  required proving bootstrap-starts-before-create-done and
  child-reaped-before-marker, both of which are now covered; a dedicated
  signal-delivery test was judged likely to be flaky/racy across platforms
  and was left out to avoid expanding scope beyond what was requested.

## Correction cycle 2

- Review verdict on the cycle-1 correction above: `CORRECTIONS_REQUIRED`.
- Blocker addressed: cycle 1's `supervise_cilium_async_create`
  (`scripts/talos/local-cluster.sh`) only reaped the backgrounded
  `talosctl cluster create docker` child in the explicit `if ! cmd; then
  ... fi` failure branches it wrote by hand. An unexpected `set -e` failure
  from an ordinary, unguarded command in between — the reviewer's example
  being the kubeconfig rewrite (`rewrite_kubeconfig_server_endpoint`, an
  unguarded `sed -i` call) — would trip `errexit` and exit the process
  directly, bypassing every one of those hand-written kill/wait blocks and
  leaving the backgrounded process running unsupervised. Replaced the
  scattered kill+wait blocks with a single reusable guard: a new
  `CILIUM_ASYNC_CREATE_PID` global holds the backgrounded PID from the
  moment it is set (`CILIUM_ASYNC_CREATE_PID=$!`, right after backgrounding
  create_cmd) until it is cleared, and a new `cilium_async_reap()` function
  kills+waits whatever PID that global currently holds (no-op if empty).
  `trap cilium_async_reap EXIT` is armed immediately after the background
  job starts, so it fires on *every* non-success exit from that point on —
  an explicit `die`, an unhandled `set -e` failure from any command
  (kubeconfig rewrite included), or an external kill — not just the paths
  the function's own code anticipated. `trap '... EXIT/INT/TERM ...` mirrors
  the same reap plus an explicit `exit 130` for signals specifically (EXIT
  traps alone don't guarantee a non-zero interrupted status). The guard is
  cleared (`CILIUM_ASYNC_CREATE_PID=""`) only immediately after the final,
  successful `wait "${CILIUM_ASYNC_CREATE_PID}"` — i.e. once the child has
  actually been directly reaped by that `wait`, at which point
  `cilium_async_reap` would have nothing left to do anyway; the explicit
  `trap - EXIT INT TERM` right after that removes the guard entirely. Every
  one of the four explicit failure branches (`die` on kubeconfig-fetch
  timeout, port-discovery timeout, Cilium bootstrap failure, and the final
  backgrounded-create failure) was simplified to a plain `die "..."` call,
  since the EXIT trap now handles reaping uniformly instead of each branch
  duplicating it. No state is ever deleted by any of this — only the
  backgrounded process is terminated and reaped. The default `--cni=flannel`
  path never calls any of this and is unaffected (confirmed: `bash -n` and
  `shellcheck` clean, and all 52 `test-local-cluster.sh` assertions for the
  default path still pass unchanged).
- Test coverage added (`scripts/talos/tests/test-local-cluster-cilium.sh`,
  now 38 assertions, up from 33): a new focused case sets
  `STUB_DOCKER_PORT_MAPPING="127.0.0.1#evil:6443"` — the embedded `#` is the
  exact delimiter character `rewrite_kubeconfig_server_endpoint`'s `sed -i
  -E "s#...#...#"` uses, so the substituted replacement breaks the sed
  script's own syntax and `sed` exits non-zero on a real, unmodified
  invocation (verified manually first: BSD `sed` on this host reports `bad
  flag in substitute command: 'e'`, exit 1) — an authentic unexpected
  `set -e` failure, not a simulated one. With `STUB_TALOSCTL_CREATE_SLEEP_SECONDS=5`
  and a `STUB_TALOSCTL_CREATE_DONE_FILE` sentinel, the test asserts: `create`
  exits non-zero; the done-file is absent immediately after `create` returns
  (the child was killed before finishing its simulated 5s wait, not left to
  run to completion); the done-file is *still* absent a further 6s later
  (outliving the stub's full simulated duration — ruling out "it just hadn't
  finished yet" as an explanation and confirming the process was actually
  terminated, not merely still in flight at first check — validated
  manually beforehand with a standalone kill+wait probe against a real
  backgrounded sleeping script, which also never produced its done-file);
  Talos state is retained; no wrapper marker is written. Ran the full
  cilium suite twice back-to-back after adding this timing-sensitive case
  to check for flakiness; stable at 38/38 both times. All pre-existing
  suites re-verified unaffected: 52/52 in `test-local-cluster.sh`, 6/6 in
  `test-cilium-handoff.sh`.
- Local validation performed for this cycle (all offline, no live
  Docker/Colima/Talos/Kubernetes/Helm/VMware operation):
  - `bash scripts/talos/tests/test-local-cluster.sh` — 52 passed, 0 failed.
  - `bash scripts/talos/tests/test-local-cluster-cilium.sh` — 38 passed,
    0 failed (run twice to rule out flakiness in the new timing-based case).
  - `bash scripts/talos/tests/test-cilium-handoff.sh` — 6 passed, 0 failed.
  - `bash scripts/talos/tests/test-syntax.sh` — 0 failing checks (`bash -n`
    plus `shellcheck`, both clean against the reworked trap/guard code).
  - `git diff --check` — clean.
- No documentation changes were needed for this cycle: the async-flow
  description already added in cycle 1 (background create, concurrent
  bootstrap, final wait-and-propagate, interrupt reaping) remains accurate
  — this cycle only closes a gap in *how* reaping is guaranteed, not the
  documented behavior itself.
- Known limitations: unchanged from cycle 1 (see above); the same
  signal-delivery-test scoping note still applies — this cycle's new test
  exercises the EXIT-trap path via an unhandled command failure rather than
  an actual `SIGINT`/`SIGTERM` delivery, which was judged sufficient
  evidence for the guard mechanism itself without adding a
  platform-sensitive signal test.

## Independent review

- Reviewer:
- Exact commit reviewed:
- Diff range:
- Checks rerun:
- Verdict: `APPROVED`
- Corrections requested:
- Follow-up work:

## Owner decision

- Accepted for local `lab`:
- Remote publication authorized:
- Notes:
