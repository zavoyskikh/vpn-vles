#!/usr/bin/env bash
# Backup working configuration of the 3x-ui Docker stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_DIR="${PROJECT_DIR}/backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_NAME="vpn-backup-${TIMESTAMP}.tar.gz"
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"
STAGING_DIR="$(mktemp -d)"

POSTGRES_CONTAINER="3xui_postgres"
POSTGRES_USER="xui"
POSTGRES_DB="xui"

cleanup() {
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
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

pg_setting() {
  local key="$1"
  docker exec "${POSTGRES_CONTAINER}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc \
    "SELECT COALESCE(value, '') FROM settings WHERE key = '${key}';" 2>/dev/null || true
}

require_cmd docker
require_cmd tar
require_cmd gzip
require_cmd python3

mkdir -p "${BACKUP_DIR}"
log "Каталог бэкапов: ${BACKUP_DIR}"

log "Создание staging-каталога..."
mkdir -p "${STAGING_DIR}/data"

# Project configuration
cp "${PROJECT_DIR}/docker-compose.yml" "${STAGING_DIR}/"
[ -f "${PROJECT_DIR}/.env" ] && cp "${PROJECT_DIR}/.env" "${STAGING_DIR}/"

# Runtime volumes
for dir in db cert; do
  if [ -d "${PROJECT_DIR}/${dir}" ]; then
    mkdir -p "${STAGING_DIR}/data/${dir}"
    cp -a "${PROJECT_DIR}/${dir}/." "${STAGING_DIR}/data/${dir}/"
  fi
done

# NPM data (without logs)
if [ -d "${PROJECT_DIR}/npm" ]; then
  mkdir -p "${STAGING_DIR}/data/npm"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude 'logs/' "${PROJECT_DIR}/npm/" "${STAGING_DIR}/data/npm/"
  else
    cp -a "${PROJECT_DIR}/npm/." "${STAGING_DIR}/data/npm/"
    rm -rf "${STAGING_DIR}/data/npm/data/logs"/*
  fi
fi

# PostgreSQL dump (consistent snapshot while container is running)
if docker ps --format '{{.Names}}' | grep -qx "${POSTGRES_CONTAINER}"; then
  log "Дамп PostgreSQL (${POSTGRES_DB})..."
  docker exec "${POSTGRES_CONTAINER}" pg_dump -U "${POSTGRES_USER}" --clean --if-exists "${POSTGRES_DB}" \
    > "${STAGING_DIR}/postgres.sql"
else
  log "Предупреждение: контейнер ${POSTGRES_CONTAINER} не запущен, дамп БД пропущен."
  : > "${STAGING_DIR}/postgres.sql"
fi

PUBLIC_IP="$(detect_public_ip)"
SUB_URI=""
WEB_DOMAIN=""
if docker ps --format '{{.Names}}' | grep -qx "${POSTGRES_CONTAINER}"; then
  SUB_URI="$(pg_setting subURI | tr -d '\r')"
  WEB_DOMAIN="$(pg_setting webDomain | tr -d '\r')"
fi

NPM_SQLITE="${PROJECT_DIR}/npm/data/database.sqlite"
PANEL_PORT="4443"
export CREATED_AT="$(date -Iseconds)"
export HOST_NAME="$(hostname)"
export PUBLIC_IP SUB_URI WEB_DOMAIN NPM_SQLITE PANEL_PORT PROJECT_DIR POSTGRES_CONTAINER POSTGRES_DB

python3 - "${STAGING_DIR}/manifest.json" <<'PY'
import json, os, sqlite3, sys
from urllib.parse import urlparse

manifest_path = sys.argv[1]
npm_domains = []
npm_db = os.environ.get("NPM_SQLITE", "")
if npm_db and os.path.isfile(npm_db):
    conn = sqlite3.connect(npm_db)
    try:
        rows = conn.execute(
            "SELECT domain_names FROM proxy_host WHERE COALESCE(is_deleted,0)=0 AND COALESCE(enabled,1)=1"
        ).fetchall()
    except sqlite3.Error:
        rows = []
    finally:
        conn.close()
    for (raw,) in rows:
        try:
            names = json.loads(raw or "[]")
        except json.JSONDecodeError:
            names = [raw]
        npm_domains.extend(str(n) for n in names if n)

sub_uri = os.environ.get("SUB_URI", "")
panel_domain = ""
parsed = urlparse(sub_uri)
if parsed.hostname:
    panel_domain = parsed.hostname
elif npm_domains:
    panel_domain = npm_domains[0]

payload = {
    "created_at": os.environ["CREATED_AT"],
    "hostname": os.environ["HOST_NAME"],
    "public_ip": os.environ.get("PUBLIC_IP", ""),
    "panel_domain": panel_domain,
    "panel_port": int(os.environ.get("PANEL_PORT") or 4443),
    "sub_uri": sub_uri,
    "web_domain": os.environ.get("WEB_DOMAIN", ""),
    "npm_domains": npm_domains,
    "project_dir": os.environ["PROJECT_DIR"],
    "postgres_container": os.environ["POSTGRES_CONTAINER"],
    "postgres_db": os.environ["POSTGRES_DB"],
    "components": ["docker-compose.yml", "db/", "cert/", "npm/", "postgres.sql"],
}
with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY

log "Манифест записан: IP=${PUBLIC_IP:-неизвестен}"

log "Архивирование в ${ARCHIVE_NAME}..."
tar -czf "${ARCHIVE_PATH}" -C "${STAGING_DIR}" .

SIZE="$(du -h "${ARCHIVE_PATH}" | awk '{print $1}')"
log "Готово: ${ARCHIVE_PATH} (${SIZE})"

# Keep last 10 backups
KEEP=10
mapfile -t OLD_BACKUPS < <(ls -1t "${BACKUP_DIR}"/vpn-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) || true)
if [ "${#OLD_BACKUPS[@]}" -gt 0 ]; then
  log "Удаление старых бэкапов (оставляем ${KEEP})..."
  rm -f "${OLD_BACKUPS[@]}"
fi

printf '\nСписок бэкапов:\n'
ls -lh "${BACKUP_DIR}"/vpn-backup-*.tar.gz 2>/dev/null || true
