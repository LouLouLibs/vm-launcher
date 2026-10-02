type rw_or_ro = Rw | Ro

type work = {
  default : rw_or_ro;
  read_only : string list;
  hidden : string list;
}

(* Effective network posture for the session. NOT a contract field —
   like [auth_home], it's launcher-injected (the operator-only [--egress]
   CLI flag), serialized into policy.json, and read by the guest. The
   project's microvm.ncl can never reach [Unrestricted] on its own: it's
   derived from [egress.none] at parse time ([none=true] → [Airgap], else
   [Allowlist]) and only the CLI flag can override to [Unrestricted]. So
   a (partly untrusted) policy can only make itself MORE restrictive.
   - [Allowlist]   : the default fence — in-guest MITM proxy + nftables
                     hostname allowlist.
   - [Unrestricted]: no proxy, open egress, direct NAT (operator-only).
   - [Airgap]      : no proxy, nftables drops all egress (no internet). *)
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

type console = Console_hvc0 | Console_ttys0

type secret_scope = Agent_env | Proxy_only

type secret = {
  env : string;
  source : string;
  scope : secret_scope;
}

type proxy_auth_rule = {
  host : string;
  header : string;
  value_template : string;
}

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

type guest = {
  hostname : string option;
  username : string option;
}

(* Terminal multiplexer on the guest console. [Multiplex_auto] resolves
   to tmux only when the session declares more than one agent, so
   single-agent VMs keep a plain login shell. *)
type multiplex = Multiplex_auto | Multiplex_tmux | Multiplex_none

type session = {
  multiplex : multiplex;
  ssh : bool;
      (* sshd in the guest on the slot address, for `vm-launcher attach`. *)
  headless : bool;
      (* Launcher-injected, not a contract field: set when the VM is
         booted detached. The guest then skips the console login session
         entirely — agetty on a non-tty would restart-loop, and its
         ExecStopPost=poweroff would kill the VM with the first shell
         that exits. *)
}

(* Neutral agent profile. The contract carries a [preset] ('claude |
   'codex) that expands — in Nickel — into the concrete defaults below;
   the launcher reads them as plain data. The base guest is wired off
   these fields so it carries no literal agent name. *)
(* How the guest builds ~/<config_dir>. [Symlinks] is claude's model (a
   dir of links into the RO config bind, with an enumerated writable
   subset); [Writable] is codex's (the dir IS the agent's RW state, with
   [seed_files] copied in from the RO bind at boot). *)
type config_mode = Symlinks | Writable

type agent = {
  preset : string;
  name : string;             (* identity: <name>-run, state namespace, tmux window *)
  package : string;          (* nixpkgs attr added to the guest closure *)
  command : string;          (* binary the wrapper execs (on PATH via tools) *)
  flags : string list;       (* was claudeFlags *)
  instructions_file : string;(* rendered-instructions filename, e.g. CLAUDE.md *)
  instructions : string option; (* was claudeInstructions *)
  config_dir : string;       (* path relative to $HOME, e.g. .claude, .config/codex *)
  config_guest : string;     (* RO bind mountpoint in the guest, e.g. /var/lib/claude *)
  config_env : string;       (* env var pointing the agent at it ("" = none) *)
  config_mode : config_mode; (* how ~/<config_dir> is built in the guest *)
  seed_files : string list;  (* Writable only: files copied from the RO bind at boot *)
  task_dir : string;         (* RW task-tracker nest under config_guest ("" = none) *)
  state_dirs : string list;  (* writable subdirs redirected to the state bind *)
  state_files : string list; (* writable files inside config_dir *)
  home_state_files : string list; (* siblings of config_dir in $HOME *)
  sync_files : string list;
      (* Symlinks only: files the agent replaces atomically — copied in
         from the state namespace at boot, copied back on change *)
  config_host : string option;
      (* Host config dir ($HOME/<config_dir>), resolved by the launcher
         from $HOME when auth = Bind (None otherwise). Not a contract
         field — injected at boot time so the guest's config bind isn't
         hardcoded to one user's home. Formerly [auth_home]. *)
}

type on_failure = On_failure_warn | On_failure_block

type startup_command = {
  command : string;
  on_failure : on_failure;
}

type startup = {
  commands : startup_command list;
  tools : string list;
      (* Empty list is the documented sentinel for "inherit
         policy.tools" — the substitution happens at the
         guest-side _guest.nix. Non-empty list =
         exactly those nixpkgs attrs in the startup-hooks PATH. *)
  log_file : string option;
}

type t = {
  project : string;
  work : work;
  inputs : string list;
  egress : egress;
  auth : auth;
  agent : agent;
  extra_agents : agent list;
  session : session;
  tools : string list;
  resources : resources;
  console : console;
  secrets : secret list;
  env : (string * string) list;
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

(* Parser. Internal exception → top-level result; gives us cheap
   propagation through nested calls without sprinkling Result.bind. *)

exception Parse_error of string

let fail fmt = Printf.ksprintf (fun s -> raise (Parse_error s)) fmt

let must_string = function
  | `String s -> s
  | j -> fail "expected string, got %s" (Yojson.Safe.to_string j)

let must_int = function
  | `Int n -> n
  | j -> fail "expected int, got %s" (Yojson.Safe.to_string j)

let must_bool = function
  | `Bool b -> b
  | j -> fail "expected bool, got %s" (Yojson.Safe.to_string j)

let must_list = function
  | `List xs -> xs
  | j -> fail "expected list, got %s" (Yojson.Safe.to_string j)

let must_assoc = function
  | `Assoc kvs -> kvs
  | j -> fail "expected object, got %s" (Yojson.Safe.to_string j)

let field name j =
  match List.assoc_opt name (must_assoc j) with
  | Some v -> v
  | None -> fail "missing field: %s" name

let field_opt name j = List.assoc_opt name (must_assoc j)

let string_list j = List.map must_string (must_list j)

(* Agent name: becomes a command name (<name>-run), a path segment (the
   state namespace) and a tmux window name, so keep it to a bare word.
   Rejects empty, and anything outside [A-Za-z0-9_-]. *)
let valid_agent_name s =
  let len = String.length s in
  len > 0
  && (let rec ok i =
        if i >= len then true
        else
          let c = s.[i] in
          ((c >= 'a' && c <= 'z')
          || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9')
          || c = '_' || c = '-')
          && ok (i + 1)
      in
      ok 0)

(* POSIX env-var name: leading letter or underscore (uppercase by
   convention; we enforce uppercase since policy.env is for shell
   exports and lowercase names trip a lot of tooling that
   greps for [A-Z_]+=), then [A-Z0-9_]*. Rejects empty too. *)
let valid_env_name s =
  let len = String.length s in
  if len = 0 then false
  else
    let head_ok =
      let c = s.[0] in
      (c >= 'A' && c <= 'Z') || c = '_'
    in
    let rec tail_ok i =
      if i >= len then true
      else
        let c = s.[i] in
        let ok =
          (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_'
        in
        ok && tail_ok (i + 1)
    in
    head_ok && tail_ok 1

(* Prefix the field path onto inner errors so the user sees
   "work.readOnly[2]: expected string" instead of just "expected string". *)
let in_field name f j =
  try f (field name j)
  with Parse_error msg -> raise (Parse_error (name ^ "." ^ msg))

(* Optional field with a default. Treats both an absent key and an
   explicit [`Null] as "use the default" — the latter is what Nickel
   exports for fields whose contract says [| ... | _ : Dyn]. Same
   error-prefix wrapping as [in_field] so nested failures are
   attributed correctly. *)
let in_field_or name default f j =
  match field_opt name j with
  | None | Some `Null -> default
  | Some v ->
      (try f v
       with Parse_error msg -> raise (Parse_error (name ^ "." ^ msg)))

let opt_str = function "" -> None | s -> Some s

let parse_rw_or_ro j =
  match must_string j with
  | "rw" -> Rw
  | "ro" -> Ro
  | s -> fail {|expected "rw" or "ro", got %S|} s

let parse_work j =
  {
    default = in_field "default" parse_rw_or_ro j;
    read_only = in_field "readOnly" string_list j;
    hidden = in_field "hidden" string_list j;
  }

let egress_mode_of_string = function
  (* Both spellings parse. `fenced`/`unfenced`/`airgap` is the vocabulary
     the tool speaks everywhere else — the guest banner, the statusline,
     `vm-launcher ls` — while `allowlist`/`noblock`/`block` are what it
     used to accept. Keeping the old ones costs three lines and means no
     policy.json, script or muscle-memory breaks. *)
  | "fenced" | "allowlist" -> Allowlist
  | "unfenced" | "noblock" -> Unrestricted
  | "airgap" | "block" -> Airgap
  | s ->
      fail
        {|expected "fenced", "unfenced" or "airgap" (or the former allowlist/noblock/block), got %S|}
        s

let parse_egress j =
  let none = in_field "none" must_bool j in
  (* [mode] is launcher-injected, not a contract field — Nickel-exported
     policy JSON has no [mode] key, so default it from [none]
     ([none=true] → airgap, else allowlist). Read it back when present so
     [of_json (to_json p)] round-trips (tests rely on it). *)
  let mode =
    in_field_or "mode" (if none then Airgap else Allowlist)
      (fun j -> egress_mode_of_string (must_string j)) j
  in
  { hosts = in_field "hosts" string_list j; none; mode }

let parse_auth j =
  match must_string j with
  | "bind" -> Bind
  | "ephemeral" -> Ephemeral
  | s -> fail {|expected "bind" or "ephemeral", got %S|} s

let parse_resources j =
  { vcpu = in_field "vcpu" must_int j; mem_mb = in_field "memMb" must_int j }

let parse_console j =
  match must_string j with
  | "hvc0" -> Console_hvc0
  | "ttyS0" -> Console_ttys0
  | s -> fail {|expected "hvc0" or "ttyS0", got %S|} s

let parse_secret_scope j =
  match must_string j with
  | "agent" -> Agent_env
  | "proxy" -> Proxy_only
  | s -> fail {|expected "agent" or "proxy", got %S|} s

(* [scope] is optional on input for forward-compat with microvm.ncl files
   that predate the field. Default is [Agent_env] (the legacy behaviour);
   a future contract change will eventually flip this to required. *)
let parse_secret j =
  {
    env = in_field "env" must_string j;
    source = in_field "source" must_string j;
    scope = in_field_or "scope" Agent_env parse_secret_scope j;
  }

let parse_proxy_auth_rule j =
  {
    host = in_field "host" must_string j;
    header = in_field "header" must_string j;
    value_template = in_field "valueTemplate" must_string j;
  }

let parse_share j =
  {
    source = in_field "source" must_string j;
    mount_point = in_field "mountPoint" must_string j;
    read_only = in_field_or "readOnly" false must_bool j;
  }

let parse_git j =
  {
    name = opt_str (in_field "name" must_string j);
    email = opt_str (in_field "email" must_string j);
    allowed_github_orgs = in_field "allowedGithubOrgs" string_list j;
  }

let parse_julia j = { env = in_field "env" must_string j }
let parse_r j = { packages = in_field "packages" string_list j }

let parse_guest j =
  {
    hostname = opt_str (in_field "hostname" must_string j);
    username = opt_str (in_field "username" must_string j);
  }

let parse_config_mode j =
  match must_string j with
  | "symlinks" -> Symlinks
  | "writable" -> Writable
  | s -> fail {|expected "symlinks" or "writable", got %S|} s

(* Preset-derived fallbacks for the fields added after PR-A. Fixtures and
   hand-built JSON that predate them still parse: an older policy.json is
   a claude-shaped single agent. *)
let default_name_of_preset = function "codex" -> "codex" | _ -> "claude"
let default_package_of_preset = function "codex" -> "codex" | _ -> "claude-code"
let default_config_env_of_preset = function "codex" -> "CODEX_HOME" | _ -> ""
let default_config_mode_of_preset = function "codex" -> Writable | _ -> Symlinks

let parse_agent j =
  let preset = in_field "preset" must_string j in
  {
    preset;
    name = in_field_or "name" (default_name_of_preset preset) must_string j;
    package =
      in_field_or "package" (default_package_of_preset preset) must_string j;
    command = in_field "command" must_string j;
    flags = in_field "flags" string_list j;
    instructions_file = in_field "instructionsFile" must_string j;
    instructions = opt_str (in_field "instructions" must_string j);
    config_dir = in_field "configDir" must_string j;
    config_guest = in_field "configGuest" must_string j;
    config_env =
      in_field_or "configEnv" (default_config_env_of_preset preset) must_string j;
    config_mode =
      in_field_or "configMode"
        (default_config_mode_of_preset preset)
        parse_config_mode j;
    seed_files = in_field_or "seedFiles" [] string_list j;
    task_dir = in_field "taskDir" must_string j;
    state_dirs = in_field "stateDirs" string_list j;
    state_files = in_field "stateFiles" string_list j;
    home_state_files = in_field "homeStateFiles" string_list j;
    sync_files = in_field_or "syncFiles" [] string_list j;
    (* configHost is launcher-injected, absent from the contract — default
       None so parsing a plain microvm.ncl export still succeeds. *)
    config_host =
      in_field_or "configHost" None (fun v -> opt_str (must_string v)) j;
  }

let parse_multiplex j =
  match must_string j with
  | "auto" -> Multiplex_auto
  | "tmux" -> Multiplex_tmux
  | "none" -> Multiplex_none
  | s -> fail {|expected "auto", "tmux" or "none", got %S|} s

let parse_session j =
  {
    (* Must match contract.ncl's default ('none) and _guest.nix's
       fallback. Three copies of one default is already a smell; three
       copies that DISAGREE meant any path not going through Nickel (a
       hand-written policy.json, an older launcher) silently got tmux. *)
    multiplex = in_field_or "multiplex" Multiplex_none parse_multiplex j;
    (* Forward-compat defaults: a policy.json written before these fields
       existed is a non-ssh, attached session. *)
    ssh = in_field_or "ssh" false must_bool j;
    headless = in_field_or "headless" false must_bool j;
  }

let parse_on_failure j =
  match must_string j with
  | "warn" -> On_failure_warn
  | "block" -> On_failure_block
  | s -> fail {|expected "warn" or "block", got %S|} s

let parse_startup_command j =
  {
    command = in_field "command" must_string j;
    on_failure = in_field_or "onFailure" On_failure_warn parse_on_failure j;
  }

let parse_startup j =
  let commands =
    in_field_or "commands" [] (fun j' -> List.map parse_startup_command (must_list j')) j
  in
  (* tools: forward-compat default for pre-field fixtures. Empty list
     is the documented sentinel for "inherit policy.tools" — the
     guest does the substitution. *)
  let tools = in_field_or "tools" [] string_list j in
  let log_file = in_field_or "logFile" None (fun v -> opt_str (must_string v)) j in
  { commands; tools; log_file }

(* Names must be unique across agent + extraAgents: they name the run
   wrapper, the state namespace and the tmux window, so a duplicate would
   silently give two agents one wrapper and one pile of state. *)
let check_agent_names (agents : agent list) =
  List.iter
    (fun a ->
      if not (valid_agent_name a.name) then
        fail "agent name %S is not a bare word (allowed: [A-Za-z0-9_-])" a.name)
    agents;
  let rec dup seen = function
    | [] -> ()
    | (a : agent) :: rest ->
        if List.mem a.name seen then
          fail "duplicate agent name %S (agent + extraAgents must be unique)"
            a.name
        else dup (a.name :: seen) rest
  in
  dup [] agents

let parse_policy j =
  let proxy_auth =
    in_field_or "proxyAuth" []
      (fun j' -> List.map parse_proxy_auth_rule (must_list j')) j
  in
  let secrets =
    in_field "secrets" (fun j' -> List.map parse_secret (must_list j')) j
  in
  (* env: literal NAME=value pairs. Validates names against POSIX
     env-var rules at parse time so a bad entry cannot slip into
     Stage.env_vars where the failure would be opaque. Empty-default
     + field_opt for forward-compat with pre-field fixtures. *)
  let env =
    match field_opt "env" j with
    | None | Some `Null -> []
    | Some (`Assoc kvs) ->
        List.iter
          (fun (k, _) ->
            if not (valid_env_name k) then
              raise (Parse_error
                (Printf.sprintf
                   "env: invalid env-var name %S (must match \
                    [A-Z_][A-Z0-9_]*)" k)))
          kvs;
        List.map
          (fun (k, v) ->
            try (k, must_string v)
            with Parse_error msg ->
              raise (Parse_error ("env." ^ k ^ ": " ^ msg)))
          kvs
    | Some j' ->
        raise (Parse_error
          (Printf.sprintf "env: expected object, got %s"
             (Yojson.Safe.to_string j')))
  in
  (* shares is optional in the parser: older fixtures pre-date the
     field. Same forward-compat pattern as proxyAuth. *)
  let shares =
    in_field_or "shares" [] (fun j' -> List.map parse_share (must_list j')) j
  in
  (* Agents are bound (and checked) before the record so a duplicate or
     malformed name fails at parse time, where the error names the field
     — not later, inside the guest, as two agents sharing one wrapper. *)
  let agent = in_field "agent" parse_agent j in
  (* extraAgents / session: forward-compat defaults. Every policy that
     predates the multi-agent contract is a single-agent, unmultiplexed
     session. *)
  let extra_agents =
    in_field_or "extraAgents" [] (fun j' -> List.map parse_agent (must_list j')) j
  in
  check_agent_names (agent :: extra_agents);
  {
    project = in_field "project" must_string j;
    work = in_field "work" parse_work j;
    inputs = in_field "inputs" string_list j;
    egress = in_field "egress" parse_egress j;
    auth = in_field "auth" parse_auth j;
    agent;
    extra_agents;
    (* A policy.json with no session block predates these fields, so it
       is an attached, non-ssh session — NOT the contract's defaults.
       Real policies always arrive through the contract, which fills
       session.ssh in itself. Defaulting to ssh = true here would make
       every legacy fixture try to mint keys. *)
    session =
      in_field_or "session"
        { multiplex = Multiplex_none; ssh = false; headless = false }
        parse_session j;
    tools = in_field "tools" string_list j;
    resources = in_field "resources" parse_resources j;
    (* console: forward-compat default. Older fixtures predate the
       field; current Nickel contract always writes it (default
       'hvc0 → "hvc0"). *)
    console = in_field_or "console" Console_hvc0 parse_console j;
    secrets;
    env;
    proxy_auth;
    shares;
    state_dir = opt_str (in_field "stateDir" must_string j);
    git = in_field "git" parse_git j;
    julia = in_field "julia" parse_julia j;
    r = in_field "r" parse_r j;
    (* loginMessage is parsed optionally — older fixtures predate the
       field. The serializer always writes it (default "") so the
       guest's _guest.nix never sees a missing key. *)
    login_message =
      in_field_or "loginMessage" None (fun v -> opt_str (must_string v)) j;
    startup =
      in_field_or "startup"
        { commands = []; tools = []; log_file = None } parse_startup j;
    guest =
      in_field_or "guest"
        { hostname = None; username = None } parse_guest j;
  }

(* Every agent in the session, default first. The order is load-bearing:
   the default agent leads the MOTD, owns the `agent-run` alias, and is
   the first tmux window. *)
let agents (t : t) : agent list = t.agent :: t.extra_agents

let of_json j =
  try Ok (parse_policy j) with Parse_error msg -> Error msg

(* Serializer. Mirrors the on-disk JSON shape the launcher's bash version
   writes via `jq -n`; the guest's _guest.nix reads specific fields and
   ignores any extras. Empty optionals become "" to match the contract's
   defaults (so a roundtrip through the parser is structural-equality
   preserving). *)

let json_of_rw_or_ro = function Rw -> `String "rw" | Ro -> `String "ro"
let json_of_auth = function Bind -> `String "bind" | Ephemeral -> `String "ephemeral"

let json_of_secret_scope = function
  | Agent_env -> `String "agent"
  | Proxy_only -> `String "proxy"

let json_of_string_list xs = `List (List.map (fun s -> `String s) xs)
let json_of_opt_str = function Some s -> `String s | None -> `String ""

let json_of_work w =
  `Assoc
    [
      "default", json_of_rw_or_ro w.default;
      "readOnly", json_of_string_list w.read_only;
      "hidden", json_of_string_list w.hidden;
    ]

let string_of_egress_mode = function
  | Allowlist -> "fenced"
  | Unrestricted -> "unfenced"
  | Airgap -> "airgap"

let json_of_egress e =
  `Assoc
    [
      "hosts", json_of_string_list e.hosts;
      "none", `Bool e.none;
      "mode", `String (string_of_egress_mode e.mode);
    ]

let json_of_resources r =
  `Assoc [ "vcpu", `Int r.vcpu; "memMb", `Int r.mem_mb ]

let json_of_console = function
  | Console_hvc0 -> `String "hvc0"
  | Console_ttys0 -> `String "ttyS0"

let json_of_secret (s : secret) =
  `Assoc
    [
      "env", `String s.env;
      "source", `String s.source;
      "scope", json_of_secret_scope s.scope;
    ]

let json_of_proxy_auth_rule r =
  `Assoc
    [
      "host", `String r.host;
      "header", `String r.header;
      "valueTemplate", `String r.value_template;
    ]

let json_of_share (s : share) =
  `Assoc
    [
      "source", `String s.source;
      "mountPoint", `String s.mount_point;
      "readOnly", `Bool s.read_only;
    ]

(* Annotated: [agent] also has a [name] field, so field-based inference
   would otherwise resolve [g.name] to the wrong record. *)
let json_of_git (g : git_identity) =
  `Assoc
    [
      "name", json_of_opt_str g.name;
      "email", json_of_opt_str g.email;
      "allowedGithubOrgs", json_of_string_list g.allowed_github_orgs;
    ]

let json_of_julia (j : julia) = `Assoc [ "env", `String j.env ]
let json_of_r (r : r) = `Assoc [ "packages", json_of_string_list r.packages ]

let json_of_on_failure = function
  | On_failure_warn -> `String "warn"
  | On_failure_block -> `String "block"

let json_of_startup_command (c : startup_command) =
  `Assoc
    [
      "command", `String c.command;
      "onFailure", json_of_on_failure c.on_failure;
    ]

let json_of_startup (s : startup) =
  `Assoc
    [
      "commands", `List (List.map json_of_startup_command s.commands);
      "tools", json_of_string_list s.tools;
      "logFile", json_of_opt_str s.log_file;
    ]

let json_of_guest (g : guest) =
  `Assoc
    [
      "hostname", json_of_opt_str g.hostname;
      "username", json_of_opt_str g.username;
    ]

let json_of_config_mode = function
  | Symlinks -> `String "symlinks"
  | Writable -> `String "writable"

let json_of_multiplex = function
  | Multiplex_auto -> `String "auto"
  | Multiplex_tmux -> `String "tmux"
  | Multiplex_none -> `String "none"

let json_of_session (s : session) =
  `Assoc
    [
      "multiplex", json_of_multiplex s.multiplex;
      "ssh", `Bool s.ssh;
      "headless", `Bool s.headless;
    ]

let json_of_agent (a : agent) =
  `Assoc
    [
      "preset", `String a.preset;
      "name", `String a.name;
      "package", `String a.package;
      "command", `String a.command;
      "flags", json_of_string_list a.flags;
      "instructionsFile", `String a.instructions_file;
      "instructions", json_of_opt_str a.instructions;
      "configDir", `String a.config_dir;
      "configGuest", `String a.config_guest;
      "configEnv", `String a.config_env;
      "configMode", json_of_config_mode a.config_mode;
      "seedFiles", json_of_string_list a.seed_files;
      "taskDir", `String a.task_dir;
      "stateDirs", json_of_string_list a.state_dirs;
      "stateFiles", json_of_string_list a.state_files;
      "homeStateFiles", json_of_string_list a.home_state_files;
      "syncFiles", json_of_string_list a.sync_files;
      "configHost", json_of_opt_str a.config_host;
    ]

let to_json t =
  `Assoc
    [
      "project", `String t.project;
      "work", json_of_work t.work;
      "inputs", json_of_string_list t.inputs;
      "egress", json_of_egress t.egress;
      "auth", json_of_auth t.auth;
      "agent", json_of_agent t.agent;
      "extraAgents", `List (List.map json_of_agent t.extra_agents);
      "session", json_of_session t.session;
      "tools", json_of_string_list t.tools;
      "resources", json_of_resources t.resources;
      "console", json_of_console t.console;
      "secrets", `List (List.map json_of_secret t.secrets);
      ("env",
       `Assoc (List.map (fun (k, v) -> (k, `String v)) t.env));
      "proxyAuth", `List (List.map json_of_proxy_auth_rule t.proxy_auth);
      "shares", `List (List.map json_of_share t.shares);
      "stateDir", json_of_opt_str t.state_dir;
      "git", json_of_git t.git;
      "julia", json_of_julia t.julia;
      "r", json_of_r t.r;
      "loginMessage", json_of_opt_str t.login_message;
      "startup", json_of_startup t.startup;
      "guest", json_of_guest t.guest;
    ]
