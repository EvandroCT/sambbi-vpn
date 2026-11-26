{
  description = "Cliente da VPN sambbi: tailscale, rclone e scripts, com ou sem root";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      sistemas = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      paraCada = nixpkgs.lib.genAttrs sistemas;
    in
    {
      packages = paraCada (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # Parâmetros comuns (servidor, proxy, pastas), no início de cada script
          comum = builtins.readFile ./pacote/comum.sh;

          vpnd = pkgs.writeShellApplication {
            name = "sambbi-vpnd";
            runtimeInputs = [
              pkgs.tailscale
              pkgs.coreutils
              pkgs.util-linuxMinimal # flock
            ];
            text = comum + builtins.readFile ./pacote/sambbi-vpnd.sh;
          };

          vpn = pkgs.writeShellApplication {
            name = "sambbi-vpn";
            runtimeInputs = with pkgs; [
              tailscale
              coreutils
              procps
              util-linuxMinimal # setsid, flock
              jq
            ];
            text = ''
              DAEMON=${vpnd}/bin/sambbi-vpnd
            ''
            + comum
            + builtins.readFile ./pacote/sambbi-vpn.sh;
          };

          teste = pkgs.writeShellApplication {
            name = "vpn-teste";
            runtimeInputs = with pkgs; [
              tailscale
              rclone
              jq
              procps
              coreutils
              gawk
              iproute2
              getconf
              diffutils
            ];
            # Mede e segue em frente quando um passo falha
            bashOptions = [ "nounset" ];
            text = comum + builtins.readFile ./pacote/vpn-teste.sh;
          };
        in
        {
          default = pkgs.symlinkJoin {
            name = "sambbi-vpn";
            paths = [
              vpn
              vpnd
              teste
              pkgs.rclone
            ];
            meta.mainProgram = "sambbi-vpn";
          };
        }
      );

      # Serviço do sistema no NixOS (ver modulo-nixos.nix)
      nixosModules.default = import ./modulo-nixos.nix;

      # O módulo avalia e gera a unidade e as regras do firewall
      checks = paraCada (
        system:
        let
          nixos = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              {
                services.sambbi-vpn.enable = true;
                services.sambbi-vpn.portasTCP = [ 22 ];
                networking.networkmanager.enable = true;
                boot.loader.grub.enable = false;
                fileSystems."/" = {
                  device = "nodev";
                  fsType = "tmpfs";
                };
                system.stateVersion = "26.05";
              }
            ];
          };
          cfg = nixos.config;
        in
        {
          modulo-nixos =
            assert cfg.systemd.services.sambbi-vpn.serviceConfig.ExecStart
              == "/nix/var/nix/profiles/sambbi-vpn/bin/sambbi-vpnd";
            assert cfg.networking.firewall.interfaces.sambbi0.allowedTCPPorts == [ 22 ];
            assert builtins.elem "/nix/var/nix/profiles/sambbi-vpn" cfg.environment.profiles;
            cfg.systemd.units."sambbi-vpn.service".unit;
        }
      );

      # Ambiente de produção, sem o Claude: nix develop github:EvandroCT/sambbi-vpn
      devShells = paraCada (system: {
        default = nixpkgs.legacyPackages.${system}.mkShellNoCC {
          packages = [ self.packages.${system}.default ];
        };
      });
    };
}
