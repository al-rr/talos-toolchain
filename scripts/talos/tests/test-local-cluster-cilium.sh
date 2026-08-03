#!/usr/bin/env bash
# @file test-local-cluster-cilium.sh
# @brief Offline fixture tests for local-cluster.sh's --cni=cilium mode.
# @description
#   Hand-rolled harness (Bats is not available on this host). Runs
#   local-cluster.sh as a real subprocess against stub talosctl/docker/
#   colima/helm/kubectl fixtures under tests/fixtures/local-cluster/
#   (prepended to PATH) and a real, throwaway local Git checkout used as the
#   GitOps repo root. No real Docker daemon, Colima instance, network,
#   Kubernetes API, VMware, or credential action is ever invoked; nothing
#   outside a tmp directory is touched, and the workspace's real
#   talos-vsphere-gitops checkout is never read or modified.
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

TMP_ROOT="$(mktemp -d -t talos-local-cluster-cilium-test.XXXXXX)"
cleanup() {
  rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

STATE_ROOT="${TMP_ROOT}/state-root"
STUB_LOG_DIR="${TMP_ROOT}/logs"
mkdir -p "${STATE_ROOT}" "${STUB_LOG_DIR}"

# Fixtures first on PATH so the stub talosctl/docker/colima/helm/kubectl
# always win over anything real that might be installed on this host.
export PATH="${FIXTURES_DIR}:${PATH}"

# --- build a real, throwaway GitOps checkout on branch "lab" ---------------

build_gitops_checkout() {
  local root="$1"
  mkdir -p "${root}/environments/lab/argocd/apps" "${root}/environments/lab/helm/cilium"

  cat > "${root}/environments/lab/argocd/apps/cilium.yaml" <<'EOF_APP'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: addon-cilium
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: oci://quay.io/cilium/charts
      chart: cilium
      targetRevision: 1.19.1
      helm:
        releaseName: cilium
        valueFiles:
          - $values/environments/lab/helm/cilium/values.yaml
    - repoURL: https://github.com/ednillibanio/talos-vsphere-gitops.git
      targetRevision: lab
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF_APP

  cat > "${root}/environments/lab/helm/cilium/release.yaml" <<'EOF_RELEASE'
releaseName: cilium
namespace: kube-system
chart: oci://quay.io/cilium/charts/cilium
version: 1.19.1
valuesFile: environments/lab/helm/cilium/values.yaml
validationSelector: k8s-app=cilium
EOF_RELEASE

  printf 'kubeProxyReplacement: true\n' > "${root}/environments/lab/helm/cilium/values.yaml"

  git -C "${root}" init -q
  git -C "${root}" config user.email "test@example.invalid"
  git -C "${root}" config user.name "test"
  git -C "${root}" checkout -q -b lab
  git -C "${root}" add -A
  git -C "${root}" commit -q -m "fixture: lab GitOps checkout"
}

GITOPS_ROOT="${TMP_ROOT}/gitops"
build_gitops_checkout "${GITOPS_ROOT}"

run_local_cluster() {
  STUB_TALOSCTL_LOG="${STUB_LOG_DIR}/talosctl.log" \
  STUB_DOCKER_LOG="${STUB_LOG_DIR}/docker.log" \
  STUB_COLIMA_LOG="${STUB_LOG_DIR}/colima.log" \
  STUB_HELM_LOG="${STUB_LOG_DIR}/helm.log" \
  STUB_KUBECTL_LOG="${STUB_LOG_DIR}/kubectl.log" \
    "${LOCAL_CLUSTER_SH}" "$@"
}

reset_logs() {
  rm -f "${STUB_LOG_DIR}"/*.log
}

# --- --cni default preserves existing flannel behavior ----------------------

reset_logs
status=0
output="$(run_local_cluster create --name=default-mode --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -eq 0 ]]; then
  pass "create with no --cni still exits 0 (default mode unchanged)"
else
  fail "create with no --cni should still exit 0 (got ${status}): ${output}"
fi
if [[ "${output}" != *"config-patch"* && "${output}" != *"cni"* ]]; then
  pass "default mode never emits a CNI config-patch or --cni-related flags"
else
  fail "default mode must not reference CNI patching: ${output}"
fi

# --- --cni=cilium requires --gitops-repo-root --------------------------------

status=0
output="$(run_local_cluster create --name=needs-gitops --cni=cilium --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "create --cni=cilium without --gitops-repo-root is rejected"
else
  fail "create --cni=cilium without --gitops-repo-root should fail: ${output}"
fi

# --- invalid --cni value is rejected -----------------------------------------

status=0
output="$(run_local_cluster create --name=bad-cni --cni=weave --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "create rejects an unknown --cni value"
else
  fail "create should reject --cni=weave: ${output}"
fi

# --- --gitops-repo-root must be a Git checkout -------------------------------

NOT_A_REPO="${TMP_ROOT}/not-a-repo"
mkdir -p "${NOT_A_REPO}"
status=0
output="$(run_local_cluster create --name=not-a-repo --cni=cilium --gitops-repo-root="${NOT_A_REPO}" --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "create rejects a --gitops-repo-root that is not a Git checkout"
else
  fail "create should reject a non-Git --gitops-repo-root: ${output}"
fi

# --- --gitops-repo-root must be on branch "lab" ------------------------------

WRONG_BRANCH_ROOT="${TMP_ROOT}/wrong-branch"
cp -r "${GITOPS_ROOT}" "${WRONG_BRANCH_ROOT}"
git -C "${WRONG_BRANCH_ROOT}" checkout -q -b not-lab
status=0
output="$(run_local_cluster create --name=wrong-branch --cni=cilium --gitops-repo-root="${WRONG_BRANCH_ROOT}" --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -ne 0 && "${output}" == *"branch 'lab'"* ]]; then
  pass "create rejects a --gitops-repo-root not on branch 'lab'"
else
  fail "create should reject a --gitops-repo-root not on 'lab': ${output}"
fi

# --- --gitops-repo-root must be clean -----------------------------------------

DIRTY_ROOT="${TMP_ROOT}/dirty"
cp -r "${GITOPS_ROOT}" "${DIRTY_ROOT}"
echo "uncommitted" >> "${DIRTY_ROOT}/environments/lab/helm/cilium/values.yaml"
status=0
output="$(run_local_cluster create --name=dirty-gitops --cni=cilium --gitops-repo-root="${DIRTY_ROOT}" --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -ne 0 && "${output}" == *"uncommitted changes"* ]]; then
  pass "create rejects a --gitops-repo-root with uncommitted changes"
else
  fail "create should reject a dirty --gitops-repo-root: ${output}"
fi
if [[ ! -s "${STUB_LOG_DIR}/talosctl.log" ]]; then
  pass "no stub talosctl call is made when the GitOps preflight fails"
else
  fail "a failed GitOps preflight must never reach talosctl: $(cat "${STUB_LOG_DIR}/talosctl.log")"
fi

# --- create --cni=cilium --dry-run: previews CNI-none patch and Cilium day-1
#     bootstrap without mutating the host or the GitOps checkout ------------

reset_logs
status=0
output="$(run_local_cluster create --name=cilium-preview --cni=cilium --gitops-repo-root="${GITOPS_ROOT}" --state-root="${STATE_ROOT}" --dry-run 2>&1)" || status=$?
if [[ "${status}" -eq 0 ]]; then
  pass "create --cni=cilium --dry-run exits 0 on a valid, clean 'lab' checkout"
else
  fail "create --cni=cilium --dry-run should exit 0 (got ${status}): ${output}"
fi
if [[ "${output}" == *'"cni":"none"'* || "${output}" == *'"name":"none"'* ]]; then
  pass "create --cni=cilium --dry-run plans a CNI-none config-patch"
else
  fail "create --cni=cilium --dry-run did not preview a CNI-none config-patch: ${output}"
fi
if [[ "${output}" == *"--host-ip 127.0.0.1"* && "${output}" == *"--exposed-ports 0:6443/tcp"* ]]; then
  pass "create --cni=cilium --dry-run publishes the Kubernetes API on a loopback host port"
else
  fail "create --cni=cilium --dry-run did not preview the loopback port publish flags: ${output}"
fi
if [[ "${output}" == *"validate-cilium-handoff.sh"* ]]; then
  pass "create --cni=cilium --dry-run previews the Cilium handoff validator gate"
else
  fail "create --cni=cilium --dry-run did not preview the handoff validator: ${output}"
fi
if [[ "${output}" == *"phase-network-bringup.sh"* && "${output}" == *"--helm-root=${GITOPS_ROOT}/environments/lab/helm"* ]]; then
  pass "create --cni=cilium --dry-run previews the Cilium day-1 Helm bring-up from the GitOps lab helm root"
else
  fail "create --cni=cilium --dry-run did not preview the expected Helm bring-up invocation: ${output}"
fi
if [[ -z "$(git -C "${GITOPS_ROOT}" status --porcelain)" ]]; then
  pass "create --cni=cilium --dry-run never modifies the GitOps checkout"
else
  fail "the GitOps checkout must remain clean after a dry-run: $(git -C "${GITOPS_ROOT}" status --porcelain)"
fi

# --- create --cni=cilium (stubbed, real run): rewrites the isolated
#     kubeconfig to the published loopback endpoint and runs the Cilium
#     day-1 bring-up ------------------------------------------------------

reset_logs
cluster_dir="${STATE_ROOT}/cilium-real"
status=0
output="$(STUB_DOCKER_PORT_MAPPING="127.0.0.1:32768" run_local_cluster create --name=cilium-real --cni=cilium --gitops-repo-root="${GITOPS_ROOT}" --state-root="${STATE_ROOT}" 2>&1)" || status=$?
if [[ "${status}" -eq 0 ]]; then
  pass "create --cni=cilium (stubbed) exits 0"
else
  fail "create --cni=cilium (stubbed) should exit 0 (got ${status}): ${output}"
fi
if grep -q "server: https://127.0.0.1:32768" "${cluster_dir}/kubeconfig" 2>/dev/null; then
  pass "create --cni=cilium (stubbed) rewrites the kubeconfig to the published loopback endpoint"
else
  fail "kubeconfig was not rewritten to the published endpoint: $(cat "${cluster_dir}/kubeconfig" 2>/dev/null)"
fi
if ! grep -q "10.5.0" "${cluster_dir}/kubeconfig" 2>/dev/null; then
  pass "create --cni=cilium (stubbed) never leaves the internal Docker network address in the kubeconfig"
else
  fail "kubeconfig must not reference the internal 10.5.0.0/24 address: $(cat "${cluster_dir}/kubeconfig")"
fi
if grep -q "template" "${STUB_LOG_DIR}/helm.log" 2>/dev/null; then
  pass "create --cni=cilium (stubbed) runs the Cilium day-1 helm template/install phase"
else
  fail "expected a stub helm invocation for Cilium day-1: $(cat "${STUB_LOG_DIR}/helm.log" 2>/dev/null)"
fi
if grep -q -- "rollout status deployment/coredns" "${STUB_LOG_DIR}/kubectl.log" 2>/dev/null; then
  pass "create --cni=cilium (stubbed) waits for the CoreDNS rollout before completing"
else
  fail "expected a CoreDNS rollout-status check: $(cat "${STUB_LOG_DIR}/kubectl.log" 2>/dev/null)"
fi
if grep -q "cni=cilium" "${cluster_dir}/.talos-toolchain-local-cluster" 2>/dev/null; then
  pass "create --cni=cilium (stubbed) records cni=cilium in the wrapper marker"
else
  fail "wrapper marker did not record cni=cilium: $(cat "${cluster_dir}/.talos-toolchain-local-cluster" 2>/dev/null)"
fi

# --- published API port discovery failure: create fails, state is retained
#     for diagnostics instead of being auto-destroyed ------------------------

reset_logs
cluster_dir="${STATE_ROOT}/cilium-port-fail"
status=0
output="$(TALOS_LOCAL_CLUSTER_API_PORT_WAIT_SECONDS=1 STUB_DOCKER_PORT_FAIL=true \
  run_local_cluster create --name=cilium-port-fail --cni=cilium --gitops-repo-root="${GITOPS_ROOT}" --state-root="${STATE_ROOT}" 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "create --cni=cilium fails when the published API port never appears"
else
  fail "create --cni=cilium should fail when docker port never reports a mapping: ${output}"
fi
if [[ -d "${cluster_dir}/talos-state" ]]; then
  pass "create --cni=cilium leaves Talos state in place for diagnostics on port-discovery failure (no auto-destroy)"
else
  fail "create --cni=cilium must retain state on failure, not clean up automatically"
fi
if [[ ! -f "${cluster_dir}/.talos-toolchain-local-cluster" ]]; then
  pass "create --cni=cilium never writes the wrapper marker when it fails before completion"
else
  fail "the wrapper marker must not be written on a failed create"
fi

# --- async supervision: talosctl cluster create docker blocks on cluster
#     health (CoreDNS), which can never happen on its own while CNI is
#     "none"; --cni=cilium must run it in the background so the Cilium
#     day-1 bootstrap (which is what makes CoreDNS come up) can start while
#     it is still running, then wait for and propagate its real result. ----

reset_logs
cluster_dir="${STATE_ROOT}/cilium-async"
CREATE_DONE_FILE="${TMP_ROOT}/create-done-async"
rm -f "${CREATE_DONE_FILE}"

STUB_TALOSCTL_CREATE_SLEEP_SECONDS=3 \
STUB_TALOSCTL_CREATE_DONE_FILE="${CREATE_DONE_FILE}" \
STUB_DOCKER_PORT_MAPPING="127.0.0.1:32769" \
  run_local_cluster create --name=cilium-async --cni=cilium --gitops-repo-root="${GITOPS_ROOT}" --state-root="${STATE_ROOT}" \
  > "${TMP_ROOT}/async-output.log" 2>&1 &
async_pid=$!

# Poll (well under the 3s simulated create) for evidence that the Cilium
# day-1 Helm phase has already started while the backgrounded create's
# done-file has not appeared yet, i.e. the create command is still
# "in flight" (still simulating its CoreDNS-health wait) when bootstrap
# begins.
bootstrap_started_before_create_done="false"
waited_ms=0
while (( waited_ms < 5000 )); do
  if [[ -s "${STUB_LOG_DIR}/helm.log" ]]; then
    if [[ ! -e "${CREATE_DONE_FILE}" ]]; then
      bootstrap_started_before_create_done="true"
    fi
    break
  fi
  sleep 0.1
  waited_ms=$((waited_ms + 100))
done

wait "${async_pid}"
async_status=$?

if [[ "${bootstrap_started_before_create_done}" == "true" ]]; then
  pass "Cilium day-1 bootstrap starts before the simulated create's CoreDNS-ready completion"
else
  fail "Cilium day-1 bootstrap did not start before the simulated create finished (or never started): $(cat "${TMP_ROOT}/async-output.log" 2>/dev/null)"
fi
if [[ "${async_status}" -eq 0 ]]; then
  pass "async create --cni=cilium exits 0 after propagating the backgrounded create's success"
else
  fail "async create --cni=cilium should exit 0 (got ${async_status}): $(cat "${TMP_ROOT}/async-output.log" 2>/dev/null)"
fi
if [[ -f "${CREATE_DONE_FILE}" ]]; then
  pass "the backgrounded talosctl cluster create docker actually ran to completion"
else
  fail "the backgrounded create's done-file was never written"
fi
if [[ -f "${cluster_dir}/.talos-toolchain-local-cluster" && "${CREATE_DONE_FILE}" -ot "${cluster_dir}/.talos-toolchain-local-cluster" ]]; then
  pass "the backgrounded child is reaped (waited on) before the success marker is written"
else
  fail "expected the create done-file to predate the wrapper marker (the child must be reaped first): done-file=$(stat -f '%m' "${CREATE_DONE_FILE}" 2>/dev/null || stat -c '%Y' "${CREATE_DONE_FILE}" 2>/dev/null) marker=$(stat -f '%m' "${cluster_dir}/.talos-toolchain-local-cluster" 2>/dev/null || stat -c '%Y' "${cluster_dir}/.talos-toolchain-local-cluster" 2>/dev/null)"
fi
if grep -q -- "cluster create docker" "${STUB_LOG_DIR}/talosctl.log" 2>/dev/null; then
  pass "async create still invokes the real (stubbed) talosctl cluster create docker command"
else
  fail "expected a stub talosctl cluster create docker invocation"
fi

# --- async create failure propagation: Cilium day-1 still bootstraps
#     (concurrently with the backgrounded create), but the backgrounded
#     create's own failure is only detected and propagated at the final
#     wait, after Cilium/CoreDNS have already been confirmed healthy -------

reset_logs
cluster_dir="${STATE_ROOT}/cilium-create-fail"
status=0
output="$(STUB_TALOSCTL_CREATE_FAIL=true STUB_DOCKER_PORT_MAPPING="127.0.0.1:32771" \
  run_local_cluster create --name=cilium-create-fail --cni=cilium --gitops-repo-root="${GITOPS_ROOT}" --state-root="${STATE_ROOT}" 2>&1)" || status=$?
if [[ "${status}" -ne 0 ]]; then
  pass "async create propagates a failed backgrounded talosctl cluster create docker exit status"
else
  fail "create --cni=cilium should fail when the backgrounded talosctl create fails: ${output}"
fi
if [[ "${output}" == *"talosctl cluster create docker failed"* ]]; then
  pass "async create failure message references the backgrounded talosctl create failure"
else
  fail "expected a diagnostic mentioning the backgrounded create failure: ${output}"
fi
if [[ ! -f "${cluster_dir}/.talos-toolchain-local-cluster" ]]; then
  pass "async create never writes the success marker when the backgrounded create ultimately fails"
else
  fail "the wrapper marker must not be written when the backgrounded create fails"
fi
if grep -q "template" "${STUB_LOG_DIR}/helm.log" 2>/dev/null; then
  pass "Cilium day-1 still bootstraps even though the backgrounded create later reports failure (its failure is only propagated after)"
else
  fail "expected the Cilium day-1 Helm phase to have run before the backgrounded create failure was propagated"
fi
if [[ -d "${cluster_dir}/talos-state" ]]; then
  pass "async create leaves Talos state in place for diagnostics when the backgrounded create fails (no auto-destroy)"
else
  fail "async create must retain state when the backgrounded create fails, not clean up automatically"
fi

# --- EXIT trap guard: an unexpected `set -e` failure in an ordinary command
#     between the child starting and the final wait (not just the explicit
#     `if ! cmd; then die` branches above) must still terminate and reap the
#     backgrounded talosctl create, not leave it running unsupervised. A
#     published endpoint containing the kubeconfig-rewrite sed's own '#'
#     delimiter breaks that sed command's syntax, so it exits non-zero and
#     (unguarded by an explicit if) trips `set -e` on its own. -------------

reset_logs
cluster_dir="${STATE_ROOT}/cilium-rewrite-fail"
CREATE_DONE_FILE="${TMP_ROOT}/create-done-rewrite-fail"
rm -f "${CREATE_DONE_FILE}"
status=0
output="$(STUB_TALOSCTL_CREATE_SLEEP_SECONDS=5 STUB_TALOSCTL_CREATE_DONE_FILE="${CREATE_DONE_FILE}" STUB_DOCKER_PORT_MAPPING="127.0.0.1#evil:6443" \
  run_local_cluster create --name=cilium-rewrite-fail --cni=cilium --gitops-repo-root="${GITOPS_ROOT}" --state-root="${STATE_ROOT}" 2>&1)" || status=$?

if [[ "${status}" -ne 0 ]]; then
  pass "an unexpected set -e failure (malformed endpoint breaking the kubeconfig rewrite's sed) makes create fail"
else
  fail "create --cni=cilium should fail when the kubeconfig rewrite step fails unexpectedly: ${output}"
fi
if [[ ! -f "${CREATE_DONE_FILE}" ]]; then
  pass "the EXIT trap reaps the backgrounded talosctl create before it can run to completion on an unexpected mid-flow failure"
else
  fail "the backgrounded create should have been terminated by the EXIT trap, not allowed to finish: done-file was written"
fi
# Outlive the stub's full simulated duration to prove it was actually
# terminated, not merely still in flight at the moment we first checked.
sleep 6
if [[ ! -f "${CREATE_DONE_FILE}" ]]; then
  pass "the backgrounded talosctl create never completes after being reaped by the EXIT trap, confirmed after its full simulated duration"
else
  fail "the backgrounded create eventually completed anyway; the EXIT trap did not actually terminate it"
fi
if [[ -d "${cluster_dir}/talos-state" ]]; then
  pass "an unexpected mid-flow failure still leaves Talos state in place for diagnostics (no auto-destroy)"
else
  fail "an unexpected mid-flow failure must retain state, not clean up automatically"
fi
if [[ ! -f "${cluster_dir}/.talos-toolchain-local-cluster" ]]; then
  pass "an unexpected mid-flow failure never writes the success marker"
else
  fail "the wrapper marker must not be written when an unexpected mid-flow failure occurs"
fi

echo ""
echo "test-local-cluster-cilium: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "${FAIL_COUNT}" -eq 0 ]]
