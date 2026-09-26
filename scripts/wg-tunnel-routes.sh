#!/usr/bin/env bash
# Вешает на интерфейс wg-exit сети из routes/tunnel-ipv4.txt.
# Запускать на этом сервере после того, как туннель поднялся.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIST="${ROOT}/routes/tunnel-ipv4.txt"
IFACE="${IFACE:-wg-exit}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Запустите от root"
[[ -f "${LIST}" ]] || die "Нет списка ${LIST}"
ip link show "${IFACE}" >/dev/null 2>&1 || die "Интерфейс ${IFACE} не поднят. Сначала scripts/wg-tunnel-local.sh"

if ! wg show "${IFACE}" latest-handshakes | awk '{exit !($2+0 > 0)}'; then
  die "Нет рукопожатия с 2a03:afc0:9::12e1. Сначала выполните на том хосте scripts/generated/wg-exit-on-remote.sh"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

python3 - "${LIST}" "${tmpdir}/routes.txt" << 'PY'
import ipaddress, sys
seen = set()
out = open(sys.argv[2], "w")
for lineno, raw in enumerate(open(sys.argv[1]), 1):
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    cidr = line.split()[0]
    try:
        net = ipaddress.IPv4Network(cidr, strict=False)
    except ValueError:
        raise SystemExit(f"Строка {lineno}: неверная сеть {cidr}")
    cidr = str(net)
    if cidr in seen:
        continue
    seen.add(cidr)
    out.write(cidr + "\n")
print(len(seen))
PY

current="$(ip -4 route show dev "${IFACE}" | awk '{print $1}')"
wanted="$(cat "${tmpdir}/routes.txt")"
# Снять с интерфейса сети, которых больше нет в списке.
while read -r cidr; do
  [[ -n "${cidr}" && "${cidr}" != "10.66.66.0/24" ]] || continue
  grep -qx "${cidr}" <<< "${wanted}" || ip route del "${cidr}" dev "${IFACE}" || true
done <<< "${current}"

count=0
while read -r cidr; do
  [[ -n "${cidr}" ]] || continue
  ip route replace "${cidr}" dev "${IFACE}"
  count=$((count + 1))
done < "${tmpdir}/routes.txt"
log "В туннель направлено сетей: ${count}"
