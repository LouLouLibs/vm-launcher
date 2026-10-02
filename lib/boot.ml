let log fmt = Util.log_info fmt
let log_phase fmt = Util.log_phase fmt

(* VM_LAUNCHER_VERBOSE=1 restores the per-share virtiofsd lines (one per
   mount) that the staging phase otherwise collapses into a single
   count. Out-of-band env rail, like VM_LAUNCHER_FAST / _SLOT — a
   transient debugging knob, not project policy. *)
let verbose () = Sys.getenv_opt "VM_LAUNCHER_VERBOSE" = Some "1"

(* OCaml's Sys.sig* constants are negative implementation-internal
   numbers (Sys.sigterm = -11, sigkill = -7, ...) — handed back as-is
   by Unix.WSIGNALED. To produce conventional shell exit codes
   (128 + POSIX_signo) and human-readable error messages, translate. *)
let posix_signo_of_ocaml n =
  if      n = Sys.sighup  then 1
  else if n = Sys.sigint  then 2
  else if n = Sys.sigquit then 3
  else if n = Sys.sigill  then 4
  else if n = Sys.sigabrt then 6
  else if n = Sys.sigfpe  then 8
  else if n = Sys.sigkill then 9
  else if n = Sys.sigsegv then 11
  else if n = Sys.sigpipe then 13
  else if n = Sys.sigalrm then 14
  else if n = Sys.sigterm then 15
  else 0  (* unknown — caller decides what to report *)

let exit_code_of_signal ocaml_signo =
  let p = posix_signo_of_ocaml ocaml_signo in
  if p = 0 then 128 else 128 + p

let chmod_quiet path perm =
  try Unix.chmod path perm with Unix.Unix_error _ -> ()

(* --- 1. host-side path prep --- *)

(* Pre-create host paths the guest mount layout needs, and — for
   auth = Bind — resolve the host config dir ($HOME/<config_dir>) from
   $HOME and return the policy with [agent.config_host] set, so the
   guest's config bind mounts the ACTUAL operator's home instead of a
   hardcoded path. *)
(* Every agent owns a namespace under the state dir: <state_dir>/<name>/.
   Flat entries predate multi-agent sessions — claude and codex BOTH keep
   a history.jsonl, so a shared flat layout would have them clobber each
   other. Move what this agent declares into its namespace, once; entries
   already migrated (or never present) are left alone. *)
let migrate_flat_state ~state_dir ~ns (a : Policy.agent) =
  let entries =
    a.state_dirs @ a.state_files @ a.home_state_files @ a.sync_files
    @ (if a.task_dir = "" then [] else [ a.task_dir ])
  in
  List.iter
    (fun entry ->
      let flat = state_dir ^ "/" ^ entry and nested = ns ^ "/" ^ entry in
      if Sys.file_exists flat && not (Sys.file_exists nested) then begin
        Util.mkdir_p ~perm:0o700 (Filename.dirname nested);
        (* Best-effort: a cross-device or permission failure leaves the
           flat copy in place rather than aborting the boot. *)
        try Sys.rename flat nested with Sys_error _ -> ()
      end)
    entries

let prepare_host_paths (p : Policy.t) : Policy.t =
  let agents = Policy.agents p in
  (match p.state_dir with
   | None -> ()
   | Some state_dir ->
       Util.mkdir_p ~perm:0o700 state_dir;
       chmod_quiet state_dir 0o700;
       List.iter
         (fun (a : Policy.agent) ->
           let ns = state_dir ^ "/" ^ a.name in
           migrate_flat_state ~state_dir ~ns a;
           Util.mkdir_p ~perm:0o700 ns;
           chmod_quiet ns 0o700;
           if a.task_dir <> "" then begin
             Util.mkdir_p ~perm:0o700 (ns ^ "/" ^ a.task_dir);
             chmod_quiet (ns ^ "/" ^ a.task_dir) 0o700
           end)
         agents);
  if p.auth <> Policy.Bind then p
  else begin
    let home = try Sys.getenv "HOME" with Not_found -> "" in
    (* The guest nests a RW [vmtasks] share at <config_guest>/<task_dir>,
       inside the RO config bind. The mountpoint must already exist on
       the host side (the guest can't mkdir into the RO bind), so we
       pre-create it under $HOME/<config_dir>/. We also need $HOME to
       resolve the config bind's source at all. Empty HOME with auth=Bind
       would silently skip that pre-creation and the guest's nested
       mount would fail with no diagnostic on the host — hard-fail
       instead. *)
    if home = "" then
      failwith
        "auth = bind requires $HOME to be set so the agent config dir \
         can be resolved and its task-tracker nest pre-created \
         (mount-point inside the RO config bind)";
    let prepare_agent (a : Policy.agent) : Policy.agent =
      let config_host = home ^ "/" ^ a.config_dir in
      (* The config bind's SOURCE must exist before virtiofsd opens it.
         A first codex run on a host that never ran codex would otherwise
         fail the mount instead of just starting empty. *)
      Util.mkdir_p ~perm:0o700 config_host;
      if a.task_dir <> "" then
        Util.mkdir_p ~perm:0o700 (config_host ^ "/" ^ a.task_dir);
      (match p.state_dir with
       | Some sd ->
           (* Seed each home-state file (e.g. .claude.json) from the host
              into the agent's state namespace on first run so login
              persists. *)
           List.iter
             (fun f ->
               let src = home ^ "/" ^ f in
               let dst = sd ^ "/" ^ a.name ^ "/" ^ f in
               if (not (Sys.file_exists dst)) && Sys.file_exists src then
                 Util.copy_file ~perm:0o600 src dst)
             a.home_state_files
       | None -> ());
      { a with config_host = Some config_host }
    in
    {
      p with
      agent = prepare_agent p.agent;
      extra_agents = List.map prepare_agent p.extra_agents;
    }
  end

(* --- 2. nix build the runner --- *)

(* Build a child env from the current process env by stripping any
   entries for the given keys, then appending the new key=value pairs.
   Idempotent over duplicate keys in [overrides]. *)
let env_with overrides =
  let prefixes = List.map (fun (k, _) -> k ^ "=") overrides in
  Unix.environment ()
  |> Array.to_seq
  |> Seq.filter (fun s ->
    not (List.exists (fun p -> String.starts_with ~prefix:p s) prefixes))
  |> Array.of_seq
  |> fun base ->
    Array.append base
      (Array.of_list (List.map (fun (k, v) -> k ^ "=" ^ v) overrides))

let nix_build_runner ?(fast = false) ~slot ~flake ~policy_json () =
  (* Targets nixosConfigurations.vmLauncher — the guest the
     flake exposes (nix/guest/_guest.nix: drops sudo,
     reads agent-secrets/, runs vm-egress-proxy, substitutes
     policy.guest.{hostname,username}).
     VM_LAUNCHER_NIXOS_CONFIG overrides for local testing. *)
  let attr =
    Printf.sprintf "%s#nixosConfigurations.%s.config.microvm.declaredRunner"
      flake (Util.nixos_config_attr ())
  in
  (* VM_LAUNCHER_FAST=1 only when --fast was passed. The guest's
     _guest.nix reads it with builtins.getEnv; absent ↔ "" ↔ default
     (single-threaded, smaller image, slower build). *)
  (* VM_LAUNCHER_SLOT: the network slot this session holds (see
     Session.acquire_slot). The guest derives tap id / MAC / IP /
     gateway / vmcfg-share path from it — same out-of-band getEnv
     rail as VM_LAUNCHER_FAST. *)
  let env =
    env_with (
      ("VM_LAUNCHER_POLICY_JSON", policy_json)
      :: ("VM_LAUNCHER_SLOT", string_of_int slot)
      :: (if fast then [ "VM_LAUNCHER_FAST", "1" ] else []))
  in
  let status, out =
    Util.subprocess_capture_stdout
      ~env
      ~prog:"nix"
      ~args:[| "nix"; "build"; "--impure"; "--no-link"; "--print-out-paths"; attr |]
      ()
  in
  match status with
  | Unix.WEXITED 0 ->
      let out = Util.trim_trailing_newline out in
      if out = "" then failwith "nix build produced empty output"
      else if not (Sys.file_exists (out ^ "/bin/microvm-run")) then
        failwith
          (Printf.sprintf
             "nix build succeeded but no microvm-run in '%s'" out)
      else out
  | Unix.WEXITED n ->
      failwith (Printf.sprintf "nix build exited with rc=%d" n)
  | Unix.WSIGNALED n ->
      failwith
        (Printf.sprintf "nix build killed by signal %d" (posix_signo_of_ocaml n))
  | Unix.WSTOPPED _ -> failwith "nix build stopped"

(* Closure size of a store path via `nix path-info -S --json`. The
   JSON shape moved between nix releases (list of objects vs object
   keyed by path), so don't pin a layout — walk the tree for the
   first "closureSize" int. [None] on any failure: the size feeds a
   forensic manifest field, not the boot. *)
let rec find_closure_size (j : Yojson.Safe.t) =
  match j with
  | `Assoc kvs ->
      (match List.assoc_opt "closureSize" kvs with
       | Some (`Int n) -> Some n
       | Some (`Intlit s) -> int_of_string_opt s
       | _ -> List.find_map (fun (_, v) -> find_closure_size v) kvs)
  | `List l -> List.find_map find_closure_size l
  | _ -> None

let nix_closure_size ~store_path =
  let status, out =
    Util.subprocess_capture_stdout
      ~stdin_dev_null:true
      ~prog:"nix"
      ~args:[| "nix"; "path-info"; "-S"; "--json"; store_path |]
      ()
  in
  match status with
  | Unix.WEXITED 0 ->
      (try find_closure_size (Yojson.Safe.from_string out)
       with _ -> None)
  | _ -> None

(* --- 3. spawn virtiofsd --- *)

(* [detach]: put the daemon in its OWN session (setsid) before exec.
   Without it a hangup on the launching terminal reaches the whole
   process group, and a detached VM would lose its shares the moment the
   operator closes the window that started it. *)
let spawn_virtiofsd ~detach ~socket ~source ~read_only ~log_path =
  let base =
    [
      "virtiofsd";
      "--socket-path=" ^ socket;
      "--shared-dir=" ^ source;
      "--sandbox=none";
      "--cache=auto";
      "--xattr";
    ]
  in
  let args =
    Array.of_list (if read_only then base @ [ "--readonly" ] else base)
  in
  (* dev_null is opened first; if the log_path openfile raises (parent
     dir missing, EACCES, …), dev_null must still be closed.
     create_process'es own failures are equally covered. *)
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  Fun.protect
    ~finally:(fun () ->
      try Unix.close dev_null with Unix.Unix_error _ -> ())
    (fun () ->
      let log_fd =
        Unix.openfile log_path
          [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ]
          0o644
      in
      Fun.protect
        ~finally:(fun () ->
          try Unix.close log_fd with Unix.Unix_error _ -> ())
        (fun () ->
          if not detach then
            Unix.create_process "virtiofsd" args dev_null log_fd log_fd
          else
            (* fork + setsid + exec: same as create_process, plus its own
               session so a terminal hangup can't reach it. *)
            match Unix.fork () with
            | 0 ->
                (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
                Unix.dup2 dev_null Unix.stdin;
                Unix.dup2 log_fd Unix.stdout;
                Unix.dup2 log_fd Unix.stderr;
                (try Unix.execvp "virtiofsd" args with _ -> exit 127)
            | pid -> pid))

(* --- 4. wait for sockets --- *)

let socket_exists path =
  try (Unix.stat path).st_kind = Unix.S_SOCK
  with Unix.Unix_error _ -> false

let wait_for_sockets sockets ~timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if List.for_all socket_exists sockets then ()
    else if Unix.gettimeofday () >= deadline then
      failwith
        (Printf.sprintf
           "virtiofsd sockets did not all appear after %.0fs \
            (inspect <state>/virtiofsd-*.log for the failing tag)"
           timeout)
    else (
      Unix.sleepf 0.2;
      loop ())
  in
  loop ()

(* --- 5. run microvm-run --- *)

let run_microvm_run ~on_vm_pid ~session ~runner =
  (* cloud-hypervisor's own log goes to its stderr — the benign vmm
     chatter every launch ("signal already blocked", disk-image-type
     deprecation, sparse-unsupported, "tap already exists") drowns the
     rest of the boot. The INTERACTIVE guest console is on stdout
     (--console tty), so stderr carries no user-facing output: route it
     to a per-session cloud-hypervisor.log (same as virtiofsd's logs) to
     keep the boot terminal clean. The file has the full record if a
     launch fails. VM_LAUNCHER_VERBOSE=1 keeps it inline. *)
  let ch_stderr, owned =
    if verbose () then Unix.stderr, false
    else
      Unix.openfile (Session.state_dir session ^ "/cloud-hypervisor.log")
        [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ] 0o644,
      true
  in
  (* Block SIGINT/SIGTERM around create_process + register_child so a
     signal landing in that window can't run cleanup against a stale
     children list (which would orphan the just-spawned microvm-run).
     The kernel queues the signal; it fires once the mask is restored,
     at which point register_child has run. *)
  let pid =
    Session.with_signals_blocked [ Sys.sigint; Sys.sigterm ] (fun () ->
      let p =
        Unix.create_process (runner ^ "/bin/microvm-run")
          [| "microvm-run" |]
          Unix.stdin Unix.stdout ch_stderr
      in
      (* Register with SIGTERM-grace so launcher SIGTERM (Ctrl-C,
         external kill) gives cloud-hypervisor a chance to power off
         the guest cleanly — flushes vmm state, releases tap + vhost
         sockets, proper systemd shutdown inside the guest — before we
         SIGKILL. Already-dead pid (normal VM power-off path) is a
         harmless ESRCH that kill_pids swallows.

         Registration order also matters: register_child prepends, so
         microvm-run dies BEFORE its virtiofsds get SIGKILL'd —
         without that, virtiofsd death yanks the file shares out from
         under cloud-hypervisor's still-running guest. *)
      Session.register_child ~mode:(Sigterm_then_kill 5.0) session p;
      p)
  in
  (* Report the pid for the FOREGROUND path too. The VM's liveness is
     this process, not the launcher: if the launcher is killed, the
     guest keeps running, and anything that reasons about "is this
     session alive" from the launcher pid will be wrong — which is how
     `clean` could shred a live VM's shares. *)
  on_vm_pid ~pid;
  (* The child holds its own dup of the log fd; drop ours. *)
  if owned then (try Unix.close ch_stderr with Unix.Unix_error _ -> ());
  let _, status = Unix.waitpid [] pid in
  match status with
  | Unix.WEXITED n -> n
  | Unix.WSIGNALED n -> exit_code_of_signal n
  | Unix.WSTOPPED _ -> 1

(* Detached boot: the VM outlives the launcher.

   fork + setsid so the runner leaves the launcher's session entirely —
   otherwise closing the terminal would SIGHUP the VM. stdout/stderr go
   to console.log in the session dir (there is no terminal to write to),
   stdin to /dev/null.

   The child is deliberately NOT registered with the session: registered
   children are killed on launcher exit, which is exactly what a
   detached VM must survive. For the same reason the caller must keep
   the state dir — its virtiofsd sockets are still in use. *)
let spawn_detached ~session ~runner =
  let log_path = Session.state_dir session ^ "/console.log" in
  let log =
    Unix.openfile log_path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644
  in
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0o644 in
  match Unix.fork () with
  | 0 ->
      (* Child: new session, so no controlling terminal to be hung up. *)
      (try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ());
      Unix.dup2 devnull Unix.stdin;
      Unix.dup2 log Unix.stdout;
      Unix.dup2 log Unix.stderr;
      (try
         Unix.execv (runner ^ "/bin/microvm-run") [| "microvm-run" |]
       with _ -> exit 127)
  | pid ->
      (try Unix.close log with Unix.Unix_error _ -> ());
      (try Unix.close devnull with Unix.Unix_error _ -> ());
      pid

(* --- entry point --- *)

let run ?(fast = false) ?(detach = false)
    ?(on_vm_pid = fun ~pid:_ -> ())
    ?(on_runner = fun ~store_path:_ ~closure_bytes:_ -> ())
    ~session ~policy ~flake () =
  (* policy.tools maps 1:1 onto pkgs.${n} in the guest's _guest.nix.
     A bad name fails deep inside nix build with a pointer to that
     file (not to the user's microvm.ncl). Pre-check against raw
     nixpkgs so the launcher surfaces the offending attr by name
     before anything expensive runs. Best-effort: any failure of the
     check itself is logged and skipped \xe2\x80\x94 nix build is the
     fallback. *)
  Validate.tools ~flake ~tools:policy.Policy.tools;

  (* memMb > host RAM boots fine (guest pages fault in lazily) and
     then gets cloud-hypervisor OOM-killed mid-run once the workload
     touches more memory than the host can back. Catch it up front. *)
  Validate.host_memory ~mem_mb:policy.Policy.resources.mem_mb ();

  (* A work.readOnly / inputs / shares source pointing at a regular
     file (not a directory) passes existence checks but fails the
     guest virtiofs mount, dropping the VM into a locked-root
     emergency-mode hang with no host-visible diagnostic. Catch it
     here — a pure host-path property of the policy — before the
     multi-GB build + boot. *)
  Validate.share_sources ~project:policy.Policy.project
    ~read_only:policy.Policy.work.read_only ~inputs:policy.Policy.inputs
    ~shares:policy.Policy.shares;

  let policy = prepare_host_paths policy in

  let policy_json_path = Session.state_dir session ^ "/policy.json" in
  Stage.policy_json ~path:policy_json_path policy;

  let slot =
    match Session.slot session with
    | Some i -> i
    | None ->
      invalid_arg "Boot.run: no network slot allocated (acquire_slot first)"
  in
  log_phase "building guest closure...";
  let runner =
    nix_build_runner ~fast ~slot ~flake ~policy_json:policy_json_path ()
  in
  (* Hand the built runner back to the caller (main.ml records it +
     its closure size into the session manifest for `ls`'s SIZE
     column). Best-effort: a failed path-info or callback must not
     stop the boot. *)
  (try on_runner ~store_path:runner
         ~closure_bytes:(nix_closure_size ~store_path:runner)
   with _ -> ());

  (* cloud-hypervisor opens virtiofs sockets by RELATIVE path, so cwd
     must be the per-session state dir before any virtiofsd starts. *)
  Sys.chdir (Session.state_dir session);

  let entries = Shares.read_manifest ~runner in
  if entries = [] then
    failwith
      (Printf.sprintf
         "empty share manifest at %s/share/microvm/virtiofs — the \
          runner closure shipped no virtiofs shares. Either the guest \
          config (_guest.nix) is malformed or the build wrote into an \
          unexpected layout. Booting with no shares would hang \
          cloud-hypervisor for 60s and fail."
         runner);
  let ro = Shares.ro_tags policy in
  let is_ro tag = List.mem tag ro in
  (* Flip current-session-<slot> AFTER the build: a failed build never
     repoints the symlink. Per-slot symlinks mean
     sessions in different slots cannot race each other here — the
     v0.1.x boot.lock that serialized this window is retired.

     The share-source existence check stays AFTER the flip: the vmcfg
     share's source is /run/vm-launcher/current-session-<slot>/etc,
     which only exists once set_as_current has run. *)
  Session.set_as_current session;
  List.iter
    (fun (e : Shares.manifest_entry) ->
      if not (Sys.file_exists e.source) then
        failwith
          (Printf.sprintf
             "share '%s' source does not exist: %s \
              (check work.readOnly / inputs in your microvm.ncl)"
             e.tag e.source)
      (* Backstop for Validate.share_sources: that pre-build check
         works off the policy's raw paths; this one catches any
         non-directory source the resolved manifest surfaces (e.g.
         a share whose host path the pre-build resolver couldn't
         reconstruct). virtiofs serves a directory tree, so a file
         source would fail the guest mount and hang the VM in
         emergency mode. *)
      else if not (Sys.is_directory e.source) then
        failwith
          (Printf.sprintf
             "share '%s' source is not a directory: %s — work.readOnly \
              / inputs / shares entries must be directories (virtiofs \
              shares a directory tree; a file there fails the guest \
              mount and drops the VM into a locked-root emergency-mode \
              hang)."
             e.tag e.source))
    entries;
  (* One summary line instead of N near-identical "starting virtiofsd"
     lines (a share-heavy project mounts a dozen+, drowning the rest of
     the launch log). VM_LAUNCHER_VERBOSE=1 restores per-share detail. *)
  let verbose = verbose () in
  let total = List.length entries in
  let ro_count =
    List.length (List.filter (fun (e : Shares.manifest_entry) -> is_ro e.tag) entries)
  in
  log_phase "staging %d virtiofs share%s (%d read-write, %d read-only)"
    total (if total = 1 then "" else "s") (total - ro_count) ro_count;
  List.iter
    (fun (e : Shares.manifest_entry) ->
      let read_only = is_ro e.tag in
      let log_path =
        Session.state_dir session ^ "/virtiofsd-" ^ e.tag ^ ".log"
      in
      if verbose then
        log "  tag=%s source=%s%s" e.tag e.source
          (if read_only then " (readonly)" else "");
      (* Same spawn-vs-register race protection as run_microvm_run —
         a SIGTERM landing between create_process and register_child
         would orphan the just-spawned virtiofsd; N shares = N
         windows. *)
      Session.with_signals_blocked [ Sys.sigint; Sys.sigterm ] (fun () ->
        let pid =
          spawn_virtiofsd ~detach ~socket:e.socket ~source:e.source
            ~read_only ~log_path
        in
        Session.register_child session pid))
    entries;
  let sockets =
    List.map (fun (e : Shares.manifest_entry) -> e.socket) entries
  in
  wait_for_sockets sockets ~timeout:10.0;

  if detach then begin
    log_phase "starting VM detached (runner=%s)" runner;
    let pid = spawn_detached ~session ~runner in
    on_vm_pid ~pid;
    (* Nothing to wait for: the VM is now independent of this process.
       rc 0 means "launched", not "the guest exited cleanly". *)
    0
  end
  else begin
    log_phase "starting VM (runner=%s)" runner;
    run_microvm_run ~on_vm_pid ~session ~runner
  end
