(** Typed view of the Nickel policy that drives a vm-launcher session.

    Parsed from the Nickel-exported JSON the launcher reads. The
    source-of-truth schema lives in
    [policy/contract.ncl]; this is the OCaml mirror. *)

type rw_or_ro = Rw | Ro

type work = {
  default : rw_or_ro;
  read_only : string list;
  hidden : string list;
}

(** Effective network posture. NOT a contract field — launcher-injected
    (the operator-only [--egress] CLI flag), serialized into policy.json,
    read by the guest. A project's microvm.ncl can only reach [Airgap]
    (via [egress.none]) or stay [Allowlist]; only the CLI flag reaches
    [Unrestricted], so an untrusted policy can never lift the fence. *)
type egress_mode = Allowlist | Unrestricted | Airgap

type egress = {
  hosts : string list;
  none : bool;
  mode : egress_mode;
}

type auth = Bind | Ephemeral

type resources = {
  vcpu : int;
  mem_mb : int;
}

(** Which character device backs the user-facing console inside the
    guest. The guest's _guest.nix branches on this value to set
    [microvm.cloud-hypervisor.extraArgs], [boot.kernelParams], and the
    agetty TTYPath.

    - [Console_hvc0] (default): virtio-console wired to the launcher's
      stdio. Vring-batched, so TUI redraws (e.g. claude's full-screen
      panel) feel native. ttyS0 stays alive as a host pty for kernel
      logs / panic dumps.
    - [Console_ttys0]: emulated 16550 UART wired to the launcher's
      stdio. Byte-at-a-time PIO → slow TUI redraws. For debugging
      only — when you need the legacy serial port directly or as a
      fallback if virtio-console misbehaves. *)
type console = Console_hvc0 | Console_ttys0

(** Where a secret is loaded into.

    - [Agent_env]: legacy/v1 behavior — exported as an env var in the
      agent's login shell. Visible to [env], [printenv], etc.
    - [Proxy_only]: loaded into the egress proxy's address space only.
      The agent's shell never holds the value; the proxy injects it
      into outbound requests per [proxy_auth]. *)
type secret_scope = Agent_env | Proxy_only

type secret = {
  env : string;
  source : string;
  scope : secret_scope;
}

(** A per-host header to inject into outbound HTTPS requests. Read by
    the proxy at startup; refers by [env] to a [secret] with
    [scope = Proxy_only]. *)
type proxy_auth_rule = {
  host : string;
  header : string;        (* e.g. "Authorization" *)
  value_template : string;  (* e.g. "Bearer ${OPENAI_API_KEY}" *)
}

(** Arbitrary host path bound into the guest at an arbitrary mountpoint.
    Generic escape hatch for cases [policy.inputs] doesn't cover (RW,
    custom mount path, or RO at a non-[/inputs/<basename>] location).

    [source]: absolute host path (or [~/...] which the launcher expands).
    [mount_point]: absolute guest path. Every PARENT of this path must
    exist at boot — safe parents are [/mnt], [/srv], [/opt], [/var/lib],
    [/home/<user>]. Paths constructed at runtime by [agent-home-init]
    (e.g. [/home/<user>/.claude/projects/-work/...]) will fail
    [local-fs.target] and block boot.

    [read_only]: virtiofsd is started with [--readonly] (kernel-level RO),
    not just mount-flag RO — agent inside the guest cannot remount RW.

    Security model is always [passthrough] (host uid maps directly to
    guest uid 1000, the agent user). *)
type share = {
  source : string;
  mount_point : string;
  read_only : bool;
}

type git_identity = {
  name : string option;
  email : string option;
  allowed_github_orgs : string list;
}

type julia = { env : string }

type r = { packages : string list }

(** Per-guest identity. Both fields are [None] when the policy left
    them empty in the contract; [Resolver.resolve_guest] fills them
    with derived defaults at launch:
    - [hostname]: RFC-1123-sanitized basename of [project] (lowercased,
      non-alphanumerics → hyphens, collapsed, fallback ["vmlauncher"]).
    - [username]: host [$USER] with a [-vm] suffix (fallback
      ["vmlauncher"]). *)
type guest = {
  hostname : string option;
  username : string option;
}

(** How a single [startup.commands] entry handles a non-zero exit.

    - [On_failure_warn] (default): log the failure to [logFile] and
      keep going with the next command. The interactive shell still
      starts. Best for debugging — a broken provisioning step
      shouldn't lock you out of the VM.
    - [On_failure_block]: the systemd unit fails, which fails
      [vm-launcher-session.service] and the VM exits. Use for strict
      preconditions (e.g. "data file must exist before login"). *)
type on_failure = On_failure_warn | On_failure_block

type startup_command = {
  command : string;
  on_failure : on_failure;
}

(** Run-on-boot hooks. Executed by a systemd oneshot inside the guest
    after the home-init oneshot, before the interactive shell. As the
    [claude] user, in [/work]. All stdout + stderr is appended to
    [log_file]. *)
type startup = {
  commands : startup_command list;
  tools : string list;
      (** Tools scoped to the startup-hooks systemd unit's PATH,
          independent of the broader [policy.tools] that gates the
          agent's interactive shell. Empty list (the default in fresh
          policies; also the parser's forward-compat default for
          fixtures predating this field) is the documented sentinel
          for "inherit [policy.tools]" — the substitution happens at
          the guest-side [_guest.nix]. Non-empty list = exactly those
          nixpkgs attrs in the startup-hooks PATH; nothing else. Use
          to tighten the boot phase when the agent's manifest is
          broader than what provisioning needs. *)
  log_file : string option;
      (** [None] (or empty in JSON) lets the guest unit pick a default:
          [/var/lib/vm-launcher-state/startup.log] for bind-auth +
          stateDir != "" (persistent across reboots), otherwise
          [/tmp/vm-launcher-startup.log]. *)
}

(** Neutral agent profile. The contract carries a [preset] (['claude] |
    ['codex]) that expands — in Nickel — into the concrete defaults
    below; the launcher reads them as plain data so the base guest is
    wired off these fields and carries no literal agent name.

    - [command]: binary the [agent-run] wrapper execs (delivered on PATH
      via [tools]).
    - [flags]: flags baked into the wrapper (was [claudeFlags]).
    - [instructions_file]: filename of the rendered session context (e.g.
      [CLAUDE.md]).
    - [instructions]: per-project guidance appended to it (was
      [claudeInstructions]).
    - [name]: identity within the session — names the [<name>-run]
      wrapper, the agent's state namespace, and its tmux window. Unique
      across [agent] + [extra_agents].
    - [package]: nixpkgs attr delivering the binary; the guest adds it to
      the closure for every declared agent.
    - [config_dir]: path relative to [$HOME] (e.g. [.claude],
      [.config/codex]).
    - [config_guest]: RO config-bind mountpoint in the guest (e.g.
      [/var/lib/claude]).
    - [config_env]: env var pointing the agent at its guest-side config
      dir ([""] = none). codex hardcodes [~/.codex] without [CODEX_HOME].
    - [config_mode] / [seed_files]: how the guest builds the config dir —
      see {!config_mode}.
    - [task_dir]: RW task-tracker nest under [config_guest] ([""] = none).
    - [state_dirs] / [state_files] / [home_state_files]: under
      [Symlinks], the writable layout the home-init service redirects to
      the state bind. Unused under [Writable]. *)

(** How the guest builds [~/<config_dir>].

    - [Symlinks] (claude): a real dir of links into the RO config bind,
      with [state_dirs]/[state_files] redirected to the RW state dir —
      the host's settings stay authoritative and the writable surface is
      enumerated.
    - [Writable] (codex): the dir IS the agent's RW state namespace, with
      [seed_files] copied in from the RO bind at boot. Required when the
      agent writes throughout its own home — codex keeps sqlite DBs at
      the root of [CODEX_HOME], refreshes [auth.json] in place, and
      extracts+execs helper binaries into [CODEX_HOME/tmp]. *)
type config_mode = Symlinks | Writable

type agent = {
  preset : string;
  name : string;
  package : string;
  command : string;
  flags : string list;
  instructions_file : string;
  instructions : string option;
  config_dir : string;
  config_guest : string;
  config_env : string;
  config_mode : config_mode;
  seed_files : string list;
  task_dir : string;
  state_dirs : string list;
  state_files : string list;
  home_state_files : string list;
  sync_files : string list;
  config_host : string option;
      (** Host config dir ([$HOME/<config_dir>]), resolved by the
          launcher from [$HOME] when [auth = Bind] ([None] otherwise).
          Launcher-injected, not a contract field — keeps the guest's
          config bind from hardcoding one user's home. Formerly
          [auth_home]. *)
}

(** Terminal multiplexer on the guest console. The VM has one console and
    one login shell, so without a multiplexer only one agent can be
    interactive at a time. [Multiplex_auto] resolves to tmux only when
    more than one agent is declared, leaving single-agent VMs unchanged. *)
type multiplex = Multiplex_auto | Multiplex_tmux | Multiplex_none

type session = {
  multiplex : multiplex;
  ssh : bool;
      (** Run sshd in the guest, bound to the slot's guest address, so
          [vm-launcher attach] can open independent shells. Does not
          affect the egress fence: the guest's nftables [input] chain is
          already accept, and the tap network is host-only. *)
  headless : bool;
      (** Launcher-injected (not a contract field): the VM was booted
          detached, so the guest skips the console login session. *)
}

type t = {
  project : string;
  work : work;
  inputs : string list;
  egress : egress;
  auth : auth;
  agent : agent;
      (** The session's DEFAULT agent — what [agent-run] resolves to. *)
  extra_agents : agent list;
      (** Additional agents sharing the same VM, each with its own run
          wrapper, config bind, instructions file and state namespace. *)
  session : session;
  tools : string list;
  resources : resources;
  console : console;
  secrets : secret list;
  env : (string * string) list;
      (** Literal NAME=value pairs exported into the guest's agent
          login shell. Sourced AFTER [secrets], so a clashing key in
          [env] wins. Names are validated at parse time against POSIX
          shell env-var rules; anything else raises [Parse_error].
          Values are arbitrary strings; the launcher single-quotes
          them when staging so they round-trip through the shell
          intact. Use for non-secret values; sensitive data belongs in
          [secrets]. *)
  proxy_auth : proxy_auth_rule list;
  shares : share list;
  state_dir : string option;
  git : git_identity;
  julia : julia;
  r : r;
  login_message : string option;
  startup : startup;
  guest : guest;
}

(** Every agent in the session, default first. Order is load-bearing: the
    default leads the MOTD, owns the [agent-run] alias, and is the first
    tmux window. *)
val agents : t -> agent list

val of_json : Yojson.Safe.t -> (t, string) result
(** Parse a Nickel-exported policy JSON into a typed record. Returns
    [Error msg] for any malformed input; no silent coercion, no
    default-filling at parse time. The launcher decides when to fill
    derived fields (e.g. resolving [git.name] from the host's
    [~/.gitconfig]) — those are not the parser's job. *)

val to_json : t -> Yojson.Safe.t
(** Serialize back to JSON for the policy.json file the guest reads. *)

val string_of_egress_mode : egress_mode -> string
(** Render an [egress_mode] as its CLI / policy.json token ("fenced" |
    "unfenced" | "airgap"). The CLI parses the inverse with an explicit
    match (see [bin/main.ml]) so a bad [--egress] value is a clean exit,
    not an exception; both parsers also accept the former
    allowlist/noblock/block spellings. *)
