#!/usr/bin/env bash
# Restore working configuration of the 3x-ui Docker stack from backup archive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_DIR="${PROJECT_DIR}/backups"

POSTGRES_CONTAINER="3xui_postgres"
POSTGRES_USER="xui"
POSTGRES_DB="xui"

AUTO_YES=false
ARCHIVE=""

usage() {
  cat <<EOF
Использование: $(basename "$0") [опции] <путь-к-архиву.tar.gz>

Восстанавливает рабочую конфигурацию проекта из бэкапа:
  - docker-compose.yml
  - db/, cert/, npm/
  - PostgreSQL (из postgres.sql)

Опции:
  -y, --yes     Не спрашивать подтверждение
  -h, --help    Показать справку

Примеры:
  $(basename "$0") backups/vpn-backup-20260712-120000.tar.gz
  $(basename "$0") -y /path/to/vpn-backup.tar.gz
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

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) AUTO_YES=true; shift ;;
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

# Resolve relative path from backups dir
if [ ! -f "${ARCHIVE}" ] && [ -f "${BACKUP_DIR}/${ARCHIVE}" ]; then
  ARCHIVE="${BACKUP_DIR}/${ARCHIVE}"
fi

[ -f "${ARCHIVE}" ] || die "Архив не найден: ${ARCHIVE}"

require_cmd docker
require_cmd tar

STAGING_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

log "Распаковка ${ARCHIVE}..."
tar -xzf "${ARCHIVE}" -C "${STAGING_DIR}"

[ -f "${STAGING_DIR}/docker-compose.yml" ] || die "Некорректный архив: нет docker-compose.yml"
[ -f "${STAGING_DIR}/manifest.json" ] && log "Манифест: $(cat "${STAGING_DIR}/manifest.json")"

confirm "Восстановление перезапишет текущую конфигурацию. Продолжить?" || die "Отменено."

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

  log "Восстановление дампа БД..."
  docker exec -i "${POSTGRES_CONTAINER}" psql -U "${POSTGRES_USER}" -d postgres \
    < "${STAGING_DIR}/postgres.sql"
else
  log "Предупреждение: postgres.sql пуст, БД не восстанавливается."
fi

log "Запуск всех сервисов..."
docker compose up -d --build

log "Готово. Проверка контейнеров:"
docker compose ps

printf '\nВосстановление завершено из: %s\n' "${ARCHIVE}"
