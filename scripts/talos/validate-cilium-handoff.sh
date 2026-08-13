#!/usr/bin/env bash
# @file validate-cilium-handoff.sh
# @brief Offline Cilium day-1/day-2 (Argo CD) handoff contract validator.
# @description
#   Compares the day-1 imperative Cilium Helm release (as consumed by
#   phase-network-bringup.sh / apply-post-bootstrap.sh from a synced project
#   helm/cilium/release.yaml) against the day-2 GitOps Argo CD Application
#   that will adopt Cilium reconciliation (talos-vsphere-gitops
#   environments/<env>/argocd/apps/cilium.yaml). Fails on any mismatch that
#   would make Argo CD reconcile a different chart, version, values content,
#   release identity, or environment revision than the one Cilium was
#   bootstrapped with, and on a non-automated adoption sync policy.
#
#   Reads local files only. Never contacts talosctl, kubectl, helm, Argo CD,
#   or any live cluster/VMware endpoint, and never mutates a repository.
#
# @arg --day1-release path Path to the synced day-1 helm/cilium/release.yaml (required).
# @arg --gitops-repo-root path Path to a talos-vsphere-gitops checkout (required).
# @arg --environment name Environment directory name under environments/ (required, e.g. lab).
# @arg --gitops-cilium-app path Override path to the cilium Argo Application manifest.
# @arg --gitops-self-repo-pattern regex Regex matched against repoURL to identify the GitOps repo itself.
# @flag --help,-h Show usage information.
#
# @example
#   ./validate-cilium-handoff.sh \
#     --day1-release=./clusters/talos-dev/helm/cilium/release.yaml \
#     --gitops-repo-root=../talos-vsphere-gitops \
#     --environment=lab
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

DAY1_RELEASE=""
GITOPS_REPO_ROOT=""
ENVIRONMENT=""
GITOPS_CILIUM_APP=""
SELF_REPO_PATTERN='talos-vsphere-gitops(\.git)?$'

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Offline validator for the Cilium day-1 (imperative) / day-2 (Argo CD) handoff
contract. Verifies that Argo CD will adopt the same chart, version, rendered
values, release identity, and environment revision that day-1 bootstrapped,
and that the adoption sync policy is fully automated.

Options:
  --day1-release=<path>            Synced day-1 helm/cilium/release.yaml (required)
  --gitops-repo-root=<path>        talos-vsphere-gitops checkout root (required)
  --environment=<name>             Environment directory name, e.g. lab (required)
  --gitops-cilium-app=<path>       Override cilium Argo Application manifest path
  --gitops-self-repo-pattern=<re>  Regex identifying the GitOps repo's own repoURL
                                    (default: ${SELF_REPO_PATTERN})
  -h, --help                        Show help

Examples:
  $(basename "$0") --day1-release=./clusters/talos-dev/helm/cilium/release.yaml \\
    --gitops-repo-root=../talos-vsphere-gitops --environment=lab
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --day1-release=*) DAY1_RELEASE="${1#*=}"; shift ;;
      --gitops-repo-root=*) GITOPS_REPO_ROOT="${1#*=}"; shift ;;
      --environment=*) ENVIRONMENT="${1#*=}"; shift ;;
      --gitops-cilium-app=*) GITOPS_CILIUM_APP="${1#*=}"; shift ;;
      --gitops-self-repo-pattern=*) SELF_REPO_PATTERN="${1#*=}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "${DAY1_RELEASE}" ]] || die "--day1-release is required."
  [[ -n "${GITOPS_REPO_ROOT}" ]] || die "--gitops-repo-root is required."
  [[ -n "${ENVIRONMENT}" ]] || die "--environment is required."
}

read_release_field() {
  local file_path="$1"
  local field_name="$2"
  awk -F': ' -v key="${field_name}" '$1==key {print $2; exit}' "${file_path}" | sed -e 's/^"//' -e 's/"$//'
}

resolve_values_file_path() {
  local addon_dir="$1"
  local values_raw="$2"
  local basename_candidate=""

  if [[ "${values_raw}" = /* && -f "${values_raw}" ]]; then
    printf '%s\n' "${values_raw}"
    return 0
  fi
  if [[ -f "${addon_dir}/${values_raw}" ]]; then
    printf '%s\n' "${addon_dir}/${values_raw}"
    return 0
  fi
  basename_candidate="$(basename "${values_raw}")"
  if [[ -f "${addon_dir}/${basename_candidate}" ]]; then
    printf '%s\n' "${addon_dir}/${basename_candidate}"
    return 0
  fi
  return 1
}

# Minimal line-oriented parser for the known two-source Cilium Argo
# Application shape (Helm OCI chart source + GitOps values ref source). Not a
# general YAML parser; mirrors the same pragmatic approach already used by
# talos-vsphere-gitops/scripts/validate-argocd-revisions.sh.
parse_cilium_app() {
  local app_file="$1"
  awk '
    function emit(key, val) { printf "%s=%s\n", key, val }
    /^[[:space:]]*sources:[[:space:]]*$/ { in_sources=1; next }
    /^[[:space:]]*destination:[[:space:]]*$/ { in_sources=0; in_dest=1; next }
    /^[[:space:]]*syncPolicy:[[:space:]]*$/ { in_dest=0; in_sync=1; next }
    in_sources && /^[[:space:]]*-[[:space:]]*repoURL:/ {
      idx++
      line=$0; sub(/^[[:space:]]*-[[:space:]]*repoURL:[[:space:]]*/, "", line); repo[idx]=line
      cur=idx
      next
    }
    in_sources && /^[[:space:]]*chart:/ { line=$0; sub(/^[[:space:]]*chart:[[:space:]]*/, "", line); chart[cur]=line; next }
    in_sources && /^[[:space:]]*targetRevision:/ { line=$0; sub(/^[[:space:]]*targetRevision:[[:space:]]*/, "", line); rev[cur]=line; next }
    in_sources && /^[[:space:]]*releaseName:/ { line=$0; sub(/^[[:space:]]*releaseName:[[:space:]]*/, "", line); relname[cur]=line; next }
    in_sources && /^[[:space:]]*-[[:space:]]*\$values\// {
      line=$0; sub(/^[[:space:]]*-[[:space:]]*\$values\//, "", line); valuesfile[cur]=line; next
    }
    in_dest && /^[[:space:]]*namespace:/ { line=$0; sub(/^[[:space:]]*namespace:[[:space:]]*/, "", line); namespace=line; next }
    in_sync && /^[[:space:]]*prune:/ { line=$0; sub(/^[[:space:]]*prune:[[:space:]]*/, "", line); prune=line; next }
    in_sync && /^[[:space:]]*selfHeal:/ { line=$0; sub(/^[[:space:]]*selfHeal:[[:space:]]*/, "", line); selfheal=line; next }
    END {
      emit("CHART_REPO", repo[1])
      emit("CHART_NAME", chart[1])
      emit("CHART_VERSION", rev[1])
      emit("RELEASE_NAME", relname[1])
      emit("VALUES_FILE", valuesfile[1])
      emit("VALUES_REPO_URL", repo[2])
      emit("VALUES_REPO_REV", rev[2])
      emit("NAMESPACE", namespace)
      emit("SYNC_PRUNE", prune)
      emit("SYNC_SELFHEAL", selfheal)
    }
  ' "${app_file}"
}

sha256_of() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${path}" | awk '{print $1}'
  else
    shasum -a 256 "${path}" | awk '{print $1}'
  fi
}

main() {
  local -a failures=()
  local day1_dir=""
  local day1_release_name="" day1_namespace="" day1_chart="" day1_version="" day1_values_raw="" day1_values_file=""
  local gitops_cilium_app=""
  local chart_repo="" chart_name="" chart_version="" release_name="" values_file_rel=""
  local values_repo_url="" values_repo_rev="" namespace="" sync_prune="" sync_selfheal=""
  local expected_chart="" gitops_values_file="" gitops_values_hash="" day1_values_hash=""

  parse_args "$@"

  require_file "${DAY1_RELEASE}"
  day1_dir="$(cd "$(dirname "${DAY1_RELEASE}")" && pwd)"
  [[ -d "${GITOPS_REPO_ROOT}" ]] || die "GitOps repo root not found: ${GITOPS_REPO_ROOT}"
  GITOPS_REPO_ROOT="$(cd "${GITOPS_REPO_ROOT}" && pwd)"

  gitops_cilium_app="${GITOPS_CILIUM_APP:-${GITOPS_REPO_ROOT}/environments/${ENVIRONMENT}/argocd/apps/cilium.yaml}"
  require_file "${gitops_cilium_app}"

  day1_release_name="$(read_release_field "${DAY1_RELEASE}" "releaseName")"
  day1_namespace="$(read_release_field "${DAY1_RELEASE}" "namespace")"
  day1_chart="$(read_release_field "${DAY1_RELEASE}" "chart")"
  day1_version="$(read_release_field "${DAY1_RELEASE}" "version")"
  day1_values_raw="$(read_release_field "${DAY1_RELEASE}" "valuesFile")"

  [[ -n "${day1_release_name}" ]] || die "releaseName missing in ${DAY1_RELEASE}"
  [[ -n "${day1_namespace}" ]] || die "namespace missing in ${DAY1_RELEASE}"
  [[ -n "${day1_chart}" ]] || die "chart missing in ${DAY1_RELEASE}"
  [[ -n "${day1_version}" ]] || die "version missing in ${DAY1_RELEASE}"
  [[ -n "${day1_values_raw}" ]] || die "valuesFile missing in ${DAY1_RELEASE}"

  day1_values_file="$(resolve_values_file_path "${day1_dir}" "${day1_values_raw}")" || \
    die "Could not resolve day-1 valuesFile '${day1_values_raw}' from ${DAY1_RELEASE}"

  eval "$(parse_cilium_app "${gitops_cilium_app}")"
  # shellcheck disable=SC2153 # CHART_REPO etc. come from the eval above, not a typo of the lowercase locals
  chart_repo="${CHART_REPO}"
  # shellcheck disable=SC2153
  chart_name="${CHART_NAME}"
  # shellcheck disable=SC2153
  chart_version="${CHART_VERSION}"
  # shellcheck disable=SC2153
  release_name="${RELEASE_NAME}"
  # shellcheck disable=SC2153
  values_file_rel="${VALUES_FILE}"
  # shellcheck disable=SC2153
  values_repo_url="${VALUES_REPO_URL}"
  # shellcheck disable=SC2153
  values_repo_rev="${VALUES_REPO_REV}"
  # shellcheck disable=SC2153
  namespace="${NAMESPACE}"
  # shellcheck disable=SC2153
  sync_prune="${SYNC_PRUNE}"
  # shellcheck disable=SC2153
  sync_selfheal="${SYNC_SELFHEAL}"

  [[ -n "${chart_repo}" && -n "${chart_name}" ]] || die "Could not parse chart source from ${gitops_cilium_app}"
  [[ -n "${values_file_rel}" ]] || die "Could not parse values file reference from ${gitops_cilium_app}"
  [[ -n "${values_repo_url}" && -n "${values_repo_rev}" ]] || die "Could not parse values-ref source from ${gitops_cilium_app}"

  # 1) GitOps environment revision agreement: the values-ref source (the
  #    GitOps repo pointing at itself) must resolve the same revision as the
  #    environment directory it lives under.
  if [[ "${values_repo_url}" =~ ${SELF_REPO_PATTERN} ]]; then
    if [[ "${values_repo_rev}" != "${ENVIRONMENT}" ]]; then
      failures+=("environment revision mismatch: ${gitops_cilium_app} values-ref targetRevision='${values_repo_rev}' (expected '${ENVIRONMENT}')")
    fi
  else
    failures+=("values-ref source repoURL '${values_repo_url}' does not match expected GitOps repo pattern '${SELF_REPO_PATTERN}'")
  fi

  # 2) Rendered Cilium identity: chart, version, release name, namespace.
  #
  # The Argo CD Application's repoURL deliberately omits the oci:// scheme
  # (see the comment in talos-vsphere-gitops's argocd/apps/cilium.yaml: with
  # the prefix, Argo CD treats the value as the complete OCI artifact
  # reference and never appends `chart`, so quay.io answers 401 instead of
  # 404 for the resulting bad path). day-1's release.yaml needs the opposite
  # convention -- a single string `helm pull`/`helm template` can resolve on
  # its own -- so it keeps the scheme. Both name the same real artifact;
  # strip the scheme from whichever side has it before comparing, so this
  # deliberate day-1/day-2 formatting difference is not reported as drift.
  expected_chart="${chart_repo%/}/${chart_name}"
  day1_chart_noscheme="${day1_chart#oci://}"
  expected_chart_noscheme="${expected_chart#oci://}"
  if [[ "${day1_chart_noscheme}" != "${expected_chart_noscheme}" ]]; then
    failures+=("chart mismatch: day-1='${day1_chart}' gitops='${expected_chart}'")
  fi
  if [[ "${day1_version}" != "${chart_version}" ]]; then
    failures+=("chart version mismatch: day-1='${day1_version}' gitops='${chart_version}'")
  fi
  if [[ "${day1_release_name}" != "${release_name}" ]]; then
    failures+=("release name mismatch: day-1='${day1_release_name}' gitops='${release_name}'")
  fi
  if [[ "${day1_namespace}" != "${namespace}" ]]; then
    failures+=("namespace mismatch: day-1='${day1_namespace}' gitops='${namespace}'")
  fi

  # 3) Rendered values content identity.
  gitops_values_file="${GITOPS_REPO_ROOT}/${values_file_rel}"
  if [[ -f "${gitops_values_file}" ]]; then
    gitops_values_hash="$(sha256_of "${gitops_values_file}")"
    day1_values_hash="$(sha256_of "${day1_values_file}")"
    if [[ "${gitops_values_hash}" != "${day1_values_hash}" ]]; then
      failures+=("values content mismatch: day-1 '${day1_values_file}' (${day1_values_hash}) != gitops '${gitops_values_file}' (${gitops_values_hash})")
    fi
  else
    failures+=("gitops values file not found: ${gitops_values_file}")
  fi

  # 4) Adoption readiness: sync policy must be fully automated, otherwise
  #    Argo CD will not reconcile Cilium without a manual sync.
  if [[ "${sync_prune}" != "true" || "${sync_selfheal}" != "true" ]]; then
    failures+=("adoption sync policy is not fully automated: prune='${sync_prune}' selfHeal='${sync_selfheal}'")
  fi

  if (( ${#failures[@]} > 0 )); then
    log_error "Cilium GitOps handoff validation FAILED:"
    local f=""
    for f in "${failures[@]}"; do
      log_error "  - ${f}"
    done
    exit 1
  fi

  log_info "OK: day-1 Cilium release matches the GitOps adoption contract for environment '${ENVIRONMENT}'."
}

main "$@"
