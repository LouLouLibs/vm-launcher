# Host-side NixOS module: everything a host must provide before
# `vm-launcher` can boot a guest.
#
#   - the launcher on PATH, wrapped with the tools it shells out to, plus
#     the Nickel policy contract at /run/current-system/sw/share/vm-launcher/
#   - kernel modules for tap-backed microVMs
#   - a pool of persistent tap devices, one per concurrent session, each
#     NAT'd out the host's default route
#   - /run/vm-launcher, the per-session state base, owned by the operator
#
# The slot layout is fixed by the launcher and the guest: slot i owns
# vm-tap<i>, 10.42.<i>.0/24 (host .1, guest .2). Only the pool SIZE is a
# host decision; the launcher discovers it by scanning for vm-tap<i>.
#
# The taps are systemd-networkd devices, so this enables networkd. On a
# host whose physical link is managed by the scripted dhcpcd setup (the
# NixOS default), either switch it to networkd (`networking.useNetworkd`)
# or keep dhcpcd off the taps; a NetworkManager host needs neither, but
# usually wants `systemd.network.wait-online.enable = false`.
#
# Site-specific additions stay in the site's own config: a tailnet
# upstream for the egress proxy (host listener + firewall rule, plus the
# guest's `vmLauncher.egress.upstreams`), networkd wait-online tweaks on a
# NetworkManager host, extra guest layers via `mkGuest`.
{ self }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.vm-launcher;
  system = pkgs.stdenv.hostPlatform.system;

  wrapped = pkgs.runCommand "vm-launcher-wrapped"
    { nativeBuildInputs = [ pkgs.makeWrapper ]; }
    ''
      mkdir -p $out/bin $out/share/vm-launcher $out/share/zsh/site-functions
      ln -s ${cfg.package}/bin/vm-egress-proxy $out/bin/vm-egress-proxy
      makeWrapper ${cfg.package}/bin/vm-launcher $out/bin/vm-launcher \
        --prefix PATH : ${lib.makeBinPath cfg.runtimePackages} \
        ${lib.optionalString (cfg.flake != null)
            "--set-default VM_LAUNCHER_FLAKE ${lib.escapeShellArg cfg.flake}"}
      cp ${cfg.contract} $out/share/vm-launcher/contract.ncl
      # What lands on PATH is this wrapper, not the package, so forward
      # the completion or programs.zsh.enableCompletion never sees it.
      ln -s ${cfg.package}/share/zsh/site-functions/_vm-launcher \
        $out/share/zsh/site-functions/_vm-launcher
    '';

  slots = builtins.genList builtins.toString cfg.slots;
  forEachSlot = f:
    lib.listToAttrs (map (s: { name = "20-vm-tap${s}"; value = f s; }) slots);
in
{
  options.services.vm-launcher = {
    enable = lib.mkEnableOption "the vm-launcher host side (tap pool, NAT, wrapped launcher)";

    user = lib.mkOption {
      type = lib.types.str;
      example = "alice";
      description = ''
        The operator who runs `vm-launcher`. Owns the tap devices (so they
        open without root) and /run/vm-launcher.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = "Group owning /run/vm-launcher.";
    };

    slots = lib.mkOption {
      type = lib.types.ints.between 1 254;
      default = 4;
      description = ''
        Number of tap devices, i.e. how many VMs can run at once. A launch
        with every slot busy waits for one to free.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${system}.vm-launcher;
      defaultText = lib.literalExpression "vm-launcher.packages.\${system}.vm-launcher";
      description = "The vm-launcher package (ships vm-launcher and vm-egress-proxy).";
    };

    contract = lib.mkOption {
      type = lib.types.path;
      default = "${self}/policy/contract.ncl";
      defaultText = lib.literalExpression ''"''${vm-launcher}/policy/contract.ncl"'';
      description = ''
        The Nickel policy contract, installed at
        /run/current-system/sw/share/vm-launcher/contract.ncl for policies
        to import. Must match {option}`package`.
      '';
    };

    flake = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/etc/nixos";
      description = ''
        Flake the launcher builds the guest from (it must export
        `nixosConfigurations.vmLauncher`, e.g. via `mkGuest`). `null` keeps
        the package's default: this repo's base guest. Set it when your
        site extends the guest.
      '';
    };

    runtimePackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        coreutils bashInteractive jq nickel nix git virtiofsd iproute2
        # ssh-keygen mints each session's keypair; `attach` execs ssh.
        openssh
      ];
      defaultText = lib.literalExpression
        "with pkgs; [ coreutils bashInteractive jq nickel nix git virtiofsd iproute2 openssh ]";
      description = "Tools put on the launcher's PATH by its wrapper.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ wrapped ];

    boot.kernelModules = [ "tap" "vhost_net" "kvm" ];

    systemd.network = {
      enable = true;
      netdevs = forEachSlot (s: {
        netdevConfig = { Name = "vm-tap${s}"; Kind = "tap"; };
        tapConfig = {
          User = cfg.user;
          MultiQueue = true; # cloud-hypervisor opens 2 queues per vCPU
          VNetHeader = true; # virtio-net offloads
        };
      });
      networks = forEachSlot (s: {
        matchConfig.Name = "vm-tap${s}";
        address = [ "10.42.${s}.1/24" ];
        networkConfig = {
          IPMasquerade = "ipv4";
          # A tap has no carrier until cloud-hypervisor opens it; assign the
          # address anyway so host services can bind to it at boot.
          ConfigureWithoutCarrier = true;
        };
        linkConfig.ActivationPolicy = "always-up";
      });
    };

    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    # Forward guest traffic out, and replies back in. There is no
    # tap-to-tap rule: guests in different slots cannot reach each other.
    # (This option only takes effect with the nftables firewall; the
    # iptables firewall does not filter forwarded traffic by default.)
    networking.firewall.extraForwardRules = ''
      iifname "vm-tap*" accept
      oifname "vm-tap*" ct state established,related accept
    '';

    systemd.tmpfiles.rules = [
      "d /run/vm-launcher 0755 ${cfg.user} ${cfg.group} -"
    ];
  };
}
