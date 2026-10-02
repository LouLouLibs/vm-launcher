open Lwt.Infix
open Vm_launcher_lib

type mitm_state = {
  ca : Proxy_ca.ca;
  secrets : (string, string) Hashtbl.t;
  leaf_cache : (string, Proxy_ca.leaf) Hashtbl.t;
  upstream_config : Tls.Config.client;
}

let log fmt =
  Printf.ksprintf (fun s -> prerr_endline ("vm-egress-proxy: " ^ s)) fmt

(* Race [task] against an [secs]-second sleep; whichever finishes
   first wins. Bounds the worst case for upstream connect and TLS
   handshake — a dead-but-accepting host can otherwise pin the
   agent's TLS state indefinitely. *)
let with_timeout ~secs ~msg task =
  Lwt.pick
    [ task;
      Lwt_unix.sleep secs >>= fun () -> Lwt.fail_with msg ]

let upstream_connect_timeout = 5.0
let upstream_handshake_timeout = 5.0

let build_upstream_config authenticator =
  match
    Tls.Config.client ~authenticator
      ~alpn_protocols:[ "http/1.1" ]
      ()
  with
  | Ok c -> c
  | Error (`Msg m) -> failwith ("upstream tls config: " ^ m)

let make_state ~ca ~secrets ~upstream_authenticator =
  {
    ca;
    secrets;
    leaf_cache = Hashtbl.create 16;
    upstream_config = build_upstream_config upstream_authenticator;
  }

let validate_templates rules secrets =
  let rec loop = function
    | [] -> Ok ()
    | (r : Policy.proxy_auth_rule) :: rest ->
        (match
           Proxy_lib.render_template
             ~template:r.value_template
             ~lookup:(fun n -> Hashtbl.find_opt secrets n)
         with
         | Ok _ -> loop rest
         | Error msg ->
             Error
               (Printf.sprintf "%s=%s: %s" r.host r.header msg))
  in
  loop rules

(* Soft cap: when the cache grows past [leaf_cache_max], reset it
   (cheap; the next request for any host pays one cert-gen). Without
   a bound, a long-running session that hits many distinct hosts
   could grow this table without limit — an agent enumerating
   `*.example.com` (within the egress allowlist's domain-suffix
   match) would be enough. 256 entries fits a generous mix of API
   subdomains while keeping RSS in check. *)
let leaf_cache_max = 256

let leaf_for state host =
  match Hashtbl.find_opt state.leaf_cache host with
  | Some l -> l
  | None ->
      if Hashtbl.length state.leaf_cache >= leaf_cache_max then
        Hashtbl.reset state.leaf_cache;
      let l = Proxy_ca.generate_leaf ~ca:state.ca ~hostname:host in
      Hashtbl.add state.leaf_cache host l;
      l

let leaf_cache_size state = Hashtbl.length state.leaf_cache
let ensure_leaf state host = ignore (leaf_for state host)

(* Tls server config for a single hostname. ALPN forces http/1.1 —
   HTTP/2 needs the [h2] package and is deferred. *)
let mitm_server_config (leaf : Proxy_ca.leaf) =
  let own_cert =
    `Single ([ Proxy_ca.leaf_cert leaf ], Proxy_ca.leaf_key leaf)
  in
  match
    Tls.Config.server
      ~certificates:own_cert
      ~alpn_protocols:[ "http/1.1" ]
      ()
  with
  | Ok c -> c
  | Error (`Msg m) -> failwith ("mitm_server_config: " ^ m)

let domain_name_host_of_string s =
  match Domain_name.of_string s with
  | Error _ -> None
  | Ok d -> Result.to_option (Domain_name.host d)

(* TCP connect to host:port. Uses [getaddrinfo] (non-blocking under
   Lwt) — [gethostbyname] would block the whole event loop on every
   DNS query, pinning every other in-flight MITM connection. *)
let connect_direct host port =
  let opts =
    [ Unix.AI_FAMILY Unix.PF_INET; Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
  in
  Lwt_unix.getaddrinfo host (string_of_int port) opts >>= function
  | [] -> Lwt.fail_with (Printf.sprintf "no addresses for %s" host)
  | ai :: _ ->
      let sock = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
      Lwt.catch
        (fun () -> Lwt_unix.connect sock ai.Unix.ai_addr >|= fun () -> sock)
        (fun exn -> Lwt_unix.close sock >>= fun () -> Lwt.fail exn)

(* Shared by plain CONNECT and MITM, so authentication does not change
   how a destination is reached. Keep the channels after CONNECT: they
   own the socket and any bytes buffered while reading the response. *)
let connect_target ~upstreams (target : Proxy_lib.connect_target) =
  let upstream = Proxy_lib.pick_upstream upstreams target.host in
  let host, port = match upstream with
    | None ->
        log "CONNECT %s:%d (direct)" target.host target.port;
        target.host, target.port
    | Some u ->
        log "CONNECT %s:%d via upstream %s:%d"
          target.host target.port u.proxy_host u.proxy_port;
        u.proxy_host, u.proxy_port
  in
  connect_direct host port >>= fun sock ->
  let ic = Lwt_io.of_fd ~mode:Lwt_io.input sock in
  let oc = Lwt_io.of_fd ~mode:Lwt_io.output sock in
  Lwt.catch
    (fun () ->
      (match upstream with
       | None -> Lwt.return_unit
       | Some _ ->
           Lwt_io.write oc
             (Printf.sprintf "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n\r\n"
                target.host target.port target.host target.port)
           >>= fun () -> Lwt_io.flush oc >>= fun () ->
           Lwt_io.read_line_opt ic >>= fun line ->
           let accepted = match line with
             | Some s ->
                 (match String.split_on_char ' ' s with
                  | _ :: code :: _ ->
                      (match int_of_string_opt code with
                       | Some n -> n >= 200 && n < 300
                       | None -> false)
                  | _ -> false)
             | None -> false
           in
           if not accepted then Lwt.fail_with "upstream rejected CONNECT"
           else
             let rec drain () =
               Lwt_io.read_line_opt ic >>= function
               | Some "" -> Lwt.return_unit
               | None -> Lwt.fail_with "upstream EOF in CONNECT headers"
               | Some _ -> drain ()
             in
             drain ())
      >|= fun () -> sock, ic, oc)
    (fun exn ->
      Lwt.catch (fun () -> Lwt_io.close oc) (fun _ -> Lwt.return_unit)
      >>= fun () ->
      Lwt.catch (fun () -> Lwt_io.close ic) (fun _ -> Lwt.return_unit)
      >>= fun () -> Lwt.fail exn)

(* Walk a chunked body from [reader] into [writer]; returns when the
   transfer encoding signals end-of-body. Never buffers the whole
   stream — each chunk goes straight through. *)
let pump_body read_chunk write_body =
  let rec loop () =
    read_chunk () >>= function
    | Cohttp.Transfer.Done -> Lwt.return_unit
    | Final_chunk s -> write_body s
    | Chunk s -> write_body s >>= loop
  in
  loop ()

let render_value rule secrets =
  Proxy_lib.render_template
    ~template:rule.Policy.value_template
    ~lookup:(fun n -> Hashtbl.find_opt secrets n)

(* Write the [200 Connection Established] response for a CONNECT
   tunnel. Deliberately empty headers: the connection upgrades to a
   tunnel after the blank line, so [Connection: close] would be a
   nonsense signal and trips some pedantic clients. *)
let write_connect_ok oc =
  Lwt_io.write oc "HTTP/1.1 200 Connection Established\r\n\r\n"

let forward_to_upstream ~upstreams state target req agent_body_reader agent_oc =
  Lwt.catch
    (fun () ->
      let host_dn =
        match domain_name_host_of_string target.Proxy_lib.host with
        | Some d -> d
        | None ->
            failwith (Printf.sprintf "invalid hostname %S" target.host)
      in
      with_timeout
        ~secs:upstream_connect_timeout
        ~msg:(Printf.sprintf "upstream TCP connect timeout (%s)"
                target.host)
        (connect_target ~upstreams target)
      >>= fun (_, transport_ic, transport_oc) ->
      Lwt.catch
        (fun () ->
          with_timeout
            ~secs:upstream_handshake_timeout
            ~msg:(Printf.sprintf "upstream TLS handshake timeout (%s)"
                    target.host)
            (Tls_lwt.Unix.client_of_channels
               state.upstream_config ~host:host_dn (transport_ic, transport_oc))
          >>= fun upstream_tls ->
          let upstream_ic, upstream_oc = Tls_lwt.of_t upstream_tls in
          let upstream_cohttp_ic =
            Cohttp_lwt_unix.Private.Input_channel.create upstream_ic
          in
          let close_upstream () =
            Lwt.catch
              (fun () ->
                Lwt.catch (fun () -> Lwt_io.flush transport_oc)
                  (fun _ -> Lwt.return_unit) >>= fun () ->
                Tls_lwt.Unix.close upstream_tls)
              (fun _ -> Lwt.return_unit)
          in
          Lwt.finalize
            (fun () ->
              Cohttp_lwt_unix.Request.write ~flush:true
                (fun writer ->
                  (* RFC 7230: a request body exists only when
                     signaled by Content-Length or Transfer-Encoding.
                     Cohttp's [Unknown] encoding reads-until-EOF on the
                     body reader — pumping that against a keep-alive
                     agent waiting for our response would deadlock. *)
                  match Cohttp.Request.encoding req with
                  | Cohttp.Transfer.Unknown -> Lwt.return_unit
                  | Cohttp.Transfer.Fixed _ | Cohttp.Transfer.Chunked ->
                      pump_body
                        (fun () ->
                          Cohttp_lwt_unix.Request.read_body_chunk
                            agent_body_reader)
                        (fun s ->
                          Cohttp_lwt_unix.Request.write_body writer s))
                req upstream_oc
              >>= fun () ->
              Lwt_io.flush upstream_oc >>= fun () ->
              Cohttp_lwt_unix.Response.read upstream_cohttp_ic >>= function
              | `Eof ->
                  log "MITM %s: upstream EOF before response" target.host;
                  Lwt.return_unit
              | `Invalid msg ->
                  log "MITM %s: invalid response: %s" target.host msg;
                  Lwt.return_unit
              | `Ok resp ->
                  let resp_reader =
                    Cohttp_lwt_unix.Response.make_body_reader resp
                      upstream_cohttp_ic
                  in
                  Cohttp_lwt_unix.Response.write ~flush:true
                    (fun writer ->
                      pump_body
                        (fun () ->
                          Cohttp_lwt_unix.Response.read_body_chunk
                            resp_reader)
                        (fun s ->
                          Cohttp_lwt_unix.Response.write_body writer s))
                    resp agent_oc)
            close_upstream)
        (fun exn ->
          Lwt.catch (fun () -> Lwt_io.close transport_oc)
            (fun _ -> Lwt.return_unit) >>= fun () ->
          Lwt.catch (fun () -> Lwt_io.close transport_ic)
            (fun _ -> Lwt.return_unit) >>= fun () ->
          Lwt.fail exn))
    (fun exn ->
      log "MITM %s: upstream forward failed: %s" target.host
        (Printexc.to_string exn);
      let body =
        Printf.sprintf "upstream forward: %s\n" (Printexc.to_string exn)
      in
      let resp =
        Http.Response.make
          ~status:`Bad_gateway
          ~headers:
            (Http.Header.of_list
               [ "Content-Length", string_of_int (String.length body);
                 "Connection", "close" ])
          ()
      in
      Lwt.catch
        (fun () ->
          Cohttp_lwt_unix.Response.write ~flush:true
            (fun writer ->
              Cohttp_lwt_unix.Response.write_body writer body)
            resp agent_oc
          >>= fun () -> Lwt_io.flush agent_oc)
        (fun exn ->
          log "MITM %s: 502 write failed: %s" target.host
            (Printexc.to_string exn);
          Lwt.return_unit))

let mitm_handler ?(upstreams = []) state
    (rule : Policy.proxy_auth_rule)
    (target : Proxy_lib.connect_target)
    client_ic client_oc =
  let leaf = leaf_for state target.host in
  let config = mitm_server_config leaf in
  let injected_value =
    match render_value rule state.secrets with
    | Ok v -> v
    | Error msg -> failwith ("render template: " ^ msg)
  in
  log "MITM %s:%d (inject %s)" target.host target.port rule.header;
  write_connect_ok client_oc >>= fun () ->
  Lwt_io.flush client_oc >>= fun () ->
  Tls_lwt.Unix.server_of_channels config (client_ic, client_oc)
  >>= fun agent_tls ->
  let agent_ic, agent_oc = Tls_lwt.of_t agent_tls in
  let agent_cohttp_ic =
    Cohttp_lwt_unix.Private.Input_channel.create agent_ic
  in
  let close_agent () =
    (* [Tls_lwt.of_t]'s output channel writes encrypted bytes via
       [Lwt_io.write client_oc] — un-flushed. After
       [Tls_lwt.Unix.write] / [Lwt_io.flush agent_oc], those bytes
       sit in [client_oc]'s buffer until something forces a flush.
       The close path's [Lwt_io.close client_oc <&> close client_ic]
       runs in parallel and can race: if the input close drops the
       fd before the output flush completes, application bytes never
       make it on the wire. Flushing [client_oc] ourselves removes
       the race. *)
    Lwt.catch
      (fun () ->
        Lwt.catch
          (fun () -> Lwt_io.flush client_oc)
          (fun _ -> Lwt.return_unit)
        >>= fun () -> Tls_lwt.Unix.close agent_tls)
      (fun _ -> Lwt.return_unit)
  in
  Lwt.finalize
    (fun () ->
      Cohttp_lwt_unix.Request.read agent_cohttp_ic >>= function
      | `Eof ->
          log "MITM %s: agent EOF before request" target.host;
          Lwt.return_unit
      | `Invalid msg ->
          log "MITM %s: invalid request: %s" target.host msg;
          Lwt.return_unit
      | `Ok req ->
          let req' = Proxy_lib.inject_header req rule injected_value in
          let agent_body_reader =
            Cohttp_lwt_unix.Request.make_body_reader req agent_cohttp_ic
          in
          forward_to_upstream ~upstreams state target req' agent_body_reader agent_oc)
    close_agent
