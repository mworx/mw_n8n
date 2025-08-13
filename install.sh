#!/usr/bin/env bash
# MEDIA WORKS — Automated Deployment (Supabase + n8n + Traefik)
# ЛОГ УСТАНОВКИ: /tmp/mediaworks_install.log
set -euo pipefail
exec > >(tee -a /tmp/mediaworks_install.log) 2>&1

# ---------- Цвета и баннер ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
info() { echo -e "${BLUE}[ INFO ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ WARN ]${NC} $*"; }
err()  { echo -e "${RED}[ ERROR ]${NC} $*"; exit 1; }

banner() {
cat <<'BANNER'
 __  _____________  _______       _       ______  ____  __ _______
/  |/  / ____/ __ \/  _/   |     | |     / / __ \/ __ \/ //_/ ___/
 / /|_/ / __/ / / / // // /| |    | | /| / / / / / /_/ / ,<  \__ \
/ /  / / /___/ /_/ // // ___ |    | |/ |/ / /_/ / _, _/ /| |___/ /
/_/  /_/_____/_____/___/_/  |_|    |__/|__/\____/_/ |_/_/ |_/____/   m e d i a   w o r k s

MEDIA WORKS — One-line Installer (Supabase + n8n + Traefik)
BANNER
}
banner

# ---------- Проверки окружения ----------
[ "$(id -u)" -eq 0 ] || err "Запустите скрипт от root (sudo)."

if [ -f /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ok "Обнаружена ОС: ${NAME}";;
    *) err "Поддерживаются только Ubuntu/Debian. Найдено: ${NAME:-unknown}";;
  esac
else
  err "Не найден /etc/os-release — не могу определить дистрибутив."
fi

retry() {
  local tries="${1:-3}"; shift
  local n=1
  until "$@"; do
    if [ $n -ge "$tries" ]; then return 1; fi
    warn "Попытка $n из $tries не удалась. Повтор через 5с..."
    n=$((n+1)); sleep 5
  done
}

gen_alnum() { # length
  local len="${1:-32}"
  ( set +o pipefail; tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len" ) || true
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt_hs256() { # jwt_hs256 <secret> <json-payload>
  local secret="$1" payload="$2"
  local header='{"alg":"HS256","typ":"JWT"}'
  local h b s
  h=$(printf '%s' "$header" | b64url)
  b=$(printf '%s' "$payload" | b64url)
  s=$(printf '%s' "${h}.${b}" | openssl dgst -binary -sha256 -hmac "$secret" | b64url)
  printf '%s.%s.%s' "$h" "$b" "$s"
}

# ---------- Сбор параметров ----------
echo
info "Введите параметры установки (обязательные помечены *)."
read -rp " * Имя проекта (латиница, каталог в /root): " PROJECT_NAME
[[ -n "$PROJECT_NAME" && "$PROJECT_NAME" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || err "Некорректное имя проекта."
PROJECT_DIR="/root/${PROJECT_NAME}"

read -rp " * Основной домен (example.com): " ROOT_DOMAIN
[ -n "${ROOT_DOMAIN:-}" ] || err "Основной домен обязателен."

DEF_N8N="n8n.${ROOT_DOMAIN}"
read -rp "   Поддомен n8n [${DEF_N8N}]: " N8N_HOST
N8N_HOST="${N8N_HOST:-$DEF_N8N}"

DEF_STUDIO="studio.${ROOT_DOMAIN}"
read -rp "   Поддомен Supabase Studio [${DEF_STUDIO}]: " STUDIO_HOST
STUDIO_HOST="${STUDIO_HOST:-$DEF_STUDIO}"

DEF_API="api.${ROOT_DOMAIN}"
read -rp "   Поддомен Supabase API (Kong) [${DEF_API}]: " API_HOST
API_HOST="${API_HOST:-$DEF_API}"

read -rp " * Email для Let's Encrypt (ACME): " ACME_EMAIL
[ -n "${ACME_EMAIL:-}" ] || err "Email обязателен."

read -rp "   Настроить SMTP для Supabase? (y/N): " WANT_SMTP
WANT_SMTP="${WANT_SMTP:-N}"
if [[ "$WANT_SMTP" =~ ^[Yy]$ ]]; then
  read -rp "   SMTP Host: " SMTP_HOST
  read -rp "   SMTP Port (обычно 587/465): " SMTP_PORT
  read -rp "   SMTP User: " SMTP_USER
  read -rsp "   SMTP Password: " SMTP_PASS; echo
  read -rp "   SMTP Sender Name (напр. 'My App'): " SMTP_SENDER_NAME
  read -rp "   SMTP Admin Email: " SMTP_ADMIN_EMAIL
else
  SMTP_HOST=""; SMTP_PORT=""; SMTP_USER=""; SMTP_PASS=""
  SMTP_SENDER_NAME=""; SMTP_ADMIN_EMAIL=""
fi

# ---------- Пакеты и Docker ----------
info "Устанавливаем зависимости..."
retry 3 apt-get update -y || err "apt-get update не удалось."
retry 3 apt-get install -y ca-certificates curl gnupg lsb-release git wget openssl || err "Не удалось установить базовые пакеты."

if ! command -v docker >/dev/null 2>&1; then
  info "Устанавливаем Docker..."
  retry 3 sh -c "curl -fsSL https://get.docker.com | sh" || err "Установка Docker не удалась."
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker  >/dev/null 2>&1 || true
fi
ok "Docker установлен."

if ! docker compose version >/dev/null 2>&1; then
  info "Устанавливаем docker compose-plugin..."
  retry 3 apt-get install -y docker-compose-plugin || warn "Не удалось поставить docker-compose-plugin из apt."
fi
docker compose version >/dev/null 2>&1 || err "docker compose недоступен."

# ---------- Каталоги ----------
info "Готовим структуру каталогов..."
mkdir -p "/root/supabase"
mkdir -p "${PROJECT_DIR}/"{configs/traefik,volumes/traefik,volumes/n8n,volumes/postgres_n8n,volumes/logs,volumes/db,volumes/pooler,volumes/api,scripts,backups}
touch "${PROJECT_DIR}/volumes/traefik/acme.json"
chmod 600 "${PROJECT_DIR}/volumes/traefik/acme.json"

# ---------- Supabase (repo) ----------
if [ ! -d "/root/supabase/.git" ]; then
  info "Клонируем Supabase (self-hosted) репозиторий..."
  git clone --depth=1 https://github.com/supabase/supabase.git /root/supabase || err "Клонирование supabase не удалось."
else
  info "Обновляем Supabase репозиторий..."
  (cd /root/supabase && git fetch --depth 1 origin && git reset --hard origin/HEAD) || warn "Не удалось обновить supabase, продолжим с текущей копией."
fi

# Копируем полный compose Supabase (НЕ МОДИФИЦИРУЕМ)
cp /root/supabase/docker/docker-compose.yml "${PROJECT_DIR}/compose.supabase.yml"
# Копируем необходимые volume-заготовки
rm -rf "${PROJECT_DIR}/volumes/logs" "${PROJECT_DIR}/volumes/db" "${PROJECT_DIR}/volumes/pooler" "${PROJECT_DIR}/volumes/api"
cp -a /root/supabase/docker/volumes/logs   "${PROJECT_DIR}/volumes/"
cp -a /root/supabase/docker/volumes/db     "${PROJECT_DIR}/volumes/"
cp -a /root/supabase/docker/volumes/pooler "${PROJECT_DIR}/volumes/"
cp -a /root/supabase/docker/volumes/api    "${PROJECT_DIR}/volumes/"

# ---------- Секреты и ключи ----------
info "Генерируем пароли и ключи..."
POSTGRES_PASSWORD="$(gen_alnum 32)"    # для Supabase DB (postgres)
JWT_SECRET="$(gen_alnum 40)"           # общий секрет Supabase
now_epoch=$(date +%s)
exp_epoch=$(( now_epoch + 20*365*24*3600 )) # ~20 лет
ANON_PAYLOAD=$(printf '{"role":"anon","iss":"supabase","iat":%d,"exp":%d}' "$now_epoch" "$exp_epoch")
SERVICE_PAYLOAD=$(printf '{"role":"service_role","iss":"supabase","iat":%d,"exp":%d}' "$now_epoch" "$exp_epoch")
ANON_KEY="$(jwt_hs256 "$JWT_SECRET" "$ANON_PAYLOAD")"
SERVICE_ROLE_KEY="$(jwt_hs256 "$JWT_SECRET" "$SERVICE_PAYLOAD")"

DASHBOARD_USERNAME="admin"
DASHBOARD_PASSWORD="$(gen_alnum 24)"
N8N_ENCRYPTION_KEY="$(gen_alnum 32)"
REDIS_PASSWORD="$(gen_alnum 24)"
N8N_PG_PASSWORD="$(gen_alnum 32)"

# Дополнительные ключи/дефолты для Supabase (чтобы не было WARN и падений)
SECRET_KEY_BASE="$(gen_alnum 64)"
VAULT_ENC_KEY="$(gen_alnum 64)"
LOGFLARE_PUBLIC_ACCESS_TOKEN="$(gen_alnum 48)"
LOGFLARE_PRIVATE_ACCESS_TOKEN="$(gen_alnum 48)"

POOLER_PROXY_PORT_TRANSACTION="6543"
POOLER_DEFAULT_POOL_SIZE="20"
POOLER_MAX_CLIENT_CONN="100"
POOLER_TENANT_ID="${PROJECT_NAME}"
POOLER_DB_POOL_SIZE="5"

IMGPROXY_ENABLE_WEBP_DETECTION="true"
PGRST_DB_SCHEMAS="public"
JWT_EXPIRY="630720000" # ~20 лет

STUDIO_DEFAULT_ORGANIZATION="MEDIA WORKS"
STUDIO_DEFAULT_PROJECT="${PROJECT_NAME}"

FUNCTIONS_VERIFY_JWT="false"
ADDITIONAL_REDIRECT_URLS=""
DISABLE_SIGNUP="false"
ENABLE_EMAIL_SIGNUP="false"
ENABLE_ANONYMOUS_USERS="true"
ENABLE_EMAIL_AUTOCONFIRM="false"
ENABLE_PHONE_SIGNUP="false"
ENABLE_PHONE_AUTOCONFIRM="false"
MAILER_URLPATHS_CONFIRMATION="/auth/v1/verify"
MAILER_URLPATHS_INVITE="/auth/v1/verify"
MAILER_URLPATHS_RECOVERY="/auth/v1/verify"
MAILER_URLPATHS_EMAIL_CHANGE="/auth/v1/verify"

# Если пользователь включил SMTP — скорректируем флаги
if [[ "${WANT_SMTP}" =~ ^[Yy]$ ]]; then
  ENABLE_EMAIL_SIGNUP="true"
  ENABLE_ANONYMOUS_USERS="false"
  ENABLE_EMAIL_AUTOCONFIRM="true"
fi

# Где лежит docker.sock (нужно Supabase compose, иначе invalid spec)
DOCKER_SOCKET_LOCATION="/var/run/docker.sock"

# ---------- .env ----------
info "Формируем .env..."
cat > "${PROJECT_DIR}/.env" <<EOF
# ===== MEDIA WORKS generated .env (${PROJECT_NAME}) =====
# Домены
ROOT_DOMAIN=${ROOT_DOMAIN}
N8N_HOST=${N8N_HOST}
STUDIO_HOST=${STUDIO_HOST}
API_HOST=${API_HOST}
ACME_EMAIL=${ACME_EMAIL}

# Supabase core
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=postgres
POSTGRES_HOST=db
POSTGRES_PORT=5432

JWT_SECRET=${JWT_SECRET}
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
JWT_EXPIRY=${JWT_EXPIRY}

DASHBOARD_USERNAME=${DASHBOARD_USERNAME}
DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}

SUPABASE_PUBLIC_URL=https://${API_HOST}
SITE_URL=https://${STUDIO_HOST}
API_EXTERNAL_URL=https://${API_HOST}
KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443

# Vector / Docker socket (для compose.supabase.yml)
DOCKER_SOCKET_LOCATION=${DOCKER_SOCKET_LOCATION}
IMGPROXY_ENABLE_WEBP_DETECTION=${IMGPROXY_ENABLE_WEBP_DETECTION}
PGRST_DB_SCHEMAS=${PGRST_DB_SCHEMAS}

# Studio defaults
STUDIO_DEFAULT_ORGANIZATION=${STUDIO_DEFAULT_ORGANIZATION}
STUDIO_DEFAULT_PROJECT=${STUDIO_DEFAULT_PROJECT}

# Auth toggles
ENABLE_EMAIL_SIGNUP=${ENABLE_EMAIL_SIGNUP}
ENABLE_ANONYMOUS_USERS=${ENABLE_ANONYMOUS_USERS}
ENABLE_EMAIL_AUTOCONFIRM=${ENABLE_EMAIL_AUTOCONFIRM}
ENABLE_PHONE_SIGNUP=${ENABLE_PHONE_SIGNUP}
ENABLE_PHONE_AUTOCONFIRM=${ENABLE_PHONE_AUTOCONFIRM}
FUNCTIONS_VERIFY_JWT=${FUNCTIONS_VERIFY_JWT}
ADDITIONAL_REDIRECT_URLS=${ADDITIONAL_REDIRECT_URLS}
DISABLE_SIGNUP=${DISABLE_SIGNUP}
MAILER_URLPATHS_CONFIRMATION=${MAILER_URLPATHS_CONFIRMATION}
MAILER_URLPATHS_INVITE=${MAILER_URLPATHS_INVITE}
MAILER_URLPATHS_RECOVERY=${MAILER_URLPATHS_RECOVERY}
MAILER_URLPATHS_EMAIL_CHANGE=${MAILER_URLPATHS_EMAIL_CHANGE}

# Логи/секреты Supabase
SECRET_KEY_BASE=${SECRET_KEY_BASE}
VAULT_ENC_KEY=${VAULT_ENC_KEY}
LOGFLARE_PUBLIC_ACCESS_TOKEN=${LOGFLARE_PUBLIC_ACCESS_TOKEN}
LOGFLARE_PRIVATE_ACCESS_TOKEN=${LOGFLARE_PRIVATE_ACCESS_TOKEN}

# Supavisor Pooler
POOLER_PROXY_PORT_TRANSACTION=${POOLER_PROXY_PORT_TRANSACTION}
POOLER_DEFAULT_POOL_SIZE=${POOLER_DEFAULT_POOL_SIZE}
POOLER_MAX_CLIENT_CONN=${POOLER_MAX_CLIENT_CONN}
POOLER_TENANT_ID=${POOLER_TENANT_ID}
POOLER_DB_POOL_SIZE=${POOLER_DB_POOL_SIZE}

# n8n / Redis
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
REDIS_PASSWORD=${REDIS_PASSWORD}

# n8n DB (отдельный Postgres)
N8N_DB_HOST=postgres-n8n
N8N_DB_PORT=5432
N8N_DB_NAME=n8n
N8N_DB_USER=n8n
N8N_DB_PASSWORD=${N8N_PG_PASSWORD}

# SMTP (опционально)
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
SMTP_SENDER_NAME=${SMTP_SENDER_NAME}
SMTP_ADMIN_EMAIL=${SMTP_ADMIN_EMAIL}
EOF

# Санитация .env
sed -i 's/[[:space:]]*$//' "${PROJECT_DIR}/.env"
sed -i 's/\r$//' "${PROJECT_DIR}/.env"
grep -E '^[A-Z0-9_]+=' "${PROJECT_DIR}/.env" >/dev/null || err "Invalid .env format (нет KEY=VALUE)."

# ---------- Docker Compose (проектная часть, без middlewares) ----------
info "Создаём docker-compose.yml для Traefik + n8n + postgres-n8n + redis..."
cat > "${PROJECT_DIR}/docker-compose.yml" <<'EOF'
x-common: &common
  restart: unless-stopped
  logging:
    driver: "json-file"
    options: { max-size: "10m", max-file: "3" }

services:
  traefik:
    <<: *common
    image: traefik:2.11.9
    container_name: traefik
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.le.acme.email=${ACME_EMAIL}"
      - "--certificatesresolvers.le.acme.storage=/acme/acme.json"
      - "--certificatesresolvers.le.acme.httpchallenge.entrypoint=web"
      - "--api.dashboard=false"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./volumes/traefik/acme.json:/acme/acme.json
    healthcheck:
      test: ["CMD","wget","--spider","-q","http://localhost:80"]
      interval: 10s
      timeout: 5s
      retries: 6

  redis:
    <<: *common
    image: redis:7.4.0-alpine
    container_name: redis
    command: ["redis-server","--requirepass","${REDIS_PASSWORD}"]

  postgres-n8n:
    <<: *common
    image: postgres:16.4-alpine
    container_name: postgres-n8n
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${N8N_DB_PASSWORD}
      POSTGRES_DB: postgres
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 10
    volumes:
      - ./volumes/postgres_n8n:/var/lib/postgresql/data

  pg-init-n8n:
    image: postgres:16.4-alpine
    container_name: pg-init-n8n
    depends_on: [ postgres-n8n ]
    entrypoint: ["/bin/sh","-c"]
    command:
      - |
        until pg_isready -h postgres-n8n -U postgres; do sleep 1; done
        psql -h postgres-n8n -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
          "SELECT 'CREATE ROLE n8n LOGIN PASSWORD ''${N8N_DB_PASSWORD}'';' \
           WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='n8n') \gexec"
        psql -h postgres-n8n -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
          "SELECT 'CREATE DATABASE n8n OWNER n8n' \
           WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname=''n8n'') \gexec"
        psql -h postgres-n8n -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
          "GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;"
    environment:
      PGPASSWORD: ${N8N_DB_PASSWORD}

  n8n:
    <<: *common
    image: n8nio/n8n:latest
    container_name: n8n
    environment:
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=5678
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_SECURE_COOKIE=false
      - N8N_PROTOCOL=http
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${N8N_DB_HOST}
      - DB_POSTGRESDB_PORT=${N8N_DB_PORT}
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
    depends_on:
      - redis
      - pg-init-n8n
    healthcheck:
      test: ["CMD","wget","--spider","-q","http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n.entrypoints=web,websecure"
      - "traefik.http.routers.n8n.tls.certresolver=le"

  # Дополняем сервисы Supabase (определены в compose.supabase.yml) только лейблами для Traefik.
  kong:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.kong.rule=Host(`${API_HOST}`)"
      - "traefik.http.routers.kong.entrypoints=web,websecure"
      - "traefik.http.routers.kong.tls.certresolver=le"

  studio:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.studio.rule=Host(`${STUDIO_HOST}`)"
      - "traefik.http.routers.studio.entrypoints=web,websecure"
      - "traefik.http.routers.studio.tls.certresolver=le"
EOF

# ---------- manage.sh / backup.sh / update.sh ----------
info "Создаём служебные скрипты..."

cat > "${PROJECT_DIR}/scripts/manage.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Загружаем .env
set -a
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; *=*) key="${line%%=*}"; val="${line#*=}"
    if [[ "$val" =~ ^\".*\"$ ]]; then val="${val:1:${#val}-2}"
    elif [[ "$val" =~ ^\'.*\'$ ]]; then val="${val:1:${#val}-2}"; fi
    printf -v "$key" '%s' "$val"; export "$key";;
  esac
done < .env
set +a

docker compose -f compose.supabase.yml -f docker-compose.yml "${@:-up}" -d || {
  case "${1:-}" in
    up) exit 1;;
    down|ps|pull|restart) docker compose -f compose.supabase.yml -f docker-compose.yml "$@" ;;
    logs) shift || true; docker compose -f compose.supabase.yml -f docker-compose.yml logs -f --tail=200 "$@" ;;
    *) echo "Usage: $0 {up|down|ps|logs|restart|pull}" ; exit 1;;
  esac
}
EOF
chmod +x "${PROJECT_DIR}/scripts/manage.sh"

cat > "${PROJECT_DIR}/scripts/backup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; *=*) export "$line" ;; esac
done < .env
set +a

TS=$(date +%Y%m%d_%H%M%S)
mkdir -p backups

echo "Dumping n8n database..."
DB_CONT="postgres-n8n"
docker exec -e PGPASSWORD="${N8N_DB_PASSWORD}" "${DB_CONT}" pg_dump -U postgres -d "${N8N_DB_NAME}" -Fc -f "/tmp/n8n_${TS}.dump" || {
  echo "n8n DB может отсутствовать; пробую postgres..." >&2
  docker exec -e PGPASSWORD="${N8N_DB_PASSWORD}" "${DB_CONT}" pg_dump -U postgres -d postgres -Fc -f "/tmp/n8n_${TS}.dump"
}
docker cp "${DB_CONT}:/tmp/n8n_${TS}.dump" "backups/n8n_${TS}.dump"
docker exec "${DB_CONT}" rm -f "/tmp/n8n_${TS}.dump"

if docker ps --format '{{.Names}}' | grep -q '^supabase-db$'; then
  echo "Dumping Supabase database..."
  docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" supabase-db pg_dump -U postgres -d "${POSTGRES_DB}" -Fc -f "/tmp/supabase_${TS}.dump"
  docker cp "supabase-db:/tmp/supabase_${TS}.dump" "backups/supabase_${TS}.dump"
  docker exec "supabase-db" rm -f "/tmp/supabase_${TS}.dump"
fi

echo "Готово. Дампы в ./backups/"
EOF
chmod +x "${PROJECT_DIR}/scripts/backup.sh"

cat > "${PROJECT_DIR}/scripts/update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/manage.sh pull
./scripts/manage.sh up
sleep 2
EOF
chmod +x "${PROJECT_DIR}/scripts/update.sh"

# ---------- Credentials ----------
info "Записываем credentials..."
cat > "${PROJECT_DIR}/credentials.txt" <<EOF
==== MEDIA WORKS — Credentials (${PROJECT_NAME}) ====

Domains:
  n8n:     https://${N8N_HOST}
  studio:  https://${STUDIO_HOST}
  api:     https://${API_HOST}

Supabase:
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
  JWT_SECRET: ${JWT_SECRET}
  ANON_KEY: ${ANON_KEY}
  SERVICE_ROLE_KEY: ${SERVICE_ROLE_KEY}
  Studio Dashboard: ${DASHBOARD_USERNAME} / ${DASHBOARD_PASSWORD}

n8n Postgres:
  HOST: postgres-n8n
  PORT: 5432
  DB:   n8n
  USER: n8n
  PASS: ${N8N_PG_PASSWORD}

Redis:
  PASSWORD: ${REDIS_PASSWORD}

ACME email: ${ACME_EMAIL}

SMTP:
  ENABLED: $([[ "${WANT_SMTP}" =~ ^[Yy]$ ]] && echo yes || echo no)
  HOST: ${SMTP_HOST}
  PORT: ${SMTP_PORT}
  USER: ${SMTP_USER}
  PASS: ${SMTP_PASS}
  SENDER_NAME: ${SMTP_SENDER_NAME}
  ADMIN_EMAIL: ${SMTP_ADMIN_EMAIL}
EOF
chmod 600 "${PROJECT_DIR}/credentials.txt"

# ---------- Запуск ----------
info "Запускаем стек (Supabase полный + n8n инфраструктура)..."
pushd "${PROJECT_DIR}" >/dev/null
./scripts/manage.sh up

# ---------- Упрощённые health-checks ----------
info "Проверяем статусы контейнеров..."
sleep 5
docker compose -f compose.supabase.yml -f docker-compose.yml ps || true

check_ok=1
docker exec postgres-n8n pg_isready -U postgres >/dev/null 2>&1 || { warn "postgres-n8n ещё не готов"; check_ok=0; }
docker exec supabase-db pg_isready -U postgres >/dev/null 2>&1 || { warn "supabase-db ещё не готов"; check_ok=0; }

docker exec n8n wget --spider -q http://localhost:5678/healthz || { warn "n8n healthz не отвечает"; check_ok=0; }
docker exec supabase-kong wget --spider -q http://localhost:8000/ || { warn "Kong (API) не отвечает на 8000"; check_ok=0; }
docker exec traefik wget --spider -q http://localhost:80 || { warn "Traefik HTTP не отвечает"; check_ok=0; }

popd >/dev/null

[ "$check_ok" -eq 1 ] && ok "Базовые проверки пройдены." || warn "Некоторые проверки не пройдены. Проверьте 'docker compose ps' и логи."

# ---------- Итог ----------
echo
echo "==============================================="
echo -e "✅ ${GREEN}Установка завершена${NC}"
echo "🚀 MEDIA WORKS — Supabase (full) + n8n + Redis + Traefik"
echo "==============================================="
echo
echo "Проект:    ${PROJECT_DIR}"
echo "Управление: ${PROJECT_DIR}/scripts/manage.sh {up|down|ps|logs|restart|pull}"
echo "Бэкапы:     ${PROJECT_DIR}/scripts/backup.sh"
echo "Обновление: ${PROJECT_DIR}/scripts/update.sh"
echo
echo "Доступы и ключи: ${PROJECT_DIR}/credentials.txt  (chmod 600)"
echo
echo "Проверьте DNS на домены:"
echo "  - ${N8N_HOST}"
echo "  - ${STUDIO_HOST}"
echo "  - ${API_HOST}"
echo "И откройте порты 80/443 в файерволе."
echo
echo "Лог установки: /tmp/mediaworks_install.log"
