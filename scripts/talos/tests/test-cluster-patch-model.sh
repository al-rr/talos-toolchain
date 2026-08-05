#!/usr/bin/env bash
# @file test-cluster-patch-model.sh
# @brief Offline tests for the cluster-patches model and its materialization.
# @description
#   Covers cluster.sh create-project's patch scaffolding, which had no test
#   coverage while it emitted the same patches from inline heredocs. Runs
#   cluster.sh as a real subprocess against a stub curl (the only network
#   dependency, the Talos Factory schematic POST) and a throwaway project
#   directory under a tmp root. No real network, Docker, Talos, VMware, or
#   credential action is invoked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${TALOS_DIR}/../.." && pwd)"
CLUSTER_SH="${TALOS_DIR}/cluster.sh"
PATCH_MODEL_DIR="${REPO_ROOT}/cluster-patches"

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

TMP_ROOT="$(mktemp -d -t talos-cluster-patch-model-test.XXXXXX)"
cleanup() { rm -rf "${TMP_ROOT}"; }
trap cleanup EXIT

# Stub curl so the Factory schematic POST never leaves the host. Mirrors the
# real response shape closely enough for the sed-based id extraction in
# post_schematic_and_get_id.
STUB_DIR="${TMP_ROOT}/stubs"
mkdir -p "${STUB_DIR}"
cat > "${STUB_DIR}/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '{"id":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}\n'
EOF_CURL
chmod +x "${STUB_DIR}/curl"
export PATH="${STUB_DIR}:${PATH}"

MODEL_FILES=(
  cni.patch.yaml
  cp.patch.yaml
  worker.patch.yaml
  cp-bootstrap.patch.yaml
  worker-bootstrap.patch.yaml
  longhorn.patch.yaml
)

# --- the model itself --------------------------------------------------------

missing=""
for name in "${MODEL_FILES[@]}"; do
  [[ -f "${PATCH_MODEL_DIR}/${name}" ]] || missing="${missing} ${name}"
done
if [[ -z "${missing}" ]]; then
  pass "every patch model file exists under cluster-patches/"
else
  fail "patch model files missing from ${PATCH_MODEL_DIR}:${missing}"
fi

if grep -q "name: none" "${PATCH_MODEL_DIR}/cni.patch.yaml" \
  && ! grep -q '"op":"replace"' "${PATCH_MODEL_DIR}/cni.patch.yaml"; then
  pass "cni.patch.yaml is a strategic-merge CNI-none patch (not JSON6902)"
else
  fail "cni.patch.yaml is not the expected strategic-merge CNI-none patch"
fi

if grep -q "disabled: true" "${PATCH_MODEL_DIR}/cni.patch.yaml"; then
  pass "cni.patch.yaml also disables the managed kube-proxy"
else
  fail "cni.patch.yaml must set cluster.proxy.disabled: true"
fi

# cluster-bootstrap.sh guards the role bootstrap patches with `[[ -s ]]` and
# only passes them to talosctl when non-empty. A comment header would make
# them non-empty and hand talosctl an effectively empty patch, so the
# emptiness is load-bearing, not an oversight.
for name in cp-bootstrap.patch.yaml worker-bootstrap.patch.yaml; do
  if [[ ! -s "${PATCH_MODEL_DIR}/${name}" ]]; then
    pass "${name} is empty, as cluster-bootstrap.sh's [[ -s ]] guard requires"
  else
    fail "${name} must stay zero-byte; content makes cluster-bootstrap.sh pass an empty patch to talosctl"
  fi
done

if grep -q "iscsi_tcp" "${PATCH_MODEL_DIR}/longhorn.patch.yaml" \
  && grep -q "/var/lib/longhorn" "${PATCH_MODEL_DIR}/longhorn.patch.yaml"; then
  pass "longhorn.patch.yaml carries the day-1 machine prerequisites (kernel modules + kubelet mount)"
else
  fail "longhorn.patch.yaml lost its kernel module or kubelet mount prerequisites"
fi

# --- materialization via create-project --------------------------------------

PROJECT_DIR="${TMP_ROOT}/clusters/test-cluster"
status=0
output="$("${CLUSTER_SH}" create-project --project-dir="${PROJECT_DIR}" --talos-version=v1.13.7 2>&1)" || status=$?
if [[ "${status}" -eq 0 ]]; then
  pass "create-project exits 0 against the stub Factory endpoint"
else
  fail "create-project failed (${status}): ${output}"
fi

missing=""
for name in "${MODEL_FILES[@]}"; do
  [[ -f "${PROJECT_DIR}/patches/${name}" ]] || missing="${missing} ${name}"
done
if [[ -z "${missing}" ]]; then
  pass "create-project materializes every patch model file into <project-dir>/patches/"
else
  fail "create-project did not materialize:${missing}"
fi

if diff -q "${PATCH_MODEL_DIR}/cni.patch.yaml" "${PROJECT_DIR}/patches/cni.patch.yaml" >/dev/null; then
  pass "the materialized cni.patch.yaml is byte-identical to the model"
else
  fail "the materialized cni.patch.yaml diverged from the model"
fi

for name in cp-bootstrap.patch.yaml worker-bootstrap.patch.yaml; do
  if [[ -f "${PROJECT_DIR}/patches/${name}" && ! -s "${PROJECT_DIR}/patches/${name}" ]]; then
    pass "materialized ${name} stays zero-byte"
  else
    fail "materialized ${name} must exist and stay zero-byte"
  fi
done

# --- re-running never discards operator edits --------------------------------

printf 'cluster:\n  network:\n    cni:\n      name: none\n# operator edit\n' \
  > "${PROJECT_DIR}/patches/cni.patch.yaml"
EDITED_SUM="$(cksum < "${PROJECT_DIR}/patches/cni.patch.yaml")"
rm -f "${PROJECT_DIR}/patches/worker.patch.yaml"

status=0
output="$("${CLUSTER_SH}" create-project --project-dir="${PROJECT_DIR}" --talos-version=v1.13.7 2>&1)" || status=$?
if [[ "${status}" -eq 0 ]]; then
  pass "create-project is safe to re-run over an existing project"
else
  fail "re-running create-project failed (${status}): ${output}"
fi

if [[ "$(cksum < "${PROJECT_DIR}/patches/cni.patch.yaml")" == "${EDITED_SUM}" ]]; then
  pass "re-running create-project preserves an operator-edited patch"
else
  fail "re-running create-project overwrote an operator-edited patch"
fi

if [[ -f "${PROJECT_DIR}/patches/worker.patch.yaml" ]]; then
  pass "re-running create-project restores a patch the operator deleted"
else
  fail "re-running create-project did not restore the deleted worker.patch.yaml"
fi

# --- a missing model is a clear failure, not a silent empty scaffold ---------

BROKEN_ROOT="${TMP_ROOT}/broken-toolchain"
mkdir -p "${BROKEN_ROOT}"
cp -R "${REPO_ROOT}/scripts" "${BROKEN_ROOT}/scripts"
# deliberately no cluster-patches/ directory
status=0
output="$("${BROKEN_ROOT}/scripts/talos/cluster.sh" create-project \
  --project-dir="${TMP_ROOT}/clusters/no-model" --talos-version=v1.13.7 2>&1)" || status=$?
if [[ "${status}" -ne 0 && "${output}" == *"Patch model directory not found"* ]]; then
  pass "a missing cluster-patches/ directory fails create-project with a clear message"
else
  fail "create-project should fail clearly without a patch model (${status}): ${output}"
fi

# --- dry-run writes nothing ---------------------------------------------------

DRY_PROJECT="${TMP_ROOT}/clusters/dry-cluster"
status=0
output="$("${CLUSTER_SH}" create-project --project-dir="${DRY_PROJECT}" --talos-version=v1.13.7 --dry-run 2>&1)" || status=$?
if [[ "${status}" -eq 0 && ! -d "${DRY_PROJECT}" ]]; then
  pass "create-project --dry-run creates no project directory"
else
  fail "create-project --dry-run must not write anything (${status}): ${output}"
fi

echo
echo "test-cluster-patch-model: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "${FAIL_COUNT}" -eq 0 ]]
