(** MITM termination for the in-VM egress proxy.

    Given a CONNECT target that matches a configured [proxyAuth]
    rule, [mitm_handler] presents a CA-signed leaf cert to the agent,
    parses the decrypted HTTP/1.1 request, injects the configured
    header (after rendering [${NAME}] placeholders against an
    in-memory secret map), opens a fresh TLS connection to the real
    upstream with SNI + caller-provided trust, and streams the
    response back unchanged.

    The intent is to live in a binary's accept loop (see
    [bin/vm_egress_proxy.ml]) but be reachable from in-process tests
    without spawning a subprocess. *)

open Vm_launcher_lib

type mitm_state
(** Opaque session state. Constructed once per proxy run; shared by
    every handler invocation. *)

val make_state :
  ca:Proxy_ca.ca ->
  secrets:(string, string) Hashtbl.t ->
  upstream_authenticator:X509.Authenticator.t ->
  mitm_state
(** [make_state ~ca ~secrets ~upstream_authenticator] bundles the
    per-run inputs:
    - [ca]: signs on-demand leaf certs (one per hostname, cached).
    - [secrets]: name → value, used to resolve [${NAME}] in templates.
    - [upstream_authenticator]: trust anchor used when opening the
      TLS connection to the real upstream. In production this is
      [Ca_certs.authenticator ()] (system root store). In tests it
      can trust a test CA so a fake in-process upstream is reachable
      without touching the host's trust store.

    The matching of CONNECT hosts against proxyAuth rules lives in
    the caller — it determines whether to invoke [mitm_handler] at
    all and passes the matched rule directly. *)

val validate_templates :
  Policy.proxy_auth_rule list -> (string, string) Hashtbl.t ->
  (unit, string) result
(** Render every rule's [value_template] against [secrets] once at
    startup and return the FIRST error. Fail-loud before accepting
    connections so a misconfig surfaces at boot, not at first
    request. *)

val leaf_cache_size : mitm_state -> int
(** Number of leaf certs currently cached. Exposed for tests asserting
    the soft-cap eviction behavior (cache resets when it would grow
    past the in-module max). Not a production hot path. *)

val ensure_leaf : mitm_state -> string -> unit
(** Mint (or fetch from cache) the leaf cert for [host]. No-op if the
    cert already exists. Exposed solely so tests can drive the cache
    deterministically — production code reaches the same path through
    [mitm_handler]. *)

val connect_target :
  upstreams:Proxy_lib.upstream_rule list ->
  Proxy_lib.connect_target ->
  (Lwt_unix.file_descr * Lwt_io.input_channel * Lwt_io.output_channel) Lwt.t
(** Open a destination directly or through the first matching upstream
    CONNECT proxy. The caller owns the returned channels and socket.
    Failed or cancelled CONNECT negotiations close the transport. *)

val mitm_handler :
  ?upstreams:Proxy_lib.upstream_rule list ->
  mitm_state ->
  Policy.proxy_auth_rule ->
  Proxy_lib.connect_target ->
  Lwt_io.input_channel ->
  Lwt_io.output_channel ->
  unit Lwt.t
(** [mitm_handler state rule target client_ic client_oc] runs the
    full MITM exchange for a single CONNECT.

    PRECONDITIONS:
    - The CONNECT request line + headers have been FULLY consumed
      from [client_ic] by the caller (typical caller flow:
      [Lwt_io.read_line] for the request line, then drain headers
      until a blank line).
    - No bytes have been written to [client_oc] for this connection
      yet — this function writes the [200 Connection Established]
      response itself. Leaking either side will corrupt the agent's
      TLS handshake ("record overflow") because cleartext bytes will
      be interpreted as TLS frames.

    The exchange runs as:
    1. Writes [HTTP/1.1 200 Connection Established] to [client_oc].
    2. TLS-handshakes with the agent presenting a leaf for
       [target.host].
    3. Reads the decrypted HTTP/1.1 request.
    4. Replaces [rule.header] with the rendered template value
       (any existing same-named header from the agent is overwritten
       — see [Proxy_lib.inject_header]).
    5. Opens a TLS client to [target.host:target.port] with SNI,
       through a matching [upstreams] CONNECT proxy when configured.
       Certificate verification remains against the destination host.
    6. Streams the modified request upstream + the response back.

    Exceptions during the upstream half are caught and surfaced to
    the agent as [502 Bad Gateway]. The TLS sessions on both ends
    are closed unconditionally. *)
