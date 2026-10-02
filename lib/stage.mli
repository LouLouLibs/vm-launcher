(** Effectful staging: write the files into [etc_dir] that the guest's
    vmcfg virtiofs share will expose at [/etc/vm-launcher/].

    Each artifact has its own function so the boot path and [--show]
    can both reuse them, and so failures (e.g. a missing secret source)
    surface at the staging step rather than during VM boot. *)

val egress_hosts : etc_dir:string -> Policy.t -> unit
(** Write [etc_dir/egress-hosts]. *)

val instructions : etc_dir:string -> Policy.t -> unit
(** Write [etc_dir/instructions/<name>/<instructions_file>] for every
    declared agent (e.g. [instructions/claude/CLAUDE.md] and
    [instructions/codex/AGENTS.md]). Namespaced by agent name so two
    agents of the same preset don't overwrite each other. *)

val microvm_loaded :
  etc_dir:string -> source:Resolver.policy_source -> Policy.t -> unit
(** Write the "what built this VM" artifact under [etc_dir].

    - ALWAYS: serialize the RESOLVED [policy] as pretty JSON to
      [microvm-loaded.json]. This reflects CLI overrides the launcher
      applied (notably [--egress]), so it — not the [.ncl] below — is the
      trustworthy record of what actually built the VM. The guest points
      users at it from the login MOTD.
    - [Override path] → ALSO copy [path] verbatim as [microvm-loaded.ncl]
      (the declarative source as written; does not show CLI overrides). *)

val secrets : etc_dir:string -> Policy.t -> unit
(** For each [policy.secrets[]] entry, copy the (tilde-expanded) source
    file to a scope-specific subdir:
    - [Agent_env]  → [etc_dir/agent-secrets/<env>]  (read by the
      guest's [loginShellInit] for normal env-var wiring).
    - [Proxy_only] → [etc_dir/proxy-secrets/<env>]  (the
      [egressproxy-secret-bootstrap] systemd unit picks these up and
      tmpfs-shadows the directory so the agent never sees them).

    Each subdir is created on demand (mode 0700) and each file written
    mode 0600. A policy with only one scope writes only one subdir.

    Hard-fails (raises [Failure]) when a source path doesn't exist —
    catches typos before the guest tries to use the missing secret. *)

val session_id : etc_dir:string -> string -> unit
(** Write [etc_dir/session-id] (mode 0644) containing exactly the ID
    string (no trailing newline). Guest reads this back at
    [/etc/vm-launcher/session-id] via the vmcfg virtiofs share. *)

val env_vars : etc_dir:string -> (string * string) list -> unit
(** Write [etc_dir/env-vars] (mode 0644) as a shell-source-able file:
    one [export NAME='value'] line per entry, with single-quotes in
    values escaped as ['\\'']. The guest's [loginShellInit] sources
    this AFTER the [agent-secrets/] loop — so a name colliding with a
    secret resolves to the [env] value. Caller is responsible for
    name validation (already done at parse time in [Policy.of_json];
    invalid names there raise [Parse_error] long before this
    function sees them). *)

val shell_escape_single_quoted : string -> string
(** Exposed for testing. Wraps [s] in single quotes for safe
    embedding in a bash [export NAME=...] line: ['] in [s] becomes
    ['\\''] (close-quote, escaped-quote, reopen-quote). Inside the
    resulting literal, nothing else has special shell meaning. *)

val proxy_auth_config :
  etc_dir:string -> Policy.proxy_auth_rule list -> unit
(** Serialize [policy.proxyAuth] to [etc_dir/proxy-auth.conf] (mode
    0644) so the systemd-run proxy can ingest the rules without re-
    parsing the policy JSON. One line per rule, tab-separated:
    {v HOST<TAB>HEADER<TAB>VALUE_TEMPLATE v}

    Tabs let the template contain ['=' ':'] and spaces freely with no
    escape mechanism — the format intentionally has no quoting. Blank
    lines + ['#'-prefixed] lines are tolerated when parsing back via
    [Proxy_lib.parse_proxy_auth_config_line]. *)

val proxy_ca : etc_dir:string -> Proxy_ca.ca -> unit
(** Persist the per-VM MITM CA to disk so the proxy unit can read it
    back when systemd starts it:
    - [etc_dir/proxy-ca.pem] mode 0644 (the guest's trust store
      installs this via [security.pki.certificateFiles]).
    - [etc_dir/proxy-ca-key.pem] mode 0600 (only the
      [egressproxy-secret-bootstrap] oneshot reads it).

    Per-VM-session rotation is a deliberate property: the launcher
    generates a fresh CA each boot so a key leak's blast radius is
    one session. Do NOT reuse an on-disk CA across runs. *)

val policy_json : path:string -> Policy.t -> unit
(** Write [Policy.to_json p] as compact JSON to [path]. Distinct from
    the other stage functions because the file lives at
    [<state>/policy.json], not under [etc/] — the guest does not see
    it; the nix-build step reads it via [VM_LAUNCHER_POLICY_JSON]. *)

val resolve_shares : Policy.t -> Policy.t
(** Tilde-expand every [shares[].source] and validate it exists. Returns
    the policy with sources canonicalized so [_guest.nix] reads
    absolute paths via [policy_json].

    Raises [Failure] on the first missing source — staging-time fail-
    loud, because the alternative is virtiofsd exporting an empty dir
    and the guest seeing an empty mount with no diagnostic at boot. *)

val all :
  etc_dir:string -> source:Resolver.policy_source -> Policy.t -> unit
(** Convenience: [egress_hosts; instructions; microvm_loaded; secrets]
    in that order. *)
