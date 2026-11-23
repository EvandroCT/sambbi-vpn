#!/usr/bin/env bash
# Instala o cliente da VPN sambbi, com ou sem root.
# https://github.com/EvandroCT/sambbi-vpn (licença GNU AGPL 3.0)
#
#   bash <(curl -fsSL https://github.com/EvandroCT/sambbi-vpn/raw/main/instalar-vpn.sh) [opções]
#
# Pode rodar de novo: o que já está feito fica como está. Os passos:
# 1. O Nix, pelo nixinstall (github.com/EvandroCT/nixinstall).
# 2. O pacote deste flake, num perfil próprio do Nix: sambbi-vpn, sambbi-vpnd,
#    vpn-teste e rclone.
# 3. O daemon da VPN (tailscaled), como serviço sempre que der:
#    - root com systemd: serviço do sistema, com a rede do kernel;
#    - sem root, com o systemd do usuário: serviço do usuário. Ele sobe no boot
#      se o linger for aceito; senão, no login;
#    - sem systemd (pod, contêiner): um supervisor faz o papel do serviço,
#      até o próximo reinício. Depois dele, a VPN sobe com sambbi-vpn iniciar;
#      com o Nix pelo proot, sobe sozinha ao abrir um terminal
# 4. O cadastro: com a chave de cadastro, se houver; senão, com um pedido que o
#    admin aprova na VM.
# 5. O remote nas do rclone, com a senha do FTP, se você a digitar.
set -Eeuo pipefail
trap 'printf "erro: o passo da linha %s falhou\n" "$LINENO" >&2' ERR

FLAKE=${SAMBBI_VPN_FLAKE:-github:EvandroCT/sambbi-vpn}
NIXINSTALL=https://github.com/EvandroCT/nixinstall/raw/main/instalar-nix.sh
NAS=100.64.0.1 # o NAS na VPN
PROXY=${SAMBBI_VPN_PROXY:-127.0.0.1:1055}
MARCA='sambbi-vpn: comandos da VPN no PATH'
MARCA_PROOT='sambbi-vpn: VPN com o Nix pelo proot'

diz() { printf '==> %s\n' "$*"; }
morre() { printf 'erro: %s\n' "$*" >&2; exit 1; }

uso() {
  cat <<'EOF'
uso: instalar-vpn.sh [--proot] [--nome NOME] [--chave ARQUIVO]

Instala o Nix (se preciso), o cliente da VPN sambbi e o rclone. Sobe a VPN como
serviço sempre que der e cadastra a máquina.

  --proot          Nix em ~/.nix, pelo proot: para quem não tem root nem um /nix
                   persistente (github.com/EvandroCT/nixinstall)
  --nome NOME      nome desta máquina na VPN (sem a opção, o script pergunta)
  --chave ARQUIVO  chave de cadastro criada na VM. Sem ela, o script pede a
                   chave; sem chave, faz um pedido para o admin aprovar na VM

Com sudo: curl -fsSL URL | sudo bash -s -- [opções]
Detalhes: https://github.com/EvandroCT/sambbi-vpn
EOF
}

# pergunta VARIÁVEL TEXTO [-s]: lê do terminal (-s: sem eco). Falha sem terminal.
pergunta() {
  { : </dev/tty; } 2>/dev/null || return 1
  local resposta
  if [ "${3:-}" = -s ]; then
    IFS= read -rs -p "$2" resposta </dev/tty
    printf '\n' >/dev/tty
  else
    IFS= read -r -p "$2" resposta </dev/tty
  fi
  printf -v "$1" '%s' "$resposta"
}

# Acha um nix que responda, no PATH ou nos perfis de sempre, e o guarda em NIX.
achar_nix() {
  local n
  for n in "$(command -v nix || true)" "$HOME/.nix-profile/bin/nix" \
    /nix/var/nix/profiles/default/bin/nix /run/current-system/sw/bin/nix; do
    if [ -n "$n" ] && [ -x "$n" ] && "$n" --version >/dev/null 2>&1; then
      NIX=("$n")
      return 0
    fi
  done
  return 1
}

PROOT=0 NOME='' CHAVE=''
while [ "$#" -gt 0 ]; do
  case $1 in
    --proot) PROOT=1; shift ;;
    --nome) [ "$#" -ge 2 ] || morre "falta o nome depois de --nome"; NOME=$2; shift 2 ;;
    --chave) [ "$#" -ge 2 ] || morre "falta o arquivo depois de --chave"; CHAVE=$2; shift 2 ;;
    -h | --help) uso; exit 0 ;;
    *) printf 'erro: opção desconhecida: %s\n\n' "$1" >&2; uso >&2; exit 2 ;;
  esac
done
if [ -n "$CHAVE" ]; then
  [ -r "$CHAVE" ] || morre "não consigo ler a chave: $CHAVE"
  CHAVE=$(cd "$(dirname "$CHAVE")" && pwd)/$(basename "$CHAVE")
fi
eu=$(id -u)
TMPCHAVE=''
trap '[ -z "$TMPCHAVE" ] || rm -f "$TMPCHAVE"' EXIT

diz "1/5 Nix, pelo nixinstall"
tmp=$(mktemp)
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp" "$NIXINSTALL"
# A entrada vazia protege o caso `curl | bash -s`, em que o resto deste script
# chega pela entrada padrão. O sudo pede a senha pelo terminal mesmo assim.
if [ "$PROOT" = 1 ]; then bash "$tmp" --proot </dev/null; else bash "$tmp" </dev/null; fi
rm -f "$tmp"

# Com o Nix pelo proot, os comandos do Nix e do pacote passam pelo nixp
PFX=()
if [ "$eu" != 0 ] && [ -d "$HOME/.nix/store" ] && [ -x "$HOME/.local/bin/nixp" ]; then
  PFX=("$HOME/.local/bin/nixp")
  NIX=("$HOME/.nix-profile/bin/nix")
else
  achar_nix || morre "o Nix não responde"
fi
nix_() { ${PFX[@]+"${PFX[@]}"} "${NIX[@]}" --extra-experimental-features 'nix-command flakes' "$@"; }
if [ "$eu" = 0 ]; then
  PERFIL=/nix/var/nix/profiles/sambbi-vpn
else
  PERFIL=${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/sambbi-vpn
fi
B=$PERFIL/bin
# Com o Nix pelo proot, o comando da VPN passa pelo ~/.local/bin/sambbi-vpn (passo 2)
if [ "${#PFX[@]}" -gt 0 ]; then
  vpn() { "$HOME/.local/bin/sambbi-vpn" "$@"; }
else
  vpn() { "$B/sambbi-vpn" "$@"; }
fi
rclone_() { ${PFX[@]+"${PFX[@]}"} "$B/rclone" "$@"; }
vivo() { vpn status --json >/dev/null 2>&1; }
# Logo depois de o daemon subir, o estado passa por NoState e Starting: espera
# ele assentar, por até 20 s
na_vpn() {
  local j fim=$((SECONDS + 20))
  while :; do
    j=$(vpn status --json 2>/dev/null || true)
    case $j in
      *'"BackendState": "Running"'*) return 0 ;;
      *'"BackendState": "NoState"'* | *'"BackendState": "Starting"'*) ;;
      *) return 1 ;;
    esac
    if [ "$SECONDS" -ge "$fim" ]; then return 1; fi
    sleep 1
  done
}

# A versão no perfil: o caminho no store, lido dos links do perfil (sem
# segui-los até o fim, o que pelo proot não daria)
versao() {
  local g
  g=$(readlink "$PERFIL" 2>/dev/null) || return 0
  case $g in /*) ;; *) g=${PERFIL%/*}/$g ;; esac
  readlink "$g" 2>/dev/null || true
}

diz "2/5 pacote da VPN ($FLAKE) no perfil $PERFIL"
mkdir -p "${PERFIL%/*}"
antes=$(versao)
nix_ build --refresh --no-link --profile "$PERFIL" "$FLAKE"
depois=$(versao)
if [ "$eu" = 0 ]; then
  mkdir -p /usr/local/bin
  for c in sambbi-vpn vpn-teste rclone; do
    l=/usr/local/bin/$c
    if [ -L "$l" ] && [ "$(readlink "$l")" = "$B/$c" ]; then continue; fi
    if [ -e "$l" ] || [ -L "$l" ]; then
      diz "aviso: $l já existe e fica como está; o da VPN está em $B/$c"
      continue
    fi
    ln -s "$B/$c" "$l"
  done
else
  # O arquivo que o shell de login lê, o mesmo do nixinstall
  alvo=''
  for f in .bash_profile .bash_login .profile; do
    if [ -e "$HOME/$f" ]; then alvo=$HOME/$f; break; fi
  done
  alvo=${alvo:-$HOME/.profile}
fi
if [ "$eu" = 0 ]; then
  :
elif [ "${#PFX[@]}" -gt 0 ]; then
  # Nix pelo proot. Um processo aberto dentro do proot de um terminal morre com o
  # terminal, e o nixp de um comando só volta quando terminam todos os processos
  # dele. Por isso o daemon roda sob um supervisor com um proot só dele, aberto
  # fora de qualquer outro proot por este comando: ao abrir um terminal, pelo
  # bloco abaixo, e em "iniciar" fora dos terminais (notebooks, scripts).
  mkdir -p "$HOME/.local/bin"
  cat >"$HOME/.local/bin/sambbi-vpn" <<EOF
#!/bin/sh
# sambbi-vpn para o Nix pelo proot, gravado por instalar-vpn.sh
# (github.com/EvandroCT/sambbi-vpn). Uma nova instalação o reescreve.
#
# Fora do proot, "iniciar" e "--supervisor" sobem o supervisor da VPN num proot
# só dele, que não cai com nenhum terminal; ele sai na hora se já houver outro.
# O caminho do perfil vai também como argumento, porque pelo proot o \$0 do
# script chega resolvido até o store. O resto vai para o sambbi-vpn do perfil,
# pelo nixp.
p='$B/sambbi-vpn'
n="\$HOME/.local/bin/nixp"
if [ -z "\${NIX_PROOT:-}" ]; then
  case \${1:-} in
    --supervisor | iniciar)
      s=\$(command -v setsid || true)
      (\${s:+"\$s"} nohup "\$n" "\$p" supervisionar "\$p" >/dev/null 2>&1 </dev/null &)
      if [ "\$1" = --supervisor ]; then exit 0; fi
      SAMBBI_VPN_SUPERVISOR_FORA=1
      export SAMBBI_VPN_SUPERVISOR_FORA
      ;;
  esac
fi
exec "\$n" "\$p" "\$@"
EOF
  chmod 755 "$HOME/.local/bin/sambbi-vpn"
  # O bloco vem antes do bloco do nixinstall, que leva o terminal para o proot
  if ! grep -qF "$MARCA_PROOT" "$alvo" 2>/dev/null; then
    tmp=$(mktemp)
    {
      cat <<EOF
# >>> $MARCA_PROOT >>>
# Fora do proot, ao abrir um terminal, sobe o supervisor da VPN, num proot só
# dele (se ele já estiver no ar, nada muda). Dentro do proot, os comandos no PATH.
if [ -z "\${NIX_PROOT:-}" ]; then
    if [ -x "\$HOME/.local/bin/sambbi-vpn" ]; then "\$HOME/.local/bin/sambbi-vpn" --supervisor; fi
else
    case ":\$PATH:" in *":$B:"*) ;; *) PATH="$B:\$PATH" ;; esac
fi
# <<< $MARCA_PROOT <<<

EOF
      if [ -e "$alvo" ]; then cat "$alvo"; fi
    } >"$tmp"
    cat "$tmp" >"$alvo" # escreve através de um eventual link
    rm -f "$tmp"
    diz "$alvo: bloco da VPN no início do arquivo, antes do bloco que abre o proot"
  fi
else
  if ! grep -qF "$MARCA" "$alvo" 2>/dev/null; then
    cat >>"$alvo" <<EOF

# >>> $MARCA >>>
case ":\$PATH:" in *":$B:"*) ;; *) PATH="$B:\$PATH" ;; esac
# <<< $MARCA <<<
EOF
    diz "$alvo: $B no PATH"
  fi
fi

diz "3/5 daemon da VPN"
modo=sessão
# Um daemon que já estava no ar segue na versão anterior do pacote
antigo=0
if [ -n "$antes" ] && [ "$antes" != "$depois" ] && vivo; then antigo=1; fi
# Um daemon no ar fora do serviço do systemd (de um supervisor anterior a ele)
fora=0
if [ "$eu" = 0 ]; then
  if [ -e /etc/NIXOS ]; then
    diz "aviso: no NixOS, um serviço permanente vem do configuration.nix, que este script não altera"
  elif [ -d /run/systemd/system ]; then
    cat >/etc/systemd/system/sambbi-vpn.service <<EOF
[Unit]
Description=VPN sambbi (tailscaled)
Documentation=https://github.com/EvandroCT/sambbi-vpn
Wants=network-pre.target
After=network-pre.target NetworkManager.service systemd-resolved.service

[Service]
ExecStart=$B/sambbi-vpnd
ExecStopPost=$B/sambbi-vpnd --cleanup
Restart=on-failure
RuntimeDirectory=sambbi-vpn
RuntimeDirectoryMode=0755
StateDirectory=sambbi-vpn
StateDirectoryMode=0700

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if systemctl is-active --quiet sambbi-vpn || ! vivo; then
      systemctl enable --now sambbi-vpn
    else
      systemctl enable sambbi-vpn
      fora=1
    fi
    modo=sistema
  fi
elif command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
  d=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
  mkdir -p "$d"
  cat >"$d/sambbi-vpn.service" <<EOF
[Unit]
Description=VPN sambbi (tailscaled sem root)
Documentation=https://github.com/EvandroCT/sambbi-vpn

[Service]
ExecStart=${PFX[*]+${PFX[*]} }$B/sambbi-vpnd
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  if systemctl --user is-active --quiet sambbi-vpn || ! vivo; then
    systemctl --user enable --now sambbi-vpn
  else
    systemctl --user enable sambbi-vpn
    fora=1
  fi
  modo=usuário
  if [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)" = yes ]; then
    :
  elif loginctl --no-ask-password enable-linger 2>/dev/null; then
    diz "linger ligado: o serviço sobe no boot, mesmo sem login"
  else
    diz "aviso: sem linger, o serviço sobe só quando você faz login"
  fi
fi
# Trocar o daemon no ar derruba a VPN por alguns segundos, e com ela uma sessão
# SSH que passe por ela: a troca fica a cargo de quem roda o instalador.
if [ "$fora" = 1 ]; then
  diz "aviso: já há um daemon da VPN no ar, iniciado fora do serviço. O serviço fica ligado para o próximo boot; para passar a ele agora (a VPN cai por alguns segundos): sambbi-vpn reiniciar"
else
  vpn iniciar
  if [ "$antigo" = 1 ]; then
    diz "aviso: o daemon no ar segue na versão anterior do pacote. Para trocar agora (a VPN cai por alguns segundos): sambbi-vpn reiniciar"
  fi
fi

diz "4/5 cadastro"
if na_vpn; then
  diz "esta máquina já está na VPN"
else
  if [ -z "$NOME" ]; then
    padrao=$(uname -n)
    padrao=${padrao%%.*}
    pergunta NOME "Nome desta máquina na VPN [$padrao]: " || true
    NOME=${NOME:-$padrao}
  fi
  if [ -z "$CHAVE" ]; then
    k=''
    pergunta k "Chave de cadastro (não aparece; Enter para pedir aprovação na VM): " -s || true
    if [ -n "$k" ]; then
      TMPCHAVE=$(umask 077 && mktemp)
      printf '%s\n' "$k" >"$TMPCHAVE"
      CHAVE=$TMPCHAVE
    fi
    k=''
  fi
  vpn entrar --nome "$NOME" ${CHAVE:+--chave "$CHAVE"}
fi

diz "5/5 remote nas do rclone"
remotos=$(rclone_ listremotes 2>/dev/null || true)
case $'\n'$remotos$'\n' in
  *$'\n'nas:$'\n'*) tem_nas=1 ;;
  *) tem_nas=0 ;;
esac
if [ "$tem_nas" = 1 ]; then
  diz "o remote nas já existe e fica como está"
else
  u=''
  pergunta u "Usuário do FTP do NAS (Enter pula o rclone): " || true
  if [ -z "$u" ]; then
    diz "remote nas não criado; para criá-lo depois, rode este instalador de novo num terminal"
  else
    s=''
    pergunta s "Senha do FTP (não aparece; Enter deixa para depois): " -s || true
    conf=$(rclone_ config file | tail -n 1)
    if [ -f "$conf" ] && grep -q 'Encrypted rclone configuration' "$conf"; then
      morre "a configuração do rclone ($conf) é cifrada: crie o remote nas à mão, com rclone config"
    fi
    obsc=''
    if [ -n "$s" ]; then obsc=$(printf '%s\n' "$s" | rclone_ obscure -); fi
    s=''
    mkdir -p "${conf%/*}"
    # O FTP do QNAP responde 550 ao MLSD na pasta home dos usuários (e em tudo
    # dentro dela), embora o LIST funcione: o remote usa só o LIST.
    (
      umask 077
      printf '\n[nas]\ntype = ftp\nhost = %s\nuser = %s\n' "$NAS" "$u"
      if [ -n "$obsc" ]; then printf 'pass = %s\n' "$obsc"; fi
      printf 'socks_proxy = %s\ndisable_mlsd = true\n' "$PROXY"
    ) >>"$conf"
    chmod 600 "$conf"
    if [ -n "$obsc" ]; then
      diz "remote nas criado em $conf"
    else
      diz "remote nas criado sem senha; para pô-la: rclone config, editar nas, campo pass"
    fi
  fi
fi

echo
case $modo in
  sistema) diz "pronto: a VPN é um serviço do sistema (systemctl status sambbi-vpn) e sobe no boot" ;;
  usuário) diz "pronto: a VPN é um serviço do seu usuário (systemctl --user status sambbi-vpn)" ;;
  *)
    if [ "${#PFX[@]}" -gt 0 ]; then
      diz "pronto: a VPN fica no ar sob um supervisor, num proot só dele, que não cai com os terminais. Depois de um reinício, ela sobe ao abrir um terminal"
    else
      diz "pronto: a VPN fica no ar sob um supervisor até o próximo reinício. Depois dele, suba de novo com: sambbi-vpn iniciar"
    fi
    ;;
esac
diz "num terminal novo: sambbi-vpn status, sambbi-vpn ping nas, vpn-teste, rclone lsd nas:"
if [ "${#PFX[@]}" -gt 0 ]; then
  diz "fora dos terminais (notebooks, scripts): ~/.local/bin/sambbi-vpn COMANDO; para o rclone e o vpn-teste, ponha nixp antes"
fi
