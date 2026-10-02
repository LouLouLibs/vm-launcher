(* Per-session ssh material for `vm-launcher attach`.

   The guest runs sshd bound to its slot address on the host-only tap
   network. Everything here exists so that attaching needs no operator
   setup and no TOFU prompt:

   - a CLIENT keypair, generated per session, private half kept in the
     session state dir, public half staged for the guest;
   - a HOST keypair, also generated here, private half staged INTO the
     guest (its root is tmpfs, so a guest-generated key would differ on
     every boot) and the public half written into a session-scoped
     known_hosts so verification is strict rather than disabled.

   Both are ephemeral: they live and die with the session state dir. *)

type attach_info = {
  id : string;
  project : string;
  slot : int;
  guest_ip : string;
  user : string;
  key : string;
  known_hosts : string;
  runner_pid : int;
  detached : bool;
}

(* Guest address of a slot: the host owns 10.42.<slot>.1, the guest
   .2 (see the host's vm-launcher module + _guest.nix). *)
let guest_ip ~slot = Printf.sprintf "10.42.%d.2" slot

let run_quiet prog args =
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0o644 in
  let pid =
    Unix.create_process prog (Array.of_list (prog :: args)) devnull devnull
      devnull
  in
  let _, status = Unix.waitpid [] pid in
  (try Unix.close devnull with Unix.Unix_error _ -> ());
  match status with Unix.WEXITED 0 -> true | _ -> false

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* ssh-keygen must be on PATH. The installed wrapper puts openssh
   there; a bare dev shell may not, hence the explicit error rather
   than a confusing keygen failure later. *)
let keygen ~path ~comment =
  (* -N "" = no passphrase: the key is as secret as the session dir it
     lives in, and an interactive prompt would break every non-tty
     caller (the e2e suite included). *)
  if not (run_quiet "ssh-keygen"
            [ "-q"; "-t"; "ed25519"; "-N"; ""; "-C"; comment; "-f"; path ])
  then
    failwith
      (Printf.sprintf
         "ssh-keygen failed for %s — is openssh on PATH? (session.ssh = \
          true needs it to mint the per-session keypair)"
         path)

let generate ~state_dir ~etc_dir ~slot =
  let client = state_dir ^ "/id_ed25519" in
  let host = state_dir ^ "/ssh_host_ed25519_key" in
  List.iter
    (fun p ->
      (* ssh-keygen refuses to overwrite without prompting. *)
      List.iter
        (fun f -> if Sys.file_exists f then Sys.remove f)
        [ p; p ^ ".pub" ])
    [ client; host ];
  keygen ~path:client ~comment:"vm-launcher-attach";
  keygen ~path:host ~comment:"vm-launcher-guest-host-key";

  let ssh_etc = etc_dir ^ "/ssh" in
  Util.mkdir_p ~perm:0o755 ssh_etc;
  (* The guest's vm-sshd-keys oneshot copies these into place with the
     ownership sshd requires; staged mode only has to keep them from
     being world-readable on the host side. *)
  Util.copy_file ~perm:0o644 (client ^ ".pub") (ssh_etc ^ "/authorized_key.pub");
  Util.copy_file ~perm:0o600 host (ssh_etc ^ "/host_ed25519_key");

  (* known_hosts, scoped to this session: strict verification without a
     prompt, and no pollution of the operator's ~/.ssh/known_hosts with
     an address that gets a different key next boot. *)
  let pub = String.trim (read_file (host ^ ".pub")) in
  Util.write_file (state_dir ^ "/known_hosts")
    (Printf.sprintf "%s %s\n" (guest_ip ~slot) pub)

(* attach.json: what `vm-launcher attach` needs to reach a running
   session, written next to the rest of the session state. *)

let attach_path ~state_dir = state_dir ^ "/attach.json"

let to_json (a : attach_info) =
  `Assoc
    [
      ("id", `String a.id);
      ("project", `String a.project);
      ("slot", `Int a.slot);
      ("guestIp", `String a.guest_ip);
      ("user", `String a.user);
      ("key", `String a.key);
      ("knownHosts", `String a.known_hosts);
      ("runnerPid", `Int a.runner_pid);
      ("detached", `Bool a.detached);
    ]

(* tmp + rename: `ls` reads this concurrently, and an in-place truncate
   lets it observe an empty or half-written file — which Ssh.read turns
   into None, i.e. a live VM flapping to "no attach info". *)
let write ~state_dir (a : attach_info) =
  let final = attach_path ~state_dir in
  let tmp = final ^ ".tmp" in
  Util.write_file tmp (Yojson.Safe.pretty_to_string (to_json a) ^ "\n");
  Sys.rename tmp final

let read ~state_dir : attach_info option =
  let path = attach_path ~state_dir in
  if not (Sys.file_exists path) then None
  else
    try
      let j = Yojson.Safe.from_file path in
      let field k =
        match j with `Assoc kvs -> List.assoc_opt k kvs | _ -> None
      in
      let str k = match field k with Some (`String s) -> s | _ -> "" in
      let int_ k = match field k with Some (`Int n) -> n | _ -> -1 in
      let bool_ k = match field k with Some (`Bool b) -> b | _ -> false in
      Some
        {
          id = str "id";
          project = str "project";
          slot = int_ "slot";
          guest_ip = str "guestIp";
          user = str "user";
          key = str "key";
          known_hosts = str "knownHosts";
          runner_pid = int_ "runnerPid";
          detached = bool_ "detached";
        }
    with _ -> None

(* argv for reaching the guest. StrictHostKeyChecking stays ON — the
   session-scoped known_hosts written by [generate] already has the
   right key, so a mismatch here means something is wrong, not merely
   new. IdentitiesOnly keeps the agent's other keys out of the
   handshake. *)
let ssh_argv ?(command = None) (a : attach_info) =
  let base =
    [
      "ssh";
      "-i"; a.key;
      "-o"; "IdentitiesOnly=yes";
      "-o"; "UserKnownHostsFile=" ^ a.known_hosts;
      "-o"; "StrictHostKeyChecking=yes";
      "-o"; "LogLevel=ERROR";
      Printf.sprintf "%s@%s" a.user a.guest_ip;
    ]
  in
  Array.of_list (match command with None -> base | Some c -> base @ [ c ])

(* Probe argv: the same strict options as [ssh_argv], plus BatchMode (never
   prompt) and a short ConnectTimeout, running [true]. *)
let probe_argv (a : attach_info) =
  [|
    "ssh"; "-i"; a.key;
    "-o"; "IdentitiesOnly=yes";
    "-o"; "UserKnownHostsFile=" ^ a.known_hosts;
    "-o"; "StrictHostKeyChecking=yes";
    "-o"; "LogLevel=ERROR";
    "-o"; "BatchMode=yes";
    "-o"; "ConnectTimeout=3";
    Printf.sprintf "%s@%s" a.user a.guest_ip;
    "true";
  |]

let runner_alive pid =
  pid > 0 && (try Unix.kill pid 0; true with Unix.Unix_error _ -> false)

(* Is sshd answering yet? A bare TCP connect plus the server's
   identification line — no auth, no ssh process — so `ls` can afford it
   once per live row. Before the guest's network is up the connect hangs
   (nobody answers ARP for .2), hence the short deadline; once the kernel
   is up but sshd isn't, it is refused at once. Reading the "SSH-" banner
   rather than trusting connect() alone is what makes "available" mean
   sshd, not merely "something accepted". *)
let sshd_up ?(timeout = 0.5) ?(port = 22) (a : attach_info) =
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) @@ fun () ->
  (* On Linux connect() honours SO_SNDTIMEO, so both halves are bounded. *)
  Unix.setsockopt_float fd Unix.SO_SNDTIMEO timeout;
  Unix.setsockopt_float fd Unix.SO_RCVTIMEO timeout;
  let b = Bytes.create 4 in
  try
    Unix.connect fd
      (Unix.ADDR_INET (Unix.inet_addr_of_string a.guest_ip, port));
    Unix.read fd b 0 4 = 4 && Bytes.to_string b = "SSH-"
  with _ -> false

let wait_ready ?(timeout = 300.0) (a : attach_info) =
  let deadline = Unix.gettimeofday () +. timeout in
  let null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  let probe () =
    match Unix.create_process "ssh" (probe_argv a) null null null with
    | pid -> (
        match Unix.waitpid [] pid with
        | _, Unix.WEXITED 0 -> true
        | _ -> false)
    | exception Unix.Unix_error _ -> false
  in
  let rec loop () =
    if not (runner_alive a.runner_pid) then false
    else if probe () then true
    else if Unix.gettimeofday () >= deadline then false
    else (Unix.sleepf 1.0; loop ())
  in
  Fun.protect ~finally:(fun () -> Unix.close null) loop

let run_interactive (a : attach_info) =
  let argv = ssh_argv a in
  match
    Unix.create_process "ssh" argv Unix.stdin Unix.stdout Unix.stderr
  with
  | exception Unix.Unix_error _ ->
      failwith "ssh not found on PATH — needed to attach"
  | pid ->
      (* The terminal belongs to ssh until it exits. ssh puts it in raw
         mode, so Ctrl-C normally reaches the guest as a byte; ignore the
         signal here too, so a stray one (before raw mode, or after) can't
         kill this process and skip the note that follows. *)
      let prev_int = Sys.signal Sys.sigint Sys.Signal_ignore in
      let prev_quit = Sys.signal Sys.sigquit Sys.Signal_ignore in
      let rec wait () =
        match Unix.waitpid [] pid with
        | _, Unix.WEXITED rc -> rc
        | _, (Unix.WSIGNALED _ | Unix.WSTOPPED _) -> 255
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
      in
      Fun.protect
        ~finally:(fun () ->
          Sys.set_signal Sys.sigint prev_int;
          Sys.set_signal Sys.sigquit prev_quit)
        wait
