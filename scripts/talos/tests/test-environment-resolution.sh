#!/usr/bin/env bash
# @file test-environment-resolution.sh
# @brief Offline tests for how a cluster resolves the environment it reads.
# @description
#   A cluster and the environment it runs in are separate identities, and
#   several clusters normally share one environment. These tests pin that
#   contract: two differently named clusters both resolve "lab", the project's
#   declared cluster.environment is honoured, --environment overrides it, and
#   the environment is never derived from the cluster name.
#
#   Runs cluster.sh as a real subprocess against a stub curl (the Factory
#   schematic POST) and throwaway project directories under a tmp root. No
#   real network, Docker, Talos, VMware, or credential action is invoked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_SH="${TALOS_DIR}/cluster.sh"

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

if ! command -v yq >/dev/null 2>&1; then
  echo "test-environment-resolution: SKIPPED (yq not installed on this host)"
  exit 0
fi

TMP_ROOT="$(mktemp -d -t talos-env-resolution-test.XXXXXX)"
cleanup() { rm -rf "${TMP_ROOT}"; }
trap cleanup EXIT

STUB_DIR="${TMP_ROOT}/stubs"
mkdir -p "${STUB_DIR}"
cat > "${STUB_DIR}/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '{"id":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}\n'
EOF_CURL
chmod +x "${STUB_DIR}/curl"
export PATH="${STUB_DIR}:${PATH}"

# Keep every XDG config read inside the tmp tree: these tests must never touch
# the operator's real ~/.config/talos-toolchain or its credentials.
export XDG_CONFIG_HOME="${TMP_ROOT}/xdg-config"
mkdir -p "${XDG_CONFIG_HOME}"
chmod 700 "${XDG_CONFIG_HOME}"

new_project() {
  local name="$1"
  shift
  "${CLUSTER_SH}" create-project \
    --project-dir="${TMP_ROOT}/clusters/${name}" \
    --talos-version=v1.13.7 \
    "$@" >/dev/null 2>&1
  printf '%s\n' "${TMP_ROOT}/clusters/${name}"
}

declared_env() {
  yq eval '.cluster.environment // ""' "$1/config.yaml"
}

# Runs an action far enough to emit the resolved-environment log line, without
# requiring real infrastructure. The action itself is expected to fail later --
# there is no vSphere or Docker here -- so its exit status is deliberately
# discarded; only the resolved environment matters. Kept out of a pipeline so
# `pipefail` does not turn that expected failure into a test error.
resolved_env() {
  local project="$1"
  local output=""
  shift
  output="$(TALOS_TOOLCHAIN_DIR="$(cd "${TALOS_DIR}/../.." && pwd)" \
    "${CLUSTER_SH}" generate --project-dir="${project}" --dry-run "$@" 2>&1 || true)"
  printf '%s\n' "${output}" |
    sed -nE "s/.*Using environment '([^']+)'.*/\1/p" | head -1
}

# --- the owner's two-cluster example ----------------------------------------
# cluster-lab (containers) and cluster-lab-vmware (vSphere, 3cp/3wk, HAProxy)
# must both read lab.

CONTAINER_PROJECT="$(new_project cluster-lab)"
VMWARE_PROJECT="$(new_project cluster-lab-vmware)"

if [[ "$(declared_env "${CONTAINER_PROJECT}")" == "lab" ]]; then
  pass "create-project declares environment lab by default (cluster-lab)"
else
  fail "cluster-lab declared '$(declared_env "${CONTAINER_PROJECT}")', expected lab"
fi

if [[ "$(declared_env "${VMWARE_PROJECT}")" == "lab" ]]; then
  pass "create-project declares environment lab by default (cluster-lab-vmware)"
else
  fail "cluster-lab-vmware declared '$(declared_env "${VMWARE_PROJECT}")', expected lab"
fi

container_resolved="$(resolved_env "${CONTAINER_PROJECT}")"
vmware_resolved="$(resolved_env "${VMWARE_PROJECT}")"

if [[ "${container_resolved}" == "lab" && "${vmware_resolved}" == "lab" ]]; then
  pass "two differently named clusters both resolve the same environment (lab)"
else
  fail "clusters resolved '${container_resolved}' and '${vmware_resolved}', expected both lab"
fi

# The specific regression: the environment used to default to the cluster name,
# so each cluster went looking for an environment named after itself.
if [[ "${vmware_resolved}" != "cluster-lab-vmware" ]]; then
  pass "the environment is never derived from the cluster name"
else
  fail "the environment fell back to the cluster name: ${vmware_resolved}"
fi

# --- a project declaring a different environment ------------------------------

PROD_PROJECT="$(new_project cluster-prod --environment=prod)"

if [[ "$(declared_env "${PROD_PROJECT}")" == "prod" ]]; then
  pass "create-project --environment writes the declared environment"
else
  fail "cluster-prod declared '$(declared_env "${PROD_PROJECT}")', expected prod"
fi

if [[ "$(resolved_env "${PROD_PROJECT}")" == "prod" ]]; then
  pass "a project's declared cluster.environment is honoured on later actions"
else
  fail "cluster-prod resolved '$(resolved_env "${PROD_PROJECT}")', expected prod"
fi

# --- the flag overrides the declared value for one run ------------------------

if [[ "$(resolved_env "${CONTAINER_PROJECT}" --environment=prod)" == "prod" ]]; then
  pass "--environment overrides the project's declared environment for one run"
else
  fail "--environment did not override the declared environment"
fi

# --- a project without the field still resolves the default -------------------

LEGACY_PROJECT="$(new_project cluster-legacy)"
yq eval -i 'del(.cluster.environment)' "${LEGACY_PROJECT}/config.yaml"

if [[ "$(resolved_env "${LEGACY_PROJECT}")" == "lab" ]]; then
  pass "a project predating the field falls back to lab, not to its own name"
else
  fail "legacy project resolved '$(resolved_env "${LEGACY_PROJECT}")', expected lab"
fi

# --- an invalid environment name is rejected ----------------------------------

output="$(resolved_env "${CONTAINER_PROJECT}" --environment=../escape 2>&1)"
if [[ "${output}" != "../escape" ]]; then
  pass "a path-traversal environment name is rejected"
else
  fail "a path-traversal environment name was accepted: ${output}"
fi

echo
echo "test-environment-resolution: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "${FAIL_COUNT}" -eq 0 ]]
