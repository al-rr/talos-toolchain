#!/usr/bin/env bash
# @file cluster-bootstrap.sh
# @brief Day-1 Talos flow: generate configs, apply configs, bootstrap cluster.
# @description
#   Executes the Day-1 sequence for Talos clusters in a reusable way:
#   1) generate machine configs and talosconfig,
#   2) apply per-node configs (including optional patches),
#   3) bootstrap the first control-plane node.
#
# @arg --env string Overlay environment name. Defaults to lab.
# @arg --mode string generate|apply|bootstrap|all. Defaults to all.
# @arg --cluster-name string Talos cluster name.
# @arg --endpoint string Cluster endpoint URL or host:port.
# @arg --generated-dir string Output directory for generated files.
# @arg --cp-ips string Control-plane IP list (CSV/JSON-like).
# @arg --worker-ips string Worker IP list (CSV/JSON-like).
# @arg --bootstrap-node string Control-plane IP used for bootstrap.
# @flag --disable-default-cni Disable Talos default CNI/kube-proxy using cni.patch.yaml.
# @flag --enable-default-cni Keep Talos default CNI/kube-proxy (default).
# @flag --skip-lb-config Disable automatic HAProxy Talos backend/frontend reconciliation.
# @arg --validate-timeout-seconds int Seconds to wait for kube-api readiness via VIP.
# @arg --validate-interval-seconds int Interval between kube-api readiness checks.
# @flag --skip-post-validate Skip kube-api readiness validation after bootstrap.
# @flag --dry-run,-n Print planned actions only.
# @flag --help,-h Show usage.
#
# @example
#   # Run full day-1 bootstrap flow for lab overlay
#   ./cluster-bootstrap.sh --env=lab --mode=all
#
# @example
#   # Apply only pre-bootstrap stage with explicit control-plane and worker IPs
#   ./cluster-bootstrap.sh --env=lab --mode=apply --apply-stage=pre --cp-ips=192.168.0.61,192.168.0.62,192.168.0.63 --worker-ips=192.168.0.71,192.168.0.72,192.168.0.73

set -euo pipefail

BOOTSTRAP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${BOOTSTRAP_SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/talos/lib/common.sh"

ENV_NAME="lab"
MODE="all" # generate|apply|bootstrap|all
APPLY_STAGE="${TALOS_APPLY_STAGE:-auto}" # pre|post|auto
DRY_RUN="false"
ROTATE_SECRETS="false"
FORCE_GENERATE="false"
CLUSTER_NAME=""
CLUSTER_ENDPOINT=""
GENERATED_DIR=""
CP_IPS_RAW=""
WORKER_IPS_RAW=""
BOOTSTRAP_NODE=""
AUTO_CONFIGURE_LB="true"
VALIDATE_POST_BOOTSTRAP="true"
VALIDATE_TIMEOUT_SECONDS="180"
VALIDATE_INTERVAL_SECONDS="5"
DISABLE_DEFAULT_CNI=""
CNI_PATCH_FILE=""

declare -a CP_IPS=()
declare -a WORKER_IPS=()
declare -a APPLY_CP_IPS=()
declare -a APPLY_WORKER_IPS=()

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Options:
  --env=<env>                 Overlay environment (default: lab)
  --mode=<mode>               generate|apply|bootstrap|all (default: all)
  --apply-stage=<stage>       pre|post|auto (default: auto, used with --mode=apply)
  --cluster-name=<name>       Talos cluster name
  --endpoint=<endpoint>       Cluster endpoint (e.g. https://192.168.0.30:6443)
  --generated-dir=<path>      Output dir for generated sensitive files
  --cp-ips=<csv>              Control-plane IP list
  --worker-ips=<csv>          Worker IP list
  --bootstrap-node=<ip>       Bootstrap control-plane node IP (default: first cp ip)
  --disable-default-cni       Disable default Talos CNI/kube-proxy via cni.patch.yaml
  --enable-default-cni        Keep default Talos CNI/kube-proxy (default)
  --skip-lb-config            Skip automatic Talos HAProxy reconciliation
  --validate-timeout-seconds=<seconds>
                              Wait timeout for kube-api readiness via VIP (default: 180)
  --validate-interval-seconds=<seconds>
                              Check interval for kube-api readiness (default: 5)
  --skip-post-validate        Skip kube-api readiness validation after bootstrap
  --rotate-secrets            Regenerate Talos PKI secrets for this cluster
  --force-generate            Force regeneration of Talos config files
  -n, --dry-run               Show actions without executing
  -h, --help                  Show help

Examples:
  # Run full day-1 Talos flow (generate + apply + bootstrap)
  $(basename "$0") --env=lab --mode=all

  # Generate configs only
  $(basename "$0") --env=lab --mode=generate

  # Apply pre-bootstrap stage only
  $(basename "$0") --env=lab --mode=apply --apply-stage=pre

  # Bootstrap only, using existing generated files
  $(basename "$0") --env=lab --mode=bootstrap
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env=*) ENV_NAME="${1#*=}"; shift ;;
      --mode=*) MODE="${1#*=}"; shift ;;
      --apply-stage=*) APPLY_STAGE="${1#*=}"; shift ;;
      -n|--dry-run) DRY_RUN="true"; shift ;;
      --cluster-name=*) CLUSTER_NAME="${1#*=}"; shift ;;
      --endpoint=*) CLUSTER_ENDPOINT="${1#*=}"; shift ;;
      --generated-dir=*) GENERATED_DIR="${1#*=}"; shift ;;
      --cp-ips=*) CP_IPS_RAW="${1#*=}"; shift ;;
      --worker-ips=*) WORKER_IPS_RAW="${1#*=}"; shift ;;
      --bootstrap-node=*) BOOTSTRAP_NODE="${1#*=}"; shift ;;
      --disable-default-cni) DISABLE_DEFAULT_CNI="true"; shift ;;
      --enable-default-cni) DISABLE_DEFAULT_CNI="false"; shift ;;
      --skip-lb-config) AUTO_CONFIGURE_LB="false"; shift ;;
      --validate-timeout-seconds=*) VALIDATE_TIMEOUT_SECONDS="${1#*=}"; shift ;;
      --validate-interval-seconds=*) VALIDATE_INTERVAL_SECONDS="${1#*=}"; shift ;;
      --skip-post-validate) VALIDATE_POST_BOOTSTRAP="false"; shift ;;
      --rotate-secrets) ROTATE_SECRETS="true"; shift ;;
      --force-generate) FORCE_GENERATE="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done
}

validate_args() {
  case "${MODE}" in
    generate|apply|bootstrap|all) ;;
    *) die "--mode must be one of: generate, apply, bootstrap, all" ;;
  esac
  case "${APPLY_STAGE}" in
    pre|post|auto) ;;
    *) die "--apply-stage must be one of: pre, post, auto" ;;
  esac
  [[ "${VALIDATE_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || die "--validate-timeout-seconds must be numeric."
  [[ "${VALIDATE_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]] || die "--validate-interval-seconds must be numeric."
  [[ "${VALIDATE_TIMEOUT_SECONDS}" -gt 0 ]] || die "--validate-timeout-seconds must be > 0."
  [[ "${VALIDATE_INTERVAL_SECONDS}" -gt 0 ]] || die "--validate-interval-seconds must be > 0."
}

sanitize_overlay_env() {
  # Prevent inherited shell exports from overriding overlay vars during dry-run
  # and normal execution. CLI flags still win afterwards.
  [[ -z "${CLUSTER_NAME}" ]] && unset TALOS_CLUSTER_NAME || true
  [[ -z "${CLUSTER_ENDPOINT}" ]] && unset TALOS_CLUSTER_ENDPOINT || true
  [[ -z "${CP_IPS_RAW}" ]] && unset TALOS_CONTROL_PLANE_IPS || true
  [[ -z "${WORKER_IPS_RAW}" ]] && unset TALOS_WORKER_IPS || true
  unset TALOS_CONTROL_PLANE_CONFIG_PATH || true
  unset TALOS_WORKER_CONFIG_PATH || true
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
  local item=""
  read -r -a _arr <<<"${csv}"
  for item in "${_arr[@]}"; do
    [[ -n "${item}" ]] || continue
    printf '%s\n' "${item}"
  done
}

resolve_repo_path() {
  local path_value="$1"
  if [[ -z "${path_value}" ]]; then
    printf '%s\n' ""
    return 0
  fi
  if [[ "${path_value}" = /* ]]; then
    printf '%s\n' "${path_value}"
  else
    printf '%s\n' "${REPO_ROOT}/${path_value}"
  fi
}

normalize_endpoint() {
  local endpoint="$1"
  endpoint="${endpoint#http://}"
  endpoint="${endpoint#https://}"
  printf 'https://%s\n' "${endpoint}"
}

endpoint_host() {
  local endpoint="$1"
  endpoint="${endpoint#http://}"
  endpoint="${endpoint#https://}"
  endpoint="${endpoint%%/*}"
  endpoint="${endpoint%%:*}"
  printf '%s\n' "${endpoint}"
}

endpoint_port() {
  local endpoint="$1"
  local stripped=""
  local host_port=""
  stripped="${endpoint#http://}"
  stripped="${stripped#https://}"
  host_port="${stripped%%/*}"
  if [[ "${host_port}" == *:* ]]; then
    printf '%s\n' "${host_port##*:}"
  else
    printf '6443\n'
  fi
}

normalize_bool() {
  local value="${1:-}"
  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  case "${value}" in
    1|true|yes|on) printf 'true\n' ;;
    0|false|no|off|"") printf 'false\n' ;;
    *) die "Invalid boolean value: ${1}" ;;
  esac
}

run_or_echo() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

is_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<<"${ip}"
  (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 ))
}

discover_bootstrap_ips_for_apply() {
  local bootstrap_file="${GENERATED_DIR}/bootstrap-ips.txt"
  local cp_prefix="${TALOS_CONTROL_PLANE_NAME_PREFIX:-talos-cp}"
  local worker_prefix="${TALOS_WORKER_NAME_PREFIX:-talos-worker}"
  local timeout="${TALOS_BOOTSTRAP_DISCOVERY_TIMEOUT:-300}"
  local interval="${TALOS_BOOTSTRAP_DISCOVERY_INTERVAL:-5}"
  local deadline now
  local cp_count="${#CP_IPS[@]}"
  local worker_count="${#WORKER_IPS[@]}"
  local expected=$((cp_count + worker_count))
  local found=0
  local i vm_name ip tmp_file
  declare -A seen=()

  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout="300"
  [[ "${interval}" =~ ^[0-9]+$ ]] || interval="5"
  (( timeout > 0 )) || timeout=300
  (( interval > 0 )) || interval=5

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] discover bootstrap DHCP IPs into ${bootstrap_file}"
    return 0
  fi

  command -v govc >/dev/null 2>&1 || die "govc is required to discover bootstrap DHCP IPs in apply-config phase."
  export_common_tool_env >/dev/null 2>&1 || true

  deadline=$(( "$(date +%s)" + timeout ))
  mkdir -p "${GENERATED_DIR}"

  while true; do
    now="$(date +%s)"
    (( now <= deadline )) || break

    tmp_file="$(mktemp)"
    found=0
    seen=()

    for ((i = 1; i <= cp_count; i++)); do
      vm_name="${cp_prefix}-${i}"
      ip="$(timeout 3 govc vm.ip -wait 1s "${vm_name}" 2>/dev/null | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print; exit}' || true)"
      if [[ -n "${ip}" ]] && is_ipv4 "${ip}"; then
        printf '%s %s %s\n' "control-plane-${i}" "${vm_name}" "${ip}" >> "${tmp_file}"
        seen["${ip}"]=1
      fi
    done

    for ((i = 1; i <= worker_count; i++)); do
      vm_name="${worker_prefix}-${i}"
      ip="$(timeout 3 govc vm.ip -wait 1s "${vm_name}" 2>/dev/null | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print; exit}' || true)"
      if [[ -n "${ip}" ]] && is_ipv4 "${ip}"; then
        printf '%s %s %s\n' "worker-${i}" "${vm_name}" "${ip}" >> "${tmp_file}"
        seen["${ip}"]=1
      fi
    done

    mv "${tmp_file}" "${bootstrap_file}"
    found="${#seen[@]}"
    if (( found >= expected )); then
      log_info "Discovered bootstrap DHCP IPs for ${found}/${expected} nodes: ${bootstrap_file}"
      return 0
    fi

    sleep "${interval}"
  done

  if [[ -s "${bootstrap_file}" ]]; then
    log_warn "Bootstrap DHCP discovery timed out (${timeout}s). Partial inventory saved: ${bootstrap_file}"
  else
    log_warn "Bootstrap DHCP discovery timed out (${timeout}s) and no inventory was discovered."
  fi
}

load_apply_target_ips() {
  local bootstrap_file="${GENERATED_DIR}/bootstrap-ips.txt"
  local role="" vm_name="" ip=""
  local idx=""
  local updates=0
  local cp_found=0
  local worker_found=0
  local iso_mode="false"
  local require_bootstrap_ips="true"
  local static_ip=""
  local target_ip=""

  APPLY_CP_IPS=("${CP_IPS[@]}")
  APPLY_WORKER_IPS=("${WORKER_IPS[@]}")

  [[ -z "${TALOS_OVA_PATH:-}" ]] && iso_mode="true"
  if [[ -n "${TALOS_ISO_REQUIRE_BOOTSTRAP_IPS:-}" ]]; then
    require_bootstrap_ips="$(normalize_bool "${TALOS_ISO_REQUIRE_BOOTSTRAP_IPS}")"
  fi

  if [[ "${iso_mode}" == "true" && "${APPLY_STAGE}" != "post" ]]; then
    discover_bootstrap_ips_for_apply
  fi

  if [[ ! -s "${bootstrap_file}" ]]; then
    if [[ "${iso_mode}" == "true" && "${require_bootstrap_ips}" == "true" ]]; then
      die "ISO mode requires bootstrap DHCP inventory before apply-config. Missing or empty: ${bootstrap_file}"
    fi
    return 0
  fi

  while read -r role vm_name ip; do
    [[ -n "${role:-}" && -n "${ip:-}" ]] || continue
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
    if [[ "${role}" =~ ^control-plane-([0-9]+)$ ]]; then
      idx="${BASH_REMATCH[1]}"
      APPLY_CP_IPS[$((idx - 1))]="${ip}"
      updates=$((updates + 1))
      cp_found=$((cp_found + 1))
    elif [[ "${role}" =~ ^worker-([0-9]+)$ ]]; then
      idx="${BASH_REMATCH[1]}"
      APPLY_WORKER_IPS[$((idx - 1))]="${ip}"
      updates=$((updates + 1))
      worker_found=$((worker_found + 1))
    fi
  done < "${bootstrap_file}"

  if (( updates > 0 )); then
    log_info "Using bootstrap inventory addresses for apply phase: ${bootstrap_file}"
  fi

  for idx in "${!CP_IPS[@]}"; do
    static_ip="${CP_IPS[$idx]}"
    target_ip="${APPLY_CP_IPS[$idx]:-}"
    if [[ -n "${target_ip}" && "${target_ip}" != "${static_ip}" ]]; then
      log_info "control-plane-$((idx + 1)) bootstrap IP ${target_ip} differs from static ${static_ip}; applying via bootstrap IP first."
    fi
  done

  for idx in "${!WORKER_IPS[@]}"; do
    static_ip="${WORKER_IPS[$idx]}"
    target_ip="${APPLY_WORKER_IPS[$idx]:-}"
    if [[ -n "${target_ip}" && "${target_ip}" != "${static_ip}" ]]; then
      log_info "worker-$((idx + 1)) bootstrap IP ${target_ip} differs from static ${static_ip}; applying via bootstrap IP first."
    fi
  done

  if [[ "${iso_mode}" == "true" && "${require_bootstrap_ips}" == "true" ]]; then
    if (( cp_found < ${#CP_IPS[@]} )); then
      die "ISO mode requires bootstrap DHCP IPs for all control-plane nodes before apply-config. Found ${cp_found}/${#CP_IPS[@]} in ${bootstrap_file}."
    fi
    if (( worker_found < ${#WORKER_IPS[@]} )); then
      die "ISO mode requires bootstrap DHCP IPs for all workers before apply-config. Found ${worker_found}/${#WORKER_IPS[@]} in ${bootstrap_file}."
    fi
  fi
}

apply_installer_image_override() {
  local config_file="$1"
  local installer_image="$2"
  local patch_file=""
  local tmp_file=""

  [[ -f "${config_file}" ]] || die "Missing config file for installer override: ${config_file}"
  [[ -n "${installer_image}" ]] || return 0

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] apply installer image override on ${config_file}: ${installer_image}"
    return 0
  fi

  patch_file="$(mktemp)"
  cat > "${patch_file}" <<EOF_PATCH
machine:
  install:
    image: ${installer_image}
EOF_PATCH

  tmp_file="$(mktemp)"
  talosctl machineconfig patch "${config_file}" -p "@${patch_file}" -o "${tmp_file}" >/dev/null
  mv "${tmp_file}" "${config_file}"
  rm -f "${patch_file}"
}

build_controlplane_vip_patch_file() {
  local vip_enabled="${TALOS_CONTROL_PLANE_VIP_ENABLED:-true}"
  local vip_ip="${TALOS_CONTROL_PLANE_VIP:-${HAPROXY_VIP:-}}"
  local iface="${TALOS_NODE_INTERFACE:-eth0}"
  local lb_vip="${HAPROXY_VIP:-}"
  local patch_file=""

  vip_enabled="$(normalize_bool "${vip_enabled}")"
  [[ "${vip_enabled}" == "true" ]] || return 0
  [[ -n "${vip_ip}" ]] || return 0
  if [[ -n "${lb_vip}" && "${vip_ip}" == "${lb_vip}" ]]; then
    die "Control-plane VIP (${vip_ip}) matches HAPROXY_VIP (${lb_vip}). Use distinct IPs, or set TALOS_CONTROL_PLANE_VIP_ENABLED=false when using external LB."
  fi

  patch_file="$(mktemp)"
  cat > "${patch_file}" <<EOF_PATCH
machine:
  network:
    interfaces:
      - interface: ${iface}
        vip:
          ip: ${vip_ip}
EOF_PATCH

  printf '%s\n' "${patch_file}"
}

render_node_network_patches() {
  local cluster_patches_dir="$1"
  local cp_prefix="${TALOS_CONTROL_PLANE_NAME_PREFIX:-talos-cp}"
  local worker_prefix="${TALOS_WORKER_NAME_PREFIX:-talos-worker}"
  local iface="${TALOS_NODE_INTERFACE:-eth0}"
  local gateway="${TALOS_GATEWAY:-${NETWORK_GATEWAY:-}}"
  local netmask="${TALOS_NETMASK_PREFIX:-${NETWORK_NETMASK_PREFIX:-24}}"
  local dns_raw="${TALOS_NAMESERVERS:-${NETWORK_NAMESERVERS:-}}"
  local dns_csv=""
  local dns_ip=""
  local -a dns_list=()
  local idx=1
  local ip=""
  local patch_file=""

  mkdir -p "${cluster_patches_dir}"
  dns_csv="$(normalize_csv_list "${dns_raw}")"
  if [[ -n "${dns_csv}" ]]; then
    mapfile -t dns_list < <(csv_to_array "${dns_csv}")
  fi

  for ip in "${CP_IPS[@]}"; do
    patch_file="${cluster_patches_dir}/${cp_prefix}-${idx}.patch.yaml"
    {
      echo "machine:"
      echo "  network:"
      echo "    interfaces:"
      echo "      - interface: ${iface}"
      echo "        addresses:"
      echo "          - ${ip}/${netmask}"
      echo "        routes:"
      echo "          - network: 0.0.0.0/0"
      echo "            gateway: ${gateway}"
      echo "        dhcp: false"
      if (( ${#dns_list[@]} > 0 )); then
        echo "    nameservers:"
        for dns_ip in "${dns_list[@]}"; do
          [[ -n "${dns_ip}" ]] || continue
          echo "      - ${dns_ip}"
        done
      fi
    } > "${patch_file}"
    idx=$((idx + 1))
  done

  idx=1
  for ip in "${WORKER_IPS[@]}"; do
    patch_file="${cluster_patches_dir}/${worker_prefix}-${idx}.patch.yaml"
    {
      echo "machine:"
      echo "  network:"
      echo "    interfaces:"
      echo "      - interface: ${iface}"
      echo "        addresses:"
      echo "          - ${ip}/${netmask}"
      echo "        routes:"
      echo "          - network: 0.0.0.0/0"
      echo "            gateway: ${gateway}"
      echo "        dhcp: false"
      if (( ${#dns_list[@]} > 0 )); then
        echo "    nameservers:"
        for dns_ip in "${dns_list[@]}"; do
          [[ -n "${dns_ip}" ]] || continue
          echo "      - ${dns_ip}"
        done
      fi
    } > "${patch_file}"
    idx=$((idx + 1))
  done
}

render_bootstrap_patch() {
  local cluster_patches_dir="$1"
  local bootstrap_patch_file="${cluster_patches_dir}/bootstrap.patch.yaml"
  local dns_raw="${TALOS_NAMESERVERS:-${NETWORK_NAMESERVERS:-}}"
  local dns_csv=""
  local dns_ip=""
  local -a dns_list=()
  local include_nameservers="${TALOS_BOOTSTRAP_INCLUDE_NAMESERVERS:-false}"
  local time_disabled="${TALOS_BOOTSTRAP_TIME_DISABLED:-true}"
  local hostdns_enabled="${TALOS_BOOTSTRAP_HOST_DNS_ENABLED:-false}"
  local hostdns_forward="${TALOS_BOOTSTRAP_FORWARD_KUBE_DNS_TO_HOST:-false}"

  mkdir -p "${cluster_patches_dir}"

  dns_csv="$(normalize_csv_list "${dns_raw}")"
  if [[ -n "${dns_csv}" ]]; then
    mapfile -t dns_list < <(csv_to_array "${dns_csv}")
  fi
  include_nameservers="$(normalize_bool "${include_nameservers}")"

  {
    echo "machine:"
    echo "  time:"
    echo "    disabled: ${time_disabled}"
    echo "  features:"
    echo "    hostDNS:"
    echo "      enabled: ${hostdns_enabled}"
    echo "      forwardKubeDNSToHost: ${hostdns_forward}"
    if [[ "${include_nameservers}" == "true" ]] && (( ${#dns_list[@]} > 0 )); then
      echo "  network:"
      echo "    nameservers:"
      for dns_ip in "${dns_list[@]}"; do
        [[ -n "${dns_ip}" ]] || continue
        echo "      - ${dns_ip}"
      done
    fi
  } > "${bootstrap_patch_file}"
}

build_generate_patch_args() {
  local kind="$1"
  local global_patches_dir="$2"
  local cluster_patches_dir="$3"
  local role_bootstrap_patch=""
  local role_common_patch=""
  local -a args=()

  if [[ "${kind}" == "control-plane" ]]; then
    role_bootstrap_patch="cp-bootstrap.patch.yaml"
    role_common_patch="cp.patch.yaml"
  else
    role_bootstrap_patch="worker-bootstrap.patch.yaml"
    role_common_patch="worker.patch.yaml"
  fi

  if [[ -n "${global_patches_dir}" && -d "${global_patches_dir}" ]]; then
    [[ -f "${global_patches_dir}/dns.patch.yaml" ]] && args+=("--config-patch-${kind}" "@${global_patches_dir}/dns.patch.yaml")
    [[ -f "${global_patches_dir}/flannel.patch.yaml" ]] && args+=("--config-patch-${kind}" "@${global_patches_dir}/flannel.patch.yaml")
  fi

  [[ -n "${CNI_PATCH_FILE}" ]] && args+=("--config-patch-${kind}" "@${CNI_PATCH_FILE}")
  [[ -f "${cluster_patches_dir}/bootstrap.patch.yaml" ]] && args+=("--config-patch-${kind}" "@${cluster_patches_dir}/bootstrap.patch.yaml")
  [[ -f "${cluster_patches_dir}/${role_common_patch}" ]] && args+=("--config-patch-${kind}" "@${cluster_patches_dir}/${role_common_patch}")
  [[ -s "${cluster_patches_dir}/${role_bootstrap_patch}" ]] && args+=("--config-patch-${kind}" "@${cluster_patches_dir}/${role_bootstrap_patch}")
  if [[ "${kind}" == "worker" ]]; then
    [[ -f "${cluster_patches_dir}/longhorn.patch.yaml" ]] && args+=("--config-patch-${kind}" "@${cluster_patches_dir}/longhorn.patch.yaml")
  fi
  [[ -f "${cluster_patches_dir}/dns.patch.yaml" ]] && args+=("--config-patch-${kind}" "@${cluster_patches_dir}/dns.patch.yaml")

  printf '%s\n' "${args[@]}"
}

patch_for_node() {
  local base_cfg="$1"
  local kind="$2"        # controlplane|worker
  local index="$3"
  local global_patches_dir="$4"
  local cluster_patches_dir="$5"
  local cp_prefix="${TALOS_CONTROL_PLANE_NAME_PREFIX:-talos-cp}"
  local worker_prefix="${TALOS_WORKER_NAME_PREFIX:-talos-worker}"
  local named_patch=""
  local role_bootstrap_patch=""
  local role_common_patch=""
  local current=""
  local tmp=""
  local patch=""
  local -a chain=()

  if [[ "${kind}" == "controlplane" ]]; then
    role_bootstrap_patch="cp-bootstrap.patch.yaml"
    role_common_patch="cp.patch.yaml"
  else
    role_bootstrap_patch="worker-bootstrap.patch.yaml"
    role_common_patch="worker.patch.yaml"
  fi

  if [[ -n "${global_patches_dir}" && -d "${global_patches_dir}" ]]; then
    [[ -f "${global_patches_dir}/bootstrap.patch.yaml" ]] && chain+=("${global_patches_dir}/bootstrap.patch.yaml")
    [[ -s "${global_patches_dir}/${role_bootstrap_patch}" ]] && chain+=("${global_patches_dir}/${role_bootstrap_patch}")
    [[ -f "${global_patches_dir}/dns.patch.yaml" ]] && chain+=("${global_patches_dir}/dns.patch.yaml")
    [[ -f "${global_patches_dir}/flannel.patch.yaml" ]] && chain+=("${global_patches_dir}/flannel.patch.yaml")
    [[ -f "${global_patches_dir}/${kind}-${index}.patch.yaml" ]] && chain+=("${global_patches_dir}/${kind}-${index}.patch.yaml")
  fi

  [[ -n "${CNI_PATCH_FILE}" ]] && chain+=("${CNI_PATCH_FILE}")
  [[ -f "${cluster_patches_dir}/bootstrap.patch.yaml" ]] && chain+=("${cluster_patches_dir}/bootstrap.patch.yaml")
  [[ -f "${cluster_patches_dir}/${role_common_patch}" ]] && chain+=("${cluster_patches_dir}/${role_common_patch}")
  [[ -s "${cluster_patches_dir}/${role_bootstrap_patch}" ]] && chain+=("${cluster_patches_dir}/${role_bootstrap_patch}")
  [[ -f "${cluster_patches_dir}/dns.patch.yaml" ]] && chain+=("${cluster_patches_dir}/dns.patch.yaml")
  [[ -f "${cluster_patches_dir}/${kind}-${index}.patch.yaml" ]] && chain+=("${cluster_patches_dir}/${kind}-${index}.patch.yaml")
  if [[ "${kind}" == "controlplane" ]]; then
    named_patch="${cluster_patches_dir}/${cp_prefix}-${index}.patch.yaml"
  else
    named_patch="${cluster_patches_dir}/${worker_prefix}-${index}.patch.yaml"
  fi
  [[ -f "${named_patch}" ]] && chain+=("${named_patch}")

  if (( ${#chain[@]} == 0 )); then
    printf '%s\n' "${base_cfg}"
    return 0
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '%s\n' "${base_cfg}"
    return 0
  fi

  current="$(mktemp)"
  cp "${base_cfg}" "${current}"

  for patch in "${chain[@]}"; do
    tmp="$(mktemp)"
    talosctl machineconfig patch "${current}" -p "@${patch}" -o "${tmp}" >/dev/null
    mv "${tmp}" "${current}"
  done

  printf '%s\n' "${current}"
}

run_generate() {
  local global_patches_dir="$1"
  local cluster_patches_dir="$2"
  local cp_installer_image="${TALOS_CONTROL_PLANE_INSTALLER_IMAGE:-${TALOS_INSTALLER_IMAGE:-}}"
  local worker_installer_image="${TALOS_WORKER_INSTALLER_IMAGE:-${TALOS_INSTALLER_IMAGE:-}}"
  local cp_base=""
  local worker_base=""
  local arg=""
  local -a cp_patch_args=()
  local -a worker_patch_args=()
  local secrets_file=""
  local cp_vip_patch_file=""
  local -a gen_args=()

  mkdir -p "${GENERATED_DIR}"
  cp_base="${GENERATED_DIR}/controlplane.yaml"
  worker_base="${GENERATED_DIR}/worker.yaml"
  secrets_file="${GENERATED_DIR}/secrets.yaml"

  if [[ "${FORCE_GENERATE}" != "true" && "${ROTATE_SECRETS}" != "true" \
     && -f "${cp_base}" && -f "${worker_base}" && -f "${GENERATED_DIR}/talosconfig" && -f "${secrets_file}" ]]; then
    log_info "Reusing existing generated Talos config bundle in ${GENERATED_DIR} (use --force-generate to regenerate)."
    return 0
  fi

  while IFS= read -r arg; do
    [[ -n "${arg}" ]] && cp_patch_args+=("${arg}")
  done < <(build_generate_patch_args "control-plane" "${global_patches_dir}" "${cluster_patches_dir}")

  cp_vip_patch_file="$(build_controlplane_vip_patch_file || true)"
  if [[ -n "${cp_vip_patch_file}" ]]; then
    log_info "Injecting control-plane VIP in generated config: ${TALOS_CONTROL_PLANE_VIP:-${HAPROXY_VIP:-}} (interface: ${TALOS_NODE_INTERFACE:-eth0})"
    cp_patch_args+=("--config-patch-control-plane" "@${cp_vip_patch_file}")
  fi

  while IFS= read -r arg; do
    [[ -n "${arg}" ]] && worker_patch_args+=("${arg}")
  done < <(build_generate_patch_args "worker" "${global_patches_dir}" "${cluster_patches_dir}")

  if [[ "${ROTATE_SECRETS}" == "true" || ! -f "${secrets_file}" ]]; then
    log_info "Generating Talos secrets bundle: ${secrets_file}"
    run_or_echo talosctl gen secrets --output-file "${secrets_file}" --force
  else
    log_info "Reusing Talos secrets bundle: ${secrets_file}"
  fi

  gen_args=(
    gen
    config
    "${CLUSTER_NAME}"
    "${CLUSTER_ENDPOINT}"
    --output-dir "${GENERATED_DIR}"
    --with-secrets "${secrets_file}"
    --force
  )
  gen_args+=("${cp_patch_args[@]}")
  gen_args+=("${worker_patch_args[@]}")

  log_info "Generating Talos configs into ${GENERATED_DIR}"
  run_or_echo talosctl "${gen_args[@]}"

  if [[ -n "${cp_vip_patch_file}" ]]; then
    rm -f "${cp_vip_patch_file}"
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    return 0
  fi

  [[ -f "${cp_base}" ]] || die "Missing generated controlplane config: ${cp_base}"
  [[ -f "${worker_base}" ]] || die "Missing generated worker config: ${worker_base}"
  [[ -f "${GENERATED_DIR}/talosconfig" ]] || die "Missing generated talosconfig: ${GENERATED_DIR}/talosconfig"

  if [[ -n "${cp_installer_image}" ]]; then
    log_info "Applying control-plane installer image override: ${cp_installer_image}"
    apply_installer_image_override "${cp_base}" "${cp_installer_image}"
  fi

  if [[ -n "${worker_installer_image}" ]]; then
    log_info "Applying worker installer image override: ${worker_installer_image}"
    apply_installer_image_override "${worker_base}" "${worker_installer_image}"
  fi
}

run_apply() {
  local global_patches_dir="$1"
  local cluster_patches_dir="$2"
  local cp_base="${GENERATED_DIR}/controlplane.yaml"
  local worker_base="${GENERATED_DIR}/worker.yaml"
  local idx=0
  local ip=""
  local cfg=""
  local talosconfig_path="${GENERATED_DIR}/talosconfig"
  local effective_apply_stage="${APPLY_STAGE}"

  if [[ "${DRY_RUN}" != "true" ]]; then
    [[ -f "${cp_base}" ]] || die "Missing generated controlplane config: ${cp_base}. Run --mode=generate first."
    [[ -f "${worker_base}" ]] || die "Missing generated worker config: ${worker_base}. Run --mode=generate first."
  fi

  log_info "Apply stage: ${APPLY_STAGE}"
  load_apply_target_ips
  if [[ "${effective_apply_stage}" == "auto" ]]; then
    # In cluster.sh flow:
    # - prepare-bootstrap forces --apply-stage=pre
    # - apply-config uses auto and is typically post-bootstrap convergence
    effective_apply_stage="post"
  fi

  idx=1
  for ip in "${APPLY_CP_IPS[@]}"; do
    cfg="$(patch_for_node "${cp_base}" "controlplane" "${idx}" "${global_patches_dir}" "${cluster_patches_dir}")"
    log_info "Applying control-plane config to ${ip}"
    if [[ "${DRY_RUN}" == "true" ]]; then
      if [[ "${effective_apply_stage}" == "pre" ]]; then
        run_or_echo talosctl apply-config --insecure --nodes "${ip}" --file "${cfg}"
      else
        run_or_echo talosctl --talosconfig "${talosconfig_path}" --nodes "${ip}" --endpoints "${ip}" apply-config --file "${cfg}"
      fi
    else
      if [[ "${effective_apply_stage}" == "pre" ]]; then
        local insecure_output=""
        if ! insecure_output="$(talosctl apply-config --insecure --nodes "${ip}" --file "${cfg}" 2>&1)"; then
          if grep -qi "tls: certificate required" <<<"${insecure_output}"; then
            log_info "Node ${ip} already requires TLS; retrying with talosconfig."
          else
            printf '%s\n' "${insecure_output}" >&2
            log_warn "Insecure apply failed for ${ip}; retrying with talosconfig."
          fi
          talosctl --talosconfig "${talosconfig_path}" --nodes "${ip}" --endpoints "${ip}" apply-config --file "${cfg}"
        elif [[ -n "${insecure_output}" ]]; then
          printf '%s\n' "${insecure_output}"
        fi
      else
        talosctl --talosconfig "${talosconfig_path}" --nodes "${ip}" --endpoints "${ip}" apply-config --file "${cfg}"
      fi
    fi
    [[ "${cfg}" != "${cp_base}" ]] && rm -f "${cfg}"
    idx=$((idx + 1))
  done

  if (( ${#APPLY_WORKER_IPS[@]} == 0 )); then
    log_warn "Worker IP list is empty; skipping worker apply phase."
    return 0
  fi

  idx=1
  for ip in "${APPLY_WORKER_IPS[@]}"; do
    cfg="$(patch_for_node "${worker_base}" "worker" "${idx}" "${global_patches_dir}" "${cluster_patches_dir}")"
    log_info "Applying worker config to ${ip}"
    if [[ "${DRY_RUN}" == "true" ]]; then
      if [[ "${effective_apply_stage}" == "pre" ]]; then
        run_or_echo talosctl apply-config --insecure --nodes "${ip}" --file "${cfg}"
      else
        run_or_echo talosctl --talosconfig "${talosconfig_path}" --nodes "${ip}" --endpoints "${ip}" apply-config --file "${cfg}"
      fi
    else
      if [[ "${effective_apply_stage}" == "pre" ]]; then
        local insecure_output=""
        if ! insecure_output="$(talosctl apply-config --insecure --nodes "${ip}" --file "${cfg}" 2>&1)"; then
          if grep -qi "tls: certificate required" <<<"${insecure_output}"; then
            log_info "Node ${ip} already requires TLS; retrying with talosconfig."
          else
            printf '%s\n' "${insecure_output}" >&2
            log_warn "Insecure apply failed for ${ip}; retrying with talosconfig."
          fi
          talosctl --talosconfig "${talosconfig_path}" --nodes "${ip}" --endpoints "${ip}" apply-config --file "${cfg}"
        elif [[ -n "${insecure_output}" ]]; then
          printf '%s\n' "${insecure_output}"
        fi
      else
        talosctl --talosconfig "${talosconfig_path}" --nodes "${ip}" --endpoints "${ip}" apply-config --file "${cfg}"
      fi
    fi
    [[ "${cfg}" != "${worker_base}" ]] && rm -f "${cfg}"
    idx=$((idx + 1))
  done
}

run_bootstrap() {
  local talosconfig_path="${GENERATED_DIR}/talosconfig"
  local bootstrap_output=""
  if [[ "${DRY_RUN}" != "true" ]]; then
    [[ -f "${talosconfig_path}" ]] || die "Missing talosconfig: ${talosconfig_path}. Run --mode=generate first."
  fi
  log_info "Bootstrapping cluster via ${BOOTSTRAP_NODE}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    run_or_echo talosctl --talosconfig "${talosconfig_path}" \
      --nodes "${BOOTSTRAP_NODE}" \
      --endpoints "${BOOTSTRAP_NODE}" \
      bootstrap
    return 0
  fi

  if ! bootstrap_output="$(
    talosctl --talosconfig "${talosconfig_path}" \
      --nodes "${BOOTSTRAP_NODE}" \
      --endpoints "${BOOTSTRAP_NODE}" \
      bootstrap 2>&1
  )"; then
    if grep -qiE "AlreadyExists|etcd data directory is not empty" <<<"${bootstrap_output}"; then
      log_warn "Cluster appears already bootstrapped; continuing."
      return 0
    fi
    printf '%s\n' "${bootstrap_output}" >&2
    return 1
  fi
  [[ -n "${bootstrap_output}" ]] && printf '%s\n' "${bootstrap_output}"
}

run_lb_reconcile() {
  local configure_script="${BOOTSTRAP_SCRIPT_DIR}/configure_load_balancer.sh"
  local cp_csv=""
  local vip=""
  local endpoint_vip=""
  local -a lb_args=()

  [[ "${AUTO_CONFIGURE_LB}" == "true" ]] || return 0
  require_file "${configure_script}"
  if [[ -z "${TALOS_LOAD_BALANCER_RECONCILE_SCRIPT:-}" ]]; then
    log_info "Skipping load balancer reconciliation: TALOS_LOAD_BALANCER_RECONCILE_SCRIPT is not set."
    return 0
  fi

  cp_csv="$(IFS=,; echo "${CP_IPS[*]}")"
  endpoint_vip="$(endpoint_host "${CLUSTER_ENDPOINT}")"
  vip="${HAPROXY_VIP:-${endpoint_vip}}"

  [[ -n "${vip}" ]] || die "Could not resolve Talos VIP for HAProxy reconciliation."

  lb_args=(
    "--env=${ENV_NAME}"
    "--append"
    "--cluster-name=${CLUSTER_NAME}"
    "--vip=${vip}"
    "--cp-ips=${cp_csv}"
  )

  if [[ "${DRY_RUN}" == "true" ]]; then
    lb_args+=("--dry-run")
  fi

  log_info "Reconciling Talos HAProxy frontend/backend for cluster '${CLUSTER_NAME}' at ${vip}:6443"
  run_or_echo "${configure_script}" "${lb_args[@]}"
}

run_post_validation() {
  local endpoint_ip=""
  local endpoint_kube_port=""
  local elapsed=0
  local curl_output=""
  local tcp_ok="false"

  [[ "${VALIDATE_POST_BOOTSTRAP}" == "true" ]] || return 0
  [[ "${MODE}" == "bootstrap" || "${MODE}" == "all" ]] || return 0

  endpoint_ip="$(endpoint_host "${CLUSTER_ENDPOINT}")"
  endpoint_kube_port="$(endpoint_port "${CLUSTER_ENDPOINT}")"
  [[ -n "${endpoint_ip}" ]] || die "Could not parse endpoint host from ${CLUSTER_ENDPOINT}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] validate kube-api readiness at https://${endpoint_ip}:${endpoint_kube_port}/readyz"
    return 0
  fi

  log_info "Validating kube-api readiness at https://${endpoint_ip}:${endpoint_kube_port}/readyz"
  while (( elapsed < VALIDATE_TIMEOUT_SECONDS )); do
    if command -v curl >/dev/null 2>&1; then
      if curl_output="$(curl -ksS --max-time 5 "https://${endpoint_ip}:${endpoint_kube_port}/readyz" 2>/dev/null || true)"; then
        :
      fi
      if [[ "${curl_output}" == *"ok"* ]]; then
        log_info "kube-api readiness check succeeded through VIP ${endpoint_ip}:${endpoint_kube_port}."
        return 0
      fi
    else
      if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${endpoint_ip}/${endpoint_kube_port}" >/dev/null 2>&1; then
        tcp_ok="true"
      else
        tcp_ok="false"
      fi
      if [[ "${tcp_ok}" == "true" ]]; then
        log_warn "curl not found; TCP connectivity to ${endpoint_ip}:${endpoint_kube_port} is up."
        return 0
      fi
    fi

    sleep "${VALIDATE_INTERVAL_SECONDS}"
    elapsed=$((elapsed + VALIDATE_INTERVAL_SECONDS))
  done

  die "kube-api readiness check failed after ${VALIDATE_TIMEOUT_SECONDS}s for https://${endpoint_ip}:${endpoint_kube_port}/readyz."
}

main() {
  local cluster_patches_dir=""
  local global_patches_dir=""
  local cp_cfg_path=""
  local worker_cfg_path=""
  local cluster_patches_default=""
  local generated_dir_default=""

  parse_args "$@"
  validate_args

  sanitize_overlay_env
  load_overlay_vars "${ENV_NAME}"

  if ! command -v talosctl >/dev/null 2>&1; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_warn "talosctl not found, but continuing due to --dry-run."
    else
      die "talosctl not found. Install talosctl and retry."
    fi
  fi

  CLUSTER_NAME="${CLUSTER_NAME:-${TALOS_CLUSTER_NAME:-k8s-cluster-lab}}"
  CLUSTER_ENDPOINT="${CLUSTER_ENDPOINT:-${TALOS_CLUSTER_ENDPOINT:-${HAPROXY_VIP:-192.168.0.30}:6443}}"
  CLUSTER_ENDPOINT="$(normalize_endpoint "${CLUSTER_ENDPOINT}")"

  CP_IPS_RAW="${CP_IPS_RAW:-${TALOS_CONTROL_PLANE_IPS:-}}"
  WORKER_IPS_RAW="${WORKER_IPS_RAW:-${TALOS_WORKER_IPS:-}}"
  CP_IPS_RAW="$(normalize_csv_list "${CP_IPS_RAW}")"
  WORKER_IPS_RAW="$(normalize_csv_list "${WORKER_IPS_RAW}")"
  mapfile -t CP_IPS < <(csv_to_array "${CP_IPS_RAW}")
  mapfile -t WORKER_IPS < <(csv_to_array "${WORKER_IPS_RAW}")

  (( ${#CP_IPS[@]} > 0 )) || die "Control-plane IPs are empty."

  BOOTSTRAP_NODE="${BOOTSTRAP_NODE:-${CP_IPS[0]}}"
  if [[ -z "${DISABLE_DEFAULT_CNI}" ]]; then
    DISABLE_DEFAULT_CNI="${TALOS_DISABLE_DEFAULT_CNI:-false}"
  fi
  DISABLE_DEFAULT_CNI="$(normalize_bool "${DISABLE_DEFAULT_CNI}")"

  cp_cfg_path="$(resolve_repo_path "${TALOS_CONTROL_PLANE_CONFIG_PATH:-}")"
  worker_cfg_path="$(resolve_repo_path "${TALOS_WORKER_CONFIG_PATH:-}")"
  if [[ -n "${GENERATED_DIR}" ]]; then
    GENERATED_DIR="$(resolve_repo_path "${GENERATED_DIR}")"
  elif [[ -n "${cp_cfg_path}" ]]; then
    GENERATED_DIR="$(dirname "${cp_cfg_path}")"
  elif [[ -n "${worker_cfg_path}" ]]; then
    GENERATED_DIR="$(dirname "${worker_cfg_path}")"
  else
    generated_dir_default="overlays/${ENV_NAME}/talos/${CLUSTER_NAME}/generated"
    GENERATED_DIR="$(resolve_repo_path "${generated_dir_default}")"
  fi

  cluster_patches_default="$(dirname "${GENERATED_DIR}")/patches"
  if [[ -d "${cluster_patches_default}" ]]; then
    cluster_patches_dir="${cluster_patches_default}"
  elif [[ -n "${cp_cfg_path}" ]]; then
    cluster_patches_dir="$(dirname "${cp_cfg_path}")/patches"
  else
    cluster_patches_dir="${cluster_patches_default}"
  fi

  global_patches_dir=""

  [[ -d "${cluster_patches_dir}" ]] || log_warn "Cluster patches directory not found: ${cluster_patches_dir}. Proceeding without cluster patches."
  CNI_PATCH_FILE=""
  if [[ "${DISABLE_DEFAULT_CNI}" == "true" ]]; then
    if [[ -f "${cluster_patches_dir}/cni.patch.yaml" ]]; then
      CNI_PATCH_FILE="${cluster_patches_dir}/cni.patch.yaml"
    elif [[ -n "${global_patches_dir}" && -f "${global_patches_dir}/cni.patch.yaml" ]]; then
      CNI_PATCH_FILE="${global_patches_dir}/cni.patch.yaml"
    fi
    [[ -n "${CNI_PATCH_FILE}" ]] || die "TALOS_DISABLE_DEFAULT_CNI=true but cni.patch.yaml was not found."
  fi
  render_bootstrap_patch "${cluster_patches_dir}"
  render_node_network_patches "${cluster_patches_dir}"
  log_info "Rendered bootstrap and per-node network patches from overlay vars in: ${cluster_patches_dir}"
  if [[ "${DISABLE_DEFAULT_CNI}" == "true" ]]; then
    log_info "Default Talos CNI/kube-proxy disable: enabled (${CNI_PATCH_FILE})"
  else
    log_info "Default Talos CNI/kube-proxy disable: disabled"
  fi
  log_info "Using cluster patches directory: ${cluster_patches_dir}"

  case "${MODE}" in
    generate)
      run_generate "${global_patches_dir}" "${cluster_patches_dir}"
      ;;
    apply)
      if [[ "${APPLY_STAGE}" == "pre" ]]; then
        run_lb_reconcile
      fi
      run_apply "${global_patches_dir}" "${cluster_patches_dir}"
      ;;
    bootstrap)
      run_bootstrap
      ;;
    all)
      run_generate "${global_patches_dir}" "${cluster_patches_dir}"
      run_apply "${global_patches_dir}" "${cluster_patches_dir}"
      run_bootstrap
      ;;
  esac

  run_post_validation

  log_info "Day-1 flow completed (mode=${MODE}). Generated files are in: ${GENERATED_DIR}"
}

main "$@"
