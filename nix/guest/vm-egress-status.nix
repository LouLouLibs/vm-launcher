# vm-egress-status — the egress posture indicator shown in the guest's
# statusline. Single source of truth for the glyph/color/proxy-probe logic
# (see ./vm-egress-status.sh). Shipped on the guest PATH by _guest.nix and
# exported as a flake package so a host statusline can call it too (it is a
# silent no-op off-VM). Deps are pinned onto PATH so it works regardless of
# the calling statusline's environment.
{ pkgs }:

pkgs.writeShellScriptBin "vm-egress-status" ''
  export PATH=${pkgs.lib.makeBinPath [ pkgs.jq pkgs.coreutils pkgs.bash ]}''${PATH:+:$PATH}
  ${builtins.readFile ./vm-egress-status.sh}
''
