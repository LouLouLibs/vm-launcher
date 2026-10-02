# vm-launcher

OCaml launcher for policy-fenced NixOS microVMs that run coding agents.
It shells out to `nix build` + `microvm-run`, spawns virtiofsds for the
shares, and runs an egress MITM proxy (`vm-egress-proxy`) inside the guest.

The launcher is agnostic to what runs inside the VM: agents are wired
from neutral profiles (a `preset` — `'claude` or `'codex` — expands to the
command, flags, config dir, instructions file and state layout that agent
needs). A session can declare several agents (`agent` plus `extraAgents`);
each gets its own `<name>-run` wrapper, read-only config bind,
instructions file and state namespace.

A VM can run **detached**: `vm-launcher --detach` boots it headless and
returns, `vm-launcher attach` opens independent ssh shells on the guest's
host-only slot address, and `vm-launcher down` stops it. Keys are per
session and the guest's host key is injected, so host-key verification is
strict with no TOFU prompt. Consequences worth remembering: the
virtiofsds are disowned so they outlive the launcher, and the guest's
tmpfs root is mode 0755 because sshd's StrictModes refuses to
authenticate through a world-writable `/`.

`vm-launcher ls` reports readiness, not just liveness: `building` (still
in `nix build`), `booting` (VM up, sshd not answering), then `running` /
`detached` once `attach` will work.

**Policy contract (source of truth):** [`policy/contract.ncl`](policy/contract.ncl).
**Docs:** sources in [`docs/`](docs/), VitePress config in `site/`;
`scripts/docs-site.sh preview` builds and serves it locally.

## This repo is PRIVATE until explicitly approved

Do not change the repository's visibility, enable GitHub Pages, or push
its contents anywhere public. The maintainer flips it public only after an
independent review. Never include host names, home paths, usernames,
private project names, account IDs or tailnet names in code, docs, tests,
commit messages or issues — use neutral examples (`myhost`,
`/home/alice`, `myproject`). A local pre-commit / pre-push hook enforces
this; never bypass it with `--no-verify`.

## Build / test / run

```
nix develop -c dune build
nix develop -c dune test
_build/default/bin/main.exe --help
_build/default/bin/main.exe --policy path/to/microvm.ncl --show
_build/default/bin/main.exe ls
```

## Testing (MANDATORY for launcher / guest changes)

Any change to the launcher (`bin/`, `lib/`) or the guest config
(`nix/guest/`) must run the e2e suite before it lands — unit tests don't
boot a real VM, so they can't catch egress/DNS/boot regressions. Run on a
host with KVM and the host networking provisioned:

```
nix develop -c dune build
VM_LAUNCHER_E2E=1 nix develop -c dune exec test/test_e2e_vm.exe
```

The suite boots this checkout's base guest by default. To boot a
site-extended guest instead, set `VM_LAUNCHER_FLAKE=/path/to/site-flake`.
`VM_LAUNCHER_E2E_ONLY=<case,case>` filters cases.

Rules for `test/test_e2e_vm.ml`:
- All cases boot with `--fast` (multi-threaded `mkfs.erofs`) so running
  e2e on every change stays affordable.
- Exactly one case is pinned `~fast:false` (`e2e-non-fast-egress`), so the
  non-fast erofs path is also built and booted every run. Keep it.

## Layout

- `nix/guest/_guest.nix` — the guest NixOS config (reads `policy.json`
  via `VM_LAUNCHER_POLICY_JSON`); `nix/guest/_proxy.nix` — the systemd
  unit for `vm-egress-proxy`.
- `flake.nix` — exposes `nixosConfigurations.vmLauncher` (the base guest)
  and `mkGuest { extraModules ? [] }`, the extension point a site uses to
  layer its own modules onto the base.
- `nix/host.nix` — the host module (`nixosModules.host`): wrapped
  launcher + contract, tap pool + NAT, `/run/vm-launcher`. The slot layout
  (vm-tap<i>, 10.42.<i>.0/24) is shared with the launcher and the guest;
  change all three together. `checks.host-module-eval` evaluates it.
