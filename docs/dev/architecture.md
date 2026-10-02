# Architecture

Four pieces, one boundary:

```
  project/envs/vm/microvm.ncl ─ Nickel policy (what the guest may see & do)
            │  validated against policy/contract.ncl
            ▼
  ┌──────────────────────────── HOST ────────────────────────────┐
  │  vm-launcher (OCaml)                                          │
  │    resolve policy → stage etc/ → nix build guest closure      │
  │    → spawn one virtiofsd per share → exec microvm-run         │
  │  vm-egress-proxy (OCaml, Lwt+TLS) — MITM egress proxy         │
  └───────────────────────────────┬──────────────────────────────┘
                                   │ virtiofs shares + tap NIC
  ┌──────────────────────────── GUEST ───────────────────────────┐
  │  NixOS microVM (microvm.nix + cloud-hypervisor)              │
  │    tmpfs root · hermetic /nix/store erofs · /work = project   │
  │    in-guest proxy + nftables fence + per-VM MITM CA           │
  │    agent-home-init → startup hooks → login shell (agent-run)  │
  └───────────────────────────────────────────────────────────────┘
```

- **Policy (Nickel).** [`policy/contract.ncl`](../../policy/contract.ncl) is
  the typed schema; `lib/policy.ml` is its in-process mirror.
- **Launcher (OCaml).** Resolves the policy and fills in launcher-injected
  data (git identity, guest user/hostname, session id, egress mode, host
  config dirs). It stages a session `etc/`, builds the guest through
  microvm.nix's `declaredRunner`, spawns a `virtiofsd` per share, then runs
  `microvm-run` (cloud-hypervisor), supervised or detached.
- **The fence.** nftables drops all egress that isn't the proxy's uid; the
  proxy enforces the hostname allowlist and, for `proxyAuth` hosts,
  terminates TLS with a per-VM CA and injects headers.
- **The guest.** `nix/guest/_guest.nix`: tmpfs root, an erofs `/nix/store`
  holding only what the policy needs, `/work` bridged with carve-outs, no
  sudo, an unprivileged agent user. The guest is **agent-neutral**: a
  data-driven profile per agent (`preset = 'claude | 'codex`) drives the run
  wrapper, the config bind, the instructions file and the state layout.
- **Per-session networking.** Each session claims a slot (`vm-tap<i>`, its own
  subnet and MAC), so VMs run concurrently.

## Repo layout

| Path | What |
|---|---|
| `bin/main.ml` | CLI: launch, `attach`, `down`, `ls`, `clean` |
| `lib/` | policy parsing, staging, boot, slots, ssh, session registry, the proxy |
| `nix/guest/_guest.nix` | the base guest NixOS config (reads `policy.json`) |
| `nix/guest/_proxy.nix` | the in-guest egress proxy unit |
| `nix/host.nix` | the host module (`nixosModules.host`): wrapper, tap pool + NAT, state dir |
| `policy/contract.ncl` | the policy contract (source of truth) |
| `flake.nix` | packages, `nixosConfigurations.vmLauncher`, `mkGuest { extraModules }` |
| `test/` | unit/CLI tests and the e2e suite |
| `docs/`, `site/` | these pages and the VitePress site |

## What lives in the host config

`nixosModules.host` (`nix/host.nix`) provides the generic host side: the
wrapped binaries and contract, kernel modules, the tap pool with NAT,
`ip_forward`, the forward rule and the `/run/vm-launcher` tmpfile rule. A
site's own config adds only what is specific to it:
- its *extended* guest, if any, built with
  `inputs.vm-launcher.mkGuest { extraModules = … }` (e.g. a language
  toolchain), and `services.vm-launcher.flake` pointing at it;
- extras such as a tailnet upstream for the egress proxy (a host-side
  listener and firewall rule, plus the guest's `vmLauncher.egress.upstreams`).

Changing the launcher or the base guest is self-contained here. The host
config is touched only to bump the flake input or change host networking or a
site capability.
