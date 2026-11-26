# sambbi-vpn

Cliente da VPN sambbi (Headscale + Tailscale) para Linux, com ou sem root: instala o Nix se preciso, o tailscale e o rclone por este flake, sobe a VPN como serviço sempre que dá e cadastra a máquina.

```sh
bash <(curl -fsSL https://github.com/EvandroCT/sambbi-vpn/raw/main/instalar-vpn.sh)
```

Pode rodar de novo: o que já está feito fica como está, e o pacote é atualizado para a versão atual do flake. Um daemon que já estava no ar segue na versão anterior até `sambbi-vpn reiniciar` ou até o próximo reinício. O instalador não o troca sozinho, porque a troca derruba a VPN por alguns segundos, e com ela uma sessão SSH que passe por ela.

| Opção | Para quê |
|---|---|
| `--proot` | Sem root e sem um `/nix` persistente, como num pod de JupyterHub em que a TI dá um `/nix` vazio a cada sessão. O Nix fica em `~/.nix`, pelo proot ([nixinstall](https://github.com/EvandroCT/nixinstall)) |
| `--nome NOME` | Nome desta máquina na VPN. Sem a opção, o instalador pergunta |
| `--chave ARQUIVO` | Chave de cadastro criada na VM. Sem a opção, o instalador pede a chave no terminal |

Com sudo, o script vem pela entrada padrão: `curl -fsSL URL | sudo bash -s -- [opções]`.

## O que o instalador faz

1. Instala o Nix pelo [nixinstall](https://github.com/EvandroCT/nixinstall): no `/nix` por padrão, ou pelo proot com `--proot`.
2. Instala o pacote deste flake num perfil próprio do Nix: `/nix/var/nix/profiles/sambbi-vpn` com root, `~/.local/state/nix/profiles/sambbi-vpn` sem root. Os comandos entram no `PATH` por links em `/usr/local/bin` (root) ou por um bloco no fim do `~/.profile`.

   Sem root, se o `~/.ssh/config` tiver a linha `ProxyCommand tailscale --socket=…/tailscale-user/tailscaled.sock nc %h %p`, de uma instalação manual anterior, o instalador a troca por `ProxyCommand CAMINHO/sambbi-vpn nc %h %p`. Com o caminho completo do comando, o SSH alcança a VPN também fora dos terminais. O arquivo anterior fica em `~/.ssh/config.antes-sambbi-vpn`. Com root, o `~/.ssh/config` fica como está, porque com sudo o `HOME` pode ser o de outro usuário.
3. Sobe o daemon da VPN (o `tailscaled`), como serviço sempre que dá:

   | Máquina | Daemon | Rede |
   |---|---|---|
   | Root com systemd | Serviço do sistema (`sambbi-vpn.service`), que sobe no boot | Do kernel, na interface `sambbi0` |
   | Root no NixOS | Serviço do sistema, se o [módulo](#nixos) estiver no `configuration.nix`. Sem ele, supervisor, e o instalador mostra o trecho a acrescentar | Do kernel, na interface `sambbi0` |
   | Sem root, com o systemd do usuário | Serviço do usuário. Com o linger, sobe no boot; sem ele, no login | No espaço do usuário |
   | Sem systemd (contêiner) | Supervisor, até o próximo reinício. Depois dele: `sambbi-vpn iniciar` | No espaço do usuário; root com `/dev/net/tun` e `CAP_NET_ADMIN` usa a do kernel |
   | Nix pelo proot, sem systemd (pod) | Supervisor, que sobe ao abrir um terminal ([detalhes](#com-o-nix-pelo-proot)) | No espaço do usuário |

   O serviço e o supervisor rodam o mesmo comando, `sambbi-vpnd`. Sem systemd, o supervisor faz o papel do serviço: roda o daemon e o sobe de novo se ele cair. Depois de `sambbi-vpn parar`, o daemon fica parado até `sambbi-vpn iniciar` ou até o próximo reinício. O log do daemon fica em `tailscaled.log`, na pasta de estado; o da sessão anterior, ou o que passar de 10 MiB, vai para `tailscaled.log.1`.

   Na rede do espaço do usuário, os programas alcançam a VPN pelo proxy SOCKS5 e HTTP em `127.0.0.1:1055`. O proxy fica no ar em todos os modos.
4. Cadastra a máquina, se ela ainda não estiver na VPN:
   - **Com chave:** o admin cria a chave na VM, com `headscale preauthkeys create --user ID --expiration 10m`. O instalador a lê de `--chave ARQUIVO` ou do terminal, sem eco, e não a guarda.
   - **Sem chave:** o tailscale mostra um endereço com o comando que o admin roda na VM, `headscale auth register --auth-id ID --user USUÁRIO`. O pedido vale 15 minutos.
   - Sem root, o estado fica em `~/.local/state/tailscale-user`, a pasta das instalações manuais anteriores: um cadastro já feito continua valendo.
5. Cria o remote `nas` do rclone: FTP no NAS (`100.64.0.1`), pelo proxy. O instalador pergunta o usuário e a senha do FTP, que não aparece na tela. Enter pula. O rclone guarda a senha ofuscada, não cifrada, num arquivo com permissão 600: quem consegue ler o arquivo descobre a senha.
   - O remote usa `disable_mlsd = true`. O FTP do QNAP responde `550 No such file or directory` ao `MLSD` na pasta `home` de cada usuário e em tudo dentro dela, embora o `LIST` funcione.
   - A pasta de cada usuário aparece na raiz do FTP como `home`. A pasta com o nome do usuário, quando existe, é uma pasta compartilhada comum.

## Comandos

| Comando | O que faz |
|---|---|
| `sambbi-vpn iniciar` | Sobe o daemon: pelo serviço do systemd, se houver; senão, pelo supervisor |
| `sambbi-vpn parar` | Para o daemon. Sem systemd, ele fica parado até o próximo `iniciar` ou até um reinício |
| `sambbi-vpn reiniciar` | Troca o daemon no ar pelo da versão instalada agora. Quem o sobe de novo é o systemd ou o supervisor: se o comando cair no meio, como numa sessão SSH pela própria VPN, a VPN volta assim mesmo. Prefira-o a `parar` seguido de `iniciar` |
| `sambbi-vpn entrar [--nome NOME] [--chave ARQUIVO]` | Cadastra a máquina |
| `sambbi-vpn status`, `ip`, `ping 100.64.0.1`, `netcheck`, `nc HOST PORTA`... | Comandos do tailscale, com o socket certo |
| `vpn-teste [MiB]` | Caminho (direto ou retransmissor), latência e velocidade do FTP até o NAS, nos dois sentidos. O arquivo vai para `teste-vpn/`, dentro da pasta com o nome do usuário ou da `home` (ou para `NAS_DIR`), e é apagado no fim. O NAS é achado pelo endereço na VPN, `100.64.0.1` (ou `NAS_IP`), e não pelo nome, que pode mudar |
| `rclone lsd nas:` | O NAS pelo rclone |

O ambiente de produção, sem instalar nada no perfil: `nix develop github:EvandroCT/sambbi-vpn`.

## NixOS

No NixOS, `/etc/systemd/system` vem do Nix store, e o instalador não cria o serviço do sistema. Os links que ele põe em `/usr/local/bin` também ficam fora do `PATH`. O serviço vem do módulo deste flake, no `configuration.nix`:

```nix
imports = [ (builtins.getFlake "github:EvandroCT/sambbi-vpn").nixosModules.default ];
services.sambbi-vpn = {
  enable = true;
  portasTCP = [ 22 ];  # opcional: portas abertas só para a VPN
};
```

Fora de um flake, prefira fixar o commit, como em `github:EvandroCT/sambbi-vpn/HASH`. Sem o hash, cada `nixos-rebuild` pega a versão do momento, e o Nix guarda a cópia baixada por até 1 hora. Se o root baixou uma versão anterior ao módulo nessa janela, por exemplo com o instalador, a avaliação falha com `attribute 'nixosModules' missing`. Num `configuration.nix` de flake, use o flake como input e `inputs.sambbi-vpn.nixosModules.default`.

O módulo declara a mesma unidade que o instalador cria nas outras distribuições, com a rede do kernel. Ele também põe o perfil `/nix/var/nix/profiles/sambbi-vpn` no `PATH` de todos e deixa a `sambbi0` fora do NetworkManager. O pacote continua no perfil do instalador, que o atualiza. Por isso, rode o instalador com root antes ou depois do `nixos-rebuild switch`: sem o perfil, o serviço não sobe, mas também não falha.

Com o serviço declarado:
- `sudo sambbi-vpn iniciar|parar|reiniciar` usa o systemctl, e `systemctl status sambbi-vpn` também funciona;
- sem sudo, use o `sambbi-vpn` só para consultas. Ele cai no socket do sistema, mas um `iniciar` sem sudo subiria um segundo daemon, sem root;
- o cadastro com sudo (pelo instalador ou por `sudo sambbi-vpn entrar`) dá ao usuário o papel de operador (`--operator`), e o `tailscale` funciona sem sudo para ele.

Para passar um cliente sem root para o serviço, com o mesmo nó:
1. instale o perfil do sistema, com `sudo nix build --profile /nix/var/nix/profiles/sambbi-vpn github:EvandroCT/sambbi-vpn`;
2. ponha o módulo no `configuration.nix`;
3. pare o cliente sem root, com `systemctl --user disable --now sambbi-vpn`;
4. copie `~/.local/state/tailscale-user/tailscaled.state` para `/var/lib/sambbi-vpn/`, com a pasta em 0700, o arquivo em 0600 e ambos de root;
5. rode `sudo nixos-rebuild switch` e `sudo sambbi-vpn set --operator=$USER`;
6. desinstale o resto do cliente sem root ([Desinstalar](#desinstalar), passos 1 e 2).

## Com o Nix pelo proot

Os terminais abrem dentro do proot. Um processo aberto ali dentro morre quando o terminal é encerrado, e um `nixp COMANDO` só volta quando terminam todos os processos que o comando abriu. Por isso o supervisor da VPN roda num proot só dele, aberto fora de qualquer outro:

- **ao abrir um terminal**, por um bloco no início do `~/.profile`, antes do bloco do nixinstall. Se o supervisor já estiver no ar, nada muda;
- **fora dos terminais** (notebooks, scripts), por `~/.local/bin/sambbi-vpn iniciar`. Esse comando aceita os outros subcomandos também, como `~/.local/bin/sambbi-vpn status`.

Fora dos terminais, o `PATH` não tem o perfil da VPN. Por isso o rclone e o vpn-teste também ganham um comando em `~/.local/bin`: `~/.local/bin/rclone lsd nas:` e `~/.local/bin/vpn-teste`. Se um desses arquivos já existir e não for do instalador, ele fica como está, e o instalador avisa.

Encerrar um terminal não derruba a VPN.

Sem um supervisor no ar, `sambbi-vpn iniciar` num terminal sobe o daemon dentro do proot desse terminal e avisa. O daemon cai junto com o terminal, a menos que outro terminal seja aberto antes: o supervisor que ele sobe assume o daemon. Isso só acontece quando a VPN é instalada num terminal que já abriu dentro do proot.

## Cuidados

- O proxy em `127.0.0.1:1055` aceita qualquer usuário da máquina, sem senha. Numa máquina compartilhada, todos alcançam a VPN por ele; com a rede do kernel, também.
- Dois usuários sem root na mesma máquina disputam a porta 1055. Mude a de um deles com `SAMBBI_VPN_PROXY`.
- O instalador não mexe na configuração do NixOS. Lá, o serviço do sistema vem do [módulo](#nixos).

## Variáveis

Valem para o instalador e para os comandos:

| Variável | Padrão |
|---|---|
| `SAMBBI_VPN_SERVIDOR` | `https://sambbi.duckdns.org` |
| `SAMBBI_VPN_PROXY` | `127.0.0.1:1055` |
| `SAMBBI_VPN_ESTADO` | `/var/lib/sambbi-vpn` com root; `~/.local/state/tailscale-user` sem root |
| `SAMBBI_VPN_SOCKET` | `/run/sambbi-vpn/tailscaled.sock` com root; `tailscaled.sock` na pasta de estado sem root |
| `SAMBBI_VPN_FLAKE` | `github:EvandroCT/sambbi-vpn` (só o instalador) |

## Desinstalar

1. Pare o daemon e desligue o serviço:
   - root: `systemctl disable --now sambbi-vpn && rm /etc/systemd/system/sambbi-vpn.service`. No NixOS, tire o módulo do `configuration.nix` e rode `nixos-rebuild switch`;
   - serviço do usuário: `systemctl --user disable --now sambbi-vpn && rm ~/.config/systemd/user/sambbi-vpn.service`;
   - supervisor: `sambbi-vpn parar`. O supervisor sai sozinho quando o perfil é apagado (passo 2).
2. Apague o perfil: `rm /nix/var/nix/profiles/sambbi-vpn*` (root) ou `rm ~/.local/state/nix/profiles/sambbi-vpn*`.
   - Com root, apague também os links de `/usr/local/bin`.
   - Sem root, apague o bloco `sambbi-vpn` do `~/.profile` (ou do `~/.bash_profile`, se ele existir).
   - Com o proot, apague também `~/.local/bin/sambbi-vpn`, e o `~/.local/bin/rclone` e o `~/.local/bin/vpn-teste` que o instalador gravou.
   - Se o instalador trocou o `ProxyCommand` do `~/.ssh/config`, ajuste a linha ou volte o arquivo anterior, `~/.ssh/config.antes-sambbi-vpn`.
3. Para sair da VPN, apague a pasta de estado e peça ao admin que remova o nó na VM (`headscale nodes delete`).

## Licença

[GNU AGPL 3.0](LICENSE).
