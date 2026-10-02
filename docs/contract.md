# Policy contract

Every `microvm.ncl` is checked against this contract before anything is built:
an unknown field or a wrong type is an error. Every field except `project` has
a default. A policy ends with `| c.Policy`, where `c` is the installed contract:

```nickel
let c = import "/run/current-system/sw/share/vm-launcher/contract.ncl" in
{ project = "/home/alice/src/myproject", … } | c.Policy
```

`vm-launcher --show` prints the policy with every default filled in. This page
lists the fields. [Writing a policy](policies.md) walks through them by example,
and the [verbatim contract](#the-contract-verbatim) is at the bottom.

Things that are **not** policy fields, on purpose: the network posture override
([`--egress`](cli.md#launching)) and the launch mode (`--detach`, `--console`).
Those belong to the operator, so a project's own policy can't loosen its
sandbox.

## Project and shares

| Field | Type | Default | Meaning |
|---|---|---|---|
| `project` | string | **required** | Absolute host path of the project, mounted at `/work`. |
| `work.default` | `'rw` \| `'ro` | `'rw` | Mode of the whole `/work` share. |
| `work.readOnly` | [string] | `[]` | Subpaths (relative to the project) forced read-only, as real mounts. Put `envs/vm` here so the agent can't rewrite its own policy. |
| `work.hidden` | [string] | `[]` | Subpaths hidden entirely (`.env`, `secrets/`). |
| `inputs` | [string] | `[]` | Absolute host paths mounted read-only at `/inputs/<basename>`. |
| `shares` | [{`source`, `mountPoint`, `readOnly`}] | `[]` | Host paths at a chosen guest path, read-write by default. Every parent of `mountPoint` must exist at boot (`/mnt`, `/srv`, `/opt`, `/var/lib` are safe). |
| `stateDir` | string | `""` | Per-project persistent state on the host (agent history, logins, logs). `""` → `~/.local/state/microvm/<project-basename>/`. |

## Network

See [Network and egress](network.md).

| Field | Type | Default | Meaning |
|---|---|---|---|
| `egress.hosts` | [string] | `["api.anthropic.com"]` | Hostnames the in-guest proxy lets through; everything else is refused. |
| `egress.none` | bool | `false` | No network at all (airgap). A policy can tighten its posture, never loosen it. |
| `proxyAuth` | [{`host`, `header`, `valueTemplate`}] | `[]` | Headers the proxy injects into requests to `host`. `valueTemplate` renders `${NAME}` from `'proxy` secrets. See [secrets the agent must not see](credentials.md#secrets-the-agent-must-not-see). |

## Credentials and environment

See [Credentials and logins](credentials.md).

| Field | Type | Default | Meaning |
|---|---|---|---|
| `auth` | `'bind` \| `'ephemeral` | `'bind` | `'bind`: the host's agent config dirs are mounted read-only. `'ephemeral`: nothing is mounted and the agent starts blank. |
| `secrets` | [{`source`, `env`, `scope`}] | `[]` | Host files (0600) exported as `env` in the guest. `scope = 'agent` (default): the agent can read it. `'proxy`: only the egress proxy sees it. |
| `env` | {NAME = string} | `{}` | Literal, non-secret variables for the agent's shell and the startup hooks. Names must match `[A-Z_][A-Z0-9_]*`. E.g. `ENABLE_CLAUDEAI_MCP_SERVERS = "false"` ([connectors](connectors.md)). |
| `git.name`, `git.email` | string | `""` | Commit identity in the guest. `""` → the host's, marked `(vm-launcher)` / `+vmlaunch`. |
| `git.allowedGithubOrgs` | [string] | `[]` | Orgs/users (`"my-org"`) or `org/repo` pairs. Other GitHub URLs are rewritten to `blocked.invalid`. A soft layer; the allowlist and token scope are the hard one. |

## Tools and resources

See [tools](policies.md#tools-where-packages-come-from) and
[resources](policies.md#resources).

| Field | Type | Default | Meaning |
|---|---|---|---|
| `tools` | [string] | `["coreutils", "bashInteractive", "git", "jq", "gnused", "claude-code"]` | nixpkgs attribute names put on the guest's `PATH`. Checked before the build. Declared agents add their own package. |
| `resources.vcpu` | number | `4` | Virtual CPUs. |
| `resources.memMb` | number | `4096` | Guest memory. Above the host's total: error; above what's free: warning. |
| `r.packages` | [string] | `[]` | CRAN packages (`rPackages.<name>`); puts an `R` / `Rscript` that sees them on `PATH`. |
| `julia.env` | string | `"env/julia"` | Julia env relative to the project; becomes `JULIA_PROJECT`. |

## Boot and session

| Field | Type | Default | Meaning |
|---|---|---|---|
| `startup.commands` | [{`command`, `onFailure`}] | `[]` | Run at boot, before any shell, as the agent user in `/work`. `onFailure = 'warn` (default) logs and continues; `'block` fails the boot. |
| `startup.tools` | [string] | `[]` | A narrower `PATH` for the startup commands only (`[]` = the full `tools`). |
| `startup.logFile` | string | `""` | Where command output goes. `""` → `<stateDir>/startup.log` (`/tmp/vm-launcher-startup.log` with `auth = 'ephemeral`). |
| `session.ssh` | bool | `true` | sshd on the slot's host-only address, for [`attach`](running.md). Off means console only: no `attach`, no `--detach`. |
| `session.multiplex` | `'none` \| `'tmux` \| `'auto` | `'none` | tmux on the console: a window per agent. `'auto` = tmux when more than one agent is declared. |
| `console` | `'hvc0` \| `'ttyS0` | `'hvc0` | Console device for `--console` sessions; `'ttyS0` is slow, for debugging only. |
| `loginMessage` | string | `""` | Extra banner for the human at login (agent guidance goes in `agent.instructions`). |
| `guest.hostname`, `guest.username` | string | `""` | `""` → project basename / host `$USER` + `-vm`. |

## Agents

`agent` is the default agent; `extraAgents` adds more to the same VM. Both take
an **agent profile**, where `preset` fills in every other field. See
[Agents](policies.md#agents).

| Field | Type | Default (`'claude` / `'codex`) | Meaning |
|---|---|---|---|
| `preset` | `'claude` \| `'codex` | `'claude` | Picks the defaults below. |
| `name` | string | `claude` / `codex` | Names `<name>-run`, the state namespace, the tmux window. Must be unique. |
| `package` | string | `claude-code` / `codex` | nixpkgs attribute added to the guest. |
| `command` | string | `claude` / `codex` | Binary the run wrapper executes. |
| `flags` | [string] | `--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox` | Baked into `<name>-run`. |
| `instructions` | string | `""` | Project guidance appended to the agent's instructions file. |
| `instructionsFile` | string | `CLAUDE.md` / `AGENTS.md` | Name of that file. |
| `configDir` | string | `.claude` / `.config/codex` | The agent's config dir, relative to `$HOME`. |
| `configGuest` | string | `/var/lib/claude` / `/var/lib/codex` | Where the read-only host copy is mounted in the guest. |
| `configEnv` | string | `""` / `CODEX_HOME` | Variable pointing the agent at its config dir. |
| `configMode` | `'symlinks` \| `'writable` | `'symlinks` / `'writable` | How the config dir is built; see [the table](policies.md#how-the-agent-s-config-dir-is-built). |
| `seedFiles` | [string] | `[]` / `auth.json`, `config.toml` | `'writable`: copied from the host at every boot. |
| `stateDirs` | [string] | `projects`, `todos`, `session-env`, `shell-snapshots`, `file-history`, `paste-cache` / `[]` | `'symlinks`: subdirs kept in the state dir. |
| `stateFiles` | [string] | `history.jsonl` / `[]` | `'symlinks`: files in the config dir kept in the state dir (written in place). |
| `homeStateFiles` | [string] | `.claude.json` / `[]` | Files next to the config dir in `$HOME`, kept in the state dir. |
| `syncFiles` | [string] | `[]` | `'symlinks`: files the agent replaces atomically, restored at boot and copied back on change. `[".credentials.json"]` gives a VM [its own login](credentials.md#option-b-the-guest-s-own-login). |
| `taskDir` | string | `tasks` / `""` | Writable task-tracker dir under `configGuest`. |

## The contract, verbatim

The source of truth, with every field's full commentary:
[`policy/contract.ncl`](../policy/contract.ncl), installed at
`/run/current-system/sw/share/vm-launcher/contract.ncl`.

<<< ../policy/contract.ncl{nickel}
