(** [vm-launcher ls] — list past + currently-running VM sessions.

    Reads the global session registry at
    [<xdg_state_home>/microvm/sessions/<id>/manifest.json] (canonical
    record of every launch) and cross-checks against
    [<state_base>/session-<pid>/etc/session-id] (the staged ID inside
    each live state dir) to flag which sessions are still running.

    Output is plain text — one session per line, columns separated by
    two-or-more spaces, header row first. Designed for both
    eyeballing and grep'ing. No JSON mode yet; add if a programmatic
    caller appears. *)

val run :
  ?all:bool -> xdg_state_home:string -> state_base:string -> unit -> unit
(** Walk both registries and print the table to stdout. Missing /
    unreadable dirs degrade to "no sessions found", not an error —
    a fresh box with no launches yet is a normal case.

    Shows the newest 10 sessions by default; a trailing
    ["... N more (vm-launcher ls --all)"] line points at the rest.
    [?all] (default [false]) lifts the cap.

    The SIZE column is the nix closure size of the guest image the
    session booted ([runner] block in the manifest, recorded
    post-build). The closure is shared between sessions built from
    the same config and reclaimed by [nix store gc] — not by
    [vm-launcher clean] — so the column reads "-" once the store path
    is gone (and for pre-v0.2.4 manifests that never recorded it). *)

(** {2 Shared with [Clean]} *)

val ids :
  ?live_only:bool -> xdg_state_home:string -> state_base:string -> unit -> int
(** Print session ids, newest first, one per line — and nothing else.
    The machine-readable half of [run]: shell completion needs a stable
    contract, and the table is for humans (its columns have already
    changed twice). [live_only] restricts to VMs that can actually be
    acted on, which is what [attach] and [down] complete against. *)

val short_project : string -> string
(** A project path shortened for display: abbreviated against [$HOME]
    and elided from the left when long, since the tail is the part that
    identifies it. Shared with the CLI so a path reads the same in `ls`
    and in an error message. *)

val live_sessions : string -> (int * string) list
(** [live_sessions state_base] — every [(pid, session_id)] readable
    from [<state_base>/session-<pid>/etc/session-id]. "Live" means
    the state dir exists, NOT that the pid is still running — pair
    with [process_alive]. *)

val attached_clients : known_hosts:string -> string list
(** Terminals of the ssh clients attached to the session owning
    [known_hosts], e.g. [["pts/3"; "pts/7"]]; ["no-tty"] for a client
    with no terminal (a scripted [ssh host cmd]).

    Found by scanning /proc for ssh processes carrying that path — every
    [vm-launcher attach] passes it via [-o UserKnownHostsFile], and the
    path is unique per session. argv[0] must actually be ssh: a shell or
    editor merely MENTIONING the path would otherwise be counted as an
    attached shell. *)

val pid_is_runner : int -> bool
(** Whether [pid] is really a VM runner, by /proc cmdline — not merely a
    live pid. Pids recycle, and [down] SIGKILLs what this says yes to. *)

val runner_alive : state_base:string -> pid:int -> bool
(** Whether the VM launched by [pid] is still running, judged by its
    RUNNER pid (recorded in attach.json for every boot) rather than the
    launcher's. A foreground launcher can be killed while its guest runs
    on; treating that as finished let [clean] delete a live VM's state. *)

val detached_runner_alive : state_base:string -> pid:int -> bool
(** Whether the session launched by [pid] left a DETACHED runner
    that is still alive. Such a session outlives its launcher by design,
    so a dead launcher pid alone does not make it stale — cleaning it
    would kill a running VM's virtiofsds. *)

val process_alive : int -> bool
(** [kill 0]-probe. EPERM counts as alive (exists, not signalable). *)
