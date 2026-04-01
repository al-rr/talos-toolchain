#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/talos/lib/common.sh"

PROJECT_DIR=""
VARS_FILE=""
LOCAL_VARS_FILE=""
CLUSTER_NAME=""
KUBECONFIG_PATH=""
ADDONS_RAW=""
DRY_RUN="false"

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Apply mandatory post-bootstrap baseline configuration for a functional cluster.

Options:
  --project-dir=<path>   Cluster project dir (required)
  --vars-file=<path>     Optional vars override (default: <project>/vars.sh)
  --local-vars-file=<path>  Optional local vars override (default: <project>/vars.local.sh)
  --cluster-name=<name>  Cluster name override
  --kubeconfig=<path>    Kubeconfig path override
  --addons=<list>        CSV/JSON-like addons order (default: TALOS_CLUSTER_BASELINE_ADDONS or cilium)
  -n, --dry-run          Print actions without executing
  -h, --help             Show help

Examples:
  $(basename "$0") --project-dir=./clusters/talos-dev
  $(basename "$0") --addons=cilium,longhorn
  $(basename "$0") --addons='["cilium","longhorn"]'
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-dir=*) PROJECT_DIR="${1#*=}"; shift ;;
      --vars-file=*) VARS_FILE="${1#*=}"; shift ;;
      --local-vars-file=*) LOCAL_VARS_FILE="${1#*=}"; shift ;;
      --cluster-name=*) CLUSTER_NAME="${1#*=}"; shift ;;
      --kubeconfig=*) KUBECONFIG_PATH="${1#*=}"; shift ;;
      --addons=*) ADDONS_RAW="${1#*=}"; shift ;;
      -n|--dry-run) DRY_RUN="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      --env=*|--env) die "--env was removed. Use --project-dir." ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done
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

normalize_csv_list() {
  local raw="$1"
  raw="${raw//[/}"
  raw="${raw//]/}"
  raw="${raw//\"/}"
  raw="${raw// /}"
  printf '%s\n' "${raw}"
}

run_or_echo() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

contains_addon() {
  local target="$1"
  shift
  local item
  for item in "$@"; do
    [[ "${item}" == "${target}" ]] && return 0
  done
  return 1
}

resolve_repo_path() {
  local path_value="$1"
  if [[ "${path_value}" = /* ]]; then
    printf '%s\n' "${path_value}"
  else
    printf '%s\n' "${REPO_ROOT}/${path_value}"
  fi
}

find_helm_root_from_extract() {
  local extract_dir="$1"
  local first_release=""
  local root=""

  first_release="$(find "${extract_dir}" -type f -name release.yaml | head -n1 || true)"
  [[ -n "${first_release}" ]] || return 1
  root="$(dirname "$(dirname "${first_release}")")"
  [[ -d "${root}" ]] || return 1
  printf '%s\n' "${root}"
}

sync_tree() {
  local src="$1"
  local dst="$2"
  local overwrite="$3"

  [[ -d "${src}" ]] || die "Helm source dir not found: ${src}"
  mkdir -p "${dst}"

  if [[ "${overwrite}" == "true" ]]; then
    if command -v rsync >/dev/null 2>&1; then
      run_or_echo rsync -a --delete "${src}/" "${dst}/"
    else
      if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY-RUN] rm -rf ${dst}/* && cp -a ${src}/. ${dst}/"
      else
        find "${dst}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        cp -a "${src}/." "${dst}/"
      fi
    fi
  else
    if command -v rsync >/dev/null 2>&1; then
      run_or_echo rsync -a --ignore-existing "${src}/" "${dst}/"
    else
      run_or_echo cp -an "${src}/." "${dst}/"
    fi
  fi
}

sync_post_bootstrap_helm() {
  local project_dir_abs="$1"
  local source_mode=""
  local source_path=""
  local source_url=""
  local overwrite_mode=""
  local target_helm_dir=""
  local tmp_dir=""
  local archive_file=""
  local extracted_helm_root=""

  source_mode="${TALOS_POST_BOOTSTRAP_HELM_SOURCE_MODE:-path}"
  source_path="${TALOS_POST_BOOTSTRAP_HELM_SOURCE_PATH:-/home/vagrant/talos-vsphere-gitops/environments/lab/helm}"
  source_url="${TALOS_POST_BOOTSTRAP_HELM_SOURCE_URL:-}"
  overwrite_mode="${TALOS_POST_BOOTSTRAP_HELM_OVERWRITE:-true}"
  target_helm_dir="${project_dir_abs}/helm"

  case "${source_mode}" in
    path)
      [[ -n "${source_path}" ]] || die "TALOS_POST_BOOTSTRAP_HELM_SOURCE_PATH is required when mode=path."
      source_path="$(resolve_repo_path "${source_path}")"
      log_info "Syncing post-bootstrap helm from path: ${source_path}"
      sync_tree "${source_path}" "${target_helm_dir}" "${overwrite_mode}"
      ;;
    web)
      [[ -n "${source_url}" ]] || die "TALOS_POST_BOOTSTRAP_HELM_SOURCE_URL is required when mode=web."
      [[ "${DRY_RUN}" == "true" ]] && log_info "[DRY-RUN] Downloading helm archive: ${source_url}"
      tmp_dir="$(mktemp -d)"
      archive_file="${tmp_dir}/source.archive"

      if [[ "${DRY_RUN}" != "true" ]]; then
        if command -v wget >/dev/null 2>&1; then
          wget -q -O "${archive_file}" "${source_url}"
        elif command -v curl >/dev/null 2>&1; then
          curl -fsSL -o "${archive_file}" "${source_url}"
        else
          die "Either wget or curl is required for mode=web."
        fi

        case "${source_url}" in
          *.tar.gz|*.tgz) tar -xzf "${archive_file}" -C "${tmp_dir}" ;;
          *.zip)
            command -v unzip >/dev/null 2>&1 || die "unzip is required for .zip sources."
            unzip -q "${archive_file}" -d "${tmp_dir}"
            ;;
          *)
            die "Unsupported archive extension in URL. Use .tar.gz/.tgz/.zip"
            ;;
        esac

        extracted_helm_root="$(find_helm_root_from_extract "${tmp_dir}")" || \
          die "Could not locate helm root from downloaded archive."
        log_info "Syncing post-bootstrap helm from web archive root: ${extracted_helm_root}"
        sync_tree "${extracted_helm_root}" "${target_helm_dir}" "${overwrite_mode}"
        rm -rf "${tmp_dir}"
      fi
      ;;
    *)
      die "Invalid TALOS_POST_BOOTSTRAP_HELM_SOURCE_MODE='${source_mode}'. Use path or web."
      ;;
  esac

  if [[ -n "${tmp_dir}" && -d "${tmp_dir}" ]]; then
    rm -rf "${tmp_dir}"
  fi
}

ensure_generated_kubeconfig() {
  local project_dir_abs="$1"
  local kubeconfig_file="$2"
  local talosconfig_path="${project_dir_abs}/generated/talosconfig"
  local cp_ips_raw=""
  local bootstrap_node=""
  local -a cp_ips=()

  if [[ -f "${kubeconfig_file}" ]]; then
    return 0
  fi

  require_file "${talosconfig_path}"
  cp_ips_raw="$(normalize_csv_list "${TALOS_CONTROL_PLANE_IPS:-}")"
  mapfile -t cp_ips < <(csv_to_array "${cp_ips_raw}")
  (( ${#cp_ips[@]} > 0 )) || die "TALOS_CONTROL_PLANE_IPS is empty; cannot generate kubeconfig."
  bootstrap_node="${cp_ips[0]}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] talosctl --talosconfig ${talosconfig_path} config endpoint ${cp_ips[*]}"
    log_info "[DRY-RUN] talosctl --talosconfig ${talosconfig_path} config node ${cp_ips[*]}"
    log_info "[DRY-RUN] talosctl --talosconfig ${talosconfig_path} --nodes ${bootstrap_node} --endpoints ${bootstrap_node} kubeconfig ${kubeconfig_file} --force --merge=false --force-context-name admin@${CLUSTER_NAME}"
    return 0
  fi

  talosctl --talosconfig "${talosconfig_path}" config endpoint "${cp_ips[@]}" >/dev/null
  talosctl --talosconfig "${talosconfig_path}" config node "${cp_ips[@]}" >/dev/null
  mkdir -p "$(dirname "${kubeconfig_file}")"
  talosctl --talosconfig "${talosconfig_path}" \
    --nodes "${bootstrap_node}" \
    --endpoints "${bootstrap_node}" \
    kubeconfig "${kubeconfig_file}" \
    --force \
    --merge=false \
    --force-context-name "admin@${CLUSTER_NAME}"
}

main() {
  local project_dir_abs=""
  local vars_file=""
  local local_vars_file=""
  local auto_prepare_post_bootstrap_helm=""
  local baseline_raw=""
  local baseline_csv=""
  local addon=""
  local kubeconfig_file=""
  local -a addons=()
  local -a cmd=()

  parse_args "$@"
  [[ -n "${PROJECT_DIR}" ]] || die "--project-dir is required."
  if [[ "${PROJECT_DIR}" = /* ]]; then
    project_dir_abs="${PROJECT_DIR}"
  else
    project_dir_abs="${REPO_ROOT}/${PROJECT_DIR}"
  fi

  vars_file="${VARS_FILE:-${project_dir_abs}/vars.sh}"
  local_vars_file="${LOCAL_VARS_FILE:-${project_dir_abs}/vars.local.sh}"
  require_file "${vars_file}"
  export OVERLAY_VARS_FILE="${vars_file}"
  if [[ -f "${local_vars_file}" ]]; then
    export OVERLAY_LOCAL_VARS_FILE="${local_vars_file}"
  fi
  load_overlay_vars "lab"

  CLUSTER_NAME="${CLUSTER_NAME:-${TALOS_CLUSTER_NAME:-$(basename "${project_dir_abs}")}}"
  baseline_raw="${ADDONS_RAW:-${TALOS_CLUSTER_BASELINE_ADDONS:-${TALOS_BASELINE_ADDONS:-cilium}}}"
  baseline_csv="$(normalize_csv_list "${baseline_raw}")"
  mapfile -t addons < <(csv_to_array "${baseline_csv}")
  (( ${#addons[@]} > 0 )) || die "No baseline addons defined."

  if [[ "${TALOS_DISABLE_DEFAULT_CNI:-false}" == "true" ]]; then
    contains_addon "cilium" "${addons[@]}" || \
      die "TALOS_DISABLE_DEFAULT_CNI=true requires cilium in baseline addons."
  fi

  kubeconfig_file="${KUBECONFIG_PATH:-${project_dir_abs}/generated/kubeconfig}"
  auto_prepare_post_bootstrap_helm="${TALOS_POST_BOOTSTRAP_HELM_AUTO_PREPARE:-true}"
  ensure_generated_kubeconfig "${project_dir_abs}" "${kubeconfig_file}"

  log_info "Applying cluster baseline configuration (post-bootstrap): ${addons[*]}"

  if [[ "${auto_prepare_post_bootstrap_helm}" == "true" ]]; then
    sync_post_bootstrap_helm "${project_dir_abs}"
  fi

  for addon in "${addons[@]}"; do
    [[ -n "${addon}" ]] || continue
    cmd=(
      "${SCRIPT_DIR}/phase-network-bringup.sh"
      "--project-dir=${project_dir_abs}"
      "--cluster-name=${CLUSTER_NAME}"
      "--addon=${addon}"
      "--kubeconfig=${kubeconfig_file}"
    )
    [[ "${DRY_RUN}" == "true" ]] && cmd+=("--dry-run")
    run_or_echo "${cmd[@]}"
  done

  log_info "Cluster baseline configuration completed."
}

main "$@"
