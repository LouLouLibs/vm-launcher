# claude.ai connectors

claude.ai **connectors** are the integrations attached to your claude.ai
account: Gmail, Google Drive, Calendar, Claude Docs, and so on. Claude Code
loads them automatically for any session logged in to that account.

Inside a VM the agent usually runs prompts-off (`--dangerously-skip-permissions`),
so a connector there means the agent can read and send your mail, or edit your
documents, without asking. **The recommended default is no connectors in any
VM.** Turning them on is an explicit, per-VM choice.

## Does this VM have connectors?

It depends on the [login](credentials.md#claude-pick-one-of-two-logins):

- **Setup-token VMs (the default): no.** The token can only make model
  requests, so connectors can't load. Nothing to do.
- **VMs with their own login: yes, unless you turn them off.** A full claude.ai
  login brings every connector on the account.

## Turning them off

Two layers, both in the project's `microvm.ncl`:

```nickel
egress.hosts = [
  "api.anthropic.com",
  "platform.claude.com",            # /login + token refresh
  # NOT "mcp-proxy.anthropic.com": that's the connector proxy
],
env = {
  ENABLE_CLAUDEAI_MCP_SERVERS = "false",
},
```

**`ENABLE_CLAUDEAI_MCP_SERVERS = "false"`** tells Claude Code not to load them,
so `claude mcp list` shows only local MCP servers. It's a *soft* switch: the
agent could start another `claude` with the variable unset.

**Leaving `mcp-proxy.anthropic.com` off the allowlist** is the *hard* switch.
Every connector call goes through that host (`MCP_PROXY_URL` in the Claude Code
binary). The agent can read its own credentials, but with the host blocked it
has no way to reach a connector. The proxy log shows the attempt:

```
vm-egress-proxy: denied: CONNECT mcp-proxy.anthropic.com:443 (host not in allowlist)
```

Blocking it costs nothing else. `/login` and token refresh use
`platform.claude.com`, and model calls use `api.anthropic.com`; both were
checked live with connectors blocked.

::: tip
Older policies allowlisted `mcp-proxy.anthropic.com` with the comment
"needed by /login". That was never true. It only carries connector traffic.
:::

The same two lines are a harmless default for setup-token VMs too, and keep
the VM safe if it's ever switched to its own login.

## Turning them on for one VM

If a VM really should use a connector:

1. Give it [its own login](credentials.md#option-b-the-guest-s-own-login).
2. Add `"mcp-proxy.anthropic.com"` to its `egress.hosts`.
3. Remove `ENABLE_CLAUDEAI_MCP_SERVERS` from its `env`.
4. Restart the VM. Inside, `claude mcp list` should show the connectors.

To allow some connectors but not others, use Claude Code's own controls
inside the guest: `/mcp` toggles connectors per project. Those are settings
the agent can change, though. Only the egress block is enforced from outside.

## Checking a VM

```bash
# inside the guest
echo $ENABLE_CLAUDEAI_MCP_SERVERS                 # false
claude mcp list                                   # no "claude.ai …" entries
grep mcp-proxy /etc/vm-launcher/egress-hosts      # no output
```
