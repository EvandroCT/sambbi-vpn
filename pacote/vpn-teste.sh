# Teste da VPN até o NAS: caminho (direto ou retransmissor da VM), latência e
# velocidade do FTP com o rclone, nos dois sentidos.
#
#   vpn-teste [MiB]   (padrão: 100)
#
# Precisa do daemon no ar (sambbi-vpn iniciar) e do remote nas do rclone. O
# arquivo de teste é aleatório, vai para NAS_DIR e é apagado no fim. Sem
# NAS_DIR, vai para teste-vpn/ dentro da pasta com o nome do usuário do remote,
# se houver, ou da pasta home.
socket_do_sistema
mib=${1:-100}
sock=$SAMBBI_VPN_SOCKET
# O FTP do QNAP responde 550 ao MLSD na pasta home dos usuários; o LIST funciona.
rclone() { command rclone --ftp-disable-mlsd "$@"; }
if [ -z "${NAS_DIR:-}" ]; then
  u=$(rclone config dump 2>/dev/null | jq -r '.nas.user // empty')
  raiz=$(rclone lsf --dirs-only nas: 2>/dev/null)
  if [ -n "$u" ] && printf '%s\n' "$raiz" | grep -qxF "$u/"; then
    NAS_DIR=nas:$u/teste-vpn
  elif printf '%s\n' "$raiz" | grep -qx 'home/'; then
    NAS_DIR=nas:home/teste-vpn
  else
    echo "erro: não achei a pasta do usuário no NAS; defina NAS_DIR (por exemplo, NAS_DIR=nas:PASTA/teste-vpn vpn-teste)" >&2
    exit 2
  fi
fi
dest=$NAS_DIR
echo "== destino do teste: $dest"
t() { tailscale --socket="$sock" "$@"; }
caminho() { t status --json | jq -c '.Peer[] | select(.HostName=="nas") | {CurAddr, Relay}'; }
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT

# Interface e endereço de saída, sem depender do iproute2 (alguns contêineres não têm)
dev=$(awk '$2 == "00000000" {print $1; exit}' /proc/net/route)
end=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}')
[ -n "$end" ] || end=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "== $(date '+%F %T') saída: $dev $end"
echo "== netcheck"
t netcheck 2>&1 | grep -E 'UDP|IPv4|MappingVaries|PortMapping|sambbi:'
echo "== ping (para quando o caminho fica direto)"
t ping -c 15 nas 2>&1 | tail -3
echo "== caminho"
caminho

head -c $((mib * 1048576)) /dev/urandom >"$w/envio.bin"
# O nixpkgs embrulha o tailscaled (o processo se chama `.tailscaled-wra`): achar pelo socket.
pid=$(pgrep -u "$(id -u)" -f -- "tailscaled .*--socket=$sock" | head -1)
hz=$(getconf CLK_TCK)
cpu() { if [ -n "$pid" ]; then awk '{print $14 + $15}' "/proc/$pid/stat"; else echo 0; fi; }
medir() { # nome comando...
  local nome=$1 c0 c1 t0 t1 rc
  shift
  c0=$(cpu)
  t0=$(date +%s.%N)
  "$@"
  rc=$?
  t1=$(date +%s.%N)
  c1=$(cpu)
  awk -v n="$nome" -v rc="$rc" -v m="$mib" -v a="$t0" -v b="$t1" -v c0="$c0" -v c1="$c1" -v hz="$hz" \
    'BEGIN { s = b - a; printf "%s: rc=%d %.1f MiB/s (%.0f s), tailscaled local %.0f%% de um núcleo\n", n, rc, m / s, s, 100 * (c1 - c0) / hz / s }'
}
medir envio rclone copyto -I "$w/envio.bin" "$dest/teste.bin"
medir download rclone copyto -I "$dest/teste.bin" "$w/volta.bin"
if cmp -s "$w/envio.bin" "$w/volta.bin"; then echo "download igual ao original"; else echo "download DIFERENTE do original"; fi
rclone deletefile "$dest/teste.bin"
rclone rmdir "$dest" 2>/dev/null

echo "== caminho depois da carga"
caminho
t ping -c 5 --until-direct=false nas 2>&1 | tail -5
