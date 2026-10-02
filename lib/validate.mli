(** Host-side sanity checks the launcher runs before [nix build].

    These are best-effort guards: failure to [run] the check itself is
    logged and swallowed, so the launcher falls back to the existing
    behaviour (let [nix build] surface the error). Only when the check
    runs cleanly AND finds a concrete problem do we raise. *)

val build_tools_expr : flake:string -> tools:string list -> string
(** Pure helper exposed for testing. Builds the Nix expression that
    [tools] feeds to [nix eval]: resolves the flake's
    [nixosConfigurations.<attr>.pkgs] (overlay-applied — the same
    pkgs the guest closure actually consumes) and returns the subset
    of [tools] that are not top-level attrs of [pkgs]. The
    nixosConfiguration attribute defaults to [vmLauncher] and is
    overridable via [VM_LAUNCHER_NIXOS_CONFIG]. *)

val nix_string_escape : string -> string
(** Pure helper exposed for testing. Wraps [s] in double quotes and
    escapes backslash, double-quote, newline, CR, tab, and dollar
    sign so a hostile policy string cannot inject Nix code via the
    \[$\{...\}\] interpolation syntax. *)

val meminfo_field : field:string -> string -> int option
(** Pure helper exposed for testing. Extracts the kB value of [field]
    (e.g. ["MemTotal"]) from /proc/meminfo-shaped [contents]. *)

val host_memory : ?meminfo_path:string -> mem_mb:int -> unit -> unit
(** Pre-check [policy.resources.memMb] against host memory BEFORE
    [nix build]. Guest memory is shmem-backed and faulted in lazily,
    so an overcommitted guest boots fine — and then the host kernel
    OOM-kills cloud-hypervisor (killing the whole VM mid-run) once
    the workload touches more pages than the host can back.

    Raises [Failure] when [mem_mb] exceeds host MemTotal (the guest
    can never be fully backed — clear-cut misconfiguration). Logs a
    warning when [mem_mb] exceeds MemAvailable at launch (may still
    be fine: the guest may not touch everything, the host may free
    memory). Unreadable/unparseable meminfo is logged and skipped.
    [meminfo_path] defaults to /proc/meminfo; overridable for tests. *)

val tools : flake:string -> tools:string list -> unit
(** Pre-validate [policy.tools] against the same overlaid [pkgs] the
    guest closure will actually use ([flake.nixosConfigurations.<attr>.pkgs])
    BEFORE [nix build] is invoked. Raises [Failure] naming the bad
    attr(s) on confirmed misses. No-op for an empty list.

    Overlay-aware: packages introduced by overlays on the
    nixosConfiguration (e.g. [pkgs.nclq] / [pkgs.snakemake-uv] /
    [pkgs.dt-cli-tools] in a site flake) are recognised. *)

val share_sources :
  project:string ->
  read_only:string list ->
  inputs:string list ->
  shares:Policy.share list ->
  unit
(** Pre-build check that every virtiofs share source ([work.readOnly]
    subpaths resolved against [project], [inputs], and [shares]
    sources) is a directory rather than a regular file. Each becomes a
    virtiofs share, which serves a *directory* tree; a file there
    passes the host existence check but fails the guest mount, fails
    [local-fs.target], and drops the VM into emergency mode where
    (root locked) it hangs with no host-visible diagnostic.

    Raises [Failure] naming the offending policy entry ONLY on the
    certain case — the source exists AND is a regular file. Missing
    sources are left to the post-build manifest check in [Boot]. *)
