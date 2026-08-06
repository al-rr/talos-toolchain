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
SCRIPTS_DIR="$(cd "${TALOS_DIR}/.." && pwd)"

TARGETS=(
  "${TALOS_DIR}/lib/bash-preflight.sh"
  "${TALOS_DIR}/lib/common.sh"
  "${TALOS_DIR}/lib/yaml-config.sh"
  "${TALOS_DIR}/cluster.sh"
  "${TALOS_DIR}/local-cluster.sh"
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
  "${TALOS_DIR}/validate-cilium-handoff.sh"
  "${TALOS_DIR}/vars.sh"
  "${TALOS_DIR}/tests/test-local-cluster-cilium.sh"
  "${TALOS_DIR}/tests/test-cluster-patch-model.sh"
  "${TALOS_DIR}/tests/test-environment-resolution.sh"
  "${SCRIPTS_DIR}/host/setup-macos.sh"
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
  "${TALOS_DIR}/local-cluster.sh"
  "${TALOS_DIR}/config.sh"
  "${TALOS_DIR}/talos-gitops.sh"
  "${TALOS_DIR}/validate-cilium-handoff.sh"
  "${SCRIPTS_DIR}/host/setup-macos.sh"
)

# setup-macos.sh installs Bash 5, so it must itself parse under macOS's stock
# Bash 3.2. The generic `bash -n` above runs under whatever Bash is on PATH,
# which on a configured host is already Bash 5 and would not catch a Bash 4+
# construct sneaking in. Check it explicitly against the system Bash.
if [[ "$(uname -s)" == "Darwin" && -x /bin/bash ]]; then
  if /bin/bash -n "${SCRIPTS_DIR}/host/setup-macos.sh"; then
    echo "[PASS] /bin/bash -n (Bash 3.2 compatibility) host/setup-macos.sh"
  else
    echo "[FAIL] /bin/bash -n (Bash 3.2 compatibility) host/setup-macos.sh"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  echo "[SKIP] Bash 3.2 compatibility check (not macOS)"
fi

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
