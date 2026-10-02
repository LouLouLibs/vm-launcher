(* vm-launcher ls — read the global session registry + live state
   dirs and print a table. Keep this module IO-only and printf-driven;
   the logic is mostly plumbing.

   The two truths reconciled here:
     - <xdg>/microvm/sessions/<id>/manifest.json
         Canonical metadata for every launch (the launcher writes
         this once, during boot). May outlive the VM.
     - <state_base>/session-<pid>/etc/session-id
         Staged inside each LIVE state dir. We use it to discover
         which IDs are still running by walking /run/vm-launcher and
         reading the file back.

   Cross-reference: a manifest with no matching live state dir = ran
   before, now gone (state = "exited"). A live state dir whose
   session-id matches a known manifest = running. A live state dir
   without a manifest is unusual but possible (manifest writer
   crashed mid-launch); we surface it with an empty project. *)

let readdir_opt path =
  try Some (Sys.readdir path) with _ -> None

(* Live state dirs: /run/vm-launcher/session-<pid>/etc/session-id.
   Return [(pid, session_id)] for every readable entry; skip the
   noise (current-session symlink, half-staged dirs without
   session-id yet, dirs not matching session-<n>). *)
let live_sessions state_base =
  match readdir_opt state_base with
  | None -> []
  | Some entries ->
      Array.to_list entries
      |> List.filter_map (fun name ->
           (* Strip the "session-" prefix; the remainder must be all
              digits to count. *)
           if not (String.length name > 8
                   && String.sub name 0 8 = "session-")
           then None
           else
             let suffix =
               String.sub name 8 (String.length name - 8)
             in
             match int_of_string_opt suffix with
             | None -> None
             | Some pid ->
                 let sid_path =
                   Printf.sprintf "%s/%s/etc/session-id" state_base name
                 in
                 (match Util.read_file_opt sid_path with
                  | None -> None
                  | Some s ->
                      let id = String.trim s in
                      if id = "" then None else Some (pid, id)))

(* Check if a process is still alive without killing it. [kill 0 pid]
   raises ESRCH if not — exactly what we want as a presence probe. *)
(* The VM's liveness is its RUNNER, never its launcher.

   A detached session outlives its launcher by design. A foreground one
   can too, involuntarily: kill the launcher and cloud-hypervisor keeps
   serving the guest. Either way, judging by the launcher pid says
   "stale" about a live machine — and `clean` acts on that by killing
   the virtiofsds and deleting the state dir underneath a running
   guest. So ask attach.json, which now records the runner pid for
   every boot. *)
(* A bare `kill 0` proves a pid EXISTS, not that it is still our VM.
   Pids recycle, and the consequences here are real: `down` SIGKILLs
   this pid, and a recycled one in a slot marker pins the slot busy
   forever. Check /proc identity, the same way Clean.pid_is_virtiofsd
   already does for the daemons. microvm-run execs cloud-hypervisor
   with argv[0] "microvm@<name>". *)
let pid_is_runner pid =
  match Util.read_proc_opt (Printf.sprintf "/proc/%d/cmdline" pid) with
  | None -> false
  | Some c ->
      let argv0 =
        match String.index_opt c '\000' with
        | Some i -> String.sub c 0 i
        | None -> c
      in
      let base = Filename.basename argv0 in
      base = "microvm-run" || base = "cloud-hypervisor"
      || (String.length base >= 7 && String.sub base 0 7 = "microvm")

let runner_alive ~state_base ~pid =
  let state_dir = Printf.sprintf "%s/session-%d" state_base pid in
  match Ssh.read ~state_dir with
  | Some a -> a.runner_pid > 0 && pid_is_runner a.runner_pid
  | None -> false

(* Kept as the detached-specific question: alive AND meant to outlive
   its launcher. *)
let detached_runner_alive ~state_base ~pid =
  runner_alive ~state_base ~pid
  && (match Ssh.read ~state_dir:(Printf.sprintf "%s/session-%d" state_base pid) with
      | Some a -> a.detached
      | None -> false)

let process_alive pid =
  try Unix.kill pid 0; true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) ->
      (* EPERM means "you can't signal them, but they exist". Counts
         as alive for our purposes. *)
      true
  | _ -> false

(* Colour only when stdout is a terminal: `vm-launcher ls | grep` and
   the CLI tests must keep seeing plain text. *)
let tty = lazy (Unix.isatty Unix.stdout)
let sgr code s = if Lazy.force tty then "\027[" ^ code ^ "m" ^ s ^ "\027[0m" else s
let dim = sgr "2"
let bold = sgr "1"

(* Visible width: skips ANSI escapes, counts UTF-8 codepoints rather than
   bytes, and charges 2 columns for the emoji we render (a terminal draws
   them double-width) and 0 for a variation selector. Without this the
   EGRESS column drifts by a column per glyph and the whole table skews. *)
let vis_len s =
  let n = String.length s in
  let rec go i acc =
    if i >= n then acc
    else if s.[i] = '\027' then
      match String.index_from_opt s i 'm' with
      | Some j -> go (j + 1) acc
      | None -> acc + (n - i)
    else
      let b = Char.code s.[i] in
      let len =
        if b < 0x80 then 1
        else if b land 0xE0 = 0xC0 then 2
        else if b land 0xF0 = 0xE0 then 3
        else 4
      in
      let cp =
        match len with
        | 1 -> b
        | 2 -> ((b land 0x1F) lsl 6) lor (Char.code s.[i + 1] land 0x3F)
        | 3 ->
            ((b land 0x0F) lsl 12)
            lor ((Char.code s.[i + 1] land 0x3F) lsl 6)
            lor (Char.code s.[i + 2] land 0x3F)
        | _ ->
            ((b land 0x07) lsl 18)
            lor ((Char.code s.[i + 1] land 0x3F) lsl 12)
            lor ((Char.code s.[i + 2] land 0x3F) lsl 6)
            lor (Char.code s.[i + 3] land 0x3F)
      in
      let w =
        if cp = 0xFE0F then 0        (* variation selector: no width *)
        else if cp >= 0x1F300 then 2 (* pictographic emoji *)
        else if cp = 0x26D4 || cp = 0x2708 || cp = 0x26A0 then 2
          (* ⛔ ✈ ⚠ render double-width like the pictographs above *)
        else 1
      in
      go (i + len) (acc + w)
  in
  go 0 0

let pad w s = s ^ String.make (max 0 (w - vis_len s)) ' '

(* A glyph carries the state faster than the word does, and survives a
   colourless terminal: filled = alive and attachable, half-filled /
   dotted = coming up, hollow = gone, triangle = wants attention. The
   word stays for greppability. *)
let colour_state st =
  match st with
  | "running" -> sgr "32" ("● " ^ st)   (* green: alive, a terminal owns it *)
  | "detached" -> sgr "36" ("● " ^ st)  (* cyan: alive, yours to `down` *)
  | "orphaned" -> sgr "33" ("▲ " ^ st)  (* yellow: alive, nobody owns it *)
  | "booting" -> sgr "34" ("◐ " ^ st)   (* blue: VM up, sshd not yet *)
  | "building" -> sgr "34" ("◌ " ^ st)  (* blue: no VM yet, nix build *)
  | "stale" -> sgr "31" ("▲ " ^ st)     (* red: debris worth cleaning *)
  | "exited" -> dim ("○ " ^ st)
  | s -> dim ("  " ^ s)

(* Deliberately NO glyph here. The banner and the statusline show one
   posture once; a table shows one per row, and a column of emoji pulls
   the eye away from the rows that actually differ. Colour carries it —
   unfenced in bold red is still unmissable. *)
let colour_egress e =
  match e with
  | "unfenced" -> sgr "1;31" e
  | "airgap" -> sgr "33" e
  | "fenced" -> sgr "32" e
  | s -> dim s

(* Uptime of the VM itself, from the runner's /proc starttime — not the
   manifest's launched_at, which includes however long `nix build` took. *)
let uptime_of_pid pid =
  let clk = 100.0 in
  match
    ( Util.read_proc_opt (Printf.sprintf "/proc/%d/stat" pid),
      Util.read_proc_opt "/proc/uptime" )
  with
  | Some stat, Some up -> (
      (* Field 22 is starttime; the comm field can contain spaces, so
         count from the closing paren rather than splitting on space. *)
      match String.rindex_opt stat ')' with
      | None -> "-"
      | Some i -> (
          let fields =
            String.sub stat (i + 2) (String.length stat - i - 2)
            |> String.split_on_char ' '
          in
          match (List.nth_opt fields 19, String.split_on_char ' ' up) with
          | Some st, up_s :: _ -> (
              match (float_of_string_opt st, float_of_string_opt up_s) with
              | Some st, Some up_s ->
                  let secs = int_of_float (up_s -. (st /. clk)) in
                  if secs < 0 then "-"
                  else if secs < 60 then Printf.sprintf "%ds" secs
                  else if secs < 3600 then Printf.sprintf "%dm" (secs / 60)
                  else if secs < 86400 then
                    Printf.sprintf "%dh%02dm" (secs / 3600) (secs mod 3600 / 60)
                  else Printf.sprintf "%dd%02dh" (secs / 86400) (secs mod 86400 / 3600)
              | _ -> "-")
          | _ -> "-"))
  | _ -> "-"

(* Collapse runs of '/' so a path matches whatever way it was spelled.
   `ssh -o UserKnownHostsFile=$dir/known_hosts` with a $dir that already
   ends in '/' produces "…session-42//known_hosts", which an exact
   compare misses — and then `ls` quietly reports 0 attached clients
   while two people are typing in the VM. *)
let normalize_slashes s =
  let b = Buffer.create (String.length s) in
  String.iteri
    (fun i c ->
      if not (c = '/' && i > 0 && s.[i - 1] = '/') then Buffer.add_char b c)
    s;
  Buffer.contents b

(* Substring search over a NUL-separated /proc cmdline. Hand-rolled to
   keep the library's dependency list as it is — one call site does not
   justify pulling in Str. *)
let contains_sub ~needle hay =
  let n = String.length needle and h = String.length hay in
  n > 0 && h >= n
  && (let rec go i =
        if i + n > h then false
        else if String.sub hay i n = needle then true
        else go (i + 1)
      in
      go 0)

(* Who is attached, and from which terminal.

   Every `vm-launcher attach` execs ssh with
   `-o UserKnownHostsFile=<state_dir>/known_hosts` (Ssh.ssh_argv), and
   that path is unique per session — so scanning /proc for it identifies
   this VM's clients exactly, with no ambiguity and no guest round-trip.
   The client's controlling terminal comes from its stdin symlink, which
   is what makes the answer actionable: "2 attached (pts/3, pts/7)"
   tells you which window to go back to. *)
let attached_clients ~known_hosts =
  if known_hosts = "" then []
  else
    match Sys.readdir "/proc" with
    | exception _ -> []
    | entries ->
        Array.to_list entries
        |> List.filter_map int_of_string_opt
        |> List.filter_map (fun pid ->
               match
                 Util.read_proc_opt (Printf.sprintf "/proc/%d/cmdline" pid)
               with
               (* argv[0] must BE ssh, not merely mention the path: a
                  shell running `grep known_hosts …`, an editor with the
                  file open, or this very tool's own diagnostic command
                  all carry that string in their cmdline and would
                  otherwise be counted as attached shells. *)
               | Some c
                 when c <> ""
                      && (let argv0 =
                            match String.index_opt c '\000' with
                            | Some i -> String.sub c 0 i
                            | None -> c
                          in
                          Filename.basename argv0 = "ssh")
                      && contains_sub
                           ~needle:(normalize_slashes known_hosts)
                           (normalize_slashes c) ->
                   let tty =
                     match
                       Unix.readlink (Printf.sprintf "/proc/%d/fd/0" pid)
                     with
                     | exception _ -> "?"
                     | l ->
                         (* Only a real terminal is worth naming. A client
                            whose stdin is /dev/null or a pipe (a script,
                            a `ssh host cmd`) has no window to go back to,
                            so say that rather than printing "null". *)
                         let has_pfx p =
                           String.length l > String.length p
                           && String.sub l 0 (String.length p) = p
                         in
                         if has_pfx "/dev/pts/" || has_pfx "/dev/tty" then
                           String.sub l 5 (String.length l - 5)
                         else "no-tty"
                   in
                   Some tty
               | _ -> None)
        |> List.sort_uniq String.compare

(* The project path is what the VM IS — whatever lives there is bridged
   at /work — so show the path, not just the basename: two checkouts of
   the same repo are otherwise indistinguishable. Abbreviated against
   $HOME and elided from the LEFT, since the tail is the part that
   identifies it. *)
let short_project path =
  let home = try Sys.getenv "HOME" with Not_found -> "" in
  let p =
    if home <> "" && String.length path > String.length home
       && String.sub path 0 (String.length home) = home
    then "~" ^ String.sub path (String.length home) (String.length path - String.length home)
    else path
  in
  let max_w = 30 in
  if String.length p <= max_w then p
  else "…" ^ String.sub p (String.length p - max_w + 1) (max_w - 1)

(* Agents and egress posture come from the session's own resolved
   policy.json, which every live state dir has. Free: one small read. *)
let policy_facts state_dir =
  match Util.read_file_opt (state_dir ^ "/policy.json") with
  | None -> ("-", "-")
  | Some txt -> (
      match Yojson.Safe.from_string txt with
      | exception _ -> ("-", "-")
      | `Assoc top ->
          let name_of = function
            | `Assoc a -> (
                match List.assoc_opt "name" a with
                | Some (`String n) -> n
                | _ -> "?")
            | _ -> "?"
          in
          let agents =
            (match List.assoc_opt "agent" top with
             | Some a -> [ name_of a ]
             | None -> [])
            @ (match List.assoc_opt "extraAgents" top with
               | Some (`List xs) -> List.map name_of xs
               | _ -> [])
          in
          let egress =
            match List.assoc_opt "egress" top with
            | Some (`Assoc e) -> (
                match List.assoc_opt "mode" e with
                (* Both vocabularies: the launcher writes the first set
                   now, the second is what older sessions recorded. *)
                | Some (`String ("fenced" | "allowlist")) -> "fenced"
                | Some (`String ("unfenced" | "noblock")) -> "unfenced"
                | Some (`String ("airgap" | "block")) -> "airgap"
                | _ -> "-")
            | _ -> "-"
          in
          ((if agents = [] then "-" else String.concat "," agents), egress)
      | _ -> ("-", "-"))

(* Whether this session runs sshd at all ([session.ssh]). Without it no
   attach.json is ever written, so its absence says nothing about how
   far the boot has got. *)
let policy_ssh state_dir =
  match Util.read_file_opt (state_dir ^ "/policy.json") with
  | None -> false
  | Some txt -> (
      match Yojson.Safe.from_string txt with
      | `Assoc top -> (
          match List.assoc_opt "session" top with
          | Some (`Assoc s) -> List.assoc_opt "ssh" s = Some (`Bool true)
          | _ -> false)
      | _ | (exception _) -> false)

(* Ownership (running / detached) says who holds the VM; this says
   whether you can USE it yet. A live launcher with no attach.json is
   still in `nix build` — the runner, and so the file, come after. A
   live runner whose sshd does not answer is still booting. Only an
   sshd that greets us keeps the ownership word, so "running" and
   "detached" now both mean "attach will work right now". Orphaned is
   left alone: its warning matters more than its boot progress. *)
let refine_readiness ~state_base ~pid state =
  let state_dir = Printf.sprintf "%s/session-%d" state_base pid in
  match state with
  | "running" | "detached" -> (
      match Ssh.read ~state_dir with
      | Some a when runner_alive ~state_base ~pid ->
          if Ssh.sshd_up a then state else "booting"
      | Some _ -> state
      | None ->
          if state = "running" && policy_ssh state_dir then "building"
          else state)
  | s -> s

let live_states = [ "running"; "detached"; "orphaned"; "booting"; "building" ]
let is_live st = List.mem st live_states

type entry = {
  id : string;
  project : string;       (* basename only — the table is narrow *)
  launched_at : string;   (* trimmed to date+time, no TZ *)
  state : string;         (* running / detached / orphaned / booting /
                             building / exited / stale *)
  up : string;            (* VM uptime, "-" once it is gone *)
  agents : string;        (* claude / claude,codex / "-" *)
  egress : string;        (* fenced / unfenced / airgap *)
  clients : string list;  (* terminals attached over ssh, e.g. ["pts/3"] *)
  pid : int option;
  slot : string;          (* network slot, "-" when absent (old
                             manifests, --show, orphans) *)
  size : string;          (* guest-image closure size, "-" when the
                             manifest predates the field or nix GC
                             already collected the store path *)
}

(* "9.8G" / "412M" from a byte count. The number everyone compares
   against is `du -sh /nix/store/...`, so binary units. *)
let human_size bytes =
  let gib = 1073741824. and mib = 1048576. in
  let b = float_of_int bytes in
  if b >= gib then Printf.sprintf "%.1fG" (b /. gib)
  else Printf.sprintf "%.0fM" (b /. mib)

(* The manifest's [runner] block (written post-build since v0.2.4).
   The closure is shared between sessions built from the same config
   and reclaimed by nix GC — once the store path is gone the recorded
   size no longer describes anything on disk, so show "-". *)
let size_of_runner_json top =
  match List.assoc_opt "runner" top with
  | Some (`Assoc r) ->
      let path =
        match List.assoc_opt "store_path" r with
        | Some (`String s) -> Some s
        | _ -> None
      in
      let bytes =
        match List.assoc_opt "closure_bytes" r with
        | Some (`Int n) -> Some n
        | Some (`Intlit s) -> int_of_string_opt s
        | _ -> None
      in
      (match path, bytes with
       | Some p, Some b when Sys.file_exists p -> human_size b
       | _ -> "-")
  | _ -> "-"

(* Read one manifest.json. We only need the four fields the table
   prints; tolerate missing/garbled keys. *)
let entry_of_manifest ~state_base path id ~pid_for_id =
  let json = try Some (Yojson.Safe.from_file path) with _ -> None in
  let trim_at s =
    (* "2026-06-06T20:43:12+02:00" → "2026-06-06 20:43" *)
    if String.length s < 16 then s
    else
      let date = String.sub s 0 10 in
      let time = String.sub s 11 5 in
      date ^ " " ^ time
  in
  match json with
  | None ->
      { id; project = "(unreadable manifest)"; up = "-"; agents = "-";
        egress = "-"; clients = [];
        launched_at = ""; state = "stale"; pid = pid_for_id id;
        slot = "-"; size = "-" }
  | Some (`Assoc top) ->
      let get_string k =
        match List.assoc_opt k top with
        | Some (`String s) -> s
        | _ -> ""
      in
      let project_full = get_string "project" in
      let launched_at = trim_at (get_string "launched_at") in
      let pid = pid_for_id id in
      (* PID column: show the pid that MATTERS for this row. For a live
         VM that is the runner — what `down` signals and what liveness
         is judged by. Showing the launcher pid meant the rows you most
         want to act on displayed a long-dead process. *)
      let display_pid =
        match pid with
        | Some p when runner_alive ~state_base ~pid:p -> (
            match Ssh.read ~state_dir:(Printf.sprintf "%s/session-%d" state_base p) with
            | Some a -> Some a.runner_pid
            | None -> pid)
        | _ -> pid
      in
      let state =
        match pid with
        | None -> "exited"
        | Some p when detached_runner_alive ~state_base ~pid:p -> "detached"
        (* Launcher alive = an ordinary foreground session. This MUST be
           tested before the orphan case: a foreground VM has a live
           runner too, and checking the runner first labelled every
           healthy foreground VM "orphaned". *)
        | Some p when process_alive p -> "running"
        (* Runner alive, launcher gone, never detached: the VM is running
           with nobody owning it. Not "stale" — stale means safe to
           clean, and this is the opposite. *)
        | Some p when runner_alive ~state_base ~pid:p -> "orphaned"
        | Some _ -> "stale"
      in
      let state =
        match pid with
        | Some p -> refine_readiness ~state_base ~pid:p state
        | None -> state
      in
      let slot =
        match List.assoc_opt "slot" top with
        | Some (`Int i) -> string_of_int i
        | _ -> "-"
      in
      let sd = match pid with
        | Some p -> Printf.sprintf "%s/session-%d" state_base p
        | None -> ""
      in
      let agents, egress = if sd = "" then ("-", "-") else policy_facts sd in
      let clients =
        if sd = "" then []
        else
          match Ssh.read ~state_dir:sd with
          | Some a -> attached_clients ~known_hosts:a.known_hosts
          | None -> []
      in
      let up =
        match display_pid with
        | Some p when is_live state -> uptime_of_pid p
        | _ -> "-"
      in
      { id;
        project = short_project project_full;
        launched_at; state; pid = display_pid; slot; up; agents; egress;
        clients;
        size = size_of_runner_json top }
  | Some _ ->
      { id; project = "(bad manifest)"; up = "-"; agents = "-"; egress = "-";
        clients = [];
        launched_at = ""; state = "stale"; pid = pid_for_id id;
        slot = "-"; size = "-" }

(* List the session IDs from the global registry. *)
let global_session_ids xdg_state_home =
  let dir = Printf.sprintf "%s/microvm/sessions" xdg_state_home in
  match readdir_opt dir with
  | None -> []
  | Some entries -> Array.to_list entries

(* How many rows a plain [ls] shows; [--all] lifts the cap. *)
let default_limit = 10

let rec take n = function
  | [] -> []
  | _ when n <= 0 -> []
  | x :: rest -> x :: take (n - 1) rest

(* Sort for display: live sessions (running / detached / orphaned)
   first, then stale, then exited — the rows you can act on carry the
   table — and alphabetically by id within each group. *)
let state_rank e =
  match e.state with
  | s when is_live s -> 0
  | "stale" -> 1
  | _ -> 2

let display_sort entries =
  List.sort
    (fun a b ->
      match compare (state_rank a) (state_rank b) with
      | 0 -> String.compare a.id b.id
      | c -> c)
    entries

(* Print a fixed-width-ish table. *)
let print_table ~all entries =
  if entries = [] then begin
    print_endline "no sessions found";
    ()
  end else begin
    let total = List.length entries in
    let entries =
      if all then entries
      else begin
        (* The cap keeps every live and stale row (the actionable
           ones), then fills up to the limit with the NEWEST exited
           sessions — capping on display order alone would surface the
           oldest exited rows instead. *)
        let actionable, exited =
          List.partition (fun e -> state_rank e < 2) entries
        in
        let room = max 0 (default_limit - List.length actionable) in
        let newest_exited =
          exited
          |> List.sort
               (fun a b -> String.compare b.launched_at a.launched_at)
          |> take room
        in
        actionable @ newest_exited
      end
    in
    let entries = display_sort entries in
    (* Column widths: enough to fit our actual data + min reasonable. *)
    let max_with min_w sel =
      List.fold_left
        (fun acc e -> max acc (String.length (sel e)))
        min_w entries
    in
    let live e = is_live e.state in
    let w_id = max_with 22 (fun e -> e.id) in
    let w_proj = max_with 16 (fun e -> e.project) in
    let w_state = 11 in
    let w_up = max_with 5 (fun e -> e.up) in
    let w_agents = max_with 6 (fun e -> e.agents) in
    let w_egress = max_with 8 (fun e -> e.egress) in
    let clients_str e =
      if not (live e) then "-"
      else match List.length e.clients with 0 -> "0" | n -> string_of_int n
    in
    let w_cl = 3 in
    let pid_str e =
      match e.pid with None -> "-" | Some p -> string_of_int p
    in
    let w_pid = max_with 5 pid_str in
    let w_slot = 4 in
    (* SIZE is the last column: printed unpadded, so no width needed. *)
    print_endline
      (sgr "1;90"
         (Printf.sprintf
            "%-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %s"
            w_id "ID" w_proj "PROJECT" w_state "STATE" w_up "UP"
            w_agents "AGENTS" w_egress "EGRESS" w_cl "ATT" w_pid "PID"
            w_slot "SLOT" "SIZE"));
    List.iter
      (fun e ->
        (* Finished rows are dimmed whole, so the live ones — the only
           ones you can act on — carry the eye. *)
        let plain s = if live e then s else dim s in
        Printf.printf "%s  %s  %s  %s  %s  %s  %s  %s  %s  %s\n"
          (pad w_id (plain e.id))
          (pad w_proj (if live e then bold e.project else dim e.project))
          (pad w_state (colour_state e.state))
          (pad w_up (if live e then sgr "37" e.up else dim e.up))
          (pad w_agents (if live e then sgr "35" e.agents else dim e.agents))
          (pad w_egress (if live e then colour_egress e.egress else dim e.egress))
          (pad w_cl
             (if live e && e.clients <> [] then sgr "36" (clients_str e)
              else plain (clients_str e)))
          (pad w_pid (plain (pid_str e)))
          (pad w_slot (plain e.slot))
          (plain e.size))
      entries;
    (* Footer: what is running, and the two things you would do next. *)
    let live_entries = List.filter live entries in
    let n_live = List.length live_entries in
    if n_live > 0 then begin
      let unfenced =
        List.filter (fun e -> e.egress = "unfenced") live_entries
      in
      print_newline ();
      let slots = List.length (Session.discover_slots ()) in
      Printf.printf "%s\n"
        (dim
           (Printf.sprintf "%s running%s · %s finished · %d/%d slots busy"
              (bold (string_of_int n_live))
              (match
                 List.length
                   (List.filter
                      (fun e -> e.state = "booting" || e.state = "building")
                      live_entries)
               with
               | 0 -> ""
               | n -> Printf.sprintf " (%d not ready yet)" n)
              (string_of_int (List.length entries - n_live))
              n_live slots));
      if unfenced <> [] then
        Printf.printf "%s\n"
          (sgr "1;31"
             (Printf.sprintf "! %d running UNFENCED (no egress allowlist)"
                (List.length unfenced)));
      List.iter
        (fun e ->
          if e.clients <> [] then
            Printf.printf "%s\n"
              (dim
                 (Printf.sprintf "  %s attached from %s"
                    (match List.length e.clients with
                     | 1 -> "1 shell"
                     | n -> Printf.sprintf "%d shells" n)
                    (String.concat ", " e.clients))))
        live_entries;
      (match List.filter (fun e -> e.state = "orphaned") live_entries with
       | [] -> ()
       | os ->
           List.iter
             (fun e ->
               Printf.printf "%s\n"
                 (sgr "33"
                    (Printf.sprintf
                       "! %s is running but its launcher is gone — `vm-launcher down %s`"
                       e.id e.id)))
             os);
      match List.filter (fun e -> e.state = "detached") live_entries with
      | [ e ] ->
          Printf.printf "%s\n"
            (dim
               (Printf.sprintf "attach: vm-launcher attach %s   ·   stop: vm-launcher down %s"
                  e.id e.id))
      | _ :: _ ->
          Printf.printf "%s\n"
            (dim "attach: vm-launcher attach <ID>   ·   stop: vm-launcher down <ID>")
      | [] -> ()
    end;
    let shown = List.length entries in
    if total > shown then
      Printf.printf "... %d more (vm-launcher ls --all)\n" (total - shown)
  end

let collect ~xdg_state_home ~state_base =
  let live = live_sessions state_base in
  (* Map id -> pid (last wins; collisions are impossible in practice
     because each pid stages its own session ID). *)
  let live_by_id = Hashtbl.create (List.length live) in
  List.iter (fun (pid, id) -> Hashtbl.replace live_by_id id pid) live;
  let pid_for_id id = Hashtbl.find_opt live_by_id id in
  let global_ids = global_session_ids xdg_state_home in
  let global_entries =
    List.filter_map
      (fun id ->
        let manifest_path =
          Printf.sprintf "%s/microvm/sessions/%s/manifest.json"
            xdg_state_home id
        in
        if Sys.file_exists manifest_path
        then Some (entry_of_manifest ~state_base manifest_path id ~pid_for_id)
        else None)
      global_ids
  in
  (* A live session WITHOUT a global manifest (manifest writer crashed
     before completing) — surface so it's not silently invisible. *)
  let global_id_set = Hashtbl.create (List.length global_ids) in
  List.iter (fun id -> Hashtbl.replace global_id_set id ()) global_ids;
  let orphans =
    List.filter_map
      (fun (pid, id) ->
        if Hashtbl.mem global_id_set id then None
        else
          (* No manifest: the boot died before writing one, or the
             registry entry was removed. Do NOT assume it is running —
             that claim used to be hardcoded here, so a torn-down
             session's leftover /run dir read as a healthy VM forever.
             Probe both the runner and the launcher. *)
          let state =
            if runner_alive ~state_base ~pid then "orphaned"
            else if process_alive pid then
              refine_readiness ~state_base ~pid "running"
            else "stale"
          in
          Some
            (let agents, egress =
               policy_facts (Printf.sprintf "%s/session-%d" state_base pid)
             in
             { id; project = "(no manifest)";
               launched_at = ""; state; up = uptime_of_pid pid;
               agents; egress;
               clients =
                 (match Ssh.read ~state_dir:(Printf.sprintf "%s/session-%d" state_base pid) with
                  | Some a -> attached_clients ~known_hosts:a.known_hosts
                  | None -> []);
               pid = Some pid; slot = "-"; size = "-" }))
      live
  in
  global_entries @ orphans

let run ?(all = false) ~xdg_state_home ~state_base () =
  print_table ~all (collect ~xdg_state_home ~state_base)

(* Bare ids, newest first, one per line — the machine-readable half of
   `ls`. Shell completion needs something stable to consume, and the
   table is explicitly for humans: its columns have already changed
   twice. [live_only] restricts to VMs you can actually act on, which is
   what `attach` and `down` complete against. *)
let ids ?(live_only = false) ~xdg_state_home ~state_base () =
  let entries = collect ~xdg_state_home ~state_base in
  entries
  |> List.filter (fun e ->
         (not live_only)
         || (is_live e.state && e.state <> "building"))
  |> List.sort (fun a b -> String.compare b.launched_at a.launched_at)
  |> List.iter (fun e -> print_endline e.id);
  0
