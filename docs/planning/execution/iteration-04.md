# Iteration 04 — YAML Talos environment configuration

- Iteration: 4
- Repository: `talos-toolchain`
- Status: `CORRECTIONS_APPLIED (cycle 2, local review pending)`
- Base branch: `lab`
- Baseline commit: `d397c9b9fd5988f8a5fafa028589472e43f8c555`
- Working branch: `feat/issue-009-environment-config`
- Implementer: `Claude Code`
- Reviewer: `Codex`
- GitHub issue: [#9](https://github.com/al-rr/talos-toolchain/issues/9)
- Optional pull request: not authorized
- VMware validation: not required

## Accepted design

Environment configuration is YAML data, not sourced shell. The initial layout
uses `base/config.yaml`, `environments/<name>/config.yaml`, and protected
`environments/<name>/credentials.yaml` beneath XDG configuration. `vars.sh`
and `vars.local.sh` remain a temporary compatibility interface only, subject to
the same ownership/type/permission checks before sourcing.

## Scope

- Secure YAML bootstrap, loading, schema validation, precedence, and redacted
  diagnostics in `talos-toolchain`.
- Neutral project scaffold and focused offline tests using temporary XDG paths.
- Paired EN/PT-BR operator documentation and this execution record.

## Acceptance criteria

- [x] YAML config and credentials are loaded only after secure file checks.
- [x] Directories use `0700`; credentials use `0600`; bootstrap is idempotent.
- [x] Unknown/type-invalid YAML and unsafe legacy shell files are rejected.
- [x] Precedence is defaults, base, project intent, environment, credentials,
  then CLI flags.
- [x] No concrete site defaults or credentials are scaffolded.
- [x] Offline tests pass without network, Docker/Colima, VMware, or secrets.
- [x] `provision-talos-vsphere` and `talos-vsphere-gitops` remain unchanged.

## Implementation summary

- Added `scripts/talos/lib/yaml-config.sh`: XDG path helpers, secure
  file/directory checks (current-user ownership, no symlinks, `0700`
  directories, `0600` credentials, no group/world-writable config), an
  allowlisted schema (`TALOS_CONFIG_SCHEMA_TABLE` /
  `TALOS_CONFIG_SECRET_SCHEMA_TABLE`) validated via `yq` against leaf paths
  and types, idempotent bootstrap, precedence-ordered load/export
  (defaults < base < tracked project intent < environment < credentials,
  CLI flags applied by the caller last), and redacted diagnostics. The
  table-based schema (rather than Bash 4+ associative arrays/namerefs) is a
  deliberate choice: this host has no Homebrew Bash 5 installed and
  installing one requires network access outside this iteration's scope, so
  a Bash-3.2-runnable implementation was the only way to actually execute
  the test suite rather than trust untested Bash-5-only code.
- Added `scripts/talos/config.sh`: `bootstrap`/`show` entrypoint.
- Integrated the loader into `cluster.sh`: new `--environment=<name>` flag
  (default: project/cluster name), YAML config loads before the legacy
  `vars.sh`/`vars.local.sh` source step, and both legacy files now pass
  through the same secure-source check before being sourced.
- Neutralized `cluster.sh create-project` scaffolding: `vars.sh`,
  `vars.local.example.sh` no longer bake in concrete vSphere/SSH/network
  values; the project now also scaffolds a tracked, non-secret
  `config.yaml` for the project-intent precedence layer.
- Added `scripts/talos/tests/test-yaml-config.sh` (22 assertions: bootstrap
  idempotency/force, secure-check rejections, schema rejections/acceptance,
  precedence, redaction) and registered the new files in
  `tests/test-syntax.sh`.
- Added `docs/en/environment-config.md` + `docs/pt-br/environment-config.md`
  and cross-linked them from `day1-project-vars.md` and both docs READMEs.

## Deviations from the plan

- The schema uses flat `path|ENV_VAR|type` tables instead of Bash 4+
  associative arrays/namerefs, for the reason above. Functionally
  equivalent; still Bash-5-compatible.

## Correction cycle 1

Review verdict `CORRECTIONS_REQUIRED`; all five blockers addressed in
`scripts/talos/lib/yaml-config.sh`, `scripts/talos/config.sh`, and
`scripts/talos/cluster.sh`:

1. **Environment name validation.** Added
   `talos_config_validate_env_name`/`talos_config_require_valid_env_name`
   (`^[A-Za-z0-9][A-Za-z0-9._-]*$`), enforced eagerly (as a plain statement,
   not inside a command substitution — see the note below) in
   `talos_config_env_dir`, `talos_config_env_file`,
   `talos_config_credentials_file`, `talos_config_bootstrap`,
   `talos_config_load`, `talos_config_show_redacted`, and at the `config.sh`
   and `cluster.sh` CLI boundaries. Regression tests cover empty, `.`, `..`,
   slash-containing, and traversal-shaped names, and assert no filesystem
   entry is created outside the XDG tree.
   - Found and fixed a related latent bug while adding these tests:
     `path="$(some_validating_fn ...)"` swallows a `die`/`exit` from inside
     the command substitution (bash does not apply `set -e` to the
     assignment statement itself), so an invalid name could silently
     continue with an empty path instead of aborting. Fixed by calling the
     validator as a bare statement before any such assignment in every
     affected function.
2. **Bootstrap refuses unsafe pre-existing state.** Added
   `_talos_config_bootstrap_dir`/`_talos_config_bootstrap_file`: any
   pre-existing symlink, wrong-type entry, or entry failing the secure
   check is refused before any `chmod`/write; `--force` only overwrites a
   file that has already passed the secure check. Idempotency for
   already-valid files is preserved (existing tests still pass unmodified).
   New tests attack both a directory and a file path with a symlink
   (including under `--force`) and assert the attack target is never
   chmod'd or written through.
3. **Stricter schema validation.** `talos_config_validate_schema` now walks
   every node (not only scalar leaves) via `yq eval '.. | select(path |
   length > 0) | ...'`, classifying each path as a known leaf (must be a
   scalar of the exact declared type; `null`/float/map/seq are all
   rejected), a known namespace prefix (must be a mapping, empty or not),
   or unknown (always rejected, regardless of emptiness). New fixtures
   cover an unknown empty map, an empty list at a scalar leaf, `null` at a
   leaf and at a namespace, and a float where an int is expected; existing
   generated defaults are asserted to still validate.
4. **Precedence in the real `cluster.sh` flow.** `main()` now sources
   legacy `vars.sh`/`vars.local.sh` first (still through the secure-source
   check) and calls `talos_config_load` afterward, so the YAML
   environment/credentials layers always win over legacy values. A new
   integration-style regression in `test-yaml-config.sh` reproduces this
   exact sequence and asserts the YAML value wins.
5. **`yq` required early, no silent skip.** Replaced the
   `command -v yq || log_warn` soft-skip in `cluster.sh` with
   `talos_config_require_yq` (the same actionable failure the YAML tooling
   already uses), for every action except `create-project`, which stays
   fully offline/`yq`-independent (verified manually: `create-project
   --dry-run` succeeds with `yq` absent from `PATH`; `generate` fails with
   the actionable message under the same condition).

Docs (`docs/en/environment-config.md`, `docs/pt-br/environment-config.md`)
updated to describe the corrected precedence order, `yq` requirement,
environment-name validation, and bootstrap/schema hardening. Schema scope
was not broadened.

## Correction cycle 2

Review verdict `CORRECTIONS_REQUIRED`; both blockers addressed in
`scripts/talos/lib/yaml-config.sh`:

1. **Malformed YAML must unambiguously fail schema validation.**
   `talos_config_validate_schema` previously fed `yq`'s output into the
   parsing loop via `done < <(yq eval ...)` — a process substitution whose
   exit status the consuming `while` loop never checks. On a YAML parse
   error, `yq` writes its error to stderr and produces no stdout, so the
   loop body never runs, `failures` stays at `0`, and the malformed file was
   silently accepted. Fixed by capturing `yq`'s output via command
   substitution instead (`yq_output="$(yq eval ... 2>&1)" || yq_status=$?`),
   checking `yq_status` explicitly, and returning failure immediately (with
   an actionable message) before the parsing loop ever runs. A new
   malformed-YAML fixture (an unterminated quoted scalar) proves both
   `talos_config_validate_schema` and `talos_config_load` reject it, and
   that `talos_config_load` exports nothing from it.
2. **Toolchain-managed XDG ancestors are now part of the secure boundary.**
   Previously only `base/` and `environments/<name>/` were secured;
   `mkdir -p` on those paths would silently traverse through the
   `talos-toolchain` root and its `environments` parent even if either had
   been swapped for a symlink. Added
   `talos_config_check_ancestor_secure_if_present` and
   `talos_config_require_secure_ancestors`: `talos_config_bootstrap` now
   checks/creates all four levels — root, `environments/`, `base/`,
   `environments/<name>/` — in that order (root-first, so a deeper
   `mkdir -p` is never the first thing to touch an unverified shallower
   ancestor), refusing before any `mkdir -p`/`chmod`/write if a
   pre-existing entry at any level is a symlink or otherwise unsafe.
   `talos_config_load` now refuses to read anything if the root or
   `environments/` parent is present but unsafe, closing the gap where a
   leaf file could individually pass its own secure-file check while being
   reached only through a swapped-in ancestor symlink. Two new test
   scenarios attack the root and the `environments/` parent respectively
   with a symlink to an external, differently-permissioned directory, and
   assert bootstrap refuses, never chmods/writes into the external target,
   and `talos_config_load` also refuses to read through it.

Docs updated (EN/PT-BR) to describe the ancestor security boundary and the
malformed-YAML rejection behavior. Schema scope was not broadened; all
changes stayed within `scripts/talos/lib/yaml-config.sh` and
`scripts/talos/tests/test-yaml-config.sh` — no changes were needed to
`cluster.sh` or `config.sh` for this cycle.

## Commands run

- `bash -n` on all changed/added shell files (pass).
- `shellcheck` on `lib/yaml-config.sh`, `config.sh`, `cluster.sh` (pass, no
  findings).
- `bash scripts/talos/tests/test-yaml-config.sh` (initial implementation: 22
  passed, 0 failed; after correction cycle 1: 56 passed, 0 failed; after
  correction cycle 2: 68 passed, 0 failed).
- `bash scripts/talos/tests/test-syntax.sh` (all targets pass).
- `bash scripts/talos/tests/test-bash-preflight.sh` (14 passed, 0 failed,
  pre-existing, unaffected).
- Manual end-to-end checks against a temporary `XDG_CONFIG_HOME`, with the
  `talos_require_bash5` preflight call stripped from throwaway copies of
  `config.sh`/`cluster.sh` (this host has no Homebrew Bash 5 installed; real
  `talosctl`/`govc`/network-touching actions were not exercised):
  - `config.sh bootstrap`/`show` end-to-end.
  - `cluster.sh create-project --dry-run` with `yq` absent from `PATH`
    succeeds (stays `yq`-independent).
  - `cluster.sh generate --dry-run` with `yq` absent from `PATH` fails with
    the actionable "yq is required" message (no silent skip).
  - `cluster.sh`'s corrected load order (source legacy `vars.sh`, then
    `talos_config_load`) resolves `TALOS_CLUSTER_NAME` to the YAML
    environment value, not the legacy value.

## Known environment gap

This development host has no Homebrew Bash 5 installed
(`/opt/homebrew/bin/bash` etc. are absent), so `cluster.sh`/`config.sh`
cannot be run directly end-to-end here — their `talos_require_bash5`
preflight correctly refuses and exits. This matches the portability gap
already tracked in the repository root `CLAUDE.md`. Verification instead
combined `bash -n`/`shellcheck` on the real entrypoints, full execution of
the shared library under this host's Bash 3.2 (hence the flat-table schema
choice), and manual end-to-end runs against copies with only the version
preflight call removed.
