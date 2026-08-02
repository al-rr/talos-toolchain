#!/usr/bin/env bash
# @file test-syntax.sh
# @brief Offline syntax and (optional) ShellCheck pass for maintained entrypoints.
# @description
#   Runs `bash -n` under whatever Bash is on PATH (the declared Bash 5 when
#   available, the host's Bash otherwise) and, if installed, ShellCheck.
#   No Talos, Kubernetes, Helm, or VMware command is invoked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGETS=(
  "${TALOS_DIR}/lib/bash-preflight.sh"
  "${TALOS_DIR}/lib/common.sh"
  "${TALOS_DIR}/lib/yaml-config.sh"
  "${TALOS_DIR}/cluster.sh"
  "${TALOS_DIR}/config.sh"
  "${TALOS_DIR}/talos-gitops.sh"
  "${TALOS_DIR}/cluster-bootstrap.sh"
  "${TALOS_DIR}/apply-post-bootstrap.sh"
  "${TALOS_DIR}/sync-kubectl.sh"
  "${TALOS_DIR}/sync-talosctl.sh"
  "${TALOS_DIR}/provision-cluster.sh"
  "${TALOS_DIR}/govc/provision-cluster.sh"
  "${TALOS_DIR}/configure_load_balancer.sh"
  "${TALOS_DIR}/phase-network-bringup.sh"
  "${TALOS_DIR}/vars.sh"
)

FAIL_COUNT=0

echo "bash --version: $(bash --version | head -n1)"

for target in "${TARGETS[@]}"; do
  if bash -n "${target}"; then
    echo "[PASS] bash -n ${target}"
  else
    echo "[FAIL] bash -n ${target}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

# ShellCheck is scoped to files this iteration changed. Other scripts under
# scripts/talos/ carry pre-existing warnings out of this iteration's scope.
SHELLCHECK_TARGETS=(
  "${TALOS_DIR}/lib/bash-preflight.sh"
  "${TALOS_DIR}/lib/yaml-config.sh"
  "${TALOS_DIR}/cluster.sh"
  "${TALOS_DIR}/config.sh"
  "${TALOS_DIR}/talos-gitops.sh"
)

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "${SHELLCHECK_TARGETS[@]}"; then
    echo "[PASS] shellcheck"
  else
    echo "[FAIL] shellcheck"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  echo "[SKIP] shellcheck not found on PATH"
fi

echo ""
echo "test-syntax: ${FAIL_COUNT} failing check(s)"
[[ "${FAIL_COUNT}" -eq 0 ]]
