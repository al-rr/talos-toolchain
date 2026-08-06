# macOS Host Setup

## Purpose

`scripts/host/setup-macos.sh` installs the tooling an operator's macOS
workstation needs to run this repository's lint and offline test suite. It
exists because that tooling was previously only described in prose, scattered
across several documents, so a fresh Mac failed checks with no single command
to fix it.

It is host tooling only. It installs no cluster client and no container
runtime.

## What it manages

| Tool | Formula | Why it is needed |
| --- | --- | --- |
| Bash 5+ | `bash` | Every toolchain entrypoint requires it; macOS ships Bash 3.2 |
| `yamllint` | `yamllint` | `scripts/talos/tests/test-yaml-style.sh` |
| `shellcheck` | `shellcheck` | Static analysis of the scripts under `scripts/` |

## Usage

```bash
# Report what is installed and what is missing; changes nothing
./scripts/host/setup-macos.sh check

# Install what is missing (preview first)
./scripts/host/setup-macos.sh install --dry-run
./scripts/host/setup-macos.sh install
```

`check` exits `2` when anything is missing, so it is usable as a gate in a
wrapper script.

## What it deliberately does not do

- **It is not wired into any lifecycle entrypoint.** Running setup stays an
  explicit operator decision. `cluster.sh`, `local-cluster.sh`, and
  `talos-gitops.sh` never call it.
- **It does not install cluster clients** — `talosctl`, `kubectl`, `helm`,
  `cilium` — or a container runtime such as Colima or Docker. Those carry
  version-pinning and resource decisions that must track a specific cluster,
  not a workstation. On the Vagrant lab controller, the versioned installers
  under `provision-talos-vsphere/overlays/lab/controller/scripts/` own that
  job.
- **It never runs `sudo`**, never edits shell rc files, never changes your
  login shell, and never contacts a cluster.

## Its relationship to the Bash 5 preflight

`scripts/talos/lib/bash-preflight.sh` **diagnoses** a missing Bash 5 and stops
with an actionable message. It never installs anything, and
`scripts/talos/tests/test-bash-preflight.sh` asserts that its message does not
even imply installation.

That separation is intentional and this script does not change it: the
preflight still only reports, and installation remains a separate, explicit
action. Homebrew's Bash 5 is installed *alongside* the system Bash 3.2 — it
does not replace it, and your login shell is untouched. The entrypoints locate
it themselves at the fixed paths the preflight accepts.

## Running it on a Bash 3.2 host

The script must run under macOS's stock Bash 3.2, because it is what installs
Bash 5. It therefore avoids `mapfile`, associative arrays, and other Bash 4+
syntax. Keep it that way when editing: a Bash 5 dependency here would make it
impossible to run on exactly the host that needs it most.
