#!/bin/bash

# =============================================================================
# Script de Instalacao Automatizada do TeaSpeaK
# =============================================================================

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Banner
clear
echo -e "${CYAN}${BOLD}================================================"
echo -e "           INSTALADOR TEASPEAK"
echo -e "================================================${NC}\n"

# Funcao de log simples
log() { echo -e "${GREEN}[OK]${NC} $1"; }
err() { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}>>>${NC} $1"; }

# Spinner com contador de tempo - versao melhorada
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    local elapsed=0
    
    # Salvar posicao do cursor
    tput sc
    
    while ps -p $pid > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c] %ds" "$spinstr" "$elapsed"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        elapsed=$((elapsed + 1))
        # Restaurar posicao e limpar ate o fim da linha
        tput rc
        tput el
    done
    
    # Limpar o spinner final
    tput rc
    tput el
}

# Verificar root
[[ $EUID -ne 0 ]] && err "Execute como root"

# 1. Instalacao de pacotes
step "Instalando dependencias..."
printf "${YELLOW}Atualizando repositorios...${NC}"
apt update > /dev/null 2>&1 &
spinner $!
printf " ${GREEN}OK${NC}\n"

printf "${YELLOW}Atualizando sistema (apt upgrade)...${NC}"
apt upgrade -y > /dev/null 2>&1 &
spinner $!
printf " ${GREEN}OK${NC}\n"

echo -e "${YELLOW}Instalando pacotes:${NC}"

# Instalar openssh-server primeiro (obrigatorio)
echo -ne "  - Instalando ${BOLD}openssh-server${NC}... "
apt install -y openssh-server > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}JA INSTALADO${NC}"
fi

# Instalar pacotes simples primeiro
SIMPLE_PACKAGES="cron sudo wget curl screen xz-utils libnice10"
for pkg in $SIMPLE_PACKAGES; do
    echo -ne "  - Instalando ${BOLD}$pkg${NC}... "
    apt install -y $pkg > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}JA INSTALADO${NC}"
    fi
done

log "Dependencias instaladas"

# 2. Criar usuario teaspeak
step "Configurando usuario teaspeak..."
if id "teaspeak" &>/dev/null; then
    log "Usuario ja existe"
else
    echo -e "\n${YELLOW}Digite a senha para o usuario teaspeak:${NC}"
    adduser teaspeak --gecos ""
    [[ $? -eq 0 ]] || err "Falha ao criar usuario"
    log "Usuario criado com sucesso"
fi

# 3. Download e extracao do TeaSpeak
step "Baixando TeaSpeak 1.4.21-beta-3..."
su - teaspeak -c '
cd ~
wget -q --show-progress https://repo.teaspeak.de/server/linux/amd64_optimized/TeaSpeak-1.4.21-beta-3.tar.gz || exit 1
tar -xzf TeaSpeak-1.4.21-beta-3.tar.gz || exit 1
rm -f TeaSpeak-1.4.21-beta-3.tar.gz
' || err "Falha no download/extracao"
log "TeaSpeak extraido"

# 4. Criar scripts de automacao
step "Criando scripts de automacao..."
mkdir -p /home/teaspeak/resources

# Script anticrash
cat > /home/teaspeak/resources/anticrash.sh << 'EOF'
#!/bin/bash
case $1 in
teaspeakserver)
    teaspeakserverpid=`ps ax | grep TeaSpeakServer | grep -v grep | wc -l`
    if [ $teaspeakserverpid -eq 1 ]
    then exit
    else
        /home/teaspeak/teastart.sh start
    fi
;;
esac
EOF

# Script backup
cat > /home/teaspeak/resources/teaspeakbackup.sh << 'EOF'
#!/bin/bash

TS3_DIR="/home/teaspeak"
BACKUP_DIR="/home/teaspeak/backups"
LOG_FILE="/home/teaspeak/backups/backup.log"
DATE=$(date +"%Y%m%d_%H%M%S")
BACKUP_NAME="teaspeak_backup_$DATE.tar.gz"
RETENTION_DAYS=30

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

error_exit() {
    log_message "ERRO - $1"
    exit 1
}

log_message "=== Iniciando Backup ==="
mkdir -p "$BACKUP_DIR" || error_exit "Erro ao criar diretorio de backup"

[ ! -d "$TS3_DIR" ] && error_exit "Diretorio TeaSpeak nao encontrado"

FILES_TO_BACKUP=""
for item in "files" "geoloc" "config.yml" "protocolkey.txt" "query_ip_whitelist.txt" "TeaData.sqlite"; do
    [ -e "$TS3_DIR/$item" ] && FILES_TO_BACKUP="$FILES_TO_BACKUP $item"
done

[ -z "$FILES_TO_BACKUP" ] && error_exit "Nenhum arquivo encontrado"

cd "$TS3_DIR" || error_exit "Erro ao acessar diretorio"

eval "tar -czf \"$BACKUP_DIR/$BACKUP_NAME\" $FILES_TO_BACKUP" 2>> "$LOG_FILE"

if [ $? -eq 0 ] && [ -f "$BACKUP_DIR/$BACKUP_NAME" ]; then
    BACKUP_SIZE=$(ls -lh "$BACKUP_DIR/$BACKUP_NAME" | awk '{print $5}')
    log_message "Backup criado: $BACKUP_NAME ($BACKUP_SIZE)"
    
    find "$BACKUP_DIR" -name "teaspeak_backup_*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete
    log_message "Limpeza de backups antigos concluida"
else
    error_exit "Falha ao criar backup"
fi

tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
exit 0
EOF

chmod +x /home/teaspeak/resources/*.sh
chown -R teaspeak:teaspeak /home/teaspeak/resources
log "Scripts criados"

# 5. Configurar crontab
step "Configurando crontab..."
su - teaspeak -c 'cat > /tmp/teaspeak_crontab << "CRON"
@reboot cd /home/teaspeak && ./teastart.sh start
*/5 * * * * /home/teaspeak/resources/anticrash.sh teaspeakserver > /dev/null 2>&1
0 6 * * * /home/teaspeak/resources/teaspeakbackup.sh >/dev/null 2>&1
CRON
crontab /tmp/teaspeak_crontab
rm -f /tmp/teaspeak_crontab'
log "Crontab configurado"

# 5.5. Escolher tipo de firewall
step "Escolha o tipo de firewall..."
echo -e "${YELLOW}Selecione o firewall para este servidor:${NC}\n"
echo -e "  ${BOLD}1)${NC} ${GREEN}nftables${NC}  - Anti-DDoS 3 camadas (recomendado para VMs)"
echo -e "               fragment drop + max 750B + rate limit 150pps/IP"
echo -e "  ${BOLD}2)${NC} ${YELLOW}iptables${NC} - Anti-DDoS 3 camadas (para LXC sem nftables)"
echo -e "               mesma protecao via iptables raw + hashlimit"
echo -e "  ${BOLD}3)${NC} ${RED}Nenhum${NC}   - Sem regras de firewall\n"

while true; do
    read -rp "Opcao [1/2/3]: " fw_choice
    case "$fw_choice" in
        1) FIREWALL_TYPE="nftables"; break ;;
        2) FIREWALL_TYPE="iptables"; break ;;
        3) FIREWALL_TYPE="none"; break ;;
        *) echo -e "  ${RED}Opcao invalida. Digite 1, 2 ou 3${NC}" ;;
    esac
done
log "Firewall selecionado: ${FIREWALL_TYPE}"

# 5.6. Configurar portas
SSH_PORT="22"
UDP_START="10500"
UDP_END="10530"
TCP_PORTS="30303"

if [ "$FIREWALL_TYPE" != "none" ]; then
    echo ""
    read -rp "Porta SSH [${SSH_PORT}]: " input_ssh
    [ -n "$input_ssh" ] && SSH_PORT="$input_ssh"
    log "Porta SSH: ${SSH_PORT}"

    read -rp "Porta UDP inicial [${UDP_START}]: " input_udp_start
    [ -n "$input_udp_start" ] && UDP_START="$input_udp_start"
    read -rp "Porta UDP final [${UDP_END}]: " input_udp_end
    [ -n "$input_udp_end" ] && UDP_END="$input_udp_end"
    log "Range UDP: ${UDP_START}-${UDP_END}"

    read -rp "Portas TCP abertas (separadas por virgula) [${TCP_PORTS}]: " input_tcp
    [ -n "$input_tcp" ] && TCP_PORTS="$input_tcp"
    log "Portas TCP: ${TCP_PORTS}"
fi

# 5.7. Coletar IPv4 para whitelist do SSH e porta 10101
if [ "$FIREWALL_TYPE" != "none" ]; then
    step "Configurando whitelist para SSH e porta 10101 (Server Query)..."
    WHITELIST_IPS=()
    echo -e "${YELLOW}Digite os IPv4 para whitelist do SSH e porta 10101${NC}"
    echo -e "${YELLOW}Aceita IP exato (ex: 170.84.159.207) ou CIDR (ex: 170.84.159.0/24)${NC}"
    echo -e "${YELLOW}Adicione pelo menos um IP. Linha vazia para finalizar.${NC}"
    while true; do
        read -rp "IPv4: " wl_ip
        [ -z "$wl_ip" ] && [ ${#WHITELIST_IPS[@]} -gt 0 ] && break
        if [ -z "$wl_ip" ]; then
            echo -e "  ${RED}Pelo menos um IPv4 deve ser informado${NC}"
            continue
        fi
        if [[ "$wl_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
            WHITELIST_IPS+=("$wl_ip")
            echo -e "  ${GREEN}Adicionado: ${wl_ip}${NC}"
        else
            echo -e "  ${RED}IPv4 invalido: ${wl_ip}${NC}"
        fi
    done
    log "Whitelist configurada: ${WHITELIST_IPS[*]}"
fi

# 6. Configurar firewall
if [ "$FIREWALL_TYPE" = "nftables" ]; then
    step "Configurando firewall (nftables + Anti-DDoS 3 camadas)..."

    # Instalar nftables
    echo -ne "  - Instalando ${BOLD}nftables${NC}... "
    apt install -y nftables > /dev/null 2>&1
    echo -e "${GREEN}OK${NC}"

    # Remover iptables-persistent se existir (evitar conflito)
    if dpkg -l iptables-persistent 2>/dev/null | grep -q '^ii'; then
        echo -ne "  - Removendo ${BOLD}iptables-persistent${NC} (conflito)... "
        systemctl stop netfilter-persistent 2>/dev/null || true
        systemctl disable netfilter-persistent 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt purge -y iptables-persistent netfilter-persistent > /dev/null 2>&1 || true
        rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6 2>/dev/null
        rm -rf /etc/iptables 2>/dev/null
        echo -e "${GREEN}OK${NC}"
    fi

    # Flush iptables residuais
    if command -v iptables &>/dev/null; then
        iptables -F 2>/dev/null; iptables -X 2>/dev/null
        iptables -P INPUT ACCEPT 2>/dev/null; iptables -P FORWARD ACCEPT 2>/dev/null
    fi

    # Montar whitelist para nftables
    WHITELIST_NFT=$(printf ", %s" "${WHITELIST_IPS[@]}")
    WHITELIST_NFT="${WHITELIST_NFT:2}"

    # Gerar /etc/nftables.conf com anti-DDoS 3 camadas
    printf "${YELLOW}Gerando regras nftables...${NC}"
    cat > /etc/nftables.conf << NFTEOF
#!/usr/sbin/nft -f
# =============================================================================
# nftables - Firewall + Anti-DDoS TeaSpeak Server
# Gerado automaticamente pelo teainstall.sh
# =============================================================================
# Anti-DDoS (3 camadas):
#   Prerouting: fragment drop + notrack UDP voice
#   Layer 1: Drop UDP > 750 bytes (voice max ~500B)
#   Layer 2: Rate limit 150 pps/IP, burst 300, timeout 120s
#   Layer 3: Accept trafego legitimo
# =============================================================================

flush ruleset

# ---------- PREROUTING RAW: bypass conntrack para voice ----------
table ip raw {
    chain prerouting {
        type filter hook prerouting priority raw; policy accept;

        # Drop ALL IP fragments (amplification/evasion attack vector)
        ip frag-off & 0x1fff != 0 counter drop

        # Notrack voice UDP - zero conntrack overhead
        udp dport ${UDP_START}-${UDP_END} counter notrack
    }
}

# ---------- MAIN FILTER ----------
table inet firewall {
    chain input {
        type filter hook input priority filter; policy drop;

        # Loopback
        iifname "lo" accept

        # Conntrack (TCP only, UDP voice e notracked)
        ct state established,related counter accept
        ct state invalid counter drop

        # ICMP rate-limited
        ip protocol icmp icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } limit rate 5/second burst 10 packets counter accept
        ip protocol icmp counter drop

        # ICMPv6
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, echo-reply, destination-unreachable, time-exceeded, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } limit rate 5/second burst 10 packets counter accept
        ip6 nexthdr icmpv6 counter drop

        # SSH (porta ${SSH_PORT}) - whitelist + rate limit POR IP
        ip saddr { ${WHITELIST_NFT} } tcp dport ${SSH_PORT} ct state new meter ssh_limit { ip saddr limit rate 5/minute burst 10 packets } accept

        # TeaSpeak TCP (FileTransfer e outros servicos)
        tcp dport { ${TCP_PORTS} } counter accept

        # Server Query (10101) - apenas IPs autorizados
        ip saddr { ${WHITELIST_NFT} } tcp dport 10101 accept

        # ====== UDP VOICE - 3-layer anti-DDoS ======

        # LAYER 1: Drop oversized packets (voice max ~500B, threshold 750B)
        udp dport ${UDP_START}-${UDP_END} meta length > 750 counter drop

        # LAYER 2: Per-IP rate limit (150 pps, burst 300, timeout 120s)
        udp dport ${UDP_START}-${UDP_END} meter ts3_flood { ip saddr timeout 120s limit rate over 150/second burst 300 packets } counter drop

        # LAYER 3: Accept remaining legitimate voice traffic
        udp dport ${UDP_START}-${UDP_END} counter accept

        # Log dropped packets
        counter comment "policy-drop-count"
        limit rate 3/minute burst 5 packets log prefix "nftables-drop: " level warn
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
NFTEOF
    chmod 755 /etc/nftables.conf
    printf " ${GREEN}OK${NC}\n"

    # Gerar sysctl otimizado
    printf "${YELLOW}Configurando sysctl anti-DDoS...${NC}"
    cat > /etc/sysctl.d/99-teaspeak.conf << 'SYSEOF'
# Sysctl - Tuning de rede para TeaSpeak Server Anti-DDoS

# Receive/Send buffers
net.core.rmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_max = 16777216
net.core.wmem_default = 1048576

# UDP buffers
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536
net.ipv4.udp_mem = 65536 131072 262144

# Backlog de rede
net.core.netdev_max_backlog = 30000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.somaxconn = 4096

# Conntrack otimizado (voice e notracked)
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096

# Anti-spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Smurf attack prevention
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# TCP timestamps
net.ipv4.tcp_timestamps = 1
SYSEOF
    sysctl --system > /dev/null 2>&1
    printf " ${GREEN}OK${NC}\n"

    # Override para containers LXC
    if systemd-detect-virt -c -q 2>/dev/null; then
        printf "${YELLOW}Detectado container LXC - aplicando override nftables...${NC}"
        mkdir -p /etc/systemd/system/nftables.service.d
        cat > /etc/systemd/system/nftables.service.d/override.conf << 'LXCEOF'
[Service]
ProtectSystem=false
ProtectHome=false

[Install]
WantedBy=multi-user.target
LXCEOF
        systemctl daemon-reload
        printf " ${GREEN}OK${NC}\n"
    fi

    # Desabilitar ssh.socket (Debian 13 usa socket activation que ignora Port)
    if systemctl is-active ssh.socket &>/dev/null 2>&1; then
        printf "${YELLOW}Desabilitando ssh.socket (incompativel com porta customizada)...${NC}"
        systemctl disable --now ssh.socket 2>/dev/null || true
        systemctl disable --now ssh@.service 2>/dev/null || true
        rm -f /etc/systemd/system/ssh.service.d/00-socket.conf 2>/dev/null || true
        systemctl daemon-reload
        printf " ${GREEN}OK${NC}\n"
    fi

    # Configurar porta SSH
    if [ "$SSH_PORT" != "22" ]; then
        sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
        grep -q '^Port ' /etc/ssh/sshd_config || echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    fi

    # Ativar e aplicar nftables
    printf "${YELLOW}Aplicando regras nftables...${NC}"
    systemctl enable nftables > /dev/null 2>&1
    nft -f /etc/nftables.conf 2>/dev/null
    systemctl restart nftables > /dev/null 2>&1
    printf " ${GREEN}OK${NC}\n"
    log "Firewall nftables + Anti-DDoS configurado"

elif [ "$FIREWALL_TYPE" = "iptables" ]; then
    step "Configurando firewall (iptables + Anti-DDoS 3 camadas)..."

    # Instalar iptables-persistent
    echo -ne "  - Instalando ${BOLD}iptables-persistent${NC}... "
    DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent > /dev/null 2>&1
    echo -e "${GREEN}OK${NC}"

    printf "${YELLOW}Aplicando regras de firewall...${NC}"

    # =====================================================================
    # Limpar TUDO (filter + raw + mangle + nat)
    # =====================================================================
    iptables -F > /dev/null 2>&1
    iptables -X > /dev/null 2>&1
    iptables -t raw -F > /dev/null 2>&1
    iptables -t raw -X > /dev/null 2>&1
    iptables -t mangle -F > /dev/null 2>&1
    iptables -t nat -F > /dev/null 2>&1

    # =====================================================================
    # RAW TABLE - PREROUTING (equivalente ao table ip raw do nftables)
    # - Drop ALL IP fragments (vetor de amplificacao/evasao)
    # - NOTRACK para UDP voice (zero conntrack overhead)
    # =====================================================================
    iptables -t raw -A PREROUTING -f -j DROP
    iptables -t raw -A PREROUTING -p udp --dport "${UDP_START}:${UDP_END}" -j CT --notrack

    # =====================================================================
    # FILTER TABLE - INPUT
    # =====================================================================
    # Politicas padrao
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    # Loopback
    iptables -A INPUT -i lo -j ACCEPT

    # Conntrack (TCP only, UDP voice e notracked)
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate INVALID -j DROP

    # ICMP rate-limited (5/s burst 10)
    iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/s --limit-burst 10 -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type echo-reply -m limit --limit 5/s --limit-burst 10 -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type destination-unreachable -m limit --limit 5/s --limit-burst 10 -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type time-exceeded -m limit --limit 5/s --limit-burst 10 -j ACCEPT
    iptables -A INPUT -p icmp -j DROP

    # SSH - whitelist + rate limit POR IP (5/min burst 10)
    for cidr in "${WHITELIST_IPS[@]}"; do
        iptables -A INPUT -p tcp -s "$cidr" --dport "$SSH_PORT" -m conntrack --ctstate NEW \
            -m hashlimit --hashlimit-name ssh_limit --hashlimit-above 5/minute --hashlimit-burst 10 \
            --hashlimit-mode srcip --hashlimit-htable-expire 60000 -j DROP
        iptables -A INPUT -p tcp -s "$cidr" --dport "$SSH_PORT" -j ACCEPT
    done

    # TeaSpeak TCP (FileTransfer e outros servicos)
    for port in $(echo "$TCP_PORTS" | tr ',' ' '); do
        iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
    done

    # Server Query (10101) - apenas IPs autorizados
    for cidr in "${WHITELIST_IPS[@]}"; do
        iptables -A INPUT -p tcp -s "$cidr" --dport 10101 -j ACCEPT
    done
    iptables -A INPUT -p tcp --dport 10101 -j DROP

    # =====================================================================
    # UDP VOICE - 3-layer anti-DDoS (equivalente ao nftables)
    # =====================================================================

    # LAYER 1: Drop oversized packets (voice max ~500B, threshold 750B)
    # -m length mede o pacote IP inteiro (header + payload), equivalente a meta length
    iptables -A INPUT -p udp --dport "${UDP_START}:${UDP_END}" -m length --length 751:65535 -j DROP

    # LAYER 2: Per-IP rate limit (150 pps, burst 300, timeout 120s)
    # hashlimit: equivalente ao meter ts3_flood do nftables
    iptables -A INPUT -p udp --dport "${UDP_START}:${UDP_END}" \
        -m hashlimit --hashlimit-name ts3_flood \
        --hashlimit-above 150/sec --hashlimit-burst 300 \
        --hashlimit-mode srcip --hashlimit-htable-expire 120000 \
        -j DROP

    # LAYER 3: Accept remaining legitimate voice traffic
    iptables -A INPUT -p udp --dport "${UDP_START}:${UDP_END}" -j ACCEPT

    # Log dropped packets (policy drop)
    iptables -A INPUT -m limit --limit 3/min --limit-burst 5 -j LOG --log-prefix "iptables-drop: "

    printf " ${GREEN}OK${NC}\n"

    # =====================================================================
    # SYSCTL - mesmo tuning que nftables
    # =====================================================================
    printf "${YELLOW}Configurando sysctl anti-DDoS...${NC}"
    cat > /etc/sysctl.d/99-teaspeak.conf << 'SYSEOF'
# Sysctl - Tuning de rede para TeaSpeak Server Anti-DDoS

# Receive/Send buffers
net.core.rmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_max = 16777216
net.core.wmem_default = 1048576

# UDP buffers
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536
net.ipv4.udp_mem = 65536 131072 262144

# Backlog de rede
net.core.netdev_max_backlog = 30000
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
net.core.somaxconn = 4096

# Conntrack otimizado (voice e notracked)
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096

# Anti-spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Smurf attack prevention
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# TCP timestamps
net.ipv4.tcp_timestamps = 1
SYSEOF
    sysctl --system > /dev/null 2>&1
    printf " ${GREEN}OK${NC}\n"

    # Desabilitar ssh.socket (Debian 13 usa socket activation que ignora Port)
    if systemctl is-active ssh.socket &>/dev/null 2>&1; then
        printf "${YELLOW}Desabilitando ssh.socket (incompativel com porta customizada)...${NC}"
        systemctl disable --now ssh.socket 2>/dev/null || true
        systemctl disable --now ssh@.service 2>/dev/null || true
        rm -f /etc/systemd/system/ssh.service.d/00-socket.conf 2>/dev/null || true
        systemctl daemon-reload
        printf " ${GREEN}OK${NC}\n"
    fi

    # Configurar porta SSH
    if [ "$SSH_PORT" != "22" ]; then
        sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
        grep -q '^Port ' /etc/ssh/sshd_config || echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    fi

    # Salvar regras (filter + raw)
    printf "${YELLOW}Salvando regras iptables...${NC}"
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save > /dev/null 2>&1
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
    fi
    printf " ${GREEN}OK${NC}\n"
    log "Firewall iptables + Anti-DDoS configurado"

else
    step "Firewall: nenhum selecionado"
    echo -e "${YELLOW}Nenhuma regra de firewall sera aplicada.${NC}"
    echo -e "${YELLOW}O servidor ficara sem protecao de firewall local.${NC}"
    log "Firewall: nenhum (usuario escolheu nao instalar)"
fi

# =============================================================================
# PRIMEIRA INICIALIZACAO E CONFIGURACAO DO CONFIG.YML
# =============================================================================

step "Executando primeira inicializacao do TeaSpeak..."
echo -e "${YELLOW}O servidor sera iniciado por 10 segundos para gerar os arquivos iniciais${NC}\n"

# Criar script temporario para executar como usuario teaspeak
cat > /tmp/first_start.sh << 'EOF'
#!/bin/bash
cd /home/teaspeak

# Verificar se o teastart_minimal.sh existe
if [ ! -f "teastart_minimal.sh" ]; then
    echo "Erro: teastart_minimal.sh nao encontrado em /home/teaspeak"
    ls -la /home/teaspeak/ > /tmp/teaspeak_dir_listing.txt
    exit 1
fi

# Executar em background e aguardar apenas 3 segundos para geracao dos arquivos
./teastart_minimal.sh > /tmp/teaspeak_init.log 2>&1 &
TS_PID=$!

# Aguardar 3 segundos para geracao dos arquivos iniciais
sleep 3

# Encerrar o processo imediatamente
kill $TS_PID 2>/dev/null
wait $TS_PID 2>/dev/null

exit 0
EOF
chmod +x /tmp/first_start.sh

# Executar como usuario teaspeak
printf "${YELLOW}Inicializando servidor...${NC}"
su - teaspeak -c '/tmp/first_start.sh' > /dev/null 2>&1
printf " ${GREEN}OK${NC}\n"

# Garantir que todos os processos foram finalizados
pkill -9 -u teaspeak TeaSpeakServer 2>/dev/null
sleep 1

log "Primeira inicializacao concluida"

# Baixar config.yml customizado
step "Baixando configuracao customizada..."
echo -e "${YELLOW}Fazendo backup do config.yml original...${NC}"
su - teaspeak -c 'cd /home/teaspeak && [ -f config.yml ] && cp config.yml config.yml.original'

printf "${YELLOW}Baixando config.yml...${NC}"
su - teaspeak -c '
cd /home/teaspeak
wget -q https://raw.githubusercontent.com/uteaspeak/proxinstall/main/config.yml -O config.yml.new || exit 1
mv config.yml.new config.yml
' || err "Falha ao baixar config.yml customizado"
printf " ${GREEN}OK${NC}\n"

log "Config.yml customizado instalado"
echo -e "${CYAN}  - Backup original: ${BOLD}/home/teaspeak/config.yml.original${NC}"

# Limpar arquivos temporarios
rm -f /tmp/first_start.sh /tmp/teaspeak_init.log

# Resumo final
echo ""
echo -e "${GREEN}${BOLD}================================================${NC}"
echo -e "${GREEN}${BOLD}          INSTALACAO CONCLUIDA${NC}"
echo -e "${GREEN}${BOLD}================================================${NC}"
echo ""

echo -e "${CYAN}Resumo:${NC}"
echo -e "  - Usuario: ${BOLD}teaspeak${NC}"
echo -e "  - Diretorio: ${BOLD}/home/teaspeak/${NC}"
echo -e "  - Config: ${GREEN}OK${NC} - customizado instalado"
echo -e "  - AutoStart: ${GREEN}OK${NC} - ativo no boot"
echo -e "  - Anti-Crash: ${GREEN}OK${NC} - verificacao a cada 5min"
echo -e "  - Backup: ${GREEN}OK${NC} - backup diario as 6h"

if [ "$FIREWALL_TYPE" = "nftables" ]; then
    echo -e "  - Firewall: ${GREEN}OK${NC} - nftables + Anti-DDoS 3 camadas"
    echo ""
    echo -e "${CYAN}Anti-DDoS ativo:${NC}"
    echo -e "  - Prerouting: fragment drop + notrack UDP"
    echo -e "  - Layer 1: Drop pacotes > 750 bytes"
    echo -e "  - Layer 2: Rate limit 150 pps/IP (burst 300)"
    echo -e "  - Layer 3: Accept trafego legitimo"
    echo ""
    echo -e "${CYAN}Portas abertas:${NC}"
    echo -e "  - SSH:  ${BOLD}${SSH_PORT}${NC} (whitelist: ${WHITELIST_IPS[*]})"
    echo -e "  - TCP:  ${BOLD}${TCP_PORTS}${NC} (FileTransfer)"
    echo -e "  - 10101: whitelist (Server Query)"
    echo -e "  - UDP:  ${BOLD}${UDP_START}-${UDP_END}${NC} (voice, anti-DDoS)"
    echo ""
    echo -e "${CYAN}Verificar firewall:${NC}"
    echo -e "  ${YELLOW}nft list ruleset${NC}"
    echo -e "  ${YELLOW}nft list chain inet firewall input${NC}"
    echo -e "  ${YELLOW}nft list meters inet firewall${NC}  (ver IPs rate-limited)"
elif [ "$FIREWALL_TYPE" = "iptables" ]; then
    echo -e "  - Firewall: ${GREEN}OK${NC} - iptables + Anti-DDoS 3 camadas"
    echo ""
    echo -e "${CYAN}Anti-DDoS ativo:${NC}"
    echo -e "  - Prerouting RAW: fragment drop + NOTRACK UDP"
    echo -e "  - Layer 1: Drop pacotes > 750 bytes (-m length)"
    echo -e "  - Layer 2: Rate limit 150 pps/IP burst 300 (-m hashlimit)"
    echo -e "  - Layer 3: Accept trafego legitimo"
    echo ""
    echo -e "${CYAN}Portas abertas:${NC}"
    echo -e "  - SSH:  ${BOLD}${SSH_PORT}${NC} (whitelist: ${WHITELIST_IPS[*]})"
    echo -e "  - TCP:  ${BOLD}${TCP_PORTS}${NC} (FileTransfer)"
    echo -e "  - 10101: whitelist (Server Query)"
    echo -e "  - UDP:  ${BOLD}${UDP_START}-${UDP_END}${NC} (voice, anti-DDoS)"
    echo ""
    echo -e "${CYAN}Verificar firewall:${NC}"
    echo -e "  ${YELLOW}iptables -L -v -n${NC}"
    echo -e "  ${YELLOW}iptables -t raw -L -v -n${NC}  (fragment drop + notrack)"
    echo -e "  ${YELLOW}cat /proc/net/ipt_hashlimit/ts3_flood${NC}  (IPs rate-limited)"
else
    echo -e "  - Firewall: ${RED}NAO INSTALADO${NC} - sem protecao local"
fi

echo ""
echo -e "${CYAN}Iniciar servidor:${NC}"
echo -e "  ${YELLOW}su teaspeak${NC}"
echo -e "  ${YELLOW}cd ~${NC}"
echo -e "  ${YELLOW}./teastart.sh start${NC}"

echo ""
echo -e "${CYAN}Verificar logs:${NC}"
echo -e "  ${YELLOW}tail -f ~/logs/server_*.log${NC}"

echo ""
echo -e "${GREEN}${BOLD}O servidor esta pronto para ser iniciado!${NC}"
echo ""
