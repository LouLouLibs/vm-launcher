# Running VMs

## Launch, attach, leave, stop

```bash
vm-launcher                   # on a terminal: boot detached, then attach you
vm-launcher --detach          # boot, print how to reach it, return
vm-launcher attach [ID]       # a shell in a running VM, from any terminal
vm-launcher down [ID]         # power it off and release its slot
vm-launcher --console         # old mode: this terminal IS the VM console
```

A plain launch on a terminal is `--detach` followed by `attach`. The launcher
waits for the guest's sshd, opens a shell here, and when you log out
(`Ctrl-D`) the VM keeps running:

```
vm-launcher: left VM <id> running (slot <n>)
vm-launcher:   reattach: vm-launcher attach <id>
vm-launcher:   stop:     vm-launcher down <id>
```

`attach` prints the same note when its shell exits. Every `attach` is an
independent shell, so open as many as you like. Work that must outlive a
dropped connection belongs under `tmux` inside the guest.

Without an ID, `attach` and `down` pick **this project's** VM (from the
current directory), or the only one running. A VM belonging to another
project must be named explicitly, and ambiguity is reported rather than
guessed at.

### Who owns the VM

| Launched with | Owned by | `Ctrl-D` | Stopped by |
|---|---|---|---|
| `vm-launcher` (terminal) | nobody (detached) | leaves it running | `down` |
| `--detach` | nobody (detached) | n/a | `down` |
| `--console` | the launching terminal | **powers it off** | logging out of the console, or `Ctrl-C` |
| any launch without a terminal (scripts, CI) | the launcher process | n/a | stopping the launcher |

A policy with `session.ssh = false` has no attach path, so it always gets the
console, and `--detach` is refused rather than booting something unreachable.

`attach` goes over ssh on the guest's slot address (`10.42.<slot>.2`), a tap
network reachable only from this host. Keys are minted per session; the
guest's host key is injected, so verification is strict with no
trust-on-first-use prompt. Both die with the session.

## Several VMs at once: network slots

Each session owns a **network slot**: a host tap `vm-tap<i>` with its own
subnet (`10.42.<i>.0/24`), MAC, and `current-session-<i>` link. The host's
tap devices *are* the capacity (e.g. 4). A per-slot lock under
`/run/vm-launcher/` is released by the kernel on any exit, crashes included.
Concurrent VMs share no network identity.

When every slot is busy, a launch **queues**:

```
vm-launcher: queued — all 4 network slots are busy (projA (pid N), …).
vm-launcher: this session starts automatically when a slot frees. Ctrl-C to cancel.
```

`--show` takes no slot and works anytime.

## Listing sessions: `ls`

```bash
vm-launcher ls            # live + stale sessions, plus the newest exited
vm-launcher ls --all      # every recorded session
```

| Column | Meaning |
|---|---|
| `STATE` | see below |
| `UP` | the VM's own uptime (excludes the `nix build`) |
| `AGENTS` | agents declared by the session's policy |
| `EGRESS` | `fenced`, `unfenced` or `airgap`; an unfenced VM is also called out in the footer |
| `ATT` | ssh shells attached right now (the footer names their terminals) |
| `PID` | the VM runner's pid |
| `SIZE` | closure size of the guest image (`-` once garbage-collected) |

States:

- **building**: the launcher is still in `nix build`; there is no VM yet.
- **booting**: the VM is up but its sshd isn't answering yet. `attach`
  waits for it; `down` works.
- **running**: up and reachable, owned by its launcher (a `--console` or
  scripted session).
- **detached**: up and reachable, outlives its launcher. `attach` and `down`
  act on it; `clean` refuses it.
- **orphaned**: up, but its launcher died without detaching. `attach` works;
  `down` reaps it.
- **exited**: the VM ran and is gone. Normal.
- **stale**: a state dir whose VM is gone, because teardown never ran
  (SIGKILL, host crash, `--keep-state`). This is what `clean` is for.

Liveness is judged by the VM's **runner** process, never the launcher, which
is also what stops `clean` from deleting a live VM's state.
**running** and **detached** mean "`attach` works right now": `ls` probes each
live VM's sshd (a TCP connect and the `SSH-` greeting, no login, ≤0.5s), and
shows **booting** until it answers.

## Cleaning up: `clean`

```bash
vm-launcher clean <id> [<id> …]   # specific sessions
vm-launcher clean --exited        # everything not running
```

Per session, `clean` removes the registry entry, the per-project
`<stateDir>/sessions/<id>` link and, for stale sessions, the leftover
`/run/vm-launcher/session-<pid>/` dir and any orphaned `virtiofsd` (each pid
verified via `/proc/<pid>/cmdline` before it's signalled). Running sessions
are refused. The guest image in `/nix/store` is left to `nix store gc`.

## Where things live on the host

| Path | What |
|---|---|
| `/run/vm-launcher/session-<pid>/` | per-session staging: `etc/` the guest reads, ssh keys, virtiofsd sockets |
| `~/.local/state/microvm/<project>/` | per-project state: agent history, todos, logins, `startup.log`, `bootstrap.log` |
| `~/.local/state/microvm/sessions/<id>/manifest.json` | what built each session: resolved policy, flake rev, launcher path |
