(** Pure helpers for the egress proxy ([bin/vm_egress_proxy.ml]).

    The IO + Lwt loop lives in the binary; the matching / parsing
    semantics live here so tests can fingerprint them without a
    socket. *)

val parse_egress_hosts : string -> string list
(** Parse the [egress-hosts] file contents: one hostname per line.
    Blank lines and lines starting with [#] are skipped. Leading /
    trailing whitespace per line is trimmed. *)

val host_allowed : allowlist:string list -> host:string -> bool
(** Domain-suffix match, case-insensitive: [host] is allowed iff some
    entry [e] in [allowlist] satisfies [host = e] OR [host] ends with
    ["." ^ e]. Prevents the [evil-api.anthropic.com] superstring class
    of bypass that a naive [String.suffix] would allow.

    Note: stricter than tinyproxy's regex-line semantics — the bash
    launcher's [/etc/vm-launcher/egress-hosts] entries are already plain
    hostnames in practice, so this is "drop-in with security hardening". *)

type upstream_rule = {
  suffix : string;
  proxy_host : string;
  proxy_port : int;
}

val parse_upstream_rule : string -> upstream_rule
(** Parse ["SUFFIX=HOST:PORT"] (e.g. [".example.ts.net=10.42.0.1:1055"]).
    Raises [Failure] with a descriptive message on malformed input. *)

val pick_upstream : upstream_rule list -> string -> upstream_rule option
(** [pick_upstream rules host] returns the first rule whose [suffix]
    matches [host] via the same domain-suffix rule as [host_allowed].
    Order matters: earlier rules win.

    [None] means "no upstream — connect directly to the target". *)

type connect_target = {
  host : string;
  port : int;
}

val parse_connect_line : string -> connect_target option
(** Parse the HTTP CONNECT request line — ["CONNECT host:port HTTP/1.1"].
    Returns [None] for any other method or malformed shape. Liberal
    about HTTP version, strict about the method name and target
    structure (must be exactly [host:port] with non-empty host and a
    numeric port). *)

val render_template :
  template:string -> lookup:(string -> string option) ->
  (string, string) result
(** Substitute [${NAME}] placeholders in [template] using [lookup].
    Names follow POSIX shell rules ([[A-Za-z_][A-Za-z0-9_]*]). Returns
    [Error] on the first undefined variable or on malformed
    [${...}] syntax. No-op for templates without [${...}]. *)

val parse_proxy_auth_config_line :
  string -> (Policy.proxy_auth_rule, string) result
(** Parse one line of [etc/proxy-auth.conf] — exactly two TAB-separated
    fields followed by the value template:
    {v HOST<TAB>HEADER<TAB>VALUE_TEMPLATE v}
    The template field may be empty; host and header must be non-empty.
    Returns [Error _] if the line doesn't have exactly two tabs or if
    host/header is blank. Callers should strip [#]-comments + blank
    lines before invoking this (cf. [parse_egress_hosts]). *)

val parse_proxy_auth_config :
  string -> (Policy.proxy_auth_rule list, string) result
(** Parse the full content of [etc/proxy-auth.conf]: split into lines,
    tolerate trailing CR (CRLF endings), skip blank lines and
    [#]-prefixed comment lines, parse the remainder via
    [parse_proxy_auth_config_line]. Returns [Error _] on the first
    malformed line (the error message includes the offending line). *)

val parse_proxy_auth_flag :
  string -> (Policy.proxy_auth_rule, string) result
(** Parse the CLI form ["HOST=HEADER:VALUE_TEMPLATE"], e.g.
    ["httpbin.org=Authorization:Bearer ${MY_API_KEY}"]. Splits on the
    FIRST [=] and the FIRST [:] in the remainder — header names are
    RFC 7230 tokens and cannot contain [:], so the [VALUE_TEMPLATE]
    may. Returns [Error msg] for empty host/header or missing
    separators. *)

val pick_proxy_auth :
  Policy.proxy_auth_rule list -> string -> Policy.proxy_auth_rule option
(** [pick_proxy_auth rules host] returns the first rule whose [host]
    matches via the same domain-suffix rule as [host_allowed]. *)

val is_env_name : string -> bool
(** Whether a string is a valid POSIX-shell variable name
    ([[A-Za-z_][A-Za-z0-9_]*]). Used to filter the contents of
    [--secret-dir] so that incidental files (CA pems, dotfiles)
    don't quietly shadow real secrets. *)

val inject_header :
  Http.Request.t -> Policy.proxy_auth_rule -> string -> Http.Request.t
(** Replace [rule.header] in [req]'s headers with [value]. Adds the
    header if absent, OVERWRITES if present — this is the threat
    model: an agent setting its own [Authorization] value must not
    poison the upstream call. Other headers / method / URI preserved. *)

val load_secret_dir :
  dir:string -> (string, string) Hashtbl.t * string list
(** [load_secret_dir ~dir] reads [dir]'s regular-file entries into a
    [name → contents] map. Returns [(map, warnings)]; the warnings list
    is the human-readable reasons for skipped entries (callers log them).

    - Filenames that aren't valid POSIX env-var names (e.g. [ca.pem],
      dotfiles) are skipped + warned. Guards against incidental files
      shadowing real secrets.
    - Files with bits set in group/other (mode > 0600) are skipped +
      warned. Refuses rather than silently loads — a wider mode is a
      deployment mistake, and silent loading would defeat the
      proxy-only secret model.
    - Non-regular entries (subdirs, symlinks to other things) are
      skipped silently.
    - For loaded files: strip exactly one trailing [\n].
      [echo TOKEN > file] is the documented write pattern; the trailing
      newline must not survive into header values.

    Raises [Failure] if [dir] can't be read. *)
