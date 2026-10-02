type policy_source =
  | Override of string
  | Default

(* --- shelling out --- *)

let read_cmd_stdout cmd =
  let ic = Unix.open_process_in cmd in
  let buf = Buffer.create 1024 in
  (try
     while true do
       Buffer.add_channel buf ic 1024
     done
   with End_of_file -> ());
  let status = Unix.close_process_in ic in
  (status, Buffer.contents buf)

let find_project_root ?(cwd = Sys.getcwd ()) () =
  let cmd =
    Printf.sprintf "cd %s && git rev-parse --show-toplevel 2>/dev/null"
      (Filename.quote cwd)
  in
  match read_cmd_stdout cmd with
  | Unix.WEXITED 0, out ->
      let s = Util.trim_trailing_newline out in
      if String.length s > 0 then s else cwd
  | _ -> cwd

let nickel_export ?(nickel = "nickel") path =
  let cmd =
    Printf.sprintf "%s export %s --format json"
      (Filename.quote nickel) (Filename.quote path)
  in
  match read_cmd_stdout cmd with
  | Unix.WEXITED 0, out -> Yojson.Safe.from_string out
  | _, _ -> failwith (Printf.sprintf "nickel export failed: %s" path)

let host_git_identity () =
  let get key =
    let cmd =
      Printf.sprintf "git config --global %s 2>/dev/null" (Filename.quote key)
    in
    match read_cmd_stdout cmd with
    | Unix.WEXITED 0, out ->
        let s = Util.trim_trailing_newline out in
        if String.length s > 0 then Some s else None
    | _ -> None
  in
  get "user.name", get "user.email"

(* --- pure resolution --- *)

let tilde_expand path =
  if String.length path >= 2 && String.sub path 0 2 = "~/" then
    let home = try Sys.getenv "HOME" with Not_found -> "" in
    home ^ "/" ^ String.sub path 2 (String.length path - 2)
  else path

(* Convention-based policy discovery, used when no --policy is given.
   Searched relative to the project root. Directory variants are tried
   plural-first; within each phase the whole variant list is exhausted
   before moving on. Phase 1 = the canonical [microvm.ncl]; phase 2 =
   any [*.ncl] in the dir (alphabetical, first wins). First hit wins.
   Documented in docs/usage.md. *)
let policy_search_dirs = [ "envs"; "env"; "environments"; "environment" ]

let discover_policy ~project =
  let ( / ) = Filename.concat in
  let vm_dir d = project / d / "vm" in
  (* Phase 1: the canonical microvm.ncl under each dir variant, in order. *)
  let exact = List.map (fun d -> vm_dir d / "microvm.ncl") policy_search_dirs in
  (* Phase 2: any *.ncl under each dir variant (alphabetical, first wins),
     dir variants still tried in order. *)
  let globbed =
    List.concat_map
      (fun d ->
        let dir = vm_dir d in
        match Sys.readdir dir with
        | files ->
            Array.sort compare files;
            Array.to_list files
            |> List.filter (fun f -> Filename.check_suffix f ".ncl")
            |> List.map (fun f -> dir / f)
        | exception Sys_error _ -> [])
      policy_search_dirs
  in
  List.find_opt Sys.file_exists (exact @ globbed)

let resolve_source ~project ~override =
  match override with
  | Some path ->
      let path = tilde_expand path in
      if Sys.file_exists path then Override path
      else
        failwith
          (Printf.sprintf "--policy file does not exist: %s" path)
  | None -> (
      match discover_policy ~project with
      | Some path -> Override path
      | None -> Default)

let default_policy ~project =
  Policy.
    {
      project;
      work = { default = Rw; read_only = []; hidden = [] };
      inputs = [];
      egress = { hosts = [ "api.anthropic.com" ]; none = false; mode = Allowlist };
      auth = Bind;
      (* The built-in default hard-codes the claude-preset expansion (the
         contract's [preset = 'claude] computes the same defaults in
         Nickel). [config_host] is resolved at boot by
         [Boot.prepare_host_paths]. *)
      agent =
        {
          preset = "claude";
          name = "claude";
          package = "claude-code";
          command = "claude";
          flags = [ "--dangerously-skip-permissions" ];
          instructions_file = "CLAUDE.md";
          instructions = None;
          config_dir = ".claude";
          config_guest = "/var/lib/claude";
          config_env = "";
          config_mode = Symlinks;
          seed_files = [];
          task_dir = "tasks";
          state_dirs =
            [ "projects"; "todos"; "session-env"; "shell-snapshots";
              "file-history"; "paste-cache" ];
          state_files = [ "history.jsonl" ];
          home_state_files = [ ".claude.json" ];
          sync_files = [];
          config_host = None;
        };
      (* The built-in default is a single-agent, unmultiplexed session —
         the shape every policy had before the multi-agent contract. *)
      extra_agents = [];
      session = { multiplex = Multiplex_none; ssh = true; headless = false };
      tools =
        [ "coreutils"; "bashInteractive"; "git"; "jq"; "gnused"; "claude-code" ];
      resources = { vcpu = 4; mem_mb = 4096 };
      console = Console_hvc0;
      secrets = [];
      env = [];
      proxy_auth = [];
      shares = [];
      state_dir = None;
      git = { name = None; email = None; allowed_github_orgs = [] };
      julia = { env = "env/julia" };
      r = { packages = [] };
      login_message = None;
      startup = { commands = []; tools = []; log_file = None };
      guest = { hostname = None; username = None };
    }

let load ?nickel ~project source =
  match source with
  | Default -> default_policy ~project
  | Override path ->
      let json = nickel_export ?nickel path in
      (match Policy.of_json json with
       | Ok p -> p
       | Error msg -> failwith (Printf.sprintf "parse %s: %s" path msg))

let resolve_state_dir ~policy_state_dir ~xdg_state_home ~project_basename =
  match policy_state_dir with
  | Some s -> tilde_expand s
  | None -> xdg_state_home ^ "/microvm/" ^ project_basename

let marker_email host_email =
  match String.index_opt host_email '@' with
  | Some i when i > 0 && i < String.length host_email - 1 ->
      let localpart = String.sub host_email 0 i in
      let domain =
        String.sub host_email (i + 1) (String.length host_email - i - 1)
      in
      localpart ^ "+vmlaunch@" ^ domain
  | _ -> "vm-launcher@localhost"

(* [policy_git] annotated: [Policy.agent] also carries a [name] field,
   so field-based inference would otherwise resolve [policy_git.name]
   to the wrong record. *)
let resolve_git_identity ~(policy_git : Policy.git_identity) ~host_name
    ~host_email =
  let open Policy in
  let name =
    match policy_git.name with
    | Some _ as n -> n
    | None ->
        Some
          (match host_name with
           | Some n -> n ^ " (vm-launcher)"
           | None -> "vm-launcher")
  in
  let email =
    match policy_git.email with
    | Some _ as e -> e
    | None ->
        Some
          (match host_email with
           | Some e -> marker_email e
           | None -> "vm-launcher@localhost")
  in
  { policy_git with name; email }

(* Shared core: map each char to its sanitized form, collapse runs of
   '-', strip leading/trailing '-', optionally truncate. The
   [extra_allowed] charset lets username keep '_' (POSIX-legal) while
   hostname does not (RFC-1123 says letters, digits, hyphens). *)
let sanitize_for ~extra_allowed ?max_len s =
  let buf = Buffer.create (String.length s) in
  let last_dash = ref true in   (* start state: any leading dash is dropped *)
  String.iter
    (fun c ->
      let c' = Char.lowercase_ascii c in
      let is_alnum =
        (c' >= 'a' && c' <= 'z') || (c' >= '0' && c' <= '9')
      in
      if is_alnum || String.contains extra_allowed c' then begin
        Buffer.add_char buf c';
        last_dash := false
      end else if not !last_dash then begin
        Buffer.add_char buf '-';
        last_dash := true
      end)
    s;
  let raw = Buffer.contents buf in
  let len = String.length raw in
  let trimmed =
    if len > 0 && raw.[len - 1] = '-'
    then String.sub raw 0 (len - 1)
    else raw
  in
  let truncated =
    match max_len with
    | Some n when String.length trimmed > n ->
        (* If the truncated tail is a dash, drop it too. *)
        let s = String.sub trimmed 0 n in
        let n' = String.length s in
        if n' > 0 && s.[n' - 1] = '-' then String.sub s 0 (n' - 1) else s
    | _ -> trimmed
  in
  if truncated = "" then "vmlauncher" else truncated

let sanitize_hostname s = sanitize_for ~extra_allowed:"" s

let sanitize_username s =
  (* POSIX username charset is [a-z_][a-z0-9_-]* up to 32 chars. We
     keep '_' from the user's input and apply the same dash-collapse +
     trim semantics as the hostname case. The leading-char rule
     ([a-z_]) is handled implicitly: sanitize_for drops any leading
     dash, and the first kept char from a sanitized basename is
     always either a letter, a digit, or '_' — all of which are
     POSIX-legal as a first character except digits. We do not
     explicitly fix the leading-digit case; in practice no host $USER
     starts with a digit and the fallback "vmlauncher" covers anything
     pathological. *)
  sanitize_for ~extra_allowed:"_" ~max_len:32 s

let resolve_guest ~policy_guest ~project ~host_user =
  let open Policy in
  let hostname =
    match policy_guest.hostname with
    | Some _ as h -> h
    | None ->
        Some (sanitize_hostname (Filename.basename project))
  in
  let username =
    match policy_guest.username with
    | Some _ as u -> u
    | None ->
        let raw =
          match host_user with
          | Some u when u <> "" -> u ^ "-vm"
          | _ -> "vmlauncher"
        in
        Some (sanitize_username raw)
  in
  { hostname; username }
