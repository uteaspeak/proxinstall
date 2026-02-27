#!/usr/bin/env bash

# =============================================================================
# ovh-debian13-lxc.sh — Provisionamento automatizado de CT Debian 13 (Trixie)
# Plataforma: Proxmox VE 8.x / 9.x + OVH Baremetal com IP Failover
# =============================================================================
#
# Cria um Container LXC Debian 13 no Proxmox VE com:
#   - Rede estatica com IP Failover /32 (gerenciada pelo Proxmox)
#   - Firewall nftables puro (sem iptables) otimizado para VoIP
#   - Sysctl tunado para alta concorrencia (700+ conexoes simultaneas)
#   - Instalacao automatica do TeaSpeak Server 1.4.x
#
# Uso:
#   bash -c "$(wget -qO- https://raw.githubusercontent.com/uteaspeak/proxinstall/main/ovh-debian13-lxc.sh)"
#
# Requisitos:
#   - Proxmox VE 8.x ou 9.x
#   - MAC Virtual configurado no painel OVH
#   - IP Failover atribuido ao servidor
# =============================================================================

set -euo pipefail

# ===================== CORES E FORMATACAO =====================
YW='\033[33m'
BL='\033[36m'
RD='\033[01;31m'
GN='\033[1;92m'
DGN='\033[32m'
BGN='\033[4;92m'
CL='\033[m'
BOLD='\033[1m'
BFR="\\r\\033[K"
TAB="  "

CM="${TAB}✔️${TAB}${CL}"
CROSS="${TAB}✖️${TAB}${CL}"
INFO="${TAB}💡${TAB}${CL}"

# ===================== FUNCOES AUXILIARES =====================
function header_info() {
  clear
  cat <<"EOF"
   ____  _    _ _    _   ____       _     _             __ ____
  / __ \| |  | | |  | | |  _ \  ___| |__ (_) __ _ _ __ /_ |___ \
 | |  | | |  | | |__| | | | | |/ _ \ '_ \| |/ _` | '_ \| | __) |
 | |  | | |  | |  __  | | |_| |  __/ |_) | | (_| | | | | ||__ <
 | |__| | \__/ | |  | | |____/ \___|_.__/|_|\__,_|_| |_|_|___) |
  \____/ \____/|_|  |_|                                  |____/
    ______              _____                  __
   /_  __/__  ____ _   / ___/____  ___  ____ _/ /__
    / / / _ \/ __ `/   \__ \/ __ \/ _ \/ __ `/ //_/
   / / /  __/ /_/ /   ___/ / /_/ /  __/ /_/ / ,<
  /_/  \___/\__,_/   /____/ .___/\___/\__,_/_/|_|
                         /_/
                    [ LXC Container ]
EOF
  echo ""
}

function msg_info() {
  local msg="$1"
  echo -ne "${TAB}${YW} ${msg} ${CL}"
}

function msg_ok() {
  local msg="$1"
  echo -e "${BFR}${CM}${GN}${msg}${CL}"
}

function msg_error() {
  local msg="$1"
  echo -e "${BFR}${CROSS}${RD}${msg}${CL}"
}

function exit_script() {
  clear
  echo -e "\n${CROSS}${RD}Usuario saiu do script${CL}\n"
  exit
}

# ===================== VERIFICACOES =====================
function check_root() {
  if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $PPID) == "sudo" ]]; then
    clear
    msg_error "Execute este script como root."
    echo -e "\nSaindo..."
    sleep 2
    exit 1
  fi
}

function pve_check() {
  if ! command -v pveversion &>/dev/null; then
    msg_error "Este script deve ser executado em um host Proxmox VE."
    exit 1
  fi
  local PVE_VER
  PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  if [[ ! "$PVE_VER" =~ ^(8|9)\.[0-9] ]]; then
    msg_error "Versao do Proxmox VE nao suportada. Requer 8.x ou 9.x"
    exit 1
  fi
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    msg_error "Este script requer arquitetura amd64."
    exit 1
  fi
}

function get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1))
      continue
    fi
    break
  done
  echo "$try_id"
}

# ===================== VALIDACAO DE ENTRADA =====================
function validate_mac() {
  local mac="$1"
  if [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    return 0
  fi
  return 1
}

function validate_ipv4() {
  local ip="$1"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
      if ((octet < 0 || octet > 255)); then
        return 1
      fi
    done
    return 0
  fi
  return 1
}

function validate_ipv4_cidr() {
  local input="$1"
  local ip="${input%%/*}"
  local cidr="${input#*/}"
  if ! validate_ipv4 "$ip"; then
    return 1
  fi
  if [[ "$input" == *"/"* ]]; then
    if [[ "$cidr" =~ ^[0-9]{1,2}$ ]] && ((cidr >= 0 && cidr <= 32)); then
      return 0
    fi
    return 1
  fi
  return 0
}

# ===================== COLETA DE PARAMETROS OVH =====================
function collect_ovh_params() {
  echo -e "\n${BOLD}${BL}=== Configuracao OVH Failover IP ===${CL}\n"

  # MAC Virtual (obrigatorio)
  while true; do
    MAC=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
      --inputbox "MAC Virtual (do painel OVH)\n\nExemplo: 02:00:00:XX:XX:XX\n\nConfigure o MAC Virtual no painel OVH antes de continuar." \
      14 60 "" --title "MAC VIRTUAL (OBRIGATORIO)" --cancel-button Sair 3>&1 1>&2 2>&3) || exit_script
    MAC=$(echo "$MAC" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    if validate_mac "$MAC"; then
      echo -e "${CM}${GN}MAC Virtual: ${BGN}${MAC}${CL}"
      break
    else
      whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
        --msgbox "MAC invalido. Use o formato: XX:XX:XX:XX:XX:XX" 8 50 --title "ERRO"
    fi
  done

  # IPv4 Failover (obrigatorio)
  while true; do
    FAILOVER_IP=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
      --inputbox "IPv4 Failover (IP publico adicional)\n\nExemplo: 1.2.3.4\n\nSera configurado com mascara /32" \
      14 60 "" --title "IPv4 FAILOVER (OBRIGATORIO)" --cancel-button Sair 3>&1 1>&2 2>&3) || exit_script
    FAILOVER_IP=$(echo "$FAILOVER_IP" | tr -d ' ')
    if validate_ipv4 "$FAILOVER_IP"; then
      echo -e "${CM}${GN}IPv4 Failover: ${BGN}${FAILOVER_IP}/32${CL}"
      break
    else
      whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
        --msgbox "IPv4 invalido. Use o formato: X.X.X.X" 8 55 --title "ERRO"
    fi
  done

  # Gateway do servidor (obrigatorio)
  while true; do
    GATEWAY=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
      --inputbox "Gateway do servidor principal\n\nExemplo: 1.2.3.254\n\nVerifique no painel OVH ou com 'ip route'" \
      14 60 "" --title "GATEWAY (OBRIGATORIO)" --cancel-button Sair 3>&1 1>&2 2>&3) || exit_script
    GATEWAY=$(echo "$GATEWAY" | tr -d ' ')
    if validate_ipv4 "$GATEWAY"; then
      echo -e "${CM}${GN}Gateway: ${BGN}${GATEWAY}${CL}"
      break
    else
      whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
        --msgbox "Gateway invalido. Use o formato: X.X.X.X" 8 50 --title "ERRO"
    fi
  done
}

# ===================== COLETA DE PARAMETROS DO CT =====================
function collect_ct_params() {
  echo -e "\n${BOLD}${BL}=== Configuracao do Container ===${CL}\n"

  # CT ID
  CTID=$(get_valid_nextid)
  if NEW_CTID=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
    --inputbox "ID do Container" 8 58 "$CTID" \
    --title "CT ID" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_CTID" ] && CTID="$NEW_CTID"
    echo -e "${CM}${GN}CT ID: ${BGN}${CTID}${CL}"
  else
    exit_script
  fi

  # Hostname
  HN="teaspeak"
  if NEW_HN=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
    --inputbox "Hostname do Container" 8 58 "$HN" \
    --title "HOSTNAME" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_HN" ] && HN=$(echo "${NEW_HN,,}" | tr -d ' ')
    echo -e "${CM}${GN}Hostname: ${BGN}${HN}${CL}"
  else
    exit_script
  fi

  # CPU Cores
  CORE_COUNT="2"
  if NEW_CORES=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
    --inputbox "Nucleos de CPU" 8 58 "$CORE_COUNT" \
    --title "CPU CORES" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_CORES" ] && CORE_COUNT="$NEW_CORES"
    echo -e "${CM}${GN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
  else
    exit_script
  fi

  # RAM
  RAM_SIZE="2048"
  if NEW_RAM=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
    --inputbox "RAM em MiB" 8 58 "$RAM_SIZE" \
    --title "RAM" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_RAM" ] && RAM_SIZE="$NEW_RAM"
    echo -e "${CM}${GN}RAM: ${BGN}${RAM_SIZE} MiB${CL}"
  else
    exit_script
  fi

  # Disk Size
  DISK_SIZE="8"
  if NEW_DISK=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
    --inputbox "Tamanho do disco em GB (ex: 8, 16, 32)" 8 58 "$DISK_SIZE" \
    --title "DISCO" --cancel-button Sair 3>&1 1>&2 2>&3); then
    NEW_DISK=$(echo "$NEW_DISK" | tr -d ' GgBb')
    [[ "$NEW_DISK" =~ ^[0-9]+$ ]] && DISK_SIZE="$NEW_DISK"
    echo -e "${CM}${GN}Disco: ${BGN}${DISK_SIZE} GB${CL}"
  else
    exit_script
  fi

  # Bridge
  BRG="vmbr0"
  if NEW_BRG=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
    --inputbox "Bridge de rede" 8 58 "$BRG" \
    --title "BRIDGE" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_BRG" ] && BRG="$NEW_BRG"
    echo -e "${CM}${GN}Bridge: ${BGN}${BRG}${CL}"
  else
    exit_script
  fi

  # Privilegiado ou nao
  if whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
    --title "TIPO DE CONTAINER" --yesno \
    "Criar container PRIVILEGIADO?\n\nPrivilegiado: Compatibilidade total com nftables e sysctl.\nNao-privilegiado: Mais seguro, mas nftables pode ter limitacoes.\n\nPara TeaSpeak com firewall nftables, recomendado: Privilegiado." \
    14 65 --defaultno; then
    UNPRIVILEGED=0
    echo -e "${CM}${GN}Tipo: ${BGN}Privilegiado${CL}"
  else
    UNPRIVILEGED=1
    echo -e "${CM}${GN}Tipo: ${BGN}Nao-privilegiado${CL}"
  fi

  # Senha root do CT
  while true; do
    ROOT_PASSWORD=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
      --passwordbox "Senha ROOT para o Container Debian 13\n\nEsta sera a senha de acesso root via console e SSH." \
      12 58 "" --title "SENHA ROOT (OBRIGATORIO)" --cancel-button Sair 3>&1 1>&2 2>&3) || exit_script
    if [ -z "$ROOT_PASSWORD" ]; then
      whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
        --msgbox "A senha nao pode ser vazia." 8 50 --title "ERRO"
      continue
    fi
    ROOT_PASSWORD_CONFIRM=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
      --passwordbox "Confirme a senha ROOT" \
      10 58 "" --title "CONFIRMAR SENHA ROOT" --cancel-button Sair 3>&1 1>&2 2>&3) || exit_script
    if [ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]; then
      whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
        --msgbox "As senhas nao coincidem. Tente novamente." 8 50 --title "ERRO"
      continue
    fi
    echo -e "${CM}${GN}Senha root: ${BGN}definida${CL}"
    break
  done
}

# ===================== COLETA DE PARAMETROS NFTABLES =====================
function collect_firewall_params() {
  echo -e "\n${BOLD}${BL}=== Configuracao do Firewall (nftables) ===${CL}\n"

  # Porta SSH
  SSH_PORT="22"
  if NEW_SSH=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
    --inputbox "Porta SSH\n\n(Padrao: 22, recomendado alterar para seguranca)" \
    12 58 "$SSH_PORT" --title "PORTA SSH" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_SSH" ] && SSH_PORT="$NEW_SSH"
    echo -e "${CM}${GN}Porta SSH: ${BGN}${SSH_PORT}${CL}"
  else
    exit_script
  fi

  # Portas TCP
  TCP_PORTS="30303"
  if NEW_TCP=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
    --inputbox "Portas TCP abertas (separadas por virgula)\n\n30303 = TeaSpeak FileTransfer\n\nNOTA: SSH e porta 10101 (Server Query) serao restritas\npor whitelist de IPs na proxima etapa." \
    14 58 "$TCP_PORTS" --title "PORTAS TCP" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_TCP" ] && TCP_PORTS="$NEW_TCP"
    echo -e "${CM}${GN}Portas TCP: ${BGN}${TCP_PORTS}${CL}"
  else
    exit_script
  fi

  # Range UDP
  UDP_RANGE_START="10500"
  UDP_RANGE_END="10530"
  if NEW_UDP_START=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
    --inputbox "Porta UDP inicial (voice channels)\n\nPadrao: 10500" \
    12 58 "$UDP_RANGE_START" --title "UDP INICIO" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_UDP_START" ] && UDP_RANGE_START="$NEW_UDP_START"
  else
    exit_script
  fi
  if NEW_UDP_END=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
    --inputbox "Porta UDP final (voice channels)\n\nPadrao: 10530" \
    12 58 "$UDP_RANGE_END" --title "UDP FIM" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_UDP_END" ] && UDP_RANGE_END="$NEW_UDP_END"
  else
    exit_script
  fi
  echo -e "${CM}${GN}Range UDP: ${BGN}${UDP_RANGE_START}-${UDP_RANGE_END}${CL}"

  # Whitelist IPv4 para SSH e porta 10101 (Server Query)
  WHITELIST_CIDRS=()
  while true; do
    WL_IP=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
      --inputbox "IPv4 para whitelist do SSH e porta 10101 (Server Query)\n\nIP exato (ex: 170.84.159.207) ou CIDR (ex: 170.84.159.0/24)\n\nIPs adicionados: ${#WHITELIST_CIDRS[@]}" \
      16 62 "" --title "WHITELIST SSH/10101 (OBRIGATORIO)" --cancel-button Sair 3>&1 1>&2 2>&3) || exit_script
    WL_IP=$(echo "$WL_IP" | tr -d ' ')
    if validate_ipv4_cidr "$WL_IP"; then
      WHITELIST_CIDRS+=("$WL_IP")
      echo -e "${CM}${GN}Whitelist: ${BGN}${WL_IP}${CL}"
      if ! (whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
        --title "ADICIONAR MAIS?" --yesno "Adicionar outro IPv4 a whitelist?" 8 50); then
        break
      fi
    else
      whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
        --msgbox "IPv4 invalido. Use o formato: X.X.X.X ou X.X.X.X/CIDR" 8 55 --title "ERRO"
    fi
  done
  if [ ${#WHITELIST_CIDRS[@]} -eq 0 ]; then
    msg_error "Pelo menos um IPv4 deve ser informado para whitelist do SSH e porta 10101"
    exit 1
  fi
  WHITELIST_NFT=$(printf ", %s" "${WHITELIST_CIDRS[@]}")
  WHITELIST_NFT="${WHITELIST_NFT:2}"
}

# ===================== GERAR CONFIGURACAO NFTABLES =====================
function generate_nftables_conf() {
  cat <<NFTEOF
#!/usr/sbin/nft -f
# =============================================================================
# nftables - Firewall TeaSpeak Server (OVH Failover IP)
# Gerado automaticamente pelo ovh-debian13-lxc.sh
# 100% nftables (sem iptables) - otimizado para 700+ usuarios simultaneos
# =============================================================================
# IMPORTANTE: UDP voice tem PRIORIDADE MAXIMA na chain input.
# Aceito ANTES de 'ct state invalid drop' para que conntrack nunca
# interfira com trafego de voz. Sem rate limit global nas portas UDP.
# Protecao volumetrica e responsabilidade do anti-DDoS da OVH.
# =============================================================================

flush ruleset

table inet firewall {

    chain input {
        type filter hook input priority 0; policy drop;

        # Loopback - trafego interno do sistema
        iif "lo" accept

        # Conexoes estabelecidas/relacionadas - usuarios conectados SEMPRE passam
        ct state established,related accept

        # =============================================================
        # UDP VOICE - PRIORIDADE MAXIMA (antes de qualquer filtro)
        # =============================================================
        udp dport ${UDP_RANGE_START}-${UDP_RANGE_END} accept

        # Descartar pacotes invalidos (seguro: UDP voice ja aceito acima)
        ct state invalid drop

        # ICMP
        ip protocol icmp icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } limit rate 5/second burst 10 packets accept
        ip protocol icmp drop

        # ICMPv6
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, echo-reply, destination-unreachable, time-exceeded, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } limit rate 5/second burst 10 packets accept
        ip6 nexthdr icmpv6 drop

        # SSH (porta ${SSH_PORT}) - whitelist + rate limit POR IP de origem
        ip saddr { ${WHITELIST_NFT} } tcp dport ${SSH_PORT} ct state new meter ssh_limit { ip saddr limit rate 5/minute burst 10 packets } accept

        # TeaSpeak TCP (FileTransfer e outros servicos)
        tcp dport { ${TCP_PORTS} } accept

        # Server Query (10101) - apenas IPs autorizados (whitelist)
        ip saddr { ${WHITELIST_NFT} } tcp dport 10101 accept

        # Log de pacotes descartados
        limit rate 3/minute burst 5 packets log prefix "nftables-drop: " level warn
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
NFTEOF
}

# ===================== GERAR SYSCTL PARA ALTA CONCORRENCIA =====================
function generate_sysctl_conf() {
  cat <<SYSEOF
# =============================================================================
# Sysctl - Otimizacoes para TeaSpeak Server (700+ usuarios)
# Gerado automaticamente pelo ovh-debian13-lxc.sh
# =============================================================================

# Conntrack
net.netfilter.nf_conntrack_max = 262144
net.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_buckets = 65536
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

# Buffers de rede UDP
net.core.rmem_max = 26214400
net.core.rmem_default = 1048576
net.core.wmem_max = 26214400
net.core.wmem_default = 1048576

# Backlog de rede
net.core.netdev_max_backlog = 10000

# Protecao contra SYN flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096

# Desabilitar ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Desabilitar source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Protecao contra IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
SYSEOF
}

# ===================== SELECAO DE STORAGE =====================
function select_storage() {
  msg_info "Validando Storage"
  local STORAGE_MENU=()
  local MSG_MAX_LENGTH=0

  while read -r line; do
    local TAG TYPE FREE ITEM OFFSET
    TAG=$(echo "$line" | awk '{print $1}')
    TYPE=$(echo "$line" | awk '{printf "%-10s", $2}')
    FREE=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
    ITEM="  Type: $TYPE Free: $FREE "
    OFFSET=2
    if [[ $((${#ITEM} + OFFSET)) -gt ${MSG_MAX_LENGTH} ]]; then
      MSG_MAX_LENGTH=$((${#ITEM} + OFFSET))
    fi
    STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
  done < <(pvesm status -content rootdir | awk 'NR>1')

  local VALID
  VALID=$(pvesm status -content rootdir | awk 'NR>1')
  if [ -z "$VALID" ]; then
    msg_error "Nenhum storage valido para containers detectado."
    exit 1
  elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
    STORAGE=${STORAGE_MENU[0]}
  else
    while [ -z "${STORAGE:+x}" ]; do
      STORAGE=$(whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" --title "Storage" --radiolist \
        "Selecione o storage para o CT ${HN}:\n" \
        16 $((MSG_MAX_LENGTH + 23)) 6 \
        "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit_script
    done
  fi
  msg_ok "Storage: ${CL}${BL}${STORAGE}${CL}"
}

# ===================== DOWNLOAD DO TEMPLATE =====================
function download_template() {
  msg_info "Buscando template Debian 13"

  # Encontrar storage que suporta templates
  TEMPLATE_STORAGE=$(pvesm status -content vztmpl | awk 'NR>1 {print $1}' | head -1)
  if [ -z "$TEMPLATE_STORAGE" ]; then
    msg_error "Nenhum storage para templates (vztmpl) encontrado."
    exit 1
  fi

  # Atualizar lista de templates
  pveam update >/dev/null 2>&1

  # Buscar template Debian 13
  TEMPLATE=$(pveam available --section system 2>/dev/null | grep -i 'debian-13' | awk '{print $2}' | sort -V | tail -1)
  if [ -z "$TEMPLATE" ]; then
    msg_error "Template Debian 13 nao encontrado. Verifique se o repositorio de templates esta acessivel."
    exit 1
  fi

  # Verificar se ja esta baixado
  if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
    msg_ok "Template ja disponivel: ${CL}${BL}${TEMPLATE}${CL}"
  else
    msg_info "Baixando template: ${TEMPLATE}"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null 2>&1
    msg_ok "Template baixado: ${CL}${BL}${TEMPLATE}${CL}"
  fi

  TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
}

# ===================== CRIACAO DO CONTAINER =====================
function create_ct() {

  download_template

  # Criar CT
  msg_info "Criando Container Debian 13 (${HN})"
  pct create "$CTID" "$TEMPLATE_PATH" \
    --hostname "$HN" \
    --cores "$CORE_COUNT" \
    --memory "$RAM_SIZE" \
    --swap 512 \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --net0 "name=eth0,bridge=${BRG},hwaddr=${MAC},ip=${FAILOVER_IP}/32,gw=${GATEWAY},type=veth" \
    --nameserver "213.186.33.99 1.1.1.1" \
    --password "$ROOT_PASSWORD" \
    --unprivileged "$UNPRIVILEGED" \
    --features "nesting=1" \
    --onboot 1 \
    --start 0 >/dev/null 2>&1
  msg_ok "Container criado (ID: ${CTID})"

  # Descricao do CT
  local DESCRIPTION
  DESCRIPTION="OVH Debian 13 LXC - TeaSpeak | IP: ${FAILOVER_IP}/32 | SSH: ${SSH_PORT} | TCP: ${TCP_PORTS} | UDP: ${UDP_RANGE_START}-${UDP_RANGE_END}"
  pct set "$CTID" -description "$DESCRIPTION" >/dev/null 2>&1

  # Iniciar CT
  msg_info "Iniciando Container"
  pct start "$CTID"
  msg_ok "Container iniciado"

  # Esperar o container estar pronto
  msg_info "Aguardando container inicializar"
  local retries=0
  while [ $retries -lt 30 ]; do
    if pct exec "$CTID" -- test -f /etc/os-release 2>/dev/null; then
      break
    fi
    sleep 2
    retries=$((retries + 1))
  done
  if [ $retries -ge 30 ]; then
    msg_error "Timeout esperando o container inicializar."
    exit 1
  fi
  msg_ok "Container pronto"

  # Esperar rede funcionar
  msg_info "Aguardando conectividade de rede"
  retries=0
  while [ $retries -lt 30 ]; do
    if pct exec "$CTID" -- ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
      break
    fi
    sleep 2
    retries=$((retries + 1))
  done
  if [ $retries -ge 30 ]; then
    msg_error "Sem conectividade de rede. Verifique MAC Virtual e IP Failover no painel OVH."
    echo -e "  ${YW}O container foi criado mas nao tem rede.${CL}"
    echo -e "  ${YW}Verifique: pct exec ${CTID} -- ip addr${CL}"
    echo -e "  ${YW}Verifique: pct exec ${CTID} -- ip route${CL}"
    exit 1
  fi
  msg_ok "Rede OK"

  # ===================== INSTALACAO DENTRO DO CONTAINER =====================

  # Atualizar sistema
  msg_info "Atualizando sistema"
  pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get update -y >/dev/null 2>&1 && apt-get upgrade -y >/dev/null 2>&1"
  msg_ok "Sistema atualizado"

  # Remover iptables residual e instalar pacotes
  msg_info "Instalando pacotes necessarios"
  pct exec "$CTID" -- bash -c 'export DEBIAN_FRONTEND=noninteractive
# Desabilitar persistencia iptables
systemctl stop netfilter-persistent 2>/dev/null || true
systemctl disable netfilter-persistent 2>/dev/null || true
systemctl mask netfilter-persistent 2>/dev/null || true

# Flush iptables residual
if command -v iptables &>/dev/null; then
  iptables -F 2>/dev/null || true
  iptables -X 2>/dev/null || true
  iptables -t nat -F 2>/dev/null || true
  iptables -t mangle -F 2>/dev/null || true
  iptables -P INPUT ACCEPT 2>/dev/null || true
  iptables -P FORWARD ACCEPT 2>/dev/null || true
  iptables -P OUTPUT ACCEPT 2>/dev/null || true
fi
if command -v ip6tables &>/dev/null; then
  ip6tables -F 2>/dev/null || true
  ip6tables -X 2>/dev/null || true
  ip6tables -P INPUT ACCEPT 2>/dev/null || true
  ip6tables -P FORWARD ACCEPT 2>/dev/null || true
  ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
fi

apt-get purge -y iptables-persistent netfilter-persistent 2>/dev/null || true
rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6 2>/dev/null || true
rm -rf /etc/iptables 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# Instalar pacotes
apt-get install -y openssh-server cron nftables sudo wget curl screen xz-utils libnice10 >/dev/null 2>&1
'
  msg_ok "Pacotes instalados"

  # Configurar SSH
  msg_info "Configurando SSH (porta ${SSH_PORT})"
  pct exec "$CTID" -- bash -c "
# Debian 13 usa ssh.socket (systemd socket activation) que ignora Port do sshd_config.
# Desabilitar socket activation para que sshd gerencie a porta diretamente.
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl disable --now ssh@.service 2>/dev/null || true
rm -f /etc/systemd/system/ssh.service.d/00-socket.conf 2>/dev/null || true
mkdir -p /etc/systemd/system/ssh.socket.d
cat > /etc/systemd/system/ssh.socket.d/override.conf << 'SSHSOCK'
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
SSHSOCK
systemctl daemon-reload

sed -i 's/^#\\?Port .*/Port ${SSH_PORT}/' /etc/ssh/sshd_config
grep -q '^Port ' /etc/ssh/sshd_config || echo 'Port ${SSH_PORT}' >> /etc/ssh/sshd_config
sed -i 's/^#\\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
grep -q '^PermitRootLogin ' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
grep -q '^PasswordAuthentication ' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
systemctl enable ssh.socket 2>/dev/null || true
systemctl restart ssh.socket 2>/dev/null || true
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
"
  msg_ok "SSH configurado na porta ${SSH_PORT}"

  # Enviar configuracao nftables
  msg_info "Configurando firewall nftables"
  generate_nftables_conf > "/tmp/ovh_nftables_${CTID}.conf"
  pct push "$CTID" "/tmp/ovh_nftables_${CTID}.conf" /etc/nftables.conf
  rm -f "/tmp/ovh_nftables_${CTID}.conf"
  pct exec "$CTID" -- bash -c '
# Override do nftables.service para funcionar corretamente em containers LXC
# - Remove ProtectSystem/ProtectHome (incompativeis com namespaces LXC)
# - Garante ativacao via multi-user.target (sysinit.target pode nao funcionar em LXC)
mkdir -p /etc/systemd/system/nftables.service.d
cat > /etc/systemd/system/nftables.service.d/override.conf << NFTOVER
[Service]
ProtectSystem=
ProtectHome=

[Install]
WantedBy=multi-user.target
NFTOVER
systemctl daemon-reload
systemctl enable nftables >/dev/null 2>&1
systemctl restart nftables >/dev/null 2>&1
if [ -f /etc/nftables.conf ]; then
  nft -f /etc/nftables.conf 2>/dev/null || echo "AVISO: nftables nao pode ser carregado (normal em containers nao-privilegiados)"
fi
'
  msg_ok "Firewall configurado"

  # Enviar sysctl
  msg_info "Configurando sysctl (alta concorrencia)"
  generate_sysctl_conf > "/tmp/99-teaspeak_${CTID}.conf"
  pct push "$CTID" "/tmp/99-teaspeak_${CTID}.conf" /etc/sysctl.d/99-teaspeak.conf
  rm -f "/tmp/99-teaspeak_${CTID}.conf"
  pct exec "$CTID" -- bash -c 'sysctl --system >/dev/null 2>&1 || true'
  msg_ok "Sysctl configurado"

  # Criar usuario teaspeak
  msg_info "Criando usuario teaspeak"
  pct exec "$CTID" -- bash -c '
TEASPEAK_PASSWORD=$(openssl rand -base64 16 | tr -d "/+=" | head -c 20)
if ! id "teaspeak" &>/dev/null; then
  useradd -m -s /bin/bash teaspeak
  echo "teaspeak:${TEASPEAK_PASSWORD}" | chpasswd
fi

CREDENTIALS_FILE="/root/teaspeak_credentials.txt"
cat > "$CREDENTIALS_FILE" << CREDEOF
# =============================================================================
# Credenciais TeaSpeak Server
# Gerado em: $(date "+%Y-%m-%d %H:%M:%S")
# =============================================================================
#
# IMPORTANTE: Altere a senha apos o primeiro acesso!
#   passwd teaspeak
#
# Apos alterar, delete este arquivo:
#   rm -f $CREDENTIALS_FILE
# =============================================================================

Usuario: teaspeak
Senha:   ${TEASPEAK_PASSWORD}

CREDEOF
chmod 600 "$CREDENTIALS_FILE"
'
  msg_ok "Usuario teaspeak criado"

  # Instalar TeaSpeak
  msg_info "Baixando e instalando TeaSpeak Server"
  pct exec "$CTID" -- bash -c '
for attempt in 1 2 3; do
  su - teaspeak -c "
cd ~
wget -q --show-progress https://repo.teaspeak.de/server/linux/amd64_optimized/TeaSpeak-1.4.21-beta-3.tar.gz || exit 1
tar -xzf TeaSpeak-1.4.21-beta-3.tar.gz || exit 1
rm -f TeaSpeak-1.4.21-beta-3.tar.gz
" && break
  echo "Tentativa $attempt falhou, tentando novamente em 10s..."
  sleep 10
done

if [ ! -f /home/teaspeak/teastart.sh ]; then
  echo "ERRO: Falha ao baixar/extrair TeaSpeak apos 3 tentativas"
  exit 1
fi
'
  msg_ok "TeaSpeak instalado"

  # Configurar scripts auxiliares (anticrash, backup)
  msg_info "Configurando automacao (anticrash, backup, cron)"
  pct exec "$CTID" -- bash -c '
mkdir -p /home/teaspeak/resources /home/teaspeak/backups

# Script anticrash
cat > /home/teaspeak/resources/anticrash.sh << '\''AEOF'\''
#!/bin/bash
case $1 in
teaspeakserver)
    teaspeakserverpid=$(ps ax | grep TeaSpeakServer | grep -v grep | wc -l)
    if [ "$teaspeakserverpid" -eq 1 ]; then
        exit
    else
        /home/teaspeak/teastart.sh start
    fi
;;
esac
AEOF

# Script backup
cat > /home/teaspeak/resources/teaspeakbackup.sh << '\''BEOF'\''
#!/bin/bash
TS3_DIR="/home/teaspeak"
BACKUP_DIR="/home/teaspeak/backups"
LOG_FILE="/home/teaspeak/backups/backup.log"
DATE=$(date +"%Y%m%d_%H%M%S")
BACKUP_NAME="teaspeak_backup_$DATE.tar.gz"
RETENTION_DAYS=30

log_message() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" >> "$LOG_FILE"; }
error_exit() { log_message "ERRO - $1"; exit 1; }

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
    BACKUP_SIZE=$(ls -lh "$BACKUP_DIR/$BACKUP_NAME" | awk "{print \$5}")
    log_message "Backup criado: $BACKUP_NAME ($BACKUP_SIZE)"
    find "$BACKUP_DIR" -name "teaspeak_backup_*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete
    log_message "Limpeza de backups antigos concluida"
else
    error_exit "Falha ao criar backup"
fi

tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
exit 0
BEOF

chmod +x /home/teaspeak/resources/*.sh
chown -R teaspeak:teaspeak /home/teaspeak/resources
chown -R teaspeak:teaspeak /home/teaspeak/backups

# Crontab do teaspeak
su - teaspeak -c "cat > /tmp/teaspeak_crontab << CRON
@reboot cd /home/teaspeak && ./teastart.sh start
*/5 * * * * /home/teaspeak/resources/anticrash.sh teaspeakserver > /dev/null 2>&1
0 6 * * * /home/teaspeak/resources/teaspeakbackup.sh >/dev/null 2>&1
CRON
crontab /tmp/teaspeak_crontab
rm -f /tmp/teaspeak_crontab"
'
  msg_ok "Automacao configurada"

  # Primeira inicializacao do TeaSpeak
  msg_info "Inicializando TeaSpeak (primeiro boot)"
  pct exec "$CTID" -- bash -c '
if [ -f /home/teaspeak/teastart_minimal.sh ]; then
  su - teaspeak -c "
cd /home/teaspeak
./teastart_minimal.sh > /tmp/teaspeak_init.log 2>&1 &
TS_PID=\$!
sleep 3
kill \$TS_PID 2>/dev/null
wait \$TS_PID 2>/dev/null
"
fi
pkill -9 -u teaspeak TeaSpeakServer 2>/dev/null || true
sleep 1
'
  msg_ok "TeaSpeak inicializado"

  # Baixar config.yml customizado
  msg_info "Baixando configuracao customizada"
  pct exec "$CTID" -- bash -c '
su - teaspeak -c "
cd /home/teaspeak
[ -f config.yml ] && cp config.yml config.yml.original
wget -q https://raw.githubusercontent.com/uteaspeak/proxinstall/main/config.yml -O config.yml.new && mv config.yml.new config.yml
"
'
  msg_ok "Configuracao aplicada"

  # Iniciar TeaSpeak
  msg_info "Iniciando TeaSpeak Server"
  pct exec "$CTID" -- bash -c '
su - teaspeak -c "cd /home/teaspeak && ./teastart.sh start" >/dev/null 2>&1
'
  sleep 2
  if pct exec "$CTID" -- pgrep -u teaspeak TeaSpeakServer >/dev/null 2>&1; then
    msg_ok "TeaSpeak Server rodando"
  else
    msg_ok "TeaSpeak Server configurado (sera iniciado via cron)"
  fi
}

# ===================== RESUMO FINAL =====================
function show_summary() {
  echo ""
  echo -e "${GN}${BOLD}======================================================${CL}"
  echo -e "${GN}${BOLD}       CONTAINER DEBIAN 13 CRIADO COM SUCESSO         ${CL}"
  echo -e "${GN}${BOLD}======================================================${CL}"
  echo ""
  echo -e "${BL}Configuracao do Container:${CL}"
  echo -e "  CT ID:      ${BOLD}${CTID}${CL}"
  echo -e "  Hostname:   ${BOLD}${HN}${CL}"
  echo -e "  CPU:        ${BOLD}${CORE_COUNT} cores${CL}"
  echo -e "  RAM:        ${BOLD}${RAM_SIZE} MiB${CL}"
  echo -e "  Disco:      ${BOLD}${DISK_SIZE} GB${CL}"
  echo -e "  Storage:    ${BOLD}${STORAGE}${CL}"
  echo -e "  Tipo:       ${BOLD}$([ $UNPRIVILEGED -eq 0 ] && echo 'Privilegiado' || echo 'Nao-privilegiado')${CL}"
  echo ""
  echo -e "${BL}Configuracao de Rede OVH:${CL}"
  echo -e "  MAC Virtual:    ${BOLD}${MAC}${CL}"
  echo -e "  IPv4 Failover:  ${BOLD}${FAILOVER_IP}/32${CL}"
  echo -e "  Gateway:        ${BOLD}${GATEWAY}${CL}"
  echo -e "  Bridge:         ${BOLD}${BRG}${CL}"
  echo ""
  echo -e "${BL}Firewall (nftables):${CL}"
  echo -e "  SSH:   ${BOLD}porta ${SSH_PORT}${CL} (whitelist + rate limit 5/min por IP)"
  echo -e "  SSH/10101: ${BOLD}whitelist: ${WHITELIST_NFT}${CL}"
  echo -e "  TCP:   ${BOLD}${TCP_PORTS}${CL}"
  echo -e "  UDP:   ${BOLD}${UDP_RANGE_START}-${UDP_RANGE_END}${CL} (prioridade maxima)"
  echo -e "  ICMP:  ${BOLD}limitado 5/s${CL}"
  echo -e "  Conntrack: ${BOLD}262144 entradas${CL}"
  echo ""
  echo -e "${BL}Acesso root do CT:${CL}"
  echo -e "  Senha root: ${BOLD}definida pelo usuario${CL}"
  echo ""
  echo -e "${BL}TeaSpeak Server:${CL}"
  echo -e "  ${GN}${BOLD}Credenciais salvas em:${CL} ${YW}/root/teaspeak_credentials.txt${CL}"
  echo -e "  ${INFO}Acesse o container e leia: ${YW}cat /root/teaspeak_credentials.txt${CL}"
  echo -e "  ${RD}${BOLD}ALTERE A SENHA APOS O PRIMEIRO ACESSO:${CL} ${YW}passwd teaspeak${CL}"
  echo ""
  echo -e "${BL}Backups automaticos:${CL}"
  echo -e "  Diretorio:  ${BOLD}/home/teaspeak/backups/${CL}"
  echo -e "  Frequencia: ${BOLD}Diario as 6h${CL}"
  echo -e "  Retencao:   ${BOLD}30 dias${CL}"
  echo -e "  Anti-crash: ${BOLD}Verificacao a cada 5 minutos${CL}"
  echo -e "  AutoStart:  ${BOLD}Ativo no boot${CL}"
  echo ""
  echo -e "${BL}Acesso ao Container:${CL}"
  echo -e "  Console: ${YW}pct console ${CTID}${CL}"
  echo -e "  Enter:   ${YW}pct enter ${CTID}${CL}"
  echo -e "  SSH:     ${YW}ssh root@${FAILOVER_IP} -p ${SSH_PORT}${CL}"
  echo ""
  echo -e "${BL}Verificar firewall (dentro do CT):${CL}"
  echo -e "  ${YW}nft list ruleset${CL}"
  echo ""
  echo -e "${BL}Iniciar TeaSpeak (dentro do CT):${CL}"
  echo -e "  ${YW}su teaspeak${CL}"
  echo -e "  ${YW}cd ~ && ./teastart.sh start${CL}"
  echo ""
  echo -e "${GN}${BOLD}O container esta pronto!${CL}"
  echo ""
}

# ===================== MAIN =====================
header_info

# Confirmacao
if ! whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
  --title "Debian 13 LXC - OVH TeaSpeak" \
  --yesno "Este script ira criar um Container LXC Debian 13 configurado para:\n\n• IP Failover OVH (MAC Virtual + IPv4/32)\n• Firewall nftables com portas configuraveis\n• Instalacao automatica do TeaSpeak Server\n\nRequisitos:\n• MAC Virtual configurado no painel OVH\n• IP Failover atribuido ao servidor\n\nContinuar?" 18 62; then
  echo -e "${CROSS}${RD}Usuario saiu do script${CL}\n"
  exit
fi

check_root
arch_check
pve_check

header_info
collect_ovh_params
collect_ct_params
collect_firewall_params

# Confirmacao final
echo ""
echo -e "${BOLD}${BL}=== Resumo da Configuracao ===${CL}"
echo -e "  MAC Virtual:   ${BOLD}${MAC}${CL}"
echo -e "  IPv4 Failover: ${BOLD}${FAILOVER_IP}/32${CL}"
echo -e "  Gateway:       ${BOLD}${GATEWAY}${CL}"
echo -e "  CT ID:         ${BOLD}${CTID}${CL}"
echo -e "  Hostname:      ${BOLD}${HN}${CL}"
echo -e "  CPU:           ${BOLD}${CORE_COUNT} cores${CL}"
echo -e "  RAM:           ${BOLD}${RAM_SIZE} MiB${CL}"
echo -e "  Disco:         ${BOLD}${DISK_SIZE} GB${CL}"
echo -e "  Tipo:          ${BOLD}$([ $UNPRIVILEGED -eq 0 ] && echo 'Privilegiado' || echo 'Nao-privilegiado')${CL}"
echo -e "  Senha root:    ${BOLD}definida${CL}"
echo -e "  SSH:           ${BOLD}porta ${SSH_PORT}${CL}"
echo -e "  SSH/10101:     ${BOLD}whitelist: ${WHITELIST_NFT}${CL}"
echo -e "  UDP:           ${BOLD}${UDP_RANGE_START}-${UDP_RANGE_END}${CL}"
echo ""

if ! whiptail --backtitle "OVH Debian 13 LXC - TeaSpeak" \
  --title "CONFIRMAR" --yesno "Criar o container com as configuracoes acima?" 8 58; then
  echo -e "${CROSS}${RD}Usuario cancelou a criacao${CL}\n"
  exit
fi

select_storage
create_ct
show_summary
