# Inside the VM

When you attach, the login banner lists the agents, the network posture, the
startup commands that ran, and where their log is. `vm-agents` prints it
again.

## The shell

- The prompt is `[<user>-vm@<project>:/work]$`: the host `$USER` plus `-vm`,
  and the project's directory name. Override with
  `guest.{username,hostname}`.
- `/work` is the project, read-write apart from the policy's `readOnly` and
  `hidden` carve-outs.
- `claude-run` / `codex-run` start an agent prompts-off; `claude` / `codex`
  keep their prompts.
- There is **no `sudo`** and root is locked. The agent has no way to
  escalate, which is what keeps proxy-scoped secrets out of its reach.
- `journalctl -u <unit>` works without root (read-only).

## What persists

| Location | Lifetime |
|---|---|
| `/work` | the project on the host |
| the agent's history, todos, sessions, `~/.claude.json` | the project's state dir on the host, so `claude --resume` works across restarts |
| a login kept with `syncFiles` | the state dir, see [credentials](credentials.md) |
| everything else (`/tmp`, `~`, installed junk) | gone at shutdown; the root is tmpfs |

## What the agent is told

Each agent gets an instructions file (`CLAUDE.md` for claude, `AGENTS.md` for
codex) generated from the session's policy. It only states what that policy
actually provides:

| Section | Always | Only when |
|---|---|---|
| The VM, the egress allowlist, what persists, what not to do | yes | |
| Other agents in this VM, and their `-run` wrappers | | `extraAgents` is set |
| "Use `gh`; `GH_TOKEN` is preset" | | a secret exports `GH_TOKEN` |
| `JULIA_PROJECT=/work/<julia.env>`, the `/work/.julia` depot, `Pkg.add` | | `tools` contains `julia` or `julia-bin` |
| Your own guidance, under "Project-specific guidance" | | `agent.instructions` is set |

The julia lines describe the layout a julia-enabled guest is expected to have.
The base guest only installs the package. Setting `JULIA_PROJECT` and the
depot is a site module's job (see `mkGuest`).

### Adding your own conventions

Anything specific to your setup goes in `agent.instructions`. A shared julia
sysimage built by a site module is a typical example:

```nickel
let site_notes = m%"
  - A shared Julia sysimage is at `/var/lib/julia-sysimage.so`:
    `julia -J /var/lib/julia-sysimage.so script.jl`.
"% in
{
  agent = { preset = 'claude, instructions = site_notes },
  extraAgents = [ { preset = 'codex, instructions = site_notes } ],
}
```

Bind the text once and pass it to every agent, so `CLAUDE.md` and `AGENTS.md`
say the same thing.

## Useful files

```bash
cat /etc/vm-launcher/egress-hosts           # this session's allowlist
cat /etc/vm-launcher/microvm-loaded.json    # the fully resolved policy
cat /etc/vm-launcher/session-id             # matches ~/.local/state/microvm/sessions/<id>/ on the host
cat /var/lib/vm-launcher-state/startup.log  # output of policy.startup.commands
```

## Units worth knowing

```bash
systemctl status vm-egress-proxy            # the egress proxy (listens on :3128)
journalctl -u vm-egress-proxy               # allowed/denied connections
journalctl -u vm-launcher-startup-hooks     # your startup commands
journalctl -u agent-home-init               # how ~/.claude etc. were assembled
systemctl status agent-sync.path            # syncFiles watcher, when used
```
