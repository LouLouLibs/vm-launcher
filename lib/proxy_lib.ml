let parse_egress_hosts content =
  String.split_on_char '\n' content
  |> List.filter_map (fun line ->
       let trimmed = String.trim line in
       if trimmed = "" || trimmed.[0] = '#' then None
       else Some trimmed)

let ends_with_dot_prefix ~suffix ~s =
  let ls = String.length s and lt = String.length suffix in
  ls > lt
  && s.[ls - lt - 1] = '.'
  && String.lowercase_ascii (String.sub s (ls - lt) lt)
     = String.lowercase_ascii suffix

let same_host ~a ~b =
  String.lowercase_ascii a = String.lowercase_ascii b

let host_allowed ~allowlist ~host =
  List.exists
    (fun entry ->
      same_host ~a:host ~b:entry
      || ends_with_dot_prefix ~suffix:entry ~s:host)
    allowlist

type upstream_rule = {
  suffix : string;
  proxy_host : string;
  proxy_port : int;
}

let parse_upstream_rule s =
  match String.index_opt s '=' with
  | None ->
      failwith
        (Printf.sprintf "--upstream %S: expected SUFFIX=HOST:PORT" s)
  | Some i ->
      let suffix = String.sub s 0 i in
      let hostport = String.sub s (i + 1) (String.length s - i - 1) in
      (* Strip a leading '.' on suffix so [.foo.com] and [foo.com]
         both produce a [foo.com] suffix for host_allowed's domain
         check. The tinyproxy config style uses ".foo.com"; tolerate. *)
      let suffix =
        if String.length suffix > 0 && suffix.[0] = '.'
        then String.sub suffix 1 (String.length suffix - 1)
        else suffix
      in
      if suffix = "" then
        failwith
          (Printf.sprintf "--upstream %S: SUFFIX is empty" s);
      (match String.rindex_opt hostport ':' with
       | None ->
           failwith
             (Printf.sprintf
                "--upstream %S: HOST:PORT missing colon in %S" s hostport)
       | Some j ->
           let proxy_host = String.sub hostport 0 j in
           let port_str =
             String.sub hostport (j + 1) (String.length hostport - j - 1)
           in
           (match int_of_string_opt port_str with
            | None ->
                failwith
                  (Printf.sprintf "--upstream %S: bad port %S" s port_str)
            | Some proxy_port ->
                if proxy_host = "" then
                  failwith
                    (Printf.sprintf "--upstream %S: HOST is empty" s);
                { suffix; proxy_host; proxy_port }))

let pick_upstream rules host =
  List.find_opt
    (fun r ->
      same_host ~a:host ~b:r.suffix
      || ends_with_dot_prefix ~suffix:r.suffix ~s:host)
    rules

type connect_target = {
  host : string;
  port : int;
}

let parse_connect_line line =
  match String.split_on_char ' ' (String.trim line) with
  | [ method_; target; _http_ver ] ->
      if String.uppercase_ascii method_ <> "CONNECT" then None
      else
        (match String.rindex_opt target ':' with
         | None -> None
         | Some i ->
             let host = String.sub target 0 i in
             let port_str =
               String.sub target (i + 1) (String.length target - i - 1)
             in
             (match int_of_string_opt port_str with
              | Some p when host <> "" -> Some { host; port = p }
              | _ -> None))
  | _ -> None

(* ${NAME} substitution. Name charset matches POSIX shell variable
   names: [A-Za-z_][A-Za-z0-9_]*. Missing names → Error. We do NOT
   try to be clever about `$NAME` (no braces) — the proxyAuth template
   format requires braces, both for parsing clarity and to keep this
   tiny. *)
let is_name_start c =
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c = '_'

let is_name_cont c =
  is_name_start c || (c >= '0' && c <= '9')

let render_template ~template ~lookup =
  let buf = Buffer.create (String.length template) in
  let n = String.length template in
  let rec loop i =
    if i >= n then Ok ()
    else if i + 1 < n && template.[i] = '$' && template.[i + 1] = '{' then
      (* Find matching '}'. Names allow only is_name_cont chars. *)
      let j = i + 2 in
      if j >= n || not (is_name_start template.[j]) then
        Error
          (Printf.sprintf
             "invalid ${...} at offset %d: expected variable name" i)
      else
        let rec scan k =
          if k >= n then
            Error
              (Printf.sprintf
                 "unterminated ${...} starting at offset %d" i)
          else if template.[k] = '}' then
            let name = String.sub template j (k - j) in
            (match lookup name with
             | None -> Error (Printf.sprintf "undefined variable %S" name)
             | Some v ->
                 Buffer.add_string buf v;
                 loop (k + 1))
          else if is_name_cont template.[k] then scan (k + 1)
          else
            Error
              (Printf.sprintf
                 "invalid character %C in ${...} at offset %d"
                 template.[k] k)
        in
        scan j
    else
      (Buffer.add_char buf template.[i]; loop (i + 1))
  in
  match loop 0 with
  | Ok () ->
      let result = Buffer.contents buf in
      (* HTTP header values MUST NOT contain CR or LF — RFC 7230 §3.2.4
         forbids it, and Cohttp.Header.replace does not validate. A
         secret with embedded CR/LF (or unusual-but-legal contents like
         a multi-line PEM) injected into an Authorization header would
         smuggle additional headers downstream. Refuse here so the
         error surfaces at startup (validate_templates) AND on every
         live request (mitm_handler), without each caller re-checking. *)
      if String.contains result '\r' || String.contains result '\n'
      then
        Error
          "rendered value contains CR or LF — refusing to inject \
           (HTTP header values forbid CR/LF; check the secret file \
           for a trailing newline or other control chars)"
      else
        Ok result
  | Error msg -> Error msg

(* Tab-separated config line: HOST<TAB>HEADER<TAB>VALUE_TEMPLATE.
   No escape mechanism — tab is the field separator precisely because
   headers, hosts, and most template payloads never contain it. *)
let parse_proxy_auth_config_line s =
  let parts = String.split_on_char '\t' s in
  match parts with
  | [ host; header; value_template ] ->
      if host = "" then
        Error (Printf.sprintf "proxy-auth.conf line %S: empty HOST" s)
      else if header = "" then
        Error (Printf.sprintf "proxy-auth.conf line %S: empty HEADER" s)
      else
        Ok { Policy.host; header; value_template }
  | _ ->
      Error
        (Printf.sprintf
           "proxy-auth.conf line %S: expected exactly two TABs separating \
            HOST, HEADER, VALUE_TEMPLATE" s)

let parse_proxy_auth_config content =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | raw :: rest ->
        let line =
          let n = String.length raw in
          if n > 0 && raw.[n - 1] = '\r' then String.sub raw 0 (n - 1)
          else raw
        in
        if String.trim line = "" then loop acc rest
        else if line.[0] = '#' then loop acc rest
        else
          (match parse_proxy_auth_config_line line with
           | Ok r -> loop (r :: acc) rest
           | Error msg -> Error msg)
  in
  loop [] (String.split_on_char '\n' content)

(* Parse ["host=header:template"]:
     - host: everything before the FIRST '='
     - header: between that '=' and the FIRST ':' (RFC 7230 tokens
       forbid ':' inside header names — safe split)
     - template: the remainder, may contain ':' freely *)
let parse_proxy_auth_flag s =
  match String.index_opt s '=' with
  | None ->
      Error
        (Printf.sprintf
           "--proxy-auth %S: expected HOST=HEADER:VALUE_TEMPLATE" s)
  | Some i ->
      let host = String.sub s 0 i in
      let rest = String.sub s (i + 1) (String.length s - i - 1) in
      (match String.index_opt rest ':' with
       | None ->
           Error
             (Printf.sprintf
                "--proxy-auth %S: missing ':' between HEADER and VALUE_TEMPLATE"
                s)
       | Some j ->
           let header = String.sub rest 0 j in
           let value_template =
             String.sub rest (j + 1) (String.length rest - j - 1)
           in
           if host = "" then
             Error (Printf.sprintf "--proxy-auth %S: HOST is empty" s)
           else if header = "" then
             Error (Printf.sprintf "--proxy-auth %S: HEADER is empty" s)
           else
             Ok { Policy.host; header; value_template })

let pick_proxy_auth rules host =
  List.find_opt
    (fun (r : Policy.proxy_auth_rule) ->
      same_host ~a:host ~b:r.host
      || ends_with_dot_prefix ~suffix:r.host ~s:host)
    rules

(* Filenames must look like env-var names: [A-Za-z_] followed by zero
   or more [A-Za-z0-9_] characters. Stricter than POSIX so that weird
   files (CA pems, dotfiles, etc.) in a secret-dir don't quietly
   shadow real secrets. *)
let is_env_name s =
  let n = String.length s in
  if n = 0 then false
  else
    let ok = ref true in
    let c0 = s.[0] in
    if not ((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z') || c0 = '_')
    then ok := false;
    for i = 1 to n - 1 do
      let c = s.[i] in
      if not ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
              || (c >= '0' && c <= '9') || c = '_')
      then ok := false
    done;
    !ok

let inject_header (req : Http.Request.t)
    (rule : Policy.proxy_auth_rule) value =
  let headers = Http.Header.replace req.headers rule.header value in
  { req with headers }

(* Load a regular-file directory's contents into a (name → contents) map.
   Skip with a warning:
     - filenames that aren't valid POSIX env-var names (CA PEMs, dotfiles)
     - files with bits set in group/other (wider than 0600 — a deployment
       mistake, refuse rather than silently load).
   Skip silently:
     - non-regular entries (directories, symlinks-to-elsewhere, etc.).

   Trailing newline handling: strip exactly one trailing '\n'.
   [echo TOKEN > file] (the documented secret-write pattern) produces
   "TOKEN\n"; injecting that verbatim into an HTTP header value would
   either malform the request or smuggle additional headers upstream.
   Stripping one \n is enough because [render_template] later rejects
   any remaining CR/LF on render. *)
let load_secret_dir ~dir =
  let h = Hashtbl.create 16 in
  let warnings = ref [] in
  let warn fmt = Printf.ksprintf (fun s -> warnings := s :: !warnings) fmt in
  let entries =
    try Sys.readdir dir
    with Sys_error msg -> failwith (Printf.sprintf "--secret-dir %s" msg)
  in
  Array.iter
    (fun name ->
      let full = Filename.concat dir name in
      match (try Some (Unix.stat full) with _ -> None) with
      | Some st when st.st_kind = Unix.S_REG ->
          if not (is_env_name name) then
            warn "skipping secret %S (not a valid env-var name)" name
          else if st.st_perm land 0o077 <> 0 then
            warn "skipping secret %S (mode %04o is wider than 0600)"
              name st.st_perm
          else
            let raw = Util.read_file full in
            let v =
              let n = String.length raw in
              if n > 0 && raw.[n - 1] = '\n'
              then String.sub raw 0 (n - 1)
              else raw
            in
            Hashtbl.replace h name v
      | _ -> ())
    entries;
  h, List.rev !warnings
