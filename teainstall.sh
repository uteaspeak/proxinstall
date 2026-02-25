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

# iptables-persistent precisa de tratamento especial
printf "  - Instalando ${BOLD}iptables-persistent${NC} (pode demorar)..."
DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent > /dev/null 2>&1 &
IPTABLES_PID=$!
spinner $IPTABLES_PID
if wait $IPTABLES_PID; then
    printf " ${GREEN}OK${NC}\n"
else
    printf " ${YELLOW}JA INSTALADO${NC}\n"
fi

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
for item in "files" "geoloc" "config.yml" "query_ip_whitelist.txt" "TeaData.sqlite"; do
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

# 5.5. Coletar IPv4 para whitelist da porta 10101
step "Configurando whitelist para porta 10101 (Server Query)..."
WHITELIST_IPS=()
echo -e "${YELLOW}Digite os IPv4 para whitelist da porta 10101${NC}"
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

# 6. Configurar iptables
step "Configurando firewall (iptables)..."

printf "${YELLOW}Aplicando regras de firewall...${NC}"

# Limpar regras antigas
iptables -F > /dev/null 2>&1
iptables -X > /dev/null 2>&1

# Politicas padrao
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Permitir trafego local
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# TCP: SSH e 30303
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 30303 -j ACCEPT

# TCP: 10101 restrita por whitelist
for cidr in "${WHITELIST_IPS[@]}"; do
    iptables -A INPUT -p tcp -s "$cidr" --dport 10101 -j ACCEPT
done

# UDP: 10500-10530 com rate limiting
iptables -N TS3_UDP
iptables -A INPUT -p udp --dport 10500:10530 -j TS3_UDP
iptables -A TS3_UDP -m conntrack --ctstate NEW -m limit --limit 50/sec --limit-burst 100 -j ACCEPT
iptables -A TS3_UDP -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A TS3_UDP -m limit --limit 5/min -j LOG --log-prefix "TS3 DDoS: "
iptables -A TS3_UDP -j DROP

# Mitigacao de flood com recent
iptables -A INPUT -p udp --dport 10500:10530 -m recent --name TS3_ATTACK --set
iptables -A INPUT -p udp --dport 10500:10530 -m recent --name TS3_ATTACK --update --seconds 60 --hitcount 100 -j DROP

# ICMP limitado
iptables -A INPUT -p icmp -m limit --limit 1/s -j ACCEPT
iptables -A INPUT -p icmp -j DROP

# Salvar regras permanentemente
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save > /dev/null 2>&1
else
    iptables-save > /etc/iptables/rules.v4
fi

# Garantir que as regras sejam restauradas no boot
cat > /etc/network/if-pre-up.d/iptables << 'EOF'
#!/bin/sh
/sbin/iptables-restore < /etc/iptables/rules.v4
EOF
chmod +x /etc/network/if-pre-up.d/iptables

printf " ${GREEN}OK${NC}\n"
log "Firewall configurado e salvo"

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
echo -e "  - Firewall: ${GREEN}OK${NC} - iptables configurado"

echo ""
echo -e "${CYAN}Portas abertas:${NC}"
echo -e "  - TCP: 22, 30303"
echo -e "  - TCP 10101: whitelist: ${WHITELIST_IPS[*]}"
echo -e "  - UDP: 10500-10530 com rate limiting"

echo ""
echo -e "${CYAN}Verificar firewall:${NC}"
echo -e "  ${YELLOW}iptables -L -v -n${NC}"
echo -e "  ${YELLOW}iptables -L TS3_UDP -v -n${NC}"

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
