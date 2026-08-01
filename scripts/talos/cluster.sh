#!/usr/bin/env bash
# @file cluster.sh
# @brief Unified day-1 Talos cluster lifecycle entrypoint.
# @description
#   Provides project-oriented actions for Talos day-1 flows:
#   scaffold project files, generate machine configs, provision VMs,
#   prepare and bootstrap control planes, apply post-bootstrap machine config,
#   synchronize local access, and refresh Talos Factory schematics.
#
# @arg create-project action Create project scaffold in --project-dir.
# @arg generate action Generate Talos configs and rendered patches.
# @arg provision action Provision Talos VMs.
# @arg prepare-bootstrap action Prepare hosts for bootstrap pre-stage.
# @arg apply-config action Apply machine configuration to nodes.
# @arg bootstrap action Bootstrap Talos control plane.
# @arg apply-post-bootstrap action Apply mandatory post-bootstrap baseline.
# @arg sync-access action Sync local kubectl and talosctl access.
# @arg refresh-schematics action Refresh schematic IDs and image vars.
#
# @arg --project-dir path Cluster project directory.
# @arg --vars-file path Explicit vars file (advanced mode).
# @arg --local-vars-file path Optional local override vars file.
# @arg --cluster-name name Cluster name override.
# @arg --generated-dir path Generated directory override.
# @arg --worker-count int Worker count override for provision.
# @arg --addons list Addons list for apply-post-bootstrap.
# @arg --talos-version version Talos version for schematic image tags.
# @arg --cp-schematic-file path Control-plane schematic file path.
# @arg --worker-schematic-file path Worker schematic file path.
# @flag --force-generate Force regeneration of Talos config files.
# @flag --no-update-ova Do not rewrite TALOS_OVA_PATH on refresh-schematics.
# @flag --dry-run,-n Print actions without executing.
# @flag --help,-h Show usage information.
#
# @example
#   # Create project scaffold and initialize schematic image IDs
#   ./cluster.sh create-project --project-dir=./clusters/talos-dev
#
# @example
#   # Run standard day-1 sequence for an existing project
#   ./cluster.sh generate --project-dir=./clusters/talos-dev
#   ./cluster.sh provision --project-dir=./clusters/talos-dev
#   ./cluster.sh prepare-bootstrap --project-dir=./clusters/talos-dev
#   ./cluster.sh bootstrap --project-dir=./clusters/talos-dev
#   ./cluster.sh apply-config --project-dir=./clusters/talos-dev
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/talos/lib/common.sh"

ACTION=""
VARS_FILE=""
LOCAL_VARS_FILE=""
PROJECT_DIR=""
CLUSTER_NAME=""
GENERATED_DIR=""
WORKER_COUNT=""
ADDONS_LIST=""
TALOS_VERSION=""
CP_SCHEMATIC_FILE=""
WORKER_SCHEMATIC_FILE=""
UPDATE_OVA_FROM_SCHEMATIC="true"
FORCE_GENERATE="false"
DRY_RUN="false"

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") <action> [options]

Actions:
  create-project  Create a new cluster project scaffold in --project-dir and initialize Factory image IDs
  generate        Generate Talos configs and rendered patches
  provision       Provision Talos VMs (create)
  prepare-bootstrap  Prepare hosts for bootstrap (discovers DHCP IPs in ISO mode and applies config)
  apply-config    Apply machine configuration to nodes
  bootstrap       Bootstrap Talos control plane
  apply-post-bootstrap  Apply mandatory post-bootstrap baseline (for example cilium, longhorn)
  sync-access     Sync local kubectl and talosctl access
  refresh-schematics  Generate schematic IDs and refresh Talos image vars in project vars.sh

Options:
  --vars-file=<path>              Explicit vars file (env-agnostic mode)
  --bootstrap-vars-file=<path>    Alias of --vars-file
  --local-vars-file=<path>        Optional local overrides file
  --project-dir=<path>            Cluster project dir (loads vars.sh and vars.local.sh from there)
  --cluster-name=<name>           Cluster name override
  --generated-dir=<path>          Generated output dir override
  --worker-count=<n>              Worker count override (provision only)
  --addons=<list>                 Addon list for apply-post-bootstrap (CSV/JSON-like)
  --talos-version=<version>       Talos version for image tags (example: v1.12.4)
  --cp-schematic-file=<path>      CP schematic file (default: <project>/schematic.cp.yaml)
  --worker-schematic-file=<path>  Worker schematic file (default: <project>/schematic.worker.yaml, fallback schematic.yaml)
  --force-generate                Force regeneration of Talos config files
  --no-update-ova                 Do not rewrite TALOS_OVA_PATH during refresh-schematics
  -n, --dry-run                   Print actions without executing
  -h, --help                      Show this help

Examples:
  # Create project scaffold and initialize schematic image IDs
  $(basename "$0") create-project --project-dir=./clusters/talos-dev

  # Generate Talos config artifacts for the project
  $(basename "$0") generate --project-dir=./clusters/talos-dev

  # Provision project VMs on the configured virtualization backend
  $(basename "$0") provision --project-dir=./clusters/talos-dev

  # Prepare hosts for bootstrap pre-stage
  $(basename "$0") prepare-bootstrap --project-dir=./clusters/talos-dev

  # Re-apply machine configuration post-bootstrap
  $(basename "$0") apply-config --project-dir=./clusters/talos-dev

  # Bootstrap Talos control plane
  $(basename "$0") bootstrap --project-dir=./clusters/talos-dev

  # Apply mandatory post-bootstrap baseline addons
  $(basename "$0") apply-post-bootstrap --project-dir=./clusters/talos-dev --addons='[\"cilium\",\"longhorn\"]'

  # Sync local kubeconfig and talosconfig access
  $(basename "$0") sync-access --project-dir=./clusters/talos-dev

  # Refresh schematic IDs and image vars
  $(basename "$0") refresh-schematics --project-dir=./clusters/talos-dev --talos-version=v1.12.4
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      create-project|generate|provision|prepare-bootstrap|apply-config|bootstrap|apply-post-bootstrap|sync-access|refresh-schematics)
        [[ -z "${ACTION}" ]] || die "Action already set: ${ACTION}"
        ACTION="$1"
        shift
        ;;
      --vars-file=*) VARS_FILE="${1#*=}"; shift ;;
      --bootstrap-vars-file=*) VARS_FILE="${1#*=}"; shift ;;
      --local-vars-file=*) LOCAL_VARS_FILE="${1#*=}"; shift ;;
      --project-dir=*) PROJECT_DIR="${1#*=}"; shift ;;
      --cluster-name=*) CLUSTER_NAME="${1#*=}"; shift ;;
      --generated-dir=*) GENERATED_DIR="${1#*=}"; shift ;;
      --worker-count=*) WORKER_COUNT="${1#*=}"; shift ;;
      --addons=*) ADDONS_LIST="${1#*=}"; shift ;;
      --talos-version=*) TALOS_VERSION="${1#*=}"; shift ;;
      --cp-schematic-file=*) CP_SCHEMATIC_FILE="${1#*=}"; shift ;;
      --worker-schematic-file=*) WORKER_SCHEMATIC_FILE="${1#*=}"; shift ;;
      --force-generate) FORCE_GENERATE="true"; shift ;;
      --no-update-ova) UPDATE_OVA_FROM_SCHEMATIC="false"; shift ;;
      -n|--dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      --env=*|--env)
        die "--env was removed. Use --project-dir or --vars-file."
        ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "${ACTION}" ]] || { usage; die "Action is required."; }
}

run_or_echo() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

run_or_echo_cmd_string() {
  local command="$1"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] ${command}"
    return 0
  fi
  bash -lc "${command}"
}

resolve_abs_path() {
  local path_value="$1"
  if [[ "${path_value}" = /* ]]; then
    printf '%s\n' "${path_value}"
  else
    printf '%s\n' "${REPO_ROOT}/${path_value}"
  fi
}

detect_talos_version_from_vars() {
  local vars_file="$1"
  local detected=""
  detected="$(awk -F'"' '/^export TALOS_OVA_PATH=/{print $2}' "${vars_file}" \
    | sed -nE 's#.*\/(v[0-9]+\.[0-9]+\.[0-9]+)\/.*#\1#p' \
    | head -n1)"
  if [[ -z "${detected}" ]]; then
    detected="$(awk -F'[:"]' '/^export TALOS_WORKER_INSTALLER_IMAGE=/{print $(NF-1)}' "${vars_file}" | head -n1)"
  fi
  printf '%s\n' "${detected}"
}

read_export_var() {
  local file="$1"
  local key="$2"
  awk -F'"' -v k="${key}" '$0 ~ "^export " k "=" { print $2; exit }' "${file}"
}

is_valid_vmware_installer_image() {
  local image="$1"
  [[ "${image}" =~ ^factory\.talos\.dev/vmware-installer/.+:[^:]+$ ]]
}

ensure_factory_installer_images_for_generate() {
  local vars_file="$1"
  local project_abs="$2"
  local cp_image=""
  local worker_image=""

  [[ -f "${vars_file}" ]] || die "vars.sh not found: ${vars_file}"

  cp_image="$(read_export_var "${vars_file}" "TALOS_CONTROL_PLANE_INSTALLER_IMAGE" || true)"
  worker_image="$(read_export_var "${vars_file}" "TALOS_WORKER_INSTALLER_IMAGE" || true)"

  if is_valid_vmware_installer_image "${cp_image}" && is_valid_vmware_installer_image "${worker_image}"; then
    return 0
  fi

  [[ -n "${project_abs}" ]] || die "Missing --project-dir. Cannot auto-refresh schematics without project context."
  log_warn "Factory vmware-installer images are missing/invalid in vars.sh."
  log_info "Auto-refreshing schematics before generate."
  refresh_schematics "${vars_file}" "${project_abs}"
}

post_schematic_and_get_id() {
  local schematic_file="$1"
  local response=""
  local schematic_id=""

  [[ -f "${schematic_file}" ]] || die "Schematic file not found: ${schematic_file}"
  command -v curl >/dev/null 2>&1 || die "curl is required for refresh-schematics."

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] POST schematic: ${schematic_file} -> https://factory.talos.dev/schematics"
    printf '%s\n' "dryrun-schematic-id"
    return 0
  fi

  response="$(curl -fsSL -X POST --data-binary @"${schematic_file}" https://factory.talos.dev/schematics)"
  schematic_id="$(printf '%s' "${response}" | sed -nE 's/.*"id":"([a-f0-9]+)".*/\1/p')"
  [[ -n "${schematic_id}" ]] || die "Failed to parse schematic id from response: ${response}"
  printf '%s\n' "${schematic_id}"
}

upsert_export_var() {
  local file="$1"
  local key="$2"
  local value="$3"
  local escaped_value=""
  local tmp_file=""

  escaped_value="${value//\\/\\\\}"
  escaped_value="${escaped_value//\"/\\\"}"
  tmp_file="$(mktemp)"

  if grep -qE "^export ${key}=" "${file}"; then
    awk -v k="${key}" -v v="${escaped_value}" '
      BEGIN { done=0 }
      $0 ~ "^export " k "=" {
        print "export " k "=\"" v "\""
        done=1
        next
      }
      { print }
      END {
        if (!done) {
          print "export " k "=\"" v "\""
        }
      }
    ' "${file}" > "${tmp_file}"
  else
    cat "${file}" > "${tmp_file}"
    printf '\nexport %s="%s"\n' "${key}" "${escaped_value}" >> "${tmp_file}"
  fi

  mv "${tmp_file}" "${file}"
}

refresh_schematics() {
  local vars_file="$1"
  local project_abs="$2"
  local cp_file=""
  local worker_file=""
  local cp_id=""
  local worker_id=""
  local version=""
  local cp_image=""
  local worker_image=""
  local ova_url=""

  [[ -n "${project_abs}" ]] || die "--project-dir is required for refresh-schematics."
  [[ -f "${vars_file}" ]] || die "vars.sh not found: ${vars_file}"

  if [[ -n "${CP_SCHEMATIC_FILE}" ]]; then
    cp_file="$(resolve_abs_path "${CP_SCHEMATIC_FILE}")"
  else
    cp_file="${project_abs}/schematic.cp.yaml"
  fi

  if [[ -n "${WORKER_SCHEMATIC_FILE}" ]]; then
    worker_file="$(resolve_abs_path "${WORKER_SCHEMATIC_FILE}")"
  else
    worker_file="${project_abs}/schematic.worker.yaml"
  fi

  if [[ ! -f "${worker_file}" && -f "${project_abs}/schematic.yaml" ]]; then
    worker_file="${project_abs}/schematic.yaml"
  fi

  if [[ ! -f "${cp_file}" ]]; then
    if [[ -f "${project_abs}/schematic.yaml" ]]; then
      cp_file="${project_abs}/schematic.yaml"
    else
      cp_file="${worker_file}"
    fi
    log_warn "CP schematic not found; using fallback: ${cp_file}"
  fi

  [[ -f "${worker_file}" ]] || die "Worker schematic not found: ${worker_file}"
  [[ -f "${cp_file}" ]] || die "CP schematic not found: ${cp_file}"

  version="${TALOS_VERSION}"
  if [[ -z "${version}" ]]; then
    version="$(detect_talos_version_from_vars "${vars_file}")"
  fi
  [[ -n "${version}" ]] || die "Talos version not set. Use --talos-version (example: v1.12.4)."

  cp_id="$(post_schematic_and_get_id "${cp_file}")"
  worker_id="$(post_schematic_and_get_id "${worker_file}")"

  cp_image="factory.talos.dev/vmware-installer/${cp_id}:${version}"
  worker_image="factory.talos.dev/vmware-installer/${worker_id}:${version}"
  ova_url="https://factory.talos.dev/image/${worker_id}/${version}/vmware-amd64.ova"

  log_info "Resolved schematic IDs: cp=${cp_id} worker=${worker_id}"
  log_info "Control-plane installer image: ${cp_image}"
  log_info "Worker installer image: ${worker_image}"
  [[ "${UPDATE_OVA_FROM_SCHEMATIC}" == "true" ]] && log_info "OVA URL: ${ova_url}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] Would update ${vars_file}"
    return 0
  fi

  upsert_export_var "${vars_file}" "TALOS_CONTROL_PLANE_INSTALLER_IMAGE" "${cp_image}"
  upsert_export_var "${vars_file}" "TALOS_WORKER_INSTALLER_IMAGE" "${worker_image}"
  [[ "${UPDATE_OVA_FROM_SCHEMATIC}" == "true" ]] && upsert_export_var "${vars_file}" "TALOS_OVA_PATH" "${ova_url}"

  log_info "Updated image vars in: ${vars_file}"
}

create_project_scaffold() {
  local project_dir="$1"
  local cluster_name="$2"
  local project_abs=""

  if [[ "${project_dir}" = /* ]]; then
    project_abs="${project_dir}"
  else
    project_abs="${REPO_ROOT}/${project_dir}"
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] create project scaffold at ${project_abs}"
    return 0
  fi

  mkdir -p "${project_abs}/patches" "${project_abs}/generated" "${project_abs}/helm"

  if [[ ! -f "${project_abs}/patches/cni.patch.yaml" ]]; then
    cat > "${project_abs}/patches/cni.patch.yaml" <<'EOF_CNI'
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
EOF_CNI
  fi

  if [[ ! -f "${project_abs}/patches/cp.patch.yaml" ]]; then
    cat > "${project_abs}/patches/cp.patch.yaml" <<'EOF_CP_PATCH'
machine:
  time:
    disabled: true
  features:
    hostDNS:
      enabled: true
      forwardKubeDNSToHost: true
EOF_CP_PATCH
  fi

  if [[ ! -f "${project_abs}/patches/worker.patch.yaml" ]]; then
    cat > "${project_abs}/patches/worker.patch.yaml" <<'EOF_WORKER_PATCH'
machine:
  time:
    disabled: true
  features:
    hostDNS:
      enabled: true
      forwardKubeDNSToHost: true
EOF_WORKER_PATCH
  fi

  if [[ ! -f "${project_abs}/patches/cp-bootstrap.patch.yaml" ]]; then
    : > "${project_abs}/patches/cp-bootstrap.patch.yaml"
  fi

  if [[ ! -f "${project_abs}/patches/worker-bootstrap.patch.yaml" ]]; then
    : > "${project_abs}/patches/worker-bootstrap.patch.yaml"
  fi

  if [[ ! -f "${project_abs}/patches/longhorn.patch.yaml" ]]; then
    cat > "${project_abs}/patches/longhorn.patch.yaml" <<'EOF_LONGHORN'
machine:
  kubelet:
    extraMounts:
      - destination: /var/lib/longhorn
        type: bind
        source: /var/mnt/longhorn
        options:
          - bind
          - rshared
          - rw
  disks:
    - device: /dev/sdb
      partitions:
        - mountpoint: /var/mnt/longhorn
  kernel:
    modules:
      - name: nbd
      - name: iscsi_tcp
      - name: configfs
EOF_LONGHORN
  fi

  if [[ ! -f "${project_abs}/schematic.cp.yaml" ]]; then
    cat > "${project_abs}/schematic.cp.yaml" <<'EOF_SCHEMATIC_CP'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/vmtoolsd-guest-agent
  bootloader: sd-boot
EOF_SCHEMATIC_CP
  fi

  if [[ ! -f "${project_abs}/schematic.worker.yaml" ]]; then
    cat > "${project_abs}/schematic.worker.yaml" <<'EOF_SCHEMATIC_WORKER'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/vmtoolsd-guest-agent
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
  bootloader: sd-boot
EOF_SCHEMATIC_WORKER
  fi

  if [[ ! -f "${project_abs}/vars.sh" ]]; then
    cat > "${project_abs}/vars.sh" <<EOF_VARS
#!/usr/bin/env bash
set -euo pipefail

# Generated by cluster.sh create-project
PROJECT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
: "\${TALOS_TOOLCHAIN_DIR:?Set TALOS_TOOLCHAIN_DIR to the talos-toolchain checkout.}"
BASE_VARS="\${TALOS_TOOLCHAIN_DIR}/scripts/talos/vars.sh"

if [[ ! -f "\${BASE_VARS}" ]]; then
  echo "[ERROR] Missing base vars file: \${BASE_VARS}" >&2
  return 1 2>/dev/null || exit 1
fi

# shellcheck source=/dev/null
source "\${BASE_VARS}"

export TALOS_CLUSTER_NAME="${cluster_name}"

# vSphere target (required for provision)
export VSPHERE_ENDPOINT="192.168.0.233"
export VSPHERE_USERNAME="root"
export VSPHERE_PASSWORD="CHANGE_ME"
export VSPHERE_INSECURE_CONNECTION="true"
export VSPHERE_DATASTORE="DATASTORE_02"
export VSPHERE_NETWORK="VM Network"
export VSPHERE_FOLDER=""
export VSPHERE_RESOURCE_POOL=""

# SSH user defaults (controller -> helper VMs such as HAProxy/DNS)
export BUILD_USERNAME="vagrant"
export SSH_USER="vagrant"
export ANSIBLE_USER="\${ANSIBLE_USER:-\${SSH_USER}}"
export ANSIBLE_USERNAME="\${ANSIBLE_USERNAME:-\${SSH_USER}}"
export SSH_PORT="22"
export HAPROXY_SSH_USER="\${HAPROXY_SSH_USER:-\${SSH_USER}}"

# Talos access endpoint
export HAPROXY_VIP="192.168.0.30"
export HAPROXY_NODE_1_NAME="talos-lb-1"
export HAPROXY_NODE_1_IP="192.168.0.31"
export HAPROXY_NODE_2_NAME="talos-lb-2"
export HAPROXY_NODE_2_IP="192.168.0.32"
export TALOS_LOAD_BALANCER_RECONCILE_SCRIPT=""
export TALOS_CLUSTER_ENDPOINT="https://\${HAPROXY_VIP}:6443"

# Talos image source (choose one primary strategy)
export TALOS_OVA_PATH="https://factory.talos.dev/image/<schematic-id>/v1.12.4/vmware-amd64.ova"
export TALOS_ISO_DATASTORE_PATH="ISOs/talos-v1.12.4-uefi.iso"
# Optional local ISO used for automatic datastore upload in ISO mode
export TALOS_ISO_LOCAL_PATH=""

# Cluster topology
export TALOS_CONTROL_PLANE_COUNT="3"
export TALOS_WORKER_COUNT="3"
export TALOS_CONTROL_PLANE_IPS='["192.168.0.61","192.168.0.62","192.168.0.63"]'
export TALOS_WORKER_IPS='["192.168.0.71","192.168.0.72","192.168.0.73"]'
export TALOS_CONTROL_PLANE_NAME_PREFIX="\${TALOS_CLUSTER_NAME}-cp"
export TALOS_WORKER_NAME_PREFIX="\${TALOS_CLUSTER_NAME}-worker"

# Node resources
export TALOS_CONTROL_PLANE_CPU="2"
export TALOS_CONTROL_PLANE_MEMORY_MB="4096"
export TALOS_CONTROL_PLANE_DISK_GB="20"
export TALOS_CONTROL_PLANE_EXTRA_DISK_GB="40"
export TALOS_WORKER_CPU="2"
export TALOS_WORKER_MEMORY_MB="4096"
export TALOS_WORKER_DISK_GB="40"
export TALOS_WORKER_EXTRA_DISK_GB="40"

# Networking
export TALOS_GATEWAY="192.168.0.2"
export TALOS_NETMASK_PREFIX="24"
export TALOS_NODE_INTERFACE="eth0"
# Keep false when using external LB (HAProxy/keepalived VIP).
# Enable only if you intentionally run Talos CP interface VIP with a distinct IP.
export TALOS_CONTROL_PLANE_VIP_ENABLED="false"
export TALOS_CONTROL_PLANE_VIP="\${HAPROXY_VIP}"
export TALOS_NAMESERVERS='["1.1.1.1","8.8.8.8"]'

# CNI baseline
export TALOS_DISABLE_DEFAULT_CNI="true"
export TALOS_CLUSTER_BASELINE_ADDONS='["cilium"]'
export TALOS_POST_BOOTSTRAP_HELM_AUTO_PREPARE="true"
export TALOS_POST_BOOTSTRAP_HELM_SOURCE_MODE="path"
export TALOS_POST_BOOTSTRAP_HELM_SOURCE_PATH=""
export TALOS_POST_BOOTSTRAP_HELM_SOURCE_URL=""
export TALOS_POST_BOOTSTRAP_HELM_OVERWRITE="true"
export TALOS_DNS_SYNC_REQUIRED="false"
export TALOS_DNS_REGISTER_SCRIPT=""
export TALOS_DNS_UNREGISTER_SCRIPT=""

# Generated artifacts and machine configs
export TALOS_CONTROL_PLANE_CONFIG_PATH="\${PROJECT_DIR}/generated/controlplane.yaml"
export TALOS_WORKER_CONFIG_PATH="\${PROJECT_DIR}/generated/worker.yaml"

EOF_VARS
    chmod +x "${project_abs}/vars.sh"
  fi

  if [[ ! -f "${project_abs}/vars.local.example.sh" ]]; then
    cat > "${project_abs}/vars.local.example.sh" <<'EOF_LOCAL'
#!/usr/bin/env bash
# Copy to vars.local.sh and customize sensitive values.

export VSPHERE_ENDPOINT="192.168.0.233"
export VSPHERE_USERNAME="root"
export VSPHERE_PASSWORD="CHANGE_ME"
export VSPHERE_DATASTORE="DATASTORE_02"
export VSPHERE_NETWORK="VM Network"
export VSPHERE_FOLDER=""
export VSPHERE_RESOURCE_POOL=""
export SSH_USER="vagrant"
export HAPROXY_SSH_USER="vagrant"
export TALOS_NAMESERVERS='["192.168.0.53"]'
export TALOS_LOAD_BALANCER_RECONCILE_SCRIPT=""
export TALOS_DNS_SYNC_REQUIRED="false"
export TALOS_DNS_REGISTER_SCRIPT=""
export TALOS_DNS_UNREGISTER_SCRIPT=""
EOF_LOCAL
  fi

  if [[ ! -f "${project_abs}/.gitignore" ]]; then
    cat > "${project_abs}/.gitignore" <<'EOF_IGNORE'
vars.local.sh
generated/*
!generated/.gitkeep
EOF_IGNORE
  fi

  if [[ ! -f "${project_abs}/generated/.gitkeep" ]]; then
    : > "${project_abs}/generated/.gitkeep"
  fi

  if [[ ! -f "${project_abs}/cluster-spec.yaml" ]]; then
    cat > "${project_abs}/cluster-spec.yaml" <<EOF_SPEC
apiVersion: platform.labs/v1alpha1
kind: TalosClusterSpec
metadata:
  name: ${cluster_name}
spec:
  sourceOfTruth:
    varsFile: ${project_abs}/vars.sh
    localVarsFile: ${project_abs}/vars.local.sh
  workflow:
    generate: "cluster.sh generate --project-dir=${project_abs}"
    provision: "cluster.sh provision --project-dir=${project_abs}"
    prepareBootstrap: "cluster.sh prepare-bootstrap --project-dir=${project_abs}"
    applyConfig: "cluster.sh apply-config --project-dir=${project_abs}"
    bootstrap: "cluster.sh bootstrap --project-dir=${project_abs}"
    syncAccess: "cluster.sh sync-access --project-dir=${project_abs}"
    postBootstrap: "cluster.sh apply-post-bootstrap --project-dir=${project_abs}"
EOF_SPEC
  fi

  if [[ ! -f "${project_abs}/README.md" ]]; then
    cat > "${project_abs}/README.md" <<EOF_README
# ${cluster_name}

This project was generated by:

\`\`\`bash
cluster.sh create-project --project-dir=${project_abs}
\`\`\`

## Quick Flow

1. Review the committed baseline in \`vars.sh\`.
2. Create \`vars.local.sh\` from \`vars.local.example.sh\` for local or sensitive overrides.
3. (Optional) Refresh Talos images from schematics if you changed schematic files:

\`\`\`bash
cluster.sh refresh-schematics --project-dir=${project_abs} --talos-version=v1.12.4
\`\`\`

4. Execute:

\`\`\`bash
cluster.sh generate --project-dir=${project_abs}
cluster.sh provision --project-dir=${project_abs}
cluster.sh prepare-bootstrap --project-dir=${project_abs}
cluster.sh apply-config --project-dir=${project_abs}
cluster.sh bootstrap --project-dir=${project_abs}
cluster.sh sync-access --project-dir=${project_abs}
cluster.sh apply-post-bootstrap --project-dir=${project_abs}
\`\`\`
EOF_README
  fi

  log_info "Project scaffold created: ${project_abs}"
}

main() {
  local -a cmd=()
  local project_vars_file=""
  local project_local_vars_file=""
  local project_abs=""
  local project_name=""

  parse_args "$@"

  if [[ -n "${PROJECT_DIR}" ]]; then
    if [[ "${PROJECT_DIR}" = /* ]]; then
      project_abs="${PROJECT_DIR}"
    else
      project_abs="${REPO_ROOT}/${PROJECT_DIR}"
    fi

    project_vars_file="${project_abs}/vars.sh"
    project_local_vars_file="${project_abs}/vars.local.sh"
    [[ -z "${VARS_FILE}" ]] && VARS_FILE="${project_vars_file}"
    [[ -z "${LOCAL_VARS_FILE}" ]] && LOCAL_VARS_FILE="${project_local_vars_file}"
    [[ -z "${CLUSTER_NAME}" ]] && CLUSTER_NAME="$(basename "${project_abs}")"
    [[ -z "${GENERATED_DIR}" ]] && GENERATED_DIR="${project_abs}/generated"
  fi

  if [[ "${ACTION}" != "create-project" && -z "${VARS_FILE}" ]]; then
    die "Missing vars source. Use --project-dir=<path> or --vars-file=<path>."
  fi

  if [[ -n "${VARS_FILE}" ]]; then
    export OVERLAY_VARS_FILE="${VARS_FILE}"
  fi
  if [[ -n "${LOCAL_VARS_FILE}" ]]; then
    export OVERLAY_LOCAL_VARS_FILE="${LOCAL_VARS_FILE}"
  fi

  if [[ "${ACTION}" != "create-project" ]]; then
    [[ -f "${VARS_FILE}" ]] || die "Vars file not found: ${VARS_FILE}"
    # shellcheck disable=SC1090
    source "${VARS_FILE}"
    if [[ -n "${LOCAL_VARS_FILE}" && -f "${LOCAL_VARS_FILE}" ]]; then
      # shellcheck disable=SC1090
      source "${LOCAL_VARS_FILE}"
    fi
  fi

  case "${ACTION}" in
    create-project)
      [[ -n "${PROJECT_DIR}" ]] || die "--project-dir is required for create-project."
      project_name="${CLUSTER_NAME:-$(basename "${project_abs}")}"
      create_project_scaffold "${PROJECT_DIR}" "${project_name}"
      if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] Would initialize Factory image IDs via refresh-schematics."
      else
        # Initialize project with concrete Factory IDs (cp + worker) and OVA URL.
        VARS_FILE="${project_abs}/vars.sh"
        [[ -f "${VARS_FILE}" ]] || die "Expected vars.sh after create-project: ${VARS_FILE}"
        refresh_schematics "${VARS_FILE}" "${project_abs}"
      fi
      return 0
      ;;
    refresh-schematics)
      refresh_schematics "${VARS_FILE}" "${project_abs}"
      return 0
      ;;
    generate)
      cmd=("${SCRIPT_DIR}/cluster-bootstrap.sh" "--env=lab" "--mode=generate")
      [[ -n "${CLUSTER_NAME}" ]] && cmd+=("--cluster-name=${CLUSTER_NAME}")
      [[ -n "${GENERATED_DIR}" ]] && cmd+=("--generated-dir=${GENERATED_DIR}")
      [[ "${FORCE_GENERATE}" == "true" ]] && cmd+=("--force-generate")
      [[ "${DRY_RUN}" == "true" ]] && cmd+=("--dry-run")
      ;;
    provision)
      cmd=("${SCRIPT_DIR}/provision-cluster.sh" "--env=lab" "create")
      [[ -n "${WORKER_COUNT}" ]] && cmd+=("--worker-count=${WORKER_COUNT}")
      [[ "${DRY_RUN}" == "true" ]] && cmd+=("--dry-run")
      ;;
    prepare-bootstrap)
      cmd=("${SCRIPT_DIR}/cluster-bootstrap.sh" "--env=lab" "--mode=apply" "--apply-stage=pre")
      [[ -n "${CLUSTER_NAME}" ]] && cmd+=("--cluster-name=${CLUSTER_NAME}")
      [[ -n "${GENERATED_DIR}" ]] && cmd+=("--generated-dir=${GENERATED_DIR}")
      [[ "${DRY_RUN}" == "true" ]] && cmd+=("--dry-run")
      ;;
    apply-config)
      cmd=("${SCRIPT_DIR}/cluster-bootstrap.sh" "--env=lab" "--mode=apply")
      [[ -n "${CLUSTER_NAME}" ]] && cmd+=("--cluster-name=${CLUSTER_NAME}")
      [[ -n "${GENERATED_DIR}" ]] && cmd+=("--generated-dir=${GENERATED_DIR}")
      [[ "${DRY_RUN}" == "true" ]] && cmd+=("--dry-run")
      ;;
    bootstrap)
      cmd=("${SCRIPT_DIR}/cluster-bootstrap.sh" "--env=lab" "--mode=bootstrap")
      [[ -n "${CLUSTER_NAME}" ]] && cmd+=("--cluster-name=${CLUSTER_NAME}")
      [[ -n "${GENERATED_DIR}" ]] && cmd+=("--generated-dir=${GENERATED_DIR}")
      [[ "${DRY_RUN}" == "true" ]] && cmd+=("--dry-run")
      ;;
    sync-access)
      [[ -n "${project_abs}" ]] || die "--project-dir is required for sync-access."
      cmd=("${SCRIPT_DIR}/sync-kubectl.sh" "--env=lab" "--source=${project_abs}/generated/kubeconfig")
      [[ -n "${CLUSTER_NAME}" ]] && cmd+=("--cluster-name=${CLUSTER_NAME}")
      [[ "${DRY_RUN}" == "true" ]] && cmd+=("--dry-run")
      run_or_echo "${cmd[@]}"
      cmd=("${SCRIPT_DIR}/sync-talosctl.sh" "--env=lab" "--source=${project_abs}/generated/talosconfig")
      [[ -n "${CLUSTER_NAME}" ]] && cmd+=("--cluster-name=${CLUSTER_NAME}")
      [[ "${DRY_RUN}" == "true" ]] && cmd+=("--dry-run")
      ;;
    apply-post-bootstrap)
      [[ -n "${PROJECT_DIR}" ]] || die "--project-dir is required for apply-post-bootstrap."
      cmd=("${SCRIPT_DIR}/apply-post-bootstrap.sh" "--project-dir=${project_abs}")
      [[ -n "${CLUSTER_NAME}" ]] && cmd+=("--cluster-name=${CLUSTER_NAME}")
      [[ -n "${ADDONS_LIST}" ]] && cmd+=("--addons=${ADDONS_LIST}")
      [[ "${DRY_RUN}" == "true" ]] && cmd+=("--dry-run")
      ;;
  esac

  run_or_echo "${cmd[@]}"
}

main "$@"
