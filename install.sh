#!/usr/bin/env bash
set -euo pipefail

# ================================
# MEDIA WORKS — Deployment Master
# n8n + Supabase + PostgreSQL + Traefik
# ================================

# ---------- Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
info() { echo -e "${BLUE}[ INFO ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ WARN ]${NC} $*"; }
err()  { echo -e "${RED}[ ERROR ]${NC} $*"; exit 1; }

banner() {
cat <<'BANNER'
 __  _____________  _______       _       ______  ____  __ _______
/  |/  / ____/ __ \/  _/   |     | |     / / __ \/ __ \/ //_/ ___/
 / /|_/ / __/ / / / // // /| |     | | /| / / / / / /_/ / ,<  \__ \
/ /  / / /___/ /_/ // // ___ |     | |/ |/ / /_/ / _, _/ /| |___/ /
_/  /_/_____/_____/___/_/  |_|     |__/|__/\____/_/ |_/_/ |_/____/  m e d i a   w o r k s

MEDIA WORKS — Automated Deployment Stack (Supabase + n8n + Traefik)
BANNER
}
banner

# ---------- Root / OS checks ----------
[ "$(id -u)" -eq 0 ] || err "Запустите скрипт от root (sudo)."

if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-}"; OS_NAME="${NAME:-}"
else
  err "Не удалось определить дистрибутив (нет /etc/os-release)."
fi

case "$OS_ID" in
  ubuntu|debian) ok "Обнаружена ОС: $OS_NAME" ;;
  *) err "Поддерживаются только Debian/Ubuntu. Обнаружено: $OS_NAME" ;;
esac

# ---------- Helpers ----------
retry_operation() {
  local max_attempts=3 delay=5 attempt=1
  while [ $attempt -le $max_attempts ]; do
    if "$@"; then return 0; fi
    warn "Попытка $attempt из $max_attempts не удалась. Повтор через ${delay}s..."
    sleep "$delay"; attempt=$((attempt+1))
  done
  return 1
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

wait_for_postgres() { # container
  local svc="$1" max=30 i=1
  while [ $i -le $max ]; do
    if docker exec "$svc" pg_isready -U postgres >/dev/null 2>&1; then return 0; fi
    sleep 2; i=$((i+1))
  done
  return 1
}

health_check_all_services() {
  local failed=()
  local -a wait_list=()

  # Универсальная функция ожидания Docker Health=healthy
  wait_healthy() {
    local name="$1" tries=60
    while [ $tries -gt 0 ]; do
      local st
      st="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || true)"
      if [ "$st" = "healthy" ] || [ "$st" = "running" ]; then
        return 0
      fi
      sleep 2
      tries=$((tries-1))
    done
    return 1
  }

  # --- n8n ---
  if ! wait_healthy n8n; then
    # Доп.проверка «изнутри»
    if ! docker exec n8n sh -c 'wget --spider -q http://localhost:5678/healthz' >/dev/null 2>&1; then
      failed+=("n8n")
    fi
  fi

  if [ "${INSTALLATION_MODE}" = "light" ]; then
    # --- PostgreSQL (light) ---
    if ! wait_healthy postgres; then
      failed+=("PostgreSQL")
    fi
  else
    # --- Supabase DB ---
    if ! wait_healthy supabase-db; then
      failed+=("Supabase PostgreSQL")
    fi

    # --- Supabase REST (PostgREST) ---
    if ! wait_healthy supabase-rest; then
      # внутренняя проверка
      if ! docker exec supabase-rest sh -c 'wget --spider -q http://localhost:3000/ready' >/dev/null 2>&1; then
        failed+=("Supabase REST")
      fi
    fi

    # --- Supabase Auth (GoTrue) ---
    if ! wait_healthy supabase-auth; then
      if ! docker exec supabase-auth sh -c 'wget --spider -q http://localhost:9999/health' >/dev/null 2>&1; then
        failed+=("Supabase Auth")
      fi
    fi

    # --- Supabase Kong ---
    # У upstream нет встроенного healthcheck; проверим, что HTTP слушает/отдаёт что-то
    if ! docker exec supabase-kong sh -c 'wget --spider -q http://localhost:8000/ || wget --spider -q http://localhost:8000/health || wget --spider -q http://localhost:8000/status' >/dev/null 2>&1; then
      failed+=("Supabase Kong")
    fi
  fi

  # --- Traefik (теперь с ping и healthcheck) ---
  if ! wait_healthy traefik; then
    # резервная проверка ping’а с хоста
    if ! curl -sf "http://localhost:8080/ping" >/dev/null 2>&1; then
      failed+=("Traefik")
    fi
  fi

  if [ ${#failed[@]} -gt 0 ]; then
    err "Следующие сервисы не прошли health check: ${failed[*]}"
  fi
  ok "Все сервисы работают корректно ✓"
}


# ---------- Ask inputs ----------
echo
info "Введите параметры установки (обязательные помечены *):"
read -rp " * Имя проекта (каталог в /root): " PROJECT_NAME
[ -n "${PROJECT_NAME:-}" ] || err "Имя проекта обязательно."
# уберём возможный \r из ввода
PROJECT_NAME="$(printf '%s' "$PROJECT_NAME" | tr -d '\r')"
PROJECT_DIR="/root/${PROJECT_NAME}"


read -rp " * Основной домен (example.com): " ROOT_DOMAIN
[ -n "${ROOT_DOMAIN:-}" ] || err "Основной домен обязателен."

DEFAULT_N8N_SUB="n8n.${ROOT_DOMAIN}"
read -rp " * Поддомен для n8n [${DEFAULT_N8N_SUB}]: " N8N_HOST
N8N_HOST="${N8N_HOST:-$DEFAULT_N8N_SUB}"

DEF_STUDIO="studio.${ROOT_DOMAIN}"
read -rp "   Поддомен Supabase Studio [${DEF_STUDIO}]: " STUDIO_HOST
STUDIO_HOST="${STUDIO_HOST:-$DEF_STUDIO}"

DEF_API="api.${ROOT_DOMAIN}"
read -rp "   Поддомен API (Kong) [${DEF_API}]: " API_HOST
API_HOST="${API_HOST:-$DEF_API}"

read -rp " * Email для Let's Encrypt: " ACME_EMAIL
[ -n "${ACME_EMAIL:-}" ] || err "Email обязателен для ACME."

read -rp "Установить и настроить SMTP параметры для Supabase? (y/N): " WANT_SMTP
WANT_SMTP="${WANT_SMTP:-N}"
if [[ "$WANT_SMTP" =~ ^[Yy]$ ]]; then
  read -rp " SMTP Host: " SMTP_HOST
  read -rp " SMTP Port (обычно 587/465): " SMTP_PORT
  read -rp " SMTP User: " SMTP_USER
  read -rsp " SMTP Password: " SMTP_PASS; echo
  read -rp " SMTP Sender Name (например, 'My App'): " SMTP_SENDER_NAME
  read -rp " SMTP Admin Email: " SMTP_ADMIN_EMAIL
else
  SMTP_HOST=""; SMTP_PORT=""; SMTP_USER=""; SMTP_PASS=""
  SMTP_SENDER_NAME=""; SMTP_ADMIN_EMAIL=""
fi

echo
info "Выберите режим установки:"
echo "  1) FULL — Supabase(всё) + n8n main+worker + Redis + Traefik"
echo "  2) STANDARD — Supabase(всё) + n8n (single) + Traefik"
echo "  3) RAG — Supabase (vector, studio, kong, rest, meta, pooler, auth, db) + n8n + Traefik"
echo "  4) LIGHT — n8n + PostgreSQL + Traefik (без Supabase)"
read -rp "Выбор [1-4]: " MODE_SEL
case "${MODE_SEL:-}" in
  1) INSTALLATION_MODE="full" ;;
  2) INSTALLATION_MODE="standard" ;;
  3) INSTALLATION_MODE="rag" ;;
  4) INSTALLATION_MODE="light" ;;
  *) err "Неверный выбор режима." ;;
esac
ok "Режим: ${INSTALLATION_MODE^^}"

# ---------- Install dependencies ----------
info "Устанавливаем зависимости (curl, git, docker, docker compose)..."
retry_operation apt-get update -y || err "apt-get update не удалось."
retry_operation apt-get install -y ca-certificates curl gnupg lsb-release git wget openssl || err "Не удалось установить базовые пакеты."

if ! command -v docker >/dev/null 2>&1; then
  info "Устанавливаем Docker (официальный скрипт)..."
  retry_operation sh -c "curl -fsSL https://get.docker.com | sh" || err "Установка Docker не удалась."
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker  >/dev/null 2>&1 || true
fi
ok "Docker установлен."

if ! docker compose version >/dev/null 2>&1; then
  info "Устанавливаем docker compose-plugin..."
  retry_operation apt-get install -y docker-compose-plugin || warn "Не удалось поставить docker-compose-plugin из apt."
fi
docker compose version >/dev/null 2>&1 || err "docker compose недоступен."

# ---------- Prepare directories ----------
info "Готовим структуру каталогов..."
mkdir -p "/root/supabase"
mkdir -p "${PROJECT_DIR}/"{configs/traefik/dynamic,configs/supabase,volumes/traefik,volumes/postgres,volumes/n8n,volumes/supabase,volumes/db,volumes/logs,volumes/pooler,data,logs,scripts}
touch "${PROJECT_DIR}/volumes/traefik/acme.json"
chmod 600 "${PROJECT_DIR}/volumes/traefik/acme.json"

# ---------- Clone Supabase (once/update) ----------
if [ ! -d "/root/supabase/.git" ]; then
  info "Клонируем Supabase (self-hosted) репозиторий..."
  git clone --depth=1 https://github.com/supabase/supabase.git /root/supabase || err "Клонирование supabase не удалось."
else
  info "Supabase репозиторий уже есть, обновляем..."
  (cd /root/supabase && git fetch --depth 1 origin && git reset --hard origin/HEAD) || warn "Не удалось обновить supabase, продолжим с текущей копией."
fi

# ---------- Generate secrets ----------
info "Генерируем пароли и ключи..."
POSTGRES_PASSWORD="$(gen_alnum 32)"
N8N_ENCRYPTION_KEY="$(gen_alnum 32)"
REDIS_PASSWORD="$(gen_alnum 24)"
DASHBOARD_USERNAME="admin"
DASHBOARD_PASSWORD="$(gen_alnum 24)"
JWT_SECRET="$(gen_alnum 40)"

now_epoch=$(date +%s)
exp_epoch=$(( now_epoch + 20*365*24*3600 )) # ~20 лет
ANON_PAYLOAD=$(printf '{"role":"anon","iss":"supabase","iat":%d,"exp":%d}' "$now_epoch" "$exp_epoch")
SERVICE_PAYLOAD=$(printf '{"role":"service_role","iss":"supabase","iat":%d,"exp":%d}' "$now_epoch" "$exp_epoch")
ANON_KEY="$(jwt_hs256 "$JWT_SECRET" "$ANON_PAYLOAD")"
SERVICE_ROLE_KEY="$(jwt_hs256 "$JWT_SECRET" "$SERVICE_PAYLOAD")"
ok "Секреты сгенерированы."

# n8n DB host/password должны быть определены ДО сборки .env (из-за set -u)
if [ "$INSTALLATION_MODE" = "light" ]; then
  N8N_DB_HOST="postgres"
else
  N8N_DB_HOST="supabase-db"
fi
N8N_DB_PASSWORD="$(gen_alnum 24)"

# ---------- Build .env (STRICT KEY=VALUE) ----------
info "Готовим .env..."
# ЧИСТЫЙ .env без наследования из .env.example
cat > "${PROJECT_DIR}/.env" <<EOF
# --- MEDIA WORKS generated .env (${PROJECT_NAME}) ---

# Mode / domains
INSTALLATION_MODE=${INSTALLATION_MODE}
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
PGRST_DB_SCHEMAS=public

JWT_SECRET=${JWT_SECRET}
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
JWT_EXPIRY=630720000

DASHBOARD_USERNAME=${DASHBOARD_USERNAME}
DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}

SUPABASE_PUBLIC_URL=https://${API_HOST}
SITE_URL=https://${STUDIO_HOST}
API_EXTERNAL_URL=https://${API_HOST}

KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443
IMGPROXY_ENABLE_WEBP_DETECTION=true

# Vector / Docker socket
DOCKER_SOCKET_LOCATION=/var/run/docker.sock

# Studio defaults (кавычки из-за пробелов)
STUDIO_DEFAULT_ORGANIZATION="MEDIA WORKS"
STUDIO_DEFAULT_PROJECT=${PROJECT_NAME}

# n8n / Redis
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
REDIS_PASSWORD=${REDIS_PASSWORD}

# n8n DB
N8N_DB_HOST=${N8N_DB_HOST}
N8N_DB_PASSWORD=${N8N_DB_PASSWORD}

# Auth toggles (SMTP блок ниже при необходимости)
ENABLE_EMAIL_SIGNUP=false
ENABLE_ANONYMOUS_USERS=true
ENABLE_EMAIL_AUTOCONFIRM=false
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false
EOF

# SMTP блок при выборе (добавляем поверх)
if [[ "$WANT_SMTP" =~ ^[Yy]$ ]]; then
  cat >> "${PROJECT_DIR}/.env" <<EOF
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
SMTP_SENDER_NAME=${SMTP_SENDER_NAME}
SMTP_ADMIN_EMAIL=${SMTP_ADMIN_EMAIL}
ENABLE_EMAIL_SIGNUP=true
ENABLE_ANONYMOUS_USERS=false
ENABLE_EMAIL_AUTOCONFIRM=true
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false
EOF
fi


# Очистка .env и валидация
sed -i 's/[[:space:]]*$//' "${PROJECT_DIR}/.env"
sed -i 's/\r$//' "${PROJECT_DIR}/.env"
# Удаляем любые строки YAML-формата "KEY: value" если внезапно появились
sed -i '/^[A-Za-z0-9_]\+:\s\+.*/d' "${PROJECT_DIR}/.env"
# Приводим "KEY = VALUE" к "KEY=VALUE"
sed -i 's/^\([A-Z0-9_]\+\)[[:space:]]*=[[:space:]]*/\1=/' "${PROJECT_DIR}/.env"
# Проверка формата
grep -E '^[A-Z0-9_]+=' "${PROJECT_DIR}/.env" >/dev/null || err "Invalid .env format (нет KEY=VALUE)."

# ---------- Traefik config ----------
info "Создаём конфигурацию Traefik..."
cat > "${PROJECT_DIR}/configs/traefik/traefik.yml" <<EOF
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
  ping:
    address: ":8080"

api:
  dashboard: false

ping: {}

providers:
  docker:
    exposedByDefault: false
  file:
    filename: /etc/traefik/dynamic/security.yml
    watch: true

certificatesResolvers:
  myresolver:
    acme:
      email: "${ACME_EMAIL}"
      storage: /acme/acme.json
      httpChallenge:
        entryPoint: web
EOF

cat > "${PROJECT_DIR}/configs/traefik/dynamic/security.yml" <<'EOF'
http:
  middlewares:
    mw-https-redirect:
      redirectScheme:
        scheme: https
        permanent: true

    mw-sec-headers:
      headers:
        sslRedirect: true
        stsSeconds: 31536000
        stsIncludeSubdomains: true
        stsPreload: true
        frameDeny: true
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "no-referrer-when-downgrade"

    mw-ratelimit:
      rateLimit:
        average: 100
        burst: 200

  routers: {}
  services: {}
EOF

# ---------- Compose files ----------
info "Готовим Docker Compose файлы..."

# 1) Для full/standard: подтягиваем базовый compose + нужные volumes из репо
if [ "$INSTALLATION_MODE" = "full" ] || [ "$INSTALLATION_MODE" = "standard" ]; then
  cp /root/supabase/docker/docker-compose.yml "${PROJECT_DIR}/compose.supabase.yml"
  # Обязательные каталоги/файлы для vector/db/pooler
  mkdir -p "${PROJECT_DIR}/volumes/logs" "${PROJECT_DIR}/volumes/db" "${PROJECT_DIR}/volumes/pooler"
  cp -rT /root/supabase/docker/volumes/logs   "${PROJECT_DIR}/volumes/logs"
  cp -rT /root/supabase/docker/volumes/db     "${PROJECT_DIR}/volumes/db"
  cp -rT /root/supabase/docker/volumes/pooler "${PROJECT_DIR}/volumes/pooler"
  # Для Kong нужен файл ./volumes/api/kong.yml
  mkdir -p "${PROJECT_DIR}/volumes/api"
  cp -rT /root/supabase/docker/volumes/api "${PROJECT_DIR}/volumes/api"  
fi

# Патчим vector: монтируем директорию, а не файл (исправляет "not a directory")
if [ -f "${PROJECT_DIR}/compose.supabase.yml" ]; then
  sed -i 's#- \./volumes/logs/vector\.yml:/etc/vector/vector\.yml:ro,z#- ./volumes/logs:/etc/vector:ro,z#' "${PROJECT_DIR}/compose.supabase.yml"
fi


# 2) Наш override: Traefik + n8n + Traefik labels для kong/studio
cat > "${PROJECT_DIR}/docker-compose.yml" <<'EOF'
x-common: &common
  restart: unless-stopped
  logging:
    driver: "json-file"
    options:
      max-size: "10m"
      max-file: "3"

networks:
  web:
  internal:

services:
  traefik:
    <<: *common
    image: traefik:2.11
    container_name: traefik
    command:
      - "--providers.docker=true"
      - "--providers.docker.network=${PROJECT_WEB_NET}"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.ping.address=:8080"
      - "--ping=true"
      - "--ping.entrypoint=ping"
      - "--certificatesresolvers.myresolver.acme.email=${ACME_EMAIL}"
      - "--certificatesresolvers.myresolver.acme.storage=/acme/acme.json"
      - "--certificatesresolvers.myresolver.acme.httpchallenge.entrypoint=web"
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./configs/traefik/traefik.yml:/traefik.yml:ro
      - ./configs/traefik/dynamic/security.yml:/etc/traefik/dynamic/security.yml:ro
      - ./volumes/traefik/acme.json:/acme/acme.json
    networks:
      - web
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:8080/ping"]
      interval: 10s
      timeout: 5s
      retries: 6      

  # n8n - main
  n8n:
    <<: *common
    image: n8nio/n8n:1.75.0
    container_name: n8n
    environment:
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=5678
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_SECURE_COOKIE=false
      - N8N_PROTOCOL=http
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${N8N_DB_HOST}
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
    depends_on:
      - redis
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n.entrypoints=web,websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
      - "traefik.http.routers.n8n.middlewares=mw-sec-headers@file,mw-ratelimit@file"
    networks:
      - web
      - internal

  redis:
    <<: *common
    image: redis:7-alpine
    container_name: redis
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
    networks:
      - internal

  # n8n worker (используется только в FULL режиме)
  n8n-worker:
    <<: *common
    image: n8nio/n8n:1.75.0
    container_name: n8n-worker
    environment:
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${N8N_DB_HOST}
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
    depends_on:
      - redis
    networks:
      - internal

  # Traefik-лейблы для supabase сервисов (подтягиваются из compose.supabase.yml)
  kong:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.kong.rule=Host(`${API_HOST}`)"
      - "traefik.http.routers.kong.entrypoints=web,websecure"
      - "traefik.http.routers.kong.tls.certresolver=myresolver"
      - "traefik.http.routers.kong.middlewares=mw-sec-headers@file,mw-ratelimit@file"

  studio:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.studio.rule=Host(`${STUDIO_HOST}`)"
      - "traefik.http.routers.studio.entrypoints=web,websecure"
      - "traefik.http.routers.studio.tls.certresolver=myresolver"
      - "traefik.http.routers.studio.middlewares=mw-sec-headers@file,mw-ratelimit@file"
EOF

# LIGHT compose
if [ "$INSTALLATION_MODE" = "light" ]; then
  cat > "${PROJECT_DIR}/compose.light.yml" <<'EOF'
networks: { internal: {} }
services:
  postgres:
    image: postgres:15-alpine
    container_name: postgres
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: postgres
    healthcheck:
      test: ["CMD-SHELL","pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 10
    volumes:
      - ./volumes/postgres:/var/lib/postgresql/data
    networks: [internal]

  pg-init:
    image: postgres:15-alpine
    container_name: pg-init
    depends_on: [postgres]
    entrypoint: ["/bin/sh","-c"]
    command:
      - |
        until pg_isready -h postgres -U postgres; do sleep 1; done
        psql -h postgres -U postgres -d postgres -v ON_ERROR_STOP=1 \
          -c "DO $$ BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n') THEN
                  EXECUTE format('CREATE ROLE n8n LOGIN PASSWORD %L', '${N8N_DB_PASSWORD}');
                ELSE
                  EXECUTE format('ALTER ROLE n8n LOGIN PASSWORD %L', '${N8N_DB_PASSWORD}');
                END IF;
                IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'n8n') THEN
                  CREATE DATABASE n8n OWNER n8n;
                END IF;
              END $$;"
        psql -h postgres -U postgres -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;"
    environment:
      PGPASSWORD: ${POSTGRES_PASSWORD}
    networks: [internal]
EOF
fi


# RAG compose (урезанный supabase)
if [ "$INSTALLATION_MODE" = "rag" ]; then
  cat > "${PROJECT_DIR}/compose.supabase.rag.yml" <<'EOF'
version: '3.8'
x-common: &common
  restart: unless-stopped
  logging:
    driver: "json-file"
    options: { max-size: "10m", max-file: "3" }

networks: { web: {}, internal: {} }

services:
  vector:
    <<: *common
    image: timberio/vector:0.28.1-alpine
    container_name: supabase-vector
    volumes:
      - ./volumes/logs:/etc/vector:ro,z
      - ${DOCKER_SOCKET_LOCATION}:/var/run/docker.sock:ro,z
    healthcheck:
      test: ["CMD","wget","--no-verbose","--tries=1","--spider","http://vector:9001/health"]
      interval: 5s
      timeout: 5s
      retries: 3
    networks: [internal]

  db:
    <<: *common
    image: supabase/postgres:15.8.1.060
    container_name: supabase-db
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      JWT_SECRET: ${JWT_SECRET}
      JWT_EXP: ${JWT_EXPIRY}
      PGPORT: ${POSTGRES_PORT}
      POSTGRES_PORT: ${POSTGRES_PORT}
      POSTGRES_HOST: /var/run/postgresql
    volumes:
      - ./volumes/db/realtime.sql:/docker-entrypoint-initdb.d/migrations/99-realtime.sql:Z
      - ./volumes/db/webhooks.sql:/docker-entrypoint-initdb.d/init-scripts/98-webhooks.sql:Z
      - ./volumes/db/roles.sql:/docker-entrypoint-initdb.d/init-scripts/99-roles.sql:Z
      - ./volumes/db/jwt.sql:/docker-entrypoint-initdb.d/init-scripts/99-jwt.sql:Z
      - ./volumes/db/data:/var/lib/postgresql/data:Z
      - ./volumes/db/_supabase.sql:/docker-entrypoint-initdb.d/migrations/97-_supabase.sql:Z
      - ./volumes/db/logs.sql:/docker-entrypoint-initdb.d/migrations/99-logs.sql:Z
      - ./volumes/db/pooler.sql:/docker-entrypoint-initdb.d/migrations/99-pooler.sql:Z
      - db-config:/etc/postgresql-custom
    healthcheck:
      test: ["CMD","pg_isready","-U","postgres","-h","localhost"]
      interval: 5s
      timeout: 5s
      retries: 10
    depends_on:
      vector:
        condition: service_healthy
    networks: [internal]

  supavisor:
    <<: *common
    image: supabase/supavisor:2.5.7
    container_name: supabase-pooler
    ports:
      - ${POSTGRES_PORT}:5432
    volumes:
      - ./volumes/pooler/pooler.exs:/etc/pooler/pooler.exs:ro,z
    healthcheck:
      test: ["CMD","curl","-sSfL","--head","-o","/dev/null","http://127.0.0.1:4000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 5
    depends_on:
      db: { condition: service_healthy }
    environment:
      PORT: 4000
      POSTGRES_PORT: ${POSTGRES_PORT}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      DATABASE_URL: ecto://supabase_admin:${POSTGRES_PASSWORD}@db:${POSTGRES_PORT}/_supabase
      CLUSTER_POSTGRES: true
      SECRET_KEY_BASE: ${SERVICE_ROLE_KEY}
      VAULT_ENC_KEY: ${SERVICE_ROLE_KEY}
      API_JWT_SECRET: ${JWT_SECRET}
      METRICS_JWT_SECRET: ${JWT_SECRET}
      REGION: local
      ERL_AFLAGS: -proto_dist inet_tcp
      POOLER_TENANT_ID: dev
      POOLER_DEFAULT_POOL_SIZE: 5
      POOLER_MAX_CLIENT_CONN: 50
      POOLER_POOL_MODE: transaction
      DB_POOL_SIZE: 10
    networks: [internal]

  meta:
    <<: *common
    image: supabase/postgres-meta:v0.91.0
    container_name: supabase-meta
    environment:
      PG_META_PORT: 8080
      PG_META_DB_HOST: db
      PG_META_DB_PORT: ${POSTGRES_PORT}
      PG_META_DB_NAME: ${POSTGRES_DB}
      PG_META_DB_USER: supabase_admin
      PG_META_DB_PASSWORD: ${POSTGRES_PASSWORD}
    depends_on:
      db: { condition: service_healthy }
    networks: [internal]

  rest:
    <<: *common
    image: postgrest/postgrest:v12.2.12
    container_name: supabase-rest
    environment:
      PGRST_DB_URI: postgres://authenticator:${POSTGRES_PASSWORD}@db:${POSTGRES_PORT}/${POSTGRES_DB}
      PGRST_DB_SCHEMAS: public
      PGRST_DB_ANON_ROLE: anon
      PGRST_JWT_SECRET: ${JWT_SECRET}
      PGRST_DB_USE_LEGACY_GUCS: "false"
      PGRST_APP_SETTINGS_JWT_SECRET: ${JWT_SECRET}
      PGRST_APP_SETTINGS_JWT_EXP: ${JWT_EXPIRY}
    command: ["postgrest"]
    depends_on:
      db: { condition: service_healthy }
    networks: [internal]

  auth:
    <<: *common
    image: supabase/gotrue:v2.177.0
    container_name: supabase-auth
    environment:
      GOTRUE_API_HOST: 0.0.0.0
      GOTRUE_API_PORT: 9999
      API_EXTERNAL_URL: https://${API_HOST}
      GOTRUE_DB_DRIVER: postgres
      GOTRUE_DB_DATABASE_URL: postgres://supabase_auth_admin:${POSTGRES_PASSWORD}@db:${POSTGRES_PORT}/${POSTGRES_DB}
      GOTRUE_SITE_URL: https://${STUDIO_HOST}
      GOTRUE_JWT_ADMIN_ROLES: service_role
      GOTRUE_JWT_AUD: authenticated
      GOTRUE_JWT_DEFAULT_GROUP_NAME: authenticated
      GOTRUE_JWT_EXP: ${JWT_EXPIRY}
      GOTRUE_JWT_SECRET: ${JWT_SECRET}
      GOTRUE_EXTERNAL_EMAIL_ENABLED: ${ENABLE_EMAIL_SIGNUP}
      GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED: ${ENABLE_ANONYMOUS_USERS}
      GOTRUE_SMTP_ADMIN_EMAIL: ${SMTP_ADMIN_EMAIL}
      GOTRUE_SMTP_HOST: ${SMTP_HOST}
      GOTRUE_SMTP_PORT: ${SMTP_PORT}
      GOTRUE_SMTP_USER: ${SMTP_USER}
      GOTRUE_SMTP_PASS: ${SMTP_PASS}
      GOTRUE_SMTP_SENDER_NAME: ${SMTP_SENDER_NAME}
    healthcheck:
      test: ["CMD","wget","--no-verbose","--tries=1","--spider","http://localhost:9999/health"]
      interval: 5s
      timeout: 5s
      retries: 3
    depends_on:
      db: { condition: service_healthy }
    networks: [internal]

  kong:
    <<: *common
    image: kong:2.8.1
    container_name: supabase-kong
    ports:
      - "8000:8000"
      - "8443:8443"
    volumes:
      - ./configs/supabase/kong.yml:/home/kong/temp.yml:ro,z
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /home/kong/kong.yml
      KONG_DNS_ORDER: LAST,A,CNAME
      KONG_PLUGINS: request-transformer,cors,key-auth,acl,basic-auth
      SUPABASE_ANON_KEY: ${ANON_KEY}
      SUPABASE_SERVICE_KEY: ${SERVICE_ROLE_KEY}
      DASHBOARD_USERNAME: ${DASHBOARD_USERNAME}
      DASHBOARD_PASSWORD: ${DASHBOARD_PASSWORD}
    entrypoint: bash -c 'eval "echo \"$$(cat ~/temp.yml)\"" > ~/kong.yml && /docker-entrypoint.sh kong docker-start'
    depends_on:
      auth: { condition: service_started }
      rest: { condition: service_started }
    networks: [internal, web]

  studio:
    <<: *common
    image: supabase/studio:2025.06.30-sha-6f5982d
    container_name: supabase-studio
    environment:
      STUDIO_PG_META_URL: http://meta:8080
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      DEFAULT_ORGANIZATION_NAME: ${STUDIO_DEFAULT_ORGANIZATION}
      DEFAULT_PROJECT_NAME: ${STUDIO_DEFAULT_PROJECT}
      SUPABASE_URL: http://kong:8000
      SUPABASE_PUBLIC_URL: https://${API_HOST}
      SUPABASE_ANON_KEY: ${ANON_KEY}
      SUPABASE_SERVICE_KEY: ${SERVICE_ROLE_KEY}
      AUTH_JWT_SECRET: ${JWT_SECRET}
    healthcheck:
      test: ["CMD","node","-e","fetch('http://studio:3000/api/platform/profile').then((r)=>{if(r.status!==200) throw new Error(r.status)})"]
      timeout: 10s
      interval: 5s
      retries: 3
    depends_on:
      meta: { condition: service_started }
    networks: [internal, web]

volumes:
  db-config:
EOF
fi

# ---------- Supabase Kong template ----------
cat > "${PROJECT_DIR}/configs/supabase/kong.yml" <<'EOF'
_format_version: "2.1"
_transform: true

services:
  - name: postgrest
    url: http://rest:3000
    routes:
      - name: rest
        paths: ["/rest/v1/"]
        strip_path: false
        protocols: ["http","https"]

  - name: auth
    url: http://auth:9999
    routes:
      - name: auth
        paths: ["/auth/v1/"]
        strip_path: false
        protocols: ["http","https"]

plugins:
  - name: cors
    config:
      origins: ["*"]
      methods: ["GET","POST","PUT","PATCH","DELETE","OPTIONS"]
      headers: ["Authorization","apikey","Content-Type"]
      exposed_headers: ["Content-Range","Content-Type","Date","Content-Location","Location","Content-Profile"]
      credentials: true
      preflight_continue: false
EOF


# ---------- Scripts: manage / backup / update ----------
info "Создаём служебные скрипты..."

cat > "${PROJECT_DIR}/scripts/manage.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# === УСТОЙЧИВАЯ ЗАГРУЗКА .env (поддерживает пробелы/кавычки в значениях) ===
set -a
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|\#*) continue ;;                # пустые строки и комментарии
    *=*)
      key="${line%%=*}"
      val="${line#*=}"
      # убираем внешние кавычки, если есть
      if [[ "$val" =~ ^\".*\"$ ]]; then
        val="${val:1:${#val}-2}"
      elif [[ "$val" =~ ^\'.*\'$ ]]; then
        val="${val:1:${#val}-2}"
      fi
      printf -v "$key" '%s' "$val"
      export "$key"
      ;;
    *) ;;                              # игнор прочего
  esac
done < .env
set +a

# === ОПРЕДЕЛЕНИЕ РЕАЛЬНОГО ИМЕНИ ПРОЕКТА ДЛЯ СЕТИ TRAEFIK ===
# Если в compose.supabase.yml задано name: supabase, используем его; иначе — имя папки.
if grep -qE '^[[:space:]]*name:[[:space:]]*supabase\b' compose.supabase.yml 2>/dev/null; then
  PROJECT_NAME="supabase"
else
  PROJECT_NAME="$(basename "$PWD")"
fi
export PROJECT_WEB_NET="${PROJECT_NAME}_web"

MODE="${INSTALLATION_MODE:-standard}"

compose_args=()
case "$MODE" in
  full|standard)
    compose_args=(-f compose.supabase.yml -f docker-compose.yml)
    ;;
  rag)
    compose_args=(-f compose.supabase.rag.yml -f docker-compose.yml)
    ;;
  light)
    compose_args=(-f compose.light.yml -f docker-compose.yml)
    ;;
  *)
    echo "Unknown mode: $MODE" >&2; exit 1;;
esac

case "${1:-up}" in
  up)
    docker compose "${compose_args[@]}" up -d
    ;;
  down)
    docker compose "${compose_args[@]}" down
    ;;
  ps)
    docker compose "${compose_args[@]}" ps
    ;;
  logs)
    shift || true
    if [ $# -gt 0 ]; then
      docker compose "${compose_args[@]}" logs -f --tail=200 "$@"
    else
      docker compose "${compose_args[@]}" logs -f --tail=200
    fi
    ;;
  restart)
    docker compose "${compose_args[@]}" restart
    ;;
  pull)
    docker compose "${compose_args[@]}" pull
    ;;
  *)
    echo "Usage: $0 {up|down|ps|logs|restart|pull}" ;;
esac
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

if [ "${INSTALLATION_MODE}" = "light" ]; then
  DB_CONT="postgres"
else
  DB_CONT="supabase-db"
fi

echo "Dumping database from ${DB_CONT}..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${DB_CONT}" pg_dump -U postgres -d "${POSTGRES_DB}" -Fc -f "/tmp/backup_${TS}.dump"
docker cp "${DB_CONT}:/tmp/backup_${TS}.dump" "backups/backup_${TS}.dump"
docker exec "${DB_CONT}" rm -f "/tmp/backup_${TS}.dump"
echo "Backup saved to backups/backup_${TS}.dump"
EOF
chmod +x "${PROJECT_DIR}/scripts/backup.sh"

cat > "${PROJECT_DIR}/scripts/update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/manage.sh pull
./scripts/manage.sh up
# Подождём, пока Traefik и (если не light) базовые сервисы получат healthy
sleep 3
EOF
chmod +x "${PROJECT_DIR}/scripts/update.sh"

info "Важно: для управления стеком используйте:"
echo "  ${PROJECT_DIR}/scripts/manage.sh (он подставляет оба compose-файла)."

# ---------- Credentials file ----------
info "Записываем credentials..."
cat > "${PROJECT_DIR}/credentials.txt" <<EOF
==== MEDIA WORKS — Credentials (${PROJECT_NAME}) ====

Mode: ${INSTALLATION_MODE}

Domains:
  n8n:     https://${N8N_HOST}
  studio:  https://${STUDIO_HOST}
  api:     https://${API_HOST}

Supabase:
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
  JWT_SECRET: ${JWT_SECRET}
  ANON_KEY: ${ANON_KEY}
  SERVICE_ROLE_KEY: ${SERVICE_ROLE_KEY}
  Studio Dashboard:
    USER: ${DASHBOARD_USERNAME}
    PASS: ${DASHBOARD_PASSWORD}

n8n:
  DB:
    HOST: ${N8N_DB_HOST}
    USER: n8n
    PASS: ${N8N_DB_PASSWORD}
    NAME: n8n
  ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}

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

# ---------- Start stack ----------
info "Запускаем стек по зависимостям..."
pushd "${PROJECT_DIR}" >/dev/null

if [ "$INSTALLATION_MODE" = "light" ]; then
  ./scripts/manage.sh up
  wait_for_postgres postgres || err "PostgreSQL (light) не поднялся."
else
  # Сначала база (требует здоровый vector в full/standard из upstream)
  docker compose -f compose.supabase.yml up -d vector || true
  docker compose -f compose.supabase.yml up -d db || err "Не удалось запустить supabase-db"
  wait_for_postgres supabase-db || err "Supabase DB не поднялся."

# Инициализация пользователя/БД для n8n в Supabase (без here-doc)
info "Инициализируем пользователя и БД n8n в Supabase..."
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" supabase-db \
  psql -U postgres -d "${POSTGRES_DB:-postgres}" -v ON_ERROR_STOP=1 \
  -c "DO \$\$ BEGIN
         IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n') THEN
           EXECUTE format('CREATE ROLE n8n LOGIN PASSWORD %L', '${N8N_DB_PASSWORD}');
         ELSE
           EXECUTE format('ALTER ROLE n8n LOGIN PASSWORD %L', '${N8N_DB_PASSWORD}');
         END IF;
         IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'n8n') THEN
           CREATE DATABASE n8n OWNER n8n;
         END IF;
       END \$\$;" \
  -c "GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;"




  # Затем весь стек
  ./scripts/manage.sh up
fi

# ---------- Health checks ----------
info "Выполняем health-check’и..."
health_check_all_services

popd >/dev/null

# ---------- FOOTER ----------
echo
echo "==============================================="
echo -e "✅ ${GREEN}Установка завершена успешно!${NC}"
echo "🚀 MEDIA WORKS — автоматизация на максималках"
echo "==============================================="
echo
echo "Файлы проекта: ${PROJECT_DIR}"
echo "Управление:    ${PROJECT_DIR}/scripts/manage.sh {up|down|ps|logs|restart|pull}"
echo "Backup:        ${PROJECT_DIR}/scripts/backup.sh"
echo "Update:        ${PROJECT_DIR}/scripts/update.sh"
echo
echo "Доступы и ключи: ${PROJECT_DIR}/credentials.txt  (права 600)"
echo
echo "Важно:"
echo " - Проверьте DNS записи для доменов:"
echo "     ${N8N_HOST}, ${STUDIO_HOST}, ${API_HOST}"
echo " - Откройте порты 80/443."
echo " - Первичная авторизация в Supabase Studio: ${DASHBOARD_USERNAME} / ${DASHBOARD_PASSWORD}"
echo " - n8n доступен по: https://${N8N_HOST}"
