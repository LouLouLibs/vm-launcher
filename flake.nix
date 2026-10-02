{
  description = "vm-launcher: OCaml microVM launcher + egress MITM proxy";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # microvm.nix: declarative NixOS microVMs (cloud-hypervisor backend).
  # The guest config lives in this repo so the guest closure builds here
  # and $VM_LAUNCHER_FLAKE can default to `self` — no host-config checkout
  # needed.
  inputs.microvm.url = "github:astro/microvm.nix";
  inputs.microvm.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, microvm }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # mirage-crypto < 2.3.0 has CVE-2026-87732/-87733/-87735/-87736
      # (spread over mirage-crypto, -pk, -ec; the worst: authenticated
      # decryption exposes plaintext before the tag check, and -pk is the
      # RSA under the proxy's MITM CA). nixos-26.05 flags all three
      # packages via knownVulnerabilities, which makes any consumer that
      # `follows` a recent 26.05 into this flake refuse to
      # evaluate — and our own nixpkgs pin carries 2.1.0 too. Pin 2.3.0
      # (the release that clears every listed CVE) until a base nixpkgs
      # ships ≥2.3.0; the versionOlder guard makes the whole block a
      # no-op (delete it then) once one does. The -pk/-ec overrides only
      # strip the flags hardcoded in their nixpkgs expressions — their
      # version/src already follow the scope's mirage-crypto.
      ocamlPackages =
        if pkgs.lib.versionOlder pkgs.ocamlPackages.mirage-crypto.version "2.3.0" then
          pkgs.ocamlPackages.overrideScope (
            ofinal: oprev:
            let
              clearVulns = p: p.overrideAttrs (old: {
                meta = old.meta // { knownVulnerabilities = [ ]; };
              });
            in {
              mirage-crypto = clearVulns (oprev.mirage-crypto.overrideAttrs (old: rec {
                version = "2.3.0";
                src = pkgs.fetchurl {
                  url = "https://github.com/mirage/mirage-crypto/releases/download/v${version}/mirage-crypto-${version}.tbz";
                  hash = "sha256-hA+/QTZgW0ofHdXAYRkyonT+O/l0ZMgqazqXMaaOII4=";
                };
              }));
              mirage-crypto-pk = clearVulns oprev.mirage-crypto-pk;
              mirage-crypto-ec = clearVulns oprev.mirage-crypto-ec;
            }
          )
        else
          pkgs.ocamlPackages;

      # The two executables this flake builds. Names here match what
      # gets installed into $out/bin/ (NOT the dune target names —
      # bin/main.ml's exe is "main.exe" but we install it as
      # "vm-launcher").
      # Nix package names — sublibs (mirage-crypto-rng.unix, ptime.clock.os)
      # resolve through findlib at link time and don't have separate
      # nixpkgs attrs, so we only list the parent packages here.
      ocamlDeps = with ocamlPackages; [
        yojson x509 mirage-crypto mirage-crypto-pk mirage-crypto-rng
        ptime http lwt cohttp cohttp-lwt cohttp-lwt-unix
        tls tls-lwt ca-certs domain-name
      ];
      vmLauncher = ocamlPackages.buildDunePackage {
        pname = "vm-launcher";
        version = "0.2.5-dev";
        src = ./.;
        duneVersion = "3";

        # makeWrapper: the installed launcher defaults VM_LAUNCHER_FLAKE to
        # this flake's own store path, which carries the vendored guest
        # config (nixosConfigurations.vmLauncher). So a fresh install
        # boots with no env setup; `--set-default` keeps the dev override.
        nativeBuildInputs = [ pkgs.makeWrapper ];

        # Skip dune install — the executables don't declare a
        # public_name so we copy them by hand into $out/bin/.
        buildPhase = ''
          runHook preBuild
          dune build bin/main.exe bin/vm_egress_proxy.exe
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          mkdir -p $out/bin
          cp _build/default/bin/main.exe              $out/bin/vm-launcher
          cp _build/default/bin/vm_egress_proxy.exe   $out/bin/vm-egress-proxy

          # zsh completion. site-functions is where NixOS's
          # programs.zsh.enableCompletion picks it up from any package on
          # environment.systemPackages, so installing it here is all the
          # host has to do.
          install -Dm444 completions/_vm-launcher \
            $out/share/zsh/site-functions/_vm-launcher
          chmod +x $out/bin/vm-launcher $out/bin/vm-egress-proxy
          wrapProgram $out/bin/vm-launcher \
            --set-default VM_LAUNCHER_FLAKE ${self}
          runHook postInstall
        '';

        doCheck = true;
        checkPhase = ''
          runHook preCheck
          dune runtest
          runHook postCheck
        '';

        # test/test_cli.ml spawns main.exe with a real policy file;
        # main.exe shells out to nickel (policy export) and git
        # (project-root + identity lookups). Without these on the
        # sandbox PATH, the CLI tests can't reach Validate.tools /
        # Boot.run.
        nativeCheckInputs = [ pkgs.git pkgs.nickel ];

        propagatedBuildInputs = ocamlDeps;

        meta = with pkgs.lib; {
          description =
            "vm-launcher: OCaml microVM launcher + egress MITM proxy";
          license = licenses.mit;
          platforms = [ "x86_64-linux" ];
          mainProgram = "vm-launcher";
        };
      };
      # The guest closure. `mkGuest` is
      # the extension point: a site layers its own modules/overlays
      # on top of the base via `extraModules` instead of forking the guest.
      #
      # NOTE: the base guest (nix/guest/_guest.nix) still references some
      # site-supplied packages (pkgs.julia-sysimage, ...) guarded behind
      # `julia ∈ tools`; with the eval-only policy (tools = []) those paths
      # aren't forced, so the base still evaluates against stock nixpkgs.
      # Making the base fully distribution-clean is follow-up work.
      mkGuest = { extraModules ? [ ] }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit microvm;
            # Break the old cross-flake cycle: the guest closure references
            # the SAME package this flake builds, not a separate input.
            vmLauncherPkg = self.packages.${system}.default;
          };
          modules = [ ./nix/guest/_guest.nix ] ++ extraModules;
        };
    in {
      packages.${system} = {
        default   = vmLauncher;
        vm-launcher = vmLauncher;
        # Egress posture indicator for the statusline. Shipped on the guest
        # PATH by the guest module; exported here so a host can drop it on
        # PATH too (it prints nothing off-VM), keeping one source of truth.
        vm-egress-status = import ./nix/guest/vm-egress-status.nix { inherit pkgs; };
      };

      # Raw guest module — a site imports this and supplies its own
      # microvm / vmLauncherPkg / extra modules when it wants finer control.
      nixosModules.guest = ./nix/guest/_guest.nix;

      # Host side: wrapped launcher + contract, tap pool + NAT, state dir.
      #   imports = [ inputs.vm-launcher.nixosModules.host ];
      #   services.vm-launcher = { enable = true; user = "alice"; };
      nixosModules.host = import ./nix/host.nix { inherit self; };
      nixosModules.default = self.nixosModules.host;

      # Evaluation-only check that the host module produces a valid system.
      # The toplevel's drv path is computed (forcing a full evaluation) but
      # its string context is dropped, so nothing gets built.
      checks.${system}.host-module-eval =
        let
          host = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.host
              {
                services.vm-launcher = { enable = true; user = "alice"; slots = 2; };
                users.users.alice = { isNormalUser = true; };
                networking.useNetworkd = true;
                boot.loader.grub.enable = false;
                fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
                system.stateVersion = "25.11";
              }
            ];
          };
        in
        pkgs.writeText "host-module-eval"
          (builtins.unsafeDiscardStringContext host.config.system.build.toplevel.drvPath);

      # Default base guest. `$VM_LAUNCHER_FLAKE` unset → the launcher builds
      # `self#nixosConfigurations.vmLauncher.config.microvm.declaredRunner`.
      nixosConfigurations.vmLauncher = self.mkGuest { };

      # Exposed so a site can build an extended guest:
      #   inputs.vm-launcher.mkGuest { extraModules = [ ./my-site-guest.nix ]; }
      inherit mkGuest;

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = (with ocamlPackages; [
          ocaml
          dune_3
          findlib
          lwt
          yojson
          # Proxy stack.
          #   3a (landed): pure Lwt + hand-parsed CONNECT.
          #   3b (in progress): MITM via ocaml-tls + x509 + per-host
          #     leaf cert generation. cohttp/cohttp-lwt-unix used for
          #     HTTP/1.1 parsing of the decrypted request.
          cohttp
          cohttp-lwt-unix
          tls
          tls-lwt
          # x509 / mirage-crypto / ca-certs are pulled in by tls but
          # we want them on the explicit dep list because Proxy_ca
          # uses them directly.
          x509
          mirage-crypto
          mirage-crypto-pk
          mirage-crypto-rng
          ca-certs
          utop
          ocaml-lsp
          ocamlformat
        ]) ++ [
          # Runtime deps the launcher shells out to. Matches the
          # installed launcher wrapper's --prefix PATH set so a
          # locally-built _build/default/bin/main.exe behaves the
          # same as the installed binary — needed for the e2e VM
          # test (test/test_e2e_vm.ml) to find virtiofsd + iproute2.
          pkgs.nickel
          pkgs.git
          pkgs.virtiofsd
          pkgs.iproute2
          # ssh-keygen mints the per-session attach keypair; ssh is what
          # `vm-launcher attach` execs. The host's launcher wrapper
          # must carry openssh for the same reason.
          pkgs.openssh
        ];
      };
    };
}
