#!/usr/bin/env bash
# @file test-render-namespaces.sh
# @brief Offline tests for namespace collection in phase-network-bringup.sh.
# @description
#   Server-side dry-run creates nothing, so every namespace a rendered bundle
#   declares must exist before validation runs. Deriving that list from the
#   values file misses chart-defaulted namespaces: the lab Cilium values never
#   name "cilium-secrets", yet the chart renders it plus namespaced RBAC
#   inside it. A live run failed with twelve `namespaces "cilium-secrets" not
#   found` errors while all offline suites were green, so these tests pin the
#   render — not the values — as the source of truth.
#
#   Sources phase-network-bringup.sh (its main is guarded) and calls the
#   collectors directly. No cluster, network, Helm, or kubectl is involved.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TALOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PHASE_SH="${TALOS_DIR}/phase-network-bringup.sh"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures/render"

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

assert_equals() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass "${description}"
  else
    fail "${description} (expected '${expected}', got '${actual}')"
  fi
}

# shellcheck source=/dev/null
source "${PHASE_SH}"

TMP_ROOT="$(mktemp -d -t talos-render-ns-test.XXXXXX)"
cleanup() { rm -rf "${TMP_ROOT}"; }
trap cleanup EXIT

# --- The regression the live run exposed -----------------------------------

render_fixture="${FIXTURES_DIR}/cilium-defaulted-namespace.yaml"
[[ -f "${render_fixture}" ]] || {
  echo "missing fixture: ${render_fixture}" >&2
  exit 1
}

assert_equals "render collector finds the chart-defaulted namespace" \
  "cilium-secrets" \
  "$(collect_render_namespaces "${render_fixture}" | tr '\n' ' ' | sed 's/ $//')"

# The values file for that same render names no namespace at all. This is the
# blind spot: the old collector returned nothing here, so nothing was created
# and every namespaced resource failed server-side dry-run.
values_without_namespace="${TMP_ROOT}/values-no-ns.yaml"
cat > "${values_without_namespace}" <<'YAML'
ingressController:
  enabled: true
  enableSecretsSync: true
gatewayAPI:
  enabled: true
YAML

assert_equals "values collector is blind to a chart-defaulted namespace" \
  "" \
  "$(collect_cilium_secret_namespaces "${values_without_namespace}")"

# --- Collector correctness --------------------------------------------------

assert_equals "only Namespace documents are collected, not metadata.namespace" \
  "1" \
  "$(collect_render_namespaces "${render_fixture}" | wc -l | tr -d ' ')"

multi_ns="${TMP_ROOT}/multi-ns.yaml"
cat > "${multi_ns}" <<'YAML'
---
apiVersion: v1
kind: Namespace
metadata:
  name: beta
---
apiVersion: v1
kind: Namespace
metadata:
  name: alpha
---
apiVersion: v1
kind: Namespace
metadata:
  name: beta
YAML

assert_equals "multiple namespaces are sorted and de-duplicated" \
  "alpha beta" \
  "$(collect_render_namespaces "${multi_ns}" | tr '\n' ' ' | sed 's/ $//')"

# A bundle with no Namespace document must yield nothing rather than guessing.
no_ns="${TMP_ROOT}/no-ns.yaml"
cat > "${no_ns}" <<'YAML'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: only-a-configmap
  namespace: kube-system
YAML

assert_equals "a render with no Namespace document yields nothing" \
  "" \
  "$(collect_render_namespaces "${no_ns}")"

# The first document is not preceded by a separator in some renders.
leading_doc="${TMP_ROOT}/leading.yaml"
cat > "${leading_doc}" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: first-without-separator
YAML

assert_equals "a leading document with no --- separator is still collected" \
  "first-without-separator" \
  "$(collect_render_namespaces "${leading_doc}")"

# Values that *do* declare a namespace must still be honoured, so the union at
# the call site never regresses the original behaviour.
values_with_namespace="${TMP_ROOT}/values-ns.yaml"
cat > "${values_with_namespace}" <<'YAML'
ingressController:
  secretsNamespace:
    name: "custom-secrets"
YAML

assert_equals "values collector still honours an explicit secretsNamespace" \
  "custom-secrets" \
  "$(collect_cilium_secret_namespaces "${values_with_namespace}")"

echo
echo "test-render-namespaces: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "${FAIL_COUNT}" -eq 0 ]]
