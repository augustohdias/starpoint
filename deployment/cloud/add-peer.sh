#!/usr/bin/env bash
# Adiciona um peer WireGuard ao Starpoint cloud (sem mexer nos existentes)
# Uso: sudo ./deployment/cloud/add-peer.sh "NomeDoIrmao"
set -euo pipefail
WG_IFACE=wg0
WG_PORT=51820
WG_SUBNET=10.66.0
SERVER_IP_IN_TUNNEL=${WG_SUBNET}.1
STARPOINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

[[ $EUID -eq 0 ]] || { echo "rode como root (sudo)"; exit 1; }
[[ $# -eq 1 ]] || { echo "uso: $0 \"Nome\""; exit 1; }
NAME="$1"

SERVER_PUB=$(cat /etc/wireguard/server_public.key)
PUBLIC_IP=$(curl -s --max-time 8 ifconfig.me || echo SEU_IP_PUBLICO)

# próximo IP livre (peers existentes em wg0.conf)
LAST=$(grep -oP "AllowedIPs = ${WG_SUBNET}\.\K\d+" /etc/wireguard/${WG_IFACE}.conf | sort -n | tail -1)
IP_NUM=$(( ${LAST:-1} + 1 ))
[[ $IP_NUM -lt 255 ]] || { echo "sem IPs livres no túnel"; exit 1; }
IP=${WG_SUBNET}.${IP_NUM}

PRIV=$(wg genkey)
PUB=$(echo "$PRIV" | wg pubkey)

mkdir -p "${STARPOINT_DIR}/clients"
cat > "${STARPOINT_DIR}/clients/${NAME}.conf" <<EOF
[Interface]
PrivateKey = ${PRIV}
Address = ${IP}/32
DNS = ${SERVER_IP_IN_TUNNEL}

[Peer]
PublicKey = ${SERVER_PUB}
AllowedIPs = ${WG_SUBNET}.0/24
Endpoint = ${PUBLIC_IP}:${WG_PORT}
PersistentKeepalive = 25
EOF

cat >> /etc/wireguard/${WG_IFACE}.conf <<EOF

[Peer]
# ${NAME}
PublicKey = ${PUB}
AllowedIPs = ${IP}/32
EOF

wg addconf ${WG_IFACE} <(printf '[Peer]\n# %s\nPublicKey = %s\nAllowedIPs = %s/32\n' "$NAME" "$PUB" "$IP")
systemctl restart wg-quick@${WG_IFACE}

echo "peer ${NAME} adicionado (${IP})"
qrencode -t ansiutf8 < "${STARPOINT_DIR}/clients/${NAME}.conf" 2>/dev/null || cat "${STARPOINT_DIR}/clients/${NAME}.conf"
