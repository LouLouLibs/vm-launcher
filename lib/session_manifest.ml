type t = {
  id : string;
  launched_at : string;
  slot : int option;
  launch_cwd : string;
  policy_source_path : string option;
  policy_source_sha256 : string option;
  policy_json : Yojson.Safe.t;
  flake_path : string option;
  flake_rev : string option;
  flake_dirty : bool;
  vm_launcher_store_path : string option;
  hostname : string;
  user : string;
  project : string;
}

(* Crockford base32 alphabet: 0-9 + a-z without I, L, O, U. Avoids
   easily-confused chars in a hand-copied ID. 32 chars exactly so
   [c land 0x1f] always lands in-bounds. *)
let alphabet = "0123456789abcdefghjkmnpqrstvwxyz"

let random_suffix n =
  let bytes = Mirage_crypto_rng.generate n in
  let buf = Buffer.create n in
  for i = 0 to n - 1 do
    let c = Char.code (String.get bytes i) in
    Buffer.add_char buf alphabet.[c land 0x1f]
  done;
  Buffer.contents buf

(* [YYYYMMDDTHHMMSS] in local time. [Ptime_clock.current_tz_offset_s]
   gives the offset to add to UTC to land in local time. *)
let id_time_prefix () =
  let utc = Ptime_clock.now () in
  let offs =
    Option.value (Ptime_clock.current_tz_offset_s ()) ~default:0
  in
  let local =
    match Ptime.add_span utc (Ptime.Span.of_int_s offs) with
    | Some l -> l
    | None -> utc   (* span overflow — implausible; fall back *)
  in
  let (y, mo, d), ((h, mi, s), _) = Ptime.to_date_time local in
  Printf.sprintf "%04d%02d%02dT%02d%02d%02d" y mo d h mi s

let generate_id () =
  id_time_prefix () ^ "-" ^ random_suffix 6

(* ISO 8601 with TZ offset for the manifest's [launched_at]. *)
let iso8601_local () =
  let utc = Ptime_clock.now () in
  let offs =
    Option.value (Ptime_clock.current_tz_offset_s ()) ~default:0
  in
  Ptime.to_rfc3339 ~tz_offset_s:offs utc

(* ---- Subprocess helpers (degrade gracefully on failure) ---- *)

(* Run [cmd] (via /bin/sh -c), return first line of stdout on success.
   [None] for any failure: nonzero rc, missing binary, broken pipe.
   Used for git rev-parse + sha256sum where a missing tool / repo is
   expected, not an error. *)
let first_line_of_process cmd =
  let ic =
    try Some (Unix.open_process_in cmd)
    with Unix.Unix_error _ -> None
  in
  match ic with
  | None -> None
  | Some ic ->
      let line =
        try Some (input_line ic)
        with End_of_file -> None
      in
      (* Drain rest so close doesn't SIGPIPE the producer. *)
      (try while true do ignore (input_line ic) done
       with End_of_file -> ());
      (match Unix.close_process_in ic with
       | Unix.WEXITED 0 -> line
       | _ -> None)

let any_line_of_process cmd =
  let ic =
    try Some (Unix.open_process_in cmd)
    with Unix.Unix_error _ -> None
  in
  match ic with
  | None -> false
  | Some ic ->
      let saw = ref false in
      (try while true do let _ = input_line ic in saw := true done
       with End_of_file -> ());
      let _ = Unix.close_process_in ic in
      !saw

(* All shell-outs redirect stderr to /dev/null. Failures are expected
   (missing git binary, not-a-git-repo, missing sha256sum); they must
   not leak diagnostic noise to the launcher's tty. *)
let sha256_file path =
  let cmd =
    Printf.sprintf "sha256sum %s 2>/dev/null" (Filename.quote path)
  in
  match first_line_of_process cmd with
  | None -> None
  | Some line ->
      (* "<64 hex>  <path>" — keep just the hash. *)
      if String.length line >= 64 then Some (String.sub line 0 64)
      else None

let git_rev_in path =
  let cmd =
    Printf.sprintf "cd %s 2>/dev/null && git rev-parse HEAD 2>/dev/null"
      (Filename.quote path)
  in
  first_line_of_process cmd

let git_dirty_in path =
  let cmd =
    Printf.sprintf "cd %s 2>/dev/null && git status --porcelain 2>/dev/null"
      (Filename.quote path)
  in
  any_line_of_process cmd

let self_exe () =
  try Some (Unix.readlink "/proc/self/exe")
  with Unix.Unix_error _ -> None

let hostname () =
  try Unix.gethostname () with _ -> "unknown"

let username () =
  try (Unix.getpwuid (Unix.getuid ())).pw_name with _ -> "unknown"

(* ---- build / serialize / write ---- *)

let build ~id ~launch_cwd ~slot ~(source : Resolver.policy_source)
    ~(policy : Policy.t) =
  let policy_source_path, policy_source_sha256 =
    match source with
    | Default -> None, None
    | Override path -> Some path, sha256_file path
  in
  let flake_path =
    match Sys.getenv_opt "VM_LAUNCHER_FLAKE" with
    | Some s when s <> "" -> Some s
    | _ -> None
  in
  let flake_rev =
    match flake_path with
    | None -> None
    | Some p -> git_rev_in p
  in
  let flake_dirty =
    match flake_path with
    | None -> false
    | Some p -> git_dirty_in p
  in
  {
    id;
    slot;
    launched_at = iso8601_local ();
    launch_cwd;
    policy_source_path;
    policy_source_sha256;
    policy_json = Policy.to_json policy;
    flake_path;
    flake_rev;
    flake_dirty;
    vm_launcher_store_path = self_exe ();
    hostname = hostname ();
    user = username ();
    project = policy.project;
  }

let opt_json_str = function
  | None -> `Null
  | Some s -> `String s

let to_json (m : t) : Yojson.Safe.t =
  `Assoc [
    "id",                  `String m.id;
    "slot",                (match m.slot with
                            | Some i -> `Int i
                            | None -> `Null);
    "launched_at",         `String m.launched_at;
    "launch_cwd",          `String m.launch_cwd;
    "project",             `String m.project;
    "policy", `Assoc [
      "source_path",       opt_json_str m.policy_source_path;
      "source_sha256",     opt_json_str m.policy_source_sha256;
      "resolved_json",     m.policy_json;
    ];
    "flake", `Assoc [
      "path",              opt_json_str m.flake_path;
      "rev",               opt_json_str m.flake_rev;
      "dirty",             `Bool m.flake_dirty;
    ];
    "vm_launcher", `Assoc [
      "store_path",        opt_json_str m.vm_launcher_store_path;
    ];
    "host", `Assoc [
      "hostname",          `String m.hostname;
      "user",              `String m.user;
    ];
  ]

(* Post-build amendment: the runner store path + its nix closure size
   only exist once `nix build` has finished, which is after [write]
   already ran (the manifest must exist before the slow build so a
   crashed build still leaves a record). Re-read, splice the "runner"
   block in, rename over — same atomicity story as [write]. Best-
   effort throughout: a manifest that can't be amended is a forensic
   gap, never a boot failure. *)
let record_runner ~xdg_state_home ~id ~store_path ~closure_bytes =
  try
    let manifest_path =
      Printf.sprintf "%s/microvm/sessions/%s/manifest.json"
        xdg_state_home id
    in
    match Yojson.Safe.from_file manifest_path with
    | `Assoc top ->
        let runner =
          `Assoc [
            "store_path", `String store_path;
            "closure_bytes",
              (match closure_bytes with
               | Some b -> `Int b
               | None -> `Null);
          ]
        in
        let top = List.remove_assoc "runner" top @ [ "runner", runner ] in
        let json = Yojson.Safe.pretty_to_string (`Assoc top) in
        let tmp = manifest_path ^ ".tmp" in
        Util.write_file ~perm:0o644 tmp (json ^ "\n");
        Unix.rename tmp manifest_path
    | _ -> ()
  with _ -> ()

(* Replace any existing symlink at [link] with one pointing at [target].
   Atomic via rename. *)
let force_symlink ~target ~link =
  let tmp = link ^ ".tmp" in
  (try Unix.unlink tmp with _ -> ());
  Unix.symlink target tmp;
  (try Unix.unlink link with _ -> ());
  Unix.rename tmp link

let write ~xdg_state_home ~project_state_dir (m : t) =
  let global_dir =
    Printf.sprintf "%s/microvm/sessions/%s" xdg_state_home m.id
  in
  Util.mkdir_p ~perm:0o755 global_dir;
  let manifest_path = global_dir ^ "/manifest.json" in
  let json = Yojson.Safe.pretty_to_string (to_json m) in
  (* Atomic: write to a sibling tmpfile, then rename over. Without
     this, a reader catching the file mid-write would see a half-
     emitted JSON document. Same trick as [force_symlink] below. *)
  let tmp = manifest_path ^ ".tmp" in
  Util.write_file ~perm:0o644 tmp (json ^ "\n");
  Unix.rename tmp manifest_path;
  (* Per-project symlink: <project state_dir>/sessions/<id> → global. *)
  match project_state_dir with
  | None -> ()
  | Some dir when dir = "" -> ()
  | Some dir ->
      let proj_sessions = dir ^ "/sessions" in
      Util.mkdir_p ~perm:0o700 proj_sessions;
      force_symlink ~target:global_dir
        ~link:(proj_sessions ^ "/" ^ m.id)
