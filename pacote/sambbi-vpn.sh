# Comando da VPN sambbi: sobe e para o daemon, cadastra a máquina e passa os
# outros comandos ao tailscale, com o socket certo.
uso() {
  cat <<'EOF'
uso: sambbi-vpn COMANDO

  iniciar   sobe o daemon: pelo serviço do systemd, se houver; senão, pelo
            supervisor, que o mantém no ar e o reinicia se ele cair
  parar     para o daemon. Sem systemd, ele fica parado até o próximo iniciar
            ou até um supervisor novo, depois de um reinício
  reiniciar troca o daemon no ar pelo da versão instalada agora. O systemd ou
            o supervisor o sobe de novo, mesmo que este comando caia no meio
            (numa sessão SSH pela própria VPN, por exemplo)
  entrar [--nome NOME] [--chave ARQUIVO]
            cadastra esta máquina: com a chave de cadastro ou, sem ela, com
            um pedido que o admin aprova na VM
  outros    vão para o tailscale: status, ip, ping nas, netcheck, nc...
EOF
}

# O caminho deste comando. Por ele o supervisor acha a versão instalada agora
# (daemon_atual) e percebe a desinstalação.
case $0 in
  /*) self=$0 ;;
  *) self=$PWD/$0 ;;
esac
SOCKET_PROPRIO=$SAMBBI_VPN_SOCKET
socket_do_sistema
t() { tailscale --socket="$SAMBBI_VPN_SOCKET" "$@"; }
vivo() { t status --json >/dev/null 2>&1; }
morto() { ! vivo; }
estado() { t status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true; }
# Logo depois de subir, o daemon passa por NoState e Starting
assentado() {
  case $(estado) in
    '' | NoState | Starting) return 1 ;;
  esac
}
# ate SEGUNDOS COMANDO...: espera o comando dar certo. Conta o tempo, não as
# tentativas: sem daemon, cada consulta ao tailscale leva uns 2 s.
ate() {
  local fim=$((SECONDS + $1))
  shift
  until "$@"; do
    if [ "$SECONDS" -ge "$fim" ]; then return 1; fi
    sleep 0.5
  done
}

# O serviço do systemd, se foi instalado e o systemd responde.
servico() {
  if [ "$(id -u)" = 0 ]; then
    [ -f /etc/systemd/system/sambbi-vpn.service ] && [ -d /run/systemd/system ]
  else
    [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/sambbi-vpn.service" ] &&
      systemctl --user show-environment >/dev/null 2>&1
  fi
}
ctl() { if [ "$(id -u)" = 0 ]; then systemctl "$@"; else systemctl --user "$@"; fi; }
journal() { echo "journalctl $([ "$(id -u)" = 0 ] || echo '--user ')-u sambbi-vpn"; }

# Sem systemd, o supervisor faz o papel do serviço: roda o daemon e o sobe de
# novo se ele cair. O aviso PARADO (sambbi-vpn parar) o segura até o próximo
# iniciar; um supervisor novo, depois de um reinício, o apaga.
#
# Com o Nix pelo proot, um processo aberto dentro do proot de um terminal morre
# com o terminal. Lá o supervisor precisa de um proot só dele, aberto fora de
# qualquer outro: quem o abre é o ~/.local/bin/sambbi-vpn (ver instalar-vpn.sh).
LOG=$SAMBBI_VPN_ESTADO/tailscaled.log
PARADO=$SAMBBI_VPN_ESTADO/parado
TRAVA=$SAMBBI_VPN_ESTADO/supervisor.lock
supervisor_no_ar() { [ -e "$TRAVA" ] && ! flock -n "$TRAVA" true; }
pasta() {
  mkdir -p "$SAMBBI_VPN_ESTADO"
  chmod 700 "$SAMBBI_VPN_ESTADO"
}
# O nixpkgs embrulha o tailscaled; o processo se acha pelo socket
pids_daemon() { pgrep -u "$(id -u)" -f -- "tailscaled .*--socket=$SAMBBI_VPN_SOCKET" || true; }
sem_pid() { ! kill -0 "$1" 2>/dev/null; }
matar_daemon() {
  pkill -u "$(id -u)" -f -- "tailscaled .*--socket=$SAMBBI_VPN_SOCKET" || return 1
  ate 10 morto
}
# O daemon da versão instalada agora, ao lado deste comando no perfil (com
# root, $self pode ser o link em /usr/local/bin). Depois de uma atualização, o
# supervisor, que segue rodando o script antigo, já sobe o daemon novo.
daemon_atual() {
  local s=$self
  if [ ! -x "${s%/*}/sambbi-vpnd" ] && [ -L "$s" ]; then s=$(readlink "$s"); fi
  if [ -x "${s%/*}/sambbi-vpnd" ]; then echo "${s%/*}/sambbi-vpnd"; else echo "$DAEMON"; fi
}

supervisionar() {
  # O caminho do comando no perfil, quando vem como argumento: pelo proot, o $0
  # chega resolvido até o store (ver o ~/.local/bin/sambbi-vpn, em instalar-vpn.sh)
  if [ -n "${1:-}" ]; then self=$1; fi
  # Com o serviço do systemd ou com o daemon do sistema, não há o que supervisionar
  if servico || [ "$SAMBBI_VPN_SOCKET" != "$SOCKET_PROPRIO" ]; then return 0; fi
  pasta
  exec 8>>"$TRAVA"
  # Já há um supervisor no ar. A espera cobre o teste de supervisor_no_ar, que
  # segura a trava por um instante.
  flock -w 2 8 || return 0
  rm -f "$PARADO"
  # O log da sessão anterior fica em tailscaled.log.1
  if [ -s "$LOG" ]; then mv -f "$LOG" "$LOG.1"; fi
  printf '== %s supervisor no ar (pid %s)\n' "$(date '+%F %T')" "$$" >"$LOG"
  vigiar_log "$$" &
  # Um daemon aberto sem supervisor (num terminal do proot) passa para este
  if [ -n "$(pids_daemon)" ]; then matar_daemon || true; fi
  local inicio d
  # Sai quando o pacote é desinstalado ou quando um serviço do systemd, instalado
  # depois, assume o daemon
  while [ -e "$self" ] && ! servico; do
    if [ -e "$PARADO" ]; then
      sleep 2
      continue
    fi
    d=$(daemon_atual)
    printf '== %s daemon iniciado: %s\n' "$(date '+%F %T')" "$(readlink -f "$d")" >>"$LOG"
    inicio=$SECONDS
    "$d" >>"$LOG" 2>&1 </dev/null 8>&- || true
    printf '== %s daemon terminou\n' "$(date '+%F %T')" >>"$LOG"
    # Caiu logo depois de subir: espera antes de tentar de novo
    if [ $((SECONDS - inicio)) -lt 30 ] && [ ! -e "$PARADO" ]; then sleep 10; fi
  done
  printf '== %s supervisor saiu\n' "$(date '+%F %T')" >>"$LOG"
}

# O log do daemon cresce sem parar. Acima de 10 MiB, ele vira tailscaled.log.1
# e recomeça vazio; o daemon escreve no fim do arquivo (>>), que volta ao zero.
# Sai junto com o supervisor (pid em $1).
vigiar_log() {
  exec 8>&- # não segura a trava do supervisor
  while sleep 60 && kill -0 "$1" 2>/dev/null; do
    if [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
      cp -f "$LOG" "$LOG.1" && : >"$LOG"
    fi
  done
}

iniciar() {
  if servico; then
    if vivo && ! ctl is-active --quiet sambbi-vpn; then
      echo "o daemon da VPN já está no ar, fora do serviço do systemd. Para passar ao serviço (a VPN cai por alguns segundos): sambbi-vpn reiniciar"
      return 0
    fi
    ctl start sambbi-vpn
    if ate 20 vivo; then
      echo "daemon da VPN no ar, pelo serviço do systemd"
      return 0
    fi
    echo "erro: o daemon da VPN não respondeu em 20 s; veja o log: $(journal)" >&2
    return 1
  fi
  pasta
  # Consulta antes de apagar o aviso de parado: depois, o supervisor pode subir
  # o daemon durante a consulta, e a resposta seria dele. Se o comando de fora
  # acabou de abrir um supervisor, quem sobe o daemon é ele: só espera.
  if [ -z "${SAMBBI_VPN_SUPERVISOR_FORA:-}" ] && vivo; then
    rm -f "$PARADO"
    echo "o daemon da VPN já está no ar ($SAMBBI_VPN_SOCKET)"
    return 0
  fi
  rm -f "$PARADO"
  if supervisor_no_ar; then
    : # ele vê que o aviso de parado sumiu e sobe o daemon
  elif [ -z "${NIX_PROOT:-}" ]; then
    setsid nohup "$self" supervisionar >/dev/null 2>&1 </dev/null &
  elif [ -n "${SAMBBI_VPN_SUPERVISOR_FORA:-}" ]; then
    # O ~/.local/bin/sambbi-vpn acabou de abrir o supervisor, fora do proot
    if ! ate 10 supervisor_no_ar; then
      echo "erro: o supervisor da VPN não subiu; veja $LOG" >&2
      return 1
    fi
  elif [ "$(cat "/proc/$PPID/comm" 2>/dev/null || true)" = proot ]; then
    # Chamado pelo nixp, de fora: o proot dele esperaria o daemon terminar
    echo "erro: pelo nixp, este comando não voltaria. Fora dos terminais, use: ~/.local/bin/sambbi-vpn iniciar" >&2
    return 1
  else
    setsid nohup "$(daemon_atual)" >"$LOG" 2>&1 </dev/null &
    echo "aviso: sem um supervisor no ar, o daemon subiu dentro do proot deste terminal e cai junto com ele. O próximo terminal que você abrir sobe o supervisor, que assume o daemon."
  fi
  if ate 20 vivo; then
    echo "daemon da VPN no ar; log em $LOG"
    return 0
  fi
  echo "erro: o daemon da VPN não respondeu em 20 s" >&2
  tail -n 20 "$LOG" >&2 || true
  return 1
}

parar() {
  if servico; then
    ctl stop sambbi-vpn
    # Um daemon de fora do serviço, de um supervisor anterior a ele. O aviso de
    # parado segura o supervisor, que sai em seguida, ao ver o serviço.
    if [ -n "$(pids_daemon)" ]; then
      pasta
      : >"$PARADO"
      matar_daemon || true
    fi
    echo "daemon da VPN parado"
    return 0
  fi
  pasta
  : >"$PARADO"
  if [ -z "$(pids_daemon)" ]; then
    echo "nenhum daemon da VPN desta conta está no ar"
    return 0
  fi
  if matar_daemon; then
    echo "daemon da VPN parado"
    return 0
  fi
  echo "erro: o daemon da VPN não parou" >&2
  return 1
}

# Quem sobe o daemon de novo é o systemd ou o supervisor, não este comando: se
# ele cair no meio, como numa sessão SSH pela própria VPN, a VPN volta assim mesmo.
reiniciar() {
  local p principal pids fora=()
  if servico; then
    # Um daemon de fora do serviço segura a trava do estado. O do serviço espera
    # por ela até 10 s, e ela se solta quando o de fora termina.
    principal=$(ctl show -p MainPID --value sambbi-vpn 2>/dev/null || echo 0)
    mapfile -t pids < <(pids_daemon)
    for p in "${pids[@]}"; do
      if [ "$p" != "$principal" ]; then fora+=("$p"); fi
    done
    ctl restart sambbi-vpn
    if [ "${#fora[@]}" -gt 0 ]; then
      pasta
      : >"$PARADO" # o supervisor dele fica parado e sai, ao ver o serviço
      kill "${fora[@]}" 2>/dev/null || true
      for p in "${fora[@]}"; do ate 10 sem_pid "$p" || true; done
    fi
    if ate 30 vivo; then
      ate 20 assentado || true
      echo "daemon da VPN reiniciado, pelo serviço do systemd"
      return 0
    fi
    echo "erro: o daemon da VPN não voltou em 30 s; veja o log: $(journal)" >&2
    return 1
  fi
  mapfile -t pids < <(pids_daemon)
  if [ "${#pids[@]}" -eq 0 ] || [ -e "$PARADO" ] || ! supervisor_no_ar; then
    iniciar # nada a reiniciar: só sobe
    return
  fi
  # Sem o aviso de parado, o supervisor sobe o daemon de novo
  kill "${pids[@]}" 2>/dev/null || true
  for p in "${pids[@]}"; do ate 10 sem_pid "$p" || true; done
  if ate 30 vivo; then
    ate 20 assentado || true
    echo "daemon da VPN reiniciado; log em $LOG"
    return 0
  fi
  echo "erro: o daemon da VPN não voltou em 30 s; veja $LOG" >&2
  return 1
}

entrar() {
  local nome='' chave='' args
  while [ "$#" -gt 0 ]; do
    case $1 in
      --nome) nome=${2:?falta o nome depois de --nome}; shift 2 ;;
      --chave) chave=${2:?falta o arquivo depois de --chave}; shift 2 ;;
      *) uso >&2; exit 2 ;;
    esac
  done
  vivo || iniciar
  ate 20 assentado || true
  if [ "$(estado)" = Running ]; then
    echo "esta máquina já está na VPN: $(t ip -4 2>/dev/null || true)"
    return 0
  fi
  if [ -z "$nome" ]; then
    nome=$(uname -n)
    nome=${nome%%.*}
  fi
  args=(up --reset --login-server="$SAMBBI_VPN_SERVIDOR" --hostname="$nome" --accept-dns=false --timeout=15m)
  # Com root via sudo, quem rodou o sudo também controla a VPN sem sudo
  if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then args+=(--operator="$SUDO_USER"); fi
  if [ -n "$chave" ]; then
    args+=(--auth-key="file:$chave")
  else
    echo "Sem chave de cadastro: o tailscale vai mostrar um endereço. Ele mostra o comando que o admin roda na VM para aprovar (headscale auth register ...). O pedido vale 15 min."
  fi
  t "${args[@]}"
  echo "na VPN como $nome: $(t ip -4 2>/dev/null || true)"
}

case ${1:-} in
  iniciar) iniciar ;;
  parar) parar ;;
  reiniciar) reiniciar ;;
  entrar) shift; entrar "$@" ;;
  supervisionar) shift; supervisionar "$@" ;;
  '' | -h | --help | ajuda) uso ;;
  *) exec tailscale --socket="$SAMBBI_VPN_SOCKET" "$@" ;;
esac
