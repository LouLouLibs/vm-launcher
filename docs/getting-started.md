# Getting started

## What you need

- A **NixOS host with KVM** (`/dev/kvm`). The guest is built with
  [microvm.nix](https://github.com/microvm-nix/microvm.nix) and runs under
  cloud-hypervisor.
- **Host provisioning** for the VMs: a pool of tap devices (`vm-tap<i>`) with
  NAT, the `/run/vm-launcher` state dir, and the wrapped binaries on `$PATH`.
  This repo's host module provides all of it.

## Install

Add this repo as an input of your host's flake and enable the host module:

```nix
# flake.nix of the host config
inputs.vm-launcher.url = "github:LouLouLibs/vm-launcher";
inputs.vm-launcher.inputs.nixpkgs.follows = "nixpkgs";
```

```nix
# in the host's NixOS configuration
{ inputs, ... }: {
  imports = [ inputs.vm-launcher.nixosModules.host ];
  services.vm-launcher = {
    enable = true;
    user = "alice";   # who runs vm-launcher; owns the taps and /run/vm-launcher
    slots = 4;        # how many VMs can run at once (default 4)
  };
}
```

```bash
sudo nixos-rebuild switch --flake <host-config>#<host>
```

That installs `vm-launcher` and `vm-egress-proxy`, the policy contract at
`/run/current-system/sw/share/vm-launcher/contract.ncl`, and creates the tap
pool. Updating the launcher means bumping the flake input and rebuilding.

| Option | Default | |
|---|---|---|
| `user` | (required) | Operator; owns the tap devices and `/run/vm-launcher`. |
| `group` | `users` | Group of `/run/vm-launcher`. |
| `slots` | `4` | Tap devices = concurrent VMs. Slot `i` is `vm-tap<i>`, `10.42.<i>.0/24`. |
| `flake` | `null` | Flake the guest is built from. `null` = this repo's base guest. |
| `package`, `contract` | this repo's | Override only to pin a different launcher build. |
| `runtimePackages` | nix, nickel, git, virtiofsd, openssh, … | Tools on the launcher's `PATH`. |

**Networking note.** The taps are systemd-networkd devices, so the module
enables networkd. If the host's physical link uses the default scripted
dhcpcd setup, switch it to networkd (`networking.useNetworkd = true`) so the
two don't manage the same interfaces. On a NetworkManager host, also set
`systemd.network.wait-online.enable = false`: no networkd link needs to be
online at boot, and the wait otherwise stalls the switch.

### Extending the guest

To layer your own modules (a language toolchain, extra packages) onto the
base guest, export an extended guest from the host flake and point the
launcher at it:

```nix
nixosConfigurations.vmLauncher = inputs.vm-launcher.mkGuest {
  extraModules = [ ./my-site-guest.nix ];
};
```

```nix
services.vm-launcher.flake = "/path/to/host-config";
```

## Your first policy

Create `envs/vm/microvm.ncl` at the root of a project:

```nickel
let c = import "/run/current-system/sw/share/vm-launcher/contract.ncl" in
{
  project = "/home/alice/src/myproject",
  work = { default = 'rw, readOnly = ["data/raw", "envs/vm"] },
  egress.hosts = [
    "api.anthropic.com",
    "platform.claude.com",          # login + token refresh
    "github.com", "api.github.com",
  ],
  auth = 'bind,
  secrets = [
    { source = "~/.config/microvm/secrets/claude-code-oauth-token",
      env = "CLAUDE_CODE_OAUTH_TOKEN", scope = 'agent },
  ],
  env = { ENABLE_CLAUDEAI_MCP_SERVERS = "false" },
  tools = [ "git", "gh", "ripgrep", "jq" ],
  resources = { vcpu = 4, memMb = 8192 },
} | c.Policy
```

Listing `envs/vm` under `readOnly` keeps the agent from rewriting the policy
that built its cage. The token file comes from `claude setup-token`; see
[Credentials and logins](credentials.md).

Check it without booting anything:

```bash
vm-launcher --show
```

`--show` prints the resolved policy and the egress allowlist, or rejects the
file if a field is unknown or mistyped.

## Boot it

```bash
vm-launcher
```

The first boot builds the guest closure, which takes a few minutes; later
boots reuse it. When it's up, the launcher attaches your terminal over ssh:

```
[alice-vm@myproject:/work]$ claude-run
```

`/work` is your project. `Ctrl-D` leaves the VM running and tells you how to
come back (`vm-launcher attach`) or stop it (`vm-launcher down`).

Next: [Running VMs](running.md) for the lifecycle, and
[Writing a policy](policies.md) for everything a policy can say.
