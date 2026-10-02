let egress_hosts ~etc_dir p =
  Util.write_file (etc_dir ^ "/egress-hosts") (Render.egress_hosts p)

(* One instructions file per declared agent, namespaced by agent name:
   etc/instructions/<name>/<instructionsFile>. The namespace matters even
   though CLAUDE.md and AGENTS.md differ — two agents of the SAME preset
   (two claudes on different tasks) would otherwise overwrite each other's
   file. The guest's per-agent home-init reads its own path. *)
let instructions ~etc_dir (p : Policy.t) =
  List.iter
    (fun (a : Policy.agent) ->
      let dir = etc_dir ^ "/instructions/" ^ a.name in
      Util.mkdir_p ~perm:0o755 dir;
      Util.write_file (dir ^ "/" ^ a.instructions_file)
        (Render.instructions ~agent:a p))
    (Policy.agents p)

let microvm_loaded ~etc_dir ~(source : Resolver.policy_source) (p : Policy.t) =
  (* Always write the RESOLVED policy as JSON. This is the source of
     truth the guest surfaces at login (`cat microvm-loaded.json`): it
     reflects every CLI override the launcher applied on top of the
     source — most importantly the operator-only `--egress` flag, which
     a verbatim copy of the .ncl source would NOT show. *)
  let json = Yojson.Safe.pretty_to_string (Policy.to_json p) in
  Util.write_file (etc_dir ^ "/microvm-loaded.json") (json ^ "\n");
  (* And, when the policy came from a file, ALSO preserve the declarative
     source verbatim as .ncl — handy for diffing against what you wrote,
     but it is the .json above (not this) that captures CLI overrides. *)
  match source with
  | Override path ->
      Util.copy_file ~perm:0o644 path (etc_dir ^ "/microvm-loaded.ncl")
  | Default -> ()

let secrets ~etc_dir (p : Policy.t) =
  (* Scope split: [Agent_env] secrets go under
     [agent-secrets/] (read by the guest's [loginShellInit] env wiring);
     [Proxy_only] secrets go under [proxy-secrets/] (the
     [egressproxy-secret-bootstrap] systemd unit copies them to a
     egressproxy-owned location, then tmpfs-shadows this dir to prevent
     filename enumeration).

     Both scopes are written mode 0600. virtiofs passthrough means
     the guest agent (uid 1000) and the bootstrap unit's virtiofsd
     proxy (also uid 1000 — the launcher's user) share an effective
     uid, so a stricter mode would block the bootstrap too. The
     actual defense for Proxy_only files is the tmpfs shadow that
     the bootstrap unit puts over /etc/vm-launcher/proxy-secrets/
     BEFORE any agent code runs (via systemd Before= vm-launcher-
     startup-hooks / vm-launcher-session). The race window is closed
     by ordering, not mode. *)
  let agent_dir = etc_dir ^ "/agent-secrets" in
  let proxy_dir = etc_dir ^ "/proxy-secrets" in
  let ensure_dir d =
    try Unix.mkdir d 0o700
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  in
  List.iter
    (fun (s : Policy.secret) ->
      let src = Resolver.tilde_expand s.source in
      if not (Sys.file_exists src) then
        failwith
          (Printf.sprintf "secret source missing: %s (env=%s)" src s.env);
      let dir =
        match s.scope with
        | Agent_env -> agent_dir
        | Proxy_only -> proxy_dir
      in
      ensure_dir dir;
      Util.copy_file ~perm:0o600 src (dir ^ "/" ^ s.env))
    p.secrets

let session_id ~etc_dir id =
  (* No trailing newline — the guest's loginShellInit-style readers
     read with `cat` and we don't want stray \n in $SESSION_ID. *)
  Util.write_file ~perm:0o644 (etc_dir ^ "/session-id") id

let proxy_auth_config ~etc_dir (rules : Policy.proxy_auth_rule list) =
  let buf = Buffer.create 256 in
  List.iter
    (fun (r : Policy.proxy_auth_rule) ->
      Buffer.add_string buf r.host;
      Buffer.add_char buf '\t';
      Buffer.add_string buf r.header;
      Buffer.add_char buf '\t';
      Buffer.add_string buf r.value_template;
      Buffer.add_char buf '\n')
    rules;
  Util.write_file ~perm:0o644
    (etc_dir ^ "/proxy-auth.conf")
    (Buffer.contents buf)

let proxy_ca ~etc_dir (ca : Proxy_ca.ca) =
  (* Cert is intentionally world-readable: the guest's CA-bundle
     composer (vm-cabundle oneshot) cats this into the runtime trust
     bundle every boot. *)
  Util.write_file ~perm:0o644 (etc_dir ^ "/proxy-ca.pem")
    (Proxy_ca.ca_cert_pem ca);
  (* Key goes UNDER proxy-secrets/ so the egressproxy-secret-bootstrap
     unit covers it with the same tmpfs shadow as proxy-scoped
     secrets. Mode 0600 is sufficient — virtiofs `passthrough` means
     virtiofsd (host uid 1000) reads on behalf of any guest uid,
     including root, so a stricter mode would block the bootstrap
     too (the agent's uid in the guest is also 1000 — they share
     virtiofsd, so mode bits can't distinguish them). The actual
     defense is unit ordering: bootstrap runs Before=
     vm-launcher-startup-hooks/vm-launcher-session, so the tmpfs shadow lands
     before any agent process exists. After the shadow, even an
     `ls /etc/vm-launcher/proxy-secrets/` from the agent returns
     Permission denied. *)
  let proxy_secrets = etc_dir ^ "/proxy-secrets" in
  (try Unix.mkdir proxy_secrets 0o700
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Util.write_file ~perm:0o600
    (proxy_secrets ^ "/proxy-ca-key.pem")
    (Proxy_ca.ca_key_pem ca)

(* Single-quote a value for safe shell export. Inside a single-
   quoted bash string the ONLY character with special meaning is the
   single-quote itself, which we escape via close-quote, escaped-
   quote, reopen-quote (the {| it ... s me |} pattern). Anything else
   inside the literal passes through untouched: no interpolation, no
   command substitution, no backslash interp. *)
let shell_escape_single_quoted s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '\'';
  String.iter
    (fun c ->
      if c = '\'' then Buffer.add_string buf "'\\''"
      else Buffer.add_char buf c)
    s;
  Buffer.add_char buf '\'';
  Buffer.contents buf

(* policy.env → /etc/vm-launcher/env-vars: a shell-source-able file
   the guest's loginShellInit reads AFTER agent-secrets/. Order is
   contract: env can override a clashing name from secrets. *)
let env_vars ~etc_dir (env : (string * string) list) =
  let path = etc_dir ^ "/env-vars" in
  let buf = Buffer.create 256 in
  List.iter
    (fun (k, v) ->
      Buffer.add_string buf "export ";
      Buffer.add_string buf k;
      Buffer.add_char buf '=';
      Buffer.add_string buf (shell_escape_single_quoted v);
      Buffer.add_char buf '\n')
    env;
  Util.write_file ~perm:0o644 path (Buffer.contents buf)

let policy_json ~path p =
  Util.write_file path (Yojson.Safe.to_string (Policy.to_json p))

(* Resolve shares: tilde-expand each [source] and validate it exists.
   Returns the policy with sources canonicalized so the staged JSON
   (read by _guest.nix) has absolute paths microvm.nix can hand to
   virtiofsd. A missing source fails-loud at staging time — much
   better than a virtiofsd that boots, exports an empty dir, and the
   guest sees an empty mount with no diagnostic. *)
let resolve_shares (p : Policy.t) : Policy.t =
  let shares =
    List.map
      (fun (s : Policy.share) ->
        let src = Resolver.tilde_expand s.source in
        if not (Sys.file_exists src) then
          failwith
            (Printf.sprintf
               "shares: source %s does not exist (mountPoint=%s)"
               src s.mount_point);
        { s with source = src })
      p.shares
  in
  { p with shares }

let all ~etc_dir ~source p =
  egress_hosts ~etc_dir p;
  instructions ~etc_dir p;
  microvm_loaded ~etc_dir ~source p;
  secrets ~etc_dir p;
  (* env-vars staged AFTER secrets so the loginShellInit ordering
     contract (secrets first, env last → env overrides) is mirrored
     on the host side. The guest is what actually sources them in
     order; this is layout consistency for the reader. *)
  env_vars ~etc_dir p.env
