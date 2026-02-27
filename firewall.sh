#!/usr/bin/env bash

# =============================================================================
# Firewall TeaSpeak Server - nftables puro (sem iptables)
# =============================================================================
# Script standalone para configurar/reconfigurar o firewall nftables
# diretamente em um Debian 11+ com TeaSpeak Server.
#
# Uso:
#   sudo bash firewall.sh              # Modo interativo (pergunta as portas)
#   sudo bash firewall.sh --apply      # Aplica com valores atuais do /etc/nftables.conf
#   sudo bash firewall.sh --show       # Mostra regras ativas
#   sudo bash firewall.sh --status     # Status do firewall e conntrack
#
# Seguranca:
#   - 100% nftables (iptables removido automaticamente)
#   - UDP voice com prioridade maxima (antes de ct state invalid)
#   - Sem rate limit global em UDP (protege usuarios legitimos)
#   - SSH com rate limit por IP (brute-force nao afeta outros)
#   - SSH e Server Query (10101) restritos por whitelist de IPs
#   - Conntrack expandido e sysctl otimizado para 700+ usuarios
# =============================================================================

set -euo pipefail

# ===================== CORES =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
err()  { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

# ===================== VERIFICACOES =====================
[[ "$(id -u)" -ne 0 ]] && err "Execute como root: sudo bash $0"

# ===================== VALORES PADRAO =====================
SSH_PORT="22"
TCP_PORTS="30303"
UDP_RANGE_START="10500"
UDP_RANGE_END="10530"
WHITELIST_IPS=""

# ===================== FUNCOES DE VALIDACAO =====================
validate_ipv4_cidr() {
  local input="$1"
  local ip="${input%%/*}"
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi
  local IFS='.'
  read -ra octets <<< "$ip"
  for octet in "${octets[@]}"; do
    ((octet < 0 || octet > 255)) && return 1
  done
  if [[ "$input" == *"/"* ]]; then
    local cidr="${input#*/}"
    [[ "$cidr" =~ ^[0-9]{1,2}$ ]] && ((cidr >= 0 && cidr <= 32)) && return 0
    return 1
  fi
  return 0
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

# ===================== DETECTAR CONFIG ATUAL =====================
detect_current_config() {
  if [ -f /etc/nftables.conf ]; then
    # Extrair porta SSH atual
    local ssh=$(grep -oP 'tcp dport \K[0-9]+(?= ct state new meter ssh_limit)' /etc/nftables.conf 2>/dev/null || true)
    [ -n "$ssh" ] && SSH_PORT="$ssh"

    # Extrair portas TCP atuais
    local tcp=$(grep -oP 'tcp dport \{ \K[^}]+' /etc/nftables.conf 2>/dev/null | head -1 || true)
    [ -n "$tcp" ] && TCP_PORTS="$tcp"

    # Extrair range UDP atual
    local udp_start=$(grep -oP 'udp dport \K[0-9]+(?=-)' /etc/nftables.conf 2>/dev/null | head -1 || true)
    local udp_end=$(grep -oP 'udp dport [0-9]+-\K[0-9]+' /etc/nftables.conf 2>/dev/null | head -1 || true)
    [ -n "$udp_start" ] && UDP_RANGE_START="$udp_start"
    [ -n "$udp_end" ] && UDP_RANGE_END="$udp_end"

    # Extrair whitelist atual
    local wl=$(grep -oP 'ip saddr \{ \K[^}]+(?= \} tcp dport 10101)' /etc/nftables.conf 2>/dev/null || true)
    [ -n "$wl" ] && WHITELIST_IPS="$wl"

    return 0
  fi
  return 1
}

# ===================== MODO --show =====================
show_rules() {
  echo -e "\n${BOLD}${CYAN}=== Regras nftables ativas ===${NC}\n"
  if command -v nft &>/dev/null; then
    nft list ruleset 2>/dev/null || warn "Nenhuma regra carregada"
  else
    err "nftables nao esta instalado"
  fi
  exit 0
}

# ===================== MODO --status =====================
show_status() {
  echo -e "\n${BOLD}${CYAN}=== Status do Firewall ===${NC}\n"

  # Servico nftables
  if systemctl is-active --quiet nftables 2>/dev/null; then
    log "Servico nftables: ${GREEN}ativo${NC}"
  else
    warn "Servico nftables: ${RED}inativo${NC}"
  fi

  # Container LXC
  if systemd-detect-virt -c -q 2>/dev/null; then
    info "Ambiente: ${BOLD}container LXC${NC}"
    if [ -f /etc/systemd/system/nftables.service.d/override.conf ]; then
      log "Override LXC do nftables.service: ${GREEN}ativo${NC}"
    else
      warn "Override LXC do nftables.service: ${RED}ausente${NC} (execute o firewall.sh para corrigir)"
    fi
  fi

  # iptables residual
  if command -v iptables &>/dev/null; then
    local ipt_rules
    ipt_rules=$(iptables -S 2>/dev/null | grep -cv '^\-P' || true)
    if [ "$ipt_rules" -gt 0 ]; then
      warn "iptables tem ${ipt_rules} regras residuais (deveria ser 0)"
    else
      log "iptables: ${GREEN}limpo (sem regras residuais)${NC}"
    fi
  else
    log "iptables: ${GREEN}nao instalado${NC}"
  fi

  # Conntrack
  echo ""
  if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
    local ct_max ct_cur
    ct_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "?")
    ct_cur=$(conntrack -C 2>/dev/null || cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "?")
    info "Conntrack: ${BOLD}${ct_cur}${NC} / ${BOLD}${ct_max}${NC} entradas"

    local udp_timeout udp_stream
    udp_timeout=$(sysctl -n net.netfilter.nf_conntrack_udp_timeout 2>/dev/null || echo "?")
    udp_stream=$(sysctl -n net.netfilter.nf_conntrack_udp_timeout_stream 2>/dev/null || echo "?")
    info "UDP timeout: ${BOLD}${udp_timeout}s${NC}  |  UDP stream: ${BOLD}${udp_stream}s${NC}"
  fi

  # Config atual
  echo ""
  if detect_current_config; then
    info "SSH:       porta ${BOLD}${SSH_PORT}${NC} (whitelist)"
    info "TCP:       ${BOLD}${TCP_PORTS}${NC}"
    info "UDP:       ${BOLD}${UDP_RANGE_START}-${UDP_RANGE_END}${NC}"
    info "SSH/10101: whitelist ${BOLD}${WHITELIST_IPS}${NC}"
  else
    warn "Arquivo /etc/nftables.conf nao encontrado"
  fi

  echo ""
  exit 0
}

# ===================== MODO --apply =====================
apply_current() {
  if [ ! -f /etc/nftables.conf ]; then
    err "Arquivo /etc/nftables.conf nao encontrado. Use o modo interativo."
  fi
  info "Aplicando regras de /etc/nftables.conf..."
  nft -f /etc/nftables.conf
  log "Regras aplicadas com sucesso"
  nft list chain inet firewall input 2>/dev/null | head -5
  exit 0
}

# ===================== MODO --drops =====================
show_drops() {
  local LIVE=false
  local LINES=50
  [ "${2:-}" = "--live" ] && LIVE=true
  [[ "${2:-}" =~ ^[0-9]+$ ]] && LINES="$2"
  [[ "${3:-}" =~ ^[0-9]+$ ]] && LINES="$3"

  echo -e "\n${BOLD}${CYAN}=== Pacotes Bloqueados (nftables) ===${NC}\n"

  # Contadores das regras nftables (se disponiveis)
  if command -v nft &>/dev/null; then
    echo -e "${BOLD}${YELLOW}--- Contadores por regra ---${NC}"
    local has_counters=false
    while IFS= read -r line; do
      if [[ "$line" == *"counter"* ]]; then
        has_counters=true
        # Colorir a linha: destacar packets e bytes
        local colored
        colored=$(echo "$line" | sed -E \
          's/(counter packets )([0-9]+)( bytes )([0-9]+)/\1'"${BOLD}"'\2'"${NC}"'\3'"${BOLD}"'\4'"${NC}"'/g; s/^\s+/  /')
        echo -e "$colored"
      fi
    done < <(nft list chain inet firewall input 2>/dev/null)
    if ! $has_counters; then
      warn "Sem contadores nas regras. Reconfigure com: sudo bash $0"
      info "As regras atuais nao tem 'counter'. Reconfigure para habilitar."
    fi
    echo ""
  fi

  # Top IPs bloqueados (dos logs do journal)
  echo -e "${BOLD}${YELLOW}--- Top 15 IPs bloqueados ---${NC}"
  local top_ips
  top_ips=$(journalctl -k --no-pager -q 2>/dev/null | grep 'nftables-drop:' | \
    grep -oP 'SRC=\K[0-9.]+' | sort | uniq -c | sort -rn | head -15 || true)
  if [ -n "$top_ips" ]; then
    echo -e "  ${BOLD}Pacotes  IP de origem${NC}"
    echo "$top_ips" | while read -r count ip; do
      printf "  %7s  %s\n" "$count" "$ip"
    done
  else
    info "Nenhum IP bloqueado nos logs (pode ser que nao houve drops ainda)"
  fi
  echo ""

  # Top portas de destino bloqueadas
  echo -e "${BOLD}${YELLOW}--- Top 10 portas de destino bloqueadas ---${NC}"
  local top_ports
  top_ports=$(journalctl -k --no-pager -q 2>/dev/null | grep 'nftables-drop:' | \
    grep -oP 'DPT=\K[0-9]+' | sort | uniq -c | sort -rn | head -10 || true)
  if [ -n "$top_ports" ]; then
    echo -e "  ${BOLD}Pacotes  Porta${NC}"
    echo "$top_ports" | while read -r count port; do
      printf "  %7s  %s\n" "$count" "$port"
    done
  else
    info "Nenhuma porta bloqueada nos logs"
  fi
  echo ""

  # Ultimos drops
  echo -e "${BOLD}${YELLOW}--- Ultimos ${LINES} drops ---${NC}"
  local recent
  recent=$(journalctl -k --no-pager -q -n "$LINES" 2>/dev/null | grep 'nftables-drop:' || true)
  if [ -n "$recent" ]; then
    echo "$recent" | while IFS= read -r line; do
      # Extrair campos uteis
      local ts src dst dpt proto
      ts=$(echo "$line" | grep -oP '^\S+ \S+ \S+' || echo "?")
      src=$(echo "$line" | grep -oP 'SRC=\K[0-9.]+' || echo "?")
      dst=$(echo "$line" | grep -oP 'DST=\K[0-9.]+' || echo "?")
      dpt=$(echo "$line" | grep -oP 'DPT=\K[0-9]+' || echo "?")
      proto=$(echo "$line" | grep -oP 'PROTO=\K\S+' || echo "?")
      printf "  ${RED}DROP${NC} %s  %s -> %s:%s (%s)\n" "$ts" "$src" "$dst" "$dpt" "$proto"
    done
  else
    info "Nenhum drop recente nos logs"
  fi
  echo ""

  # Modo live
  if $LIVE; then
    echo -e "${BOLD}${YELLOW}--- Monitoramento em tempo real (Ctrl+C para sair) ---${NC}\n"
    journalctl -kf 2>/dev/null | grep --line-buffered 'nftables-drop:' | while IFS= read -r line; do
      local src dpt proto
      src=$(echo "$line" | grep -oP 'SRC=\K[0-9.]+' || echo "?")
      dpt=$(echo "$line" | grep -oP 'DPT=\K[0-9]+' || echo "?")
      proto=$(echo "$line" | grep -oP 'PROTO=\K\S+' || echo "?")
      echo -e "  ${RED}DROP${NC} $(date '+%H:%M:%S')  ${src} -> porta ${dpt} (${proto})"
    done
  else
    info "Use ${YELLOW}sudo bash $0 --drops --live${NC} para monitorar em tempo real"
  fi

  exit 0
}

# ===================== PROCESSAR ARGUMENTOS =====================
case "${1:-}" in
  --show)   show_rules ;;
  --status) show_status ;;
  --apply)  apply_current ;;
  --drops)  show_drops "$@" ;;
  --help|-h)
    echo "Uso: sudo bash $0 [opcao]"
    echo ""
    echo "  (sem argumento)   Modo interativo - configura portas e whitelist"
    echo "  --apply           Reaplica regras do /etc/nftables.conf atual"
    echo "  --show            Mostra regras nftables ativas"
    echo "  --status          Status do firewall, conntrack e config atual"
    echo "  --drops           Mostra pacotes bloqueados, top IPs e portas"
    echo "  --drops --live    Monitora drops em tempo real (Ctrl+C para sair)"
    echo "  --drops 100       Mostra ultimos 100 drops (padrao: 50)"
    echo "  --help            Mostra esta ajuda"
    exit 0
    ;;
  "") ;; # modo interativo
  *) err "Opcao desconhecida: $1 (use --help)" ;;
esac

# ===================== MODO INTERATIVO =====================
echo -e "\n${BOLD}${CYAN}================================================${NC}"
echo -e "${BOLD}${CYAN}   FIREWALL TEASPEAK - nftables puro${NC}"
echo -e "${BOLD}${CYAN}================================================${NC}\n"

# Detectar config atual como valores padrao
if detect_current_config; then
  info "Configuracao atual detectada em /etc/nftables.conf"
  info "Pressione Enter para manter o valor atual entre [colchetes]\n"
fi

# Porta SSH
read -rp "$(echo -e "${YELLOW}Porta SSH${NC} [${BOLD}${SSH_PORT}${NC}]: ")" input
[ -n "$input" ] && { validate_port "$input" && SSH_PORT="$input" || err "Porta invalida: $input"; }
log "SSH: porta ${SSH_PORT}"

# Portas TCP
read -rp "$(echo -e "${YELLOW}Portas TCP${NC} (virgula) [${BOLD}${TCP_PORTS}${NC}]: ")" input
[ -n "$input" ] && TCP_PORTS="$input"
log "TCP: ${TCP_PORTS}"

# Range UDP
read -rp "$(echo -e "${YELLOW}UDP inicio${NC} [${BOLD}${UDP_RANGE_START}${NC}]: ")" input
[ -n "$input" ] && { validate_port "$input" && UDP_RANGE_START="$input" || err "Porta invalida: $input"; }

read -rp "$(echo -e "${YELLOW}UDP fim${NC} [${BOLD}${UDP_RANGE_END}${NC}]: ")" input
[ -n "$input" ] && { validate_port "$input" && UDP_RANGE_END="$input" || err "Porta invalida: $input"; }
log "UDP: ${UDP_RANGE_START}-${UDP_RANGE_END}"

# Whitelist para SSH e 10101
echo ""
if [ -n "$WHITELIST_IPS" ]; then
  info "Whitelist atual: ${BOLD}${WHITELIST_IPS}${NC}"
  read -rp "$(echo -e "${YELLOW}Manter whitelist atual?${NC} [${BOLD}S${NC}/n]: ")" keep_wl
  if [[ "${keep_wl,,}" == "n" ]]; then
    WHITELIST_IPS=""
  fi
fi

if [ -z "$WHITELIST_IPS" ]; then
  echo -e "${YELLOW}IPs para whitelist do SSH e porta 10101 (Server Query):${NC}"
  echo -e "${YELLOW}Aceita IP exato ou CIDR (ex: 170.84.159.0/24). Linha vazia para finalizar.${NC}"
  WHITELIST_CIDRS=()
  while true; do
    read -rp "IPv4: " wl_ip
    [ -z "$wl_ip" ] && [ ${#WHITELIST_CIDRS[@]} -gt 0 ] && break
    if [ -z "$wl_ip" ]; then
      echo -e "  ${RED}Pelo menos um IP deve ser informado${NC}"
      continue
    fi
    if validate_ipv4_cidr "$wl_ip"; then
      WHITELIST_CIDRS+=("$wl_ip")
      echo -e "  ${GREEN}Adicionado: ${wl_ip}${NC}"
    else
      echo -e "  ${RED}IPv4 invalido: ${wl_ip}${NC}"
    fi
  done
  WHITELIST_IPS=$(printf ", %s" "${WHITELIST_CIDRS[@]}")
  WHITELIST_IPS="${WHITELIST_IPS:2}"
fi
log "Whitelist 10101: ${WHITELIST_IPS}"

# ===================== CONFIRMACAO =====================
echo -e "\n${BOLD}${CYAN}=== Resumo ===${NC}"
echo -e "  SSH:       ${BOLD}porta ${SSH_PORT}${NC} (whitelist + rate limit 5/min por IP)"
echo -e "  SSH/10101: ${BOLD}whitelist: ${WHITELIST_IPS}${NC}"
echo -e "  UDP:       ${BOLD}${UDP_RANGE_START}-${UDP_RANGE_END}${NC} (prioridade maxima, sem rate limit)"
echo -e "  ICMP:      ${BOLD}5/s tipos especificos${NC}"
echo -e "  Policy:    ${BOLD}DROP (todo o resto)${NC}"
echo ""

read -rp "$(echo -e "${YELLOW}Aplicar estas regras?${NC} [S/n]: ")" confirm
[[ "${confirm,,}" == "n" ]] && { echo -e "${RED}Cancelado.${NC}"; exit 0; }

# ===================== REMOVER IPTABLES (se presente) =====================
if dpkg -l | grep -q 'iptables-persistent\|netfilter-persistent' 2>/dev/null; then
  warn "Removendo iptables-persistent para evitar conflito..."

  systemctl stop netfilter-persistent 2>/dev/null || true
  systemctl disable netfilter-persistent 2>/dev/null || true
  systemctl mask netfilter-persistent 2>/dev/null || true

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

  DEBIAN_FRONTEND=noninteractive apt-get purge -y iptables-persistent netfilter-persistent 2>/dev/null || true
  rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6 2>/dev/null || true
  rm -rf /etc/iptables 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true

  log "iptables removido"
fi

# ===================== INSTALAR NFTABLES =====================
if ! command -v nft &>/dev/null; then
  info "Instalando nftables..."
  apt-get update -y >/dev/null 2>&1
  apt-get install -y nftables >/dev/null 2>&1
fi

# Detectar container LXC e aplicar override do systemd
# ProtectSystem/ProtectHome sao incompativeis com namespaces LXC
# e sysinit.target pode nao funcionar em containers
IS_LXC=false
if systemd-detect-virt -c -q 2>/dev/null || grep -qsw 'lxc\|container' /proc/1/environ 2>/dev/null; then
  IS_LXC=true
  info "Container LXC detectado - aplicando override do nftables.service"
  mkdir -p /etc/systemd/system/nftables.service.d
  cat > /etc/systemd/system/nftables.service.d/override.conf << 'NFTOVER'
[Service]
ProtectSystem=
ProtectHome=

[Install]
WantedBy=multi-user.target
NFTOVER
  systemctl daemon-reload
fi

systemctl enable nftables 2>/dev/null || true

# ===================== GERAR /etc/nftables.conf =====================
info "Gerando /etc/nftables.conf..."

# Backup da config anterior
if [ -f /etc/nftables.conf ]; then
  cp /etc/nftables.conf "/etc/nftables.conf.bak.$(date +%Y%m%d_%H%M%S)"
  log "Backup: /etc/nftables.conf.bak.$(date +%Y%m%d_%H%M%S)"
fi

cat > /etc/nftables.conf << NFTEOF
#!/usr/sbin/nft -f
# =============================================================================
# nftables - Firewall TeaSpeak Server
# Gerado por firewall.sh em $(date '+%Y-%m-%d %H:%M:%S')
# 100% nftables (sem iptables) - otimizado para 700+ usuarios simultaneos
# =============================================================================
# UDP voice tem PRIORIDADE MAXIMA na chain input.
# Aceito ANTES de 'ct state invalid drop' para que conntrack nunca
# interfira com trafego de voz. Sem rate limit global nas portas UDP.
# =============================================================================

flush ruleset

table inet firewall {

    chain input {
        type filter hook input priority 0; policy drop;

        # Loopback - trafego interno do sistema
        iif "lo" accept

        # Conexoes estabelecidas/relacionadas - usuarios conectados SEMPRE passam
        ct state established,related counter accept

        # =============================================================
        # UDP VOICE - PRIORIDADE MAXIMA (antes de qualquer filtro)
        # Posicionado ANTES de 'ct state invalid drop' para garantir
        # que pacotes de voz NUNCA sejam descartados por conntrack.
        # =============================================================
        udp dport ${UDP_RANGE_START}-${UDP_RANGE_END} counter accept

        # Descartar pacotes invalidos (seguro: UDP voice ja aceito acima)
        ct state invalid counter drop

        # ICMP - ping e diagnosticos (tipos especificos)
        ip protocol icmp icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } limit rate 5/second burst 10 packets counter accept
        ip protocol icmp counter drop

        # ICMPv6 - inclui NDP para operacao IPv6 correta
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, echo-reply, destination-unreachable, time-exceeded, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } limit rate 5/second burst 10 packets counter accept
        ip6 nexthdr icmpv6 counter drop

        # SSH (porta ${SSH_PORT}) - whitelist + rate limit POR IP de origem
        ip saddr { ${WHITELIST_IPS} } tcp dport ${SSH_PORT} ct state new meter ssh_limit { ip saddr limit rate 5/minute burst 10 packets } counter accept

        # TeaSpeak TCP (FileTransfer e outros servicos)
        tcp dport { ${TCP_PORTS} } counter accept

        # Server Query (10101) - apenas IPs autorizados (whitelist)
        ip saddr { ${WHITELIST_IPS} } tcp dport 10101 counter accept

        # Log e contagem de pacotes descartados
        counter comment "policy-drop-count"
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

chmod 755 /etc/nftables.conf
log "Arquivo /etc/nftables.conf gerado"

# ===================== GERAR SYSCTL =====================
info "Gerando /etc/sysctl.d/99-teaspeak.conf..."

cat > /etc/sysctl.d/99-teaspeak.conf << 'SYSEOF'
# =============================================================================
# Sysctl - Otimizacoes para TeaSpeak Server (700+ usuarios)
# Gerado por firewall.sh
# =============================================================================

# Conntrack expandido
net.netfilter.nf_conntrack_max = 262144
net.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_buckets = 65536

# Timeout UDP otimizado para voice
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# Timeout TCP
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

log "Arquivo /etc/sysctl.d/99-teaspeak.conf gerado"

# ===================== APLICAR =====================
info "Aplicando regras nftables..."
nft -f /etc/nftables.conf
log "Regras nftables aplicadas"

info "Aplicando sysctl..."
sysctl --system >/dev/null 2>&1
log "Sysctl aplicado"

systemctl restart nftables
log "Servico nftables reiniciado"

# ===================== RESUMO =====================
echo -e "\n${GREEN}${BOLD}================================================${NC}"
echo -e "${GREEN}${BOLD}       FIREWALL CONFIGURADO COM SUCESSO${NC}"
echo -e "${GREEN}${BOLD}================================================${NC}\n"

echo -e "${CYAN}Regras ativas:${NC}"
echo -e "  SSH:       ${BOLD}porta ${SSH_PORT}${NC} (whitelist + rate limit 5/min por IP)"
echo -e "  SSH/10101: ${BOLD}whitelist: ${WHITELIST_IPS}${NC}"
echo -e "  UDP:       ${BOLD}${UDP_RANGE_START}-${UDP_RANGE_END}${NC} (prioridade maxima)"
echo -e "  ICMP:      ${BOLD}5/s tipos especificos${NC}"
echo -e "  Conntrack: ${BOLD}$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 262144)${NC} entradas"
echo ""
echo -e "${CYAN}Comandos uteis:${NC}"
echo -e "  ${YELLOW}sudo bash $0 --show${NC}       Ver regras ativas"
echo -e "  ${YELLOW}sudo bash $0 --status${NC}     Status completo"
echo -e "  ${YELLOW}sudo bash $0 --drops${NC}      Ver pacotes bloqueados (top IPs, portas)"
echo -e "  ${YELLOW}sudo bash $0 --drops --live${NC}  Monitorar drops em tempo real"
echo -e "  ${YELLOW}sudo bash $0 --apply${NC}      Reaplicar /etc/nftables.conf"
echo -e "  ${YELLOW}sudo bash $0${NC}              Reconfigurar interativamente"
echo ""
