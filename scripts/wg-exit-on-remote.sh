#!/usr/bin/env bash
# Шаблон выходного туннеля. На удалённый хост его не копировать.
# Готовый файл с ключами: scripts/generated/wg-exit-on-remote.sh
set -euo pipefail

WG_PORT="${WG_PORT:-51820}"
WG_ADDR="${WG_ADDR:-10.66.66.1/24}"
PEER_ADDR="${PEER_ADDR:-10.66.66.2/32}"
PEER_ENDPOINT="${PEER_ENDPOINT:-2a03:6f01:1:2::1:8306}"
IFACE="wg-exit"

SERVER_PRIV="__SERVER_PRIV__"
PEER_PUB="__PEER_PUB__"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

if [[ "${SERVER_PRIV}" == __* ]]; then
  die "Это шаблон без ключей. На удалённый хост копируйте scripts/generated/wg-exit-on-remote.sh"
fi
[[ "$(id -u)" -eq 0 ]] || die "Запустите от root"

export DEBIAN_FRONTEND=noninteractive
if ! command -v wg >/dev/null 2>&1; then
  log "Устанавливаю wireguard"
  apt-get update -qq
  apt-get install -y -qq wireguard iptables
fi

EGRESS="$(ip -4 route show default | awk '{print $5; exit}')"
[[ -n "${EGRESS}" ]] || die "Нет IPv4-маршрута по умолчанию, выпускать трафик некуда"

install -d -m 700 /etc/wireguard
umask 077
cat > "/etc/wireguard/${IFACE}.conf" <<EOF
[Interface]
Address = ${WG_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
MTU = 1380

[Peer]
PublicKey = ${PEER_PUB}
AllowedIPs = ${PEER_ADDR}
Endpoint = [${PEER_ENDPOINT}]:${WG_PORT}
PersistentKeepalive = 25
EOF
chmod 600 "/etc/wireguard/${IFACE}.conf"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w "net.ipv4.conf.${IFACE}.rp_filter=0" >/dev/null 2>&1 || true
cat > /etc/sysctl.d/99-wg-exit.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.${IFACE}.rp_filter=0
EOF

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
  ufw allow "${WG_PORT}/udp" comment 'wg-exit' >/dev/null || true
fi

nft delete table inet wgexit >/dev/null 2>&1 || true
nft -f - <<EOF
table inet wgexit {
  chain input {
    type filter hook input priority -50; policy accept;
    udp dport ${WG_PORT} accept
  }
  chain forward {
    type filter hook forward priority -50; policy accept;
    iifname "${IFACE}" accept
    oifname "${IFACE}" ct state established,related accept
  }
  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
    ip saddr 10.66.66.0/24 oifname "${EGRESS}" masquerade
  }
}
EOF

iptables -C FORWARD -i "${IFACE}" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "${IFACE}" -j ACCEPT
iptables -C FORWARD -o "${IFACE}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o "${IFACE}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s 10.66.66.0/24 -o "${EGRESS}" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o "${EGRESS}" -j MASQUERADE

systemctl enable "wg-quick@${IFACE}" >/dev/null
systemctl restart "wg-quick@${IFACE}"
log "Слушаю [${PEER_ENDPOINT} ждёт нас]:${WG_PORT}, свой адрес ${WG_ADDR}, выход ${EGRESS}"
wg show "${IFACE}"
