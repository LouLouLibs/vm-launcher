(** Internal IO + subprocess helpers shared across the library.
    Promoted here only after the second copy of the same helper
    appeared in a different module. *)

val trim_trailing_newline : string -> string

(** [mkdir_p ?perm path] — recursive mkdir; idempotent. *)
val mkdir_p : ?perm:int -> string -> unit

(** [rm -rf -- path] via the shell. Best-effort: the exit status is
    ignored (a vanished path is not an error for any caller). *)
val rm_rf : string -> unit

(** Write [content] to [path], truncating any existing file. Opens
    with [O_CLOEXEC] so the fd does not leak into concurrent
    subprocesses (relevant for secret writes). *)
val write_file : ?perm:int -> string -> string -> unit

(** Read the entire file at [path] into a string. Raises [Sys_error]
    on IO failure. *)
val read_file : string -> string

(** Same as [read_file] but returns [None] on any failure. *)
val read_file_opt : string -> string option

val read_proc_opt : string -> string option
(** Read a file whose size the kernel reports as 0 — i.e. anything under
    [/proc]. [read_file] returns [""] for those, since it trusts
    [in_channel_length]. *)

(** Same as [read_file] with one trailing [\n] stripped (if present). *)
val read_file_trimmed : string -> string

(** Copy [src] to [dst] (read into memory, write via [write_file], so
    the destination fd is [O_CLOEXEC]). *)
val copy_file : ?perm:int -> string -> string -> unit

(** Value of [VM_LAUNCHER_NIXOS_CONFIG], or ["vmLauncher"] when unset
    / empty. Used by the launcher AND by [Validate] when constructing
    the nix expression that probes [pkgs]. *)
val nixos_config_attr : unit -> string

(** [subprocess_capture_stdout ?env ?stdin_dev_null ~prog ~args ()] —
    fork+exec [prog] with [args]; capture stdout into the returned
    string; stderr is inherited. [env] defaults to the current process
    env. [stdin_dev_null] (default [false]) replaces the child's stdin
    with /dev/null; the default inherits the launcher's stdin. *)
val subprocess_capture_stdout :
  ?env:string array ->
  ?stdin_dev_null:bool ->
  prog:string ->
  args:string array ->
  unit ->
  Unix.process_status * string

(** Colored stderr loggers with a "vm-launcher:" tag + message (newline
    + flush). ANSI is emitted only when stderr is a terminal and
    [NO_COLOR] is unset; otherwise the line is plain
    ["<name>: " ^ message], byte-identical to the historical prefix (so
    piped output and tests are unaffected). [?name] overrides the tag.
    [log_info] = cyan tag; [log_warn] = yellow tag + yellow body;
    [log_error] = red tag + red body; [log_phase] = cyan tag + bold body
    prefixed with a ▶ glyph, for the ordered launch milestones. *)
val log_info : ?name:string -> ('a, unit, string, unit) format4 -> 'a
val log_warn : ?name:string -> ('a, unit, string, unit) format4 -> 'a
val log_error : ?name:string -> ('a, unit, string, unit) format4 -> 'a
val log_phase : ?name:string -> ('a, unit, string, unit) format4 -> 'a
