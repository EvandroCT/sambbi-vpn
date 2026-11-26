# Serviço do sistema para o cliente da VPN no NixOS, onde o instalador não cria
# a unidade do systemd: lá /etc/systemd/system vem do Nix store.
#
#   imports = [ (builtins.getFlake "github:EvandroCT/sambbi-vpn").nixosModules.default ];
#   services.sambbi-vpn.enable = true;
#
# É a mesma unidade que o instalador cria nas outras distribuições, com a rede do
# kernel (interface sambbi0). O pacote vem do perfil do instalador, que o
# atualiza; o cadastro também é com o instalador ou com "sudo sambbi-vpn entrar".
# Com o serviço declarado, "sudo sambbi-vpn iniciar|parar|reiniciar" usa o
# systemctl. Sem sudo, o sambbi-vpn só consulta: um "iniciar" sem sudo subiria
# outro daemon, sem root.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.sambbi-vpn;
in
{
  options.services.sambbi-vpn = {
    enable = lib.mkEnableOption "o cliente da VPN sambbi como serviço do sistema";

    perfil = lib.mkOption {
      type = lib.types.str;
      default = "/nix/var/nix/profiles/sambbi-vpn";
      description = "Perfil do Nix com o pacote, o mesmo do instalador com root.";
    };

    portasTCP = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      example = [ 22 ];
      description = "Portas TCP abertas no firewall só para a VPN (interface sambbi0).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.sambbi-vpn = {
      description = "VPN sambbi (tailscaled)";
      documentation = [ "https://github.com/EvandroCT/sambbi-vpn" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-pre.target" ];
      after = [
        "network-pre.target"
        "NetworkManager.service"
        "systemd-resolved.service"
      ];
      # Antes da primeira instalação do perfil, o serviço não sobe nem falha
      unitConfig.ConditionPathExists = "${cfg.perfil}/bin/sambbi-vpnd";
      # Os mesmos do módulo services.tailscale do nixpkgs
      path = [
        pkgs.procps
        pkgs.getent
        pkgs.kmod
      ];
      serviceConfig = {
        ExecStart = "${cfg.perfil}/bin/sambbi-vpnd";
        ExecStopPost = "${cfg.perfil}/bin/sambbi-vpnd --cleanup";
        Restart = "on-failure";
        RuntimeDirectory = "sambbi-vpn";
        RuntimeDirectoryMode = "0755";
        StateDirectory = "sambbi-vpn";
        StateDirectoryMode = "0700";
      };
    };

    # sambbi-vpn, vpn-teste e rclone no PATH de todos
    environment.profiles = [ cfg.perfil ];

    networking.networkmanager.unmanaged = [ "sambbi0" ];
    networking.firewall.interfaces.sambbi0.allowedTCPPorts = cfg.portasTCP;
  };
}
