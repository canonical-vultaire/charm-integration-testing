# Development Sandbox

A sandbox instance with Copilot and development tools for charm integration
testing. Multipass remains the default; LXD can provide either a VM or an
unprivileged container. Your checkout is mounted into the instance, so edits are
visible on the host.

## Quick start

On an amd64 host with [GitHub CLI](https://cli.github.com/) installed and either
[Multipass](https://canonical.com/multipass) (the default) or a configured local
LXD installation, run from the repository root:

```bash
cp development-sandbox/.env.sample development-sandbox/.env
# Configure credentials and optional settings in .env.
scripts/sandbox.sh up
scripts/sandbox.sh run --interactive
```

For LXD, set `SANDBOX_BACKEND=lxd` or `SANDBOX_BACKEND=lxd-container` in
`development-sandbox/.env` before running `up`. The host must have LXD 5.21 or
newer initialized, a default storage pool configured, and the current user
authorized to use the local LXD daemon. The LXD remote alias defaults to `local`;
override it with `SANDBOX_LXD_REMOTE` if needed. Do not select a remote server,
because the project mount uses a host path.

Both LXD backends align the guest `ubuntu` UID/GID with the host account on
first setup, and pin that identity to the instance. Use a different
`SANDBOX_VM` for another host account. The VM backend shares the host path
directly; the `lxd-container` backend uses LXD's shifted mount to provide that
mapping in an unprivileged container. It installs `sudo` and `snapd` but does
not enable nested LXD, Docker, or Kubernetes services. The host kernel and
project filesystem must support LXD's shifted/idmapped mounts. Container
sandboxes are for development and remote-cloud workflows; local
`/setup-lxd` and `/setup-k8s` provisioning requires a VM. Use a different
`SANDBOX_VM` name when switching between an LXD VM and container, because they
share an instance namespace.

The `lxd` backend selects an LXD VM as the sandbox. Inside that VM,
`/setup-lxd` can configure a separate local LXD substrate for Juju testing.

Ask Copilot to develop or test a validator, reproduce a failure, or review a PR.
Skills such as `/setup-k8s`, `/setup-lxd`, `/develop-validator`, and `/test-validator`
handle substrate setup and testing.

## Copilot CLI arguments

Pass Copilot CLI arguments after `--`, for example:
`scripts/sandbox.sh run --interactive -- --continue`.
For autonomous runs, put the task before `--`.

Use `--resume [SESSION]` (or `-r`) to resume a session; without a value, it opens
the session picker. `--continue` resumes the most recent session. See `copilot --help`
inside the sandbox for other CLI arguments.

Run `scripts/sandbox.sh --help` for sandbox lifecycle and agent options.

## Instance setup

`up` installs the stable Mise Snap, then prepares the sandbox toolchain from the
repository catalogue.

`scripts/sandbox.sh up`, `run`, and `shell` set `UV_PROJECT_ENVIRONMENT` to store
Python dependencies under
`~/.local/share/charm-integration-testing/venvs/<checkout-path-hash>` (or
`$XDG_DATA_HOME/charm-integration-testing/venvs/<checkout-path-hash>` when set).
The hash uses the canonical instance checkout path, so different mounts have
separate environments. Each shell or agent session keeps the environment for
its mount; use the other checkout's `scripts/sandbox.sh shell` or `run` to work
on that project.
Host commands continue using the checkout's `.venv`; sandbox setup leaves it
untouched. Run `scripts/sandbox.sh up` again to configure an existing sandbox.

For substrate prerequisites and provisioning, follow the
[Kubernetes](../.agents/skills/setup-k8s/SKILL.md) or
[LXD](../.agents/skills/setup-lxd/SKILL.md) setup steps. Provisioning does not
install or refresh packages. For Chaos Mesh on an existing cluster, follow the
[existing-cluster procedure](../.agents/skills/setup-k8s/SKILL.md#set-up-chaos-mesh-on-an-existing-cluster).

To select another Juju client before provisioning, follow
[Juju client selection](../CONTRIBUTING.md#selecting-the-juju-client).

## Configuration

Set options in `development-sandbox/.env` (gitignored). See
[`.env.sample`](.env.sample) for all settings.

| Option | Purpose |
|---|---|
| `SANDBOX_VAR_GITHUB_TOKEN` | Fine-grained PAT; recommended permissions below |
| `SANDBOX_VAR_COPILOT_GITHUB_TOKEN` | Token for Copilot authentication |
| `SANDBOX_VAR_COPILOT_MODEL` | Optional model override; otherwise Copilot CLI uses its default |
| `SANDBOX_CPUS` / `SANDBOX_MEMORY` / `SANDBOX_DISK` | Instance limits at creation (defaults: `8` / `16G` / `80G`) |
| `SANDBOX_BACKEND` | `multipass` (default), `lxd` VM, or `lxd-container` |
| `SANDBOX_LXD_REMOTE` | Local LXD remote alias (default: `local`) |
| `SANDBOX_VM` / `SANDBOX_MOUNT` | Instance name and mount path; use a unique mount path for each checkout sharing an instance |

Multipass and LXD maintain separate instance namespaces; LXD VMs and containers
share one, so give them different names. Select the same backend for `up`,
`shell`, `run`, `down`, and `destroy`. `destroy` permanently removes the instance
from the selected backend.

For read-only tasks, limit `SANDBOX_VAR_GITHUB_TOKEN` to the repositories you need:

| Repository permission | Access |
|---|---|
| Contents | Read-only |
| Issues | Read-only |
| Pull requests | Read-only |
| Actions | Read-only |

Grant write access only for tasks that need it: Pull requests for posting reviews,
Issues for filing bugs, and Contents for pushing changes.

Without dedicated tokens, the script asks before using your host `gh` token in the
VM. That token carries your host permissions; prefer narrowly scoped tokens.
Declining leaves the corresponding tools unauthenticated.

Host-side GitHub API calls use `GITHUB_TOKEN` or the host's `gh` token. Automatic
SSH signing-key registration requires the `write:ssh_signing_key` scope.

## Chaos Mesh

Sandbox Kubernetes setup installs Chaos Mesh components but does not run chaos
experiments. Shared CI clusters are provisioned separately.

## Recommended MCP servers

Copy the optional [sample](mcp.json.sample), replace the credential placeholders,
and remove any servers you do not need:

```bash
cp development-sandbox/mcp.json.sample development-sandbox/mcp.json
```

The sample uses `{"mcpServers": {...}}`; add separately named entries for other
services or environments, such as Test Observer staging, with their own endpoint
and token. Do not commit credentials. Set this in `development-sandbox/.env`:

```
SANDBOX_MCP_CONFIG_FILE=development-sandbox/mcp.json
```

This applies to both interactive and autonomous `run` sessions.
Sandbox setup includes Go and uvx; rerun `scripts/sandbox.sh up` to prepare them
in older VMs.

Any host environment variable prefixed with `SANDBOX_VAR_` is passed into the VM
with that prefix removed. API overrides must be reachable from inside the VM.

The root `.copilotignore` uses path-independent patterns for local credential
files. It does not protect process
environments or the sandbox's temporary MCP config outside the checkout.
Assume an unrestricted agent can read and use any credentials available to its
user, regardless of ignore files.

### GitHub

Built into Copilot CLI; no additional configuration needed.

### Jira

Create a [Jira API token](https://id.atlassian.com/manage-profile/security/api-tokens)
and set `JIRA_USERNAME` to your Atlassian account email.

### Test Observer

Ask SQA for a Test Observer API token. The launcher requires authenticated `gh`
in the VM with read access to the private repository; the other prerequisites
are installed by default.
