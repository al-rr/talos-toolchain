#!/usr/bin/env bash
# @file test-local-cluster.sh
# @brief Offline fixture tests for scripts/talos/local-cluster.sh.
# @description
#   Hand-rolled harness (Bats is not available on this host). Runs
#   local-cluster.sh as a real subprocess against stub talosctl/docker/colima
#   fixtures under tests/fixtures/local-cluster/ (prepended to PATH) and an
#   isolated --state-root under a throwaway tmp directory. No real Docker
#   daemon, Colima instance, network, VMware, or credential action is ever
#   invoked; nothing outside the tmp directory is touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCAL_CLUSTER_SH="${TALOS_DIR}/local-cluster.sh"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures/local-cluster"

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

TMP_ROOT="$(mktemp -d -t talos-local-cluster-test.XXXXXX)"
cleanup() {
  rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

STATE_ROOT="${TMP_ROOT}/state-root"
STUB_LOG_DIR="${TMP_ROOT}/logs"
mkdir -p "${STATE_ROOT}" "${STUB_LOG_DIR}"

# Fixtures first on PATH so the stub talosctl/docker/colima always win over
# anything real that might be installed on this host.
export PATH="${FIXTURES_DIR}:${PATH}"

run_local_cluster() {
  STUB_TALOSCTL_LOG="${STUB_LOG_DIR}/talosctl.log" \
  STUB_DOCKER_LOG="${STUB_LOG_DIR}/docker.log" \
  STUB_COLIMA_LOG="${STUB_LOG_DIR}/colima.log" \
    "${LOCAL_CLUSTER_SH}" "$@"
}

reset_logs() {
  rm -f "${STUB_LOG_DIR}"/*.log
}

# --- create --dry-run: never mutates the host ---

reset_logs
cluster_dir="${STATE_ROOT}/dry-run-cluster"
output=""
status=0
output="$(run_local_cluster create --name=dry-run-cluster --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?

if [[ "${status}" -eq 0 ]]; then
  pass "create --dry-run exits 0"
else
  fail "create --dry-run should exit 0 (got ${status}): ${output}"
fi

if [[ ! -d "${cluster_dir}" ]]; then
  pass "create --dry-run does not create the cluster directory"
else
  fail "create --dry-run must not create ${cluster_dir}"
fi

if [[ "${output}" == *"talosctl cluster create docker"* && "${output}" == *"--name dry-run-cluster"* ]]; then
  pass "create --dry-run prints the explicit 'talosctl cluster create docker' command"
else
  fail "create --dry-run output missing expected talosctl invocation: ${output}"
fi

if [[ "${output}" != *"cluster create --provisioner docker"* && "${output}" != *"cluster create dev"* ]]; then
  pass "create --dry-run never emits the deprecated generic create or QEMU dev invocation"
else
  fail "create --dry-run must not emit the deprecated --provisioner docker or dev invocation: ${output}"
fi

if [[ "${output}" == *"--talosconfig-destination ${STATE_ROOT}/dry-run-cluster/talosconfig"* ]]; then
  pass "create --dry-run uses an isolated --talosconfig-destination path under the cluster dir"
else
  fail "create --dry-run did not reference an isolated --talosconfig-destination path: ${output}"
fi

# --- create for real (stubbed talosctl/docker/colima): isolated paths, marker written ---

reset_logs
cluster_dir="${STATE_ROOT}/real-cluster"
status=0
output="$(run_local_cluster create --name=real-cluster --state-root="${STATE_ROOT}" 2>&1)" || status=$?

if [[ "${status}" -eq 0 ]]; then
  pass "create (stubbed) exits 0"
else
  fail "create (stubbed) should exit 0 (got ${status}): ${output}"
fi

if [[ -f "${cluster_dir}/.talos-toolchain-local-cluster" ]]; then
  pass "create (stubbed) writes the wrapper marker"
else
  fail "create (stubbed) did not write a marker at ${cluster_dir}/.talos-toolchain-local-cluster"
fi

if [[ -f "${cluster_dir}/kubeconfig" ]]; then
  pass "create (stubbed) fetches an isolated kubeconfig"
else
  fail "create (stubbed) did not produce ${cluster_dir}/kubeconfig"
fi

if grep -q -- "--state ${cluster_dir}/talos-state" "${STUB_LOG_DIR}/talosctl.log" 2>/dev/null; then
  pass "create (stubbed) passes an isolated --state path to talosctl"
else
  fail "create (stubbed) talosctl invocation missing isolated --state path"
fi

# --- create refuses a second time (marker already present) ---

status=0
output="$(run_local_cluster create --name=real-cluster --state-root="${STATE_ROOT}" 2>&1)" || status=$?

if [[ "${status}" -ne 0 ]]; then
  pass "create refuses to run again once a marker already exists"
else
  fail "create should refuse a second run for an already-created cluster"
fi

# --- unsafe cluster names are rejected before any path is touched ---

for unsafe_name in "../escape" "foo/bar" "UPPER" "" ".hidden" "trailing-"; do
  status=0
  output="$(run_local_cluster create --name="${unsafe_name}" --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
  if [[ "${status}" -ne 0 ]]; then
    pass "create rejects unsafe --name '${unsafe_name}'"
  else
    fail "create should reject unsafe --name '${unsafe_name}'"
  fi
done

if [[ ! -e "${STATE_ROOT}/../escape" && ! -e "${STATE_ROOT}/escape" ]]; then
  pass "rejected traversal name never created a directory outside the cluster dir"
else
  fail "traversal name must not create any directory"
fi

# --- --controlplanes other than 1 is rejected: the Docker backend has no
#     control-plane-count flag and always creates exactly one ---

reset_logs
status=0
output="$(run_local_cluster create --name=too-many-cp --state-root="${STATE_ROOT}" --controlplanes=3 --dry-run 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "create rejects --controlplanes=3 (Docker backend supports exactly 1)"
else
  fail "create should reject --controlplanes=3: ${output}"
fi
if [[ ! -s "${STUB_LOG_DIR}/talosctl.log" ]]; then
  pass "no stub talosctl call is made when --controlplanes is unsupported"
else
  fail "an unsupported --controlplanes must never reach talosctl: $(cat "${STUB_LOG_DIR}/talosctl.log")"
fi

reset_logs
status=0
output="$(run_local_cluster create --name=one-cp-ok --state-root="${STATE_ROOT}" --controlplanes=1 --dry-run 2>&1)" || status=$?
if [[ "${status}" -eq 0 ]]; then
  pass "create accepts the explicit --controlplanes=1"
else
  fail "create should accept --controlplanes=1: ${output}"
fi

# --- status is read-only and works whether or not a marker exists ---

reset_logs
status=0
output="$(run_local_cluster status --name=real-cluster --state-root="${STATE_ROOT}" 2>&1)" || status=$?
if [[ "${status}" -eq 0 && "${output}" == *"Wrapper marker: present"* ]]; then
  pass "status reports a present wrapper marker"
else
  fail "status did not report the marker as present: ${output}"
fi

status=0
output="$(run_local_cluster status --name=never-created --state-root="${STATE_ROOT}" 2>&1)" || status=$?
if [[ "${status}" -eq 0 && "${output}" == *"Wrapper marker: absent"* ]]; then
  pass "status reports an absent wrapper marker without failing"
else
  fail "status should succeed and report an absent marker: ${output}"
fi

if [[ ! -d "${STATE_ROOT}/never-created" || ! -f "${STATE_ROOT}/never-created/talos-state" ]]; then
  pass "status never creates cluster state for a never-created cluster"
else
  fail "status must remain read-only"
fi

# --- status --dry-run: talosctl cluster show supports --provisioner but not
#     --talosconfig; the wrapper must pass the former and never the latter ---

status=0
output="$(run_local_cluster status --name=real-cluster --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -eq 0 && "${output}" == *"talosctl cluster show"* && "${output}" == *"--provisioner docker"* ]]; then
  pass "status --dry-run previews talosctl cluster show with --provisioner docker"
else
  fail "status --dry-run did not preview the expected talosctl cluster show invocation: ${output}"
fi
if [[ "${output}" != *"--talosconfig "* ]]; then
  pass "status --dry-run never passes the unsupported --talosconfig flag to cluster show"
else
  fail "status --dry-run must not pass --talosconfig to talosctl cluster show: ${output}"
fi

# --- destroy without --confirm-destroy refuses to run ---

status=0
output="$(run_local_cluster destroy --name=real-cluster --state-root="${STATE_ROOT}" 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "destroy without --confirm-destroy refuses to run"
else
  fail "destroy without --confirm-destroy should refuse to run"
fi
if [[ -d "${cluster_dir}" ]]; then
  pass "destroy without --confirm-destroy leaves the cluster directory intact"
else
  fail "destroy without --confirm-destroy must not remove ${cluster_dir}"
fi

# --- destroy --dry-run previews without deleting anything ---

status=0
output="$(run_local_cluster destroy --name=real-cluster --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -eq 0 && "${output}" == *"talosctl cluster destroy"* ]]; then
  pass "destroy --dry-run previews the planned talosctl destroy command"
else
  fail "destroy --dry-run did not preview as expected: ${output}"
fi
if [[ "${output}" != *"--provisioner"* ]]; then
  pass "destroy --dry-run never passes the unsupported --provisioner flag to cluster destroy"
else
  fail "destroy --dry-run must not pass --provisioner to talosctl cluster destroy: ${output}"
fi
if [[ -d "${cluster_dir}" ]]; then
  pass "destroy --dry-run leaves the cluster directory intact"
else
  fail "destroy --dry-run must not remove ${cluster_dir}"
fi

# --- destroy refuses a cluster this wrapper never created (no marker) ---

mkdir -p "${STATE_ROOT}/unmanaged-cluster/talos-state"
status=0
output="$(run_local_cluster destroy --name=unmanaged-cluster --state-root="${STATE_ROOT}" --confirm-destroy 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "destroy refuses a cluster directory without a wrapper marker"
else
  fail "destroy should refuse to touch a directory it never created"
fi
if [[ -d "${STATE_ROOT}/unmanaged-cluster" ]]; then
  pass "destroy leaves an unmanaged cluster directory intact"
else
  fail "destroy must not remove a directory it never created"
fi

# --- destroy (stubbed) with --confirm-destroy actually tears down and cleans up ---

status=0
output="$(run_local_cluster destroy --name=real-cluster --state-root="${STATE_ROOT}" --confirm-destroy 2>&1)" || status=$?
if [[ "${status}" -eq 0 ]]; then
  pass "destroy --confirm-destroy (stubbed) exits 0"
else
  fail "destroy --confirm-destroy (stubbed) should exit 0: ${output}"
fi
if [[ ! -d "${cluster_dir}" ]]; then
  pass "destroy --confirm-destroy (stubbed) removes the isolated cluster directory"
else
  fail "destroy --confirm-destroy (stubbed) should remove ${cluster_dir}"
fi

# --- create preflight failure: unresponsive Docker daemon blocks create ---

reset_logs
status=0
output="$(STUB_DOCKER_INFO_FAIL=true run_local_cluster create --name=docker-down --state-root="${STATE_ROOT}" 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "create refuses to proceed when the Docker daemon is unresponsive"
else
  fail "create should fail when docker info fails"
fi
if [[ ! -d "${STATE_ROOT}/docker-down" ]]; then
  pass "create does not create any state when the Docker daemon preflight fails"
else
  fail "create must not create state when the Docker daemon preflight fails"
fi

# --- --state-root safety: absolute, not "/", no ".." traversal shape ---

reset_logs
for unsafe_root in "/" "relative/state-root" "${STATE_ROOT}/../escape" "${STATE_ROOT}/sub/../../escape"; do
  status=0
  output="$(run_local_cluster create --name=root-check --state-root="${unsafe_root}" --dry-run 2>&1)" || status=$?
  if [[ "${status}" -ne 0 ]]; then
    pass "create rejects unsafe --state-root '${unsafe_root}'"
  else
    fail "create should reject unsafe --state-root '${unsafe_root}'"
  fi
done

if [[ ! -s "${STUB_LOG_DIR}/talosctl.log" ]]; then
  pass "no stub talosctl call is made when --state-root is rejected"
else
  fail "an unsafe --state-root must never reach talosctl: $(cat "${STUB_LOG_DIR}/talosctl.log")"
fi

# --- symlinked state root: rejected, attack target never touched ---

ATTACK_TARGET="${TMP_ROOT}/attack-target"
mkdir -p "${ATTACK_TARGET}"
printf 'untouched\n' > "${ATTACK_TARGET}/sentinel"
SYMLINKED_ROOT="${TMP_ROOT}/state-root-symlink"
ln -s "${ATTACK_TARGET}" "${SYMLINKED_ROOT}"

reset_logs
status=0
output="$(run_local_cluster create --name=via-symlinked-root --state-root="${SYMLINKED_ROOT}" 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "create refuses a --state-root that is itself a symlink"
else
  fail "create should refuse a symlinked --state-root: ${output}"
fi

status=0
output="$(run_local_cluster status --name=via-symlinked-root --state-root="${SYMLINKED_ROOT}" 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "status refuses a --state-root that is itself a symlink"
else
  fail "status should refuse a symlinked --state-root: ${output}"
fi

status=0
output="$(run_local_cluster destroy --name=via-symlinked-root --state-root="${SYMLINKED_ROOT}" --confirm-destroy 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "destroy refuses a --state-root that is itself a symlink"
else
  fail "destroy should refuse a symlinked --state-root: ${output}"
fi

if [[ "$(cat "${ATTACK_TARGET}/sentinel")" == "untouched" && ! -e "${ATTACK_TARGET}/.talos-toolchain-local-cluster" ]]; then
  pass "attack target reached through a symlinked state root is never mutated"
else
  fail "attack target must never be touched via a symlinked state root"
fi

if [[ ! -s "${STUB_LOG_DIR}/talosctl.log" ]]; then
  pass "no stub talosctl call is made when --state-root is a symlink"
else
  fail "a symlinked --state-root must never reach talosctl: $(cat "${STUB_LOG_DIR}/talosctl.log")"
fi

# --- symlinked cluster directory: rejected, attack target never touched ---

CLUSTER_SYMLINK_ROOT="${TMP_ROOT}/cluster-symlink-root"
mkdir -p "${CLUSTER_SYMLINK_ROOT}"
ln -s "${ATTACK_TARGET}" "${CLUSTER_SYMLINK_ROOT}/evil-cluster"

reset_logs
status=0
output="$(run_local_cluster create --name=evil-cluster --state-root="${CLUSTER_SYMLINK_ROOT}" 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "create refuses a cluster directory that is itself a symlink"
else
  fail "create should refuse a symlinked cluster directory: ${output}"
fi

status=0
output="$(run_local_cluster status --name=evil-cluster --state-root="${CLUSTER_SYMLINK_ROOT}" 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "status refuses a cluster directory that is itself a symlink"
else
  fail "status should refuse a symlinked cluster directory: ${output}"
fi

status=0
output="$(run_local_cluster destroy --name=evil-cluster --state-root="${CLUSTER_SYMLINK_ROOT}" --confirm-destroy 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "destroy refuses a cluster directory that is itself a symlink"
else
  fail "destroy should refuse a symlinked cluster directory: ${output}"
fi

if [[ -L "${CLUSTER_SYMLINK_ROOT}/evil-cluster" ]]; then
  pass "the symlinked cluster directory itself is left untouched, not replaced"
else
  fail "the symlinked cluster directory must not be removed or replaced"
fi

if [[ "$(cat "${ATTACK_TARGET}/sentinel")" == "untouched" && ! -e "${ATTACK_TARGET}/.talos-toolchain-local-cluster" ]]; then
  pass "attack target reached through a symlinked cluster directory is never mutated"
else
  fail "attack target must never be touched via a symlinked cluster directory"
fi

if [[ ! -s "${STUB_LOG_DIR}/talosctl.log" ]]; then
  pass "no stub talosctl call is made when the cluster directory is a symlink"
else
  fail "a symlinked cluster directory must never reach talosctl: $(cat "${STUB_LOG_DIR}/talosctl.log")"
fi

echo ""
echo "test-local-cluster: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "${FAIL_COUNT}" -eq 0 ]]
