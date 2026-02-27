# TeaSpeak Server -- Instalador para Proxmox + OVH

Scripts de provisionamento automatizado de containers LXC e VMs no Proxmox VE para servidores dedicados OVH com IP Failover.

## Scripts

| Script | Descricao |
|--------|-----------|
| `ovh-debian13-lxc.sh` | Cria container LXC Debian 13 com TeaSpeak (principal) |
| `ovh-debian13-vm.sh` | Cria VM Debian 13 com TeaSpeak |
| `firewall.sh` | Reconfigura firewall nftables em instalacao existente |
| `addip.sh` | Adiciona/remove IP Failover em VM existente |
| `teainstall.sh` | Instalacao direta em Debian existente (iptables) |
| `config.yml` | Configuracao customizada do TeaSpeak |

O que o instalador entrega:

- TeaSpeak 1.4.21-beta-3 rodando e acessivel
- Firewall nftables sem iptables, portas e whitelist configuraveis
- UDP voice com prioridade maxima, sem rate limit global
- Anti-crash com verificacao a cada 5 minutos
- Backup automatico diario (6h, retencao de 30 dias)
- AutoStart no boot
- Conntrack expandido (262144 entradas) e sysctl ajustado para 700+ usuarios

---

## Guia de Instalacao -- LXC (ovh-debian13-lxc.sh)

### Pre-requisitos

- Servidor dedicado OVH com Proxmox VE 8.x ou 9.x
- IP Failover atribuido ao servidor (comprado no painel OVH)
- Acesso root ao shell do Proxmox

### 1. Configurar MAC Virtual no painel OVH

Faca isso antes de rodar o script.

1. Acesse o [Painel OVH](https://www.ovh.com/manager/)
2. Va em **Bare Metal Cloud** e selecione o servidor
3. Aba **IP**, localize o IP Failover
4. Clique nos `...` ao lado do IP e selecione **Adicionar um endereco MAC virtual**
5. Tipo: **OVH**
6. Anote o MAC gerado (ex: `02:00:00:AB:CD:EF`)

### 2. Anotar informacoes de rede

Voce vai precisar de 3 dados:

| Dado | Onde encontrar |
|------|---------------|
| MAC Virtual | Painel OVH, configurado na etapa anterior |
| IPv4 Failover | Painel OVH, aba IP |
| Gateway | No Proxmox: `ip route \| grep default` |

O gateway geralmente e o IP do servidor com ultimo octeto `.254` ou `.1`.

### 3. Executar o script

No shell do Proxmox (Datacenter > seu no > Shell):

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/uteaspeak/proxinstall/main/ovh-debian13-lxc.sh)"
```

### 4. Responder as perguntas

O script abre telas interativas nesta ordem:

**Rede OVH:**
- MAC Virtual
- IPv4 Failover
- Gateway

**Container:**
- CT ID (auto-detectado)
- Hostname (padrao: `teaspeak`)
- CPU cores (padrao: `2`)
- RAM em MiB (padrao: `2048`)
- Disco em GB (padrao: `8`)
- Bridge (padrao: `vmbr0`)
- Privilegiado ou nao (recomendado: privilegiado para nftables)
- Senha root (obrigatorio, com confirmacao)

**Firewall:**
- Porta SSH (padrao: `22`, recomendado alterar)
- Portas TCP (padrao: `30303`)
- Range UDP inicio/fim (padrao: `10500-10530`)
- Whitelist de IPs para SSH e porta 10101 (obrigatorio, aceita CIDR)

Depois disso, o script mostra um resumo para confirmacao e faz tudo sozinho.

### 5. Acessar o container

```bash
# Console do Proxmox
pct enter <CTID>

# Ou via SSH
ssh root@<IP_FAILOVER> -p <PORTA_SSH>
```

Ver credenciais do usuario teaspeak:

```bash
cat /root/teaspeak_credentials.txt
```

Altere a senha imediatamente:

```bash
passwd teaspeak
rm -f /root/teaspeak_credentials.txt
```

### 6. Verificar que esta rodando

```bash
# Status do TeaSpeak
su teaspeak
cd ~ && ./teastart.sh status

# Firewall
exit
nft list ruleset

# Conntrack
sysctl net.netfilter.nf_conntrack_max
```

### 7. Conectar o cliente

No cliente TeaSpeak:

- Endereco: seu IP Failover
- Porta: primeira do range UDP (padrao: `10500`)

Na primeira conexao voce sera Server Admin. O token aparece nos logs:

```bash
su teaspeak
cat ~/logs/server_*.log | grep -i token
```

---

## Reconfigurar Firewall (firewall.sh)

Script standalone para alterar portas, whitelist ou reaplicar regras sem recriar o container.

```bash
# Modo interativo
sudo bash firewall.sh

# Reaplicar regras do /etc/nftables.conf
sudo bash firewall.sh --apply

# Ver regras ativas
sudo bash firewall.sh --show

# Status completo
sudo bash firewall.sh --status

# Pacotes bloqueados (top IPs, portas, ultimos drops)
sudo bash firewall.sh --drops

# Drops em tempo real
sudo bash firewall.sh --drops --live
```

---

## Adicionar/Remover IP Failover (addip.sh)

Para VMs configuradas pelo `ovh-debian13-vm.sh`. Gerencia IPs no netplan.

```bash
# Listar IPs atuais
bash addip.sh --list

# Adicionar IP
bash addip.sh --add 1.2.3.4

# Remover IP
bash addip.sh --remove 1.2.3.4
```

---

## Referencia Tecnica

### Rede OVH

Conforme [documentacao OVH para baremetal](https://help.ovhcloud.com/csm/en-dedicated-servers-network-bridging):

- IP Failover com mascara `/32`
- Rota para o gateway com scope link
- Rota default com on-link
- DNS: `213.186.33.99` (OVH), `1.1.1.1` (Cloudflare)
- No LXC, rede configurada pelo Proxmox via `--net0`
- Na VM, configurada via netplan + systemd-networkd

### Regras nftables

O firewall e 100% nftables. O iptables e removido durante a instalacao para evitar conflito no backend `nf_tables` do kernel.

Ordem das regras na chain input:

```
1. loopback              -> accept
2. ct state established  -> accept  (usuarios conectados)
3. UDP voice ports       -> accept  (prioridade maxima)
4. ct state invalid      -> drop
5. ICMP                  -> rate limit 5/s
6. SSH                   -> whitelist + rate limit 5/min por IP
7. TCP (FileTransfer)    -> accept
8. Server Query 10101   -> whitelist
9. log drops             -> 3/min
10. policy drop
```

**Por que UDP voice vem antes de `ct state invalid`?**

Sob carga alta, o conntrack pode classificar pacotes UDP legitimos como "invalid" (tabela cheia, pacotes fora de sequencia). Se o drop de invalidos viesse primeiro, usuarios seriam desconectados. Com UDP antes, pacotes de voz nunca sao afetados.

**Por que nao tem rate limit global no UDP?**

Num ataque DDoS, pacotes chegam com IPs de origem falsos. Um rate limit global contaria esses pacotes spoofados e, ao atingir o limite, bloquearia usuarios reais. A protecao volumetrica e responsabilidade do anti-DDoS da OVH na infraestrutura, antes de chegar ao servidor.

### Sysctl

| Parametro | Valor | Motivo |
|-----------|-------|--------|
| `nf_conntrack_max` | `262144` | Tabela conntrack para 700+ conexoes |
| `nf_conntrack_udp_timeout` | `30s` | Libera entradas UDP rapido |
| `nf_conntrack_udp_timeout_stream` | `180s` | Fluxos estabelecidos (idle/mutados) |
| `rmem_max` / `wmem_max` | `25 MB` | Buffers UDP aumentados |
| `tcp_syncookies` | `1` | Protecao SYN flood |
| `rp_filter` | `1` | Protecao IP spoofing |

### Portas

| Porta | Protocolo | Acesso | Descricao |
|-------|-----------|--------|-----------|
| Configuravel | TCP | Whitelist + rate limit | SSH |
| 10101 | TCP | Whitelist | TeaSpeak Server Query |
| 30303 | TCP | Aberta | TeaSpeak FileTransfer |
| 10500-10530 | UDP | Aberta (prioridade maxima) | Voice Channels |

### Backup automatico

- Diretorio: `/home/teaspeak/backups/`
- Formato: `teaspeak_backup_YYYYMMDD_HHMMSS.tar.gz`
- Retencao: 30 dias
- Conteudo: `files/`, `geoloc/`, `config.yml`, `protocolkey.txt`, `query_ip_whitelist.txt`, `TeaData.sqlite`

Backup manual:

```bash
su teaspeak
/home/teaspeak/resources/teaspeakbackup.sh
```

### Estrutura de diretorios

```
/home/teaspeak/
  config.yml
  protocolkey.txt
  TeaData.sqlite
  files/
  geoloc/
  logs/
  resources/
    anticrash.sh
    teaspeakbackup.sh
  backups/
    backup.log
    teaspeak_backup_*.tar.gz
```

---

## Troubleshooting

**TeaSpeak nao inicia:**

```bash
su teaspeak
cat ~/logs/latest.log
```

**Firewall bloqueando conexoes:**

```bash
# Ver drops
journalctl -k | grep nftables-drop

# Contadores
nft list chain inet firewall input
```

**SSH recusando conexao:**

No Debian 13, o systemd usa socket activation para o SSH. O script ja configura o override, mas se precisar verificar:

```bash
ss -tlnp | grep ssh
cat /etc/systemd/system/ssh.socket.d/override.conf
```

**Backup falhou:**

```bash
cat /home/teaspeak/backups/backup.log
```

**Anti-crash nao funciona:**

```bash
crontab -l -u teaspeak
ls -la /home/teaspeak/resources/anticrash.sh
```
