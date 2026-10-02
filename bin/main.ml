open Vm_launcher_lib

let show_only = ref false
let detach = ref false
(* --console: the old foreground mode — this terminal IS the guest's
   console, and logging out of it powers the VM off. *)
let console = ref false
(* Set when a plain launch on a terminal boots detached and then attaches
   this terminal over ssh, so logging out leaves the VM running. *)
let auto_attach = ref false
let keep_state = ref false
let fast = ref false
let policy_override : string option ref = ref None

(* Operator-only network-posture override. The checked-in microvm.ncl
   can never reach [Unrestricted] on its own (see Policy.egress_mode) —
   only this CLI flag can lift the fence, so a partly-untrusted project
   policy can't silently turn egress filtering off. [None] = honor the
   policy's own posture (Allowlist, or Airgap when egress.none=true). *)
let egress_override : Policy.egress_mode option ref = ref None

(* Per-session state base. /run/vm-launcher in production (an
   user-owned tmpfile rule in the host's NixOS configuration); overridable
   via VM_LAUNCHER_STATE_BASE so the CLI test suite can point at a
   tempdir without root. *)
let state_base =
  match Sys.getenv_opt "VM_LAUNCHER_STATE_BASE" with
  | Some s when s <> "" -> s
  | _ -> "/run/vm-launcher"

let help_text =
  {|vm-launcher: run coding agents inside a per-session NixOS microVM.

Usage:
  vm-launcher [--policy PATH] [--detach | --console] [--egress MODE] [--show]
              [--keep-state] [--fast]
                            launch a VM (default). --detach leaves it
                            running and hands the terminal back.
  vm-launcher attach [ID]   open a shell in a running detached VM (ssh over
                            the host-only tap network). Without ID: the
                            running VM for this project, or the only one.
  vm-launcher down [ID]     power off a detached VM and release its slot
  vm-launcher ls [--all]    list sessions (newest 10; --all for everything)
  vm-launcher clean ID...   delete finished sessions by ID (registry
                            entry, per-project symlink, and any stale
                            /run state dir + orphaned virtiofsds);
                            refuses running sessions
  vm-launcher clean --exited
                            delete every session that is not running
                            (states "exited" and "stale")

Flags (launch only):
  --policy PATH read the Nickel contract from PATH. PATH may live anywhere
                — the binary makes no assumption about layout. Without
                --policy the launcher auto-discovers a policy under the
                project root (envs/vm/microvm.ncl, then env/, environments/,
                environment/ variants; then any *.ncl in those dirs). If
                none exists a built-in default policy is used. The resolved
                policy is exposed to the guest at
                /etc/vm-launcher/microvm-loaded.{ncl,json}.
  --egress MODE override the network posture (operator-only; a project
                policy can never lift the fence itself):
                  fenced     (default) in-guest MITM proxy + nftables
                             allowlist. The guest reaches only the hosts in
                             egress.hosts. Shown as 🛡 everywhere.
                  unfenced   NO fence: direct internet via NAT, no proxy,
                             no allowlist, no MITM CA. For a trusted job,
                             to bisect the proxy, or a plain VM. 🌐
                  airgap     no network egress at all. ⛔
                The former spellings (allowlist / noblock / block) are
                still accepted.
  (default)     on a terminal: boot the VM detached, then attach this terminal
                to it over ssh. Logging out (Ctrl-D) leaves the VM running
                and prints how to reattach or stop it. Without a terminal
                (scripts, CI) the launcher owns the VM as before.
  --console     make this terminal the VM's console instead (the older
                foreground mode): logging out of it powers the VM off.
  --detach      boot the VM and return to the prompt instead of taking over
                the terminal. The guest runs headless (no console login) and
                you reach it with `vm-launcher attach`, from as many
                terminals as you like; it lives until `vm-launcher down`.
                Implies --keep-state: the session dir holds the ssh keys
                and the virtiofsd sockets the VM is still using.
  --show        print the resolved policy + egress posture; exit
  --keep-state  preserve /run/vm-launcher/session-<pid>/ after exit (debugging)
  --fast        drop mkfs.erofs's single-threaded -Efragments/-Ededupe
                flags so the guest store-disk build uses all cores.
                ~10-30% larger image, but the build runs ~2-4x faster
                on a multi-core box. Fast and non-fast images don't
                share Nix cache (different env -> different drv hash).

Environment:
  VM_LAUNCHER_FLAKE  path to the flake exporting
                   nixosConfigurations.vmLauncher (this repo, or a
                   site flake built with mkGuest). Required for boot; unused
                   for --show.
|}

let print_help_and_exit () =
  print_string help_text;
  exit 0

let speclist =
  [
    "--show", Arg.Set show_only, " print the resolved policy + egress allowlist; exit";
    "--keep-state", Arg.Set keep_state, " preserve the session state dir after exit";
    "--detach", Arg.Set detach,
      " boot headless and return to the prompt; reach it with `vm-launcher attach`";
    "--console", Arg.Set console,
      " this terminal is the VM's console; logging out powers it off";
    "--fast", Arg.Set fast, " multi-threaded mkfs.erofs (faster build, ~10-30% larger image)";
    "--policy",
      Arg.String (fun p -> policy_override := Some p),
      "PATH read the Nickel contract from PATH";
    "--egress",
      Arg.String (fun v ->
        let m =
          match v with
          | "fenced" | "allowlist" -> Policy.Allowlist
          | "unfenced" | "noblock" -> Policy.Unrestricted
          | "airgap" | "block" -> Policy.Airgap
          | _ ->
              Util.log_error
                "--egress: expected 'fenced', 'unfenced' or 'airgap' \
                 (or the former allowlist/noblock/block), got %S" v;
              exit 2
        in
        egress_override := Some m),
      "MODE override egress posture: fenced (default) | unfenced \
       (UNFENCED — direct internet) | airgap (no network)";
    "--help", Arg.Unit print_help_and_exit, " show this help and exit";
    "-h", Arg.Unit print_help_and_exit, " show this help and exit";
  ]

let xdg_state_home () =
  try Sys.getenv "XDG_STATE_HOME"
  with Not_found -> (
    try Sys.getenv "HOME" ^ "/.local/state" with Not_found -> "/tmp")

let fully_resolve (p : Policy.t) : Policy.t =
  (* Derive the state_dir basename from policy.project (what the guest
     will mount as /work), NOT the auto-detected git root. With
     [vm-launcher --policy /elsewhere/foo.ncl] run from inside repo
     [bar], the policy may set [project = /elsewhere/foo]; sessions /
     todos / history must scope to /foo, not /bar. *)
  let state_dir =
    Resolver.resolve_state_dir
      ~policy_state_dir:p.state_dir
      ~xdg_state_home:(xdg_state_home ())
      ~project_basename:(Filename.basename p.project)
  in
  let host_name, host_email = Resolver.host_git_identity () in
  let git =
    Resolver.resolve_git_identity ~policy_git:p.git ~host_name ~host_email
  in
  let host_user =
    match Sys.getenv_opt "USER" with
    | Some s when s <> "" -> Some s
    | _ -> None
  in
  let guest =
    Resolver.resolve_guest ~policy_guest:p.guest ~project:p.project ~host_user
  in
  let p = { p with state_dir = Some state_dir; git; guest } in
  (* shares: validate sources exist + tilde-expand so the JSON the
     guest reads has absolute paths microvm.nix can hand straight to
     virtiofsd. Stage-time failure is much louder than a virtiofsd
     happily exporting an empty dir. *)
  Stage.resolve_shares p

let do_show ~session (policy : Policy.t) =
  print_endline "## vm-launcher: resolved policy";
  print_endline (Yojson.Safe.pretty_to_string (Policy.to_json policy));
  print_endline "";
  Printf.printf "## egress posture: %s\n"
    (match policy.egress.mode with
     | Policy.Allowlist -> "fenced (in-guest proxy + nftables allowlist)"
     | Policy.Unrestricted -> "unfenced (direct internet, no proxy)"
     | Policy.Airgap -> "airgap (no network egress)");
  print_endline "";
  print_endline "## egress allowlist (one per line; applies in allowlist mode)";
  print_string (Render.egress_hosts policy);
  print_endline "";
  print_endline "## state dir";
  print_endline (Session.state_dir session);
  print_endline "";
  print_endline "## staged files under <state>/etc/";
  Sys.readdir (Session.etc_dir session)
  |> Array.iter (fun n -> print_endline ("  " ^ n))

let flake_from_env_or_die () =
  try Sys.getenv "VM_LAUNCHER_FLAKE"
  with Not_found ->
    (* Installed builds are wrapped to default VM_LAUNCHER_FLAKE to this
       flake's own store path (flake.nix, makeWrapper --set-default), which
       carries nixosConfigurations.vmLauncher — so it's never unset
       there. Only the raw dev binary (_build/.../main.exe) reaches here. *)
    failwith
      "VM_LAUNCHER_FLAKE env var not set \xe2\x80\x94 installed builds default \
       it to the bundled flake; for a dev binary point it at a flake that \
       exports nixosConfigurations.vmLauncher (this repo, or a working tree)"

(* argv after the subcommand word. *)
let subcommand_args () =
  Array.to_list (Array.sub Sys.argv 2 (Array.length Sys.argv - 2))

let do_ls args =
  let all = ref false in
  List.iter
    (fun a ->
      match a with
      | "--all" -> all := true
      | s ->
          Util.log_error "ls: unknown arg '%s'" s;
          exit 2)
    args;
  Ls.run ~all:!all ~xdg_state_home:(xdg_state_home ()) ~state_base ();
  exit 0

let do_clean args =
  let exited = ref false in
  let ids = ref [] in
  List.iter
    (fun a ->
      match a with
      | "--exited" -> exited := true
      | s when String.length s > 0 && s.[0] = '-' ->
          Util.log_error "clean: unknown flag '%s'" s;
          exit 2
      | id -> ids := id :: !ids)
    args;
  let ids = List.rev !ids in
  if !exited && ids <> [] then begin
    Util.log_error "clean: pass session IDs or --exited, not both";
    exit 2
  end;
  if (not !exited) && ids = [] then begin
    Util.log_error
      "clean: nothing to do — pass session IDs (see 'vm-launcher ls') \
       or --exited";
    exit 2
  end;
  exit
    (Clean.run ~xdg_state_home:(xdg_state_home ()) ~state_base
       ~ids ~exited:!exited)

(* --- attach / down -----------------------------------------------

   A detached session outlives its launcher, so it is found by walking
   the live state dirs for an attach.json whose runner is still alive —
   the same registry `ls` reads, filtered to VMs that can actually be
   reached. *)

(* The state dir is named for the launcher pid — session-<pid>. *)
let launcher_pid_of state_dir =
  match int_of_string_opt (Filename.basename state_dir |> fun b ->
        match String.index_opt b '-' with
        | Some i -> String.sub b (i + 1) (String.length b - i - 1)
        | None -> "") with
  | Some p -> p
  | None -> 0

let running_attachables () =
  Ls.live_sessions state_base
  |> List.filter_map (fun (pid, id) ->
       let state_dir = Printf.sprintf "%s/session-%d" state_base pid in
       match Ssh.read ~state_dir with
       (* Attachable = the VM is alive, judged by its runner. True for
          both modes: sshd runs whenever session.ssh is set, so a
          foreground VM takes a second shell just as happily as a
          detached one. Ownership (who may `down` it) is a separate
          question, answered by a.detached. *)
       | Some a when Ls.runner_alive ~state_base ~pid -> Some (id, state_dir, a)
       | _ -> None)

(* Print each candidate AS THE COMMAND that acts on it. An id alone
   leaves the reader to assemble `vm-launcher attach <id>` from a
   sentence above; these lines can be copied straight back into the
   shell, which is the whole point of printing them. *)
let describe_candidates ~verb cands =
  List.iter
    (fun (id, _, (a : Ssh.attach_info)) ->
      Printf.eprintf "    vm-launcher %s %s   # slot %d  %s\n" verb id a.slot
        (Ls.short_project a.project))
    cands

(* Pick the session to act on: an explicit ID (prefix match, as
   elsewhere in the CLI), else the one for the current project, else
   the only one. Ambiguity is reported rather than guessed at — the
   wrong guess here powers off someone's work. *)
let select_session ~verb args =
  let cands = running_attachables () in
  match cands with
  | [] ->
      Util.log_error
        "no VM is running to %s (boot one with `vm-launcher`, or \
         `vm-launcher --detach` to leave it running)" verb;
      exit 1
  | _ -> (
      let by_id id =
        List.filter (fun (sid, _, _) ->
          sid = id
          || (String.length id > 0
              && String.length sid >= String.length id
              && String.sub sid 0 (String.length id) = id)) cands
      in
      match args with
      | id :: _ -> (
          match by_id id with
          | [ one ] -> one
          | [] ->
              Util.log_error "no running VM matches %S" id;
              describe_candidates ~verb cands;
              exit 1
          | many ->
              Util.log_error "%S matches several sessions:" id;
              describe_candidates ~verb many;
              exit 1)
      | [] -> (
          (* THIS PROJECT first, always. The old order asked "is there
             exactly one VM anywhere?" before it asked "is one of them
             mine", so standing in a project with its own VM running
             could attach you to a different project's VM — or, with
             `down`, stop it. Being in a directory is the whole context
             for a bare `attach`/`down`; a VM belonging to another
             project must be named explicitly. *)
          let here = try Resolver.find_project_root () with _ -> "" in
          let mine =
            List.filter
              (fun (_, _, (a : Ssh.attach_info)) -> here <> "" && a.project = here)
              cands
          in
          match mine with
          | [ one ] -> one
          | _ :: _ ->
              Util.log_error
                "several VMs are running for this project — run one of these:";
              describe_candidates ~verb mine;
              exit 1
          | [] ->
              Util.log_error
                "no VM is running for this project (%s)."
                (if here = "" then "no project root found" else here);
              Util.log_error
                "%d running elsewhere — name it explicitly, e.g.:"
                (List.length cands);
              describe_candidates ~verb cands;
              exit 1))

(* What to run next, after leaving a guest shell: the VM is still up
   (that is the point), so say how to get back and how to end it. *)
let print_leave_note (a : Ssh.attach_info) =
  if Ssh.runner_alive a.runner_pid then begin
    Util.log_info "left VM %s running (slot %d)" a.id a.slot;
    Util.log_info "  reattach: vm-launcher attach %s" a.id;
    if a.detached then
      Util.log_info "  stop:     vm-launcher down %s" a.id
    else
      Util.log_info
        "  stop:     log out of its console, in the terminal that launched it"
  end
  else Util.log_info "VM %s is no longer running" a.id

(* Spawned, not exec'd: once ssh returns we still have to say how to get
   back in or end the session. ssh's exit code is passed through. *)
let attach_here (a : Ssh.attach_info) =
  let rc =
    try Ssh.run_interactive a
    with Failure msg -> Util.log_error "%s" msg; exit 127
  in
  print_leave_note a;
  exit rc

let do_attach args =
  let id, state_dir, (a : Ssh.attach_info) = select_session ~verb:"attach" args in
  (* A VM `ls` shows as booting is a valid target: wait for its sshd
     rather than handing the user ssh's "connection refused". *)
  if not (Ssh.sshd_up a) then begin
    Util.log_info "%s is still booting; waiting for its sshd" id;
    if not (Ssh.wait_ready a) then begin
      Util.log_error "could not reach the guest's sshd";
      Util.log_info "  console:  tail -f %s/console.log" state_dir;
      exit 1
    end
  end;
  attach_here a

let do_down args =
  let id, state_dir, (a : Ssh.attach_info) = select_session ~verb:"down" args in
  if (not a.detached) && Ls.process_alive (launcher_pid_of state_dir) then begin
    (* Foreground with its launcher still alive: that launcher owns the
       VM's lifetime and tears down its own children on exit. Killing
       the VM from here would leave it waiting on a dead child. (A
       foreground VM whose launcher has died IS stoppable here — that is
       the "orphaned" case, and `down` is the only way to reap it.) *)
    Util.log_error
      "%s is running in the FOREGROUND — stop it from its own terminal \
       (log out of its console, or Ctrl-C), or re-launch without \
       --console to make it stoppable from here"
      id;
    exit 1
  end;
  if not (Ls.pid_is_runner a.runner_pid) then begin
    (* The recorded pid is alive but is no longer cloud-hypervisor — it
       was recycled. Signalling it would hit an unrelated process. *)
    Util.log_error
      "%s: recorded runner pid %d is not a VM any more (pid recycled); \
       the VM is already gone — `vm-launcher clean %s` to tidy up"
      id a.runner_pid id;
    exit 1
  end;
  Util.log_info "powering off %s (runner pid %d)" id a.runner_pid;
  (* SIGTERM lets cloud-hypervisor shut the guest down cleanly — vmm
     state flushed, tap and vhost sockets released — the same courtesy
     an attached session gets on Ctrl-C. *)
  (try Unix.kill a.runner_pid Sys.sigterm with Unix.Unix_error _ -> ());
  let deadline = Unix.gettimeofday () +. 20.0 in
  let rec wait () =
    if Ls.process_alive a.runner_pid then
      if Unix.gettimeofday () >= deadline then begin
        Util.log_warn "runner did not exit in 20s; sending SIGKILL";
        (try Unix.kill a.runner_pid Sys.sigkill with Unix.Unix_error _ -> ())
      end
      else (Unix.sleepf 0.3; wait ())
  in
  wait ();
  (* The slot marker and the state dir (virtiofsd sockets, ssh keys) are
     only safe to drop once the VM is actually gone. *)
  (try Sys.remove (Printf.sprintf "%s/slot-%d.detached" state_base a.slot)
   with Sys_error _ -> ());
  Util.log_info "stopped; state dir %s left for `vm-launcher clean %s`"
    state_dir id;
  exit 0

(* --- bare `vm-launcher`, on a terminal ----------------------------

   With no arguments the old behavior was to boot a foreground VM, and —
   if no policy was found — to boot a BUILT-IN one around whatever
   directory you happened to be standing in, a 10-20 minute build nobody
   asked for. It also ignored the likeliest intent: when this project
   already has a VM up, you almost certainly want a shell in it, not a
   second VM competing for a slot.

   So with no arguments AND a terminal, offer what the directory implies.
   Any explicit argument, or a non-tty stdin (scripts, CI, the e2e
   suite), keeps the old behavior untouched. *)

let ask prompt =
  print_string prompt;
  flush stdout;
  match input_line stdin with
  | line -> String.trim (String.lowercase_ascii line)
  | exception End_of_file -> ""

(* Returns true when the caller should go on to boot a VM; the chooser
   may also exec (attach) or exit on its own. *)
let interactive_default () =
  let project = try Resolver.find_project_root () with _ -> Sys.getcwd () in
  let source = Resolver.resolve_source ~project ~override:None in
  let mine =
    List.filter
      (fun (_, _, (a : Ssh.attach_info)) -> a.project = project)
      (running_attachables ())
  in
  Printf.printf "\n  %s\n" project;
  (match source with
   | Resolver.Override path ->
       Printf.printf "  policy   %s\n" path
   | Resolver.Default ->
       Printf.printf "  policy   none found under this project\n");
  (match mine with
   | [] -> Printf.printf "  running  nothing for this project\n"
   | l ->
       List.iter
         (fun (id, _, (a : Ssh.attach_info)) ->
           Printf.printf "  running  %s (slot %d)%s\n" id a.slot
             (if a.detached then " detached" else " in another terminal"))
         l);
  print_newline ();
  match (mine, source) with
  | (_ :: _), _ ->
      (* A VM is up. Attaching is the overwhelmingly likely intent. *)
      let ans =
        ask "  [a] attach  [n] new VM  [s] stop it  [q] quit   (a): "
      in
      if ans = "" || ans = "a" then do_attach []
      else if ans = "s" then do_down []
      else if ans = "n" then true
      else exit 0
  | [], Resolver.Override _ ->
      let ans =
        ask "  [d] start detached  [f] start here  [s] show policy  [q] quit   (d): "
      in
      if ans = "" || ans = "d" then (detach := true; true)
      else if ans = "f" then true
      else if ans = "s" then (show_only := true; true)
      else exit 0
  | [], Resolver.Default ->
      (* No policy: booting the built-in default shares THIS directory
         with an agent and costs a full guest build. Never the silent
         default — make it a decision. *)
      Util.log_warn
        "no policy under %s — a VM here would use the built-in default: \
         this whole directory shared read-write, egress limited to \
         api.anthropic.com"
        project;
      let ans =
        ask "  [y] boot it anyway  [q] quit   (q): "
      in
      if ans = "y" then true else exit 0

(* Subcommand dispatch. The first non-flag argv (if any) selects a
   subcommand; otherwise we fall through to the legacy flag-only
   launch path. Keep this minimal — Arg.parse handles the launch
   flags after we strip the subcommand. *)
let dispatch_subcommand () =
  if Array.length Sys.argv >= 2 then
    let arg1 = Sys.argv.(1) in
    if String.length arg1 = 0 || arg1.[0] = '-' then ()
    else
      match arg1 with
      | "attach" -> do_attach (subcommand_args ())
      | "down" -> do_down (subcommand_args ())
      | "ls" -> do_ls (subcommand_args ())
      | "ids" ->
          (* Undocumented in the usage block on purpose: this exists for
             shell completion, not for people. *)
          exit
            (Ls.ids ~live_only:(List.mem "--live" (subcommand_args ()))
               ~xdg_state_home:(xdg_state_home ()) ~state_base ())
      | "clean" -> do_clean (subcommand_args ())
      | "help" | "h" -> print_help_and_exit ()
      | s ->
          Util.log_error
            "unknown subcommand %S (try 'vm-launcher --help')" s;
          exit 2

let main () =
  dispatch_subcommand ();
  (* Bare invocation on a terminal: ask before doing anything expensive
     or irreversible. Guarded on argc so any flag keeps the old path, and
     on isatty so nothing scripted ever blocks on a prompt. *)
  if Array.length Sys.argv = 1 && Unix.isatty Unix.stdin then
    ignore (interactive_default ());
  Arg.parse speclist
    (fun s ->
      Util.log_error "unknown arg '%s'" s;
      exit 2)
    help_text;

  let project = Resolver.find_project_root () in
  let source = Resolver.resolve_source ~project ~override:!policy_override in
  (match source, !policy_override with
   | Default, _ ->
       Util.log_info
         "no --policy supplied \xe2\x80\x94 using built-in default rooted at %s"
         project
   | Override path, None ->
       Util.log_info
         "no --policy supplied \xe2\x80\x94 auto-discovered %s" path
   | Override _, Some _ -> ());
  let policy = Resolver.load ~project source in
  let policy =
    match !egress_override with
    | None -> policy
    | Some mode -> { policy with egress = { policy.egress with mode } }
  in
  (* Loud, conspicuous notice when the operator has lifted or dropped the
     fence — this disables the launcher's core protection, so it should
     never be silent (it's also recorded in the session manifest via the
     embedded policy). *)
  (match policy.egress.mode with
   | Policy.Allowlist -> ()
   | Policy.Unrestricted ->
       Util.log_warn
         "WARNING \xe2\x80\x94 --egress unfenced: this session runs UNFENCED \
          (no egress proxy, no allowlist, direct internet)"
   | Policy.Airgap ->
       Util.log_warn
         "--egress airgap: this session has NO network egress");
  let policy = fully_resolve policy in
  (* --detach implies keeping the state dir: it holds the session's ssh
     keys and the virtiofsd sockets the running VM is still using, and
     Session.with_state would otherwise delete both on the way out.
     headless goes into the policy so the guest skips its console login
     session — see Policy.session. *)
  if !detach && !console then begin
    Util.log_error "--detach and --console are mutually exclusive";
    exit 2
  end;
  (* A plain launch on a terminal: boot detached and attach over ssh, so
     the VM outlives a logout. Needs the attach path (session.ssh);
     without it the console is the only way in, so keep that. Never
     without a terminal — scripts and the e2e suite keep the launcher-
     owns-the-VM behavior. *)
  if (not !detach) && (not !console) && (not !show_only)
     && Unix.isatty Unix.stdin && Unix.isatty Unix.stdout
  then begin
    if policy.Policy.session.ssh then begin
      auto_attach := true;
      detach := true
    end
    else
      Util.log_info
        "session.ssh = false: no attach path, so this terminal is the \
         console (logging out powers the VM off)"
  end;
  let policy =
    if !detach then begin
      keep_state := true;
      Policy.{ policy with session = { policy.session with headless = true } }
    end
    else policy
  in
  if !detach && not policy.Policy.session.ssh then begin
    Util.log_error
      "--detach needs session.ssh = true: headless means ssh is the only \
       way in, and this policy turns it off";
    exit 2
  end;

  (* Capture VM exit code + state-dir path OUT of the with_state lambda:
     calling exit from inside would terminate before Fun.protect's
     finally runs, orphaning virtiofsds + microvm-run and leaking the
     state dir. The state_dir ref is also how the final-status hint
     below knows where to point the user for --keep-state inspection. *)
  let exit_code = ref 0 in
  let state_dir_seen = ref "" in
  Session.with_state
    ~state_base
    ~keep_state:!keep_state
    ~f:(fun session ->
      state_dir_seen := Session.state_dir session;
      (* Stage before symlinking current-session: a concurrent reader
         that resolves through the link sees a fully populated etc/,
         not a half-written one. *)
      Stage.all ~etc_dir:(Session.etc_dir session) ~source policy;
      (* RNG init is needed regardless of egress mode — the session ID
         pulls from it below. Idempotent; never persists across runs. *)
      Mirage_crypto_rng_unix.use_default ();
      (* Per-VM MITM CA + proxy-auth rules are only meaningful in the
         default (Allowlist) posture — the unfenced/airgap modes run no
         egress proxy, so staging a CA or auth rules would be dead
         weight (and the guest builds no runtime CA bundle in those
         modes). Skip them, and warn loudly if the policy carries proxy
         config that this session will silently NOT apply. *)
      (match policy.egress.mode with
       | Policy.Allowlist ->
           let ca = Proxy_ca.generate_ca () in
           Stage.proxy_ca ~etc_dir:(Session.etc_dir session) ca;
           Stage.proxy_auth_config
             ~etc_dir:(Session.etc_dir session) policy.proxy_auth
       | Policy.Unrestricted | Policy.Airgap ->
           let has_proxy_secrets =
             List.exists
               (fun (s : Policy.secret) -> s.scope = Policy.Proxy_only)
               policy.secrets
           in
           if policy.proxy_auth <> [] || has_proxy_secrets then
             Util.log_warn
               "WARNING \xe2\x80\x94 no egress proxy in this mode; proxyAuth \
                rules and proxy-scoped secrets will NOT be applied");
      (* Session ID + manifest: write the ID into etc/ for the guest
         to read, write the canonical manifest to the global registry
         (and symlink it into the per-project state dir). *)
      let session_id = Session_manifest.generate_id () in
      Stage.session_id ~etc_dir:(Session.etc_dir session) session_id;
      (* Boot path only: --show neither holds a network slot nor
         touches a current-session-<i> symlink, so it stays usable —
         and harmless — while real sessions are running. Slot before
         manifest so the manifest records which identity this
         session booted with. *)
      let slot =
        if !show_only then None
        else Some (Session.acquire_slot session)
      in
      let manifest =
        Session_manifest.build
          ~id:session_id
          ~launch_cwd:(Sys.getcwd ())
          ~slot
          ~source
          ~policy
      in
      (* Only a real launch is a session. --show used to register here
         too, so every dry run left an "exited" row in `ls`. *)
      if not !show_only then
        Session_manifest.write
          ~xdg_state_home:(xdg_state_home ())
          ~project_state_dir:policy.state_dir
          manifest;
      if !show_only then do_show ~session policy
      else begin
        let flake = flake_from_env_or_die () in
        let slot_n = match slot with Some i -> i | None -> 0 in
        let guest_user =
          Option.value policy.Policy.guest.username ~default:"vmlauncher"
        in
        (* Per-session ssh material, staged for the guest. Needs the
           slot (the guest address goes into known_hosts), so it runs
           after acquire_slot rather than with the rest of Stage. *)
        if policy.Policy.session.ssh then begin
          Ssh.generate
            ~state_dir:(Session.state_dir session)
            ~etc_dir:(Session.etc_dir session)
            ~slot:slot_n;
        end;
        exit_code :=
          Boot.run ~fast:!fast ~detach:!detach
            ~on_vm_pid:(fun ~pid ->
              (* Written for EVERY boot, not just detached: a foreground
                 VM runs sshd too, so `attach` can open a second shell
                 into it — and, more importantly, this file is where
                 `ls`/`clean` learn the VM's real liveness. Keying that
                 on the launcher pid is what let `clean` kill the shares
                 of a foreground VM whose launcher had been killed. *)
              if policy.Policy.session.ssh then
                Ssh.write ~state_dir:(Session.state_dir session)
                  Ssh.
                    {
                      id = session_id;
                      project = policy.Policy.project;
                      slot = slot_n;
                      guest_ip = Ssh.guest_ip ~slot:slot_n;
                      user = guest_user;
                      key = Session.state_dir session ^ "/id_ed25519";
                      known_hosts = Session.state_dir session ^ "/known_hosts";
                      runner_pid = pid;
                      detached = !detach;
                    };
              if not !detach then ()
              else begin
              (* Hand the virtiofsds over to init. They are registered
                 for kill-on-exit, and this launcher is about to exit —
                 without this the shares vanish the instant we return
                 and cloud-hypervisor dies with "vhost-user: can't
                 connect to peer". The runner itself was never
                 registered. *)
              Session.disown_children session;
              (* Claim the slot for the VM rather than for this
                 launcher, which is about to exit. *)
              Session.mark_slot_detached ~state_base ~slot:slot_n ~pid;
              (* One statement about the VM's state, then a block of
                 copy-pasteable commands — never mix the two (a path is
                 not a command; label it or make it one). *)
              if !auto_attach then
                Util.log_info
                  "VM running (session %s, slot %d); attaching this \
                   terminal once its sshd is up"
                  session_id slot_n
              else begin
                Util.log_info
                  "VM running detached (session %s, slot %d); state in %s"
                  session_id slot_n (Session.state_dir session);
                Util.log_info "  attach:   vm-launcher attach %s" session_id;
                Util.log_info "  stop:     vm-launcher down %s" session_id;
                Util.log_info "  console:  tail -f %s/console.log"
                  (Session.state_dir session)
              end
              end)
            ~on_runner:(fun ~store_path ~closure_bytes ->
              Session_manifest.record_runner
                ~xdg_state_home:(xdg_state_home ())
                ~id:session_id ~store_path ~closure_bytes)
            ~session ~policy ~flake ()
      end);
  if !exit_code <> 0 then begin
    if !keep_state then
      Util.log_error
        "session exited with rc=%d; state preserved at %s"
        !exit_code !state_dir_seen
    else
      Util.log_error
        "session exited with rc=%d (re-run with --keep-state to \
         preserve the session dir for debugging)"
        !exit_code;
    exit !exit_code
  end
  else if !keep_state && (not !detach) && !state_dir_seen <> "" then
    (* Clean exit, but --keep-state was set so Session.with_state did
       NOT rm the state dir. Surface the path so the user doesn't
       have to remember it. Not on --detach: the session has NOT
       ended — only this launcher — and the detach block above
       already named the state dir. *)
    Util.log_info
      "session ended cleanly; state preserved at %s" !state_dir_seen;
  if !auto_attach then begin
    match Ssh.read ~state_dir:!state_dir_seen with
    | None ->
        Util.log_error
          "VM booted but its attach.json is missing (%s); \
           try `vm-launcher attach`" !state_dir_seen;
        exit 1
    | Some a ->
        if Ssh.wait_ready a then attach_here a
        else begin
          Util.log_error "could not reach the guest's sshd";
          print_leave_note a;
          Util.log_info "  console:  tail -f %s/console.log" !state_dir_seen;
          exit 1
        end
  end

let () =
  try main () with
  | Failure msg ->
      Util.log_error "%s" msg;
      (* Any real failure (not user-initiated Ctrl-C, which the signal
         handler exits 130 directly) surfaces --keep-state for triage. *)
      if not !keep_state then
        Util.log_info
          "(re-run with --keep-state to preserve the session dir for \
           debugging)";
      exit 1
  | Sys_error msg ->
      Util.log_error "%s" msg;
      if not !keep_state then
        Util.log_info
          "(re-run with --keep-state to preserve the session dir for \
           debugging)";
      exit 1
