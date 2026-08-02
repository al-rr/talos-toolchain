# YAML Style

## Purpose

Every tracked `*.yaml`/`*.yml` file in this repository (currently the
`.github/ISSUE_TEMPLATE/` forms and `.github/workflows/`) is checked against
a single, versioned [`yamllint`](https://yamllint.readthedocs.io/) policy so
style stays consistent as the repository's YAML footprint grows.

## Policy

The policy lives at the repository root in `.yamllint.yaml`. It extends
yamllint's `default` ruleset and relaxes only what this repository's real
files require:

- `line-length`: raised to 160 to accommodate the long single-line option
  arrays used by GitHub issue-form dropdowns.
- `document-start`: requires that files **not** use a leading `---` marker,
  matching this repository's existing issue-form and workflow files.
- `truthy`: does not flag map keys, so the bare `on:` GitHub Actions trigger
  key is not treated as a boolean value.

No rule is disabled wholesale.

## Local usage

Install `yamllint` (any one of):

```bash
pipx install yamllint
pip install --user yamllint
brew install yamllint
```

Run the check:

```bash
bash scripts/talos/tests/test-yaml-style.sh
```

The script lints only Git-tracked `*.yaml`/`*.yml` files with the versioned
policy above. It exits non-zero with an actionable install message if
`yamllint` is not on `PATH`, and exits 0 with a `[SKIP]` message if the
repository has no tracked YAML files at all. It performs no network,
Talos, Kubernetes, Helm, or VMware operation.

## CI

`.github/workflows/yaml-style.yml` runs the same
`scripts/talos/tests/test-yaml-style.sh` command on `push` and
`pull_request`, so local and CI results never diverge. The workflow requests
only `contents: read` permission and pins `actions/checkout` and
`actions/setup-python` to a specific commit SHA.
