#!/usr/bin/env bash
# @file test-cilium-handoff.sh
# @brief Offline fixture tests for validate-cilium-handoff.sh and the day-2
#   Cilium imperative-reinstall exclusion in talos-gitops.sh.
# @description
#   Hand-rolled harness (Bats is not available on this host). Exercises the
#   validator against consistent and mismatched day-1/GitOps fixtures, and
#   confirms talos-gitops.sh refuses to (re)install Cilium imperatively after
#   Argo CD adoption. Uses a stub kubectl fixture and never contacts a real
#   Kubernetes/Helm/Talos/VMware endpoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FIXTURES="${SCRIPT_DIR}/fixtures/cilium-handoff"
VALIDATOR="${TALOS_DIR}/validate-cilium-handoff.sh"
GITOPS_CLI="${TALOS_DIR}/talos-gitops.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "[PASS] $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "[FAIL] $1"
}

assert_validator_ok() {
  local scenario="$1"
  local out=""
  if out="$(bash "${VALIDATOR}" \
    --day1-release="${FIXTURES}/${scenario}/day1/helm/cilium/release.yaml" \
    --gitops-repo-root="${FIXTURES}/${scenario}/gitops" \
    --environment=lab 2>&1)"; then
    pass "${scenario}: validator passes on consistent fixture"
  else
    fail "${scenario}: expected validator to pass"
    echo "${out}"
  fi
}

assert_validator_fails_with() {
  local scenario="$1"
  local expected_substring="$2"
  local out=""
  if out="$(bash "${VALIDATOR}" \
    --day1-release="${FIXTURES}/${scenario}/day1/helm/cilium/release.yaml" \
    --gitops-repo-root="${FIXTURES}/${scenario}/gitops" \
    --environment=lab 2>&1)"; then
    fail "${scenario}: expected validator to fail"
    echo "${out}"
  else
    if [[ "${out}" == *"${expected_substring}"* ]]; then
      pass "${scenario}: validator fails with expected diagnostic"
    else
      fail "${scenario}: validator failed but diagnostic did not match '${expected_substring}'"
      echo "${out}"
    fi
  fi
}

assert_validator_ok "consistent"
assert_validator_fails_with "mismatch-revision" "environment revision mismatch"
assert_validator_fails_with "mismatch-chart-version" "chart version mismatch"
assert_validator_fails_with "mismatch-values" "values content mismatch"
assert_validator_fails_with "mismatch-sync-policy" "adoption sync policy is not fully automated"

# --- day-2 imperative reinstall exclusion -----------------------------------

TMP_HELM_DIR="$(mktemp -d -t talos-cilium-handoff-test.XXXXXX)"
cleanup() { rm -rf "${TMP_HELM_DIR}"; }
trap cleanup EXIT
cp -r "${FIXTURES}/day2-exclusion/helm" "${TMP_HELM_DIR}/helm"

run_install_addon_cilium() {
  PATH="${FIXTURES}:${PATH}" bash "${GITOPS_CLI}" install-addon \
    --helm-manifest-dir="${TMP_HELM_DIR}/helm" \
    --kubeconfig="${FIXTURES}/fake-kubeconfig" \
    --kube-context=fake-context \
    --addon=cilium
}

out=""
if out="$(run_install_addon_cilium 2>&1)"; then
  fail "day-2 install-addon --addon=cilium: expected refusal, command succeeded"
  echo "${out}"
else
  if [[ "${out}" == *"system-excluded"* ]]; then
    pass "day-2 install-addon --addon=cilium: refused as system-excluded (no imperative reinstall after adoption)"
  else
    fail "day-2 install-addon --addon=cilium: refused but message did not mention system-exclusion"
    echo "${out}"
  fi
fi

echo ""
echo "test-cilium-handoff: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "${FAIL_COUNT}" -eq 0 ]]
