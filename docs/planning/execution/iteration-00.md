# Iteration 00 — establish local planning and review tracking

- Iteration: 0
- Repository: `talos-toolchain`
- Status: `DONE`
- Base branch: `lab`
- Baseline commit: `a84caae`
- Working branch: `docs/talos-projects-roadmap`
- Implementer: `Codex`
- Reviewer: `Claude Code`
- GitHub issue: `#3` (`https://github.com/al-rr/talos-toolchain/issues/3`)
- Optional pull request: not created
- VMware validation: not required

## Scope

### Files

- `AGENTS.md`
- `CLAUDE.md`
- `docs/planning/talos-projects-roadmap.md`
- `docs/planning/reviews/codex-initial-audit.md`
- `docs/planning/reviews/claude-independent-review.md`
- `docs/planning/execution/README.md`
- `docs/planning/execution/TEMPLATE.md`
- `docs/planning/execution/iteration-00.md`

### Acceptance criteria

- [x] Preserve both independent source reviews.
- [x] Establish one canonical consolidated roadmap.
- [x] Record explicit implementer and reviewer roles.
- [x] Define local-first review without requiring GitHub.
- [x] Link agent instructions to the canonical roadmap.
- [x] Complete independent review by Claude Code.
- [x] Record repository-owner acceptance.

## Implementation handoff

- Implementation commits: `bc11bc3` (`docs(planning): add consolidated Talos
  projects roadmap`).
- Uncommitted changes included: none at handoff.
- Local validation performed: Markdown structure, internal decision keywords,
  branch state, and staged-diff checks before commit.
- Known limitations: root workspace is not versioned; canonical copies now live
  in this repository. No remote issue or PR exists.

## Independent review

- Reviewer: Claude Code
- Exact commit reviewed: `16a261b` (`docs(planning): record iteration zero
  handoff`), which includes `bc11bc3` (`docs(planning): add consolidated
  Talos projects roadmap`) in its history. Both commits are in scope; the
  diff below covers both.
- Diff range: `a84caae...docs/talos-projects-roadmap` (equivalent to
  `a84caae..16a261b`; `a84caae` is confirmed identical to `lab`'s current
  tip via `git rev-parse`).

### Checks rerun

- `git branch --show-current`, `git status --short`, `git log --oneline
  a84caae..docs/talos-projects-roadmap`, `git rev-parse a84caae lab
  docs/talos-projects-roadmap` — confirmed branch, baseline, and the exact
  two-commit history stated in the handoff.
- `git diff --stat a84caae...docs/talos-projects-roadmap` — confirmed scope:
  8 files changed, 2,638 insertions, 0 deletions (purely additive), matching
  the file list declared in this record's own "Scope" section.
- `git diff` on `AGENTS.md` and `CLAUDE.md` individually — confirmed both are
  additive-only and both correctly point future agents at
  `docs/planning/talos-projects-roadmap.md` as the canonical decision
  document and at `docs/planning/reviews/` as historical/non-authoritative.
- Byte-for-byte `diff` of `docs/planning/reviews/codex-initial-audit.md`
  against root `/Users/ednil/projects/alerr/talos-projects/TALOS_REPOSITORIES_AUDIT_PLAN.md`,
  and `docs/planning/reviews/claude-independent-review.md` against root
  `/Users/ednil/projects/alerr/talos-projects/TALOS_REPOSITORIES_CLAUDE_REVIEW.md`
  — both **identical**. No transcription drift; the preserved copies are
  faithful.
- Read `AGENTS.md`, `CLAUDE.md`, `docs/planning/talos-projects-roadmap.md`,
  `docs/planning/execution/{README,TEMPLATE}.md`, and both preserved review
  documents in full.
- Section-by-section cross-check of the consolidated roadmap against both
  source reviews to confirm every owner decision listed in the task request
  is present and not weakened or inverted: `talos-toolchain` as CTL (§1,
  §11); Talos per-environment config owned by `talos-toolchain` under
  XDG/home (§6, §11); `gitopsctl`/`platformctl` as references only (§1,
  §11); `lab`→`lab`, `main`→`main` revision mapping (§1, §11); Milestone A
  local-macOS/no-VMware (§1, §9); VMware provisioning deferred to Milestone B
  (§11); Homebrew Bash 5 baseline (§8, §11); local-first
  implementation/review (§13, `AGENTS.md`, `CLAUDE.md`,
  `docs/planning/execution/README.md`); GitHub issues/PRs/reviewer
  assignment optional (§13, §16, §17, `AGENTS.md`, `CLAUDE.md`). All nine
  confirmed present, worded consistently with the source decisions, and not
  contradicted elsewhere in the document.
- Verified specific factual corrections from `claude-independent-review.md`
  actually carried into the roadmap rather than silently dropped: the
  `readlink -f` correction (roadmap §8: "not a confirmed blocker"), the
  `agenda.md`/Keepalived correction (roadmap §2: "role exists, but is not
  wired into the HAProxy playbook"), the Terraform `sensitive`-marking/no-
  backend-block finding (roadmap §2, lines 105-106), the `vars.local.sh`
  `.gitignore` glob mismatch (roadmap §2, line 111), the stray nested
  `talosconfig` (roadmap Iteration 1), the "port `TALOS_DAY1_*` back"
  question correctly reframed as an open decision rather than a settled
  recommendation (roadmap §12 item 2, which goes further and says "do not
  automatically port"), the branch-mismatch acceptance test explicitly
  reproducing the confirmed invalid case (roadmap Iteration 6), and the
  Cilium release-identity-by-construction nuance (roadmap §10 risk 8:
  "Release identity is aligned, but branch/content drift..."). All present
  and accurately restated. Also confirmed the stale "may be deliberate
  policy" hedge that `claude-independent-review.md`'s addendum flagged as an
  internal inconsistency in the base audit document was **not** carried into
  the roadmap — the roadmap states the branch mismatch as plain fact (§2),
  so that inconsistency was resolved, not propagated.
- `grep -n "^## "` over the roadmap — confirmed sections 1-17 are present,
  sequential, and non-duplicated.
- Scanned the full diff for secret-shaped patterns (`BEGIN ... KEY`,
  `password=`, `token=`) — no matches; all eight changed files are planning
  prose only.
- Confirmed every file path referenced by name inside the new documents
  (`docs/planning/execution/{README,TEMPLATE,iteration-00}.md`,
  `docs/planning/reviews/{codex-initial-audit,claude-independent-review}.md`,
  `docs/planning/talos-projects-roadmap.md`) exists on disk.
- Read the iteration-by-iteration plan (§13) end to end and traced the
  dependency chain implied by each iteration's stated repository and
  content, looking specifically for iterations that depend on prior work
  landing first but do not say so (see Corrections requested).
- Did not read, print, or reproduce the contents of any credential-shaped
  path. Did not run `talosctl`, `docker`, `colima`, `helm`, `kubectl`,
  `govc`, or `terraform`. Did not fetch, push, branch, tag, merge, or modify
  any file outside this record.

### Verdict

`CHANGES_REQUESTED`

The roadmap accurately consolidates both source reviews, correctly states
every owner decision listed in the review request without weakening or
reopening any of them, and measurably incorporates the great majority of the
prior independent review's corrections and recommendations (confirmed
above). No factual error, contradiction, or improperly reopened decision was
found. The corrections below are refinements to the planning document itself
(missing explicit dependency statements and a couple of missing acceptance-
criteria items), not defects in direction or substance, and are all within
Iteration 0's own scope (the roadmap document under review) — none rise to a
`FOLLOW_UP_ISSUE`.

### Corrections requested

1. **File:** `docs/planning/talos-projects-roadmap.md`, section "Iteration 5
   — local Talos cluster backend" (around line 560).
   **Reason:** This iteration adds new shell code to `talos-toolchain`
   (Docker/Colima cluster create/status/destroy workflow) that will run on
   the same macOS Bash 3.2 default this plan already documents as broken for
   `mapfile`/`declare -A`/`${var,,}` (§8). Iteration 4 explicitly states "Do
   not add the environment loader until this foundation passes on macOS,"
   but Iteration 5 has no equivalent statement despite being equally new
   shell code subject to the identical hazard.
   **Recommended change:** Add a line to Iteration 5 such as "Do not
   implement this workflow until the Bash 5/macOS contract in Iteration 3
   passes," mirroring Iteration 4's existing wording.

2. **File:** `docs/planning/talos-projects-roadmap.md`, section "Iteration 7
   — Cilium and Argo bootstrap handoff" (around line 595).
   **Reason:** Iteration 7's first bullet, "Verify identical environment
   revision and rendered Cilium content before bootstrap," presupposes
   Iteration 6's GitOps revision fix (`lab`→`lab`, `main`→`main`) already
   exists. No dependency on Iteration 6 is stated.
   **Recommended change:** Add an explicit "Depends on Iteration 6 landing
   first" note to Iteration 7, consistent with the explicit-dependency
   pattern already used between Iteration 3 and Iteration 4.

3. **File:** `docs/planning/talos-projects-roadmap.md`, section "6. Talos
   environment configuration contract" (around lines 250-268, the "Before
   sourcing shell files, verify..." rule) and/or "Iteration 4 — Talos
   environment configuration."
   **Reason:** The rule to verify regular-file type, current-user
   ownership, and absence of group/world write permission before sourcing a
   config file is scoped only to the *new* config loader.
   `claude-independent-review.md`'s addendum (§12) recommends the same check
   be retrofitted into the *existing* `load_overlay_vars` sourcing path in
   `talos-toolchain/scripts/talos/lib/common.sh` and
   `provision-talos-vsphere/overlays/base/scripts/functions.sh`, which today
   source `vars.sh`/`vars.local.sh` unconditionally. Risk #10 ("Untrusted
   shell sourcing") is generic enough to arguably cover this, but neither §6
   nor Iteration 4's scope says the check must extend to the pre-existing
   sourcing path, only to the new loader.
   **Recommended change:** Add one sentence to §6 or Iteration 4 clarifying
   that the same ownership/permission check must also be retrofitted into
   the existing `vars.sh`/`vars.local.sh` sourcing path in both
   repositories, not only the new loader.

4. **File:** `docs/planning/talos-projects-roadmap.md`, section "Iteration 5
   — local Talos cluster backend" or "Iteration 8 — local platform
   reconciliation."
   **Reason:** `claude-independent-review.md` §5 notes that Cilium 1.19.1 /
   cert-manager 1.20.0 / Longhorn 1.9.0 / kube-prometheus-stack 82.13.6
   compatibility against whatever Kubernetes version `talosctl cluster
   create docker` provisions "cannot be determined by static file
   inspection... is a legitimate first practical validation step" and
   "should be listed as an explicit acceptance check," not just assumed.
   Neither Iteration 5 nor Iteration 8 currently lists this as an explicit
   acceptance item.
   **Recommended change:** Add a bullet such as "Verify the pinned
   Cilium/cert-manager/Longhorn/kube-prometheus-stack chart versions are
   compatible with the Kubernetes version the local Docker cluster
   provisions" to Iteration 5 or Iteration 8.

5. **(Low priority, optional)** **File:**
   `docs/planning/talos-projects-roadmap.md`, section "2. Current repository
   map" → `talos-toolchain` current boundary problems (around lines 72-83).
   **Reason:** The duplication with `provision-talos-vsphere` is described
   one-directionally ("Some lifecycle scripts are duplicated and have
   drifted in `provision-talos-vsphere`"). `claude-independent-review.md`
   §3 established the duplication is bidirectional — `talos-toolchain` has
   roughly a dozen files (`argocd.sh`, `cilium.sh`, `cert-manager.sh`, and
   others) that `provision-talos-vsphere` entirely lacks — which is the
   actual basis for §12 item 2's "do not automatically port the older
   `TALOS_DAY1_*` mapping layer back" guidance. The roadmap's operative
   guidance already avoids the mistake this nuance guards against, so this
   is a wording clarity improvement, not a substantive defect.
   **Recommended change:** Optionally note that the duplication/drift runs
   in both directions, not only one repository being strictly ahead of the
   other.

### Follow-up work

No findings fall outside Iteration 0's scope; nothing here warrants a
separate `FOLLOW_UP_ISSUE` record. The natural next steps are already
represented in the roadmap itself:

- Iterations 1-12 remain `PLANNED` and unimplemented, exactly as the
  execution tracker (§17) states; this review does not authorize or begin
  any of them.
- Credential rotation for the six tracked files identified in
  `claude-independent-review.md` §2 remains an explicit owner-authorized
  action (Iteration 1) and was not performed, inspected, or printed during
  this review.
- Corrections 1-5 above should be applied to
  `docs/planning/talos-projects-roadmap.md` by the implementer (Codex) as a
  small follow-up documentation commit within this same Iteration 0 scope,
  then re-submitted for a short confirmation pass before this record moves
  to `DONE`.

### Correction implementation

- Implementer: Codex.
- Scope remained limited to this execution record and
  `docs/planning/talos-projects-roadmap.md`.
- All five requested corrections were applied: explicit Iteration 3 → 5 and
  Iteration 6 → 7 dependencies; existing loader permission checks added to the
  environment contract; local chart/Kubernetes compatibility added to
  Iteration 8; bidirectional lifecycle drift clarified.
- GitHub tracking was created in the repository that owns the work:
  `al-rr/talos-toolchain#3`. The orchestration repository is only a
  cross-repository coordinator and does not own these changes.
- Local validation and bounded independent confirmation are required before
  the verdict can change from `CHANGES_REQUESTED` to `APPROVED`.

### Correction confirmation

- Reviewer: Claude Code, new bounded session because the original review
  session ID was not recorded.
- Verdict: `VERIFIED`.
- Scope: only the roadmap ranges containing the five corrections and the
  execution-record metadata/correction summary; no other repository was read.
- Commands were restricted to `rtk sed`, `rtk git diff --check`, and
  `rtk git status --short`; no file was edited by the reviewer.
- Usage: 7 turns, 1,295 output tokens, 18,796 cache-creation tokens, 47,520
  cache-read tokens, and USD 0.147493 estimated CLI equivalent under a USD 0.30
  guard. The account uses subscription limits rather than API-key billing.
- Verified evidence: bidirectional lifecycle drift at roadmap lines 74-77;
  existing vars sourcing checks at lines 253-255; Iteration 5 dependency at
  lines 568-569; Iteration 7 dependency at lines 606-607; local chart/Kubernetes
  compatibility at lines 627-630; issue and correction ownership in this
  record.
- Raw prompt/result envelopes remain only in the ignored workspace
  `.agent-runs/` area and must not be committed.

## Owner decision

- Accepted for local `lab`: yes, after PR merge.
- Remote publication authorized: yes, including PR and merge to `lab`.
- Notes: no new tags are created until all planned iterations are complete.
