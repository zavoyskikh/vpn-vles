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

require_cmd docker
require_cmd tar
require_cmd gzip

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

# Manifest
cat > "${STAGING_DIR}/manifest.json" <<EOF
{
  "created_at": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "project_dir": "${PROJECT_DIR}",
  "postgres_container": "${POSTGRES_CONTAINER}",
  "postgres_db": "${POSTGRES_DB}",
  "components": [
    "docker-compose.yml",
    "db/",
    "cert/",
    "npm/",
    "postgres.sql"
  ]
}
EOF

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
