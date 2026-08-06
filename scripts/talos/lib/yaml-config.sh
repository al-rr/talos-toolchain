#!/usr/bin/env bash

# @file yaml-config.sh
# @brief XDG YAML environment configuration for the Talos toolchain.
# @description
#   Data-only YAML configuration contract. `base/config.yaml` holds
#   non-secret shared defaults, `environments/<name>/config.yaml` holds
#   non-secret environment overrides, and `environments/<name>/credentials.yaml`
#   holds protected secrets. Every file is validated against an allowlisted
#   schema and secure file/ownership/permission checks before it is read.
#   Legacy `vars.sh`/`vars.local.sh` shell sourcing remains a temporary
#   compatibility path and is subject to the same secure-source checks.
#   Deliberately avoids Bash-4+-only associative arrays/namerefs so it stays
#   parseable and runnable on macOS's stock Bash 3.2, not only on Bash 5.
# @exitcode 0 If sourced successfully.
# @exitcode 1 If executed directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "This file is a library and must be sourced by another script." >&2
  exit 1
fi

# --- Allowlisted schema -----------------------------------------------------
#
# One row per line: "dotted.yaml.path|ENV_VAR_NAME|type" (type in: str, int,
# bool). Adding a configuration field means adding one row here. Unknown or
# type-mismatched keys are rejected.
TALOS_CONFIG_SCHEMA_TABLE="cluster.name|TALOS_CLUSTER_NAME|str
cluster.environment|TALOS_CLUSTER_ENVIRONMENT|str
cluster.endpoint|TALOS_CLUSTER_ENDPOINT|str
vsphere.endpoint|VSPHERE_ENDPOINT|str
vsphere.username|VSPHERE_USERNAME|str
vsphere.insecure|VSPHERE_INSECURE_CONNECTION|bool
vsphere.datastore|VSPHERE_DATASTORE|str
vsphere.network|VSPHERE_NETWORK|str
vsphere.folder|VSPHERE_FOLDER|str
vsphere.resourcePool|VSPHERE_RESOURCE_POOL|str
ssh.user|SSH_USER|str
ssh.port|SSH_PORT|int
ansible.username|ANSIBLE_USERNAME|str
ansible.hostKeyChecking|ANSIBLE_HOST_KEY_CHECKING|bool
haproxy.vip|HAPROXY_VIP|str
haproxy.node1.name|HAPROXY_NODE_1_NAME|str
haproxy.node1.ip|HAPROXY_NODE_1_IP|str
haproxy.node2.name|HAPROXY_NODE_2_NAME|str
haproxy.node2.ip|HAPROXY_NODE_2_IP|str
talos.ovaPath|TALOS_OVA_PATH|str
talos.isoDatastorePath|TALOS_ISO_DATASTORE_PATH|str
talos.controlPlane.count|TALOS_CONTROL_PLANE_COUNT|int
talos.controlPlane.cpu|TALOS_CONTROL_PLANE_CPU|int
talos.controlPlane.memoryMb|TALOS_CONTROL_PLANE_MEMORY_MB|int
talos.controlPlane.diskGb|TALOS_CONTROL_PLANE_DISK_GB|int
talos.worker.count|TALOS_WORKER_COUNT|int
talos.worker.cpu|TALOS_WORKER_CPU|int
talos.worker.memoryMb|TALOS_WORKER_MEMORY_MB|int
talos.worker.diskGb|TALOS_WORKER_DISK_GB|int
talos.network.gateway|TALOS_GATEWAY|str
talos.network.netmaskPrefix|TALOS_NETMASK_PREFIX|int
talos.dns.syncRequired|TALOS_DNS_SYNC_REQUIRED|bool"

# Secret-bearing dotted paths, valid only in credentials.yaml. Diagnostics
# redact these values unconditionally, regardless of source file.
TALOS_CONFIG_SECRET_SCHEMA_TABLE="vsphere.password|VSPHERE_PASSWORD|str
ssh.privateKeyFile|SSH_PRIVATE_KEY_FILE|str
ansible.privateKeyFile|ANSIBLE_PRIVATE_KEY_FILE|str
build.password|BUILD_PASSWORD|str"

_talos_config_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

talos_config_require_yq() {
  _talos_config_command_exists yq || die "yq is required for YAML configuration support."
}

# @description Validates an environment name is a single, safe path
#   component: starts with an alphanumeric, followed by alphanumerics, dots,
#   underscores, or hyphens. Rejects empty names, slashes, dot-only names
#   (".", ".."), and any other path-traversal-shaped input. Every public
#   function that turns an environment name into a filesystem path must call
#   this first.
# @arg $1 env_name Environment name to validate.
talos_config_validate_env_name() {
  local env_name="$1"
  [[ "${env_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# @description Validates an environment name or dies with an actionable
#   error. Convenience wrapper for public-boundary callers.
# @arg $1 env_name Environment name to validate.
talos_config_require_valid_env_name() {
  local env_name="$1"
  talos_config_validate_env_name "${env_name}" \
    || die "Invalid environment name '${env_name}'. Use a single path component matching [A-Za-z0-9][A-Za-z0-9._-]*."
}

# @description Looks up a dotted path in a schema table (a variable name
#   holding a "path|ENV_VAR|type" table, indirected via ${!table_name}).
#   Prints "ENV_VAR|type" on match, nothing on miss.
_talos_config_schema_lookup() {
  local table_name="$1"
  local path="$2"
  local table_value="${!table_name}"
  printf '%s\n' "${table_value}" | awk -F'|' -v p="${path}" '$1 == p { print $2 "|" $3; exit }'
}

# @description Prints every strict, non-leaf dotted-path prefix implied by a
#   schema table (for example "talos" and "talos.controlPlane" for a leaf
#   "talos.controlPlane.count"), one per line, deduplicated. These are the
#   only paths allowed to be a (possibly empty) mapping instead of a scalar.
_talos_config_schema_prefixes() {
  local table_name="$1"
  local table_value="${!table_name}"
  printf '%s\n' "${table_value}" | awk -F'|' '
    {
      n = split($1, parts, ".")
      prefix = ""
      for (i = 1; i < n; i++) {
        prefix = (i == 1) ? parts[i] : prefix "." parts[i]
        print prefix
      }
    }
  ' | sort -u
}

# @description True (0) if path is present in the newline-separated prefix
#   list, using an exact whole-line match.
_talos_config_is_schema_prefix() {
  local path="$1"
  local prefixes="$2"
  grep -Fxq -- "${path}" <<< "${prefixes}"
}

# --- XDG path helpers --------------------------------------------------------

talos_config_home() {
  printf '%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}/talos-toolchain"
}

talos_config_base_dir() {
  printf '%s\n' "$(talos_config_home)/base"
}

talos_config_base_file() {
  printf '%s\n' "$(talos_config_base_dir)/config.yaml"
}

talos_config_env_dir() {
  local env_name="${1:?Environment name is required}"
  talos_config_require_valid_env_name "${env_name}"
  printf '%s\n' "$(talos_config_home)/environments/${env_name}"
}

talos_config_env_file() {
  local env_name="${1:?Environment name is required}"
  talos_config_require_valid_env_name "${env_name}"
  printf '%s\n' "$(talos_config_env_dir "${env_name}")/config.yaml"
}

talos_config_credentials_file() {
  local env_name="${1:?Environment name is required}"
  talos_config_require_valid_env_name "${env_name}"
  printf '%s\n' "$(talos_config_env_dir "${env_name}")/credentials.yaml"
}

# --- Secure file/dir checks ---------------------------------------------------

_talos_config_stat_mode() {
  local path="$1"
  stat -f '%Lp' "${path}" 2>/dev/null || stat -c '%a' "${path}" 2>/dev/null
}

_talos_config_stat_uid() {
  local path="$1"
  stat -f '%u' "${path}" 2>/dev/null || stat -c '%u' "${path}" 2>/dev/null
}

# @description Verifies a config directory is a real (non-symlink) directory,
#   owned by the current user, and mode exactly 0700.
talos_config_check_dir_secure() {
  local path="$1"
  local mode=""
  local owner_uid=""

  [[ -e "${path}" ]] || { log_error "Config directory not found: ${path}"; return 1; }
  [[ -L "${path}" ]] && { log_error "Config directory must not be a symlink: ${path}"; return 1; }
  [[ -d "${path}" ]] || { log_error "Config directory path is not a directory: ${path}"; return 1; }

  owner_uid="$(_talos_config_stat_uid "${path}")"
  [[ "${owner_uid}" == "$(id -u)" ]] || { log_error "Config directory is not owned by the current user: ${path}"; return 1; }

  mode="$(_talos_config_stat_mode "${path}")"
  [[ "${mode}" == "700" ]] || { log_error "Config directory must be mode 0700 (found ${mode}): ${path}"; return 1; }

  return 0
}

# @description Verifies a config/credentials file is a real (non-symlink)
#   regular file, owned by the current user, and not group/world writable.
#   When required_mode is given (for example "600"), the mode must match
#   exactly.
talos_config_check_file_secure() {
  local path="$1"
  local required_mode="${2:-}"
  local mode=""
  local owner_uid=""

  [[ -e "${path}" ]] || { log_error "Config file not found: ${path}"; return 1; }
  [[ -L "${path}" ]] && { log_error "Config file must not be a symlink: ${path}"; return 1; }
  [[ -f "${path}" ]] || { log_error "Config file path is not a regular file: ${path}"; return 1; }

  owner_uid="$(_talos_config_stat_uid "${path}")"
  [[ "${owner_uid}" == "$(id -u)" ]] || { log_error "Config file is not owned by the current user: ${path}"; return 1; }

  mode="$(_talos_config_stat_mode "${path}")"

  if [[ -n "${required_mode}" ]]; then
    [[ "${mode}" == "${required_mode}" ]] || { log_error "Config file must be mode 0${required_mode} (found ${mode}): ${path}"; return 1; }
  else
    if (( (8#${mode} & 8#022) != 0 )); then
      log_error "Config file must not be group/world writable (found ${mode}): ${path}"
      return 1
    fi
  fi

  return 0
}

# @description Applies the same secure-file checks to legacy vars.sh/
#   vars.local.sh shell files before they are sourced.
talos_config_check_legacy_shell_secure() {
  talos_config_check_file_secure "$1"
}

# @description Refuses a toolchain-managed ancestor directory (the
#   `talos-toolchain` root or its `environments` parent) that is present but
#   unsafe: a symlink, not a directory, or otherwise failing the secure
#   directory check. An ancestor that does not exist yet is not an error
#   (nothing has been bootstrapped there) — only a pre-existing, unsafe one
#   is refused. Used by both bootstrap (before mkdir -p/chmod/write) and load
#   (before any read), so a file reached only through a swapped-in ancestor
#   symlink is never accepted either way.
# @arg $1 path Ancestor directory path.
talos_config_check_ancestor_secure_if_present() {
  local path="$1"

  if [[ -e "${path}" || -L "${path}" ]]; then
    talos_config_check_dir_secure "${path}"
    return $?
  fi

  return 0
}

# @description Refuses the `talos-toolchain` root and its `environments`
#   parent if either is present but unsafe, before any file beneath them is
#   trusted.
# @arg $1 home_dir The `talos-toolchain` root directory.
talos_config_require_secure_ancestors() {
  local home_dir="$1"

  talos_config_check_ancestor_secure_if_present "${home_dir}" \
    || die "Refusing to proceed: ${home_dir} exists but failed the secure ancestor check (fix ownership/mode 0700 or remove it manually)."
  talos_config_check_ancestor_secure_if_present "${home_dir}/environments" \
    || die "Refusing to proceed: ${home_dir}/environments exists but failed the secure ancestor check (fix ownership/mode 0700 or remove it manually)."
}

# --- Idempotent bootstrap ------------------------------------------------------

_talos_config_write_default_base() {
  local file="$1"
  cat > "${file}" <<'EOF_BASE'
# Non-secret shared defaults for all environments.
# See docs/en/environment-config.md for the field reference.
cluster:
  name: ""
  endpoint: ""
vsphere:
  endpoint: ""
  username: ""
  insecure: true
  datastore: ""
  network: ""
  folder: ""
  resourcePool: ""
ssh:
  user: ""
  port: 22
ansible:
  username: ""
  hostKeyChecking: false
haproxy:
  vip: ""
  node1:
    name: ""
    ip: ""
  node2:
    name: ""
    ip: ""
talos:
  ovaPath: ""
  isoDatastorePath: ""
  controlPlane:
    count: 3
    cpu: 2
    memoryMb: 4096
    diskGb: 20
  worker:
    count: 2
    cpu: 2
    memoryMb: 4096
    diskGb: 40
  network:
    gateway: ""
    netmaskPrefix: 24
  dns:
    syncRequired: false
EOF_BASE
}

_talos_config_write_default_env() {
  local file="$1"
  local env_name="$2"
  cat > "${file}" <<EOF_ENV
# Non-secret overrides for the "${env_name}" environment.
# See docs/en/environment-config.md for the field reference.
cluster:
  name: "${env_name}"
EOF_ENV
}

_talos_config_write_default_credentials() {
  local file="$1"
  cat > "${file}" <<'EOF_CRED'
# Protected secrets for this environment. Never commit this file.
vsphere:
  password: ""
ssh:
  privateKeyFile: ""
ansible:
  privateKeyFile: ""
build:
  password: ""
EOF_CRED
}

# @description Refuses a pre-existing bootstrap directory that is a symlink,
#   not a directory, or fails the secure-permissions check, before any
#   chmod/write happens. Creates and secures the directory only when it does
#   not already exist. Idempotent for an already-valid directory.
_talos_config_bootstrap_dir() {
  local path="$1"

  if [[ -e "${path}" || -L "${path}" ]]; then
    if [[ -L "${path}" ]]; then
      die "Refusing to bootstrap: ${path} exists and is a symlink."
    fi
    if [[ ! -d "${path}" ]]; then
      die "Refusing to bootstrap: ${path} exists and is not a directory."
    fi
    talos_config_check_dir_secure "${path}" \
      || die "Refusing to bootstrap: ${path} exists but failed the secure directory check (fix ownership/mode 0700 or remove it manually)."
    return 0
  fi

  mkdir -p "${path}"
  chmod 700 "${path}"
}

# @description Refuses a pre-existing bootstrap file that is a symlink, not a
#   regular file, or fails the secure-permissions check, before any
#   chmod/write happens. `force` may only overwrite a file that has already
#   passed that check (an already-validated, regular, in-tree file); it never
#   overwrites through a symlink or an unsafe file. Idempotent for an
#   already-valid file when force is not set.
# @arg $1 path Target file path.
# @arg $2 required_mode Required/target file mode (for example "600").
# @arg $3 force "true" to overwrite an already-validated existing file.
# @arg $4 writer Name of a function that writes default content: writer(path, ...).
# @arg $@ writer_args Additional arguments forwarded to the writer after path.
_talos_config_bootstrap_file() {
  local path="$1"
  local required_mode="$2"
  local force="$3"
  local writer="$4"
  shift 4
  local -a writer_args=("$@")

  if [[ -e "${path}" || -L "${path}" ]]; then
    if [[ -L "${path}" ]]; then
      die "Refusing to bootstrap: ${path} exists and is a symlink."
    fi
    if [[ ! -f "${path}" ]]; then
      die "Refusing to bootstrap: ${path} exists and is not a regular file."
    fi
    talos_config_check_file_secure "${path}" "${required_mode}" \
      || die "Refusing to bootstrap: ${path} exists but failed the secure file check (fix ownership/mode 0${required_mode} or remove it manually)."

    if [[ "${force}" == "true" ]]; then
      "${writer}" "${path}" ${writer_args[@]+"${writer_args[@]}"}
      chmod "${required_mode}" "${path}"
      log_info "Overwrote (force): ${path}"
    else
      log_info "Already exists and is valid (use --force to overwrite): ${path}"
    fi
    return 0
  fi

  "${writer}" "${path}" ${writer_args[@]+"${writer_args[@]}"}
  chmod "${required_mode}" "${path}"
  log_info "Wrote: ${path}"
}

# @description Idempotently creates base/config.yaml, environments/<name>/
#   config.yaml, and environments/<name>/credentials.yaml with safe
#   directory (0700) and file (0600) permissions. Refuses any pre-existing
#   symlink or otherwise unsafe directory/file before touching it, at every
#   toolchain-managed ancestor level (the `talos-toolchain` root, its
#   `environments` parent, `base/`, and `environments/<name>/`), not only the
#   leaf directories. Existing, already-valid files are left untouched unless
#   force="true".
# @arg $1 env_name Environment name.
# @arg $2 force "true" to overwrite existing, already-valid files.
talos_config_bootstrap() {
  local env_name="${1:?Environment name is required}"
  local force="${2:-false}"
  local home_dir environments_dir base_dir env_dir base_file env_file cred_file

  talos_config_require_valid_env_name "${env_name}"

  home_dir="$(talos_config_home)"
  environments_dir="${home_dir}/environments"
  base_dir="$(talos_config_base_dir)"
  env_dir="$(talos_config_env_dir "${env_name}")"
  base_file="$(talos_config_base_file)"
  env_file="$(talos_config_env_file "${env_name}")"
  cred_file="$(talos_config_credentials_file "${env_name}")"

  # Ancestors are checked/created root-first: mkdir -p on a deeper path must
  # never be the first thing to touch a shallower, unverified ancestor.
  _talos_config_bootstrap_dir "${home_dir}"
  _talos_config_bootstrap_dir "${environments_dir}"
  _talos_config_bootstrap_dir "${base_dir}"
  _talos_config_bootstrap_dir "${env_dir}"

  _talos_config_bootstrap_file "${base_file}" "600" "${force}" _talos_config_write_default_base
  _talos_config_bootstrap_file "${env_file}" "600" "${force}" _talos_config_write_default_env "${env_name}"
  _talos_config_bootstrap_file "${cred_file}" "600" "${force}" _talos_config_write_default_credentials
}

# --- Schema validation ---------------------------------------------------------

# @description Validates every node in a YAML file (not only scalar leaves)
#   against the given schema table. A path that exactly matches a schema
#   leaf must be a scalar of the declared type (str/int/bool): null, float,
#   empty/non-empty maps, and empty/non-empty lists are all rejected there,
#   since none of them are a supported shape for a scalar field. A path that
#   is a strict prefix of a schema leaf (a namespace, e.g. "talos") must be a
#   mapping (empty or not); any other shape there is rejected too. Every
#   other path, empty or not, null or not, is an unknown key and rejected.
#   A malformed/unparseable YAML file is rejected outright, before any of the
#   above walks its (nonexistent) output.
# @arg $1 file YAML file to validate.
# @arg $2 table_name Name of a "path|ENV_VAR|type" table variable in scope.
talos_config_validate_schema() {
  local file="$1"
  local table_name="$2"
  local path tag entry expected_type actual_type prefixes
  local failures=0
  local yq_output=""
  local yq_status=0

  talos_config_require_yq

  # Captured via command substitution (not a `< <(...)` process substitution)
  # specifically so yq's own exit status is available here: a process
  # substitution's exit status is not checked by the consuming `while` loop,
  # so a parse error would otherwise leave `failures` at 0 and the file would
  # be silently accepted.
  yq_output="$(yq eval '.. | select(path | length > 0) | [path | join("."), tag] | @csv' "${file}" 2>&1)" || yq_status=$?
  if [[ "${yq_status}" -ne 0 ]]; then
    log_error "Failed to parse YAML file ${file}: ${yq_output}"
    return 1
  fi

  prefixes="$(_talos_config_schema_prefixes "${table_name}")"

  while IFS=',' read -r path tag; do
    [[ -n "${path}" ]] || continue

    entry="$(_talos_config_schema_lookup "${table_name}" "${path}")"
    if [[ -n "${entry}" ]]; then
      expected_type="${entry#*|}"
      case "${tag}" in
        '!!str') actual_type="str" ;;
        '!!int') actual_type="int" ;;
        '!!bool') actual_type="bool" ;;
        *) actual_type="${tag}" ;;
      esac
      if [[ "${actual_type}" != "${expected_type}" ]]; then
        log_error "Invalid value for '${path}' in ${file}: expected ${expected_type}, got ${tag}"
        failures=$((failures + 1))
      fi
      continue
    fi

    if _talos_config_is_schema_prefix "${path}" "${prefixes}"; then
      if [[ "${tag}" != "!!map" ]]; then
        log_error "Invalid shape for '${path}' in ${file}: expected a mapping, got ${tag}"
        failures=$((failures + 1))
      fi
      continue
    fi

    log_error "Unknown configuration key '${path}' in ${file}"
    failures=$((failures + 1))
  done <<< "${yq_output}"

  [[ "${failures}" -eq 0 ]]
}

# --- Load and export with precedence --------------------------------------------

_talos_config_export_from_file() {
  local file="$1"
  local table_name="$2"
  local table_value="${!table_name}"
  local path env_var _type value

  while IFS='|' read -r path env_var _type; do
    [[ -n "${path}" ]] || continue
    value="$(yq eval ".${path} // \"\"" "${file}" 2>/dev/null)"
    if [[ -n "${value}" && "${value}" != "null" ]]; then
      export "${env_var}=${value}"
    fi
  done <<< "${table_value}"
}

# @description Reads a single dotted path from a config file, before the full
#   layered load runs. Needed for exactly one bootstrapping problem: the
#   environment name must be known in order to load the environment layer, and
#   a project declares which environment it belongs to inside its own
#   config.yaml. Applies the same secure-file check as the full loader; prints
#   nothing when the file is absent or the key is unset.
# @arg $1 file Config file to read.
# @arg $2 path Dotted YAML path, for example "cluster.environment".
talos_config_read_field() {
  local file="$1"
  local path="$2"
  local value=""

  [[ -f "${file}" ]] || return 0
  talos_config_check_file_secure "${file}" || die "Refusing to read insecure config: ${file}"
  talos_config_require_yq

  value="$(yq eval ".${path} // \"\"" "${file}" 2>/dev/null)"
  [[ -n "${value}" && "${value}" != "null" ]] || return 0
  printf '%s\n' "${value}"
}

# @description Loads defaults, base YAML, project intent (non-secret), the
#   named environment YAML, and its credentials file, exporting mapped
#   environment variables in that precedence order. CLI flags are applied by
#   the caller after this returns, so they remain the final override.
# @arg $1 env_name Environment name.
# @arg $2 project_config_file Optional tracked project config.yaml (no secrets).
talos_config_load() {
  local env_name="${1:?Environment name is required}"
  local project_config_file="${2:-}"
  local base_file env_file cred_file

  # Validated eagerly as a plain statement (not inside a command
  # substitution): a failing command substitution inside a plain assignment
  # does not trigger `set -e` in the caller, so die()/exit here must happen
  # before any "path=$(...)" assignment below, or an invalid name would
  # silently continue with an empty path instead of aborting.
  talos_config_require_valid_env_name "${env_name}"

  talos_config_require_yq

  # Refuse before reading anything if the talos-toolchain root or its
  # environments/ parent is present but unsafe (for example swapped for a
  # symlink pointing outside the XDG tree) — a leaf file can individually
  # pass its own secure-file check while still being reached only through
  # such an unsafe ancestor.
  talos_config_require_secure_ancestors "$(talos_config_home)"

  base_file="$(talos_config_base_file)"
  env_file="$(talos_config_env_file "${env_name}")"
  cred_file="$(talos_config_credentials_file "${env_name}")"

  if [[ -f "${base_file}" ]]; then
    talos_config_check_file_secure "${base_file}" || die "Refusing to read insecure base config: ${base_file}"
    talos_config_validate_schema "${base_file}" TALOS_CONFIG_SCHEMA_TABLE || die "Rejected base config schema: ${base_file}"
    _talos_config_export_from_file "${base_file}" TALOS_CONFIG_SCHEMA_TABLE
  fi

  if [[ -n "${project_config_file}" && -f "${project_config_file}" ]]; then
    talos_config_check_file_secure "${project_config_file}" || die "Refusing to read insecure project config: ${project_config_file}"
    talos_config_validate_schema "${project_config_file}" TALOS_CONFIG_SCHEMA_TABLE || die "Rejected project config schema: ${project_config_file}"
    _talos_config_export_from_file "${project_config_file}" TALOS_CONFIG_SCHEMA_TABLE
  fi

  if [[ -f "${env_file}" ]]; then
    talos_config_check_file_secure "${env_file}" || die "Refusing to read insecure environment config: ${env_file}"
    talos_config_validate_schema "${env_file}" TALOS_CONFIG_SCHEMA_TABLE || die "Rejected environment config schema: ${env_file}"
    _talos_config_export_from_file "${env_file}" TALOS_CONFIG_SCHEMA_TABLE
  fi

  if [[ -f "${cred_file}" ]]; then
    talos_config_check_file_secure "${cred_file}" "600" || die "Refusing to read insecure credentials file: ${cred_file}"
    talos_config_validate_schema "${cred_file}" TALOS_CONFIG_SECRET_SCHEMA_TABLE || die "Rejected credentials schema: ${cred_file}"
    _talos_config_export_from_file "${cred_file}" TALOS_CONFIG_SECRET_SCHEMA_TABLE
  fi
}

# --- Redacted diagnostics --------------------------------------------------------

# @description Prints the resolved configuration for an environment with
#   every secret-schema value redacted, regardless of which file it came
#   from. Never prints raw credentials.yaml contents.
# @arg $1 env_name Environment name.
talos_config_show_redacted() {
  local env_name="${1:?Environment name is required}"
  local path env_var _type value

  talos_config_require_valid_env_name "${env_name}"
  talos_config_load "${env_name}"

  {
    while IFS='|' read -r path env_var _type; do
      [[ -n "${path}" ]] || continue
      value="${!env_var:-}"
      if [[ -n "${value}" ]]; then
        printf '%s=%s\n' "${env_var}" "${value}"
      fi
    done <<< "${TALOS_CONFIG_SCHEMA_TABLE}"

    while IFS='|' read -r path env_var _type; do
      [[ -n "${path}" ]] || continue
      value="${!env_var:-}"
      if [[ -n "${value}" ]]; then
        printf '%s=%s\n' "${env_var}" "[REDACTED]"
      fi
    done <<< "${TALOS_CONFIG_SECRET_SCHEMA_TABLE}"
  } | sort
}
