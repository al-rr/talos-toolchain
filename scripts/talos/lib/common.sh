#!/usr/bin/env bash

# @describe Shared helper library for overlay-based automation entrypoints.
# @exitcode 0 If sourced successfully.
# @exitcode 1 If executed directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "This file is a library and must be sourced by another script."
  exit 1
fi

overlay_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../../.." >/dev/null 2>&1 && pwd
}

log_info() {
  echo "[INFO] $*"
}

log_warn() {
  echo "[WARN] $*" >&2
}

log_error() {
  echo "[ERROR] $*" >&2
}

die() {
  log_error "$*"
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "${path}" ]] || die "Required file not found: ${path}"
}

env_first() {
  local key
  for key in "$@"; do
    if [[ -n "${!key:-}" ]]; then
      echo "${!key}"
      return 0
    fi
  done
  echo ""
}

to_bool() {
  local value="${1:-}"
  case "${value,,}" in
    1|true|yes|on) echo "true" ;;
    0|false|no|off|"") echo "false" ;;
    *) echo "${value}" ;;
  esac
}

load_legacy_env_file() {
  local repo_root="${1}"
  local env_file="${repo_root}/.env"

  if [[ "${OVERLAY_ALLOW_LEGACY_ENV:-false}" != "true" ]]; then
    return 0
  fi

  if [[ -f "${env_file}" ]]; then
    log_warn "Loading legacy ${env_file}. Prefer overlays/base/scripts/vars.sh and overlays/<env>/scripts/vars.sh."
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  fi
}

normalize_global_env() {
  local endpoint
  endpoint="$(env_first VSPHERE_ENDPOINT vsphere_endpoint GOVC_URL)"
  endpoint="${endpoint#https://}"
  endpoint="${endpoint#http://}"
  endpoint="${endpoint%%/}"

  export VSPHERE_ENDPOINT="${endpoint}"
  export VSPHERE_USERNAME="$(env_first VSPHERE_USERNAME vsphere_username GOVC_USERNAME)"
  export VSPHERE_PASSWORD="$(env_first VSPHERE_PASSWORD vsphere_password GOVC_PASSWORD)"
  export VSPHERE_INSECURE_CONNECTION="$(to_bool "$(env_first VSPHERE_INSECURE_CONNECTION vsphere_insecure_connection GOVC_INSECURE)")"
  export VSPHERE_DATACENTER="$(env_first VSPHERE_DATACENTER vsphere_datacenter GOVC_DATACENTER)"
  export VSPHERE_CLUSTER="$(env_first VSPHERE_CLUSTER vsphere_cluster)"
  export VSPHERE_HOST="$(env_first VSPHERE_HOST vsphere_host)"
  export VSPHERE_DATASTORE="$(env_first VSPHERE_DATASTORE vsphere_datastore GOVC_DATASTORE)"
  export VSPHERE_NETWORK="$(env_first VSPHERE_NETWORK vsphere_network GOVC_NETWORK)"
  export VSPHERE_FOLDER="$(env_first VSPHERE_FOLDER vsphere_folder GOVC_FOLDER)"
  export VSPHERE_RESOURCE_POOL="$(env_first VSPHERE_RESOURCE_POOL vsphere_resource_pool)"
  export VSPHERE_SET_HOST_FOR_DATASTORE_UPLOADS="$(to_bool "$(env_first VSPHERE_SET_HOST_FOR_DATASTORE_UPLOADS vsphere_set_host_for_datastore_uploads)")"
  export COMMON_ISO_DATASTORE="$(env_first COMMON_ISO_DATASTORE common_iso_datastore)"
  export COMMON_ISO_CONTENT_LIBRARY="$(env_first COMMON_ISO_CONTENT_LIBRARY common_iso_content_library)"
  export COMMON_ISO_CONTENT_LIBRARY_ENABLED="$(to_bool "$(env_first COMMON_ISO_CONTENT_LIBRARY_ENABLED common_iso_content_library_enabled)")"
  export COMMON_VM_VERSION="$(env_first COMMON_VM_VERSION common_vm_version)"
  export COMMON_TOOLS_UPGRADE_POLICY="$(to_bool "$(env_first COMMON_TOOLS_UPGRADE_POLICY common_tools_upgrade_policy)")"
  export COMMON_REMOVE_CDROM="$(to_bool "$(env_first COMMON_REMOVE_CDROM common_remove_cdrom)")"
  export COMMON_TEMPLATE_CONVERSION="$(to_bool "$(env_first COMMON_TEMPLATE_CONVERSION common_template_conversion)")"
  export COMMON_CONTENT_LIBRARY="$(env_first COMMON_CONTENT_LIBRARY common_content_library)"
  export COMMON_CONTENT_LIBRARY_ENABLED="$(to_bool "$(env_first COMMON_CONTENT_LIBRARY_ENABLED common_content_library_enabled)")"
  export COMMON_CONTENT_LIBRARY_OVF="$(to_bool "$(env_first COMMON_CONTENT_LIBRARY_OVF common_content_library_ovf)")"
  export COMMON_CONTENT_LIBRARY_DESTROY="$(to_bool "$(env_first COMMON_CONTENT_LIBRARY_DESTROY common_content_library_destroy)")"
  export COMMON_CONTENT_LIBRARY_SKIP_EXPORT="$(to_bool "$(env_first COMMON_CONTENT_LIBRARY_SKIP_EXPORT common_content_library_skip_export)")"
  export COMMON_OVF_EXPORT_ENABLED="$(to_bool "$(env_first COMMON_OVF_EXPORT_ENABLED common_ovf_export_enabled)")"
  export COMMON_OVF_EXPORT_OVERWRITE="$(to_bool "$(env_first COMMON_OVF_EXPORT_OVERWRITE common_ovf_export_overwrite)")"
  export COMMON_DATA_SOURCE="$(env_first COMMON_DATA_SOURCE common_data_source)"
  export COMMON_HTTP_IP="$(env_first COMMON_HTTP_IP common_http_ip)"
  export COMMON_HTTP_PORT_MIN="$(env_first COMMON_HTTP_PORT_MIN common_http_port_min)"
  export COMMON_HTTP_PORT_MAX="$(env_first COMMON_HTTP_PORT_MAX common_http_port_max)"
  export COMMON_IP_WAIT_TIMEOUT="$(env_first COMMON_IP_WAIT_TIMEOUT common_ip_wait_timeout)"
  export COMMON_IP_SETTLE_TIMEOUT="$(env_first COMMON_IP_SETTLE_TIMEOUT common_ip_settle_timeout)"
  export COMMON_SHUTDOWN_TIMEOUT="$(env_first COMMON_SHUTDOWN_TIMEOUT common_shutdown_timeout)"
  export BUILD_USERNAME="$(env_first BUILD_USERNAME build_username)"
  export BUILD_PASSWORD="$(env_first BUILD_PASSWORD build_password)"
  export BUILD_PASSWORD_ENCRYPTED="$(env_first BUILD_PASSWORD_ENCRYPTED build_password_encrypted)"
  export BUILD_KEY="$(env_first BUILD_KEY build_key)"
  export SSH_USER="$(env_first SSH_USER ssh_user)"
  export SSH_PORT="$(env_first SSH_PORT ssh_port)"
  export SSH_PRIVATE_KEY_FILE="$(env_first SSH_PRIVATE_KEY_FILE ssh_private_key_file)"
  export ANSIBLE_USERNAME="$(env_first ANSIBLE_USERNAME ansible_username SSH_USER ssh_user)"
  export ANSIBLE_KEY="$(env_first ANSIBLE_KEY ansible_key)"
  export ANSIBLE_PRIVATE_KEY_FILE="$(env_first ANSIBLE_PRIVATE_KEY_FILE ansible_private_key_file SSH_PRIVATE_KEY_FILE ssh_private_key_file)"
  export ANSIBLE_HOST_KEY_CHECKING="$(env_first ANSIBLE_HOST_KEY_CHECKING ansible_host_key_checking)"
  export COMMUNICATOR_PROXY_HOST="$(env_first COMMUNICATOR_PROXY_HOST communicator_proxy_host)"
  export COMMUNICATOR_PROXY_PORT="$(env_first COMMUNICATOR_PROXY_PORT communicator_proxy_port)"
  export COMMUNICATOR_PROXY_USERNAME="$(env_first COMMUNICATOR_PROXY_USERNAME communicator_proxy_username)"
  export COMMUNICATOR_PROXY_PASSWORD="$(env_first COMMUNICATOR_PROXY_PASSWORD communicator_proxy_password)"
  export TF_TEMPLATE_NAME="$(env_first TF_TEMPLATE_NAME tf_template_name)"
  export TF_VM_NAME="$(env_first TF_VM_NAME tf_vm_name)"
  export TF_VM_CPUS="$(env_first TF_VM_CPUS tf_vm_cpus)"
  export TF_VM_MEMORY_MB="$(env_first TF_VM_MEMORY_MB tf_vm_memory_mb)"
  export TF_VM_DISK_GB="$(env_first TF_VM_DISK_GB tf_vm_disk_gb)"
  export TF_VM_IPV4_ADDRESS="$(env_first TF_VM_IPV4_ADDRESS tf_vm_ipv4_address)"
  export TF_VM_IPV4_PREFIX="$(env_first TF_VM_IPV4_PREFIX tf_vm_ipv4_prefix)"
  export TF_VM_IPV4_GATEWAY="$(env_first TF_VM_IPV4_GATEWAY tf_vm_ipv4_gateway)"
  export TF_VM_DOMAIN="$(env_first TF_VM_DOMAIN tf_vm_domain)"
  export HAPROXY_VIP="$(env_first HAPROXY_VIP haproxy_vip)"
  export HAPROXY_NODE_1_NAME="$(env_first HAPROXY_NODE_1_NAME haproxy_node_1_name)"
  export HAPROXY_NODE_1_IP="$(env_first HAPROXY_NODE_1_IP haproxy_node_1_ip)"
  export HAPROXY_NODE_2_NAME="$(env_first HAPROXY_NODE_2_NAME haproxy_node_2_name)"
  export HAPROXY_NODE_2_IP="$(env_first HAPROXY_NODE_2_IP haproxy_node_2_ip)"
  export TALOS_CLUSTER_NAME="$(env_first TALOS_CLUSTER_NAME talos_cluster_name)"
  export TALOS_CLUSTER_ENDPOINT="$(env_first TALOS_CLUSTER_ENDPOINT talos_cluster_endpoint)"
  export TALOS_TEMPLATE_NAME="$(env_first TALOS_TEMPLATE_NAME talos_template_name)"
  export TALOS_OVA_PATH="$(env_first TALOS_OVA_PATH talos_ova_path)"
  export TALOS_OVF_URL="$(env_first TALOS_OVF_URL talos_ovf_url)"
  export TALOS_CONTROL_PLANE_COUNT="$(env_first TALOS_CONTROL_PLANE_COUNT talos_control_plane_count)"
  export TALOS_WORKER_COUNT="$(env_first TALOS_WORKER_COUNT talos_worker_count)"
  export TALOS_CONTROL_PLANE_CPU="$(env_first TALOS_CONTROL_PLANE_CPU talos_control_plane_cpu)"
  export TALOS_CONTROL_PLANE_MEMORY_MB="$(env_first TALOS_CONTROL_PLANE_MEMORY_MB talos_control_plane_memory_mb)"
  export TALOS_CONTROL_PLANE_DISK_GB="$(env_first TALOS_CONTROL_PLANE_DISK_GB talos_control_plane_disk_gb)"
  export TALOS_WORKER_CPU="$(env_first TALOS_WORKER_CPU talos_worker_cpu)"
  export TALOS_WORKER_MEMORY_MB="$(env_first TALOS_WORKER_MEMORY_MB talos_worker_memory_mb)"
  export TALOS_WORKER_DISK_GB="$(env_first TALOS_WORKER_DISK_GB talos_worker_disk_gb)"
  export TALOS_CONTROL_PLANE_IPS="$(env_first TALOS_CONTROL_PLANE_IPS talos_control_plane_ips)"
  export TALOS_WORKER_IPS="$(env_first TALOS_WORKER_IPS talos_worker_ips)"
  export TALOS_GATEWAY="$(env_first TALOS_GATEWAY talos_gateway)"
  export TALOS_NETMASK_PREFIX="$(env_first TALOS_NETMASK_PREFIX talos_netmask_prefix)"
  export TALOS_NAMESERVERS="$(env_first TALOS_NAMESERVERS talos_nameservers)"
  export TALOS_DOMAIN="$(env_first TALOS_DOMAIN talos_domain)"
  export TALOS_CONTROL_PLANE_CONFIG_PATH="$(env_first TALOS_CONTROL_PLANE_CONFIG_PATH talos_control_plane_config_path)"
  export TALOS_WORKER_CONFIG_PATH="$(env_first TALOS_WORKER_CONFIG_PATH talos_worker_config_path)"
}

load_overlay_vars() {
  local env_name="${1:?Environment name is required}"
  local repo_root
  local base_vars
  local env_vars
  local local_vars
  local explicit_vars_file
  local explicit_local_vars_file

  repo_root="$(overlay_repo_root)"
  if [[ -f "${repo_root}/scripts/talos/vars.sh" ]]; then
    base_vars="${repo_root}/scripts/talos/vars.sh"
  else
    base_vars="${repo_root}/overlays/base/scripts/vars.sh"
  fi
  env_vars="${repo_root}/overlays/${env_name}/scripts/vars.sh"
  local_vars="${repo_root}/overlays/${env_name}/scripts/vars.local.sh"
  explicit_vars_file="${OVERLAY_VARS_FILE:-}"
  explicit_local_vars_file="${OVERLAY_LOCAL_VARS_FILE:-}"

  require_file "${base_vars}"
  # shellcheck disable=SC1090
  source "${base_vars}"

  if [[ -n "${explicit_vars_file}" ]]; then
    if [[ "${explicit_vars_file}" != /* ]]; then
      explicit_vars_file="${repo_root}/${explicit_vars_file}"
    fi
    require_file "${explicit_vars_file}"
    log_info "Loading explicit overlay vars from ${explicit_vars_file}"
    # shellcheck disable=SC1090
    source "${explicit_vars_file}"
  else
    if [[ -f "${env_vars}" ]]; then
      # shellcheck disable=SC1090
      source "${env_vars}"
    else
      log_warn "No overlay vars file found for environment '${env_name}' at ${env_vars}"
    fi
  fi

  if [[ -n "${explicit_local_vars_file}" ]]; then
    if [[ "${explicit_local_vars_file}" != /* ]]; then
      explicit_local_vars_file="${repo_root}/${explicit_local_vars_file}"
    fi
    if [[ -f "${explicit_local_vars_file}" ]]; then
      log_info "Loading explicit local overlay overrides from ${explicit_local_vars_file}"
      # shellcheck disable=SC1090
      source "${explicit_local_vars_file}"
    fi
  else
    if [[ -f "${local_vars}" ]]; then
      log_info "Loading local overlay overrides from ${local_vars}"
      # shellcheck disable=SC1090
      source "${local_vars}"
    fi
  fi

  load_legacy_env_file "${repo_root}"
  normalize_global_env
}

export_common_tool_env() {
  export GOVC_URL="https://${VSPHERE_ENDPOINT}"
  export GOVC_USERNAME="${VSPHERE_USERNAME}"
  export GOVC_PASSWORD="${VSPHERE_PASSWORD}"
  export GOVC_INSECURE="${VSPHERE_INSECURE_CONNECTION}"
  export GOVC_DATASTORE="${VSPHERE_DATASTORE}"
  export GOVC_NETWORK="${VSPHERE_NETWORK}"
  export GOVC_FOLDER="${VSPHERE_FOLDER}"
  export GOVC_DATACENTER="${VSPHERE_DATACENTER}"
}

export_packer_vars() {
  export PKR_VAR_vsphere_endpoint="${VSPHERE_ENDPOINT}"
  export PKR_VAR_vsphere_username="${VSPHERE_USERNAME}"
  export PKR_VAR_vsphere_password="${VSPHERE_PASSWORD}"
  export PKR_VAR_vsphere_insecure_connection="${VSPHERE_INSECURE_CONNECTION}"
  export PKR_VAR_vsphere_datacenter="${VSPHERE_DATACENTER}"
  export PKR_VAR_vsphere_cluster="${VSPHERE_CLUSTER}"
  export PKR_VAR_vsphere_host="${VSPHERE_HOST}"
  export PKR_VAR_vsphere_datastore="${VSPHERE_DATASTORE}"
  export PKR_VAR_vsphere_network="${VSPHERE_NETWORK}"
  export PKR_VAR_vsphere_folder="${VSPHERE_FOLDER}"
  export PKR_VAR_vsphere_resource_pool="${VSPHERE_RESOURCE_POOL}"
  export PKR_VAR_vsphere_set_host_for_datastore_uploads="${VSPHERE_SET_HOST_FOR_DATASTORE_UPLOADS}"
  export PKR_VAR_common_iso_datastore="${COMMON_ISO_DATASTORE}"
  export PKR_VAR_common_iso_content_library="${COMMON_ISO_CONTENT_LIBRARY}"
  export PKR_VAR_common_iso_content_library_enabled="${COMMON_ISO_CONTENT_LIBRARY_ENABLED}"
  export PKR_VAR_common_vm_version="${COMMON_VM_VERSION:-15}"
  export PKR_VAR_common_tools_upgrade_policy="${COMMON_TOOLS_UPGRADE_POLICY:-true}"
  export PKR_VAR_common_remove_cdrom="${COMMON_REMOVE_CDROM:-true}"
  export PKR_VAR_common_template_conversion="${COMMON_TEMPLATE_CONVERSION:-false}"
  export PKR_VAR_common_content_library="${COMMON_CONTENT_LIBRARY}"
  export PKR_VAR_common_content_library_enabled="${COMMON_CONTENT_LIBRARY_ENABLED:-false}"
  export PKR_VAR_common_content_library_ovf="${COMMON_CONTENT_LIBRARY_OVF:-true}"
  export PKR_VAR_common_content_library_destroy="${COMMON_CONTENT_LIBRARY_DESTROY:-true}"
  export PKR_VAR_common_content_library_skip_export="${COMMON_CONTENT_LIBRARY_SKIP_EXPORT:-false}"
  export PKR_VAR_common_ovf_export_enabled="${COMMON_OVF_EXPORT_ENABLED:-false}"
  export PKR_VAR_common_ovf_export_overwrite="${COMMON_OVF_EXPORT_OVERWRITE:-true}"
  export PKR_VAR_common_data_source="${COMMON_DATA_SOURCE:-disk}"
  export PKR_VAR_common_http_ip="${COMMON_HTTP_IP}"
  export PKR_VAR_common_http_port_min="${COMMON_HTTP_PORT_MIN:-8000}"
  export PKR_VAR_common_http_port_max="${COMMON_HTTP_PORT_MAX:-8099}"
  export PKR_VAR_common_ip_wait_timeout="${COMMON_IP_WAIT_TIMEOUT:-20m}"
  export PKR_VAR_common_ip_settle_timeout="${COMMON_IP_SETTLE_TIMEOUT:-5s}"
  export PKR_VAR_common_shutdown_timeout="${COMMON_SHUTDOWN_TIMEOUT:-15m}"
  export PKR_VAR_build_username="${BUILD_USERNAME}"
  export PKR_VAR_build_password="${BUILD_PASSWORD}"
  export PKR_VAR_build_password_encrypted="${BUILD_PASSWORD_ENCRYPTED}"
  export PKR_VAR_build_key="${BUILD_KEY}"
  export PKR_VAR_ansible_username="${ANSIBLE_USERNAME}"
  export PKR_VAR_ansible_key="${ANSIBLE_KEY}"
  export PKR_VAR_communicator_proxy_host="${COMMUNICATOR_PROXY_HOST}"
  export PKR_VAR_communicator_proxy_port="${COMMUNICATOR_PROXY_PORT}"
  export PKR_VAR_communicator_proxy_username="${COMMUNICATOR_PROXY_USERNAME}"
  export PKR_VAR_communicator_proxy_password="${COMMUNICATOR_PROXY_PASSWORD}"
}

export_haproxy_terraform_vars() {
  export TF_VAR_vsphere_server="${VSPHERE_ENDPOINT}"
  export TF_VAR_vsphere_user="${VSPHERE_USERNAME}"
  export TF_VAR_vsphere_password="${VSPHERE_PASSWORD}"
  export TF_VAR_vsphere_allow_unverified_ssl="${VSPHERE_INSECURE_CONNECTION}"
  export TF_VAR_datacenter="${VSPHERE_DATACENTER}"
  export TF_VAR_cluster="${VSPHERE_CLUSTER}"
  export TF_VAR_host="${VSPHERE_HOST}"
  export TF_VAR_resource_pool="${VSPHERE_RESOURCE_POOL}"
  export TF_VAR_datastore="${VSPHERE_DATASTORE}"
  export TF_VAR_network="${VSPHERE_NETWORK}"
  export TF_VAR_folder="${VSPHERE_FOLDER}"
  export TF_VAR_template_name="${TF_TEMPLATE_NAME}"
  export TF_VAR_vm_name="${TF_VM_NAME:-haproxy-lb-01}"
  export TF_VAR_vm_cpus="${TF_VM_CPUS:-2}"
  export TF_VAR_vm_memory_mb="${TF_VM_MEMORY_MB:-4096}"
  export TF_VAR_vm_disk_gb="${TF_VM_DISK_GB:-40}"
  export TF_VAR_vm_ipv4_address="${TF_VM_IPV4_ADDRESS}"
  export TF_VAR_vm_ipv4_prefix="${TF_VM_IPV4_PREFIX:-24}"
  export TF_VAR_vm_ipv4_gateway="${TF_VM_IPV4_GATEWAY}"
  export TF_VAR_vm_domain="${TF_VM_DOMAIN:-infra.local}"
}

export_talos_terraform_vars() {
  export TF_VAR_vsphere_server="${VSPHERE_ENDPOINT}"
  export TF_VAR_vsphere_user="${VSPHERE_USERNAME}"
  export TF_VAR_vsphere_password="${VSPHERE_PASSWORD}"
  export TF_VAR_vsphere_allow_unverified_ssl="${VSPHERE_INSECURE_CONNECTION}"
  export TF_VAR_datacenter="${VSPHERE_DATACENTER}"
  export TF_VAR_cluster="${VSPHERE_CLUSTER}"
  export TF_VAR_host="${VSPHERE_HOST}"
  export TF_VAR_resource_pool="${VSPHERE_RESOURCE_POOL}"
  export TF_VAR_datastore="${VSPHERE_DATASTORE}"
  export TF_VAR_network="${VSPHERE_NETWORK}"
  export TF_VAR_folder="${VSPHERE_FOLDER}"
  export TF_VAR_cluster_name="${TALOS_CLUSTER_NAME:-talos-prod}"
  export TF_VAR_cluster_endpoint="${TALOS_CLUSTER_ENDPOINT:-${HAPROXY_VIP}}"
  export TF_VAR_talos_template_name="${TALOS_TEMPLATE_NAME}"
  export TF_VAR_talos_ovf_url="${TALOS_OVF_URL}"
  export TF_VAR_control_plane_count="${TALOS_CONTROL_PLANE_COUNT:-3}"
  export TF_VAR_worker_count="${TALOS_WORKER_COUNT:-2}"
  export TF_VAR_control_plane_cpu="${TALOS_CONTROL_PLANE_CPU:-2}"
  export TF_VAR_control_plane_memory_mb="${TALOS_CONTROL_PLANE_MEMORY_MB:-4096}"
  export TF_VAR_control_plane_disk_gb="${TALOS_CONTROL_PLANE_DISK_GB:-20}"
  export TF_VAR_worker_cpu="${TALOS_WORKER_CPU:-2}"
  export TF_VAR_worker_memory_mb="${TALOS_WORKER_MEMORY_MB:-4096}"
  export TF_VAR_worker_disk_gb="${TALOS_WORKER_DISK_GB:-40}"
  export TF_VAR_control_plane_ips="${TALOS_CONTROL_PLANE_IPS}"
  export TF_VAR_worker_ips="${TALOS_WORKER_IPS}"
  export TF_VAR_talos_gateway="${TALOS_GATEWAY}"
  export TF_VAR_talos_netmask_prefix="${TALOS_NETMASK_PREFIX:-24}"
  export TF_VAR_talos_nameservers="${TALOS_NAMESERVERS}"
  export TF_VAR_talos_domain="${TALOS_DOMAIN:-infra.local}"
  export TF_VAR_control_plane_config_path="${TALOS_CONTROL_PLANE_CONFIG_PATH}"
  export TF_VAR_worker_config_path="${TALOS_WORKER_CONFIG_PATH}"
}

export_ansible_vars() {
  export ANSIBLE_USER="${ANSIBLE_USERNAME:-${ANSIBLE_USER:-}}"
  export ANSIBLE_PRIVATE_KEY_FILE="${ANSIBLE_PRIVATE_KEY_FILE:-${ANSIBLE_PRIVATE_KEY_FILE:-}}"
  export ANSIBLE_HOST_KEY_CHECKING="${ANSIBLE_HOST_KEY_CHECKING:-False}"
}
