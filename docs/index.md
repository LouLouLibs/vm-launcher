---
title: vm-launcher
sidebar: false
prev: false
next: false
---

# vm-launcher

Coding agents in a disposable NixOS microVM {.subtitle}

**Platform:** NixOS host with KVM · **Agents:** Claude Code, codex · **Status:** private, in daily use {.meta}

`vm-launcher` boots coding agents ([Claude Code](https://docs.claude.com/en/docs/claude-code)
and [codex](https://github.com/openai/codex), together if you want both)
inside an ephemeral [cloud-hypervisor](https://www.cloudhypervisor.org/)
microVM. The VM wall **is** the security boundary, so the agent runs
prompts-off without putting the host at risk:

- it sees **only the project directory** you share (with read-only and hidden
  carve-outs);
- it reaches **only the hosts you allowlist**, through an in-guest proxy;
- everything it didn't write to a shared dir is **wiped on shutdown**.

Each project describes its cage in a small [Nickel](https://nickel-lang.org)
policy, `envs/vm/microvm.ncl`. The launcher validates it, builds the guest,
wires up the shares and the egress fence, and drops you at a shell inside.

New here? Start with [Getting started](getting-started.md).

## A quick tour

```bash
# from a project root, on the host
vm-launcher --show          # resolve the policy + egress allowlist, no boot
vm-launcher                 # boot the VM and attach this terminal
#   … work inside; Ctrl-D leaves the VM running …
vm-launcher attach          # another shell in it, from any terminal
vm-launcher ls              # what's running, for how long, with which agents
vm-launcher down            # power it off
```

Inside the guest, `claude-run` / `codex-run` start an agent prompts-off;
the bare `claude` / `codex` keep their own permission prompts.

## What's in the box

- **A policy per project:** shares, egress allowlist, secrets, tools, agents,
  resources, git identity. Validated before anything is built.
  See [Writing a policy](policies.md).
- **An egress fence:** nftables lets only the in-guest proxy out, and the
  proxy enforces the hostname allowlist and can inject secrets the agent never
  sees. See [Network and egress](network.md).
- **Credentials without host logouts:** a shared setup-token, or a VM's own
  persistent login. See [Credentials and logins](credentials.md).
- **No connectors by default:** keep the agent away from your mail and
  documents. See [claude.ai connectors](connectors.md).
- **Several VMs at once:** each session gets its own network slot, and launches
  queue when every slot is busy. See [Running VMs](running.md).
