#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/talos/lib/common.sh"

ENV_NAME="lab"
CLUSTER_NAME=""
SOURCE_KUBECONFIG=""
TARGET_KUBECONFIG="${HOME}/.kube/config"
SET_CONTEXT="true"
DRY_RUN="false"

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Options:
  --env=<env>                 Overlay environment (default: lab)
  --cluster-name=<name>       Cluster name override
  --source=<path>             Source kubeconfig path
  --target=<path>             Target kubeconfig path (default: ~/.kube/config)
  --no-set-context            Do not switch current kubectl context
  -n, --dry-run               Print actions without executing
  -h, --help                  Show help
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env=*) ENV_NAME="${1#*=}"; shift ;;
      --cluster-name=*) CLUSTER_NAME="${1#*=}"; shift ;;
      --source=*) SOURCE_KUBECONFIG="${1#*=}"; shift ;;
      --target=*) TARGET_KUBECONFIG="${1#*=}"; shift ;;
      --no-set-context) SET_CONTEXT="false"; shift ;;
      -n|--dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done
}

resolve_repo_path() {
  local path_value="$1"
  if [[ "${path_value}" = /* ]]; then
    printf '%s\n' "${path_value}"
  else
    printf '%s\n' "${REPO_ROOT}/${path_value}"
  fi
}

run_or_echo() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

main() {
  local cluster_context=""
  local cluster_entry=""
  local user_entry=""
  local source_cfg=""
  local target_cfg=""
  local target_dir=""
  local merged_tmp=""

  parse_args "$@"
  load_overlay_vars "${ENV_NAME}"

  CLUSTER_NAME="${CLUSTER_NAME:-${TALOS_CLUSTER_NAME:-talos}}"
  cluster_context="admin@${CLUSTER_NAME}"
  cluster_entry="${CLUSTER_NAME}"
  user_entry="admin@${CLUSTER_NAME}"

  source_cfg="${SOURCE_KUBECONFIG:-overlays/${ENV_NAME}/talos/${CLUSTER_NAME}/generated/kubeconfig}"
  source_cfg="$(resolve_repo_path "${source_cfg}")"
  target_cfg="${TARGET_KUBECONFIG}"
  target_dir="$(dirname "${target_cfg}")"

  [[ -f "${source_cfg}" ]] || die "Missing source kubeconfig: ${source_cfg}"

  run_or_echo mkdir -p "${target_dir}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Merge ${source_cfg} into ${target_cfg}"
  else
    # Remove stale entries for this cluster so new CA/certs are always authoritative.
    if [[ -f "${target_cfg}" ]]; then
      kubectl --kubeconfig "${target_cfg}" config delete-context "${cluster_context}" >/dev/null 2>&1 || true
      kubectl --kubeconfig "${target_cfg}" config delete-user "${user_entry}" >/dev/null 2>&1 || true
      kubectl --kubeconfig "${target_cfg}" config delete-cluster "${cluster_entry}" >/dev/null 2>&1 || true
    fi

    merged_tmp="$(mktemp)"
    if [[ -f "${target_cfg}" ]]; then
      KUBECONFIG="${target_cfg}:${source_cfg}" kubectl config view --flatten > "${merged_tmp}"
    else
      cp "${source_cfg}" "${merged_tmp}"
    fi
    mv "${merged_tmp}" "${target_cfg}"
    chmod 600 "${target_cfg}"
  fi

  if [[ "${SET_CONTEXT}" == "true" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_info "[DRY-RUN] kubectl --kubeconfig ${target_cfg} config use-context ${cluster_context}"
    else
      kubectl --kubeconfig "${target_cfg}" config use-context "${cluster_context}" >/dev/null
    fi
  fi

  log_info "kubectl access synced: ${target_cfg} (context: ${cluster_context})"
}

main "$@"
