(** Virtiofs share manifest + tag-scheme mirror of [_guest.nix].

    The launcher spawns [virtiofsd] directly, bypassing microvm.nix's
    per-share helper scripts. So it must independently:

    - know which tags should be [--readonly] (derived from the policy)
    - read the framework-generated socket/source manifest under
      [<runner>/share/microvm/virtiofs/<tag>/]

    Drift between this module and [_guest.nix] is silent and
    high-stakes: virtiofsd ends up bound to a socket the runner never
    opens (or with the wrong RO flag), and cloud-hypervisor waits 60s
    before failing. Whenever you touch this, eyeball
    [_guest.nix] (lines ~28–96 — wkro/in tags + the share list). *)

val wkro_tag : string -> string
(** Mirrors [_guest.nix:30]:
    [wkro-${substring 0 12 (hashString "md5" sub)}]. *)

val in_tag : int -> string
(** Mirrors [_guest.nix:41]: ["in-N"] where N is the 0-based index in
    [policy.inputs]. *)

val share_tag : int -> string
(** Tag for the i-th entry of [policy.shares]: ["share-N"]. Independent
    of [in_tag] (different policy fields → different namespaces).
    [_guest.nix] emits the same tag scheme. *)

val auth_tag : Policy.agent -> string
(** Tag of an agent's RO config bind: ["auth-<name>"]. Per agent, since a
    VM can carry several. [_guest.nix] emits the same scheme. *)

val ro_tags : Policy.t -> string list
(** Tags that must be passed [--readonly] to virtiofsd:

    - always: [vmcfg]
    - [auth_tag a] for every declared agent, iff [policy.auth = Bind]
    - [work] iff [policy.work.default = Ro]
    - [wkro_tag sub] for each [sub] in [policy.work.read_only]
    - [in_tag i] for each entry in [policy.inputs] (0-indexed)
    - [share_tag i] for each [policy.shares] entry with
      [read_only = true] (RW entries are absent — virtiofsd starts
      without [--readonly]) *)

type manifest_entry = {
  tag : string;
  source : string;  (** host path; contents of [.../source], newline-stripped *)
  socket : string;  (** relative socket path; contents of [.../socket], newline-stripped *)
}

val read_manifest : runner:string -> manifest_entry list
(** Read [<runner>/share/microvm/virtiofs/<tag>/{source,socket}] for
    every directory under that path. Entries returned sorted by tag
    for determinism. Empty list if the manifest dir is absent (matches
    bash's silent for-loop fall-through). *)
