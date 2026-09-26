#!/usr/bin/env bash
# Вешает на интерфейс wg-exit сети из shlima/keneetic-antifilter.
# Запускать на этом сервере после того, как туннель поднялся.
set -euo pipefail

IFACE="${IFACE:-wg-exit}"
BASE="https://raw.githubusercontent.com/shlima/keneetic-antifilter/master/routes"
API="https://api.github.com/repos/shlima/keneetic-antifilter/contents/routes"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Запустите от root"
ip link show "${IFACE}" >/dev/null 2>&1 || die "Интерфейс ${IFACE} не поднят. Сначала scripts/wg-tunnel-local.sh"

if ! wg show "${IFACE}" latest-handshakes | awk '{exit !($2+0 > 0)}'; then
  die "Нет рукопожатия с 2a03:afc0:9::12e1. Сначала выполните на том хосте scripts/generated/wg-exit-on-remote.sh"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

log "Список файлов маршрутов"
curl -fsSL "${API}" -o "${tmpdir}/index.json"
python3 - "${tmpdir}/index.json" "${tmpdir}/files.txt" << 'PY'
import json, sys
names = [x["name"] for x in json.load(open(sys.argv[1])) if x["name"].endswith(".bat")]
alls = sorted(n for n in names if n.startswith("all-ipv4-"))
chosen = alls or sorted(n for n in names if n.endswith("-ipv4.bat"))
if not chosen:
    raise SystemExit("в репозитории нет bat-файлов")
open(sys.argv[2], "w").write("\n".join(chosen) + "\n")
print(len(chosen))
PY

: > "${tmpdir}/all.bat"
while read -r name; do
  [[ -n "${name}" ]] || continue
  log "Качаю ${name}"
  curl -fsSL "${BASE}/${name}" >> "${tmpdir}/all.bat"
  printf '\n' >> "${tmpdir}/all.bat"
done < "${tmpdir}/files.txt"

python3 - "${tmpdir}/all.bat" "${tmpdir}/routes.txt" << 'PY'
import ipaddress, sys
seen = set()
out = open(sys.argv[2], "w")
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) < 5 or parts[0] != "route" or parts[1] != "ADD":
        continue
    net = ipaddress.IPv4Network(f"{parts[2]}/{parts[4]}", strict=False)
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
