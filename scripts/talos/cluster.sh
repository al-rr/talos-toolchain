#!/usr/bin/env bash
# @file cluster.sh
# @brief Day-1 Talos cluster lifecycle entrypoint.
# @description
#   Provides project-oriented actions for Talos cluster creation and bootstrap
#   workflows. This is the canonical day-1 CLI in talos-toolchain.
#
# @arg create-project action Create cluster project scaffold.
# @arg generate action Generate cluster artifacts from project inputs.
# @arg provision action Provision cluster hosts.
# @arg prepare-bootstrap action Prepare hosts for Talos bootstrap.
# @arg bootstrap action Bootstrap Talos control plane.
# @arg apply-config action Re-converge Talos machine config.
# @arg sync-access action Sync local kubectl/talosctl access.
# @arg apply-post-bootstrap action Apply mandatory post-bootstrap baseline.
# @arg refresh-schematics action Refresh Talos image schematics.
#
# @arg --project-dir path Cluster project directory.
# @arg --vars-file path Optional vars override.
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

usage() {
  cat <<'EOF_USAGE'
Usage: cluster.sh <action> [options]

Actions:
  create-project        Create cluster project scaffold
  generate              Generate cluster artifacts from project inputs
  provision             Provision cluster hosts
  prepare-bootstrap     Prepare hosts for Talos bootstrap
  bootstrap             Bootstrap Talos control plane
  apply-config          Re-converge Talos machine config
  sync-access           Sync local kubectl/talosctl access
  apply-post-bootstrap  Apply mandatory post-bootstrap baseline
  refresh-schematics    Refresh Talos image schematics

Options:
  --project-dir=<path>  Cluster project directory (primary contract)
  --vars-file=<path>    Optional vars override file
  -h, --help            Show help

Examples:
  # Create a new cluster workspace
  cluster.sh create-project --project-dir=./clusters/talos-dev

  # Generate artifacts for an existing cluster project
  cluster.sh generate --project-dir=./clusters/talos-dev
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      create-project|generate|provision|prepare-bootstrap|bootstrap|apply-config|sync-access|apply-post-bootstrap|refresh-schematics)
        [[ -z "${ACTION}" ]] || die "Action already set: ${ACTION}"
        ACTION="$1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        shift
        ;;
    esac
  done
  [[ -n "${ACTION}" ]] || { usage; die "Action is required."; }
}

main() {
  parse_args "$@"
  die "Action '${ACTION}' is not implemented yet in talos-toolchain scaffold."
}

main "$@"
