# Network and egress

## The fence

By default a VM is **fenced**. `nftables` in the guest drops every outbound
packet that isn't from the egress proxy's uid, and the proxy
(`vm-egress-proxy`, on `:3128`) only connects to hosts in
`policy.egress.hosts`. Everything else is refused and logged:

```
vm-egress-proxy: denied: CONNECT example.com:443 (host not in allowlist)
```

The agent's shell has `HTTPS_PROXY` set and a CA bundle that trusts a
**per-VM** proxy CA. That CA is minted for each session and dies with it.

## Postures: `--egress`

| Posture | What the guest can reach | Glyph |
|---|---|---|
| `fenced` (default) | only `egress.hosts`, via the proxy | `☁ ◉` |
| `unfenced` | **the whole internet**, directly via the host's NAT; no proxy, no allowlist, no MITM CA | `☁ ○` |
| `airgap` | nothing | `☁ ✈` |
| (fenced, proxy down) | nothing, since the fence holds | `☁ ⚠` |

`--egress` is an **operator-only** command-line flag, never a policy field, so
a project's own `microvm.ncl` can't lift its fence. A policy can only make
itself *more* restrictive: `egress.none = true` means airgap. Use `unfenced`
for a trusted job, to find out whether the proxy is the problem, or for a
plain VM with internet. The launcher warns loudly, `ls` flags it, and the
session manifest records it.

The older spellings `allowlist` / `noblock` / `block` still parse.

Inside the guest, `vm-egress-status` prints the glyph for the statusline.
It prints nothing outside a VM, so a shared statusline can call it guarded:
`command -v vm-egress-status && vm-egress-status`.

## The allowlist

```nickel
egress.hosts = [
  "api.anthropic.com",
  "platform.claude.com",              # Claude login + token refresh
  "pypi.org", "files.pythonhosted.org",
  "github.com", "api.github.com", "codeload.github.com",
],
```

Matching is by hostname. Keep the list as short as the project allows:
anything the agent can read, it can send to any listed host.

Common entries:

| Purpose | Hosts |
|---|---|
| Claude Code | `api.anthropic.com`, `platform.claude.com` |
| claude.ai connectors (usually **left out**) | `mcp-proxy.anthropic.com`; see [connectors](connectors.md) |
| codex | `chatgpt.com`, `auth.openai.com` |
| Python | `pypi.org`, `files.pythonhosted.org` |
| Julia | `pkg.julialang.org`, `storage.julialang.net` (+ regional mirrors) |
| R | `cloud.r-project.org` |
| GitHub | `github.com`, `api.github.com`, `codeload.github.com`, `objects.githubusercontent.com` |

Claude Code's telemetry hosts (e.g. Datadog) are refused under the fence;
the refusals in the proxy log are harmless.

## Injecting secrets: `proxyAuth`

For a listed host, the proxy can terminate TLS and add a header from a
`scope = 'proxy` secret, which the agent never sees:

```nickel
secrets   = [ { source = "~/.config/microvm/tokens/openai", env = "OPENAI_KEY", scope = 'proxy } ],
proxyAuth = [ { host = "api.openai.com", header = "Authorization",
                valueTemplate = "Bearer ${OPENAI_KEY}" } ],
```

See [Credentials and logins](credentials.md#secrets-the-agent-must-not-see).
`proxyAuth` needs the proxy, so it does nothing under `unfenced` or `airgap`
(the launcher warns).

## Reaching tailnet services

The proxy dials allowlisted hosts directly. To reach a **Tailscale** peer, it
can chain the CONNECT through the host's tailscaled HTTP proxy
(`tailscaled --outbound-http-proxy-listen=HOST:PORT`), so tailnet traffic
leaves as the host's Tailscale identity rather than one device per VM.

The base guest ships no such rule. A site adds one through
`mkGuest { extraModules = [ … ]; }`:

```nix
{ vmLauncher.egress.upstreams = [
    { suffix = ".example.ts.net"; proxy = "10.42.0.1:1055"; }
  ]; }
```

Hostnames matching `suffix` go through that upstream. The tunnel is opaque,
not MITM'd, so TLS runs end-to-end to the peer. The project still has to list
the exact host in `egress.hosts`: the upstream rule says *how* a tailnet host
is reached, the allowlist says *which* ones. Only port 443 is tunnelled, so
the service must be served over HTTPS on 443 (e.g. behind `tailscale serve`).
