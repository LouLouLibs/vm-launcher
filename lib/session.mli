(** Per-session state directory lifecycle.

    [with_state ~f] acquires the state dir, runs [f], and tears down
    on normal return, exception, or SIGINT/SIGTERM. The "registered a
    cleanup that the trap fired before" footgun shell trap-based
    cleanup is prone to becomes structurally impossible. *)

type t
(** A live session token. Held only inside [with_state]'s callback. *)

val pid : t -> int

val slot : t -> int option
(** The network slot [acquire_slot] took, or [None] before
    allocation (and always for [--show]). *)

val state_dir : t -> string
(** Absolute path: [state_base ^ "/session-<pid>"]. *)

val etc_dir : t -> string
(** Absolute path: [state_dir t ^ "/etc"]. Bridged into the guest as
    /etc/vm-launcher via the vmcfg virtiofs share (see _guest.nix). *)

val with_state :
  state_base:string ->
  keep_state:bool ->
  f:(t -> 'a) ->
  'a
(** Acquire a per-session state dir at [state_base ^ "/session-<pid>"]
    (with an [etc/] subdir pre-created), run [f t], then tear down.

    [state_base] is ["/run/vm-launcher"] in production; tests pass a
    temp dir.

    Tear-down (in order):
    - SIGKILL every PID registered via [register_child] (best-effort).
    - If [not keep_state]: [rm -rf] the state dir.
    - If [not keep_state]: drop the [{state_base}/current-session]
      symlink iff it still points at us (a concurrent session may have
      stolen it; that one's cleanup handles its own symlink).

    Runs on normal return, on exception escaping [f] (re-raised after
    cleanup), and on SIGINT/SIGTERM (handler exits with 130/143 after
    cleanup). Previous signal handlers are restored. *)

val discover_slots : unit -> int list
(** The host's network slot pool: every [vm-tap<i>] device under
    /sys/class/net, sorted. [VM_LAUNCHER_SLOT_POOL="0 1"] overrides
    discovery (nix-sandbox CLI tests, dev setups). The host's vm-launcher module
    provisions these; their presence IS the concurrency capacity, so
    launcher and host module deploy independently (an old host
    exposes only vm-tap0 and the launcher behaves like the v0.1.0
    one-session contract). *)

val mark_slot_detached : state_base:string -> slot:int -> pid:int -> unit
(** Record that a DETACHED runner owns [slot], so later launchers
    treat it as busy.

    Necessary because fcntl locks are not inherited across fork: the
    launcher's slot lock dies when it exits, while the detached VM keeps
    running on that tap. The marker names the runner pid; a slot whose
    marker names a live process is busy, and the marker is cleaned up by
    the next launcher to look once the process is gone. *)

val acquire_slot : ?slots:int list -> t -> int
(** Take a free network slot (per-session networking):
    try each slot's POSIX lock ([{state_base}/slot-<i>.lock]),
    first free wins, held until process exit (fd intentionally never
    closed; the kernel releases it on any exit path, so crashes
    cannot leak a slot). All busy = queue: prints who holds the
    slots (project + pid, best-effort), polls until one frees, and
    continues automatically. Records the slot in [t] (see [slot])
    and returns it.

    [?slots] overrides discovery for tests. Raises [Failure] when
    the pool is empty (host module not active).

    Boot path only — [--show] allocates nothing. *)

val set_as_current : t -> unit
(** Atomic [ln -sfn state_dir {state_base}/current-session-<slot>].
    The guest's vmcfg share resolves through the per-slot symlink, so
    it's the commit point at which a populated [etc/] becomes visible
    to the booting guest of THIS slot — sessions in different slots
    touch different symlinks and cannot race each other (this is what
    retired the v0.1.x boot.lock). Requires [acquire_slot] first
    (raises [Invalid_argument] otherwise). Call after the
    guest-closure build: a failed build then never repoints the
    symlink. *)

val with_signals_blocked : int list -> (unit -> 'a) -> 'a
(** Block the given OCaml-internal signal numbers (typically
    [[Sys.sigint; Sys.sigterm]]) for the duration of [f], restore
    the prior mask after. Use to make a [Unix.create_process] +
    [register_child] pair atomic w.r.t. the cleanup handlers — without
    it, a signal landing in the spawn-vs-register window runs cleanup
    against a stale [children] list, orphaning the just-spawned pid.

    Signals delivered while blocked are pending; the kernel delivers
    them once the mask is restored, at which point [register_child]
    has run, so cleanup sees the pid. *)

type child_mode =
  | Sigkill
  (** Cleanup sends SIGKILL immediately. Right for virtiofsds — no
      in-process state worth flushing. *)
  | Sigterm_then_kill of float
  (** Cleanup sends SIGTERM, polls [waitpid WNOHANG] up to the given
      seconds, then SIGKILLs if still alive. Right for cloud-hypervisor
      (via microvm-run): SIGTERM is its graceful shutdown signal —
      powers off the guest, flushes vmm state, releases tap/vhost
      sockets cleanly. *)

val disown_children : t -> unit
(** Drop every registered child from the kill-on-exit list, so they
    survive this process. Required for a detached boot: the
    virtiofsds must keep serving a VM that outlives the launcher.
    Pair with [keep_state:true] — their sockets live in the state dir. *)

val register_child : ?mode:child_mode -> t -> int -> unit
(** Record a child PID for tear-down. [mode] defaults to [Sigkill] for
    back-compat with the original signature (every existing call site
    was for virtiofsds). Idempotent for already-dead PIDs.

    Kill order is LIFO (prepended on register, iterated in stored
    order): if you register virtiofsds first and microvm-run last,
    cleanup tears down microvm-run before pulling its file shares. *)
