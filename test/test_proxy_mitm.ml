(* Wire-level integration test for the phase-3b CP2 MITM path.

   What this test proves: when an HTTPS request flows through
   [Proxy_mitm.mitm_handler], the in-process fake upstream actually
   receives the configured header injection — i.e. the threat model
   holds at the byte level, not just at the OCaml-data level.

   Topology:
                        ┌───────────────┐
   test-as-agent ─────► │ mitm_handler  │ ────► fake upstream (in-process)
   (TLS 1.3, http/1.1)  └───────────────┘       (TLS 1.3, http/1.1)
                                                  │
                                                  └─► captures request bytes,
                                                      replies with synthetic
                                                      response

   One CA is shared by both directions:
   - The proxy uses it to sign its on-demand leaf for the agent side.
   - The fake upstream serves a CA-signed leaf for "localhost".
   - The proxy's upstream authenticator trusts that same CA — so we
     don't have to touch the host's trust store. *)

open Lwt.Infix
open Vm_launcher_lib

let assert_b label cond =
  if not cond then failwith (Printf.sprintf "assertion failed: %s" label)

let contains needle s =
  let nl = String.length needle and sl = String.length s in
  if nl > sl then false
  else
    let found = ref false in
    let i = ref 0 in
    while not !found && !i <= sl - nl do
      if String.sub s !i nl = needle then found := true;
      incr i
    done;
    !found

let init_rng_once = lazy (Mirage_crypto_rng_unix.use_default ())

(* Build an [X509.Authenticator.t] that trusts exactly the given CA
   cert — used for both sides so the proxy's upstream trusts our
   fake server, and the test client trusts the proxy's MITM leaf. *)
let trust_only ca_cert : X509.Authenticator.t =
  X509.Authenticator.chain_of_trust
    ~time:(fun () -> Some (Ptime_clock.now ()))
    [ ca_cert ]

(* Build a Tls.Config.server with the leaf as own cert + ALPN
   http/1.1. Used to power the fake upstream. *)
let tls_server_config_of_leaf (leaf : Proxy_ca.leaf) =
  match
    Tls.Config.server
      ~certificates:
        (`Single ([ Proxy_ca.leaf_cert leaf ], Proxy_ca.leaf_key leaf))
      ~alpn_protocols:[ "http/1.1" ]
      ()
  with
  | Ok c -> c
  | Error (`Msg m) -> failwith ("fake upstream config: " ^ m)

(* Bind an Lwt socket on 127.0.0.1:0 and return [(fd, port)]. *)
let listen_loopback () =
  let fd = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_unix.setsockopt fd Unix.SO_REUSEADDR true;
  let addr = Unix.ADDR_INET (Unix.inet_addr_loopback, 0) in
  Lwt_unix.bind fd addr >>= fun () ->
  Lwt_unix.listen fd 1;
  let port =
    match Unix.getsockname (Lwt_unix.unix_file_descr fd) with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> assert false
  in
  Lwt.return (fd, port)

(* Synthetic response the fake upstream returns. *)
let upstream_response_body = "fake-upstream-ok\n"
let upstream_response_status = `OK

(* Fake HTTPS upstream: accept one connection, do TLS, read the
   HTTP/1.1 request fully, capture it into [captured], reply with a
   small synthetic response. Returns the captured request as soon as
   the response has been sent. *)
let run_fake_upstream ?expected_connect listen_fd server_config : Http.Request.t Lwt.t =
  Lwt_unix.accept listen_fd >>= fun (cfd, _) ->
  (match expected_connect with
   | None -> Lwt.return_unit
   | Some expected ->
       (* Read exactly the CONNECT headers before switching this socket
          to TLS. The client cannot start TLS until we send the 200. *)
       let headers = Buffer.create 128 in
       let byte = Bytes.create 1 in
       let rec read () =
         Lwt_unix.read cfd byte 0 1 >>= fun n ->
         if n = 0 then Lwt.fail_with "EOF before CONNECT headers"
         else begin
           Buffer.add_char headers (Bytes.get byte 0);
           if String.ends_with ~suffix:"\r\n\r\n" (Buffer.contents headers)
           then Lwt.return_unit else read ()
         end
       in
       read () >>= fun () ->
       assert_b "CONNECT uses destination authority"
         (String.starts_with ~prefix:("CONNECT " ^ expected ^ " HTTP/1.1\r\n")
            (Buffer.contents headers));
       let response = Bytes.of_string "HTTP/1.1 200 Connection Established\r\n\r\n" in
       let rec write off =
         if off = Bytes.length response then Lwt.return_unit
         else Lwt_unix.write cfd response off (Bytes.length response - off)
           >>= fun n -> write (off + n)
       in
       write 0)
  >>= fun () ->
  Tls_lwt.Unix.server_of_fd server_config cfd >>= fun tls ->
  let ic, oc = Tls_lwt.of_t tls in
  let cohttp_ic =
    Cohttp_lwt_unix.Private.Input_channel.create ic
  in
  Cohttp_lwt_unix.Request.read cohttp_ic >>= fun result ->
  match result with
  | `Eof -> Lwt.fail_with "fake upstream: agent EOF"
  | `Invalid msg ->
      Lwt.fail_with ("fake upstream: invalid request: " ^ msg)
  | `Ok req ->
      let body_reader =
        Cohttp_lwt_unix.Request.make_body_reader req cohttp_ic
      in
      (* Drain any body so the connection state is well-defined,
         then reply with the synthetic response. *)
      let rec drain_body () =
        match Cohttp.Request.encoding req with
        | Cohttp.Transfer.Unknown -> Lwt.return_unit
        | Cohttp.Transfer.Fixed _ | Cohttp.Transfer.Chunked ->
            Cohttp_lwt_unix.Request.read_body_chunk body_reader
            >>= function
            | Done -> Lwt.return_unit
            | Final_chunk _ -> Lwt.return_unit
            | Chunk _ -> drain_body ()
      in
      drain_body () >>= fun () ->
      let resp =
        Http.Response.make
          ~status:upstream_response_status
          ~headers:
            (Http.Header.of_list
               [
                 ("Content-Length",
                  string_of_int (String.length upstream_response_body));
                 ("Connection", "close");
               ])
          ()
      in
      Cohttp_lwt_unix.Response.write ~flush:true
        (fun writer ->
          Cohttp_lwt_unix.Response.write_body writer upstream_response_body)
        resp oc
      >>= fun () ->
      Lwt_io.flush oc >>= fun () ->
      (* Close cleanly so the proxy's body reader sees EOF. *)
      Lwt.catch (fun () -> Tls_lwt.Unix.close tls)
        (fun _ -> Lwt.return_unit)
      >>= fun () ->
      Lwt.return req

(* Test client: reads the 200 Connection Established that
   [mitm_handler] writes unprompted (in production the caller would
   have already parsed the CONNECT — we skip the CONNECT exchange
   entirely since we're calling [mitm_handler] directly), does the
   TLS handshake trusting [ca_cert], sends a GET for [path], and
   returns the full response body as a string.

   [client_fd] is the *client*-side end of the socketpair — i.e. the
   fd via which we talk TO the proxy. *)
let run_test_client client_fd ca_cert ~target_host ~path =
  let proxy_ic = Lwt_io.of_fd ~mode:Lwt_io.input client_fd in
  let proxy_oc = Lwt_io.of_fd ~mode:Lwt_io.output client_fd in
  (* Step 1: read 200 status + headers up to blank line. Must drain
     these BEFORE TLS, otherwise the leftover bytes confuse the TLS
     engine on the proxy side ("record overflow"). *)
  Lwt_io.read_line proxy_ic >>= fun status_line ->
  assert_b
    (Printf.sprintf "200 status line %S contains 200" status_line)
    (contains "200" status_line);
  let rec drain_headers () =
    Lwt_io.read_line proxy_ic >>= function
    | "" | "\r" -> Lwt.return_unit
    | _ -> drain_headers ()
  in
  drain_headers () >>= fun () ->
  (* Step 2: TLS handshake with the proxy. Trust [ca_cert] so the
     proxy's on-demand leaf for [target_host] validates. SNI must be
     [target_host]. *)
  let host_dn =
    Domain_name.of_string_exn target_host
    |> Domain_name.host_exn
  in
  let client_config =
    match
      Tls.Config.client
        ~authenticator:(trust_only ca_cert)
        ~alpn_protocols:[ "http/1.1" ]
        ()
    with
    | Ok c -> c
    | Error (`Msg m) -> failwith ("test client config: " ^ m)
  in
  Tls_lwt.Unix.client_of_channels client_config
    ~host:host_dn (proxy_ic, proxy_oc)
  >>= fun tls ->
  let tls_ic, tls_oc = Tls_lwt.of_t tls in
  (* Step 4: GET *)
  let get_req =
    Printf.sprintf
      "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: vm-egress-proxy-mitm-test\r\nAccept: */*\r\n\r\n"
      path target_host
  in
  Lwt_io.write tls_oc get_req >>= fun () ->
  Lwt_io.flush tls_oc >>= fun () ->
  (* Step 5: read response with cohttp so we don't have to parse
     content-length / transfer-encoding by hand. *)
  let cohttp_ic =
    Cohttp_lwt_unix.Private.Input_channel.create tls_ic
  in
  Cohttp_lwt_unix.Response.read cohttp_ic >>= function
  | `Eof -> Lwt.fail_with "client: upstream EOF before response"
  | `Invalid msg ->
      Lwt.fail_with ("client: invalid response: " ^ msg)
  | `Ok resp ->
      let buf = Buffer.create 64 in
      let body_reader =
        Cohttp_lwt_unix.Response.make_body_reader resp cohttp_ic
      in
      let rec read_body () =
        Cohttp_lwt_unix.Response.read_body_chunk body_reader
        >>= function
        | Done -> Lwt.return_unit
        | Final_chunk s -> Buffer.add_string buf s; Lwt.return_unit
        | Chunk s -> Buffer.add_string buf s; read_body ()
      in
      read_body () >>= fun () ->
      Lwt.catch (fun () -> Tls_lwt.Unix.close tls)
        (fun _ -> Lwt.return_unit)
      >>= fun () ->
      Lwt.return (resp, Buffer.contents buf)

(* The actual test. *)
let test_mitm_threat_model ?(via_proxy = false) () =
  Lazy.force init_rng_once;
  let ca = Proxy_ca.generate_ca ~common_name:"test-ca" () in
  let ca_cert =
    match X509.Certificate.decode_pem (Proxy_ca.ca_cert_pem ca) with
    | Ok c -> c
    | Error (`Msg m) -> failwith m
  in
  (* The fake upstream serves an authentic-ish cert for "localhost".
     The proxy's on-demand leaf for "localhost" is a different cert,
     signed by the same CA. *)
  let upstream_leaf =
    Proxy_ca.generate_leaf ~ca ~hostname:"localhost"
  in
  let server_config = tls_server_config_of_leaf upstream_leaf in
  let secrets = Hashtbl.create 1 in
  Hashtbl.add secrets "TEST_SECRET" "the-secret-value-42";
  let rule =
    {
      Policy.host = "localhost";
      header = "X-Test-Injection";
      value_template = "Bearer ${TEST_SECRET}";
    }
  in
  let upstream_authenticator = trust_only ca_cert in
  let state =
    Proxy_mitm.make_state ~ca ~secrets ~upstream_authenticator
  in
  Lwt_main.run
    ( (* Bind the fake upstream. *)
      listen_loopback () >>= fun (upstream_fd, upstream_port) ->
      Lwt.finalize
        (fun () ->
          let upstream_captured = run_fake_upstream
            ?expected_connect:(if via_proxy then Some "localhost:1" else None)
            upstream_fd server_config in
          (* Build a connected socket pair the proxy and the test
             client share. proxy_side feeds [mitm_handler]; client_side
             is the agent. *)
          let proxy_side, client_side = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
          let proxy_ic = Lwt_io.of_fd ~mode:Lwt_io.input proxy_side in
          let proxy_oc = Lwt_io.of_fd ~mode:Lwt_io.output proxy_side in
          let target =
            { Proxy_lib.host = "localhost"; port = if via_proxy then 1 else upstream_port }
          in
          let upstreams = if via_proxy then
            [{ Proxy_lib.suffix = "localhost"; proxy_host = "127.0.0.1";
               proxy_port = upstream_port }]
            else [] in
          let handler_task =
            Proxy_mitm.mitm_handler ~upstreams state rule target proxy_ic proxy_oc
          in
          let client_task =
            run_test_client client_side ca_cert
              ~target_host:"localhost"
              ~path:"/test"
          in
          Lwt.pick [
            Lwt.join [ handler_task; Lwt.map ignore client_task ];
            (Lwt_unix.sleep 10. >>= fun () -> Lwt.fail_with "MITM exchange timeout")
          ] >>= fun () ->
          upstream_captured >>= fun req ->
          (* The crux: did the injection actually go over the wire? *)
          let injected =
            Http.Header.get req.headers "X-Test-Injection"
          in
          assert_b "fake upstream received the injected header"
            (injected = Some "Bearer the-secret-value-42");
          (* And basic sanity on the captured request. *)
          assert_b "method preserved" (req.meth = `GET);
          assert_b "resource preserved" (req.resource = "/test");
          assert_b "Host header forwarded"
            (Http.Header.get req.headers "Host" = Some "localhost");
          (* Run again to verify the client got the synthetic body
             back through the MITM unchanged. *)
          client_task >>= fun (resp, body) ->
          assert_b "client saw upstream's status"
            (resp.status = upstream_response_status);
          assert_b "client got upstream's body unchanged"
            (body = upstream_response_body);
          Lwt.return_unit)
        (fun () ->
          Lwt.catch (fun () -> Lwt_unix.close upstream_fd)
            (fun _ -> Lwt.return_unit)) )

let test_mitm_overwrites_agent_supplied_header () =
  (* Threat-model regression: if the agent crafts its own
     X-Test-Injection header in the request, the proxy MUST overwrite
     it — never let the agent's value reach the upstream. *)
  Lazy.force init_rng_once;
  let ca = Proxy_ca.generate_ca () in
  let ca_cert =
    match X509.Certificate.decode_pem (Proxy_ca.ca_cert_pem ca) with
    | Ok c -> c
    | Error (`Msg m) -> failwith m
  in
  let upstream_leaf =
    Proxy_ca.generate_leaf ~ca ~hostname:"localhost"
  in
  let server_config = tls_server_config_of_leaf upstream_leaf in
  let secrets = Hashtbl.create 1 in
  Hashtbl.add secrets "REAL" "real-token";
  let rule =
    {
      Policy.host = "localhost";
      header = "X-Test-Injection";
      value_template = "Bearer ${REAL}";
    }
  in
  let state =
    Proxy_mitm.make_state ~ca ~secrets
      ~upstream_authenticator:(trust_only ca_cert)
  in
  Lwt_main.run
    ( listen_loopback () >>= fun (upstream_fd, upstream_port) ->
      Lwt.finalize
        (fun () ->
          let upstream_captured = run_fake_upstream upstream_fd server_config in
          let proxy_side, client_side = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
          let proxy_ic = Lwt_io.of_fd ~mode:Lwt_io.input proxy_side in
          let proxy_oc = Lwt_io.of_fd ~mode:Lwt_io.output proxy_side in
          let target =
            { Proxy_lib.host = "localhost"; port = upstream_port }
          in
          let handler_task =
            Proxy_mitm.mitm_handler state rule target proxy_ic proxy_oc
          in
          (* This client does the CONNECT + TLS, then sends a GET that
             tries to set X-Test-Injection itself. *)
          let attacker_get_req path target_host =
            Printf.sprintf
              "GET %s HTTP/1.1\r\nHost: %s\r\nX-Test-Injection: Bearer ATTACKER-VALUE\r\n\r\n"
              path target_host
          in
          let attacker_client () =
            let proxy_ic2 = Lwt_io.of_fd ~mode:Lwt_io.input client_side in
            let proxy_oc2 = Lwt_io.of_fd ~mode:Lwt_io.output client_side in
            Lwt_io.read_line proxy_ic2 >>= fun _ ->
            let rec drain () =
              Lwt_io.read_line proxy_ic2 >>= function
              | "" | "\r" -> Lwt.return_unit
              | _ -> drain ()
            in
            drain () >>= fun () ->
            let cfg =
              match
                Tls.Config.client
                  ~authenticator:(trust_only ca_cert)
                  ~alpn_protocols:[ "http/1.1" ] ()
              with
              | Ok c -> c
              | Error (`Msg m) -> failwith m
            in
            let host_dn =
              Domain_name.of_string_exn "localhost"
              |> Domain_name.host_exn
            in
            Tls_lwt.Unix.client_of_channels cfg ~host:host_dn
              (proxy_ic2, proxy_oc2)
            >>= fun tls ->
            let _tls_ic, tls_oc = Tls_lwt.of_t tls in
            Lwt_io.write tls_oc (attacker_get_req "/p" "localhost")
            >>= fun () -> Lwt_io.flush tls_oc
          in
          Lwt.join [ handler_task; attacker_client () ] >>= fun () ->
          upstream_captured >>= fun req ->
          let injected =
            Http.Header.get req.headers "X-Test-Injection"
          in
          (* Real injected value, NOT the attacker's *)
          assert_b "agent's value overwritten by proxy"
            (injected = Some "Bearer real-token");
          assert_b "no leak of attacker value through duplicate headers"
            (not
               (List.exists
                  (fun v -> contains "ATTACKER" v)
                  (Http.Header.get_multi req.headers "X-Test-Injection")));
          Lwt.return_unit)
        (fun () ->
          Lwt.catch (fun () -> Lwt_unix.close upstream_fd)
            (fun _ -> Lwt.return_unit)) )

let test_mitm_validate_templates () =
  (* validate_templates returns the first error, not just any error,
     and surfaces enough info for an operator to fix the misconfig. *)
  let secrets = Hashtbl.create 2 in
  Hashtbl.add secrets "PRESENT" "x";
  let rules =
    [
      {
        Policy.host = "h1";
        header = "H1";
        value_template = "Bearer ${PRESENT}";
      };
      {
        Policy.host = "h2";
        header = "H2";
        value_template = "Bearer ${MISSING}";
      };
      {
        Policy.host = "h3";
        header = "H3";
        value_template = "Bearer ${ALSO_MISSING}";
      };
    ]
  in
  match Proxy_mitm.validate_templates rules secrets with
  | Ok () -> failwith "expected Error"
  | Error msg ->
      assert_b "names the host" (contains "h2" msg);
      assert_b "names the header" (contains "H2" msg);
      assert_b "names the missing variable" (contains "MISSING" msg);
      assert_b "stops at first error"
        (not (contains "ALSO_MISSING" msg));
      assert_b "first rule succeeded" (not (contains "h1" msg))

(* Exercise the upstream-handshake timeout: the fake upstream accepts
   the TCP connection but never does the TLS handshake. The proxy's
   [with_timeout] around [Tls_lwt.Unix.client_of_fd] should fire,
   bubble out as a 502, and the agent should see Bad Gateway in
   well under 10 seconds. *)
let test_mitm_upstream_timeout () =
  Lazy.force init_rng_once;
  let ca = Proxy_ca.generate_ca () in
  let ca_cert =
    match X509.Certificate.decode_pem (Proxy_ca.ca_cert_pem ca) with
    | Ok c -> c
    | Error (`Msg m) -> failwith m
  in
  let secrets = Hashtbl.create 1 in
  Hashtbl.add secrets "K" "v";
  let rule =
    { Policy.host = "localhost"; header = "X-T"; value_template = "${K}" }
  in
  let state =
    Proxy_mitm.make_state ~ca ~secrets
      ~upstream_authenticator:(trust_only ca_cert)
  in
  Lwt_main.run
    ( listen_loopback () >>= fun (upstream_fd, upstream_port) ->
      Lwt.finalize
        (fun () ->
          (* Black-hole: accept then sit forever. *)
          let hanging_upstream =
            Lwt_unix.accept upstream_fd >>= fun (cfd, _) ->
            (* Hold the connection open past the test's deadline. *)
            Lwt_unix.sleep 30.0 >>= fun () ->
            Lwt_unix.close cfd
          in
          let proxy_side, client_side =
            Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0
          in
          let proxy_ic = Lwt_io.of_fd ~mode:Lwt_io.input proxy_side in
          let proxy_oc = Lwt_io.of_fd ~mode:Lwt_io.output proxy_side in
          let target =
            { Proxy_lib.host = "localhost"; port = upstream_port }
          in
          let started = Unix.gettimeofday () in
          let handler_task =
            Proxy_mitm.mitm_handler state rule target proxy_ic proxy_oc
          in
          let client_task =
            run_test_client client_side ca_cert
              ~target_host:"localhost" ~path:"/"
          in
          Lwt.join [ handler_task; Lwt.map ignore client_task ]
          >>= fun () ->
          let elapsed = Unix.gettimeofday () -. started in
          (* The handshake timeout is 5s in lib/proxy_mitm. Allow
             generous slack for CI jitter but bound it well below
             the hanging_upstream sleep so a regression that drops
             the timeout is loud. *)
          assert_b
            (Printf.sprintf "elapsed %.1fs <= 10s (timeout fires)" elapsed)
            (elapsed <= 10.0);
          client_task >>= fun (resp, _body) ->
          assert_b "agent got 502 Bad Gateway from the timeout path"
            (resp.status = `Bad_gateway);
          Lwt.cancel hanging_upstream;
          Lwt.return_unit)
        (fun () ->
          Lwt.catch (fun () -> Lwt_unix.close upstream_fd)
            (fun _ -> Lwt.return_unit)) )

(* Leaf-cache soft cap: the cache evicts (resets) when it would grow
   past the in-module max. Without that, an agent enumerating a wide
   *.example.com would grow the table without bound. We probe the
   cap by behavior: mint distinct-host leaves one at a time, observe
   when [leaf_cache_size] drops back to 1. *)
let test_leaf_cache_evicts_at_soft_cap () =
  Lazy.force init_rng_once;
  let ca = Proxy_ca.generate_ca () in
  let secrets = Hashtbl.create 0 in
  (* The authenticator is stored in mitm_state but this test never
     opens an upstream TLS connection — make_state just keeps it
     around for the live forward path. Using the test's own CA
     instead of Ca_certs.authenticator () so the test runs inside
     the Nix build sandbox (which has no system trust store). *)
  let ca_cert =
    match X509.Certificate.decode_pem (Proxy_ca.ca_cert_pem ca) with
    | Ok c -> c
    | Error (`Msg m) -> failwith ("decode CA PEM: " ^ m)
  in
  let authenticator = trust_only ca_cert in
  let state =
    Proxy_mitm.make_state ~ca ~secrets ~upstream_authenticator:authenticator
  in
  let rec mint_until_reset n =
    Proxy_mitm.ensure_leaf state (Printf.sprintf "h%d.test" n);
    let sz = Proxy_mitm.leaf_cache_size state in
    if sz = 1 && n > 0 then n
    else if n > 1024 then
      failwith "cache grew past 1024 — eviction never fired"
    else mint_until_reset (n + 1)
  in
  let reset_at = mint_until_reset 0 in
  assert_b
    (Printf.sprintf
       "cache reset within sane bound (got %d distinct hosts before reset)"
       reset_at)
    (reset_at >= 8 && reset_at <= 1024);
  Proxy_mitm.ensure_leaf state "after-reset.test";
  let sz = Proxy_mitm.leaf_cache_size state in
  assert_b
    (Printf.sprintf "post-reset cache size grows again (got %d)" sz)
    (sz = 2);
  (* Repeated hits on the same host don't grow the cache. *)
  Proxy_mitm.ensure_leaf state "after-reset.test";
  Proxy_mitm.ensure_leaf state "after-reset.test";
  let sz2 = Proxy_mitm.leaf_cache_size state in
  assert_b
    (Printf.sprintf "hot-key reuse, size still %d" sz2)
    (sz2 = sz)

let cases =
  [
    "mitm-validate-templates", test_mitm_validate_templates;
    "mitm-threat-model-end-to-end", (fun () -> test_mitm_threat_model ());
    "mitm-through-upstream", (fun () -> test_mitm_threat_model ~via_proxy:true ());
    "mitm-overwrites-agent-supplied-header",
      test_mitm_overwrites_agent_supplied_header;
    "mitm-upstream-timeout", test_mitm_upstream_timeout;
    "mitm-leaf-cache-evicts-at-soft-cap",
      test_leaf_cache_evicts_at_soft_cap;
  ]

let () =
  let failed = ref 0 in
  List.iter
    (fun (name, f) ->
      try
        f ();
        Printf.printf "ok    %s\n" name
      with
      | Failure msg ->
          incr failed;
          Printf.printf "FAIL  %s: %s\n" name msg
      | e ->
          incr failed;
          Printf.printf "FAIL  %s: unexpected exception: %s\n"
            name (Printexc.to_string e))
    cases;
  if !failed > 0 then exit 1
