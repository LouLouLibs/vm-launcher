# NixOS guest config for the vm-launcher microVM tier.
#
# Imported by flake.nixosConfigurations.vmLauncher in default.nix.
# Architectural invariants:
#   - imports ./_proxy.nix (the vm-egress-proxy module) — same dir.
#   - the agent user has NO wheel membership and there's no sudoers
#     entry. Without this, `sudo cat /run/egressproxy/secrets/*`
#     defeats the proxy-only secret model.
#   - environment.loginShellInit reads agent-scoped secrets from
#     /etc/vm-launcher/agent-secrets/ (Stage.secrets writes Agent_env
#     entries there).
#
# Reads the per-session policy from VM_LAUNCHER_POLICY_JSON (the launcher
# exports that env var before running `nix build`). No IFD: the only
# ${} interpolation is fromJSON of an absolute path the launcher wrote.
#
# Leading `_` keeps import-tree from picking this up as a host-side
# flake-parts module.
{ pkgs, lib, modulesPath, microvm, vmLauncherPkg, ... }:
let
  policyEnv = builtins.getEnv "VM_LAUNCHER_POLICY_JSON";
  # Eval-only fallback so `nix flake check` / `nix flake show` can evaluate the
  # vmLauncher nixosConfiguration in a clean shell (no env var). It is a minimal
  # but complete policy: every field the guest reads, with inert defaults
  # (ephemeral auth, no tools, no shares). The launcher ALWAYS exports
  # VM_LAUNCHER_POLICY_JSON before building, so a real session never uses this —
  # it exists purely to keep the output evaluable instead of throwing.
  evalOnlyPolicy = {
    tools = []; inputs = []; shares = []; loginMessage = "";
    egress = { hosts = []; none = false; mode = "allowlist"; };
    auth = "ephemeral"; stateDir = ""; project = "/var/empty"; console = "ttyS0";
    # Inert agent block (claude-preset shape, configHost = "") so
    # `nix flake check` evaluates without a real policy.
    agent = {
      preset = "claude"; name = "claude"; package = "claude-code";
      command = "claude"; flags = [];
      instructionsFile = "CLAUDE.md"; instructions = "";
      configDir = ".claude"; configGuest = "/var/lib/claude";
      configEnv = ""; configMode = "symlinks"; seedFiles = [];
      taskDir = "tasks";
      stateDirs = []; stateFiles = []; homeStateFiles = []; syncFiles = [];
      configHost = "";
    };
    extraAgents = [];
    session = { multiplex = "none"; ssh = true; headless = false; };
    startup = { tools = []; commands = []; logFile = ""; };
    guest = { username = ""; hostname = ""; };
    work = { default = "ro"; readOnly = []; hidden = []; };
    resources = { vcpu = 1; memMb = 512; };
    r = { packages = []; };
    julia = { env = ""; };
    git = { name = ""; email = ""; allowedGithubOrgs = []; };
  };
  policy =
    if policyEnv == ""
    then evalOnlyPolicy
    else builtins.fromJSON (builtins.readFile policyEnv);

  # Neutral agent profile (see policy/contract.ncl). The base guest is
  # wired entirely off these fields so it carries no literal agent name.
  # `agent` is the session DEFAULT (what `agent-run` resolves to);
  # `agents` is every agent this VM carries, default first.
  agent = policy.agent;
  extraAgents = policy.extraAgents or [];
  agents = [ agent ] ++ extraAgents;

  # Terminal multiplexer. The VM has ONE console and one login shell, so
  # a second agent has nowhere to run without this. "auto" turns tmux on
  # exactly when there is more than one agent, leaving single-agent VMs
  # with the plain login shell they have always had.
  # Matches contract.ncl and Policy.parse_session — see the note there.
  multiplexMode = policy.session.multiplex or "none";
  multiplexed =
    if multiplexMode == "tmux" then true
    else if multiplexMode == "none" then false
    else builtins.length agents > 1;

  # Per-agent paths. The state namespace keeps two agents from colliding:
  # claude and codex BOTH keep a history.jsonl, and the launcher migrates
  # any pre-namespacing flat layout into <state>/<name>/ at boot.
  agentStateNs = a: "/var/lib/vm-launcher-state/${a.name}";
  agentHomeDir = a: "${guestHome}/${a.configDir}";
  agentRunName = a: "${a.name}-run";
  # agent.syncFiles (symlinks mode only; `or []` for an older launcher's
  # policy.json without the field).
  agentSyncFiles = a:
    if (a.configMode or "symlinks") == "symlinks" then a.syncFiles or [] else [];
  # Agents whose sync files can actually persist (they need the state bind).
  syncAgents = lib.filter (a: agentSyncFiles a != [])
    (if policy.auth == "bind" && policy.stateDir != "" then agents else []);
  # Staged VM context for this agent (Stage.instructions writes one per
  # agent, namespaced so two agents of the same preset can't collide).
  agentStagedInstructions = a:
    "/etc/vm-launcher/instructions/${a.name}/${a.instructionsFile}";

  # systemd .mount unit name for the RO config bind, derived from
  # agent.configGuest. Mirror systemd's path escaping: strip the leading
  # '/', replace '/' with '-', and escape a literal '-' to '\x2d' (so
  # /var/lib/claude → var-lib-claude, and a dashed path like
  # /var/lib/codex-cli → var-lib-codex\x2dcli, matching how systemd names
  # the .mount unit). replaceStrings is a single left-to-right pass and
  # does NOT re-scan its own output, so the '/'→'-' substitution can't be
  # re-escaped — the two rules compose correctly. This is the same
  # escaping the hardcoded `var-lib-vm\x2dlauncher\x2dstate.mount` literal
  # below uses; deriving it here keeps any future preset's configGuest
  # (PR-B's /var/lib/codex, a site override, etc.) pointing at the unit
  # systemd actually instantiates. (escapeSystemdPath lives only in the
  # NixOS `utils` module arg, not in `lib`, so we open-code it.)
  configMountUnitOf = a:
    (builtins.replaceStrings [ "/" "-" ] [ "-" "\\x2d" ]
      (lib.removePrefix "/" a.configGuest)) + ".mount";

  # Effective network posture (launcher-injected; see Policy.egress_mode).
  #   "allowlist" (default) → in-guest MITM proxy + nftables allowlist.
  #   "noblock"             → UNFENCED: no proxy, direct internet via NAT.
  #   "block"               → no egress at all (nftables drops it).
  # `or "allowlist"` keeps an older launcher (policy.json without the
  # field) on the fenced default — fail safe, never fail open.
  # Accepts both vocabularies: "fenced"/"unfenced"/"airgap" as the
  # launcher writes them now, and the older "allowlist"/"noblock"/"block"
  # so a policy.json staged by a previous launcher still boots. `or` on
  # a missing field keeps the fail-safe default of fenced.
  egressMode = policy.egress.mode or "fenced";
  fenced = egressMode == "fenced" || egressMode == "allowlist";
  airgap = egressMode == "airgap" || egressMode == "block";

  # ANSI styling for the login MOTD. The user-facing console is always
  # allocated as xterm-256color (see the agetty ExecStart below), so SGR
  # escapes render. The MOTD lays out each section behind a colored
  # gutter bar (no right border), so any path / greeting length aligns.
  # ESC (0x1b) has no Nix string escape; '' strings don't interpret
  # backslash, so the literal chars \u001b reach fromJSON as a JSON string.
  esc = builtins.fromJSON ''"\u001b"'';
  sgr = code: "${esc}[${code}m";
  ansi = {
    reset  = sgr "0";
    bold   = sgr "1";
    dim    = sgr "2";
    red    = sgr "91";
    green  = sgr "92";
    cyan   = sgr "96";
    gray   = sgr "90";
    yellow = sgr "93";
    bcyan  = sgr "1;96";
    bred   = sgr "1;91";
    byellow = sgr "1;93";
  };
  # MOTD layout primitives: each section is a self-contained block — a
  # top-left corner (┌─ TITLE ───) heading a left rail (vertical bar)
  # down its content. Sections are separated by a true blank line (the
  # rail breaks between them) so the ┌─ rules read as clean section
  # breaks; the final block closes with a └ bottom rule. The rail's tint
  # changes per section (e.g. red for an unfenced network).
  # Escapes are zero-width, so visible columns line up; ASCII titles
  # measure exactly via stringLength.
  motdWidth = 100;
  motdBar = n: lib.concatStrings (lib.genList (_: "─") (lib.max 0 n));
  gbar = color: "${color}│${ansi.reset}";
  # Titled rule. `corner` is the left glyph (┌ opens every section block;
  # └ closes the last one, via motdFoot, and takes no title). Title is
  # bolded; the rule fills to motdWidth.
  motdHead = corner: color: title:
    "${color}${corner}─${ansi.reset} ${ansi.bold}${title}${ansi.reset} "
    + "${color}${motdBar (motdWidth - 4 - builtins.stringLength title)}${ansi.reset}";
  motdFoot = color: "${color}└${motdBar (motdWidth - 1)}${ansi.reset}";
  # Render the freeform project greeting under a gutter. An indented,
  # non-bullet line reads as a runnable command (cyan, stands out);
  # everything else is prose in the default fg (NOT dimmed — dimming made
  # commands look disabled). Blank lines render as a bare gutter.
  gutterLines = color: text:
    lib.concatMapStringsSep "\n"
      (l:
        if l == "" then gbar color
        else if (builtins.match "^  +[^ -].*$" l) != null
        then "${gbar color}  ${ansi.cyan}${l}${ansi.reset}"
        else "${gbar color}  ${l}")
      (lib.splitString "\n" text);

  # Proxy env vars: only meaningful when the egress proxy actually runs
  # (fenced). Empty in noblock/airgap so clients go direct (noblock) or
  # nowhere (airgap) instead of dialing a proxy that isn't listening.
  proxyEnv = lib.optionalAttrs fenced {
    HTTPS_PROXY = "http://127.0.0.1:3128";
    https_proxy = "http://127.0.0.1:3128";
    HTTP_PROXY  = "http://127.0.0.1:3128";
    http_proxy  = "http://127.0.0.1:3128";
    NO_PROXY    = "localhost,127.0.0.1";
  };

  # CA trust. Fenced sessions verify against the runtime bundle the
  # vm-cabundle oneshot composes (system trust + per-VM MITM CA). Unfenced
  # /airgap sessions run no proxy and stage no CA, so /run/vm-ca-bundle.crt
  # is never written — point every TLS client at the plain system trust
  # store (there's no MITM to trust).
  caEnv =
    if fenced then {
      SSL_CERT_FILE       = "/run/vm-ca-bundle.crt";
      CURL_CA_BUNDLE      = "/run/vm-ca-bundle.crt";
      REQUESTS_CA_BUNDLE  = "/run/vm-ca-bundle.crt";
      NODE_EXTRA_CA_CERTS = "/etc/vm-launcher/proxy-ca.pem";
    } else {
      SSL_CERT_FILE      = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      CURL_CA_BUNDLE     = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      REQUESTS_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };

  # `vm-launcher --fast` exports VM_LAUNCHER_FAST=1; the guest-side
  # reads it here and strips the single-threaded mkfs.erofs flags
  # (-Efragments, -Ededupe) from microvm.storeDiskErofsFlags below.
  # Out-of-band channel by design: --fast is a transient dev-iteration
  # knob, not a per-project policy field, so it stays out of the
  # contract. Empty / absent / anything-but-"1" ⇒ false ⇒ default
  # (single-threaded, smaller image).
  fast = builtins.getEnv "VM_LAUNCHER_FAST" == "1";

  # Network slot (per-session networking). The launcher
  # allocates a free slot (a per-slot lockf under /run/vm-launcher) and
  # exports VM_LAUNCHER_SLOT before the closure build; everything
  # identity-shaped derives from it: tap id, MAC, guest IP, gateway,
  # and the per-slot current-session symlink the vmcfg share resolves
  # through. Same out-of-band getEnv rail as VM_LAUNCHER_FAST — the
  # slot is launch-time infrastructure, not project policy. Empty /
  # absent ⇒ "0", which reproduces the original single-identity layout
  # (vm-tap0 / 02:00:00:42:00:02 / 10.42.0.2), so an old launcher
  # against this config still works.
  slot =
    let raw = builtins.getEnv "VM_LAUNCHER_SLOT";
    in if raw == "" then "0" else raw;
  slotTap = "vm-tap${slot}";
  slotMac = "02:00:00:42:0${slot}:02";
  slotGuestIp = "10.42.${slot}.2";
  slotGateway = "10.42.${slot}.1";

  # policy.tools PLUS every declared agent's package: declaring an agent
  # is the declaration, so a policy doesn't have to also remember to list
  # "codex" in tools. Deduped — the existing policies still name
  # "claude-code" there and would otherwise appear twice.
  agentPackages = map (a: a.package) agents;
  toolNames = lib.unique (policy.tools ++ agentPackages);
  toolPkgs = builtins.map (n: pkgs.${n}) toolNames;

  # policy.startup.tools is the boot-phase manifest, independent of
  # policy.tools (which scopes the agent's interactive shell). Empty
  # list is the contract-documented sentinel for "inherit policy.tools";
  # non-empty list = exactly those nixpkgs attrs. The substitution
  # happens here, at the host-side boundary, so the contract default
  # ([]) means existing policies keep working without change while the
  # boot phase remains tightenable on demand.
  startupTools =
    if policy.startup.tools == []
    then toolNames        # resolved set: policy.tools + every agent's package
    else policy.startup.tools;
  startupToolPkgs = builtins.map (n: pkgs.${n}) startupTools;

  # agent.configEnv -> guest config dir, for every agent that declares one.
  agentConfigEnv = builtins.listToAttrs
    (map (a: { name = a.configEnv; value = agentHomeDir a; })
      (builtins.filter (a: a.configEnv != "") agents));

  # The "which agents does this VM carry" answer, as a list of MOTD
  # lines. Hoisted out of users.motd so `vm-agents` can print the exact
  # same text INSIDE tmux: attaching switches the terminal to the
  # alternate screen, which paints over the login MOTD before anyone can
  # read it, so in multiplexed mode the banner has to be reprinted where
  # the user actually lands.
  agentStartLines =
    lib.concatMap (ag:
      [ ("${gbar ansi.cyan}  ${ansi.cyan}❯${ansi.reset} ${ansi.bold}${agentRunName ag}${ansi.reset}"
         + "   ${ansi.gray}# ${ag.command}"
         + lib.optionalString (ag.name == agent.name)
             " — the default, also `agent-run`"
         + "${ansi.reset}")
      ]
      ++ lib.optional (ag.flags != [])
           "${gbar ansi.cyan}      ${ansi.dim}${lib.concatStringsSep " " ag.flags}${ansi.reset}")
      agents;

  agentWindowLines = [
    "${gbar ansi.cyan}  ${ansi.dim}one tmux window per agent (plus `shell`), all rooted at /work${ansi.reset}"
    "${gbar ansi.cyan}  ${ansi.dim}prefix is ${ansi.reset}${ansi.bold}${tmuxPrefix}${ansi.reset}${ansi.dim} (press it twice from a host tmux that forwards it)${ansi.reset}"
    "${gbar ansi.cyan}  ${ansi.bold}${tmuxPrefix} w${ansi.reset}${ansi.gray}  list windows${ansi.reset}   ${ansi.bold}${tmuxPrefix} n/p${ansi.reset}${ansi.gray}  next/prev${ansi.reset}   ${ansi.bold}${tmuxPrefix} c${ansi.reset}${ansi.gray}  new window${ansi.reset}"
    "${gbar ansi.cyan}  ${ansi.bold}${tmuxPrefix} d${ansi.reset}${ansi.gray}  detach — back to the login shell; `vm-attach` returns${ansi.reset}"
    "${gbar ansi.byellow}  ${ansi.byellow}▲${ansi.reset} ${ansi.dim}Ctrl-D at that bare shell powers the VM OFF, detached agents and all.${ansi.reset}"
  ];

  # Reprints the agent list on demand. Runs in the first tmux window at
  # session creation (so the banner is the first thing on screen) and is
  # on PATH as `vm-agents` any time after.
  vmAgentsScript = pkgs.writeShellScriptBin "vm-agents" ''
    cat <<'VM_AGENTS_EOF'

    ${lib.concatStringsSep "\n" (
        [ (motdHead "┌" ansi.bcyan "AGENTS") ]
        ++ agentStartLines
        ++ lib.optionals multiplexed ([ "" (motdHead "┌" ansi.cyan "WINDOWS") ] ++ agentWindowLines)
        ++ [ (motdFoot ansi.gray) ])}
    VM_AGENTS_EOF
  '';

  # sshd for `vm-launcher attach`. Independent shells, as many as
  # you open, instead of one console welded to the launching terminal.
  sshEnabled = policy.session.ssh or false;

  # Booted detached: no console login session at all. agetty on a non-tty
  # would restart-loop, and its ExecStopPost=poweroff would take the VM
  # down with the first shell that exits.
  headless = policy.session.headless or false;

  # Guest tmux prefix. Backtick, mirroring the host config: nested
  # sessions are driven by pressing it twice (the host's `bind ` 
  # send-prefix` forwards it inward).
  tmuxPrefix = "`";

  # tmux config + session builder. Only referenced when multiplexed.
  #
  # Prefix stays the stock C-b: a guest session is typically nested
  # inside the operator's OWN tmux on the host, and the two must differ.
  # screen-256color (not tmux-256color) because it is the entry most
  # reliably present in a minimal guest's terminfo.
  guestTmuxConf = pkgs.writeText "tmux.conf" ''
    # Prefix: backtick, matching the operator's host tmux. A guest session
    # is normally nested inside that one, and the host binds ` to
    # send-prefix — so ` ` (twice) reaches THIS tmux, which is the muscle
    # memory already in use. Keeping C-b here would have been the "safe"
    # non-colliding choice, but it means two different prefixes to hold in
    # your head.
    unbind C-b
    set -g prefix ${tmuxPrefix}
    bind-key ${tmuxPrefix} send-prefix

    set -g default-terminal "screen-256color"
    set -g history-limit 50000
    set -g mouse on
    set -g base-index 1
    setw -g pane-base-index 1
    set -g renumber-windows on
    set -g status-interval 10
    set -g status-keys emacs

    # Splits and new-window inherit the pane's cwd, as on the host.
    bind | split-window -h -c "#{pane_current_path}"
    bind - split-window -v -c "#{pane_current_path}"
    unbind '"'
    unbind %
    bind c new-window -c "#{pane_current_path}"

    # Bar: same features as the host's (session name, window list, clock)
    # but deliberately PLAINER — left-justified, no coloured block, muted
    # palette. The host bar is centred with a #698DDA highlight, so at a
    # glance the two nested bars are never confused: bottom-left "VM"
    # means you are typing into the guest.
    set -g status-position bottom
    set -g status-justify left
    set -g status-style "bg=colour234,fg=colour245"
    set -g status-left "#[fg=colour45,bold] VM #[fg=colour245,nobold]${guestHostName} #[default]"
    set -g status-left-length 40
    set -g status-right "#[fg=colour245]%H:%M "
    set -g status-right-length 20
    setw -g window-status-format " #I:#W "
    setw -g window-status-current-format "#[fg=colour45,bold] #I:#W #[default]"
    set -g pane-active-border-style "fg=colour45"
    set -g message-style "fg=colour234,bg=colour45"
  '';

  # One window per agent (named after it, rooted at /work) plus a plain
  # shell window. Windows start as SHELLS, not running agents: booting a
  # VM should not spend quota on sessions nobody asked for. The MOTD says
  # which command starts which.
  vmSessionScript = pkgs.writeShellScriptBin "vm-session" ''
    set -eu
    export PATH="${pkgs.tmux}/bin:$PATH"
    if tmux has-session -t vm 2>/dev/null; then
      exec tmux attach -t vm
    fi
    # The first window prints the agent list, then execs the login shell.
    # This has to happen as the window's START COMMAND, not via send-keys:
    # keys sent to a shell that is still initializing are discarded when
    # bash sets up the terminal (TCSAFLUSH), so the banner echoed and then
    # vanished. A start command has no such race.
    tmux -f ${guestTmuxConf} new-session -d -s vm -n ${(builtins.head agents).name} -c /work \
      "${vmAgentsScript}/bin/vm-agents; exec ${pkgs.bashInteractive}/bin/bash -l"
    ${lib.concatMapStrings (a: ''
      tmux new-window -t vm -n ${a.name} -c /work
    '') (builtins.tail agents)}
    tmux new-window -t vm -n shell -c /work
    tmux select-window -t vm:${(builtins.head agents).name}
    exec tmux attach -t vm
  '';

  # Resolved path of the collected startup-hooks log. Single source of
  # truth shared by the vm-launcher-startup-hooks unit (which writes it)
  # and the login MOTD (which points the operator/agent at it): policy
  # override > persistent (bind + stateDir != "") > /tmp fallback.
  startupLogFile =
    if policy.startup.logFile != ""
    then policy.startup.logFile
    else if policy.auth == "bind" && policy.stateDir != ""
    then "/var/lib/vm-launcher-state/startup.log"
    else "/tmp/vm-launcher-startup.log";

  # Guest identity. The launcher's Resolver.resolve_guest always fills
  # policy.guest.{hostname,username} before the JSON reaches here, so
  # the empty-string fallbacks below are belt-and-braces against an
  # older launcher binary OR a hand-written policy.json bypassing the
  # OCaml launcher.
  guestUser =
    if policy.guest.username != ""
    then policy.guest.username
    else "vmlauncher";
  guestHostName =
    if policy.guest.hostname != ""
    then policy.guest.hostname
    else "vmlauncher";
  guestHome = "/home/${guestUser}";

  # User-facing console wiring. See policy.contract.console for the
  # full rationale; the short version is "hvc0 = fast virtio-console
  # for TUIs, ttyS0 = slow emulated UART for legacy/debug".
  #
  # In hvc0 mode we tell cloud-hypervisor to wire its virtio-console
  # device to stdio (--console tty) and expose the 16550 UART as a
  # host pty (--serial pty) so kernel printk + panic dumps remain
  # captured. The kernel registers BOTH consoles via boot.kernelParams,
  # with hvc0 last so /dev/console points there (userspace init's
  # stdio reaches the user's terminal).
  #
  # In ttyS0 mode we leave both knobs unset and microvm.nix's defaults
  # (--console null --serial tty, kernel cmdline earlyprintk=ttyS0
  # console=ttyS0) take over — exactly the pre-knob behaviour.
  useHvc0 = policy.console == "hvc0";
  consoleTty = if useHvc0 then "hvc0" else "ttyS0";

  # R with project-declared CRAN packages. Bare `pkgs.R` has no library
  # path; we wrap it so `library(<name>)` works for everything listed in
  # policy.r.packages. Only built when the list is non-empty so guests
  # that don't use R don't drag in the R closure.
  rWithPkgs = pkgs.rWrapper.override {
    packages = builtins.map (n: pkgs.rPackages.${n}) policy.r.packages;
  };

  # One virtiofs share per work.readOnly subpath. Tag is short + stable.
  roShares = builtins.map (sub: {
    tag = "wkro-${builtins.substring 0 12 (builtins.hashString "md5" sub)}";
    proto = "virtiofs";
    source = "${policy.project}/${sub}";
    mountPoint = "/work/${sub}";
    readOnly = true;
    securityModel = "passthrough";
  }) policy.work.readOnly;

  # External RO inputs.
  externalInputs = lib.imap0 (i: src: {
    tag = "in-${toString i}";
    proto = "virtiofs";
    source = src;
    mountPoint = "/inputs/${builtins.baseNameOf src}";
    readOnly = true;
    securityModel = "passthrough";
  }) policy.inputs;

  # Generic policy.shares — arbitrary host source -> arbitrary guest
  # mountPoint, RO or RW per entry. Tag must match
  # Shares.share_tag in lib/shares.ml (the launcher iterates the
  # manifest by tag to spawn virtiofsds + tag the RO ones).
  #
  # CONTRACT: every parent of mountPoint MUST exist at boot (before
  # local-fs.target). Paths constructed at runtime by
  # agent-home-init (anything inside ~/<configDir>/projects/...) will
  # fail their .mount unit and block local-fs.target → no boot.
  # The contract.ncl comment documents this; nothing here enforces it.
  extraShares = lib.imap0 (i: share: {
    tag = "share-${toString i}";
    proto = "virtiofs";
    source = share.source;
    mountPoint = share.mountPoint;
    readOnly = share.readOnly;
    securityModel = "passthrough";
  }) policy.shares;

  # Config bind (skipped when auth == "ephemeral"). The host's agent
  # config dir (e.g. ~/.claude) is mounted RO — it contains settings,
  # statusline, custom skills, agents, plugins, auth credentials. The
  # guest never writes here.
  # One RO bind per declared agent. Tag is `auth-<name>`, which
  # Shares.ro_tags mirrors on the launcher side — keep the two in step.
  authBind = lib.optionals (policy.auth == "bind") (map (a: {
    tag = "auth-${a.name}";
    proto = "virtiofs";
    # Host config dir, resolved by the launcher from $HOME
    # (Boot.prepare_host_paths sets configHost per agent when auth =
    # bind) — NOT hardcoded to one user.
    source = a.configHost;
    mountPoint = a.configGuest;
    readOnly = true;
    securityModel = "passthrough";
  }) agents);

  # Per-project persistent state dir (resolved by the launcher to an
  # absolute path). Bridged RW for the agent's sessions/todos/history and
  # the writable home-state files. Skipped if stateDir == "".
  stateBind = lib.optionals (policy.stateDir != "") [{
    tag = "vmstate";
    proto = "virtiofs";
    source = policy.stateDir;
    mountPoint = "/var/lib/vm-launcher-state";
    readOnly = false;
    securityModel = "passthrough";
  }];

  # Some agents' task-trackers hardcode a writable path inside the config
  # dir (Claude Code: <configGuest>/tasks/<uuid>/.lock.lock) — which lands
  # inside the RO config bind, so the mkdir fails with EROFS. Nest a RW
  # share at that exact path (agent.taskDir) so the harness can write its
  # lock files. Source is <stateDir>/<taskDir> so tasks persist across VM
  # restarts. The launcher pre-creates both the source and the mountpoint
  # (the latter inside the host's config dir so the nested mount has
  # somewhere to land on the RO bind). Skipped when taskDir == "".
  tasksBind = lib.optionals (policy.auth == "bind" && policy.stateDir != "")
    (map (a: {
      tag = "tasks-${a.name}";
      proto = "virtiofs";
      # Namespaced under the agent, matching Boot.prepare_host_paths.
      source = "${policy.stateDir}/${a.name}/${a.taskDir}";
      mountPoint = "${a.configGuest}/${a.taskDir}";
      readOnly = false;
      securityModel = "passthrough";
    }) (builtins.filter (a: a.taskDir != "") agents));

  # /etc/vm-launcher host-side dir (carries egress-hosts allowlist) bridged in.
  vmcfgShare = [{
    tag = "vmcfg";
    proto = "virtiofs";
    source = "/run/vm-launcher/current-session-${slot}/etc";
    mountPoint = "/etc/vm-launcher";
    readOnly = true;
    securityModel = "passthrough";
  }];

  # Tmpfs over hidden subpaths in the guest. NixOS mounts these AFTER the
  # work share, hiding whatever was beneath.
  hiddenMounts = builtins.listToAttrs (builtins.map (sub: {
    name = "/work/${sub}";
    value = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "size=4M" "mode=0700" "nosuid" "nodev" ];
    };
  }) policy.work.hidden);

  # Force ro into the kernel mount options for each work.readOnly subpath.
  # virtiofsd's --readonly (set by the launcher) is what actually blocks
  # writes; this is the second-layer + makes `mount | grep /work` truthful.
  # microvm.nix upstream hardcodes virtiofs options to ["defaults" ...]
  # regardless of share.readOnly, so we override per-mountpoint here.
  roMountOptions = builtins.listToAttrs (builtins.map (sub: {
    name = "/work/${sub}";
    value.options = lib.mkForce [
      "ro" "nosuid" "nodev"
      "x-systemd.after=systemd-modules-load.service"
    ];
  }) policy.work.readOnly);
in {
  imports = [
    microvm.nixosModules.microvm
    ./_proxy.nix
  ];

  # Expose the parsed session policy as a module argument so site-specific
  # modules layered in via `mkGuest { extraModules = [...]; }` can react to
  # it with stock NixOS options (environment.variables, systemd.tmpfiles, …)
  # WITHOUT extending the Nickel contract. The contract stays the interface
  # (`tools = ["julia"]`); a site module turns that into e.g. sysimage wiring.
  # This is the portability seam.
  #
  # Consuming `policy` in a site module — two patterns:
  #   • Module applied ONLY inside the guest → name it: `{ policy, ... }:`.
  #   • Module ALSO applied on the host (e.g. an overlay module shared by
  #     host + guest) → do NOT name it; read it defensively:
  #       `let policy = config._module.args.policy or null; in ...`
  #     Naming a formal makes the module system REQUIRE _module.args.policy
  #     wherever the module is used, and it errors on the host (no policy
  #     there) — the `? null` arg default does not save it. Also keep any
  #     policy-reading config OUT of a module that sets nixpkgs.overlays
  #     (overlays evaluate in an earlier phase where the arg isn't ready).
  _module.args.policy = policy;

  nixpkgs.config.allowUnfree = true;

  # Surface per-project agent-scoped secrets bridged in via vmcfg as env
  # vars. Each file under /etc/vm-launcher/agent-secrets/ is named after an
  # env var (e.g. GH_TOKEN) and contains the secret. NixOS's /etc/profile
  # does NOT source /etc/profile.d/, so we use environment.loginShellInit
  # which gets baked into /etc/profile directly — sourced by every login
  # shell.
  #
  # Two-stage exports, in order:
  #   1. agent-secrets/* — file-sourced values from `policy.secrets`
  #      (scope = "agent").
  #   2. env-vars — literal NAME='value' lines from `policy.env`.
  # Sourced LAST so a name appearing in both `policy.secrets` and
  # `policy.env` resolves to the env value (Stage.env_vars and
  # Policy.t both document this winner-takes-key contract).
  #
  # Proxy-scoped secrets live under /etc/vm-launcher/proxy-secrets/ and are
  # picked up by the egressproxy-secret-bootstrap oneshot in _proxy.nix —
  # those NEVER get exported as env vars (the agent can't read them).
  environment.loginShellInit = ''
    if [ -d /etc/vm-launcher/agent-secrets ]; then
      for _vm_f in /etc/vm-launcher/agent-secrets/*; do
        [ -f "$_vm_f" ] || continue
        _vm_name="$(basename "$_vm_f")"
        _vm_val="$(cat "$_vm_f")"
        export "$_vm_name=$_vm_val"
      done
      unset _vm_f _vm_name _vm_val
    fi
    if [ -f /etc/vm-launcher/env-vars ]; then
      . /etc/vm-launcher/env-vars
    fi

    # NixOS's sshd prints the MOTD on every `vm-launcher attach`, and
    # that MOTD's footer talks about the CONSOLE. Correct it here for
    # anyone who arrived over ssh: Ctrl-D ends this shell and nothing
    # else, but whatever they started dies with the connection unless it
    # is under tmux.
    if [ -n "''${SSH_CONNECTION:-}" ] && [ -t 1 ]; then
      printf '\n  attached over ssh — Ctrl-D closes this shell only; the VM keeps running.\n'
      printf '  work that must outlive the connection: start it under `tmux`.\n\n'
    fi
  '' + lib.optionalString multiplexed ''
    # Multiplexed session: land in tmux instead of a bare console shell,
    # so several agents can be interactive at once.
    #
    # NOT exec'd, deliberately. exec would tie the login shell's lifetime
    # to tmux, and since vm-launcher-session powers the VM off when that
    # shell exits, a plain detach (C-b d) would kill the VM with the
    # agents still running in it. Returning here instead leaves the
    # session alive and reattachable.
    # SSH_CONNECTION guard: an attached session is already independent,
    # so auto-attaching it to the SHARED tmux would make every client
    # mirror one screen — the opposite of why you attached. Run
    # `vm-attach` by hand when you do want the shared session.
    if [ -t 0 ] && [ -z "''${TMUX:-}" ] && [ -z "''${SSH_CONNECTION:-}" ] \
       && [ -z "''${VM_LAUNCHER_NO_TMUX:-}" ]; then
      vm-session || true
      printf '\n  detached from the tmux session — it is still running.\n'
      printf '  vm-attach   to go back\n'
      printf '  Ctrl-D      to power the VM off (kills whatever is still running)\n\n'
    fi
  '';

  # System-wide proxy env + per-VM CA trust.
  #
  # The CA-bundle paths point at the runtime-composed bundle written by
  # the vm-cabundle oneshot in _proxy.nix (system trust + per-VM
  # MITM CA). Every TLS client picks one of these env vars:
  #   SSL_CERT_FILE       — OpenSSL / curl / most C clients
  #   CURL_CA_BUNDLE      — curl-specific fallback
  #   REQUESTS_CA_BUNDLE  — Python `requests` (and httpx via it)
  #   NODE_EXTRA_CA_CERTS — Node.js extras list (Node-based agents use this).
  #                         Note: NODE_EXTRA_CA_CERTS is "add THESE on
  #                         top of the system store" — point it at the
  #                         per-VM CA alone, not the composed bundle.
  #
  # environment.variables writes to /etc/environment, which PAM reads at
  # login → propagates into bash through /bin/login → the agent inherits
  # it. environment.sessionVariables (writes /etc/profile.d/) is
  # belt-and-braces for non-login shells.
  # Proxy + CA env: proxyEnv is empty unless fenced; caEnv points at the
  # runtime MITM bundle when fenced, the system trust store otherwise.
  # Per-agent config-dir env vars (agent.configEnv). codex hardcodes
  # ~/.codex unless CODEX_HOME says otherwise, so an agent whose
  # configDir is relocated MUST advertise it here or it reads a directory
  # nobody wrote to. Empty configEnv (claude) contributes nothing.
  environment.variables = proxyEnv // caEnv // agentConfigEnv;
  environment.sessionVariables = proxyEnv // caEnv // agentConfigEnv;

  # hvc0 mode: override microvm.nix's default `--console null --serial tty`.
  # `--console tty` puts virtio-console on the launcher's inherited stdio
  # (cloud-hypervisor exposes it as /dev/hvc0 in the guest). `--serial pty`
  # keeps the 16550 UART alive but redirects it to a host pty file so
  # kernel logs / panic dumps stay capturable without occupying the user's
  # terminal. ttyS0 mode: leave extraArgs empty so microvm.nix applies its
  # default (16550 UART on stdio), matching pre-knob behaviour.
  microvm.cloud-hypervisor.extraArgs = lib.optionals useHvc0 [
    "--console" "tty"
    "--serial" "pty"
  ];

  # hvc0 mode: with `--serial pty`, microvm.nix's auto-injected
  # `earlyprintk=ttyS0 console=ttyS0` is dropped (see lib/runners/
  # cloud-hypervisor.nix's `kernelConsole`), so we register both
  # consoles ourselves. Order matters: the LAST console=... becomes
  # /dev/console, and we want userspace init's stdio reaching the
  # user's terminal on hvc0. Earlyprintk goes to ttyS0 (the host pty,
  # invisible to the user) — only relevant for kernel panics before
  # the virtio-console driver inits. ttyS0 mode: leave kernelParams
  # empty so microvm.nix's default cmdline kicks in.
  # Quiet the boot console. The agent's first sight of the VM should be
  # the login MOTD, not ~150 lines of kernel printk + systemd unit
  # status. `quiet` + consoleLogLevel drop kernel chatter to warnings;
  # `systemd.show_status=false` hides the "[ OK ] Started …" flood;
  # udev.log_level trims device-event noise. None of this is lost —
  # `journalctl -b` inside the guest still has the full boot log. These
  # are orthogonal to the console= wiring, so they apply in both modes.
  boot.consoleLogLevel = 3;
  boot.kernelParams =
    [ "quiet" "systemd.show_status=false" "udev.log_level=3" "rd.udev.log_level=3" ]
    ++ lib.optionals useHvc0 [
      "earlyprintk=ttyS0"
      "console=ttyS0"
      "console=hvc0"
    ];

  microvm = {
    hypervisor = "cloud-hypervisor";
    vcpu = policy.resources.vcpu;
    mem = policy.resources.memMb;

    # Hermetic store: build a per-policy store-disk image containing ONLY
    # the closure of this guest's system. Without it (i.e. sharing the
    # host's /nix/store whole), the guest could reach any binary the host
    # has ever built — defeating the "policy.tools is the manifest" goal.
    # Cost: a few seconds the first time a closure is built; cached after.
    storeOnDisk = true;

    # --fast: drop the single-threaded -Efragments / -Ededupe passes
    # from mkfs.erofs so the store-disk build scales with cores. The
    # default (when [fast] is false) includes them and is what
    # microvm.nix's storeDiskErofsFlags would have set — see
    # microvm.nix's options.nix:1009-1018 for the upstream rationale
    # ("Omit -Efragments and -Ededupe to enable multi-threading").
    # lib.mkForce wins over the upstream listOf-str default; without
    # it the values would merge-append, leaving the slow passes in
    # the final cmdline.
    storeDiskErofsFlags = lib.mkIf fast (lib.mkForce [
      "-zlz4hc"
      "-Eztailpacking"
    ]);

    shares = [
      { tag = "work"; source = policy.project; mountPoint = "/work";
        proto = "virtiofs"; readOnly = (policy.work.default == "ro");
        securityModel = "passthrough"; }
    ] ++ roShares ++ externalInputs ++ extraShares
      ++ authBind ++ tasksBind ++ stateBind ++ vmcfgShare;

    interfaces = [{
      type = "tap";
      id = slotTap;      # host pre-creates the slot pool; see default.nix
      mac = slotMac;
    }];
  };

  # Tmpfs root. /nix/store is shared from the host, so no store disk needed.
  fileSystems = lib.recursiveUpdate (lib.recursiveUpdate {
    # mode=0755, not tmpfs's default 1777. A world-writable / is wrong on
    # its own terms — any process could drop files at the root — and it
    # is load-bearing for ssh: sshd's StrictModes walks every directory
    # on the way to authorized_keys and refuses the whole authentication
    # with "bad ownership or modes for directory /". That is how this
    # was found; the fix is the mode, not disabling the check.
    "/" = {
      device = "rootfs"; fsType = "tmpfs";
      options = [ "mode=0755" ];
      neededForBoot = true;
    };
  } hiddenMounts) roMountOptions;

  # Guest networking: static address on the tap, default route to the host.
  networking = {
    hostName = guestHostName;
    useDHCP = false;
    useNetworkd = true;
    firewall.enable = false;   # nftables in _proxy.nix is our firewall
    # Static resolver, written straight to /etc/resolv.conf via
    # environment.etc below — NOT via `networking.nameservers`. Under
    # `useNetworkd`, nameservers only feed networkd's `DNS=`, which is
    # consumed solely by systemd-resolved; with resolved off (below) they
    # reach nothing and /etc/resolv.conf ends up empty, breaking the
    # proxy's getaddrinfo and thus all egress. Disable resolvconf too so
    # it can't regenerate an empty resolv.conf on top of the static one.
    resolvconf.enable = false;
  };

  # Static resolver for the egress proxy (uid 988), the only thing that
  # resolves names in the guest. A fixed file — no forwarding stub
  # (services.resolved off, below): a stub on 127.0.0.53 would forward
  # arbitrary queries off-box for any local process, reopening the
  # DNS-exfil hole the nftables uid scoping (in _proxy.nix) closes.
  environment.etc."resolv.conf".text = ''
    nameserver 1.1.1.1
    nameserver 9.9.9.9
    options edns0
  '';

  # No in-guest forwarding resolver. The agent's traffic is proxied (so it
  # needs no local name resolution), and the egress proxy resolves upstream
  # hostnames itself via /etc/resolv.conf above. Running resolved would put a
  # stub on loopback that forwards any query off-box — a DNS-exfil channel
  # the firewall can't distinguish from legitimate resolution. See the
  # nftables comment in _proxy.nix.
  services.resolved.enable = false;

  # Disable nscd/nsncd so name resolution happens IN-PROCESS, as the uid of
  # the calling process. This is load-bearing for the egress model: nsncd
  # runs as its own `nscd` user and would perform every getaddrinfo's DNS
  # query under THAT uid — but the nftables linchpin (_proxy.nix) only lets
  # uid 988 (egressproxy) egress, so a centralised resolver under any other
  # uid means *nobody* resolves (the proxy included) and all egress dies.
  # With nscd off, the proxy (uid 988) resolves under its own allowed uid,
  # while the agent (uid 1000) resolving directly is dropped by the firewall
  # — exactly the "only the proxy resolves" intent. The minimal guest has no
  # NSS modules that need the daemon (hosts = files + dns), so clear the
  # module path to satisfy the nscd-required assertion.
  services.nscd.enable = false;
  system.nssModules = lib.mkForce [ ];

  systemd.network = {
    enable = true;
    networks."10-eth" = {
      # cloud-hypervisor names the virtio-net interface ens2 (predictable
      # names), not eth0. Match by MAC instead — unambiguous and survives
      # any future naming-policy change.
      matchConfig.MACAddress = slotMac;
      address = [ "${slotGuestIp}/24" ];
      routes = [{ Gateway = slotGateway; }];
      dns = [ "1.1.1.1" "9.9.9.9" ];
    };
  };

  # The user that runs Claude inside the VM.
  #
  # NO wheel, no sudo. Phase 3c: the agent has no privilege escalation
  # path inside the guest at all. This is load-bearing for the
  # proxy-only secret model — without it the agent could
  # `sudo cat /run/egressproxy/secrets/*` and read every secret the proxy
  # is meant to mediate. The bash flow still has wheel + nopasswd
  # because tinyproxy doesn't isolate secrets anyway; we drop both
  # here together.
  users.users.${guestUser} = {
    isNormalUser = true;
    uid = 1000;
    home = guestHome;
    shell = pkgs.bashInteractive;
    # systemd-journal: lets the agent run `journalctl -u <unit>` for
    # any system service. Read-only, so the agent can't write/erase
    # the journal — only inspect it. Critical for debugging startup-
    # hook failures (the agent IS the user running startup hooks).
    extraGroups = [ "systemd-journal" ];
    # Empty password — VM is ephemeral and the boundary is the VM wall.
    # Used for emergency rescue (an operator with the host pty for the
    # rescue console can log in as the agent user without credentials).
    hashedPassword = "";
  };
  # Explicitly disable sudo (default would still be enabled with no
  # wheel members; this kills the binary entirely so an escalation
  # bug can't be reached via a sudoers misconfig).
  security.sudo.enable = false;

  # ${guestHome}/<configDir> (e.g. ~/.claude, ~/.config/codex) is built
  # per agent by the agent-home-init oneshot below, in one of two shapes
  # (agent.configMode — see policy/contract.ncl):
  #
  #   'symlinks' (claude): a real dir of symlinks. RO things (settings,
  #     statusline, agents, plugins, credentials) point into the RO config
  #     bind; the writable subset (agent.stateDirs/stateFiles, and the
  #     homeStateFiles siblings) points into this agent's namespace under
  #     /var/lib/vm-launcher-state.
  #
  #   'writable' (codex): the dir IS the agent's state namespace (a
  #     symlink to it), with agent.seedFiles copied in from the RO bind.
  #     Needed because codex writes throughout its own home — sqlite DBs
  #     at the root of CODEX_HOME, auth.json refreshed in place, helper
  #     binaries extracted into tmp/ and exec'd. Seeding is a COPY, so a
  #     guest-side credential refresh never reaches the host.
  #
  # One unit for all agents: they share the same ordering constraints
  # (every config bind + the state bind must be up), and a partial
  # success would leave the session half-wired anyway.
  systemd.services.agent-home-init = lib.mkIf (policy.auth == "bind") {
    description =
      "Build each agent's config dir from its RO bind + the RW state dir";
    wantedBy = [ "multi-user.target" ];
    # sshd too, not just the console: when headless, `vm-launcher attach`
    # is the only way in, and landing in a shell before ~/.claude and
    # ~/.config/codex exist is exactly the confusion this ordering
    # prevents on the console path.
    before = [ "vm-launcher-session.service" ]
      ++ lib.optional sshEnabled "sshd.service";
    # Wait for every agent's config mount plus the state mount. systemd
    # escapes '-' as \x2d in unit names.
    requires = (map configMountUnitOf agents)
      ++ lib.optionals (policy.stateDir != "")
           [ "var-lib-vm\\x2dlauncher\\x2dstate.mount" ];
    after = (map configMountUnitOf agents)
      ++ lib.optionals (policy.stateDir != "")
           [ "var-lib-vm\\x2dlauncher\\x2dstate.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      umask 077
    '' + lib.concatMapStrings (a: ''

      # ---- ${a.name} (${a.command}) ----
      config_dir="${agentHomeDir a}"
      ro_bind="${a.configGuest}"
      state_ns="${agentStateNs a}"
      instructions="${a.instructionsFile}"
      staged="${agentStagedInstructions a}"

      # ~/.config/codex and friends: the PARENT has to exist before the
      # dir (or its symlink) can be made.
      #
      # AND it has to belong to the agent. This unit runs as root with
      # umask 077, so a NESTED configDir leaves ~/.config as root-owned
      # 0700 — the agent then cannot traverse into its own config dir
      # ("Permission denied" from codex on CODEX_HOME, while every file
      # inside is perfectly correct). Walk from the parent back up to
      # $HOME handing each level over. A configDir that sits directly in
      # $HOME (.claude) has parent == $HOME, so the loop does nothing.
      parent="$(dirname "$config_dir")"
      mkdir -p "$parent"
      p="$parent"
      while [ "$p" != "${guestHome}" ] && [ "$p" != "/" ]; do
        chown ${guestUser}:users "$p" 2>/dev/null || true
        chmod 0700 "$p" 2>/dev/null || true
        p="$(dirname "$p")"
      done

      ${if a.configMode == "writable" then ''
        ${if policy.stateDir != "" then ''
          # The config dir IS the state namespace. -T so a pre-existing
          # path can never turn this into a link *inside* a directory.
          mkdir -p "$state_ns"
          rm -f "$config_dir"
          ln -sfnT "$state_ns" "$config_dir"
        '' else ''
          # No state bind (ephemeral session): a plain tmpfs dir, wiped
          # with the VM.
          mkdir -p "$config_dir"
        ''}

        # Seed from the RO bind. Overwrites on every boot: the HOST copy
        # is authoritative, and the guest's own writes (a refreshed
        # auth.json) deliberately do not survive into the next session.
        ${lib.concatMapStrings (f: ''
          if [ -f "$ro_bind/${f}" ]; then
            install -m 600 "$ro_bind/${f}" "$config_dir/${f}"
          fi
        '') a.seedFiles}
      '' else ''
        mkdir -p "$config_dir"

        # Symlink every top-level entry from the RO bind into the real
        # dir. Hidden entries too (.credentials.json etc.). The
        # instructions file gets handled specially below — skip it here.
        for src in "$ro_bind"/* "$ro_bind"/.[!.]* "$ro_bind"/..?*; do
          [ -e "$src" ] || continue
          base="$(basename "$src")"
          [ "$base" = "$instructions" ] && continue
          ln -sfn "$src" "$config_dir/$base"
        done

        ${lib.optionalString (policy.stateDir != "") ''
          ${lib.optionalString (a.stateDirs != []) ''
            # Override writable subdirs to point at this agent's state
            # namespace so they persist across VM restarts and the agent
            # can write into them.
            for sub in ${lib.escapeShellArgs a.stateDirs}; do
              mkdir -p "$state_ns/$sub"
              ln -sfn "$state_ns/$sub" "$config_dir/$sub"
            done
          ''}

          ${lib.optionalString (a.stateFiles != []) ''
            # Writable files inside configDir — touch + symlink so the
            # agent can append.
            for f in ${lib.escapeShellArgs a.stateFiles}; do
              [ -e "$state_ns/$f" ] || : > "$state_ns/$f"
              ln -sfn "$state_ns/$f" "$config_dir/$f"
            done
          ''}

          ${lib.optionalString (a.homeStateFiles != []) ''
            # Home-state files (siblings of configDir in $HOME, e.g.
            # ~/.claude.json) — symlinked to the state namespace so login
            # persists across VM restarts. Launcher seeded them on first
            # run from the host's $HOME.
            for f in ${lib.escapeShellArgs a.homeStateFiles}; do
              ln -sfn "$state_ns/$f" "${guestHome}/$f"
            done
          ''}
        ''}

        ${lib.optionalString (agentSyncFiles a != []) ''
          # Sync files (agent.syncFiles): the agent replaces these with
          # write-temp + rename, which would swap a symlink for a plain
          # tmpfs file. So: never link the RO bind's copy in (the guest
          # must not run on the host's credentials), restore the saved
          # copy as a REGULAR file, and let agent-sync-<name>.path copy
          # every later change back into the state namespace.
          for f in ${lib.escapeShellArgs (agentSyncFiles a)}; do
            rm -f "$config_dir/$f"
            ${lib.optionalString (policy.stateDir != "") ''
              if [ -s "$state_ns/$f" ]; then
                install -m 600 "$state_ns/$f" "$config_dir/$f"
              fi
            ''}
          done
        ''}
      ''}

      # Instructions file: a real file (not a symlink) = the host's
      # content (if any) + the VM context the launcher staged for THIS
      # agent. The agent reads it as user-level memory every session.
      out="$config_dir/$instructions"
      rm -f "$out"
      if [ -f "$ro_bind/$instructions" ]; then
        cat "$ro_bind/$instructions" > "$out"
        printf "\n\n---\n\n" >> "$out"
      fi
      if [ -f "$staged" ]; then
        cat "$staged" >> "$out"
      fi

      # Resolve first: under configMode = 'writable the config dir is a
      # SYMLINK into the state bind, and `chown -R` does not traverse a
      # symlink operand (-P is the default), so chowning the link itself
      # would leave the actual tree untouched.
      target="$(readlink -f "$config_dir" 2>/dev/null || echo "$config_dir")"
      chown -h ${guestUser}:users "$config_dir" 2>/dev/null || true
      chown -R ${guestUser}:users "$target" ${lib.concatMapStringsSep " " (f: "${guestHome}/${f}") a.homeStateFiles} 2>/dev/null || true
    '') agents;
  };

  # agent.syncFiles write-back: agent-sync.path watches every agent's
  # sync files and triggers agent-sync.service, which copies each one
  # into its agent's state namespace (tmp + rename, so a crash mid-copy
  # never leaves a torn credentials file there). A file the agent deleted
  # (a logout) truncates the saved copy — agent-home-init skips empty
  # ones. Started after agent-home-init so the boot-time copy-in isn't
  # echoed back (its `rm` of the RO link would otherwise truncate the
  # saved copy), and before the startup hooks / session so no agent
  # write is missed.
  #
  # DefaultDependencies = false: a .path unit is otherwise ordered
  # Before=paths.target (< basic.target), while agent-home-init, a plain
  # service, runs after basic.target. After=agent-home-init on top of
  # that is an ordering cycle, and systemd breaks it by DELETING
  # agent-home-init's start job — no ~/.claude, no startup hooks.
  systemd.paths.agent-sync = lib.mkIf (syncAgents != []) {
    description = "Watch the agents' syncFiles for changes";
    unitConfig.DefaultDependencies = false;
    wantedBy = [ "multi-user.target" ];
    requires = [ "agent-home-init.service" ];
    after = [ "agent-home-init.service" ];
    conflicts = [ "shutdown.target" ];
    before = [ "vm-launcher-session.service" "vm-launcher-startup-hooks.service"
               "shutdown.target" ]
      ++ lib.optional sshEnabled "sshd.service";
    pathConfig.PathChanged = lib.concatMap (a:
      map (f: "${agentHomeDir a}/${f}") (agentSyncFiles a)) syncAgents;
  };

  systemd.services.agent-sync = lib.mkIf (syncAgents != []) {
    description = "Copy the agents' syncFiles into the state dir";
    serviceConfig = {
      Type = "oneshot";
      User = guestUser;
      Group = "users";
      UMask = "0077";
    };
    script = ''
      set -u
      sync() {
        if [ -f "$1" ]; then
          cp "$1" "$2.sync-tmp" && mv -f "$2.sync-tmp" "$2"
        else
          : > "$2"
        fi
      }
    '' + lib.concatMapStrings (a: lib.concatMapStrings (f: ''
      sync ${lib.escapeShellArg "${agentHomeDir a}/${f}"} ${lib.escapeShellArg "${agentStateNs a}/${f}"}
    '') (agentSyncFiles a)) syncAgents;
  };

  # Policy-declared startup hooks. Run AFTER home-init (so ~/<configDir>
  # is populated and the agent's HOME makes sense) and BEFORE the
  # interactive shell, as the agent user in /work. Stdout + stderr
  # from every command land in a single log file so you can `cat` it
  # later from inside the VM or — for bind-auth — from the host's
  # state dir (the log lives on the bridged RW state share).
  #
  # Per-command onFailure semantics:
  #   "warn"  (default): log + continue. The interactive shell still
  #                      starts. Best for debugging — a broken
  #                      provisioning step shouldn't lock the user out.
  #   "block":          exit non-zero, which fails this unit, which
  #                      blocks vm-launcher-session.service. Strict
  #                      precondition path.
  systemd.services.vm-launcher-startup-hooks =
    lib.mkIf (policy.startup.commands != []) (
      let
        # Log file resolution is hoisted to `startupLogFile` (top-level
        # let) so the login MOTD points at the very same path this unit
        # writes. Aim for the persistent path when possible so
        # post-mortems work after a reboot.
        logFile = startupLogFile;
        total = builtins.length policy.startup.commands;
        # Render one command-iteration as a shell block. The
        # ${entry.command} interp is at Nix-eval time, substitutes
        # the user's literal command bytes into the script;
        # bash interprets them normally (shell vars, pipes, etc.
        # all work).
        renderCmd = i: entry:
          let
            idx = "${toString (i + 1)}/${toString total}";
            blockOnFail = entry.onFailure == "block";
            # escapeShellArg gives a properly single-quoted literal,
            # safe to printf as data without re-evaluation. Used so
            # the log line shows the command verbatim regardless of
            # quoting/specials inside it.
            cmdQuoted = lib.escapeShellArg entry.command;
          in ''
            {
              printf '\n--- [${idx}] command: %s\n' ${cmdQuoted}
              ( ${entry.command} )
              rc=$?
              if [ "$rc" -eq 0 ]; then
                printf '[${idx}] OK\n'
              else
                printf '[${idx}] FAIL rc=%d\n' "$rc"
                ${if blockOnFail then ''
                  printf '[${idx}] onFailure=block — aborting startup\n'
                  exit "$rc"
                '' else ''
                  printf '[${idx}] onFailure=warn — continuing\n'
                ''}
              fi
            } >> "$log" 2>&1
          '';
      in
      {
        description = "Run policy.startup.commands as the agent user";
        wantedBy = [ "multi-user.target" ];
        # Same reasoning as agent-home-init: with ssh as the way in,
        # provisioning must finish before a shell can be opened.
        before = [ "vm-launcher-session.service" ]
          ++ lib.optional sshEnabled "sshd.service";
        # Requires:
        # - agent-home-init: ~/<configDir> must be populated before the
        #   commands try to use it.
        # - egressproxy-secret-bootstrap: the tmpfs shadow over
        #   /etc/vm-launcher/proxy-secrets/ must be in place before
        #   we run anything as the agent — otherwise a startup
        #   command could `cat /etc/vm-launcher/proxy-secrets/*` and
        #   exfiltrate proxy-scoped secrets.
        # - vm-cabundle: /run/vm-ca-bundle.crt (the file
        #   SSL_CERT_FILE / CURL_CA_BUNDLE / REQUESTS_CA_BUNDLE point
        #   at in this unit's environment) must exist before any
        #   command runs `curl https://…` — otherwise TLS silently
        #   falls back to the empty bundle, every cert verifies as
        #   unknown.
        # agent-home-init only exists when auth = "bind" (it
        # populates ~/<configDir> from the RO config share into a RW state
        # dir; ephemeral auth has nothing to bind). Listing it
        # unconditionally in `requires` causes systemd to skip
        # vm-launcher-startup-hooks with "unit not loaded" when auth =
        # "ephemeral", which silently drops the policy's startup
        # commands. Gate by auth.
        # vm-egress-proxy.service is required + after-ordered so the
        # proxy is actually accepting connections on :3128 before any
        # startup command runs. The proxy's ExecStartPost probes its
        # own bind() — once the unit reaches "active", connections
        # succeed. Without this dep, startup commands that touch the
        # network (curl, uv sync, anything HTTPS-bound) race the
        # proxy's listen() and fail with "Could not connect to server".
        # The egress-proxy trio (bootstrap + cabundle + proxy) only exists
        # when fenced — depending on it in noblock/airgap would wedge this
        # unit on a never-started service. Gate it.
        requires =
          (lib.optional (policy.auth == "bind") "agent-home-init.service")
          ++ lib.optionals fenced [
            "egressproxy-secret-bootstrap.service"
            "vm-cabundle.service"
            "vm-egress-proxy.service"
          ];
        after =
          (lib.optional (policy.auth == "bind") "agent-home-init.service")
          ++ lib.optionals fenced [
            "egressproxy-secret-bootstrap.service"
            "vm-cabundle.service"
            "vm-egress-proxy.service"
          ];
        environment = { HOME = guestHome; } // proxyEnv // caEnv;
        # Make the boot-phase manifest reachable from startup commands.
        #
        # NixOS's systemd default PATH for a unit only includes the
        # minimal essentials (coreutils, findutils, grep, sed, systemd)
        # — it does NOT include /run/current-system/sw/bin where
        # environment.systemPackages lands. Without an explicit `path`,
        # a startup command of `curl ...` errors with "curl: command
        # not found" even when "curl" is in policy.tools, because the
        # unit doesn't pass through /etc/profile the way the agent's
        # login shell does.
        #
        # Tight design choice: `path = startupToolPkgs`, NOT
        # /run/current-system/sw/bin. Pointing at the system profile
        # would expose agent-run, the julia sysimage wrapper,
        # rWithPkgs, AND every package the NixOS base profile drops
        # in (bash, gawk, less, …). The agent's interactive login
        # shell already sees that broader set (via /etc/profile); the
        # boot phase shouldn't inherit it implicitly.
        #
        # startupToolPkgs resolves policy.startup.tools (the explicit
        # boot manifest in the contract) and falls back to policy.tools
        # when empty — so existing policies keep working unchanged
        # while users who want a tighter boot can set startup.tools
        # explicitly to a subset.
        #
        # `path` APPENDS to PATH, so the essentials above are
        # preserved.
        path = startupToolPkgs;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = guestUser;
          Group = "users";
          WorkingDirectory = "/work";
        };
        script = ''
          # set +e: per-command failures are handled explicitly inside
          # each renderCmd block; the warn path must NOT terminate the
          # script. Block-on-fail commands call `exit "$rc"` themselves.
          set +e

          # policy.env exports get sourced here so user commands see
          # them (the unit is NOT a login shell, so loginShellInit
          # doesn't apply — without this source step, ${"$"}TEST_FOO etc.
          # would be empty inside the user's commands). File is staged
          # by Stage.env_vars on the host; absent + harmless when
          # policy.env is empty.
          [ -f /etc/vm-launcher/env-vars ] && . /etc/vm-launcher/env-vars

          # escapeShellArg quotes the value for safe shell use even
          # if logFile contains apostrophes / spaces / special chars
          # an operator might paste in by accident.
          log=${lib.escapeShellArg logFile}
          ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$log")"
          ${pkgs.coreutils}/bin/touch "$log"

          printf '\n=== vm-launcher-startup-hooks @ %s ===\n' \
            "$(${pkgs.coreutils}/bin/date -u +%FT%TZ)" >> "$log"

          ${lib.concatStringsSep "\n"
            (lib.imap0 renderCmd policy.startup.commands)}

          printf '=== vm-launcher-startup-hooks done ===\n' >> "$log"
        '';
      });

  # A tiny wrapper so the user can run the agent with the policy's flags
  # baked in without re-typing them. Named `agent-run` to make the
  # behavior explicit at the call site. The bare `${agent.command}` binary
  # is also on PATH (via policy.tools) for the raw, prompts-on path.
  #
  # NOTE: site-specific toolchain wiring (the Julia sysimage exposure that
  # reacts to `julia ∈ policy.tools` — closure pull, /var/lib symlink,
  # JULIA_DEPOT_PATH/JULIA_PROJECT) has moved OUT of this base and into a
  # site-side module layered through `mkGuest { extraModules = [...]; }`.
  # It consumes the `policy` module arg (above) and stock NixOS options.
  # The base must stay buildable against stock nixpkgs — do NOT reference
  # non-stock pkgs here.
  environment.systemPackages = toolPkgs
    # One `<name>-run` wrapper per declared agent, plus `agent-run` as the
    # alias for the session default. A single-agent VM therefore keeps
    # both `agent-run` and (new) `claude-run`.
    ++ map (a: pkgs.writeShellScriptBin (agentRunName a) ''
      exec ${a.command} ${lib.escapeShellArgs a.flags} "$@"
    '') agents
    ++ [
    (pkgs.writeShellScriptBin "agent-run" ''
      exec ${agent.command} ${lib.escapeShellArgs agent.flags} "$@"
    '')
    # Egress posture indicator for the statusline (☁ ◉/○/✈/⚠). On the guest
    # PATH so the (host-bound) statusline resolves it here; a no-op off-VM.
    (import ./vm-egress-status.nix { inherit pkgs; })
  ] ++ lib.optionals (multiplexed || sshEnabled) [
    # Shipped whenever there is a way in: an ssh session that drops takes
    # its agent with it, so `tmux` by hand is the persistence story even
    # when multiplex = 'none.
    pkgs.tmux
    vmAgentsScript
    # Attach-or-create the session. Also the recovery path after a
    # detach: the login shell is still sitting there, and `vm-attach`
    # gets you back without knowing the session name.
    (pkgs.writeShellScriptBin "vm-attach" ''
      exec ${vmSessionScript}/bin/vm-session
    '')
    vmSessionScript
  ] ++ lib.optionals (policy.r.packages != []) [
    rWithPkgs
  ];

  # MOTD shown on the user-facing console at login (hvc0 or ttyS0 per
  # policy.console). Laid out as gutter-barred blocks (START / NETWORK /
  # CONFIG / PROJECT); policy.loginMessage, when non-empty, becomes the
  # PROJECT block so project reminders aren't tangled with the boilerplate.
  users.motd =
    let
      a = ansi;
      flagsStr = lib.concatStringsSep " " agent.flags;
      # The staged etc dir is bridged in from the host at this path; the
      # `current-session-<slot>` symlink is the operator-facing handle.
      hostJson = "/run/vm-launcher/current-session-${slot}/etc/microvm-loaded.json";
      start =
        [ ""
          (motdHead "┌" a.bcyan "vm-launcher")
          "${gbar a.bcyan}  ${a.dim}you are inside the microVM${a.reset}"
          ""
          (motdHead "┌" a.cyan "START")
        ]
        # One line per declared agent: what starts it, and — for the
        # session default — that `agent-run` is the same thing. Shared
        # with `vm-agents`, which reprints them inside tmux.
        ++ agentStartLines
        ++ [ "${gbar a.cyan}  ${a.cyan}❯${a.reset} ${a.bold}${agent.command}${a.reset}   ${a.gray}# the raw binary (permission prompts on)${a.reset}" ]
        ++ lib.optionals multiplexed
             ([ "" (motdHead "┌" a.cyan "WINDOWS") ]
              ++ agentWindowLines
              ++ [ "${gbar a.cyan}  ${a.bold}vm-agents${a.reset}${a.gray}  reprint this list inside tmux${a.reset}" ]);
      network =
        if fenced then
          [ ""
            (motdHead "┌" a.green "NETWORK")
            "${gbar a.green}  ${a.green}🛡️ fenced${a.reset}  ${a.dim}— egress via the in-guest MITM proxy, allowlist only${a.reset}"
            "${gbar a.green}  ${a.green}❯${a.reset} cat /etc/vm-launcher/egress-hosts   ${a.gray}# the allowlist${a.reset}"
            "${gbar a.green}  ${a.green}❯${a.reset} ls /work   ${a.gray}# the project share${a.reset}"
            "${gbar a.green}  ${a.green}❯${a.reset} systemctl status vm-egress-proxy   ${a.gray}# the proxy${a.reset}"
            "${gbar a.green}  ${a.green}❯${a.reset} curl -v --max-time 5 https://api.anthropic.com/   ${a.gray}# smoke-test the proxy${a.reset}"
          ]
        else if egressMode == "unfenced" || egressMode == "noblock" then
          [ ""
            (motdHead "┌" a.red "NETWORK")
            "${gbar a.red}  ${a.bred}🌐 UNFENCED${a.reset}  ${a.red}(--egress noblock)${a.reset}"
            "${gbar a.red}  ${a.byellow}No proxy, no allowlist, no MITM — direct to the whole internet. Operator-enabled.${a.reset}"
            "${gbar a.red}  ${a.red}❯${a.reset} ls /work   ${a.gray}# the project share${a.reset}"
            "${gbar a.red}  ${a.red}❯${a.reset} curl -v --max-time 5 https://example.com/   ${a.gray}# direct (no proxy)${a.reset}"
          ]
        else
          [ ""
            (motdHead "┌" a.gray "NETWORK")
            "${gbar a.gray}  ${a.gray}⛔ airgap${a.reset}  ${a.dim}(--egress block) — no outbound network${a.reset}"
            "${gbar a.gray}  ${a.gray}❯${a.reset} ls /work   ${a.gray}# the project share${a.reset}"
          ];
      config =
        [ ""
          (motdHead "┌" a.cyan "CONFIG")
          "${gbar a.cyan}  ${a.dim}this session's fully-resolved options (reflects --egress etc.)${a.reset}"
          "${gbar a.cyan}  ${a.dim}in guest${a.reset}  ${a.cyan}cat /etc/vm-launcher/microvm-loaded.json${a.reset}"
          "${gbar a.cyan}  ${a.dim}on host ${a.reset}  ${a.cyan}cat ${hostJson}${a.reset}"
        ];
      # STARTUP: only rendered when the policy defines run-on-boot hooks.
      # Tells whoever lands in the shell that provisioning commands ran
      # before them (so a half-provisioned VM isn't a silent mystery) and
      # points at the collected log + the journal for the actual output.
      startupTotal = builtins.length policy.startup.commands;
      startup = lib.optionals (policy.startup.commands != [])
        ([ ""
           (motdHead "┌" a.yellow "STARTUP")
           "${gbar a.yellow}  ${a.dim}these commands ran at boot, before this shell (output → the log below):${a.reset}"
         ]
         ++ lib.imap0
              (i: entry:
                "${gbar a.yellow}  ${a.yellow}[${toString (i + 1)}/${toString startupTotal}]${a.reset} ${a.bold}${entry.command}${a.reset}")
              policy.startup.commands
         ++ [ "${gbar a.yellow}  ${a.dim}log    ${a.reset}  ${a.yellow}cat ${startupLogFile}${a.reset}"
              "${gbar a.yellow}  ${a.dim}journal${a.reset}  ${a.yellow}journalctl -u vm-launcher-startup-hooks${a.reset}"
            ]);
      project = lib.optionals (policy.loginMessage != "")
        [ ""
          (motdHead "┌" a.gray "PROJECT")
          (gutterLines a.gray policy.loginMessage)
        ];
      # How this VM dies — the single most consequential line in the
      # MOTD, and it depends on how you got here. It used to say
      # "Exit the shell to shut the VM down" unconditionally, which is
      # false for a detached VM (no console session runs at all) and
      # false again over ssh, where NixOS's sshd prints this same motd
      # and Ctrl-D closes one shell. The ssh case is corrected at the
      # bottom of loginShellInit, which runs after this is printed.
      footer =
        [ (motdFoot a.gray) ]
        ++ (if headless then
              [ "${a.dim}This VM is ${a.reset}${a.bold}detached${a.reset}${a.dim} — nothing in here powers it off.${a.reset}"
                "${a.dim}Leaving a shell just leaves the shell. Stop it from the host:${a.reset} ${a.bold}vm-launcher down${a.reset}"
              ]
            else
              [ "${a.byellow}▲${a.reset} ${a.dim}Ctrl-D or `logout` at ${a.reset}${a.bold}this console${a.reset}${a.dim} powers the VM OFF — everything running in it dies.${a.reset}"
              ]);
    in lib.concatStringsSep "\n" (start ++ network ++ config ++ startup ++ project ++ footer) + "\n";

  # Drop the user into a bash login shell on the user-facing console
  # (hvc0 or ttyS0 per policy.console). `agent-run` runs the agent with
  # the right flags when they're ready.
  systemd.services.vm-launcher-session = {
    # Headless (booted with --detach): nothing is listening on the other
    # end of the console, so no login session — and, critically, no
    # ExecStopPost=poweroff that a stray shell exit could trigger. The VM
    # then lives until `vm-launcher down`.
    enable = !headless;
    description = "vm-launcher interactive shell on /dev/${consoleTty}";
    # Wait for startup-hooks IF the policy has any. lib.optional appends
    # the unit name only when commands != [] — vm-launcher-session.service
    # references a non-existent unit name otherwise and systemd warns.
    after = [
      "network-online.target"
    ] ++ lib.optional fenced "vm-egress-proxy.service"
      ++ lib.optional (policy.auth == "bind") "agent-home-init.service"
      ++ lib.optional (policy.startup.commands != [])
           "vm-launcher-startup-hooks.service";
    wants = [
      "network-online.target"
    ] ++ lib.optional fenced "vm-egress-proxy.service"
      ++ lib.optional (policy.auth == "bind") "agent-home-init.service"
      ++ lib.optional (policy.startup.commands != [])
           "vm-launcher-startup-hooks.service";
    wantedBy = [ "multi-user.target" ];
    # environment.sessionVariables only fires for interactive shells via
    # /etc/profile.d/, but bash --login reads those — keep the unit-level
    # copy for processes that don't source profile (e.g. ssh exec).
    # proxyEnv is empty when unfenced.
    environment = {
      # Make ~/<configDir> resolvable for the config bind case.
      HOME = guestHome;
    } // proxyEnv;
    serviceConfig = {
      Type = "simple";
      # No User= — agetty does setuid to the agent user via --autologin.
      # Running the unit as root lets ExecStopPost call systemctl poweroff
      # without polkit drama.
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "tty";
      TTYPath = "/dev/${consoleTty}";
      TTYReset = true;
      TTYVHangup = true;
      # agetty handles PAM session setup, sets WorkingDirectory to the user's
      # $HOME, and spawns /bin/login (autologin skips the password). TERM
      # is xterm-256color so paste/escape sequences from ghostty+tmux on
      # the host get interpreted correctly instead of being typed literally.
      ExecStart = "${pkgs.util-linux}/sbin/agetty --autologin ${guestUser} --noclear ${consoleTty} xterm-256color";
      # `+` prefix => run as root regardless of any User=. Even though we
      # don't set User=, future-proofs against someone adding it.
      ExecStopPost = "+${pkgs.systemd}/bin/systemctl poweroff";
      Restart = "no";
    };
  };

  # ── sshd: the attach path ──────────────────────────────────────────
  #
  # Bound to the slot's guest address ONLY, which lives on a host-only tap
  # network — unroutable from anywhere else. The egress fence is
  # untouched: it filters the nftables OUTPUT chain, while INPUT is
  # already policy accept, so nothing here widens what the guest reaches.
  services.openssh = lib.mkIf sshEnabled {
    enable = true;
    listenAddresses = [ { addr = slotGuestIp; port = 22; } ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
    # No guest-generated host keys: the root is tmpfs, so they would be
    # new on every boot — every attach would face a changed-key warning,
    # or verification would have to be turned off. The launcher generates
    # one per session and stages it; vm-sshd-keys installs it below.
    hostKeys = [ ];
    # mkForce, NOT extraConfig: nixpkgs emits its own AuthorizedKeysFile
    # (including %h/.ssh/authorized_keys) at mkOrder 0, and sshd honours
    # the FIRST occurrence — so the same line in extraConfig is inert and
    # the home-directory path stays live. The launcher-staged key is the
    # only one that should open this VM.
    authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
    extraConfig = ''
      HostKey /etc/ssh/vm_host_ed25519_key
    '';
  };

  # Install the staged key material with the ownership sshd insists on.
  # The staged copies arrive over virtiofs owned by the launcher's uid,
  # and sshd refuses a host key it considers loosely held — so copy
  # rather than symlink, and chown to root.
  systemd.services.vm-sshd-keys = lib.mkIf sshEnabled {
    description = "Install launcher-staged ssh host key + authorized key";
    wantedBy = [ "multi-user.target" ];
    before = [ "sshd.service" ];
    requires = [ "etc-vm\\x2dlauncher.mount" ];
    after = [ "etc-vm\\x2dlauncher.mount" ];
    unitConfig.ConditionPathExists = "/etc/vm-launcher/ssh/host_ed25519_key";
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      set -eu
      install -D -m 0600 -o root -g root \
        /etc/vm-launcher/ssh/host_ed25519_key /etc/ssh/vm_host_ed25519_key
      install -D -m 0644 -o root -g root \
        /etc/vm-launcher/ssh/authorized_key.pub \
        /etc/ssh/authorized_keys.d/${guestUser}
    '';
  };

  # Git identity, system-wide. Resolved by the launcher from policy.git
  # (default = host's identity + "vm-launcher" markers).
  #
  # If git.allowedGithubOrgs is set, also ship insteadOf rules that
  # rewrite github.com URLs outside the allowlist to blocked.invalid.
  # git applies the LONGEST matching `insteadOf` value, so:
  #   - `https://github.com/LouLouLibs/x` matches the identity rule
  #     (longer prefix `https://github.com/LouLouLibs/`) and stays put
  #   - `https://github.com/anyone/y`     matches the catchall (shorter
  #     prefix `https://github.com/`) and becomes
  #     `https://blocked.invalid/anyone/y` => clone fails
  # Entries can be an org (`LouLouLibs` — whole org allowed) or an
  # org/repo pair (`alice/myproject` — only that repo). For the
  # repo form we emit a second rule against the `.git` URL because
  # `https://github.com/foo/bar.git` does not have `https://github.com/foo/bar/`
  # as a prefix (`.` ≠ `/`), so a single trailing-slash rule would miss
  # the canonical clone URL.
  # Soft (bypassable via `git -c url...= ...`); the hard layer is the
  # egress allowlist + your GH_TOKEN scope.
  environment.etc."gitconfig".text = ''
    [user]
        name = ${policy.git.name}
        email = ${policy.git.email}
    [safe]
        directory = /work
  '' + lib.optionalString (policy.git.allowedGithubOrgs != []) (''
    [url "https://blocked.invalid/"]
        insteadOf = https://github.com/
  '' + lib.concatMapStringsSep "" (entry:
    let isRepo = lib.hasInfix "/" entry;
    in ''
    [url "https://github.com/${entry}/"]
        insteadOf = https://github.com/${entry}/
  '' + lib.optionalString isRepo ''
    [url "https://github.com/${entry}.git"]
        insteadOf = https://github.com/${entry}.git
  '') policy.git.allowedGithubOrgs);

  documentation.enable = false;
  # sshd is defined above, gated on session.ssh: off unless the
  # policy asks for the attach path. It used to be unconditionally
  # disabled here — the guest had exactly one way in, the console.

  # vm-launcher-session owns the user-facing console (/dev/${consoleTty}).
  # Stop the auto-enabled gettys for both the 16550 UART and the
  # virtio-console — systemd instantiates serial-getty@<dev>.service for
  # every device named in `console=` on the kernel cmdline, so in hvc0
  # mode both would otherwise race with our session unit for the tty.
  systemd.services."serial-getty@ttyS0".enable = false;
  systemd.services."serial-getty@hvc0".enable = false;
  # No man-page index, no VT in this guest, no need to rebuild systemd's
  # update-done state on every boot, no need for the message catalog refresh
  # at boot-time. Each shaves 30-100ms.
  systemd.services.systemd-journal-catalog-update.enable = false;
  systemd.services.systemd-update-done.enable = false;
  systemd.services.systemd-vconsole-setup.enable = false;

  # System-wide readline config — bracketed paste means a paste from the host
  # terminal is one atomic input event, not a series of keystrokes (which
  # would otherwise execute commands as soon as they hit \n inside the
  # pasted text).
  environment.etc."inputrc".text = ''
    set enable-bracketed-paste on
    set show-all-if-ambiguous on
    set completion-ignore-case on
    "\e[A": history-search-backward
    "\e[B": history-search-forward
  '';

  # Drop the login shell into /work, not $HOME. Only on the first interactive
  # shell of the session (when PWD still equals $HOME), so subshells the user
  # spawns later from anywhere stay where they are.
  programs.bash.interactiveShellInit = ''
    if [ "$PWD" = "$HOME" ] && [ -d /work ]; then
      cd /work
    fi
  '';

  # Root is LOCKED (no password login). An empty root password plus the
  # always-present `su` setuid wrapper would let the agent — who runs as the
  # unprivileged guest user — `su` to root and `cat /run/egressproxy/secrets/*`,
  # defeating the entire no-wheel/no-sudo proxy-secret model above. Rescue does
  # not need root here: an operator on the host pty logs in as the agent user
  # (empty password, set in its block above) for inspection, and true root
  # rescue is the hypervisor's single-user boot — a path the agent can't reach.
  users.users.root.hashedPassword = "!";

  # nix-ld so upstream dynamic binaries run inside the guest, as a NixOS
  # host typically enables it too. Without this, uv's
  # downloaded cpython-*-linux-x86_64-gnu (python-build-standalone) and
  # juliaup's Julia fail at the dynamic loader:
  #   Could not start dynamically linked executable: ...
  #   NixOS cannot run dynamically linked executables intended for
  #   generic linux environments out of the box.
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc.lib  # libstdc++ / libgcc_s
    zlib
    openssl
    curl
  ];

  system.stateVersion = "26.05";
}
