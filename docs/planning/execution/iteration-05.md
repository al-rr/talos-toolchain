# Iteration 05 — YAML style and CI

- Iteration: 5
- Repository: `talos-toolchain`
- Status: `IMPLEMENTED — awaiting Codex review`
- Base branch: `lab`
- Baseline commit: `077673006c93848ee7dea5bec1a964a11ca81d8e`
- Working branch: `feat/issue-011-yaml-lint-ci`
- GitHub issue: [#11](https://github.com/al-rr/talos-toolchain/issues/11)
- Implementer: `Claude Code` after plan approval and explicit authorization
- Reviewer: `Codex`

## Goal

Establish a versioned YAML style policy that developers can run locally and
GitHub Actions enforces against the same tracked YAML scope.

## Initial impact analysis

- `talos-toolchain`: owner and only repository changed. It already tracked
  four `.github/ISSUE_TEMPLATE/*.yml` files but had no lint policy or GitHub
  workflow, so this iteration establishes the first reusable lint/CI
  baseline covering those files plus the new workflow YAML itself.
- `provision-talos-vsphere`: unchanged; VMware adapter and Milestone B work
  remain out of scope.
- `talos-vsphere-gitops`: unchanged; it owns Kubernetes/Argo desired state,
  not this toolchain's CI.

## Proposed acceptance criteria

- A versioned `.yamllint` configuration states the selected rules.
- A local command validates tracked `.yaml`/`.yml` files with that config and
  emits an actionable missing-tool error.
- GitHub Actions runs the same command for `push` and `pull_request` using
  least-privilege permissions.
- EN/PT-BR guidance explains install and use.
- Existing offline checks remain green.

## Approved implementation approach

1. Version a narrowly tailored `.yamllint.yaml` policy at the repository root.
2. Add an offline local entrypoint that passes only Git-tracked YAML files to
   `yamllint` with that policy and fails clearly when the tool is absent.
3. Add a least-privilege GitHub Actions workflow for push and pull request
   events that installs an explicit `yamllint` version and invokes that same
   local entrypoint.
4. Document local installation/use and CI behavior in EN/PT-BR, then rerun
   style and existing offline checks.

## Implementation result

- `.yamllint.yaml`: extends yamllint's `default` ruleset with three narrow
  relaxations (`line-length: 160` for long issue-form dropdown option
  arrays, `document-start: {present: false}` matching this repo's
  no-leading-`---` convention, and `truthy: {check-keys: false}` so the bare
  `on:` GitHub Actions key is not flagged).
- `scripts/talos/tests/test-yaml-style.sh`: new offline entrypoint. Requires
  `yamllint` on `PATH` (actionable install message and exit 1 otherwise),
  discovers the tracked `*.yaml`/`*.yml` set via `git ls-files`, exits 0
  with `[SKIP]` on an empty set, and otherwise lints with the versioned
  config. Uses a portable `while read` loop instead of `mapfile` so it also
  runs under macOS's stock Bash 3.2, consistent with the other test scripts
  in this directory.
- `.github/workflows/yaml-style.yml`: runs on `push` and `pull_request` with
  `permissions: contents: read`; pins `actions/checkout@fbc6f39...` (v5.1.0)
  and `actions/setup-python@a26af69...` (v5.6.0) by commit SHA; installs
  `yamllint==1.38.0`; invokes the same local script (no duplicate lint
  command or CI-only policy).
- `docs/en/yaml-style.md` / `docs/pt-br/yaml-style.md`: paired guidance on
  purpose, policy rationale, local install/use, and CI behavior; both
  README indices updated to link the new guide.
- Verified locally with `yamllint` installed in a throwaway virtualenv
  (kept outside the repository and outside system/Homebrew Python):
  `test-yaml-style.sh`, `test-syntax.sh`, `test-yaml-config.sh`, and
  `test-bash-preflight.sh` all pass; `git diff --check` is clean; the new
  `.yamllint.yaml` and workflow file self-lint cleanly under the same
  policy.
- No commit, push, or PR was made; no network, VMware, Docker/Colima, or
  credential operation was performed beyond resolving public GitHub Actions
  tag-to-SHA mappings and installing `yamllint` into a local scratch
  virtualenv for verification.
