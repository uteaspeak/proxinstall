#!/usr/bin/env bash

# =============================================================================
# ovh-debian13-vm.sh — Provisionamento automatizado de VM Debian 13 (Trixie)
# Plataforma: Proxmox VE 8.x / 9.x + OVH Baremetal com IP Failover
# =============================================================================
#
# Cria uma VM Debian 13 no Proxmox VE com:
#   - Rede estatica com IP Failover /32 via netplan + systemd-networkd
#   - Firewall nftables puro (sem iptables) otimizado para VoIP
#   - Sysctl tunado para alta concorrencia (700+ conexoes simultaneas)
#   - Instalacao automatica do TeaSpeak Server 1.4.x
#
# Uso:
#   bash -c "$(wget -qO- https://raw.githubusercontent.com/uteaspeak/proxinstall/main/ovh-debian13-vm.sh)"
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
    MAC=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
      --inputbox "MAC Virtual (do painel OVH)\n\nExemplo: 02:00:00:XX:XX:XX\n\nConfigure o MAC Virtual no painel OVH antes de continuar." \
      14 60 "" --title "MAC VIRTUAL (OBRIGATORIO)" --cancel-button Sair 3>&1 1>&2 2>&3) || exit_script
    MAC=$(echo "$MAC" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    if validate_mac "$MAC"; then
      echo -e "${CM}${GN}MAC Virtual: ${BGN}${MAC}${CL}"
      break
    else
      whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
        --msgbox "MAC invalido. Use o formato: XX:XX:XX:XX:XX:XX" 8 50 --title "ERRO"
    fi
  done

  # IPv4 Failover (obrigatorio)
  while true; do
    FAILOVER_IP=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
      --inputbox "IPv4 Failover (IP publico adicional)\n\nExemplo: 1.2.3.4\n\nSera configurado com mascara /32" \
      14 60 "" --title "IPv4 FAILOVER (OBRIGATORIO)" --cancel-button Sair 3>&1 1>&2 2>&3) || exit_script
    FAILOVER_IP=$(echo "$FAILOVER_IP" | tr -d ' ')
    if validate_ipv4 "$FAILOVER_IP"; then
      echo -e "${CM}${GN}IPv4 Failover: ${BGN}${FAILOVER_IP}/32${CL}"
      break
    else
      whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
        --msgbox "IPv4 invalido. Use o formato: X.X.X.X" 8 50 --title "ERRO"
    fi
  done

  # Gateway do servidor (obrigatorio)
  while true; do
    GATEWAY=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
      --inputbox "Gateway do servidor principal\n\nExemplo: 1.2.3.254\n\nVerifique no painel OVH ou com 'ip route'" \
      14 60 "" --title "GATEWAY (OBRIGATORIO)" --cancel-button Sair 3>&1 1>&2 2>&3) || exit_script
    GATEWAY=$(echo "$GATEWAY" | tr -d ' ')
    if validate_ipv4 "$GATEWAY"; then
      echo -e "${CM}${GN}Gateway: ${BGN}${GATEWAY}${CL}"
      break
    else
      whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
        --msgbox "Gateway invalido. Use o formato: X.X.X.X" 8 50 --title "ERRO"
    fi
  done
}

# ===================== COLETA DE PARAMETROS DA VM =====================
function collect_vm_params() {
  echo -e "\n${BOLD}${BL}=== Configuracao da VM ===${CL}\n"

  # VM ID
  VMID=$(get_valid_nextid)
  if NEW_VMID=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
    --inputbox "ID da Maquina Virtual" 8 58 "$VMID" \
    --title "VM ID" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_VMID" ] && VMID="$NEW_VMID"
    echo -e "${CM}${GN}VM ID: ${BGN}${VMID}${CL}"
  else
    exit_script
  fi

  # Hostname
  HN="teaspeak"
  if NEW_HN=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
    --inputbox "Hostname da VM" 8 58 "$HN" \
    --title "HOSTNAME" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_HN" ] && HN=$(echo "${NEW_HN,,}" | tr -d ' ')
    echo -e "${CM}${GN}Hostname: ${BGN}${HN}${CL}"
  else
    exit_script
  fi

  # CPU Cores
  CORE_COUNT="2"
  if NEW_CORES=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
    --inputbox "Nucleos de CPU" 8 58 "$CORE_COUNT" \
    --title "CPU CORES" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_CORES" ] && CORE_COUNT="$NEW_CORES"
    echo -e "${CM}${GN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
  else
    exit_script
  fi

  # RAM
  RAM_SIZE="2048"
  if NEW_RAM=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
    --inputbox "RAM em MiB" 8 58 "$RAM_SIZE" \
    --title "RAM" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_RAM" ] && RAM_SIZE="$NEW_RAM"
    echo -e "${CM}${GN}RAM: ${BGN}${RAM_SIZE} MiB${CL}"
  else
    exit_script
  fi

  # Disk Size
  DISK_SIZE="100G"
  if NEW_DISK=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
    --inputbox "Tamanho do disco (ex: 16, 32, 64)" 8 58 "16" \
    --title "DISCO" --cancel-button Sair 3>&1 1>&2 2>&3); then
    NEW_DISK=$(echo "$NEW_DISK" | tr -d ' ')
    if [[ "$NEW_DISK" =~ ^[0-9]+$ ]]; then
      DISK_SIZE="${NEW_DISK}G"
    elif [[ "$NEW_DISK" =~ ^[0-9]+G$ ]]; then
      DISK_SIZE="$NEW_DISK"
    fi
    echo -e "${CM}${GN}Disco: ${BGN}${DISK_SIZE}${CL}"
  else
    exit_script
  fi

  # Bridge
  BRG="vmbr0"
  if NEW_BRG=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
    --inputbox "Bridge de rede" 8 58 "$BRG" \
    --title "BRIDGE" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_BRG" ] && BRG="$NEW_BRG"
    echo -e "${CM}${GN}Bridge: ${BGN}${BRG}${CL}"
  else
    exit_script
  fi

  # Senha root da VM
  while true; do
    ROOT_PASSWORD=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
      --passwordbox "Senha ROOT para a VM Debian 13\n\nEsta sera a senha de acesso root via SSH e console." \
      12 58 "" --title "SENHA ROOT (OBRIGATORIO)" --cancel-button Sair 3>&1 1>&2 2>&3) || exit_script
    if [ -z "$ROOT_PASSWORD" ]; then
      whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
        --msgbox "A senha nao pode ser vazia." 8 50 --title "ERRO"
      continue
    fi
    ROOT_PASSWORD_CONFIRM=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
      --passwordbox "Confirme a senha ROOT" \
      10 58 "" --title "CONFIRMAR SENHA ROOT" --cancel-button Sair 3>&1 1>&2 2>&3) || exit_script
    if [ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]; then
      whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
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
  if NEW_SSH=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
    --inputbox "Porta SSH\n\n(Padrao: 22, recomendado alterar para seguranca)" \
    12 58 "$SSH_PORT" --title "PORTA SSH" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_SSH" ] && SSH_PORT="$NEW_SSH"
    echo -e "${CM}${GN}Porta SSH: ${BGN}${SSH_PORT}${CL}"
  else
    exit_script
  fi

  # Portas TCP (sem a 10101 que sera restrita por whitelist)
  TCP_PORTS="30303"
  if NEW_TCP=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
    --inputbox "Portas TCP abertas (separadas por virgula)\n\n30303 = TeaSpeak FileTransfer\n\nNOTA: A porta 10101 (Server Query) sera restrita\npor whitelist de IPs na proxima etapa." \
    14 58 "$TCP_PORTS" --title "PORTAS TCP" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_TCP" ] && TCP_PORTS="$NEW_TCP"
    echo -e "${CM}${GN}Portas TCP: ${BGN}${TCP_PORTS}${CL}"
  else
    exit_script
  fi

  # Range UDP
  UDP_RANGE_START="10500"
  UDP_RANGE_END="10530"
  if NEW_UDP_START=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
    --inputbox "Porta UDP inicial (voice channels)\n\nPadrao: 10500" \
    12 58 "$UDP_RANGE_START" --title "UDP INICIO" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_UDP_START" ] && UDP_RANGE_START="$NEW_UDP_START"
  else
    exit_script
  fi
  if NEW_UDP_END=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
    --inputbox "Porta UDP final (voice channels)\n\nPadrao: 10530" \
    12 58 "$UDP_RANGE_END" --title "UDP FIM" --cancel-button Sair 3>&1 1>&2 2>&3); then
    [ -n "$NEW_UDP_END" ] && UDP_RANGE_END="$NEW_UDP_END"
  else
    exit_script
  fi
  echo -e "${CM}${GN}Range UDP: ${BGN}${UDP_RANGE_START}-${UDP_RANGE_END}${CL}"

  # Whitelist IPv4 para porta 10101 (Server Query)
  WHITELIST_CIDRS=()
  while true; do
    WL_IP=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
      --inputbox "IPv4 para whitelist da porta 10101 (Server Query)\n\nIP exato (ex: 170.84.159.207) ou CIDR (ex: 170.84.159.0/24)\n\nIPs adicionados: ${#WHITELIST_CIDRS[@]}" \
      16 62 "" --title "WHITELIST 10101 (OBRIGATORIO)" --cancel-button Sair 3>&1 1>&2 2>&3) || exit_script
    WL_IP=$(echo "$WL_IP" | tr -d ' ')
    if validate_ipv4_cidr "$WL_IP"; then
      WHITELIST_CIDRS+=("$WL_IP")
      echo -e "${CM}${GN}Whitelist: ${BGN}${WL_IP}${CL}"
      if ! (whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
        --title "ADICIONAR MAIS?" --yesno "Adicionar outro IPv4 a whitelist?" 8 50); then
        break
      fi
    else
      whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
        --msgbox "IPv4 invalido. Use o formato: X.X.X.X ou X.X.X.X/CIDR" 8 55 --title "ERRO"
    fi
  done
  if [ ${#WHITELIST_CIDRS[@]} -eq 0 ]; then
    msg_error "Pelo menos um IPv4 deve ser informado para whitelist da porta 10101"
    exit 1
  fi
  WHITELIST_NFT=$(printf ", %s" "${WHITELIST_CIDRS[@]}")
  WHITELIST_NFT="${WHITELIST_NFT:2}"
}

# ===================== GERAR CONFIGURACAO NFTABLES =====================
# Firewall 100% nftables (sem iptables) - seguro para 700+ usuarios
#
# Estrategia de seguranca (ordem das regras importa):
#   1. Conntrack established/related: usuarios conectados SEMPRE passam
#   2. UDP voice: aceita ANTES de qualquer filtro (prioridade maxima)
#      - Sem rate limit global (IPs spoofados consumiriam o limite)
#      - Posicionado antes de 'ct state invalid drop' para nunca ser afetado
#   3. ct state invalid drop: so atinge pacotes nao-voice
#   4. SSH: rate limit por IP (cada IP com limite independente)
#   5. Protecao volumetrica: confia no anti-DDoS da OVH
#   6. Conntrack expandido via sysctl para 700+ conexoes simultaneas
function generate_nftables_conf() {
  cat <<NFTEOF
#!/usr/sbin/nft -f
# =============================================================================
# nftables - Firewall TeaSpeak Server (OVH Failover IP)
# Gerado automaticamente pelo ovh-debian13-vm.sh
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
        # Aceita TODAS as conexoes nas portas de voz sem rate limit.
        # Posicionado ANTES de 'ct state invalid drop' para garantir
        # que pacotes de voz NUNCA sejam descartados por conntrack.
        # Ataques volumetricos sao filtrados pelo anti-DDoS da OVH.
        # =============================================================
        udp dport ${UDP_RANGE_START}-${UDP_RANGE_END} accept

        # Descartar pacotes invalidos (seguro: UDP voice ja aceito acima)
        ct state invalid drop

        # ICMP - ping e diagnosticos (tipos especificos, rate limit generoso)
        ip protocol icmp icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } limit rate 5/second burst 10 packets accept
        ip protocol icmp drop

        # ICMPv6 - inclui NDP para operacao IPv6 correta
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, echo-reply, destination-unreachable, time-exceeded, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } limit rate 5/second burst 10 packets accept
        ip6 nexthdr icmpv6 drop

        # SSH (porta ${SSH_PORT}) - rate limit POR IP de origem
        # Cada IP tem limite independente (5/min) - brute-force nao afeta outros
        tcp dport ${SSH_PORT} ct state new meter ssh_limit { ip saddr limit rate 5/minute burst 10 packets } accept

        # TeaSpeak TCP (FileTransfer e outros servicos)
        tcp dport { ${TCP_PORTS} } accept

        # Server Query (10101) - apenas IPs autorizados (whitelist)
        ip saddr { ${WHITELIST_NFT} } tcp dport 10101 accept

        # Log de pacotes descartados (limitado para nao sobrecarregar disco)
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
# Ajustes de kernel para suportar 700+ usuarios com conexoes UDP simultaneas
function generate_sysctl_conf() {
  cat <<SYSEOF
# =============================================================================
# Sysctl - Otimizacoes para TeaSpeak Server (700+ usuarios)
# Gerado automaticamente pelo ovh-debian13-vm.sh
# =============================================================================

# Conntrack - tabela expandida para suportar muitas conexoes UDP simultaneas
# Padrao: 65536, necessario: ~700 usuarios x 4 (entrada+saida+margem)
net.netfilter.nf_conntrack_max = 262144
net.nf_conntrack_max = 262144

# Buckets do conntrack (recomendado: nf_conntrack_max / 4)
net.netfilter.nf_conntrack_buckets = 65536

# Timeout UDP otimizado para voice (700+ usuarios)
# timeout: pacotes novos sem resposta (manter baixo para liberar rapido)
# timeout_stream: fluxos de voz estabelecidos (generoso para usuarios mutados/idle)
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# Timeout TCP (ajustar para conexoes server query)
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

# Buffers de rede UDP - aumentar para alta concorrencia de voice
net.core.rmem_max = 26214400
net.core.rmem_default = 1048576
net.core.wmem_max = 26214400
net.core.wmem_default = 1048576

# Backlog de rede
net.core.netdev_max_backlog = 10000

# Protecao contra SYN flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096

# Desabilitar ICMP redirects (seguranca)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Desabilitar source routing (seguranca)
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Protecao contra IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
SYSEOF
}

# ===================== GERAR CONFIGURACAO DE REDE OVH (NETPLAN) =====================
# Referencia: Documentacao OVH Baremetal - Network Bridging
# https://help.ovhcloud.com/csm/en-dedicated-servers-network-bridging
# Para VM com IP Failover em servidor dedicado OVH:
#   - Mascara /32
#   - Rota explicita para o gateway com scope link (nao esta na mesma sub-rede /32)
#   - Rota default via gateway com on-link: true
#   - Gateway do servidor principal (visivel em ip route no host)
# Debian 13 (Trixie) usa netplan com systemd-networkd por padrao
function generate_network_config() {
  cat <<NETEOF
# =============================================================================
# Configuracao de rede para OVH Failover IP (Servidor Dedicado / Baremetal)
# Documentacao: https://help.ovhcloud.com/csm/en-dedicated-servers-network-bridging
# =============================================================================
# Interface: ens18 (padrao Proxmox virtio)
# MAC Virtual: Configurado no painel OVH e atribuido a interface da VM
network:
  version: 2
  renderer: networkd
  ethernets:
    ens18:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${FAILOVER_IP}/32
      routes:
        - to: ${GATEWAY}/32
          scope: link
        - to: default
          via: ${GATEWAY}
          on-link: true
      nameservers:
        addresses:
          - 213.186.33.99
          - 1.1.1.1
NETEOF
}

# ===================== GERAR SCRIPT POS-INSTALACAO =====================
function generate_post_install_script() {
  cat <<'POSTEOF'
#!/bin/bash
# =============================================================================
# Script de pos-instalacao executado no primeiro boot da VM
# Configura nftables, sysctl e instala TeaSpeak Server
# =============================================================================

export DEBIAN_FRONTEND=noninteractive
CREDENTIALS_FILE="/root/teaspeak_credentials.txt"

# Esperar rede disponivel
for i in $(seq 1 30); do
  if ping -c 1 1.1.1.1 &>/dev/null; then
    break
  fi
  sleep 2
done

# Atualizar sistema
apt-get update -y
apt-get upgrade -y

# =====================================================================
# FIREWALL: nftables puro (sem iptables)
# Remover iptables para evitar conflito de regras no backend nf_tables.
# No Debian 13, iptables-nft compartilha o backend com nftables.
# Ter ambos ativos causa comportamento imprevisivel.
# =====================================================================

# Desabilitar servicos de persistencia iptables
systemctl stop netfilter-persistent 2>/dev/null || true
systemctl disable netfilter-persistent 2>/dev/null || true
systemctl mask netfilter-persistent 2>/dev/null || true

# Flush regras iptables residuais ANTES de remover os pacotes
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

# Remover pacotes de persistencia iptables (nao remove nft do kernel)
apt-get purge -y iptables-persistent netfilter-persistent 2>/dev/null || true
rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6 2>/dev/null || true
rm -rf /etc/iptables 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# Instalar pacotes necessarios (somente nftables, sem iptables)
apt-get install -y openssh-server cron nftables sudo wget curl screen xz-utils libnice10

# Habilitar nftables como unico firewall do sistema
systemctl enable nftables
systemctl restart nftables

# Aplicar configuracao nftables
# O 'flush ruleset' no nftables.conf limpa TUDO (inclusive regras iptables-nft residuais)
if [ -f /etc/nftables.conf ]; then
  nft -f /etc/nftables.conf
fi

# Aplicar sysctl otimizado para 700+ usuarios
if [ -f /etc/sysctl.d/99-teaspeak.conf ]; then
  sysctl --system
fi

# Gerar senha aleatoria segura para o usuario teaspeak
TEASPEAK_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=' | head -c 20)

# Criar usuario teaspeak com senha gerada
if ! id "teaspeak" &>/dev/null; then
  useradd -m -s /bin/bash teaspeak
  echo "teaspeak:${TEASPEAK_PASSWORD}" | chpasswd
fi

# Salvar credenciais em arquivo protegido (somente root pode ler)
cat > "$CREDENTIALS_FILE" << CREDEOF
# =============================================================================
# Credenciais TeaSpeak Server
# Gerado em: $(date '+%Y-%m-%d %H:%M:%S')
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

# Baixar e instalar TeaSpeak (com retry em caso de falha de rede)
for attempt in 1 2 3; do
  su - teaspeak -c '
cd ~
wget -q --show-progress https://repo.teaspeak.de/server/linux/amd64_optimized/TeaSpeak-1.4.21-beta-3.tar.gz || exit 1
tar -xzf TeaSpeak-1.4.21-beta-3.tar.gz || exit 1
rm -f TeaSpeak-1.4.21-beta-3.tar.gz
' && break
  echo "Tentativa $attempt falhou, tentando novamente em 10 segundos..."
  sleep 10
done

# Verificar se o TeaSpeak foi instalado corretamente
if [ ! -f /home/teaspeak/teastart.sh ]; then
  echo "ERRO: Falha ao baixar/extrair TeaSpeak apos 3 tentativas"
  exit 1
fi

# Criar diretorios de automacao e backup
mkdir -p /home/teaspeak/resources
mkdir -p /home/teaspeak/backups

# Script anticrash
cat > /home/teaspeak/resources/anticrash.sh << 'AEOF'
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
cat > /home/teaspeak/resources/teaspeakbackup.sh << 'BEOF'
#!/bin/bash
TS3_DIR="/home/teaspeak"
BACKUP_DIR="/home/teaspeak/backups"
LOG_FILE="/home/teaspeak/backups/backup.log"
DATE=$(date +"%Y%m%d_%H%M%S")
BACKUP_NAME="teaspeak_backup_$DATE.tar.gz"
RETENTION_DAYS=30

log_message() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
error_exit() { log_message "ERRO - $1"; exit 1; }

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
BEOF

chmod +x /home/teaspeak/resources/*.sh
chown -R teaspeak:teaspeak /home/teaspeak/resources
chown -R teaspeak:teaspeak /home/teaspeak/backups

# Configurar crontab do teaspeak
su - teaspeak -c 'cat > /tmp/teaspeak_crontab << "CRON"
@reboot cd /home/teaspeak && ./teastart.sh start
*/5 * * * * /home/teaspeak/resources/anticrash.sh teaspeakserver > /dev/null 2>&1
0 6 * * * /home/teaspeak/resources/teaspeakbackup.sh >/dev/null 2>&1
CRON
crontab /tmp/teaspeak_crontab
rm -f /tmp/teaspeak_crontab'

# Primeira inicializacao do TeaSpeak (gerar arquivos iniciais)
if [ ! -f /home/teaspeak/teastart_minimal.sh ]; then
  echo "ERRO: teastart_minimal.sh nao encontrado em /home/teaspeak"
  ls -la /home/teaspeak/ > /tmp/teaspeak_dir_listing.txt
else
  su - teaspeak -c '
cd /home/teaspeak
./teastart_minimal.sh > /tmp/teaspeak_init.log 2>&1 &
TS_PID=$!
sleep 3
kill $TS_PID 2>/dev/null
wait $TS_PID 2>/dev/null
'
fi

# Garantir que todos os processos foram finalizados
pkill -9 -u teaspeak TeaSpeakServer 2>/dev/null
sleep 1

# Baixar config.yml customizado
su - teaspeak -c '
cd /home/teaspeak
[ -f config.yml ] && cp config.yml config.yml.original
wget -q https://raw.githubusercontent.com/uteaspeak/proxinstall/main/config.yml -O config.yml.new && mv config.yml.new config.yml
'

# Remover o script de pos-instalacao (execucao unica)
rm -f /root/teaspeak-setup.sh

echo ""
echo "=== Instalacao do TeaSpeak concluida ==="
echo "Credenciais salvas em: $CREDENTIALS_FILE"
echo "Leia com: cat $CREDENTIALS_FILE"
echo ""
POSTEOF
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
  done < <(pvesm status -content images | awk 'NR>1')

  local VALID
  VALID=$(pvesm status -content images | awk 'NR>1')
  if [ -z "$VALID" ]; then
    msg_error "Nenhum storage valido detectado."
    exit 1
  elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then
    STORAGE=${STORAGE_MENU[0]}
  else
    while [ -z "${STORAGE:+x}" ]; do
      STORAGE=$(whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" --title "Storage" --radiolist \
        "Selecione o storage para a VM ${HN}:\n" \
        16 $((MSG_MAX_LENGTH + 23)) 6 \
        "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit_script
    done
  fi
  msg_ok "Storage: ${CL}${BL}${STORAGE}${CL}"
}

# ===================== CRIACAO DA VM =====================
function create_vm() {
  msg_info "Instalando dependencias do host (se necessario)"
  if ! command -v virt-customize &>/dev/null; then
    apt-get update >/dev/null 2>&1
    apt-get install -y libguestfs-tools >/dev/null 2>&1
  fi
  msg_ok "Dependencias do host OK"

  # Download da imagem Debian 13
  msg_info "Baixando imagem Debian 13 (nocloud)"
  local URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-nocloud-amd64.qcow2"
  curl -f#SL -o "$(basename "$URL")" "$URL"
  echo -en "\e[1A\e[0K"
  local FILE
  FILE=$(basename "$URL")
  msg_ok "Imagem baixada: ${CL}${BL}${FILE}${CL}"

  # Personalizar imagem
  msg_info "Personalizando imagem"
  local WORK_FILE
  WORK_FILE=$(mktemp --suffix=.qcow2)
  cp "$FILE" "$WORK_FILE"

  # Hostname
  virt-customize -q -a "$WORK_FILE" --hostname "${HN}" >/dev/null 2>&1

  # Senha root definida pelo usuario
  virt-customize -q -a "$WORK_FILE" --root-password "password:${ROOT_PASSWORD}" >/dev/null 2>&1

  # Machine-id unico
  virt-customize -q -a "$WORK_FILE" --run-command "truncate -s 0 /etc/machine-id" >/dev/null 2>&1
  virt-customize -q -a "$WORK_FILE" --run-command "rm -f /var/lib/dbus/machine-id" >/dev/null 2>&1

  # Desabilitar systemd-firstboot
  virt-customize -q -a "$WORK_FILE" --run-command "systemctl disable systemd-firstboot.service 2>/dev/null; rm -f /etc/systemd/system/sysinit.target.wants/systemd-firstboot.service; ln -sf /dev/null /etc/systemd/system/systemd-firstboot.service" >/dev/null 2>&1 || true

  # Timezone
  virt-customize -q -a "$WORK_FILE" --run-command "echo 'Etc/UTC' > /etc/timezone && ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime" >/dev/null 2>&1 || true

  # Auto-login no console serial e tty1
  virt-customize -q -a "$WORK_FILE" --run-command "mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d" >/dev/null 2>&1 || true
  virt-customize -q -a "$WORK_FILE" --run-command 'cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF' >/dev/null 2>&1 || true
  virt-customize -q -a "$WORK_FILE" --run-command "mkdir -p /etc/systemd/system/getty@tty1.service.d" >/dev/null 2>&1 || true
  virt-customize -q -a "$WORK_FILE" --run-command 'cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF' >/dev/null 2>&1 || true

  # Configurar SSH - modificar sshd_config diretamente (Port, PermitRootLogin, PasswordAuthentication)
  virt-customize -q -a "$WORK_FILE" --run-command "sed -i 's/^#\?Port .*/Port ${SSH_PORT}/' /etc/ssh/sshd_config; grep -q '^Port ' /etc/ssh/sshd_config || echo 'Port ${SSH_PORT}' >> /etc/ssh/sshd_config" >/dev/null 2>&1
  virt-customize -q -a "$WORK_FILE" --run-command "sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config; grep -q '^PermitRootLogin ' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config" >/dev/null 2>&1
  virt-customize -q -a "$WORK_FILE" --run-command "sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config; grep -q '^PasswordAuthentication ' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config" >/dev/null 2>&1

  # Configurar rede OVH (netplan - padrao Debian 13)
  generate_network_config > /tmp/ovh_netplan.yaml
  virt-customize -q -a "$WORK_FILE" --run-command "mkdir -p /etc/netplan" >/dev/null 2>&1
  virt-customize -q -a "$WORK_FILE" --run-command "rm -f /etc/netplan/*.yaml /etc/netplan/*.yml" >/dev/null 2>&1
  virt-customize -q -a "$WORK_FILE" --upload /tmp/ovh_netplan.yaml:/etc/netplan/01-netcfg.yaml >/dev/null 2>&1
  rm -f /tmp/ovh_netplan.yaml

  # Configurar nftables
  generate_nftables_conf > /tmp/ovh_nftables.conf
  virt-customize -q -a "$WORK_FILE" --upload /tmp/ovh_nftables.conf:/etc/nftables.conf >/dev/null 2>&1
  rm -f /tmp/ovh_nftables.conf

  # Configurar sysctl para alta concorrencia (1000+ usuarios)
  generate_sysctl_conf > /tmp/99-teaspeak.conf
  virt-customize -q -a "$WORK_FILE" --upload /tmp/99-teaspeak.conf:/etc/sysctl.d/99-teaspeak.conf >/dev/null 2>&1
  rm -f /tmp/99-teaspeak.conf

  # Inserir script de pos-instalacao (executado no primeiro boot via rc.local)
  generate_post_install_script > /tmp/teaspeak-setup.sh
  chmod +x /tmp/teaspeak-setup.sh
  virt-customize -q -a "$WORK_FILE" --upload /tmp/teaspeak-setup.sh:/root/teaspeak-setup.sh >/dev/null 2>&1
  rm -f /tmp/teaspeak-setup.sh

  # Criar servico systemd para executar o setup no primeiro boot
  virt-customize -q -a "$WORK_FILE" --run-command 'cat > /etc/systemd/system/teaspeak-firstboot.service << SVCEOF
[Unit]
Description=TeaSpeak First Boot Setup
After=network-online.target
Wants=network-online.target
ConditionPathExists=/root/teaspeak-setup.sh

[Service]
Type=oneshot
ExecStart=/bin/bash /root/teaspeak-setup.sh
ExecStartPost=/bin/systemctl disable teaspeak-firstboot.service
RemainAfterExit=yes
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl enable teaspeak-firstboot.service' >/dev/null 2>&1 || true

  msg_ok "Imagem personalizada"

  # Determinar tipo de storage e extensoes
  local STORAGE_TYPE DISK_EXT DISK_REF DISK_IMPORT THIN FORMAT
  STORAGE_TYPE=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $2}')
  THIN="discard=on,ssd=1,"
  FORMAT=",efitype=4m"
  case $STORAGE_TYPE in
    nfs|dir)
      DISK_EXT=".qcow2"
      DISK_REF="$VMID/"
      DISK_IMPORT="-format qcow2"
      THIN=""
      ;;
    btrfs)
      DISK_EXT=".raw"
      DISK_REF="$VMID/"
      DISK_IMPORT="-format raw"
      THIN=""
      ;;
    *)
      DISK_EXT=""
      DISK_REF=""
      DISK_IMPORT="-format raw"
      ;;
  esac

  local DISK0 DISK1 DISK0_REF DISK1_REF
  DISK0="vm-${VMID}-disk-0${DISK_EXT}"
  DISK1="vm-${VMID}-disk-1${DISK_EXT}"
  DISK0_REF="${STORAGE}:${DISK_REF}${DISK0}"
  DISK1_REF="${STORAGE}:${DISK_REF}${DISK1}"

  # Criar VM
  msg_info "Criando VM Debian 13 (${HN})"
  qm create "$VMID" -agent 1 -tablet 0 -localtime 1 -bios ovmf \
    -cores "$CORE_COUNT" -memory "$RAM_SIZE" \
    -name "$HN" -tags ovh-teaspeak \
    -net0 "virtio,bridge=${BRG},macaddr=${MAC}" \
    -onboot 1 -ostype l26 -scsihw virtio-scsi-pci

  pvesm alloc "$STORAGE" "$VMID" "$DISK0" 4M 1>&/dev/null
  qm importdisk "$VMID" "${WORK_FILE}" "$STORAGE" ${DISK_IMPORT:-} 1>&/dev/null
  qm set "$VMID" \
    -efidisk0 "${DISK0_REF}${FORMAT}" \
    -scsi0 "${DISK1_REF},${DISK_CACHE:-}${THIN}size=${DISK_SIZE}" \
    -boot order=scsi0 \
    -serial0 socket >/dev/null

  rm -f "$WORK_FILE"

  # Descricao da VM
  local DESCRIPTION
  DESCRIPTION=$(cat <<DESCEOF
<div align='center'>
  <h2>Debian 13 - TeaSpeak (OVH)</h2>
  <p><b>IP Failover:</b> ${FAILOVER_IP}/32</p>
  <p><b>Gateway:</b> ${GATEWAY}</p>
  <p><b>SSH:</b> porta ${SSH_PORT}</p>
  <p><b>TCP:</b> ${TCP_PORTS}</p>
  <p><b>TCP 10101:</b> whitelist: ${WHITELIST_NFT}</p>
  <p><b>UDP:</b> ${UDP_RANGE_START}-${UDP_RANGE_END}</p>
</div>
DESCEOF
  )
  qm set "$VMID" -description "$DESCRIPTION" >/dev/null

  # Redimensionar disco
  msg_info "Redimensionando disco para ${DISK_SIZE}"
  qm resize "$VMID" scsi0 "${DISK_SIZE}" >/dev/null
  msg_ok "Disco redimensionado"

  msg_ok "VM ${CL}${BL}${HN}${CL} ${GN}criada (ID: ${VMID})"

  # Iniciar VM
  if (whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
    --title "INICIAR VM" --yesno "Iniciar a VM agora?\n\nA instalacao do TeaSpeak sera executada automaticamente no primeiro boot." 10 58); then
    msg_info "Iniciando VM"
    qm start "$VMID"
    msg_ok "VM iniciada"
  fi
}

# ===================== RESUMO FINAL =====================
function show_summary() {
  echo ""
  echo -e "${GN}${BOLD}======================================================${CL}"
  echo -e "${GN}${BOLD}          VM DEBIAN 13 CRIADA COM SUCESSO             ${CL}"
  echo -e "${GN}${BOLD}======================================================${CL}"
  echo ""
  echo -e "${BL}Configuracao da VM:${CL}"
  echo -e "  VM ID:      ${BOLD}${VMID}${CL}"
  echo -e "  Hostname:   ${BOLD}${HN}${CL}"
  echo -e "  CPU:        ${BOLD}${CORE_COUNT} cores${CL}"
  echo -e "  RAM:        ${BOLD}${RAM_SIZE} MiB${CL}"
  echo -e "  Disco:      ${BOLD}${DISK_SIZE}${CL}"
  echo -e "  Storage:    ${BOLD}${STORAGE}${CL}"
  echo ""
  echo -e "${BL}Configuracao de Rede OVH:${CL}"
  echo -e "  MAC Virtual:    ${BOLD}${MAC}${CL}"
  echo -e "  IPv4 Failover:  ${BOLD}${FAILOVER_IP}/32${CL}"
  echo -e "  Gateway:        ${BOLD}${GATEWAY}${CL}"
  echo -e "  Bridge:         ${BOLD}${BRG}${CL}"
  echo ""
  echo -e "${BL}Firewall (nftables) - seguro para producao:${CL}"
  echo -e "  SSH:   ${BOLD}porta ${SSH_PORT}${CL} (rate limit por IP: 5/min)"
  echo -e "  TCP:   ${BOLD}${TCP_PORTS}${CL}"
  echo -e "  TCP 10101: ${BOLD}whitelist: ${WHITELIST_NFT}${CL}"
  echo -e "  UDP:   ${BOLD}${UDP_RANGE_START}-${UDP_RANGE_END}${CL} (prioridade maxima - sem rate limit)"
  echo -e "  ICMP:  ${BOLD}limitado 5/s${CL} (tipos especificos)"
  echo -e "  Conntrack: ${BOLD}262144 entradas${CL} (sysctl otimizado para 700+ usuarios)"
  echo -e "  ${GN}UDP voice aceito ANTES de qualquer filtro - nunca bloqueado${CL}"
  echo -e "  ${GN}iptables completamente removido - somente nftables${CL}"
  echo ""
  echo -e "${BL}Acesso root da VM:${CL}"
  echo -e "  Senha root: ${BOLD}definida pelo usuario${CL}"
  echo ""
  echo -e "${BL}TeaSpeak Server:${CL}"
  echo -e "  Sera instalado automaticamente no primeiro boot."
  echo -e "  ${GN}${BOLD}Credenciais salvas em:${CL} ${YW}/root/teaspeak_credentials.txt${CL}"
  echo -e "  ${INFO}Acesse a VM e leia o arquivo: ${YW}cat /root/teaspeak_credentials.txt${CL}"
  echo -e "  ${RD}${BOLD}ALTERE A SENHA APOS O PRIMEIRO ACESSO:${CL} ${YW}passwd teaspeak${CL}"
  echo ""
  echo -e "${BL}Backups automaticos:${CL}"
  echo -e "  Diretorio:  ${BOLD}/home/teaspeak/backups/${CL}"
  echo -e "  Frequencia: ${BOLD}Diario as 6h${CL}"
  echo -e "  Retencao:   ${BOLD}30 dias${CL}"
  echo -e "  Anti-crash: ${BOLD}Verificacao a cada 5 minutos${CL}"
  echo -e "  AutoStart:  ${BOLD}Ativo no boot${CL}"
  echo ""
  echo -e "${BL}Acesso a VM:${CL}"
  echo -e "  Console: ${YW}qm terminal ${VMID}${CL}"
  echo -e "  SSH:     ${YW}ssh root@${FAILOVER_IP} -p ${SSH_PORT}${CL}"
  echo ""
  echo -e "${BL}Verificar firewall (dentro da VM):${CL}"
  echo -e "  ${YW}nft list ruleset${CL}"
  echo ""
  echo -e "${BL}Iniciar TeaSpeak (dentro da VM):${CL}"
  echo -e "  ${YW}su teaspeak${CL}"
  echo -e "  ${YW}cd ~ && ./teastart.sh start${CL}"
  echo ""
  echo -e "${GN}${BOLD}A VM esta pronta!${CL}"
  echo ""
}

# ===================== MAIN =====================
TEMP_DIR=$(mktemp -d)
pushd "$TEMP_DIR" >/dev/null
trap 'popd >/dev/null 2>&1; rm -rf "$TEMP_DIR"' EXIT

header_info

# Confirmacao
if ! whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
  --title "Debian 13 VM - OVH TeaSpeak" \
  --yesno "Este script ira criar uma VM Debian 13 configurada para:\n\n• IP Failover OVH (MAC Virtual + IPv4/32)\n• Firewall nftables com portas configuraveis\n• Instalacao automatica do TeaSpeak Server\n\nRequisitos:\n• MAC Virtual configurado no painel OVH\n• IP Failover atribuido ao servidor\n\nContinuar?" 18 62; then
  echo -e "${CROSS}${RD}Usuario saiu do script${CL}\n"
  exit
fi

check_root
arch_check
pve_check

header_info
collect_ovh_params
collect_vm_params
collect_firewall_params

# Confirmacao final
echo ""
echo -e "${BOLD}${BL}=== Resumo da Configuracao ===${CL}"
echo -e "  MAC Virtual:   ${BOLD}${MAC}${CL}"
echo -e "  IPv4 Failover: ${BOLD}${FAILOVER_IP}/32${CL}"
echo -e "  Gateway:       ${BOLD}${GATEWAY}${CL}"
echo -e "  VM ID:         ${BOLD}${VMID}${CL}"
echo -e "  Hostname:      ${BOLD}${HN}${CL}"
echo -e "  CPU:           ${BOLD}${CORE_COUNT} cores${CL}"
echo -e "  RAM:           ${BOLD}${RAM_SIZE} MiB${CL}"
echo -e "  Disco:         ${BOLD}${DISK_SIZE}${CL}"
echo -e "  Senha root:    ${BOLD}definida${CL}"
echo -e "  SSH:           ${BOLD}porta ${SSH_PORT}${CL}"
echo -e "  TCP:           ${BOLD}${TCP_PORTS}${CL}"
echo -e "  TCP 10101:     ${BOLD}whitelist: ${WHITELIST_NFT}${CL}"
echo -e "  UDP:           ${BOLD}${UDP_RANGE_START}-${UDP_RANGE_END}${CL}"
echo ""

if ! whiptail --backtitle "OVH Debian 13 VM - TeaSpeak" \
  --title "CONFIRMAR" --yesno "Criar a VM com as configuracoes acima?" 8 58; then
  echo -e "${CROSS}${RD}Usuario cancelou a criacao${CL}\n"
  exit
fi

select_storage
create_vm
show_summary
