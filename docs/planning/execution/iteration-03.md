# Iteration 03 — macOS Bash 5 preflight contract

- Iteration: 3
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

- `scripts/talos/` supported entrypoints and a new shared Bash-version/preflight
  helper, as determined by the approved implementation plan.
- Focused offline test fixture(s) for the shell contract.
- `README.md`, `docs/en/`, and matching `docs/pt-br/` operator guidance.
- This execution record.

### Acceptance criteria

- [x] An invocation under macOS Bash 3.2 reaches an actionable Bash 5 failure
  or an explicitly located/re-executed Bash 5 before incompatible logic runs.
- [x] The supported Bash 5 path retains action and argument handling.
- [x] Required command checks are diagnostic-only and make no host changes.
- [x] Offline syntax, preflight, and compatibility tests pass without Talos,
  Docker/Colima, Kubernetes, VMware, or network operations.
- [x] Script internals and CLI output are English; EN/PT-BR operator guidance
  is consistent.
- [x] No change is made to `provision-talos-vsphere` or
  `talos-vsphere-gitops`.

## Implementation handoff

- Implementation commits: pending; commits are not authorized.
- Uncommitted changes included:
  - `scripts/talos/lib/bash-preflight.sh` (new): Bash-3.2-parseable
    `talos_require_bash5` (version check, fixed-path Homebrew Bash 5
    candidate search, guarded re-exec with `PATH` prepend, actionable error)
    and `talos_require_commands` (diagnostic-only missing-CLI report).
  - `scripts/talos/cluster.sh`: sources and calls `talos_require_bash5`
    before sourcing `lib/common.sh`; adds `preflight_cli_for_action` invoked
    in `main()` before dispatch, mapping each action to the external
    commands it needs (`talosctl`, `govc`, `kubectl`, `helm`, `curl`).
  - `scripts/talos/talos-gitops.sh`: same preflight wiring; adds
    `preflight_cli_for_action` for its four actions; replaces the GNU-only
    `find -printf '%f\n'` addon-discovery call with a portable
    `find -exec basename {} \;` equivalent (same output, no BSD/macOS `find`
    dependency change in behavior).
  - `scripts/talos/tests/test-bash-preflight.sh` (new): 14 offline
    assertions covering the pure version-comparison logic (majors 3/4/5/6/
    empty), `talos_require_commands` success/failure/message content, a
    guarded re-exec against a fixture "Bash 5" executable
    (`tests/fixtures/fake-bash5`) verified via a marker file, the
    no-candidate actionable-error path, and the re-exec loop guard.
  - `scripts/talos/tests/test-syntax.sh` (new): `bash -n` over all
    `scripts/talos/` entrypoints and libraries plus ShellCheck scoped to the
    files this iteration changed (pre-existing warnings in untouched files
    such as `lib/common.sh`, `cluster-bootstrap.sh`, `govc/provision-cluster.sh`,
    `vars.sh` are out of scope and left as-is).
  - `scripts/talos/tests/fixtures/fake-bash5` (new): non-Bash test double
    used only by the test harness; never referenced by production code.
  - `README.md`, `docs/en/README.md`, `docs/en/shell-requirements.md`,
    `docs/pt-br/README.md`, `docs/pt-br/shell-requirements.md`: document the
    Bash 5/macOS contract, the fixed candidate paths, the CLI preflight, and
    that Docker/Colima remains a later iteration.
  - This execution record.
- Local validation performed: baseline/branch verification (clean checkout
  of `fix/issue-007-macos-bash-preflight` at `723b3845ba826f0c78ae8eecc47e75c91af3c03f`,
  the only pre-existing untracked file was this record); static inventory of
  Bash 5-only constructs (`mapfile`, `declare -A`, `${var,,}`) and GNU-only
  utility invocations (`find -printf`, `readlink -f`, `timeout`) across
  `scripts/talos/`; confirmed the two maintained entrypoints (`cluster.sh`,
  `talos-gitops.sh`) are the only scripts invoked directly by an operator —
  the rest are dispatched by them as child processes and inherit the
  re-exec's `PATH` fix via their own `#!/usr/bin/env bash` shebang.
- Commands run:
  - `bash scripts/talos/tests/test-bash-preflight.sh` — 14 passed, 0 failed.
  - `bash scripts/talos/tests/test-syntax.sh` — `bash -n` over 13 scripts
    (all pass under the host's Bash 3.2) plus ShellCheck on the 3 changed
    files (pass, one intentional inline-disabled `SC2016`).
  - `bash scripts/talos/cluster.sh --help` and
    `bash scripts/talos/talos-gitops.sh --help` under the host's stock
    Bash 3.2 — both now stop at the preflight with the actionable Bash 5
    error instead of reaching later Bash-5-only code.
- Not run: any real re-exec under an actual Homebrew Bash 5 (none installed
  on this host), and any Talos/Kubernetes/Helm/VMware/govc operation
  (excluded by the iteration's non-goals and unavailable/unauthorized here).
- Known limitations: this host has `/bin/bash` 3.2 and ShellCheck, but no
  Bash 5 or Bats. The implementation does not install them; the re-exec path
  is verified with a non-Bash fixture executable standing in for a Bash 5
  candidate, and the version-comparison logic is tested directly with
  synthetic version majors. `timeout`, used by `cluster-bootstrap.sh` and
  `govc/provision-cluster.sh` for VMware/network waits, remains GNU-only and
  unreplaced: it is invoked only inside provisioning code paths out of this
  iteration's scope (no VMware execution here), and is not on this host
  either; a future iteration should decide whether to add it to the CLI
  preflight's required-command list or provide a portable wrapper.

## Independent review

- Reviewer: Codex
- Exact commit reviewed: pending implementation.
- Diff range: `723b3845ba826f0c78ae8eecc47e75c91af3c03f...fix/issue-007-macos-bash-preflight`
- Checks rerun: pending.
- Verdict: `PENDING`
- Corrections requested: pending.
- Follow-up work: Iteration 4 environment configuration; Iteration 5 local
  Docker/Colima backend only after this contract is accepted.

## Owner decision

- Accepted for local `lab`: pending independent review and explicit owner
  authorization for a commit.
- Remote publication authorized: no.
- Notes: no tags, VMware, credential, or destructive operations are in scope.

## Corrective independent review

- Operational run: 013, linked to the same issue and working branch because
  the original run exhausted its permitted correction attempts while Claude
  authentication was unavailable inside the sandbox.
- Reviewer: Codex.
- Result: `APPROVED`. The missing CLI version/compatibility contract is now
  documented in matching EN/PT-BR guides. The first corrective wording
  incorrectly constrained Helm to 3.x; the bounded follow-up removed that
  unsupported major pin, and the final rule requires only Helm/Kubernetes
  compatibility per Helm's own support matrix.
- Checks rerun: `git diff --check`; 14 preflight assertions; syntax checks for
  13 scripts; scoped ShellCheck; and clean status in the two non-owning
  repositories.
- Commit, push, PR, merge, and tag remain unapproved.
