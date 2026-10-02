(** Per-session ssh material for [vm-launcher attach].

    The guest runs sshd on its slot address over the host-only tap
    network. This module mints the keys that make attaching work with no
    operator setup and no trust-on-first-use prompt, and records what
    [attach] needs to find a running VM again.

    Both keypairs are ephemeral — they live and die with the session
    state dir. *)

type attach_info = {
  id : string;  (** session id, as in [vm-launcher ls] *)
  project : string;
  slot : int;
  guest_ip : string;
  user : string;  (** guest agent user *)
  key : string;  (** client private key, in the session state dir *)
  known_hosts : string;  (** session-scoped, holds exactly one host key *)
  runner_pid : int;
      (** microvm-run pid — the VM's real liveness, recorded for EVERY
          boot. Keying liveness on the launcher instead is what let
          [clean] shred a foreground VM whose launcher had been killed. *)
  detached : bool;
      (** Whether the VM outlives its launcher. [down] acts only on
          these while the launcher lives; a foreground VM is stopped
          from its own terminal. *)
}

val guest_ip : slot:int -> string
(** [10.42.<slot>.2] — the guest side of the slot's tap pair. *)

val generate : state_dir:string -> etc_dir:string -> slot:int -> unit
(** Mint both keypairs and stage the guest's half.

    - client keypair -> [state_dir/id_ed25519]{,[.pub]}; the public half
      is staged to [etc_dir/ssh/authorized_key.pub].
    - host keypair -> [state_dir/ssh_host_ed25519_key]{,[.pub]}; the
      PRIVATE half is staged to [etc_dir/ssh/host_ed25519_key] for the
      guest to serve. The guest's root is tmpfs, so a key generated in
      there would change on every boot; injecting one lets the launcher
      write a real [known_hosts] instead of disabling verification.
    - [state_dir/known_hosts] gets the one entry for this guest.

    Requires [ssh-keygen] on PATH; raises [Failure] with that as the
    hint if it is missing. *)

val write : state_dir:string -> attach_info -> unit
(** Record [attach.json] in the session state dir. *)

val read : state_dir:string -> attach_info option
(** Read it back; [None] when absent or unparseable (a session booted
    without [session.ssh], or by an older launcher). *)

val ssh_argv : ?command:string option -> attach_info -> string array
(** argv for reaching the guest, with strict host-key checking against
    the session's own [known_hosts]. [command] runs non-interactively
    instead of opening a shell. *)

val runner_alive : int -> bool
(** Whether the VM's runner pid is still alive. *)

val sshd_up : ?timeout:float -> ?port:int -> attach_info -> bool
(** One cheap probe: does the guest accept a TCP connection on [port]
    (default 22) and greet with an ["SSH-"] banner within [timeout]
    (default 0.5s)? No login is attempted. This is the line between a
    VM that is still booting and one you can attach to. *)

val wait_ready : ?timeout:float -> attach_info -> bool
(** Poll the guest's sshd (non-interactive, strict host key) until it
    accepts a login. [false] when the runner dies first or [timeout]
    (default 300s) runs out. *)

val run_interactive : attach_info -> int
(** Open an interactive shell in the guest on this terminal and return
    ssh's exit code once it closes. Spawned rather than exec'd, so the
    caller can say what to do next. Raises [Failure] if ssh is missing. *)
