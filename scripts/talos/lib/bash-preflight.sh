#!/usr/bin/env bash

# @file bash-preflight.sh
# @brief Bash 5 shell contract preflight for maintained Talos toolchain entrypoints.
# @description
#   Bash-3.2-parseable guard. Must be sourced before any Bash-5-only syntax
#   (mapfile, associative arrays, lowercase parameter expansion) executes.
#   On a Bash 5+ interpreter it is a no-op. On macOS's stock Bash 3.2 it looks
#   for a Homebrew Bash 5 at explicit, well-known install paths only, re-execs
#   the calling entrypoint under it, and prepends that Bash's directory to
#   PATH so any script it dispatches via `#!/usr/bin/env bash` resolves the
#   same interpreter. If no Bash 5 is found, it stops with an actionable
#   installation message before incompatible syntax can run. It never
#   installs or reconfigures anything on the host.
# @exitcode 0 If sourced successfully.
# @exitcode 1 If executed directly instead of sourced.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This file is a library and must be sourced by another script." >&2
  exit 1
fi

_TALOS_BASH_PREFLIGHT_MIN_MAJOR=5

# @description Explicit Homebrew Bash candidate paths, Apple Silicon first.
#   No PATH search and no package-manager query: only these fixed locations.
_talos_bash_preflight_candidates() {
  printf '%s\n' \
    "/opt/homebrew/bin/bash" \
    "/usr/local/bin/bash" \
    "/usr/local/opt/bash/bin/bash"
}

# @description True (0) when the given major version is below the required minimum.
_talos_bash_preflight_needs_upgrade() {
  local major="$1"
  [ -n "${major}" ] || return 0
  case "${major}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "${major}" -lt "${_TALOS_BASH_PREFLIGHT_MIN_MAJOR}" ]
}

# @description Prints the candidate's major Bash version, empty if it cannot be determined.
_talos_bash_preflight_version_major() {
  local candidate="$1"
  [ -x "${candidate}" ] || return 0
  # shellcheck disable=SC2016 # intentionally unexpanded: evaluated by the candidate's own shell
  "${candidate}" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null
}

# @description Verifies the running interpreter is Bash 5+. Re-execs the
#   caller under a located Homebrew Bash 5 candidate, or exits with an
#   actionable error. Never installs or modifies host configuration.
# @arg $1 self_path Absolute path of the calling entrypoint (for re-exec).
# @arg $@ remaining Original entrypoint arguments to preserve across re-exec.
talos_require_bash5() {
  local self_path="$1"
  shift || true
  local current_major="${BASH_VERSINFO[0]:-0}"
  local candidate=""
  local candidate_major=""

  if ! _talos_bash_preflight_needs_upgrade "${current_major}"; then
    return 0
  fi

  if [ -n "${TALOS_BASH_PREFLIGHT_REEXEC:-}" ]; then
    echo "[ERROR] Re-exec under a located Bash still reports Bash ${current_major}.x." >&2
    echo "[ERROR] Refusing to re-exec again to avoid a loop." >&2
    echo "[ERROR] Install Homebrew Bash 5 and verify it directly: brew install bash && /opt/homebrew/bin/bash --version" >&2
    exit 1
  fi

  for candidate in $(_talos_bash_preflight_candidates); do
    [ -x "${candidate}" ] || continue
    candidate_major="$(_talos_bash_preflight_version_major "${candidate}")"
    if ! _talos_bash_preflight_needs_upgrade "${candidate_major}"; then
      local candidate_dir=""
      candidate_dir="$(dirname "${candidate}")"
      export TALOS_BASH_PREFLIGHT_REEXEC=1
      export PATH="${candidate_dir}:${PATH}"
      exec "${candidate}" "${self_path}" "$@"
    fi
  done

  echo "[ERROR] This entrypoint requires Bash ${_TALOS_BASH_PREFLIGHT_MIN_MAJOR}+ (found Bash ${current_major}.x)." >&2
  echo "[ERROR] macOS ships Bash 3.2 by default; no supported Bash 5 was found at:" >&2
  for candidate in $(_talos_bash_preflight_candidates); do
    echo "[ERROR]   ${candidate}" >&2
  done
  echo "[ERROR] Install Homebrew Bash 5 and re-run:" >&2
  echo "[ERROR]   brew install bash" >&2
  echo "[ERROR] Then either open a shell where it is first on PATH, or invoke this entrypoint explicitly:" >&2
  echo "[ERROR]   /opt/homebrew/bin/bash ${self_path} $*" >&2
  exit 1
}

# @description Diagnostic-only check for required CLIs. Reports every
#   missing command in one message and returns non-zero; never installs or
#   configures anything.
# @arg $@ commands Required command names.
talos_require_commands() {
  local missing=()
  local cmd=""

  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "[ERROR] Missing required command(s): ${missing[*]}" >&2
    echo "[ERROR] Install them and re-run. This preflight check does not install or configure anything." >&2
    return 1
  fi

  return 0
}
