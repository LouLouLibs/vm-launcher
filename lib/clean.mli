(** [vm-launcher clean] — delete finished sessions.

    Removes, per session ID: the global registry dir
    [<xdg_state_home>/microvm/sessions/<id>/], the per-project
    [<stateDir>/sessions/<id>] symlink, and — for "stale" sessions
    whose launcher pid is dead but whose teardown never ran — the
    leftover [<state_base>/session-<pid>/] dir, any
    [current-session-<i>] symlink still pointing at it, and any
    orphaned virtiofsds its pidfiles name (killed only after a
    /proc cmdline check, so a recycled pid is never signalled).

    Running sessions are never touched. The guest image closure in
    /nix/store is NOT reclaimed here — it's shared between sessions
    and owned by nix ([nix store gc]). *)

val run :
  xdg_state_home:string ->
  state_base:string ->
  ids:string list ->
  exited:bool ->
  int
(** Clean the given [ids], or — when [exited] is [true] — every
    session that is not currently running (states "exited" and
    "stale"; [ids] is ignored in that mode, the CLI rejects mixing
    the two). Returns the process exit code: 0 when everything asked
    for was cleaned (or there was nothing to clean), 1 when any ID
    was unknown or referred to a running session (each failure is
    reported on stderr; the rest are still cleaned). *)
