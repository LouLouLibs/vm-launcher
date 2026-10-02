(** Pure functions that turn a resolved {!Policy.t} into the strings
    the launcher writes into the guest's [/etc/vm-launcher/].

    Effects live in {!Stage}. *)

val egress_hosts : Policy.t -> string
(** One host per line, trailing newline. The in-guest proxy reads this
    file at start-up; the order doesn't matter to the proxy but is
    preserved here for human diff-ability. *)

val instructions : agent:Policy.agent -> Policy.t -> string
(** The auto-generated instructions file for ONE agent (named by
    [agent.instructions_file], e.g. CLAUDE.md) the guest's
    [agent-home-init] service concatenates with the host-side file (if
    any) and exposes as [~/<agent.config_dir>/<agent.instructions_file>]
    inside the VM. Called once per declared agent, so a two-agent VM
    renders both a CLAUDE.md and an AGENTS.md, each addressed to its own
    reader and naming the others aboard.

    Carries: the project basename in the title, the egress allowlist
    verbatim, the JULIA_PROJECT path, the "what NOT to do" rules, and
    — when [policy.agent.instructions] is set — the user's per-project
    guidance under a [Project-specific guidance] heading. *)
