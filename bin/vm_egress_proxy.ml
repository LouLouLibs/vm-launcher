(* vm-egress-proxy: HTTPS-CONNECT egress proxy for the vm-launcher guest.

   Listens on 127.0.0.1:3128, accepts HTTP CONNECT, gates by hostname-
   suffix allowlist (from /etc/vm-launcher/egress-hosts), tunnels raw
   TCP to the target or — for chained suffixes — through an upstream
   HTTP proxy (e.g. the tailscaled outbound chain for
   *.example.ts.net).

   For hosts that match a configured [proxyAuth] rule, TLS-terminates
   the connection (with a per-session CA, signing leaf certs on
   demand), injects the configured header, and forwards to the real
   upstream. Otherwise the tunnel is opaque end-to-end. *)

open Lwt.Infix
open Vm_launcher_lib

(* CONNECT is one ASCII line + headers up to a blank line; cohttp's
   Request.read in v6 wants its own channel type and adds friction.
   parse_connect_line lives in Proxy_lib for unit testability — cohttp
   stays in the dev shell for 3b's plain-HTTP header-injection path. *)
let drain_headers ic =
  let rec loop () =
    Lwt_io.read_line_opt ic >>= function
    | None -> Lwt.return_unit
    | Some line when String.trim line = "" -> Lwt.return_unit
    | Some _ -> loop ()
  in
  loop ()

let log fmt =
  Printf.ksprintf (fun s -> prerr_endline ("vm-egress-proxy: " ^ s)) fmt

(* ---------- CLI ---------- *)

let port = ref 3128
let listen_addr = ref "127.0.0.1"
let egress_hosts_path = ref "/etc/vm-launcher/egress-hosts"
let upstream_rules : Proxy_lib.upstream_rule list ref = ref []
(* MITM termination on hosts with a configured proxyAuth rule. Keys
   are loaded once at startup; the CA signs per-host leaf certs on
   demand. *)
let proxy_ca_cert_path = ref ""
let proxy_ca_key_path = ref ""
let proxy_auth_specs : string list ref = ref []
(* In production the systemd unit hands a file in via --proxy-auth-config
   (Stage.proxy_auth_config writes it during launcher staging). The
   inline --proxy-auth flag stays for tests + ad-hoc dev: when both are
   set, file rules come first, then inline rules appended. *)
let proxy_auth_config_path = ref ""
let secret_dir = ref ""
let gen_ca = ref false
(* CONNECT to ports outside this set is rejected. Bash launcher used
   tinyproxy's ConnectPort 443 — only TLS. *)
let allowed_connect_ports = [ 443 ]

let help_text =
  {|vm-egress-proxy: HTTPS-CONNECT egress proxy for the vm-launcher guest.

Usage:
  vm-egress-proxy [--port PORT] [--listen ADDR] [--egress-hosts PATH]
            [--upstream SUFFIX=HOST:PORT ...]
            [--proxy-ca-cert PATH --proxy-ca-key PATH
             --proxy-auth HOST=HEADER:TEMPLATE ... --secret-dir PATH]
  vm-egress-proxy --gen-ca --proxy-ca-cert PATH --proxy-ca-key PATH

  --port PORT          listen port (default 3128)
  --listen ADDR        bind address (default 127.0.0.1)
  --egress-hosts PATH  hostname-allowlist file (default /etc/vm-launcher/egress-hosts).
                       One hostname per line; blank + #-comment lines ignored.
                       Match is domain-suffix: an entry "foo.com" allows
                       "foo.com" and "*.foo.com" but NOT "evilfoo.com".
  --upstream SPEC      route matching hosts via an upstream HTTP proxy
                       (repeatable). SPEC is SUFFIX=HOST:PORT, e.g.
                       ".example.ts.net=10.42.0.1:1055" for the
                       tailscaled outbound chain.

MITM header injection:
  --proxy-ca-cert PATH PEM file with the CA cert used to sign leaf
                       certs for MITM'd hostnames. The agent's trust
                       store must trust this CA.
  --proxy-ca-key PATH  PEM file with the CA private key. Should be 0600.
  --proxy-auth SPEC    inject a header on outbound HTTPS requests to a
                       matching host (repeatable). SPEC is
                       HOST=HEADER:VALUE_TEMPLATE. Template supports
                       ${NAME} substitution against --secret-dir.
                       Example:
                         httpbin.org=Authorization:Bearer ${MY_API_KEY}
  --proxy-auth-config PATH
                       read TAB-separated rules from PATH (one per line):
                         HOST<TAB>HEADER<TAB>VALUE_TEMPLATE
                       Blank lines + '#'-prefixed comment lines ignored.
                       Combinable with --proxy-auth (file first, inline
                       rules appended).
  --secret-dir PATH    directory whose regular files are loaded into
                       the secret map at startup: filename → contents.
                       Default empty (no secrets).
  --gen-ca             generate a fresh CA into --proxy-ca-cert and
                       --proxy-ca-key (must NOT exist yet) and exit.
                       Convenience for tests; production launchers
                       generate the CA themselves.
|}

let print_help_and_exit () =
  print_string help_text;
  exit 0

let speclist =
  [
    "--port", Arg.Set_int port, "PORT listen port";
    "--listen", Arg.Set_string listen_addr, "ADDR bind address";
    "--egress-hosts", Arg.Set_string egress_hosts_path,
      "PATH allowlist file";
    "--upstream",
      Arg.String (fun s ->
        upstream_rules := !upstream_rules @ [ Proxy_lib.parse_upstream_rule s ]),
      "SPEC route matching hosts via upstream HTTP proxy";
    "--proxy-ca-cert", Arg.Set_string proxy_ca_cert_path,
      "PATH PEM file with the MITM CA cert";
    "--proxy-ca-key", Arg.Set_string proxy_ca_key_path,
      "PATH PEM file with the MITM CA private key";
    "--proxy-auth",
      Arg.String (fun s -> proxy_auth_specs := !proxy_auth_specs @ [ s ]),
      "SPEC HOST=HEADER:VALUE_TEMPLATE (repeatable)";
    "--proxy-auth-config", Arg.Set_string proxy_auth_config_path,
      "PATH file written by Stage.proxy_auth_config (TAB-separated HOST<TAB>HEADER<TAB>TEMPLATE)";
    "--secret-dir", Arg.Set_string secret_dir,
      "PATH directory of filename→contents secret files";
    "--gen-ca", Arg.Set gen_ca,
      " generate a fresh CA into --proxy-ca-cert/--proxy-ca-key and exit";
    "--help", Arg.Unit print_help_and_exit, " show this help and exit";
    "-h", Arg.Unit print_help_and_exit, " show this help and exit";
  ]

(* ---------- helpers ---------- *)

(* Close an Lwt channel, swallowing any failure. A closed-mid-tunnel
   socket raises here and is benign. *)
let safe_close ch =
  Lwt.catch (fun () -> Lwt_io.close ch) (fun _ -> Lwt.return_unit)

(* CONNECT 200: deliberately empty headers — see proxy_mitm.ml. *)
let write_connect_ok oc =
  Lwt_io.write oc "HTTP/1.1 200 Connection Established\r\n\r\n"

let write_status_with_body oc code reason body =
  Lwt_io.write oc
    (Printf.sprintf
       "HTTP/1.1 %d %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
       code reason (String.length body) body)

(* Bidirectional byte-copy between two Lwt input/output channel pairs.
   Returns when EITHER direction reaches EOF — the matching half is
   left to be reaped by close. Errors on either side are silently
   absorbed: a closed socket mid-tunnel is normal. *)
let bidirectional_tunnel client_ic client_oc upstream_ic upstream_oc =
  let buf_size = 4096 in
  let copy src dst =
    let buf = Bytes.create buf_size in
    let rec loop () =
      Lwt.catch
        (fun () ->
          Lwt_io.read_into src buf 0 buf_size >>= fun n ->
          if n = 0 then Lwt.return_unit
          else Lwt_io.write_from_exactly dst buf 0 n >>= loop)
        (fun _exn -> Lwt.return_unit)
    in
    loop ()
  in
  Lwt.join
    [ copy client_ic upstream_oc; copy upstream_ic client_oc ]

(* ---------- MITM session state ---------- *)

(* The proxyAuth rules live in the binary so the routing check
   ([Proxy_lib.pick_proxy_auth]) can decide between tunnel + MITM
   without going through the proxy_mitm library. *)
type mitm_run = {
  state : Proxy_mitm.mitm_state;
  rules : Policy.proxy_auth_rule list;
}

(* Load secrets via the library implementation; emit warnings on stderr.
   Failure to read the dir is fatal (exit 1). *)
let load_secret_dir dir =
  let h, warnings =
    try Proxy_lib.load_secret_dir ~dir
    with Failure msg ->
      Printf.eprintf "vm-egress-proxy: %s\n" msg; exit 1
  in
  List.iter (fun w -> log "%s" w) warnings;
  h

(* ---------- per-connection handler ---------- *)

let allowed_port port = List.mem port allowed_connect_ports

(* Gate the CONNECT request against the port set + host allowlist.
   [`Reject (code, reason, body, drain)]: [drain] is true when the
   request is well-formed and we should consume its headers before
   replying (be a polite proxy); false when parsing failed and the
   bytes can't be trusted. *)
let validate_request ~allowlist line =
  match Proxy_lib.parse_connect_line line with
  | None ->
      (* Not a well-formed CONNECT line — could be plain HTTP
         GET/POST (unsupported) or garbage. *)
      `Reject (405, "Method Not Allowed",
               "this proxy only accepts CONNECT\n", false)
  | Some ({ host; port = p } : Proxy_lib.connect_target)
    when not (allowed_port p) ->
      log "denied: CONNECT %s:%d (port not allowed)" host p;
      `Reject (403, "Forbidden",
               Printf.sprintf "port %d not in allowed CONNECT ports\n" p,
               true)
  | Some ({ host; port = p } : Proxy_lib.connect_target)
    when not (Proxy_lib.host_allowed ~allowlist ~host) ->
      log "denied: CONNECT %s:%d (host not in allowlist)" host p;
      `Reject (403, "Forbidden",
               Printf.sprintf "host %s not in egress allowlist\n" host,
               true)
  | Some target -> `Ok target

(* MITM branch: TLS-terminate the client side, inject the header, forward
   to the real upstream. Failures are logged + swallowed so the per-conn
   handler still falls through to cleanup. *)
let mitm_branch upstreams run rule (target : Proxy_lib.connect_target) client_ic client_oc =
  Lwt.catch
    (fun () ->
      Proxy_mitm.mitm_handler ~upstreams run.state rule
        { Proxy_lib.host = target.host; port = target.port }
        client_ic client_oc)
    (fun exn ->
      log "MITM %s:%d failed: %s" target.host target.port
        (Printexc.to_string exn);
      Lwt.return_unit)

(* Plain CONNECT tunnel branch: open upstream, ack the client, bidi-copy
   until either end EOFs, close the upstream side. *)
let tunnel_branch upstreams (target : Proxy_lib.connect_target) client_ic client_oc =
  Lwt.catch
    (fun () ->
      Proxy_mitm.connect_target ~upstreams target
      >>= fun (target_sock, target_ic, target_oc) ->
      write_connect_ok client_oc >>= fun () ->
      Lwt_io.flush client_oc >>= fun () ->
      bidirectional_tunnel client_ic client_oc target_ic target_oc
      >>= fun () ->
      safe_close target_ic >>= fun () ->
      safe_close target_oc >>= fun () ->
      (try Unix.close (Lwt_unix.unix_file_descr target_sock) with _ -> ());
      Lwt.return_unit)
    (fun exn ->
      log "CONNECT %s:%d failed: %s" target.host target.port
        (Printexc.to_string exn);
      write_status_with_body client_oc 502 "Bad Gateway"
        (Printf.sprintf "upstream connect: %s\n" (Printexc.to_string exn)))

let addr_str = function
  | Unix.ADDR_INET (ia, p) ->
      Printf.sprintf "%s:%d" (Unix.string_of_inet_addr ia) p
  | Unix.ADDR_UNIX p -> p

let handle_connection ?mitm allowlist upstreams (client_sock, client_addr) =
  let client_ic = Lwt_io.of_fd ~mode:Lwt_io.input client_sock in
  let client_oc = Lwt_io.of_fd ~mode:Lwt_io.output client_sock in
  let cleanup () = safe_close client_ic >>= fun () -> safe_close client_oc in
  let dispatch (target : Proxy_lib.connect_target) =
    let mitm_rule =
      match mitm with
      | Some run -> Proxy_lib.pick_proxy_auth run.rules target.host
      | None -> None
    in
    match mitm, mitm_rule with
    | Some run, Some rule -> mitm_branch upstreams run rule target client_ic client_oc
    | _ -> tunnel_branch upstreams target client_ic client_oc
  in
  Lwt.catch
    (fun () ->
      Lwt_io.read_line_opt client_ic >>= function
      | None -> cleanup ()
      | Some line ->
          (match validate_request ~allowlist line with
           | `Reject (code, reason, body, drain) ->
               (if drain then drain_headers client_ic else Lwt.return_unit)
               >>= fun () ->
               write_status_with_body client_oc code reason body
               >>= cleanup
           | `Ok target ->
               drain_headers client_ic >>= fun () ->
               dispatch target >>= cleanup))
    (fun exn ->
      log "client handler error (%s): %s"
        (addr_str client_addr) (Printexc.to_string exn);
      cleanup ())

(* ---------- main loop ---------- *)

let run ~port ~listen_addr ~allowlist ~upstreams ~mitm =
  let addr =
    Unix.ADDR_INET (Unix.inet_addr_of_string listen_addr, port)
  in
  let sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt sock Unix.SO_REUSEADDR true;
  Lwt_unix.bind sock addr >>= fun () ->
  Lwt_unix.listen sock 32;
  let mitm_desc = match mitm with
    | None -> "off"
    | Some run -> Printf.sprintf "%d rules" (List.length run.rules)
  in
  log "listening on %s:%d (allowlist=%d, upstreams=%d, mitm=%s)"
    listen_addr port (List.length allowlist) (List.length upstreams)
    mitm_desc;
  let rec accept_loop () =
    Lwt_unix.accept sock >>= fun pair ->
    Lwt.async (fun () ->
      handle_connection ?mitm allowlist upstreams pair);
    accept_loop ()
  in
  accept_loop ()

(* --gen-ca mode: generate a fresh CA, write PEMs, exit. *)
let do_gen_ca () =
  if !proxy_ca_cert_path = "" || !proxy_ca_key_path = "" then begin
    Printf.eprintf
      "vm-egress-proxy: --gen-ca requires both --proxy-ca-cert and --proxy-ca-key\n";
    exit 2
  end;
  (* Refuse to overwrite — protects against the obvious "oops, my key". *)
  if Sys.file_exists !proxy_ca_cert_path then begin
    Printf.eprintf "vm-egress-proxy: --proxy-ca-cert %s already exists\n"
      !proxy_ca_cert_path;
    exit 1
  end;
  if Sys.file_exists !proxy_ca_key_path then begin
    Printf.eprintf "vm-egress-proxy: --proxy-ca-key %s already exists\n"
      !proxy_ca_key_path;
    exit 1
  end;
  Mirage_crypto_rng_unix.use_default ();
  let ca = Proxy_ca.generate_ca () in
  (* Explicit umask: openfile's mode is masked by the process umask
     before the kernel applies it. With the operator's umask = 022,
     mode 0600 → 0600 (no bits to clear). With umask = 027 or 0, the
     resulting file mode would be wider than intended. Pin umask to
     0077 around the writes so the CA key NEVER lands group/other-
     readable, regardless of the calling shell's umask. Restore on
     exit. *)
  let saved_umask = Unix.umask 0o077 in
  let restore_umask () = ignore (Unix.umask saved_umask) in
  let write_secure path body =
    let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600 in
    let n = String.length body in
    let written = Unix.write_substring fd body 0 n in
    Unix.close fd;
    if written <> n then begin
      Printf.eprintf "vm-egress-proxy: short write to %s\n" path;
      restore_umask ();
      exit 1
    end
  in
  Fun.protect ~finally:restore_umask (fun () ->
    write_secure !proxy_ca_cert_path (Proxy_ca.ca_cert_pem ca);
    write_secure !proxy_ca_key_path (Proxy_ca.ca_key_pem ca));
  Printf.printf "wrote CA cert: %s\nwrote CA key:  %s\n"
    !proxy_ca_cert_path !proxy_ca_key_path

(* Read --proxy-auth-config: defer the actual parse (skip blanks +
   #-comments, tolerate CRLF, per-line parse) to Proxy_lib so the
   filter logic stays unit-testable. We only own the IO + error-to-
   exit translation here. *)
let load_proxy_auth_config_file path =
  let content =
    try Util.read_file path
    with Sys_error msg ->
      Printf.eprintf "vm-egress-proxy: --proxy-auth-config %s\n" msg;
      exit 1
  in
  match Proxy_lib.parse_proxy_auth_config content with
  | Ok rules -> rules
  | Error msg ->
      Printf.eprintf "vm-egress-proxy: --proxy-auth-config %s: %s\n" path msg;
      exit 2

let load_mitm_state () : mitm_run option =
  (* MITM is opt-in: it activates only when the operator sets the CA
     paths AND at least one --proxy-auth* rule (from either source). *)
  let has_ca =
    !proxy_ca_cert_path <> "" || !proxy_ca_key_path <> ""
  in
  let file_rules =
    if !proxy_auth_config_path = "" then []
    else load_proxy_auth_config_file !proxy_auth_config_path
  in
  let inline_rules =
    List.map
      (fun spec ->
        match Proxy_lib.parse_proxy_auth_flag spec with
        | Ok r -> r
        | Error msg ->
            Printf.eprintf "vm-egress-proxy: %s\n" msg;
            exit 2)
      !proxy_auth_specs
  in
  (* File first, inline after — documented in --help. *)
  let rules = file_rules @ inline_rules in
  let has_rules = rules <> [] in
  if has_rules && not has_ca then begin
    Printf.eprintf
      "vm-egress-proxy: --proxy-auth/--proxy-auth-config requires \
       --proxy-ca-cert and --proxy-ca-key\n";
    exit 2
  end;
  if has_ca
     && (!proxy_ca_cert_path = "" || !proxy_ca_key_path = "") then begin
    Printf.eprintf
      "vm-egress-proxy: --proxy-ca-cert and --proxy-ca-key must both be set\n";
    exit 2
  end;
  if not has_rules then begin
    if has_ca then
      log "WARNING: --proxy-ca-* set but no --proxy-auth rules — MITM disabled";
    None
  end else begin
    Mirage_crypto_rng_unix.use_default ();
    let cert_pem = Util.read_file !proxy_ca_cert_path in
    let key_pem = Util.read_file !proxy_ca_key_path in
    let ca =
      match Proxy_ca.load_ca ~cert_pem ~key_pem with
      | Ok ca -> ca
      | Error msg ->
          Printf.eprintf "vm-egress-proxy: %s\n" msg;
          exit 1
    in
    let secrets =
      if !secret_dir <> "" then load_secret_dir !secret_dir
      else Hashtbl.create 16
    in
    (match Proxy_mitm.validate_templates rules secrets with
     | Ok () -> ()
     | Error msg ->
         Printf.eprintf "vm-egress-proxy: --proxy-auth %s\n" msg;
         exit 1);
    let upstream_authenticator =
      match Ca_certs.authenticator () with
      | Ok a -> a
      | Error (`Msg m) ->
          Printf.eprintf "vm-egress-proxy: upstream trust store: %s\n" m;
          exit 1
    in
    let state =
      Proxy_mitm.make_state ~ca ~secrets ~upstream_authenticator
    in
    Some { state; rules }
  end

let main () =
  Arg.parse speclist
    (fun s ->
      Printf.eprintf "vm-egress-proxy: unknown arg %S\n" s;
      exit 2)
    help_text;
  if !gen_ca then begin
    do_gen_ca ();
    exit 0
  end;
  let allowlist =
    try Proxy_lib.parse_egress_hosts (Util.read_file !egress_hosts_path)
    with Sys_error msg ->
      Printf.eprintf "vm-egress-proxy: %s\n" msg;
      exit 1
  in
  if allowlist = [] then
    log "WARNING: allowlist is empty — every CONNECT will be denied";
  let mitm = load_mitm_state () in
  Lwt_main.run
    (run ~port:!port ~listen_addr:!listen_addr ~allowlist
       ~upstreams:!upstream_rules ~mitm)

let () =
  try main () with
  | Failure msg ->
      Printf.eprintf "vm-egress-proxy: %s\n" msg;
      exit 1
  | Sys_error msg ->
      Printf.eprintf "vm-egress-proxy: %s\n" msg;
      exit 1
