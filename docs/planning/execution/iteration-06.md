# Iteration 06 — Bash preflight test isolation

- Status: `IMPLEMENTED — local checks passing, awaiting Codex review`
- Repository: `talos-toolchain`
- Issue: [#13](https://github.com/al-rr/talos-toolchain/issues/13)
- Branch: `fix/issue-013-bash-preflight-test-isolation`
- Scope: make Bash preflight fixture tests independent of host-installed Bash
  5 while preserving production preflight behavior.

## Impact

- `talos-toolchain`: only repository changed.
- `provision-talos-vsphere` and `talos-vsphere-gitops`: unchanged.

## Acceptance

- Preflight fixture tests pass both with and without Homebrew Bash 5.
- Re-exec, no-candidate and loop-guard cases remain explicitly covered.
- Production preflight behavior is unchanged unless a demonstrated defect
  requires a separately reviewed adjustment.
- Existing offline suites pass.

## Implementation notes

Root cause: `talos_require_bash5` computed `current_major` inline from
`BASH_VERSINFO[0]`, which is fixed by whichever interpreter actually runs the
test process. On a host with a real Homebrew Bash 5 on `PATH` (this host:
`/opt/homebrew/bin/bash` 5.3.15), `test-bash-preflight.sh` itself executes
under Bash 5, so the function short-circuited via its own "already 5+" check
before ever reaching the candidate/re-exec/loop-guard logic the fixture
subshells were trying to exercise — 5 of 14 prior assertions failed
non-deterministically depending on host Bash.

Fix: extracted the inline read into
`_talos_bash_preflight_current_major()` in `lib/bash-preflight.sh` (same
value, `BASH_VERSINFO[0]:-0`, no behavior change), mirroring the existing
`_talos_bash_preflight_candidates` override pattern. Each fixture subshell in
`tests/test-bash-preflight.sh` now overrides
`_talos_bash_preflight_current_major` to a fixed synthetic major (`3`),
isolating the re-exec, no-candidate, and loop-guard cases from the host
interpreter. Added a new regression case overriding it to `5` to assert the
already-Bash-5+ host path no-ops without consulting candidates or re-execing.

Verified: `bash scripts/talos/tests/test-bash-preflight.sh` (16/16 pass, was
9/14) both under `/opt/homebrew/bin/bash` 5.3.15 and under `/bin/bash` 3.2.57
— same 16/16 result either way, confirming determinism. Also ran
`test-syntax.sh` (includes shellcheck, 0 failing) and `test-yaml-config.sh`
(68/68 pass), both unaffected. `test-yaml-style.sh` not run: `yamllint` is
not installed on this host. `git diff --check`: clean.

No operator-facing behavior changed, so EN/PT-BR docs were not touched.
