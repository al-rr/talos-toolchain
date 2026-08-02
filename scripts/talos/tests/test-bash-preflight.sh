#!/usr/bin/env bash
# @file test-bash-preflight.sh
# @brief Offline fixture tests for lib/bash-preflight.sh.
# @description
#   Hand-rolled harness (Bats is not available on this host). Exercises the
#   preflight's decision logic without requiring a real Bash 5 binary: the
#   version-comparison helper is tested directly with synthetic majors, and
#   the candidate/re-exec path is tested against fixture executables under
#   tests/fixtures/. Runs no Talos, Kubernetes, Helm, or VMware operation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "${SCRIPT_DIR}/../lib" && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

# shellcheck disable=SC1091
source "${LIB_DIR}/bash-preflight.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "[PASS] $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "[FAIL] $1"
}

assert_eq() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    pass "${description}"
  else
    fail "${description} (expected '${expected}', got '${actual}')"
  fi
}

# --- _talos_bash_preflight_needs_upgrade: pure version-comparison logic ---

if _talos_bash_preflight_needs_upgrade "3"; then
  pass "Bash major 3 is reported as needing upgrade"
else
  fail "Bash major 3 should need upgrade"
fi

if _talos_bash_preflight_needs_upgrade "4"; then
  pass "Bash major 4 is reported as needing upgrade"
else
  fail "Bash major 4 should need upgrade"
fi

if ! _talos_bash_preflight_needs_upgrade "5"; then
  pass "Bash major 5 is reported as supported (no upgrade needed)"
else
  fail "Bash major 5 should not need upgrade"
fi

if ! _talos_bash_preflight_needs_upgrade "6"; then
  pass "Bash major 6 is reported as supported"
else
  fail "Bash major 6 should not need upgrade"
fi

if _talos_bash_preflight_needs_upgrade ""; then
  pass "Empty/undetected version is treated as needing upgrade"
else
  fail "Empty version should be treated as needing upgrade"
fi

# --- talos_require_commands: diagnostic-only missing CLI reporting ---

if talos_require_commands bash sh >/dev/null 2>&1; then
  pass "talos_require_commands succeeds when all commands are present"
else
  fail "talos_require_commands should succeed for bash/sh"
fi

missing_output="$(talos_require_commands definitely-not-a-real-command-xyz 2>&1 || true)"
if [[ "${missing_output}" == *"definitely-not-a-real-command-xyz"* ]]; then
  pass "talos_require_commands reports the missing command by name"
else
  fail "talos_require_commands did not report missing command: ${missing_output}"
fi

if ! talos_require_commands definitely-not-a-real-command-xyz >/dev/null 2>&1; then
  pass "talos_require_commands returns non-zero for a missing command"
else
  fail "talos_require_commands should return non-zero for a missing command"
fi

if [[ "${missing_output}" != *"brew install"* && "${missing_output}" == *"does not install"* ]]; then
  pass "talos_require_commands never claims it will install anything"
else
  fail "talos_require_commands message unexpectedly implies installation: ${missing_output}"
fi

# --- talos_require_bash5: re-exec against a fake Bash 5 candidate fixture ---
#
# All talos_require_bash5 scenarios below override
# _talos_bash_preflight_current_major to a fixed synthetic value inside an
# isolated subshell. This decouples the assertions from whichever Bash
# interpreter actually runs this test file (e.g. a real Homebrew Bash 5 on
# PATH), which would otherwise make talos_require_bash5 return early via its
# own "already Bash 5+" short-circuit and skip the candidate/re-exec/
# loop-guard logic entirely.

marker_file="$(mktemp -t talos-preflight-marker.XXXXXX)"
rm -f "${marker_file}"

(
  _talos_bash_preflight_current_major() { printf '%s\n' "3"; }
  _talos_bash_preflight_candidates() {
    printf '%s\n' "${FIXTURES_DIR}/fake-bash5"
  }
  export TALOS_PREFLIGHT_TEST_MARKER="${marker_file}"
  talos_require_bash5 "/does/not/matter/entrypoint.sh" --some-arg
)

if [[ -f "${marker_file}" ]]; then
  marker_contents="$(cat "${marker_file}")"
  assert_eq "re-exec candidate receives the entrypoint path and args" \
    "/does/not/matter/entrypoint.sh --some-arg" "${marker_contents}"
  rm -f "${marker_file}"
else
  fail "talos_require_bash5 did not re-exec into the fixture Bash 5 candidate"
fi

# --- talos_require_bash5: no candidate available -> actionable error, exit 1 ---

no_candidate_output=""
no_candidate_status=0
no_candidate_output="$(
  _talos_bash_preflight_current_major() { printf '%s\n' "3"; }
  _talos_bash_preflight_candidates() {
    printf '%s\n' "${FIXTURES_DIR}/does-not-exist-bash"
  }
  talos_require_bash5 "/does/not/matter/entrypoint.sh" 2>&1
)" || no_candidate_status=$?

assert_eq "talos_require_bash5 exits 1 when no Bash 5 candidate is found" "1" "${no_candidate_status}"
if [[ "${no_candidate_output}" == *"brew install bash"* ]]; then
  pass "no-candidate error message is actionable (mentions brew install bash)"
else
  fail "no-candidate error message missing installation guidance: ${no_candidate_output}"
fi

# --- talos_require_bash5: re-exec guard prevents an infinite loop ---

loop_guard_output=""
loop_guard_status=0
loop_guard_output="$(
  export TALOS_BASH_PREFLIGHT_REEXEC=1
  _talos_bash_preflight_current_major() { printf '%s\n' "3"; }
  _talos_bash_preflight_candidates() {
    printf '%s\n' "${FIXTURES_DIR}/fake-bash5"
  }
  talos_require_bash5 "/does/not/matter/entrypoint.sh" 2>&1
)" || loop_guard_status=$?

assert_eq "talos_require_bash5 refuses a second re-exec attempt" "1" "${loop_guard_status}"
if [[ "${loop_guard_output}" == *"loop"* ]]; then
  pass "re-exec loop guard message explains the refusal"
else
  fail "re-exec loop guard message unclear: ${loop_guard_output}"
fi

# --- talos_require_bash5: host already reports Bash 5+ -> immediate no-op ---
#
# Regression for a host with a real Homebrew Bash 5 installed (as opposed to
# the synthetic "major 3" scenarios above): talos_require_bash5 must return
# 0 immediately without consulting candidates or re-execing anything.

host_bash5_status=0
host_bash5_marker="$(mktemp -t talos-preflight-host-marker.XXXXXX)"
rm -f "${host_bash5_marker}"

(
  _talos_bash_preflight_current_major() { printf '%s\n' "5"; }
  _talos_bash_preflight_candidates() {
    echo "candidates should not be consulted when already on Bash 5+" >&2
    printf '%s\n' "${FIXTURES_DIR}/fake-bash5"
  }
  export TALOS_PREFLIGHT_TEST_MARKER="${host_bash5_marker}"
  talos_require_bash5 "/does/not/matter/entrypoint.sh"
) || host_bash5_status=$?

assert_eq "talos_require_bash5 no-ops on a host already reporting Bash 5+" "0" "${host_bash5_status}"
if [[ -f "${host_bash5_marker}" ]]; then
  fail "talos_require_bash5 re-execed even though the host already reports Bash 5+"
  rm -f "${host_bash5_marker}"
else
  pass "talos_require_bash5 does not re-exec when the host already reports Bash 5+"
fi

echo ""
echo "bash-preflight tests: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "${FAIL_COUNT}" -eq 0 ]]
