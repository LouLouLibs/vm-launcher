# Credentials and logins

A VM needs credentials to be useful: the agent has to reach its model, and
usually GitHub too. This page explains where each credential comes from, what
the guest can see, and which setup to pick.

## The short version

| Credential | How it gets in | Agent can read it? | Survives a VM restart? |
|---|---|---|---|
| Agent settings, skills, plugins | RO bind of the host's config dir (`auth = 'bind`) | yes, read-only | n/a (host copy) |
| Claude: setup-token (default for guests) | `secrets` → `$CLAUDE_CODE_OAUTH_TOKEN` | yes | yes (file on the host) |
| Claude: the guest's own login | `agent.syncFiles = [".credentials.json"]` + `/login` once | yes | yes (state dir) |
| codex: `auth.json` | copied from the host at each boot (`seedFiles`) | yes | no, re-copied from the host |
| GitHub token / App key | `secrets` with `scope = 'agent` | yes | yes (file on the host) |
| API keys the agent must not see | `secrets` with `scope = 'proxy` + `proxyAuth` | **no**, injected by the proxy | yes |

Everything in the guest that the agent **can** read, it can also send to any
host on the egress allowlist. Keep that list short. A secret the agent never
needs to see belongs in `scope = 'proxy`.

## Where the agent's config comes from

With `auth = 'bind` (what a project policy normally uses), the host's agent
config dir (`~/.claude`, `~/.config/codex`) is mounted **read-only** in the
guest. Your settings, skills, plugins and statusline are the same inside and
out, and the guest can't change them.

The agent still needs to write some things: session history, todos, its own
`~/.claude.json`. Those are listed per agent (`stateDirs`, `stateFiles`,
`homeStateFiles`) and redirected into the project's **state dir** on the host,
`~/.local/state/microvm/<project>/<agent>/`. That dir is what makes
`claude --resume` work across VM restarts.

`auth = 'ephemeral` binds nothing: the guest starts with an empty config and
loses everything on shutdown.

## Claude: pick one of two logins

### Why the host's login can't simply be shared

Claude Code's claude.ai login is an access token (about 8 hours) plus a refresh
token. **Every refresh rotates the refresh token**: the old one dies the moment
a new one is issued. If a guest used the host's `~/.claude/.credentials.json`
through the read-only bind, its first refresh would kill the token the host
still holds. The host (and every other guest) would then hit
`Login expired · Please run /login`, several times a day. So guests never use
the host's login. They get one of the two below.

### Option A: a setup-token (the default)

A one-year token from `claude setup-token`, handed to every guest as an
environment variable. `CLAUDE_CODE_OAUTH_TOKEN` outranks `/login` credentials,
so the bound `.credentials.json` is ignored and never refreshed.

```bash
claude setup-token                      # on the host; needs a Pro/Max/Team plan
umask 077; printf '%s' '<token>' > ~/.config/microvm/secrets/claude-code-oauth-token
```

```nickel
secrets = [
  { source = "~/.config/microvm/secrets/claude-code-oauth-token",
    env = "CLAUDE_CODE_OAUTH_TOKEN", scope = 'agent },
],
```

`setup-token` prints a URL, takes the pasted `<code>#<state>` back, and *then*
prints the token: the `sk-ant-oat01-…` line, not the code you pasted. The file
must exist before launch, since a missing `secrets` source fails the boot.

- **Pro:** set up once for every VM; nothing rotates; no host logouts.
- **Con:** it can only make model requests. **No Remote Control, no claude.ai
  connectors.** Re-mint it yearly. Never pass `--bare` to the agent, because
  bare mode ignores the variable.

### Option B: the guest's own login

The guest keeps a login of its own in its state dir. You run `/login` once
inside the VM, and it lasts across restarts.

```nickel
agent.syncFiles = [".credentials.json"],   # and NO CLAUDE_CODE_OAUTH_TOKEN secret
```

What `syncFiles` does, per file:

1. **At boot**, `agent-home-init` drops the RO bind's link for the file, so the
   guest never sees the host's copy. If the state dir holds a saved copy, it
   is restored as a regular file.
2. **While running**, `agent-sync.path` watches the file, and every change is
   copied back to `<stateDir>/claude/.credentials.json` (tmp + rename).

It can't be a `stateFiles` entry. Claude saves credentials by writing a temp
file and renaming it over the old one, which replaces a symlink with a plain
file on the guest's tmpfs root, and the login would vanish at shutdown.

A guest login is **its own token family**: its refresh rotation never touches
the host's or another VM's login. You only need to `/login` again if the VM
goes unused for longer than the refresh token's life (about a month), or if
you sign out of all sessions on claude.ai.

- **Pro:** full claude.ai features: Remote Control and connectors.
- **Con:** one `/login` per VM. The login also carries your claude.ai
  connectors into the guest. Turn them off unless you want them; see
  [claude.ai connectors](connectors.md).

Remote Control also needs feature flags, so don't set `DISABLE_TELEMETRY` in
`policy.env` for such a VM. Start it from an **interactive** session: run
`claude` (or `claude-run`, under `tmux` if it should outlive your connection)
and type `/remote-control`. That works through the egress fence. The
standalone `claude remote-control` server mode still fails behind the proxy
(a known limitation).

### Which one?

Use the **setup-token** unless you need Remote Control (or connectors) in that
VM. It's one secret file for all VMs and nothing to maintain.

## codex

codex keeps `auth.json` in `CODEX_HOME` and refreshes it in place. Its config
dir is **writable** (`configMode = 'writable`), seeded from the host at each
boot by copying `seedFiles` (`auth.json`, `config.toml`). Because it is a copy,
a refresh inside the guest never reaches the host, so a VM can't log the host
out. The flip side: the guest's refreshed `auth.json` is replaced by the host's
copy at the next boot.

## GitHub and other tokens

Anything else comes in through `secrets`: a file on the host, exported as an
environment variable in the guest.

```nickel
secrets = [
  { source = "~/.config/microvm/tokens/agent-bot.gh",
    env = "GH_TOKEN", scope = 'agent },
],
```

The file is read at launch and never committed. The policy only names its
path. For GitHub, prefer a narrowly scoped identity over your own:

- **A GitHub App** installed on just the repo, with the agent minting
  short-lived (1 h) installation tokens from the App's private key. The key is
  the secret (`env = "GH_APP_KEY"`); App ID and owner/repo are plain `env`
  values.
- **A bot account's fine-grained PAT**, paired with that account's noreply
  address in `git.email` so commits are attributed to it. A reusable *identity
  bundle* module keeps this to one line per project; see
  [Writing a policy](policies.md#pattern-an-agent-identity-bundle).

`git.allowedGithubOrgs` adds a soft layer on top: GitHub URLs outside the
listed orgs are rewritten to `blocked.invalid`, so a fetch or push to a
foreign repo fails.

## Secrets the agent must not see

`scope = 'proxy` secrets **never reach the agent process**. The in-guest egress
proxy reads them and injects them into matching requests itself:

```nickel
secrets = [
  { source = "~/.config/microvm/tokens/openai", env = "OPENAI_KEY", scope = 'proxy },
],
proxyAuth = [
  { host = "api.openai.com", header = "Authorization",
    valueTemplate = "Bearer ${OPENAI_KEY}" },
],
```

The proxy terminates TLS for that host with a per-VM CA and adds the header,
and the agent only ever sees requests succeed. The secret files are shadowed
before any agent code runs, and the guest has no `sudo`, so
`cat /etc/vm-launcher/proxy-secrets/*` is denied even to the agent user.
Proxy-scoped secrets need the proxy, so they do nothing under
`--egress unfenced` or `airgap` (the launcher warns).
