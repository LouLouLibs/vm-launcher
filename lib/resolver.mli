(** Host-side policy resolution.

    Turns CLI arguments + the filesystem + git config into a Policy.t
    ready for the session to consume. Lives separately from {!Policy}
    so the parser can stay side-effect-free. *)

type policy_source =
  | Override of string  (** --policy PATH *)
  | Default             (** the launcher's built-in fallback *)
(** Where the policy came from.

    When no [--policy] is given, the binary auto-discovers a
    convention-based file under the project root (see {!discover_policy});
    only if that finds nothing does it fall back to [Default]. A user can
    always name a file explicitly with [vm-launcher --policy PATH]. *)

val find_project_root : ?cwd:string -> unit -> string
(** [git rev-parse --show-toplevel] in [cwd] (default: [Sys.getcwd ()]),
    or [cwd] itself if not in a git repo. Used for the [project] field
    of the built-in default policy and for [Filename.basename]-derived
    state dir paths. *)

val resolve_source :
  project:string -> override:string option -> policy_source
(** [Some PATH] → [Override PATH] (hard-fails if PATH doesn't exist).
    [None] → [discover_policy ~project], or [Default] if that finds
    nothing. *)

val discover_policy : project:string -> string option
(** Convention-based policy lookup under [project], used when no
    [--policy] is supplied. Directory variants [envs], [env],
    [environments], [environment] (plural-first) are searched under
    [<project>/<dir>/vm/]. Phase 1 tries the canonical [microvm.ncl] in
    each variant; phase 2 falls back to any [*.ncl] (alphabetical) in
    each variant. Returns the first existing file, or [None]. *)

val default_policy : project:string -> Policy.t
(** The launcher's inline fallback. Every contract field is filled in
    with the contract's stated default, so [_guest.nix] can read the
    whole policy without crashing on missing keys. *)

val nickel_export : ?nickel:string -> string -> Yojson.Safe.t
(** Shell-out to [nickel export <path> --format json], parsed as JSON. *)

val load :
  ?nickel:string ->
  project:string ->
  policy_source ->
  Policy.t
(** [Default] → [default_policy ~project]; otherwise [nickel_export]
    then [Policy.of_json]. *)

val tilde_expand : string -> string
(** ["~/foo"] → ["$HOME/foo"], else unchanged. *)

val resolve_state_dir :
  policy_state_dir:string option ->
  xdg_state_home:string ->
  project_basename:string ->
  string
(** The per-project persistent state dir bridged RW into the guest.
    - [Some s] → [tilde_expand s]
    - [None]   → [xdg_state_home ^ "/microvm/" ^ project_basename] *)

val host_git_identity : unit -> string option * string option
(** [git config --global user.name] and [user.email]. [None] for each
    that is unset or that git fails to read. *)

val marker_email : string -> string
(** ["alice@example.com"] → ["alice+vmlaunch@example.com"].
    Falls back to ["vm-launcher@localhost"] for malformed input.
    Exposed because the marker scheme is part of the user-visible
    contract (commits made inside the VM look like
    "[name] (vm-launcher) <alice+vmlaunch@example.com>"). *)

val resolve_git_identity :
  policy_git:Policy.git_identity ->
  host_name:string option ->
  host_email:string option ->
  Policy.git_identity
(** Fill blank [name] / [email] from host values + vm-launcher markers
    ([" (vm-launcher)"] suffix on name, [marker_email] on
    email). Leaves [allowed_github_orgs] alone. *)

val sanitize_hostname : string -> string
(** RFC-1123 sanitization: lowercase, replace non-[a-z0-9] runs with a
    single ['-'], strip leading + trailing ['-'], fallback to
    ["vmlauncher"] if the result is empty. Used to derive a default
    [guest.hostname] from a project basename — MyProject →
    myproject, other_project.workdir → other-project-workdir,
    [".env"] → "env" (no leading dash), ["."] → "vmlauncher". *)

val sanitize_username : string -> string
(** Linux-username sanitization (loosely POSIX
    [[a-z_][a-z0-9_-]*], 32 chars): lowercase, replace non-
    [a-z0-9_-] with [-], collapse runs, strip leading/trailing [-],
    truncate to 32 chars, fallback to ["vmlauncher"] if empty. *)

val resolve_guest :
  policy_guest:Policy.guest ->
  project:string ->
  host_user:string option ->
  Policy.guest
(** Fill blank [hostname] / [username] from defaults:
    - [hostname]: [sanitize_hostname (Filename.basename project)].
    - [username]: [sanitize_username (host_user ^ "-vm")], or
      ["vmlauncher"] when [host_user] is [None] or empty. *)
