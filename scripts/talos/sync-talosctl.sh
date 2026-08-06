#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/talos/lib/common.sh"

ENV_NAME="lab"
CLUSTER_NAME=""
SOURCE_TALOSCONFIG=""
TARGET_TALOSCONFIG="${HOME}/.talos/config"
DRY_RUN="false"

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Options:
  --env=<env>                 Overlay environment (default: lab)
  --cluster-name=<name>       Cluster name override
  --source=<path>             Source talosconfig path
  --target=<path>             Target talosconfig path (default: ~/.talos/config)
  -n, --dry-run               Print actions without executing
  -h, --help                  Show help
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env=*) ENV_NAME="${1#*=}"; shift ;;
      --cluster-name=*) CLUSTER_NAME="${1#*=}"; shift ;;
      --source=*) SOURCE_TALOSCONFIG="${1#*=}"; shift ;;
      --target=*) TARGET_TALOSCONFIG="${1#*=}"; shift ;;
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

normalize_csv_list() {
  local raw="$1"
  raw="${raw//[/}"
  raw="${raw//]/}"
  raw="${raw//\"/}"
  raw="${raw// /}"
  printf '%s\n' "${raw}"
}

csv_to_array() {
  local csv="$1"
  [[ -n "${csv}" ]] || return 0
  local IFS=','
  local -a _arr=()
  read -r -a _arr <<<"${csv}"
  printf '%s\n' "${_arr[@]}"
}

run_or_echo() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

main() {
  local source_cfg=""
  local target_cfg=""
  local target_dir=""
  local endpoint=""
  local talosctl_endpoints_raw=""
  local talosctl_endpoints_csv=""
  local -a talosctl_endpoints=()
  local cp_ips_raw=""
  local -a cp_ips=()

  parse_args "$@"
  load_overlay_vars "${ENV_NAME}"

  CLUSTER_NAME="${CLUSTER_NAME:-${TALOS_CLUSTER_NAME:-talos}}"
  source_cfg="${SOURCE_TALOSCONFIG:-overlays/${ENV_NAME}/talos/${CLUSTER_NAME}/generated/talosconfig}"
  source_cfg="$(resolve_repo_path "${source_cfg}")"

  [[ -f "${source_cfg}" ]] || die "Missing source talosconfig: ${source_cfg}"

  target_cfg="${TARGET_TALOSCONFIG}"
  target_dir="$(dirname "${target_cfg}")"
  # Talos API endpoints must target Talos API (default 50000), not Kubernetes API (6443).
  # Allow explicit override, otherwise default to control-plane IP list.
  talosctl_endpoints_raw="${TALOS_TALOSCTL_ENDPOINTS:-}"
  talosctl_endpoints_csv="$(normalize_csv_list "${talosctl_endpoints_raw}")"
  if [[ -n "${talosctl_endpoints_csv}" ]]; then
    mapfile -t talosctl_endpoints < <(csv_to_array "${talosctl_endpoints_csv}")
  fi

  cp_ips_raw="$(normalize_csv_list "${TALOS_CONTROL_PLANE_IPS:-}")"
  mapfile -t cp_ips < <(csv_to_array "${cp_ips_raw}")
  (( ${#cp_ips[@]} > 0 )) || die "TALOS_CONTROL_PLANE_IPS is empty."

  run_or_echo mkdir -p "${target_dir}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] cp ${source_cfg} ${target_cfg}"
  else
    cp "${source_cfg}" "${target_cfg}"
    chmod 600 "${target_cfg}"
  fi

  if (( ${#talosctl_endpoints[@]} == 0 )); then
    talosctl_endpoints=("${cp_ips[@]}")
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] talosctl --talosconfig ${target_cfg} config endpoint ${talosctl_endpoints[*]}"
  else
    talosctl --talosconfig "${target_cfg}" config endpoint "${talosctl_endpoints[@]}" >/dev/null
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] talosctl --talosconfig ${target_cfg} config node ${cp_ips[*]}"
  else
    talosctl --talosconfig "${target_cfg}" config node "${cp_ips[@]}" >/dev/null
  fi

  log_info "talosctl access synced: ${target_cfg}"
}

main "$@"
