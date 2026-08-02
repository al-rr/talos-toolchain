# Iteration 07 — Isolated local Talos Docker/Colima lifecycle

- Status: `CLAUDE_COMPLETED (correction cycle 1) — awaiting Codex review`
- Repository: `talos-toolchain`
- Base branch: `lab`
- Baseline: `9573ef2`
- Branch: `feat/issue-015-local-talos-backend`
- Issue: [#15](https://github.com/al-rr/talos-toolchain/issues/15)
- Implementer: Claude Code
- Reviewer: Codex (pending)

## Decision

Use a dedicated `local-cluster.sh` wrapper for the local Docker backend. It
owns its local state contract and does not route through the existing
vSphere-oriented `cluster.sh`; this avoids silently mixing the Milestone-A
local path with VMware variables or destructive behavior.

## Impact analysis

- `talos-toolchain`: only runtime owner and only repository changed.
- `provision-talos-vsphere`: unchanged; VMware adapter remains Milestone B.
- `talos-vsphere-gitops`: unchanged; GitOps revision correction is a later,
  separate iteration.

## Proposed acceptance criteria

- Dedicated create/status/destroy lifecycle with explicit XDG-local state.
- Preflight diagnoses but never starts/configures Colima.
- Create/status/destroy are guarded by safe cluster-name and marker checks;
  destroy requires explicit confirmation and supports dry-run.
- Offline fixture tests cover paths, arguments, diagnostics, and teardown
  refusals without starting Docker/Colima/Talos.
- EN/PT-BR documentation accurately states limitations and live validation is
  left to an explicitly authorized operator command.

## Implementation summary

- Added `scripts/talos/local-cluster.sh` (`create`/`status`/`destroy`),
  isolated per-cluster paths under
  `${XDG_STATE_HOME:-$HOME/.local/state}/talos-toolchain/local-clusters/<name>/`
  (`talos-state/`, `talosconfig`, `kubeconfig`, wrapper marker file),
  Bash-5 preflight, and `talosctl`/`docker`/`colima` presence checks.
  `create`/`status` diagnose Docker daemon reachability (`docker info`) and
  Colima state (`colima status`) but never start or reconfigure either.
- Cluster names are validated against `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`
  before any path is built, rejecting traversal (`..`, `/`) and unsafe
  characters. `destroy` only acts on a directory carrying this wrapper's own
  marker file and matching recorded name, and requires `--confirm-destroy`
  in addition to `--dry-run` support on all three actions.
- Added offline fixture tests: `scripts/talos/tests/test-local-cluster.sh`
  plus stub `talosctl`/`docker`/`colima` executables under
  `scripts/talos/tests/fixtures/local-cluster/`. 29/29 assertions pass; no
  real Docker daemon, Colima instance, network, or VMware action is invoked.
  Registered `local-cluster.sh` in `scripts/talos/tests/test-syntax.sh`
  (`bash -n` + ShellCheck targets).
- Added `docs/en/local-cluster.md` and `docs/pt-br/local-cluster.md`, linked
  from both `docs/en/README.md`/`docs/pt-br/README.md`, and updated the
  stale "not implemented yet" Docker/Colima notes in both README local-first
  boundary sections and both `shell-requirements.md` files.

### Commands run

- `bash scripts/talos/tests/test-local-cluster.sh` — 29 passed, 0 failed.
- `bash scripts/talos/tests/test-bash-preflight.sh` — 16 passed, 0 failed
  (pre-existing, unaffected).
- `bash scripts/talos/tests/test-syntax.sh` — all `bash -n` + ShellCheck
  targets pass, including the new `local-cluster.sh`.
- `bash scripts/talos/tests/test-yaml-config.sh` — 68 passed, 0 failed
  (pre-existing, unaffected; no YAML files were touched this iteration).
- `bash scripts/talos/tests/test-yaml-style.sh` — not run: `yamllint` is not
  installed on this host. No YAML files were added or changed this
  iteration, so this is a pre-existing environment gap, not a regression.
- `git diff --check` — clean.

### Deviations from the plan

- None. Scope stayed within `talos-toolchain`; `provision-talos-vsphere` and
  `talos-vsphere-gitops` were not touched.

### Risks / remaining work

- `local-cluster.sh` was never run against a real `talosctl`/Docker/Colima
  stack (prohibited for this iteration); an operator should dry-run then
  run `create`/`destroy` for real once authorized, to validate the actual
  `talosctl cluster create --provisioner docker` / `talosctl kubeconfig` /
  `talosctl cluster destroy` flag surface against an installed `talosctl`
  version.
- `yamllint` is not installed on this host, so `test-yaml-style.sh` could
  not be exercised end-to-end this iteration (pre-existing gap, unrelated to
  this change).

## Correction cycle 1

Review verdict: `CORRECTIONS_REQUIRED`. Blockers addressed in
`scripts/talos/local-cluster.sh` and `scripts/talos/tests/test-local-cluster.sh`
(both already `accepted` in the correction baseline; the fixtures directory
was already `extended`):

- **`--state-root` validation** (`require_safe_state_root`): now rejects a
  non-absolute path, `/` itself, and any path containing a `..` segment
  (even inside an otherwise-absolute path, e.g.
  `/state-root/sub/../../escape`). Applied uniformly to both an explicit
  override and the resolved default XDG path, so the default's behavior is
  unchanged.
- **Filesystem-aware containment** (`require_state_tree_safe`,
  `require_dir_safe_if_present`, `require_file_safe_if_present`,
  `require_not_symlink_if_present`): before any action reads, writes, passes
  `--state`, or removes managed state, every managed path (state root, its
  parent when using the default XDG layout, cluster directory, Talos state
  directory, talosconfig, kubeconfig, wrapper marker) is checked for
  symlink-ness and expected node type. This runs alongside, not instead of,
  the existing lexical `require_cluster_dir_contained` prefix check.
- **Ordering**: `require_state_tree_safe` runs immediately after path
  resolution in `do_create`/`do_status`/`do_destroy`, before any
  mkdir/read/talosctl invocation. `create`'s `mkdir -p` still only runs after
  this validation and only in the non-dry-run branch. `status`/`destroy`
  create no paths (unchanged). `destroy` re-validates the cluster directory
  a second time (`require_dir_safe_if_present`) immediately before `rm -rf`,
  as a TOCTOU guard between the `talosctl cluster destroy` call and removal.
- **New offline fixture tests** added to `test-local-cluster.sh` (16 new
  assertions, 45/45 total passing): `--state-root=/`, a relative
  `--state-root`, two `..`-traversal-shaped absolute roots, a symlinked state
  root, and a symlinked cluster directory — each exercised against
  `create`/`status`/`destroy`, asserting rejection, zero stub `talosctl`
  invocations, and an untouched attack-target sentinel file/marker.

### Commands re-run after the correction

- `bash scripts/talos/tests/test-local-cluster.sh` — 45 passed, 0 failed (all
  29 prior assertions preserved, 16 new).
- `shellcheck scripts/talos/local-cluster.sh scripts/talos/tests/test-local-cluster.sh` — clean.
- `bash scripts/talos/tests/test-syntax.sh` — all `bash -n` + ShellCheck
  targets pass.
- `bash scripts/talos/tests/test-bash-preflight.sh` — 16 passed, 0 failed
  (unaffected).
- `bash scripts/talos/tests/test-yaml-config.sh` — 68 passed, 0 failed
  (unaffected; no YAML touched).
- `git diff --check` — clean.

No live Docker/Colima/Talos validation was performed; no other repository
was touched; no commit/push/PR/merge was made.
