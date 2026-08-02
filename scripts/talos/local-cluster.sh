#!/usr/bin/env bash
# @file local-cluster.sh
# @brief Isolated local Talos Docker/Colima lifecycle wrapper (Milestone A).
# @description
#   Dedicated create/status/destroy wrapper around `talosctl cluster create
#   --provisioner docker` for a single local development cluster. This is a
#   separate entrypoint from the vSphere-oriented cluster.sh: it never
#   sources vSphere/VMware variables, never touches provision-talos-vsphere,
#   and never installs, starts, or reconfigures Colima or the Docker daemon.
#   Every cluster is isolated under its own directory keyed by a safe cluster
#   name, rooted at an XDG state directory (default
#   ${XDG_STATE_HOME:-$HOME/.local/state}/talos-toolchain/local-clusters), so
#   talosconfig/kubeconfig/Talos state never collide across clusters or with
#   the operator's default ~/.talos or ~/.kube/config.
#
# @arg create action Create the local Docker-backed Talos cluster.
# @arg status action Print read-only diagnostics for the local cluster.
# @arg destroy action Tear down the local Docker-backed Talos cluster.
#
# @arg --name name Safe cluster name (required for all actions).
# @arg --state-root path Override the XDG state root directory (advanced/test use).
#   Must be an absolute path, must not be "/", and must not contain a ".."
#   segment. Every managed path (state root, its parent for the default XDG
#   layout, cluster directory, Talos state directory, talosconfig,
#   kubeconfig, wrapper marker) is also checked for symlinks before it is
#   read, written, created, passed to talosctl, or removed.
# @arg --controlplanes int Control-plane node count for create (default 1).
# @arg --workers int Worker node count for create (default 1).
# @flag --confirm-destroy Required to actually run destroy (not needed for --dry-run).
# @flag --dry-run,-n Print actions without executing or mutating the host.
# @flag --help,-h Show usage information.
#
# @example
#   # Create an isolated local cluster (dry-run first)
#   ./local-cluster.sh create --name=dev --dry-run
#   ./local-cluster.sh create --name=dev
#
# @example
#   # Inspect and tear down
#   ./local-cluster.sh status --name=dev
#   ./local-cluster.sh destroy --name=dev --dry-run
#   ./local-cluster.sh destroy --name=dev --confirm-destroy
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/bash-preflight.sh"
talos_require_bash5 "${SCRIPT_PATH}" "$@"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

ACTION=""
CLUSTER_NAME=""
STATE_ROOT_OVERRIDE=""
CONTROLPLANES="1"
WORKERS="1"
CONFIRM_DESTROY="false"
DRY_RUN="false"

MARKER_NAME=".talos-toolchain-local-cluster"

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") <action> --name=<name> [options]

Actions:
  create   Create the local Docker-backed Talos cluster
  status   Print read-only diagnostics (never starts Colima/Docker)
  destroy  Tear down the local Docker-backed Talos cluster

Options:
  --name=<name>          Safe cluster name (required): lowercase alphanumeric
                         and dashes only, e.g. "dev" or "talos-local-1"
  --state-root=<path>    Override the XDG state root (advanced/test use).
                         Must be absolute, not "/", and free of ".." segments.
  --controlplanes=<n>    Control-plane node count for create (default 1)
  --workers=<n>          Worker node count for create (default 1)
  --confirm-destroy      Required to actually run destroy (not required with --dry-run)
  -n, --dry-run          Print actions without executing or mutating the host
  -h, --help             Show this help

This wrapper never invokes VMware/vSphere code or variables, and never
starts, stops, or reconfigures Colima or the Docker daemon. Start Colima
yourself first (for example: colima start) if it is not already running.

Examples:
  $(basename "$0") create --name=dev --dry-run
  $(basename "$0") create --name=dev
  $(basename "$0") status --name=dev
  $(basename "$0") destroy --name=dev --dry-run
  $(basename "$0") destroy --name=dev --confirm-destroy
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      create|status|destroy)
        [[ -z "${ACTION}" ]] || die "Action already set: ${ACTION}"
        ACTION="$1"
        shift
        ;;
      --name=*) CLUSTER_NAME="${1#*=}"; shift ;;
      --state-root=*) STATE_ROOT_OVERRIDE="${1#*=}"; shift ;;
      --controlplanes=*) CONTROLPLANES="${1#*=}"; shift ;;
      --workers=*) WORKERS="${1#*=}"; shift ;;
      --confirm-destroy) CONFIRM_DESTROY="true"; shift ;;
      -n|--dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "${ACTION}" ]] || { usage; die "Action is required."; }
  [[ -n "${CLUSTER_NAME}" ]] || { usage; die "--name is required."; }
}

# @description Rejects anything but a safe, single-path-segment cluster name:
#   lowercase alphanumeric and internal dashes, 1-63 chars. This blocks path
#   traversal ("..", "/") and shell-hostile characters before the name is
#   ever used to build a filesystem path or a talosctl argument.
require_safe_cluster_name() {
  local name="$1"
  if [[ ! "${name}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    die "Unsafe or invalid --name '${name}'. Use lowercase alphanumeric characters and dashes only (no '.', '/', or leading/trailing dash)."
  fi
}

USING_STATE_ROOT_OVERRIDE="false"

# @description Rejects a state root that is not an absolute path, is exactly
#   "/", or contains a ".." path segment anywhere (traversal-shaped, even
#   when the overall path is absolute, e.g. "/var/foo/../../etc"). Applied to
#   both an explicit --state-root override and the resolved default XDG path,
#   so the default is validated the same way it is trusted.
require_safe_state_root() {
  local path="$1"
  [[ "${path}" == /* ]] || die "--state-root must be an absolute path: '${path}'."
  [[ "${path}" != "/" ]] || die "--state-root must not be '/'."
  if [[ "${path}" =~ (^|/)\.\.(/|$) ]]; then
    die "--state-root must not contain '..' path segments: '${path}'."
  fi
}

resolve_state_root() {
  local resolved=""
  if [[ -n "${STATE_ROOT_OVERRIDE}" ]]; then
    USING_STATE_ROOT_OVERRIDE="true"
    resolved="${STATE_ROOT_OVERRIDE}"
  else
    USING_STATE_ROOT_OVERRIDE="false"
    local xdg_state_home="${XDG_STATE_HOME:-${HOME}/.local/state}"
    resolved="${xdg_state_home}/talos-toolchain/local-clusters"
  fi
  require_safe_state_root "${resolved}"
  printf '%s\n' "${resolved}"
}

# @description Populates the isolated per-cluster path globals. Must run
#   after require_safe_cluster_name so CLUSTER_DIR can never escape STATE_ROOT.
set_cluster_paths() {
  local state_root="$1"
  local name="$2"
  STATE_ROOT="${state_root}"
  CLUSTER_DIR="${state_root}/${name}"
  TALOS_STATE_DIR="${CLUSTER_DIR}/talos-state"
  TALOSCONFIG_PATH="${CLUSTER_DIR}/talosconfig"
  KUBECONFIG_PATH="${CLUSTER_DIR}/kubeconfig"
  MARKER_FILE="${CLUSTER_DIR}/${MARKER_NAME}"
}

# @description Defense in depth: refuse to touch a resolved cluster
#   directory that does not lexically live under the resolved state root.
#   This is a name-shape check only; require_state_tree_safe below does the
#   filesystem-aware (symlink-aware) verification and must also run before
#   any path here is read, written, passed to talosctl, or removed.
require_cluster_dir_contained() {
  case "${CLUSTER_DIR}" in
    "${STATE_ROOT}"/*) return 0 ;;
    *) die "Refusing to operate: resolved cluster dir '${CLUSTER_DIR}' escapes state root '${STATE_ROOT}'." ;;
  esac
}

# @description Refuses a path that currently exists as a symlink. A path
#   that does not exist yet is not an error (nothing has been created there).
require_not_symlink_if_present() {
  local path="$1"
  local label="$2"
  if [[ -L "${path}" ]]; then
    die "Refusing to operate: ${label} exists and is a symlink: ${path}"
  fi
}

# @description Refuses a path that exists as a symlink or exists as
#   something other than a directory, before it is created, traversed
#   (mkdir -p), passed as talosctl --state, or removed.
require_dir_safe_if_present() {
  local path="$1"
  local label="$2"
  require_not_symlink_if_present "${path}" "${label}"
  if [[ -e "${path}" && ! -d "${path}" ]]; then
    die "Refusing to operate: ${label} exists and is not a directory: ${path}"
  fi
}

# @description Refuses a path that exists as a symlink or exists as
#   something other than a regular file, before it is read, written, or
#   passed to talosctl.
require_file_safe_if_present() {
  local path="$1"
  local label="$2"
  require_not_symlink_if_present "${path}" "${label}"
  if [[ -e "${path}" && ! -f "${path}" ]]; then
    die "Refusing to operate: ${label} exists and is not a regular file: ${path}"
  fi
}

# @description Filesystem-aware containment: verifies every path this
#   wrapper manages (the state root, its own parent when using the default
#   XDG layout, the cluster directory, the Talos state directory, and the
#   talosconfig/kubeconfig/marker files) is not a symlink and, if present,
#   is the expected node type. Must run before any of these paths is read,
#   written, created, passed to talosctl (for example --state), or removed,
#   so a pre-existing symlink can never redirect an action outside the
#   isolated cluster directory. Complements, and never replaces, the
#   lexical require_cluster_dir_contained check above.
require_state_tree_safe() {
  if [[ "${USING_STATE_ROOT_OVERRIDE}" != "true" ]]; then
    require_dir_safe_if_present "$(dirname "${STATE_ROOT}")" "State root parent directory"
  fi
  require_dir_safe_if_present "${STATE_ROOT}" "State root"
  require_dir_safe_if_present "${CLUSTER_DIR}" "Cluster directory"
  require_dir_safe_if_present "${TALOS_STATE_DIR}" "Talos state directory"
  require_file_safe_if_present "${TALOSCONFIG_PATH}" "talosconfig"
  require_file_safe_if_present "${KUBECONFIG_PATH}" "kubeconfig"
  require_file_safe_if_present "${MARKER_FILE}" "Wrapper marker"
}

# @description Diagnostic-only Docker daemon reachability check. Never
#   starts, installs, or reconfigures Docker.
check_docker_daemon() {
  if docker info >/dev/null 2>&1; then
    log_info "Docker daemon: responsive"
    return 0
  fi
  log_error "Docker daemon is not responsive (docker info failed)."
  log_error "This wrapper never starts or configures Docker. Start Docker/Colima yourself and re-run."
  return 1
}

# @description Diagnostic-only Colima state report. Never starts, stops, or
#   reconfigures Colima; a non-running Colima is reported, not corrected.
report_colima_state() {
  local colima_output=""
  if colima_output="$(colima status 2>&1)"; then
    log_info "Colima status: ${colima_output}"
  else
    log_warn "Colima status: ${colima_output:-not running}"
    log_warn "This wrapper never starts Colima. Run 'colima start' yourself if the Docker backend is meant to be Colima."
  fi
}

preflight_common() {
  talos_require_commands talosctl docker colima
}

do_create() {
  require_safe_cluster_name "${CLUSTER_NAME}"
  local state_root=""
  state_root="$(resolve_state_root)"
  set_cluster_paths "${state_root}" "${CLUSTER_NAME}"
  require_cluster_dir_contained
  require_state_tree_safe

  preflight_common
  report_colima_state
  check_docker_daemon || die "Docker daemon preflight failed. See message above."

  if [[ -f "${MARKER_FILE}" ]]; then
    die "Cluster '${CLUSTER_NAME}' already has wrapper state at ${CLUSTER_DIR}. Run 'destroy --name=${CLUSTER_NAME}' first, or choose a different --name."
  fi

  local create_cmd=(
    talosctl cluster create
    --name "${CLUSTER_NAME}"
    --provisioner docker
    --state "${TALOS_STATE_DIR}"
    --talosconfig "${TALOSCONFIG_PATH}"
    --controlplanes "${CONTROLPLANES}"
    --workers "${WORKERS}"
  )
  local kubeconfig_cmd=(
    talosctl kubeconfig "${KUBECONFIG_PATH}"
    --talosconfig "${TALOSCONFIG_PATH}"
    --nodes "${CLUSTER_NAME}-controlplane-1"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] mkdir -p ${TALOS_STATE_DIR}"
    log_info "[DRY-RUN] ${create_cmd[*]}"
    log_info "[DRY-RUN] ${kubeconfig_cmd[*]}"
    log_info "[DRY-RUN] write marker ${MARKER_FILE}"
    return 0
  fi

  mkdir -p "${TALOS_STATE_DIR}"
  log_info "Creating local cluster '${CLUSTER_NAME}': ${create_cmd[*]}"
  "${create_cmd[@]}"
  log_info "Fetching isolated kubeconfig: ${kubeconfig_cmd[*]}"
  "${kubeconfig_cmd[@]}"

  {
    printf 'name=%s\n' "${CLUSTER_NAME}"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "${MARKER_FILE}"

  log_info "Local cluster '${CLUSTER_NAME}' created."
  log_info "talosconfig: ${TALOSCONFIG_PATH}"
  log_info "kubeconfig:  ${KUBECONFIG_PATH}"
}

do_status() {
  require_safe_cluster_name "${CLUSTER_NAME}"
  local state_root=""
  state_root="$(resolve_state_root)"
  set_cluster_paths "${state_root}" "${CLUSTER_NAME}"
  require_cluster_dir_contained
  require_state_tree_safe

  preflight_common
  report_colima_state
  check_docker_daemon || true

  if [[ -f "${MARKER_FILE}" ]]; then
    log_info "Wrapper marker: present (${MARKER_FILE})"
  else
    log_warn "Wrapper marker: absent. This wrapper did not create '${CLUSTER_NAME}' at ${CLUSTER_DIR}."
  fi

  if [[ ! -d "${TALOS_STATE_DIR}" ]]; then
    log_warn "No Talos state directory at ${TALOS_STATE_DIR}; cluster likely not created."
    return 0
  fi

  local show_cmd=(
    talosctl cluster show
    --name "${CLUSTER_NAME}"
    --provisioner docker
    --state "${TALOS_STATE_DIR}"
    --talosconfig "${TALOSCONFIG_PATH}"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] ${show_cmd[*]}"
    return 0
  fi

  log_info "Cluster status: ${show_cmd[*]}"
  "${show_cmd[@]}"
}

do_destroy() {
  require_safe_cluster_name "${CLUSTER_NAME}"
  local state_root=""
  state_root="$(resolve_state_root)"
  set_cluster_paths "${state_root}" "${CLUSTER_NAME}"
  require_cluster_dir_contained
  require_state_tree_safe

  preflight_common

  if [[ ! -f "${MARKER_FILE}" ]]; then
    die "Refusing to destroy: no wrapper marker at ${MARKER_FILE}. This wrapper only destroys clusters it created; nothing else under ${CLUSTER_DIR} was touched."
  fi

  local marker_name=""
  marker_name="$(awk -F= '$1=="name"{print $2; exit}' "${MARKER_FILE}")"
  if [[ "${marker_name}" != "${CLUSTER_NAME}" ]]; then
    die "Refusing to destroy: marker at ${MARKER_FILE} records name '${marker_name}', not requested '${CLUSTER_NAME}'."
  fi

  local destroy_cmd=(
    talosctl cluster destroy
    --name "${CLUSTER_NAME}"
    --provisioner docker
    --state "${TALOS_STATE_DIR}"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] ${destroy_cmd[*]}"
    log_info "[DRY-RUN] rm -rf ${CLUSTER_DIR}"
    return 0
  fi

  if [[ "${CONFIRM_DESTROY}" != "true" ]]; then
    die "Refusing to destroy '${CLUSTER_NAME}' without --confirm-destroy. Re-run with --dry-run first to preview, then add --confirm-destroy."
  fi

  log_info "Destroying local cluster '${CLUSTER_NAME}': ${destroy_cmd[*]}"
  "${destroy_cmd[@]}"

  require_cluster_dir_contained
  require_dir_safe_if_present "${CLUSTER_DIR}" "Cluster directory"
  rm -rf "${CLUSTER_DIR}"
  log_info "Removed isolated state directory: ${CLUSTER_DIR}"
}

main() {
  parse_args "$@"

  case "${ACTION}" in
    create) do_create ;;
    status) do_status ;;
    destroy) do_destroy ;;
  esac
}

main "$@"
