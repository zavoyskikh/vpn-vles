# vpn-vles

Docker-развёртывание [3x-ui](https://github.com/MHSanaei/3x-ui) **v3.6.0** (панель управления Xray, xray-core **v26.7.28**) с PostgreSQL и Nginx Proxy Manager.

Образ панели: `ghcr.io/mhsanaei/3x-ui:v3.6.0`

## Архитектура

```
                    ┌─────────────────────────────────────┐
  Клиенты VPN ─────►│  3xui_app (Xray)          :443    │
                    │  панель (внутр.)          :2053    │
                    │  подписки (внутр.)        :2096    │
                    └──────────────┬──────────────────────┘
                                   │
                    ┌──────────────▼──────────────────────┐
  Браузер ─────────►│  nginx-proxy-manager              │
  :80               │  :80   — HTTP / Let's Encrypt     │
  :4443             │  :4443 — HTTPS (панель, /sub)     │
  :81               │  :81   — админка NPM              │
                    └──────────────┬──────────────────────┘
                                   │
                    ┌──────────────▼──────────────────────┐
                    │  postgres (БД панели)     :5432    │
                    └─────────────────────────────────────┘
```

## Порты

| Порт | Сервис | Назначение |
|------|--------|------------|
| `443` | 3x-ui / Xray | VPN-трафик (напрямую) |
| `80` | NPM | HTTP, Let's Encrypt challenge |
| `4443` | NPM | HTTPS — панель 3x-ui и подписки `/sub` |
| `81` | NPM | Админ-панель Nginx Proxy Manager |

## Быстрый старт

```bash
git clone https://github.com/zavoyskikh/vpn-vles.git
cd vpn-vles

docker compose up -d --build
```

Панель 3x-ui доступна через NPM: `https://<домен>:4443`

Админка NPM: `http://<сервер>:81`

## Структура данных

| Каталог | Описание |
|---------|----------|
| `db/` | Данные панели (volume `/etc/x-ui/`) |
| `cert/` | Сертификаты панели |
| `pgdata/` | Данные PostgreSQL |
| `npm/data/` | Конфигурация NPM |
| `npm/letsencrypt/` | Сертификаты Let's Encrypt |
| `backups/` | Архивы бэкапов |

Эти каталоги не входят в git — создаются при первом запуске.

## Бэкап и восстановление

```bash
# Создать бэкап (хранятся последние 10)
./scripts/backup.sh

# Восстановить из архива на том же сервере
./scripts/restore.sh backups/vpn-backup-YYYYMMDD-HHMMSS.tar.gz

# Без подтверждения
./scripts/restore.sh -y backups/vpn-backup-YYYYMMDD-HHMMSS.tar.gz

# Перенос на другой сервер (IP/sslip.io подставятся сами)
./scripts/restore.sh -y backups/vpn-backup-YYYYMMDD-HHMMSS.tar.gz

# Явно указать новый IP или домен
./scripts/restore.sh --public-ip 203.0.113.10 backups/vpn-backup.tar.gz
./scripts/restore.sh --domain vpn.example.com backups/vpn-backup.tar.gz

# Домен не менять (только A-запись DNS), заменить IP в адресах клиентов
./scripts/restore.sh --keep-domain backups/vpn-backup.tar.gz
```

Бэкап включает: `docker-compose.yml`, `db/`, `cert/`, `npm/`, дамп PostgreSQL и манифест с публичным IP/доменом.

При восстановлении на другом IP скрипт обновляет `subURI`, домены Nginx Proxy Manager и пытается выпустить новый Let's Encrypt сертификат. UUID клиентов и Reality (SNI/ключи) не меняются — клиентам нужно только обновить адрес сервера или URL подписки.

### Автоматический бэкап (cron)

```bash
0 3 * * * /root/3x-ui/scripts/backup.sh >> /var/log/vpn-backup.log 2>&1
```

## Fail2ban (лимит IP)

Встроен в образ 3x-ui, включён по умолчанию (`XUI_ENABLE_FAIL2BAN=true`).

1. В панели: **Xray Configs** → `log` → **Access log** → `./access.log` → сохранить → перезапустить Xray
2. У клиентов задать **Лимит IP** > 0

Проверка:

```bash
docker exec 3xui_app fail2ban-client status 3x-ipl
docker exec 3xui_app tail -f /var/log/x-ui/3xipl-banned.log
```

Подробнее: [документация 3x-ui — Fail2ban](https://github.com/MHSanaei/3x-ui/wiki/Configuration#setting-fail2ban)

## Nginx Proxy Manager

Текущая схема:

- Домен проксируется на `3xui_app:2053` (панель) и `3xui_app:2096` (`/sub`)
- HTTPS наружу — порт `4443` (стандартный 443 занят Xray)
- Порт `80` нужен для обновления сертификатов Let's Encrypt

Рекомендуется включить **Force SSL** в настройках Proxy Host в NPM.

## Переменные окружения

| Переменная | Значение | Описание |
|------------|----------|----------|
| `XUI_DB_TYPE` | `postgres` | Бэкенд БД |
| `XUI_DB_DSN` | `postgres://xui:xui@postgres:5432/xui?sslmode=disable` | Подключение к PostgreSQL |
| `XUI_ENABLE_FAIL2BAN` | `true` | Лимит IP через fail2ban |

Для `cap_add: NET_ADMIN` и `NET_RAW` — без них fail2ban не применяет баны через iptables.

## Полезные команды

```bash
# Статус
docker compose ps

# Логи
docker compose logs -f 3xui
docker compose logs -f nginx-proxy-manager

# Пересборка после обновления кода
docker compose up -d --build

# Остановка
docker compose down
```

## Обновление

```bash
git pull
docker compose up -d --build
```

Перед обновлением рекомендуется сделать бэкап: `./scripts/backup.sh`

## Лицензия

Основа — [3x-ui](https://github.com/MHSanaei/3x-ui) (GPL-3.0). См. [LICENSE](LICENSE).
