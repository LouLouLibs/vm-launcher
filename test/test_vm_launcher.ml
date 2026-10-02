(* Snapshot + roundtrip tests for Policy.

   Fixtures are real Nickel-exported microvm.ncl files from local projects
   (sample-project, VM-TESTING). Dune copies them next to the test binary so
   relative paths resolve in both `dune test` and `dune runtest`. *)

open Vm_launcher_lib

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let parse_fixture name =
  let json = Yojson.Safe.from_string (read_file ("fixtures/" ^ name)) in
  match Policy.of_json json with
  | Ok p -> (json, p)
  | Error msg -> failwith (Printf.sprintf "fixture %s: %s" name msg)

let assert_b label cond =
  if not cond then failwith (Printf.sprintf "assertion failed: %s" label)

let test_policy_startup_default () =
  (* Fixture has no [startup] field — parser must default to empty. *)
  let _, p = parse_fixture "sample-project.json" in
  assert_b "startup.commands empty by default" (p.startup.commands = []);
  assert_b "startup.tools empty by default = inherit policy.tools"
    (p.startup.tools = []);
  assert_b "startup.log_file None by default" (p.startup.log_file = None)

(* Local substring helper — the file-level [contains] is defined later
   in the file (after [test_render_egress_hosts]) and we run before
   that block. *)
let local_contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i =
    i + n <= h && (String.sub haystack i n = needle || loop (i + 1))
  in
  loop 0

let test_policy_startup_parse () =
  (* Hand-build a policy JSON with an explicit startup block — covers
     the full grammar: empty commands, single warn (default), explicit
     block, explicit warn, logFile set + unset. Policy.to_json always
     returns an [`Assoc], so the [_] arm is here only to satisfy
     the exhaustiveness check. *)
  let mk_with_startup startup_json =
    let _, base = parse_fixture "vm-testing.json" in
    let base_json = Policy.to_json base in
    let kvs =
      match base_json with
      | `Assoc kvs -> kvs
      | _ -> failwith "Policy.to_json did not return `Assoc"
    in
    let kvs =
      List.filter (fun (k, _) -> k <> "startup") kvs
      @ [ "startup", startup_json ]
    in
    match Policy.of_json (`Assoc kvs) with
    | Ok p -> p
    | Error e -> failwith ("parse: " ^ e)
  in
  (* Empty startup block. *)
  let p = mk_with_startup (`Assoc [ "commands", `List []; "logFile", `String "" ]) in
  assert_b "empty commands" (p.startup.commands = []);
  assert_b "empty logFile → None" (p.startup.log_file = None);
  (* Two commands: implicit warn (no onFailure key) + explicit block. *)
  let two =
    `Assoc [
      "commands", `List [
        `Assoc [ "command", `String "uv sync" ];
        `Assoc [
          "command", `String "test -f data/required.parquet";
          "onFailure", `String "block";
        ];
      ];
      "logFile", `String "/work/.startup.log";
    ]
  in
  let p = mk_with_startup two in
  assert_b "two commands" (List.length p.startup.commands = 2);
  let c1 = List.nth p.startup.commands 0 in
  let c2 = List.nth p.startup.commands 1 in
  assert_b "first command body" (c1.command = "uv sync");
  assert_b "first defaults to warn"
    (c1.on_failure = Policy.On_failure_warn);
  assert_b "second command body"
    (c2.command = "test -f data/required.parquet");
  assert_b "second is block"
    (c2.on_failure = Policy.On_failure_block);
  assert_b "logFile parsed" (p.startup.log_file = Some "/work/.startup.log");
  (* Explicit tools list parsed verbatim. *)
  let with_tools =
    `Assoc [
      "commands", `List [];
      "tools", `List [ `String "coreutils"; `String "curl"; `String "git" ];
      "logFile", `String "";
    ]
  in
  let p = mk_with_startup with_tools in
  assert_b "tools parsed" (p.startup.tools = [ "coreutils"; "curl"; "git" ]);
  (* Bad onFailure value surfaces a parse error mentioning the field. *)
  let bad =
    `Assoc [
      "commands", `List [
        `Assoc [
          "command", `String "x";
          "onFailure", `String "panic";
        ];
      ];
      "logFile", `String "";
    ]
  in
  let _, base = parse_fixture "vm-testing.json" in
  let kvs =
    match Policy.to_json base with
    | `Assoc kvs -> kvs
    | _ -> failwith "unreachable"
  in
  let bad_policy_json =
    `Assoc (
      List.filter (fun (k, _) -> k <> "startup") kvs
      @ [ "startup", bad ])
  in
  (match Policy.of_json bad_policy_json with
   | Error msg ->
       assert_b "error mentions startup path"
         (local_contains "startup" msg);
       assert_b "error mentions the bad value"
         (local_contains "panic" msg || local_contains "warn" msg)
   | Ok _ -> failwith "expected Error on bad onFailure")

let test_policy_startup_roundtrip () =
  let _, p = parse_fixture "vm-testing.json" in
  let p' = { p with startup = {
    commands = [
      { command = "uv sync"; on_failure = On_failure_warn };
      { command = "true"; on_failure = On_failure_block };
    ];
    tools = [ "coreutils"; "curl" ];
    log_file = Some "/work/.log";
  } } in
  let j = Policy.to_json p' in
  match Policy.of_json j with
  | Error msg -> failwith ("roundtrip: " ^ msg)
  | Ok p'' ->
      assert_b "roundtrip preserves startup" (p''.startup = p'.startup)

let test_sample_project () =
  let _, p = parse_fixture "sample-project.json" in
  assert_b "project" (p.project = "/home/alice/projects/myproject");
  assert_b "work.default = Rw" (p.work.default = Rw);
  assert_b "work.readOnly" (p.work.read_only = [ "input"; "env/vm" ]);
  assert_b "egress non-empty" (List.length p.egress.hosts > 5);
  assert_b "auth = Bind" (p.auth = Bind);
  assert_b "resources" (p.resources.vcpu = 12 && p.resources.mem_mb = 64000);
  assert_b "secrets count" (List.length p.secrets = 1);
  let s = List.hd p.secrets in
  assert_b "secret env" (s.env = "GH_TOKEN");
  assert_b "secret scope defaults to Agent_env"
    (s.scope = Agent_env);
  assert_b "git.allowedGithubOrgs"
    (p.git.allowed_github_orgs = [ "LouLouLibs"; "alice" ]);
  assert_b "git.name None when empty" (p.git.name = None);
  assert_b "stateDir None when empty" (p.state_dir = None);
  assert_b "agent.instructions None when empty" (p.agent.instructions = None);
  assert_b "julia.env" (p.julia.env = "env/julia");
  assert_b "r.packages empty" (p.r.packages = []);
  assert_b "proxyAuth defaults to []" (p.proxy_auth = []);
  (* Fixture predates the console field; parser defaults to Console_hvc0
     (matches the contract's `default = 'hvc0`). *)
  assert_b "console defaults to Console_hvc0" (p.console = Console_hvc0)

let test_vm_testing () =
  let _, p = parse_fixture "vm-testing.json" in
  assert_b "project" (p.project = "/home/alice/projects/VM-TESTING");
  assert_b "secrets empty" (p.secrets = []);
  assert_b "small VM" (p.resources.vcpu = 2);
  assert_b "tools small" (List.length p.tools = 5);
  assert_b "console defaults to Console_hvc0" (p.console = Console_hvc0)

(* Explicit console values: parser accepts both "hvc0" and "ttyS0",
   rejects anything else with a message that mentions the field. Built
   the same way as test_policy_startup_parse — clone a known-good
   policy, splice in the field under test, re-parse. *)
let test_policy_console () =
  let _, base = parse_fixture "vm-testing.json" in
  let mk_with_console value =
    let base_kvs =
      match Policy.to_json base with
      | `Assoc kvs -> kvs
      | _ -> failwith "Policy.to_json did not return `Assoc"
    in
    let kvs =
      List.filter (fun (k, _) -> k <> "console") base_kvs
      @ [ "console", value ]
    in
    Policy.of_json (`Assoc kvs)
  in
  (match mk_with_console (`String "hvc0") with
   | Ok p -> assert_b "explicit hvc0" (p.console = Console_hvc0)
   | Error e -> failwith ("hvc0 parse: " ^ e));
  (match mk_with_console (`String "ttyS0") with
   | Ok p -> assert_b "explicit ttyS0" (p.console = Console_ttys0)
   | Error e -> failwith ("ttyS0 parse: " ^ e));
  (match mk_with_console (`String "nope") with
   | Ok _ -> failwith "expected Error on bad console value"
   | Error msg ->
       assert_b "error mentions console field"
         (local_contains "console" msg);
       assert_b "error mentions the bad value"
         (local_contains "nope" msg));
  (* Roundtrip with explicit ttyS0 preserves the value. *)
  match mk_with_console (`String "ttyS0") with
  | Error e -> failwith ("ttyS0 setup: " ^ e)
  | Ok p ->
      let j = Policy.to_json p in
      match Policy.of_json j with
      | Error e -> failwith ("ttyS0 roundtrip: " ^ e)
      | Ok p' ->
          assert_b "ttyS0 roundtrips" (p'.console = Console_ttys0)

(* Roundtrip: parse → serialize → parse should fixed-point. We compare the
   typed records, not the raw JSON — to_json may reorder keys, and that's
   fine as long as the parsed shape matches. *)
let test_roundtrip name () =
  let _, p1 = parse_fixture name in
  let j2 = Policy.to_json p1 in
  match Policy.of_json j2 with
  | Error msg -> failwith (Printf.sprintf "roundtrip parse failed: %s" msg)
  | Ok p2 ->
      assert_b (name ^ " roundtrip fixed-point") (p1 = p2)

let test_missing_field () =
  let j = Yojson.Safe.from_string {|{}|} in
  match Policy.of_json j with
  | Error _ -> ()
  | Ok _ -> failwith "expected parse error for empty object"

let test_bad_auth () =
  let j = Yojson.Safe.from_string {|{"auth": "nope"}|} in
  match Policy.of_json j with
  | Error msg
    when String.length msg > 0
         && (String.length msg < 200) -> ()
  | Error _ -> ()
  | Ok _ -> failwith "expected parse error for bad auth value"

(* Session lifecycle tests. Each one uses a fresh temp dir as state_base
   so they don't touch the host's real /run/vm-launcher or each other. *)

let rm_rf_safe path =
  if String.length path > 4 (* paranoia: never rm-rf "/" or "/tmp" *)
  then ignore (Sys.command (Printf.sprintf "rm -rf -- %s" (Filename.quote path)))

let with_temp_base f =
  let base = Filename.temp_file "vm-launcher-test-" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  Fun.protect ~finally:(fun () -> rm_rf_safe base) (fun () -> f base)

(* Snapshot/restore process-global env vars across a test body.
   Test order would otherwise leak HOME/etc into siblings — e.g. a
   later test reading $HOME could find a dangling temp-dir path. *)
let with_env name value f =
  let prev = try Some (Sys.getenv name) with Not_found -> None in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv name v
      | None ->
          (* No portable unsetenv in OCaml stdlib pre-5.x; setting to ""
             is the documented-safe equivalent here — putenv with "" on
             Linux removes the variable. *)
          Unix.putenv name "")
    f

let lexists path =
  try ignore (Unix.lstat path); true
  with Unix.Unix_error _ -> false

let test_session_creates_dir () =
  with_temp_base @@ fun base ->
  Session.with_state ~state_base:base ~keep_state:false ~f:(fun s ->
    assert_b "state_dir exists" (Sys.file_exists (Session.state_dir s));
    assert_b "etc_dir exists" (Sys.file_exists (Session.etc_dir s));
    assert_b "state_dir under base"
      (String.starts_with ~prefix:(base ^ "/session-") (Session.state_dir s));
    assert_b "pid matches" (Session.pid s = Unix.getpid ()))

let test_session_cleanup () =
  with_temp_base @@ fun base ->
  let captured = ref "" in
  Session.with_state ~state_base:base ~keep_state:false ~f:(fun s ->
    captured := Session.state_dir s);
  assert_b "state_dir gone after cleanup" (not (lexists !captured))

let test_session_cleanup_on_exception () =
  with_temp_base @@ fun base ->
  let captured = ref "" in
  (try
     Session.with_state ~state_base:base ~keep_state:false ~f:(fun s ->
       captured := Session.state_dir s;
       failwith "boom")
   with Failure _ -> ());
  assert_b "state_dir gone after cleanup-on-raise" (not (lexists !captured))

let test_session_keep_state () =
  with_temp_base @@ fun base ->
  let captured = ref "" in
  Session.with_state ~state_base:base ~keep_state:true ~f:(fun s ->
    captured := Session.state_dir s);
  assert_b "state_dir preserved" (Sys.file_exists !captured)

let test_set_as_current () =
  with_temp_base @@ fun base ->
  Session.with_state ~state_base:base ~keep_state:false ~f:(fun s ->
    ignore (Session.acquire_slot ~slots:[ 0 ] s);
    Session.set_as_current s;
    let link = base ^ "/current-session-0" in
    let target = Unix.readlink link in
    assert_b "symlink points at us" (target = Session.state_dir s));
  assert_b "symlink removed on cleanup"
    (not (lexists (base ^ "/current-session-0")))

let test_current_session_not_ours () =
  with_temp_base @@ fun base ->
  let link = base ^ "/current-session-0" in
  Unix.symlink "/some/other/path" link;
  Session.with_state ~state_base:base ~keep_state:false ~f:(fun s ->
    (* Hold slot 0 but never set_as_current: cleanup must still not
       remove a symlink that isn't ours. *)
    ignore (Session.acquire_slot ~slots:[ 0 ] s));
  (* The other session "owns" that symlink; we must not have removed it. *)
  assert_b "other session's symlink preserved" (lexists link);
  Unix.unlink link

let test_register_child () =
  with_temp_base @@ fun base ->
  (* Fork a child that sleeps; register it; verify cleanup kills it.
     Sleep 30s — generous so the test isn't racy under load. *)
  let pid =
    match Unix.fork () with
    | 0 ->
        (* child: in-process sleep (no /bin/sleep on this host) *)
        (try Unix.sleep 30 with _ -> ()); Unix._exit 0
    | n -> n
  in
  Session.with_state ~state_base:base ~keep_state:false ~f:(fun s ->
    Session.register_child s pid);
  (* After cleanup, the child should be reapable (zombie) or already gone.
     waitpid with WNOHANG returns 0 if still running, pid if exited. *)
  let dead =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ -> false      (* still running *)
    | _, _ -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  if not dead then begin
    (* Give it a beat; SIGKILL is async. *)
    Unix.sleepf 0.1;
    let dead2 =
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ -> false
      | _, _ -> true
      | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
    in
    if not dead2 then begin
      (try Unix.kill pid Sys.sigkill with _ -> ());
      failwith "register_child cleanup did not kill the child"
    end
  end

let test_register_child_sigterm_grace () =
  with_temp_base @@ fun base ->
  (* A child that handles SIGTERM and exits with rc=42. If
     Sigterm_then_kill works, the child gets SIGTERM, runs its trap,
     and exits cleanly — we should observe WEXITED 42, not WSIGNALED.
     Using bash for the SIGTERM trap; if the grace path SIGKILL'd
     instead we'd see WSIGNALED with no rc. *)
  let pid =
    match Unix.fork () with
    | 0 ->
        (* `wait` IS interruptible by signal — when SIGTERM arrives,
           wait returns, the trap fires, exit 42 propagates. A naive
           `sleep 30` with a trap doesn't work because sh defers the
           trap until the foreground command completes. *)
        Unix.execv "/bin/sh"
          [| "sh"; "-c"; "trap 'exit 42' TERM; sleep 30 & wait" |]
    | n -> n
  in
  (* Tiny wait for the child to install its trap before we kill it. *)
  Unix.sleepf 0.2;
  Session.with_state ~state_base:base ~keep_state:false ~f:(fun s ->
    Session.register_child ~mode:(Sigterm_then_kill 3.0) s pid);
  (* with_state has exited → cleanup ran → child should have caught
     SIGTERM, exited 42, and been reaped (waitpid in sigterm_then_kill). *)
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | exception Unix.Unix_error (Unix.ECHILD, _, _) ->
      (* Already reaped by sigterm_then_kill's WNOHANG poll. Can't
         inspect the exit code post-hoc; the contract is "graceful
         shutdown observed" and ECHILD here means we got there. *)
      ()
  | 0, _ -> failwith "child still running after Sigterm_then_kill"
  | _, Unix.WEXITED 42 -> ()
  | _, Unix.WEXITED n ->
      failwith (Printf.sprintf "child exited rc=%d, expected 42" n)
  | _, Unix.WSIGNALED _ ->
      failwith "child was SIGKILL'd despite Sigterm_then_kill grace"
  | _, Unix.WSTOPPED _ -> failwith "child stopped (unexpected)"

let test_with_signals_blocked () =
  (* Use SIGUSR1 so we don't fight the real launcher signal handlers
     (SIGINT/SIGTERM are managed by Session.with_state). *)
  let fired = ref false in
  let prev = Sys.signal Sys.sigusr1
    (Sys.Signal_handle (fun _ -> fired := true)) in
  Fun.protect
    ~finally:(fun () -> Sys.set_signal Sys.sigusr1 prev)
    (fun () ->
      Session.with_signals_blocked [ Sys.sigusr1 ] (fun () ->
        Unix.kill (Unix.getpid ()) Sys.sigusr1;
        (* OCaml delivers async signals at safe points, but blocked
           signals are queued by the kernel and don't reach the
           runtime at all. Brief sleep to make sure no safe-point
           delivery happens. *)
        Unix.sleepf 0.05;
        assert_b "signal not delivered while blocked" (not !fired));
      (* After unblock, signal should be delivered very soon. *)
      Unix.sleepf 0.05;
      assert_b "signal delivered after unblock" !fired)

let test_register_child_grace_timeout_falls_back_to_kill () =
  with_temp_base @@ fun base ->
  (* A child that IGNORES SIGTERM (trap '' TERM). Sigterm_then_kill
     should then fall back to SIGKILL after the grace window — without
     that the child would survive cleanup. *)
  let pid =
    match Unix.fork () with
    | 0 ->
        Unix.execv "/bin/sh"
          [| "sh"; "-c"; "trap '' TERM; sleep 30" |]
    | n -> n
  in
  Unix.sleepf 0.2;
  Session.with_state ~state_base:base ~keep_state:false ~f:(fun s ->
    (* Short timeout — test runs fast. *)
    Session.register_child ~mode:(Sigterm_then_kill 0.5) s pid);
  (* Past the grace window: child should be SIGKILL'd. waitpid with
     WNOHANG: reaped already or about to be. *)
  Unix.sleepf 0.1;
  let dead =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ -> false
    | _, _ -> true
    | exception Unix.Unix_error (Unix.ECHILD, _, _) -> true
  in
  if not dead then begin
    (try Unix.kill pid Sys.sigkill with _ -> ());
    failwith "Sigterm_then_kill grace fallback didn't SIGKILL"
  end

(* Resolver: pure logic. The shell-out helpers (find_project_root,
   nickel_export, host_git_identity) are plumbing — tested elsewhere
   or via the CLI integration. *)

let test_tilde_expand () =
  with_env "HOME" "/home/test" @@ fun () ->
  assert_b "tilde expands" (Resolver.tilde_expand "~/foo" = "/home/test/foo");
  assert_b "absolute unchanged" (Resolver.tilde_expand "/etc" = "/etc");
  assert_b "relative unchanged" (Resolver.tilde_expand "foo" = "foo");
  assert_b "bare ~ unchanged" (Resolver.tilde_expand "~" = "~")

let test_default_policy () =
  let p = Resolver.default_policy ~project:"/x" in
  assert_b "project" (p.project = "/x");
  assert_b "default rw" (p.work.default = Rw);
  assert_b "claude-code in tools" (List.mem "claude-code" p.tools);
  assert_b "resources" (p.resources.vcpu = 4);
  assert_b "default julia env" (p.julia.env = "env/julia");
  assert_b "agent.preset" (p.agent.preset = "claude");
  assert_b "agent.command" (p.agent.command = "claude");
  assert_b "agent.flags" (p.agent.flags = [ "--dangerously-skip-permissions" ]);
  assert_b "agent.configDir" (p.agent.config_dir = ".claude");
  assert_b "agent.configGuest" (p.agent.config_guest = "/var/lib/claude");
  assert_b "agent.instructionsFile" (p.agent.instructions_file = "CLAUDE.md");
  assert_b "agent.config_host None at default" (p.agent.config_host = None);
  assert_b "no secrets" (p.secrets = []);
  assert_b "no proxyAuth" (p.proxy_auth = []);
  (* roundtrip the default to make sure it satisfies our own parser *)
  (match Policy.of_json (Policy.to_json p) with
   | Error msg -> failwith ("default policy fails round-trip: " ^ msg)
   | Ok p' -> assert_b "default-policy fixed point" (p = p'))

let test_resolve_source () =
  with_temp_base @@ fun base ->
  (* No override + empty project tree → Default. *)
  let r = Resolver.resolve_source ~project:base ~override:None in
  assert_b "no override, no convention file → Default" (r = Default);

  (* Override path exists → Override *)
  let override_path = base ^ "/custom.ncl" in
  let oc = open_out override_path in close_out oc;
  let r = Resolver.resolve_source ~project:base ~override:(Some override_path) in
  assert_b "override → Override"
    (match r with Override p when p = override_path -> true | _ -> false);

  (* Override that doesn't exist → Failure *)
  (try
     let _ =
       Resolver.resolve_source ~project:base
         ~override:(Some (base ^ "/missing.ncl"))
     in
     failwith "expected Failure on missing override"
   with Failure _ -> ())

let touch path =
  let dir = Filename.dirname path in
  let _ = Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote dir)) in
  let oc = open_out path in
  close_out oc

let test_discover_policy () =
  (* Nothing on disk → None (and resolve_source → Default). *)
  with_temp_base (fun base ->
      assert_b "empty tree → None"
        (Resolver.discover_policy ~project:base = None));

  (* Lone env/vm/microvm.ncl (singular) is found. *)
  with_temp_base (fun base ->
      touch (base ^ "/env/vm/microvm.ncl");
      assert_b "env/vm/microvm.ncl discovered"
        (Resolver.discover_policy ~project:base
         = Some (base ^ "/env/vm/microvm.ncl")));

  (* envs (plural) wins over env (singular). *)
  with_temp_base (fun base ->
      touch (base ^ "/env/vm/microvm.ncl");
      touch (base ^ "/envs/vm/microvm.ncl");
      assert_b "envs beats env"
        (Resolver.discover_policy ~project:base
         = Some (base ^ "/envs/vm/microvm.ncl")));

  (* environments/environment variants are searched too. *)
  with_temp_base (fun base ->
      touch (base ^ "/environment/vm/microvm.ncl");
      assert_b "environment/vm/microvm.ncl discovered"
        (Resolver.discover_policy ~project:base
         = Some (base ^ "/environment/vm/microvm.ncl")));

  (* Phase 1 -- any dir's microvm.ncl -- beats phase 2's ncl glob: a
     microvm.ncl under env/ outranks a foo.ncl under envs/. *)
  with_temp_base (fun base ->
      touch (base ^ "/envs/vm/foo.ncl");
      touch (base ^ "/env/vm/microvm.ncl");
      assert_b "microvm.ncl phase 1 beats ncl-glob phase 2"
        (Resolver.discover_policy ~project:base
         = Some (base ^ "/env/vm/microvm.ncl")));

  (* Phase 2 glob: no microvm.ncl anywhere, alphabetical first ncl wins,
     dir variants still tried in order. *)
  with_temp_base (fun base ->
      touch (base ^ "/env/vm/bbb.ncl");
      touch (base ^ "/envs/vm/zzz.ncl");
      assert_b "envs ncl beats env ncl in phase 2"
        (Resolver.discover_policy ~project:base
         = Some (base ^ "/envs/vm/zzz.ncl")));
  with_temp_base (fun base ->
      touch (base ^ "/envs/vm/bbb.ncl");
      touch (base ^ "/envs/vm/aaa.ncl");
      assert_b "alphabetical first ncl wins within a dir"
        (Resolver.discover_policy ~project:base
         = Some (base ^ "/envs/vm/aaa.ncl")))

let test_resolve_state_dir () =
  with_env "HOME" "/home/test" @@ fun () ->
  (* policy gives a path *)
  let r =
    Resolver.resolve_state_dir
      ~policy_state_dir:(Some "~/state")
      ~xdg_state_home:"/should/be/ignored"
      ~project_basename:"foo"
  in
  assert_b "policy path wins + tilde expanded" (r = "/home/test/state");

  (* policy empty → XDG fallback *)
  let r =
    Resolver.resolve_state_dir
      ~policy_state_dir:None
      ~xdg_state_home:"/home/test/.local/state"
      ~project_basename:"myproject"
  in
  assert_b "XDG fallback"
    (r = "/home/test/.local/state/microvm/myproject")

let test_marker_email () =
  assert_b "gmail style"
    (Resolver.marker_email "alice@gmail.com"
     = "alice+vmlaunch@gmail.com");
  assert_b "subaddressed"
    (Resolver.marker_email "bob+old@example.com"
     = "bob+old+vmlaunch@example.com");
  assert_b "no @ → fallback"
    (Resolver.marker_email "junk" = "vm-launcher@localhost");
  assert_b "@ at start → fallback"
    (Resolver.marker_email "@x" = "vm-launcher@localhost");
  assert_b "@ at end → fallback"
    (Resolver.marker_email "x@" = "vm-launcher@localhost")

let test_sanitize_hostname () =
  let eq label want got =
    assert_b (Printf.sprintf "%s: want %S got %S" label want got)
      (want = got)
  in
  eq "MyProject" "myproject"
    (Resolver.sanitize_hostname "MyProject");
  eq "my_project.workdir" "my-project-workdir"
    (Resolver.sanitize_hostname "my_project.workdir");
  eq "MIXED-Case_123" "mixed-case-123"
    (Resolver.sanitize_hostname "MIXED-Case_123");
  eq "leading dot dropped" "env"
    (Resolver.sanitize_hostname ".env");
  eq "trailing dot dropped" "x"
    (Resolver.sanitize_hostname "x.");
  eq "runs collapse" "a-b"
    (Resolver.sanitize_hostname "a___---...b");
  eq "all junk → vmlauncher" "vmlauncher"
    (Resolver.sanitize_hostname "....");
  eq "empty → vmlauncher" "vmlauncher"
    (Resolver.sanitize_hostname "");
  eq "single char kept" "x"
    (Resolver.sanitize_hostname "x");
  eq "digit-only kept" "42"
    (Resolver.sanitize_hostname "42")

let test_sanitize_username () =
  let eq label want got =
    assert_b (Printf.sprintf "%s: want %S got %S" label want got)
      (want = got)
  in
  (* Underscores are POSIX-legal in usernames; they survive. *)
  eq "underscore kept" "alice_vm"
    (Resolver.sanitize_username "alice_vm");
  eq "alice-vm passes through" "alice-vm"
    (Resolver.sanitize_username "alice-vm");
  eq "uppercased lowered" "alice-vm"
    (Resolver.sanitize_username "Alice-VM");
  eq "non-alnum collapsed" "weird-user"
    (Resolver.sanitize_username "weird@user");
  eq "long truncated to 32"
    "abcdefghij0123456789abcdefghij01"
    (Resolver.sanitize_username
       "abcdefghij0123456789abcdefghij012345abcdef");
  assert_b "truncation never leaves trailing dash"
    (let s = Resolver.sanitize_username
       "abcdefghij0123456789abcdefghij0-zzzzzz" in
     String.length s <= 32
     && s.[String.length s - 1] <> '-');
  eq "all junk → vmlauncher" "vmlauncher"
    (Resolver.sanitize_username "@@@@")

let test_resolve_guest () =
  (* Both blank → derive from project + host user. *)
  let g =
    Resolver.resolve_guest
      ~policy_guest:{ hostname = None; username = None }
      ~project:"/home/alice/projects/MyProject"
      ~host_user:(Some "alice")
  in
  assert_b "hostname derived" (g.hostname = Some "myproject");
  assert_b "username derived with -vm" (g.username = Some "alice-vm");
  (* No host user → fallback. *)
  let g =
    Resolver.resolve_guest
      ~policy_guest:{ hostname = None; username = None }
      ~project:"/x/foo"
      ~host_user:None
  in
  assert_b "username falls back to vmlauncher" (g.username = Some "vmlauncher");
  (* Explicit policy values pass through unchanged. *)
  let g =
    Resolver.resolve_guest
      ~policy_guest:{ hostname = Some "fixed"; username = Some "alice" }
      ~project:"/x/foo"
      ~host_user:(Some "ignored")
  in
  assert_b "policy hostname wins" (g.hostname = Some "fixed");
  assert_b "policy username wins" (g.username = Some "alice")

let test_resolve_git_identity () =
  let blank : Policy.git_identity =
    { name = None; email = None; allowed_github_orgs = [ "X" ] }
  in
  (* Both host values present *)
  let r =
    Resolver.resolve_git_identity ~policy_git:blank
      ~host_name:(Some "Alice") ~host_email:(Some "alice@example.com")
  in
  assert_b "host name → marked" (r.name = Some "Alice (vm-launcher)");
  assert_b "host email → marked" (r.email = Some "alice+vmlaunch@example.com");
  assert_b "allowed_github_orgs preserved" (r.allowed_github_orgs = [ "X" ]);

  (* Neither host value *)
  let r =
    Resolver.resolve_git_identity ~policy_git:blank ~host_name:None
      ~host_email:None
  in
  assert_b "no host name → vm-launcher" (r.name = Some "vm-launcher");
  assert_b "no host email → @localhost"
    (r.email = Some "vm-launcher@localhost");

  (* Policy explicit values win over host *)
  let policy : Policy.git_identity =
    {
      name = Some "Project Bot";
      email = Some "bot@proj.example";
      allowed_github_orgs = [];
    }
  in
  let r =
    Resolver.resolve_git_identity ~policy_git:policy
      ~host_name:(Some "Alice") ~host_email:(Some "alice@example.com")
  in
  assert_b "policy name wins" (r.name = Some "Project Bot");
  assert_b "policy email wins" (r.email = Some "bot@proj.example")

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
  loop 0

let test_render_egress_hosts () =
  let _, p = parse_fixture "sample-project.json" in
  let s = Render.egress_hosts p in
  assert_b "one host per line" (String.contains s '\n');
  assert_b "starts with api.anthropic" (String.length s > 0 && String.sub s 0 17 = "api.anthropic.com");
  assert_b "trailing newline" (s.[String.length s - 1] = '\n');
  assert_b "no empty lines" (not (contains "\n\n" s))

let test_render_instructions () =
  let _, p = parse_fixture "sample-project.json" in
  let md = Render.instructions ~agent:p.agent p in
  assert_b "title has project basename" (contains "myproject" md);
  assert_b "mentions egress allowlist" (contains "## Network egress" md);
  assert_b "lists at least one host"
    (contains "api.anthropic.com" md);
  assert_b "mentions JULIA_PROJECT" (contains "JULIA_PROJECT=/work/env/julia" md);
  assert_b "mentions microvm-loaded path"
    (contains "/etc/vm-launcher/microvm-loaded" md);
  (* The sample fixture has no agent.instructions → no project-specific section *)
  assert_b "no project-specific section when blank"
    (not (contains "Project-specific guidance" md))

(* The instructions only claim what the policy provides: no julia tool,
   no julia lines; no GH_TOKEN secret, no "GH_TOKEN is preset". A stock
   VM would otherwise be told about a JULIA_PROJECT and a depot that
   nothing set up. *)
let test_render_instructions_gated_on_policy () =
  let _, p = parse_fixture "sample-project.json" in
  let md = Render.instructions ~agent:p.agent p in
  assert_b "julia in tools → JULIA_PROJECT line" (contains "JULIA_PROJECT" md);
  assert_b "julia in tools → depot line" (contains "/work/.julia" md);
  assert_b "GH_TOKEN secret → gh line" (contains "GH_TOKEN` is preset" md);
  assert_b "no site sysimage claim" (not (contains "sysimage" md));
  let bare =
    { p with
      tools = List.filter (fun t -> t <> "julia" && t <> "julia-bin") p.tools;
      secrets = [] }
  in
  let md = Render.instructions ~agent:bare.agent bare in
  assert_b "no julia → no JULIA_PROJECT" (not (contains "JULIA_PROJECT" md));
  assert_b "no julia → no depot" (not (contains "/work/.julia" md));
  assert_b "no GH_TOKEN → no gh claim" (not (contains "GH_TOKEN" md));
  assert_b "still has the egress section" (contains "## Network egress" md)

let test_render_instructions_with_instructions () =
  let _, p = parse_fixture "sample-project.json" in
  let p =
    { p with agent = { p.agent with instructions = Some "Always run tests with pytest -q." } }
  in
  let md = Render.instructions ~agent:p.agent p in
  assert_b "has project-specific heading"
    (contains "Project-specific guidance" md);
  assert_b "embeds the instruction text"
    (contains "Always run tests with pytest -q." md)

(* --- egress posture (Policy.egress_mode, the --egress flag's target) --- *)

(* The launcher-injected `mode` is absent from Nickel-exported policy
   JSON, so parse_egress derives it from `none`: false → Allowlist,
   true → Airgap. Only the --egress CLI flag ever reaches Unrestricted —
   the contract never does (a partly-untrusted policy can't lift the
   fence). *)
let test_egress_mode_derived_from_none () =
  let json, p = parse_fixture "sample-project.json" in
  assert_b "no mode key + none=false → Allowlist"
    (p.egress.mode = Policy.Allowlist);
  (* Rebuild the JSON with egress.none = true and STILL no mode key, to
     exercise the derivation rather than a literal. *)
  let kvs =
    match json with `Assoc kvs -> kvs | _ -> failwith "fixture not object"
  in
  let kvs' =
    List.map
      (fun (k, v) ->
        if k = "egress"
        then (k, `Assoc [ ("hosts", `List []); ("none", `Bool true) ])
        else (k, v))
      kvs
  in
  match Policy.of_json (`Assoc kvs') with
  | Error e -> failwith ("airgap derivation: " ^ e)
  | Ok p' -> assert_b "none=true → Airgap" (p'.egress.mode = Policy.Airgap)

(* to_json serializes mode as its CLI token and of_json reads it back: a
   CLI-overridden Unrestricted survives the round trip the guest's
   policy.json makes (to_json on the launcher → fromJSON in the guest). *)
let test_egress_mode_roundtrip () =
  let _, p = parse_fixture "sample-project.json" in
  let p = { p with egress = { p.egress with mode = Policy.Unrestricted } } in
  let j = Policy.to_json p in
  (match j with
   | `Assoc kvs -> (
       match List.assoc "egress" kvs with
       | `Assoc e ->
           assert_b "to_json writes the displayed vocabulary"
             (List.assoc "mode" e = `String "unfenced")
       | _ -> failwith "egress not object")
   | _ -> failwith "to_json not object");
  match Policy.of_json j with
  | Error e -> failwith ("roundtrip: " ^ e)
  | Ok p' ->
      assert_b "Unrestricted round-trips" (p'.egress.mode = Policy.Unrestricted)

let test_stage_writes_files () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  let _, p = parse_fixture "sample-project.json" in
  (* The fixture's secret source ($HOME/.config/microvm/tokens/myproject.gh)
     won't exist in the test sandbox — drop secrets to keep the test
     hermetic. Stage.secrets is exercised separately. *)
  let p = { p with secrets = [] } in
  Stage.all ~etc_dir:etc ~source:Default p;
  assert_b "egress-hosts written" (Sys.file_exists (etc ^ "/egress-hosts"));
  assert_b "instructions file written"
    (Sys.file_exists
       (etc ^ "/instructions/" ^ p.agent.name ^ "/" ^ p.agent.instructions_file));
  assert_b "microvm-loaded.json written (Default source)"
    (Sys.file_exists (etc ^ "/microvm-loaded.json"));
  assert_b "no .ncl artifact for Default"
    (not (Sys.file_exists (etc ^ "/microvm-loaded.ncl")))

let test_stage_microvm_loaded_ncl_source () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  (* Synthesize an .ncl source file; Stage should copy it verbatim. *)
  let ncl_path = base ^ "/source.ncl" in
  let src_content = "# fake nickel\n{ project = \"/x\" }\n" in
  let oc = open_out ncl_path in
  output_string oc src_content;
  close_out oc;
  let _, p = parse_fixture "vm-testing.json" in
  Stage.microvm_loaded ~etc_dir:etc ~source:(Override ncl_path) p;
  assert_b ".ncl artifact present"
    (Sys.file_exists (etc ^ "/microvm-loaded.ncl"));
  (* The resolved policy is ALSO written as .json for the Override case
     (it captures CLI overrides the verbatim .ncl can't — e.g. --egress);
     this is the file the guest surfaces at login. *)
  assert_b ".json artifact also present for Override source"
    (Sys.file_exists (etc ^ "/microvm-loaded.json"));
  let ic = open_in (etc ^ "/microvm-loaded.ncl") in
  let n = in_channel_length ic in
  let got = really_input_string ic n in
  close_in ic;
  assert_b "ncl copy is verbatim" (got = src_content)

let test_stage_secrets_copy_and_perms () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  let mk path text =
    let oc = open_out path in
    output_string oc text;
    close_out oc;
    Unix.chmod path 0o600
  in
  let host_token = base ^ "/host-token" in
  mk host_token "TOKEN123";
  let p =
    let _, base_p = parse_fixture "vm-testing.json" in
    { base_p with secrets =
        [
          { env = "GH_TOKEN"; source = host_token; scope = Agent_env };
        ] }
  in
  Stage.secrets ~etc_dir:etc p;
  let agent_dir = etc ^ "/agent-secrets" in
  assert_b "agent-secrets dir exists" (Sys.is_directory agent_dir);
  let st = Unix.stat agent_dir in
  assert_b "agent-secrets dir 0700"
    (st.st_perm land 0o777 = 0o700);
  let read p =
    let ic = open_in p in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic; s
  in
  assert_b "GH_TOKEN copied" (read (agent_dir ^ "/GH_TOKEN") = "TOKEN123");
  let st = Unix.stat (agent_dir ^ "/GH_TOKEN") in
  assert_b "secret file 0600"
    (st.st_perm land 0o777 = 0o600);
  (* No Proxy_only entry → no proxy-secrets/ dir written. *)
  assert_b "no proxy-secrets dir when no Proxy_only entries"
    (not (Sys.file_exists (etc ^ "/proxy-secrets")))

let test_stage_secrets_mixed_scopes () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  let mk path text =
    let oc = open_out path in
    output_string oc text;
    close_out oc;
    Unix.chmod path 0o600
  in
  let h_gh = base ^ "/host-gh" in
  let h_anthropic = base ^ "/host-anth" in
  let h_openai = base ^ "/host-oai" in
  mk h_gh "GH_VALUE";
  mk h_anthropic "ANTH_VALUE";
  mk h_openai "OAI_VALUE";
  let p =
    let _, base_p = parse_fixture "vm-testing.json" in
    { base_p with secrets =
        [
          { env = "GH_TOKEN";       source = h_gh;       scope = Agent_env };
          { env = "ANTHROPIC_KEY";  source = h_anthropic; scope = Proxy_only };
          { env = "OPENAI_KEY";     source = h_openai;   scope = Proxy_only };
        ] }
  in
  Stage.secrets ~etc_dir:etc p;
  let agent_dir = etc ^ "/agent-secrets" in
  let proxy_dir = etc ^ "/proxy-secrets" in
  assert_b "agent dir exists" (Sys.is_directory agent_dir);
  assert_b "proxy dir exists" (Sys.is_directory proxy_dir);
  assert_b "agent dir 0700"
    ((Unix.stat agent_dir).st_perm land 0o777 = 0o700);
  assert_b "proxy dir 0700"
    ((Unix.stat proxy_dir).st_perm land 0o777 = 0o700);
  let read p =
    let ic = open_in p in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic; s
  in
  (* Agent_env routed only to agent-secrets/ (0600 — the agent owns it
     via loginShellInit). *)
  assert_b "GH_TOKEN under agent-secrets"
    (read (agent_dir ^ "/GH_TOKEN") = "GH_VALUE");
  assert_b "GH_TOKEN not under proxy-secrets"
    (not (Sys.file_exists (proxy_dir ^ "/GH_TOKEN")));
  assert_b "agent secret 0600"
    ((Unix.stat (agent_dir ^ "/GH_TOKEN")).st_perm land 0o777 = 0o600);
  (* Proxy_only routed to proxy-secrets/ at mode 0600. The actual
     defense against agent reads is the tmpfs shadow that
     egressproxy-secret-bootstrap puts over the dir before any agent
     code runs — mode bits can't distinguish guest-root from guest-
     agent because both go through virtiofsd uid 1000. *)
  assert_b "ANTHROPIC_KEY mode 0600"
    ((Unix.stat (proxy_dir ^ "/ANTHROPIC_KEY")).st_perm land 0o777 = 0o600);
  assert_b "OPENAI_KEY mode 0600"
    ((Unix.stat (proxy_dir ^ "/OPENAI_KEY")).st_perm land 0o777 = 0o600);
  assert_b "ANTHROPIC_KEY content under proxy-secrets"
    (read (proxy_dir ^ "/ANTHROPIC_KEY") = "ANTH_VALUE");
  assert_b "OPENAI_KEY content under proxy-secrets"
    (read (proxy_dir ^ "/OPENAI_KEY") = "OAI_VALUE");
  assert_b "ANTHROPIC_KEY not under agent-secrets"
    (not (Sys.file_exists (agent_dir ^ "/ANTHROPIC_KEY")))

let test_stage_secrets_missing_source () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  let p =
    let _, base_p = parse_fixture "vm-testing.json" in
    { base_p with secrets =
        [
          { env = "MISSING";
            source = base ^ "/not-there";
            scope = Agent_env };
        ] }
  in
  try
    Stage.secrets ~etc_dir:etc p;
    failwith "expected failwith on missing secret source"
  with Failure msg ->
    assert_b "error mentions env name" (contains "MISSING" msg)

let test_session_id_generate_shape () =
  Mirage_crypto_rng_unix.use_default ();
  let id = Session_manifest.generate_id () in
  (* Shape: YYYYMMDDTHHMMSS-<6 chars> = 8+1+6+1+6 = 22 chars. *)
  assert_b "id length 22" (String.length id = 22);
  assert_b "T separator at offset 8" (id.[8] = 'T');
  assert_b "- separator at offset 15" (id.[15] = '-');
  (* Random suffix is from the Crockford alphabet — no I/L/O/U,
     lowercase + digits only. *)
  let suffix = String.sub id 16 6 in
  String.iter
    (fun c ->
      let ok =
        (c >= '0' && c <= '9')
        || (c >= 'a' && c <= 'z'
            && c <> 'i' && c <> 'l' && c <> 'o' && c <> 'u')
      in
      assert_b
        (Printf.sprintf "char %C in Crockford alphabet" c) ok)
    suffix;
  (* Two consecutive calls don't collide (the random suffix changes
     even within the same second). 100 draws = 32^6 chance of any
     pair colliding ≈ 5e-6; effectively zero. *)
  let ids = Array.init 100 (fun _ -> Session_manifest.generate_id ()) in
  let h = Hashtbl.create 100 in
  Array.iter
    (fun id ->
      assert_b ("no dup in 100 draws: " ^ id)
        (not (Hashtbl.mem h id));
      Hashtbl.add h id ())
    ids

let test_stage_session_id () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  let id = "20260606T204312-x4f9q2" in
  Stage.session_id ~etc_dir:etc id;
  let path = etc ^ "/session-id" in
  assert_b "file exists" (Sys.file_exists path);
  let st = Unix.stat path in
  assert_b "mode 0644"
    (st.st_perm land 0o777 = 0o644);
  let ic = open_in path in
  let n = in_channel_length ic in
  let contents = really_input_string ic n in
  close_in ic;
  (* Exactly the ID, no trailing newline. *)
  assert_b "exactly the ID" (contents = id)

let test_session_manifest_write () =
  Mirage_crypto_rng_unix.use_default ();
  with_temp_base @@ fun base ->
  let xdg = base ^ "/state" in
  Unix.mkdir xdg 0o755;
  let proj_state = base ^ "/proj-state" in
  Unix.mkdir proj_state 0o700;
  let _, p = parse_fixture "vm-testing.json" in
  let id = Session_manifest.generate_id () in
  let m =
    Session_manifest.build
      ~id
      ~launch_cwd:"/tmp/somewhere"
      ~slot:(Some 0)
      ~source:Default
      ~policy:p
  in
  Session_manifest.write
    ~xdg_state_home:xdg
    ~project_state_dir:(Some proj_state)
    m;
  let global =
    Printf.sprintf "%s/microvm/sessions/%s" xdg id
  in
  let manifest_path = global ^ "/manifest.json" in
  assert_b "global manifest exists" (Sys.file_exists manifest_path);
  let st = Unix.stat manifest_path in
  assert_b "manifest 0644"
    (st.st_perm land 0o777 = 0o644);
  (* JSON parses + has the expected top-level keys. *)
  let json = Yojson.Safe.from_file manifest_path in
  let top = match json with `Assoc kvs -> kvs | _ -> failwith "not assoc" in
  let has k = List.mem_assoc k top in
  assert_b "has id" (has "id");
  assert_b "has launched_at" (has "launched_at");
  assert_b "has launch_cwd" (has "launch_cwd");
  assert_b "has policy" (has "policy");
  assert_b "has flake" (has "flake");
  assert_b "has vm_launcher" (has "vm_launcher");
  assert_b "has host" (has "host");
  (* id field round-trips. *)
  (match List.assoc "id" top with
   | `String s -> assert_b "id round-trips" (s = id)
   | _ -> failwith "id not a string");
  (* policy.resolved_json embeds the full Policy.to_json shape. *)
  (match List.assoc "policy" top with
   | `Assoc pkvs ->
       (match List.assoc_opt "resolved_json" pkvs with
        | Some (`Assoc resolved) ->
            assert_b "resolved has project"
              (List.mem_assoc "project" resolved);
            assert_b "resolved has proxyAuth"
              (List.mem_assoc "proxyAuth" resolved)
        | _ -> failwith "resolved_json missing or wrong type")
   | _ -> failwith "policy not an assoc");
  (* Per-project symlink points at the global dir. *)
  let proj_link = proj_state ^ "/sessions/" ^ id in
  let target = Unix.readlink proj_link in
  assert_b "symlink target is global dir"
    (target = global);
  (* Re-running with the same id is idempotent (overwrites). *)
  Session_manifest.write
    ~xdg_state_home:xdg
    ~project_state_dir:(Some proj_state)
    m;
  assert_b "manifest still there after re-run"
    (Sys.file_exists manifest_path);
  assert_b "symlink still there after re-run"
    (Unix.readlink proj_link = global)

let test_session_manifest_no_project_dir () =
  Mirage_crypto_rng_unix.use_default ();
  with_temp_base @@ fun base ->
  let xdg = base ^ "/state" in
  Unix.mkdir xdg 0o755;
  let _, p = parse_fixture "vm-testing.json" in
  let id = Session_manifest.generate_id () in
  let m =
    Session_manifest.build
      ~id ~launch_cwd:"/x" ~slot:None ~source:Default ~policy:p
  in
  (* No project_state_dir → still writes the global manifest, no
     symlink. *)
  Session_manifest.write
    ~xdg_state_home:xdg ~project_state_dir:None m;
  let global = Printf.sprintf "%s/microvm/sessions/%s" xdg id in
  assert_b "global written"
    (Sys.file_exists (global ^ "/manifest.json"));
  (* Empty-string project_state_dir is treated the same as None. *)
  let id2 = Session_manifest.generate_id () in
  let m2 = { m with id = id2 } in
  Session_manifest.write
    ~xdg_state_home:xdg ~project_state_dir:(Some "") m2;
  assert_b "global written for empty-string project_state_dir"
    (Sys.file_exists
       (Printf.sprintf "%s/microvm/sessions/%s/manifest.json" xdg id2))

let test_stage_proxy_auth_config_writes_file () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  let rules : Policy.proxy_auth_rule list =
    [
      { host = "api.openai.com";
        header = "Authorization";
        value_template = "Bearer ${OPENAI_KEY}" };
      { host = "httpbin.org";
        header = "X-Test";
        value_template = "literal:has=signs" };
    ]
  in
  Stage.proxy_auth_config ~etc_dir:etc rules;
  let path = etc ^ "/proxy-auth.conf" in
  assert_b "config file written" (Sys.file_exists path);
  let st = Unix.stat path in
  assert_b "config 0644"
    (st.st_perm land 0o777 = 0o644);
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  let lines =
    String.split_on_char '\n' s
    |> List.filter (fun l -> String.trim l <> "" && (l = "" || l.[0] <> '#'))
  in
  assert_b "two non-empty lines" (List.length lines = 2);
  let parsed =
    List.map
      (fun l ->
        match Proxy_lib.parse_proxy_auth_config_line l with
        | Ok r -> r
        | Error msg -> failwith ("parse: " ^ msg))
      lines
  in
  assert_b "round-trip equality" (parsed = rules)

(* CP3-D plumbing: vm_egress_proxy reads --proxy-auth-config with the same
   parse/skip-blanks-and-comments policy as parse_egress_hosts, then
   concatenates with --proxy-auth inline rules (file first, inline
   appended). Tested here at the parser layer; the binary's wiring is
   identical to what this exercises. *)
let test_proxy_auth_config_file_then_inline_concat () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  let file_rules : Policy.proxy_auth_rule list =
    [
      { host = "api.openai.com";
        header = "Authorization";
        value_template = "Bearer ${OPENAI_KEY}" };
      { host = "api.anthropic.com";
        header = "x-api-key";
        value_template = "${ANTHROPIC_KEY}" };
    ]
  in
  Stage.proxy_auth_config ~etc_dir:etc file_rules;
  let path = etc ^ "/proxy-auth.conf" in
  (* Insert a blank line + a # comment to confirm those are tolerated. *)
  let ic = open_in path in
  let n = in_channel_length ic in
  let body = really_input_string ic n in
  close_in ic;
  let oc = open_out path in
  output_string oc "# auto-generated by Stage.proxy_auth_config\n\n";
  output_string oc body;
  output_string oc "\n";
  close_out oc;
  let ic = open_in path in
  let n = in_channel_length ic in
  let content = really_input_string ic n in
  close_in ic;
  let parsed_file =
    String.split_on_char '\n' content
    |> List.filter_map (fun raw ->
         let line =
           let n = String.length raw in
           if n > 0 && raw.[n - 1] = '\r' then String.sub raw 0 (n - 1)
           else raw
         in
         if String.trim line = "" then None
         else if line.[0] = '#' then None
         else Some line)
    |> List.map (fun l ->
         match Proxy_lib.parse_proxy_auth_config_line l with
         | Ok r -> r
         | Error msg -> failwith msg)
  in
  assert_b "file rules round-trip (comments/blanks skipped)"
    (parsed_file = file_rules);
  (* Inline rule (smoke-override style): different host so neither
     shadows the other. Final list preserves file-first ordering. *)
  let inline =
    match Proxy_lib.parse_proxy_auth_flag
      "smoke.example=X-Smoke:on" with
    | Ok r -> [ r ]
    | Error msg -> failwith msg
  in
  let combined = parsed_file @ inline in
  assert_b "file-first order"
    (List.length combined = 3
     && (List.hd combined).host = "api.openai.com"
     && (List.nth combined 2).host = "smoke.example");
  (match Proxy_lib.pick_proxy_auth combined "api.openai.com" with
   | Some r -> assert_b "pick openai" (r.header = "Authorization")
   | None -> failwith "expected openai match");
  (match Proxy_lib.pick_proxy_auth combined "smoke.example" with
   | Some r -> assert_b "pick smoke" (r.header = "X-Smoke")
   | None -> failwith "expected smoke match");
  assert_b "no match for unrelated host"
    (Proxy_lib.pick_proxy_auth combined "google.com" = None)

(* Same-host overlap: spec'd precedence is file-first, inline appended.
   With List.find_opt first-match semantics, that means the FILE rule
   wins on a host collision. Documenting it so a later change to the
   concat direction surfaces here. *)
let test_proxy_auth_config_file_wins_on_overlap () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  let file_rule : Policy.proxy_auth_rule =
    { host = "api.openai.com";
      header = "Authorization";
      value_template = "Bearer ${FROM_FILE}" }
  in
  Stage.proxy_auth_config ~etc_dir:etc [ file_rule ];
  let ic = open_in (etc ^ "/proxy-auth.conf") in
  let n = in_channel_length ic in
  let content = really_input_string ic n in
  close_in ic;
  let file_rules =
    match Proxy_lib.parse_proxy_auth_config content with
    | Ok rs -> rs
    | Error msg -> failwith msg
  in
  let inline_rule =
    match Proxy_lib.parse_proxy_auth_flag
      "api.openai.com=Authorization:Bearer ${FROM_INLINE}" with
    | Ok r -> r
    | Error msg -> failwith msg
  in
  let combined = file_rules @ [ inline_rule ] in
  match Proxy_lib.pick_proxy_auth combined "api.openai.com" with
  | None -> failwith "expected a match"
  | Some r ->
      assert_b "file rule wins on overlap"
        (r.value_template = "Bearer ${FROM_FILE}")

let test_stage_proxy_auth_config_empty () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  Stage.proxy_auth_config ~etc_dir:etc [];
  let path = etc ^ "/proxy-auth.conf" in
  assert_b "empty config file written" (Sys.file_exists path);
  let st = Unix.stat path in
  assert_b "file is zero bytes" (st.st_size = 0);
  assert_b "config 0644"
    (st.st_perm land 0o777 = 0o644);
  (* Parser handles empty input as zero rules. *)
  (match Proxy_lib.parse_proxy_auth_config "" with
   | Ok [] -> ()
   | Ok _ -> failwith "expected []"
   | Error msg -> failwith ("empty parse: " ^ msg))

(* CRLF endings + blanks + #-comments interleaved. Confirms
   Proxy_lib.parse_proxy_auth_config (and via it, vm_egress_proxy's
   --proxy-auth-config loader) tolerates Windows-edited config files. *)
let test_parse_proxy_auth_config_crlf () =
  let content =
    "# auto-generated\r\n"
    ^ "\r\n"
    ^ "api.openai.com\tAuthorization\tBearer ${KEY}\r\n"
    ^ "\r\n"
    ^ "# another comment with CRLF\r\n"
    ^ "httpbin.org\tX-Test\tliteral-value\r\n"
  in
  let rules =
    match Proxy_lib.parse_proxy_auth_config content with
    | Ok rs -> rs
    | Error msg -> failwith msg
  in
  assert_b "two rules" (List.length rules = 2);
  let r1 = List.hd rules in
  assert_b "first host" (r1.host = "api.openai.com");
  assert_b "first header" (r1.header = "Authorization");
  assert_b "first template (no stray CR)"
    (r1.value_template = "Bearer ${KEY}");
  let r2 = List.nth rules 1 in
  assert_b "second host" (r2.host = "httpbin.org");
  assert_b "second template (no stray CR)"
    (r2.value_template = "literal-value");
  (* LF-only also fine (we don't require CRLF). *)
  let lf_only = "h\tH\tv\n" in
  (match Proxy_lib.parse_proxy_auth_config lf_only with
   | Ok [ r ] -> assert_b "LF-only host" (r.host = "h")
   | _ -> failwith "LF-only single rule expected");
  (* Malformed line surfaces an Error mentioning the offending content. *)
  let bad = "ok.com\tH\tv\nbroken-line-no-tabs\n" in
  (match Proxy_lib.parse_proxy_auth_config bad with
   | Ok _ -> failwith "expected Error on malformed line"
   | Error msg ->
       assert_b "error mentions offender" (contains "broken-line-no-tabs" msg))

let test_parse_proxy_auth_config_line () =
  let ok = function Ok r -> r | Error e -> failwith e in
  let err = function Ok _ -> failwith "expected Error" | Error e -> e in
  let r = ok (Proxy_lib.parse_proxy_auth_config_line
    "api.openai.com\tAuthorization\tBearer ${KEY}") in
  assert_b "host" (r.host = "api.openai.com");
  assert_b "header" (r.header = "Authorization");
  assert_b "template" (r.value_template = "Bearer ${KEY}");
  (* Template can contain '=', ':', spaces — the whole point of TAB. *)
  let r = ok (Proxy_lib.parse_proxy_auth_config_line
    "h\tX-Url\thttps://x:443/p?q=1") in
  assert_b "template colons + equals" (r.value_template = "https://x:443/p?q=1");
  (* Empty template is OK. *)
  let r = ok (Proxy_lib.parse_proxy_auth_config_line "h\tH\t") in
  assert_b "empty template ok" (r.value_template = "");
  (* Missing tabs. *)
  let _ = err (Proxy_lib.parse_proxy_auth_config_line "no tabs at all") in
  let _ = err (Proxy_lib.parse_proxy_auth_config_line "one\ttab-only") in
  let _ = err (Proxy_lib.parse_proxy_auth_config_line "too\tmany\ttabs\there") in
  (* Empty host / header. *)
  let e = err (Proxy_lib.parse_proxy_auth_config_line "\tH\tv") in
  assert_b "empty host mentioned" (contains "HOST" e);
  let e = err (Proxy_lib.parse_proxy_auth_config_line "h\t\tv") in
  assert_b "empty header mentioned" (contains "HEADER" e)

let test_stage_proxy_ca () =
  (* idempotent; safe even if a later test re-initialises *)
  Mirage_crypto_rng_unix.use_default ();
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  let ca = Proxy_ca.generate_ca ~common_name:"stage-test" () in
  Stage.proxy_ca ~etc_dir:etc ca;
  let cert_path = etc ^ "/proxy-ca.pem" in
  (* Key lives under proxy-secrets/ so the tmpfs-shadow that
     egressproxy-secret-bootstrap puts over that dir covers the key
     too — the agent never sees it after the shadow lands. *)
  let key_path = etc ^ "/proxy-secrets/proxy-ca-key.pem" in
  assert_b "cert PEM exists" (Sys.file_exists cert_path);
  assert_b "key PEM exists under proxy-secrets/"
    (Sys.file_exists key_path);
  assert_b "proxy-secrets/ created with mode 0700"
    ((Unix.stat (etc ^ "/proxy-secrets")).st_perm land 0o777 = 0o700);
  let cert_st = Unix.stat cert_path in
  assert_b "cert mode 0644"
    (cert_st.st_perm land 0o777 = 0o644);
  let key_st = Unix.stat key_path in
  assert_b "key mode 0600"
    (key_st.st_perm land 0o777 = 0o600);
  let read p =
    let ic = open_in p in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic; s
  in
  let cert_pem = read cert_path in
  let key_pem = read key_path in
  (* Cert PEM round-trips through X509. *)
  (match X509.Certificate.decode_pem cert_pem with
   | Ok _ -> ()
   | Error (`Msg m) -> failwith ("staged cert PEM decode: " ^ m));
  (* load_ca on the persisted pair succeeds — sanity that the systemd
     unit (which reads these paths) will be able to reconstruct the CA. *)
  (match Proxy_ca.load_ca ~cert_pem ~key_pem with
   | Ok _ -> ()
   | Error msg -> failwith ("load_ca on staged pair: " ^ msg))

let test_shares_wkro_tag () =
  (* md5("input") = a43c1b0aa53a0c908810c06ab1ff3967 — first 12 hex chars. *)
  assert_b "wkro of 'input'"
    (Shares.wkro_tag "input" = "wkro-a43c1b0aa53a");
  (* md5("env/vm") = 92746e5e689abc89358c09a412ed9ad2. *)
  assert_b "wkro of 'env/vm'"
    (Shares.wkro_tag "env/vm" = "wkro-92746e5e689a");
  assert_b "length always 17"
    (String.length (Shares.wkro_tag "anything-here") = 17)

let test_shares_in_tag () =
  assert_b "in-0" (Shares.in_tag 0 = "in-0");
  assert_b "in-12" (Shares.in_tag 12 = "in-12")

let test_shares_ro_tags_default () =
  let p = Resolver.default_policy ~project:"/x" in
  let tags = Shares.ro_tags p in
  assert_b "vmcfg always" (List.mem "vmcfg" tags);
  (* default is auth=Bind, work.default=Rw, no readOnly, no inputs *)
  (* Config binds are per agent now: auth-<name>, not a bare "auth". *)
  assert_b "auth-claude (Bind)" (List.mem "auth-claude" tags);
  assert_b "no bare auth tag" (not (List.mem "auth" tags));
  assert_b "no work (Rw)" (not (List.mem "work" tags));
  assert_b "no wkro-* under defaults"
    (not (List.exists
            (fun s -> String.length s > 5 && String.sub s 0 5 = "wkro-")
            tags));
  assert_b "no in-* under defaults"
    (not (List.exists
            (fun s -> String.length s > 3 && String.sub s 0 3 = "in-")
            tags))

let test_shares_ro_tags_full () =
  let p = Resolver.default_policy ~project:"/x" in
  let p =
    { p with
      auth = Ephemeral;
      work = { default = Ro; read_only = [ "input"; "env/vm" ]; hidden = [] };
      inputs = [ "/a/b"; "/c/d" ];
    }
  in
  let tags = Shares.ro_tags p in
  assert_b "no auth (Ephemeral)" (not (List.mem "auth" tags));
  assert_b "work (Ro)" (List.mem "work" tags);
  assert_b "wkro for input" (List.mem (Shares.wkro_tag "input") tags);
  assert_b "wkro for env/vm" (List.mem (Shares.wkro_tag "env/vm") tags);
  assert_b "in-0" (List.mem "in-0" tags);
  assert_b "in-1" (List.mem "in-1" tags);
  (* Sanity: vmcfg still there with everything else *)
  assert_b "vmcfg still there" (List.mem "vmcfg" tags)

let test_shares_read_manifest () =
  with_temp_base @@ fun base ->
  let mk_share tag source socket =
    let d = base ^ "/share/microvm/virtiofs/" ^ tag in
    ignore
      (Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote d)));
    (* microvm.nix writes these via writeText, which adds a trailing
       newline — make sure read_manifest strips it. *)
    let oc = open_out (d ^ "/source") in
    output_string oc (source ^ "\n");
    close_out oc;
    let oc = open_out (d ^ "/socket") in
    output_string oc (socket ^ "\n");
    close_out oc
  in
  mk_share "vmcfg" "/run/vm-launcher/current-session/etc" "vmcfg.sock";
  mk_share "work" "/home/user/project" "work.sock";
  mk_share "in-0" "/data/input-one" "in-0.sock";
  let entries = Shares.read_manifest ~runner:base in
  assert_b "three entries" (List.length entries = 3);
  let vmcfg =
    List.find (fun (e : Shares.manifest_entry) -> e.tag = "vmcfg") entries
  in
  assert_b "vmcfg source trimmed"
    (vmcfg.source = "/run/vm-launcher/current-session/etc");
  assert_b "vmcfg socket trimmed" (vmcfg.socket = "vmcfg.sock");
  let in0 =
    List.find (fun (e : Shares.manifest_entry) -> e.tag = "in-0") entries
  in
  assert_b "in-0 source" (in0.source = "/data/input-one")

let test_shares_read_manifest_missing_dir () =
  with_temp_base @@ fun base ->
  assert_b "missing manifest dir → []"
    (Shares.read_manifest ~runner:base = [])

(* Boot helpers. The full Boot.run is shell-out-heavy (nix, virtiofsd,
   microvm-run) and gets its coverage from the end-to-end smoke;
   here we fingerprint the host-side preparation logic. *)

let write_file path text =
  let oc = open_out path in
  output_string oc text;
  close_out oc

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic; s

let perm_of path = (Unix.stat path).st_perm land 0o777

(* A Bind-auth policy threaded through Boot.prepare_host_paths — the
   default_policy supplies the rest of the contract fields. *)
let bind_policy ~state_dir : Policy.t =
  let p = Resolver.default_policy ~project:"/x" in
  { p with state_dir = Some state_dir; auth = Bind }

let test_boot_prepare_paths_bind_with_state () =
  with_temp_base @@ fun base ->
  with_env "HOME" base @@ fun () ->
  let state_dir = base ^ "/state" in
  let p = Boot.prepare_host_paths (bind_policy ~state_dir) in
  assert_b "config_host resolved to host ~/.claude (not hardcoded)"
    (p.Policy.agent.config_host = Some (base ^ "/.claude"));
  assert_b "state_dir exists" (Sys.is_directory state_dir);
  assert_b "state_dir 0700" (perm_of state_dir = 0o700);
  (* State is namespaced per agent (<state>/<name>/…) — claude and codex
     both keep a history.jsonl, so a flat layout would collide. *)
  assert_b "claude/tasks/ exists" (Sys.is_directory (state_dir ^ "/claude/tasks"));
  assert_b "claude/tasks/ 0700" (perm_of (state_dir ^ "/claude/tasks") = 0o700);
  assert_b "~/.claude/tasks/ exists"
    (Sys.is_directory (base ^ "/.claude/tasks"));
  assert_b "~/.claude/tasks/ 0700"
    (perm_of (base ^ "/.claude/tasks") = 0o700);
  (* No host ~/.claude.json exists → state .claude.json not created *)
  assert_b "no .claude.json seeded when host has none"
    (not (Sys.file_exists (state_dir ^ "/claude/.claude.json")))

let test_boot_prepare_paths_seeds_claude_json () =
  with_temp_base @@ fun base ->
  with_env "HOME" base @@ fun () ->
  (* Host has a .claude.json *)
  write_file (base ^ "/.claude.json") {|{"hostSide":true}|};
  let state_dir = base ^ "/state" in
  ignore (Boot.prepare_host_paths (bind_policy ~state_dir));
  assert_b ".claude.json seeded into the agent's state namespace"
    (Sys.file_exists (state_dir ^ "/claude/.claude.json"));
  assert_b "seeded contents match host"
    (read_file (state_dir ^ "/claude/.claude.json") = {|{"hostSide":true}|});
  assert_b ".claude.json 0600"
    (perm_of (state_dir ^ "/claude/.claude.json") = 0o600)

let test_boot_prepare_paths_preserves_existing_claude_json () =
  with_temp_base @@ fun base ->
  with_env "HOME" base @@ fun () ->
  write_file (base ^ "/.claude.json") {|{"hostSide":true}|};
  let state_dir = base ^ "/state" in
  Unix.mkdir state_dir 0o700;
  (* Subsequent-run state: .claude.json already exists, possibly mutated
     by the guest. Must NOT be overwritten by the host's copy. Written at
     the pre-namespacing FLAT path, so this also pins the one-time
     migration: the file moves into <state>/claude/ with its contents
     intact rather than being re-seeded from the host. *)
  write_file (state_dir ^ "/.claude.json") {|{"vmMutated":true}|};
  ignore (Boot.prepare_host_paths (bind_policy ~state_dir));
  assert_b "flat state migrated into the agent namespace"
    (Sys.file_exists (state_dir ^ "/claude/.claude.json"));
  assert_b "flat copy is gone after migration"
    (not (Sys.file_exists (state_dir ^ "/.claude.json")));
  assert_b "in-VM mutations preserved"
    (read_file (state_dir ^ "/claude/.claude.json") = {|{"vmMutated":true}|})

(* ---- headless + ssh attach ---- *)

let test_ssh_guest_ip_follows_slot () =
  assert_b "slot 0" (Ssh.guest_ip ~slot:0 = "10.42.0.2");
  assert_b "slot 3" (Ssh.guest_ip ~slot:3 = "10.42.3.2")

let test_ssh_attach_roundtrip () =
  with_temp_base @@ fun base ->
  let a : Ssh.attach_info =
    { id = "20260101T000000-abcdef"; project = "/x"; slot = 2;
      guest_ip = "10.42.2.2"; user = "agent";
      key = base ^ "/id_ed25519"; known_hosts = base ^ "/known_hosts";
      runner_pid = 4242; detached = true }
  in
  Ssh.write ~state_dir:base a;
  match Ssh.read ~state_dir:base with
  | None -> failwith "attach.json did not read back"
  | Some b ->
      assert_b "roundtrips" (b = a);
      assert_b "argv targets user@ip"
        (Array.exists (fun s -> s = "agent@10.42.2.2") (Ssh.ssh_argv b));
      assert_b "argv keeps strict host-key checking"
        (Array.exists (fun s -> s = "StrictHostKeyChecking=yes") (Ssh.ssh_argv b))

(* /proc files defeat read_file: in_channel_length RAISES on
   /proc/<pid>/stat (so read_file_opt is None) and reports 0 for
   /proc/<pid>/cmdline (so it is Some ""). That is how
   Clean.pid_is_virtiofsd came to reject every pid it was asked about,
   silently disabling the recycled-pid guard it exists to provide. *)
(* Both egress vocabularies must resolve to the same posture. Getting
   this wrong is not a cosmetic bug: if a spelling fails to match
   "fenced" in the guest, no proxy stack is emitted and the VM boots with
   OPEN egress while every banner still claims it is fenced. *)
let test_egress_vocabularies_are_equivalent () =
  let mode_of s =
    match
      Policy.of_json
        (`Assoc
          [ ("project", `String "/x");
            ("work", `Assoc [ ("default", `String "rw");
                              ("readOnly", `List []); ("hidden", `List []) ]);
            ("inputs", `List []); ("shares", `List []);
            ("egress",
             `Assoc [ ("hosts", `List []); ("none", `Bool false);
                      ("mode", `String s) ]);
            ("auth", `String "bind");
            ("agent", Policy.to_json (Resolver.default_policy ~project:"/x")
                      |> (function `Assoc kv -> List.assoc "agent" kv | _ -> `Null));
            ("tools", `List []);
            ("resources", `Assoc [ ("vcpu", `Int 1); ("memMb", `Int 512) ]);
            ("secrets", `List []); ("stateDir", `String "");
            ("git", `Assoc [ ("name", `String ""); ("email", `String "");
                             ("allowedGithubOrgs", `List []) ]);
            ("julia", `Assoc [ ("env", `String "env/julia") ]);
            ("r", `Assoc [ ("packages", `List []) ]) ])
    with
    | Ok p -> p.Policy.egress.mode
    | Error m -> failwith ("parse failed for " ^ s ^ ": " ^ m)
  in
  assert_b "fenced == allowlist" (mode_of "fenced" = mode_of "allowlist");
  assert_b "unfenced == noblock" (mode_of "unfenced" = mode_of "noblock");
  assert_b "airgap == block" (mode_of "airgap" = mode_of "block");
  assert_b "fenced is the Allowlist posture"
    (mode_of "fenced" = Policy.Allowlist);
  assert_b "unfenced is the Unrestricted posture"
    (mode_of "unfenced" = Policy.Unrestricted);
  assert_b "airgap is the Airgap posture" (mode_of "airgap" = Policy.Airgap);
  (* And the serializer emits the vocabulary the tool displays. *)
  assert_b "serializes as fenced"
    (match Policy.to_json (Resolver.default_policy ~project:"/x") with
     | `Assoc kv -> (
         match List.assoc "egress" kv with
         | `Assoc e -> List.assoc "mode" e = `String "fenced"
         | _ -> false)
     | _ -> false)

let test_read_proc_opt_reads_zero_sized_files () =
  assert_b "read_file_opt cannot read /proc/<pid>/stat"
    (Util.read_file_opt "/proc/self/stat" = None);
  assert_b "read_file_opt reads /proc/<pid>/cmdline as empty"
    (Util.read_file_opt "/proc/self/cmdline" = Some "");
  assert_b "read_proc_opt reads stat"
    (match Util.read_proc_opt "/proc/self/stat" with
     | Some s -> String.length s > 20
     | None -> false);
  assert_b "read_proc_opt reads cmdline"
    (match Util.read_proc_opt "/proc/self/cmdline" with
     | Some s -> String.length s > 0
     | None -> false);
  assert_b "missing /proc entry is None"
    (Util.read_proc_opt "/proc/999999999/stat" = None)

(* The false positive this guard exists for: our own process mentions
   the search string in its cmdline (it is an argument to the test
   binary's own invocation), and a path-only match would count it as an
   attached shell. argv[0] is not ssh, so it must not be. *)
let test_attached_clients_ignores_non_ssh_processes () =
  let self_cmdline =
    match Util.read_proc_opt "/proc/self/cmdline" with
    | Some c -> c
    | None -> ""
  in
  let needle =
    match String.index_opt self_cmdline '\000' with
    | Some i -> String.sub self_cmdline 0 i
    | None -> self_cmdline
  in
  assert_b "precondition: we can see our own argv0" (String.length needle > 0);
  assert_b "a non-ssh process mentioning the path is not an attached client"
    (Ls.attached_clients ~known_hosts:needle = []);
  assert_b "an empty path matches nothing"
    (Ls.attached_clients ~known_hosts:"" = [])

let test_pid_is_runner_rejects_non_runner () =
  assert_b "this test process is not a VM runner"
    (not (Ls.pid_is_runner (Unix.getpid ())));
  assert_b "a dead pid is not a runner" (not (Ls.pid_is_runner 999_999_999))

(* Recycled-pid protection: attach.json can name a pid that is alive
   but is no longer the VM. `down` SIGKILLs whatever this says yes to,
   so a bare `kill 0` is not enough — identity is checked against
   /proc. Our own pid stands in for "alive, but not cloud-hypervisor".

   The positive case (a real runner keeping a launcher-less VM alive)
   cannot be faked here; e2e-detached-ssh-attach covers it. *)
let test_runner_alive_rejects_recycled_pid () =
  with_temp_base @@ fun base ->
  let dead_launcher = 999_999_999 in
  let state_dir = Printf.sprintf "%s/session-%d" base dead_launcher in
  Util.mkdir_p ~perm:0o700 state_dir;
  let a : Ssh.attach_info =
    { id = "20260101T000000-live00"; project = "/x"; slot = 1;
      guest_ip = "10.42.1.2"; user = "agent";
      key = state_dir ^ "/id_ed25519"; known_hosts = state_dir ^ "/known_hosts";
      runner_pid = Unix.getpid (); detached = false }
  in
  Ssh.write ~state_dir a;
  assert_b "launcher is gone" (not (Ls.process_alive dead_launcher));
  assert_b "a live NON-runner pid does not count as a live VM"
    (not (Ls.runner_alive ~state_base:base ~pid:dead_launcher))

let test_runner_alive_false_when_runner_dead () =
  with_temp_base @@ fun base ->
  let state_dir = Printf.sprintf "%s/session-%d" base 999_999_998 in
  Util.mkdir_p ~perm:0o700 state_dir;
  let a : Ssh.attach_info =
    { id = "20260101T000000-dead00"; project = "/x"; slot = 1;
      guest_ip = "10.42.1.2"; user = "agent"; key = ""; known_hosts = "";
      runner_pid = 999_999_997; detached = true }
  in
  Ssh.write ~state_dir a;
  assert_b "dead runner is not alive"
    (not (Ls.runner_alive ~state_base:base ~pid:999_999_998))

(* The readiness probe behind `ls`'s booting/running split. A forked
   child stands in for sshd on an ephemeral loopback port: it accepts
   once and greets with [banner]. A refused port must read as not-up,
   and so must a listener that talks something other than ssh. *)
let with_fake_sshd ~banner f =
  let srv = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt srv Unix.SO_REUSEADDR true;
  Unix.bind srv (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  Unix.listen srv 1;
  let port =
    match Unix.getsockname srv with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "no port"
  in
  let child =
    match Unix.fork () with
    | 0 ->
        (try
           let c, _ = Unix.accept srv in
           ignore (Unix.write_substring c banner 0 (String.length banner));
           Unix.sleepf 1.0
         with _ -> ());
        Unix._exit 0
    | n -> n
  in
  Unix.close srv;
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill child Sys.sigkill with _ -> ());
      (try ignore (Unix.waitpid [] child) with _ -> ()))
    (fun () -> f port)

let test_sshd_up_probe () =
  let a : Ssh.attach_info =
    { id = "x"; project = "/x"; slot = 1; guest_ip = "127.0.0.1";
      user = "agent"; key = ""; known_hosts = ""; runner_pid = 0;
      detached = false }
  in
  with_fake_sshd ~banner:"SSH-2.0-OpenSSH_test\r\n" (fun port ->
      assert_b "an ssh greeting counts as up"
        (Ssh.sshd_up ~timeout:2.0 ~port a));
  with_fake_sshd ~banner:"HTTP/1.1 400\r\n" (fun port ->
      assert_b "a non-ssh listener does not count"
        (not (Ssh.sshd_up ~timeout:2.0 ~port a)));
  (* Grab a free port, then close it: connecting is refused. *)
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname s with Unix.ADDR_INET (_, p) -> p | _ -> 0
  in
  Unix.close s;
  assert_b "a refused port is not up"
    (not (Ssh.sshd_up ~timeout:1.0 ~port a));
  assert_b "an unparseable address is not up"
    (not (Ssh.sshd_up { a with guest_ip = "not-an-ip" }))

let test_multiplex_default_matches_contract () =
  (* contract.ncl defaults multiplex to 'none; a policy.json that omits
     the field must parse the same way, or anything not going through
     Nickel silently gets tmux. *)
  let p = Resolver.default_policy ~project:"/x" in
  let j = Policy.to_json p in
  let stripped =
    match j with
    | `Assoc kvs ->
        `Assoc
          (List.map
             (fun (k, v) ->
               if k <> "session" then (k, v)
               else
                 match v with
                 | `Assoc sk ->
                     (k, `Assoc (List.filter (fun (sk', _) -> sk' <> "multiplex") sk))
                 | x -> (k, x))
             kvs)
    | x -> x
  in
  match Policy.of_json stripped with
  | Error msg -> failwith ("parse failed: " ^ msg)
  | Ok p' ->
      assert_b "absent multiplex parses as 'none"
        (p'.Policy.session.multiplex = Policy.Multiplex_none)

let test_ssh_read_absent_is_none () =
  with_temp_base @@ fun base ->
  assert_b "no attach.json -> None" (Ssh.read ~state_dir:base = None)

let test_session_defaults_are_headless_capable () =
  let p = Resolver.default_policy ~project:"/x" in
  (* The built-in default is what a project with no policy file gets:
     ssh on (so `attach` works), tmux off (attach replaces it). *)
  assert_b "ssh on by default" p.Policy.session.ssh;
  assert_b "not headless unless --detach" (not p.Policy.session.headless);
  assert_b "multiplex none by default"
    (p.Policy.session.multiplex = Policy.Multiplex_none)

let test_session_absent_block_is_not_ssh () =
  (* A policy.json predating the field must NOT be treated as ssh: the
     launcher would try to mint keys for a session that never asked. *)
  let p = Resolver.default_policy ~project:"/x" in
  let j = Policy.to_json p in
  let stripped =
    match j with
    | `Assoc kvs -> `Assoc (List.filter (fun (k, _) -> k <> "session") kvs)
    | x -> x
  in
  match Policy.of_json stripped with
  | Error msg -> failwith ("parse failed: " ^ msg)
  | Ok p' ->
      assert_b "legacy policy is not ssh" (not p'.Policy.session.ssh);
      assert_b "legacy policy is not headless" (not p'.Policy.session.headless)

(* ---- multi-agent ---- *)

(* A codex profile as the Nickel contract expands it, used as an
   extraAgents entry. Mirrors policy/contract.ncl's 'codex preset. *)
let codex_agent : Policy.agent =
  {
    preset = "codex";
    name = "codex";
    package = "codex";
    command = "codex";
    flags = [ "--dangerously-bypass-approvals-and-sandbox" ];
    instructions_file = "AGENTS.md";
    instructions = None;
    config_dir = ".config/codex";
    config_guest = "/var/lib/codex";
    config_env = "CODEX_HOME";
    config_mode = Writable;
    seed_files = [ "auth.json"; "config.toml" ];
    task_dir = "";
    state_dirs = [];
    state_files = [];
    home_state_files = [];
    sync_files = [];
    config_host = None;
  }

let two_agent_policy ~state_dir : Policy.t =
  let p = bind_policy ~state_dir in
  { p with extra_agents = [ codex_agent ] }

let test_policy_agents_default_first () =
  let p = two_agent_policy ~state_dir:"/x/state" in
  assert_b "agents lists default first, then extras"
    (List.map (fun (a : Policy.agent) -> a.name) (Policy.agents p)
     = [ "claude"; "codex" ])

let test_policy_agent_roundtrip_multi () =
  let p = two_agent_policy ~state_dir:"/x/state" in
  match Policy.of_json (Policy.to_json p) with
  | Error msg -> failwith ("roundtrip failed: " ^ msg)
  | Ok p' ->
      assert_b "extra agent survives roundtrip" (p'.extra_agents = [ codex_agent ]);
      assert_b "codex config_mode is Writable"
        ((List.hd p'.extra_agents).config_mode = Policy.Writable);
      assert_b "session survives roundtrip" (p'.session = p.session)

let test_policy_rejects_duplicate_agent_names () =
  let p = two_agent_policy ~state_dir:"/x/state" in
  (* Same name twice: the run wrapper, the state namespace and the tmux
     window would all collide. *)
  let p = { p with extra_agents = [ { codex_agent with name = "claude" } ] } in
  match Policy.of_json (Policy.to_json p) with
  | Ok _ -> failwith "expected duplicate agent name to be rejected"
  | Error msg ->
      assert_b "error names the duplicate" (contains "duplicate agent name" msg)

let test_policy_rejects_bad_agent_name () =
  let p = two_agent_policy ~state_dir:"/x/state" in
  let p = { p with extra_agents = [ { codex_agent with name = "co/dex" } ] } in
  match Policy.of_json (Policy.to_json p) with
  | Ok _ -> failwith "expected path-ish agent name to be rejected"
  | Error msg -> assert_b "error names the field" (contains "agent name" msg)

let test_boot_prepare_paths_multi_agent () =
  with_temp_base @@ fun base ->
  with_env "HOME" base @@ fun () ->
  let state_dir = base ^ "/state" in
  let p = Boot.prepare_host_paths (two_agent_policy ~state_dir) in
  let codex = List.hd p.Policy.extra_agents in
  assert_b "codex config_host under the host's $HOME"
    (codex.config_host = Some (base ^ "/.config/codex"));
  assert_b "codex config dir created (first-ever codex run)"
    (Sys.is_directory (base ^ "/.config/codex"));
  assert_b "each agent gets its own state namespace"
    (Sys.is_directory (state_dir ^ "/claude")
     && Sys.is_directory (state_dir ^ "/codex"));
  (* codex declares no taskDir → no tasks nest for it *)
  assert_b "no tasks nest for a taskDir-less agent"
    (not (Sys.file_exists (state_dir ^ "/codex/tasks")))

let test_stage_instructions_per_agent () =
  with_temp_base @@ fun etc ->
  let p = two_agent_policy ~state_dir:"/x/state" in
  Stage.instructions ~etc_dir:etc p;
  assert_b "claude gets CLAUDE.md"
    (Sys.file_exists (etc ^ "/instructions/claude/CLAUDE.md"));
  assert_b "codex gets AGENTS.md"
    (Sys.file_exists (etc ^ "/instructions/codex/AGENTS.md"))

let test_render_instructions_names_the_other_agents () =
  let p = two_agent_policy ~state_dir:"/x/state" in
  let claude_md = Render.instructions ~agent:p.agent p in
  let codex_md = Render.instructions ~agent:(List.hd p.extra_agents) p in
  assert_b "claude's file names its own wrapper"
    (contains "`claude-run`" claude_md);
  assert_b "claude's file mentions codex is aboard"
    (contains "codex-run" claude_md);
  assert_b "codex's file names its own wrapper"
    (contains "`codex-run`" codex_md);
  assert_b "codex's file mentions claude is aboard"
    (contains "claude-run" codex_md)

let test_shares_auth_tag_per_agent () =
  let p = two_agent_policy ~state_dir:"/x/state" in
  let tags = Shares.ro_tags p in
  assert_b "one RO config tag per agent"
    (List.mem "auth-claude" tags && List.mem "auth-codex" tags)

let test_boot_prepare_paths_ephemeral_skips_claude_dir () =
  with_temp_base @@ fun base ->
  with_env "HOME" base @@ fun () ->
  write_file (base ^ "/.claude.json") {|{"hostSide":true}|};
  let state_dir = base ^ "/state" in
  let p = bind_policy ~state_dir in
  let p = { p with auth = Ephemeral } in
  let p = Boot.prepare_host_paths p in
  assert_b "no config_host for Ephemeral" (p.Policy.agent.config_host = None);
  assert_b "state_dir still created" (Sys.is_directory state_dir);
  assert_b "no ~/.claude/tasks/ for Ephemeral"
    (not (Sys.file_exists (base ^ "/.claude/tasks")));
  assert_b "no .claude.json seeded for Ephemeral"
    (not (Sys.file_exists (state_dir ^ "/.claude.json")))

let test_boot_prepare_paths_no_state_dir () =
  with_temp_base @@ fun base ->
  with_env "HOME" base @@ fun () ->
  write_file (base ^ "/.claude.json") {|{"hostSide":true}|};
  let p = Resolver.default_policy ~project:"/x" in
  let p = { p with state_dir = None; auth = Bind } in
  ignore (Boot.prepare_host_paths p);
  (* No state_dir → nothing to seed into; ~/.claude/tasks still
     created (the guest's nested mount-point exists independently). *)
  assert_b "~/.claude/tasks/ still pre-created"
    (Sys.is_directory (base ^ "/.claude/tasks"))

let test_boot_prepare_paths_empty_home_fails () =
  with_temp_base @@ fun base ->
  (* Empty HOME with auth=Bind would silently skip ~/.claude/tasks
     pre-creation in the original code, breaking the guest's nested
     vmtasks mount with no diagnostic. *)
  with_env "HOME" "" @@ fun () ->
  let state_dir = base ^ "/state" in
  (try
     ignore (Boot.prepare_host_paths (bind_policy ~state_dir));
     failwith "expected failwith on empty HOME with auth=Bind"
   with Failure msg ->
     assert_b "error mentions $HOME" (contains "HOME" msg);
     (* Message is agent-neutral — no longer hardcodes ~/.claude/tasks;
        it now refers to the agent config dir + task-tracker nest. *)
     assert_b "error mentions the task-tracker nest"
       (contains "task-tracker" msg))

let test_boot_wait_for_sockets_success () =
  with_temp_base @@ fun base ->
  let sock_path = base ^ "/test.sock" in
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind fd (Unix.ADDR_UNIX sock_path);
  Fun.protect
    ~finally:(fun () ->
      (try Unix.close fd with _ -> ());
      (try Unix.unlink sock_path with _ -> ()))
    (fun () -> Boot.wait_for_sockets [ sock_path ] ~timeout:2.0)

(* Proxy_lib — pure helpers for the egress proxy in bin/vm_egress_proxy.ml.
   The Lwt loop itself is exercised via the smoke test (and could
   eventually graduate to a hermetic integration test that bring up
   the proxy on an ephemeral port + curl through it). *)

let test_proxy_parse_egress_hosts () =
  let content =
    "api.anthropic.com\n# this is a comment\n\npypi.org   \n  \n#another\n"
  in
  let r = Proxy_lib.parse_egress_hosts content in
  assert_b "two hosts" (List.length r = 2);
  assert_b "first is anthropic" (List.hd r = "api.anthropic.com");
  assert_b "trimmed whitespace" (List.nth r 1 = "pypi.org");
  (* empty input → [] *)
  assert_b "empty → []" (Proxy_lib.parse_egress_hosts "" = []);
  assert_b "only comments → []"
    (Proxy_lib.parse_egress_hosts "# only\n# comments\n" = [])

let test_proxy_host_allowed () =
  let allow = [ "api.anthropic.com"; "pypi.org"; "github.com" ] in
  let allowed h = Proxy_lib.host_allowed ~allowlist:allow ~host:h in
  assert_b "exact match" (allowed "api.anthropic.com");
  assert_b "case-insensitive exact"
    (allowed "Api.Anthropic.Com");
  assert_b "subdomain allowed"
    (allowed "files.pypi.org");
  assert_b "subdomain case-insensitive"
    (allowed "Codeload.GitHub.COM");
  assert_b "superstring not allowed (security)"
    (not (allowed "evil-api.anthropic.com"));
  assert_b "trailing-substring not allowed (no leading dot)"
    (not (allowed "fakeanthropic.com"));
  assert_b "empty list denies everything"
    (not (Proxy_lib.host_allowed ~allowlist:[] ~host:"foo.com"));
  assert_b "unrelated host denied"
    (not (allowed "evil.com"))

let test_proxy_parse_upstream_rule () =
  (* Tinyproxy-style with leading dot is tolerated. *)
  let r = Proxy_lib.parse_upstream_rule ".example.ts.net=10.42.0.1:1055" in
  assert_b "suffix dot-stripped" (r.suffix = "example.ts.net");
  assert_b "proxy host" (r.proxy_host = "10.42.0.1");
  assert_b "proxy port" (r.proxy_port = 1055);

  (* No leading dot also fine. *)
  let r = Proxy_lib.parse_upstream_rule "internal.example=proxy.local:8080" in
  assert_b "no leading dot suffix" (r.suffix = "internal.example");
  assert_b "named host" (r.proxy_host = "proxy.local");
  assert_b "port 8080" (r.proxy_port = 8080);

  (* Errors *)
  let fails msg s =
    try
      let _ = Proxy_lib.parse_upstream_rule s in
      failwith (Printf.sprintf "expected failure for %s: %s" msg s)
    with Failure _ -> ()
  in
  fails "no equals" "no-equals";
  fails "empty suffix" "=host:80";
  fails "missing port" "foo=host";
  fails "bad port" "foo=host:abc";
  fails "empty host" "foo=:80"

(* Proxy_ca — needs the RNG initialised once before any key gen.
   Mirage_crypto_rng_unix.use_default sets the default RNG generator;
   safe to call repeatedly. *)
let init_rng_once = lazy (Mirage_crypto_rng_unix.use_default ())

let test_proxy_ca_roundtrip_pem () =
  Lazy.force init_rng_once;
  let ca = Proxy_ca.generate_ca ~common_name:"test-ca" () in
  let pem = Proxy_ca.ca_cert_pem ca in
  assert_b "cert PEM starts with BEGIN CERTIFICATE"
    (String.length pem > 30
     && String.sub pem 0 27 = "-----BEGIN CERTIFICATE-----");
  let key_pem = Proxy_ca.ca_key_pem ca in
  assert_b "key PEM has PRIVATE KEY marker"
    (contains "PRIVATE KEY" key_pem)

let test_proxy_ca_leaf_signed_by_ca () =
  Lazy.force init_rng_once;
  let ca = Proxy_ca.generate_ca () in
  let leaf = Proxy_ca.generate_leaf ~ca ~hostname:"api.example.com" in
  let cert = Proxy_ca.leaf_cert leaf in
  (* The leaf's issuer DN must match the CA's subject DN. *)
  let ca_pem = Proxy_ca.ca_cert_pem ca in
  match X509.Certificate.decode_pem ca_pem with
  | Error (`Msg m) -> failwith ("decode CA PEM: " ^ m)
  | Ok ca_cert ->
      let ca_subj = X509.Certificate.subject ca_cert in
      let leaf_issuer = X509.Certificate.issuer cert in
      assert_b "leaf issuer = CA subject"
        (X509.Distinguished_name.equal leaf_issuer ca_subj)

let test_proxy_ca_leaf_hostname_in_san () =
  Lazy.force init_rng_once;
  let ca = Proxy_ca.generate_ca () in
  let leaf =
    Proxy_ca.generate_leaf ~ca ~hostname:"streaming.anthropic.com"
  in
  let cert = Proxy_ca.leaf_cert leaf in
  (* X509.Certificate.hostnames returns Domain_name.t set of names
     covered by SAN + CN; check our hostname is present. *)
  let names = X509.Certificate.hostnames cert in
  let host = Domain_name.of_string_exn "streaming.anthropic.com" in
  assert_b "hostname in cert names"
    (X509.Host.Set.exists
       (fun (_typ, name) -> Domain_name.equal name host)
       names)

let test_proxy_ca_leaf_validates_against_ca () =
  Lazy.force init_rng_once;
  let ca = Proxy_ca.generate_ca () in
  let leaf = Proxy_ca.generate_leaf ~ca ~hostname:"x.example" in
  let cert = Proxy_ca.leaf_cert leaf in
  (* Verify the signature on the leaf using the CA's public key. *)
  let ca_pem = Proxy_ca.ca_cert_pem ca in
  match X509.Certificate.decode_pem ca_pem with
  | Error (`Msg m) -> failwith ("decode CA PEM: " ^ m)
  | Ok ca_cert ->
      (* X509.Validation.verify_chain takes a trust anchor list +
         a chain to validate. *)
      let host = Domain_name.of_string_exn "x.example" |> Domain_name.host_exn in
      let r =
        X509.Validation.verify_chain ~host:(Some host)
          ~anchors:[ ca_cert ]
          ~time:(fun () -> Some (Ptime_clock.now ()))
          [ cert ]
      in
      (match r with
       | Ok _ -> ()
       | Error e ->
           failwith
             (Format.asprintf "chain validation: %a"
                X509.Validation.pp_chain_error e))

let test_proxy_ca_load_ca_roundtrip () =
  Lazy.force init_rng_once;
  let ca = Proxy_ca.generate_ca ~common_name:"rt-ca" () in
  let cert_pem = Proxy_ca.ca_cert_pem ca in
  let key_pem = Proxy_ca.ca_key_pem ca in
  (match Proxy_ca.load_ca ~cert_pem ~key_pem with
   | Error e -> failwith ("load_ca: " ^ e)
   | Ok ca' ->
       (* Mint a leaf with the reloaded CA, verify it chain-validates
          against the original CA cert — proves the key actually matches. *)
       let leaf = Proxy_ca.generate_leaf ~ca:ca' ~hostname:"x.test" in
       let host =
         Domain_name.of_string_exn "x.test" |> Domain_name.host_exn
       in
       let r =
         X509.Validation.verify_chain
           ~host:(Some host)
           ~anchors:[
             (match X509.Certificate.decode_pem cert_pem with
              | Ok c -> c
              | Error (`Msg m) -> failwith m)
           ]
           ~time:(fun () -> Some (Ptime_clock.now ()))
           [ Proxy_ca.leaf_cert leaf ]
       in
       (match r with
        | Ok _ -> ()
        | Error e ->
            failwith
              (Format.asprintf "reloaded-CA chain: %a"
                 X509.Validation.pp_chain_error e)));
  (* Garbage PEMs surface as Error, not exception. *)
  (match Proxy_ca.load_ca ~cert_pem:"" ~key_pem with
   | Error _ -> ()
   | Ok _ -> failwith "expected Error for empty cert PEM");
  (match Proxy_ca.load_ca ~cert_pem ~key_pem:"" with
   | Error _ -> ()
   | Ok _ -> failwith "expected Error for empty key PEM")

let test_proxy_parse_connect_line () =
  let parse = Proxy_lib.parse_connect_line in
  (* Happy path *)
  (match parse "CONNECT api.anthropic.com:443 HTTP/1.1" with
   | Some { host; port } ->
       assert_b "host parsed" (host = "api.anthropic.com");
       assert_b "port parsed" (port = 443)
   | None -> failwith "expected parse success");
  (* Lowercase method tolerated *)
  (match parse "connect example.com:8080 HTTP/1.0" with
   | Some { host; port } ->
       assert_b "lowercase host" (host = "example.com");
       assert_b "lowercase port" (port = 8080)
   | None -> failwith "expected parse success on lowercase");
  (* Trailing CR tolerated (real HTTP request lines end with \r\n) *)
  (match parse "CONNECT a.b.c:443 HTTP/1.1\r" with
   | Some _ -> ()
   | None -> failwith "trailing \\r should be tolerated by trim");
  (* Non-CONNECT method *)
  assert_b "GET rejected" (parse "GET / HTTP/1.1" = None);
  assert_b "POST rejected" (parse "POST / HTTP/1.1" = None);
  (* Malformed shapes *)
  assert_b "no port → None" (parse "CONNECT foo HTTP/1.1" = None);
  assert_b "empty host → None" (parse "CONNECT :443 HTTP/1.1" = None);
  assert_b "non-numeric port → None"
    (parse "CONNECT foo:abc HTTP/1.1" = None);
  assert_b "too few tokens → None" (parse "CONNECT foo:443" = None);
  assert_b "too many tokens → None"
    (parse "CONNECT foo:443 HTTP/1.1 extra" = None);
  assert_b "empty → None" (parse "" = None);
  assert_b "garbage → None" (parse "random garbage line" = None)

let test_proxy_pick_upstream () =
  let r1 =
    Proxy_lib.parse_upstream_rule ".example.ts.net=10.42.0.1:1055"
  in
  let r2 = Proxy_lib.parse_upstream_rule "internal.lab=proxy.lab:8080" in
  let rules = [ r1; r2 ] in
  let pick h = Proxy_lib.pick_upstream rules h in
  assert_b "matches tailscale subdomain"
    (match pick "myhost.example.ts.net" with
     | Some r when r.proxy_host = "10.42.0.1" -> true
     | _ -> false);
  assert_b "matches internal exact"
    (match pick "internal.lab" with
     | Some r when r.proxy_host = "proxy.lab" -> true
     | _ -> false);
  assert_b "no match → None" (pick "api.anthropic.com" = None);
  assert_b "superstring doesn't match"
    (pick "evilexample.ts.net" = None);
  (* Earlier rule wins on overlap. *)
  let overlap =
    [
      Proxy_lib.parse_upstream_rule ".foo.com=first.proxy:1";
      Proxy_lib.parse_upstream_rule ".foo.com=second.proxy:2";
    ]
  in
  match Proxy_lib.pick_upstream overlap "host.foo.com" with
  | Some r -> assert_b "first rule wins" (r.proxy_host = "first.proxy")
  | None -> failwith "expected overlap match"

let test_proxy_render_template () =
  let lookup_of pairs name = List.assoc_opt name pairs in
  let ok = function Ok s -> s | Error e -> failwith e in
  let err = function
    | Ok s -> failwith (Printf.sprintf "expected Error, got Ok %S" s)
    | Error e -> e
  in
  let r = ok (Proxy_lib.render_template
    ~template:"Bearer ${TOKEN}"
    ~lookup:(lookup_of [ "TOKEN", "abc" ])) in
  assert_b "single subst" (r = "Bearer abc");
  let r = ok (Proxy_lib.render_template
    ~template:"plain text" ~lookup:(fun _ -> None)) in
  assert_b "no subst is identity" (r = "plain text");
  let r = ok (Proxy_lib.render_template
    ~template:"${A}-${B}-${A}"
    ~lookup:(lookup_of [ "A", "x"; "B", "y" ])) in
  assert_b "multi + reuse" (r = "x-y-x");
  let r = ok (Proxy_lib.render_template
    ~template:"" ~lookup:(fun _ -> None)) in
  assert_b "empty template" (r = "");
  (* a bare `$` without `{` is literal *)
  let r = ok (Proxy_lib.render_template
    ~template:"price: $5" ~lookup:(fun _ -> None)) in
  assert_b "bare $ literal" (r = "price: $5");
  (* missing variable → Error mentions the name *)
  let e = err (Proxy_lib.render_template
    ~template:"x${MISSING}y"
    ~lookup:(fun _ -> None)) in
  assert_b "missing var mentions name" (contains "MISSING" e);
  (* unterminated → Error *)
  let _ = err (Proxy_lib.render_template
    ~template:"x${NEVER_CLOSED"
    ~lookup:(fun _ -> None)) in
  (* empty name → Error *)
  let _ = err (Proxy_lib.render_template
    ~template:"${}" ~lookup:(fun _ -> None)) in
  (* invalid char in name (digit-start) → Error *)
  let _ = err (Proxy_lib.render_template
    ~template:"${1A}" ~lookup:(fun _ -> None)) in
  ()

let test_proxy_parse_proxy_auth_flag () =
  let ok = function Ok r -> r | Error e -> failwith e in
  let err = function
    | Ok _ -> failwith "expected Error"
    | Error e -> e
  in
  let r = ok (Proxy_lib.parse_proxy_auth_flag
    "httpbin.org=Authorization:Bearer ${MY_API_KEY}") in
  assert_b "host" (r.host = "httpbin.org");
  assert_b "header" (r.header = "Authorization");
  assert_b "template preserves ':'"
    (r.value_template = "Bearer ${MY_API_KEY}");
  let r = ok (Proxy_lib.parse_proxy_auth_flag
    "api.example.com=X-Token:literal-value") in
  assert_b "no template subst" (r.value_template = "literal-value");
  (* template can contain ':' (URL-shaped values) *)
  let r = ok (Proxy_lib.parse_proxy_auth_flag
    "foo=X-Url:https://x:443/path") in
  assert_b "template keeps colons"
    (r.value_template = "https://x:443/path");
  let e = err (Proxy_lib.parse_proxy_auth_flag "no-equals-here") in
  assert_b "missing = mentioned" (contains "HEADER" e || contains "=" e);
  let e = err (Proxy_lib.parse_proxy_auth_flag "host=no-colon-here") in
  assert_b "missing : mentioned" (contains ":" e);
  let _ = err (Proxy_lib.parse_proxy_auth_flag "=Header:value") in
  let _ = err (Proxy_lib.parse_proxy_auth_flag "host=:value") in
  ()

let test_proxy_is_env_name () =
  let yes s = assert_b (Printf.sprintf "%S accepted" s)
                (Proxy_lib.is_env_name s) in
  let no s = assert_b (Printf.sprintf "%S rejected" s)
               (not (Proxy_lib.is_env_name s)) in
  (* shapes a real secret-dir would have *)
  yes "MY_API_KEY";
  yes "OPENAI_API_KEY";
  yes "_PRIVATE";
  yes "_";
  yes "A";
  yes "X1";
  yes "Snake_case_123";
  yes "lowercase";
  (* shapes that should be rejected *)
  no "";
  no "1FOO";              (* digit start — POSIX rule *)
  no "FOO-BAR";           (* dash *)
  no "FOO BAR";           (* space *)
  no "FOO.BAR";           (* dot — guarded the ca.pem case *)
  no "FOO/BAR";           (* path separator *)
  no ".hidden";           (* dotfile *)
  no "ca.pem";            (* the actual case we hit during CP2 smoke *)
  no "FOO+BAR";
  no "héllo";             (* non-ASCII *)
  ()

let test_proxy_inject_header () =
  let rule h = { Policy.host = "x"; header = h; value_template = "" } in
  let req_with hdrs =
    {
      Http.Request.headers = Http.Header.of_list hdrs;
      meth = `GET;
      resource = "/path";
      version = `HTTP_1_1;
    }
  in
  let get h hdrs = Http.Header.get hdrs h in
  (* Adds the header when absent. *)
  let req = req_with [ "Host", "x"; "Accept", "*/*" ] in
  let req' = Proxy_lib.inject_header req (rule "X-Token") "secret-v" in
  assert_b "added"
    (get "X-Token" req'.headers = Some "secret-v");
  assert_b "other headers kept"
    (get "Host" req'.headers = Some "x"
     && get "Accept" req'.headers = Some "*/*");
  assert_b "method preserved" (req'.meth = `GET);
  assert_b "resource preserved" (req'.resource = "/path");
  assert_b "version preserved" (req'.version = `HTTP_1_1);
  (* OVERWRITES when the agent set its own value (threat model: an
     attacker-controlled agent must not poison the upstream call). *)
  let req = req_with [ "Authorization", "Bearer attacker-supplied" ] in
  let req' =
    Proxy_lib.inject_header req (rule "Authorization") "Bearer real"
  in
  assert_b "overwrites attacker value"
    (get "Authorization" req'.headers = Some "Bearer real");
  (* Header lookup is case-insensitive per HTTP semantics — replace
     should target the existing header regardless of case. *)
  let req = req_with [ "authorization", "old" ] in
  let req' =
    Proxy_lib.inject_header req (rule "Authorization") "new"
  in
  assert_b "case-insensitive replacement"
    (get "Authorization" req'.headers = Some "new"
     && (* and no stray duplicate left under the lowercase spelling *)
        List.length (Http.Header.get_multi req'.headers "Authorization")
        = 1);
  ()

let test_proxy_render_template_rejects_crlf () =
  (* H4 defense: a secret value containing CR or LF rendered into a
     template must surface an Error, not silently splat through to
     the upstream as a header-smuggling vector. *)
  let lookup pairs n = List.assoc_opt n pairs in
  let err = function Ok _ -> failwith "expected Error" | Error e -> e in
  (* LF *)
  let e =
    err (Proxy_lib.render_template
      ~template:"Bearer ${T}" ~lookup:(lookup [ "T", "abc\ndef" ]))
  in
  assert_b "LF rejected with CRLF message"
    (contains "CR or LF" e);
  (* CR *)
  let _ = err (Proxy_lib.render_template
    ~template:"Bearer ${T}" ~lookup:(lookup [ "T", "abc\rdef" ])) in
  (* CRLF combo *)
  let _ = err (Proxy_lib.render_template
    ~template:"Bearer ${T}" ~lookup:(lookup [ "T", "abc\r\nDangerous: yes" ])) in
  (* Plain trailing newline (the `echo TOKEN > file` case) — also
     rejected post-render. The fix in load_secret_dir strips one
     trailing \n before lookup ever sees the value, but the rendered
     check is a belt-and-braces second layer. *)
  let _ = err (Proxy_lib.render_template
    ~template:"${T}" ~lookup:(lookup [ "T", "abc\n" ])) in
  (* Tab is fine — tab is the proxy-auth.conf field separator, not an
     HTTP header forbidden char. *)
  (match Proxy_lib.render_template
           ~template:"${T}" ~lookup:(lookup [ "T", "abc\tdef" ])
   with
   | Ok s -> assert_b "tab survives" (s = "abc\tdef")
   | Error e -> failwith ("tab unexpectedly rejected: " ^ e))

let test_proxy_render_template_more () =
  (* Edge cases beyond the basic happy/missing-var test. *)
  let lookup pairs n = List.assoc_opt n pairs in
  let ok = function Ok s -> s | Error e -> failwith e in
  let err = function Ok _ -> failwith "expected Error" | Error e -> e in
  (* Adjacent substitutions with no separator. *)
  let r = ok (Proxy_lib.render_template
    ~template:"${A}${B}" ~lookup:(lookup ["A","x";"B","y"])) in
  assert_b "adjacent" (r = "xy");
  (* Substitution at start / end. *)
  let r = ok (Proxy_lib.render_template
    ~template:"${A}-end" ~lookup:(lookup ["A","x"])) in
  assert_b "start" (r = "x-end");
  let r = ok (Proxy_lib.render_template
    ~template:"start-${A}" ~lookup:(lookup ["A","x"])) in
  assert_b "end" (r = "start-x");
  (* Bare $ with non-{ next character is literal — important for things
     like Bearer $TOKEN or PATH=$HOME/bin in non-template strings. *)
  let r = ok (Proxy_lib.render_template
    ~template:"$TOKEN" ~lookup:(fun _ -> Some "should-not-be-used")) in
  assert_b "bare $ stays literal" (r = "$TOKEN");
  (* Value can contain $ or { — substituted value is not re-scanned
     (no template injection via secret contents). *)
  let r = ok (Proxy_lib.render_template
    ~template:"x=${V}" ~lookup:(lookup ["V","${OTHER}"])) in
  assert_b "no recursive expansion" (r = "x=${OTHER}");
  (* Empty value is OK. *)
  let r = ok (Proxy_lib.render_template
    ~template:"a=${E}." ~lookup:(lookup ["E",""])) in
  assert_b "empty value" (r = "a=.");
  (* Trailing $ alone. *)
  let r = ok (Proxy_lib.render_template
    ~template:"trail$" ~lookup:(fun _ -> None)) in
  assert_b "trailing $" (r = "trail$");
  (* Final $ followed by { but nothing else. *)
  let _ = err (Proxy_lib.render_template
    ~template:"${" ~lookup:(fun _ -> None)) in
  (* '${A B}' — space in name → Error (catches a quoting mistake). *)
  let _ = err (Proxy_lib.render_template
    ~template:"${A B}" ~lookup:(fun _ -> None)) in
  ()

let test_proxy_pick_proxy_auth () =
  let mk host = { Policy.host; header = "X"; value_template = "v" } in
  let rules = [ mk "api.openai.com"; mk "anthropic.com" ] in
  let pick h = Proxy_lib.pick_proxy_auth rules h in
  assert_b "exact match"
    (match pick "api.openai.com" with
     | Some r -> r.host = "api.openai.com"
     | None -> false);
  assert_b "subdomain via suffix"
    (match pick "console.anthropic.com" with
     | Some r -> r.host = "anthropic.com"
     | None -> false);
  assert_b "no match → None" (pick "other.com" = None);
  (* superstring guard: same as host_allowed *)
  assert_b "superstring blocked"
    (pick "evilanthropic.com" = None)

let test_boot_wait_for_sockets_timeout () =
  with_temp_base @@ fun base ->
  let missing = base ^ "/never-bound.sock" in
  let t0 = Unix.gettimeofday () in
  (try
     Boot.wait_for_sockets [ missing ] ~timeout:0.5;
     failwith "expected wait_for_sockets to time out"
   with Failure msg ->
     assert_b "error mentions timeout"
       (contains "did not all appear" msg));
  let dt = Unix.gettimeofday () -. t0 in
  assert_b "timeout fired roughly on schedule (>=0.4s, <2s)"
    (dt >= 0.4 && dt < 2.0)

let test_load_default () =
  let p = Resolver.load ~project:"/some/proj" Default in
  assert_b "Default → default_policy" (p.project = "/some/proj");
  assert_b "Default policy round-trip"
    (match Policy.of_json (Policy.to_json p) with
     | Ok p' -> p = p'
     | Error _ -> false)

(* ---- Gap-audit additions (2026-06-07) ---- *)

(* load_secret_dir: regression coverage for the four silent-failure
   modes the proxy's secret-isolation depends on. *)
let test_proxy_load_secret_dir_basic () =
  with_temp_base @@ fun base ->
  let mk ~mode name body =
    let path = base ^ "/" ^ name in
    let fd =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] mode
    in
    let n = String.length body in
    let _ = Unix.write_substring fd body 0 n in
    Unix.close fd;
    (* openfile mode is masked by umask; force-chmod afterward. *)
    Unix.chmod path mode
  in
  (* Happy: 0600, valid env name, no trailing newline. *)
  mk ~mode:0o600 "TOKEN" "abc-no-newline";
  (* Trailing-newline strip: exactly one \n removed. *)
  mk ~mode:0o600 "STRIPPED" "value\n";
  (* Two newlines: only one stripped, the other survives. *)
  mk ~mode:0o600 "DOUBLE_NL" "value\n\n";
  let h, warnings = Proxy_lib.load_secret_dir ~dir:base in
  assert_b "no warnings on happy path" (warnings = []);
  assert_b "TOKEN no-strip"
    (Hashtbl.find_opt h "TOKEN" = Some "abc-no-newline");
  assert_b "STRIPPED exactly one \\n stripped"
    (Hashtbl.find_opt h "STRIPPED" = Some "value");
  assert_b "DOUBLE_NL only one \\n stripped"
    (Hashtbl.find_opt h "DOUBLE_NL" = Some "value\n")

let test_proxy_load_secret_dir_rejects_wide_modes () =
  with_temp_base @@ fun base ->
  let mk ~mode name body =
    let path = base ^ "/" ^ name in
    let fd =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] mode
    in
    let _ = Unix.write_substring fd body 0 (String.length body) in
    Unix.close fd;
    Unix.chmod path mode
  in
  (* 0600 OK *)
  mk ~mode:0o600 "KEEP" "keep";
  (* 0644 — group/other readable, must be skipped + warned *)
  mk ~mode:0o644 "WORLD" "world";
  (* 0640 — group readable only, still wider than 0600, must be skipped *)
  mk ~mode:0o640 "GROUP" "group";
  let h, warnings = Proxy_lib.load_secret_dir ~dir:base in
  assert_b "KEEP loaded" (Hashtbl.find_opt h "KEEP" = Some "keep");
  assert_b "WORLD skipped" (Hashtbl.find_opt h "WORLD" = None);
  assert_b "GROUP skipped" (Hashtbl.find_opt h "GROUP" = None);
  (* Warning text must point at the file name AND the offending mode so an
     operator can identify what to fix without a stat. *)
  let any pred = List.exists pred warnings in
  assert_b "WORLD warning mentions name + 0644"
    (any (fun w -> contains "WORLD" w && contains "0644" w));
  assert_b "WORLD warning mentions mode"
    (any (fun w -> contains "mode" w && contains "WORLD" w));
  assert_b "GROUP warning mentions name + 0640"
    (any (fun w -> contains "GROUP" w && contains "0640" w));
  assert_b "no warning for KEEP"
    (not (any (fun w -> contains "KEEP" w)))

let test_proxy_load_secret_dir_skips_non_env_names () =
  with_temp_base @@ fun base ->
  let mk ~mode name body =
    let path = base ^ "/" ^ name in
    let fd =
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] mode
    in
    let _ = Unix.write_substring fd body 0 (String.length body) in
    Unix.close fd;
    Unix.chmod path mode
  in
  (* A real-world layout: the CA pem + key pair sit alongside the
     secrets dir for the bootstrap unit to read, BUT we must not treat
     "proxy-ca-key.pem" as a secret value mapped to env name "proxy-ca-key.pem"
     — that's not even a valid env-var name and would corrupt the
     lookup. *)
  mk ~mode:0o600 "OPENAI_KEY"   "sk-openai-value";
  mk ~mode:0o600 "ca.pem"       "<<<not-a-secret>>>";
  mk ~mode:0o600 "1FOO"         "digit-start-rejected";
  mk ~mode:0o600 "FOO-BAR"      "dash-rejected";
  mk ~mode:0o600 ".hidden"      "dotfile-rejected";
  let h, warnings = Proxy_lib.load_secret_dir ~dir:base in
  assert_b "valid env name kept"
    (Hashtbl.find_opt h "OPENAI_KEY" = Some "sk-openai-value");
  assert_b "ca.pem skipped" (Hashtbl.find_opt h "ca.pem" = None);
  assert_b "1FOO skipped" (Hashtbl.find_opt h "1FOO" = None);
  assert_b "FOO-BAR skipped" (Hashtbl.find_opt h "FOO-BAR" = None);
  assert_b ".hidden skipped" (Hashtbl.find_opt h ".hidden" = None);
  (* Warnings for the skipped ones; not for OPENAI_KEY. *)
  let any p = List.exists p warnings in
  assert_b "ca.pem warning mentions env-var name"
    (any (fun w -> contains "ca.pem" w && contains "env-var name" w));
  assert_b "no warning for OPENAI_KEY"
    (not (any (fun w -> contains "OPENAI_KEY" w)))

let test_proxy_load_secret_dir_skips_non_regular () =
  with_temp_base @@ fun base ->
  (* A subdirectory whose name is a valid env-var name must not be
     misread as a secret value. *)
  Unix.mkdir (base ^ "/SUBDIR") 0o700;
  let oc = open_out (base ^ "/REAL") in
  output_string oc "real-content"; close_out oc;
  Unix.chmod (base ^ "/REAL") 0o600;
  let h, warnings = Proxy_lib.load_secret_dir ~dir:base in
  assert_b "regular file loaded"
    (Hashtbl.find_opt h "REAL" = Some "real-content");
  assert_b "subdir not loaded"
    (Hashtbl.find_opt h "SUBDIR" = None);
  (* Non-regular entries skip silently (no warning) — directories
     mixed in alongside real secrets is a routine layout, not an error. *)
  assert_b "no warning for the subdir"
    (not (List.exists (fun w -> contains "SUBDIR" w) warnings))

(* Leaf-cache eviction lives in test_proxy_mitm.ml (needs the
   proxy_mitm library, which test_claude_vm.ml deliberately doesn't
   link to keep this binary cohttp/tls-free). *)

(* CA validity window: leaves should be backdated by ~60s to cover
   minor host/guest clock skew + extend ~1y into the future. *)
let test_proxy_ca_leaf_validity_window () =
  Lazy.force init_rng_once;
  let ca = Proxy_ca.generate_ca () in
  let leaf = Proxy_ca.generate_leaf ~ca ~hostname:"x.example" in
  let cert = Proxy_ca.leaf_cert leaf in
  let validity = X509.Certificate.validity cert in
  let nb_ptime = fst validity in
  let na_ptime = snd validity in
  let now = Unix.gettimeofday () in
  let nb_s = Ptime.to_float_s nb_ptime in
  let na_s = Ptime.to_float_s na_ptime in
  assert_b
    (Printf.sprintf "not_before is ~60s in past (got delta %.0fs)"
       (now -. nb_s))
    (now -. nb_s >= 30. && now -. nb_s <= 120.);
  let one_year_s = 365. *. 24. *. 3600. in
  assert_b
    (Printf.sprintf "not_after ~1y in future (got delta %.0fs)"
       (na_s -. now))
    (na_s -. now >= one_year_s -. 120. && na_s -. now <= one_year_s +. 120.)

(* Malformed hostnames in [generate_leaf]: today the x509 layer is
   permissive — empty string, embedded spaces, dots-only all sign
   without raising. Lock that in: the resulting cert MUST fail to
   match any real hostname when X509.Validation.verify_chain probes
   it. If a future x509 upgrade tightens this and starts raising on
   build, that's fine too — but silent acceptance + silent matching
   would be a security regression. *)
let test_proxy_ca_generate_leaf_bad_hostname_is_unmatchable () =
  Lazy.force init_rng_once;
  let ca = Proxy_ca.generate_ca () in
  let cert_pem = Proxy_ca.ca_cert_pem ca in
  let anchor =
    match X509.Certificate.decode_pem cert_pem with
    | Ok c -> c
    | Error (`Msg m) -> failwith m
  in
  let probe bad_host real_host =
    let leaf =
      try Some (Proxy_ca.generate_leaf ~ca ~hostname:bad_host)
      with Failure _ -> None
    in
    match leaf with
    | None -> ()   (* raise is acceptable *)
    | Some leaf ->
        let h =
          Domain_name.of_string_exn real_host |> Domain_name.host_exn
        in
        let r =
          X509.Validation.verify_chain
            ~host:(Some h) ~anchors:[ anchor ]
            ~time:(fun () -> Some (Ptime_clock.now ()))
            [ Proxy_ca.leaf_cert leaf ]
        in
        (match r with
         | Ok _ ->
             failwith
               (Printf.sprintf
                  "leaf with bad hostname %S unexpectedly matched %S"
                  bad_host real_host)
         | Error _ -> ())
  in
  probe ""            "example.com";
  probe "..."         "example.com";
  probe "  spaced  "  "spaced"

(* Mismatched CA pair: cert from CA-A + key from CA-B. load_ca itself
   succeeds (each PEM decodes independently); leaves signed with the
   wrong key fail chain validation against the cert. *)
let test_proxy_ca_load_ca_mismatched_pair () =
  Lazy.force init_rng_once;
  let ca1 = Proxy_ca.generate_ca ~common_name:"ca-one" () in
  let ca2 = Proxy_ca.generate_ca ~common_name:"ca-two" () in
  let cert_pem = Proxy_ca.ca_cert_pem ca1 in
  let key_pem = Proxy_ca.ca_key_pem ca2 in
  (* PEM decode succeeds. *)
  let mismatched =
    match Proxy_ca.load_ca ~cert_pem ~key_pem with
    | Ok ca -> ca
    | Error msg -> failwith ("expected load_ca to succeed: " ^ msg)
  in
  (* Mint a leaf using the wrong key — issuer DN matches cert (which
     came from ca1) but signature uses ca2's key. Chain validation
     against cert_pem (the trust anchor) must fail. *)
  let leaf = Proxy_ca.generate_leaf ~ca:mismatched ~hostname:"x.test" in
  let host = Domain_name.of_string_exn "x.test" |> Domain_name.host_exn in
  let anchor =
    match X509.Certificate.decode_pem cert_pem with
    | Ok c -> c
    | Error (`Msg m) -> failwith m
  in
  let result =
    X509.Validation.verify_chain
      ~host:(Some host) ~anchors:[ anchor ]
      ~time:(fun () -> Some (Ptime_clock.now ()))
      [ Proxy_ca.leaf_cert leaf ]
  in
  match result with
  | Ok _ ->
      failwith
        "chain validation succeeded for a leaf signed by the wrong key"
  | Error _ -> ()

(* TAB in header/template: Stage.proxy_auth_config has no escape, so a
   header containing TAB produces a four-field line. The parse round-trip
   then errors out — documenting the failure mode so a future change
   that "fixes" Stage to silently mangle the input gets caught. *)
let test_stage_proxy_auth_config_tab_in_header_fails_roundtrip () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  let bad_rule : Policy.proxy_auth_rule =
    { host = "api.x";
      header = "X-Has\tTab";          (* literal TAB in header value *)
      value_template = "v" }
  in
  Stage.proxy_auth_config ~etc_dir:etc [ bad_rule ];
  let path = etc ^ "/proxy-auth.conf" in
  let ic = open_in path in
  let n = in_channel_length ic in
  let content = really_input_string ic n in
  close_in ic;
  (* Stage doesn't sanitize — the on-disk line has THREE tabs instead
     of two, so parse_proxy_auth_config sees four fields and rejects. *)
  (match Proxy_lib.parse_proxy_auth_config content with
   | Ok _ ->
       failwith
         "expected parse error: TAB in header should produce a too-many-tabs line"
   | Error msg ->
       assert_b "parse error mentions tab count"
         (contains "TAB" msg || contains "tab" msg))

(* session_manifest helpers: hash + git probes degrade to None/false
   on missing inputs (not exceptions). *)
let test_session_manifest_sha256_file () =
  with_temp_base @@ fun base ->
  let path = base ^ "/hashme" in
  write_file path "the-quick-brown-fox\n";
  match Session_manifest.sha256_file path with
  | None ->
      (* Skip rather than fail if sha256sum isn't installed in the test
         env. Production has it (it's in the launcher PATH). *)
      Printf.printf "skip (no sha256sum on PATH)\n"
  | Some hex ->
      assert_b "sha256 is 64 hex chars" (String.length hex = 64);
      String.iter
        (fun c ->
          assert_b
            (Printf.sprintf "hex char %C" c)
            ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
        hex;
      (* Cross-check against direct shell-out: same bytes, same hash. *)
      let oracle =
        let ic =
          Unix.open_process_in
            (Printf.sprintf "sha256sum %s 2>/dev/null"
               (Filename.quote path))
        in
        let line = try input_line ic with End_of_file -> "" in
        let _ = Unix.close_process_in ic in
        if String.length line >= 64 then String.sub line 0 64 else ""
      in
      assert_b "sha256_file matches oracle" (hex = oracle)

let test_session_manifest_sha256_file_missing () =
  with_temp_base @@ fun base ->
  (* Non-existent path → None, no exception. *)
  assert_b "missing file → None"
    (Session_manifest.sha256_file (base ^ "/never") = None)

let test_session_manifest_git_rev_non_git () =
  with_temp_base @@ fun base ->
  (* base is a plain tmpdir, not a git repo. *)
  assert_b "non-git → None"
    (Session_manifest.git_rev_in base = None);
  assert_b "non-git dirty → false"
    (not (Session_manifest.git_dirty_in base))

let test_session_manifest_git_rev_in_git_repo () =
  with_temp_base @@ fun base ->
  (* Init a tiny repo and commit a file so HEAD resolves. The launcher
     calls git in a no-credentials, sandbox-friendly way; mimic that
     here with explicit user.{name,email}. If git isn't installed,
     skip. *)
  let rc =
    Sys.command
      (Printf.sprintf
         "cd %s && git init -q && git config user.email a@b \
          && git config user.name a \
          && git config commit.gpgsign false \
          && touch f && git add f \
          && git commit -q -m x"
         (Filename.quote base))
  in
  if rc <> 0 then Printf.printf "skip (git not usable)\n"
  else begin
    (match Session_manifest.git_rev_in base with
     | Some hex ->
         assert_b "rev is 40 hex chars"
           (String.length hex = 40);
         String.iter
           (fun c ->
             assert_b "rev hex"
               ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
           hex
     | None -> failwith "expected Some rev in fresh git repo");
    (* Clean tree → dirty is false. *)
    assert_b "clean tree → not dirty"
      (not (Session_manifest.git_dirty_in base));
    (* Make tree dirty. *)
    write_file (base ^ "/f") "changed\n";
    assert_b "modified tree → dirty"
      (Session_manifest.git_dirty_in base)
  end

let test_session_manifest_iso8601_local_shape () =
  let s = Session_manifest.iso8601_local () in
  (* RFC 3339 with explicit TZ offset: ends with "Z" or with "+HH:MM" /
     "-HH:MM". Length is fixed-format. *)
  assert_b "non-empty" (String.length s > 0);
  assert_b "contains 'T' separator" (String.contains s 'T');
  let last = s.[String.length s - 1] in
  let ends_with_offset =
    last = 'Z'
    || (let n = String.length s in
        n >= 6
        && (s.[n - 6] = '+' || s.[n - 6] = '-')
        && s.[n - 3] = ':')
  in
  assert_b "ends with Z or ±HH:MM offset" ends_with_offset

(* Policy parser negatives. The shape-error path is well-covered for
   primitive types (bad_auth, missing_field) but not for the nested
   types that landed in CP3 / Feature 1/2. *)
let test_policy_proxy_auth_missing_field () =
  let _, base = parse_fixture "vm-testing.json" in
  let kvs =
    match Policy.to_json base with
    | `Assoc kvs -> kvs
    | _ -> failwith "unreachable"
  in
  (* proxyAuth = [ { header = ...; valueTemplate = ... } ] — no host. *)
  let bad =
    `Assoc (
      List.filter (fun (k, _) -> k <> "proxyAuth") kvs
      @ [ "proxyAuth",
          `List [
            `Assoc [
              "header", `String "X-Test";
              "valueTemplate", `String "v";
            ]
          ] ])
  in
  match Policy.of_json bad with
  | Ok _ -> failwith "expected Error on proxyAuth missing host"
  | Error msg ->
      assert_b "error mentions proxyAuth path" (contains "proxyAuth" msg);
      assert_b "error mentions host field" (contains "host" msg)

let test_policy_secret_bad_scope () =
  let _, base = parse_fixture "vm-testing.json" in
  let kvs =
    match Policy.to_json base with
    | `Assoc kvs -> kvs
    | _ -> failwith "unreachable"
  in
  let bad =
    `Assoc (
      List.filter (fun (k, _) -> k <> "secrets") kvs
      @ [ "secrets",
          `List [
            `Assoc [
              "env", `String "X";
              "source", `String "/etc/passwd";
              "scope", `String "other";   (* not in {"agent","proxy"} *)
            ]
          ] ])
  in
  match Policy.of_json bad with
  | Ok _ -> failwith "expected Error on bad secret scope"
  | Error msg ->
      assert_b "error mentions secrets path" (contains "secrets" msg);
      assert_b "error names the bad value or expected set"
        (contains "other" msg || contains "agent" msg)

(* parse_upstream_rule with bracketed IPv6 — the audit flagged this as
   broken, but rindex_opt finds the LAST ':', which is correctly the
   port separator. Lock that in so a refactor to index_opt would catch
   regression. (NB: connect_direct still uses PF_INET so IPv6 actually
   reaching the wire is a separate change.) *)
let test_proxy_parse_upstream_rule_ipv6_bracketed () =
  let r =
    Proxy_lib.parse_upstream_rule ".internal.example=[::1]:8080"
  in
  assert_b "IPv6 suffix dot-stripped"
    (r.suffix = "internal.example");
  assert_b "IPv6 host kept with brackets"
    (r.proxy_host = "[::1]");
  assert_b "IPv6 port" (r.proxy_port = 8080);
  (* Pick still matches the suffix the normal way (no IPv6 concern in
     the suffix matching path). *)
  match Proxy_lib.pick_upstream [ r ] "host.internal.example" with
  | Some r' ->
      assert_b "pick → same host" (r'.proxy_host = "[::1]")
  | None -> failwith "expected pick to match"

(* vm-launcher ls — capture stdout, assert on the printed table. *)
let capture_stdout f =
  let orig_stdout = Unix.dup Unix.stdout in
  let r, w = Unix.pipe () in
  Unix.dup2 w Unix.stdout;
  Unix.close w;
  Fun.protect
    ~finally:(fun () ->
      flush stdout;
      Unix.dup2 orig_stdout Unix.stdout;
      Unix.close orig_stdout)
    (fun () ->
      let result = f () in
      flush stdout;
      let buf = Buffer.create 1024 in
      let bytes = Bytes.create 4096 in
      Unix.set_nonblock r;
      (try
         while true do
           let n = Unix.read r bytes 0 (Bytes.length bytes) in
           if n = 0 then raise Exit
           else Buffer.add_subbytes buf bytes 0 n
         done
       with
       | Exit -> ()
       | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ());
      Unix.close r;
      (result, Buffer.contents buf))

let test_ls_no_sessions () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  Unix.mkdir xdg 0o700;
  let state_base = base ^ "/run" in
  Unix.mkdir state_base 0o700;
  let (), out =
    capture_stdout (fun () -> Ls.run ~xdg_state_home:xdg ~state_base ())
  in
  assert_b "empty case prints diagnostic"
    (contains "no sessions found" out)

(* [?state_dir] lands as policy.resolved_json.stateDir (what Clean
   reads back to find the per-project symlink); [?runner_json] is a
   raw top-level fragment, e.g.
   [{|"runner":{"store_path":"/x","closure_bytes":1}|}] (what Ls's
   SIZE column reads). *)
let write_manifest ?(state_dir = "") ?(runner_json = "")
    dir id project launched =
  let path = dir ^ "/manifest.json" in
  let resolved =
    if state_dir = "" then "{}"
    else Printf.sprintf {|{"stateDir":"%s"}|} state_dir
  in
  let runner = if runner_json = "" then "" else "," ^ runner_json in
  let json =
    Printf.sprintf
      {|{"id":"%s","launched_at":"%s","project":"%s","launch_cwd":"/x","policy":{"resolved_json":%s},"flake":{"path":null,"rev":null,"dirty":false},"vm_launcher":{"store_path":null},"host":{"hostname":"h","user":"u"}%s}|}
      id launched project resolved runner
  in
  let oc = open_out path in
  output_string oc json;
  close_out oc

let test_ls_lists_global_manifests () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  Unix.mkdir xdg 0o700;
  let state_base = base ^ "/run" in
  Unix.mkdir state_base 0o700;
  let sessions = xdg ^ "/microvm/sessions" in
  ignore (Sys.command
            (Printf.sprintf "mkdir -p %s" (Filename.quote sessions)));
  let mk id project ts =
    let d = sessions ^ "/" ^ id in
    Unix.mkdir d 0o755;
    write_manifest d id project ts
  in
  mk "20260101T120000-aaaaaa" "/home/u/Alpha"
    "2026-01-01T12:00:00+00:00";
  mk "20260102T130000-bbbbbb" "/home/u/Beta"
    "2026-01-02T13:00:00+00:00";
  let (), out =
    capture_stdout (fun () -> Ls.run ~xdg_state_home:xdg ~state_base ())
  in
  assert_b "alpha id" (contains "20260101T120000-aaaaaa" out);
  assert_b "beta id"  (contains "20260102T130000-bbbbbb" out);
  assert_b "alpha basename" (contains "Alpha" out);
  assert_b "beta basename"  (contains "Beta"  out);
  (* No live state dirs → both rows say 'exited'. *)
  let count_substr needle hay =
    let n = String.length needle and m = String.length hay in
    let rec loop i acc =
      if i + n > m then acc
      else if String.sub hay i n = needle then loop (i + n) (acc + 1)
      else loop (i + 1) acc
    in loop 0 0
  in
  assert_b "two 'exited' rows" (count_substr "exited" out = 2);
  (* Sort: same state group (both exited) → alphabetical by id, so
     Alpha (aaaaaa) above Beta (bbbbbb). *)
  let idx needle =
    let n = String.length needle and m = String.length out in
    let rec loop i =
      if i + n > m then -1
      else if String.sub out i n = needle then i else loop (i + 1)
    in loop 0
  in
  let beta_pos = idx "Beta" and alpha_pos = idx "Alpha" in
  assert_b "Alpha sorted above Beta"
    (beta_pos >= 0 && alpha_pos >= 0 && alpha_pos < beta_pos)

(* mkdir -p replacement: native, no shell-out, so dune's test sandbox
   can't restrict it (and we don't have to spell out a sequence of
   Unix.mkdirs at every test call site). *)
let rec mkdirp ?(perm = 0o755) path =
  if path = "" || path = "/" || path = "." then ()
  else if Sys.file_exists path then ()
  else begin
    mkdirp ~perm (Filename.dirname path);
    try Unix.mkdir path perm
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let test_ls_marks_live_session_as_running () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  Unix.mkdir xdg 0o700;
  let state_base = base ^ "/run" in
  Unix.mkdir state_base 0o700;
  let sessions = xdg ^ "/microvm/sessions" in
  mkdirp sessions;
  let id = "20260104T100000-cafebe" in
  let d = sessions ^ "/" ^ id in
  Unix.mkdir d 0o755;
  write_manifest d id "/home/u/LiveProj" "2026-01-04T10:00:00+00:00";
  let pid =
    match Unix.fork () with
    | 0 -> (try Unix.sleep 30 with _ -> ()); Unix._exit 0
    | n -> n
  in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill pid Sys.sigkill with _ -> ());
      (try ignore (Unix.waitpid [] pid) with _ -> ()))
    (fun () ->
      let live_dir = Printf.sprintf "%s/session-%d" state_base pid in
      let etc = live_dir ^ "/etc" in
      mkdirp etc;
      let oc = open_out (etc ^ "/session-id") in
      output_string oc id;
      close_out oc;
      let (), out =
        capture_stdout (fun () -> Ls.run ~xdg_state_home:xdg ~state_base ())
      in
      assert_b "LiveProj basename present" (contains "LiveProj" out);
      assert_b "row marked running" (contains "running" out);
      assert_b "child pid in output"
        (contains (string_of_int pid) out))

(* Launcher alive, session.ssh on, but no attach.json yet: the runner
   has not been spawned, so the session is still in `nix build`. It must
   not read as "running" — that word now promises attach works. *)
let test_ls_marks_prebuild_session_as_building () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  Unix.mkdir xdg 0o700;
  let state_base = base ^ "/run" in
  Unix.mkdir state_base 0o700;
  let sessions = xdg ^ "/microvm/sessions" in
  mkdirp sessions;
  let id = "20260104T100000-bu1ld0" in
  let d = sessions ^ "/" ^ id in
  Unix.mkdir d 0o755;
  write_manifest d id "/home/u/BuildProj" "2026-01-04T10:00:00+00:00";
  let pid =
    match Unix.fork () with
    | 0 -> (try Unix.sleep 30 with _ -> ()); Unix._exit 0
    | n -> n
  in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill pid Sys.sigkill with _ -> ());
      (try ignore (Unix.waitpid [] pid) with _ -> ()))
    (fun () ->
      let live_dir = Printf.sprintf "%s/session-%d" state_base pid in
      mkdirp (live_dir ^ "/etc");
      let write path txt =
        let oc = open_out path in
        output_string oc txt;
        close_out oc
      in
      write (live_dir ^ "/etc/session-id") id;
      write (live_dir ^ "/policy.json") {|{"session":{"ssh":true}}|};
      let (), out =
        capture_stdout (fun () -> Ls.run ~xdg_state_home:xdg ~state_base ())
      in
      assert_b "row marked building" (contains "building" out);
      assert_b "footer flags it not ready" (contains "not ready yet" out);
      let (), ids =
        capture_stdout (fun () ->
            ignore (Ls.ids ~live_only:true ~xdg_state_home:xdg ~state_base ()))
      in
      assert_b "a building session is not an attach candidate"
        (not (contains id ids)))

let test_ls_orphan_live_session () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  Unix.mkdir xdg 0o700;
  let state_base = base ^ "/run" in
  Unix.mkdir state_base 0o700;
  let pid =
    match Unix.fork () with
    | 0 -> (try Unix.sleep 30 with _ -> ()); Unix._exit 0
    | n -> n
  in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill pid Sys.sigkill with _ -> ());
      (try ignore (Unix.waitpid [] pid) with _ -> ()))
    (fun () ->
      let live_dir = Printf.sprintf "%s/session-%d" state_base pid in
      let etc = live_dir ^ "/etc" in
      mkdirp etc;
      let oc = open_out (etc ^ "/session-id") in
      output_string oc "20260105T100000-orphan";
      close_out oc;
      let (), out =
        capture_stdout (fun () -> Ls.run ~xdg_state_home:xdg ~state_base ())
      in
      assert_b "orphan id printed"
        (contains "20260105T100000-orphan" out);
      assert_b "'no manifest' marker present"
        (contains "no manifest" out))

(* ls caps a plain run at 10 rows (newest first) and points at --all;
   --all lifts the cap. *)
let test_ls_caps_at_ten_without_all () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  let state_base = base ^ "/run" in
  Unix.mkdir state_base 0o700;
  let sessions = xdg ^ "/microvm/sessions" in
  mkdirp sessions;
  for i = 1 to 12 do
    let id = Printf.sprintf "202601%02dT120000-aaaaaa" i in
    let d = sessions ^ "/" ^ id in
    Unix.mkdir d 0o755;
    write_manifest d id "/home/u/Proj"
      (Printf.sprintf "2026-01-%02dT12:00:00+00:00" i)
  done;
  let (), out =
    capture_stdout (fun () -> Ls.run ~xdg_state_home:xdg ~state_base ())
  in
  assert_b "newest row shown" (contains "20260112T120000" out);
  assert_b "11th-newest row hidden" (not (contains "20260102T120000" out));
  assert_b "oldest row hidden" (not (contains "20260101T120000" out));
  assert_b "overflow line points at --all"
    (contains "2 more" out && contains "--all" out);
  let (), out_all =
    capture_stdout (fun () ->
      Ls.run ~all:true ~xdg_state_home:xdg ~state_base ())
  in
  assert_b "--all shows the oldest row"
    (contains "20260101T120000" out_all);
  assert_b "--all has no overflow line"
    (not (contains "more" out_all))

(* ls orders rows by state group — live (running/detached/orphaned)
   first, then stale, then exited — alphabetically by id within each
   group. Launch time must NOT override the grouping: the live
   session here is the oldest and still prints first, the newest
   session is exited and prints last. *)
let test_ls_orders_by_state_group () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  let state_base = base ^ "/run" in
  Unix.mkdir state_base 0o700;
  let sessions = xdg ^ "/microvm/sessions" in
  mkdirp sessions;
  let mk id ts =
    let d = sessions ^ "/" ^ id in
    Unix.mkdir d 0o755;
    write_manifest d id "/home/u/Proj" ts
  in
  let live_id = "20260101T120000-alive0" in
  let stale_id = "20260102T120000-stale0" in
  let exited_a = "20260103T120000-exitaa" in
  let exited_b = "20260104T120000-exitbb" in
  mk live_id "2026-01-01T12:00:00+00:00";
  mk stale_id "2026-01-02T12:00:00+00:00";
  mk exited_a "2026-01-03T12:00:00+00:00";
  mk exited_b "2026-01-04T12:00:00+00:00";
  let put_session_id dir id =
    mkdirp (dir ^ "/etc");
    let oc = open_out (dir ^ "/etc/session-id") in
    output_string oc id;
    close_out oc
  in
  (* Stale: a state dir named after a pid that existed and is dead. *)
  let dead_pid =
    match Unix.fork () with
    | 0 -> Unix._exit 0
    | n -> ignore (Unix.waitpid [] n); n
  in
  put_session_id
    (Printf.sprintf "%s/session-%d" state_base dead_pid) stale_id;
  (* Live: a state dir named after a pid that is still running. *)
  let pid =
    match Unix.fork () with
    | 0 -> (try Unix.sleep 30 with _ -> ()); Unix._exit 0
    | n -> n
  in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill pid Sys.sigkill with _ -> ());
      (try ignore (Unix.waitpid [] pid) with _ -> ()))
    (fun () ->
      put_session_id
        (Printf.sprintf "%s/session-%d" state_base pid) live_id;
      let (), out =
        capture_stdout (fun () ->
          Ls.run ~xdg_state_home:xdg ~state_base ())
      in
      let idx needle =
        let n = String.length needle and m = String.length out in
        let rec loop i =
          if i + n > m then
            failwith (Printf.sprintf "row %s not in ls output" needle)
          else if String.sub out i n = needle then i
          else loop (i + 1)
        in
        loop 0
      in
      assert_b "live row above stale row" (idx live_id < idx stale_id);
      assert_b "stale row above exited rows" (idx stale_id < idx exited_a);
      assert_b "exited rows alphabetical" (idx exited_a < idx exited_b))

(* SIZE column: rendered from the manifest's runner block while the
   store path exists; "-" once it's gone (nix GC) or absent (old
   manifests). *)
let test_ls_size_column_from_runner_block () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  let state_base = base ^ "/run" in
  Unix.mkdir state_base 0o700;
  let sessions = xdg ^ "/microvm/sessions" in
  mkdirp sessions;
  let mk id ts runner_json =
    let d = sessions ^ "/" ^ id in
    Unix.mkdir d 0o755;
    write_manifest ~runner_json d id "/home/u/Proj" ts
  in
  (* [base] exists → size shown; 10 GiB + change → "10.1G". *)
  mk "20260101T120000-sized0" "2026-01-01T12:00:00+00:00"
    (Printf.sprintf
       {|"runner":{"store_path":"%s","closure_bytes":10845127639}|} base);
  (* Store path GC'd → "-" even though bytes were recorded. *)
  mk "20260102T120000-gcgone" "2026-01-02T12:00:00+00:00"
    (Printf.sprintf
       {|"runner":{"store_path":"%s/nope","closure_bytes":10845127639}|}
       base);
  (* Pre-runner-block manifest → "-". *)
  mk "20260103T120000-legacy" "2026-01-03T12:00:00+00:00" "";
  let (), out =
    capture_stdout (fun () -> Ls.run ~xdg_state_home:xdg ~state_base ())
  in
  assert_b "SIZE header present" (contains "SIZE" out);
  assert_b "live store path renders GiB" (contains "10.1G" out);
  (* Exactly one row carries a size; the other two fall back to "-".
     Cheap proxy: the GiB string appears exactly once. *)
  let count_substr needle hay =
    let n = String.length needle and m = String.length hay in
    let rec loop i acc =
      if i + n > m then acc
      else if String.sub hay i n = needle then loop (i + n) (acc + 1)
      else loop (i + 1) acc
    in loop 0 0
  in
  assert_b "only the live-path row has a size"
    (count_substr "10.1G" out = 1)

(* clean <id> on an exited session: registry dir + per-project
   symlink both go; an unrelated session survives. *)
let test_clean_exited_removes_registry_and_symlink () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  let state_base = base ^ "/run" in
  Unix.mkdir state_base 0o700;
  let sessions = xdg ^ "/microvm/sessions" in
  mkdirp sessions;
  let proj_state = base ^ "/proj-state" in
  mkdirp (proj_state ^ "/sessions");
  let mk id ts =
    let d = sessions ^ "/" ^ id in
    Unix.mkdir d 0o755;
    write_manifest ~state_dir:proj_state d id "/home/u/Proj" ts;
    Unix.symlink d (proj_state ^ "/sessions/" ^ id);
    d
  in
  let victim = mk "20260101T120000-victim" "2026-01-01T12:00:00+00:00" in
  let keeper = mk "20260102T120000-keeper" "2026-01-02T12:00:00+00:00" in
  let rc, _ =
    capture_stdout (fun () ->
      Clean.run ~xdg_state_home:xdg ~state_base
        ~ids:[ "20260101T120000-victim" ] ~exited:false)
  in
  assert_b "clean exits 0" (rc = 0);
  assert_b "victim registry dir removed" (not (Sys.file_exists victim));
  assert_b "victim project symlink removed"
    (not (Sys.file_exists
            (proj_state ^ "/sessions/20260101T120000-victim")));
  assert_b "keeper registry dir intact" (Sys.file_exists keeper);
  assert_b "keeper project symlink intact"
    (Sys.file_exists (proj_state ^ "/sessions/20260102T120000-keeper"))

(* clean refuses a running session (live state dir + alive pid). *)
let test_clean_refuses_running_session () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  let state_base = base ^ "/run" in
  Unix.mkdir state_base 0o700;
  let sessions = xdg ^ "/microvm/sessions" in
  mkdirp sessions;
  let id = "20260104T100000-alive0" in
  let d = sessions ^ "/" ^ id in
  Unix.mkdir d 0o755;
  write_manifest d id "/home/u/Live" "2026-01-04T10:00:00+00:00";
  let pid =
    match Unix.fork () with
    | 0 -> (try Unix.sleep 30 with _ -> ()); Unix._exit 0
    | n -> n
  in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill pid Sys.sigkill with _ -> ());
      (try ignore (Unix.waitpid [] pid) with _ -> ()))
    (fun () ->
      let live_dir = Printf.sprintf "%s/session-%d" state_base pid in
      mkdirp (live_dir ^ "/etc");
      let oc = open_out (live_dir ^ "/etc/session-id") in
      output_string oc id;
      close_out oc;
      let rc, _ =
        capture_stdout (fun () ->
          Clean.run ~xdg_state_home:xdg ~state_base
            ~ids:[ id ] ~exited:false)
      in
      assert_b "clean exits 1 on a running session" (rc = 1);
      assert_b "registry dir untouched" (Sys.file_exists d);
      assert_b "live state dir untouched" (Sys.file_exists live_dir))

(* clean on a stale session (state dir whose pid is dead): the /run
   dir and its current-session symlink go too. A pidfile naming a
   dead pid must not blow up the pass. *)
let test_clean_stale_removes_state_dir () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  let state_base = base ^ "/run" in
  Unix.mkdir state_base 0o700;
  let sessions = xdg ^ "/microvm/sessions" in
  mkdirp sessions;
  let id = "20260105T100000-stale0" in
  let d = sessions ^ "/" ^ id in
  Unix.mkdir d 0o755;
  write_manifest d id "/home/u/Stale" "2026-01-05T10:00:00+00:00";
  (* A pid that existed and is now dead: fork a child that exits
     immediately, reap it. *)
  let dead_pid =
    match Unix.fork () with
    | 0 -> Unix._exit 0
    | n -> ignore (Unix.waitpid [] n); n
  in
  let live_dir = Printf.sprintf "%s/session-%d" state_base dead_pid in
  mkdirp (live_dir ^ "/etc");
  let oc = open_out (live_dir ^ "/etc/session-id") in
  output_string oc id;
  close_out oc;
  (* Leftover virtiofsd pidfile pointing at the same dead pid — the
     cmdline probe finds no /proc entry and must skip, not raise. *)
  let oc = open_out (live_dir ^ "/proj-virtiofs-work.sock.pid") in
  output_string oc (string_of_int dead_pid);
  close_out oc;
  Unix.symlink live_dir (state_base ^ "/current-session-1");
  let rc, _ =
    capture_stdout (fun () ->
      Clean.run ~xdg_state_home:xdg ~state_base ~ids:[ id ] ~exited:false)
  in
  assert_b "clean exits 0" (rc = 0);
  assert_b "stale state dir removed" (not (Sys.file_exists live_dir));
  assert_b "registry dir removed" (not (Sys.file_exists d));
  assert_b "current-session symlink removed"
    (match Unix.lstat (state_base ^ "/current-session-1") with
     | _ -> false
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true)

(* clean --exited sweeps everything not running and spares the
   running session. *)
let test_clean_exited_bulk_spares_running () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  let state_base = base ^ "/run" in
  Unix.mkdir state_base 0o700;
  let sessions = xdg ^ "/microvm/sessions" in
  mkdirp sessions;
  let mk id ts =
    let d = sessions ^ "/" ^ id in
    Unix.mkdir d 0o755;
    write_manifest d id "/home/u/Proj" ts;
    d
  in
  let dead1 = mk "20260101T120000-dead01" "2026-01-01T12:00:00+00:00" in
  let dead2 = mk "20260102T120000-dead02" "2026-01-02T12:00:00+00:00" in
  let live_id = "20260103T120000-alive0" in
  let live_reg = mk live_id "2026-01-03T12:00:00+00:00" in
  let pid =
    match Unix.fork () with
    | 0 -> (try Unix.sleep 30 with _ -> ()); Unix._exit 0
    | n -> n
  in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.kill pid Sys.sigkill with _ -> ());
      (try ignore (Unix.waitpid [] pid) with _ -> ()))
    (fun () ->
      let live_dir = Printf.sprintf "%s/session-%d" state_base pid in
      mkdirp (live_dir ^ "/etc");
      let oc = open_out (live_dir ^ "/etc/session-id") in
      output_string oc live_id;
      close_out oc;
      let rc, out =
        capture_stdout (fun () ->
          Clean.run ~xdg_state_home:xdg ~state_base ~ids:[] ~exited:true)
      in
      assert_b "bulk clean exits 0" (rc = 0);
      assert_b "dead 1 removed" (not (Sys.file_exists dead1));
      assert_b "dead 2 removed" (not (Sys.file_exists dead2));
      assert_b "running registry dir spared" (Sys.file_exists live_reg);
      assert_b "running state dir spared" (Sys.file_exists live_dir);
      assert_b "both cleans reported"
        (contains "20260101T120000-dead01" out
         && contains "20260102T120000-dead02" out))

(* resolve_state_dir without an XDG hint and with the policy state_dir
   pointed at the project basename — same path the user gets with no
   --policy + a project-root cwd. *)
let test_resolve_state_dir_blank_policy_uses_xdg () =
  with_env "HOME" "/H" @@ fun () ->
  let r =
    Resolver.resolve_state_dir
      ~policy_state_dir:None
      ~xdg_state_home:"/X"
      ~project_basename:"my-proj"
  in
  assert_b "uses XDG / microvm / basename"
    (r = "/X/microvm/my-proj");
  (* Tilde-expanded policy path overrides XDG completely. *)
  let r =
    Resolver.resolve_state_dir
      ~policy_state_dir:(Some "~/elsewhere")
      ~xdg_state_home:"/X-ignored"
      ~project_basename:"my-proj"
  in
  assert_b "policy path overrides XDG"
    (r = "/H/elsewhere")

(* policy.shares — additive contract field, forward-compat. *)

let test_policy_shares_default () =
  (* The sample-project fixture has no [shares] field — parser must default
     to []. Same forward-compat pattern as proxyAuth + guest + startup. *)
  let _, p = parse_fixture "sample-project.json" in
  assert_b "shares empty by default" (p.shares = [])

let test_policy_shares_parse () =
  let _, base = parse_fixture "vm-testing.json" in
  let kvs =
    match Policy.to_json base with
    | `Assoc kvs -> kvs
    | _ -> failwith "unreachable"
  in
  let with_shares shares_json =
    let kvs' =
      List.filter (fun (k, _) -> k <> "shares") kvs
      @ [ "shares", shares_json ]
    in
    match Policy.of_json (`Assoc kvs') with
    | Ok p -> p
    | Error msg -> failwith ("parse: " ^ msg)
  in
  (* Single RO share, default omitted via the optional readOnly path. *)
  let p =
    with_shares
      (`List [
        `Assoc [
          "source", `String "/data/foo";
          "mountPoint", `String "/mnt/foo";
          "readOnly", `Bool true;
        ];
      ])
  in
  assert_b "one share parsed" (List.length p.shares = 1);
  let s = List.hd p.shares in
  assert_b "source" (s.source = "/data/foo");
  assert_b "mountPoint" (s.mount_point = "/mnt/foo");
  assert_b "readOnly" (s.read_only = true);
  (* Explicit readOnly=false roundtrips. *)
  let p =
    with_shares
      (`List [
        `Assoc [
          "source", `String "/srv/scratch";
          "mountPoint", `String "/var/lib/scratch";
          "readOnly", `Bool false;
        ];
      ])
  in
  assert_b "rw share parsed"
    ((List.hd p.shares).read_only = false);
  (* readOnly omitted -> default false (the optional-with-default path
     in parse_share). Defends the forward-compat semantics: a fixture
     written before the parser learned about readOnly should still
     parse as RW. *)
  let p =
    with_shares
      (`List [
        `Assoc [
          "source", `String "/srv/scratch";
          "mountPoint", `String "/var/lib/scratch";
        ];
      ])
  in
  assert_b "readOnly omitted -> defaults to false"
    ((List.hd p.shares).read_only = false);
  (* Missing required field surfaces with the field path. *)
  let bad =
    `Assoc (
      List.filter (fun (k, _) -> k <> "shares") kvs
      @ [ "shares", `List [
            `Assoc [ "mountPoint", `String "/x"; "readOnly", `Bool false ]
          ] ])
  in
  match Policy.of_json bad with
  | Ok _ -> failwith "expected Error on shares missing source"
  | Error msg ->
      assert_b "error mentions shares path" (contains "shares" msg);
      assert_b "error mentions source field" (contains "source" msg)

let test_policy_shares_roundtrip () =
  let _, base = parse_fixture "vm-testing.json" in
  let p =
    { base with
      shares = [
        { source = "/data/a"; mount_point = "/mnt/a"; read_only = true };
        { source = "/data/b"; mount_point = "/var/lib/b"; read_only = false };
      ] }
  in
  match Policy.of_json (Policy.to_json p) with
  | Error msg -> failwith ("roundtrip: " ^ msg)
  | Ok p' -> assert_b "shares survive roundtrip" (p'.shares = p.shares)

let test_default_policy_shares_empty () =
  let p = Resolver.default_policy ~project:"/x" in
  assert_b "default policy has no shares" (p.shares = [])

let test_stage_resolve_shares_missing_source () =
  with_temp_base @@ fun base ->
  let _, base_p = parse_fixture "vm-testing.json" in
  let p =
    { base_p with shares = [
        { source = base ^ "/not-there";
          mount_point = "/mnt/x";
          read_only = true };
      ] }
  in
  try
    let _ = Stage.resolve_shares p in
    failwith "expected failwith on missing share source"
  with Failure msg ->
    assert_b "error mentions shares + path"
      (contains "shares" msg && contains "/not-there" msg);
    assert_b "error mentions mountPoint"
      (contains "/mnt/x" msg)

let test_stage_resolve_shares_tilde_expand () =
  with_temp_base @@ fun base ->
  with_env "HOME" base @@ fun () ->
  (* Create a real source dir; pass it via ~/foo so tilde expansion
     turns it into an absolute path. *)
  Unix.mkdir (base ^ "/foo") 0o755;
  let _, base_p = parse_fixture "vm-testing.json" in
  let p =
    { base_p with shares = [
        { source = "~/foo";
          mount_point = "/mnt/foo";
          read_only = false };
      ] }
  in
  let p' = Stage.resolve_shares p in
  let s = List.hd p'.shares in
  assert_b "tilde expanded" (s.source = base ^ "/foo");
  assert_b "mountPoint untouched" (s.mount_point = "/mnt/foo");
  assert_b "readOnly preserved" (s.read_only = false)

let test_shares_ro_tags_with_shares () =
  let base = Resolver.default_policy ~project:"/x" in
  let p =
    { base with shares = [
        { source = "/data/a"; mount_point = "/mnt/a"; read_only = true };
        { source = "/data/b"; mount_point = "/mnt/b"; read_only = false };
        { source = "/data/c"; mount_point = "/mnt/c"; read_only = true };
      ] }
  in
  let tags = Shares.ro_tags p in
  assert_b "share-0 (ro) present" (List.mem "share-0" tags);
  assert_b "share-1 (rw) absent" (not (List.mem "share-1" tags));
  assert_b "share-2 (ro) present" (List.mem "share-2" tags);
  (* And the always-on tags are still there too. *)
  assert_b "vmcfg still there" (List.mem "vmcfg" tags)

let test_validate_nix_string_escape_basic () =
  assert_b "wraps in double quotes"
    (Validate.nix_string_escape "foo" = "\"foo\"");
  assert_b "escapes backslash"
    (Validate.nix_string_escape "a\\b" = "\"a\\\\b\"");
  assert_b "escapes double quote"
    (Validate.nix_string_escape "a\"b" = "\"a\\\"b\"");
  assert_b "escapes newline"
    (Validate.nix_string_escape "a\nb" = "\"a\\nb\"");
  assert_b "escapes dollar (defangs ${} interp)"
    (Validate.nix_string_escape "${RM}" = "\"\\${RM}\"")

let test_validate_build_tools_expr_shape () =
  let expr =
    Validate.build_tools_expr ~flake:"path:/x" ~tools:[ "git"; "jq" ]
  in
  assert_b "embeds flake URI quoted" (contains "\"path:/x\"" expr);
  assert_b "embeds first tool" (contains "\"git\"" expr);
  assert_b "embeds second tool" (contains "\"jq\"" expr);
  assert_b "uses getFlake" (contains "builtins.getFlake" expr);
  assert_b "uses hasAttr" (contains "builtins.hasAttr" expr);
  assert_b "uses nixosConfiguration's overlaid pkgs"
    (contains "nixosConfigurations.vmLauncher.pkgs" expr)

let test_validate_build_tools_expr_honors_nixos_config_env () =
  let prev = try Some (Sys.getenv "VM_LAUNCHER_NIXOS_CONFIG")
             with Not_found -> None
  in
  Unix.putenv "VM_LAUNCHER_NIXOS_CONFIG" "myCustomGuest";
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | Some v -> Unix.putenv "VM_LAUNCHER_NIXOS_CONFIG" v
      | None -> Unix.putenv "VM_LAUNCHER_NIXOS_CONFIG" "")
    (fun () ->
      let expr =
        Validate.build_tools_expr ~flake:"path:/x" ~tools:[ "git" ]
      in
      assert_b "uses the override"
        (contains "nixosConfigurations.myCustomGuest.pkgs" expr);
      assert_b "does NOT use the default"
        (not (contains "nixosConfigurations.vmLauncher.pkgs" expr)))

let test_validate_build_tools_expr_escapes_hostile_name () =
  (* A tool name carrying ${...} must not get interpolated by the
     eval; the dollar sign needs escaping in the embedded literal.
     Every [${] occurrence must be preceded by [\]. *)
  let expr =
    Validate.build_tools_expr ~flake:"path:/x"
      ~tools:[ "\";rm -rf /;${pkgs.hello}" ]
  in
  assert_b "escaped interp present" (contains "\\${pkgs.hello}" expr);
  let rec all_dollar_braces_escaped i =
    match String.index_from_opt expr i '$' with
    | None -> true
    | Some k ->
      let next_is_brace =
        k + 1 < String.length expr && expr.[k + 1] = '{'
      in
      if not next_is_brace then all_dollar_braces_escaped (k + 1)
      else if k > 0 && expr.[k - 1] = '\\' then
        all_dollar_braces_escaped (k + 1)
      else false
  in
  assert_b "no unescaped ${...} anywhere in the expression"
    (all_dollar_braces_escaped 0);
  (* And the embedded double-quote / semicolons did not break out
     of the string literal: the closing quote of THIS tool's literal
     is still present after the escaped payload. *)
  assert_b "quoted closing of the hostile name"
    (contains "\\${pkgs.hello}\"" expr)

(* --- Validate.tools end-to-end against a fake `nix` shim on PATH ---

   Spawns a real subprocess (sh script masquerading as `nix`) so the
   pipe handling, JSON parse, and error-message rendering paths run
   the same code the production launcher does. Sandbox-safe: no
   network, no /nix/store, no nixpkgs eval — the shim emits whatever
   string the test wrote to its output file. *)

let with_fake_nix ~output ?(rc = 0) f =
  with_temp_base @@ fun base ->
  let bin_dir = base ^ "/bin" in
  Unix.mkdir bin_dir 0o755;
  let script = bin_dir ^ "/nix" in
  let oc = open_out script in
  (* Single dispatch: dump $FAKE_NIX_OUTPUT_FILE if set; exit with
     $FAKE_NIX_RC. Ignores all argv — the launcher invokes
     `nix eval --impure --json --expr <expr>` but the shim doesn't
     parse it. *)
  output_string oc "#!/bin/sh\n";
  output_string oc
    "if [ -n \"$FAKE_NIX_OUTPUT_FILE\" ] && [ -f \"$FAKE_NIX_OUTPUT_FILE\" ]; \
     then cat \"$FAKE_NIX_OUTPUT_FILE\"; fi\n";
  output_string oc "exit \"${FAKE_NIX_RC:-0}\"\n";
  close_out oc;
  Unix.chmod script 0o755;
  let out_file = base ^ "/output" in
  let oc = open_out out_file in
  output_string oc output;
  close_out oc;
  let prev_path = try Sys.getenv "PATH" with Not_found -> "" in
  with_env "PATH" (bin_dir ^ ":" ^ prev_path) @@ fun () ->
  with_env "FAKE_NIX_OUTPUT_FILE" out_file @@ fun () ->
  with_env "FAKE_NIX_RC" (string_of_int rc) f

let test_validate_tools_fake_nix_all_good () =
  with_fake_nix ~output:"[]" @@ fun () ->
  Validate.tools ~flake:"path:/dummy" ~tools:[ "git"; "jq" ]

let test_validate_tools_fake_nix_bad_single () =
  with_fake_nix ~output:"[\"foo\"]" @@ fun () ->
  let raised = ref false in
  (try
     Validate.tools ~flake:"path:/dummy" ~tools:[ "git"; "foo" ]
   with Failure msg ->
     raised := true;
     assert_b "names the bad attr" (contains "'foo'" msg);
     assert_b "mentions policy.tools" (contains "policy.tools" msg));
  assert_b "Failure was raised" !raised

let test_validate_tools_fake_nix_bad_multiple () =
  with_fake_nix ~output:"[\"alpha\",\"beta\"]" @@ fun () ->
  let raised = ref false in
  (try
     Validate.tools ~flake:"path:/dummy" ~tools:[ "git"; "alpha"; "beta" ]
   with Failure msg ->
     raised := true;
     assert_b "names alpha" (contains "'alpha'" msg);
     assert_b "names beta" (contains "'beta'" msg));
  assert_b "Failure was raised" !raised

let test_validate_tools_fake_nix_null_input () =
  (* `null` = "flake has no `nixpkgs` input"; launcher logs a warning
     and proceeds without raising. *)
  with_fake_nix ~output:"null" @@ fun () ->
  Validate.tools ~flake:"path:/dummy" ~tools:[ "git" ]

let test_validate_tools_fake_nix_non_zero_exit () =
  (* nix eval blew up for some unrelated reason; best-effort path:
     log + continue. *)
  with_fake_nix ~output:"" ~rc:1 @@ fun () ->
  Validate.tools ~flake:"path:/dummy" ~tools:[ "git" ]

let test_validate_tools_fake_nix_garbage_output () =
  (* Whatever the shim printed isn't JSON; same best-effort path. *)
  with_fake_nix ~output:"not json at all\n" @@ fun () ->
  Validate.tools ~flake:"path:/dummy" ~tools:[ "git" ]

let test_validate_tools_empty_list_skips_subprocess () =
  (* Empty list = no-op; the shim is rigged to exit 99 to prove the
     subprocess isn't even spawned. *)
  with_fake_nix ~output:"" ~rc:99 @@ fun () ->
  Validate.tools ~flake:"path:/dummy" ~tools:[]

(* --- Validate.host_memory against a fake /proc/meminfo --- *)

let fake_meminfo =
  "MemTotal:       65329788 kB\n\
   MemFree:        12345678 kB\n\
   MemAvailable:   41943040 kB\n\
   Buffers:          123456 kB\n"

let with_fake_meminfo contents f =
  with_temp_base @@ fun base ->
  let path = base ^ "/meminfo" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  f path

let test_validate_meminfo_field () =
  assert_b "MemTotal parsed"
    (Validate.meminfo_field ~field:"MemTotal" fake_meminfo
     = Some 65329788);
  assert_b "MemAvailable parsed"
    (Validate.meminfo_field ~field:"MemAvailable" fake_meminfo
     = Some 41943040);
  assert_b "missing field is None"
    (Validate.meminfo_field ~field:"SwapTotal" fake_meminfo = None);
  (* "Mem" must not prefix-match "MemTotal"/"MemFree"/... lines. *)
  assert_b "prefix of a longer field is None"
    (Validate.meminfo_field ~field:"Mem" fake_meminfo = None);
  assert_b "garbage contents is None"
    (Validate.meminfo_field ~field:"MemTotal" "not meminfo at all"
     = None)

let test_validate_host_memory_within_total () =
  (* 63798 MB total, 40960 MB available: fits under both. *)
  with_fake_meminfo fake_meminfo @@ fun path ->
  Validate.host_memory ~meminfo_path:path ~mem_mb:32000 ()

let test_validate_host_memory_above_available_warns_only () =
  (* Above MemAvailable (40960 MB) but under MemTotal (63798 MB):
     warning on stderr, no raise. *)
  with_fake_meminfo fake_meminfo @@ fun path ->
  Validate.host_memory ~meminfo_path:path ~mem_mb:48000 ()

let test_validate_host_memory_above_total_raises () =
  (* The motivating case: memMb = 64000 on a host with less RAM than that. *)
  with_fake_meminfo fake_meminfo @@ fun path ->
  let raised = ref false in
  (try Validate.host_memory ~meminfo_path:path ~mem_mb:64000 ()
   with Failure msg ->
     raised := true;
     assert_b "names the policy value" (contains "64000" msg);
     assert_b "names host MemTotal" (contains "63798" msg);
     assert_b "points at the policy field" (contains "memMb" msg));
  assert_b "Failure was raised" !raised

let test_validate_host_memory_unreadable_meminfo_skips () =
  (* Best-effort contract: no meminfo, no check, no raise. *)
  Validate.host_memory ~meminfo_path:"/nonexistent/meminfo"
    ~mem_mb:1000000 ()

let test_validate_host_memory_no_memavailable () =
  (* Some kernels/containers omit MemAvailable; only the MemTotal
     hard check applies. *)
  with_fake_meminfo "MemTotal:       65329788 kB\n" @@ fun path ->
  Validate.host_memory ~meminfo_path:path ~mem_mb:48000 ();
  let raised = ref false in
  (try Validate.host_memory ~meminfo_path:path ~mem_mb:64000 ()
   with Failure _ -> raised := true);
  assert_b "hard check still applies without MemAvailable" !raised

(* --- Validate.share_sources: file-vs-directory share guard --- *)

let test_validate_share_sources_all_dirs_ok () =
  (* A project tree with a readOnly subdir, an absolute inputs dir,
     and a shares dir: all directories → no raise. *)
  with_temp_base @@ fun base ->
  Unix.mkdir (base ^ "/sub") 0o755;
  let inputs_dir = base ^ "/inputs_dir" in
  Unix.mkdir inputs_dir 0o755;
  Unix.mkdir (base ^ "/scratch") 0o755;
  Validate.share_sources ~project:base ~read_only:[ "sub" ]
    ~inputs:[ inputs_dir ]
    ~shares:[ { Policy.source = "scratch"; mount_point = "/x"; read_only = false } ]

let test_validate_share_sources_readonly_file_raises () =
  (* The original repro: a readOnly subpath that is an 856-byte file. *)
  with_temp_base @@ fun base ->
  let oc = open_out (base ^ "/some_file") in
  output_string oc "not a directory";
  close_out oc;
  let raised = ref false in
  (try
     Validate.share_sources ~project:base ~read_only:[ "some_file" ]
       ~inputs:[] ~shares:[]
   with Failure msg ->
     raised := true;
     assert_b "names the offending entry" (contains "some_file" msg);
     assert_b "explains the directory requirement"
       (contains "not a directory" msg);
     assert_b "warns about the emergency-mode hang"
       (contains "emergency mode" msg));
  assert_b "Failure was raised for a file readOnly source" !raised

let test_validate_share_sources_inputs_file_raises () =
  with_temp_base @@ fun base ->
  let f = base ^ "/data_file" in
  let oc = open_out f in
  output_string oc "x";
  close_out oc;
  let raised = ref false in
  (try
     Validate.share_sources ~project:base ~read_only:[] ~inputs:[ f ]
       ~shares:[]
   with Failure msg ->
     raised := true;
     assert_b "names the inputs entry" (contains "data_file" msg));
  assert_b "Failure was raised for a file inputs source" !raised

let test_validate_share_sources_missing_is_skipped () =
  (* Non-existence is the post-build check's job; share_sources must
     stay silent so it never pre-empts that path's message. *)
  with_temp_base @@ fun base ->
  Validate.share_sources ~project:base ~read_only:[ "nonexistent_sub" ]
    ~inputs:[ base ^ "/nonexistent_input" ] ~shares:[]

(* --- policy.env: parse + roundtrip + name validation --- *)

let test_policy_env_default_empty () =
  (* Older fixtures (sample-project.json, vm-testing.json) predate the
     env field. Parser must default to empty, not raise. *)
  let _, p = parse_fixture "sample-project.json" in
  assert_b "env empty by default" (p.env = [])

let test_policy_env_parse () =
  let json = `Assoc [
    "project", `String "/x";
    "work", `Assoc [
      "default", `String "rw"; "readOnly", `List []; "hidden", `List []];
    "inputs", `List []; "shares", `List [];
    "egress", `Assoc [
      "hosts", `List [`String "api.anthropic.com"]; "none", `Bool false];
    "auth", `String "ephemeral";
    "agent", `Assoc [
      "preset", `String "claude"; "command", `String "claude";
      "flags", `List []; "instructionsFile", `String "CLAUDE.md";
      "instructions", `String ""; "configDir", `String ".claude";
      "configGuest", `String "/var/lib/claude"; "taskDir", `String "tasks";
      "stateDirs", `List []; "stateFiles", `List [];
      "homeStateFiles", `List []];
    "tools", `List [];
    "resources", `Assoc ["vcpu", `Int 2; "memMb", `Int 1024];
    "secrets", `List [];
    "env", `Assoc [
      "GH_USER", `String "agent-bot";
      "EDITOR", `String "vim";
      "JULIA_NUM_THREADS", `String "8";
    ];
    "proxyAuth", `List [];
    "stateDir", `String "";
    "git", `Assoc [
      "name", `String ""; "email", `String "";
      "allowedGithubOrgs", `List []];
    "julia", `Assoc ["env", `String "env/julia"];
    "r", `Assoc ["packages", `List []];
    "loginMessage", `String "";
    "startup", `Assoc ["commands", `List []; "logFile", `String ""];
    "guest", `Assoc ["hostname", `String ""; "username", `String ""];
  ] in
  match Policy.of_json json with
  | Error msg -> failwith ("expected Ok, got Error: " ^ msg)
  | Ok p ->
    assert_b "GH_USER present"
      (List.assoc_opt "GH_USER" p.env = Some "agent-bot");
    assert_b "EDITOR present"
      (List.assoc_opt "EDITOR" p.env = Some "vim");
    assert_b "JULIA_NUM_THREADS present"
      (List.assoc_opt "JULIA_NUM_THREADS" p.env = Some "8")

let test_policy_env_roundtrip () =
  let _, p = parse_fixture "sample-project.json" in
  let p =
    { p with env = [
        "GH_USER", "agent-bot";
        "RUST_LOG", "debug";
      ] }
  in
  let json = Policy.to_json p in
  match Policy.of_json json with
  | Error msg -> failwith ("roundtrip parse failed: " ^ msg)
  | Ok p' ->
    assert_b "GH_USER survived"
      (List.assoc_opt "GH_USER" p'.env = Some "agent-bot");
    assert_b "RUST_LOG survived"
      (List.assoc_opt "RUST_LOG" p'.env = Some "debug")

let env_parse_rejects_name bad_name =
  let json = `Assoc [
    "project", `String "/x";
    "work", `Assoc [
      "default", `String "rw"; "readOnly", `List []; "hidden", `List []];
    "inputs", `List []; "shares", `List [];
    "egress", `Assoc [
      "hosts", `List []; "none", `Bool false];
    "auth", `String "ephemeral";
    "agent", `Assoc [
      "preset", `String "claude"; "command", `String "claude";
      "flags", `List []; "instructionsFile", `String "CLAUDE.md";
      "instructions", `String ""; "configDir", `String ".claude";
      "configGuest", `String "/var/lib/claude"; "taskDir", `String "tasks";
      "stateDirs", `List []; "stateFiles", `List [];
      "homeStateFiles", `List []];
    "tools", `List [];
    "resources", `Assoc ["vcpu", `Int 1; "memMb", `Int 512];
    "secrets", `List [];
    "env", `Assoc [bad_name, `String "x"];
    "proxyAuth", `List [];
    "stateDir", `String "";
    "git", `Assoc [
      "name", `String ""; "email", `String "";
      "allowedGithubOrgs", `List []];
    "julia", `Assoc ["env", `String "env/julia"];
    "r", `Assoc ["packages", `List []];
    "loginMessage", `String "";
    "startup", `Assoc ["commands", `List []; "logFile", `String ""];
    "guest", `Assoc ["hostname", `String ""; "username", `String ""];
  ] in
  match Policy.of_json json with
  | Ok _ -> failwith ("expected Error for bad name " ^ bad_name)
  | Error msg ->
    assert_b ("error names the bad input (" ^ bad_name ^ ")")
      (local_contains bad_name msg
       || local_contains "env-var name" msg
       || local_contains "env:" msg)

let test_policy_env_rejects_lowercase () =
  env_parse_rejects_name "lowercase"

let test_policy_env_rejects_leading_digit () =
  env_parse_rejects_name "1FOO"

let test_policy_env_rejects_dash () =
  env_parse_rejects_name "GH-USER"

let test_policy_env_rejects_empty_name () =
  env_parse_rejects_name ""

(* --- Stage.env_vars + shell escaping --- *)

let test_stage_shell_escape_plain () =
  assert_b "wraps in single quotes"
    (Stage.shell_escape_single_quoted "vim" = "'vim'")

let test_stage_shell_escape_with_dollars () =
  (* Single-quoted strings DO NOT interpolate, so $HOME stays
     literal. The whole point of the escape strategy. *)
  assert_b "passes $ through"
    (Stage.shell_escape_single_quoted "$HOME/x"
     = "'$HOME/x'")

let test_stage_shell_escape_with_double_quote () =
  assert_b "double-quote passes through"
    (Stage.shell_escape_single_quoted "a\"b"
     = "'a\"b'")

let test_stage_shell_escape_with_backslash () =
  assert_b "backslash passes through"
    (Stage.shell_escape_single_quoted "a\\b"
     = "'a\\b'")

let test_stage_shell_escape_with_single_quote () =
  (* The classic close-quote / escaped-quote / reopen-quote trick. *)
  assert_b "single-quote: close, escape, reopen"
    (Stage.shell_escape_single_quoted "it's me"
     = "'it'\\''s me'")

let test_stage_env_vars_writes_file () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  Stage.env_vars ~etc_dir:etc [
    "GH_USER", "agent-bot";
    "RUST_LOG", "debug";
  ];
  let path = etc ^ "/env-vars" in
  assert_b "file exists" (Sys.file_exists path);
  let content = read_file path in
  assert_b "exports GH_USER"
    (local_contains "export GH_USER='agent-bot'" content);
  assert_b "exports RUST_LOG"
    (local_contains "export RUST_LOG='debug'" content);
  (* One line per export, newline-terminated. *)
  let line_count = String.fold_left
    (fun n c -> if c = '\n' then n + 1 else n) 0 content in
  assert_b "two lines" (line_count = 2)

let test_stage_env_vars_writes_empty_file_when_no_entries () =
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  Stage.env_vars ~etc_dir:etc [];
  let path = etc ^ "/env-vars" in
  assert_b "file exists (even when empty)" (Sys.file_exists path);
  let content = read_file path in
  assert_b "no lines" (content = "")

let test_stage_env_vars_round_trips_dirty_values () =
  (* Confirms the escape strategy actually round-trips: stage the
     value, source the file via /bin/sh, observe the env var. *)
  with_temp_base @@ fun base ->
  let etc = base ^ "/etc" in
  Unix.mkdir etc 0o755;
  let dirty_value =
    "weird $HOME `whoami` \\n \"quote\" 'apos' end"
  in
  Stage.env_vars ~etc_dir:etc [ "DIRTY", dirty_value ];
  let cmd =
    Printf.sprintf
      ". %s/env-vars && printf %%s \"$DIRTY\""
      etc
  in
  let ic = Unix.open_process_in ("/bin/sh -c " ^ Filename.quote cmd) in
  let observed = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  assert_b "value round-tripped through shell source unchanged"
    (observed = dirty_value)

(* --- Session.acquire_slot (per-session networking) --- *)

let with_lock_temp_dir f =
  let d = Filename.temp_file "vm-launcher-lock-test-" "" in
  Sys.remove d;
  Unix.mkdir d 0o755;
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Sys.command (Printf.sprintf "rm -rf -- %s" (Filename.quote d))))
    (fun () -> f d)

(* POSIX locks never conflict within one process, so each contender
   runs in a fork (a second [acquire_slot] in the SAME process would
   happily re-take a slot this process already holds). The queue path
   blocks, so a child that should find the pool exhausted is armed
   with [alarm]: SIGALRM killing the child is the observable proof it
   was waiting rather than proceeding. [hold] keeps the slot for that
   long after a successful acquire. Child stderr is squelched (slot /
   queue banners). Exit codes: the taken slot (0-9), 60+slot when
   double-checking via [expect], 70 = acquire raised. *)
let acquire_slot_in_child ?(hold = 0.) ?alarm ~slots ~state_base () =
  flush stdout; flush stderr;
  match Unix.fork () with
  | 0 ->
    let null = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
    Unix.dup2 null Unix.stderr;
    (match alarm with Some s -> ignore (Unix.alarm s) | None -> ());
    let rc =
      Session.with_state ~state_base ~keep_state:false ~f:(fun t ->
        try
          let i = Session.acquire_slot ~slots t in
          if hold > 0. then Unix.sleepf hold;
          i
        with _ -> 70)
    in
    Unix._exit rc
  | pid -> pid

let wait_child pid =
  match Unix.waitpid [] pid with _, st -> st

let slot_holder ~state_base i =
  try
    let ic =
      open_in (Printf.sprintf "%s/slot-%d.lock" state_base i)
    in
    let l = (try input_line ic with End_of_file -> "") in
    close_in ic;
    int_of_string_opt (String.trim l)
  with _ -> None

(* Helper: parent-held session on a temp state_base. *)
let with_parent_session ~state_base f =
  Session.with_state ~state_base ~keep_state:false ~f

let test_slot_first_free_ordering () =
  with_lock_temp_dir @@ fun base ->
  with_parent_session ~state_base:base @@ fun t ->
  (* Parent takes the first slot; a second process must get the next. *)
  assert_b "parent gets slot 0"
    (Session.acquire_slot ~slots:[ 0; 1 ] t = 0);
  let child =
    acquire_slot_in_child ~slots:[ 0; 1 ] ~state_base:base ()
  in
  (match wait_child child with
   | Unix.WEXITED 1 -> ()
   | Unix.WEXITED n ->
     failwith (Printf.sprintf "child got slot/rc %d (want 1)" n)
   | _ -> failwith "unexpected child status");
  assert_b "slot 0 lock names the parent"
    (slot_holder ~state_base:base 0 = Some (Unix.getpid ()))

let test_slot_exhaustion_queues () =
  with_lock_temp_dir @@ fun base ->
  with_parent_session ~state_base:base @@ fun t ->
  ignore (Session.acquire_slot ~slots:[ 0 ] t);
  let child =
    acquire_slot_in_child ~alarm:2 ~slots:[ 0 ] ~state_base:base ()
  in
  (match wait_child child with
   | Unix.WSIGNALED s when s = Sys.sigalrm ->
     () (* still polling at the 2s alarm = queued, as designed *)
   | Unix.WEXITED n ->
     failwith
       (Printf.sprintf
          "child got slot/rc %d on an exhausted pool (want SIGALRM)" n)
   | _ -> failwith "unexpected child status")

let test_slot_freed_on_holder_exit () =
  with_lock_temp_dir @@ fun base ->
  with_parent_session ~state_base:base @@ fun t ->
  (* Child holds the only slot for ~1s, then exits: the kernel must
     free it and the parent's queued acquire must then succeed. *)
  let child =
    acquire_slot_in_child ~hold:1.0 ~slots:[ 0 ] ~state_base:base ()
  in
  let deadline = Unix.gettimeofday () +. 5.0 in
  let rec poll () =
    if slot_holder ~state_base:base 0 = Some child then ()
    else if Unix.gettimeofday () > deadline then
      failwith "child never took the slot"
    else (Unix.sleepf 0.05; poll ())
  in
  poll ();
  let t0 = Unix.gettimeofday () in
  let i = Session.acquire_slot ~slots:[ 0 ] t in
  let dt = Unix.gettimeofday () -. t0 in
  ignore (wait_child child);
  assert_b "queued acquire got the freed slot" (i = 0);
  assert_b "and it actually waited for the holder" (dt > 0.3)

let test_slot_empty_pool_fails () =
  with_lock_temp_dir @@ fun base ->
  with_parent_session ~state_base:base @@ fun t ->
  match Session.acquire_slot ~slots:[] t with
  | exception Failure msg ->
    assert_b "empty-pool error points at the host module"
      (local_contains "vm-tap" msg)
  | _ -> failwith "empty pool should be a hard Failure"

let test_set_as_current_is_slotted () =
  with_lock_temp_dir @@ fun base ->
  with_parent_session ~state_base:base @@ fun t ->
  (* Before allocation: refuse (no identity to commit to). *)
  (match Session.set_as_current t with
   | exception Invalid_argument _ -> ()
   | () -> failwith "set_as_current must require a slot");
  ignore (Session.acquire_slot ~slots:[ 3 ] t);
  Session.set_as_current t;
  assert_b "current-session-3 points at this session"
    (Unix.readlink (base ^ "/current-session-3")
     = Session.state_dir t);
  assert_b "unslotted current-session is never created"
    (not (Sys.file_exists (base ^ "/current-session")))

let test_clean_rejects_path_ids () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  let state_base = base ^ "/run" in
  mkdirp (xdg ^ "/microvm/sessions");
  mkdirp state_base;
  let unrelated = xdg ^ "/unrelated" in
  mkdirp unrelated;
  Util.write_file (unrelated ^ "/keep") "keep";
  List.iter (fun id ->
    let rc, _ = capture_stdout (fun () ->
      Clean.run ~xdg_state_home:xdg ~state_base ~ids:[id] ~exited:false)
    in
    assert_b "invalid ID fails" (rc = 1);
    assert_b "unrelated data survives"
      (Sys.file_exists (unrelated ^ "/keep")))
    [ "../../unrelated"; ""; "."; ".."; "/tmp"; "a/../b"; "bad\000id" ]

let test_slot_marker_checked_under_lock () =
  with_lock_temp_dir @@ fun base ->
  with_parent_session ~state_base:base @@ fun t ->
  ignore (Session.acquire_slot ~slots:[0; 1] t);
  (* A stale marker must not be read/pruned while another launcher holds
     the slot lock: it may be replacing that marker with a live runner. *)
  let dead = match Unix.fork () with
    | 0 -> Unix._exit 0
    | pid -> ignore (wait_child pid); pid
  in
  Session.mark_slot_detached ~state_base:base ~slot:0 ~pid:dead;
  let marker = base ^ "/slot-0.detached" in
  let child = acquire_slot_in_child ~slots:[0; 1] ~state_base:base () in
  assert_b "contender skips locked slot" (wait_child child = Unix.WEXITED 1);
  assert_b "marker untouched outside lock" (Sys.file_exists marker)

let test_slot_detached_marker_blocks_then_releases () =
  with_lock_temp_dir @@ fun base ->
  Session.mark_slot_detached ~state_base:base ~slot:0 ~pid:(Unix.getpid ());
  let child = acquire_slot_in_child ~slots:[0; 1] ~state_base:base () in
  assert_b "live detached runner reserves slot" (wait_child child = Unix.WEXITED 1);
  let dead = match Unix.fork () with
    | 0 -> Unix._exit 0
    | pid -> ignore (wait_child pid); pid
  in
  Session.mark_slot_detached ~state_base:base ~slot:0 ~pid:dead;
  let child = acquire_slot_in_child ~slots:[0; 1] ~state_base:base () in
  assert_b "dead detached runner releases slot" (wait_child child = Unix.WEXITED 0);
  assert_b "stale marker removed" (not (Sys.file_exists (base ^ "/slot-0.detached")))

let cases =
  [
    "clean-rejects-path-ids", test_clean_rejects_path_ids;
    "slot-marker-checked-under-lock", test_slot_marker_checked_under_lock;
    "slot-detached-marker-blocks-then-releases", test_slot_detached_marker_blocks_then_releases;
    "validate-nix-string-escape-basic",
      test_validate_nix_string_escape_basic;
    "validate-build-tools-expr-shape",
      test_validate_build_tools_expr_shape;
    "validate-build-tools-expr-honors-nixos-config-env",
      test_validate_build_tools_expr_honors_nixos_config_env;
    "validate-build-tools-expr-escapes-hostile-name",
      test_validate_build_tools_expr_escapes_hostile_name;
    "validate-tools-fake-nix-all-good",
      test_validate_tools_fake_nix_all_good;
    "validate-tools-fake-nix-bad-single",
      test_validate_tools_fake_nix_bad_single;
    "validate-tools-fake-nix-bad-multiple",
      test_validate_tools_fake_nix_bad_multiple;
    "validate-tools-fake-nix-null-input",
      test_validate_tools_fake_nix_null_input;
    "validate-tools-fake-nix-non-zero-exit",
      test_validate_tools_fake_nix_non_zero_exit;
    "validate-tools-fake-nix-garbage-output",
      test_validate_tools_fake_nix_garbage_output;
    "validate-tools-empty-list-skips-subprocess",
      test_validate_tools_empty_list_skips_subprocess;
    "validate-meminfo-field", test_validate_meminfo_field;
    "validate-host-memory-within-total",
      test_validate_host_memory_within_total;
    "validate-host-memory-above-available-warns-only",
      test_validate_host_memory_above_available_warns_only;
    "validate-host-memory-above-total-raises",
      test_validate_host_memory_above_total_raises;
    "validate-host-memory-unreadable-meminfo-skips",
      test_validate_host_memory_unreadable_meminfo_skips;
    "validate-host-memory-no-memavailable",
      test_validate_host_memory_no_memavailable;
    "validate-share-sources-all-dirs-ok",
      test_validate_share_sources_all_dirs_ok;
    "validate-share-sources-readonly-file-raises",
      test_validate_share_sources_readonly_file_raises;
    "validate-share-sources-inputs-file-raises",
      test_validate_share_sources_inputs_file_raises;
    "validate-share-sources-missing-is-skipped",
      test_validate_share_sources_missing_is_skipped;
    "policy-env-default-empty", test_policy_env_default_empty;
    "policy-env-parse", test_policy_env_parse;
    "policy-env-roundtrip", test_policy_env_roundtrip;
    "policy-env-rejects-lowercase", test_policy_env_rejects_lowercase;
    "policy-env-rejects-leading-digit",
      test_policy_env_rejects_leading_digit;
    "policy-env-rejects-dash", test_policy_env_rejects_dash;
    "policy-env-rejects-empty-name", test_policy_env_rejects_empty_name;
    "stage-shell-escape-plain", test_stage_shell_escape_plain;
    "stage-shell-escape-with-dollars",
      test_stage_shell_escape_with_dollars;
    "stage-shell-escape-with-double-quote",
      test_stage_shell_escape_with_double_quote;
    "stage-shell-escape-with-backslash",
      test_stage_shell_escape_with_backslash;
    "stage-shell-escape-with-single-quote",
      test_stage_shell_escape_with_single_quote;
    "stage-env-vars-writes-file", test_stage_env_vars_writes_file;
    "stage-env-vars-writes-empty-file-when-no-entries",
      test_stage_env_vars_writes_empty_file_when_no_entries;
    "stage-env-vars-round-trips-dirty-values",
      test_stage_env_vars_round_trips_dirty_values;
    "policy-startup-default", test_policy_startup_default;
    "policy-startup-parse", test_policy_startup_parse;
    "policy-startup-roundtrip", test_policy_startup_roundtrip;
    "policy-console", test_policy_console;
    "sample-project", test_sample_project;
    "vm-testing", test_vm_testing;
    "roundtrip-sample-project", test_roundtrip "sample-project.json";
    "roundtrip-vm-testing", test_roundtrip "vm-testing.json";
    "missing-field", test_missing_field;
    "bad-auth", test_bad_auth;
    "session-creates-dir", test_session_creates_dir;
    "session-cleanup", test_session_cleanup;
    "session-cleanup-on-exception", test_session_cleanup_on_exception;
    "session-keep-state", test_session_keep_state;
    "session-set-as-current", test_set_as_current;
    "session-current-not-ours", test_current_session_not_ours;
    "session-register-child", test_register_child;
    "session-register-child-sigterm-grace", test_register_child_sigterm_grace;
    "session-register-child-grace-fallback", test_register_child_grace_timeout_falls_back_to_kill;
    "session-with-signals-blocked", test_with_signals_blocked;
    "resolver-tilde-expand", test_tilde_expand;
    "resolver-default-policy", test_default_policy;
    "resolver-resolve-source", test_resolve_source;
    "resolver-discover-policy", test_discover_policy;
    "resolver-resolve-state-dir", test_resolve_state_dir;
    "resolver-marker-email", test_marker_email;
    "resolver-resolve-git-identity", test_resolve_git_identity;
    "resolver-sanitize-hostname", test_sanitize_hostname;
    "resolver-sanitize-username", test_sanitize_username;
    "resolver-resolve-guest", test_resolve_guest;
    "resolver-load-default", test_load_default;
    "render-egress-hosts", test_render_egress_hosts;
    "render-instructions", test_render_instructions;
    "render-instructions-gated-on-policy",
      test_render_instructions_gated_on_policy;
    "render-instructions-with-instructions", test_render_instructions_with_instructions;
    "egress-mode-derived-from-none", test_egress_mode_derived_from_none;
    "egress-mode-roundtrip", test_egress_mode_roundtrip;
    "stage-writes-files", test_stage_writes_files;
    "stage-microvm-loaded-ncl", test_stage_microvm_loaded_ncl_source;
    "stage-secrets-copy-perms", test_stage_secrets_copy_and_perms;
    "stage-secrets-mixed-scopes", test_stage_secrets_mixed_scopes;
    "stage-secrets-missing", test_stage_secrets_missing_source;
    "stage-proxy-ca", test_stage_proxy_ca;
    "session-id-generate-shape", test_session_id_generate_shape;
    "stage-session-id", test_stage_session_id;
    "session-manifest-write", test_session_manifest_write;
    "session-manifest-no-project-dir", test_session_manifest_no_project_dir;
    "stage-proxy-auth-config-writes-file", test_stage_proxy_auth_config_writes_file;
    "parse-proxy-auth-config-line", test_parse_proxy_auth_config_line;
    "proxy-auth-config-file-then-inline",
      test_proxy_auth_config_file_then_inline_concat;
    "proxy-auth-config-file-wins-on-overlap",
      test_proxy_auth_config_file_wins_on_overlap;
    "stage-proxy-auth-config-empty", test_stage_proxy_auth_config_empty;
    "parse-proxy-auth-config-crlf", test_parse_proxy_auth_config_crlf;
    "shares-wkro-tag", test_shares_wkro_tag;
    "shares-in-tag", test_shares_in_tag;
    "shares-ro-tags-default", test_shares_ro_tags_default;
    "shares-ro-tags-full", test_shares_ro_tags_full;
    "shares-read-manifest", test_shares_read_manifest;
    "shares-read-manifest-missing", test_shares_read_manifest_missing_dir;
    "boot-prepare-paths-bind-with-state", test_boot_prepare_paths_bind_with_state;
    "ssh-guest-ip-follows-slot", test_ssh_guest_ip_follows_slot;
    "ssh-attach-roundtrip", test_ssh_attach_roundtrip;
    "ssh-read-absent-is-none", test_ssh_read_absent_is_none;
    "egress-vocabularies-are-equivalent", test_egress_vocabularies_are_equivalent;
    "read-proc-opt-reads-zero-sized-files", test_read_proc_opt_reads_zero_sized_files;
    "pid-is-runner-rejects-non-runner", test_pid_is_runner_rejects_non_runner;
    "attached-clients-ignores-non-ssh", test_attached_clients_ignores_non_ssh_processes;
    "runner-alive-rejects-recycled-pid", test_runner_alive_rejects_recycled_pid;
    "runner-alive-false-when-runner-dead", test_runner_alive_false_when_runner_dead;
    "multiplex-default-matches-contract", test_multiplex_default_matches_contract;
    "session-defaults-headless-capable", test_session_defaults_are_headless_capable;
    "session-absent-block-is-not-ssh", test_session_absent_block_is_not_ssh;
    "policy-agents-default-first", test_policy_agents_default_first;
    "policy-agent-roundtrip-multi", test_policy_agent_roundtrip_multi;
    "policy-rejects-duplicate-agent-names", test_policy_rejects_duplicate_agent_names;
    "policy-rejects-bad-agent-name", test_policy_rejects_bad_agent_name;
    "boot-prepare-paths-multi-agent", test_boot_prepare_paths_multi_agent;
    "stage-instructions-per-agent", test_stage_instructions_per_agent;
    "render-instructions-names-other-agents",
      test_render_instructions_names_the_other_agents;
    "shares-auth-tag-per-agent", test_shares_auth_tag_per_agent;
    "boot-prepare-paths-seeds-claude-json", test_boot_prepare_paths_seeds_claude_json;
    "boot-prepare-paths-preserves-claude-json",
      test_boot_prepare_paths_preserves_existing_claude_json;
    "boot-prepare-paths-ephemeral", test_boot_prepare_paths_ephemeral_skips_claude_dir;
    "boot-prepare-paths-no-state-dir", test_boot_prepare_paths_no_state_dir;
    "boot-prepare-paths-empty-home-fails", test_boot_prepare_paths_empty_home_fails;
    "boot-wait-for-sockets-success", test_boot_wait_for_sockets_success;
    "proxy-parse-egress-hosts", test_proxy_parse_egress_hosts;
    "proxy-host-allowed", test_proxy_host_allowed;
    "proxy-parse-upstream-rule", test_proxy_parse_upstream_rule;
    "proxy-parse-connect-line", test_proxy_parse_connect_line;
    "proxy-pick-upstream", test_proxy_pick_upstream;
    "proxy-render-template", test_proxy_render_template;
    "proxy-render-template-rejects-crlf",
      test_proxy_render_template_rejects_crlf;
    "proxy-parse-proxy-auth-flag", test_proxy_parse_proxy_auth_flag;
    "proxy-pick-proxy-auth", test_proxy_pick_proxy_auth;
    "proxy-is-env-name", test_proxy_is_env_name;
    "proxy-inject-header", test_proxy_inject_header;
    "proxy-render-template-more", test_proxy_render_template_more;
    "proxy-ca-roundtrip-pem", test_proxy_ca_roundtrip_pem;
    "proxy-ca-leaf-signed-by-ca", test_proxy_ca_leaf_signed_by_ca;
    "proxy-ca-leaf-hostname-in-san", test_proxy_ca_leaf_hostname_in_san;
    "proxy-ca-leaf-validates-against-ca", test_proxy_ca_leaf_validates_against_ca;
    "proxy-ca-load-roundtrip", test_proxy_ca_load_ca_roundtrip;
    "boot-wait-for-sockets-timeout", test_boot_wait_for_sockets_timeout;
    (* Gap-audit additions *)
    "proxy-load-secret-dir-basic", test_proxy_load_secret_dir_basic;
    "proxy-load-secret-dir-rejects-wide-modes",
      test_proxy_load_secret_dir_rejects_wide_modes;
    "proxy-load-secret-dir-skips-non-env-names",
      test_proxy_load_secret_dir_skips_non_env_names;
    "proxy-load-secret-dir-skips-non-regular",
      test_proxy_load_secret_dir_skips_non_regular;
    "proxy-ca-leaf-validity-window", test_proxy_ca_leaf_validity_window;
    "proxy-ca-generate-leaf-bad-hostname-unmatchable",
      test_proxy_ca_generate_leaf_bad_hostname_is_unmatchable;
    "proxy-ca-load-ca-mismatched-pair",
      test_proxy_ca_load_ca_mismatched_pair;
    "stage-proxy-auth-config-tab-in-header",
      test_stage_proxy_auth_config_tab_in_header_fails_roundtrip;
    "session-manifest-sha256-file", test_session_manifest_sha256_file;
    "session-manifest-sha256-file-missing",
      test_session_manifest_sha256_file_missing;
    "session-manifest-git-rev-non-git",
      test_session_manifest_git_rev_non_git;
    "session-manifest-git-rev-in-git-repo",
      test_session_manifest_git_rev_in_git_repo;
    "session-manifest-iso8601-local-shape",
      test_session_manifest_iso8601_local_shape;
    "policy-proxy-auth-missing-field",
      test_policy_proxy_auth_missing_field;
    "policy-secret-bad-scope", test_policy_secret_bad_scope;
    "proxy-parse-upstream-rule-ipv6-bracketed",
      test_proxy_parse_upstream_rule_ipv6_bracketed;
    "resolve-state-dir-blank-policy-uses-xdg",
      test_resolve_state_dir_blank_policy_uses_xdg;
    "ls-no-sessions", test_ls_no_sessions;
    "ls-lists-global-manifests", test_ls_lists_global_manifests;
    "ls-marks-live-session-as-running",
      test_ls_marks_live_session_as_running;
    "ls-marks-prebuild-session-as-building",
      test_ls_marks_prebuild_session_as_building;
    "ls-orphan-live-session", test_ls_orphan_live_session;
    "ls-caps-at-ten-without-all", test_ls_caps_at_ten_without_all;
    "ls-orders-by-state-group", test_ls_orders_by_state_group;
    "sshd-up-probe", test_sshd_up_probe;
    "ls-size-column-from-runner-block",
      test_ls_size_column_from_runner_block;
    "clean-exited-removes-registry-and-symlink",
      test_clean_exited_removes_registry_and_symlink;
    "clean-refuses-running-session", test_clean_refuses_running_session;
    "clean-stale-removes-state-dir", test_clean_stale_removes_state_dir;
    "clean-exited-bulk-spares-running",
      test_clean_exited_bulk_spares_running;
    "policy-shares-default", test_policy_shares_default;
    "policy-shares-parse", test_policy_shares_parse;
    "policy-shares-roundtrip", test_policy_shares_roundtrip;
    "default-policy-shares-empty", test_default_policy_shares_empty;
    "stage-resolve-shares-missing-source",
      test_stage_resolve_shares_missing_source;
    "stage-resolve-shares-tilde-expand",
      test_stage_resolve_shares_tilde_expand;
    "shares-ro-tags-with-shares", test_shares_ro_tags_with_shares;
    "slot-first-free-ordering", test_slot_first_free_ordering;
    "slot-exhaustion-queues", test_slot_exhaustion_queues;
    "slot-freed-on-holder-exit", test_slot_freed_on_holder_exit;
    "slot-empty-pool-fails", test_slot_empty_pool_fails;
    "set-as-current-is-slotted", test_set_as_current_is_slotted;
  ]

let () =
  let failed = ref 0 in
  List.iter
    (fun (name, f) ->
      (try
        f ();
        Printf.printf "ok    %s\n" name
      with
      | Failure msg ->
          incr failed;
          Printf.printf "FAIL  %s: %s\n" name msg
      | e ->
          incr failed;
          Printf.printf "FAIL  %s: %s\n" name (Printexc.to_string e));
      flush stdout)
    cases;
  if !failed > 0 then (
    Printf.printf "\n%d test(s) failed\n" !failed;
    exit 1)
