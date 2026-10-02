(* End-to-end VM boot test. Gated on VM_LAUNCHER_E2E=1 — otherwise
   the binary prints a skip line and exits 0.

   What it actually exercises (everything `dune test` does NOT cover
   on its own): launcher argv → Resolver → Stage → Boot.run → real
   `nix build` → real `virtiofsd` spawn → real `microvm-run` → guest
   boot → agent-home-init → vm-launcher-startup-hooks → writes into
   `/work/` → host observes the writes → SIGTERM → graceful guest
   shutdown → launcher cleanup.

   Run after big changes touching the boot path or the policy contract.
   Intended cadence: by hand, on a KVM host, before pushing a meaningful
   PR that touches `lib/boot.ml`, `lib/stage.ml`, `policy/contract.ncl`,
   or the guest config. NOT in CI — the buildDunePackage
   sandbox can't run VMs.

   Requirements:
   - KVM on the host
   - VM_LAUNCHER_FLAKE pointing at a checkout that exposes
     `nixosConfigurations.vmLauncher` (default: this checkout; set
     VM_LAUNCHER_FLAKE=/path/to/site-flake for a site-extended guest)
   - nickel + virtiofsd + cloud-hypervisor + nix on PATH (the dev
     shell provides them)
   - Wall clock: 20–60s once the guest closure is cached; several
     minutes the very first time. *)

let assert_b label cond =
  if not cond then failwith (Printf.sprintf "assertion failed: %s" label)

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i = i + n <= h
    && (String.sub haystack i n = needle || loop (i + 1))
  in
  loop 0

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let rm_rf path =
  if String.length path > 4
  then ignore
    (Sys.command (Printf.sprintf "rm -rf -- %s" (Filename.quote path)))

let with_temp_base f =
  let base = Filename.temp_file "vm-launcher-e2e-" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () -> f base)

(* Locate main.exe by walking from our own binary's path. dune builds
   it next door under _build/default/bin/main.exe; our binary lives at
   _build/default/test/test_e2e_vm.exe, so `../bin/main.exe` relative
   to our exe directory works regardless of the caller's cwd. Falls
   back to the relative form so test-runner-rooted invocations still
   work even if Sys.executable_name resolves to a bare argv[0]. *)
let bin_path =
  let exe = Sys.executable_name in
  let cand = Filename.dirname exe ^ "/../bin/main.exe" in
  if Sys.file_exists cand then cand
  else "../bin/main.exe"

let resolved_flake () =
  match Sys.getenv_opt "VM_LAUNCHER_FLAKE" with
  | Some s when s <> "" -> s
  | _ ->
    (* Default to THIS vm-launcher checkout — the repo vendors its own guest
       (nixosConfigurations.vmLauncher via mkGuest), so iterating on the
       launcher needs no site flake. Override VM_LAUNCHER_FLAKE to boot a
       site-extended guest (one that layers extra modules, e.g.
       julia/snakemake/…). *)
    let ic = Unix.open_process_in "git rev-parse --show-toplevel 2>/dev/null" in
    let root = try input_line ic with End_of_file -> "" in
    ignore (Unix.close_process_in ic);
    if root <> "" then root else "."

(* The policy contract this checkout ships, NOT the deployed one. The
   e2e tests the launcher + contract + guest that live in THIS repo
   together (same spirit as [resolved_flake] defaulting to the
   checkout). Resolving via the git toplevel of the cwd —
   not [resolved_flake] — keeps it correct even when VM_LAUNCHER_FLAKE
   is overridden to a site-extended guest, which selects the
   guest but does not vendor [policy/contract.ncl]. Falls back to the
   system-installed contract if the in-repo one isn't found (e.g.
   running the binary outside a git tree). *)
let contract_path () =
  let ic = Unix.open_process_in "git rev-parse --show-toplevel 2>/dev/null" in
  let root = try input_line ic with End_of_file -> "" in
  ignore (Unix.close_process_in ic);
  let in_repo = root ^ "/policy/contract.ncl" in
  if root <> "" && Sys.file_exists in_repo then in_repo
  else "/run/current-system/sw/share/vm-launcher/contract.ncl"

(* Write a self-contained Nickel policy that imports this checkout's
   contract. Sets the minimum fields needed for a
   non-network test boot: egress empty by default, ephemeral auth,
   a tiny toolset. Caller supplies env vars + startup commands.

   [?console]: [Some "hvc0"|"ttyS0"] emits an explicit
   [console = '<v>] line. [None] omits the field and the contract
   default ([Console_hvc0] / "hvc0") kicks in.

   [?egress_hosts]: extra hostnames to allow through the proxy. The
   default empty list locks egress down to nothing (every CONNECT
   gets rejected with 403); pass [["example.com"]] etc. to test a
   network round trip. Hosts that depend on network are at the
   suite-wide gate's discretion — flaky upstream = flaky case.

   [?extra_tools]: appended to the default [coreutils; bashInteractive]
   list. Use to pull in [curl], [wget], etc. when a startup hook
   needs them. *)
let write_policy
    ?console ?(egress_hosts = []) ?(extra_tools = []) ?(extra_agents = [])
    ?(auth = "ephemeral") ?(sync_files = [])
    ~path ~project ~env_vars ~startup_commands () =
  let oc = open_out path in
  Printf.fprintf oc "let c = import %S in\n" (contract_path ());
  output_string oc "{\n";
  Printf.fprintf oc "  project = \"%s\",\n" project;
  Printf.fprintf oc "  egress.hosts = [%s],\n"
    (String.concat ", "
       (List.map (fun h -> Printf.sprintf "\"%s\"" h) egress_hosts));
  Printf.fprintf oc "  auth = '%s,\n" auth;
  Printf.fprintf oc "  tools = [%s],\n"
    (String.concat ", "
       (List.map (fun t -> Printf.sprintf "\"%s\"" t)
          ([ "coreutils"; "bashInteractive" ] @ extra_tools)));
  (* Additional agents sharing the VM, by preset name. A non-empty list
     also flips session.multiplex = 'auto to tmux. *)
  if extra_agents <> [] then
    Printf.fprintf oc "  extraAgents = [%s],\n"
      (String.concat ", "
         (List.map (fun p -> Printf.sprintf "{ preset = '%s }" p) extra_agents));
  (* agent.syncFiles on the default (claude-preset) agent. *)
  if sync_files <> [] then
    Printf.fprintf oc "  agent.syncFiles = [%s],\n"
      (String.concat ", "
         (List.map (fun f -> Printf.sprintf "\"%s\"" f) sync_files));
  output_string oc "  resources = { vcpu = 2, memMb = 1024 },\n";
  (match console with
   | None -> ()
   | Some v -> Printf.fprintf oc "  console = '%s,\n" v);
  output_string oc "  env = {\n";
  List.iter
    (fun (k, v) -> Printf.fprintf oc "    %s = \"%s\",\n" k v)
    env_vars;
  output_string oc "  },\n";
  output_string oc "  startup = {\n";
  output_string oc "    logFile = \"/work/startup.log\",\n";
  output_string oc "    commands = [\n";
  List.iter
    (fun c -> Printf.fprintf oc "      { command = \"%s\" },\n" c)
    startup_commands;
  output_string oc "    ],\n";
  output_string oc "  },\n";
  output_string oc "} | c.Policy\n";
  close_out oc

(* Wait for [path] to appear OR [pid] to die, whichever comes first.
   Polling the launcher's pid catches crashes (e.g. virtiofsd missing
   from PATH) without burning the full timeout — the test then
   reports a meaningful error pointing at the launcher's stderr
   rather than "timeout after 600s". *)
let wait_for_file_or_death path ~pid ~timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if Sys.file_exists path then ()
    else
      (* Order matters: pid=0 means "no state change" (child alive)
         regardless of the status component, so handle that case
         first. The status patterns below only trigger when waitpid
         actually returned a reaped pid. *)
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ ->
        if Unix.gettimeofday () >= deadline then
          failwith
            (Printf.sprintf
               "timeout waiting for %s (after %.0fs) — launcher \
                still running; check the session dir under \
                $VM_LAUNCHER_STATE_BASE"
               path timeout)
        else (Unix.sleepf 0.5; loop ())
      | _, Unix.WEXITED n ->
        failwith
          (Printf.sprintf
             "launcher exited rc=%d before %s appeared \
              (see stderr above for the fatal line)"
             n path)
      | _, Unix.WSIGNALED n ->
        failwith
          (Printf.sprintf
             "launcher killed by signal %d before %s appeared" n path)
      | _, Unix.WSTOPPED _ ->
        failwith (Printf.sprintf "launcher stopped before %s appeared" path)
      | exception Unix.Unix_error (Unix.ECHILD, _, _) ->
        failwith
          (Printf.sprintf
             "launcher reaped externally before %s appeared" path)
  in
  loop ()

(* Track spawned launcher pids in a process-global so the SIGTERM
   handler can propagate signals to them. Appended by
   [spawn_launcher], removed by [kill_and_wait]. A list (not an
   option) because the concurrent-VMs case runs two launchers at
   once. Race-free as long as tests run serially (which they do
   under this binary's runner). *)
let spawned_pids : int list ref = ref []

(* Spawn main.exe in the background; return its pid. Stdout + stderr
   both routed to the test runner's stderr so any launcher diagnostic
   shows up alongside the test output — or to [stderr_file] when a
   case needs to assert on the launcher's diagnostics. *)
let spawn_launcher ?stderr_file ~env_overrides args =
  List.iter (fun (k, v) -> Unix.putenv k v) env_overrides;
  let argv = Array.of_list (bin_path :: args) in
  let dev_null = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let out_fd =
    match stderr_file with
    | None -> Unix.stderr
    | Some p ->
      Unix.openfile p [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644
  in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.close dev_null with _ -> ());
      if out_fd <> Unix.stderr then (try Unix.close out_fd with _ -> ()))
    (fun () ->
      let pid =
        Unix.create_process bin_path argv dev_null out_fd out_fd
      in
      spawned_pids := pid :: !spawned_pids;
      pid)

(* SIGTERM the launcher, give it 30s to power off the guest + clean
   up, then SIGKILL if it's still around. The launcher's signal
   handler triggers graceful shutdown via Sigterm_then_kill on its
   children (microvm-run gets 5s + a SIGTERM, then SIGKILL). *)
let kill_and_wait pid =
  (try Unix.kill pid Sys.sigterm with _ -> ());
  let deadline = Unix.gettimeofday () +. 30.0 in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
      if Unix.gettimeofday () >= deadline then begin
        (try Unix.kill pid Sys.sigkill with _ -> ());
        try ignore (Unix.waitpid [] pid) with _ -> ()
      end else (Unix.sleepf 0.5; loop ())
    | _, _ -> ()
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()
  in
  loop ();
  spawned_pids := List.filter (fun p -> p <> pid) !spawned_pids

(* External-signal cleanup: when `kill <test-pid>` lands on this
   binary, Fun.protect's finally does NOT run before exit — the
   spawned launcher (and its virtiofsd / microvm-run / cloud-
   hypervisor children) get adopted by init and live on. Install
   handlers for SIGTERM/SIGINT that propagate to the launcher
   before exiting, so the launcher's own Session.with_state cleanup
   reaps the VM + state dir cleanly. *)
let install_signal_handlers () =
  let propagate signo =
    List.iter kill_and_wait !spawned_pids;
    exit (128 + signo)
  in
  Sys.set_signal Sys.sigterm
    (Sys.Signal_handle (fun _ -> propagate 15));
  Sys.set_signal Sys.sigint
    (Sys.Signal_handle (fun _ -> propagate 2))

(* On test failure, dump the per-project startup.log if it landed —
   it's the cheapest first place to look for what went wrong inside
   the guest. *)
let try_dump_log path =
  if Sys.file_exists path then begin
    Printf.eprintf "\n--- guest startup.log (%s) ---\n" path;
    (try
       let ic = open_in path in
       (try
          while true do
            Printf.eprintf "%s\n" (input_line ic)
          done
        with End_of_file -> ());
       close_in ic
     with _ -> ());
    Printf.eprintf "--- end ---\n%!"
  end

(* Boot a microVM with the given policy parameters, wait for
   /work/marker-done to land, then run [k] with the project dir as
   argument. Handles tempdir creation, launcher spawn, signal-safe
   teardown, and startup.log dump on failure. Each new e2e case
   should be one of these wrapped around its specific assertions.

   state_base intentionally NOT overridden to a tempdir: the guest
   config hardcodes the vmcfg share's source as
   /run/vm-launcher/current-session/etc, so a tempdir override would
   mean the guest mounts a stale session's etc/ dir (whichever
   /run/vm-launcher/current-session symlink happened to point at).
   Tests must use the same state_base production uses. On the host the
   dir is owned by the launching user via the host's NixOS tmpfile
   rule, so no root needed. *)

(* The suite boots with the launcher's --fast flag by default
   (multi-threaded mkfs.erofs — ~2-4x faster guest builds), so running
   e2e on every vm-launcher / nixos-guest change stays affordable. ONE
   case ([test_non_fast_egress]) overrides ~fast:false to also exercise
   the default (non-fast) erofs path — fast and non-fast images are
   built differently and both must boot. See CLAUDE.md "Testing". *)
let suite_fast = true

let boot_and_run
    ?console ?(fast = suite_fast) ?(env_vars = []) ?(egress_hosts = [])
    ?(extra_tools = []) ?(extra_agents = []) ?auth ?sync_files
    ?(setup_home = fun _ -> ())
    ?egress ~startup_commands ~k () =
  with_temp_base @@ fun base ->
  let project = base ^ "/project" in
  let home = base ^ "/home" in
  List.iter (fun d -> Unix.mkdir d 0o755) [ project; home ];
  (* auth = 'bind binds dirs out of this fake $HOME, so a case that uses
     it populates them here first. *)
  setup_home home;

  let policy = base ^ "/microvm.ncl" in
  write_policy ?console ~egress_hosts ~extra_tools ~extra_agents ?auth
    ?sync_files ~path:policy ~project ~env_vars ~startup_commands ();

  let pid =
    spawn_launcher
      ~env_overrides:[
        "VM_LAUNCHER_FLAKE", resolved_flake ();
        "HOME", home;
        (* Pin the derived state dir under the fake $HOME too, so a
           case can pre-seed or inspect it regardless of the caller's
           XDG_STATE_HOME. *)
        "XDG_STATE_HOME", home ^ "/.local/state";
      ]
      (* No --keep-state: let the launcher rm-rf its state dir on
         exit so /run/vm-launcher/ doesn't accumulate green-run
         debris. We still get a readable failure trail because
         [try_dump_log] runs in the inner Fun.protect's finally
         BEFORE the launcher exits and clears the project dir;
         startup.log content is captured to our stderr. Set
         VM_LAUNCHER_E2E_KEEP_STATE=1 to opt in to --keep-state for
         a hand-debug session. *)
      (let keep =
         match Sys.getenv_opt "VM_LAUNCHER_E2E_KEEP_STATE" with
         | Some "1" -> [ "--keep-state" ]
         | _ -> []
       in
       let fast_arg = if fast then [ "--fast" ] else [] in
       (* Operator-only egress override (--egress noblock|block). None
          leaves the policy's own posture (the allowlist fence). *)
       let egress_arg =
         match egress with Some m -> [ "--egress"; m ] | None -> []
       in
       [ "--policy"; policy ] @ fast_arg @ egress_arg @ keep)
  in

  Fun.protect
    ~finally:(fun () ->
      kill_and_wait pid;
      try_dump_log (project ^ "/startup.log"))
    (fun () ->
      (* Generous timeout: first run builds the guest closure. *)
      wait_for_file_or_death (project ^ "/marker-done")
        ~pid ~timeout:1500.0;
      k project)

let test_env_vars_reach_agent_shell () =
  boot_and_run
    ~env_vars:[
      "TEST_FOO", "hello";
      (* Nickel string is literal-by-default: $ has no special meaning
         outside "%{...}" interpolation. So no escape needed here. *)
      "TEST_QUOTED", "with spaces and $dollar";
    ]
    ~startup_commands:[
      "printf '%s' \\\"$TEST_FOO\\\" > /work/marker-foo";
      "printf '%s' \\\"$TEST_QUOTED\\\" > /work/marker-quoted";
      "whoami > /work/marker-user";
      "touch /work/marker-done";
    ]
    ~k:(fun project ->
      let foo = read_file (project ^ "/marker-foo") in
      let quoted = read_file (project ^ "/marker-quoted") in
      let user =
        let s = read_file (project ^ "/marker-user") in
        let n = String.length s in
        if n > 0 && s.[n - 1] = '\n' then String.sub s 0 (n - 1) else s
      in
      assert_b "policy.env TEST_FOO surfaces as 'hello'" (foo = "hello");
      assert_b
        "policy.env value round-trips spaces + $"
        (foo <> "" && contains "with spaces and $dollar" quoted);
      assert_b
        "agent shell ran as non-root"
        (user <> "root" && user <> "");
      Printf.printf "    (ran as %s; got TEST_FOO=%S)\n%!" user foo)
    ()

(* policy.console wiring: hvc0 mode (the contract default) should
   register virtio-console on the kernel cmdline AND keep ttyS0 there
   for panic capture, expose /dev/hvc0 to the guest, and point the
   vm-launcher-session agetty unit at /dev/hvc0. *)
let test_console_hvc0_wires_through () =
  boot_and_run
    (* No ~console: defaults to 'hvc0 via the contract. *)
    ~startup_commands:[
      "cat /proc/cmdline > /work/marker-cmdline";
      "systemctl show vm-launcher-session.service -p TTYPath --value \
       > /work/marker-ttypath";
      "if [ -c /dev/hvc0 ]; then echo present > /work/marker-hvc0; \
       else echo missing > /work/marker-hvc0; fi";
      "touch /work/marker-done";
    ]
    ~k:(fun project ->
      let cmdline = read_file (project ^ "/marker-cmdline") in
      let ttypath = String.trim (read_file (project ^ "/marker-ttypath")) in
      let hvc0 = String.trim (read_file (project ^ "/marker-hvc0")) in
      assert_b "kernel cmdline registers hvc0 console"
        (contains "console=hvc0" cmdline);
      assert_b "kernel cmdline still mirrors to ttyS0 (panic capture)"
        (contains "console=ttyS0" cmdline);
      assert_b "agetty TTYPath points at /dev/hvc0"
        (ttypath = "/dev/hvc0");
      assert_b "/dev/hvc0 char device exists in the guest"
        (hvc0 = "present");
      Printf.printf
        "    (TTYPath=%s; cmdline registers both console=hvc0 and =ttyS0)\n%!"
        ttypath)
    ()

(* policy.console = 'ttyS0: the legacy/debug fallback. microvm.nix's
   defaults take over → no hvc0 device exposed, kernel cmdline only
   registers ttyS0, agetty lands on /dev/ttyS0. *)
let test_console_ttys0_fallback () =
  boot_and_run
    ~console:"ttyS0"
    ~startup_commands:[
      "cat /proc/cmdline > /work/marker-cmdline";
      "systemctl show vm-launcher-session.service -p TTYPath --value \
       > /work/marker-ttypath";
      "touch /work/marker-done";
    ]
    ~k:(fun project ->
      let cmdline = read_file (project ^ "/marker-cmdline") in
      let ttypath = String.trim (read_file (project ^ "/marker-ttypath")) in
      assert_b "kernel cmdline registers ttyS0 console"
        (contains "console=ttyS0" cmdline);
      assert_b "kernel cmdline does NOT register hvc0 in ttyS0 mode"
        (not (contains "console=hvc0" cmdline));
      assert_b "agetty TTYPath points at /dev/ttyS0"
        (ttypath = "/dev/ttyS0");
      Printf.printf "    (TTYPath=%s; cmdline pinned to console=ttyS0)\n%!"
        ttypath)
    ()

(* End-to-end egress allowlist: with example.com in policy.egress.hosts,
   curl through the per-VM MITM proxy reaches it and gets a 2xx; a host
   NOT in the allowlist (www.iana.org here) gets blocked by the proxy
   and curl exits non-zero. This case depends on the host machine
   having outbound internet — flaky upstream = flaky test, so this
   lives behind the same VM_LAUNCHER_E2E gate as everything else and
   isn't run by default. *)
let test_egress_allowlist () =
  boot_and_run
    ~egress_hosts:[ "example.com" ]
    ~extra_tools:[ "curl" ]
    ~startup_commands:[
      (* `;` chains so $? in the rc capture reads curl's exit, not
         any prior command's. -fsS makes curl exit non-zero on
         non-2xx and silence progress noise; -m bounds the wait. *)
      "curl -fsS -m 30 -o /work/marker-allowed-body \
       https://example.com/ ; echo \\\"rc=$?\\\" > /work/marker-allowed-rc";
      "curl -fsS -m 30 -o /work/marker-denied-body \
       https://www.iana.org/ ; echo \\\"rc=$?\\\" > /work/marker-denied-rc";
      "touch /work/marker-done";
    ]
    ~k:(fun project ->
      let allowed_rc =
        String.trim (read_file (project ^ "/marker-allowed-rc")) in
      let allowed_body = read_file (project ^ "/marker-allowed-body") in
      let denied_rc =
        String.trim (read_file (project ^ "/marker-denied-rc")) in
      assert_b "curl to allowed host (example.com) returned rc=0"
        (allowed_rc = "rc=0");
      assert_b "allowed-host body contains the example.com title"
        (contains "Example Domain" allowed_body);
      assert_b "curl to disallowed host (www.iana.org) failed (rc != 0)"
        (denied_rc <> "rc=0");
      Printf.printf "    (allowed %s; denied %s)\n%!" allowed_rc denied_rc)
    ()

(* Non-fast guard. The rest of the suite boots with --fast; this one
   case pins ~fast:false so the default (single-threaded -Efragments/
   -Ededupe) mkfs.erofs path is built and booted on every e2e run —
   fast and non-fast images are produced differently and both must
   boot. It also does a real network curl through the proxy, so the
   final run of the suite proves the non-fast image actually egresses
   (the fast egress coverage is test_egress_allowlist above). Depends
   on host outbound internet, same as test_egress_allowlist. *)
let test_non_fast_egress () =
  boot_and_run
    ~fast:false
    ~egress_hosts:[ "example.com" ]
    ~extra_tools:[ "curl" ]
    ~startup_commands:[
      "curl -fsS -m 30 -o /work/marker-body \
       https://example.com/ ; echo \\\"rc=$?\\\" > /work/marker-rc";
      "touch /work/marker-done";
    ]
    ~k:(fun project ->
      let rc = String.trim (read_file (project ^ "/marker-rc")) in
      let body = read_file (project ^ "/marker-body") in
      assert_b "non-fast image: curl to allowed host returned rc=0"
        (rc = "rc=0");
      assert_b "non-fast image: allowed-host body has the example.com title"
        (contains "Example Domain" body);
      Printf.printf "    (non-fast erofs image booted + egressed; %s)\n%!" rc)
    ()

(* --egress noblock (UNFENCED): no proxy, direct NAT. The proof is that
   a host NOT in the egress allowlist is reachable — under the fence it
   would 403 (that's exactly test_egress_allowlist's denied case,
   www.iana.org). Here the allowlist is irrelevant (no proxy at all), so
   the same host returns 2xx. Also asserts NO http_proxy is set in the
   agent shell (clients go direct). Depends on host outbound internet,
   same gate as test_egress_allowlist. *)
let test_egress_noblock () =
  boot_and_run
    ~egress:"noblock"
    (* Empty allowlist on purpose — proves it's not consulted. *)
    ~extra_tools:[ "curl" ]
    ~startup_commands:[
      "curl -fsS -m 30 -o /work/marker-body \
       https://www.iana.org/ ; echo \\\"rc=$?\\\" > /work/marker-rc";
      "echo \\\"proxy=[${https_proxy:-}]\\\" > /work/marker-proxy";
      "touch /work/marker-done";
    ]
    ~k:(fun project ->
      let rc = String.trim (read_file (project ^ "/marker-rc")) in
      let body = read_file (project ^ "/marker-body") in
      let proxy = String.trim (read_file (project ^ "/marker-proxy")) in
      assert_b "unfenced: curl to a NON-allowlisted host returned rc=0"
        (rc = "rc=0");
      assert_b "unfenced: got a real response body" (String.length body > 100);
      assert_b "unfenced: no https_proxy set in the agent shell"
        (proxy = "proxy=[]");
      Printf.printf "    (unfenced reached www.iana.org directly; %s)\n%!" rc)
    ()

(* --egress block (AIRGAP): nftables drops all egress, no proxy. A curl
   to anything must FAIL — there's no path off-box. Needs no host
   internet (it asserts failure), so it's robust in any environment. The
   local marker-done still lands (it's a touch). *)
let test_egress_block () =
  boot_and_run
    ~egress:"block"
    ~extra_tools:[ "curl" ]
    ~startup_commands:[
      "curl -fsS -m 15 -o /dev/null https://example.com/ ; \
       echo \\\"rc=$?\\\" > /work/marker-rc";
      "touch /work/marker-done";
    ]
    ~k:(fun project ->
      let rc = String.trim (read_file (project ^ "/marker-rc")) in
      assert_b "airgap: curl off-box failed (rc != 0)" (rc <> "rc=0");
      Printf.printf "    (airgap blocked egress as expected; %s)\n%!" rc)
    ()

(* --- Network slot pool: queue at capacity ---

   Each session holds one network slot (vm-tap<i>); the pool is the
   set of vm-tap<i> devices the host provisions. A launch beyond
   capacity QUEUES: it prints who holds the slots, polls, and
   continues the boot when one frees. Slots are taken BEFORE the
   guest-closure nix build, so this case needs no VM to actually
   boot: fill every slot with victim launchers (each holds its slot
   within ~1s of spawn), spawn one more, assert it queues (alive +
   banner + no current-session-<i> claimed), kill the victims,
   assert the queued one announces the handover and claims a
   per-slot symlink post-build, then kill it mid-build too. Scales
   with the pool (1 victim on a 1-slot host, 4 on the full pool) and
   stays cheap either way. *)

(* The launcher hardcodes its production state base; the guest's
   vmcfg share resolves through it, so tests cannot relocate it
   (see boot_and_run's comment). *)
let state_base = "/run/vm-launcher"

(* Mirror of Session.discover_slots: the host's vm-tap<i> devices. *)
let discover_pool () =
  (* Honor the same VM_LAUNCHER_SLOT_POOL override the launcher's
     Session.discover_slots honors (it propagates to the spawned
     launchers via the inherited env). Without it this case needs
     EVERY tap free, so it can't run while a live session holds one —
     restrict the pool to the free slots instead, e.g.
     VM_LAUNCHER_SLOT_POOL="2 3". *)
  match Sys.getenv_opt "VM_LAUNCHER_SLOT_POOL" with
  | Some s when String.trim s <> "" ->
    String.split_on_char ' ' s
    |> List.filter_map int_of_string_opt
    |> List.sort_uniq compare
  | _ ->
  match (try Some (Sys.readdir "/sys/class/net") with _ -> None) with
  | None -> []
  | Some entries ->
    Array.to_list entries
    |> List.filter_map (fun name ->
        if String.length name > 6 && String.sub name 0 6 = "vm-tap"
        then int_of_string_opt
               (String.sub name 6 (String.length name - 6))
        else None)
    |> List.sort compare

let slot_holder i =
  try
    let ic = open_in (Printf.sprintf "%s/slot-%d.lock" state_base i) in
    let line = (try input_line ic with End_of_file -> "") in
    close_in ic;
    int_of_string_opt (String.trim line)
  with _ -> None

(* Wait until [pid] holds SOME slot of [pool]; return it. The pid
   lands in slot-<i>.lock only under the lock, so this doubles as the
   "launcher really holds its slot" barrier. *)
let wait_for_slot_holder ~pool ~pid ~timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    match List.find_opt (fun i -> slot_holder i = Some pid) pool with
    | Some i -> i
    | None ->
      if Unix.gettimeofday () >= deadline then
        failwith
          (Printf.sprintf
             "launcher pid %d never appeared in any slot-<i>.lock" pid)
      else (Unix.sleepf 0.2; loop ())
  in
  loop ()

let wait_exit ~pid ~timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
      if Unix.gettimeofday () >= deadline then None
      else (Unix.sleepf 0.2; loop ())
    | _, st -> Some st
  in
  loop ()

let wait_for_stderr_line ~path ~needle ~pid ~timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    let seen =
      Sys.file_exists path && contains needle (read_file path)
    in
    if seen then ()
    else begin
      (match Unix.waitpid [ Unix.WNOHANG ] pid with
       | 0, _ -> ()
       | _, _ ->
         failwith
           (Printf.sprintf "launcher pid %d exited before %S appeared \
                            in its stderr (%s)" pid needle path));
      if Unix.gettimeofday () >= deadline then
        failwith
          (Printf.sprintf "timeout waiting for %S in %s" needle path)
      else (Unix.sleepf 0.2; loop ())
    end
  in
  loop ()

let test_second_launcher_queues () =
  with_temp_base @@ fun base ->
  let pool = discover_pool () in
  if pool = [] then
    failwith "no vm-tap<i> devices on this host — vm-launcher module inactive?";
  let mk name =
    let d = base ^ "/" ^ name in
    List.iter (fun p -> Unix.mkdir p 0o755) [ d; d ^ "/project"; d ^ "/home" ];
    let policy = d ^ "/microvm.ncl" in
    write_policy ~path:policy ~project:(d ^ "/project") ~env_vars:[]
      ~startup_commands:[ "touch /work/marker-done" ] ();
    d, policy
  in
  let env home = [
    "VM_LAUNCHER_FLAKE", resolved_flake ();
    "HOME", home;
  ] in
  let victims = ref [] in
  let queued = ref None in
  Fun.protect
    ~finally:(fun () ->
      (match !queued with Some q -> kill_and_wait q | None -> ());
      List.iter kill_and_wait !victims)
    (fun () ->
      (* Fill the pool: one victim per slot, each spawned and then
         awaited until it actually holds a slot (so spawn order maps
         to first-free order deterministically). *)
      List.iteri
        (fun k _slot ->
          let vdir, vpolicy = mk (Printf.sprintf "victim%d" k) in
          ignore vdir;
          let v =
            spawn_launcher ~env_overrides:(env (vdir ^ "/home"))
              [ "--policy"; vpolicy; "--fast" ]
          in
          victims := v :: !victims;
          ignore (wait_for_slot_holder ~pool ~pid:v ~timeout:30.0))
        pool;
      let qdir, qpolicy = mk "queued" in
      let qstderr = qdir ^ "/stderr" in
      let q =
        spawn_launcher ~stderr_file:qstderr
          ~env_overrides:(env (qdir ^ "/home"))
          [ "--policy"; qpolicy; "--fast" ]
      in
      queued := Some q;
      wait_for_stderr_line ~path:qstderr
        ~needle:"queued —"
        ~pid:q ~timeout:30.0;
      let banner = read_file qstderr in
      let first_victim = List.nth !victims (List.length !victims - 1) in
      assert_b "queue banner cites a holder pid"
        (contains (Printf.sprintf "(pid %d)" first_victim) banner);
      assert_b "queue banner says it starts automatically"
        (contains "starts automatically" banner);
      assert_b "queue banner mentions the Ctrl-C escape"
        (contains "Ctrl-C to cancel" banner);
      (* Queued, not booting: still alive, and no per-slot symlink
         claimed (the flip happens post-build, and a queued launcher
         never got that far). *)
      Unix.sleepf 2.0;
      (match wait_exit ~pid:q ~timeout:0.1 with
       | Some st ->
         failwith
           (Printf.sprintf "queued launcher exited instead of waiting: %s"
              (match st with
               | Unix.WEXITED n -> Printf.sprintf "rc=%d" n
               | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
               | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n))
       | None -> ());
      let q_session = Printf.sprintf "%s/session-%d" state_base q in
      List.iter
        (fun i ->
          match (try Some (Unix.readlink
                             (Printf.sprintf "%s/current-session-%d"
                                state_base i))
                 with _ -> None) with
          | Some target ->
            assert_b "queued launcher hasn't claimed any slot symlink"
              (target <> q_session)
          | None -> ())
        pool;
      (* Holders exit → the queued launch takes a freed slot on its
         own, builds its closure, and only then claims that slot's
         symlink. *)
      List.iter kill_and_wait !victims;
      victims := [];
      wait_for_stderr_line ~path:qstderr
        ~needle:"freed — starting this session"
        ~pid:q ~timeout:30.0;
      let deadline = Unix.gettimeofday () +. 300.0 in
      let rec wait_symlink () =
        let claimed =
          List.exists
            (fun i ->
              (try Unix.readlink
                     (Printf.sprintf "%s/current-session-%d" state_base i)
               with _ -> "")
              = q_session)
            pool
        in
        if claimed then ()
        else begin
          (match Unix.waitpid [ Unix.WNOHANG ] q with
           | 0, _ -> ()
           | _, _ ->
             failwith
               "queued launcher died before claiming its slot symlink");
          if Unix.gettimeofday () >= deadline then
            failwith "queued launcher never claimed a slot symlink"
          else (Unix.sleepf 0.5; wait_symlink ())
        end
      in
      wait_symlink ();
      Printf.printf
        "    (pool of %d filled; extra launch queued, then continued \
         and claimed its slot post-build)\n%!" (List.length pool))

(* --- Concurrent VMs acceptance (per-session networking) ---

   With the slot pool, two sessions own DISTINCT taps / MACs / IPs:
   the old failure mode (tun flow-steering spraying return traffic
   between same-identity guests) is structurally impossible. This
   case is the acceptance test for that: boot a "victim" VM running
   a timestamped curl loop, boot a second VM mid-loop, kill it, let
   the victim finish — and assert ZERO egress failures in both VMs,
   in every window. (On the old shared-tap layout the same case was
   characterization-only: active flows happened to survive, idle
   flows died, and the counts were printed rather than asserted.)

   Gated on a pool of >= 2 slots: on a host that still provisions
   only vm-tap0 the second launch would just queue, so the case
   prints a skip note instead. Opt-in via VM_LAUNCHER_E2E_CONCURRENT=1
   because it costs ~2-3 boot cycles of wall clock. *)

let spawn_vm ~base ~name ~startup_commands =
  let dir = base ^ "/" ^ name in
  let project = dir ^ "/project" in
  let home = dir ^ "/home" in
  List.iter (fun d -> Unix.mkdir d 0o755) [ dir; project; home ];
  let policy = dir ^ "/microvm.ncl" in
  write_policy ~egress_hosts:[ "example.com" ] ~extra_tools:[ "curl" ]
    ~path:policy ~project ~env_vars:[] ~startup_commands ();
  let pid =
    spawn_launcher
      ~env_overrides:[
        "VM_LAUNCHER_FLAKE", resolved_flake ();
        "HOME", home;
      ]
      (* No flag needed: with the slot pool, running alongside other
         sessions IS the default (each gets its own identity). *)
      [ "--policy"; policy; "--fast" ]
  in
  (pid, project)

(* /work/egress.log lines are "<epoch.frac> ok|FAIL"; bucket them
   into before/during/after the [t0, t1) intruder window. Guest
   clocks are kvm-clock (host-synced), so comparing against host
   timestamps is sound at this granularity. *)
let egress_counts ~t0 ~t1 path =
  let buckets = Hashtbl.create 8 in
  if Sys.file_exists path then begin
    let ic = open_in path in
    (try
       while true do
         match String.split_on_char ' ' (input_line ic) with
         | [ ts; verdict ] ->
           (match float_of_string_opt ts with
            | None -> ()
            | Some t ->
              let w =
                if t < t0 then "before"
                else if t < t1 then "during"
                else "after"
              in
              let key = w ^ " " ^ verdict in
              Hashtbl.replace buckets key
                (1 + try Hashtbl.find buckets key with Not_found -> 0))
         | _ -> ()
       done
     with End_of_file -> ());
    close_in ic
  end;
  buckets

let print_counts label buckets =
  Printf.printf "    %s:\n" label;
  if Hashtbl.length buckets = 0 then Printf.printf "      (no egress log)\n";
  List.iter
    (fun key ->
      match Hashtbl.find_opt buckets key with
      | Some n -> Printf.printf "      %-12s %d\n" key n
      | None -> ())
    [ "before ok"; "before FAIL"; "during ok"; "during FAIL";
      "after ok"; "after FAIL" ]

let count buckets key =
  match Hashtbl.find_opt buckets key with Some n -> n | None -> 0

let test_concurrent_vms () =
  let pool = discover_pool () in
  if List.length pool < 2 then begin
    Printf.printf
      "    (skipped: host provisions %d network slot(s); the \
       acceptance run needs >= 2 — provision more vm-tap<i> \
       devices on the host)\n%!"
      (List.length pool);
  end else
  with_temp_base @@ fun base ->
  (* Victim: marker-done immediately, then a ~2min bounded curl loop
     (120 x (curl -m 3 + 0.5s sleep)), then loop-finished. No double
     quotes in the commands — they'd need Nickel escaping. *)
  let vm1_pid, vm1_project =
    spawn_vm ~base ~name:"vm1"
      ~startup_commands:[
        "touch /work/marker-done";
        (* --retry 2 --retry-all-errors: a single upstream blip
           (example.com weather) retries within the probe; a FAIL
           means 3 consecutive failures — real egress breakage. -m
           caps the whole attempt chain, keeping the loop bounded. *)
        "for i in $(seq 1 120); do \
         if curl -fsS --retry 2 --retry-all-errors -m 6 \
            -o /dev/null https://example.com/; \
         then echo $(date +%s.%N) ok >> /work/egress.log; \
         else echo $(date +%s.%N) FAIL >> /work/egress.log; fi; \
         sleep 0.5; done";
        "touch /work/loop-finished";
      ]
  in
  Fun.protect
    ~finally:(fun () ->
      kill_and_wait vm1_pid;
      try_dump_log (vm1_project ^ "/startup.log"))
    (fun () ->
      wait_for_file_or_death (vm1_project ^ "/marker-done")
        ~pid:vm1_pid ~timeout:1500.0;
      Printf.printf "    victim up; baseline window...\n%!";
      Unix.sleepf 10.0;

      (* Intruder: 30-curl burst, marker-done, then idle until we
         SIGTERM it. *)
      let t0 = Unix.gettimeofday () in
      let vm2_pid, vm2_project =
        spawn_vm ~base ~name:"vm2"
          ~startup_commands:[
            "for i in $(seq 1 30); do \
             if curl -fsS --retry 2 --retry-all-errors -m 6 \
                -o /dev/null https://example.com/; \
             then echo $(date +%s.%N) ok >> /work/egress.log; \
             else echo $(date +%s.%N) FAIL >> /work/egress.log; fi; \
             sleep 0.5; done";
            "touch /work/marker-done";
            "sleep 300";
          ]
      in
      let intruder_booted =
        try
          wait_for_file_or_death (vm2_project ^ "/marker-done")
            ~pid:vm2_pid ~timeout:1500.0;
          true
        with Failure msg ->
          Printf.printf "    intruder did NOT come up: %s\n%!" msg;
          false
      in
      kill_and_wait vm2_pid;
      let t1 = Unix.gettimeofday () in

      (* Victim's launcher must have survived the intruder. *)
      let vm1_alive =
        match Unix.waitpid [ Unix.WNOHANG ] vm1_pid with
        | 0, _ -> true
        | _ -> false
        | exception Unix.Unix_error (Unix.ECHILD, _, _) -> false
      in
      assert_b "victim launcher still alive after intruder exit" vm1_alive;

      (* The loop is time-bounded (worst case 120 x 3.5s = 420s), so
         loop-finished is a liveness check, not an egress check. *)
      wait_for_file_or_death (vm1_project ^ "/loop-finished")
        ~pid:vm1_pid ~timeout:900.0;

      let vm1_counts = egress_counts ~t0 ~t1 (vm1_project ^ "/egress.log") in
      let vm2_counts = egress_counts ~t0 ~t1 (vm2_project ^ "/egress.log") in
      print_counts "victim egress (second VM's window = during)" vm1_counts;
      print_counts "second VM egress" vm2_counts;
      assert_b "second VM boots alongside the victim" intruder_booted;
      (* The acceptance bar: with per-slot identities, NO window of
         EITHER VM may show a single egress failure. *)
      List.iter
        (fun w ->
          assert_b
            (Printf.sprintf "victim has zero egress failures (%s)" w)
            (count vm1_counts (w ^ " FAIL") = 0))
        [ "before"; "during"; "after" ];
      assert_b "second VM has zero egress failures"
        (count vm2_counts "during FAIL" = 0);
      assert_b "victim saw traffic in every window"
        (count vm1_counts "before ok" > 0
         && count vm1_counts "during ok" > 0
         && count vm1_counts "after ok" > 0))

(* Two agents in one VM. Proves the guest closure a
   multi-agent policy produces actually boots, and that each agent
   arrives complete: its own run wrapper, its binary on PATH, its
   config-dir env var, and a multiplexer to run them both in.

   auth = 'ephemeral here (the suite's default), so this does NOT cover
   the config binds / agent-home-init — that path needs a real host
   ~/.claude and ~/.config/codex and is hand-smoked. What it does cover
   is everything that would break at closure-build or boot time. *)
let test_multi_agent () =
  boot_and_run
    ~extra_agents:[ "codex" ]
    ~startup_commands:[
      (* Listed straight out of the system profile, not via PATH: the
         startup-hooks unit is deliberately given policy.tools ONLY, not
         /run/current-system/sw/bin, so `command -v` would not see the
         wrappers even though the agent's login shell does. *)
      "ls /run/current-system/sw/bin > /work/marker-profile 2>&1 || true";
      (* The binaries themselves DO come through policy.tools: declaring
         an agent must put its package in the closure without the policy
         listing it in `tools`. *)
      "command -v claude > /work/marker-bins 2>&1 || true";
      "command -v codex >> /work/marker-bins 2>&1 || true";
      "codex --version > /work/marker-codex-version 2>&1 || true";
      (* configEnv: codex reads ~/.codex unless CODEX_HOME says else.
         Checked through a LOGIN shell, which is how the agent gets it —
         environment.variables lands in /etc/set-environment, sourced by
         /etc/profile, and a systemd unit's env never sees it. The tmux
         hook in the same profile is tty-guarded, so this stays
         non-interactive. *)
      "bash -lc 'printenv CODEX_HOME' > /work/marker-codex-home 2>&1 || true";
      "touch /work/marker-done";
    ]
    ~k:(fun project ->
      let profile = read_file (project ^ "/marker-profile") in
      let bins = read_file (project ^ "/marker-bins") in
      let has name =
        List.exists (fun l -> String.trim l = name)
          (String.split_on_char '\n' profile)
      in
      let version = String.trim (read_file (project ^ "/marker-codex-version")) in
      let codex_home = String.trim (read_file (project ^ "/marker-codex-home")) in
      assert_b "claude-run wrapper present" (has "claude-run");
      assert_b "codex-run wrapper present" (has "codex-run");
      assert_b "agent-run alias still present" (has "agent-run");
      assert_b "tmux present when multiplexed" (has "tmux");
      assert_b "vm-session present" (has "vm-session");
      assert_b "vm-attach present" (has "vm-attach");
      assert_b "claude binary in the closure" (contains "bin/claude" bins);
      assert_b "codex binary in the closure (not listed in tools)"
        (contains "bin/codex" bins);
      assert_b "codex actually runs in the guest"
        (contains "codex-cli" version || contains "0." version);
      assert_b "CODEX_HOME points at the guest config dir"
        (contains ".config/codex" codex_home);
      Printf.printf "    (codex %s; CODEX_HOME=%s)\n%!" version codex_home)
    ()

(* auth = 'bind with a NESTED configDir. Regression test for the bug the
   ephemeral cases structurally cannot see: agent-home-init runs as root
   with umask 077, so `mkdir -p ~/.config` left ~/.config root-owned 0700
   and the agent could not traverse into its own config dir — every file
   inside correct, the directory unreachable. codex reported
   "failed to read CODEX_HOME ... Permission denied (os error 13)".

   Boots claude ('symlinks, .claude — parent is $HOME) and codex
   ('writable, .config/codex — nested) together, so both configModes and
   both parent shapes are covered in one boot. *)
let test_bind_auth_nested_configdir () =
  let mkdir_p d = ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote d))) in
  let write path text =
    let oc = open_out path in output_string oc text; close_out oc
  in
  boot_and_run
    ~auth:"bind"
    ~extra_agents:[ "codex" ]
    ~setup_home:(fun home ->
      (* A host config dir for each agent, each with one identifiable
         file: claude's is symlinked in, codex's is a seedFile copy. *)
      mkdir_p (home ^ "/.claude");
      write (home ^ "/.claude/settings.json") {|{"hostSide":"claude"}|};
      mkdir_p (home ^ "/.config/codex");
      write (home ^ "/.config/codex/auth.json") {|{"hostSide":"codex"}|})
    ~startup_commands:[
      (* The traversal itself is the assertion: these fail with
         "Permission denied" when the parent chain is root-owned. *)
      "cat ~/.claude/settings.json > /work/m-claude-settings 2>&1 || true";
      "cat ~/.config/codex/auth.json > /work/m-codex-auth 2>&1 || true";
      "stat -c '%U %a' ~/.config > /work/m-config-parent 2>&1 || true";
      (* 'symlinks vs 'writable: claude's entries are links into the RO
         bind; codex's config dir IS the state namespace. *)
      "readlink ~/.claude/settings.json > /work/m-claude-link 2>&1 || true";
      "readlink -f ~/.config/codex > /work/m-codex-target 2>&1 || true";
      "touch /work/marker-done";
    ]
    ~k:(fun project ->
      let claude_settings = String.trim (read_file (project ^ "/m-claude-settings")) in
      let codex_auth = String.trim (read_file (project ^ "/m-codex-auth")) in
      let parent = String.trim (read_file (project ^ "/m-config-parent")) in
      let claude_link = String.trim (read_file (project ^ "/m-claude-link")) in
      let codex_target = String.trim (read_file (project ^ "/m-codex-target")) in
      assert_b "agent reads claude's bound settings"
        (claude_settings = {|{"hostSide":"claude"}|});
      assert_b "agent reads codex's seeded auth.json (nested parent traversable)"
        (codex_auth = {|{"hostSide":"codex"}|});
      assert_b "~/.config belongs to the agent, not root"
        (not (contains "root" parent));
      assert_b "claude's config entries are symlinks into the RO bind"
        (contains "/var/lib/claude/settings.json" claude_link);
      assert_b "codex's config dir resolves into the state namespace"
        (contains "/var/lib/vm-launcher-state/codex" codex_target);
      Printf.printf "    (~/.config = %s; codex home -> %s)\n%!" parent codex_target)
    ()

(* agent.syncFiles: files the agent replaces with write-temp +
   rename (claude's .credentials.json), which a stateFiles symlink can't
   persist. Pins all three halves:
   - the RO bind's copy is NOT linked in (the host's file is present in
     the fake $HOME and must not be what the guest sees);
   - a non-empty saved copy is restored at boot as a regular file;
   - an atomic replace inside the guest is copied back to the state dir
     by agent-sync.path — checked from the guest AND on the host. *)
let test_sync_files () =
  let mkdir_p d = ignore (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote d))) in
  let write path text =
    let oc = open_out path in output_string oc text; close_out oc
  in
  let probe = "sync-probe.json" in
  let host_state home =
    home ^ "/.local/state/microvm/project/claude/" ^ probe
  in
  boot_and_run
    ~auth:"bind"
    ~sync_files:[ probe ]
    ~setup_home:(fun home ->
      mkdir_p (home ^ "/.claude");
      write (home ^ "/.claude/" ^ probe) "from-host-bind";
      mkdir_p (Filename.dirname (host_state home));
      write (host_state home) "saved-from-last-boot")
    ~startup_commands:[
      (* Both units up: an ordering cycle between them once made systemd
         drop one of the two start jobs, at random. *)
      "systemctl is-active agent-home-init.service agent-sync.path \
       > /work/m-sync-units 2>&1 || true";
      "readlink ~/.claude/" ^ probe ^ " > /work/m-sync-link 2>&1 || true";
      "cat ~/.claude/" ^ probe ^ " > /work/m-sync-boot 2>&1 || true";
      (* What claude does on login/refresh: write a temp, rename over. *)
      "printf rotated > ~/.claude/" ^ probe ^ ".tmp && mv -f ~/.claude/"
        ^ probe ^ ".tmp ~/.claude/" ^ probe;
      "for i in $(seq 1 50); do grep -q rotated /var/lib/vm-launcher-state/claude/"
        ^ probe ^ " 2>/dev/null && break; sleep 0.2; done";
      "cat /var/lib/vm-launcher-state/claude/" ^ probe
        ^ " > /work/m-sync-state 2>&1 || true";
      "touch /work/marker-done";
    ]
    ~k:(fun project ->
      let home = Filename.dirname project ^ "/home" in
      let link = String.trim (read_file (project ^ "/m-sync-link")) in
      let boot = String.trim (read_file (project ^ "/m-sync-boot")) in
      let state = String.trim (read_file (project ^ "/m-sync-state")) in
      let host = String.trim (read_file (host_state home)) in
      let units = String.trim (read_file (project ^ "/m-sync-units")) in
      assert_b "agent-home-init and agent-sync.path are both active"
        (units = "active\nactive");
      assert_b "sync file is a regular file, not a link into the RO bind"
        (link = "");
      assert_b "saved copy is restored at boot (not the host's)"
        (boot = "saved-from-last-boot");
      assert_b "atomic replace is copied back into the state dir (guest view)"
        (state = "rotated");
      assert_b "atomic replace reaches the host state dir" (host = "rotated");
      Printf.printf "    (boot=%s; state after rename=%s)\n%!" boot host)
    ()

(* Detached boot + ssh attach. The one case that exercises the VM
   as a SERVER: the launcher returns while the guest keeps running, and
   the operator reaches it over the host-only tap network — twice at
   once, to prove the sessions are independent rather than one mirrored
   screen.

   It also pins two things that were only found by running it:
   - the virtiofsds must outlive the launcher, or cloud-hypervisor dies
     with "vhost-user: can't connect to peer" seconds after the prompt
     comes back;
   - the guest's tmpfs root must be mode 0755, because sshd's
     StrictModes walks every directory to authorized_keys and refuses
     the login outright on a world-writable /. *)
let test_detached_ssh_attach () =
  with_temp_base @@ fun base ->
  let project = base ^ "/project" in
  let home = base ^ "/home" in
  List.iter (fun d -> Unix.mkdir d 0o755) [ project; home ];
  let policy = base ^ "/microvm.ncl" in
  write_policy ~path:policy ~project ~env_vars:[]
    ~startup_commands:[ "touch /work/marker-done" ] ();

  let pid =
    spawn_launcher
      ~env_overrides:
        [ ("VM_LAUNCHER_FLAKE", resolved_flake ()); ("HOME", home) ]
      [ "--policy"; policy; "--fast"; "--detach" ]
  in
  (* --detach returns as soon as the VM is spawned, unlike every other
     case where the launcher runs for the VM's whole life. *)
  let _, status = Unix.waitpid [] pid in
  (match status with
   | Unix.WEXITED 0 -> ()
   | _ -> failwith "launcher did not exit 0 after --detach");

  (* Find the session it left behind: the launcher is gone, so the
     state dir + attach.json are the only handle. *)
  let state_dir =
    Printf.sprintf "%s/session-%d" state_base pid
  in
  let attach_json = state_dir ^ "/attach.json" in
  if not (Sys.file_exists attach_json) then
    failwith ("no attach.json at " ^ attach_json);
  let json = Yojson.Safe.from_file attach_json in
  let str k =
    match json with
    | `Assoc kvs -> (
        match List.assoc_opt k kvs with Some (`String v) -> v | _ -> "")
    | _ -> ""
  in
  let int_ k =
    match json with
    | `Assoc kvs -> (
        match List.assoc_opt k kvs with Some (`Int v) -> v | _ -> -1)
    | _ -> -1
  in
  let target = Printf.sprintf "%s@%s" (str "user") (str "guestIp") in
  let runner_pid = int_ "runnerPid" in
  let ssh_cmd remote =
    Printf.sprintf
      "ssh -i %s/id_ed25519 -o IdentitiesOnly=yes \
       -o UserKnownHostsFile=%s/known_hosts -o StrictHostKeyChecking=yes \
       -o ConnectTimeout=5 -o LogLevel=ERROR %s %s"
      state_dir state_dir target (Filename.quote remote)
  in
  Fun.protect
    ~finally:(fun () ->
      (* Whatever happens, do not leave a VM running: nothing else will
         reap it, since the launcher already exited. *)
      (try Unix.kill runner_pid Sys.sigterm with Unix.Unix_error _ -> ());
      (* Release ONLY this VM's detached slot claim. state_base
         is the host's real /run/vm-launcher, so rm-ing slot-*.detached
         wholesale erases the claims of every OTHER detached VM — a
         live user session's included — and its slot then gets handed
         to the next launch under a still-running VM: a same-subnet
         collision. Match markers by our runner pid instead. *)
      Array.iter
        (fun name ->
          if String.length name > 5
             && String.sub name 0 5 = "slot-"
             && Filename.check_suffix name ".detached"
          then
            let path = state_base ^ "/" ^ name in
            match int_of_string_opt (String.trim (read_file path)) with
            | Some p when p = runner_pid ->
                (try Sys.remove path with Sys_error _ -> ())
            | _ | (exception Sys_error _) -> ())
        (try Sys.readdir state_base with Sys_error _ -> [||]))
    (fun () ->
      (* `ls`'s row for this session: the readiness split (booting vs
         detached) is judged by probing the guest's sshd, so only a real
         boot can check it. Same env as the launch, so it reads the same
         registry. *)
      let ls_row () =
        let f = base ^ "/ls-out" in
        ignore
          (Sys.command
             (Printf.sprintf "env HOME=%s %s ls --all > %s 2>&1"
                (Filename.quote home) (Filename.quote bin_path)
                (Filename.quote f)));
        String.split_on_char '\n' (read_file f)
        |> List.find_opt (contains (str "id"))
        |> Option.value ~default:""
      in
      let early = ls_row () in
      assert_b "ls shows the fresh VM as booting or detached"
        (contains "booting" early || contains "detached" early);
      Printf.printf "    (ls right after --detach: %s)\n%!"
        (if contains "booting" early then "booting" else "detached");

      (* sshd comes up a little after the launcher returns. *)
      let rec wait n =
        if n > 40 then failwith "ssh never became reachable (40 tries)"
        else if
          Sys.command (ssh_cmd "true" ^ " >/dev/null 2>&1") = 0
        then ()
        else (Unix.sleepf 5.0; wait (n + 1))
      in
      wait 0;

      let ready = ls_row () in
      assert_b "ls shows the VM detached (not booting) once sshd answers"
        (contains "detached" ready && not (contains "booting" ready));

      let out_file = base ^ "/ssh-out" in
      let rc =
        Sys.command
          (Printf.sprintf "%s > %s 2>&1" (ssh_cmd "whoami; hostname") out_file)
      in
      assert_b "ssh command succeeded" (rc = 0);
      let out = read_file out_file in
      assert_b "runs as the guest agent user, not root"
        (not (contains "root" out));

      (* Two at once: a mirrored console could not do this. *)
      let a_file = base ^ "/a" and b_file = base ^ "/b" in
      let a_cmd =
        Printf.sprintf "%s > %s 2>&1 &" (ssh_cmd "sleep 6; echo A-done") a_file
      in
      ignore (Sys.command a_cmd);
      Unix.sleepf 1.0;
      let rc_b =
        Sys.command
          (Printf.sprintf "%s > %s 2>&1" (ssh_cmd "echo B-done") b_file)
      in
      assert_b "second session ran while the first was still open" (rc_b = 0);
      assert_b "B finished independently" (contains "B-done" (read_file b_file));
      Unix.sleepf 8.0;
      assert_b "A finished too" (contains "A-done" (read_file a_file));

      (* The VM is still up after all that: detached means detached. *)
      assert_b "runner still alive"
        (try Unix.kill runner_pid 0; true with _ -> false);
      Printf.printf "    (attached twice to %s; runner pid %d)\n%!" target
        runner_pid)

(* Plain launch on a terminal: boot detached, attach this terminal
   over ssh, and on logout leave the VM RUNNING with a note saying how to
   reattach / stop it — instead of the console logout powering it off.
   `script` supplies the pty the launcher needs to take this path; the
   guest shell's "exit" is queued on it once the VM's sshd answers. *)
let test_terminal_logout_keeps_vm () =
  with_temp_base @@ fun base ->
  let project = base ^ "/project" in
  let home = base ^ "/home" in
  List.iter (fun d -> Unix.mkdir d 0o755) [ project; home ];
  let policy = base ^ "/microvm.ncl" in
  write_policy ~path:policy ~project ~env_vars:[]
    ~startup_commands:[ "touch /work/marker-done" ] ();
  List.iter (fun (k, v) -> Unix.putenv k v)
    [ ("VM_LAUNCHER_FLAKE", resolved_flake ()); ("HOME", home) ];
  let out_file = base ^ "/term-out" in
  let in_r, in_w = Unix.pipe ~cloexec:false () in
  Unix.set_close_on_exec in_w;
  let out_fd =
    Unix.openfile out_file [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644
  in
  let cmd =
    String.concat " "
      (List.map Filename.quote [ bin_path; "--policy"; policy; "--fast" ])
  in
  let script_pid =
    Unix.create_process "script"
      [| "script"; "-qefc"; cmd; "/dev/null" |] in_r out_fd out_fd
  in
  spawned_pids := script_pid :: !spawned_pids;
  Unix.close in_r;
  Unix.close out_fd;
  (* This session's attach.json, found by project (the launcher's pid —
     which names the state dir — is script's child, not ours). *)
  let find_session () =
    Array.fold_left
      (fun acc name ->
        match acc with
        | Some _ -> acc
        | None ->
            let dir = state_base ^ "/" ^ name in
            let j = dir ^ "/attach.json" in
            if Sys.file_exists j
               && contains (Printf.sprintf "%S" project) (read_file j)
            then Some (dir, Yojson.Safe.from_file j)
            else None)
      None
      (try Sys.readdir state_base with Sys_error _ -> [||])
  in
  let field j k =
    match j with `Assoc kvs -> List.assoc_opt k kvs | _ -> None
  in
  let runner = ref (-1) in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.close in_w with _ -> ());
      if !runner > 0 then
        (try Unix.kill !runner Sys.sigterm with Unix.Unix_error _ -> ());
      (try Unix.kill script_pid Sys.sigkill with Unix.Unix_error _ -> ());
      (try ignore (Unix.waitpid [] script_pid) with _ -> ());
      Array.iter
        (fun name ->
          if Filename.check_suffix name ".detached" then
            let path = state_base ^ "/" ^ name in
            match int_of_string_opt (String.trim (read_file path)) with
            | Some p when p = !runner ->
                (try Sys.remove path with Sys_error _ -> ())
            | _ | (exception Sys_error _) -> ())
        (try Sys.readdir state_base with Sys_error _ -> [||]))
    (fun () ->
      (* Generous: the first run builds the guest closure. *)
      let deadline = Unix.gettimeofday () +. 1500.0 in
      let rec wait_session () =
        match find_session () with
        | Some s -> s
        | None ->
            if Unix.gettimeofday () > deadline then
              failwith "launcher never wrote attach.json";
            (match Unix.waitpid [ Unix.WNOHANG ] script_pid with
             | 0, _ -> ()
             | _ ->
                 prerr_string (read_file out_file);
                 failwith "launcher exited before the VM came up");
            Unix.sleepf 2.0; wait_session ()
      in
      let state_dir, json = wait_session () in
      (match field json "runnerPid" with
       | Some (`Int p) -> runner := p
       | _ -> failwith "attach.json has no runnerPid");
      let id =
        match field json "id" with Some (`String s) -> s | _ -> ""
      in
      assert_b "the auto-attached VM is recorded as detached"
        (field json "detached" = Some (`Bool true));
      (* Wait for the guest's sshd ourselves, then queue the logout. *)
      let target =
        match (field json "user", field json "guestIp") with
        | Some (`String u), Some (`String ip) -> u ^ "@" ^ ip
        | _ -> failwith "attach.json has no user/guestIp"
      in
      let probe =
        Printf.sprintf
          "ssh -i %s/id_ed25519 -o IdentitiesOnly=yes \
           -o UserKnownHostsFile=%s/known_hosts -o StrictHostKeyChecking=yes \
           -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR %s true \
           >/dev/null 2>&1"
          state_dir state_dir target
      in
      let rec wait_ssh n =
        if n > 60 then failwith "guest sshd never answered"
        else if Sys.command probe = 0 then ()
        else (Unix.sleepf 3.0; wait_ssh (n + 1))
      in
      wait_ssh 0;
      Unix.sleepf 3.0;
      ignore (Unix.write_substring in_w "exit\n" 0 5);
      (* The launcher must return once the guest shell exits. *)
      let rec wait_exit t =
        match Unix.waitpid [ Unix.WNOHANG ] script_pid with
        | 0, _ ->
            if t > 120.0 then failwith "launcher did not return after logout"
            else (Unix.sleepf 1.0; wait_exit (t +. 1.0))
        | _ -> ()
      in
      wait_exit 0.0;
      let out = read_file out_file in
      assert_b "VM still running after the logout"
        (try Unix.kill !runner 0; true with _ -> false);
      assert_b "exit note names the reattach command"
        (contains ("vm-launcher attach " ^ id) out);
      assert_b "exit note names the stop command"
        (contains ("vm-launcher down " ^ id) out);
      (* And `down` is what ends it. *)
      let rc =
        Sys.command
          (Printf.sprintf "%s down %s >/dev/null 2>&1"
             (Filename.quote bin_path) (Filename.quote id))
      in
      assert_b "`vm-launcher down` succeeds" (rc = 0);
      assert_b "VM gone after down"
        (not (try Unix.kill !runner 0; true with _ -> false));
      Printf.printf "    (logout left %s running; down stopped it)\n%!" id)

let cases = [
  "e2e-env-vars-reach-agent-shell", test_env_vars_reach_agent_shell;
  "e2e-terminal-logout-keeps-vm", test_terminal_logout_keeps_vm;
  (* The VM as a server: boot detached, attach twice, stay up. *)
  "e2e-detached-ssh-attach", test_detached_ssh_attach;
  (* Multi-agent: claude + codex in one VM, with tmux. *)
  "e2e-multi-agent", test_multi_agent;
  (* The only bind-auth case: covers agent-home-init, which every
     ephemeral case skips entirely. *)
  "e2e-bind-auth-nested-configdir", test_bind_auth_nested_configdir;
  "e2e-sync-files", test_sync_files;
  "e2e-console-hvc0-wires-through", test_console_hvc0_wires_through;
  "e2e-console-ttys0-fallback", test_console_ttys0_fallback;
  (* No boot needed — queue + handover happen before the guest
     closure builds (the queued launcher is killed mid-build). *)
  "e2e-second-launcher-queues", test_second_launcher_queues;
  (* Operator egress overrides: unfenced (direct) + airgap (no egress). *)
  "e2e-egress-noblock", test_egress_noblock;
  "e2e-egress-block", test_egress_block;
  (* Last FAST case — ends the --fast phase with a real network curl. *)
  "e2e-egress-allowlist", test_egress_allowlist;
  (* Keep last overall: proves the non-fast image boots AND egresses. *)
  "e2e-non-fast-egress", test_non_fast_egress;
]

(* e2e-concurrent-vms is opt-in (see its comment) and
   VM_LAUNCHER_E2E_ONLY=<case-name> narrows a run to one case —
   useful for iterating on a single boot path without paying for the
   whole suite. *)
let cases =
  let all =
    match Sys.getenv_opt "VM_LAUNCHER_E2E_CONCURRENT" with
    | Some "1" -> cases @ [ "e2e-concurrent-vms", test_concurrent_vms ]
    | _ -> cases
  in
  match Sys.getenv_opt "VM_LAUNCHER_E2E_ONLY" with
  | Some spec when spec <> "" ->
    (* Comma-separated list of case names (whitespace trimmed) — e.g.
       run only the --fast cases by naming them all and omitting
       e2e-non-fast-egress. A single name still works. *)
    let wanted =
      String.split_on_char ',' spec
      |> List.map String.trim
      |> List.filter (fun s -> s <> "")
    in
    (match List.filter (fun (n, _) -> List.mem n wanted) all with
     | [] ->
       Printf.eprintf
         "VM_LAUNCHER_E2E_ONLY=%s matches no case; known cases: %s\n"
         spec (String.concat ", " (List.map fst all));
       exit 1
     | l -> l)
  | _ -> all

let () =
  match Sys.getenv_opt "VM_LAUNCHER_E2E" with
  | Some "1" ->
    install_signal_handlers ();
    let failed = ref 0 in
    List.iter
      (fun (name, f) ->
        Printf.printf "running %s ...\n%!" name;
        (try
           f ();
           Printf.printf "ok    %s\n%!" name
         with
         | Failure msg ->
           incr failed;
           Printf.printf "FAIL  %s: %s\n%!" name msg
         | e ->
           incr failed;
           Printf.printf "FAIL  %s: %s\n%!" name (Printexc.to_string e)))
      cases;
    if !failed > 0 then exit 1
  | _ ->
    Printf.printf
      "skip  e2e-vm tests (set VM_LAUNCHER_E2E=1 to run; \
       requires KVM + $VM_LAUNCHER_FLAKE pointing at a guest \
       flake, default this checkout)\n";
    exit 0
