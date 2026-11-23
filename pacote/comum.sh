# Parâmetros da VPN, os mesmos no daemon, no comando e no teste. Cada um pode
# vir do ambiente. Sem root, a pasta é ~/.local/state/tailscale-user, a mesma
# das instalações manuais anteriores: um cadastro já feito continua valendo.
: "${SAMBBI_VPN_SERVIDOR:=https://sambbi.duckdns.org}"
: "${SAMBBI_VPN_PROXY:=127.0.0.1:1055}"
if [ "$(id -u)" = 0 ]; then
  : "${SAMBBI_VPN_ESTADO:=/var/lib/sambbi-vpn}"
  : "${SAMBBI_VPN_SOCKET:=/run/sambbi-vpn/tailscaled.sock}"
else
  : "${SAMBBI_VPN_ESTADO:=${XDG_STATE_HOME:-$HOME/.local/state}/tailscale-user}"
  : "${SAMBBI_VPN_SOCKET:=$SAMBBI_VPN_ESTADO/tailscaled.sock}"
fi
export SAMBBI_VPN_SERVIDOR SAMBBI_VPN_PROXY SAMBBI_VPN_ESTADO SAMBBI_VPN_SOCKET

# Um usuário comum sem daemon próprio usa o do sistema (serviço instalado com root).
socket_do_sistema() {
  if [ "$(id -u)" != 0 ] && [ ! -S "$SAMBBI_VPN_SOCKET" ] && [ -S /run/sambbi-vpn/tailscaled.sock ]; then
    SAMBBI_VPN_SOCKET=/run/sambbi-vpn/tailscaled.sock
  fi
}
