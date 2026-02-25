# Instalador Automático TeaSpeak

Script de instalação automatizada do TeaSpeak Server com configurações otimizadas para produção.

## Scripts Disponíveis

| Script | Cenário | Firewall |
|--------|---------|----------|
| `ovh-debian13-vm.sh` | VM Debian 13 no Proxmox (OVH Baremetal) | nftables puro (iptables removido) |
| `firewall.sh` | Reconfigurar firewall em Debian existente | nftables puro (standalone) |
| `addip.sh` | Adicionar/remover IP Failover na VM | — |
| `teainstall.sh` | Instalação direta em Debian existente | iptables |
| `config.yml` | Configuração customizada do TeaSpeak | — |

## Características

- Instalação completa do TeaSpeak 1.4.21-beta-3
- Firewall nftables puro — iptables completamente removido (`ovh-debian13-vm.sh`)
- UDP voice com prioridade máxima — sem rate limit global, otimizado para 700+ usuários
- Sistema anti-crash (verificação a cada 5 minutos)
- Backup automático diário às 6h
- AutoStart no boot do sistema
- Conntrack expandido (262144 entradas) e sysctl otimizado para alta concorrência

---

## 📋 Guia Passo a Passo — VM OVH (ovh-debian13-vm.sh)

Este é o fluxo completo para quem tem um **servidor dedicado OVH** e quer criar uma **VM no Proxmox** com o TeaSpeak pronto para uso.

### Pré-requisitos

- Servidor dedicado OVH com **Proxmox VE 8.x ou 9.x** instalado
- **IP Failover** já atribuído ao servidor (comprado no painel OVH)
- Acesso **root** ao shell do Proxmox (preferencialmente via console web, não SSH)

### Etapa 1 — Configurar MAC Virtual no Painel OVH

> ⚠️ **Faça isso ANTES de executar o script**

1. Acesse o [Painel OVH](https://www.ovh.com/manager/)
2. Vá em **Bare Metal Cloud** → seu servidor dedicado
3. Clique na aba **IP**
4. Localize seu **IP Failover**
5. Clique nos `...` ao lado do IP → **Adicionar um endereço MAC virtual**
6. Selecione tipo **OVH** (ou VMware se necessário)
7. **Anote o MAC Virtual gerado** (ex: `02:00:00:XX:XX:XX`) — você vai precisar dele

### Etapa 2 — Anotar informações de rede

Antes de executar o script, anote estas 3 informações:

| Informação | Onde encontrar | Exemplo |
|-----------|---------------|---------|
| **MAC Virtual** | Painel OVH → IP → MAC Virtual (Etapa 1) | `02:00:00:AB:CD:EF` |
| **IPv4 Failover** | Painel OVH → IP → seu IP adicional | `51.77.123.45` |
| **Gateway** | No Proxmox: execute `ip route \| grep default` | `51.77.123.254` |

> 💡 O gateway geralmente é o IP do servidor com o último octeto `.254` ou `.1`

### Etapa 3 — Executar o script no Proxmox

Acesse o **shell do Proxmox** (Datacenter → seu nó → Shell) e execute:

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/uteaspeak/proxinstall/main/ovh-debian13-vm.sh)"
```

Ou, se preferir baixar primeiro:

```bash
wget https://raw.githubusercontent.com/uteaspeak/proxinstall/main/ovh-debian13-vm.sh
chmod +x ovh-debian13-vm.sh
./ovh-debian13-vm.sh
```

### Etapa 4 — Responder as perguntas do script

O script vai abrir telas interativas (whiptail) pedindo informações **nesta ordem**:

**4.1 — Configuração OVH (obrigatório):**
1. **MAC Virtual** — Cole o MAC da Etapa 1 (ex: `02:00:00:AB:CD:EF`)
2. **IPv4 Failover** — Digite seu IP Failover (ex: `51.77.123.45`)
3. **Gateway** — Digite o gateway do servidor (ex: `51.77.123.254`)

**4.2 — Configuração da VM (tem valores padrão, pode dar Enter para aceitar):**
4. **VM ID** — ID da máquina virtual (auto-detectado)
5. **Hostname** — Nome da VM (padrão: `teaspeak`)
6. **CPU Cores** — Quantidade de núcleos (padrão: `2`)
7. **RAM** — Memória em MiB (padrão: `2048`)
8. **Disco** — Tamanho em GB (padrão: `16`)
9. **Bridge** — Bridge de rede (padrão: `vmbr0`)
10. **Senha ROOT** — Senha de acesso root da VM (obrigatório, com confirmação)

**4.3 — Configuração do Firewall (personalize conforme necessário):**
11. **Porta SSH** — Porta de acesso SSH (padrão: `22`, recomendado alterar)
12. **Portas TCP** — Portas do TeaSpeak separadas por vírgula (padrão: `30303`)
13. **Range UDP início** — Porta UDP inicial para voice (padrão: `10500`)
14. **Range UDP fim** — Porta UDP final para voice (padrão: `10530`)
15. **Whitelist 10101** — IPs autorizados para Server Query (obrigatório, aceita CIDR)

**4.4 — Confirmação:**
16. O script mostra um **resumo de tudo** — confirme para criar a VM
17. **Seleção de storage** — Escolha onde salvar a VM
18. **Iniciar VM?** — Escolha se quer iniciar a VM imediatamente

### Etapa 5 — Aguardar instalação automática

Após a confirmação, o script faz tudo automaticamente:

1. ⬇️ Baixa a imagem Debian 13 (Trixie)
2. 🔧 Personaliza a imagem (rede, firewall, SSH, sysctl)
3. 💾 Cria a VM no Proxmox com as configurações escolhidas
4. 🚀 Inicia a VM (se você confirmou)

> ⏱️ **No primeiro boot**, a VM executa automaticamente a instalação do TeaSpeak.
> Isso leva **3 a 5 minutos** dependendo da conexão com a internet.

### Etapa 6 — Acessar a VM e ver as credenciais

Após a VM iniciar e o TeaSpeak terminar de instalar:

```bash
# Opção 1: Acessar via console do Proxmox (login com root e a senha que você definiu)
qm terminal <VMID>

# Opção 2: Acessar via SSH (use a senha root que você definiu)
ssh root@<SEU_IP_FAILOVER> -p <SUA_PORTA_SSH>
```

Já dentro da VM, veja as credenciais do **usuário teaspeak**:

```bash
cat /root/teaspeak_credentials.txt
```

O arquivo contém o **usuário teaspeak** e a **senha aleatória** gerada para ele.

### Etapa 7 — Alterar a senha (IMPORTANTE!)

```bash
passwd teaspeak
```

> ⚠️ **Faça isso imediatamente!** Após alterar, delete o arquivo de credenciais:
> ```bash
> rm -f /root/teaspeak_credentials.txt
> ```

### Etapa 8 — Verificar que tudo está funcionando

```bash
# Verificar se o TeaSpeak está rodando
su teaspeak
cd ~ && ./teastart.sh status

# Se não estiver rodando, iniciar manualmente
./teastart.sh start

# Verificar firewall
exit  # voltar para root
nft list ruleset

# Verificar sysctl
sysctl net.netfilter.nf_conntrack_max

# Verificar backups configurados
crontab -l -u teaspeak
```

### Etapa 9 — Conectar o cliente TeaSpeak

No seu computador, abra o **cliente TeaSpeak** e conecte em:

- **Endereço**: `<SEU_IP_FAILOVER>`
- **Porta**: A primeira porta do range UDP que você configurou (padrão: `10500`)

> 💡 Na primeira conexão, você será o **Server Admin**. O token de admin aparece nos logs:
> ```bash
> su teaspeak
> cat ~/logs/server_*.log | grep -i token
> ```

---

## 📋 Guia Passo a Passo — Instalação Direta (teainstall.sh)

Para quem já tem um **Debian 11+** rodando e quer instalar o TeaSpeak diretamente.

### Etapa 1 — Executar o script

```bash
wget https://raw.githubusercontent.com/uteaspeak/proxinstall/main/teainstall.sh
chmod +x teainstall.sh
./teainstall.sh
```

### Etapa 2 — Criar senha do usuário teaspeak

O script vai pedir para você criar uma **senha** para o usuário `teaspeak`. Digite e confirme.

### Etapa 3 — Aguardar a instalação

O script faz tudo automaticamente:
1. Instala dependências (wget, curl, screen, etc.)
2. Cria o usuário `teaspeak`
3. Baixa e extrai o TeaSpeak 1.4.21-beta-3
4. Cria scripts de anti-crash e backup
5. Configura o crontab (autostart, anti-crash, backup diário)
6. Configura o firewall iptables
7. Faz a primeira inicialização do TeaSpeak
8. Baixa a configuração customizada (config.yml)

### Etapa 4 — Iniciar o servidor

```bash
su teaspeak
cd ~
./teastart.sh start
```

### Etapa 5 — Conectar o cliente TeaSpeak

- **Endereço**: IP do seu servidor
- **Porta**: `10500` (padrão)

---

## 📋 Firewall Standalone (firewall.sh)

Script independente para configurar/reconfigurar o firewall nftables diretamente em qualquer Debian 11+ com TeaSpeak. Útil para alterar portas, whitelist ou reaplicar regras sem recriar a VM.

### Uso

```bash
# Baixar
wget https://raw.githubusercontent.com/uteaspeak/proxinstall/main/firewall.sh

# Modo interativo (pergunta portas, whitelist, etc)
sudo bash firewall.sh

# Reaplicar regras do /etc/nftables.conf atual
sudo bash firewall.sh --apply

# Ver regras nftables ativas
sudo bash firewall.sh --show

# Status completo (conntrack, config atual, etc)
sudo bash firewall.sh --status

# Ver pacotes bloqueados (top IPs, portas, ultimos drops)
sudo bash firewall.sh --drops

# Monitorar drops em tempo real (Ctrl+C para sair)
sudo bash firewall.sh --drops --live

# Ver ultimos 100 drops (padrao: 50)
sudo bash firewall.sh --drops 100
```

### O que o script faz

1. **Remove iptables** automaticamente (se presente) para evitar conflito
2. **Detecta config atual** de `/etc/nftables.conf` como valores padrão
3. Permite alterar interativamente: porta SSH, TCP, range UDP, whitelist 10101
4. **Gera `/etc/nftables.conf`** com contadores em cada regra (visíveis com `--drops`)
5. **Gera `/etc/sysctl.d/99-teaspeak.conf`** com conntrack e buffers otimizados
6. **Aplica tudo** e reinicia o serviço nftables
7. Faz **backup** do nftables.conf anterior antes de sobrescrever

---

## Referência Técnica

### Configuração de Rede OVH

Seguindo a [documentação oficial OVH para servidores baremetal](https://help.ovhcloud.com/csm/en-dedicated-servers-network-bridging):

- IP Failover com máscara `/32`
- Rota explícita para o gateway com scope link (obrigatório com /32)
- Rota default via gateway com on-link: true
- DNS: `213.186.33.99` (OVH) e `1.1.1.1` (Cloudflare)
- Configuração via netplan com systemd-networkd (padrão Debian 13)

### Firewall nftables (ovh-debian13-vm.sh)

> ⚠️ **100% nftables** — O iptables é completamente removido durante a instalação para evitar conflitos no backend `nf_tables` do kernel. No Debian 13, `iptables-nft` compartilha o mesmo backend, e ter ambos ativos causa comportamento imprevisível.

O script solicita ao usuário a configuração de **todas as portas**:

| Configuração | Padrão | Descrição |
|-------------|--------|-----------|
| Porta SSH | `22` | Porta de acesso SSH (rate limit 5/min por IP) |
| Portas TCP | `30303` | TeaSpeak FileTransfer |
| TCP 10101 | whitelist | Server Query — restrito por whitelist de IPs |
| Range UDP | `10500-10530` | Voice Channels (otimizado para 700+ usuários) |

#### Ordem das regras (prioridade importa)

```
1. loopback              → accept
2. ct state established  → accept  (usuários conectados)
3. UDP voice ports       → accept  (PRIORIDADE MÁXIMA, sem rate limit)
4. ct state invalid      → drop    (só atinge tráfego não-voice)
5. ICMP tipos específicos → rate limit 5/s
6. SSH                   → rate limit POR IP (5/min independente)
7. TCP TeaSpeak          → accept
8. Server Query 10101    → whitelist only
9. policy drop           (todo o resto)
```

#### Por que UDP voice está ANTES de `ct state invalid`?

Sob carga alta, o conntrack pode marcar pacotes UDP legítimos como "invalid" (tabela cheia, pacotes fora de sequência, etc). Se `ct state invalid drop` estivesse antes da regra UDP, esses pacotes seriam descartados — **bloqueando usuários legítimos**. Colocando o UDP voice antes, garantimos que pacotes de voz **nunca** são afetados pelo conntrack.

#### Por que NÃO há rate limit global no UDP?

Rate limit global em portas UDP é **perigoso** em servidores de voz:

1. Durante um DDoS, o atacante envia milhares de pacotes UDP com IPs de origem falsos (spoofados)
2. Cada pacote spoofado é contado como "nova conexão" e consome o rate limit global
3. Quando o limite é atingido, pacotes de **usuários legítimos** são descartados
4. Resultado: o **atacante bloqueia seus próprios usuários** usando o firewall contra você

A proteção correta para servidores OVH:
- **OVH Anti-DDoS** filtra ataques volumétricos na infraestrutura antes de chegar ao servidor
- **Conntrack established** garante que usuários já conectados nunca são afetados
- **UDP voice com prioridade máxima** aceita conexões antes de qualquer filtro
- **Policy DROP** bloqueia tudo que não é explicitamente permitido
- **Conntrack expandido** (262144 entradas) suporta 700+ conexões simultâneas

#### Sysctl otimizado (700+ usuários)

| Parâmetro | Valor | Descrição |
|-----------|-------|-----------|
| `nf_conntrack_max` | `262144` | Tabela conntrack expandida |
| `nf_conntrack_udp_timeout` | `30s` | Timeout UDP (libera entradas rápido) |
| `nf_conntrack_udp_timeout_stream` | `180s` | Fluxos estabelecidos (generoso para mutados/idle) |
| `rmem_max` / `wmem_max` | `25 MB` | Buffers de rede UDP aumentados |
| `tcp_syncookies` | `1` | Proteção contra SYN flood |
| `rp_filter` | `1` | Proteção contra IP spoofing |

### Firewall iptables (teainstall.sh)

#### Portas TCP Abertas
- `22` - SSH
- `10101` - TeaSpeak Server
- `30303` - TeaSpeak FileTransfer

#### Portas UDP Abertas
- `10500-10530` - TeaSpeak Voice (com rate limiting)

#### Proteções Ativas
- **Rate Limiting**: 50 pacotes/segundo (burst 100)
- **Anti-DDoS**: Bloqueio automático após 100 pacotes/minuto do mesmo IP
- **ICMP Limitado**: 1 ping/segundo
- **Policy DROP**: Todo tráfego não autorizado é bloqueado

### Automações (Crontab)

| Tarefa | Frequência | Descrição |
|--------|-----------|-----------|
| AutoStart | No boot | Inicia o TeaSpeak automaticamente |
| Anti-Crash | A cada 5min | Verifica e reinicia o servidor se necessário |
| Backup | Diário às 6h | Backup completo dos dados |

## Usando o TeaSpeak

### Primeira Inicialização

```bash
su teaspeak
cd ~/TeaSpeak
./teastart_minimal.sh
```

**IMPORTANTE**: Execute `teastart_minimal.sh` na primeira vez para gerar as configurações iniciais.

### Inicializações Seguintes

```bash
su teaspeak
cd ~/TeaSpeak
./teastart.sh start
```

### Comandos Úteis

```bash
# Parar o servidor
./teastart.sh stop

# Reiniciar o servidor
./teastart.sh restart

# Ver status
./teastart.sh status
```

## Estrutura de Diretórios

```
/home/teaspeak/
├── TeaSpeak/                    # Arquivos do servidor
│   ├── config.yml               # Configuração principal
│   ├── TeaData.sqlite           # Banco de dados
│   ├── files/                   # Arquivos de áudio/ícones
│   └── geoloc/                  # Dados de geolocalização
├── resources/                   # Scripts de automação
│   ├── anticrash.sh             # Monitor de processo
│   └── teaspeakbackup.sh        # Sistema de backup
└── backups/                     # Backups automáticos
    ├── backup.log               # Log de backups
    └── teaspeak_backup_*.tar.gz
```

## Firewall

### Verificar Regras Ativas

**VM OVH (nftables):**
```bash
# Ver todas as regras nftables
nft list ruleset

# Ver contadores de pacotes por regra
nft list chain inet firewall input

# Verificar conntrack atual
conntrack -C
```

**Instalação direta (iptables):**
```bash
iptables -L -v -n
iptables -L TS3_UDP -v -n
```

### Regras Persistentes

**VM OVH:** As regras nftables são carregadas de `/etc/nftables.conf` pelo serviço `nftables.service` no boot.

**Instalação direta:** As regras iptables são salvas via `netfilter-persistent` em `/etc/iptables/rules.v4`.

## Sistema de Backup

### Localização
- **Diretório**: `/home/teaspeak/backups/`
- **Formato**: `teaspeak_backup_YYYYMMDD_HHMMSS.tar.gz`
- **Retenção**: 30 dias (backups antigos são removidos automaticamente)

### Conteúdo do Backup
- `files/` - Arquivos de áudio e ícones
- `geoloc/` - Dados de geolocalização
- `config.yml` - Configurações
- `query_ip_whitelist.txt` - Lista de IPs permitidos
- `TeaData.sqlite` - Banco de dados completo

### Backup Manual

```bash
su teaspeak
/home/teaspeak/resources/teaspeakbackup.sh
```

### Verificar Logs de Backup

```bash
cat /home/teaspeak/backups/backup.log
```

## Monitoramento

### Verificar se o Servidor está Rodando

```bash
ps aux | grep TeaSpeak
```

### Ver Logs do Anti-Crash

```bash
# Verificar crontab
crontab -l -u teaspeak

# Ver logs do sistema
grep CRON /var/log/syslog | grep anticrash
```

### Monitorar Pacotes Bloqueados

**VM OVH (nftables):**
```bash
# Ver logs de pacotes dropados pelo nftables
journalctl -k | grep nftables-drop

# Em tempo real
journalctl -kf | grep nftables-drop

# Ver uso do conntrack (importante para 700+ usuários)
conntrack -C
sysctl net.netfilter.nf_conntrack_max
```

**Instalação direta (iptables):**
```bash
dmesg | grep "TS3 DDoS"
```

## Segurança

### Usuário TeaSpeak
- **Usuário**: `teaspeak`
- **Senha**: Definida durante a instalação
- **Diretório home**: `/home/teaspeak`

### Recomendações
1. Altere a porta SSH padrão (22) se possível
2. Configure autenticação por chave SSH
3. Mantenha o sistema atualizado: `apt update && apt upgrade`
4. Monitore os logs regularmente
5. Faça backup das configurações personalizadas

## Troubleshooting

### Servidor não inicia

```bash
# Verificar logs do TeaSpeak
su teaspeak
cd ~/TeaSpeak
cat logs/latest.log
```

### Firewall bloqueando conexões

**VM OVH (nftables):**
```bash
# Ver log de pacotes dropados
journalctl -k | grep nftables-drop

# Ver contadores de drop
nft list chain inet firewall input | grep -i drop

# Desabilitar temporariamente (CUIDADO em produção)
nft flush ruleset
```

**Instalação direta (iptables):**
```bash
iptables -L -v -n | grep DROP
```

### Backup falhou

```bash
# Verificar log de erros
cat /home/teaspeak/backups/backup.log

# Testar backup manual
su teaspeak
/home/teaspeak/resources/teaspeakbackup.sh
```

### Anti-crash não funciona

```bash
# Verificar se o crontab está configurado
crontab -l -u teaspeak

# Verificar permissões do script
ls -la /home/teaspeak/resources/anticrash.sh
```

## Informações Técnicas

### Versão
- **TeaSpeak**: 1.4.21-beta-3
- **Arquitetura**: amd64_optimized
- **Sistema**: Linux

### Dependências Instaladas

**VM OVH (`ovh-debian13-vm.sh`):**
- `cron`, `sudo`, `wget`, `curl`, `screen`, `xz-utils`, `libnice10`
- `nftables` (único firewall — iptables é removido)
- `openssh-server`

**Instalação direta (`teainstall.sh`):**
- `cron`, `sudo`, `wget`, `curl`, `screen`, `xz-utils`, `libnice10`
- `iptables-persistent`
- `openssh-server`

### Portas Utilizadas

| Porta | Protocolo | Acesso | Descrição |
|-------|-----------|--------|-----------|
| 22 (configurável) | TCP | Rate limit por IP (5/min) | SSH |
| 10101 | TCP | Whitelist de IPs (VM OVH) | TeaSpeak Server Query |
| 30303 | TCP | Aberta | TeaSpeak FileTransfer |
| 10500-10530 | UDP | Aberta (prioridade máxima) | Voice Channels |
