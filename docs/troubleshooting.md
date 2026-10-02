# Troubleshooting

## First: keep the evidence

Re-run with `--keep-state`, so the session dir survives the VM, then read:

| File | What |
|---|---|
| `~/.local/state/microvm/<project>/bootstrap.log` | every step of the proxy-secret bootstrap unit |
| `~/.local/state/microvm/<project>/startup.log` | output of `policy.startup.commands` |
| `~/.local/state/microvm/sessions/<id>/manifest.json` | what built the VM: flake rev, launcher path, resolved policy |
| `/run/vm-launcher/session-<pid>/etc/` | what the guest read: `egress-hosts`, `proxy-auth.conf`, `proxy-ca.pem`, … |

Inside the guest:

```bash
journalctl -u vm-egress-proxy               # proxy decisions, incl. denials
journalctl -u egressproxy-secret-bootstrap  # secret bootstrap
journalctl -u vm-cabundle                   # runtime CA bundle
journalctl -u vm-launcher-startup-hooks     # your startup commands
ss -tlnp                                    # the proxy should listen on :3128
```

## Common problems

**A download or API call fails inside the VM.** Look for
`denied: CONNECT <host>` in `journalctl -u vm-egress-proxy`, then add the host
to `egress.hosts` and restart the VM. To check whether the proxy itself is
the problem, boot once with `--egress unfenced`.

**`vm-launcher attach` says no VM is running for this project.** The launcher
may still be building the guest. `ls` shows the session while it holds a
slot, but there's no VM to attach to yet. Wait for
`VM running detached (session …)`.

**The launch says `queued — all N network slots are busy`.** Every slot is
taken. `vm-launcher ls` shows by whom; `down` one, or wait.

**`Login expired · Please run /login` on the host, several times a day.** A
guest is refreshing the host's Claude login through the read-only bind. Give
guests a setup-token or their own login; see
[Credentials and logins](credentials.md).

**`claude remote-control` inside a VM:**
- `Remote Control requires a full-scope login token`: the VM uses the
  setup-token. Give it [its own login](credentials.md#option-b-the-guest-s-own-login).
- `requires feature-flag evaluation, which is disabled because DISABLE_TELEMETRY is set`:
  remove `DISABLE_TELEMETRY` from `policy.env`.
- `socket hang up` from `claude remote-control`: the standalone server mode fails behind the egress proxy (a known limitation). Start `claude` interactively and use `/remote-control` instead, which works.

**The guest dies mid-run with no clean shutdown.** The host OOM-killed
cloud-hypervisor. Lower `resources.memMb`; the launcher warns at launch when
it exceeds free memory.

**`policy.tools: nixpkgs has no attribute 'x'`.** A typo, or a package that
exists only in your host profile or a host-only overlay. Tools resolve against
the guest's package set.

## Don't

- Don't `chmod` files under `/run/vm-launcher/session-*/etc/` by hand. The
  launcher writes them with deliberate modes.
- Don't add system tools (`systemd`, `iproute2`, `curl`, …) to `tools`.
  They're already on the guest's `PATH`.
