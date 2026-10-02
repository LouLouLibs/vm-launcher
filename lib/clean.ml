(* vm-launcher clean — delete finished sessions.

   Per session ID, three artifacts can exist; clean removes whichever
   are present:
     - <xdg>/microvm/sessions/<id>/        the global registry dir
     - <project stateDir>/sessions/<id>    the per-project symlink
     - <state_base>/session-<pid>/         a leftover live state dir
                                           ("stale": the launcher pid
                                           is dead but teardown never
                                           ran — SIGKILL, host crash,
                                           or --keep-state)
   plus any current-session-<i> symlink still pointing at that state
   dir, and any orphaned virtiofsds the state dir's pidfiles name.

   Running sessions (live state dir + alive pid) are never touched.

   What this does NOT reclaim: the guest image closure in /nix/store.
   It's shared between sessions built from the same config and owned
   by nix — `nix store gc` is the lever there. *)

let registry_dir ~xdg_state_home id =
  Printf.sprintf "%s/microvm/sessions/%s" xdg_state_home id

(* The per-project symlink Session_manifest.write dropped at
   <stateDir>/sessions/<id>. The stateDir is only recorded inside the
   manifest itself (policy.resolved_json.stateDir) — read it back
   before the manifest goes away. Any parse failure degrades to None:
   the symlink then dangles, which `ls` never follows, so it's
   cosmetic debris rather than breakage. *)
let project_symlink ~manifest_path ~id =
  let json =
    try Some (Yojson.Safe.from_file manifest_path) with _ -> None
  in
  match json with
  | Some (`Assoc top) ->
      (match List.assoc_opt "policy" top with
       | Some (`Assoc p) ->
           (match List.assoc_opt "resolved_json" p with
            | Some (`Assoc rj) ->
                (match List.assoc_opt "stateDir" rj with
                 | Some (`String d) when d <> "" ->
                     Some (d ^ "/sessions/" ^ id)
                 | _ -> None)
            | _ -> None)
       | _ -> None)
  | _ -> None

(* Only ever unlink an actual symlink — a regular file or dir at the
   expected link path means something else owns it; leave it alone. *)
let unlink_if_symlink path =
  match (try Some (Unix.lstat path) with _ -> None) with
  | Some { Unix.st_kind = Unix.S_LNK; _ } ->
      (try Unix.unlink path with _ -> ())
  | _ -> ()

let readdir_opt path =
  try Some (Sys.readdir path) with _ -> None

(* A SIGKILL'd launcher never reaps its virtiofsds; they get
   reparented and keep running with the share fds open. Each one
   wrote <state>/<name>.sock.pid at startup — read those back and
   SIGKILL, but only pids whose /proc cmdline really is virtiofsd:
   the pid may have been recycled by an unrelated process since. *)
let pid_is_virtiofsd pid =
  match Util.read_proc_opt (Printf.sprintf "/proc/%d/cmdline" pid) with
  | None -> false
  | Some c ->
      let argv0 =
        match String.index_opt c '\000' with
        | Some i -> String.sub c 0 i
        | None -> c
      in
      Filename.basename argv0 = "virtiofsd"

let kill_leftover_virtiofsds state_dir =
  match readdir_opt state_dir with
  | None -> ()
  | Some entries ->
      Array.iter
        (fun name ->
          if Filename.check_suffix name ".sock.pid" then
            match Util.read_file_opt (Filename.concat state_dir name) with
            | None -> ()
            | Some s ->
                (match int_of_string_opt (String.trim s) with
                 | Some pid when pid > 1 && pid_is_virtiofsd pid ->
                     (try Unix.kill pid Sys.sigkill with _ -> ())
                 | _ -> ()))
        entries

(* Drop every current-session-<i> symlink that resolves to the state
   dir being removed — a dangling one would feed the NEXT session of
   that slot a nonexistent vmcfg share source. Only links pointing at
   [target] go; a concurrent session's link points elsewhere. *)
let drop_current_symlinks ~state_base ~target =
  match readdir_opt state_base with
  | None -> ()
  | Some entries ->
      Array.iter
        (fun name ->
          if String.length name >= 15
             && String.sub name 0 15 = "current-session"
          then
            let link = Filename.concat state_base name in
            match (try Some (Unix.readlink link) with _ -> None) with
            | Some t when t = target -> unlink_if_symlink link
            | _ -> ())
        entries

let clean_one ~xdg_state_home ~state_base ~live_by_id id =
  if id = "" || id = "." || id = ".." || String.contains id '/'
     || String.contains id '\000' then
    Error (Printf.sprintf "%S: invalid session ID" id)
  else
  let reg = registry_dir ~xdg_state_home id in
  let reg_exists = Sys.file_exists reg in
  let live = Hashtbl.find_opt live_by_id id in
  match live with
  | Some pid when Ls.process_alive pid ->
      Error (Printf.sprintf "%s is running (pid %d) — not cleaned" id pid)
  | Some pid when Ls.runner_alive ~state_base ~pid ->
      Error
        (Printf.sprintf
           "%s: its VM is still running — not cleaned. Stop it first \
            (`vm-launcher down %s`, or Ctrl-D in its own terminal if it \
             is in the foreground)" id id)
  | _ ->
      if (not reg_exists) && live = None then
        Error (Printf.sprintf "%s: no such session" id)
      else begin
        (match live with
         | Some pid ->
             let sdir = Printf.sprintf "%s/session-%d" state_base pid in
             kill_leftover_virtiofsds sdir;
             drop_current_symlinks ~state_base ~target:sdir;
             Util.rm_rf sdir
         | None -> ());
        (* Symlink before registry dir — its target path comes out of
           the manifest we're about to delete. *)
        (match project_symlink ~manifest_path:(reg ^ "/manifest.json") ~id with
         | Some link -> unlink_if_symlink link
         | None -> ());
        if reg_exists then Util.rm_rf reg;
        Ok ()
      end

let run ~xdg_state_home ~state_base ~ids ~exited =
  let live = Ls.live_sessions state_base in
  let live_by_id = Hashtbl.create (List.length live) in
  List.iter (fun (pid, id) -> Hashtbl.replace live_by_id id pid) live;
  let ids =
    if not exited then ids
    else begin
      (* --exited: every known session (registry ∪ leftover state
         dirs) whose pid is gone. Running ones are filtered out here,
         so the bulk path can't trip the is-running refusal. *)
      let reg_ids =
        match
          readdir_opt (Printf.sprintf "%s/microvm/sessions" xdg_state_home)
        with
        | None -> []
        | Some a -> Array.to_list a
      in
      let dead_live = List.map snd live in
      List.sort_uniq String.compare (reg_ids @ dead_live)
      |> List.filter (fun id ->
           match Hashtbl.find_opt live_by_id id with
           | Some pid ->
               not (Ls.process_alive pid)
               && not (Ls.runner_alive ~state_base ~pid)
           | None -> true)
    end
  in
  if ids = [] then begin
    print_endline "nothing to clean";
    0
  end
  else begin
    let rc = ref 0 in
    List.iter
      (fun id ->
        match clean_one ~xdg_state_home ~state_base ~live_by_id id with
        | Ok () -> Printf.printf "cleaned %s\n" id
        | Error msg ->
            Util.log_error "%s" msg;
            rc := 1)
      ids;
    !rc
  end
