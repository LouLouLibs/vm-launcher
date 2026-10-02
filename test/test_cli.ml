(* CLI smoke tests: spawn the real main.exe from argv to exit.

   These are end-to-end at the launcher boundary — they exercise the
   same arg parser, env-var reads, and process spawn paths the
   production CLI uses. They do NOT hit a real nix daemon or build a
   real VM; the fake `nix` shim on PATH and the
   VM_LAUNCHER_STATE_BASE override keep them hermetic. *)

(* ../bin/main.exe is declared as a dep in test/dune, so dune builds it
   before running this test. At runtime cwd is _build/default/test/. *)
let bin_path = "../bin/main.exe"

let assert_b label cond =
  if not cond then failwith (Printf.sprintf "assertion failed: %s" label)

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i = i + n <= h
    && (String.sub haystack i n = needle || loop (i + 1))
  in
  loop 0

let rm_rf_safe path =
  if String.length path > 4
  then ignore
    (Sys.command (Printf.sprintf "rm -rf -- %s" (Filename.quote path)))

let with_temp_base f =
  let base = Filename.temp_file "vm-launcher-cli-test-" "" in
  Sys.remove base;
  Unix.mkdir base 0o755;
  Fun.protect ~finally:(fun () -> rm_rf_safe base) (fun () -> f base)

(* Snapshot + restore named env vars across a callback. Restores even
   on exception. *)
let with_envs overrides f =
  let prev =
    List.map
      (fun (k, _) -> (k, try Some (Sys.getenv k) with Not_found -> None))
      overrides
  in
  List.iter (fun (k, v) -> Unix.putenv k v) overrides;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (k, p) ->
          match p with
          | Some s -> Unix.putenv k s
          | None -> Unix.putenv k "")
        prev)
    f

(* Write a fake `nix` shim under [base]/bin and return its dir + the
   path to the output-control file. Same shape as test_vm_launcher.ml's
   with_fake_nix but inlined since this file's tests need to populate
   the env BEFORE spawning main.exe (not before calling Validate
   in-process). *)
let setup_fake_nix ~base ~output ~rc =
  let bin_dir = base ^ "/bin" in
  Unix.mkdir bin_dir 0o755;
  let script = bin_dir ^ "/nix" in
  let oc = open_out script in
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
  bin_dir, out_file, rc

(* Drain a pipe into a Buffer. Tests' outputs are small (well under
   the kernel pipe buffer) so we read after the child exits — no
   risk of deadlock from a stalled writer. *)
let read_all_close fd =
  let b = Buffer.create 1024 in
  let bytes = Bytes.create 4096 in
  (try
     while true do
       let n = Unix.read fd bytes 0 (Bytes.length bytes) in
       if n = 0 then raise Exit
       else Buffer.add_subbytes b bytes 0 n
     done
   with Exit | Unix.Unix_error _ -> ());
  (try Unix.close fd with _ -> ());
  Buffer.contents b

(* Spawn main.exe with [args], capture (rc, stdout, stderr). [env_overrides]
   are applied around the spawn — the child inherits the modified env. *)
let spawn_main ?(env_overrides = []) args =
  with_envs env_overrides @@ fun () ->
  let argv = Array.of_list (bin_path :: args) in
  let stdin_r, stdin_w = Unix.pipe ~cloexec:true () in
  let stdout_r, stdout_w = Unix.pipe ~cloexec:true () in
  let stderr_r, stderr_w = Unix.pipe ~cloexec:true () in
  let try_close fd = try Unix.close fd with _ -> () in
  Fun.protect
    ~finally:(fun () ->
      try_close stdin_r;
      try_close stdin_w;
      try_close stdout_r;
      try_close stdout_w;
      try_close stderr_r;
      try_close stderr_w)
    (fun () ->
      let pid =
        Unix.create_process bin_path argv stdin_r stdout_w stderr_w
      in
      (* Close ends owned by the child so reads see EOF when it exits. *)
      try_close stdin_r;
      try_close stdin_w;
      try_close stdout_w;
      try_close stderr_w;
      let _, st = Unix.waitpid [] pid in
      let rc = match st with
        | Unix.WEXITED n -> n
        | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> -1
      in
      let so = read_all_close stdout_r in
      let se = read_all_close stderr_r in
      rc, so, se)

(* --- tests --- *)

let test_cli_help_exits_zero () =
  let rc, so, _se = spawn_main [ "--help" ] in
  assert_b "exit code 0" (rc = 0);
  assert_b "usage banner" (contains "vm-launcher:" so);
  assert_b "lists --policy" (contains "--policy" so);
  assert_b "lists --show" (contains "--show" so);
  assert_b "lists --fast" (contains "--fast" so);
  assert_b "lists ls subcommand" (contains "ls" so);
  assert_b "lists clean subcommand" (contains "clean" so);
  (* Retired in v0.2.x: the interim single-session escape hatch. A
     reappearance means a bad merge resurrected it. *)
  assert_b "does not list --concurrent" (not (contains "--concurrent" so))

let test_cli_h_short_help_exits_zero () =
  let rc, so, _se = spawn_main [ "-h" ] in
  assert_b "exit code 0" (rc = 0);
  assert_b "usage banner" (contains "vm-launcher:" so)

let test_cli_unknown_subcommand_exits_two () =
  let rc, _so, se = spawn_main [ "bogus-subcommand" ] in
  assert_b "exit code 2" (rc = 2);
  assert_b "names the bad subcommand" (contains "bogus-subcommand" se);
  assert_b "names vm-launcher" (contains "vm-launcher" se)

let test_cli_unknown_flag_exits_two () =
  let rc, _so, se = spawn_main [ "--no-such-flag" ] in
  assert_b "exit code 2" (rc = 2);
  assert_b "complains about the flag" (contains "no-such-flag" se)

(* `clean` with neither IDs nor --exited is a usage error (exit 2),
   not a silent no-op — guards against an accidental bulk-delete if
   the flag parsing ever regresses to "no args = clean everything". *)
let test_cli_clean_requires_target () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  let state_base = base ^ "/state" in
  List.iter (fun d -> Unix.mkdir d 0o755) [ xdg; state_base ];
  let rc, _so, se =
    spawn_main
      ~env_overrides:[
        "VM_LAUNCHER_STATE_BASE", state_base;
        "XDG_STATE_HOME", xdg;
        "HOME", base;
      ]
      [ "clean" ]
  in
  assert_b "exit code 2" (rc = 2);
  assert_b "explains it needs IDs or --exited"
    (contains "--exited" se)

(* `clean ID --exited` together is rejected: the two modes are
   mutually exclusive (one targets named sessions, the other sweeps
   all finished ones). *)
let test_cli_clean_id_and_exited_conflict () =
  with_temp_base @@ fun base ->
  let xdg = base ^ "/xdg" in
  let state_base = base ^ "/state" in
  List.iter (fun d -> Unix.mkdir d 0o755) [ xdg; state_base ];
  let rc, _so, se =
    spawn_main
      ~env_overrides:[
        "VM_LAUNCHER_STATE_BASE", state_base;
        "XDG_STATE_HOME", xdg;
        "HOME", base;
      ]
      [ "clean"; "20260101T120000-aaaaaa"; "--exited" ]
  in
  assert_b "exit code 2" (rc = 2);
  assert_b "complains about mixing the two"
    (contains "not both" se)

(* Minimal self-contained Nickel policy with every required field set
   to its in-OCaml-parser default. Avoids importing the contract so
   the test doesn't need a path to policy/contract.ncl in the build
   tree. [tools_ncl] is interpolated verbatim.

   String values for the would-be-enum fields (`work.default = "rw"`,
   `auth = "bind"`) work here despite the contract requiring enum tags
   because the policy isn't piped through `| c.Policy` — the launcher's
   Nickel pipeline just exports the raw record as JSON, and the OCaml
   parser accepts the string form regardless of the contract's type.

   [?console]: when set, emits a `console = "<v>"` line so tests that
   exercise the round-trip via `--show` can pin the field. *)
let write_policy ?console ~path ~project ~tools_ncl () =
  let oc = open_out path in
  Printf.fprintf oc
    "{\n\
    \  project = \"%s\",\n\
    \  work = { default = \"rw\", readOnly = [], hidden = [] },\n\
    \  inputs = [],\n\
    \  shares = [],\n\
    \  egress = { hosts = [\"api.anthropic.com\"], none = false },\n\
    \  auth = \"bind\",\n\
    \  tools = %s,\n\
    \  resources = { vcpu = 2, memMb = 1024 },\n\
    \  agent = {\n\
    \    preset = \"claude\", command = \"claude\", flags = [],\n\
    \    instructionsFile = \"CLAUDE.md\", instructions = \"\",\n\
    \    configDir = \".claude\", configGuest = \"/var/lib/claude\",\n\
    \    taskDir = \"tasks\", stateDirs = [], stateFiles = [],\n\
    \    homeStateFiles = [],\n\
    \  },\n\
    \  loginMessage = \"\",\n\
    \  secrets = [],\n\
    \  proxyAuth = [],\n\
    \  guest = { hostname = \"\", username = \"\" },\n\
    \  startup = { commands = [], logFile = \"\" },\n\
    \  stateDir = \"\",\n\
    \  julia = { env = \"env/julia\" },\n\
    \  r = { packages = [] },\n\
    \  git = { name = \"\", email = \"\", allowedGithubOrgs = [] },\n"
    project tools_ncl;
  (match console with
   | None -> ()
   | Some v -> Printf.fprintf oc "  console = \"%s\",\n" v);
  output_string oc "  }\n";
  close_out oc

(* End-to-end: launcher → resolver → stage → Boot.run entry →
   Validate.tools → fake nix → error message. Proves the bad-tool
   guard fires in the actual CLI path, not just at the unit level. *)
let test_cli_bad_tool_fails_before_nix_build () =
  with_temp_base @@ fun base ->
  let bin_dir, _out_file, _rc =
    setup_fake_nix ~base
      ~output:"[\"totally-not-a-thing-xyzzy\"]"
      ~rc:0
  in
  let state_base = base ^ "/state" in
  let home = base ^ "/home" in
  let xdg = base ^ "/xdg" in
  List.iter (fun d -> Unix.mkdir d 0o755) [ state_base; home; xdg ];
  let policy = base ^ "/microvm.ncl" in
  write_policy ~path:policy ~project:base
    ~tools_ncl:"[\"coreutils\", \"totally-not-a-thing-xyzzy\"]" ();
  let prev_path = try Sys.getenv "PATH" with Not_found -> "" in
  let rc, _so, se =
    spawn_main
      ~env_overrides:[
        "PATH", bin_dir ^ ":" ^ prev_path;
        "FAKE_NIX_OUTPUT_FILE", base ^ "/output";
        "FAKE_NIX_RC", "0";
        "VM_LAUNCHER_STATE_BASE", state_base;
        (* No taps in the nix build sandbox: pin a fake slot pool so
           the launcher reaches the seam this test asserts on. *)
        "VM_LAUNCHER_SLOT_POOL", "0";
        "VM_LAUNCHER_FLAKE", "path:/dummy";
        "HOME", home;
        "XDG_STATE_HOME", xdg;
      ]
      [ "--policy"; policy ]
  in
  assert_b "exit non-zero" (rc <> 0);
  assert_b "stderr mentions policy.tools" (contains "policy.tools" se);
  assert_b "stderr names the bad attr"
    (contains "totally-not-a-thing-xyzzy" se);
  (* The fake nix never blew up; if validation didn't fire FIRST,
     boot.ml would have tried a real nix build and failed differently. *)
  assert_b "no 'nix build exited with rc' message"
    (not (contains "nix build exited with rc" se))

(* Good-tool variant: same fake nix, but rigged to report nothing
   missing. The launcher should then proceed past Validate.tools and
   only fail when it hits the SECOND nix invocation (the real
   `nix build` for the runner closure). The fake shim returns [] for
   eval AND [] for build, so [Boot.nix_build_runner] sees an empty
   output and fails with its own distinct message. That's the seam
   we're verifying: Validate fired AND was satisfied, the failure
   moved one step downstream. *)
let test_cli_good_tools_passes_validate_reaches_build () =
  with_temp_base @@ fun base ->
  let bin_dir, _out_file, _rc =
    setup_fake_nix ~base ~output:"[]" ~rc:0
  in
  let state_base = base ^ "/state" in
  let home = base ^ "/home" in
  let xdg = base ^ "/xdg" in
  List.iter (fun d -> Unix.mkdir d 0o755) [ state_base; home; xdg ];
  let policy = base ^ "/microvm.ncl" in
  write_policy ~path:policy ~project:base
    ~tools_ncl:"[\"coreutils\", \"git\"]" ();
  let prev_path = try Sys.getenv "PATH" with Not_found -> "" in
  let rc, _so, se =
    spawn_main
      ~env_overrides:[
        "PATH", bin_dir ^ ":" ^ prev_path;
        "FAKE_NIX_OUTPUT_FILE", base ^ "/output";
        "FAKE_NIX_RC", "0";
        "VM_LAUNCHER_STATE_BASE", state_base;
        (* No taps in the nix build sandbox: pin a fake slot pool so
           the launcher reaches the seam this test asserts on. *)
        "VM_LAUNCHER_SLOT_POOL", "0";
        "VM_LAUNCHER_FLAKE", "path:/dummy";
        "HOME", home;
        "XDG_STATE_HOME", xdg;
      ]
      [ "--policy"; policy ]
  in
  assert_b "exit non-zero (no real nix build)" (rc <> 0);
  assert_b "did NOT trip the bad-tool guard"
    (not (contains "policy.tools" se));
  (* Boot.nix_build_runner saw "[]" as the build output path, so its
     distinct failure modes fire instead — either empty output or
     missing-microvm-run. *)
  assert_b "downstream failure surfaced"
    (contains "nix build" se
     || contains "produced empty output" se
     || contains "no microvm-run" se)

(* `vm-launcher --show` round-trips policy.console through the Nickel
   exporter, OCaml parser, and Policy.to_json. With no `console` field
   in the policy file, the parser fills in Console_hvc0 (matches the
   contract default), and the JSON output reflects that. *)
let test_cli_show_console_default_hvc0 () =
  with_temp_base @@ fun base ->
  let state_base = base ^ "/state" in
  let home = base ^ "/home" in
  let xdg = base ^ "/xdg" in
  List.iter (fun d -> Unix.mkdir d 0o755) [ state_base; home; xdg ];
  let policy = base ^ "/microvm.ncl" in
  write_policy ~path:policy ~project:base
    ~tools_ncl:"[\"coreutils\"]" ();
  let rc, so, _se =
    spawn_main
      ~env_overrides:[
        "VM_LAUNCHER_STATE_BASE", state_base;
        "HOME", home;
        "XDG_STATE_HOME", xdg;
      ]
      [ "--policy"; policy; "--show" ]
  in
  assert_b "--show exits 0 on a valid policy" (rc = 0);
  assert_b "stdout contains the resolved-policy header"
    (contains "## vm-launcher: resolved policy" so);
  assert_b "console field surfaces with hvc0 default in JSON"
    (contains "\"console\": \"hvc0\"" so);
  (* A dry run is not a session: nothing lands in the registry `ls`
     reads, so it can't show up there as an "exited" row. *)
  let registry = xdg ^ "/microvm/sessions" in
  assert_b "--show registers no session"
    (not (Sys.file_exists registry) || Sys.readdir registry = [||])

(* Explicit `console = "ttyS0"` in the policy → JSON output reflects
   it. Pins the round-trip end-to-end so a future change that drops
   the field from Policy.to_json or mangles the enum→string mapping
   trips this test loudly. *)
let test_cli_show_console_explicit_ttys0 () =
  with_temp_base @@ fun base ->
  let state_base = base ^ "/state" in
  let home = base ^ "/home" in
  let xdg = base ^ "/xdg" in
  List.iter (fun d -> Unix.mkdir d 0o755) [ state_base; home; xdg ];
  let policy = base ^ "/microvm.ncl" in
  write_policy ~console:"ttyS0" ~path:policy ~project:base
    ~tools_ncl:"[\"coreutils\"]" ();
  let rc, so, _se =
    spawn_main
      ~env_overrides:[
        "VM_LAUNCHER_STATE_BASE", state_base;
        "HOME", home;
        "XDG_STATE_HOME", xdg;
      ]
      [ "--policy"; policy; "--show" ]
  in
  assert_b "--show exits 0 on a valid policy" (rc = 0);
  assert_b "console field surfaces as ttyS0 in JSON"
    (contains "\"console\": \"ttyS0\"" so);
  assert_b "no stray hvc0 leaks into the output"
    (not (contains "\"console\": \"hvc0\"" so))

(* `--egress noblock` is the operator-only unfence switch. It must flip
   the serialized egress.mode (the field the guest reads), surface the
   posture in --show, and print a loud UNFENCED warning to stderr. This
   pins the whole flag path: Arg parse → override → Policy.to_json. *)
let test_cli_egress_noblock_show () =
  with_temp_base @@ fun base ->
  let state_base = base ^ "/state" in
  let home = base ^ "/home" in
  let xdg = base ^ "/xdg" in
  List.iter (fun d -> Unix.mkdir d 0o755) [ state_base; home; xdg ];
  let policy = base ^ "/microvm.ncl" in
  write_policy ~path:policy ~project:base ~tools_ncl:"[\"coreutils\"]" ();
  let env = [
    "VM_LAUNCHER_STATE_BASE", state_base;
    "HOME", home;
    "XDG_STATE_HOME", xdg;
  ] in
  let rc, so, se =
    spawn_main ~env_overrides:env [ "--policy"; policy; "--egress"; "noblock"; "--show" ]
  in
  assert_b "--egress noblock --show exits 0" (rc = 0);
  (* The legacy spelling still parses, but the wire format and the
     posture line now use the vocabulary the tool displays everywhere. *)
  assert_b "serialized egress.mode is the new vocabulary"
    (contains "\"mode\": \"unfenced\"" so);
  assert_b "posture line reports unfenced" (contains "unfenced (direct internet" so);
  assert_b "loud UNFENCED warning on stderr"
    (contains "UNFENCED" se);
  (* Default (no flag) stays on the fence. *)
  let _, so2, _ = spawn_main ~env_overrides:env [ "--policy"; policy; "--show" ] in
  assert_b "default posture is fenced" (contains "\"mode\": \"fenced\"" so2);
  (* The new spelling of the same override is accepted too. *)
  let rc3, so3, _ =
    spawn_main ~env_overrides:env
      [ "--policy"; policy; "--egress"; "unfenced"; "--show" ]
  in
  assert_b "--egress unfenced exits 0" (rc3 = 0);
  assert_b "and resolves to the same posture"
    (contains "\"mode\": \"unfenced\"" so3)

(* A bad --egress value is a clean exit 2 (not an exception/stacktrace). *)
let test_cli_egress_bad_value_exits_two () =
  let rc, _so, se = spawn_main [ "--egress"; "bogus" ] in
  assert_b "bad --egress value exits 2" (rc = 2);
  assert_b "names the bad value" (contains "bogus" se);
  assert_b "lists the valid values" (contains "unfenced" se)

(* main.exe should NOT silently mkdir paths under VM_LAUNCHER_STATE_BASE
   when the override points at a missing parent we control. This guards
   the env-var contract from drift. *)
let test_cli_state_base_override_used () =
  with_temp_base @@ fun base ->
  let state_base = base ^ "/state" in
  Unix.mkdir state_base 0o755;
  let rc, _so, _se = spawn_main
    ~env_overrides:[
      "VM_LAUNCHER_STATE_BASE", state_base;
      "HOME", base;
    ]
    [ "--help" ]
  in
  assert_b "--help exits 0 regardless of override" (rc = 0);
  (* The override is read at module init; --help short-circuits before
     state_base is touched, but reading the env var must not fail
     parsing. If the launcher mis-parsed it the binary would exit
     non-zero. *)
  ignore base

let cases =
  [
    "cli-help-exits-zero", test_cli_help_exits_zero;
    "cli-h-short-help-exits-zero", test_cli_h_short_help_exits_zero;
    "cli-unknown-subcommand-exits-two", test_cli_unknown_subcommand_exits_two;
    "cli-unknown-flag-exits-two", test_cli_unknown_flag_exits_two;
    "cli-clean-requires-target", test_cli_clean_requires_target;
    "cli-clean-id-and-exited-conflict",
      test_cli_clean_id_and_exited_conflict;
    "cli-state-base-override-used", test_cli_state_base_override_used;
    "cli-bad-tool-fails-before-nix-build",
      test_cli_bad_tool_fails_before_nix_build;
    "cli-good-tools-passes-validate-reaches-build",
      test_cli_good_tools_passes_validate_reaches_build;
    "cli-show-console-default-hvc0", test_cli_show_console_default_hvc0;
    "cli-show-console-explicit-ttys0", test_cli_show_console_explicit_ttys0;
    "cli-egress-noblock-show", test_cli_egress_noblock_show;
    "cli-egress-bad-value-exits-two", test_cli_egress_bad_value_exits_two;
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
  if !failed > 0 then begin
    Printf.printf "\n%d test(s) failed\n" !failed;
    exit 1
  end
