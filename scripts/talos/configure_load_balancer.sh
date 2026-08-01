#!/usr/bin/env bash
# @file configure_load_balancer.sh
# @brief Configure HAProxy backends for a Talos control-plane set.
# @description
#   Builds a TCP backend block from TALOS control-plane IPs and applies it to
#   HAProxy nodes through an external reconcile hook defined by the consuming project.
#
# @arg --env,-e string Overlay environment name. Defaults to lab.
# @arg --cp-ips string Optional control-plane IP list override (CSV/space/JSON-like).
# @arg --lb-hosts string Optional HAProxy host list override (CSV/space/JSON-like).
# @arg --vars-file string Optional vars file to source after overlay vars (GOVC profile).
# @arg --user string SSH user for HAProxy hosts. Defaults to SSH_USER/HAPROXY_SSH_USER from vars.
# @arg --port string SSH port for HAProxy hosts. Defaults to 22.
# @arg --ssh-key string SSH private key used for all HAProxy hosts.
# @arg --backend-name string HAProxy backend name. Defaults to talos_k8s_api_backend.
# @arg --frontend-name string HAProxy frontend name. Defaults to talos_k8s_api.
# @arg --api-port string Talos API port. Defaults to 6443.
# @arg --vip string VIP/bind IP for generated frontend (used with --append).
# @arg --cluster-name string Cluster name used in auto-generated frontend/backend names.
# @arg --bootstrap-file string Optional bootstrap inventory fallback file.
# @flag --append Append/update generated frontend/backend into current HAProxy blocks.
# @flag --dry-run,-n Print actions without applying changes.
# @flag --help,-h Show usage information.

set -euo pipefail

ENV_NAME="lab"
DRY_RUN="false"
SSH_USER=""
SSH_PORT="22"
SSH_KEY=""
BACKEND_NAME="talos_k8s_api_backend"
FRONTEND_NAME="talos_k8s_api"
API_PORT="6443"
VIP_OVERRIDE=""
CLUSTER_NAME_OVERRIDE=""
APPEND_MODE="false"
CP_IPS_OVERRIDE=""
LB_HOSTS_OVERRIDE=""
BOOTSTRAP_FILE_OVERRIDE=""
CUSTOM_VARS_FILE=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/talos/lib/common.sh"

HAPROXY_SETUP_SCRIPT="${TALOS_LOAD_BALANCER_RECONCILE_SCRIPT:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -e, --env=<env>             Overlay environment (default: lab)
      --cp-ips=<list>         Control-plane IPs (CSV/space/JSON-like)
      --lb-hosts=<list>       HAProxy hosts (CSV/space/JSON-like)
      --user=<user>           SSH user for HAProxy hosts
      --port=<port>           SSH port (default: 22)
      --ssh-key=<path>        SSH private key used for HAProxy hosts
      --backend-name=<name>   HAProxy backend name (default: talos_k8s_api_backend)
      --frontend-name=<name>  HAProxy frontend name (default: talos_k8s_api)
      --api-port=<port>       Talos API port (default: 6443)
      --vip=<ip>              VIP/bind IP used by generated frontend in --append mode
      --cluster-name=<name>   Cluster name used for generated names
      --bootstrap-file=<path> Bootstrap inventory fallback file
      --append                Append/update generated frontend/backend in HAProxy blocks
  -n, --dry-run               Show actions without executing
  -h, --help                  Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -e|--env)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        ENV_NAME="$2"
        shift 2
        ;;
      --env=*) ENV_NAME="${1#*=}"; shift ;;
      --cp-ips=*) CP_IPS_OVERRIDE="${1#*=}"; shift ;;
      --lb-hosts=*) LB_HOSTS_OVERRIDE="${1#*=}"; shift ;;
      --vars-file=*) CUSTOM_VARS_FILE="${1#*=}"; shift ;;
      --user=*) SSH_USER="${1#*=}"; shift ;;
      --port=*) SSH_PORT="${1#*=}"; shift ;;
      --ssh-key=*) SSH_KEY="${1#*=}"; shift ;;
      --backend-name=*) BACKEND_NAME="${1#*=}"; shift ;;
      --frontend-name=*) FRONTEND_NAME="${1#*=}"; shift ;;
      --api-port=*) API_PORT="${1#*=}"; shift ;;
      --vip=*) VIP_OVERRIDE="${1#*=}"; shift ;;
      --cluster-name=*) CLUSTER_NAME_OVERRIDE="${1#*=}"; shift ;;
      --bootstrap-file=*) BOOTSTRAP_FILE_OVERRIDE="${1#*=}"; shift ;;
      --append) APPEND_MODE="true"; shift ;;
      -n|--dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "${value}"
}

parse_list_items() {
  local raw="$1"
  printf '%s' "${raw}" \
    | tr -d '[]"' \
    | tr ',' '\n' \
    | tr ' ' '\n' \
    | tr '\t' '\n' \
    | awk 'NF'
}

is_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<<"${ip}"
  (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 ))
}

resolve_repo_path() {
  local path_value="$1"
  if [[ "${path_value}" = /* ]]; then
    printf '%s\n' "${path_value}"
  else
    printf '%s\n' "${REPO_ROOT}/${path_value}"
  fi
}

collect_cp_ips_from_bootstrap_file() {
  local bootstrap_file="$1"
  [[ -f "${bootstrap_file}" ]] || return 0
  awk '/^control-plane-[0-9]+[[:space:]]+/ {print $3}' "${bootstrap_file}" | awk 'NF'
}

build_backend_block() {
  local backend_name="$1"
  local api_port="$2"
  shift 2
  local ips=("$@")
  local block=""
  local idx=0
  local ip=""
  local server_name=""

  block+=$'backend '"${backend_name}"$'\n'
  block+=$'  mode tcp\n'
  block+=$'  balance roundrobin\n'
  block+=$'  option tcp-check\n'

  for ip in "${ips[@]}"; do
    idx=$((idx + 1))
    printf -v server_name 'cp%02d' "${idx}"
    block+="  server ${server_name} ${ip}:${api_port} check"$'\n'
  done

  printf '%s' "${block}"
}

build_frontend_block() {
  local frontend_name="$1"
  local bind_target="$2"
  local backend_name="$3"
  local api_port="$4"
  local block=""

  block+=$'frontend '"${frontend_name}"$'\n'
  block+="  bind ${bind_target}:${api_port}"$'\n'
  block+=$'  mode tcp\n'
  block+="  default_backend ${backend_name}"$'\n'

  printf '%s' "${block}"
}

append_or_replace_named_block() {
  local existing="$1"
  local new_block="$2"
  local kind="$3"
  local name="$4"
  local line=""
  local out=""
  local in_target="false"

  if [[ -z "${existing}" ]]; then
    printf '%s' "${new_block}"
    return 0
  fi

  while IFS= read -r line; do
    if [[ "${line}" =~ ^${kind}[[:space:]]+${name}$ ]]; then
      if [[ "${in_target}" == "false" ]]; then
        [[ -n "${out}" ]] && out+=$'\n'
        out+="${new_block}"$'\n'
        in_target="true"
      fi
      continue
    fi

    if [[ "${in_target}" == "true" ]]; then
      if [[ "${line}" =~ ^(frontend|backend)[[:space:]]+ ]]; then
        in_target="false"
        out+="${line}"$'\n'
      fi
      continue
    fi

    out+="${line}"$'\n'
  done <<<"${existing}"

  if [[ "${in_target}" == "false" && ! "${existing}" =~ ^${kind}[[:space:]]+${name}$ ]]; then
    [[ -n "${out}" ]] && out+=$'\n'
    out+="${new_block}"$'\n'
  fi

  printf '%s' "${out}" | awk 'BEGIN{prev_blank=0} {if ($0=="") {if (!prev_blank) print; prev_blank=1} else {print; prev_blank=0}}' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

run_or_echo() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

main() {
  local cp_source=""
  local lb_source=""
  local bootstrap_file=""
  local cluster_name=""
  local frontend_name_resolved=""
  local backend_name_resolved=""
  local vip_resolved=""
  local bind_target=""
  local frontend_block=""
  local cp_raw=""
  local lb_raw=""
  local cp_ip=""
  local lb_host=""
  local backend_block=""
  local merged_frontends=""
  local merged_backends=""
  local q_backend=""
  local q_frontends=""
  local q_backends=""
  local ssh_user_resolved=""
  local -a cp_ips=()
  local -a lb_hosts=()
  local setup_cmd=()

  parse_args "$@"
  load_overlay_vars "${ENV_NAME}"
  if [[ -n "${CUSTOM_VARS_FILE}" ]]; then
    CUSTOM_VARS_FILE="$(resolve_repo_path "${CUSTOM_VARS_FILE}")"
    require_file "${CUSTOM_VARS_FILE}"
    # shellcheck disable=SC1090
    source "${CUSTOM_VARS_FILE}"
    normalize_global_env
  fi
  [[ -n "${HAPROXY_SETUP_SCRIPT}" ]] || die "Missing TALOS_LOAD_BALANCER_RECONCILE_SCRIPT. This integration must be provided by the consuming project."
  HAPROXY_SETUP_SCRIPT="$(resolve_repo_path "${HAPROXY_SETUP_SCRIPT}")"
  require_file "${HAPROXY_SETUP_SCRIPT}"

  [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || die "--port must be numeric."
  [[ "${SSH_PORT}" -ge 1 && "${SSH_PORT}" -le 65535 ]] || die "--port must be between 1 and 65535."
  [[ -n "${BACKEND_NAME}" ]] || die "--backend-name cannot be empty."
  [[ -n "${FRONTEND_NAME}" ]] || die "--frontend-name cannot be empty."
  [[ "${API_PORT}" =~ ^[0-9]+$ ]] || die "--api-port must be numeric."
  [[ "${API_PORT}" -ge 1 && "${API_PORT}" -le 65535 ]] || die "--api-port must be between 1 and 65535."
  [[ "${APPEND_MODE}" == "true" || "${APPEND_MODE}" == "false" ]] || die "--append parsing failed."

  cp_source="${CP_IPS_OVERRIDE:-}"
  if [[ -z "${cp_source}" ]]; then
    cp_source="${TALOS_CONTROL_PLANE_IPS:-}"
  fi

  bootstrap_file="${BOOTSTRAP_FILE_OVERRIDE:-}"
  if [[ -z "${bootstrap_file}" ]]; then
    bootstrap_file="$(dirname "$(resolve_repo_path "${TALOS_CONTROL_PLANE_CONFIG_PATH}")")/bootstrap-ips.txt"
  else
    bootstrap_file="$(resolve_repo_path "${bootstrap_file}")"
  fi

  if [[ -z "${cp_source}" ]]; then
    while IFS= read -r cp_raw; do
      cp_raw="$(trim "${cp_raw}")"
      [[ -n "${cp_raw}" ]] || continue
      cp_ips+=("${cp_raw}")
    done < <(collect_cp_ips_from_bootstrap_file "${bootstrap_file}")
  else
    while IFS= read -r cp_raw; do
      cp_raw="$(trim "${cp_raw}")"
      [[ -n "${cp_raw}" ]] || continue
      cp_ips+=("${cp_raw}")
    done < <(parse_list_items "${cp_source}")
  fi

  (( ${#cp_ips[@]} > 0 )) || die "No control-plane IPs found. Set TALOS_CONTROL_PLANE_IPS or provide --cp-ips."
  for cp_ip in "${cp_ips[@]}"; do
    is_ipv4 "${cp_ip}" || die "Invalid control-plane IP: ${cp_ip}"
  done

  lb_source="${LB_HOSTS_OVERRIDE:-}"
  if [[ -z "${lb_source}" ]]; then
    lb_source="${HAPROXY_NODE_1_IP:-},${HAPROXY_NODE_2_IP:-}"
  fi
  while IFS= read -r lb_raw; do
    lb_raw="$(trim "${lb_raw}")"
    [[ -n "${lb_raw}" ]] || continue
    lb_hosts+=("${lb_raw}")
  done < <(parse_list_items "${lb_source}")

  (( ${#lb_hosts[@]} > 0 )) || die "No HAProxy hosts found. Set HAPROXY_NODE_1_IP/HAPROXY_NODE_2_IP or use --lb-hosts."

  ssh_user_resolved="${SSH_USER:-${HAPROXY_SSH_USER:-}}"
  [[ -n "${ssh_user_resolved}" ]] || die "SSH user not resolved. Set SSH_USER/HAPROXY_SSH_USER in vars or pass --user."
  if [[ -n "${SSH_KEY}" ]]; then
    [[ -f "${SSH_KEY}" ]] || die "SSH key not found: ${SSH_KEY}"
  fi

  if [[ "${APPEND_MODE}" == "true" ]]; then
    cluster_name="${CLUSTER_NAME_OVERRIDE:-${TALOS_CLUSTER_NAME:-talos}}"
    vip_resolved="${VIP_OVERRIDE:-${HAPROXY_VIP:-}}"
    [[ -n "${vip_resolved}" ]] || die "In --append mode, set --vip or HAPROXY_VIP."
    is_ipv4 "${vip_resolved}" || die "Invalid VIP IP: ${vip_resolved}"

    frontend_name_resolved="${FRONTEND_NAME}"
    backend_name_resolved="${BACKEND_NAME}"
    if [[ "${FRONTEND_NAME}" == "talos_k8s_api" ]]; then
      frontend_name_resolved="${cluster_name}_k8s_api"
    fi
    if [[ "${BACKEND_NAME}" == "talos_k8s_api_backend" ]]; then
      backend_name_resolved="${cluster_name}_k8s_api_backend"
    fi

    bind_target="${vip_resolved}"
    frontend_block="$(build_frontend_block "${frontend_name_resolved}" "${bind_target}" "${backend_name_resolved}" "${API_PORT}")"
    backend_block="$(build_backend_block "${backend_name_resolved}" "${API_PORT}" "${cp_ips[@]}")"

    merged_frontends="$(append_or_replace_named_block "${HAPROXY_FRONTENDS_BLOCK:-}" "${frontend_block}" "frontend" "${frontend_name_resolved}")"
    merged_backends="$(append_or_replace_named_block "${HAPROXY_BACKENDS_BLOCK:-}" "${backend_block}" "backend" "${backend_name_resolved}")"
  else
    backend_block="$(build_backend_block "${BACKEND_NAME}" "${API_PORT}" "${cp_ips[@]}")"
  fi

  printf -v q_backend '%q' "${backend_block}"
  if [[ "${APPEND_MODE}" == "true" ]]; then
    printf -v q_frontends '%q' "${merged_frontends}"
    printf -v q_backends '%q' "${merged_backends}"
  fi

  if [[ "${APPEND_MODE}" == "true" ]]; then
    log_info "Appending/updating HAProxy frontend/backend for cluster '${cluster_name}' (${vip_resolved}:${API_PORT})."
    log_info "Frontend: ${frontend_name_resolved} | Backend: ${backend_name_resolved}"
  else
    log_info "Configuring HAProxy backend '${BACKEND_NAME}' with ${#cp_ips[@]} control-plane node(s)."
  fi
  log_info "Targets: ${lb_hosts[*]}"

  for lb_host in "${lb_hosts[@]}"; do
    setup_cmd=("${HAPROXY_SETUP_SCRIPT}" "--env=${ENV_NAME}" "--host=${lb_host}" "--user=${ssh_user_resolved}" "--port=${SSH_PORT}")
    if [[ -n "${SSH_KEY}" ]]; then
      setup_cmd+=("--ssh-key=${SSH_KEY}")
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
      if [[ "${APPEND_MODE}" == "true" ]]; then
        log_info "[DRY-RUN] HAPROXY_FRONTENDS_BLOCK=${q_frontends} HAPROXY_BACKENDS_BLOCK=${q_backends} ${setup_cmd[*]}"
      else
        log_info "[DRY-RUN] HAPROXY_BACKENDS_BLOCK=${q_backend} ${setup_cmd[*]}"
      fi
      continue
    fi

    if [[ "${APPEND_MODE}" == "true" ]]; then
      HAPROXY_FRONTENDS_BLOCK="${merged_frontends}" HAPROXY_BACKENDS_BLOCK="${merged_backends}" "${setup_cmd[@]}"
    else
      HAPROXY_BACKENDS_BLOCK="${backend_block}" "${setup_cmd[@]}"
    fi
  done

  log_info "HAProxy Talos backend configuration completed."
}

main "$@"
