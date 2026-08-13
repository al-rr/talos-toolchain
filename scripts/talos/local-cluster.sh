#!/usr/bin/env bash
# @file local-cluster.sh
# @brief Isolated local Talos Docker/Colima lifecycle wrapper (Milestone A).
# @description
#   Dedicated create/status/destroy wrapper around `talosctl cluster create
#   docker` for a single local development cluster. This is a
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
# @arg --controlplanes int Control-plane node count for create. The Talos
#   Docker backend supports exactly 1; any other value is rejected before
#   talosctl is invoked (default 1).
# @arg --workers int Worker node count for create (default 1).
# @arg --memory-controlplanes string(mb,gb) Per-control-plane-node memory
#   limit passed through to `talosctl cluster create docker
#   --memory-controlplanes`. Omitted by default, which leaves talosctl's own
#   default (2.0GiB) in effect. Measured need: the full lab addon set
#   (cert-manager, Cilium, Longhorn, kube-prometheus-stack, Argo CD)
#   installed together on a fresh cluster saturates the 2GiB default --
#   sustained ~99% memory on the worker, kubelet losing/regaining Ready, and
#   restart churn on argocd-server and longhorn-manager that is a resource
#   symptom, not an addon config problem. See
#   talos-vsphere-gitops/docs/en/day2-operations.md section 3.
# @arg --memory-workers string(mb,gb) Per-worker-node memory limit, same
#   passthrough and rationale as --memory-controlplanes.
# @arg --cpus-controlplanes string Per-control-plane-node CPU share passed
#   through to `talosctl cluster create docker --cpus-controlplanes`.
#   Omitted by default (talosctl's own default, 2.0).
# @arg --cpus-workers string Per-worker-node CPU share, same passthrough as
#   --cpus-controlplanes.
# @arg --cni name Local CNI mode for create: "flannel" (default, unchanged
#   Talos-managed CNI) or "cilium" (Talos CNI is set to "none" and Cilium is
#   bootstrapped day-1 from a local GitOps `lab` checkout).
# @arg --gitops-repo-root path Local talos-vsphere-gitops checkout root.
#   Required when --cni=cilium; must be on branch "lab" with a clean working
#   tree. Never modified: this wrapper only reads its lab environment files.
# @arg --docker-endpoint endpoint Explicit Docker endpoint (for example
#   "unix:///var/run/docker.sock") passed to the Talos Docker lifecycle
#   command for create. When omitted, an explicit `DOCKER_HOST` in the
#   environment is used if set; otherwise a Colima Docker socket is resolved
#   from `colima status` and validated before use. Create fails clearly if
#   no endpoint can be resolved.
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
#   # Create with a local Cilium day-1 bootstrap instead of managed Flannel
#   ./local-cluster.sh create --name=dev --cni=cilium \
#     --gitops-repo-root=../talos-vsphere-gitops --dry-run
#   ./local-cluster.sh create --name=dev --cni=cilium \
#     --gitops-repo-root=../talos-vsphere-gitops
#
# @example
#   # Inspect and tear down
#   ./local-cluster.sh status --name=dev
#   ./local-cluster.sh destroy --name=dev --dry-run
#   ./local-cluster.sh destroy --name=dev --confirm-destroy
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

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
MEMORY_CONTROLPLANES=""
MEMORY_WORKERS=""
CPUS_CONTROLPLANES=""
CPUS_WORKERS=""
CONFIRM_DESTROY="false"
DRY_RUN="false"
CNI_MODE="flannel"
GITOPS_REPO_ROOT=""
DOCKER_ENDPOINT_OVERRIDE=""

MARKER_NAME=".talos-toolchain-local-cluster"
GITOPS_LAB_ENVIRONMENT="lab"
CILIUM_API_PORT="6443"
CILIUM_API_HOST_IP="127.0.0.1"
# Overridable only for the offline test suite, so it never has to sleep
# through a real 60s timeout to exercise the failure path.
CILIUM_API_PORT_WAIT_SECONDS="${TALOS_LOCAL_CLUSTER_API_PORT_WAIT_SECONDS:-60}"
# Overridable only for the offline test suite, for the same reason as above.
CILIUM_KUBECONFIG_FETCH_WAIT_SECONDS="${TALOS_LOCAL_CLUSTER_KUBECONFIG_FETCH_WAIT_SECONDS:-120}"
# The /readyz gate's budget has to cover far more than "kube-apiserver
# starts". The Docker port mapping is published when the container is created,
# so this countdown begins long before the cluster is bootstrapped, and the
# API cannot answer 200 until the whole chain completes: Talos API up ->
# `talosctl cluster create docker` runs its bootstrap step -> etcd converges
# to Running -> kube-apiserver serves. On a laptop that is minutes, not
# seconds. A 60s budget cut this off mid-bootstrap, while etcd was still
# "Preparing", and reported a timeout for a cluster that was coming up
# normally. Overridable for the offline test suite, which must not sleep
# through a real timeout to exercise the failure path.
CILIUM_API_READYZ_WAIT_SECONDS="${TALOS_LOCAL_CLUSTER_API_READYZ_WAIT_SECONDS:-600}"
# How often to log that the gate is still waiting, so a multi-minute, silent
# but healthy bootstrap is not mistaken for a hang.
CILIUM_API_READYZ_PROGRESS_SECONDS="${TALOS_LOCAL_CLUSTER_API_READYZ_PROGRESS_SECONDS:-30}"
CILIUM_COREDNS_ROLLOUT_TIMEOUT="180s"

# The shared Talos machine-config patch model -- the same one cluster.sh
# create-project materializes. There is exactly one copy of these defaults in
# the repository; see cluster-patches/README.md.
#
# This backend consumes the subset that is meaningful on Docker: the per-node
# static-network patches and longhorn.patch.yaml have no Docker equivalent
# (Docker assigns addresses on its own subnet, and there is no second block
# device to partition).
PATCH_MODEL_DIR="${REPO_ROOT}/cluster-patches"
PATCH_FILE_NAMES=(cni.patch.yaml cp.patch.yaml worker.patch.yaml)

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
  --controlplanes=<n>    Control-plane node count for create (default 1).
                         The Talos Docker backend supports exactly 1.
  --workers=<n>          Worker node count for create (default 1)
  --memory-controlplanes=<val>  Per-control-plane memory limit (e.g. "4GB"),
                         passed through to talosctl. Default: talosctl's own
                         2.0GiB. Raise this if the addon set you install
                         saturates memory -- see the day-2 GitOps repo's
                         day2-operations.md section 3 for measured evidence.
  --memory-workers=<val>       Per-worker memory limit, same as above.
  --cpus-controlplanes=<val>   Per-control-plane CPU share (e.g. "4.0"),
                         passed through to talosctl. Default: talosctl's own 2.0.
  --cpus-workers=<val>         Per-worker CPU share, same as above.
  --cni=<mode>           Local CNI mode for create: "flannel" (default,
                         unchanged Talos-managed CNI) or "cilium" (Talos CNI
                         is set to "none"; Cilium is bootstrapped day-1 from
                         a local GitOps "lab" checkout).
  --gitops-repo-root=<path>  Local talos-vsphere-gitops checkout root.
                         Required with --cni=cilium; must be on branch "lab"
                         with a clean working tree. Read-only: never modified.
  --docker-endpoint=<endpoint>  Explicit Docker endpoint for create (for
                         example "unix:///var/run/docker.sock"). When
                         omitted, an explicit DOCKER_HOST in the environment
                         is used if set; otherwise a Colima Docker socket is
                         resolved from "colima status" and validated. Create
                         fails clearly if no endpoint can be resolved.
  --confirm-destroy      Required to actually run destroy (not required with --dry-run)
  -n, --dry-run          Print actions without executing or mutating the host
  -h, --help             Show this help

This wrapper never invokes VMware/vSphere code or variables, and never
starts, stops, or reconfigures Colima or the Docker daemon. Start Colima
yourself first (for example: colima start) if it is not already running.

Examples:
  $(basename "$0") create --name=dev --dry-run
  $(basename "$0") create --name=dev
  $(basename "$0") create --name=dev --cni=cilium --gitops-repo-root=../talos-vsphere-gitops --dry-run
  $(basename "$0") create --name=dev --cni=cilium --gitops-repo-root=../talos-vsphere-gitops
  $(basename "$0") create --name=dev --cni=cilium --gitops-repo-root=../talos-vsphere-gitops \\
    --memory-workers=4GB --memory-controlplanes=4GB
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
      --memory-controlplanes=*) MEMORY_CONTROLPLANES="${1#*=}"; shift ;;
      --memory-workers=*) MEMORY_WORKERS="${1#*=}"; shift ;;
      --cpus-controlplanes=*) CPUS_CONTROLPLANES="${1#*=}"; shift ;;
      --cpus-workers=*) CPUS_WORKERS="${1#*=}"; shift ;;
      --cni=*) CNI_MODE="${1#*=}"; shift ;;
      --gitops-repo-root=*) GITOPS_REPO_ROOT="${1#*=}"; shift ;;
      --docker-endpoint=*) DOCKER_ENDPOINT_OVERRIDE="${1#*=}"; shift ;;
      --confirm-destroy) CONFIRM_DESTROY="true"; shift ;;
      -n|--dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "${ACTION}" ]] || { usage; die "Action is required."; }
  [[ -n "${CLUSTER_NAME}" ]] || { usage; die "--name is required."; }

  case "${CNI_MODE}" in
    flannel|cilium) ;;
    *) usage; die "Invalid --cni='${CNI_MODE}'. Use 'flannel' or 'cilium'." ;;
  esac
  if [[ "${CNI_MODE}" == "cilium" ]]; then
    [[ -n "${GITOPS_REPO_ROOT}" ]] || { usage; die "--gitops-repo-root is required when --cni=cilium."; }
  fi
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

# @description The Talos Docker backend (`talosctl cluster create docker`)
#   exposes no control-plane-count flag and always creates exactly one
#   control plane. Reject any other requested count explicitly instead of
#   silently ignoring it.
require_docker_controlplanes_supported() {
  local count="$1"
  if [[ "${count}" != "1" ]]; then
    die "--controlplanes=${count} is not supported: the Talos Docker backend always creates exactly 1 control plane."
  fi
}

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
  # The materialized per-cluster patch project (--cni=cilium only). It lives
  # beside talos-state/ so a cluster's machine-config inputs and its Talos
  # state are destroyed together and can never outlive each other.
  CLUSTER_PATCH_DIR="${CLUSTER_DIR}/patches"
  CLUSTER_CNI_PATCH="${CLUSTER_PATCH_DIR}/cni.patch.yaml"
  CLUSTER_CP_PATCH="${CLUSTER_PATCH_DIR}/cp.patch.yaml"
  CLUSTER_WORKER_PATCH="${CLUSTER_PATCH_DIR}/worker.patch.yaml"
}

# @description Write the wrapper ownership marker.
# @arg $1 string Lifecycle state: "creating" before the backend runs,
#   "ready" once the cluster is fully up.
# @internal
write_marker() {
  local state="$1"
  local created_at=""
  # Preserve the original timestamp when promoting creating -> ready, so the
  # marker records when the cluster was claimed rather than when it finished.
  if [[ -f "${MARKER_FILE}" ]]; then
    created_at="$(awk -F= '$1=="created_at"{print $2; exit}' "${MARKER_FILE}")"
  fi
  [[ -n "${created_at}" ]] || created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf 'name=%s\n' "${CLUSTER_NAME}"
    printf 'created_at=%s\n' "${created_at}"
    printf 'cni=%s\n' "${CNI_MODE}"
    printf 'state=%s\n' "${state}"
  } > "${MARKER_FILE}"
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
  require_dir_safe_if_present "${CLUSTER_PATCH_DIR}" "Cluster patch directory"
  require_file_safe_if_present "${CLUSTER_CNI_PATCH}" "Cluster CNI patch"
  require_file_safe_if_present "${CLUSTER_CP_PATCH}" "Cluster control-plane patch"
  require_file_safe_if_present "${CLUSTER_WORKER_PATCH}" "Cluster worker patch"
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

# @description Extracts the Colima-managed Docker socket endpoint from
#   `colima status` output (line format: "docker: unix:///path/to/docker.sock",
#   optionally prefixed by a log-level tag such as "INFO[0000] "). Never
#   starts, stops, or reconfigures Colima; a non-running or Docker-less
#   Colima simply yields no match and the caller decides how to fail.
colima_docker_socket_from_status() {
  local status_output="$1"
  local match=""
  # Real Colima reports the socket inside a logfmt line on stderr:
  #   time="..." level=info msg="docker socket: unix:///path/to/docker.sock"
  # Plainer "docker: unix:///path/to/docker.sock" output is also accepted, so
  # this keeps working across Colima's output styles. The trailing character
  # class excludes the double quote that closes the logfmt msg= field, which
  # would otherwise be captured as part of the socket path.
  match="$(printf '%s\n' "${status_output}" \
    | grep -oE 'docker([[:space:]]+socket)?:[[:space:]]*unix://[^[:space:]"]+' \
    | tail -n1 || true)"
  [[ -n "${match}" ]] || return 1
  printf 'unix://%s\n' "${match#*unix://}"
}

# @description Rejects anything that is not a "unix://" socket URI, or whose
#   underlying path does not currently exist as a real socket. Applied to a
#   Colima-resolved endpoint before it is ever exported as DOCKER_HOST, so a
#   stale or malformed Colima status line can never be handed to talosctl.
require_valid_docker_socket() {
  local endpoint="$1"
  local socket_path=""
  case "${endpoint}" in
    unix://*) socket_path="${endpoint#unix://}" ;;
    *) die "Resolved Colima Docker endpoint '${endpoint}' is not a 'unix://' socket URI." ;;
  esac
  [[ -S "${socket_path}" ]] || die "Resolved Colima Docker socket does not exist or is not a socket: ${socket_path}"
}

# @description Resolves the Docker endpoint for the Talos Docker lifecycle
#   command: an explicit --docker-endpoint wins, then an explicit DOCKER_HOST
#   already set in the environment, then a Colima Docker socket discovered
#   from `colima status` and validated with require_valid_docker_socket.
#   Never starts, stops, or reconfigures Colima/Docker; fails clearly (via
#   die) when no usable endpoint can be resolved. Prints only the resolved
#   endpoint on stdout (callers capture it via command substitution); all
#   diagnostics go through die (stderr), never log_info (stdout), so nothing
#   else is ever mixed into the captured value.
resolve_docker_endpoint() {
  if [[ -n "${DOCKER_ENDPOINT_OVERRIDE}" ]]; then
    printf '%s\n' "${DOCKER_ENDPOINT_OVERRIDE}"
    return 0
  fi

  if [[ -n "${DOCKER_HOST:-}" ]]; then
    printf '%s\n' "${DOCKER_HOST}"
    return 0
  fi

  local status_output=""
  if ! status_output="$(colima status 2>&1)"; then
    die "No explicit Docker endpoint is configured (--docker-endpoint or DOCKER_HOST) and Colima is not running (colima status failed). Start Colima yourself (for example: colima start) or pass --docker-endpoint, then re-run."
  fi

  local socket=""
  if ! socket="$(colima_docker_socket_from_status "${status_output}")"; then
    die "No explicit Docker endpoint is configured (--docker-endpoint or DOCKER_HOST) and Colima's status did not report a Docker socket. Start Colima's Docker runtime yourself or pass --docker-endpoint, then re-run."
  fi

  require_valid_docker_socket "${socket}"
  printf '%s\n' "${socket}"
}

# @description Validates that the maintained default patch model
#   (cni/cp/worker) exists and every file is a safe, readable regular file
#   before any of it is copied to a destination or passed to talosctl. This
#   model is the sole source of truth for a new cluster's --cni=cilium
#   machine-config patches; nothing here is generated from an inline string.
require_patch_template_project() {
  local name=""
  for name in "${PATCH_FILE_NAMES[@]}"; do
    require_file_safe_if_present "${PATCH_MODEL_DIR}/${name}" "default patch model ${name}"
    require_file "${PATCH_MODEL_DIR}/${name}"
  done
}

# @description Materializes the default patch model into this cluster's own
#   destination patch project, so `--name=<anything>` yields a per-cluster,
#   operator-editable copy of the Cilium-focused defaults rather than sharing
#   one directory inside the toolchain checkout.
#
#   An existing destination file is never overwritten. That is the whole point
#   of materializing: once a cluster's patches exist, they are that cluster's
#   record of what was applied, and re-running create must not silently
#   discard an operator's edits. This mirrors cluster.sh create-project's
#   scaffold-if-absent contract. Destroying the cluster removes them along
#   with the rest of the cluster directory.
#
#   Copies are literal, with only a provenance header prepended: no template
#   language, no variable substitution, so what lands in the destination is
#   byte-identical machine-config YAML that an operator can diff against the
#   model and hand-edit without learning a templating syntax.
materialize_cluster_patch_project() {
  local name=""
  local src=""
  local dest=""

  mkdir -p "${CLUSTER_PATCH_DIR}"
  for name in "${PATCH_FILE_NAMES[@]}"; do
    src="${PATCH_MODEL_DIR}/${name}"
    dest="${CLUSTER_PATCH_DIR}/${name}"
    if [[ -f "${dest}" ]]; then
      log_info "Keeping existing patch ${dest} (not overwritten by the default model)."
      continue
    fi
    {
      printf '# Generated by local-cluster.sh create --name=%s from\n' "${CLUSTER_NAME}"
      printf '# %s\n' "${src}"
      printf '# Edit freely: re-running create never overwrites this file.\n'
      cat "${src}"
    } > "${dest}"
    log_info "Materialized ${dest} from the default patch model."
  done
}

# @description Cilium-mode-only preflight: verifies the required additional
#   local tools (helm, kubectl, git) are present, that the maintained
#   default patch model is intact, and that the GitOps repo root
#   is a checkout on branch "lab" with a clean working tree, without
#   starting/reconfiguring Colima or mutating the GitOps checkout in any way.
preflight_cilium_mode() {
  local gitops_root="$1"
  local resolved_root=""
  local branch=""
  local dirty=""

  talos_require_commands helm kubectl git
  require_patch_template_project

  [[ -d "${gitops_root}" ]] || die "--gitops-repo-root not found: ${gitops_root}"
  resolved_root="$(cd "${gitops_root}" && pwd)"
  git -C "${resolved_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die "--gitops-repo-root is not a Git checkout: ${resolved_root}"

  branch="$(git -C "${resolved_root}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [[ "${branch}" == "${GITOPS_LAB_ENVIRONMENT}" ]] || \
    die "--gitops-repo-root must be checked out on branch '${GITOPS_LAB_ENVIRONMENT}' (found '${branch:-unknown}')."

  dirty="$(git -C "${resolved_root}" status --porcelain 2>/dev/null || true)"
  [[ -z "${dirty}" ]] || \
    die "--gitops-repo-root has uncommitted changes; commit or stash before a local Cilium bootstrap: ${resolved_root}"

  require_file "${resolved_root}/environments/${GITOPS_LAB_ENVIRONMENT}/helm/cilium/release.yaml"
  require_file "${resolved_root}/environments/${GITOPS_LAB_ENVIRONMENT}/argocd/apps/cilium.yaml"

  RESOLVED_GITOPS_REPO_ROOT="${resolved_root}"
}

# @description Polls `docker port` for the published host mapping of the
#   control-plane container's Kubernetes API port. Never starts, stops, or
#   reconfigures Docker/Colima; only inspects the already-running container
#   this same `create` invocation just started.
wait_for_published_api_port() {
  local container_name="$1"
  local waited=0
  local mapping=""

  while (( waited < CILIUM_API_PORT_WAIT_SECONDS )); do
    mapping="$(docker port "${container_name}" "${CILIUM_API_PORT}/tcp" 2>/dev/null | head -n1 || true)"
    if [[ -n "${mapping}" ]]; then
      printf '%s\n' "${mapping}"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  return 1
}

# @description Polls the Kubernetes API server's `/readyz` endpoint, using the
#   isolated kubeconfig this same create already fetched, until it reports
#   "ok" or a bounded timeout elapses.
#
#   The probe must be authenticated. Talos runs kube-apiserver with anonymous
#   authentication disabled, so an unauthenticated request to /readyz is
#   answered with HTTP 401 no matter how ready the cluster is. An earlier
#   version of this gate probed with `curl -k` and waited for HTTP 200: it sat
#   through its entire budget watching 401s on a control plane that was fully
#   ready, then reported a timeout. Going through kubectl with the cluster's
#   own credentials both fixes that and reads real readiness rather than
#   inferring it from "something answered".
#
#   A published Docker port mapping only proves the container's port is
#   forwarded; it says nothing about whether kube-apiserver inside it has
#   finished starting. In practice this waits out the entire bootstrap chain
#   (Talos API -> cluster bootstrap -> etcd Running -> kube-apiserver), which
#   is why the budget is minutes and why progress is logged along the way.
#   Cilium day-1 must never begin installing before this gate passes, even
#   though CNI is "none" and no pod networking exists yet (the API server
#   itself does not depend on CNI).
wait_for_kubernetes_api_readyz() {
  local kubeconfig_file="$1"
  local waited=0
  local probe_output=""
  local next_progress="${CILIUM_API_READYZ_PROGRESS_SECONDS}"

  while (( waited < CILIUM_API_READYZ_WAIT_SECONDS )); do
    if probe_output="$(KUBECONFIG="${kubeconfig_file}" kubectl get --raw=/readyz 2>&1)" \
       && [[ "${probe_output}" == *ok* ]]; then
      log_info "Kubernetes API reported /readyz=ok after ${waited}s."
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
    if (( CILIUM_API_READYZ_PROGRESS_SECONDS > 0 && waited >= next_progress )); then
      log_info "Still waiting for the Kubernetes API /readyz gate (${waited}s of ${CILIUM_API_READYZ_WAIT_SECONDS}s). Talos is still bootstrapping etcd/kube-apiserver; this normally takes minutes."
      next_progress=$((next_progress + CILIUM_API_READYZ_PROGRESS_SECONDS))
    fi
  done

  log_error "Last /readyz probe result: ${probe_output:-<none>}"
  return 1
}

# @description Rewrites only the isolated per-cluster kubeconfig's server
#   endpoint to the Docker-published host address, so operators never see
#   the internal Docker network address (for example 10.5.0.2:6443) that
#   `talosctl kubeconfig` embeds by default. Never touches the operator's
#   default ~/.kube/config.
rewrite_kubeconfig_server_endpoint() {
  local kubeconfig_file="$1"
  local host_ip="$2"
  local host_port="$3"

  sed -i.bak -E "s#(server: https://)[^[:space:]]+#\\1${host_ip}:${host_port}#" "${kubeconfig_file}"
  rm -f "${kubeconfig_file}.bak"
}

# @description Runs the offline Cilium day-1/day-2 handoff validator against
#   the local GitOps "lab" checkout, then installs Cilium day-1 via the
#   canonical Helm phase (phase-network-bringup.sh in --helm-root mode)
#   pointed directly at that checkout's environments/lab/helm tree, so day-1
#   and the eventual Argo CD day-2 adoption always read the identical files.
#   Never touches the GitOps checkout; only reads it.
bootstrap_cilium_day1() {
  local gitops_root="$1"
  local kubeconfig_file="$2"
  local cluster_name="$3"

  local helm_root="${gitops_root}/environments/${GITOPS_LAB_ENVIRONMENT}/helm"
  local render_dir="${CLUSTER_DIR}/generated/helm"
  local release_file="${helm_root}/cilium/release.yaml"

  local validate_cmd=(
    "${SCRIPT_DIR}/validate-cilium-handoff.sh"
    "--day1-release=${release_file}"
    "--gitops-repo-root=${gitops_root}"
    "--environment=${GITOPS_LAB_ENVIRONMENT}"
  )
  local bringup_cmd=(
    "${SCRIPT_DIR}/phase-network-bringup.sh"
    "--helm-root=${helm_root}"
    "--render-dir=${render_dir}"
    "--kubeconfig=${kubeconfig_file}"
    "--cluster-name=${cluster_name}"
    "--addon=cilium"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] ${validate_cmd[*]}"
    log_info "[DRY-RUN] ${bringup_cmd[*]}"
    log_info "[DRY-RUN] KUBECONFIG=${kubeconfig_file} kubectl -n kube-system rollout status deployment/coredns --timeout=${CILIUM_COREDNS_ROLLOUT_TIMEOUT}"
    return 0
  fi

  # Every step below is checked explicitly rather than relying on `set -e`.
  # This function is invoked as `if ! bootstrap_cilium_day1 ...`, and Bash
  # disables errexit for the whole body of a function called in a condition
  # context. Without these guards a failing Helm render or install did not
  # abort: execution fell through to the CoreDNS wait, which then failed with
  # "deployments.apps \"coredns\" not found" and became the reported cause,
  # burying the real error further up the log.
  log_info "Validating Cilium day-1/day-2 GitOps handoff before install: ${validate_cmd[*]}"
  if ! "${validate_cmd[@]}"; then
    log_error "Cilium day-1/day-2 GitOps handoff validation failed; nothing was installed."
    return 1
  fi

  log_info "Bootstrapping Cilium day-1 from GitOps '${GITOPS_LAB_ENVIRONMENT}' checkout: ${bringup_cmd[*]}"
  if ! "${bringup_cmd[@]}"; then
    log_error "Cilium day-1 network bring-up failed; not waiting for CoreDNS, which cannot roll out without pod networking."
    return 1
  fi

  log_info "Waiting for CoreDNS rollout to confirm cluster networking is healthy."
  if ! KUBECONFIG="${kubeconfig_file}" kubectl -n kube-system rollout status deployment/coredns --timeout="${CILIUM_COREDNS_ROLLOUT_TIMEOUT}"; then
    log_error "CoreDNS did not roll out within ${CILIUM_COREDNS_ROLLOUT_TIMEOUT} even though Cilium day-1 reported success."
    return 1
  fi
}

# @description Retries a kubeconfig-fetch command until it succeeds or a
#   timeout elapses. Used only by the --cni=cilium async flow below, because
#   the Talos API may not yet answer in the instant after the backgrounded
#   create command starts. The default synchronous flannel path never calls
#   this: it fetches the kubeconfig once, after create has already returned.
fetch_kubeconfig_with_retry() {
  local -a cmd=("$@")
  local waited=0
  local interval=3

  while (( waited < CILIUM_KUBECONFIG_FETCH_WAIT_SECONDS )); do
    if "${cmd[@]}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${interval}"
    waited=$((waited + interval))
  done

  return 1
}

# @description EXIT/INT/TERM guard for the async Cilium create flow below.
#   Reads its target from the CILIUM_ASYNC_CREATE_PID global: whenever it is
#   non-empty, this kills and reaps that pid and clears the guard. Because it
#   is armed as an EXIT trap (not just explicit failure branches), it fires
#   on every non-success exit after the child starts — an explicit `die`, an
#   unexpected `set -e` failure from any ordinary command (for example the
#   kubeconfig rewrite), or a SIGINT/SIGTERM — so the backgrounded
#   `talosctl cluster create docker` is never left running unsupervised. It
#   never deletes any state; it only terminates and reaps the process.
cilium_async_reap() {
  local pid="${CILIUM_ASYNC_CREATE_PID:-}"
  [[ -n "${pid}" ]] || return 0
  kill "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  log_warn "Terminated and reaped the in-flight talosctl cluster create docker (pid ${pid}); state at ${CLUSTER_DIR} is retained for diagnostics, not destroyed."
  CILIUM_ASYNC_CREATE_PID=""
}

# @description Cilium-mode-only supervised async create. `talosctl cluster
#   create docker` exposes no `--wait=false` equivalent for the Docker
#   backend, and its internal readiness wait blocks until Kubernetes/CoreDNS
#   is healthy — which can never happen while CNI is "none" until Cilium is
#   bootstrapped from here. This runs the create command in the background,
#   fetches the isolated kubeconfig (retrying until the Talos API answers),
#   discovers and rewrites the published API endpoint, bootstraps Cilium
#   day-1 (validator gate, Helm install, CoreDNS wait), and only then waits
#   for and propagates the backgrounded create command's real exit status.
#   From the moment the child starts until the final successful `wait`, an
#   EXIT trap (cilium_async_reap, guarded by CILIUM_ASYNC_CREATE_PID) covers
#   every non-success exit — explicit failures, an unexpected `set -e`
#   failure from any command in between, and SIGINT/SIGTERM — terminating
#   and reaping the child before this process exits. The guard is cleared
#   only once the final `wait` has actually consumed the child, at which
#   point it no longer needs reaping. Every failure path leaves all state in
#   place for diagnostics and never attempts any destroy/cleanup. The
#   default flannel path never calls this function and is unaffected.
supervise_cilium_async_create() {
  local docker_endpoint="$1"
  shift
  local -a create_cmd=("$@")
  local create_log="${CLUSTER_DIR}/create.log"
  CILIUM_ASYNC_CREATE_PID=""

  log_info "Creating local cluster '${CLUSTER_NAME}' (cilium mode, async, DOCKER_HOST=${docker_endpoint}): ${create_cmd[*]}"
  log_info "talosctl output is being captured to ${create_log} while Cilium day-1 bootstraps concurrently."
  DOCKER_HOST="${docker_endpoint}" "${create_cmd[@]}" > "${create_log}" 2>&1 &
  CILIUM_ASYNC_CREATE_PID=$!

  trap cilium_async_reap EXIT
  trap 'cilium_async_reap; log_warn "Interrupted."; exit 130' INT TERM

  local kubeconfig_cmd=(
    talosctl kubeconfig "${KUBECONFIG_PATH}"
    --talosconfig "${TALOSCONFIG_PATH}"
    --nodes "${CLUSTER_NAME}-controlplane-1"
  )
  log_info "Fetching isolated kubeconfig (retrying until the Talos API answers): ${kubeconfig_cmd[*]}"
  if ! fetch_kubeconfig_with_retry "${kubeconfig_cmd[@]}"; then
    die "Timed out fetching the isolated kubeconfig before the Talos API became reachable. See ${create_log}; state was left in place for diagnostics."
  fi

  local published_mapping=""
  if ! published_mapping="$(wait_for_published_api_port "${CLUSTER_NAME}-controlplane-1")"; then
    die "Timed out waiting for the published Kubernetes API port on ${CLUSTER_NAME}-controlplane-1. Run 'status --name=${CLUSTER_NAME}' and 'docker port ${CLUSTER_NAME}-controlplane-1' to diagnose; state was left in place for diagnostics."
  fi
  local published_host="${published_mapping%%:*}"
  local published_port="${published_mapping##*:}"
  log_info "Discovered published Kubernetes API endpoint: ${published_host}:${published_port}"
  rewrite_kubeconfig_server_endpoint "${KUBECONFIG_PATH}" "${published_host}" "${published_port}"

  log_info "Waiting for the Kubernetes API /readyz gate at https://${published_host}:${published_port}/readyz before starting Cilium day-1."
  if ! wait_for_kubernetes_api_readyz "${KUBECONFIG_PATH}"; then
    die "Timed out after ${CILIUM_API_READYZ_WAIT_SECONDS}s waiting for the Kubernetes API /readyz gate at https://${published_host}:${published_port}/readyz. Check ${create_log} for the bootstrap/etcd progress before assuming a real failure; a slow control plane can be given more time with TALOS_LOCAL_CLUSTER_API_READYZ_WAIT_SECONDS. State was left in place for diagnostics."
  fi
  log_info "Kubernetes API /readyz gate passed; starting Cilium day-1 bootstrap."

  if ! bootstrap_cilium_day1 "${RESOLVED_GITOPS_REPO_ROOT}" "${KUBECONFIG_PATH}" "${CLUSTER_NAME}"; then
    die "Cilium day-1 bootstrap failed; state was left in place for diagnostics (see ${create_log} and 'status --name=${CLUSTER_NAME}')."
  fi

  log_info "Cilium day-1 is healthy; waiting for the backgrounded 'talosctl cluster create docker' (pid ${CILIUM_ASYNC_CREATE_PID}) to finish."
  local create_status=0
  wait "${CILIUM_ASYNC_CREATE_PID}" || create_status=$?
  # The child has now been waited on directly (reaped) above, so the guard
  # is cleared before evaluating its result: a failing create_status below
  # no longer needs cilium_async_reap to terminate anything.
  CILIUM_ASYNC_CREATE_PID=""
  trap - EXIT INT TERM

  if [[ "${create_status}" -ne 0 ]]; then
    die "talosctl cluster create docker failed (exit ${create_status}); see ${create_log}. State was left in place for diagnostics."
  fi
  log_info "talosctl cluster create docker completed successfully (see ${create_log})."
}

do_create() {
  require_safe_cluster_name "${CLUSTER_NAME}"
  require_docker_controlplanes_supported "${CONTROLPLANES}"
  local state_root=""
  state_root="$(resolve_state_root)"
  set_cluster_paths "${state_root}" "${CLUSTER_NAME}"
  require_cluster_dir_contained
  require_state_tree_safe

  preflight_common
  RESOLVED_GITOPS_REPO_ROOT=""
  if [[ "${CNI_MODE}" == "cilium" ]]; then
    preflight_cilium_mode "${GITOPS_REPO_ROOT}"
  fi
  report_colima_state
  check_docker_daemon || die "Docker daemon preflight failed. See message above."

  if [[ -f "${MARKER_FILE}" ]]; then
    local existing_state=""
    existing_state="$(awk -F= '$1=="state"{print $2; exit}' "${MARKER_FILE}")"
    if [[ "${existing_state}" == "creating" ]]; then
      die "Cluster '${CLUSTER_NAME}' has state at ${CLUSTER_DIR} from an interrupted create. Run 'destroy --name=${CLUSTER_NAME} --confirm-destroy' to clean it up, or choose a different --name."
    fi
    die "Cluster '${CLUSTER_NAME}' already has wrapper state at ${CLUSTER_DIR}. Run 'destroy --name=${CLUSTER_NAME}' first, or choose a different --name."
  fi

  local docker_endpoint=""
  docker_endpoint="$(resolve_docker_endpoint)"
  log_info "Resolved Docker endpoint: ${docker_endpoint}"

  local create_cmd=(
    talosctl cluster create docker
    --name "${CLUSTER_NAME}"
    --state "${TALOS_STATE_DIR}"
    --talosconfig-destination "${TALOSCONFIG_PATH}"
    --workers "${WORKERS}"
  )
  [[ -z "${MEMORY_CONTROLPLANES}" ]] || create_cmd+=(--memory-controlplanes "${MEMORY_CONTROLPLANES}")
  [[ -z "${MEMORY_WORKERS}" ]] || create_cmd+=(--memory-workers "${MEMORY_WORKERS}")
  [[ -z "${CPUS_CONTROLPLANES}" ]] || create_cmd+=(--cpus-controlplanes "${CPUS_CONTROLPLANES}")
  [[ -z "${CPUS_WORKERS}" ]] || create_cmd+=(--cpus-workers "${CPUS_WORKERS}")
  if [[ "${CNI_MODE}" == "cilium" ]]; then
    create_cmd+=(
      --config-patch "@${CLUSTER_CNI_PATCH}"
      --config-patch-controlplanes "@${CLUSTER_CP_PATCH}"
      --config-patch-workers "@${CLUSTER_WORKER_PATCH}"
      --host-ip "${CILIUM_API_HOST_IP}"
      --exposed-ports "0:${CILIUM_API_PORT}/tcp"
    )
  fi
  local kubeconfig_cmd=(
    talosctl kubeconfig "${KUBECONFIG_PATH}"
    --talosconfig "${TALOSCONFIG_PATH}"
    --nodes "${CLUSTER_NAME}-controlplane-1"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    if [[ "${CNI_MODE}" == "cilium" ]]; then
      local template_name=""
      for template_name in "${PATCH_FILE_NAMES[@]}"; do
        log_info "[DRY-RUN] materialize ${CLUSTER_PATCH_DIR}/${template_name} from ${PATCH_MODEL_DIR}/${template_name} (existing file would be kept)"
      done
    fi
    log_info "[DRY-RUN] mkdir -p ${TALOS_STATE_DIR}"
    log_info "[DRY-RUN] DOCKER_HOST=${docker_endpoint} ${create_cmd[*]}"
    log_info "[DRY-RUN] ${kubeconfig_cmd[*]}"
    if [[ "${CNI_MODE}" == "cilium" ]]; then
      log_info "[DRY-RUN] docker port ${CLUSTER_NAME}-controlplane-1 ${CILIUM_API_PORT}/tcp"
      log_info "[DRY-RUN] rewrite ${KUBECONFIG_PATH} server endpoint to the published host:port"
      log_info "[DRY-RUN] wait for Kubernetes API /readyz on the published host:port before Cilium day-1"
      bootstrap_cilium_day1 "${RESOLVED_GITOPS_REPO_ROOT}" "${KUBECONFIG_PATH}" "${CLUSTER_NAME}"
    fi
    log_info "[DRY-RUN] write marker ${MARKER_FILE} (state=creating before the backend runs, state=ready once it succeeds)"
    return 0
  fi

  mkdir -p "${TALOS_STATE_DIR}"

  # Claim ownership before anything is created, not after. The marker is what
  # authorises destroy, so writing it only on success left every interrupted
  # create -- exactly what the EXIT trap produces when Cilium day-1 fails --
  # as containers and state this wrapper would refuse to clean up, forcing a
  # manual docker rm plus rm -rf. state=creating records that the cluster may
  # be incomplete; destroy accepts it either way.
  write_marker "creating"

  if [[ "${CNI_MODE}" == "cilium" ]]; then
    materialize_cluster_patch_project
    supervise_cilium_async_create "${docker_endpoint}" "${create_cmd[@]}"
  else
    log_info "Creating local cluster '${CLUSTER_NAME}' (DOCKER_HOST=${docker_endpoint}): ${create_cmd[*]}"
    DOCKER_HOST="${docker_endpoint}" "${create_cmd[@]}"
    log_info "Fetching isolated kubeconfig: ${kubeconfig_cmd[*]}"
    "${kubeconfig_cmd[@]}"
  fi

  write_marker "ready"

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
    local marker_state=""
    marker_state="$(awk -F= '$1=="state"{print $2; exit}' "${MARKER_FILE}")"
    # Markers written before this field existed have no state; report them as
    # "ready" rather than claiming an interrupted create.
    [[ -n "${marker_state}" ]] || marker_state="ready (assumed; marker predates state tracking)"
    log_info "Wrapper marker: present (${MARKER_FILE}), state=${marker_state}"
    if [[ "${marker_state}" == "creating" ]]; then
      log_warn "This cluster's create did not finish. It may be incomplete; 'destroy --name=${CLUSTER_NAME} --confirm-destroy' will clean it up."
    fi
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
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] ${show_cmd[*]}"
    return 0
  fi

  # talosctl talks to Docker directly, so it needs the same endpoint create
  # resolved -- on a Colima host the default /var/run/docker.sock does not
  # exist. status is read-only diagnostics and must never fail on this, so an
  # unresolvable endpoint degrades to a warning rather than dying.
  local status_endpoint=""
  if status_endpoint="$(resolve_docker_endpoint 2>/dev/null)"; then
    log_info "Cluster status (DOCKER_HOST=${status_endpoint}): ${show_cmd[*]}"
    DOCKER_HOST="${status_endpoint}" "${show_cmd[@]}" || \
      log_warn "talosctl could not report cluster state; the containers may be gone while the state directory remains."
  else
    log_warn "No Docker endpoint could be resolved; skipping 'talosctl cluster show'. The state directory above is still reported accurately."
  fi
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

  local marker_state=""
  marker_state="$(awk -F= '$1=="state"{print $2; exit}' "${MARKER_FILE}")"
  if [[ "${marker_state}" == "creating" ]]; then
    log_warn "Marker records an unfinished create; destroying a partially created cluster. Some resources may already be absent, and talosctl may report them as such."
  fi

  local destroy_cmd=(
    talosctl cluster destroy
    --name "${CLUSTER_NAME}"
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

  # Same endpoint create used: without it talosctl reaches for the default
  # /var/run/docker.sock, which does not exist on a Colima host, and the
  # destroy aborts before the state directory is ever removed.
  local destroy_endpoint=""
  destroy_endpoint="$(resolve_docker_endpoint)"
  log_info "Destroying local cluster '${CLUSTER_NAME}' (DOCKER_HOST=${destroy_endpoint}): ${destroy_cmd[*]}"
  DOCKER_HOST="${destroy_endpoint}" "${destroy_cmd[@]}"

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
