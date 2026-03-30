#!/usr/bin/env bash
# @file cluster.sh
# @brief Day-1 Talos cluster lifecycle entrypoint.
# @description
#   Project-oriented day-1 CLI for Talos clusters. This toolchain entrypoint is
#   environment-agnostic and executes day-1 actions from explicit project vars.
#
# @arg create-project action Create cluster project scaffold.
# @arg refresh-schematics action Generate schematic IDs and update image vars.
# @arg generate action Execute configured day-1 generate command.
# @arg provision action Execute configured day-1 provision command.
# @arg prepare-bootstrap action Execute configured day-1 prepare-bootstrap command.
# @arg bootstrap action Execute configured day-1 bootstrap command.
# @arg apply-config action Execute configured day-1 apply-config command.
# @arg sync-access action Execute configured day-1 sync-access command.
# @arg apply-post-bootstrap action Install mandatory day-1 baseline addons.
#
# @arg --project-dir path Cluster project directory.
# @arg --cluster-name name Cluster name override.
# @arg --talos-version version Talos version for image tags.
# @arg --cp-schematic-file path Control-plane schematic file path.
# @arg --worker-schematic-file path Worker schematic file path.
# @arg --addons list Baseline addon list override for apply-post-bootstrap.
# @arg --manifest-root-dir path Manifest root dir override for apply-post-bootstrap.
# @arg --kube-context name Kube context override for apply-post-bootstrap.
# @flag --no-update-ova Do not rewrite TALOS_OVA_PATH during refresh.
# @flag --dry-run,-n Print actions without executing.
# @flag --help,-h Show usage information.
# @example
#   ./scripts/talos/cluster.sh create-project --project-dir=./clusters/talos-dev
# @example
#   ./scripts/talos/cluster.sh generate --project-dir=./clusters/talos-dev
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

ACTION=""
PROJECT_DIR=""
CLUSTER_NAME=""
TALOS_VERSION=""
CP_SCHEMATIC_FILE=""
WORKER_SCHEMATIC_FILE=""
ADDONS_LIST=""
MANIFEST_ROOT_DIR=""
KUBE_CONTEXT=""
UPDATE_OVA_FROM_SCHEMATIC="true"
DRY_RUN="false"

usage() {
  cat <<'EOF_USAGE'
Usage: cluster.sh <action> [options]

Actions:
  create-project        Create cluster project scaffold
  refresh-schematics    Generate schematic IDs and refresh image vars in vars.sh
  generate              Execute configured day-1 generate command
  provision             Execute configured day-1 provision command
  prepare-bootstrap     Execute configured day-1 prepare-bootstrap command
  bootstrap             Execute configured day-1 bootstrap command
  apply-config          Execute configured day-1 apply-config command
  sync-access           Execute configured day-1 sync-access command
  apply-post-bootstrap  Install mandatory day-1 baseline addons

Options:
  --project-dir=<path>           Cluster project directory (required)
  --cluster-name=<name>          Cluster name override
  --talos-version=<version>      Talos version for image tags (example: v1.12.4)
  --cp-schematic-file=<path>     CP schematic file path (default: <project>/schematic.cp.yaml)
  --worker-schematic-file=<path> Worker schematic file path (default: <project>/schematic.worker.yaml, fallback schematic.yaml)
  --addons=<list>                Baseline addon list override for apply-post-bootstrap
  --manifest-root-dir=<path>     Manifest root dir override for apply-post-bootstrap
  --kube-context=<name>          Kube context override for apply-post-bootstrap
  --no-update-ova                Do not rewrite TALOS_OVA_PATH during refresh-schematics
  -n, --dry-run                  Print actions without executing
  -h, --help                     Show help

Examples:
  # Create a new project scaffold
  cluster.sh create-project --project-dir=./clusters/talos-dev

  # Execute configured day-1 generate step
  cluster.sh generate --project-dir=./clusters/talos-dev

  # Apply day-1 baseline addons (cilium required)
  cluster.sh apply-post-bootstrap --project-dir=./clusters/talos-dev --addons='["cilium","longhorn"]'
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      create-project|refresh-schematics|generate|provision|prepare-bootstrap|bootstrap|apply-config|sync-access|apply-post-bootstrap)
        [[ -z "${ACTION}" ]] || die "Action already set: ${ACTION}"
        ACTION="$1"
        shift
        ;;
      --project-dir=*) PROJECT_DIR="${1#*=}"; shift ;;
      --cluster-name=*) CLUSTER_NAME="${1#*=}"; shift ;;
      --talos-version=*) TALOS_VERSION="${1#*=}"; shift ;;
      --cp-schematic-file=*) CP_SCHEMATIC_FILE="${1#*=}"; shift ;;
      --worker-schematic-file=*) WORKER_SCHEMATIC_FILE="${1#*=}"; shift ;;
      --addons=*) ADDONS_LIST="${1#*=}"; shift ;;
      --manifest-root-dir=*) MANIFEST_ROOT_DIR="${1#*=}"; shift ;;
      --kube-context=*) KUBE_CONTEXT="${1#*=}"; shift ;;
      --no-update-ova) UPDATE_OVA_FROM_SCHEMATIC="false"; shift ;;
      -n|--dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      --env=*|--env)
        die "--env is not supported in talos-toolchain. Use --project-dir."
        ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "${ACTION}" ]] || { usage; die "Action is required."; }
}

resolve_abs_path() {
  local path_value="$1"
  if [[ "${path_value}" = /* ]]; then
    printf '%s\n' "${path_value}"
  else
    printf '%s\n' "${PWD}/${path_value}"
  fi
}

run_or_echo_cmd() {
  local command="$1"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] ${command}"
    return 0
  fi
  bash -lc "${command}"
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

post_schematic_and_get_id() {
  local schematic_file="$1"
  local response=""
  local schematic_id=""

  [[ -f "${schematic_file}" ]] || die "Schematic file not found: ${schematic_file}"
  command -v curl >/dev/null 2>&1 || die "curl is required for refresh-schematics."

  if [[ "${DRY_RUN}" == "true" ]]; then
    printf '[INFO] [DRY-RUN] POST schematic: %s -> https://factory.talos.dev/schematics\n' "${schematic_file}" >&2
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
        if (!done) print "export " k "=\"" v "\""
      }
    ' "${file}" > "${tmp_file}"
  else
    cat "${file}" > "${tmp_file}"
    printf '\nexport %s="%s"\n' "${key}" "${escaped_value}" >> "${tmp_file}"
  fi

  mv "${tmp_file}" "${file}"
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
  local -a arr=()
  read -r -a arr <<<"${csv}"
  printf '%s\n' "${arr[@]}"
}

in_array() {
  local needle="$1"
  shift
  local item=""
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

load_project_vars() {
  local project_abs="$1"
  local vars_file="${project_abs}/vars.sh"
  local local_vars_file="${project_abs}/vars.local.sh"

  require_file "${vars_file}"
  # shellcheck disable=SC1090
  source "${vars_file}"
  if [[ -f "${local_vars_file}" ]]; then
    # shellcheck disable=SC1090
    source "${local_vars_file}"
  fi
}

create_project_scaffold() {
  local project_abs="$1"
  local cluster_name="$2"

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

# Generated by talos-toolchain cluster.sh create-project
PROJECT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

export TALOS_CLUSTER_NAME="${cluster_name}"
export TALOS_CLUSTER_ENDPOINT="https://192.168.0.30:6443"

# Network defaults
export TALOS_GATEWAY="192.168.0.2"
export TALOS_NETMASK_PREFIX="24"
export TALOS_NODE_INTERFACE="eth0"
export TALOS_NAMESERVERS='["1.1.1.1","8.8.8.8"]'

# Topology defaults
export TALOS_CONTROL_PLANE_COUNT="3"
export TALOS_WORKER_COUNT="3"
export TALOS_CONTROL_PLANE_IPS='["192.168.0.61","192.168.0.62","192.168.0.63"]'
export TALOS_WORKER_IPS='["192.168.0.71","192.168.0.72","192.168.0.73"]'
export TALOS_CONTROL_PLANE_NAME_PREFIX="\${TALOS_CLUSTER_NAME}-cp"
export TALOS_WORKER_NAME_PREFIX="\${TALOS_CLUSTER_NAME}-worker"

# Images (refresh-schematics will set installer image IDs)
export TALOS_OVA_PATH="https://factory.talos.dev/image/<schematic-id>/v1.12.4/vmware-amd64.ova"
export TALOS_CONTROL_PLANE_INSTALLER_IMAGE=""
export TALOS_WORKER_INSTALLER_IMAGE=""

# Day-1 action commands (must be set by your environment integration)
export TALOS_DAY1_GENERATE_CMD=""
export TALOS_DAY1_PROVISION_CMD=""
export TALOS_DAY1_PREPARE_BOOTSTRAP_CMD=""
export TALOS_DAY1_APPLY_CONFIG_CMD=""
export TALOS_DAY1_BOOTSTRAP_CMD=""
export TALOS_DAY1_SYNC_ACCESS_CMD=""

# Day-1 baseline addons
export TALOS_CLUSTER_BASELINE_ADDONS='["cilium"]'
export TALOS_DAY1_REQUIRE_CILIUM="true"
export TALOS_DAY1_MANIFEST_ROOT_DIR=""
export TALOS_DAY1_KUBE_CONTEXT=""
EOF_VARS
    chmod +x "${project_abs}/vars.sh"
  fi

  if [[ ! -f "${project_abs}/vars.local.example.sh" ]]; then
    cat > "${project_abs}/vars.local.example.sh" <<'EOF_LOCAL'
#!/usr/bin/env bash
# Copy to vars.local.sh and customize local/sensitive values.
#
# Example:
# export TALOS_DAY1_GENERATE_CMD="talos-cluster generate --project-dir=..."
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

## Required Configuration

1. Fill \`vars.sh\` and optionally \`vars.local.sh\`.
2. Set required day-1 command adapters:
   - \`TALOS_DAY1_GENERATE_CMD\`
   - \`TALOS_DAY1_PROVISION_CMD\`
   - \`TALOS_DAY1_PREPARE_BOOTSTRAP_CMD\`
   - \`TALOS_DAY1_APPLY_CONFIG_CMD\`
   - \`TALOS_DAY1_BOOTSTRAP_CMD\`
   - \`TALOS_DAY1_SYNC_ACCESS_CMD\`
3. Set post-bootstrap baseline inputs:
   - \`TALOS_DAY1_MANIFEST_ROOT_DIR\`
   - \`TALOS_DAY1_KUBE_CONTEXT\`
   - \`TALOS_CLUSTER_BASELINE_ADDONS\`
4. See variable reference in talos-toolchain repository:
   - \`docs/en/day1-project-vars.md\`
   - \`docs/pt-br/day1-project-vars.md\`
5. Refresh schematics:

\`\`\`bash
cluster.sh refresh-schematics --project-dir=${project_abs} --talos-version=v1.12.4
\`\`\`
EOF_README
  fi

  log_info "Project scaffold created: ${project_abs}"
}

refresh_schematics() {
  local project_abs="$1"
  local vars_file="${project_abs}/vars.sh"
  local cp_file=""
  local worker_file=""
  local cp_id=""
  local worker_id=""
  local version=""
  local cp_image=""
  local worker_image=""
  local ova_url=""

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

resolve_action_command_var() {
  local action="$1"
  case "${action}" in
    generate) printf '%s|%s\n' "TALOS_DAY1_GENERATE_CMD" "${TALOS_DAY1_GENERATE_CMD:-}" ;;
    provision) printf '%s|%s\n' "TALOS_DAY1_PROVISION_CMD" "${TALOS_DAY1_PROVISION_CMD:-}" ;;
    prepare-bootstrap) printf '%s|%s\n' "TALOS_DAY1_PREPARE_BOOTSTRAP_CMD" "${TALOS_DAY1_PREPARE_BOOTSTRAP_CMD:-}" ;;
    apply-config) printf '%s|%s\n' "TALOS_DAY1_APPLY_CONFIG_CMD" "${TALOS_DAY1_APPLY_CONFIG_CMD:-}" ;;
    bootstrap) printf '%s|%s\n' "TALOS_DAY1_BOOTSTRAP_CMD" "${TALOS_DAY1_BOOTSTRAP_CMD:-}" ;;
    sync-access) printf '%s|%s\n' "TALOS_DAY1_SYNC_ACCESS_CMD" "${TALOS_DAY1_SYNC_ACCESS_CMD:-}" ;;
    *) die "Unsupported mapped action: ${action}" ;;
  esac
}

run_mapped_day1_action() {
  local action="$1"
  local mapping=""
  local var_name=""
  local command=""
  mapping="$(resolve_action_command_var "${action}")"
  var_name="${mapping%%|*}"
  command="${mapping#*|}"
  [[ -n "${command}" ]] || die "Missing command mapping for '${action}'. Set ${var_name} in project vars."
  run_or_echo_cmd "${command}"
}

apply_post_bootstrap() {
  local project_abs="$1"
  local manifest_root=""
  local kube_ctx=""
  local require_cilium=""
  local raw_addons=""
  local addons_csv=""
  local addon=""
  local -a addons=()

  manifest_root="${MANIFEST_ROOT_DIR:-${TALOS_DAY1_MANIFEST_ROOT_DIR:-}}"
  kube_ctx="${KUBE_CONTEXT:-${TALOS_DAY1_KUBE_CONTEXT:-}}"
  require_cilium="${TALOS_DAY1_REQUIRE_CILIUM:-true}"
  raw_addons="${ADDONS_LIST:-${TALOS_CLUSTER_BASELINE_ADDONS:-[\"cilium\"]}}"

  [[ -n "${manifest_root}" ]] || die "Missing manifest root. Set --manifest-root-dir or TALOS_DAY1_MANIFEST_ROOT_DIR."
  [[ -n "${kube_ctx}" ]] || die "Missing kube context. Set --kube-context or TALOS_DAY1_KUBE_CONTEXT."

  addons_csv="$(normalize_csv_list "${raw_addons}")"
  mapfile -t addons < <(csv_to_array "${addons_csv}")
  (( ${#addons[@]} > 0 )) || die "No addons resolved for apply-post-bootstrap."

  if [[ "${require_cilium}" == "true" ]] && ! in_array "cilium" "${addons[@]}"; then
    die "Cilium is mandatory for day-1 baseline. Include 'cilium' in addons."
  fi

  # Force deterministic ordering: cilium first, then remaining in provided order.
  if in_array "cilium" "${addons[@]}"; then
    run_or_echo_cmd "${SCRIPT_DIR}/talos-gitops.sh install-addon --allow-system-addon --addon=cilium --kube-context=${kube_ctx} --manifest-root-dir=${manifest_root}"
  fi
  for addon in "${addons[@]}"; do
    [[ "${addon}" == "cilium" ]] && continue
    run_or_echo_cmd "${SCRIPT_DIR}/talos-gitops.sh install-addon --addon=${addon} --kube-context=${kube_ctx} --manifest-root-dir=${manifest_root}"
  done

  log_info "Day-1 post-bootstrap baseline completed."
}

main() {
  local project_abs=""
  local project_name=""

  parse_args "$@"
  [[ -n "${PROJECT_DIR}" ]] || die "--project-dir is required."
  project_abs="$(resolve_abs_path "${PROJECT_DIR}")"
  project_name="${CLUSTER_NAME:-$(basename "${project_abs}")}"

  case "${ACTION}" in
    create-project)
      create_project_scaffold "${project_abs}" "${project_name}"
      ;;
    refresh-schematics)
      refresh_schematics "${project_abs}"
      ;;
    generate|provision|prepare-bootstrap|bootstrap|apply-config|sync-access)
      load_project_vars "${project_abs}"
      run_mapped_day1_action "${ACTION}"
      ;;
    apply-post-bootstrap)
      load_project_vars "${project_abs}"
      apply_post_bootstrap "${project_abs}"
      ;;
  esac
}

main "$@"
