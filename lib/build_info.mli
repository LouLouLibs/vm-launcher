(** Build provenance, generated at build time by the rule in [lib/dune]. *)

val version : string
(** The release version, from the repo-root [VERSION] file — the same
    file [flake.nix] takes the package version from. *)

val rev : string
(** Short commit hash this binary was built from, e.g. ["82ff80b"].
    ["<hash>-dirty"] when built from a tree with uncommitted changes;
    ["unknown"] when neither the flake nor git could say. *)
