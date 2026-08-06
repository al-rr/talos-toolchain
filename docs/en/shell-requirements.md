# Shell Requirements

## Supported contract

`scripts/talos/cluster.sh` and `scripts/talos/talos-gitops.sh` are the two
maintained, user-facing entrypoints. Both require **Bash 5+**. Their internal
dispatched scripts (`cluster-bootstrap.sh`, `apply-post-bootstrap.sh`,
`sync-kubectl.sh`, `sync-talosctl.sh`, `govc/provision-cluster.sh`, and
others) use Bash-5-only syntax (`mapfile`, `declare -A`) and are not meant to
be invoked directly; they are only supported when launched through
`cluster.sh` or `talos-gitops.sh`.

macOS ships Bash 3.2 by default (`/bin/bash`), which cannot run this syntax.
The supported macOS shell is Homebrew Bash 5.

## Preflight behavior

Both entrypoints source `scripts/talos/lib/bash-preflight.sh` before any
Bash-5-only code path runs:

- If the running interpreter is already Bash 5+, execution continues
  unchanged.
- If it is Bash 3.2 (or any Bash below 5), the preflight looks for a Bash 5
  binary at explicit, fixed candidate paths only:
  - `/opt/homebrew/bin/bash`
  - `/usr/local/bin/bash`
  - `/usr/local/opt/bash/bin/bash`

  No PATH search and no package manager query is performed. If a candidate
  qualifies, the entrypoint re-execs itself under that Bash and prepends its
  directory to `PATH`, so any script it subsequently dispatches via
  `#!/usr/bin/env bash` resolves the same Bash 5 interpreter.
- If no candidate qualifies, the entrypoint stops before running any
  incompatible syntax and prints an actionable error, including the
  `brew install bash` command and an explicit invocation example. It never
  installs or reconfigures anything on the host.

A second, unresolved failure (e.g. a broken Homebrew Bash install) is
detected and refused rather than causing a re-exec loop.

To install Bash 5 — along with the rest of the macOS host tooling — use the
opt-in `scripts/host/setup-macos.sh` (see `docs/en/host-setup.md`). It is a
separate, explicit operator action: the preflight above still only diagnoses,
and no lifecycle entrypoint ever invokes the setup script.

## CLI preflight

Each entrypoint also checks, per selected action, that the external commands
that action needs (for example `talosctl`, `govc`, `kubectl`, `helm`, `curl`)
are present on `PATH` before doing any work. This check is diagnostic only:
it reports every missing command in one message and exits; it never installs
or configures anything.

## CLI version/compatibility contract

The preflight only checks that each required CLI is present on `PATH`; it
never checks a version. This section states the compatibility rule an
operator must satisfy for each CLI, so that presence-only detection does not
silently allow a version mismatch. This repository has no repository-wide
version pin for any of these tools — the source of truth is always the
per-project selection made through `vars.sh`/`--talos-version`, not a value
baked into the toolchain.

- **`talosctl`**: match the Talos release selected for the project via
  `cluster.sh refresh-schematics --talos-version=vX.Y.Z` (or the version
  embedded in the project's `TALOS_OVA_PATH`/installer image tags in
  `vars.sh`). `talosctl` enforces its own client/server version skew against
  the Talos API, so use the client build that matches that project's Talos
  version, not a fixed version chosen by this repository.
- **`kubectl`**: stay within the standard Kubernetes client/server version
  skew policy (kubectl within one minor version, older or newer, of the
  cluster's Kubernetes version) relative to the Kubernetes version that the
  project's selected Talos release ships. Talos pins the Kubernetes version
  per Talos release, not this toolchain, so there is no fixed `kubectl`
  version here either.
- **`helm`**: use a Helm release compatible with the target cluster's
  Kubernetes version according to Helm's own support matrix (not tied to a
  specific Helm major version). This repository does not select Helm chart
  versions or pin Helm itself; chart/version ownership for cluster addons
  lives in `talos-vsphere-gitops`.
- **`govc`**: any `govc` build compatible with the target vCenter/ESXi API
  version of the consuming environment. vSphere endpoint/version selection is
  out of scope for this environment-agnostic repository; it belongs to the
  consuming lab/environment repository (e.g. `provision-talos-vsphere`).
- **`curl`**: any current `curl` with HTTPS/TLS support. It is only used to
  call the Talos Factory schematic API (`create-project`,
  `refresh-schematics`); no specific version is required.

## Docker/Colima

The `cluster.sh`/`talos-gitops.sh` Bash-5 preflight contract above does not
cover a Docker/Colima execution backend. That is a separate Milestone-A
entrypoint, `scripts/talos/local-cluster.sh`, with its own Bash 5 preflight
and its own `talosctl`/Docker/Colima CLI preflight — see
`docs/en/local-cluster.md`.

## Known limitations

- The preflight targets Homebrew's default install locations. A Bash 5
  installed at a non-standard path is not detected automatically; invoke the
  entrypoint explicitly with that interpreter instead
  (`/path/to/bash5 scripts/talos/cluster.sh ...`).
- Scripts other than `cluster.sh` and `talos-gitops.sh` are not directly
  covered by the preflight guard; run them only through the two supported
  entrypoints.
