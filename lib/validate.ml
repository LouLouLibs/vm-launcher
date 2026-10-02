let log fmt = Util.log_warn fmt

let nix_string_escape s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter
    (fun c ->
      match c with
      | '"'  -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      (* Defang ${...} interpolation: a tool name like "${foo}" would
         otherwise be evaluated as a Nix expression at eval time. *)
      | '$'  -> Buffer.add_string buf "\\$"
      | c    -> Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"';
  Buffer.contents buf

let build_tools_expr ~flake ~tools =
  let names = String.concat " " (List.map nix_string_escape tools) in
  let attr = Util.nixos_config_attr () in
  Printf.sprintf
    "let \
       flake = builtins.getFlake %s; \
       pkgs = flake.nixosConfigurations.%s.pkgs; \
     in builtins.filter (n: !(builtins.hasAttr n pkgs)) [ %s ]"
    (nix_string_escape flake) attr names

(* --- policy.resources.memMb vs host memory --- *)

let meminfo_field ~field contents =
  (* /proc/meminfo lines look like "MemTotal:       65329788 kB". *)
  let prefix = field ^ ":" in
  String.split_on_char '\n' contents
  |> List.find_map (fun line ->
       if not (String.starts_with ~prefix line) then None
       else
         let rest =
           String.sub line (String.length prefix)
             (String.length line - String.length prefix)
         in
         match
           String.split_on_char ' ' rest
           |> List.filter (fun s -> s <> "")
         with
         | kb :: _ -> int_of_string_opt kb
         | [] -> None)

let host_memory ?(meminfo_path = "/proc/meminfo") ~mem_mb () =
  let contents =
    (* In_channel.input_all, not in_channel_length: /proc files stat
       as zero-length. *)
    try
      let ic = open_in meminfo_path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () -> In_channel.input_all ic)
    with _ -> ""
  in
  match meminfo_field ~field:"MemTotal" contents with
  | None ->
    log
      "policy.resources.memMb: could not read MemTotal from %s; \
       skipping host-memory check"
      meminfo_path
  | Some total_kb ->
    let total_mb = total_kb / 1024 in
    if mem_mb > total_mb then
      failwith
        (Printf.sprintf
           "policy.resources.memMb = %d MB exceeds host MemTotal \
            (%d MB). Guest memory is faulted in lazily, so the VM \
            would boot — and then the host kernel would OOM-kill \
            cloud-hypervisor the moment the guest touches more \
            memory than the host can back, taking the whole VM \
            down mid-run. Lower memMb below the host's physical RAM."
           mem_mb total_mb)
    else
      (match meminfo_field ~field:"MemAvailable" contents with
       | Some avail_kb when mem_mb > avail_kb / 1024 ->
         log
           "warning: policy.resources.memMb = %d MB exceeds host \
            MemAvailable (%d MB of %d MB). If the guest faults in \
            more memory than the host can free, the host kernel \
            will OOM-kill cloud-hypervisor and the VM dies mid-run."
           mem_mb (avail_kb / 1024) total_mb
       | _ -> ())

(* --- virtiofs share sources must be directories, not files --- *)

(* Every work.readOnly subpath, inputs entry, and shares source
   becomes a virtiofs share in the guest. virtiofs shares a
   *directory* tree, so a source pointing at a regular file passes
   the host existence check yet makes the guest mount a dir-fs onto a
   file mountpoint: the .mount unit fails, local-fs.target fails, and
   the guest drops into emergency mode where (root locked,
   security.sudo.enable = false) sulogin blocks forever — a hang with
   no host-visible diagnostic.

   These sources are pure host-path properties of the policy, so we
   can catch the misconfiguration here in milliseconds instead of
   after a multi-GB nix build + a full guest boot. Conservative by
   the best-effort contract: we raise ONLY on the certain case (the
   path exists AND is a regular file). Non-existence is left to the
   existing post-build share-source check in Boot, which resolves the
   runner's manifest and already reports a missing source. *)
let share_sources ~project ~read_only ~inputs ~shares =
  let resolve base p =
    if Filename.is_relative p then Filename.concat base p else p
  in
  let entries =
    List.map (fun sub -> ("work.readOnly entry " ^ sub, resolve project sub)) read_only
    @ List.map (fun p -> ("inputs entry " ^ p, p)) inputs
    @ List.map
        (fun (s : Policy.share) ->
          ("shares entry " ^ s.Policy.source, resolve project s.Policy.source))
        shares
  in
  List.iter
    (fun (label, source) ->
      (* file_exists follows symlinks and is false for broken ones,
         so it guards is_directory (which raises on a dangling path). *)
      if Sys.file_exists source && not (Sys.is_directory source) then
        failwith
          (Printf.sprintf
             "%s resolves to %s, which is a regular file, not a \
              directory. work.readOnly / inputs / shares entries each \
              become a virtiofs share, and virtiofs shares a directory \
              tree: a file there passes the host existence check but \
              fails the guest mount, which fails local-fs.target and \
              drops the VM into emergency mode where (root locked) it \
              hangs with no host-visible diagnostic. Point it at a \
              directory, or remove the entry."
             label source))
    entries

let tools ~flake ~tools =
  match tools with
  | [] -> ()
  | _ ->
    let expr = build_tools_expr ~flake ~tools in
    let status, out =
      try
        Util.subprocess_capture_stdout
          ~stdin_dev_null:true
          ~prog:"nix"
          ~args:[| "nix"; "eval"; "--impure"; "--json"; "--expr"; expr |]
          ()
      with e ->
        log
          "policy.tools: validation spawn failed (%s); skipping \
           \xe2\x80\x94 nix build will still surface any bad names"
          (Printexc.to_string e);
        Unix.WEXITED 0, "[]"
    in
    match status with
    | Unix.WEXITED 0 ->
      let trimmed = String.trim out in
      let json =
        try Some (Yojson.Safe.from_string trimmed)
        with _ -> None
      in
      (match json with
       | None ->
         log
           "policy.tools: validation returned unparseable output; \
            skipping (nix build will still surface any bad names)"
       | Some (`List []) -> ()
       | Some (`List items) ->
         let names =
           List.filter_map
             (function `String s -> Some s | _ -> None)
             items
         in
         let quoted =
           String.concat ", " (List.map (Printf.sprintf "'%s'") names)
         in
         failwith
           (Printf.sprintf
              "policy.tools: no attribute %s in the guest's overlaid \
               pkgs. Fix the typo, or add the package as an overlay \
               on the guest's nixosConfiguration."
              quoted)
       | Some _ ->
         log
           "policy.tools: validation returned unexpected JSON shape; \
            skipping (nix build will still surface any bad names)")
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
      log
        "policy.tools: validation exited non-zero; skipping \
         \xe2\x80\x94 nix build will still surface any bad names"
