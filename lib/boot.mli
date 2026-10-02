(** Boot the guest microVM.

    Pre-condition: the session's [etc_dir] is already populated
    (caller ran [Stage.all]).

    Sequence (all sync — [Unix.create_process] + [Unix.waitpid]; Lwt
    would buy nothing here):

    {ol
    {- Prepare host-side paths the guest needs to find ready:
       mkdir+chmod the persistent state_dir (mode 0700), its [tasks/]
       subdir, and [~/.claude/tasks/] (the mount-point the nested RW
       tasks share lands on inside the RO auth bind). Seed
       [.claude.json] from the host on first run iff [auth = Bind].}
    {- Write [<state>/policy.json] (the guest reads this through
       [VM_LAUNCHER_POLICY_JSON] at nix-build time).}
    {- [nix build] the runner closure.}
    {- Validate every share source exists ([virtiofsd] silently fails
       otherwise — cloud-hypervisor times out 60s later).}
    {- Spawn one [virtiofsd] per share, registered with [session] so
       teardown SIGKILLs them.}
    {- Poll for sockets up to 10s. Hard-fail on timeout (user inspects
       [<state>/virtiofsd-<tag>.log]).}
    {- [chdir <state>] then run [<runner>/bin/microvm-run]; return its
       exit code.}
    }

    With [detach] the last step forks + setsids the runner instead
    of waiting on it: the VM outlives the launcher, and the return code
    is 0 for "launched" rather than the
    guest's exit status. The detached runner is deliberately NOT
    registered with the session — registered children are killed on
    launcher exit — so the caller MUST keep the state dir, whose
    virtiofsd sockets the VM is still using.

    [on_vm_pid] fires on BOTH paths with the runner's pid. That pid, not
    the launcher's, is the VM's liveness: a foreground launcher can be
    killed while its guest runs on. *)

val run :
  ?fast:bool ->
  ?detach:bool ->
  ?on_vm_pid:(pid:int -> unit) ->
  ?on_runner:(store_path:string -> closure_bytes:int option -> unit) ->
  session:Session.t ->
  policy:Policy.t ->
  flake:string ->
  unit ->
  int
(** Returns the runner's exit code (0 = clean guest power-off). Raises
    [Failure] on build failure, missing share source, or socket
    timeout.

    [?on_runner] (default no-op) fires once [nix build] returns,
    before any virtiofsd spawns, with the built runner's store path
    and its closure size (via [nix path-info -S]; [None] if that
    probe failed). main.ml uses it to amend the session manifest
    ([Session_manifest.record_runner]) so [vm-launcher ls] can show
    the guest image's size. Exceptions out of the callback are
    swallowed — it must never stop a boot.

    [?fast] (default [false]): when [true], exports
    [VM_LAUNCHER_FAST=1] in the env around [nix build]. The
    guest's [_guest.nix] reads it and drops the single-threaded
    [-Efragments]/[-Ededupe] flags from [microvm.storeDiskErofsFlags],
    so [mkfs.erofs] uses all cores. ~10–30% larger image, but the
    closure build is multi-threaded — much faster for dev iteration.
    Note: toggling the flag changes the env nix sees during eval,
    which changes the store-disk drv hash, so the fast and non-fast
    images don't share cache. *)

(** {2 Exposed for testing}

    The orchestration steps below are visible so tests can fingerprint
    behaviour without standing up a real [nix] + [virtiofsd] +
    [microvm-run]. Production callers should use [run]. *)

val prepare_host_paths : Policy.t -> Policy.t
(** [mkdir -p] + [chmod 0700] on [policy.state_dir] and its
    [<agent.task_dir>/] subdir; when [policy.auth = Bind], also creates
    [$HOME/<agent.config_dir>/<agent.task_dir>/] (the mount-point the
    nested RW tasks share lands on inside the RO config bind) and seeds
    each [agent.home_state_files] entry (e.g. [.claude.json]) into
    [state_dir] from [$HOME] on first run only. No-op when
    [state_dir = None]. Reads [$HOME] from the environment and returns
    the policy with [agent.config_host] set to [$HOME/<agent.config_dir>]
    when [auth = Bind] (unchanged otherwise) — the source the guest's
    config bind mounts. *)

val wait_for_sockets : string list -> timeout:float -> unit
(** Block until every path in the list refers to a Unix socket, polling
    every 200ms. Raises [Failure] if any socket is still missing after
    [timeout] seconds. *)
