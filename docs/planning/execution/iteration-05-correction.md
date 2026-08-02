# Iteration execution record

- Iteration: 05-correction (roadmap: Iteration 5 — local Talos cluster backend)
- Repository: `talos-toolchain`
- Status: `REVIEWED — awaiting owner commit authorization`
- Base branch: `lab`
- Baseline commit: `c6f5536e0d1b67c90f97ed0154859fd2d5e8ad28`
- Working branch: `fix/issue-019-docker-colima-backend`
- Implementer: Claude Code
- Reviewer: Codex
- Optional GitHub issue: [#19](https://github.com/al-rr/talos-toolchain/issues/19)
- Optional pull request: none
- VMware validation: `not required`

## Scope

Correct the Iteration 5 local wrapper so it selects the explicit Talos Docker
container backend with Colima, rather than the deprecated CLI spelling which
redirects to QEMU on the current macOS Talos CLI. Preserve safe state isolation
and teardown guards; document safe recovery of an incomplete attempt without
performing cleanup automatically.

### Files

- `scripts/talos/local-cluster.sh`
- `scripts/talos/tests/test-local-cluster.sh`
- `docs/en/local-cluster.md`
- `docs/pt-br/local-cluster.md`
- this record

### Acceptance criteria

- [x] Dry-run selects the explicit Docker backend and avoids the deprecated
      QEMU redirect.
- [x] Status and destroy command forms match the explicit Docker-created
      cluster and do not rely on an unverified deprecated provisioner flag.
- [x] Colima/Docker remains an operator-managed prerequisite and honors
      `DOCKER_HOST`.
- [x] Offline tests retain state isolation and destructive-action guards.
- [x] EN/PT-BR documentation describes Docker/Colima accurately and contains a
      safe partial-state recovery note.
- [x] No live Docker, Colima, cluster, macOS network, VMware, or credential
      operation is performed by the implementation.

## Implementation handoff

- Implementation commits: none (uncommitted working-tree changes only; no
  commit was authorized by the owner).
- Uncommitted changes included:
  - `scripts/talos/local-cluster.sh`: `do_create` now builds
    `talosctl cluster create docker` (explicit Docker backend subcommand)
    instead of the deprecated `talosctl cluster create --provisioner docker`,
    and uses `--talosconfig-destination` instead of the removed `--talosconfig`
    flag on that subcommand. Added `require_docker_controlplanes_supported`,
    called from `do_create`, which rejects any `--controlplanes` value other
    than `1` before talosctl is invoked (the Docker backend subcommand has no
    control-plane-count flag and always creates exactly one). `do_status`'s
    `talosctl cluster show` invocation dropped the unsupported `--talosconfig`
    flag (current `talosctl cluster show --help` accepts `--provisioner` but
    not `--talosconfig`) while keeping `--provisioner docker`. `do_destroy`'s
    `talosctl cluster destroy` invocation dropped the unsupported
    `--provisioner docker` flag (current `talosctl cluster destroy --help`
    accepts neither `--provisioner` nor `--talosconfig`); both now pass only
    `--name`/`--state`.
  - `scripts/talos/tests/test-local-cluster.sh`: updated the dry-run
    assertions to expect `talosctl cluster create docker` and
    `--talosconfig-destination`, added an explicit assertion that the
    deprecated `--provisioner docker`/`cluster create dev` forms never
    appear, and added two new cases covering `--controlplanes=3` (rejected,
    no talosctl call made) and `--controlplanes=1` (accepted). Added a
    `status --dry-run` case asserting `--provisioner docker` is present and
    `--talosconfig` is absent from the `cluster show` invocation, and a
    `destroy --dry-run` case asserting `--provisioner` is absent from the
    `cluster destroy` invocation.
  - `docs/en/local-cluster.md` / `docs/pt-br/local-cluster.md`: documented the
    explicit Docker subcommand and the QEMU-redirect reason for avoiding the
    old spelling, documented the fixed one-control-plane behavior of the
    Docker backend and the new validation, and added a paired "Recovering a
    partially created cluster" / "Recuperando um cluster criado parcialmente"
    section describing manual-only recovery.
- Local validation performed:
  - `/opt/homebrew/bin/bash scripts/talos/tests/test-local-cluster.sh` — 52
    passed, 0 failed.
  - `/opt/homebrew/bin/bash scripts/talos/tests/test-syntax.sh` — `bash -n`
    over all maintained entrypoints plus `shellcheck`, 0 failing checks.
  - `git diff --check` — clean.
  - Inspected `talosctl cluster create --help`, `talosctl cluster create
    docker --help`, `talosctl cluster show --help`, and `talosctl cluster
    destroy --help` (installed `talosctl v1.13.7`, help output only) to
    confirm the docker subcommand's supported flags and that `show`/`destroy`
    flag names were unaffected.
  - No live `create`, `destroy`, Docker, Colima, QEMU, network, VMware, or
    credential command was run. The pre-existing live state from the prior
    failed attempt was not read, changed, or deleted.
- Known limitations:
  - `--controlplanes` remains a wrapper-level flag (default `1`) for
    symmetry with `cluster.sh`, but any value other than `1` is now rejected
    rather than silently dropped, since the Docker backend never supported
    scaling control planes.

## Independent review

- Reviewer: Codex
- Exact commit reviewed: working tree on
  `fix/issue-019-docker-colima-backend` based on
  `c6f5536e0d1b67c90f97ed0154859fd2d5e8ad28`
- Diff range: `c6f5536..working-tree`
- Checks rerun: local-cluster offline suite (52 passed), syntax/ShellCheck,
  and `git diff --check`.
- Verdict: `APPROVED`
- Corrections requested: none.
- Follow-up work: after merge, owner manually recovers the existing markerless
  partial state, then creates the Docker/Colima cluster.

## Owner decision

- Accepted for local `lab`:
- Remote publication authorized:
- Notes:
