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

      # Ambiente de produção, sem o Claude: nix develop github:EvandroCT/sambbi-vpn
      devShells = paraCada (system: {
        default = nixpkgs.legacyPackages.${system}.mkShellNoCC {
          packages = [ self.packages.${system}.default ];
        };
      });
    };
}
