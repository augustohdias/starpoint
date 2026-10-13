#!/usr/bin/env bash
# Starpoint Cloud Setup — VPN-only, multi-player
# Uso (na VM, como root, dentro de /opt/starpoint):
#   ./deployment/cloud/setup-server.sh "Augusto" "Esposa" "Irmão"
# Cada nome vira um peer WireGuard; os perfis são salvos em clients/<nome>.conf
set -euo pipefail

WG_IFACE=wg0
WG_PORT=51820
WG subnet placeholder-resolved below
WG_SUBNET=10.66.0
SERVER_IP_IN_TUNNEL=${WG_SUBNET}.1
STARPOINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOMAINS="na.wdfp.kakaogames.com patch.wdfp.kakaogames.com openapi-zinny3.game.kakao.com gc-openapi-zinny3.kakaogames.com gc-infodesk-zinny3.kakaogames.com"

[[ $EUID -eq 0 ]] || { echo "rode como root (sudo)"; exit 1; }
cd "$STARPOINT_DIR"

echo "==> [1/8] pacotes"
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools dnsmasq nginx ufw qrencode curl >/dev/null
if ! command -v node >/dev/null || [[ "$(node -v | cut -c2- | cut -d. -f1)" -lt 20 ]]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
    apt-get install -y -qq nodejs >/dev/null
fi
node -v

echo "==> [2/8] chaves do servidor WireGuard"
mkdir -p /etc/wireguard clients
[[ -f /etc/wireguard/server_private.key ]] || wg genkey | tee /etc/wireguide_placeholder 2>/dev/null || true
if [[ ! -f /etc/wireguard/server_private.key ]]; then
    wg genkey > /etc/wireguard/server_private.key
    wg pubkey < /etc/wireguard/server_private.key > /etc/wireguard/server_public.key
fi
SERVER_PUB=$(cat /etc/wireguard/server_public.key)

echo "==> [3/8] peers: $*"
i=2
PEER_CONFS=""
for NAME in "$@"; do
    PRIV=$(wg genkey); PUB=$(echo "$PRIV" | wg pubkey)
    IP=${WG_SUBNET}.${i}
    cat > "clients/${NAME}.conf" <<EOF
[Interface]
PrivateKey = ${PRIV}
Address = ${IP}/32
DNS = ${SERVER_IP_IN_TUNNEL}

[Peer]
PublicKey = ${SERVER_PUB}
AllowedIPs = ${WG_SUBNET}.0/24
Endpoint = $(curl -s --max-time 5 ifconfig.me || echo SEU_IP_PUBLICO):${WG_PORT}
PersistentKeepalive = 25
EOF
    PEER_CONFS+="${NAME}: ${IP} ${PUB}\n"
    i=$((i+1))
done

echo "==> [4/8] interface wg0"
cat > /etc/wireguard/${WG_IFACE}.conf <<EOF
[Interface]
Address = ${SERVER_IP_IN_TUNNEL}/24
ListenPort = ${WG_PORT}
PrivateKey = $(cat /etc/wireguard/server_private.key)
PostUp = ufw route allow in on ${WG_IFACE}
PostDown = ufw route delete allow in on ${WG_IFACE}
EOF
i=2
for NAME in "$@"; do
    PUB=$(grep -oP '(?<=PublicKey = ).*' "clients/${NAME}.conf" 2>/dev/null || true)
    :
done
# adiciona peers de fato (chaves púb. salvas durante o loop anterior)
i=2
for NAME in "$@"; do
    IP=${WG_SUBNET}.${i}
    PUB=$(echo "$PEER_CONFS" | grep "^${NAME}: " | awk '{print $3}')
    cat >> /etc/wireguard/${WG_IFACE}.conf <<EOF

[Peer]
# ${NAME}
PublicKey = ${PUB}
AllowedIPs = ${IP}/32
EOF
    i=$((i+1))
done
systemctl enable --now wg-quick@${WG_IFACE}

echo "==> [5/8] dnsmasq (DNS só no túnel)"
cat > /etc/dnsmasq.d/starpoint.conf <<EOF
listen-address=${SERVER_IP_IN_TUNNEL}
bind-interfaces
server=1.1.1.1
server=8.8.8.8
address=/na.wdfp.kakaogames.com/${SERVER_IP_IN_TUNNEL}
address=/patch.wdfp.kakaogames.com/${SERVER_IP_IN_TUNNEL}
address=/openapi-zinny3.game.kakao.com/${SERVER_IP_IN_TUNNEL}
address=/gc-openapi-zinny3.kakaogames.com/${SERVER_IP_IN_TUNNEL}
address=/gc-infodesk-zinny3.kakaogames.com/${SERVER_IP_IN_TUNNEL}
EOF
systemctl enable --now dnsmasq
systemctl restart dnsmasq

echo "==> [6/8] CA + certos Starpoint (self-signed)"
mkdir -p generated
if [[ ! -f generated/starpoint_ca.key ]]; then
    openssl genrsa -out generated/starpoint_ca.key 4096
    openssl req -x509 -new -nodes -key generated/starpoint_ca.key -sha256 -days 3650 \
        -out generated/starpoint_ca.crt -subj "/CN=Starpoint Cloud CA/O=Starpoint"
fi
SAN=""; for d in $DOMAINS; do SAN+="DNS:${d},"; done; SAN=${SAN%,}
openssl req -new -nodes -out generated/starpoint_wdfp.csr \
    -newkey rsa:4096 -keyout generated/starpoint_wdfp.key \
    -subj "/CN=na.wdfp.kakaogames.com/O=Starpoint"
openssl x509 -req -in generated/starpoint_wdfp.csr -CA generated/starpoint_ca.crt \
    -CAkey generated/starpoint_ca.key -CAcreateserial -out generated/starpoint_wdfp.crt \
    -days 3650 -sha256 -extfile <(printf "subjectAltName=%s\nextendedKeyUsage=serverAuth" "$SAN")

echo "==> [7/8] nginx (só no IP do túnel)"
cat > /etc/nginx/sites-available/starpoint <<EOF
map \$host \$target {
    default "http://127.0.0.1:8000";
}

server {
    listen ${SERVER_IP_IN_TUNNEL}:80;
    server_name _;
    location / { proxy_set_header Host \$host; proxy_pass \$target\$request_uri; }
}

server {
    listen ${SERVER_IP_IN_TUNNEL}:443 ssl;
    server_name ${DOMAINS};
    ssl_certificate ${STARPOINT_DIR}/generated/starpoint_wdfp.crt;
    ssl_certificate_key ${STARPOINT_DIR}/generated/starpoint_wdfp.key;
    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass \$target\$request_uri;
    }
}
EOF
# patch: domínios com caminho /patch → mapeia para o prefixo do starpoint
cat >> /etc/nginx/sites-available/starpoint <<EOF
server {
    listen ${SERVER_IP_IN_TUNNEL}:80;
    listen ${SERVER_IP_IN_TUNNEL}:443 ssl;
    server_name patch.wdfp.kakaogames.com;
    ssl_certificate ${STARPOINT_DIR}/generated/starpoint_wdfp.crt;
    ssl_certificate_key ${STARPOINT_DIR}/generated/starpoint_wdfp.key;
    location / {
        proxy_set_header Host \$host;
        proxy_pass http://127.0.0.1:8000/patch\$request_uri;
    }
}
EOF
ln -sf /etc/nginx/sites-available/starpoint /etc/nginx/sites-enabled/starpoint
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx && systemctl reload nginx

echo "==> [8/8] systemd + firewall"
cat > /etc/systemd/system/starpoint.service <<EOF
[Unit]
Description=Starpoint server
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
WorkingDirectory=${STARPOINT_DIR}
ExecStart=/usr/bin/env node --env-file=.env out/server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw limit OpenSSH
ufw allow ${WG_PORT}/udp
ufw allow in on ${WG_IFACE}
ufw --force enable

echo
echo "=============================================="
echo " TUDO PRONTO. Próximos passos:"
echo " 1. Suba o servidor:  systemctl start starpoint"
echo "    (antes: npm install && npm run build)"
echo " 2. Perfis dos clientes: clients/<nome>.conf"
echo "    (importe no app WireGuard de cada pessoa)"
echo " 3. Instale a CA nos celulares:"
echo "    generated/starpoint_ca.crt"
echo "    (Android: Config. → Segurança → Instalar certificado → CA)"
echo " 4. Ligue o túnel e abra o jogo."
echo "=============================================="
for NAME in "$@"; do
    echo; echo "--- ${NAME} (clients/${NAME}.conf) ---"
    qrencode -t ansiutf8 < "clients/${NAME}.conf" || cat "clients/${NAME}.conf"
done
