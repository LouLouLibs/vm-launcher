# Egress proxy for the vm-launcher guest.
#
# vm-egress-proxy: drop-in CONNECT semantics on 127.0.0.1:3128, PLUS
# MITM-terminate-and-inject for hosts that match a `policy.proxyAuth`
# rule. The injected header value renders from ${NAME} placeholders
# against the proxy-scoped secret dir — those secrets the agent process
# literally cannot read (the bootstrap oneshot below tmpfs-shadows their
# staging path).
#
# Three pieces, in order:
#   1. trust:     security.pki.certificateFiles = [ proxy-ca.pem ] so
#                 the guest's CA bundle accepts the per-VM MITM CA.
#   2. bootstrap: egressproxy-secret-bootstrap oneshot moves the CA key
#                 + proxy-secrets/ into egressproxy-owned /run/egressproxy/
#                 and tmpfs-shadows /etc/vm-launcher/proxy-secrets/ so
#                 the agent can't enumerate filenames.
#   3. proxy:     vm-egress-proxy runs as egressproxy after
#                 the bootstrap is done.
#
# nftables drop-egress-not-owned-by-egressproxy stays the same as the
# bash flow (the firewall layer is identical regardless of which
# proxy daemon is on top).
{ pkgs, lib, config, vmLauncherPkg, policy, ... }:
let
  # Single source of truth for the proxy's uid. Used both to define the
  # user below AND in the nftables egress rule — the firewall's linchpin
  # match (only this uid may egress) MUST stay in lockstep with the user,
  # so it is interpolated, never re-typed as a magic number.
  egressproxyUid = 988;

  # CONNECT-chaining rules → one `--upstream SUFFIX=HOST:PORT` flag each.
  # Empty by default: the BASE guest is site-agnostic and knows nothing
  # about any particular tailnet (see options.vmLauncher.egress.upstreams
  # below). A site supplies the rules through mkGuest extraModules.
  upstreamFlags =
    map (u: "--upstream ${u.suffix}=${u.proxy}")
      config.vmLauncher.egress.upstreams;

  # Network posture (launcher-injected; see Policy.egress_mode in the
  # OCaml side and the matching `let` in _guest.nix). This whole module
  # is the FENCE — so it only emits the proxy stack + allowlist firewall
  # when fenced. `airgap` emits a drop-everything firewall (no proxy);
  # `unfenced` emits nothing here at all, leaving egress open (the host
  # already NATs the tap subnet). `or "fenced"` fails safe.
  #
  # BOTH vocabularies are matched: the launcher writes fenced/unfenced/
  # airgap now, and allowlist/noblock/block before. Matching only one of
  # them here would be a silent unfencing — `fenced` would evaluate
  # false, no proxy stack would be emitted, and the guest would boot with
  # open egress while every banner still claimed it was fenced.
  egressMode = policy.egress.mode or "fenced";
  fenced = egressMode == "fenced" || egressMode == "allowlist";
  airgap = egressMode == "airgap" || egressMode == "block";
in
{
  # ---------------------------------------------------------------------
  # Site-supplied egress upstream chaining.
  #
  # Each rule routes hostnames matching `suffix` (domain-suffix match, as
  # the proxy's --upstream understands it) through an upstream HTTP proxy
  # at `proxy` (HOST:PORT) instead of dialing them directly. This is the
  # seam by which a guest reaches a TAILNET peer: the host runs
  # `tailscaled --outbound-http-proxy-listen=HOST:PORT`, opens that port
  # to the tap subnet, and the suffix is the tailnet's MagicDNS domain.
  #
  # The base guest defaults this to [] — it must not bake in any one
  # site's tailnet (the matching host-side tailscaled flag + firewall
  # rule already live in that site's host config). A
  # site wires both halves together via mkGuest extraModules:
  #
  #   vmLauncher.egress.upstreams = [
  #     { suffix = ".example.ts.net"; proxy = "10.42.0.1:1055"; }
  #   ];
  #
  # Per-project policy still controls WHICH tailnet hostnames are allowed
  # through (policy.egress.hosts — the allowlist); this option only
  # controls HOW a matching suffix is dialed.
  # ---------------------------------------------------------------------
  options.vmLauncher.egress.upstreams = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        suffix = lib.mkOption {
          type = lib.types.str;
          example = ".example.ts.net";
          description = "Domain suffix routed through the upstream proxy.";
        };
        proxy = lib.mkOption {
          type = lib.types.str;
          example = "10.42.0.1:1055";
          description = "Upstream HTTP proxy HOST:PORT to chain CONNECT through.";
        };
      };
    });
    default = [ ];
    description = "CONNECT-chaining rules for the egress proxy (tailnet hop).";
  };

  config = lib.mkMerge [

  # ===================================================================
  # FENCED (default): the full egress-proxy stack + allowlist firewall.
  # ===================================================================
  (lib.mkIf fenced {
  # Explicit numeric uid/gid so the bootstrap script (which runs
  # before nss is fully primed in some boot paths) can use them
  # without resolving names. 988/988 is in NixOS's reserved
  # system-uid range and free in practice.
  users.users.egressproxy = {
    isSystemUser = true;
    group = "egressproxy";
    uid = egressproxyUid;
  };
  users.groups.egressproxy.gid = egressproxyUid;

  # Per-VM CA trust at runtime.
  #
  # NixOS's `security.pki.certificateFiles` won't work here — it reads
  # the CA at BUILD time, but our CA lives at /etc/vm-launcher/proxy-ca.pem
  # (vmcfg virtiofs share) and is only present per VM session. So we
  # build a runtime bundle: system trust store + per-VM CA → written to
  # /run/vm-ca-bundle.crt at boot. _guest.nix sets SSL_CERT_FILE et al
  # to point every TLS client at this bundle.
  systemd.services.vm-cabundle = {
    description = "Compose runtime CA bundle = system trust + per-VM MITM CA";
    wantedBy = [ "multi-user.target" ];
    before = [ "vm-egress-proxy.service" "vm-launcher-session.service" ];
    after = [ "etc-vm\\x2dlauncher.mount" ];
    requires = [ "etc-vm\\x2dlauncher.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      ${pkgs.coreutils}/bin/install -m 0644 /dev/null /run/vm-ca-bundle.crt
      ${pkgs.coreutils}/bin/cat \
        ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
        >> /run/vm-ca-bundle.crt
      ${pkgs.coreutils}/bin/printf '\n' >> /run/vm-ca-bundle.crt
      ${pkgs.coreutils}/bin/cat /etc/vm-launcher/proxy-ca.pem \
        >> /run/vm-ca-bundle.crt
    '';
  };

  # Bootstrap: stage egressproxy-readable copies of the CA key + proxy
  # secrets into /run/egressproxy/, then tmpfs-shadow the host-side
  # /etc/vm-launcher/proxy-secrets/ so the agent can't enumerate.
  #
  # Runs as root (mount + chown require it). Order: after vmcfg
  # virtiofs is mounted (where the stage files live), before
  # vm-egress-proxy starts.
  systemd.services.egressproxy-secret-bootstrap = {
    description = "Stage vm-egress-proxy secrets + tmpfs-shadow the agent-visible path";
    wantedBy = [ "multi-user.target" ];
    # Before vm-launcher-startup-hooks (which runs as the agent user)
    # AND vm-launcher-session (the interactive shell) — the agent must
    # never be able to read /etc/vm-launcher/proxy-secrets/ before the
    # tmpfs shadow lands. virtiofs passthrough gives agent and
    # virtiofsd the same effective uid, so mode bits alone can't
    # protect; the ordering does.
    before = [
      "vm-egress-proxy.service"
      "vm-launcher-startup-hooks.service"
      "vm-launcher-session.service"
    ];
    after = [ "etc-vm\\x2dlauncher.mount" ];
    requires = [ "etc-vm\\x2dlauncher.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # Be paranoid about which `mount` we call — bare `mount` would
    # pick up whatever's on PATH, which on minimal images is
    # unpredictable. Same for the other coreutils.
    script = ''
      # Log every command + its rc to the persistent state share so
      # post-mortem doesn't depend on the journal (which the agent
      # user can't read by default). Survives reboot when auth=bind.
      set -x
      log=/var/lib/vm-launcher-state/bootstrap.log
      ${pkgs.coreutils}/bin/mkdir -p /var/lib/vm-launcher-state 2>/dev/null || true
      exec > >(${pkgs.coreutils}/bin/tee -a "$log") 2>&1
      echo "=== bootstrap @ $(${pkgs.coreutils}/bin/date -Iseconds) ==="
      set -eu

      # Always use absolute paths — systemd's default PATH for a
      # User=-less oneshot is minimal; bare `install` would fail-bail.
      ${pkgs.coreutils}/bin/install -d -o egressproxy -g egressproxy -m 0700 \
        /run/egressproxy
      ${pkgs.coreutils}/bin/install -d -o egressproxy -g egressproxy -m 0700 \
        /run/egressproxy/secrets

      # Each entry in proxy-secrets/ → /run/egressproxy/secrets/ owned by
      # egressproxy with the same 0600 mode. Skip silently if the staging
      # dir doesn't exist (i.e. policy has no proxy-scoped secrets;
      # MITM still works for proxyAuth rules whose templates are
      # literal strings with no ''${NAME} references).
      if [ -d /etc/vm-launcher/proxy-secrets ]; then
        for f in /etc/vm-launcher/proxy-secrets/*; do
          [ -f "$f" ] || continue
          name="$(${pkgs.coreutils}/bin/basename "$f")"
          ${pkgs.coreutils}/bin/install -o egressproxy -g egressproxy -m 0600 \
            "$f" "/run/egressproxy/secrets/$name"
        done
      fi

      # Tmpfs-shadow the staging path so the agent can't read it OR
      # enumerate filenames. The tmpfs is 0700 egressproxy-owned and
      # empty — even an `ls` from the agent returns Permission denied.
      # If the staging path doesn't exist (no proxy-scoped secrets),
      # skip — there's nothing to shadow.
      #
      # tmpfs uid=/gid= mount options require NUMERIC ids (kernel doesn't
      # resolve names); chown after the mount instead. Guard with
      # mountpoint -q so a unit restart doesn't stack mounts.
      if [ -d /etc/vm-launcher/proxy-secrets ] && \
         ! ${pkgs.util-linux}/bin/mountpoint -q /etc/vm-launcher/proxy-secrets; then
        ${pkgs.util-linux}/bin/mount -t tmpfs \
          -o size=64k,mode=0700,nosuid,nodev \
          tmpfs /etc/vm-launcher/proxy-secrets
        ${pkgs.coreutils}/bin/chown egressproxy:egressproxy /etc/vm-launcher/proxy-secrets
      fi
    '';
  };

  systemd.services.vm-egress-proxy = {
    description = "vm-launcher egress allowlist proxy (MITM-capable)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "etc-vm\\x2dlauncher.mount"
      "egressproxy-secret-bootstrap.service"
    ];
    requires = [
      "etc-vm\\x2dlauncher.mount"
      "egressproxy-secret-bootstrap.service"
    ];
    serviceConfig = {
      User = "egressproxy";
      Group = "egressproxy";
      # vm-egress-proxy doesn't fork — Type=simple is correct.
      Type = "simple";
      # The proxy reads:
      #   --egress-hosts:       allowlist file (kept from bash flow)
      #   --proxy-ca-cert/-key: per-VM CA pair for MITM signing
      #   --proxy-auth-config:  TAB-separated rules from Stage.proxy_auth_config
      #   --secret-dir:         egressproxy-owned secret dir from bootstrap
      #
      # The `--upstream` rules (if any) chain CONNECT through an upstream
      # HTTP proxy for matching suffixes — e.g. the host's tailscaled
      # outbound proxy for a tailnet domain. Site-supplied via
      # vmLauncher.egress.upstreams; empty on the base guest.
      ExecStart = lib.concatStringsSep " " ([
        "${vmLauncherPkg}/bin/vm-egress-proxy"
        "--listen 127.0.0.1"
        "--port 3128"
        "--egress-hosts /etc/vm-launcher/egress-hosts"
      ] ++ upstreamFlags ++ [
        "--proxy-ca-cert /etc/vm-launcher/proxy-ca.pem"
        # CA key lives alongside proxy-scoped secrets — the bootstrap
        # copies everything from /etc/vm-launcher/proxy-secrets/* into
        # /run/egressproxy/secrets/. vm-egress-proxy's --secret-dir iteration
        # skips it (filename isn't a valid POSIX env var name).
        "--proxy-ca-key /run/egressproxy/secrets/proxy-ca-key.pem"
        "--proxy-auth-config /etc/vm-launcher/proxy-auth.conf"
        "--secret-dir /run/egressproxy/secrets"
      ]);
      Restart = "on-failure";
      # Readiness probe: Type=simple marks the unit "active" as soon as
      # the process is forked, not when it's bound to its listening
      # socket. Anything that After=vm-egress-proxy.service would then
      # race the actual bind() — we saw vm-launcher-startup-hooks fail
      # with "Could not connect to server" on fast guest boots. Probe
      # the TCP socket directly via bash's /dev/tcp pseudo-device: the
      # redirect succeeds iff the kernel TCP connect succeeds, which
      # is the precise readiness signal we want. The unit transitions
      # to "active" only after ExecStartPost returns 0. Up to 15
      # seconds; if the proxy never binds, the unit fails and
      # dependents bail loudly instead of going dark.
      ExecStartPost = "${pkgs.bash}/bin/bash -c 'for i in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/3128) 2>/dev/null && exit 0; sleep 0.5; done; exit 1'";
      # vm-egress-proxy doesn't need any extra capabilities and shouldn't
      # have any — it's the most-attacked process in the guest.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      LockPersonality = true;
      # The proxy needs to write nothing on disk; /run/egressproxy is
      # already owned by egressproxy from the bootstrap.
      ReadWritePaths = [];
    };
  };

  # Drop egress not owned by egressproxy. Loopback + established conntrack
  # pass; everything else (INCLUDING DNS) is allowed only for the proxy uid.
  #
  # No general `udp dport 53 accept`: that would let ANY process — the agent
  # included — send DNS off-box, a classic QNAME-encoded exfil channel that
  # bypasses the whole MITM-proxy allowlist. Instead the guest runs no
  # forwarding resolver (services.resolved is off in _guest.nix) and the
  # agent's traffic goes through the proxy, so only the proxy (uid below)
  # resolves names, covered by the single skuid rule. DHCP (udp/67) is gone
  # too — the guest has a static address (_guest.nix).
  networking.nftables = {
    enable = true;
    checkRuleset = false;   # egressproxy user doesn't exist on host build context
    ruleset = ''
      table inet cvm {
        chain output {
          type filter hook output priority 0; policy drop;
          ct state established,related accept
          oifname "lo" accept
          ip daddr 127.0.0.0/8 accept
          meta skuid ${toString egressproxyUid} accept   # egressproxy — only egress (incl. DNS) path
          counter
        }
        chain input  { type filter hook input  priority 0; policy accept; }
        chain forward{ type filter hook forward priority 0; policy drop; }
      }
    '';
  };
  })

  # ===================================================================
  # AIRGAP (--egress block): no proxy, drop ALL egress. Same firewall
  # shape as the fenced one MINUS the egressproxy skuid accept — so
  # nothing on the box can initiate an outbound connection (DNS
  # included). Loopback + replies to inbound still pass; the static tap
  # address stays configured so network-online.target settles and boot
  # doesn't hang. `noblock` emits no block at all: egress is left open.
  # ===================================================================
  (lib.mkIf airgap {
    networking.nftables = {
      enable = true;
      checkRuleset = false;
      ruleset = ''
        table inet cvm {
          chain output {
            type filter hook output priority 0; policy drop;
            ct state established,related accept
            oifname "lo" accept
            ip daddr 127.0.0.0/8 accept
            counter
          }
          chain input  { type filter hook input  priority 0; policy accept; }
          chain forward{ type filter hook forward priority 0; policy drop; }
        }
      '';
    };
  })
  ];
}
