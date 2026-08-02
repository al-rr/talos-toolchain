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
# @arg --cni name Local CNI mode for create: "flannel" (default, unchanged
#   Talos-managed CNI) or "cilium" (Talos CNI is set to "none" and Cilium is
#   bootstrapped day-1 from a local GitOps `lab` checkout).
# @arg --gitops-repo-root path Local talos-vsphere-gitops checkout root.
#   Required when --cni=cilium; must be on branch "lab" with a clean working
#   tree. Never modified: this wrapper only reads its lab environment files.
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
CNI_MODE="flannel"
GITOPS_REPO_ROOT=""

MARKER_NAME=".talos-toolchain-local-cluster"
GITOPS_LAB_ENVIRONMENT="lab"
CILIUM_API_PORT="6443"
CILIUM_API_HOST_IP="127.0.0.1"
# Overridable only for the offline test suite, so it never has to sleep
# through a real 60s timeout to exercise the failure path.
CILIUM_API_PORT_WAIT_SECONDS="${TALOS_LOCAL_CLUSTER_API_PORT_WAIT_SECONDS:-60}"
# Overridable only for the offline test suite, for the same reason as above.
CILIUM_KUBECONFIG_FETCH_WAIT_SECONDS="${TALOS_LOCAL_CLUSTER_KUBECONFIG_FETCH_WAIT_SECONDS:-120}"
CILIUM_COREDNS_ROLLOUT_TIMEOUT="180s"

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
  --cni=<mode>           Local CNI mode for create: "flannel" (default,
                         unchanged Talos-managed CNI) or "cilium" (Talos CNI
                         is set to "none"; Cilium is bootstrapped day-1 from
                         a local GitOps "lab" checkout).
  --gitops-repo-root=<path>  Local talos-vsphere-gitops checkout root.
                         Required with --cni=cilium; must be on branch "lab"
                         with a clean working tree. Read-only: never modified.
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
      --cni=*) CNI_MODE="${1#*=}"; shift ;;
      --gitops-repo-root=*) GITOPS_REPO_ROOT="${1#*=}"; shift ;;
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

# @description Cilium-mode-only preflight: verifies the required additional
#   local tools (helm, kubectl, git) are present and that the GitOps repo
#   root is a checkout on branch "lab" with a clean working tree, without
#   starting/reconfiguring Colima or mutating the GitOps checkout in any way.
preflight_cilium_mode() {
  local gitops_root="$1"
  local resolved_root=""
  local branch=""
  local dirty=""

  talos_require_commands helm kubectl git

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

# @description Cluster-wide Talos machine-config patch disabling the managed
#   CNI so Cilium day-1 owns pod networking instead of Flannel. Applied via
#   --config-patch (all node types) so it never depends on which of the
#   Docker backend's single control-plane / N worker nodes is patched.
cilium_cni_none_config_patch() {
  printf '%s' '[{"op":"replace","path":"/cluster/network/cni","value":{"name":"none"}}]'
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

  log_info "Validating Cilium day-1/day-2 GitOps handoff before install: ${validate_cmd[*]}"
  "${validate_cmd[@]}"

  log_info "Bootstrapping Cilium day-1 from GitOps '${GITOPS_LAB_ENVIRONMENT}' checkout: ${bringup_cmd[*]}"
  "${bringup_cmd[@]}"

  log_info "Waiting for CoreDNS rollout to confirm cluster networking is healthy."
  KUBECONFIG="${kubeconfig_file}" kubectl -n kube-system rollout status deployment/coredns --timeout="${CILIUM_COREDNS_ROLLOUT_TIMEOUT}"
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
  local -a create_cmd=("$@")
  local create_log="${CLUSTER_DIR}/create.log"
  CILIUM_ASYNC_CREATE_PID=""

  log_info "Creating local cluster '${CLUSTER_NAME}' (cilium mode, async): ${create_cmd[*]}"
  log_info "talosctl output is being captured to ${create_log} while Cilium day-1 bootstraps concurrently."
  "${create_cmd[@]}" > "${create_log}" 2>&1 &
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
    die "Cluster '${CLUSTER_NAME}' already has wrapper state at ${CLUSTER_DIR}. Run 'destroy --name=${CLUSTER_NAME}' first, or choose a different --name."
  fi

  local create_cmd=(
    talosctl cluster create docker
    --name "${CLUSTER_NAME}"
    --state "${TALOS_STATE_DIR}"
    --talosconfig-destination "${TALOSCONFIG_PATH}"
    --workers "${WORKERS}"
  )
  if [[ "${CNI_MODE}" == "cilium" ]]; then
    create_cmd+=(
      --config-patch "$(cilium_cni_none_config_patch)"
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
    log_info "[DRY-RUN] mkdir -p ${TALOS_STATE_DIR}"
    log_info "[DRY-RUN] ${create_cmd[*]}"
    log_info "[DRY-RUN] ${kubeconfig_cmd[*]}"
    if [[ "${CNI_MODE}" == "cilium" ]]; then
      log_info "[DRY-RUN] docker port ${CLUSTER_NAME}-controlplane-1 ${CILIUM_API_PORT}/tcp"
      log_info "[DRY-RUN] rewrite ${KUBECONFIG_PATH} server endpoint to the published host:port"
      bootstrap_cilium_day1 "${RESOLVED_GITOPS_REPO_ROOT}" "${KUBECONFIG_PATH}" "${CLUSTER_NAME}"
    fi
    log_info "[DRY-RUN] write marker ${MARKER_FILE}"
    return 0
  fi

  mkdir -p "${TALOS_STATE_DIR}"
  if [[ "${CNI_MODE}" == "cilium" ]]; then
    supervise_cilium_async_create "${create_cmd[@]}"
  else
    log_info "Creating local cluster '${CLUSTER_NAME}': ${create_cmd[*]}"
    "${create_cmd[@]}"
    log_info "Fetching isolated kubeconfig: ${kubeconfig_cmd[*]}"
    "${kubeconfig_cmd[@]}"
  fi

  {
    printf 'name=%s\n' "${CLUSTER_NAME}"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'cni=%s\n' "${CNI_MODE}"
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
