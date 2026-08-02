#!/usr/bin/env bash
# @file config.sh
# @brief XDG YAML environment configuration bootstrap and diagnostics.
# @description
#   Manages the data-only YAML configuration contract: base/config.yaml,
#   environments/<name>/config.yaml, and environments/<name>/credentials.yaml
#   under XDG_CONFIG_HOME (default ~/.config/talos-toolchain). Bootstrap is
#   idempotent; existing files are left untouched unless --force is given.
#
# @arg bootstrap action Create/refresh XDG config scaffolding for an environment.
# @arg show action Print resolved, redacted configuration for an environment.
#
# @arg --environment name Environment name (required).
# @flag --force Overwrite existing config/credentials files on bootstrap.
# @flag --help,-h Show usage information.
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/bash-preflight.sh"
talos_require_bash5 "${SCRIPT_PATH}" "$@"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/yaml-config.sh"

ACTION=""
ENVIRONMENT=""
FORCE="false"

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") <action> --environment=<name> [options]

Actions:
  bootstrap  Idempotently create base/environment config and credentials files
  show       Print resolved, redacted configuration for an environment

Options:
  --environment=<name>  Environment name (required)
  --force               Overwrite existing files on bootstrap
  -h, --help            Show this help

Examples:
  $(basename "$0") bootstrap --environment=lab
  $(basename "$0") show --environment=lab
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      bootstrap|show)
        [[ -z "${ACTION}" ]] || die "Action already set: ${ACTION}"
        ACTION="$1"
        shift
        ;;
      --environment=*) ENVIRONMENT="${1#*=}"; shift ;;
      --force) FORCE="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "${ACTION}" ]] || { usage; die "Action is required."; }
  [[ -n "${ENVIRONMENT}" ]] || { usage; die "--environment is required."; }
  talos_config_require_valid_env_name "${ENVIRONMENT}"
}

main() {
  parse_args "$@"
  talos_require_commands yq

  case "${ACTION}" in
    bootstrap)
      talos_config_bootstrap "${ENVIRONMENT}" "${FORCE}"
      ;;
    show)
      talos_config_show_redacted "${ENVIRONMENT}"
      ;;
  esac
}

main "$@"
