# vm-launcher policy contract. Every project's microvm.ncl is validated
# against this. Unknown fields / wrong types are rejected before any VM
# is built.
#
# Source of truth lives here (vm-launcher repo). The host's NixOS
# configuration installs this file to
# `/run/current-system/sw/share/vm-launcher/contract.ncl`; projects
# import that absolute path from their `microvm.ncl`. The OCaml parser
# in `lib/policy.ml` is the in-process mirror of this schema — keep the
# field names + shapes in sync.
{
  Policy = {
    # Project directory bridged into the guest at /work. ABSOLUTE host path.
    # Required — no sensible default.
    project | String,

    # Share mode for the project, plus subpath carve-outs.
    work | {
      # Baseline: whole project rw or ro.
      default | [| 'rw, 'ro |] | default = 'rw,
      # Subpaths (RELATIVE to project root) forced read-only. Each becomes
      # an extra virtiofs share mounted on top of /work/<sub>, so the ro is
      # a kernel-level mount — same hardness as the bwrap fs.repo.readOnly
      # binds, no PATH bypass.
      readOnly | Array String | default = [],
      # Subpaths hidden entirely: tmpfs over the mountpoint inside the guest.
      # Use for ".env", "secrets/", anything the agent shouldn't even see.
      hidden | Array String | default = [],
    } | default = {},

    # External RO inputs mounted at /inputs/<basename>. Absolute host paths.
    inputs | Array String | default = [],

    # Arbitrary host paths bound into the guest at arbitrary mountpoints.
    # For RO datasets where /inputs/<basename> is fine, use `inputs`
    # instead (simpler). Use `shares` when you need:
    #   - RW access from inside the VM (a scratch cache, a downloads dir)
    #   - A specific guest path (not /inputs/<basename>)
    #   - A read-only mount with a hand-picked mountpoint
    #
    # Constraint: every PARENT of `mountPoint` must exist at boot
    # (before local-fs.target). Safe parents include /mnt, /srv, /opt,
    # /var/lib, /home/<user>. NOT safe: paths inside the agent's config
    # dir (e.g. ~/.claude/projects/...), /home/<user>/.config, anything
    # constructed at runtime by agent-home-init or the startup hooks. A
    # mount whose parent doesn't exist fails local-fs.target and blocks
    # boot.
    #
    # securityModel is hardcoded to "passthrough" (host uid maps directly
    # to guest uid 1000 = agent), matching every other share. If a future
    # case needs "mapped"/"none"/etc, add the field.
    shares | Array {
      source | String,
      mountPoint | String,
      readOnly | Bool | default = false,
    } | default = [],

    # Egress allowlist. The in-guest proxy gates by hostname; the firewall
    # drops everything else. DNS happens inside the proxy.
    egress | {
      hosts | Array String | default = ["api.anthropic.com"],
      # If true, the guest has no network at all (no proxy started, no NAT).
      none | Bool | default = false,
    } | default = {},

    # Auth handling.
    # - 'bind:      ro-bind ~/.claude into /var/lib/claude (default)
    #               NB: this shares the host's OAuth refresh token, which
    #               rotates on refresh and can't be written back through the
    #               RO bind. Pair 'bind with a `secrets` entry exporting
    #               CLAUDE_CODE_OAUTH_TOKEN (see docs/credentials.md) or the host
    #               gets logged out every time a guest refreshes.
    # - 'ephemeral: no auth in; re-login per session
    auth | [| 'bind, 'ephemeral |] | default = 'bind,

    # Guest tools (nixpkgs attr names). THIS LIST IS THE MANIFEST of what
    # the guest has on PATH for Claude's Bash tool. Default includes the
    # tools Claude Code's host-configured statusLine script tends to need
    # (jq for parsing, gnused for line filters) on top of git + coreutils.
    tools | Array String
      | default = ["coreutils", "bashInteractive", "git", "jq", "gnused", "claude-code"],

    # VM resource sizing. memMb is checked against the host at launch:
    # > MemTotal is a hard error, > MemAvailable a warning (an
    # overcommitted guest boots, then gets its VMM OOM-killed mid-run
    # once the workload faults in more pages than the host can back).
    resources | {
      vcpu | Number | default = 4,
      memMb | Number | default = 4096,
    } | default = {},

    # User-facing console inside the guest. Affects only WHERE the
    # interactive shell + login banner appear; kernel logs are still
    # captured on ttyS0 in both modes (panic dumps land there).
    #
    # - 'hvc0 (default): virtio-console wired to the launcher's stdio.
    #   The vring batches writes, so TUI redraws (e.g. claude's
    #   full-screen panel) feel native. cloud-hypervisor gets
    #   `--console tty --serial pty`; ttyS0 stays alive as a host pty,
    #   so kernel printk mirrors to both consoles even though the user
    #   sees hvc0.
    # - 'ttyS0:         emulated 16550 UART wired to the launcher's
    #   stdio (microvm.nix default: `--console null --serial tty`).
    #   Byte-at-a-time PIO with one VM-exit per byte → TUI redraws
    #   crawl. Set this only when you need the legacy serial port for
    #   debugging (matching a host-side ttyS0 sink, or as a fallback
    #   if virtio-console misbehaves).
    console | [| 'hvc0, 'ttyS0 |] | default = 'hvc0,

    # The session's DEFAULT agent — the one `agent-run` resolves to, and
    # the one whose name leads the login MOTD. Additional agents living in
    # the same VM go in `extraAgents` below; both take the same profile
    # shape (see AgentProfile at the bottom of this file).
    agent | AgentProfile | default = {},

    # Additional agents present in the SAME VM, each with its own
    # `<name>-run` wrapper, config bind, instructions file and state
    # namespace. Empty (default) = a single-agent VM, exactly as before.
    #
    #     agent       = { preset = 'claude },     # agent-run -> claude-run
    #     extraAgents = [ { preset = 'codex } ],  # also: codex-run
    #
    # Every declared agent's `package` is added to the guest closure, so
    # you do NOT also list it in `tools` — declaring the agent IS the
    # declaration. Names must be unique (the launcher rejects duplicates):
    # they name the wrapper, the state namespace and the tmux window.
    #
    # Running two agents at once needs somewhere to run them — see
    # `session.multiplex` below.
    extraAgents | Array AgentProfile | default = [],

    # Interactive session shape inside the guest.
    session | {
      # Run sshd in the guest, listening ONLY on the slot's guest address
      # (10.42.<slot>.2:22), so the operator can `vm-launcher attach` from
      # any terminal and get an independent shell — as many at once as
      # they like. Keys are per session, generated by the launcher; no
      # passwords, no root login.
      #
      # This does NOT weaken the fence. The guest's nftables `input` chain
      # is already policy accept; only `output` is filtered (that IS the
      # egress fence). The tap network is host-only and unroutable from
      # outside, so this opens the guest to the operator, not the world.
      #
      # Turning it off means the guest console is the only way in, and
      # `vm-launcher attach` / `--detach` stop working for this project.
      ssh | Bool | default = true,

      # Terminal multiplexer on the guest console. The VM has exactly ONE
      # console and one login shell, so without a multiplexer only one
      # agent can be interactive at a time.
      #
      # - 'none (default): a plain login shell. With `ssh` above, extra
      #   interactive sessions come from `vm-launcher attach` instead —
      #   each one independent, which is what multiplexing was standing in
      #   for. Nothing stops you running `tmux` by hand inside the guest.
      # - 'tmux:           always multiplex — a window per declared agent
      #   plus a `shell`. Still worth choosing: an ssh session that drops
      #   takes its agent with it, whereas a guest tmux survives the
      #   disconnect and `vm-attach` picks it back up.
      # - 'auto:           tmux IF more than one agent is declared.
      #
      # The guest's tmux uses BACKTICK as its prefix, matching the host
      # config it is usually nested inside (press it twice to reach the
      # inner session).
      multiplex | [| 'auto, 'tmux, 'none |] | default = 'none,
    } | default = {},

    # Banner shown to the human on the serial console at login, below the
    # built-in MOTD and framed by a divider. Use for project-specific
    # reminders aimed at the person booting the VM (not the agent — see
    # agent.instructions for that). Multiline strings work as written.
    # Empty (default) => no banner section.
    loginMessage | String | default = "",

    # Per-project secrets surfaced as env vars in the guest. Each entry is a
    # host file the launcher copies into the session etc dir; the guest's
    # /etc/profile.d/ exports the contents under the env var name. The host
    # file should be 0600-owned by you. Common uses:
    #   { source = "~/.config/microvm/tokens/<proj>.gh", env = "GH_TOKEN" }
    #
    # scope ('agent | 'proxy):
    #   - 'agent (default): launcher wires the value into the guest's
    #     loginShellInit env. The agent process can read it.
    #   - 'proxy:           launcher stages the value into an
    #     egress-proxy-owned dir, and the proxy MITM-injects it into
    #     matching outbound requests (see proxyAuth below). The agent
    #     CAN'T read it (no sudo + tmpfs-shadow over the staging path).
    secrets | Array {
      source | String,
      env | String,
      scope | [| 'agent, 'proxy |] | default = 'agent,
    } | default = [],

    # Literal, non-secret env vars exported in the guest's agent login
    # shell. Keys must match [A-Z_][A-Z0-9_]* (POSIX env-var rules);
    # the launcher rejects anything else at parse time. Values are
    # literal strings — the launcher single-quotes them so anything
    # safely round-trips through the shell. Use for informational
    # identity (GH_USER, GH_EMAIL_NOREPLY), tool prefs
    # (EDITOR, JULIA_NUM_THREADS, RUST_LOG), or anything else the agent
    # needs to read at runtime. Anything sensitive belongs in
    # `secrets` (file-sourced, kept out of the checked-in .ncl).
    #
    # Example:
    #   env = {
    #     GH_USER = "agent-bot",
    #     EDITOR = "vim",
    #     JULIA_NUM_THREADS = "8",
    #   }
    env | { _ : String } | default = {},

    # MITM header-injection rules. Each rule: for matching host
    # (domain-suffix match), the egress proxy TLS-terminates the
    # connection and INJECTS the configured header into the outbound
    # request (overwriting any agent-supplied header of the same name —
    # that's the threat model). valueTemplate supports ${NAME}
    # substitution against the secret-dir built from
    # secrets[scope="proxy"]. Example:
    #   { host = "api.openai.com", header = "Authorization",
    #     valueTemplate = "Bearer ${OPENAI_KEY}" }
    proxyAuth | Array {
      host | String,
      header | String,
      valueTemplate | String,
    } | default = [],

    # Guest identity.
    #
    # hostname: the guest's networking.hostName. Empty (default) lets
    # vm-launcher derive it from the project root's basename, lowercased
    # and RFC-1123-sanitized:
    #   /home/alice/src/MyProject          → "myproject"
    #   /home/alice/src/my_project.workdir → "my-project-workdir"
    # Override if you want a stable name across project moves.
    #
    # username: the user the agent runs as inside the guest. Empty
    # (default) → host $USER + "-vm" suffix (so commits/git logs
    # inside the guest don't look identical to host activity),
    # POSIX-sanitized, capped at 32 chars. No host $USER → "vmlauncher".
    guest | {
      hostname | String | default = "",
      username | String | default = "",
    } | default = {},

    # Run-on-boot hooks.
    #
    # The guest's vm-launcher-startup-hooks systemd unit runs these AFTER
    # agent-home-init (so ~/<configDir> is populated) and BEFORE the
    # interactive shell, as the agent user in /work. Stdout + stderr
    # from every command go to `logFile`. Examples:
    #
    #   startup.commands = [
    #     { command = "uv sync" },                              # warn (default)
    #     { command = "test -f data/x.parquet", onFailure = "block" },
    #   ]
    #
    # onFailure:
    #   'warn  (default): log it, keep going with the next command.
    #                     Interactive shell still starts. Best for
    #                     debugging — a broken provisioning step
    #                     shouldn't lock you out of the VM.
    #   'block:           fail vm-launcher-startup-hooks, which fails
    #                     vm-launcher-session, which kills the VM. Use for
    #                     strict preconditions.
    #
    # tools: nixpkgs attrs scoped to the startup-hooks systemd unit's
    # PATH, independent of policy.tools (which scopes the agent's
    # interactive shell). Empty (default) is a sentinel: the guest-side
    # wiring substitutes policy.tools so existing policies keep working
    # with no change. Set explicitly to give the boot phase a tighter
    # PATH than the agent — e.g. `startup.tools = ["coreutils", "curl",
    # "git"]` exposes only those during provisioning even when the
    # agent's policy.tools includes much more. Validated against
    # nixpkgs the same way policy.tools is.
    #
    # logFile: absolute path inside the guest. Empty (default) lets
    # the guest pick: /var/lib/vm-launcher-state/startup.log when
    # auth = "bind" + stateDir != "" (persistent across reboots),
    # otherwise /tmp/vm-launcher-startup.log (lost on reboot but at
    # least captured). Override if you want it under /work for
    # discoverability.
    startup | {
      commands | Array {
        command | String,
        onFailure | [| 'warn, 'block |] | default = 'warn,
      } | default = [],
      tools | Array String | default = [],
      logFile | String | default = "",
    } | default = {},

    # Per-project persistent state dir on the host, bridged RW into the
    # guest. Holds Claude's sessions/todos/history/.claude.json across VM
    # restarts so `claude --resume` works. Stays separate from the host's
    # ~/.claude — guest never writes to that.
    # Empty string => launcher derives $XDG_STATE_HOME/microvm/<basename>/
    # (i.e. ~/.local/state/microvm/<basename>/ by default).
    stateDir | String | default = "",

    # Julia config. Sets JULIA_PROJECT inside the guest so every julia
    # invocation (Snakefile rules, REPL, scripts) auto-activates the
    # project's centralized env. Sysimage convention: <env>/julia_sysimage.so.
    julia | {
      # Path to the centralized Julia env, RELATIVE to the project root.
      # /work/<julia.env> ends up as JULIA_PROJECT.
      env | String | default = "env/julia",
    } | default = {},

    # R config. Plain `pkgs.R` has no library path, so listing "R" in
    # `tools` would give a bare binary that can't `library(readxl)`. When
    # `r.packages` is non-empty, the guest builds
    # `rWrapper.override { packages = map (n: rPackages.${n}) ...; }` and
    # puts that on PATH instead — `R` and `Rscript` then see the requested
    # CRAN packages via R_LIBS_SITE.
    #
    # Each entry is a `pkgs.rPackages.<name>` attr (e.g. "readxl", "dplyr").
    # Typos fail at eval time, not inside the guest.
    r | {
      packages | Array String | default = [],
    } | default = {},

    # Git identity used inside the guest. Defaults derive from the host's
    # `git config --global` user.name/user.email with markers added so VM
    # commits are visibly distinguishable from host commits:
    #   name  = "<host name> (vm-launcher)"
    #   email = "<localpart>+vmlaunch@<domain>"   (gmail-style + subaddress)
    # Override per-project if you want a different identity (e.g. work email).
    git | {
      name | String | default = "",
      email | String | default = "",
      # Soft (PATH-soft) layer: when non-empty, /etc/gitconfig gets
      # insteadOf rules that rewrite any github.com URL NOT covered by
      # these entries to https://blocked.invalid/... so git clone/fetch
      # fails. Bypassable by `git -c url.X.insteadOf=...` or non-git tools;
      # the hard layer is the egress allowlist + GH_TOKEN scope. This
      # mainly stops the agent from casually cloning unrelated repos.
      #
      # Each entry is either an org/user (whole namespace allowed, e.g.
      # "LouLouLibs") or an org/repo pair (only that repo allowed, e.g.
      # "alice/myproject"). Matching is case-sensitive.
      #
      # Caveat for org/repo entries: the canonical clone URL
      # `https://github.com/<org>/<repo>.git` matches, as does any URL with
      # a `/` after the repo name. The bare form `https://github.com/<org>/<repo>`
      # (no `.git`, no trailing slash) falls through to blocked.invalid —
      # adding a no-terminator rule would silently allow `<repo>Extra` too,
      # which is worse. Stick to the `.git` form for clone URLs.
      allowedGithubOrgs | Array String | default = [],
    } | default = {},
  },

  # One agent's wiring, as plain data. `preset` selects the defaults for
  # every field below; each is individually overridable. The base guest
  # reads only these fields, so it carries no literal agent name.
  #
  # Used for `Policy.agent` (the session default) and for every entry of
  # `Policy.extraAgents`. The host-side config dir (configHost) is
  # launcher-injected at boot, not set here.
  AgentProfile = {
    preset | [| 'claude, 'codex |] | default = 'claude,

    # Identity of this agent within the session. Names the `<name>-run`
    # wrapper, the agent's state namespace under the RW state dir, and its
    # tmux window. Must be unique across `agent` + `extraAgents`, and a
    # bare word (it becomes a command name and a path segment).
    name | String
      | default = preset |> match { 'claude => "claude", 'codex => "codex" },

    # nixpkgs attr delivering the binary. Added to the guest closure
    # automatically for every declared agent — do NOT also list it in
    # `tools`.
    package | String
      | default = preset |> match { 'claude => "claude-code", 'codex => "codex" },

    # Binary the run wrapper execs.
    command | String
      | default = preset |> match { 'claude => "claude", 'codex => "codex" },

    # Flags baked into the prompts-off run wrapper. The VM is the
    # boundary, so dangerous mode is the default — nothing left to prompt
    # about. codex's equivalent of claude's --dangerously-skip-permissions
    # is --dangerously-bypass-approvals-and-sandbox, which also switches
    # OFF codex's own in-process sandbox: it would otherwise try to nest a
    # seccomp/landlock jail inside the VM jail.
    flags | Array String
      | default = preset |> match {
        'claude => ["--dangerously-skip-permissions"],
        'codex => ["--dangerously-bypass-approvals-and-sandbox"],
      },

    # Filename of the auto-generated session-context file, exposed in the
    # guest as ~/<configDir>/<instructionsFile>.
    instructionsFile | String
      | default = preset |> match { 'claude => "CLAUDE.md", 'codex => "AGENTS.md" },

    # Per-project memory appended to the auto-generated VM context. The
    # launcher renders both into ~/<configDir>/<instructionsFile> so the
    # agent reads it as user-level memory. Use markdown. Examples:
    #   "Prefer DataFrames over DataFramesMeta; never edit raw_data/."
    instructions | String | default = "",

    # The agent's config dir, RELATIVE to $HOME on the host; the launcher
    # resolves configHost = $HOME/<configDir> when auth = 'bind. Usually a
    # dotfile basename, but a nested path is fine — e.g. relocating codex
    # to ~/.config/codex via CODEX_HOME (see configEnv).
    configDir | String
      | default = preset |> match { 'claude => ".claude", 'codex => ".config/codex" },

    # RO config-bind mountpoint inside the guest.
    configGuest | String
      | default = preset |> match { 'claude => "/var/lib/claude", 'codex => "/var/lib/codex" },

    # Env var pointing the agent at its guest-side config dir ("" = none,
    # the agent finds it by convention). codex hardcodes ~/.codex unless
    # CODEX_HOME says otherwise, so a relocated configDir MUST set this or
    # the guest agent reads a directory nobody wrote to.
    configEnv | String
      | default = preset |> match { 'claude => "", 'codex => "CODEX_HOME" },

    # How ~/<configDir> is built inside the guest:
    #
    # - 'symlinks (claude): a real dir of symlinks — every entry of the RO
    #   config bind linked in, with `stateDirs`/`stateFiles` redirected to
    #   the RW state dir. Keeps the host's settings authoritative and the
    #   writable surface explicitly enumerated.
    # - 'writable (codex): the dir IS the agent's RW state namespace, with
    #   `seedFiles` copied in from the RO bind at boot. Required when the
    #   agent writes all over its own home: codex keeps sqlite DBs
    #   (state/logs/goals/memories/thread history) at the root of
    #   CODEX_HOME, refreshes auth.json in place, and extracts+execs
    #   helper binaries (codex-linux-sandbox, codex-execve-wrapper) into
    #   CODEX_HOME/tmp. A symlink farm cannot express that, and sqlite
    #   would scatter -wal/-shm sidecars across the two filesystems.
    configMode | [| 'symlinks, 'writable |]
      | default = preset |> match { 'claude => 'symlinks, 'codex => 'writable },

    # 'writable only: files COPIED from the RO config bind into the
    # writable config dir at boot. The host copy stays authoritative —
    # the guest's edits are re-seeded over on the next boot and never
    # reach the host. This is deliberate for credentials: the guest can
    # refresh its own copy of auth.json without the host being logged out
    # by a rotated refresh token.
    seedFiles | Array String
      | default = preset |> match {
        'claude => [],
        'codex => ["auth.json", "config.toml"],
      },

    # RW task-tracker nest under configGuest ("" = none).
    taskDir | String
      | default = preset |> match { 'claude => "tasks", 'codex => "" },

    # 'symlinks only: the writable layout the home-init service redirects
    # to the RW state dir so it persists across restarts — subdirs, files
    # inside configDir, and files that are siblings of configDir in $HOME.
    # Unused under 'writable (the whole config dir already persists).
    stateDirs | Array String
      | default = preset |> match {
        'claude =>
          [ "projects", "todos", "session-env", "shell-snapshots",
            "file-history", "paste-cache" ],
        'codex => [],
      },
    stateFiles | Array String
      | default = preset |> match { 'claude => ["history.jsonl"], 'codex => [] },
    homeStateFiles | Array String
      | default = preset |> match { 'claude => [".claude.json"], 'codex => [] },

    # 'symlinks only (needs a state dir): files inside configDir that the
    # agent replaces ATOMICALLY (write-temp + rename) rather than writing
    # in place. A `stateFiles` symlink cannot hold those — the rename
    # swaps the link for a plain file on the guest's tmpfs root and the
    # write never reaches the state dir. Instead each one is copied in
    # from the agent's state namespace at boot (a regular file; the RO
    # bind's copy is never linked in) and copied back on every change by
    # a systemd path unit. The motivating case is claude's
    # `.credentials.json`: listing it gives the guest its OWN persistent
    # /login (Remote Control, connectors), whose refresh-token rotation
    # can't log the host out because it is a separate token family.
    syncFiles | Array String | default = [],
  },
}
