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
#   sudo bash firewall.sh --drops      # Mostra pacotes bloqueados
#
# Seguranca (3 camadas anti-DDoS):
#   - 100% nftables (iptables removido automaticamente)
#   - PREROUTING RAW: drop fragmentos IP + notrack para UDP voice
#   - CAMADA 1: Drop pacotes UDP > 750 bytes (voice legit max ~500 bytes)
#   - CAMADA 2: Rate limit por IP (150 pps/IP, burst 300, timeout 120s)
#   - CAMADA 3: Accept trafego legitimo restante
#   - SSH e Server Query (10101) restritos por whitelist de IPs
#   - Conntrack zero para UDP voice (notrack no prerouting)
#   - Sysctl otimizado para absorver spikes de trafego
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
SSH_PORT="2424"
TCP_PORTS="30303"
UDP_PORTS=""
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

# Formata portas UDP para sintaxe nftables:
#   1 porta:  "10601"           → "10601"
#   N portas: "10601,10602,..." → "{ 10601, 10602, ... }"
format_nft_ports() {
  local ports="$1"
  local count
  count=$(echo "$ports" | tr ',' '\n' | wc -l)
  if [ "$count" -le 1 ]; then
    echo "$ports"
  else
    echo "{ $(echo "$ports" | sed 's/,/, /g') }"
  fi
}

# Formata portas UDP para display humano:
#   1 porta:  "10601"           → "10601"
#   N portas: "10601,10602,..." → "10601, 10602, ..."
format_display_ports() {
  echo "$1" | sed 's/,/, /g'
}

# ===================== DETECTAR CONFIG ATUAL =====================
detect_current_config() {
  if [ -f /etc/nftables.conf ]; then
    # Extrair porta SSH (primeira regra tcp dport com saddr whitelist)
    local ssh
    ssh=$(grep -P 'saddr.*tcp dport \d+.*accept' /etc/nftables.conf 2>/dev/null | grep -oP 'tcp dport \K[0-9]+' | head -1 || true)
    [ -n "$ssh" ] && SSH_PORT="$ssh"

    # Extrair porta TCP FileTransfer (tcp dport sem saddr, sem 10101)
    local tcp
    tcp=$(grep -P '^\s+tcp dport \d+ counter accept' /etc/nftables.conf 2>/dev/null | grep -v '10101' | grep -oP 'tcp dport \K[0-9]+' | head -1 || true)
    [ -n "$tcp" ] && TCP_PORTS="$tcp"

    # Extrair portas UDP (porta unica, set {p1, p2}, ou range)
    local udp_list
    # Primeiro tenta extrair set { port1, port2, ... }
    udp_list=$(grep -oP 'udp dport \{ \K[0-9, ]+' /etc/nftables.conf 2>/dev/null | head -1 | sed 's/ //g; s/,$//' || true)
    if [ -z "$udp_list" ]; then
      # Fallback: porta unica ou range
      udp_list=$(grep -oP 'udp dport \K[0-9]+(-[0-9]+)?' /etc/nftables.conf 2>/dev/null | head -1 || true)
    fi
    [ -n "$udp_list" ] && UDP_PORTS="$udp_list"

    # Extrair IPs de whitelist (um por linha)
    local wl_ips=()
    while IFS= read -r line; do
      local ip
      ip=$(echo "$line" | grep -oP 'ip saddr \K[0-9./]+' || true)
      [ -n "$ip" ] && wl_ips+=("$ip")
    done < <(grep "tcp dport ${SSH_PORT}" /etc/nftables.conf 2>/dev/null | grep 'saddr' | sort -u)
    if [ ${#wl_ips[@]} -gt 0 ]; then
      WHITELIST_IPS=$(printf '%s\n' "${wl_ips[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
    fi

    return 0
  fi

  # Fallback: detectar do TeaSpeak diretamente via ss
  if command -v ss &>/dev/null; then
    local voice_ports
    voice_ports=$(ss -ulnp 2>/dev/null | grep -i teaspeak | awk '{print $5}' | grep -oP ':\K[0-9]+' | sort -un | tr '\n' ',' | sed 's/,$//' || true)
    [ -n "$voice_ports" ] && UDP_PORTS="$voice_ports"

    local ft_port
    ft_port=$(ss -tlnp 2>/dev/null | grep -i teaspeak | awk '{print $4}' | grep -oP ':\K[0-9]+' | grep -v '10101' | head -1 || true)
    [ -n "$ft_port" ] && TCP_PORTS="$ft_port"
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
    info "UDP:       ${BOLD}$(format_display_ports "${UDP_PORTS}")${NC}"
    info "Whitelist: ${BOLD}${WHITELIST_IPS}${NC}"
  else
    warn "Arquivo /etc/nftables.conf nao encontrado"
  fi

  # Counters anti-DDoS
  echo ""
  info "${BOLD}Anti-DDoS counters:${NC}"
  nft list chain ip raw prerouting 2>/dev/null | grep counter | sed 's/^/  /' || true
  nft list chain inet firewall input 2>/dev/null | grep -E 'drop|accept' | grep -E 'udp|meta' | sed 's/^/  /' || true

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

  # Contadores das regras nftables
  if command -v nft &>/dev/null; then
    echo -e "${BOLD}${YELLOW}--- Contadores anti-DDoS ---${NC}"

    echo -e "\n  ${BOLD}Prerouting (raw):${NC}"
    nft list chain ip raw prerouting 2>/dev/null | grep counter | sed 's/^/    /' || true

    echo -e "\n  ${BOLD}Input (firewall):${NC}"
    local has_counters=false
    while IFS= read -r line; do
      if [[ "$line" == *"counter"* ]]; then
        has_counters=true
        local colored
        colored=$(echo "$line" | sed -E \
          "s/(counter packets )([0-9]+)( bytes )([0-9]+)/\1${BOLD}\2${NC}\3${BOLD}\4${NC}/g; s/^\s+/    /")
        echo -e "$colored"
      fi
    done < <(nft list chain inet firewall input 2>/dev/null)
    if ! $has_counters; then
      warn "Sem contadores nas regras. Reconfigure com: sudo bash $0"
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
echo -e "${BOLD}${CYAN}   FIREWALL TEASPEAK - nftables anti-DDoS${NC}"
echo -e "${BOLD}${CYAN}================================================${NC}\n"

# Detectar config atual como valores padrao
if detect_current_config; then
  info "Configuracao atual detectada em /etc/nftables.conf"
  info "Pressione Enter para manter o valor atual entre [colchetes]\n"
else
  info "Nenhuma config anterior encontrada. Detectando do TeaSpeak...\n"
  detect_current_config 2>/dev/null || true
fi

# Porta SSH
read -rp "$(echo -e "${YELLOW}Porta SSH${NC} [${BOLD}${SSH_PORT}${NC}]: ")" input
[ -n "$input" ] && { validate_port "$input" && SSH_PORT="$input" || err "Porta invalida: $input"; }
log "SSH: porta ${SSH_PORT}"

# Portas TCP (FileTransfer)
read -rp "$(echo -e "${YELLOW}Porta TCP FileTransfer${NC} [${BOLD}${TCP_PORTS}${NC}]: ")" input
[ -n "$input" ] && TCP_PORTS="$input"
log "TCP FileTransfer: ${TCP_PORTS}"

# Portas UDP voice (multiplas portas para servidores virtuais)
if [ -z "$UDP_PORTS" ]; then
  # Auto-detectar TODAS as portas do TeaSpeak
  local_udp=$(ss -ulnp 2>/dev/null | grep -i teaspeak | awk '{print $5}' | grep -oP ':\K[0-9]+' | sort -un | tr '\n' ',' | sed 's/,$//' || true)
  [ -n "$local_udp" ] && UDP_PORTS="$local_udp"
fi
[ -z "$UDP_PORTS" ] && UDP_PORTS="10602"

echo -e "${YELLOW}Portas UDP voice (servidores virtuais TeaSpeak):${NC}"
echo -e "${YELLOW}Portas atuais: ${BOLD}$(format_display_ports "$UDP_PORTS")${NC}"
read -rp "$(echo -e "${YELLOW}Manter portas atuais?${NC} [${BOLD}S${NC}/n]: ")" keep_udp
if [[ "${keep_udp,,}" == "n" ]]; then
  echo -e "${YELLOW}Digite as portas UDP (uma por linha). Linha vazia para finalizar:${NC}"
  UDP_LIST=()
  while true; do
    read -rp "Porta UDP: " udp_input
    [ -z "$udp_input" ] && [ ${#UDP_LIST[@]} -gt 0 ] && break
    if [ -z "$udp_input" ]; then
      echo -e "  ${RED}Pelo menos uma porta deve ser informada${NC}"
      continue
    fi
    if validate_port "$udp_input"; then
      UDP_LIST+=("$udp_input")
      echo -e "  ${GREEN}Adicionada: ${udp_input}${NC}"
    else
      echo -e "  ${RED}Porta invalida: ${udp_input}${NC}"
    fi
  done
  UDP_PORTS=$(printf ",%s" "${UDP_LIST[@]}")
  UDP_PORTS="${UDP_PORTS:1}"
fi
log "UDP Voice: $(format_display_ports "$UDP_PORTS")"

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
  WHITELIST_IPS=$(printf ",%s" "${WHITELIST_CIDRS[@]}")
  WHITELIST_IPS="${WHITELIST_IPS:1}"
fi
log "Whitelist: ${WHITELIST_IPS}"

# ===================== CONFIRMACAO =====================
echo -e "\n${BOLD}${CYAN}=== Resumo ===${NC}"
echo -e "  SSH:       ${BOLD}porta ${SSH_PORT}${NC} (whitelist)"
echo -e "  Whitelist: ${BOLD}${WHITELIST_IPS}${NC}"
echo -e "  TCP:       ${BOLD}${TCP_PORTS}${NC} (FileTransfer)"
echo -e "  UDP:       ${BOLD}$(format_display_ports "$UDP_PORTS")${NC} (voice, notrack)"
echo -e "  Anti-DDoS: ${BOLD}fragment drop + max 750 bytes + 150 pps/IP (burst 300)${NC}"
echo -e "  ICMP:      ${BOLD}5/s rate limited${NC}"
echo -e "  Policy:    ${BOLD}DROP (todo o resto)${NC}"
echo ""

read -rp "$(echo -e "${YELLOW}Aplicar estas regras?${NC} [S/n]: ")" confirm
[[ "${confirm,,}" == "n" ]] && { echo -e "${RED}Cancelado.${NC}"; exit 0; }

# ===================== REMOVER IPTABLES (se presente) =====================
if dpkg -l 2>/dev/null | grep -qE 'iptables-persistent|netfilter-persistent'; then
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

  # Limpar tabela iptables-nft do nftables
  nft delete table ip filter 2>/dev/null || true

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
IS_LXC=false
if systemd-detect-virt -c -q 2>/dev/null || grep -qsw 'lxc\|container' /proc/1/environ 2>/dev/null; then
  IS_LXC=true
  info "Container LXC detectado - aplicando override do nftables.service"
  mkdir -p /etc/systemd/system/nftables.service.d
  cat > /etc/systemd/system/nftables.service.d/override.conf << 'NFTOVER'
[Service]
ProtectSystem=false
ProtectHome=false

[Install]
WantedBy=multi-user.target
NFTOVER
  systemctl daemon-reload
fi

# Desabilitar ssh.socket (Debian 12+ usa socket activation que ignora sshd_config Port)
if systemctl is-enabled ssh.socket 2>/dev/null | grep -q enabled; then
  warn "Desabilitando ssh.socket (conflita com porta SSH customizada)..."
  systemctl stop ssh.socket 2>/dev/null || true
  systemctl disable ssh.socket 2>/dev/null || true
  systemctl restart ssh.service 2>/dev/null || true
  log "ssh.socket desabilitado, ssh.service ativo"
fi

systemctl enable nftables 2>/dev/null || true

# ===================== GERAR WHITELIST RULES =====================
generate_whitelist_rules() {
  local port="$1"
  local action="$2"
  local IFS=','
  for ip in $WHITELIST_IPS; do
    ip=$(echo "$ip" | xargs) # trim whitespace
    printf '        ip saddr %s tcp dport %s counter %s\n' "$ip" "$port" "$action"
  done
}

# ===================== GERAR /etc/nftables.conf =====================
info "Gerando /etc/nftables.conf..."

# Backup da config anterior
if [ -f /etc/nftables.conf ]; then
  cp /etc/nftables.conf "/etc/nftables.conf.bak.$(date +%Y%m%d_%H%M%S)"
  log "Backup salvo"
fi

# Gerar regras de whitelist
SSH_WHITELIST=$(generate_whitelist_rules "$SSH_PORT" "accept")
SQ_WHITELIST=$(generate_whitelist_rules "10101" "accept")

# Formatar portas UDP para nftables
NFT_UDP=$(format_nft_ports "$UDP_PORTS")
DISPLAY_UDP=$(format_display_ports "$UDP_PORTS")

cat > /etc/nftables.conf << NFTEOF
#!/usr/sbin/nft -f
# =============================================================================
# nftables - Firewall TeaSpeak Anti-DDoS
# Gerado por firewall.sh em $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================
# Voice: UDP ${DISPLAY_UDP} | FileTransfer: TCP ${TCP_PORTS} | SSH: TCP ${SSH_PORT}
#
# Anti-DDoS (3 camadas):
#   Prerouting: fragment drop (todo IP) + notrack UDP voice
#   Layer 1: Drop UDP > 750 bytes (voice legit max ~500B payload)
#   Layer 2: Rate limit 150 pps/IP, burst 300, timeout 120s
#   Layer 3: Accept trafego legitimo
# =============================================================================

flush ruleset

# ---------- PREROUTING RAW: bypass conntrack para voice ----------
# Tabela separada (ip raw) para processar ANTES de qualquer conntrack.
# - Fragmentos IP: SEMPRE dropados (voice legitimo nunca fragmenta,
#   max payload ~500B, bem abaixo do MTU 1500). Fragmentos sao vetor
#   de amplificacao e evasao de firewall.
# - notrack: elimina 100% do overhead do conntrack para UDP voice.
#   Sem notrack, cada pacote voice cria entrada na conntrack table,
#   e atacante com IPs spoofados esgota a tabela inteira.
table ip raw {
    chain prerouting {
        type filter hook prerouting priority raw; policy accept;

        # Drop ALL IP fragments (amplification/evasion attack vector)
        ip frag-off & 0x1fff != 0 counter drop

        # Notrack voice UDP - zero conntrack overhead
        udp dport ${NFT_UDP} counter notrack
    }
}

# ---------- MAIN FILTER ----------
table inet firewall {
    chain input {
        type filter hook input priority filter; policy drop;

        # --- Loopback ---
        iifname "lo" accept

        # --- Conntrack (TCP only, UDP voice e notracked) ---
        ct state established,related counter accept
        ct state invalid counter drop comment "drop-invalid"

        # --- SSH whitelist ---
${SSH_WHITELIST}

        # --- ServerQuery whitelist (10101) ---
${SQ_WHITELIST}
        tcp dport 10101 counter drop

        # --- FileTransfer ---
        tcp dport ${TCP_PORTS} counter accept

        # --- ICMP rate-limited ---
        ip protocol icmp limit rate 5/second burst 10 packets counter accept
        ip6 nexthdr icmpv6 limit rate 5/second burst 10 packets counter accept
        ip protocol icmp counter drop
        ip6 nexthdr icmpv6 counter drop

        # ====== UDP VOICE - 3-layer anti-DDoS ======

        # LAYER 1: Drop oversized packets
        # Dados estatisticos (60s, 128K+ pkts, 150 users, Opus level 6):
        #   Max payload observado: 500 bytes (meta length ~528)
        #   Threshold: 750 bytes (50% margem sobre max observado)
        #   Bloqueia: DNS amplification (3000+), memcached (50K+), NTP (468+)
        udp dport ${NFT_UDP} meta length > 750 counter drop

        # LAYER 2: Per-IP rate limit
        # Dados: user legit envia ~14 pps (max observado com 150 users).
        # 150 pps/IP com burst 300 da margem 10x sobre o normal.
        # timeout 120s: limpa IPs desconectados automaticamente.
        # Atacantes com IP unico flood >10000 pps e sao cortados.
        udp dport ${NFT_UDP} meter ts3_flood { ip saddr timeout 120s limit rate over 150/second burst 300 packets } counter drop

        # LAYER 3: Accept remaining legitimate voice traffic
        udp dport ${NFT_UDP} counter accept

        # --- Policy drop logging ---
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
log "Arquivo /etc/nftables.conf gerado"

# ===================== GERAR SYSCTL =====================
info "Gerando /etc/sysctl.d/99-teaspeak.conf..."

cat > /etc/sysctl.d/99-teaspeak.conf << 'SYSEOF'
# =============================================================================
# Sysctl - Tuning de rede para TeaSpeak Server Anti-DDoS
# Gerado por firewall.sh
# =============================================================================

# Receive buffer
net.core.rmem_max = 16777216
net.core.rmem_default = 1048576

# Send buffer
net.core.wmem_max = 16777216
net.core.wmem_default = 1048576

# UDP buffers - absorver spikes antes do kernel dropar
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536
net.ipv4.udp_mem = 65536 131072 262144

# Backlog de rede - fila de pacotes antes do processamento
# Default kernel (1000) e muito baixo para absorver bursts
net.core.netdev_max_backlog = 30000

# Budget - quantos pacotes o kernel processa por ciclo NAPI
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# Fila de conexoes TCP pendentes
net.core.somaxconn = 4096

# Conntrack otimizado (so TCP, voice e notracked)
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60

# Protecao contra SYN flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096

# Reverse path filter (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Desabilitar ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Desabilitar source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Ignorar broadcasts ICMP (smurf attack prevention)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignorar respostas ICMP bogus
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Timestamps TCP
net.ipv4.tcp_timestamps = 1
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
echo -e "  SSH:       ${BOLD}porta ${SSH_PORT}${NC} (whitelist)"
echo -e "  Whitelist: ${BOLD}${WHITELIST_IPS}${NC}"
echo -e "  TCP:       ${BOLD}${TCP_PORTS}${NC} (FileTransfer)"
echo -e "  UDP:       ${BOLD}$(format_display_ports "$UDP_PORTS")${NC} (voice, notrack, anti-DDoS)"
echo -e "  Anti-DDoS: ${BOLD}fragment drop + max 750 bytes + 150 pps/IP burst 300${NC}"
echo -e "  ICMP:      ${BOLD}5/s rate limited${NC}"
echo ""
echo -e "${CYAN}Verificacao rapida:${NC}"

# Mostrar counters iniciais
echo -e "  ${BOLD}Prerouting:${NC}"
nft list chain ip raw prerouting 2>/dev/null | grep counter | sed 's/^/    /'
echo -e "  ${BOLD}Anti-DDoS:${NC}"
nft list chain inet firewall input 2>/dev/null | grep -E 'udp.*drop|meta.*drop|udp.*accept' | sed 's/^/    /'

echo ""
echo -e "${CYAN}Comandos uteis:${NC}"
echo -e "  ${YELLOW}sudo bash $0 --show${NC}       Ver regras ativas"
echo -e "  ${YELLOW}sudo bash $0 --status${NC}     Status completo + counters"
echo -e "  ${YELLOW}sudo bash $0 --drops${NC}      Ver pacotes bloqueados"
echo -e "  ${YELLOW}sudo bash $0 --drops --live${NC}  Monitorar drops tempo real"
echo -e "  ${YELLOW}sudo bash $0 --apply${NC}      Reaplicar /etc/nftables.conf"
echo -e "  ${YELLOW}sudo bash $0${NC}              Reconfigurar interativamente"
echo ""
