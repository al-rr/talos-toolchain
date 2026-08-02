#!/usr/bin/env bash
# @file test-yaml-config.sh
# @brief Offline fixture tests for lib/yaml-config.sh.
# @description
#   Hand-rolled harness (Bats is not available on this host). Exercises
#   bootstrap idempotency/force, secure file/dir checks, schema validation,
#   load precedence, and redacted diagnostics against a temporary
#   XDG_CONFIG_HOME. Runs no Talos, Kubernetes, Helm, network, or VMware
#   operation, and never prints a real secret value.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../lib" && pwd)"

# shellcheck disable=SC1091
source "${LIB_DIR}/common.sh"
# shellcheck disable=SC1091
source "${LIB_DIR}/yaml-config.sh"

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

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass "${description}"
  else
    fail "${description} (expected '${expected}', got '${actual}')"
  fi
}

if ! command -v yq >/dev/null 2>&1; then
  echo "[SKIP] yq not found on PATH; skipping yaml-config tests"
  exit 0
fi

TMP_ROOT="$(mktemp -d -t talos-yaml-config-test.XXXXXX)"
cleanup() { rm -rf "${TMP_ROOT}"; }
trap cleanup EXIT

export XDG_CONFIG_HOME="${TMP_ROOT}/xdg"
ENV_NAME="test-env"

# --- bootstrap: idempotent creation with secure permissions -------------------

talos_config_bootstrap "${ENV_NAME}" "false"

base_dir="$(talos_config_base_dir)"
env_dir="$(talos_config_env_dir "${ENV_NAME}")"
base_file="$(talos_config_base_file)"
env_file="$(talos_config_env_file "${ENV_NAME}")"
cred_file="$(talos_config_credentials_file "${ENV_NAME}")"

[[ -f "${base_file}" ]] && pass "bootstrap creates base config" || fail "bootstrap did not create base config"
[[ -f "${env_file}" ]] && pass "bootstrap creates environment config" || fail "bootstrap did not create environment config"
[[ -f "${cred_file}" ]] && pass "bootstrap creates credentials file" || fail "bootstrap did not create credentials file"

if talos_config_check_dir_secure "${base_dir}" >/dev/null 2>&1; then
  pass "base config directory is 0700 and owned by current user"
else
  fail "base config directory failed secure check"
fi

if talos_config_check_file_secure "${cred_file}" "600" >/dev/null 2>&1; then
  pass "credentials file is mode 0600"
else
  fail "credentials file failed secure check"
fi

# The pristine generated defaults must still validate under the stricter
# (post-correction) schema checker.
if talos_config_validate_schema "${base_file}" TALOS_CONFIG_SCHEMA_TABLE >/dev/null 2>&1; then
  pass "generated base config still validates under the stricter schema check"
else
  fail "generated base config should still validate under the stricter schema check"
fi

if talos_config_validate_schema "${env_file}" TALOS_CONFIG_SCHEMA_TABLE >/dev/null 2>&1; then
  pass "generated environment config still validates under the stricter schema check"
else
  fail "generated environment config should still validate under the stricter schema check"
fi

if talos_config_validate_schema "${cred_file}" TALOS_CONFIG_SECRET_SCHEMA_TABLE >/dev/null 2>&1; then
  pass "generated credentials file still validates under the stricter schema check"
else
  fail "generated credentials file should still validate under the stricter schema check"
fi

# Bootstrap again without force: files must not change.
echo "sentinel: do-not-overwrite" >> "${env_file}"
talos_config_bootstrap "${ENV_NAME}" "false"
if grep -q "sentinel: do-not-overwrite" "${env_file}"; then
  pass "bootstrap without force does not overwrite existing files"
else
  fail "bootstrap without force overwrote an existing file"
fi

# Bootstrap with force: files are rewritten.
talos_config_bootstrap "${ENV_NAME}" "true"
if grep -q "sentinel: do-not-overwrite" "${env_file}"; then
  fail "bootstrap with force did not overwrite an existing file"
else
  pass "bootstrap with force overwrites existing files"
fi

# --- secure file/dir checks: rejection paths -----------------------------------

insecure_dir="${TMP_ROOT}/insecure-dir"
mkdir -p "${insecure_dir}"
chmod 755 "${insecure_dir}"
if ! talos_config_check_dir_secure "${insecure_dir}" >/dev/null 2>&1; then
  pass "directory with mode 0755 is rejected"
else
  fail "directory with mode 0755 should be rejected"
fi

group_writable_file="${TMP_ROOT}/group-writable.yaml"
: > "${group_writable_file}"
chmod 664 "${group_writable_file}"
if ! talos_config_check_file_secure "${group_writable_file}" >/dev/null 2>&1; then
  pass "group-writable file is rejected"
else
  fail "group-writable file should be rejected"
fi

wrong_mode_cred="${TMP_ROOT}/wrong-mode-cred.yaml"
: > "${wrong_mode_cred}"
chmod 644 "${wrong_mode_cred}"
if ! talos_config_check_file_secure "${wrong_mode_cred}" "600" >/dev/null 2>&1; then
  pass "credentials file with mode 0644 is rejected"
else
  fail "credentials file with mode 0644 should be rejected"
fi

symlink_file="${TMP_ROOT}/symlink.yaml"
ln -s "${base_file}" "${symlink_file}"
if ! talos_config_check_file_secure "${symlink_file}" >/dev/null 2>&1; then
  pass "symlinked config file is rejected"
else
  fail "symlinked config file should be rejected"
fi

# --- legacy shell source safety check ------------------------------------------

legacy_vars="${TMP_ROOT}/vars.sh"
echo 'export EXAMPLE=1' > "${legacy_vars}"
chmod 664 "${legacy_vars}"
if ! talos_config_check_legacy_shell_secure "${legacy_vars}" >/dev/null 2>&1; then
  pass "legacy vars.sh with mode 0664 (group-writable) is rejected before sourcing"
else
  fail "legacy vars.sh with mode 0664 should be rejected"
fi
chmod 600 "${legacy_vars}"
if talos_config_check_legacy_shell_secure "${legacy_vars}" >/dev/null 2>&1; then
  pass "legacy vars.sh with mode 0600 passes the secure-source check"
else
  fail "legacy vars.sh with mode 0600 should pass the secure-source check"
fi

# --- schema validation: unknown key and type mismatch --------------------------

unknown_key_file="${TMP_ROOT}/unknown-key.yaml"
cat > "${unknown_key_file}" <<'EOF'
cluster:
  name: "demo"
totally:
  unknown: "value"
EOF
if ! talos_config_validate_schema "${unknown_key_file}" TALOS_CONFIG_SCHEMA_TABLE >/dev/null 2>&1; then
  pass "schema validation rejects an unknown key"
else
  fail "schema validation should reject an unknown key"
fi

type_mismatch_file="${TMP_ROOT}/type-mismatch.yaml"
cat > "${type_mismatch_file}" <<'EOF'
cluster:
  name: "demo"
ssh:
  port: "not-a-number"
EOF
if ! talos_config_validate_schema "${type_mismatch_file}" TALOS_CONFIG_SCHEMA_TABLE >/dev/null 2>&1; then
  pass "schema validation rejects a type mismatch (string where int expected)"
else
  fail "schema validation should reject a type mismatch"
fi

valid_file="${TMP_ROOT}/valid.yaml"
cat > "${valid_file}" <<'EOF'
cluster:
  name: "demo"
ssh:
  port: 22
EOF
if talos_config_validate_schema "${valid_file}" TALOS_CONFIG_SCHEMA_TABLE >/dev/null 2>&1; then
  pass "schema validation accepts an allowlisted, well-typed file"
else
  fail "schema validation should accept an allowlisted, well-typed file"
fi

# --- precedence: defaults < base < project < environment < credentials --------

PRECEDENCE_ENV="precedence-env"
talos_config_bootstrap "${PRECEDENCE_ENV}" "false"

cat > "$(talos_config_base_file)" <<'EOF'
cluster:
  name: "base-name"
ssh:
  user: "base-user"
EOF
chmod 600 "$(talos_config_base_file)"

project_file="${TMP_ROOT}/project-config.yaml"
cat > "${project_file}" <<'EOF'
cluster:
  name: "project-name"
EOF
chmod 600 "${project_file}"

cat > "$(talos_config_env_file "${PRECEDENCE_ENV}")" <<'EOF'
cluster:
  name: "env-name"
EOF
chmod 600 "$(talos_config_env_file "${PRECEDENCE_ENV}")"

cat > "$(talos_config_credentials_file "${PRECEDENCE_ENV}")" <<'EOF'
vsphere:
  password: "super-secret-value"
EOF
chmod 600 "$(talos_config_credentials_file "${PRECEDENCE_ENV}")"

talos_config_load "${PRECEDENCE_ENV}" "${project_file}"
assert_eq "environment config overrides project and base for cluster.name" "env-name" "${TALOS_CLUSTER_NAME}"
assert_eq "base config supplies ssh.user when unset elsewhere" "base-user" "${SSH_USER}"
assert_eq "credentials file supplies the secret value" "super-secret-value" "${VSPHERE_PASSWORD}"

# Simulate a CLI flag applied after talos_config_load, as callers do.
TALOS_CLUSTER_NAME="cli-name"
assert_eq "explicit CLI override wins over every YAML layer" "cli-name" "${TALOS_CLUSTER_NAME}"

# --- redacted diagnostics: never print the raw secret value -------------------

redacted_output="$(talos_config_show_redacted "${PRECEDENCE_ENV}")"
if [[ "${redacted_output}" == *"VSPHERE_PASSWORD=[REDACTED]"* ]]; then
  pass "diagnostics redact the secret variable"
else
  fail "diagnostics did not redact VSPHERE_PASSWORD: ${redacted_output}"
fi

if [[ "${redacted_output}" != *"super-secret-value"* ]]; then
  pass "diagnostics never print the raw secret value"
else
  fail "diagnostics leaked the raw secret value"
fi

# --- environment name validation: reject path escapes, empty, dot-only -------

for bad_name in "" "." ".." "a/b" "../evil" "/etc/passwd" ".hidden" "../../escaped"; do
  if ! talos_config_validate_env_name "${bad_name}"; then
    pass "environment name '${bad_name}' is rejected"
  else
    fail "environment name '${bad_name}' should be rejected"
  fi
done

for good_name in "lab" "lab-01" "lab.local" "LAB1"; do
  if talos_config_validate_env_name "${good_name}"; then
    pass "environment name '${good_name}' is accepted"
  else
    fail "environment name '${good_name}' should be accepted"
  fi
done

# No path escape: a traversal name must be refused by every public helper,
# and must never create anything outside the environments/ tree.
tree_before="$(find "${XDG_CONFIG_HOME}" | sort)"

env_dir_status=0
env_dir_output="$(talos_config_env_dir "../../escaped" 2>&1)" || env_dir_status=$?
if [[ "${env_dir_status}" -ne 0 ]]; then
  pass "talos_config_env_dir refuses a traversal environment name"
else
  fail "talos_config_env_dir should refuse a traversal environment name (output: ${env_dir_output})"
fi

bootstrap_escape_status=0
bootstrap_escape_output="$(talos_config_bootstrap "../../escaped" "false" 2>&1)" || bootstrap_escape_status=$?
if [[ "${bootstrap_escape_status}" -ne 0 ]]; then
  pass "bootstrap refuses a traversal environment name"
else
  fail "bootstrap should refuse a traversal environment name (output: ${bootstrap_escape_output})"
fi

load_escape_status=0
load_escape_output="$(talos_config_load "../../escaped" 2>&1)" || load_escape_status=$?
if [[ "${load_escape_status}" -ne 0 ]]; then
  pass "talos_config_load refuses a traversal environment name"
else
  fail "talos_config_load should refuse a traversal environment name (output: ${load_escape_output})"
fi

tree_after="$(find "${XDG_CONFIG_HOME}" | sort)"
if [[ "${tree_before}" == "${tree_after}" ]] && [[ ! -e "${TMP_ROOT}/escaped" ]] && [[ ! -e "$(dirname "${TMP_ROOT}")/escaped" ]]; then
  pass "rejected traversal environment names create nothing outside the XDG tree"
else
  fail "a traversal environment name mutated the filesystem outside the environments/ tree"
fi

# --- bootstrap: refuses unsafe pre-existing directories/files (no chmod/write-through) ---

SYMLINK_DIR_ENV="symlink-dir-env"
symlink_env_dir_path="$(talos_config_home)/environments/${SYMLINK_DIR_ENV}"
attack_target_dir="${TMP_ROOT}/attack-target-dir"
mkdir -p "${attack_target_dir}"
chmod 750 "${attack_target_dir}"
mkdir -p "$(dirname "${symlink_env_dir_path}")"
ln -s "${attack_target_dir}" "${symlink_env_dir_path}"

symlink_dir_status=0
symlink_dir_output="$(talos_config_bootstrap "${SYMLINK_DIR_ENV}" "false" 2>&1)" || symlink_dir_status=$?
if [[ "${symlink_dir_status}" -ne 0 ]]; then
  pass "bootstrap refuses a pre-existing symlinked environment directory"
else
  fail "bootstrap should refuse a pre-existing symlinked environment directory (output: ${symlink_dir_output})"
fi

attack_dir_mode_after="$(stat -f '%Lp' "${attack_target_dir}" 2>/dev/null || stat -c '%a' "${attack_target_dir}" 2>/dev/null)"
if [[ "${attack_dir_mode_after}" == "750" ]]; then
  pass "bootstrap never chmods through a symlinked directory"
else
  fail "bootstrap chmod'd through the symlink (attack target mode is now ${attack_dir_mode_after}, expected 750)"
fi
if [[ -L "${symlink_env_dir_path}" ]]; then
  pass "the malicious symlink itself is left untouched, not replaced"
else
  fail "the malicious symlink should remain untouched"
fi
rm -f "${symlink_env_dir_path}"
rm -rf "${attack_target_dir}"

SYMLINK_FILE_ENV="symlink-file-env"
talos_config_bootstrap "${SYMLINK_FILE_ENV}" "false" >/dev/null
symlink_cred_file="$(talos_config_credentials_file "${SYMLINK_FILE_ENV}")"
attack_target_file="${TMP_ROOT}/attack-target-file.yaml"
echo "sentinel: pre-existing-attacker-content" > "${attack_target_file}"
chmod 640 "${attack_target_file}"
rm -f "${symlink_cred_file}"
ln -s "${attack_target_file}" "${symlink_cred_file}"

symlink_file_status=0
symlink_file_output="$(talos_config_bootstrap "${SYMLINK_FILE_ENV}" "false" 2>&1)" || symlink_file_status=$?
if [[ "${symlink_file_status}" -ne 0 ]]; then
  pass "bootstrap refuses a pre-existing symlinked credentials file"
else
  fail "bootstrap should refuse a pre-existing symlinked credentials file (output: ${symlink_file_output})"
fi

if grep -q "sentinel: pre-existing-attacker-content" "${attack_target_file}"; then
  pass "bootstrap does not write through the symlink into the attack target"
else
  fail "bootstrap wrote through the symlink into the attack target"
fi

# force must only overwrite an already-validated, regular, in-tree file: it
# must refuse the same swapped-in symlink rather than writing through it.
force_symlink_status=0
force_symlink_output="$(talos_config_bootstrap "${SYMLINK_FILE_ENV}" "true" 2>&1)" || force_symlink_status=$?
if [[ "${force_symlink_status}" -ne 0 ]]; then
  pass "bootstrap --force refuses to overwrite through a swapped-in symlink"
else
  fail "bootstrap --force should refuse to overwrite through a swapped-in symlink (output: ${force_symlink_output})"
fi

if grep -q "sentinel: pre-existing-attacker-content" "${attack_target_file}"; then
  pass "bootstrap --force does not write through the symlink into the attack target"
else
  fail "bootstrap --force wrote through the symlink into the attack target"
fi

rm -f "${symlink_cred_file}" "${attack_target_file}"

# --- schema validation: unsupported shapes (empty containers, null, float) ----

empty_map_file="${TMP_ROOT}/empty-map.yaml"
cat > "${empty_map_file}" <<'EOF'
cluster:
  name: "demo"
bogus: {}
EOF
if ! talos_config_validate_schema "${empty_map_file}" TALOS_CONFIG_SCHEMA_TABLE >/dev/null 2>&1; then
  pass "schema validation rejects an unknown key even when it is an empty map"
else
  fail "schema validation should reject an unknown key shaped as an empty map"
fi

empty_list_leaf_file="${TMP_ROOT}/empty-list-leaf.yaml"
cat > "${empty_list_leaf_file}" <<'EOF'
cluster:
  name: "demo"
ssh:
  port: []
EOF
if ! talos_config_validate_schema "${empty_list_leaf_file}" TALOS_CONFIG_SCHEMA_TABLE >/dev/null 2>&1; then
  pass "schema validation rejects an empty list at a scalar-typed leaf"
else
  fail "schema validation should reject an empty list at a scalar-typed leaf"
fi

null_leaf_file="${TMP_ROOT}/null-leaf.yaml"
cat > "${null_leaf_file}" <<'EOF'
cluster:
  name: "demo"
ssh:
  port: null
EOF
if ! talos_config_validate_schema "${null_leaf_file}" TALOS_CONFIG_SCHEMA_TABLE >/dev/null 2>&1; then
  pass "schema validation rejects a null value at a scalar-typed leaf"
else
  fail "schema validation should reject a null value at a scalar-typed leaf"
fi

null_namespace_file="${TMP_ROOT}/null-namespace.yaml"
cat > "${null_namespace_file}" <<'EOF'
cluster: null
EOF
if ! talos_config_validate_schema "${null_namespace_file}" TALOS_CONFIG_SCHEMA_TABLE >/dev/null 2>&1; then
  pass "schema validation rejects a null value at a namespace path"
else
  fail "schema validation should reject a null value at a namespace path"
fi

float_for_int_file="${TMP_ROOT}/float-for-int.yaml"
cat > "${float_for_int_file}" <<'EOF'
cluster:
  name: "demo"
ssh:
  port: 22.5
EOF
if ! talos_config_validate_schema "${float_for_int_file}" TALOS_CONFIG_SCHEMA_TABLE >/dev/null 2>&1; then
  pass "schema validation rejects a float where an int is expected"
else
  fail "schema validation should reject a float where an int is expected"
fi

empty_namespace_file="${TMP_ROOT}/empty-namespace.yaml"
cat > "${empty_namespace_file}" <<'EOF'
cluster:
  name: "demo"
vsphere: {}
EOF
if talos_config_validate_schema "${empty_namespace_file}" TALOS_CONFIG_SCHEMA_TABLE >/dev/null 2>&1; then
  pass "schema validation still accepts an empty mapping at a known namespace prefix"
else
  fail "schema validation should still accept an empty mapping at a known namespace prefix"
fi

# --- integration regression: legacy vars.sh must not override YAML -----------
#
# Mirrors cluster.sh's corrected main(): legacy vars.sh/vars.local.sh are
# sourced first as a compatibility layer, then talos_config_load runs, so the
# YAML environment/credentials layers always win over anything legacy set.

INTEGRATION_ENV="integration-env"
talos_config_bootstrap "${INTEGRATION_ENV}" "false" >/dev/null
cat > "$(talos_config_env_file "${INTEGRATION_ENV}")" <<'EOF'
cluster:
  name: "yaml-wins"
EOF
chmod 600 "$(talos_config_env_file "${INTEGRATION_ENV}")"

legacy_integration_vars="${TMP_ROOT}/integration-vars.sh"
cat > "${legacy_integration_vars}" <<'EOF'
export TALOS_CLUSTER_NAME="legacy-loses"
EOF
chmod 600 "${legacy_integration_vars}"

unset TALOS_CLUSTER_NAME
talos_config_check_legacy_shell_secure "${legacy_integration_vars}"
# shellcheck disable=SC1090
source "${legacy_integration_vars}"
assert_eq "legacy vars.sh sets its own value before YAML loads" "legacy-loses" "${TALOS_CLUSTER_NAME}"

talos_config_load "${INTEGRATION_ENV}"
assert_eq "YAML environment config overrides the legacy vars.sh value" "yaml-wins" "${TALOS_CLUSTER_NAME}"

# --- schema validation: malformed YAML must fail unambiguously ----------------
#
# talos_config_validate_schema captures yq's own exit status via command
# substitution rather than relying on the (unchecked) exit status of a
# process substitution feeding the parsing loop. Prove a parse error is
# rejected outright, before any export could occur.

malformed_yaml_file="${TMP_ROOT}/malformed.yaml"
cat > "${malformed_yaml_file}" <<'EOF'
cluster:
  name: "unterminated
ssh:
  port: 22
EOF
chmod 600 "${malformed_yaml_file}"

malformed_status=0
malformed_output="$(talos_config_validate_schema "${malformed_yaml_file}" TALOS_CONFIG_SCHEMA_TABLE 2>&1)" || malformed_status=$?
if [[ "${malformed_status}" -ne 0 ]]; then
  pass "schema validation rejects malformed/unparseable YAML"
else
  fail "schema validation should reject malformed/unparseable YAML"
fi
if [[ "${malformed_output}" == *"Failed to parse"* ]]; then
  pass "malformed YAML failure message is actionable"
else
  fail "malformed YAML failure message should explain the parse error (got: ${malformed_output})"
fi

MALFORMED_LOAD_ENV="malformed-load-env"
talos_config_bootstrap "${MALFORMED_LOAD_ENV}" "false" >/dev/null
cp "${malformed_yaml_file}" "$(talos_config_env_file "${MALFORMED_LOAD_ENV}")"
chmod 600 "$(talos_config_env_file "${MALFORMED_LOAD_ENV}")"
unset TALOS_CLUSTER_NAME
malformed_load_status=0
malformed_load_output="$(talos_config_load "${MALFORMED_LOAD_ENV}" 2>&1)" || malformed_load_status=$?
if [[ "${malformed_load_status}" -ne 0 ]]; then
  pass "talos_config_load refuses malformed YAML before any export"
else
  fail "talos_config_load should refuse malformed YAML before any export (output: ${malformed_load_output})"
fi
if [[ -z "${TALOS_CLUSTER_NAME:-}" ]]; then
  pass "no value was exported from the malformed environment config"
else
  fail "a value was exported despite the malformed environment config: ${TALOS_CLUSTER_NAME}"
fi

# --- ancestor security: talos-toolchain root and environments/ parent --------
#
# Bootstrap and load must treat the talos-toolchain root and its
# environments/ parent as part of the secure boundary, not only base/ and
# environments/<name>/: refuse a pre-existing symlink/unsafe ancestor before
# any mkdir -p, chmod, write, or read, and never touch the external target
# reached through such a symlink.

toolchain_root_path="$(talos_config_home)"
environments_parent_path="${toolchain_root_path}/environments"

# Scenario 1: the talos-toolchain root itself is a symlink to an external,
# differently-permissioned directory.
ANCESTOR_ROOT_ENV="ancestor-root-env"
external_root_target="${TMP_ROOT}/external-root-target"
mkdir -p "${external_root_target}"
chmod 750 "${external_root_target}"
rm -rf "${toolchain_root_path}"
mkdir -p "$(dirname "${toolchain_root_path}")"
ln -s "${external_root_target}" "${toolchain_root_path}"

bootstrap_root_status=0
bootstrap_root_output="$(talos_config_bootstrap "${ANCESTOR_ROOT_ENV}" "false" 2>&1)" || bootstrap_root_status=$?
if [[ "${bootstrap_root_status}" -ne 0 ]]; then
  pass "bootstrap refuses a symlinked talos-toolchain root"
else
  fail "bootstrap should refuse a symlinked talos-toolchain root (output: ${bootstrap_root_output})"
fi

external_root_mode_after="$(stat -f '%Lp' "${external_root_target}" 2>/dev/null || stat -c '%a' "${external_root_target}" 2>/dev/null)"
if [[ "${external_root_mode_after}" == "750" ]]; then
  pass "bootstrap never chmods the external target reached through a symlinked root"
else
  fail "bootstrap chmod'd the external target reached through the symlinked root (mode now ${external_root_mode_after}, expected 750)"
fi

if [[ -z "$(find "${external_root_target}" -mindepth 1 2>/dev/null)" ]]; then
  pass "bootstrap never writes into the external target reached through a symlinked root"
else
  fail "bootstrap wrote into the external target reached through the symlinked root"
fi

load_root_status=0
load_root_output="$(talos_config_load "${ANCESTOR_ROOT_ENV}" 2>&1)" || load_root_status=$?
if [[ "${load_root_status}" -ne 0 ]]; then
  pass "talos_config_load refuses to read through a symlinked talos-toolchain root"
else
  fail "talos_config_load should refuse to read through a symlinked talos-toolchain root (output: ${load_root_output})"
fi

rm -f "${toolchain_root_path}"
rm -rf "${external_root_target}"

# Scenario 2: a valid talos-toolchain root, but the environments/ parent
# itself is a symlink to an external, differently-permissioned directory.
talos_config_bootstrap "throwaway-env" "false" >/dev/null

ANCESTOR_ENVIRONMENTS_ENV="ancestor-environments-env"
external_environments_target="${TMP_ROOT}/external-environments-target"
mkdir -p "${external_environments_target}"
chmod 750 "${external_environments_target}"
rm -rf "${environments_parent_path}"
ln -s "${external_environments_target}" "${environments_parent_path}"

bootstrap_env_parent_status=0
bootstrap_env_parent_output="$(talos_config_bootstrap "${ANCESTOR_ENVIRONMENTS_ENV}" "false" 2>&1)" || bootstrap_env_parent_status=$?
if [[ "${bootstrap_env_parent_status}" -ne 0 ]]; then
  pass "bootstrap refuses a symlinked environments/ parent directory"
else
  fail "bootstrap should refuse a symlinked environments/ parent directory (output: ${bootstrap_env_parent_output})"
fi

external_environments_mode_after="$(stat -f '%Lp' "${external_environments_target}" 2>/dev/null || stat -c '%a' "${external_environments_target}" 2>/dev/null)"
if [[ "${external_environments_mode_after}" == "750" ]]; then
  pass "bootstrap never chmods the external target reached through a symlinked environments/ parent"
else
  fail "bootstrap chmod'd the external target reached through the symlinked environments/ parent (mode now ${external_environments_mode_after}, expected 750)"
fi

if [[ -z "$(find "${external_environments_target}" -mindepth 1 2>/dev/null)" ]]; then
  pass "bootstrap never writes into the external target reached through a symlinked environments/ parent"
else
  fail "bootstrap wrote into the external target reached through the symlinked environments/ parent"
fi

load_env_parent_status=0
load_env_parent_output="$(talos_config_load "${ANCESTOR_ENVIRONMENTS_ENV}" 2>&1)" || load_env_parent_status=$?
if [[ "${load_env_parent_status}" -ne 0 ]]; then
  pass "talos_config_load refuses to read through a symlinked environments/ parent"
else
  fail "talos_config_load should refuse to read through a symlinked environments/ parent (output: ${load_env_parent_output})"
fi

rm -f "${environments_parent_path}"
rm -rf "${external_environments_target}"

echo ""
echo "yaml-config tests: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "${FAIL_COUNT}" -eq 0 ]]
