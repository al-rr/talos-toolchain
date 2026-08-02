#!/usr/bin/env bash
# @file test-yaml-style.sh
# @brief Offline yamllint style check for tracked YAML files.
# @description
#   Lints every Git-tracked `*.yaml`/`*.yml` file against the versioned
#   `.yamllint.yaml` policy at the repository root. Requires `yamllint` on
#   PATH and fails with an actionable install message if it is missing.
#   Runs no Talos, Kubernetes, Helm, VMware, or network operation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
YAMLLINT_CONFIG="${REPO_ROOT}/.yamllint.yaml"

if ! command -v yamllint >/dev/null 2>&1; then
  echo "[FAIL] yamllint is not installed or not on PATH." >&2
  echo "Install it with one of:" >&2
  echo "  pipx install yamllint" >&2
  echo "  pip install --user yamllint" >&2
  echo "  brew install yamllint" >&2
  exit 1
fi

if [[ ! -f "${YAMLLINT_CONFIG}" ]]; then
  echo "[FAIL] Missing yamllint config: ${YAMLLINT_CONFIG}" >&2
  exit 1
fi

cd "${REPO_ROOT}"

YAML_FILES=()
while IFS= read -r yaml_file; do
  YAML_FILES+=("${yaml_file}")
done < <(git ls-files -- '*.yaml' '*.yml')

if [[ "${#YAML_FILES[@]}" -eq 0 ]]; then
  echo "[SKIP] No tracked *.yaml/*.yml files found."
  exit 0
fi

echo "yamllint: $(yamllint --version)"
echo "Linting ${#YAML_FILES[@]} tracked YAML file(s) with ${YAMLLINT_CONFIG}"

if yamllint --config-file "${YAMLLINT_CONFIG}" -- "${YAML_FILES[@]}"; then
  echo "[PASS] yamllint"
else
  echo "[FAIL] yamllint"
  exit 1
fi
