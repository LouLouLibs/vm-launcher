# Command line

```
vm-launcher [--policy PATH] [--detach | --console] [--egress MODE] [--show]
            [--keep-state] [--fast]
vm-launcher attach [ID]
vm-launcher down [ID]
vm-launcher ls [--all]
vm-launcher clean ID… | --exited
```

## Launching

| Flag | Effect |
|---|---|
| *(none)* | On a terminal: boot detached, then attach this terminal over ssh. `Ctrl-D` leaves the VM running. Without a terminal, the launcher owns the VM until it exits. |
| `--policy PATH` | Read the policy from `PATH`. Without it, auto-discover under the project root; see [Writing a policy](policies.md#where-the-launcher-looks). Fields: [policy contract](contract.md). |
| `--detach` | Boot headless and return to the prompt. Reach it with `attach`; it lives until `down`. Implies `--keep-state`. Needs [`session.ssh`](contract.md#boot-and-session). |
| `--console` | Make this terminal the VM's console (the old foreground mode). Logging out powers the VM off. Device: [`console`](contract.md#boot-and-session). |
| `--egress MODE` | Override the network posture: `fenced` (default), `unfenced`, `airgap`. Operator-only; the policy side is [`egress.hosts` / `egress.none`](contract.md#network). See [Network and egress](network.md). |
| `--show` | Validate the policy, print it resolved with the egress posture, and exit. Takes no slot. |
| `--keep-state` | Keep `/run/vm-launcher/session-<pid>/` after exit, for debugging. |
| `--fast` | Build the guest image with multi-threaded `mkfs.erofs`: 2–4× faster, 10–30% larger, not cache-shared with a normal build. |

## Subcommands

| Command | Effect |
|---|---|
| `attach [ID]` | Open an independent shell in a running VM over ssh. Without `ID`: this project's VM, or the only one. Prints the reattach/stop commands on exit. |
| `down [ID]` | Power off a detached (or orphaned) VM and release its slot. Refuses a VM still owned by its launching terminal. |
| `ls [--all]` | List sessions: live and stale first, then the newest exited (`--all`: everything). See [Running VMs](running.md#listing-sessions-ls). |
| `clean ID…` / `clean --exited` | Delete finished sessions: registry entry, per-project link, stale `/run` state, orphaned `virtiofsd`s. Refuses running sessions. |

## Environment

| Variable | Use |
|---|---|
| `VM_LAUNCHER_FLAKE` | Path of the flake exporting `nixosConfigurations.vmLauncher` (the host config). Set by the installed wrapper; required to boot, unused by `--show`. |
| `XDG_STATE_HOME` | Base of the per-project state dirs (default `~/.local/state`). |
