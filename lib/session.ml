type child_mode =
  | Sigkill
  | Sigterm_then_kill of float

type t = {
  pid : int;
  state_dir : string;
  etc_dir : string;
  state_base : string;
  children : (int * child_mode) list ref;
  (* Network slot (per-session networking), set by
     [acquire_slot] on the boot path; [None] for --show. *)
  slot : int option ref;
}

let pid t = t.pid
let state_dir t = t.state_dir
let etc_dir t = t.etc_dir
let slot t = !(t.slot)
(* Hand the session's children over to init: they must OUTLIVE the
   launcher. Used by the detached boot, where the virtiofsds keep
   serving a VM that is still running long after this process exits —
   cleanup's kill_pids would otherwise pull the shares out from under
   it, and cloud-hypervisor dies with "vhost-user: can't connect to
   peer". Reaping them later is `down`/`clean`'s job, via the pidfiles.

   Note this is about the KILL list only; keep_state governs the state
   dir, which a detached session also needs (its sockets live there). *)
let disown_children t = t.children := []

let register_child ?(mode = Sigkill) t p =
  t.children := (p, mode) :: !(t.children)

let rm_rf = Util.rm_rf

let sigkill pid = try Unix.kill pid Sys.sigkill with _ -> ()

let sigterm_then_kill pid timeout =
  (try Unix.kill pid Sys.sigterm with _ -> ());
  let deadline = Unix.gettimeofday () +. timeout in
  let rec poll () =
    if Unix.gettimeofday () >= deadline then sigkill pid
    else
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ -> Unix.sleepf 0.1; poll ()
      | _, _ -> ()  (* reaped *)
      | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> poll ()
  in
  poll ()

let kill_pids children =
  List.iter
    (fun (p, mode) ->
      match mode with
      | Sigkill -> sigkill p
      | Sigterm_then_kill t -> sigterm_then_kill p t)
    children

let current_link ~state_base ~slot =
  Printf.sprintf "%s/current-session-%d" state_base slot

let drop_current_if_ours ~state_base ~slot ~state_dir =
  match slot with
  | None -> ()
  | Some i ->
    let link = current_link ~state_base ~slot:i in
    (match (try Some (Unix.readlink link) with _ -> None) with
     | Some target when target = state_dir ->
         (try Unix.unlink link with _ -> ())
     | _ -> ())

let with_state ~state_base ~keep_state ~f =
  let pid = Unix.getpid () in
  let state_dir = Printf.sprintf "%s/session-%d" state_base pid in
  let etc_dir = state_dir ^ "/etc" in
  Util.mkdir_p etc_dir;
  let children = ref [] in
  let t = { pid; state_dir; etc_dir; state_base; children; slot = ref None } in

  let cleanup_done = ref false in
  let cleanup () =
    if !cleanup_done then ()
    else begin
      cleanup_done := true;
      kill_pids !children;
      if not keep_state then begin
        rm_rf state_dir;
        drop_current_if_ours ~state_base ~slot:!(t.slot) ~state_dir
      end
    end
  in

  let prev_int = Sys.signal Sys.sigint
    (Sys.Signal_handle (fun _ -> cleanup (); exit 130)) in
  let prev_term = Sys.signal Sys.sigterm
    (Sys.Signal_handle (fun _ -> cleanup (); exit 143)) in

  Fun.protect
    ~finally:(fun () ->
      Sys.set_signal Sys.sigint prev_int;
      Sys.set_signal Sys.sigterm prev_term;
      cleanup ())
    (fun () -> f t)

(* --- Network slot pool (per-session networking) ---

   The host provisions one tap per slot (vm-tap<i>, the host's
   vm-launcher module); each slot owns its own subnet, MAC, and
   current-session-<i> symlink, so concurrent sessions share NO
   network identity. The pool is DISCOVERED, not configured: the set
   of vm-tap<i> devices on the host is the capacity. Launcher and
   host module therefore deploy independently — on an old host only
   vm-tap0 exists and the launcher behaves exactly like the v0.1.0
   one-session contract.

   A slot is held by a POSIX lock on <state_base>/slot-<i>.lock for
   the session's lifetime; the fd is deliberately never closed, the
   kernel drops the lock on ANY exit path (crashes included), so
   there is no stale-slot cleanup to get wrong. The holder's pid is
   written into the file purely for the queue diagnostic. All slots
   busy = queue: say who holds them, poll until one frees, continue
   automatically. *)

let discover_slots () =
  (* VM_LAUNCHER_SLOT_POOL="0 1" overrides discovery: the nix build
     sandbox has no taps (its checkPhase runs the CLI tests, which
     drive the real boot path up to the first nix call), and dev
     setups may want a fake pool. Production relies on discovery. *)
  match Sys.getenv_opt "VM_LAUNCHER_SLOT_POOL" with
  | Some s when String.trim s <> "" ->
    String.split_on_char ' ' s
    |> List.filter_map int_of_string_opt
    |> List.sort_uniq compare
  | _ ->
  let dir = "/sys/class/net" in
  match (try Some (Sys.readdir dir) with _ -> None) with
  | None -> []
  | Some entries ->
    Array.to_list entries
    |> List.filter_map (fun name ->
        if String.length name > 6 && String.sub name 0 6 = "vm-tap"
        then int_of_string_opt
               (String.sub name 6 (String.length name - 6))
        else None)
    |> List.sort compare

let slot_lock_path ~state_base i =
  Printf.sprintf "%s/slot-%d.lock" state_base i

(* "myproject.workdir (pid 2434684)" when the holder's staged
   policy.json is readable; degrades to pid-only / generic. The pid
   comes from the slot lock file (written under the lock); the
   project name from session-<pid>/policy.json. *)
let describe_slot_holder ~state_base i =
  let pid =
    try
      let ic = open_in (slot_lock_path ~state_base i) in
      let line = (try input_line ic with End_of_file -> "") in
      close_in ic;
      int_of_string_opt (String.trim line)
    with _ -> None
  in
  match pid with
  | None -> "another vm-launcher session"
  | Some p ->
    let project =
      try
        let json =
          Yojson.Safe.from_file
            (Printf.sprintf "%s/session-%d/policy.json" state_base p)
        in
        match Yojson.Safe.Util.member "project" json with
        | `String s when s <> "" -> Some (Filename.basename s)
        | _ -> None
      with _ -> None
    in
    (match project with
     | Some name -> Printf.sprintf "%s (pid %d)" name p
     | None -> Printf.sprintf "another vm-launcher session (pid %d)" p)

(* Detached sessions cannot hold their slot with the lock: fcntl
   locks are NOT inherited across fork, so the lock dies with the
   launcher while the VM keeps running — and the next launcher would
   hand out the same tap. Record the runner pid in a marker file
   instead; a slot whose marker names a live process is busy. The
   marker goes stale on its own when the VM exits, and is removed by
   the next launcher that looks. *)
let detached_marker_path ~state_base i =
  Printf.sprintf "%s/slot-%d.detached" state_base i

let mark_slot_detached ~state_base ~slot ~pid =
  Util.write_file (detached_marker_path ~state_base slot)
    (string_of_int pid ^ "\n")

let detached_holder ~state_base i =
  let path = detached_marker_path ~state_base i in
  match int_of_string_opt (String.trim (Util.read_file path)) with
  | exception _ -> None
  | None -> None
  | Some pid ->
      let alive = try Unix.kill pid 0; true with
        | Unix.Unix_error (Unix.EPERM, _, _) -> true
        | _ -> false
      in
      if alive then Some pid
      else begin
        (* Stale: the detached VM is gone, so the slot is free again. *)
        (try Sys.remove path with Sys_error _ -> ());
        None
      end

let try_take_slot ~state_base i =
  let fd =
    Unix.openfile (slot_lock_path ~state_base i)
      [ Unix.O_RDWR; Unix.O_CREAT ] 0o644
  in
  try
    Unix.lockf fd Unix.F_TLOCK 0;
    (* Check and prune markers under the same lock the launching process
       holds while publishing its detached runner. Checking before the
       lock can miss the handoff immediately before that launcher exits. *)
    match detached_holder ~state_base i with
    | Some _ -> Unix.close fd; false
    | None ->
    ignore (Unix.ftruncate fd 0);
    let pid = string_of_int (Unix.getpid ()) ^ "\n" in
    ignore (Unix.write_substring fd pid 0 (String.length pid));
    (* fd deliberately kept open: the slot is held until exit. *)
    true
  with Unix.Unix_error ((Unix.EAGAIN | Unix.EACCES), _, _) ->
    (try Unix.close fd with _ -> ());
    false

let acquire_slot ?slots t =
  let slots =
    match slots with Some s -> s | None -> discover_slots ()
  in
  if slots = [] then
    failwith
      "no vm-tap<N> network devices found on this host — the \
       host's vm-launcher NixOS module provisions the slot pool; is \
       it active?";
  let try_all () =
    List.find_opt (try_take_slot ~state_base:t.state_base) slots
  in
  let taken =
    match try_all () with
    | Some i -> i
    | None ->
      (* Status, not scolding: queueing at capacity is the normal
         way to start one session more than the host has slots. *)
      let holders =
        slots
        |> List.map (describe_slot_holder ~state_base:t.state_base)
        |> String.concat ", "
      in
      (match slots with
       | [ _ ] ->
         Util.log_warn
           "queued — %s is running, and this host has one network slot."
           holders
       | _ ->
         Util.log_warn
           "queued — all %d network slots are busy (%s)."
           (List.length slots) holders);
      Util.log_info
        "this session starts automatically when a slot frees. Ctrl-C to cancel.";
      let rec poll () =
        match try_all () with
        | Some i ->
          Util.log_info "network slot %d freed — starting this session." i;
          i
        | None -> Unix.sleepf 0.5; poll ()
      in
      poll ()
  in
  if List.length slots > 1 then
    Util.log_info "network slot %d (of %d)" taken (List.length slots);
  t.slot := Some taken;
  taken

let set_as_current t =
  let slot =
    match !(t.slot) with
    | Some i -> i
    | None -> invalid_arg "Session.set_as_current: no slot allocated"
  in
  let link = current_link ~state_base:t.state_base ~slot in
  let tmp = link ^ ".tmp" in
  (try Unix.unlink tmp with Unix.Unix_error _ -> ());
  Unix.symlink t.state_dir tmp;
  Unix.rename tmp link

let with_signals_blocked sigs f =
  let prev = Unix.sigprocmask Unix.SIG_BLOCK sigs in
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.sigprocmask Unix.SIG_SETMASK prev))
    f
