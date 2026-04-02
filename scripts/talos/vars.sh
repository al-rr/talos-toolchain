#!/usr/bin/env bash
# @file vars.sh
# @description Default variables for all environments.
#              Environment overlays must source this file first and then
#              override only the values that change.

export OVERLAY_ENV="${OVERLAY_ENV:-}"
export OVERLAY_ALLOW_LEGACY_ENV="${OVERLAY_ALLOW_LEGACY_ENV:-false}"

# Repository paths
export BASE_PACKER_DIR="overlays/base/packer"
export BASE_HAPROXY_TERRAFORM_DIR="overlays/base/terraform/talos-lb-lb"
export BASE_TALOS_TERRAFORM_DIR="overlays/base/terraform/talos"
export BASE_HAPROXY_ANSIBLE_DIR="overlays/base/ansible/haproxy"
export BASE_GOVC_DIR="overlays/base/govc"

# vSphere Settings
export VSPHERE_DATACENTER=""
export VSPHERE_CLUSTER=""
export VSPHERE_HOST=""
export VSPHERE_DATASTORE=""
export VSPHERE_NETWORK=""
export VSPHERE_FOLDER=""
export VSPHERE_RESOURCE_POOL=""
export VSPHERE_SET_HOST_FOR_DATASTORE_UPLOADS="false"
export VSPHERE_API_TIMEOUT="10"
export VSPHERE_ENDPOINT=""
export VSPHERE_USERNAME=""
export VSPHERE_PASSWORD=""
export VSPHERE_INSECURE_CONNECTION="true"

# Build account (image creation/bootstrap account on guest OS)
export BUILD_USERNAME=""
export BUILD_PASSWORD=""
export BUILD_PASSWORD_ENCRYPTED=""
export BUILD_KEY=""

# Generic SSH access identity for remote operations
export SSH_USER=""
export SSH_PORT="22"
export SSH_PRIVATE_KEY_FILE=""

# Ansible access identity (remote automation user + authorized key)
# Keep independent from BUILD_* because roles are different:
# - BUILD_*: user created during image build/bootstrap
# - ANSIBLE_*: user/key used later for remote configuration
# Default behavior: inherit from SSH_* unless explicitly overridden.
export ANSIBLE_USERNAME="${ANSIBLE_USERNAME:-${SSH_USER:-}}"
export ANSIBLE_KEY=""
export ANSIBLE_PRIVATE_KEY_FILE="${ANSIBLE_PRIVATE_KEY_FILE:-${SSH_PRIVATE_KEY_FILE:-}}"
export ANSIBLE_HOST_KEY_CHECKING="False"

# Shared Packer settings
export COMMON_ISO_DATASTORE=""
export COMMON_ISO_CONTENT_LIBRARY=""
export COMMON_ISO_CONTENT_LIBRARY_ENABLED="false"
export COMMON_VM_VERSION="15"
export COMMON_TOOLS_UPGRADE_POLICY="true"
export COMMON_REMOVE_CDROM="true"
export COMMON_TEMPLATE_CONVERSION="false"
export COMMON_CONTENT_LIBRARY=""
export COMMON_CONTENT_LIBRARY_ENABLED="false"
export COMMON_CONTENT_LIBRARY_OVF="true"
export COMMON_CONTENT_LIBRARY_DESTROY="true"
export COMMON_CONTENT_LIBRARY_SKIP_EXPORT="false"
export COMMON_OVF_EXPORT_ENABLED="false"
export COMMON_OVF_EXPORT_OVERWRITE="true"
export COMMON_DATA_SOURCE="disk"
export COMMON_HTTP_IP=""
export COMMON_HTTP_PORT_MIN="8000"
export COMMON_HTTP_PORT_MAX="8099"
export COMMON_IP_WAIT_TIMEOUT="20m"
export COMMON_IP_SETTLE_TIMEOUT="5s"
export COMMON_SHUTDOWN_TIMEOUT="15m"

# Proxy
export COMMUNICATOR_PROXY_HOST=""
export COMMUNICATOR_PROXY_PORT=""
export COMMUNICATOR_PROXY_USERNAME=""
export COMMUNICATOR_PROXY_PASSWORD=""

# GOVC lifecycle variables (generic VM provisioning)
GOVC_SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/govc"
if [[ -d "${GOVC_SCRIPT_DIR}" && -f "${GOVC_SCRIPT_DIR}/vars.sh" ]]; then
  # shellcheck disable=SC1090
  source "${GOVC_SCRIPT_DIR}/vars.sh"
fi
unset GOVC_SCRIPT_DIR

# HAProxy topology and automation
export HAPROXY_VIP=""
export HAPROXY_NODE_1_NAME="talos-lb-1"
export HAPROXY_NODE_1_IP=""
export HAPROXY_NODE_2_NAME="talos-lb-2"
export HAPROXY_NODE_2_IP=""
export TALOS_LOAD_BALANCER_RECONCILE_SCRIPT=""
export HAPROXY_PACKER_TEMPLATE_PATH="${BASE_PACKER_DIR}"
export HAPROXY_PACKER_OVERRIDE_FILE=""
export HAPROXY_ANSIBLE_INVENTORY="${BASE_HAPROXY_ANSIBLE_DIR}/inventory"
export HAPROXY_ANSIBLE_PLAYBOOK="${BASE_HAPROXY_ANSIBLE_DIR}/playbooks/provision_haproxy.yml"
export HAPROXY_TERRAFORM_DIR="${BASE_HAPROXY_TERRAFORM_DIR}"

# Additional HAProxy lifecycle variables (install/setup/hardening)
HAPROXY_SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/ha-proxy"
if [[ -d "${HAPROXY_SCRIPT_DIR}" && -f "${HAPROXY_SCRIPT_DIR}/vars.sh" ]]; then
  # shellcheck disable=SC1090
  source "${HAPROXY_SCRIPT_DIR}/vars.sh"
fi
unset HAPROXY_SCRIPT_DIR

# DNS lifecycle defaults (VM provisioning + dnsmasq settings)
DNS_SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/dns"
if [[ -d "${DNS_SCRIPT_DIR}" && -f "${DNS_SCRIPT_DIR}/vars.sh" ]]; then
  # shellcheck disable=SC1090
  source "${DNS_SCRIPT_DIR}/vars.sh"
fi
unset DNS_SCRIPT_DIR

# Keepalived lifecycle defaults (module migrated to infra-gitops/scripts/keepalived)
export KEEPALIVED_SERVICE_NAME="keepalived"
export KEEPALIVED_CONFIG_PATH="/etc/keepalived/keepalived.conf"
export KEEPALIVED_INTERFACE="auto"
export KEEPALIVED_ROUTER_ID="51"
export KEEPALIVED_STATE="BACKUP"
export KEEPALIVED_PRIORITY="100"
export KEEPALIVED_ADVERT_INT="1"
export KEEPALIVED_AUTH_TYPE="PASS"
export KEEPALIVED_AUTH_PASS="vrrp1234"
export KEEPALIVED_VIPS="172.17.20.90/24"
export KEEPALIVED_UNICAST_SRC_IP=""
export KEEPALIVED_UNICAST_PEERS="172.17.20.181,172.17.20.182"
export KEEPALIVED_TRACK_HAPROXY="true"
export KEEPALIVED_TRACK_SCRIPT_NAME="chk_haproxy"
export KEEPALIVED_TRACK_SCRIPT_COMMAND="systemctl is-active --quiet haproxy"
export KEEPALIVED_TRACK_SCRIPT_INTERVAL="2"
export KEEPALIVED_TRACK_SCRIPT_WEIGHT="-20"

# Talos lifecycle variables (talosctl install/provision wrappers)
TALOS_SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/talos"
if [[ -d "${TALOS_SCRIPT_DIR}" && -f "${TALOS_SCRIPT_DIR}/vars.sh" ]]; then
  # shellcheck disable=SC1090
  source "${TALOS_SCRIPT_DIR}/vars.sh"
fi
unset TALOS_SCRIPT_DIR

# HAProxy VM convenience values
export TF_TEMPLATE_NAME=""
export TF_VM_NAME="talos-lb-lb-01"
export TF_VM_CPUS="2"
export TF_VM_MEMORY_MB="4096"
export TF_VM_DISK_GB="40"
export TF_VM_IPV4_ADDRESS=""
export TF_VM_IPV4_PREFIX="24"
export TF_VM_IPV4_GATEWAY=""
export TF_VM_DOMAIN="infra.local"

# Talos topology and automation
export TALOS_TERRAFORM_DIR="${BASE_TALOS_TERRAFORM_DIR}"
export TALOS_CLUSTER_NAME="talos-prod"
export TALOS_CLUSTER_ENDPOINT=""
export TALOS_TEMPLATE_NAME=""
export TALOS_OVA_PATH=""
export TALOS_OVF_URL=""
export TALOS_CONTROL_PLANE_INSTALLER_IMAGE=""
export TALOS_WORKER_INSTALLER_IMAGE=""
export TALOS_ISO_DATASTORE_PATH="ISOs/talos-v1.12.4-uefi.iso"
export TALOS_CONTROL_PLANE_COUNT="3"
export TALOS_WORKER_COUNT="2"
export TALOS_CONTROL_PLANE_CPU="2"
export TALOS_CONTROL_PLANE_MEMORY_MB="4096"
export TALOS_CONTROL_PLANE_DISK_GB="20"
export TALOS_CONTROL_PLANE_EXTRA_DISK_GB="0"
export TALOS_WORKER_CPU="2"
export TALOS_WORKER_MEMORY_MB="4096"
export TALOS_WORKER_DISK_GB="40"
export TALOS_WORKER_EXTRA_DISK_GB="0"
export TALOS_CONTROL_PLANE_IPS=""
export TALOS_WORKER_IPS=""
export TALOS_DISABLE_DEFAULT_CNI="false"
export TALOS_NODE_INTERFACE="eth0"
export TALOS_CONTROL_PLANE_VIP_ENABLED="true"
export TALOS_CONTROL_PLANE_VIP="${HAPROXY_VIP:-}"
export TALOS_GATEWAY=""
export TALOS_NETMASK_PREFIX="24"
export TALOS_NAMESERVERS=""
export TALOS_CLUSTER_BASELINE_ADDONS='["cilium"]'
export TALOS_BASELINE_ADDONS="${TALOS_CLUSTER_BASELINE_ADDONS}"
export TALOS_DOMAIN="infra.local"
export TALOS_DNS_SYNC_REQUIRED="false"
export TALOS_DNS_REGISTER_SCRIPT=""
export TALOS_DNS_UNREGISTER_SCRIPT=""
export TALOS_CONTROL_PLANE_CONFIG_PATH=""
export TALOS_WORKER_CONFIG_PATH=""
export TALOS_SINGLE_NODE_VM_NAME="talos-single-node-01"
export TALOS_SINGLE_NODE_CPU="${TALOS_CONTROL_PLANE_CPU}"
export TALOS_SINGLE_NODE_MEMORY_MB="${TALOS_CONTROL_PLANE_MEMORY_MB}"
export TALOS_SINGLE_NODE_DISK_GB="${TALOS_CONTROL_PLANE_DISK_GB}"
export TALOS_SINGLE_NODE_CONFIG_PATH="${TALOS_CONTROL_PLANE_CONFIG_PATH}"
# Legacy compatibility aliases:
export TALOS_SIMPLE_VM_NAME="${TALOS_SIMPLE_VM_NAME:-${TALOS_SINGLE_NODE_VM_NAME}}"
export TALOS_SIMPLE_CPU="${TALOS_SIMPLE_CPU:-${TALOS_SINGLE_NODE_CPU}}"
export TALOS_SIMPLE_MEMORY_MB="${TALOS_SIMPLE_MEMORY_MB:-${TALOS_SINGLE_NODE_MEMORY_MB}}"
export TALOS_SIMPLE_DISK_GB="${TALOS_SIMPLE_DISK_GB:-${TALOS_SINGLE_NODE_DISK_GB}}"
export TALOS_SIMPLE_CONFIG_PATH="${TALOS_SIMPLE_CONFIG_PATH:-${TALOS_SINGLE_NODE_CONFIG_PATH}}"

# Optional local ISO path for upload automation
export ISO_LOCAL_PATH=""
