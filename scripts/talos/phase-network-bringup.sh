#!/usr/bin/env bash
# @file phase-network-bringup.sh
# @brief Phase 2 Helm-based addon bring-up for Talos clusters.
# @description
#   Renders, validates, and installs one addon from project helm manifests.
#   Supports render-only mode and post-install validations for cluster checks.
#
# @arg --project-dir path Cluster project directory (required).
# @arg --vars-file path Optional vars file override.
# @arg --local-vars-file path Optional local vars override.
# @arg --cluster-name name Cluster name override.
# @arg --addon name Addon name under helm/ (default: cilium).
# @arg --kubeconfig path Kubeconfig path override.
# @arg --cilium-rollout-timeout duration Cilium rollout timeout when cilium CLI is unavailable.
# @flag --render-only Render and validate only, skip install.
# @flag --dry-run,-n Print actions without executing.
# @flag --help,-h Show usage information.
#
# @example
#   # Bring up Cilium from project manifests
#   ./phase-network-bringup.sh --project-dir=./clusters/talos-dev --addon=cilium
#
# @example
#   # Install Longhorn from project manifests
#   ./phase-network-bringup.sh --project-dir=./clusters/talos-dev --addon=longhorn
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/talos/lib/common.sh"

PROJECT_DIR=""
VARS_FILE=""
LOCAL_VARS_FILE=""
CLUSTER_NAME=""
ADDON_NAME="cilium"
DRY_RUN="false"
RENDER_ONLY="false"
KUBECONFIG_PATH=""
CILIUM_ROLLOUT_TIMEOUT="300s"

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Phase 2: Network Bring-up (Helm)
  1) helm template (required)
  2) kubectl apply --dry-run=server on rendered manifest (required)
  3) helm upgrade --install (unless --render-only)
  4) post-install validations

Options:
  --project-dir=<path>           Cluster project dir (required)
  --vars-file=<path>             Optional vars override (default: <project>/vars.sh)
  --local-vars-file=<path>       Optional local vars override (default: <project>/vars.local.sh)
  --cluster-name=<name>          Cluster name override
  --addon=<name>                 Addon name under helm/ (default: cilium)
  --kubeconfig=<path>            Kubeconfig path (default: <project>/generated/kubeconfig)
  --cilium-rollout-timeout=<dur> Timeout for Cilium rollout wait when cilium CLI is unavailable (default: 300s)
  --render-only                  Stop before helm upgrade --install
  -n, --dry-run                  Print actions without executing
  -h, --help                     Show help

Examples:
  # Bring up Cilium from project manifests
  $(basename "$0") --project-dir=./clusters/talos-dev --addon=cilium

  # Bring up Longhorn from project manifests
  $(basename "$0") --project-dir=./clusters/talos-dev --addon=longhorn

  # Validate rendered addon resources without installing
  $(basename "$0") --project-dir=./clusters/talos-dev --addon=prometheus-stack --render-only
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-dir=*) PROJECT_DIR="${1#*=}"; shift ;;
      --vars-file=*) VARS_FILE="${1#*=}"; shift ;;
      --local-vars-file=*) LOCAL_VARS_FILE="${1#*=}"; shift ;;
      --cluster-name=*) CLUSTER_NAME="${1#*=}"; shift ;;
      --addon=*) ADDON_NAME="${1#*=}"; shift ;;
      --kubeconfig=*) KUBECONFIG_PATH="${1#*=}"; shift ;;
      --cilium-rollout-timeout=*) CILIUM_ROLLOUT_TIMEOUT="${1#*=}"; shift ;;
      --render-only) RENDER_ONLY="true"; shift ;;
      -n|--dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      --env=*|--env) die "--env was removed. Use --project-dir." ;;
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

read_release_field() {
  local file_path="$1"
  local field_name="$2"
  awk -F': ' -v key="${field_name}" '$1==key {print $2; exit}' "${file_path}" | sed -e 's/^"//' -e 's/"$//'
}

resolve_values_file_path() {
  local release_file="$1"
  local addon_dir="$2"
  local values_raw="$3"
  local candidate=""
  local fallback_basename=""

  [[ -n "${values_raw}" ]] || return 1

  # 1) Absolute path
  if [[ "${values_raw}" = /* && -f "${values_raw}" ]]; then
    printf '%s\n' "${values_raw}"
    return 0
  fi

  # 2) Repo-root relative path
  candidate="$(resolve_repo_path "${values_raw}")"
  if [[ -f "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  # 3) Release-dir relative (supports "values.yaml" style)
  if [[ -f "${addon_dir}/${values_raw}" ]]; then
    printf '%s\n' "${addon_dir}/${values_raw}"
    return 0
  fi

  # 4) Basename fallback for synced manifests from external repos
  fallback_basename="$(basename "${values_raw}")"
  if [[ -f "${addon_dir}/${fallback_basename}" ]]; then
    printf '%s\n' "${addon_dir}/${fallback_basename}"
    return 0
  fi

  return 1
}

run_or_echo() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

collect_cilium_secret_namespaces() {
  local values_path="$1"
  awk '
    /^\s*secretsNamespace:\s*$/ { in_block=1; next }
    in_block && /^\s*name:\s*/ {
      ns=$0
      sub(/^[[:space:]]*name:[[:space:]]*/, "", ns)
      gsub(/"/, "", ns)
      if (ns != "") print ns
      in_block=0
      next
    }
    in_block && /^[^[:space:]]/ { in_block=0 }
  ' "${values_path}" | sort -u
}

ensure_namespace() {
  local kubeconfig_file="$1"
  local namespace="$2"
  [[ -n "${namespace}" ]] || return 0
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] KUBECONFIG=${kubeconfig_file} kubectl create namespace ${namespace} --dry-run=client -o yaml | kubectl apply -f -"
    return 0
  fi
  KUBECONFIG="${kubeconfig_file}" kubectl get namespace "${namespace}" >/dev/null 2>&1 || \
    KUBECONFIG="${kubeconfig_file}" kubectl create namespace "${namespace}" >/dev/null
}

label_namespace_security() {
  local kubeconfig_file="$1"
  local namespace="$2"
  local enforce_level="$3"
  local audit_level="$4"
  local warn_level="$5"

  [[ -n "${namespace}" ]] || return 0
  if [[ -z "${enforce_level}" && -z "${audit_level}" && -z "${warn_level}" ]]; then
    return 0
  fi

  local -a cmd=(kubectl label namespace "${namespace}" --overwrite)
  [[ -n "${enforce_level}" ]] && cmd+=("pod-security.kubernetes.io/enforce=${enforce_level}")
  [[ -n "${audit_level}" ]] && cmd+=("pod-security.kubernetes.io/audit=${audit_level}")
  [[ -n "${warn_level}" ]] && cmd+=("pod-security.kubernetes.io/warn=${warn_level}")

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] KUBECONFIG=${kubeconfig_file} ${cmd[*]}"
    return 0
  fi

  KUBECONFIG="${kubeconfig_file}" "${cmd[@]}" >/dev/null
}

namespace_exists() {
  local kubeconfig_file="$1"
  local namespace="$2"
  KUBECONFIG="${kubeconfig_file}" kubectl get namespace "${namespace}" >/dev/null 2>&1
}

delete_namespace() {
  local kubeconfig_file="$1"
  local namespace="$2"
  [[ -n "${namespace}" ]] || return 0
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] KUBECONFIG=${kubeconfig_file} kubectl delete namespace ${namespace}"
    return 0
  fi
  KUBECONFIG="${kubeconfig_file}" kubectl delete namespace "${namespace}" --wait=true >/dev/null
}

main() {
  local project_dir_abs=""
  local vars_file=""
  local local_vars_file=""
  local cluster_dir=""
  local helm_dir=""
  local addon_dir=""
  local release_file=""
  local render_dir=""
  local render_file=""
  local release_name=""
  local namespace=""
  local chart=""
  local version=""
  local values_file=""
  local validation_selector=""
  local kubeconfig_file=""
  local namespace_label_enforce=""
  local namespace_label_audit=""
  local namespace_label_warn=""
  local -a extra_namespaces=()
  local -a preflight_created_ns=()
  local ns=""

  parse_args "$@"
  [[ -n "${PROJECT_DIR}" ]] || die "--project-dir is required."
  project_dir_abs="$(resolve_repo_path "${PROJECT_DIR}")"
  vars_file="${VARS_FILE:-${project_dir_abs}/vars.sh}"
  local_vars_file="${LOCAL_VARS_FILE:-${project_dir_abs}/vars.local.sh}"
  require_file "${vars_file}"

  export OVERLAY_VARS_FILE="${vars_file}"
  if [[ -f "${local_vars_file}" ]]; then
    export OVERLAY_LOCAL_VARS_FILE="${local_vars_file}"
  fi
  load_overlay_vars "lab"

  CLUSTER_NAME="${CLUSTER_NAME:-${TALOS_CLUSTER_NAME:-$(basename "${project_dir_abs}")}}"
  cluster_dir="${project_dir_abs}"
  helm_dir="${cluster_dir}/helm"
  addon_dir="${helm_dir}/${ADDON_NAME}"
  release_file="${addon_dir}/release.yaml"

  require_file "${release_file}"

  release_name="$(read_release_field "${release_file}" "releaseName")"
  namespace="$(read_release_field "${release_file}" "namespace")"
  chart="$(read_release_field "${release_file}" "chart")"
  version="$(read_release_field "${release_file}" "version")"
  values_file="$(read_release_field "${release_file}" "valuesFile")"
  validation_selector="$(read_release_field "${release_file}" "validationSelector")"
  namespace_label_enforce="$(read_release_field "${release_file}" "namespaceLabelEnforce")"
  namespace_label_audit="$(read_release_field "${release_file}" "namespaceLabelAudit")"
  namespace_label_warn="$(read_release_field "${release_file}" "namespaceLabelWarn")"

  [[ -n "${release_name}" ]] || die "releaseName missing in ${release_file}"
  [[ -n "${namespace}" ]] || die "namespace missing in ${release_file}"
  [[ -n "${chart}" ]] || die "chart missing in ${release_file}"
  [[ -n "${version}" ]] || die "version missing in ${release_file}"
  [[ -n "${values_file}" ]] || die "valuesFile missing in ${release_file}"

  values_file="$(resolve_values_file_path "${release_file}" "${addon_dir}" "${values_file}")" || \
    die "Could not resolve valuesFile '${values_file}' from ${release_file}"
  require_file "${values_file}"

  kubeconfig_file="${KUBECONFIG_PATH:-${cluster_dir}/generated/kubeconfig}"
  kubeconfig_file="$(resolve_repo_path "${kubeconfig_file}")"

  render_dir="${cluster_dir}/generated/helm/${ADDON_NAME}"
  render_file="${render_dir}/rendered.yaml"

  log_info "Phase 2/1: helm template (mandatory)"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] mkdir -p ${render_dir}"
    log_info "[DRY-RUN] helm template ${release_name} ${chart} --version ${version} --namespace ${namespace} --create-namespace -f ${values_file} > ${render_file}"
  else
    mkdir -p "${render_dir}"
    helm template "${release_name}" "${chart}" \
      --version "${version}" \
      --namespace "${namespace}" \
      --create-namespace \
      -f "${values_file}" > "${render_file}"
    [[ -s "${render_file}" ]] || die "Rendered file is empty: ${render_file}"
  fi

  # Some Cilium profiles reference extra namespaces (for example cilium-secrets)
  # that must exist before server-side dry-run.
  ensure_namespace "${kubeconfig_file}" "${namespace}"
  label_namespace_security "${kubeconfig_file}" "${namespace}" \
    "${namespace_label_enforce}" "${namespace_label_audit}" "${namespace_label_warn}"
  if [[ "${ADDON_NAME}" == "cilium" ]]; then
    mapfile -t extra_namespaces < <(collect_cilium_secret_namespaces "${values_file}")
    for ns in "${extra_namespaces[@]}"; do
      [[ "${ns}" == "${namespace}" ]] && continue
      if [[ "${DRY_RUN}" == "true" ]]; then
        ensure_namespace "${kubeconfig_file}" "${ns}"
      else
        if ! namespace_exists "${kubeconfig_file}" "${ns}"; then
          ensure_namespace "${kubeconfig_file}" "${ns}"
          preflight_created_ns+=("${ns}")
        fi
      fi
    done
  fi

  log_info "Phase 2/2: server-side dry-run validation (mandatory)"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] KUBECONFIG=${kubeconfig_file} kubectl apply --server-side --force-conflicts --dry-run=server -f ${render_file}"
  else
    KUBECONFIG="${kubeconfig_file}" kubectl apply --server-side --force-conflicts --dry-run=server -f "${render_file}" >/dev/null
  fi

  if [[ "${RENDER_ONLY}" == "true" ]]; then
    if [[ "${DRY_RUN}" != "true" ]]; then
      for ns in "${preflight_created_ns[@]}"; do
        delete_namespace "${kubeconfig_file}" "${ns}"
      done
    fi
    log_warn "Stopping at render-only mode. Helm install/upgrade was not executed."
    log_info "Rendered manifest: ${render_file}"
    exit 0
  fi

  # Namespaces created only to satisfy server-side dry-run must be removed,
  # so Helm can create and own them in the release metadata.
  if [[ "${DRY_RUN}" != "true" ]]; then
    for ns in "${preflight_created_ns[@]}"; do
      delete_namespace "${kubeconfig_file}" "${ns}"
    done
  fi

  log_info "Phase 2/3: helm upgrade --install"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] KUBECONFIG=${kubeconfig_file} helm upgrade --install ${release_name} ${chart} --version ${version} --namespace ${namespace} --create-namespace -f ${values_file}"
  else
    KUBECONFIG="${kubeconfig_file}" helm upgrade --install "${release_name}" "${chart}" \
      --version "${version}" \
      --namespace "${namespace}" \
      --create-namespace \
      -f "${values_file}"
  fi

  log_info "Phase 2/4: post-install validations"
  if [[ "${DRY_RUN}" == "true" ]]; then
    if [[ -n "${validation_selector}" ]]; then
      log_info "[DRY-RUN] KUBECONFIG=${kubeconfig_file} kubectl -n ${namespace} get pods -l ${validation_selector}"
    else
      log_info "[DRY-RUN] KUBECONFIG=${kubeconfig_file} kubectl -n ${namespace} get pods"
    fi
    log_info "[DRY-RUN] KUBECONFIG=${kubeconfig_file} kubectl get nodes"
    log_info "[DRY-RUN] cilium status (if cilium CLI exists)"
  else
    if [[ -n "${validation_selector}" ]]; then
      KUBECONFIG="${kubeconfig_file}" kubectl -n "${namespace}" get pods -l "${validation_selector}"
    else
      KUBECONFIG="${kubeconfig_file}" kubectl -n "${namespace}" get pods
    fi
    KUBECONFIG="${kubeconfig_file}" kubectl get nodes
    if [[ "${ADDON_NAME}" == "cilium" ]] && command -v cilium >/dev/null 2>&1; then
      KUBECONFIG="${kubeconfig_file}" cilium status --wait
    elif [[ "${ADDON_NAME}" == "cilium" ]]; then
      log_warn "cilium CLI not found; skipping 'cilium status --wait'."
      log_info "Waiting for DaemonSet/cilium rollout via kubectl (timeout: ${CILIUM_ROLLOUT_TIMEOUT})."
      if ! KUBECONFIG="${kubeconfig_file}" kubectl -n "${namespace}" rollout status daemonset/cilium --timeout="${CILIUM_ROLLOUT_TIMEOUT}"; then
        log_warn "Cilium rollout not ready before timeout; continue monitoring with the commands below."
      fi
    fi
  fi

  log_info "Follow-up monitoring commands:"
  if [[ -n "${validation_selector}" ]]; then
    log_info "  KUBECONFIG=${kubeconfig_file} kubectl -n ${namespace} get pods -l ${validation_selector} -w"
  else
    log_info "  KUBECONFIG=${kubeconfig_file} kubectl -n ${namespace} get pods -w"
  fi
  log_info "  KUBECONFIG=${kubeconfig_file} kubectl get nodes -w"

  log_info "Network Bring-up phase completed for addon '${ADDON_NAME}' in cluster '${CLUSTER_NAME}'."
}

main "$@"
