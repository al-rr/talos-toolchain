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

STATE_ROOT="${TMP_ROOT}/state-root"
STUB_LOG_DIR="${TMP_ROOT}/logs"
mkdir -p "${STATE_ROOT}" "${STUB_LOG_DIR}"

# Fixtures first on PATH so the stub talosctl/docker/colima always win over
# anything real that might be installed on this host.
export PATH="${FIXTURES_DIR}:${PATH}"

# Deterministic Docker endpoint resolution regardless of the host's real
# environment: no ambient DOCKER_HOST is allowed to leak in and short-circuit
# the Colima-fallback tests below.
unset DOCKER_HOST

# A real (bound, unlistened) AF_UNIX socket file so require_valid_docker_socket
# has a genuine socket to validate against, without any live Colima/Docker
# process. Bind-and-close leaves the socket file node on disk. Created
# directly under /tmp (not TMP_ROOT) because AF_UNIX paths are limited to
# ~104 bytes on macOS/BSD and mktemp's default TMPDIR path is too long.
FAKE_COLIMA_SOCKET="$(mktemp -u /tmp/talos-lc-test-XXXXXX.sock)"
python3 - "${FAKE_COLIMA_SOCKET}" <<'PY'
import socket
import sys

path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.close()
PY
cleanup() {
  rm -rf "${TMP_ROOT}" "${FAKE_COLIMA_SOCKET}"
}
trap cleanup EXIT

run_local_cluster() {
  STUB_TALOSCTL_LOG="${STUB_LOG_DIR}/talosctl.log" \
  STUB_DOCKER_LOG="${STUB_LOG_DIR}/docker.log" \
  STUB_COLIMA_LOG="${STUB_LOG_DIR}/colima.log" \
  STUB_COLIMA_DOCKER_SOCKET="${STUB_COLIMA_DOCKER_SOCKET-${FAKE_COLIMA_SOCKET}}" \
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

# --- Docker endpoint resolution: default Colima fallback is used ------------

reset_logs
status=0
output="$(run_local_cluster create --name=endpoint-colima-fallback --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -eq 0 && "${output}" == *"DOCKER_HOST=unix://${FAKE_COLIMA_SOCKET}"* ]]; then
  pass "create falls back to the validated Colima Docker socket when no explicit endpoint is configured"
else
  fail "create should resolve the Colima Docker socket by default: ${output}"
fi

# Real Colima prints the socket inside a logfmt line ('msg="docker socket:
# unix://..."'), not as a bare 'docker: <uri>' field. Both styles must parse,
# and the captured path must never swallow the quote that closes the msg=
# field -- a parser that only handled the bare form failed against the real
# binary while every stubbed test still passed.
reset_logs
status=0
output="$(STUB_COLIMA_STATUS_FORMAT=plain run_local_cluster create --name=endpoint-colima-plain --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -eq 0 && "${output}" == *"DOCKER_HOST=unix://${FAKE_COLIMA_SOCKET}"* ]]; then
  pass "create also resolves the Colima Docker socket from the plainer 'docker: <uri>' status form"
else
  fail "create should resolve the Colima socket from the plain status form too: ${output}"
fi
if [[ "${output}" != *"${FAKE_COLIMA_SOCKET}\""* ]]; then
  pass "the resolved Colima socket path never includes the logfmt closing quote"
else
  fail "the resolved Colima socket path captured a trailing quote: ${output}"
fi

# --- Docker endpoint resolution: --docker-endpoint takes precedence over Colima ---

reset_logs
status=0
output="$(run_local_cluster create --name=endpoint-explicit-flag --state-root="${STATE_ROOT}" --docker-endpoint="tcp://127.0.0.1:2375" --dry-run 2>&1)" || status=$?
if [[ "${status}" -eq 0 && "${output}" == *"DOCKER_HOST=tcp://127.0.0.1:2375"* ]]; then
  pass "--docker-endpoint takes precedence over the Colima fallback"
else
  fail "--docker-endpoint should take precedence over Colima: ${output}"
fi

# --- Docker endpoint resolution: an explicit DOCKER_HOST env var takes precedence over Colima ---

reset_logs
status=0
output="$(DOCKER_HOST="unix:///tmp/explicit-env.sock" run_local_cluster create --name=endpoint-explicit-env --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -eq 0 && "${output}" == *"DOCKER_HOST=unix:///tmp/explicit-env.sock"* ]]; then
  pass "an explicit DOCKER_HOST env var takes precedence over the Colima fallback"
else
  fail "an explicit DOCKER_HOST should take precedence over Colima: ${output}"
fi

# --- Docker endpoint resolution: fails clearly when Colima is not running and no explicit endpoint is set ---

reset_logs
status=0
output="$(STUB_COLIMA_STATUS_FAIL=true run_local_cluster create --name=endpoint-colima-down --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "create fails clearly when Colima is not running and no explicit endpoint is configured"
else
  fail "create should fail when Colima is down and no explicit endpoint is set: ${output}"
fi
if [[ ! -s "${STUB_LOG_DIR}/talosctl.log" ]]; then
  pass "no stub talosctl call is made when Docker endpoint resolution fails (Colima down)"
else
  fail "a failed endpoint resolution must never reach talosctl: $(cat "${STUB_LOG_DIR}/talosctl.log")"
fi

# --- Docker endpoint resolution: fails clearly when Colima reports no Docker socket ---

reset_logs
status=0
output="$(STUB_COLIMA_DOCKER_SOCKET="" run_local_cluster create --name=endpoint-no-socket-line --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "create fails clearly when Colima's status does not report a Docker socket"
else
  fail "create should fail when Colima reports no Docker socket: ${output}"
fi
if [[ ! -s "${STUB_LOG_DIR}/talosctl.log" ]]; then
  pass "no stub talosctl call is made when Colima reports no Docker socket"
else
  fail "a missing Colima Docker socket line must never reach talosctl: $(cat "${STUB_LOG_DIR}/talosctl.log")"
fi

# --- Docker endpoint resolution: fails clearly when the resolved Colima socket does not exist on disk ---

reset_logs
status=0
output="$(STUB_COLIMA_DOCKER_SOCKET="/tmp/talos-lc-test-does-not-exist.sock" run_local_cluster create --name=endpoint-missing-socket --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "create fails clearly when the resolved Colima Docker socket does not exist on disk"
else
  fail "create should fail when the resolved Colima socket file is missing: ${output}"
fi
if [[ ! -s "${STUB_LOG_DIR}/talosctl.log" ]]; then
  pass "no stub talosctl call is made when the resolved Colima socket does not exist"
else
  fail "a nonexistent resolved Colima socket must never reach talosctl: $(cat "${STUB_LOG_DIR}/talosctl.log")"
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
if grep -q '^state=ready$' "${cluster_dir}/.talos-toolchain-local-cluster" 2>/dev/null; then
  pass "a successful create promotes the marker to state=ready"
else
  fail "a successful create must record state=ready: $(cat "${cluster_dir}/.talos-toolchain-local-cluster" 2>/dev/null)"
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

if grep -q -- "DOCKER_HOST=unix://${FAKE_COLIMA_SOCKET}" "${STUB_LOG_DIR}/talosctl.log" 2>/dev/null; then
  pass "create (stubbed) passes the resolved Colima Docker endpoint to the Talos Docker lifecycle command"
else
  fail "create (stubbed) did not pass the resolved Docker endpoint to talosctl: $(cat "${STUB_LOG_DIR}/talosctl.log" 2>/dev/null)"
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

# --- destroy cleans up after an interrupted create (state=creating) ---
#
# A create killed mid-flight -- what the EXIT trap produces when Cilium day-1
# fails -- used to leave containers and state behind with no marker, so destroy
# refused to act and the only way out was a manual docker rm plus rm -rf. The
# marker is now written before the backend runs, so this must be destroyable.

interrupted_dir="${STATE_ROOT}/interrupted-cluster"
mkdir -p "${interrupted_dir}/talos-state"
cat > "${interrupted_dir}/.talos-toolchain-local-cluster" <<'MARKER'
name=interrupted-cluster
created_at=2026-08-05T00:00:00Z
cni=cilium
state=creating
MARKER
status=0
output="$(run_local_cluster destroy --name=interrupted-cluster --state-root="${STATE_ROOT}" --confirm-destroy 2>&1)" || status=$?
if [[ "${status}" -eq 0 ]]; then
  pass "destroy cleans up a cluster left behind by an interrupted create"
else
  fail "destroy must handle a state=creating marker: ${output}"
fi
if [[ ! -d "${interrupted_dir}" ]]; then
  pass "destroy removes the interrupted cluster's directory"
else
  fail "destroy should have removed ${interrupted_dir}"
fi
if [[ "${output}" == *"unfinished create"* ]]; then
  pass "destroy says it is tearing down a partially created cluster"
else
  fail "destroy should warn that the create never finished: ${output}"
fi

# --- a marker predating state tracking is still destroyable ---

legacy_dir="${STATE_ROOT}/legacy-cluster"
mkdir -p "${legacy_dir}/talos-state"
cat > "${legacy_dir}/.talos-toolchain-local-cluster" <<'MARKER'
name=legacy-cluster
created_at=2026-08-04T00:00:00Z
cni=flannel
MARKER
status=0
output="$(run_local_cluster destroy --name=legacy-cluster --state-root="${STATE_ROOT}" --confirm-destroy 2>&1)" || status=$?
if [[ "${status}" -eq 0 && ! -d "${legacy_dir}" ]]; then
  pass "destroy still accepts a marker written before state tracking existed"
else
  fail "a stateless marker must remain destroyable (status ${status}): ${output}"
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
