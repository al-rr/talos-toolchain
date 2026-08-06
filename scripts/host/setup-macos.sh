#!/usr/bin/env bash
# @file setup-macos.sh
# @brief Install and verify the macOS host tooling the toolchain's checks require.
# @description
#   Opt-in setup for an operator's macOS workstation. It installs, via
#   Homebrew, only the tooling the repository's own lint and offline test
#   suite needs: Bash 5, yamllint, and shellcheck.
#
#   This is deliberately NOT wired into any lifecycle entrypoint.
#   scripts/talos/lib/bash-preflight.sh diagnoses a missing Bash 5 and stops
#   with an actionable message; it never installs. That separation is
#   intentional and this script does not change it — running setup stays an
#   explicit operator decision, never a side effect of running a cluster
#   command.
#
#   Scope boundaries:
#     - Host tooling only. It installs no cluster client (talosctl, kubectl,
#       helm, cilium) and no container runtime (Colima, Docker). Those carry
#       version-pinning and resource decisions that belong elsewhere.
#     - It never runs sudo, never edits shell rc files, never changes the
#       default login shell, and never touches a cluster.
#
#   This script must keep running under macOS's stock Bash 3.2, because it is
#   what installs Bash 5. Do not introduce mapfile, associative arrays, or
#   other Bash 4+ syntax here.
#
# @arg check action Report what is installed and what is missing. Changes nothing.
# @arg install action Install every missing tool via Homebrew. Idempotent.
#
# @flag --dry-run,-n Print what install would do without executing it.
# @flag --help,-h Show usage information.
#
# @example
#   # See what the host is missing
#   ./scripts/host/setup-macos.sh check
#
# @example
#   # Install the missing tooling (preview first)
#   ./scripts/host/setup-macos.sh install --dry-run
#   ./scripts/host/setup-macos.sh install
#
# @exitcode 0 check found everything, or install completed.
# @exitcode 1 Usage error, missing Homebrew, or a failed installation.
# @exitcode 2 check found at least one missing tool.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# The managed tool set, as "<command>:<brew-formula>:<description>" records.
# Keep this list in sync with docs/en/host-setup.md.
MANAGED_TOOLS="
bash:bash:Bash 5+, required by every toolchain entrypoint (macOS ships 3.2)
yamllint:yamllint:YAML policy checks, used by scripts/talos/tests/test-yaml-style.sh
shellcheck:shellcheck:Shell static analysis for the scripts under scripts/
"

DRY_RUN=0
ACTION=""

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") <action> [options]

Actions:
  check    Report installed and missing host tooling; changes nothing
  install  Install every missing tool via Homebrew (idempotent)

Options:
  -n, --dry-run  Print what install would do without executing it
  -h, --help     Show this help

Manages only the tooling this repository's lint and offline tests need:
Bash 5, yamllint, and shellcheck. It installs no cluster client (talosctl,
kubectl, helm, cilium) and no container runtime (Colima, Docker).

It never runs sudo, never edits shell rc files, never changes your login
shell, and never contacts a cluster.

Examples:
  $(basename "$0") check
  $(basename "$0") install --dry-run
  $(basename "$0") install
EOF_USAGE
}

# @description Prints field <n> of a colon-separated tool record.
tool_field() {
  local record="$1"
  local field="$2"
  printf '%s\n' "${record}" | cut -d: -f"${field}"
}

# @description Locates a Bash 5+ interpreter, mirroring the fixed candidate
#   paths that scripts/talos/lib/bash-preflight.sh accepts. Prints the path,
#   or nothing. A PATH lookup is deliberately not used: the preflight does not
#   use one either, so agreeing with it matters more than being lenient.
find_bash5() {
  local candidate=""
  local major=""
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/local/opt/bash/bin/bash; do
    [ -x "${candidate}" ] || continue
    # shellcheck disable=SC2016 # intentionally unexpanded: evaluated by the candidate's own shell
    major="$("${candidate}" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || true)"
    case "${major}" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "${major}" -ge 5 ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

# @description True (0) when the named tool is present and usable.
#   Bash is special-cased: `command -v bash` finds macOS's stock 3.2, which
#   satisfies the lookup while failing the actual requirement.
tool_is_present() {
  local cmd="$1"
  if [ "${cmd}" = "bash" ]; then
    find_bash5 >/dev/null 2>&1
    return $?
  fi
  command -v "${cmd}" >/dev/null 2>&1
}

# @description Prints a short version string for an installed tool, or "unknown".
tool_version() {
  local cmd="$1"
  local path=""
  case "${cmd}" in
    bash)
      path="$(find_bash5 2>/dev/null || true)"
      [ -n "${path}" ] || { printf 'unknown\n'; return 0; }
      # shellcheck disable=SC2016 # intentionally unexpanded: evaluated by the candidate's own shell
      "${path}" -c 'echo "${BASH_VERSION}"' 2>/dev/null || printf 'unknown\n'
      ;;
    yamllint)
      yamllint --version 2>/dev/null | head -1 || printf 'unknown\n'
      ;;
    shellcheck)
      shellcheck --version 2>/dev/null | awk '/^version:/ { print $2 }' | head -1 || printf 'unknown\n'
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

require_homebrew() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi
  log_error "Homebrew is required to install host tooling, and 'brew' is not on PATH."
  log_error "Install it from https://brew.sh, then re-run:"
  log_error "  $(basename "$0") install"
  exit 1
}

do_check() {
  local record=""
  local cmd=""
  local desc=""
  local missing=0

  log_info "Host tooling required by this repository's checks:"
  echo

  # A here-string, not a pipe: the loop must run in this shell so the
  # missing counter survives it.
  while IFS= read -r record; do
    [ -n "${record}" ] || continue
    cmd="$(tool_field "${record}" 1)"
    desc="$(tool_field "${record}" 3)"
    if tool_is_present "${cmd}"; then
      printf '  [ok]      %-12s %s\n' "${cmd}" "$(tool_version "${cmd}")"
    else
      printf '  [missing] %-12s %s\n' "${cmd}" "${desc}"
      missing=$((missing + 1))
    fi
  done <<EOF_TOOLS
${MANAGED_TOOLS}
EOF_TOOLS

  echo
  if [ "${missing}" -eq 0 ]; then
    log_info "All managed host tooling is installed."
    return 0
  fi
  log_warn "${missing} tool(s) missing. Install them with:"
  log_warn "  $(basename "$0") install"
  return 2
}

do_install() {
  local record=""
  local cmd=""
  local formula=""
  local installed_any=0

  if [ "${DRY_RUN}" -eq 0 ]; then
    require_homebrew
  elif ! command -v brew >/dev/null 2>&1; then
    log_warn "[DRY-RUN] Homebrew is not installed; a real run would stop here."
  fi

  # A here-string, not a pipe: the loop must run in this shell so
  # installed_any survives it. Word-splitting a `for` over MANAGED_TOOLS would
  # also break, because the description field contains spaces.
  while IFS= read -r record; do
    [ -n "${record}" ] || continue
    cmd="$(tool_field "${record}" 1)"
    formula="$(tool_field "${record}" 2)"

    if tool_is_present "${cmd}"; then
      log_info "${cmd} already installed ($(tool_version "${cmd}")); skipping."
      continue
    fi

    installed_any=1
    if [ "${DRY_RUN}" -eq 1 ]; then
      log_info "[DRY-RUN] brew install ${formula}"
      continue
    fi

    log_info "Installing ${formula} via Homebrew."
    if ! brew install "${formula}"; then
      log_error "Failed to install ${formula}."
      return 1
    fi
  done <<EOF_TOOLS
${MANAGED_TOOLS}
EOF_TOOLS

  if [ "${installed_any}" -eq 0 ]; then
    log_info "Nothing to do; all managed host tooling is already installed."
    return 0
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    log_info "[DRY-RUN] No change was made to this host."
    return 0
  fi

  echo
  log_info "Done. Note that Homebrew's Bash 5 is installed alongside the system"
  log_info "Bash 3.2; it does not replace it and your login shell is unchanged."
  log_info "The toolchain entrypoints locate it themselves. Verify with:"
  log_info "  bash ${REPO_ROOT}/scripts/talos/tests/test-bash-preflight.sh"
  return 0
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      check|install)
        if [ -n "${ACTION}" ]; then
          log_error "More than one action given: '${ACTION}' and '$1'."
          usage >&2
          exit 1
        fi
        ACTION="$1"
        ;;
      -n|--dry-run)
        DRY_RUN=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        usage >&2
        exit 1
        ;;
    esac
    shift
  done

  if [ -z "${ACTION}" ]; then
    log_error "An action is required."
    usage >&2
    exit 1
  fi

  if [ "$(uname -s)" != "Darwin" ]; then
    log_error "This script targets macOS; found $(uname -s)."
    log_error "On the Vagrant lab controller use the install scripts under"
    log_error "provision-talos-vsphere/overlays/lab/controller/scripts/ instead."
    exit 1
  fi

  case "${ACTION}" in
    check) do_check ;;
    install) do_install ;;
  esac
}

main "$@"
