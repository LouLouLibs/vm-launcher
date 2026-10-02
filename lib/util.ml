(* Internal grab-bag of file-IO + small process helpers shared across
   the library. Anything used by exactly one module stays in that
   module; promote here when the second copy appears. *)

let trim_trailing_newline s =
  let n = String.length s in
  if n > 0 && s.[n - 1] = '\n' then String.sub s 0 (n - 1) else s

let rec mkdir_p ?(perm = 0o755) path =
  if path = "" || path = "/" || path = "." then ()
  else if Sys.file_exists path then ()
  else begin
    mkdir_p ~perm (Filename.dirname path);
    try Unix.mkdir path perm
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let rm_rf path =
  let cmd = Printf.sprintf "rm -rf -- %s" (Filename.quote path) in
  ignore (Sys.command cmd)

(* O_CLOEXEC keeps the fd from leaking into subprocesses the launcher
   forks (nix build, virtiofsd, git, ...). Critical for the CA-key +
   secret writes — without it, a concurrent shell-out could inherit
   the fd and read the secret bytes before close. *)
let write_file ?(perm = 0o644) path content =
  let fd =
    Unix.openfile path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ]
      perm
  in
  let oc = Unix.out_channel_of_descr fd in
  output_string oc content;
  close_out oc

let read_file path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
    let n = in_channel_length ic in
    really_input_string ic n)

let read_file_opt path =
  try Some (read_file path) with _ -> None

(* /proc files report st_size = 0, so [read_file]'s in_channel_length
   returns "" for every one of them. Anything probing /proc must read
   until EOF instead. This silently defeated Clean.pid_is_virtiofsd's
   recycled-pid guard (it never matched, so the reaper never fired). *)
let read_proc_opt path =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let buf = Buffer.create 4096 in
        let chunk = Bytes.create 4096 in
        let rec loop () =
          let n = input ic chunk 0 4096 in
          if n > 0 then begin
            Buffer.add_subbytes buf chunk 0 n;
            loop ()
          end
        in
        (try loop () with End_of_file -> ());
        Some (Buffer.contents buf))
  with _ -> None

let read_file_trimmed path = trim_trailing_newline (read_file path)

let copy_file ?(perm = 0o644) src dst =
  write_file ~perm dst (read_file src)

let nixos_config_attr () =
  match Sys.getenv_opt "VM_LAUNCHER_NIXOS_CONFIG" with
  | Some s when s <> "" -> s
  | _ -> "vmLauncher"

(* Spawn [prog args], capture stdout into a string. stderr is inherited
   so the user still sees diagnostics. [env] defaults to the current
   process env; [stdin_dev_null], when set, opens /dev/null on the
   child's stdin (vs the launcher's own stdin) — used by nix eval to
   prevent a stray prompt from blocking on the TTY. *)
let subprocess_capture_stdout
    ?env ?(stdin_dev_null = false) ~prog ~args () =
  let pipe_r, pipe_w = Unix.pipe ~cloexec:true () in
  let try_close fd = try Unix.close fd with Unix.Unix_error _ -> () in
  let stdin_fd, owned_stdin =
    if stdin_dev_null
    then Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0, true
    else Unix.stdin, false
  in
  Fun.protect
    ~finally:(fun () ->
      try_close pipe_r;
      try_close pipe_w;
      if owned_stdin then try_close stdin_fd)
    (fun () ->
      let pid =
        match env with
        | None ->
            Unix.create_process prog args stdin_fd pipe_w Unix.stderr
        | Some e ->
            Unix.create_process_env prog args e stdin_fd pipe_w Unix.stderr
      in
      (* Close the write end NOW so the reader gets EOF when the
         child exits — the finally's [try_close] is idempotent. *)
      try_close pipe_w;
      let ic = Unix.in_channel_of_descr pipe_r in
      let b = Buffer.create 256 in
      Fun.protect
        (* close_in transfers ownership of pipe_r away from the channel
           — the outer finally's bare close then idempotently no-ops.
           Without close_in the fd is owned by the channel until GC and
           the finally races channel finalisation. *)
        ~finally:(fun () -> close_in ic)
        (fun () ->
          (try while true do Buffer.add_channel b ic 1024 done
           with End_of_file -> ());
          let _, st = Unix.waitpid [] pid in
          st, Buffer.contents b))

(* --- colored stderr logging --------------------------------------- *)

(* ANSI color on stderr, gated on it being a real terminal and the user
   not having opted out via NO_COLOR (https://no-color.org). Memoized —
   tty-ness is fixed for the process lifetime. Piped/redirected output
   (the test harness, the in-guest proxy whose stderr is a journal pipe)
   all get plain text, byte-identical to the un-colored prefix form. *)
let stderr_is_color =
  lazy (Unix.isatty Unix.stderr && Sys.getenv_opt "NO_COLOR" = None)

let ansi codes s =
  if codes = "" || not (Lazy.force stderr_is_color) then s
  else Printf.sprintf "\027[%sm%s\027[0m" codes s

(* Emit a "<name>: <message>" line to stderr (newline + flush). The tag
   is colored by severity; the body is tinted for warn/error so the
   whole line reads at a glance. With color disabled this is exactly
   ["<name>: " ^ message ^ "\n"], matching the historical prefix. *)
let log_line ~tag_codes ~body_codes ~name fmt =
  Printf.ksprintf
    (fun s ->
      prerr_string (ansi tag_codes (name ^ ":"));
      prerr_char ' ';
      prerr_string (ansi body_codes s);
      prerr_newline ();
      flush stderr)
    fmt

let log_info ?(name = "vm-launcher") fmt =
  log_line ~tag_codes:"1;36" ~body_codes:"" ~name fmt

let log_warn ?(name = "vm-launcher") fmt =
  log_line ~tag_codes:"1;33" ~body_codes:"33" ~name fmt

let log_error ?(name = "vm-launcher") fmt =
  log_line ~tag_codes:"1;31" ~body_codes:"31" ~name fmt

(* A phase marker — the ordered milestones of a launch (build, stage,
   boot). Bolded body + a ▶ glyph so the stages stand out among the
   run-of-the-mill info lines and demarcate where subprocess output
   (nix, cloud-hypervisor) begins. With color off it degrades to
   "<name>: ▶ <message>". *)
let log_phase ?(name = "vm-launcher") fmt =
  log_line ~tag_codes:"1;36" ~body_codes:"1" ~name ("\xe2\x96\xb6 " ^^ fmt)
