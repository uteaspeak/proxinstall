#!/usr/bin/env bash

# =============================================================================
# Adicionar IPv4 Failover a VM Debian (OVH)
# =============================================================================
# Script para adicionar IPs Failover adicionais a uma VM que ja possui
# um IP Failover configurado via netplan.
#
# Uso:
#   sudo bash addip.sh                  # Modo interativo
#   sudo bash addip.sh --list           # Listar IPs configurados
#   sudo bash addip.sh --remove         # Remover um IP
#
# Pre-requisitos:
#   - MAC Virtual configurado no painel OVH para o novo IP
#   - IP Failover atribuido ao servidor no painel OVH
#   - VM ja configurada com netplan (ovh-debian13-vm.sh)
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

NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
[ ! -f "$NETPLAN_FILE" ] && err "Arquivo $NETPLAN_FILE nao encontrado. Este script requer uma VM configurada pelo ovh-debian13-vm.sh"

# Verificar se netplan esta disponivel
command -v netplan &>/dev/null || err "netplan nao encontrado. Este script requer Debian 13+ com netplan."

# ===================== FUNCOES =====================
validate_ipv4() {
  local ip="$1"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
      ((octet < 0 || octet > 255)) && return 1
    done
    return 0
  fi
  return 1
}

get_current_ips() {
  # Extrair IPs /32 do bloco addresses, ignorando linhas de rotas (que contem "to:")
  grep '/32' "$NETPLAN_FILE" 2>/dev/null | grep -v 'to:' | grep -oP '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32' || true
}

get_gateway() {
  grep -A1 'via:' "$NETPLAN_FILE" 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

# ===================== MODO --list =====================
list_ips() {
  echo -e "\n${BOLD}${CYAN}=== IPs Failover configurados ===${NC}\n"

  local ips gateway
  ips=$(get_current_ips)
  gateway=$(get_gateway)

  if [ -z "$ips" ]; then
    warn "Nenhum IP encontrado em $NETPLAN_FILE"
  else
    local count=0
    while IFS= read -r ip; do
      count=$((count + 1))
      local ip_clean="${ip%/32}"
      # Verificar se esta ativo na interface
      if ip addr show 2>/dev/null | grep -q "$ip_clean"; then
        echo -e "  ${GREEN}●${NC} ${BOLD}${ip}${NC}  (ativo na interface)"
      else
        echo -e "  ${RED}●${NC} ${BOLD}${ip}${NC}  (configurado, nao ativo - execute: netplan apply)"
      fi
    done <<< "$ips"
    echo ""
    info "Total: ${BOLD}${count}${NC} IP(s) configurado(s)"
    info "Gateway: ${BOLD}${gateway}${NC}"
  fi

  # Mostrar IPs ativos na interface que nao estao no netplan
  echo ""
  local interface_ips
  interface_ips=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[0-9.]+' || true)
  while IFS= read -r iip; do
    if [ -n "$iip" ] && ! echo "$ips" | grep -q "$iip"; then
      warn "IP ${BOLD}${iip}${NC} ativo na interface mas NAO esta no netplan"
    fi
  done <<< "$interface_ips"

  echo ""
  exit 0
}

# ===================== MODO --remove =====================
remove_ip() {
  echo -e "\n${BOLD}${CYAN}=== Remover IP Failover ===${NC}\n"

  local ips
  ips=$(get_current_ips)
  local count
  count=$(echo "$ips" | grep -c '/' 2>/dev/null || echo 0)

  if [ "$count" -le 1 ]; then
    err "Existe apenas 1 IP configurado. Nao e possivel remover o ultimo IP (voce perderia acesso)."
  fi

  echo -e "${YELLOW}IPs configurados:${NC}"
  local i=0
  local ip_array=()
  while IFS= read -r ip; do
    i=$((i + 1))
    ip_array+=("$ip")
    echo -e "  ${BOLD}${i})${NC} ${ip}"
  done <<< "$ips"

  echo ""
  read -rp "$(echo -e "${YELLOW}Numero do IP para remover (0 para cancelar):${NC} ")" choice

  [[ "$choice" == "0" || -z "$choice" ]] && { echo -e "${RED}Cancelado.${NC}"; exit 0; }

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$i" ]; then
    err "Opcao invalida."
  fi

  local ip_to_remove="${ip_array[$((choice - 1))]}"
  local ip_clean="${ip_to_remove%/32}"

  echo ""
  warn "Vai remover: ${BOLD}${ip_to_remove}${NC}"
  read -rp "$(echo -e "${RED}Tem certeza? Isso pode desconectar servicos nesse IP [s/N]:${NC} ")" confirm
  [[ "${confirm,,}" != "s" ]] && { echo -e "${RED}Cancelado.${NC}"; exit 0; }

  # Backup
  cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
  log "Backup: ${NETPLAN_FILE}.bak.$(date +%Y%m%d_%H%M%S)"

  # Remover a linha do IP
  sed -i "/- ${ip_clean}\/32/d" "$NETPLAN_FILE"
  log "IP ${ip_to_remove} removido do netplan"

  # Aplicar
  info "Aplicando netplan..."
  netplan apply 2>&1
  log "Netplan aplicado"

  # Remover da interface imediatamente
  local iface
  iface=$(ip -4 addr show 2>/dev/null | grep "$ip_clean" | awk '{print $NF}' || true)
  if [ -n "$iface" ]; then
    ip addr del "${ip_to_remove}" dev "$iface" 2>/dev/null || true
    log "IP removido da interface ${iface}"
  fi

  echo -e "\n${GREEN}${BOLD}IP ${ip_to_remove} removido com sucesso.${NC}\n"
  info "Lembre-se de remover o MAC Virtual no painel OVH se nao for mais usar este IP."
  echo ""
  exit 0
}

# ===================== PROCESSAR ARGUMENTOS =====================
case "${1:-}" in
  --list)   list_ips ;;
  --remove) remove_ip ;;
  --help|-h)
    echo "Uso: sudo bash $0 [opcao]"
    echo ""
    echo "  (sem argumento)   Adicionar um novo IP Failover"
    echo "  --list            Listar IPs configurados e status"
    echo "  --remove          Remover um IP Failover"
    echo "  --help            Mostra esta ajuda"
    exit 0
    ;;
  "") ;; # modo interativo (adicionar)
  *) err "Opcao desconhecida: $1 (use --help)" ;;
esac

# ===================== MODO INTERATIVO (ADICIONAR) =====================
echo -e "\n${BOLD}${CYAN}================================================${NC}"
echo -e "${BOLD}${CYAN}   ADICIONAR IP FAILOVER (OVH)${NC}"
echo -e "${BOLD}${CYAN}================================================${NC}\n"

# Mostrar IPs atuais
local_ips=$(get_current_ips)
gateway=$(get_gateway)

if [ -n "$local_ips" ]; then
  info "IPs atuais:"
  while IFS= read -r ip; do
    echo -e "    ${GREEN}●${NC} ${ip}"
  done <<< "$local_ips"
  info "Gateway: ${BOLD}${gateway}${NC}"
  echo ""
fi

# Perguntar novo IP
echo -e "${YELLOW}IMPORTANTE: Antes de continuar, certifique-se de que:${NC}"
echo -e "  1. O IP Failover esta atribuido ao servidor no painel OVH"
echo -e "  2. O MAC Virtual foi configurado no painel OVH para este IP"
echo -e "  3. O MAC Virtual aponta para esta VM\n"

while true; do
  read -rp "$(echo -e "${YELLOW}Novo IPv4 Failover:${NC} ")" NEW_IP
  NEW_IP=$(echo "$NEW_IP" | tr -d ' ')

  if [ -z "$NEW_IP" ]; then
    echo -e "${RED}Cancelado.${NC}"
    exit 0
  fi

  if ! validate_ipv4 "$NEW_IP"; then
    echo -e "  ${RED}IPv4 invalido. Use o formato: X.X.X.X${NC}"
    continue
  fi

  # Verificar se ja existe
  if echo "$local_ips" | grep -q "$NEW_IP"; then
    echo -e "  ${RED}Este IP ja esta configurado.${NC}"
    continue
  fi

  break
done

log "Novo IP: ${NEW_IP}/32"

# Confirmacao
echo -e "\n${BOLD}${CYAN}=== Resumo ===${NC}"
echo -e "  IP a adicionar:  ${BOLD}${NEW_IP}/32${NC}"
echo -e "  Gateway:         ${BOLD}${gateway}${NC}"
echo -e "  Arquivo:         ${BOLD}${NETPLAN_FILE}${NC}"
echo ""

read -rp "$(echo -e "${YELLOW}Adicionar este IP?${NC} [S/n]: ")" confirm
[[ "${confirm,,}" == "n" ]] && { echo -e "${RED}Cancelado.${NC}"; exit 0; }

# ===================== BACKUP =====================
cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
log "Backup criado"

# ===================== ADICIONAR IP AO NETPLAN =====================
# Encontrar a ultima linha de "addresses:" e adicionar abaixo do ultimo IP /32
# Estrategia: inserir nova linha com "- NEW_IP/32" apos a ultima ocorrencia de "/32"
info "Adicionando IP ao netplan..."

# Encontrar o numero da ultima linha que contem /32 dentro do bloco addresses
LAST_IP_LINE=$(grep -n '/32' "$NETPLAN_FILE" | tail -1 | cut -d: -f1)

if [ -z "$LAST_IP_LINE" ]; then
  err "Nao foi possivel encontrar o bloco de addresses no netplan. Verifique $NETPLAN_FILE manualmente."
fi

# Extrair a indentacao da linha existente
INDENT=$(sed -n "${LAST_IP_LINE}p" "$NETPLAN_FILE" | grep -oP '^\s+')

# Inserir nova linha apos a ultima linha com /32
sed -i "${LAST_IP_LINE}a\\${INDENT}- ${NEW_IP}/32" "$NETPLAN_FILE"

log "IP adicionado ao netplan"

# ===================== APLICAR =====================
info "Aplicando netplan..."
if netplan apply 2>&1; then
  log "Netplan aplicado com sucesso"
else
  err "Falha ao aplicar netplan. Verifique $NETPLAN_FILE e restaure o backup se necessario."
fi

# Verificar se o IP esta ativo
sleep 2
if ip addr show 2>/dev/null | grep -q "$NEW_IP"; then
  log "IP ${NEW_IP} esta ${GREEN}ativo${NC} na interface"
else
  warn "IP adicionado ao netplan mas nao aparece na interface. Verifique o MAC Virtual no painel OVH."
fi

# ===================== RESUMO =====================
echo -e "\n${GREEN}${BOLD}================================================${NC}"
echo -e "${GREEN}${BOLD}       IP FAILOVER ADICIONADO COM SUCESSO${NC}"
echo -e "${GREEN}${BOLD}================================================${NC}\n"

echo -e "${CYAN}IPs configurados agora:${NC}"
get_current_ips | while IFS= read -r ip; do
  local_ip="${ip%/32}"
  if ip addr show 2>/dev/null | grep -q "$local_ip"; then
    echo -e "  ${GREEN}●${NC} ${BOLD}${ip}${NC}  (ativo)"
  else
    echo -e "  ${RED}●${NC} ${BOLD}${ip}${NC}  (pendente)"
  fi
done

echo ""
echo -e "${CYAN}Comandos uteis:${NC}"
echo -e "  ${YELLOW}sudo bash $0 --list${NC}      Ver IPs e status"
echo -e "  ${YELLOW}sudo bash $0 --remove${NC}    Remover um IP"
echo -e "  ${YELLOW}sudo bash $0${NC}             Adicionar outro IP"
echo -e "  ${YELLOW}ping -I ${NEW_IP} 1.1.1.1${NC}  Testar conectividade pelo novo IP"
echo ""
info "O firewall nftables ja cobre o novo IP (regras sao por porta, nao por IP)."
echo ""
