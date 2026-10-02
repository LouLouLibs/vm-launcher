# Writing a policy

A policy is a Nickel record checked against the contract
(`/run/current-system/sw/share/vm-launcher/contract.ncl`, source
[`policy/contract.ncl`](../policy/contract.ncl)). Unknown fields and wrong
types are rejected **before** anything is built. Every field is optional and
has a default. The full schema with per-field comments is in the
[contract reference](contract.md).

```bash
vm-launcher --show      # validate + print the resolved policy and allowlist
```

## Where the launcher looks

Without `--policy`, the launcher searches the **project root** (the git
toplevel of the current directory, or the directory itself) and uses the first
file that exists:

1. `envs/vm/microvm.ncl` (the canonical location)
2. `env/vm/microvm.ncl`
3. `environments/vm/microvm.ncl`
4. `environment/vm/microvm.ncl`
5. any `*.ncl` in those directories, alphabetically

If nothing is found, a bare `vm-launcher` on a terminal asks before booting the
built-in default (the whole directory shared read-write, egress limited to
`api.anthropic.com`). `--policy PATH` always wins.

## Fields by example

```nickel
let c = import "/run/current-system/sw/share/vm-launcher/contract.ncl" in
{
  # The project dir, bridged into the guest at /work.
  project = "/home/alice/src/myproject",
  work = {
    default  = 'rw,
    readOnly = ["data/raw", "envs/vm"],   # RO carve-outs (keep envs/vm here)
    hidden   = [".env"],                  # not visible at all
  },

  egress.hosts = [ "api.anthropic.com", "platform.claude.com", "pypi.org" ],

  auth = 'bind,                           # RO bind of the host's agent config

  # File-sourced secrets. 'agent: exported in the agent's shell.
  # 'proxy: only the egress proxy sees it (for proxyAuth).
  secrets = [
    { source = "~/.config/microvm/tokens/agent-bot.gh", env = "GH_TOKEN", scope = 'agent },
  ],

  # Literal NON-secret env vars, exported in the agent's login shell and
  # in the startup hooks. Names must match [A-Z_][A-Z0-9_]*.
  env = {
    ENABLE_CLAUDEAI_MCP_SERVERS = "false",
    EDITOR = "hx",
    JULIA_NUM_THREADS = "8",
  },

  tools = [ "git", "gh", "ripgrep", "uv", "helix" ],
  resources = { vcpu = 8, memMb = 16000 },

  guest = { hostname = "", username = "" },   # "" → derived from project / $USER

  git = {
    name = "", email = "",               # "" → host identity, marked "(vm-launcher)"
    allowedGithubOrgs = ["my-org"],      # other GitHub URLs → blocked.invalid
  },

  # Run after the agent's home is built, before the shell, as the agent
  # user in /work. Output goes to <stateDir>/startup.log.
  startup = {
    commands = [
      { command = "uv sync" },                                    # warn on failure (default)
      { command = "test -f data/x.parquet", onFailure = 'block },  # or fail the boot
    ],
  },

  agent = { preset = 'claude, instructions = "Project-specific guidance…" },
  extraAgents = [ { preset = 'codex } ],
  session = { ssh = true, multiplex = 'none },
} | c.Policy
```

## Agents

`agent` is the session's default agent, and `extraAgents` adds more to the
same VM. A `preset` (`'claude` or `'codex`) fills in everything else: package,
command, run flags, config dir, instructions file, state layout.

Inside the guest:

- `<name>-run` (`claude-run`, `codex-run`) runs the agent with its baked-in
  flags (`--dangerously-skip-permissions` for claude). `agent-run` is the
  default agent's.
- The bare binary stays on `$PATH` with its own prompts on.
- `agent.instructions` is appended to the agent's instructions file
  (`CLAUDE.md` / `AGENTS.md`) along with the auto-generated VM context. See
  [what the agent is told](inside-the-vm.md#what-the-agent-is-told).

Declaring an agent puts its package in the guest, so it doesn't also go in
`tools`. Agent names must be unique (two of the same preset need an explicit
`name`).

With two agents, use one `vm-launcher attach` per agent. Each is its own
shell. `session.multiplex = 'tmux` instead gives the console a tmux session
with a window per agent, which also survives a dropped connection. Booting a
VM never starts an agent by itself.

### How the agent's config dir is built

| `configMode` | Used by | Shape |
|---|---|---|
| `'symlinks` | claude | `~/.claude` is a dir of links into the RO bind; listed `stateDirs` / `stateFiles` / `homeStateFiles` point into the state dir; `syncFiles` are copied in and synced back |
| `'writable` | codex | the config dir *is* the state namespace, with `seedFiles` copied in from the host at boot |

codex needs `'writable` because it keeps sqlite databases at the root of
`CODEX_HOME`, refreshes `auth.json` in place, and executes helper binaries it
extracts there. It also needs `configEnv = "CODEX_HOME"`, or it would read
`~/.codex`. How logins fit into this is covered in
[Credentials and logins](credentials.md).

## Pattern: an agent identity bundle

Keep a bot identity (git author, token, informational env) in one Nickel file
and import it into each project:

```nickel
# ~/.config/microvm/identities/agent-bot.ncl
{
  git = { name = "agent-bot", email = "12345678+agent-bot@users.noreply.github.com" },
  secrets = [ { source = "~/.config/microvm/tokens/agent-bot.gh", env = "GH_TOKEN", scope = 'agent } ],
  env = { GH_USER = "agent-bot" },
}
```

```nickel
# <project>/envs/vm/microvm.ncl
let c = import "/run/current-system/sw/share/vm-launcher/contract.ncl" in
let bot = import "~/.config/microvm/identities/agent-bot.ncl" in
{
  project = "/home/alice/src/myproject",
  egress.hosts = [ "github.com", "api.github.com" ],
  git = bot.git, secrets = bot.secrets, env = bot.env,
} | c.Policy
```

## Tools: where packages come from

Each `tools` entry is a **nixpkgs attribute name**, resolved against the
**guest's** package set: the nixpkgs pinned by the guest flake, plus every
overlay the site applies to the guest. The host builds the closure into its
own store. Since the guest follows the host's nixpkgs revision, stock tools
you already have are reused rather than rebuilt. Nothing is built inside the
VM.

- Names are pre-checked before `nix build`, so a typo fails fast
  (`policy.tools: nixpkgs has no attribute 'gnuesd'`).
- Don't list system tools (`coreutils`, `curl`, `systemd`, …). They're
  already on every guest's `PATH`.
- `tools` is deliberately narrow: "these attrs go on `PATH`". A policy can't
  write arbitrary guest Nix (or turn its fence off). Packages the guest's
  nixpkgs lacks come from a site overlay via `mkGuest`.

## Resources

`resources.memMb` is checked against the host before the build. Guest memory
is allocated lazily, so an oversized guest boots fine and is then OOM-killed
when it touches more than the host can back:

- `memMb` above the host's total RAM: **error**.
- `memMb` above what's free right now: **warning**.

## Console

`console = 'hvc0` (default) uses virtio-console: fast, so full-screen TUIs
redraw smoothly. `'ttyS0` falls back to the emulated serial port, for debugging
only, since it is far slower. This only matters for `--console` sessions; an
attached shell is ssh.
