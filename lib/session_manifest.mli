(** Per-session metadata that lets you correlate a running / past VM
    session back to the inputs that built it.

    Two artifacts get written per launch:
    - [<xdg>/microvm/sessions/<id>/manifest.json] — the canonical
      record. Embeds [Policy.to_json] so you can replay the session
      offline by reading just this file.
    - [<project state_dir>/sessions/<id>] — a symlink to the global
      session dir, scoped to the project, so per-project [ls] gives
      you that project's session history.
    - [<etc_dir>/session-id] — staged into the guest at
      [/etc/vm-launcher/session-id]; just the ID string, no newline.

    Naming intent: "Session_manifest" not "Session" — [lib/session.ml]
    already owns the per-launch state dir lifecycle, and that's a
    different concern (process state + signal handling). *)

type t = {
  id : string;
  launched_at : string;
      (** ISO 8601 with TZ offset, e.g. [2026-06-06T20:43:12+02:00]. *)
  slot : int option;
      (** Network slot held for the boot; [None] for
          [--show]. *)
  launch_cwd : string;
  policy_source_path : string option;
      (** Absolute path of the [--policy PATH] file, when one was
          supplied. [None] for the built-in default policy. *)
  policy_source_sha256 : string option;
      (** SHA-256 of the policy source's bytes (hex string). [None]
          for the built-in default or if [sha256sum] isn't on PATH. *)
  policy_json : Yojson.Safe.t;
      (** The fully resolved [Policy.t] as JSON — the same shape the
          guest sees via [VM_LAUNCHER_POLICY_JSON]. Embedding (not linking)
          means you can replay a session from the manifest alone. *)
  flake_path : string option;
      (** [$VM_LAUNCHER_FLAKE] at launch, when set. *)
  flake_rev : string option;
      (** [git rev-parse HEAD] inside [flake_path] when it's a git
          working tree. [None] otherwise (no flake, not a git repo,
          missing git binary, ...). *)
  flake_dirty : bool;
      (** Whether [flake_path] had uncommitted changes at launch.
          Useful for "I can't reproduce this and the launcher was on
          a dirty tree" forensics. [false] when not a git tree. *)
  vm_launcher_store_path : string option;
      (** Resolved [/proc/self/exe], which on NixOS is the [/nix/store]
          path of the running launcher binary. Identifies the exact
          build that produced the session. [None] off Linux or if
          [readlink] fails. *)
  hostname : string;
  user : string;
  project : string;
      (** Absolute path from [policy.project]. *)
}

val generate_id : unit -> string
(** Fresh session ID: [YYYYMMDDTHHMMSS-<6 base32 chars>]. Time prefix
    is local time so [ls]-sorting matches the user's clock; random
    suffix uses Crockford base32 (no I/L/O/U) from
    [Mirage_crypto_rng]. Caller must have initialised the RNG (e.g.
    via [Mirage_crypto_rng_unix.use_default ()]). *)

val build :
  id:string ->
  launch_cwd:string ->
  slot:int option ->
  source:Resolver.policy_source ->
  policy:Policy.t ->
  t
(** Populate every field from environment + the resolved policy.
    Shells out to [git] (twice: HEAD + porcelain) when
    [$VM_LAUNCHER_FLAKE] is set; failures degrade to [None]/[false]
    instead of raising — a missing git binary is not a launch error. *)

val to_json : t -> Yojson.Safe.t

val sha256_file : string -> string option
(** SHA-256 of [path]'s contents, as a 64-char lowercase hex string.
    Shells out to [sha256sum]; returns [None] for a missing file,
    missing binary, or any read error (failures are not launch errors —
    the manifest field is forensic, not load-bearing). *)

val git_rev_in : string -> string option
(** [git rev-parse HEAD] inside [path]. [None] when [path] isn't a git
    working tree or git isn't on PATH. *)

val git_dirty_in : string -> bool
(** Whether [git status --porcelain] inside [path] produces any output.
    [false] when [path] isn't a git working tree. *)

val iso8601_local : unit -> string
(** Current wall-clock as RFC 3339 with the local TZ offset, e.g.
    [2026-06-06T20:43:12+02:00]. *)

val id_time_prefix : unit -> string
(** [YYYYMMDDTHHMMSS] in local time — the timestamp half of [generate_id]. *)

val write :
  xdg_state_home:string ->
  project_state_dir:string option ->
  t ->
  unit
(** Write [<xdg_state_home>/microvm/sessions/<id>/manifest.json] with
    mode 0644 and create the parent dirs as needed. When
    [project_state_dir] is [Some d], also create
    [<d>/sessions/<id>] as a symlink to the global session dir for
    per-project discoverability.

    Idempotent within the same session ID (re-runs overwrite the
    manifest, re-create the symlink). *)

val record_runner :
  xdg_state_home:string ->
  id:string ->
  store_path:string ->
  closure_bytes:int option ->
  unit
(** Amend an already-[write]-ten manifest with a ["runner"] block:
    the built runner's store path and (when [nix path-info] could be
    parsed) its closure size in bytes. Called from the boot path once
    [nix build] returns — that's the earliest the values exist.
    [vm-launcher ls] reads the block back for its SIZE column.
    Best-effort: any read/parse/write failure is swallowed; the
    manifest is forensic, never load-bearing for the boot. *)
