<div align="center">

<h1>vm-launcher</h1>
<h3>Run a coding agent inside a hardened, single-purpose NixOS microVM with a policy-defined egress fence</h3>

[![Vibecoded](https://img.shields.io/badge/vibecoded-%E2%9C%A8-blueviolet)](https://claude.ai)
[![OCaml](https://img.shields.io/badge/OCaml-EC6813?logo=ocaml&logoColor=white)](https://ocaml.org)
[![Nix](https://img.shields.io/badge/Nix-5277C3?logo=nixos&logoColor=white)](https://nixos.org)

</div>

***

`vm-launcher` boots one or more coding agents ([Claude Code](https://docs.claude.com/en/docs/claude-code) and [codex](https://github.com/openai/codex), together in the same VM if you declare both) inside an ephemeral [cloud-hypervisor](https://www.cloudhypervisor.org/) microVM. The VM wall **is** the security boundary, so the agent runs prompts-off (`--dangerously-skip-permissions`) without putting your host at risk: it sees only the project directory you share, reaches only the hosts you allowlist, and everything it didn't write to a bridged dir is wiped on shutdown.

Each project declares its cage in a small [Nickel](https://nickel-lang.org) policy. The launcher validates it, builds a per-policy guest closure, wires up the file shares and the egress proxy, and drops you at a shell inside.

```bash
# from a project root, on the host
vm-launcher --show          # resolve policy + egress, no boot (auto-discovers envs/vm/microvm.ncl)
vm-launcher                 # boot the guest and attach this terminal; Ctrl-D leaves it running
vm-launcher --detach        # boot it headless and return to the prompt
vm-launcher --console       # this terminal is the VM console; logging out powers it off
vm-launcher attach          # open a shell in a running VM — as many terminals as you like
vm-launcher down            # power off a detached VM
vm-launcher ls              # what is running, for how long, with which agents
```

A VM does not have to own the terminal that launched it. On a terminal, a plain launch boots the VM headless and attaches you over ssh, so logging out leaves it running and prints the `attach` / `down` commands. `--detach` boots it without attaching, `attach` gives each terminal its own independent shell over ssh on a host-only network, and it lives until `down`. `--console` keeps the old foreground mode, where the launching terminal is the VM's console and owns its lifetime.

Inside the guest: `claude-run` / `codex-run` start an agent prompts-off (the VM wall is the boundary, so there is nothing left to prompt about); the bare binary keeps its own prompts and sandbox on. `vm-agents` reprints what the VM carries.

## Documentation

- **The docs site** — guide, CLI and policy reference, credentials, connectors. Sources in [`docs/`](docs/) (start at [`docs/getting-started.md`](docs/getting-started.md)); `scripts/docs-site.sh preview` serves it locally.
- **[`policy/contract.ncl`](policy/contract.ncl)** — the policy contract, the source of truth for every field (shares, egress, secrets, tools, the `agent` profile, resources, git identity…).
- **[`CLAUDE.md`](CLAUDE.md)** — repo orientation, build/test commands, the mandatory e2e rule.

## Architecture / the stack

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

- **Policy (Nickel).** `policy/contract.ncl` is a typed schema; every project's `microvm.ncl` is validated against it before a VM is built. Unknown fields or wrong types are rejected up front. `lib/policy.ml` is the in-process mirror of the schema.
- **Launcher (OCaml).** `vm-launcher` resolves the policy (filling in launcher-injected data: git identity, guest hostname/user, session id, egress mode, the host config-dir source), stages a session `etc/` dir, `nix build`s the guest via `microvm.nix`'s `declaredRunner`, spawns a `virtiofsd` per file share, then execs `microvm-run` (cloud-hypervisor) and supervises its lifecycle.
- **The fence (egress).** Outbound traffic is forced through the in-guest `vm-egress-proxy`; `nftables` drops everything that isn't the proxy's uid, and the proxy enforces a **hostname allowlist**. For configured hosts it TLS-terminates with a fresh per-VM CA and **injects secrets** (e.g. `Authorization`) into requests the agent can't read. The operator-only `--egress fenced|unfenced|airgap` flag overrides the posture (the former `allowlist`/`noblock`/`block` spellings still parse); a project policy can only ever make itself *more* restrictive. Inside the guest the Claude status bar carries an egress segment: a constant cloud `☁` marks the posture, qualified by a state glyph — **`☁ ◉` fenced** (allowlist + MITM proxy up), **`☁ ○` unfenced** (direct to the whole internet), **`☁ ✈` airgapped** (no outbound), **`☁ ⚠` fence broken** (fenced but the proxy isn't answering). The launcher ships this as a one-shot CLI, `vm-egress-status` (on the guest `$PATH`; the flake also exports it as a package); any statusline renders the segment with a guarded `command -v vm-egress-status && vm-egress-status`, and it prints nothing off-VM.
- **The guest (NixOS).** `nix/guest/_guest.nix` builds a minimal microVM: tmpfs root, a hermetic `/nix/store` erofs image holding only `policy.tools`, the project bridged read-write at `/work` (with read-only / hidden carve-outs), no sudo, a locked root. The agent runs as an unprivileged user. Since the agent-abstraction work the base guest is **agent-neutral**: a data-driven agent profile (`preset = 'claude | 'codex`) drives the run wrapper, the config bind, and the instructions file — no agent name is baked into the wiring. A session can declare several agents (`agent` + `extraAgents`); each gets its own `<name>-run` wrapper, credentials bind and state namespace, and tmux multiplexes the single guest console between them.
- **Per-session networking.** Each session claims a network *slot* (its own `vm-tap<i>` / subnet / MAC), so several project VMs run concurrently without colliding. Launches queue only when every slot is busy.

Both binaries (`vm-launcher`, `vm-egress-proxy`) and the guest config live in this repo; a site's NixOS configuration consumes the flake and can layer its own modules (such as a language toolchain) onto the base via `mkGuest { extraModules = … }`.

## Build / test

Requires [Nix](https://nixos.org) with flakes. Everything runs in the dev shell:

```bash
nix develop -c dune build
nix develop -c dune test                       # unit + CLI tests
_build/default/bin/main.exe --help

# end-to-end: boots real microVMs (needs KVM). Mandatory for any
# change to bin/, lib/, or nix/guest/ — see CLAUDE.md.
VM_LAUNCHER_E2E=1 nix develop -c dune exec test/test_e2e_vm.exe
```

The launcher is deployed as a flake input of a NixOS host: `nixos-rebuild switch` installs the wrapped `vm-launcher` + `vm-egress-proxy` binaries and the policy contract onto `$PATH`.

***

<div align="center"><sub>Part of <a href="https://github.com/LouLouLibs">LouLouLibs</a></sub></div>
