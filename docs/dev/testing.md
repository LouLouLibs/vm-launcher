# Testing

```bash
nix develop -c dune build
nix develop -c dune test            # unit + CLI tests
```

## The e2e suite (mandatory for launcher and guest changes)

**Any change to `bin/`, `lib/` or `nix/guest/` must pass the e2e suite before
it lands.** Unit tests don't boot a VM, so they can't catch boot, egress or
DNS regressions. The suite boots real microVMs and needs KVM:

```bash
VM_LAUNCHER_E2E=1 nix develop -c dune exec test/test_e2e_vm.exe
```

By default it builds the **base guest** from this checkout. To test a
site-extended guest (e.g. after bumping the host config's `vm-launcher`
input), point it at the host config:

```bash
VM_LAUNCHER_E2E=1 VM_LAUNCHER_FLAKE=/path/to/host-config \
  nix develop -c dune exec test/test_e2e_vm.exe
```

- Each case boots a VM whose `policy.startup.commands` write marker files to
  `/work`; the test asserts on them from the host.
- Cases boot with `--fast`, except exactly one, `e2e-non-fast-egress`, which
  covers the normal image build and its egress. Keep that one.
- `VM_LAUNCHER_E2E_ONLY=<case>[,<case>…]` runs a subset;
  `VM_LAUNCHER_E2E_KEEP_STATE=1` keeps the session dirs for debugging.
- The first run builds the guest closure (minutes); later runs take seconds
  per case.
- Without `VM_LAUNCHER_E2E=1`, `dune test` prints `skip e2e-vm …` and passes.

### Known spurious failure

`e2e-second-launcher-queues` fills every network slot to test queueing. If
your own VMs hold slots, it fails with
`launcher pid N never appeared in any slot-<i>.lock`. The queue banner in the
log names the VMs holding the slots. Stop them, or read that failure as
unrelated.
