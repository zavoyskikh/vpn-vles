#!/usr/bin/env bash
# Restore working configuration of the 3x-ui Docker stack from backup archive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_DIR="${PROJECT_DIR}/backups"
MIGRATE_HOST_PY="${SCRIPT_DIR}/migrate_host.py"

POSTGRES_CONTAINER="3xui_postgres"
POSTGRES_USER="xui"
POSTGRES_DB="xui"
NPM_CONTAINER="3xui_npm"

AUTO_YES=false
ARCHIVE=""
PUBLIC_IP_OVERRIDE=""
OLD_IP_OVERRIDE=""
DOMAIN_OVERRIDE=""
PANEL_PORT="4443"
PANEL_PORT_SET=false
SAME_HOST=false
KEEP_DOMAIN=false
SKIP_CERT=false
SKIP_HOST_REWRITE=false

usage() {
  cat <<EOF
Использование: $(basename "$0") [опции] <путь-к-архиву.tar.gz>

Восстанавливает рабочую конфигурацию проекта из бэкапа:
  - docker-compose.yml
  - db/, cert/, npm/
  - PostgreSQL (из postgres.sql)

Если публичный IP или домен отличаются от бэкапа, скрипт переписывает:
  - subURI / subJsonURI / subClashURI / webDomain
  - адреса в hosts и inbounds.share_addr
  - домены Nginx Proxy Manager и server_name в nginx
  и пытается выпустить новый Let's Encrypt сертификат.

Опции:
  -y, --yes           Не спрашивать подтверждение
  --public-ip IP      Публичный IPv4 нового сервера (иначе определяется сам)
  --old-ip IP         Публичный IPv4 из бэкапа, если его нет в манифесте
  --domain FQDN       Имя панели/подписки (по умолчанию IP.sslip.io для sslip/nip)
  --panel-port PORT   HTTPS-порт NPM для панели и /sub (по умолчанию 4443)
  --keep-domain       Оставить домен из бэкапа (только заменить IP в адресах)
  --same-host         Не переписывать IP/домен (восстановление на том же сервере)
  --skip-cert         Не запрашивать Let's Encrypt после переноса
  -h, --help          Показать справку

Примеры:
  $(basename "$0") backups/vpn-backup-20260712-120000.tar.gz
  $(basename "$0") -y --public-ip 188.227.107.43 backups/vpn-backup.tar.gz
  $(basename "$0") --domain vpn.example.com backups/vpn-backup.tar.gz
  $(basename "$0") --keep-domain backups/vpn-backup.tar.gz
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

confirm() {
  if [ "${AUTO_YES}" = true ]; then
    return 0
  fi
  printf '%s [y/N]: ' "$1"
  read -r answer
  case "${answer}" in
    y|Y|yes|YES|да|Да) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Команда не найдена: $1"
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  if [[ ! "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ ! "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "${ip}"
}

is_ipv4() {
  [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ip_based_host() {
  local host="${1,,}"
  host="${host%.}"
  [[ -z "${host}" ]] && return 1
  is_ipv4 "${host}" && return 0
  [[ "${host}" == *.sslip.io || "${host}" == *.nip.io ]]
}

wait_for_postgres() {
  local i
  for i in $(seq 1 30); do
    if docker exec "${POSTGRES_CONTAINER}" pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "PostgreSQL не готов после ожидания."
}

wait_for_http() {
  local url="$1"
  local i code
  for i in $(seq 1 30); do
    code="$(curl -sS -o /dev/null --max-time 3 -w '%{http_code}' "${url}" 2>/dev/null || true)"
    if [ -n "${code}" ] && [ "${code}" != "000" ]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

json_get() {
  local file="$1"
  local key="$2"
  python3 - "${file}" "${key}" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)
value = data.get(key, "")
if isinstance(value, list):
    print(value[0] if value else "")
else:
    print(value or "")
PY
}

extract_old_ip_from_dump() {
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
match = re.search(r"(\d{1,3}(?:\.\d{1,3}){3})\.sslip\.io", text)
print(match.group(1) if match else "")
PY
}

issue_letsencrypt() {
  local domain="$1"
  log "Запрос Let's Encrypt для ${domain}..."
  if ! wait_for_http "http://127.0.0.1:81"; then
    log "Предупреждение: NPM ещё не отвечает на :81, сертификат нужно выпустить вручную."
    return 0
  fi
  if ! docker exec "${NPM_CONTAINER}" sh -c "command -v certbot >/dev/null"; then
    log "Предупреждение: certbot нет в контейнере NPM. Выпустите сертификат в UI на порту 81."
    return 0
  fi
  if docker exec "${NPM_CONTAINER}" certbot certonly --webroot \
    -w /data/letsencrypt-acme-challenge \
    -d "${domain}" \
    --agree-tos --register-unsafely-without-email --non-interactive; then
    local live="/etc/letsencrypt/live/${domain}"
    local nginx_dir="${PROJECT_DIR}/npm/data/nginx"
    if [ -d "${nginx_dir}" ]; then
      find "${nginx_dir}" -name '*.conf' -print0 | while IFS= read -r -d '' conf; do
        if grep -q "server_name ${domain};" "${conf}"; then
          sed -i \
            -e "s|ssl_certificate .*;|ssl_certificate ${live}/fullchain.pem;|" \
            -e "s|ssl_certificate_key .*;|ssl_certificate_key ${live}/privkey.pem;|" \
            "${conf}"
        fi
      done
    fi
    docker exec "${NPM_CONTAINER}" nginx -s reload >/dev/null 2>&1 || \
      docker restart "${NPM_CONTAINER}" >/dev/null
    log "Сертификат выпущен: ${domain}"
  else
    log "Предупреждение: Let's Encrypt не выпустился. Откройте NPM :81 и запросите сертификат для ${domain}."
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) AUTO_YES=true; shift ;;
    --public-ip)
      [ $# -ge 2 ] || die "Для --public-ip нужно значение"
      PUBLIC_IP_OVERRIDE="$2"
      shift 2
      ;;
    --domain)
      [ $# -ge 2 ] || die "Для --domain нужно значение"
      DOMAIN_OVERRIDE="$2"
      shift 2
      ;;
    --panel-port)
      [ $# -ge 2 ] || die "Для --panel-port нужно значение"
      PANEL_PORT="$2"
      PANEL_PORT_SET=true
      shift 2
      ;;
    --old-ip)
      [ $# -ge 2 ] || die "Для --old-ip нужно значение"
      OLD_IP_OVERRIDE="$2"
      shift 2
      ;;
    --keep-domain) KEEP_DOMAIN=true; shift ;;
    --same-host) SAME_HOST=true; SKIP_HOST_REWRITE=true; shift ;;
    --skip-cert) SKIP_CERT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "Неизвестная опция: $1" ;;
    *)
      [ -z "${ARCHIVE}" ] || die "Указано несколько архивов."
      ARCHIVE="$1"
      shift
      ;;
  esac
done

[ -n "${ARCHIVE}" ] || { usage; exit 1; }
[[ "${PANEL_PORT}" =~ ^[0-9]+$ ]] && [ "${PANEL_PORT}" -ge 1 ] && [ "${PANEL_PORT}" -le 65535 ] \
  || die "Некорректный --panel-port: ${PANEL_PORT}"
if [ -n "${PUBLIC_IP_OVERRIDE}" ] && ! is_ipv4 "${PUBLIC_IP_OVERRIDE}"; then
  die "Некорректный --public-ip: ${PUBLIC_IP_OVERRIDE}"
fi
if [ -n "${OLD_IP_OVERRIDE}" ] && ! is_ipv4 "${OLD_IP_OVERRIDE}"; then
  die "Некорректный --old-ip: ${OLD_IP_OVERRIDE}"
fi

# Resolve relative path from backups dir
if [ ! -f "${ARCHIVE}" ] && [ -f "${BACKUP_DIR}/${ARCHIVE}" ]; then
  ARCHIVE="${BACKUP_DIR}/${ARCHIVE}"
fi

[ -f "${ARCHIVE}" ] || die "Архив не найден: ${ARCHIVE}"

require_cmd docker
require_cmd tar
require_cmd python3
require_cmd curl
[ -f "${MIGRATE_HOST_PY}" ] || die "Не найден ${MIGRATE_HOST_PY}"

STAGING_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

log "Распаковка ${ARCHIVE}..."
tar -xzf "${ARCHIVE}" -C "${STAGING_DIR}"

[ -f "${STAGING_DIR}/docker-compose.yml" ] || die "Некорректный архив: нет docker-compose.yml"
if [ -f "${STAGING_DIR}/manifest.json" ]; then
  log "Манифест: $(tr '\n' ' ' < "${STAGING_DIR}/manifest.json")"
fi

OLD_IP="${OLD_IP_OVERRIDE}"
OLD_DOMAIN=""
if [ -f "${STAGING_DIR}/manifest.json" ]; then
  [ -n "${OLD_IP}" ] || OLD_IP="$(json_get "${STAGING_DIR}/manifest.json" public_ip)"
  OLD_DOMAIN="$(json_get "${STAGING_DIR}/manifest.json" panel_domain)"
  MANIFEST_PORT="$(json_get "${STAGING_DIR}/manifest.json" panel_port)"
  if [ "${PANEL_PORT_SET}" = false ] && [[ "${MANIFEST_PORT}" =~ ^[0-9]+$ ]]; then
    PANEL_PORT="${MANIFEST_PORT}"
  fi
fi
if [ -z "${OLD_IP}" ] && [ -s "${STAGING_DIR}/postgres.sql" ]; then
  OLD_IP="$(extract_old_ip_from_dump "${STAGING_DIR}/postgres.sql")"
fi
if [ -z "${OLD_IP}" ] && [[ "${OLD_DOMAIN}" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\.(sslip\.io|nip\.io)$ ]]; then
  OLD_IP="${BASH_REMATCH[1]}"
fi
if [ -z "${OLD_DOMAIN}" ] && [ -n "${OLD_IP}" ]; then
  OLD_DOMAIN="${OLD_IP}.sslip.io"
fi

NEW_IP="${PUBLIC_IP_OVERRIDE}"
if [ -z "${NEW_IP}" ]; then
  NEW_IP="$(detect_public_ip)"
fi
if [ -z "${NEW_IP}" ] || ! is_ipv4 "${NEW_IP}"; then
  die "Не удалось определить публичный IP. Укажите --public-ip."
fi

NEW_DOMAIN="${DOMAIN_OVERRIDE}"
if [ "${KEEP_DOMAIN}" = true ]; then
  NEW_DOMAIN="${OLD_DOMAIN}"
fi
if [ -z "${NEW_DOMAIN}" ]; then
  if is_ip_based_host "${OLD_DOMAIN}" || [ -z "${OLD_DOMAIN}" ]; then
    NEW_DOMAIN="${NEW_IP}.sslip.io"
  else
    NEW_DOMAIN="${OLD_DOMAIN}"
    KEEP_DOMAIN=true
  fi
fi

HOST_CHANGED=false
if [ "${SKIP_HOST_REWRITE}" = false ]; then
  if [ -n "${OLD_IP}" ] && [ "${OLD_IP}" != "${NEW_IP}" ]; then
    HOST_CHANGED=true
  fi
  if [ -n "${OLD_DOMAIN}" ] && [ "${OLD_DOMAIN}" != "${NEW_DOMAIN}" ]; then
    HOST_CHANGED=true
  fi
  if [ -n "${DOMAIN_OVERRIDE}" ]; then
    HOST_CHANGED=true
  fi
fi

confirm "Восстановление перезапишет текущую конфигурацию. Продолжить?" || die "Отменено."

if [ "${HOST_CHANGED}" = true ]; then
  log "Перенос на другой сервер: ${OLD_IP:-?} (${OLD_DOMAIN:-?}) -> ${NEW_IP} (${NEW_DOMAIN}), порт панели ${PANEL_PORT}"
  confirm "Обновить URI подписки, домены NPM и запросить новый сертификат?" || HOST_CHANGED=false
fi

cd "${PROJECT_DIR}"

# Safety backup of current state
if [ -x "${SCRIPT_DIR}/backup.sh" ]; then
  log "Создание страховочного бэкапа текущего состояния..."
  "${SCRIPT_DIR}/backup.sh" || log "Предупреждение: страховочный бэкап не удался."
fi

log "Остановка контейнеров..."
docker compose down

# Restore files
log "Восстановление docker-compose.yml..."
cp "${STAGING_DIR}/docker-compose.yml" "${PROJECT_DIR}/"

if [ -f "${STAGING_DIR}/.env" ]; then
  log "Восстановление .env..."
  cp "${STAGING_DIR}/.env" "${PROJECT_DIR}/"
fi

for dir in db cert; do
  if [ -d "${STAGING_DIR}/data/${dir}" ]; then
    log "Восстановление ${dir}/..."
    mkdir -p "${PROJECT_DIR}/${dir}"
    rm -rf "${PROJECT_DIR:?}/${dir:?}/"*
    cp -a "${STAGING_DIR}/data/${dir}/." "${PROJECT_DIR}/${dir}/"
  fi
done

if [ -d "${STAGING_DIR}/data/npm" ]; then
  log "Восстановление npm/..."
  mkdir -p "${PROJECT_DIR}/npm"
  rm -rf "${PROJECT_DIR:?}/npm/"*
  cp -a "${STAGING_DIR}/data/npm/." "${PROJECT_DIR}/npm/"
  mkdir -p "${PROJECT_DIR}/npm/data/logs"
fi

# PostgreSQL: reinitialize data dir and restore dump
if [ -s "${STAGING_DIR}/postgres.sql" ]; then
  log "Переинициализация PostgreSQL..."
  if [ -d "${PROJECT_DIR}/pgdata" ]; then
    rm -rf "${PROJECT_DIR:?}/pgdata/"*
  fi
  mkdir -p "${PROJECT_DIR}/pgdata"

  log "Запуск PostgreSQL..."
  docker compose up -d postgres
  wait_for_postgres

  log "Восстановление дампа БД в ${POSTGRES_DB}..."
  # pg_dump without --create writes objects only; they must go into xui.
  # Restoring into the maintenance DB "postgres" leaves xui empty.
  docker exec -i "${POSTGRES_CONTAINER}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 \
    < "${STAGING_DIR}/postgres.sql"
else
  log "Предупреждение: postgres.sql пуст, БД не восстанавливается."
fi

if [ "${HOST_CHANGED}" = true ]; then
  [ -n "${OLD_IP}" ] || die "В бэкапе нет старого IP, укажите его через манифест или восстановите с --same-host."
  log "Переписывание IP/домена в панели и NPM..."
  python3 "${MIGRATE_HOST_PY}" \
    --old-ip "${OLD_IP}" \
    --new-ip "${NEW_IP}" \
    --old-domain "${OLD_DOMAIN}" \
    --new-domain "${NEW_DOMAIN}" \
    --panel-port "${PANEL_PORT}" \
    --pg-container "${POSTGRES_CONTAINER}" \
    --pg-user "${POSTGRES_USER}" \
    --pg-db "${POSTGRES_DB}" \
    --npm-sqlite "${PROJECT_DIR}/npm/data/database.sqlite" \
    --npm-nginx-dir "${PROJECT_DIR}/npm/data/nginx"
fi

log "Запуск всех сервисов..."
docker compose up -d

if [ "${HOST_CHANGED}" = true ] && [ "${SKIP_CERT}" = false ] && [ "${NEW_DOMAIN}" != "${OLD_DOMAIN}" ]; then
  issue_letsencrypt "${NEW_DOMAIN}"
fi

log "Готово. Проверка контейнеров:"
docker compose ps

printf '\nВосстановление завершено из: %s\n' "${ARCHIVE}"
if [ "${HOST_CHANGED}" = true ]; then
  printf 'Панель:     https://%s:%s\n' "${NEW_DOMAIN}" "${PANEL_PORT}"
  printf 'Подписка:   https://%s:%s/sub/\n' "${NEW_DOMAIN}" "${PANEL_PORT}"
  printf 'VPN:        %s:443\n' "${NEW_IP}"
  printf 'NPM UI:     http://%s:81\n' "${NEW_IP}"
  printf '\nКлиентам нужно обновить адрес сервера / URL подписки.\n'
  printf 'Reality dest/SNI и UUID клиентов не менялись.\n'
else
  printf 'IP/домен не переписывались.\n'
fi
