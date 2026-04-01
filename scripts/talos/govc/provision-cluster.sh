#!/usr/bin/env bash
set -euo pipefail

# @file provision-cluster.sh
# @brief Provision Talos control-plane/worker VMs on vSphere/ESXi using govc.
# @description
#   Creates or destroys Talos nodes from overlay variables, injects machine configs
#   via guestinfo, and either imports a Talos OVA or mounts a Talos ISO for initial boot/install.
#
# @arg action string Required action: create, destroy, or plan.
# @arg --env,-e string Overlay environment (default: lab).
# @arg --cluster-name string Talos cluster name prefix.
# @arg --cp-count int Control-plane VM count.
# @arg --worker-count int Worker VM count.
# @arg --cp-cpu int Control-plane vCPUs.
# @arg --cp-memory-mb int Control-plane memory (MiB).
# @arg --cp-disk-gb int Control-plane disk size (GiB).
# @arg --cp-extra-disk-gb int Control-plane extra data disk size (GiB, optional).
# @arg --worker-cpu int Worker vCPUs.
# @arg --worker-memory-mb int Worker memory (MiB).
# @arg --worker-disk-gb int Worker disk size (GiB).
# @arg --worker-extra-disk-gb int Worker extra data disk size (GiB, optional).
# @arg --cp-config string Control-plane machine config file.
# @arg --worker-config string Worker machine config file.
# @arg --iso-path string Datastore-relative Talos ISO path.
# @arg --ova-path string Local path or URL to Talos OVA.
# @arg --network string VM network/portgroup name.
# @arg --datastore string Datastore name.
# @arg --folder string Optional VM folder.
# @arg --resource-pool string Optional resource pool.
# @flag --overwrite Recreate VM if it already exists.
# @flag --power-on Power on after create (default true).
# @flag --no-power-on Do not power on after create.
# @flag --help,-h Show usage.

ENV_NAME="lab"
ACTION=""
CLUSTER_NAME=""
CP_COUNT=""
WORKER_COUNT=""
CP_CPU=""
CP_MEMORY_MB=""
CP_DISK_GB=""
CP_EXTRA_DISK_GB=""
WORKER_CPU=""
WORKER_MEMORY_MB=""
WORKER_DISK_GB=""
WORKER_EXTRA_DISK_GB=""
CP_CONFIG_PATH=""
WORKER_CONFIG_PATH=""
ISO_DATASTORE_PATH=""
OVA_PATH=""
VM_NETWORK=""
VM_DATASTORE=""
VM_FOLDER=""
VM_RESOURCE_POOL=""
VM_OVERWRITE=""
VM_POWER_ON=""
WAIT_BOOTSTRAP_IPS=""
WAIT_BOOTSTRAP_TIMEOUT=""
WAIT_TALOS_API=""
WAIT_TALOS_API_TIMEOUT=""
VM_FIRMWARE="efi"
VM_GUEST_OS_TYPE="other3xLinux64Guest"
VM_NET_ADAPTER="vmxnet3"
VM_DISK_CONTROLLER="scsi"
ISO_LOCAL_FILE=""
CP_NAME_PREFIX=""
WORKER_NAME_PREFIX=""
CP_IPS_RAW=""
WORKER_IPS_RAW=""
declare -a CP_STATIC_IPS=()
declare -a WORKER_STATIC_IPS=()
declare -a ALL_PATCH_FILES=()
declare -a CP_PATCH_FILES=()
declare -a WORKER_PATCH_FILES=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DNS_REGISTER_SCRIPT="${TALOS_DNS_REGISTER_SCRIPT:-}"
DNS_UNREGISTER_SCRIPT="${TALOS_DNS_UNREGISTER_SCRIPT:-}"
DNS_OWNER_ID="talos"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/talos/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <create|destroy|plan>

Options:
  -e, --env=<env>                Overlay environment (default: lab)
      --cluster-name=<name>      Cluster name (default: TALOS_CLUSTER_NAME)
      --cp-count=<n>             Control-plane count (default: TALOS_CONTROL_PLANE_COUNT)
      --worker-count=<n>         Worker count (default: TALOS_WORKER_COUNT)
      --cp-cpu=<n>               Control-plane vCPU count
      --cp-memory-mb=<n>         Control-plane memory MiB
      --cp-disk-gb=<n>           Control-plane disk GiB
      --cp-extra-disk-gb=<n>     Control-plane extra data disk GiB (optional)
      --worker-cpu=<n>           Worker vCPU count
      --worker-memory-mb=<n>     Worker memory MiB
      --worker-disk-gb=<n>       Worker disk GiB
      --worker-extra-disk-gb=<n> Worker extra data disk GiB (optional)
      --cp-config=<path>         Control-plane machine config file
      --worker-config=<path>     Worker machine config file
      --iso-path=<path>          Datastore-relative Talos ISO path
      --ova-path=<path|url>      Talos OVA path/URL (preferred in ESXi lab)
      --network=<name>           VM network/portgroup
      --datastore=<name>         Datastore
      --folder=<path>            VM folder
      --resource-pool=<path>     Resource pool
      --overwrite                Recreate VM if it exists
      --power-on                 Power on after create (default)
      --no-power-on              Do not power on after create
      --wait-bootstrap-ips       Wait for bootstrap DHCP IPs after create (default)
      --no-wait-bootstrap-ips    Skip waiting for bootstrap DHCP IPs
      --wait-bootstrap-timeout=<sec> Timeout waiting for bootstrap DHCP IPs (default: 600)
      --wait-talos-api           Wait until Talos API (:50000) is reachable on all nodes (default)
      --no-wait-talos-api        Skip Talos API readiness check
      --wait-talos-api-timeout=<sec> Timeout waiting Talos API readiness (default: 300)
      --all-patch=<path>         Machineconfig patch for all nodes (repeatable)
      --cp-patch=<path>          Machineconfig patch for control-plane nodes (repeatable)
      --worker-patch=<path>      Machineconfig patch for worker nodes (repeatable)
  -h, --help                     Show this help
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
      --cluster-name=*) CLUSTER_NAME="${1#*=}"; shift ;;
      --cp-count=*) CP_COUNT="${1#*=}"; shift ;;
      --worker-count=*) WORKER_COUNT="${1#*=}"; shift ;;
      --cp-cpu=*) CP_CPU="${1#*=}"; shift ;;
      --cp-memory-mb=*) CP_MEMORY_MB="${1#*=}"; shift ;;
      --cp-disk-gb=*) CP_DISK_GB="${1#*=}"; shift ;;
      --cp-extra-disk-gb=*) CP_EXTRA_DISK_GB="${1#*=}"; shift ;;
      --worker-cpu=*) WORKER_CPU="${1#*=}"; shift ;;
      --worker-memory-mb=*) WORKER_MEMORY_MB="${1#*=}"; shift ;;
      --worker-disk-gb=*) WORKER_DISK_GB="${1#*=}"; shift ;;
      --worker-extra-disk-gb=*) WORKER_EXTRA_DISK_GB="${1#*=}"; shift ;;
      --cp-config=*) CP_CONFIG_PATH="${1#*=}"; shift ;;
      --worker-config=*) WORKER_CONFIG_PATH="${1#*=}"; shift ;;
      --iso-path=*) ISO_DATASTORE_PATH="${1#*=}"; shift ;;
      --ova-path=*) OVA_PATH="${1#*=}"; shift ;;
      --network=*) VM_NETWORK="${1#*=}"; shift ;;
      --datastore=*) VM_DATASTORE="${1#*=}"; shift ;;
      --folder=*) VM_FOLDER="${1#*=}"; shift ;;
      --resource-pool=*) VM_RESOURCE_POOL="${1#*=}"; shift ;;
      --overwrite) VM_OVERWRITE="true"; shift ;;
      --power-on) VM_POWER_ON="true"; shift ;;
      --no-power-on) VM_POWER_ON="false"; shift ;;
      --wait-bootstrap-ips) WAIT_BOOTSTRAP_IPS="true"; shift ;;
      --no-wait-bootstrap-ips) WAIT_BOOTSTRAP_IPS="false"; shift ;;
      --wait-bootstrap-timeout=*) WAIT_BOOTSTRAP_TIMEOUT="${1#*=}"; shift ;;
      --wait-talos-api) WAIT_TALOS_API="true"; shift ;;
      --no-wait-talos-api) WAIT_TALOS_API="false"; shift ;;
      --wait-talos-api-timeout=*) WAIT_TALOS_API_TIMEOUT="${1#*=}"; shift ;;
      --all-patch=*) ALL_PATCH_FILES+=("${1#*=}"); shift ;;
      --cp-patch=*) CP_PATCH_FILES+=("${1#*=}"); shift ;;
      --worker-patch=*) WORKER_PATCH_FILES+=("${1#*=}"); shift ;;
      create|destroy|plan) ACTION="$1"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done
}

resolve_path_from_repo() {
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
  local IFS=','
  read -r -a _arr <<<"${csv}"
  printf '%s\n' "${_arr[@]}"
}

is_ipv4() {
  local ip="$1"
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<<"${ip}"
  (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 ))
}

extract_vm_ipv4() {
  local vm_name="$1"
  local ip=""
  ip="$(timeout 3 govc vm.ip -wait 1s "${vm_name}" 2>/dev/null \
    | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print; exit}' || true)"
  if [[ -n "${ip}" ]] && is_ipv4 "${ip}"; then
    printf '%s\n' "${ip}"
    return 0
  fi
  ip="$(govc vm.info "${vm_name}" \
    | awk -F': ' '/IP address:/ {print $2}' \
    | tr ' ' '\n' \
    | tr ',' '\n' \
    | awk 'NF' \
    | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print; exit}')"
  printf '%s\n' "${ip}"
}

resolve_patch_files() {
  local i
  for i in "${!ALL_PATCH_FILES[@]}"; do
    ALL_PATCH_FILES[$i]="$(resolve_path_from_repo "${ALL_PATCH_FILES[$i]}")"
  done
  for i in "${!CP_PATCH_FILES[@]}"; do
    CP_PATCH_FILES[$i]="$(resolve_path_from_repo "${CP_PATCH_FILES[$i]}")"
  done
  for i in "${!WORKER_PATCH_FILES[@]}"; do
    WORKER_PATCH_FILES[$i]="$(resolve_path_from_repo "${WORKER_PATCH_FILES[$i]}")"
  done
}

load_context() {
  load_overlay_vars "${ENV_NAME}"
  export_common_tool_env

  CLUSTER_NAME="${CLUSTER_NAME:-${TALOS_CLUSTER_NAME:-talos}}"
  CP_COUNT="${CP_COUNT:-${TALOS_CONTROL_PLANE_COUNT:-3}}"
  WORKER_COUNT="${WORKER_COUNT:-${TALOS_WORKER_COUNT:-2}}"
  CP_CPU="${CP_CPU:-${TALOS_CONTROL_PLANE_CPU:-2}}"
  CP_MEMORY_MB="${CP_MEMORY_MB:-${TALOS_CONTROL_PLANE_MEMORY_MB:-4096}}"
  CP_DISK_GB="${CP_DISK_GB:-${TALOS_CONTROL_PLANE_DISK_GB:-20}}"
  CP_EXTRA_DISK_GB="${CP_EXTRA_DISK_GB:-${TALOS_CONTROL_PLANE_EXTRA_DISK_GB:-0}}"
  WORKER_CPU="${WORKER_CPU:-${TALOS_WORKER_CPU:-2}}"
  WORKER_MEMORY_MB="${WORKER_MEMORY_MB:-${TALOS_WORKER_MEMORY_MB:-4096}}"
  WORKER_DISK_GB="${WORKER_DISK_GB:-${TALOS_WORKER_DISK_GB:-40}}"
  WORKER_EXTRA_DISK_GB="${WORKER_EXTRA_DISK_GB:-${TALOS_WORKER_EXTRA_DISK_GB:-0}}"
  CP_CONFIG_PATH="${CP_CONFIG_PATH:-${TALOS_CONTROL_PLANE_CONFIG_PATH:-}}"
  WORKER_CONFIG_PATH="${WORKER_CONFIG_PATH:-${TALOS_WORKER_CONFIG_PATH:-}}"
  ISO_DATASTORE_PATH="${ISO_DATASTORE_PATH:-${TALOS_ISO_DATASTORE_PATH:-ISOs/talos-v1.12.4-uefi.iso}}"
  OVA_PATH="${OVA_PATH:-${TALOS_OVA_PATH:-}}"
  ISO_LOCAL_FILE="${ISO_LOCAL_FILE:-${TALOS_ISO_LOCAL_PATH:-${ISO_LOCAL_PATH:-}}}"
  VM_NETWORK="${VM_NETWORK:-${GOVC_NETWORK:-${VSPHERE_NETWORK:-}}}"
  VM_DATASTORE="${VM_DATASTORE:-${GOVC_DATASTORE:-${VSPHERE_DATASTORE:-}}}"
  VM_FOLDER="${VM_FOLDER:-${GOVC_FOLDER:-${VSPHERE_FOLDER:-}}}"
  VM_RESOURCE_POOL="${VM_RESOURCE_POOL:-${VSPHERE_RESOURCE_POOL:-}}"
  VM_OVERWRITE="${VM_OVERWRITE:-${GOVC_VM_OVERWRITE:-false}}"
  VM_POWER_ON="${VM_POWER_ON:-${GOVC_VM_POWER_ON:-true}}"
  WAIT_BOOTSTRAP_IPS="${WAIT_BOOTSTRAP_IPS:-true}"
  WAIT_BOOTSTRAP_TIMEOUT="${WAIT_BOOTSTRAP_TIMEOUT:-600}"
  WAIT_TALOS_API="${WAIT_TALOS_API:-true}"
  WAIT_TALOS_API_TIMEOUT="${WAIT_TALOS_API_TIMEOUT:-300}"
  CP_NAME_PREFIX="${TALOS_CONTROL_PLANE_NAME_PREFIX:-talos-cp}"
  WORKER_NAME_PREFIX="${TALOS_WORKER_NAME_PREFIX:-talos-worker}"
  CP_IPS_RAW="${TALOS_CONTROL_PLANE_IPS:-}"
  WORKER_IPS_RAW="${TALOS_WORKER_IPS:-}"
  CP_IPS_RAW="$(normalize_csv_list "${CP_IPS_RAW}")"
  WORKER_IPS_RAW="$(normalize_csv_list "${WORKER_IPS_RAW}")"
  mapfile -t CP_STATIC_IPS < <(csv_to_array "${CP_IPS_RAW}")
  mapfile -t WORKER_STATIC_IPS < <(csv_to_array "${WORKER_IPS_RAW}")

  CP_CONFIG_PATH="$(resolve_path_from_repo "${CP_CONFIG_PATH}")"
  WORKER_CONFIG_PATH="$(resolve_path_from_repo "${WORKER_CONFIG_PATH}")"
  if [[ -n "${OVA_PATH}" && "${OVA_PATH}" != /* && "${OVA_PATH}" != http://* && "${OVA_PATH}" != https://* ]]; then
    OVA_PATH="$(resolve_path_from_repo "${OVA_PATH}")"
  fi
  if [[ -n "${ISO_LOCAL_FILE}" && "${ISO_LOCAL_FILE}" != /* ]]; then
    ISO_LOCAL_FILE="$(resolve_path_from_repo "${ISO_LOCAL_FILE}")"
  fi
  resolve_patch_files
}

validate_inputs() {
  [[ -n "${ACTION}" ]] || die "Action is required: create, destroy, or plan."
  [[ "${CP_COUNT}" =~ ^[0-9]+$ ]] || die "--cp-count must be numeric."
  [[ "${WORKER_COUNT}" =~ ^[0-9]+$ ]] || die "--worker-count must be numeric."
  [[ "${CP_CPU}" =~ ^[0-9]+$ ]] || die "--cp-cpu must be numeric."
  [[ "${CP_MEMORY_MB}" =~ ^[0-9]+$ ]] || die "--cp-memory-mb must be numeric."
  [[ "${CP_DISK_GB}" =~ ^[0-9]+$ ]] || die "--cp-disk-gb must be numeric."
  [[ "${CP_EXTRA_DISK_GB}" =~ ^[0-9]+$ ]] || die "--cp-extra-disk-gb must be numeric."
  [[ "${WORKER_CPU}" =~ ^[0-9]+$ ]] || die "--worker-cpu must be numeric."
  [[ "${WORKER_MEMORY_MB}" =~ ^[0-9]+$ ]] || die "--worker-memory-mb must be numeric."
  [[ "${WORKER_DISK_GB}" =~ ^[0-9]+$ ]] || die "--worker-disk-gb must be numeric."
  [[ "${WORKER_EXTRA_DISK_GB}" =~ ^[0-9]+$ ]] || die "--worker-extra-disk-gb must be numeric."
  [[ -n "${VM_DATASTORE}" ]] || die "Datastore is required."
  [[ -n "${VM_NETWORK}" ]] || die "Network is required."
  if [[ -z "${OVA_PATH}" ]]; then
    [[ -n "${ISO_DATASTORE_PATH}" ]] || die "Talos ISO datastore path is required when OVA is not set."
  elif [[ "${OVA_PATH}" != http://* && "${OVA_PATH}" != https://* ]]; then
    [[ -f "${OVA_PATH}" ]] || die "Talos OVA not found: ${OVA_PATH}"
  fi
  [[ -n "${GOVC_URL:-}" ]] || die "GOVC_URL is empty."
  [[ -n "${GOVC_USERNAME:-}" ]] || die "GOVC_USERNAME is empty."
  [[ -n "${GOVC_PASSWORD:-}" ]] || die "GOVC_PASSWORD is empty."
  [[ "${WAIT_BOOTSTRAP_TIMEOUT}" =~ ^[0-9]+$ ]] || die "--wait-bootstrap-timeout must be numeric."
  [[ "${WAIT_TALOS_API_TIMEOUT}" =~ ^[0-9]+$ ]] || die "--wait-talos-api-timeout must be numeric."
  if (( ${#ALL_PATCH_FILES[@]} > 0 || ${#CP_PATCH_FILES[@]} > 0 || ${#WORKER_PATCH_FILES[@]} > 0 )); then
    command -v talosctl >/dev/null 2>&1 || die "talosctl is required when patches are provided."
  fi

  if [[ "${ACTION}" == "create" ]]; then
    local patch_file=""
    [[ -f "${CP_CONFIG_PATH}" ]] || die "Control-plane machine config not found: ${CP_CONFIG_PATH}"
    [[ -f "${WORKER_CONFIG_PATH}" ]] || die "Worker machine config not found: ${WORKER_CONFIG_PATH}"
    grep -q 'factory.talos.dev/vmware-installer/' "${CP_CONFIG_PATH}" || \
      die "Control-plane config should use Talos Factory vmware-installer image for production-ready flow."
    grep -q 'factory.talos.dev/vmware-installer/' "${WORKER_CONFIG_PATH}" || \
      die "Worker config should use Talos Factory vmware-installer image for production-ready flow."
    grep -q 'https://'"${HAPROXY_VIP:-}"':6443' "${CP_CONFIG_PATH}" || \
      log_warn "Control-plane endpoint does not seem to point to HAProxy VIP (${HAPROXY_VIP:-unset})."
    for patch_file in "${ALL_PATCH_FILES[@]}" "${CP_PATCH_FILES[@]}" "${WORKER_PATCH_FILES[@]}"; do
      [[ -z "${patch_file}" ]] && continue
      [[ -f "${patch_file}" ]] || die "Patch file not found: ${patch_file}"
    done
  fi
}

vm_exists() {
  local vm_name="$1"
  govc find / -type m -name "${vm_name}" | grep -qx ".*/${vm_name}"
}

vm_name_for_role() {
  local role="$1"
  local index="$2"
  case "${role}" in
    control-plane) printf '%s-%d\n' "${CP_NAME_PREFIX}" "${index}" ;;
    worker) printf '%s-%d\n' "${WORKER_NAME_PREFIX}" "${index}" ;;
    *) printf '%s-%s-%d\n' "${CLUSTER_NAME}" "${role}" "${index}" ;;
  esac
}

config_for_index() {
  local base_config="$1"
  local index="$2"
  local indexed=""

  indexed="${base_config%.*}-${index}.${base_config##*.}"
  if [[ -f "${indexed}" ]]; then
    printf '%s\n' "${indexed}"
  else
    printf '%s\n' "${base_config}"
  fi
}

encode_config_base64() {
  local cfg="$1"
  base64 -w 0 "${cfg}"
}

patched_config_file() {
  local src_cfg="$1"
  local role="$2"
  local index="$3"
  local current tmp patch_file
  local -a patch_chain=()
  local cluster_dir role_prefix role_bootstrap_patch named_patch=""
  local -a candidate_patch_dirs=()
  local patches_dir=""

  patch_chain+=("${ALL_PATCH_FILES[@]}")
  if [[ "${role}" == "control-plane" ]]; then
    patch_chain+=("${CP_PATCH_FILES[@]}")
    role_prefix="controlplane"
    role_bootstrap_patch="cp-bootstrap.patch.yaml"
  else
    patch_chain+=("${WORKER_PATCH_FILES[@]}")
    role_prefix="worker"
    role_bootstrap_patch="worker-bootstrap.patch.yaml"
  fi

  cluster_dir="$(dirname "${CP_CONFIG_PATH}")"
  candidate_patch_dirs+=("${cluster_dir}/patches")
  candidate_patch_dirs+=("$(dirname "${cluster_dir}")/patches")

  for patches_dir in "${candidate_patch_dirs[@]}"; do
    [[ -d "${patches_dir}" ]] || continue
    [[ -f "${patches_dir}/bootstrap.patch.yaml" ]] && patch_chain+=("${patches_dir}/bootstrap.patch.yaml")
    [[ -s "${patches_dir}/${role_bootstrap_patch}" ]] && patch_chain+=("${patches_dir}/${role_bootstrap_patch}")
    [[ -f "${patches_dir}/${role_prefix}-${index}.patch.yaml" ]] && patch_chain+=("${patches_dir}/${role_prefix}-${index}.patch.yaml")
    if [[ "${role}" == "control-plane" ]]; then
      named_patch="${patches_dir}/${CP_NAME_PREFIX}-${index}.patch.yaml"
    else
      named_patch="${patches_dir}/${WORKER_NAME_PREFIX}-${index}.patch.yaml"
      if [[ "${WORKER_EXTRA_DISK_GB}" != "0" && -f "${patches_dir}/longhorn.patch.yaml" ]]; then
        patch_chain+=("${patches_dir}/longhorn.patch.yaml")
      fi
    fi
    [[ -f "${named_patch}" ]] && patch_chain+=("${named_patch}")
  done

  if (( ${#patch_chain[@]} == 0 )); then
    printf '%s\n' "${src_cfg}"
    return 0
  fi

  current="$(mktemp)"
  cp "${src_cfg}" "${current}"
  for patch_file in "${patch_chain[@]}"; do
    [[ -n "${patch_file}" ]] || continue
    tmp="$(mktemp)"
    talosctl machineconfig patch "${current}" -p "@${patch_file}" -o "${tmp}" >/dev/null
    mv "${tmp}" "${current}"
  done
  printf '%s\n' "${current}"
}

ensure_cdrom_device() {
  local vm_name="$1"
  local device_name=""

  device_name="$(govc device.info -vm "${vm_name}" | awk '$1=="Name:" && $2 ~ /^cdrom-/ {print $2; exit}')"
  if [[ -n "${device_name}" ]]; then
    printf '%s\n' "${device_name}"
    return 0
  fi

  govc device.cdrom.add -vm "${vm_name}" >/dev/null
  device_name="$(govc device.info -vm "${vm_name}" | awk '$1=="Name:" && $2 ~ /^cdrom-/ {print $2; exit}')"
  [[ -n "${device_name}" ]] || die "Could not find/add CDROM device for ${vm_name}."
  printf '%s\n' "${device_name}"
}

iso_exists_on_datastore() {
  local iso_path="$1"
  govc datastore.ls -ds "${VM_DATASTORE}" "${iso_path}" >/dev/null 2>&1
}

ensure_iso_available() {
  local iso_dir=""
  if [[ -n "${OVA_PATH}" ]]; then
    return 0
  fi

  if iso_exists_on_datastore "${ISO_DATASTORE_PATH}"; then
    return 0
  fi

  [[ -n "${ISO_LOCAL_FILE}" ]] || die "ISO mode selected and datastore ISO is missing: [${VM_DATASTORE}] ${ISO_DATASTORE_PATH}. Set ISO_LOCAL_PATH or TALOS_ISO_LOCAL_PATH to upload automatically."
  [[ -f "${ISO_LOCAL_FILE}" ]] || die "Local ISO file not found: ${ISO_LOCAL_FILE}"

  iso_dir="$(dirname "${ISO_DATASTORE_PATH}")"
  if [[ -n "${iso_dir}" && "${iso_dir}" != "." ]]; then
    govc datastore.mkdir -ds "${VM_DATASTORE}" "${iso_dir}" >/dev/null 2>&1 || true
  fi

  log_info "Datastore ISO not found. Uploading from local file: ${ISO_LOCAL_FILE} -> [${VM_DATASTORE}] ${ISO_DATASTORE_PATH}"
  govc datastore.upload -ds "${VM_DATASTORE}" "${ISO_LOCAL_FILE}" "${ISO_DATASTORE_PATH}"

  iso_exists_on_datastore "${ISO_DATASTORE_PATH}" || \
    die "ISO upload finished but datastore path is still missing: [${VM_DATASTORE}] ${ISO_DATASTORE_PATH}"
}

create_vm() {
  local vm_name="$1"
  local role="$2"
  local index="$3"
  local cpu="$4"
  local memory_mb="$5"
  local disk_gb="$6"
  local cfg_path="$7"
  local cfg_effective=""
  local talos_cfg_b64=""
  local cdrom_device=""
  local iso_full_path=""
  local nic_device=""
  local import_args=()
  local create_args=(vm.create)
  local extra_disk_name=""
  local actual_firmware=""

  if vm_exists "${vm_name}"; then
    if [[ "${VM_OVERWRITE}" == "true" ]]; then
      log_warn "VM ${vm_name} already exists. Destroying because overwrite=true."
      govc vm.destroy "${vm_name}"
    else
      log_warn "VM ${vm_name} already exists. Skipping create."
      return 0
    fi
  fi

  cfg_effective="$(patched_config_file "${cfg_path}" "${role}" "${index}")"
  talos_cfg_b64="$(encode_config_base64 "${cfg_effective}")"
  iso_full_path="[${VM_DATASTORE}] ${ISO_DATASTORE_PATH}"

  if [[ -n "${OVA_PATH}" ]]; then
    import_args=(import.ova -name "${vm_name}" -ds "${VM_DATASTORE}" -net "${VM_NETWORK}")
    if [[ -n "${VM_FOLDER}" ]]; then
      import_args+=(-folder "${VM_FOLDER}")
    fi
    if [[ -n "${VM_RESOURCE_POOL}" ]]; then
      import_args+=(-pool "${VM_RESOURCE_POOL}")
    fi
    import_args+=("${OVA_PATH}")
    govc "${import_args[@]}"
    govc vm.change -vm "${vm_name}" -c "${cpu}" -m "${memory_mb}"
    actual_firmware="$(govc object.collect -s "/ha-datacenter/vm/${vm_name}" config.firmware 2>/dev/null | tail -n 1 | tr -d '\r' || true)"
    if [[ -n "${actual_firmware}" && "${actual_firmware}" != "${VM_FIRMWARE}" ]]; then
      log_warn "OVA imported with firmware=${actual_firmware}. Adjusting to ${VM_FIRMWARE} via govc device.boot."
      govc device.boot -vm "${vm_name}" -firmware "${VM_FIRMWARE}"
      actual_firmware="$(govc object.collect -s "/ha-datacenter/vm/${vm_name}" config.firmware 2>/dev/null | tail -n 1 | tr -d '\r' || true)"
      if [[ -n "${actual_firmware}" && "${actual_firmware}" != "${VM_FIRMWARE}" ]]; then
        die "Unable to enforce firmware=${VM_FIRMWARE} on ${vm_name} (current: ${actual_firmware})."
      fi
    fi
    log_warn "Using OVA mode: disk size override is ignored by import.ova."
  else
    if [[ -n "${VM_FOLDER}" ]]; then
      create_args+=(-folder "${VM_FOLDER}")
    fi
    if [[ -n "${VM_RESOURCE_POOL}" ]]; then
      create_args+=(-pool "${VM_RESOURCE_POOL}")
    fi
    create_args+=(
      -on=false
      -ds "${VM_DATASTORE}"
      -net "${VM_NETWORK}"
      -c "${cpu}"
      -m "${memory_mb}"
      -g "${VM_GUEST_OS_TYPE}"
      -firmware "${VM_FIRMWARE}"
      -disk "${disk_gb}G"
      -disk.controller "${VM_DISK_CONTROLLER}"
      -net.adapter "${VM_NET_ADAPTER}"
      "${vm_name}"
    )
    govc "${create_args[@]}"
  fi

  govc vm.change \
    -vm "${vm_name}" \
    -e "guestinfo.talos.config=${talos_cfg_b64}" \
    -e "guestinfo.talos.config.encoding=base64" \
    -e "disk.enableUUID=1"

  nic_device="$(govc device.ls -vm "${vm_name}" | awk '$1 ~ /^ethernet-/ {print $1; exit}')"
  if [[ -n "${nic_device}" ]]; then
    govc vm.network.change -vm "${vm_name}" -net "${VM_NETWORK}" "${nic_device}"
  fi

  if [[ -z "${OVA_PATH}" ]]; then
    cdrom_device="$(ensure_cdrom_device "${vm_name}")"
    govc device.cdrom.insert -vm "${vm_name}" -device "${cdrom_device}" "${iso_full_path}"
  fi

  if [[ "${role}" == "control-plane" && "${CP_EXTRA_DISK_GB}" != "0" ]]; then
    extra_disk_name="${vm_name}/disk-data"
    govc vm.disk.create \
      -vm "${vm_name}" \
      -ds "${VM_DATASTORE}" \
      -name "${extra_disk_name}" \
      -size "${CP_EXTRA_DISK_GB}G"
  fi

  if [[ "${role}" == "worker" && "${WORKER_EXTRA_DISK_GB}" != "0" ]]; then
    extra_disk_name="${vm_name}/disk-data"
    govc vm.disk.create \
      -vm "${vm_name}" \
      -ds "${VM_DATASTORE}" \
      -name "${extra_disk_name}" \
      -size "${WORKER_EXTRA_DISK_GB}G"
  fi

  if [[ "${VM_POWER_ON}" == "true" ]]; then
    govc vm.power -on "${vm_name}"
  fi

  if [[ "${cfg_effective}" != "${cfg_path}" ]]; then
    rm -f "${cfg_effective}"
  fi
}

destroy_vm() {
  local vm_name="$1"
  if vm_exists "${vm_name}"; then
    log_info "Destroying VM ${vm_name}"
    govc vm.destroy "${vm_name}"
  else
    log_warn "VM ${vm_name} not found. Skipping destroy."
  fi
}

print_plan() {
  log_info "Talos govc plan env=${ENV_NAME} action=${ACTION}"
  log_info "cluster=${CLUSTER_NAME} cp=${CP_COUNT} worker=${WORKER_COUNT}"
  log_info "vm-name-prefixes cp=${CP_NAME_PREFIX} worker=${WORKER_NAME_PREFIX}"
  log_info "cp(cpu=${CP_CPU},mem=${CP_MEMORY_MB},disk=${CP_DISK_GB},extra-disk=${CP_EXTRA_DISK_GB}) worker(cpu=${WORKER_CPU},mem=${WORKER_MEMORY_MB},disk=${WORKER_DISK_GB},extra-disk=${WORKER_EXTRA_DISK_GB})"
  log_info "network=${VM_NETWORK} datastore=${VM_DATASTORE} folder=${VM_FOLDER:-<current>} pool=${VM_RESOURCE_POOL:-<current>}"
  if [[ -n "${OVA_PATH}" ]]; then
    log_info "ova=${OVA_PATH}"
  else
    log_info "iso=[${VM_DATASTORE}] ${ISO_DATASTORE_PATH}"
  fi
  log_info "cp-config=${CP_CONFIG_PATH} worker-config=${WORKER_CONFIG_PATH}"
  if (( ${#ALL_PATCH_FILES[@]} > 0 || ${#CP_PATCH_FILES[@]} > 0 || ${#WORKER_PATCH_FILES[@]} > 0 )); then
    log_info "patches(all=${#ALL_PATCH_FILES[@]},cp=${#CP_PATCH_FILES[@]},worker=${#WORKER_PATCH_FILES[@]})"
  fi
}

execute_action() {
  local i vm_name cfg
  local -a discovered=()
  local vm_path=""
  local vm_base=""
  local destroy_cp_scope="true"
  local destroy_worker_scope="true"

  if [[ "${ACTION}" == "destroy" ]]; then
    # Respect explicit counts during destroy to allow safe scoped teardown.
    # --cp-count=0 means "do not touch control-plane VMs"
    # --worker-count=0 means "do not touch worker VMs"
    [[ "${CP_COUNT}" == "0" ]] && destroy_cp_scope="false"
    [[ "${WORKER_COUNT}" == "0" ]] && destroy_worker_scope="false"
  fi

  # For destroy flows, prefer discovered VMs by prefix so overrides like
  # --worker-count=0 don't leave stale worker VMs behind.
  if [[ "${ACTION}" == "destroy" ]]; then
    if [[ "${destroy_cp_scope}" == "true" ]]; then
      mapfile -t discovered < <(govc find / -type m -name "${CP_NAME_PREFIX}-*" 2>/dev/null | sort -V)
      if (( ${#discovered[@]} == 0 )); then
        for ((i = 1; i <= CP_COUNT; i++)); do
          discovered+=("$(vm_name_for_role "control-plane" "${i}")")
        done
      fi
      for vm_path in "${discovered[@]}"; do
        vm_base="${vm_path##*/}"
        destroy_vm "${vm_base}"
      done
    else
      log_info "Skipping control-plane destroy scope (--cp-count=0)."
    fi

    if [[ "${destroy_worker_scope}" == "true" ]]; then
      discovered=()
      mapfile -t discovered < <(govc find / -type m -name "${WORKER_NAME_PREFIX}-*" 2>/dev/null | sort -V)
      if (( ${#discovered[@]} == 0 )); then
        for ((i = 1; i <= WORKER_COUNT; i++)); do
          discovered+=("$(vm_name_for_role "worker" "${i}")")
        done
      fi
      for vm_path in "${discovered[@]}"; do
        vm_base="${vm_path##*/}"
        destroy_vm "${vm_base}"
      done
    else
      log_info "Skipping worker destroy scope (--worker-count=0)."
    fi
    return 0
  fi

  for ((i = 1; i <= CP_COUNT; i++)); do
    vm_name="$(vm_name_for_role "control-plane" "${i}")"
    cfg="$(config_for_index "${CP_CONFIG_PATH}" "${i}")"
    case "${ACTION}" in
      create) create_vm "${vm_name}" "control-plane" "${i}" "${CP_CPU}" "${CP_MEMORY_MB}" "${CP_DISK_GB}" "${cfg}" ;;
      destroy) destroy_vm "${vm_name}" ;;
    esac
  done

  for ((i = 1; i <= WORKER_COUNT; i++)); do
    vm_name="$(vm_name_for_role "worker" "${i}")"
    cfg="$(config_for_index "${WORKER_CONFIG_PATH}" "${i}")"
    case "${ACTION}" in
      create) create_vm "${vm_name}" "worker" "${i}" "${WORKER_CPU}" "${WORKER_MEMORY_MB}" "${WORKER_DISK_GB}" "${cfg}" ;;
      destroy) destroy_vm "${vm_name}" ;;
    esac
  done
}

collect_bootstrap_ips() {
  local cluster_dir out_file tmp_file
  local deadline now i vm_name ip
  local total_expected=$((CP_COUNT + WORKER_COUNT))
  local found=0
  declare -A seen_ips=()

  cluster_dir="$(dirname "${CP_CONFIG_PATH}")"
  out_file="${cluster_dir}/bootstrap-ips.txt"
  deadline=$(( "$(date +%s)" + WAIT_BOOTSTRAP_TIMEOUT ))
  : > "${out_file}"

  while true; do
    now="$(date +%s)"
    if (( now > deadline )); then
      break
    fi

    tmp_file="$(mktemp)"
    found=0
    seen_ips=()

    for ((i = 1; i <= CP_COUNT; i++)); do
      vm_name="$(vm_name_for_role "control-plane" "${i}")"
      ip="$(extract_vm_ipv4 "${vm_name}")"
      if [[ -n "${ip}" && "${ip}" != "<nil>" ]] && is_ipv4 "${ip}"; then
        printf '%s %s %s\n' "control-plane-${i}" "${vm_name}" "${ip}" >> "${tmp_file}"
        seen_ips["${ip}"]=1
      fi
    done

    for ((i = 1; i <= WORKER_COUNT; i++)); do
      vm_name="$(vm_name_for_role "worker" "${i}")"
      ip="$(extract_vm_ipv4 "${vm_name}")"
      if [[ -n "${ip}" && "${ip}" != "<nil>" ]] && is_ipv4 "${ip}"; then
        printf '%s %s %s\n' "worker-${i}" "${vm_name}" "${ip}" >> "${tmp_file}"
        seen_ips["${ip}"]=1
      fi
    done

    mv "${tmp_file}" "${out_file}"

    found="${#seen_ips[@]}"
    if (( found >= total_expected )); then
      log_info "Captured bootstrap IPs for all ${total_expected} nodes."
      log_info "Bootstrap inventory: ${out_file}"
      return 0
    fi

    sleep 5
  done

  log_warn "Timeout waiting bootstrap DHCP IPs (${WAIT_BOOTSTRAP_TIMEOUT}s). Partial inventory in ${out_file}."
  [[ -s "${out_file}" ]] && cat "${out_file}" || true
}

wait_talos_api_ready() {
  local cluster_dir out_file
  local deadline now role vm_name ip i
  local pending
  local -a nodes=()

  cluster_dir="$(dirname "${CP_CONFIG_PATH}")"
  out_file="${cluster_dir}/bootstrap-ips.txt"
  [[ -s "${out_file}" ]] || {
    log_warn "Skipping Talos API readiness check: bootstrap inventory missing (${out_file})."
    return 0
  }

  if [[ -s "${out_file}" ]]; then
    while read -r role vm_name ip; do
      [[ -n "${role:-}" && -n "${vm_name:-}" && -n "${ip:-}" ]] || continue
      if ! is_ipv4 "${ip}"; then
        log_warn "Ignoring non-IPv4 bootstrap address for ${vm_name}: ${ip}"
        continue
      fi
      nodes+=("${role}|${vm_name}|${ip}")
    done < "${out_file}"
    log_info "Talos API readiness source: bootstrap DHCP inventory (${out_file})."
  elif (( ${#CP_STATIC_IPS[@]} > 0 || ${#WORKER_STATIC_IPS[@]} > 0 )); then
    for ((i = 1; i <= CP_COUNT; i++)); do
      vm_name="$(vm_name_for_role "control-plane" "${i}")"
      ip="${CP_STATIC_IPS[$((i - 1))]:-}"
      [[ -n "${ip}" ]] || continue
      nodes+=("control-plane-${i}|${vm_name}|${ip}")
    done
    for ((i = 1; i <= WORKER_COUNT; i++)); do
      vm_name="$(vm_name_for_role "worker" "${i}")"
      ip="${WORKER_STATIC_IPS[$((i - 1))]:-}"
      [[ -n "${ip}" ]] || continue
      nodes+=("worker-${i}|${vm_name}|${ip}")
    done
    log_info "Talos API readiness source: static overlay IPs (fallback)."
  fi

  (( ${#nodes[@]} > 0 )) || {
    log_warn "Skipping Talos API readiness check: inventory is empty (${out_file})."
    return 0
  }

  deadline=$(( "$(date +%s)" + WAIT_TALOS_API_TIMEOUT ))
  while true; do
    pending=0
    for entry in "${nodes[@]}"; do
      role="${entry%%|*}"
      entry="${entry#*|}"
      vm_name="${entry%%|*}"
      ip="${entry##*|}"
      if ! timeout 2 bash -c "cat < /dev/null > /dev/tcp/${ip}/50000" 2>/dev/null; then
        pending=$((pending + 1))
        log_info "Waiting Talos API on ${role} (${vm_name}) ${ip}:50000"
      fi
    done

    if (( pending == 0 )); then
      log_info "Talos API (:50000) reachable on all nodes."
      return 0
    fi

    now="$(date +%s)"
    if (( now > deadline )); then
      log_warn "Timeout waiting Talos API readiness (${WAIT_TALOS_API_TIMEOUT}s)."
      return 0
    fi
    sleep 5
  done
}

sync_dns_hosts_for_talos() {
  local dns_domain="${DNS_DOMAIN:-}"
  local api_host="${TALOS_API_DNS_NAME:-talos-api}"
  local host_name="" ip=""
  local idx=1
  local -a records=()
  local -a cmd=()

  [[ -n "${DNS_REGISTER_SCRIPT}" ]] || die "Missing TALOS_DNS_REGISTER_SCRIPT. This integration must be provided by the consuming project."
  DNS_REGISTER_SCRIPT="$(resolve_path_from_repo "${DNS_REGISTER_SCRIPT}")"
  require_file "${DNS_REGISTER_SCRIPT}"

  if [[ -n "${HAPROXY_VIP:-}" ]]; then
    host_name="${api_host}"
    [[ -n "${dns_domain}" ]] && host_name="${api_host}.${dns_domain}"
    records+=("${host_name}=${HAPROXY_VIP}")
  fi

  idx=1
  for ip in "${CP_STATIC_IPS[@]}"; do
    [[ -n "${ip}" ]] || continue
    host_name="${CP_NAME_PREFIX}-${idx}"
    [[ -n "${dns_domain}" ]] && host_name="${host_name}.${dns_domain}"
    records+=("${host_name}=${ip}")
    idx=$((idx + 1))
  done

  idx=1
  for ip in "${WORKER_STATIC_IPS[@]}"; do
    [[ -n "${ip}" ]] || continue
    host_name="${WORKER_NAME_PREFIX}-${idx}"
    [[ -n "${dns_domain}" ]] && host_name="${host_name}.${dns_domain}"
    records+=("${host_name}=${ip}")
    idx=$((idx + 1))
  done

  if (( ${#records[@]} == 0 )); then
    log_warn "Skipping DNS sync for owner '${DNS_OWNER_ID}': no records generated."
    return 0
  fi

  cmd=("${DNS_REGISTER_SCRIPT}" "--env=${ENV_NAME}" "--owner=${DNS_OWNER_ID}")
  for host_name in "${records[@]}"; do
    cmd+=("--record=${host_name}")
  done
  "${cmd[@]}"
}

cleanup_dns_hosts_for_talos() {
  local -a cmd=()
  [[ -n "${DNS_UNREGISTER_SCRIPT}" ]] || die "Missing TALOS_DNS_UNREGISTER_SCRIPT. This integration must be provided by the consuming project."
  DNS_UNREGISTER_SCRIPT="$(resolve_path_from_repo "${DNS_UNREGISTER_SCRIPT}")"
  require_file "${DNS_UNREGISTER_SCRIPT}"
  cmd=("${DNS_UNREGISTER_SCRIPT}" "--env=${ENV_NAME}" "--owner=${DNS_OWNER_ID}")
  "${cmd[@]}"
}

main() {
  local dns_sync_required=""
  parse_args "$@"
  load_context
  validate_inputs
  print_plan

  if [[ "${ACTION}" == "plan" ]]; then
    return 0
  fi

  execute_action
  dns_sync_required="${TALOS_DNS_SYNC_REQUIRED:-true}"
  if [[ "${ACTION}" == "create" ]]; then
    ensure_iso_available
    if [[ "${dns_sync_required}" == "true" ]]; then
      if ! sync_dns_hosts_for_talos; then
        log_warn "DNS sync for Talos failed, continuing provisioning flow."
      fi
    else
      log_info "Skipping Talos DNS sync (TALOS_DNS_SYNC_REQUIRED=${dns_sync_required})."
    fi
  elif [[ "${ACTION}" == "destroy" ]]; then
    if [[ "${dns_sync_required}" == "true" ]]; then
      if ! cleanup_dns_hosts_for_talos; then
        log_warn "DNS cleanup for Talos failed, continuing destroy flow."
      fi
    else
      log_info "Skipping Talos DNS cleanup (TALOS_DNS_SYNC_REQUIRED=${dns_sync_required})."
    fi
  fi
  log_info "Action '${ACTION}' completed successfully."
}

main "$@"
