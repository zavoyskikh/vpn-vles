#!/usr/bin/env bash
# Туннель с этого сервера на 2a03:afc0:9::12e1 поверх IPv6.
# Ключи создаются здесь. Готовый скрипт для удалённого хоста пишется в scripts/generated/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IFACE="wg-exit"
CONF="/etc/wireguard/${IFACE}.conf"
STATE="/etc/wireguard/${IFACE}.state"
GEN_DIR="${ROOT}/scripts/generated"
GEN="${GEN_DIR}/wg-exit-on-remote.sh"
TEMPLATE="${ROOT}/scripts/wg-exit-on-remote.sh"
REMOTE_EP="${REMOTE_EP:-[2a03:afc0:9::12e1]:51820}"
LOCAL_EP="${LOCAL_EP:-2a03:6f01:1:2::1:8306}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Запустите от root"

export DEBIAN_FRONTEND=noninteractive
if ! command -v wg >/dev/null 2>&1; then
  log "Устанавливаю wireguard"
  apt-get update -qq
  apt-get install -y -qq wireguard iptables
fi

install -d -m 700 /etc/wireguard "${GEN_DIR}"
if [[ ! -f "${STATE}" ]]; then
  LOCAL_PRIV="$(wg genkey)"
  LOCAL_PUB="$(printf '%s' "${LOCAL_PRIV}" | wg pubkey)"
  REMOTE_PRIV="$(wg genkey)"
  REMOTE_PUB="$(printf '%s' "${REMOTE_PRIV}" | wg pubkey)"
  umask 077
  cat > "${STATE}" <<EOF
LOCAL_PRIV='${LOCAL_PRIV}'
LOCAL_PUB='${LOCAL_PUB}'
REMOTE_PRIV='${REMOTE_PRIV}'
REMOTE_PUB='${REMOTE_PUB}'
EOF
  chmod 600 "${STATE}"
  log "Создана новая пара ключей"
fi
# shellcheck disable=SC1090
source "${STATE}"

umask 077
cat > "${CONF}" <<EOF
[Interface]
Address = 10.66.66.2/24
PrivateKey = ${LOCAL_PRIV}
MTU = 1380
Table = off

[Peer]
PublicKey = ${REMOTE_PUB}
Endpoint = ${REMOTE_EP}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "${CONF}"

# Пакеты в туннель должны уходить с адреса 10.66.66.2, его ждёт удалённая сторона.
nft delete table inet wgtunnel >/dev/null 2>&1 || true
nft -f - <<'EOF'
table inet wgtunnel {
  chain postrouting {
    type nat hook postrouting priority 120; policy accept;
    oifname "wg-exit" ip saddr != 10.66.66.2 masquerade
  }
}
EOF

systemctl enable "wg-quick@${IFACE}" >/dev/null
systemctl restart "wg-quick@${IFACE}"

python3 - "${TEMPLATE}" "${GEN}" "${REMOTE_PRIV}" "${LOCAL_PUB}" << 'PY'
import pathlib, sys
src, dst, server_priv, peer_pub = sys.argv[1:]
text = pathlib.Path(src).read_text()
text = text.replace("__SERVER_PRIV__", server_priv).replace("__PEER_PUB__", peer_pub)
pathlib.Path(dst).write_text(text)
PY
chmod 700 "${GEN}"

log "Интерфейс ${IFACE} поднят, точка ${REMOTE_EP}"
log "Скрипт для удалённого хоста: ${GEN}"
if wg show "${IFACE}" latest-handshakes | awk '{exit !($2+0 > 0)}'; then
  log "Рукопожатие есть, ставлю маршруты"
  "${ROOT}/scripts/wg-tunnel-routes.sh"
else
  log "Удалённая сторона ещё не запущена, маршруты не ставлю — иначе эти адреса пропадут"
fi
