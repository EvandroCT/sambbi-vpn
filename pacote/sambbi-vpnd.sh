# Daemon da VPN (tailscaled). O mesmo comando serve ao serviço do systemd e ao
# supervisor (sambbi-vpn supervisionar); argumentos extras vão para o tailscaled.
#
# Com root, /dev/net/tun e CAP_NET_ADMIN, a VPN usa a rede do kernel (interface
# sambbi0), e todos os programas da máquina a alcançam. Senão, ela roda no
# espaço do usuário, e os programas a alcançam pelo proxy SOCKS5 e HTTP. O proxy
# fica no ar nos dois casos: o remote nas do rclone sempre passa por ele.
rede=userspace-networking
if [ "$(id -u)" = 0 ] && [ -c /dev/net/tun ]; then
  cap=0
  while read -r chave valor; do
    if [ "$chave" = CapEff: ]; then cap=$valor; fi
  done </proc/self/status
  if ((0x$cap & 0x1000)); then rede=sambbi0; fi # CAP_NET_ADMIN é o bit 12
fi
mkdir -p "$SAMBBI_VPN_ESTADO" "$(dirname "$SAMBBI_VPN_SOCKET")"
chmod 700 "$SAMBBI_VPN_ESTADO"
# Um daemon só por pasta de estado, mesmo quando dois sobem juntos. A trava passa
# ao tailscaled pelo exec e cai quando ele termina; a espera cobre a troca de um
# daemon por outro.
exec 9>>"$SAMBBI_VPN_ESTADO/tailscaled.lock"
if ! flock -w 10 9; then
  echo "erro: já há um daemon da VPN com o estado em $SAMBBI_VPN_ESTADO" >&2
  exit 1
fi
exec tailscaled \
  --statedir="$SAMBBI_VPN_ESTADO" --socket="$SAMBBI_VPN_SOCKET" --tun="$rede" \
  --socks5-server="$SAMBBI_VPN_PROXY" --outbound-http-proxy-listen="$SAMBBI_VPN_PROXY" \
  --no-logs-no-support "$@"
