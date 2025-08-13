#!/usr/bin/env bash
set -euo pipefail

# ===== Locale (во избежание "кракозябр") =====
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# ================================
# MEDIA WORKS — Deployment Master
# n8n + Supabase + Traefik
# Отдельные Postgres: supabase-db и postgres-n8n
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
_/  /_/_____/_____/___/_/  |_|     |__/|__/\____/_/ |_/_/ |_/____/

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

wait_for_postgres() { # container name
  local svc="$1" max=60 i=1
  while [ $i -le $max ]; do
    if docker exec "$svc" pg_isready -U postgres >/dev/null 2>&1; then return 0; fi
    sleep 2; i=$((i+1))
  done
  return 1
}

check_ports() {
  info "Проверяем доступность портов..."
  
  for port in 80 443; do
    if netstat -tln 2>/dev/null | grep -q ":${port} "; then
      if systemctl is-active --quiet nginx apache2 httpd 2>/dev/null; then
        warn "Порт ${port} занят веб-сервером. Попытка остановки..."
        systemctl stop nginx apache2 httpd 2>/dev/null || true
        sleep 2
      fi
      
      if netstat -tln 2>/dev/null | grep -q ":${port} "; then
        warn "Порт ${port} занят. Убедитесь, что он будет освобождён перед запуском."
      fi
    fi
  done
  
  ok "Проверка портов завершена"
}

health_check_all_services() {
  local failed=()

  wait_healthy() {
    local name="$1" tries=60
    while [ $tries -gt 0 ]; do
      local st
      st="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || true)"
      if [ "$st" = "healthy" ] || [ "$st" = "running" ]; then return 0; fi
      sleep 2; tries=$((tries-1))
    done
    return 1
  }

  wait_healthy traefik || failed+=("Traefik")
  wait_healthy postgres-n8n || failed+=("postgres-n8n")
  wait_healthy n8n || failed+=("n8n")
  wait_healthy redis || failed+=("redis")

  if [ "${INSTALLATION_MODE}" != "light" ]; then
    wait_healthy supabase-db   || failed+=("Supabase DB")
    wait_healthy supabase-rest || failed+=("Supabase REST")
    wait_healthy supabase-auth || failed+=("Supabase Auth")
    # Kong — нет health, просто проверим, что слушает
    if ! docker exec supabase-kong sh -c 'wget --spider -q http://localhost:8000/ 2>/dev/null || wget --spider -q http://localhost:8000/health 2>/dev/null' >/dev/null 2>&1; then
      failed+=("Supabase Kong")
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
read -rp " * Имя проекта (каталог в /root): " RAW_PROJECT_NAME
[ -n "${RAW_PROJECT_NAME:-}" ] || err "Имя проекта обязательно."
RAW_PROJECT_NAME="$(printf '%s' "$RAW_PROJECT_NAME" | tr -d '\r')"

# Нормализация имени проекта: только [a-z0-9-], в нижний регистр, обрезка по краям, ≥1 символ
NORMALIZED="$(printf '%s' "$RAW_PROJECT_NAME" \
  | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9-]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//' )"
if [ -z "$NORMALIZED" ]; then NORMALIZED="mw-stack"; fi
if [ "$NORMALIZED" != "$RAW_PROJECT_NAME" ]; then
  warn "Имя проекта нормализовано: '$RAW_PROJECT_NAME' → '$NORMALIZED'"
fi
PROJECT_NAME="$NORMALIZED"
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

read -rp "   OpenAI API Key (опционально, для AI функций в Supabase): " OPENAI_API_KEY
OPENAI_API_KEY="${OPENAI_API_KEY:-}"

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
  SMTP_HOST=""; SMTP_PORT="587"; SMTP_USER=""; SMTP_PASS=""
  SMTP_SENDER_NAME=""; SMTP_ADMIN_EMAIL="admin@${ROOT_DOMAIN}"
fi

echo
info "Выберите режим установки:"
echo "  1) FULL — Supabase(всё) + n8n main+worker + Redis + Traefik"
echo "  2) STANDARD — Supabase(всё) + n8n (single) + Traefik"
echo "  3) RAG — Supabase (vector, studio, kong, rest, meta, pooler, auth, db) + n8n + Traefik"
echo "  4) LIGHT — n8n + Postgres (отдельный) + Traefik (без Supabase)"
read -rp "Выбор [1-4]: " MODE_SEL
case "${MODE_SEL:-}" in
  1) INSTALLATION_MODE="full" ;;
  2) INSTALLATION_MODE="standard" ;;
  3) INSTALLATION_MODE="rag" ;;
  4) INSTALLATION_MODE="light" ;;
  *) err "Неверный выбор режима." ;;
esac
ok "Режим: ${INSTALLATION_MODE^^}"

# ---------- Check ports before installation ----------
check_ports

# ---------- Install dependencies ----------
info "Устанавливаем зависимости (curl, git, docker, docker compose)..."
retry_operation apt-get update -y || err "apt-get update не удалось."
retry_operation apt-get install -y ca-certificates curl gnupg lsb-release git wget openssl net-tools || err "Не удалось установить базовые пакеты."

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
mkdir -p "${PROJECT_DIR}/"{configs/traefik/dynamic,volumes/traefik,volumes/n8n,volumes/postgres_n8n,volumes/logs,volumes/pooler,volumes/db,volumes/api,volumes/storage,volumes/functions,data,logs,scripts}
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
POSTGRES_PASSWORD="$(gen_alnum 32)"      # для Supabase DB
N8N_PG_PASSWORD="$(gen_alnum 32)"        # для postgres-n8n
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

# Доп.секреты / дефолты
SECRET_KEY_BASE="$(gen_alnum 64)"
VAULT_ENC_KEY="$(gen_alnum 64)"
LOGFLARE_PUBLIC_ACCESS_TOKEN="$(gen_alnum 48)"
LOGFLARE_PRIVATE_ACCESS_TOKEN="$(gen_alnum 48)"
POOLER_PROXY_PORT_TRANSACTION="6543"
POOLER_DEFAULT_POOL_SIZE="20"
POOLER_MAX_CLIENT_CONN="100"
POOLER_TENANT_ID="${PROJECT_NAME}"
POOLER_DB_POOL_SIZE="5"
FUNCTIONS_VERIFY_JWT="false"
ADDITIONAL_REDIRECT_URLS=""
DISABLE_SIGNUP="false"
MAILER_URLPATHS_CONFIRMATION="/auth/v1/verify"
MAILER_URLPATHS_INVITE="/auth/v1/verify"
MAILER_URLPATHS_RECOVERY="/auth/v1/verify"
MAILER_URLPATHS_EMAIL_CHANGE="/auth/v1/verify"

# SMTP дефолты (порт числом — иначе Gotrue падает)
: "${SMTP_HOST:=}"
: "${SMTP_PORT:=587}"
: "${SMTP_USER:=}"
: "${SMTP_PASS:=}"
: "${SMTP_SENDER_NAME:=}"
: "${SMTP_ADMIN_EMAIL:=admin@${ROOT_DOMAIN}}"

# Определяем режим выполнения n8n
if [ "$INSTALLATION_MODE" = "full" ]; then
  N8N_EXEC_MODE="queue"
else
  N8N_EXEC_MODE="regular"
fi

ok "Секреты сгенерированы."

# ---------- Build .env ----------
info "Готовим .env..."
cat > "${PROJECT_DIR}/.env" <<EOF
# --- MEDIA WORKS generated .env (${PROJECT_NAME}) ---

# Mode / domains
INSTALLATION_MODE=${INSTALLATION_MODE}
ROOT_DOMAIN=${ROOT_DOMAIN}
N8N_HOST=${N8N_HOST}
STUDIO_HOST=${STUDIO_HOST}
API_HOST=${API_HOST}
ACME_EMAIL=${ACME_EMAIL}

# OpenAI
OPENAI_API_KEY=${OPENAI_API_KEY}

# Supabase core
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=postgres
POSTGRES_HOST=supabase-db
POSTGRES_PORT=5432
PGRST_DB_SCHEMAS=public,storage,graphql_public

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

# Studio defaults
STUDIO_DEFAULT_ORGANIZATION=MEDIA WORKS
STUDIO_DEFAULT_PROJECT=${PROJECT_NAME}

# n8n
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_EXEC_MODE=${N8N_EXEC_MODE}

# Redis
REDIS_PASSWORD=${REDIS_PASSWORD}

# n8n DB (отдельный Postgres)
N8N_DB_HOST=postgres-n8n
N8N_DB_PORT=5432
N8N_DB_NAME=n8n
N8N_DB_USER=n8n
N8N_DB_PASSWORD=${N8N_PG_PASSWORD}

# Auth toggles
ENABLE_EMAIL_SIGNUP=false
ENABLE_ANONYMOUS_USERS=true
ENABLE_EMAIL_AUTOCONFIRM=false
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false

# Defaults
SECRET_KEY_BASE=${SECRET_KEY_BASE}
VAULT_ENC_KEY=${VAULT_ENC_KEY}
LOGFLARE_PUBLIC_ACCESS_TOKEN=${LOGFLARE_PUBLIC_ACCESS_TOKEN}
LOGFLARE_PRIVATE_ACCESS_TOKEN=${LOGFLARE_PRIVATE_ACCESS_TOKEN}
POOLER_PROXY_PORT_TRANSACTION=${POOLER_PROXY_PORT_TRANSACTION}
POOLER_DEFAULT_POOL_SIZE=${POOLER_DEFAULT_POOL_SIZE}
POOLER_MAX_CLIENT_CONN=${POOLER_MAX_CLIENT_CONN}
POOLER_TENANT_ID=${POOLER_TENANT_ID}
POOLER_DB_POOL_SIZE=${POOLER_DB_POOL_SIZE}
FUNCTIONS_VERIFY_JWT=${FUNCTIONS_VERIFY_JWT}
ADDITIONAL_REDIRECT_URLS=${ADDITIONAL_REDIRECT_URLS}
DISABLE_SIGNUP=${DISABLE_SIGNUP}
MAILER_URLPATHS_CONFIRMATION=${MAILER_URLPATHS_CONFIRMATION}
MAILER_URLPATHS_INVITE=${MAILER_URLPATHS_INVITE}
MAILER_URLPATHS_RECOVERY=${MAILER_URLPATHS_RECOVERY}
MAILER_URLPATHS_EMAIL_CHANGE=${MAILER_URLPATHS_EMAIL_CHANGE}

# SMTP
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
SMTP_SENDER_NAME=${SMTP_SENDER_NAME}
SMTP_ADMIN_EMAIL=${SMTP_ADMIN_EMAIL}
EOF

if [[ "$WANT_SMTP" =~ ^[Yy]$ ]]; then
  sed -i 's/^ENABLE_EMAIL_SIGNUP=.*/ENABLE_EMAIL_SIGNUP=true/' "${PROJECT_DIR}/.env"
  sed -i 's/^ENABLE_ANONYMOUS_USERS=.*/ENABLE_ANONYMOUS_USERS=false/' "${PROJECT_DIR}/.env"
  sed -i 's/^ENABLE_EMAIL_AUTOCONFIRM=.*/ENABLE_EMAIL_AUTOCONFIRM=true/' "${PROJECT_DIR}/.env"
fi

# sanitize
sed -i 's/[[:space:]]*$//' "${PROJECT_DIR}/.env"
sed -i 's/\r$//' "${PROJECT_DIR}/.env"
grep -E '^[A-Z0-9_]+=' "${PROJECT_DIR}/.env" >/dev/null || err "Invalid .env format (нет KEY=VALUE)."

# ---------- Traefik config ----------
info "Создаём конфигурацию Traefik..."
cat > "${PROJECT_DIR}/configs/traefik/traefik.yml" <<EOF
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

providers:
  docker:
    exposedByDefault: false
    network: ${PROJECT_NAME}_default

certificatesResolvers:
  myresolver:
    acme:
      email: ${ACME_EMAIL}
      storage: /acme/acme.json
      httpChallenge:
        entryPoint: web

api:
  dashboard: false

log:
  level: WARN

accessLog: {}
EOF

# ---------- Compose files ----------
info "Готовим Docker Compose файлы..."

# 1) Копируем и модифицируем Supabase compose для разных режимов
if [ "$INSTALLATION_MODE" != "light" ]; then
  cp /root/supabase/docker/docker-compose.yml "${PROJECT_DIR}/compose.supabase.yml"
  
  # Чистим/копируем volumes
  rm -rf "${PROJECT_DIR}/volumes/logs" "${PROJECT_DIR}/volumes/db" "${PROJECT_DIR}/volumes/pooler" "${PROJECT_DIR}/volumes/api"
  mkdir -p "${PROJECT_DIR}/volumes"
  cp -a /root/supabase/docker/volumes/logs   "${PROJECT_DIR}/volumes/" 2>/dev/null || true
  cp -a /root/supabase/docker/volumes/db     "${PROJECT_DIR}/volumes/" 2>/dev/null || true
  cp -a /root/supabase/docker/volumes/pooler "${PROJECT_DIR}/volumes/" 2>/dev/null || true
  cp -a /root/supabase/docker/volumes/api    "${PROJECT_DIR}/volumes/" 2>/dev/null || true
  
  # Для RAG режима создаём отфильтрованную версию
  if [ "$INSTALLATION_MODE" = "rag" ]; then
    cp "${PROJECT_DIR}/compose.supabase.yml" "${PROJECT_DIR}/compose.supabase.rag.yml"
    
    # Удаляем ненужные для RAG сервисы
    for service in storage imgproxy functions realtime analytics; do
      # Удаляем весь блок сервиса до следующего сервиса или конца файла
      sed -i "/^  ${service}:/,/^  [a-z-]*:/{/^  ${service}:/d; /^  [a-z-]*:/!d}" "${PROJECT_DIR}/compose.supabase.rag.yml"
      # Удаляем зависимости от этих сервисов
      sed -i "/${service}:/d" "${PROJECT_DIR}/compose.supabase.rag.yml"
    done
  fi
fi

# 2) Основной docker-compose.yml
cat > "${PROJECT_DIR}/docker-compose.yml" <<'EOF'
x-common: &common
  restart: unless-stopped
  logging:
    driver: "json-file"
    options: { max-size: "10m", max-file: "3" }

networks:
  default:
    name: ${PROJECT_NAME}_default

services:
  traefik:
    <<: *common
    image: traefik:2.11
    container_name: traefik
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./configs/traefik/traefik.yml:/traefik.yml:ro
      - ./volumes/traefik/acme.json:/acme/acme.json
    networks:
      - default

  redis:
    <<: *common
    image: redis:7.4.0-alpine
    container_name: redis
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
    healthcheck:
      test: ["CMD", "redis-cli", "--raw", "incr", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - default

  postgres-n8n:
    <<: *common
    image: postgres:16.4-alpine
    container_name: postgres-n8n
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${N8N_DB_PASSWORD}
      POSTGRES_DB: postgres
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 10
    volumes:
      - ./volumes/postgres_n8n:/var/lib/postgresql/data
    networks:
      - default

  pg-init-n8n:
    image: postgres:16.4-alpine
    container_name: pg-init-n8n
    depends_on:
      postgres-n8n:
        condition: service_healthy
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        until pg_isready -h postgres-n8n -U postgres; do sleep 1; done
        psql -h postgres-n8n -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
        DO \$\$
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n') THEN
            CREATE ROLE n8n WITH LOGIN PASSWORD '${N8N_DB_PASSWORD}';
          END IF;
        END
        \$\$;
        
        DO \$\$
        BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'n8n') THEN
            CREATE DATABASE n8n OWNER n8n;
          END IF;
        END
        \$\$;
        
        GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
        SQL
        echo "n8n database initialized"
    environment:
      PGPASSWORD: ${N8N_DB_PASSWORD}
    networks:
      - default

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
      - DB_POSTGRESDB_PORT=${N8N_DB_PORT}
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
    depends_on:
      redis:
        condition: service_healthy
      pg-init-n8n:
        condition: service_completed_successfully
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    networks:
      - default
EOF
fi

# 3) Docker Compose Override для Traefik labels Supabase сервисов
if [ "$INSTALLATION_MODE" != "light" ]; then
  cat > "${PROJECT_DIR}/docker-compose.override.yml" <<'EOF'
version: '3.8'

services:
  kong:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.kong.rule=Host(`${API_HOST}`)"
      - "traefik.http.routers.kong.entrypoints=websecure"
      - "traefik.http.routers.kong.tls.certresolver=myresolver"
      - "traefik.http.services.kong.loadbalancer.server.port=8000"

  studio:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.studio.rule=Host(`${STUDIO_HOST}`)"
      - "traefik.http.routers.studio.entrypoints=websecure"
      - "traefik.http.routers.studio.tls.certresolver=myresolver"
      - "traefik.http.services.studio.loadbalancer.server.port=3000"
EOF
fi

# ---------- Scripts ----------
info "Создаём служебные скрипты..."

cat > "${PROJECT_DIR}/scripts/manage.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Загружаем .env
set -a
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; *=*)
    key="${line%%=*}"; val="${line#*=}"
    if [[ "$val" =~ ^\".*\"$ ]]; then val="${val:1:${#val}-2}"
    elif [[ "$val" =~ ^\'.*\'$ ]]; then val="${val:1:${#val}-2}"; fi
    printf -v "$key" '%s' "$val"; export "$key";;
  esac
done < .env
set +a

MODE="${INSTALLATION_MODE:-standard}"

compose_args=(--env-file .env)
case "$MODE" in
  full|standard)
    compose_args+=(-f compose.supabase.yml -f docker-compose.yml -f docker-compose.override.yml)
    ;;
  rag)
    compose_args+=(-f compose.supabase.rag.yml -f docker-compose.yml -f docker-compose.override.yml)
    ;;
  light)
    compose_args+=(-f docker-compose.yml)
    ;;
  *)
    echo "Unknown mode: $MODE" >&2; exit 1;;
esac

case "${1:-up}" in
  up) docker compose "${compose_args[@]}" up -d ;;
  down) docker compose "${compose_args[@]}" down ;;
  ps) docker compose "${compose_args[@]}" ps ;;
  logs) 
    shift || true
    if [ $# -gt 0 ]; then 
      docker compose "${compose_args[@]}" logs -f --tail=200 "$@"
    else 
      docker compose "${compose_args[@]}" logs -f --tail=200
    fi 
    ;;
  restart) docker compose "${compose_args[@]}" restart ;;
  pull) docker compose "${compose_args[@]}" pull ;;
  exec)
    shift || true
    if [ $# -eq 0 ]; then
      echo "Usage: $0 exec <service> [command]" >&2
      exit 1
    fi
    docker compose "${compose_args[@]}" exec "$@"
    ;;
  *) echo "Usage: $0 {up|down|ps|logs|restart|pull|exec} [args]" ;;
esac
EOF
chmod +x "${PROJECT_DIR}/scripts/manage.sh"

cat > "${PROJECT_DIR}/scripts/backup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; *=*) export "$line" ;; esac
done < .env
set +a

TS=$(date +%Y%m%d_%H%M%S)
mkdir -p backups

# Бэкапим БД n8n (отдельный Postgres)
if docker ps --format '{{.Names}}' | grep -q '^postgres-n8n}
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - EXECUTIONS_MODE=${N8N_EXEC_MODE}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
    depends_on:
      redis:
        condition: service_healthy
      pg-init-n8n:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`${N8N_HOST}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    networks:
      - default
EOF

# Добавляем n8n-worker только для FULL режима
if [ "$INSTALLATION_MODE" = "full" ]; then
  cat >> "${PROJECT_DIR}/docker-compose.yml" <<'EOF'

  n8n-worker:
    <<: *common
    image: n8nio/n8n:1.75.0
    container_name: n8n-worker
    command: worker
    environment:
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${N8N_DB_HOST}
      - DB_POSTGRESDB_PORT=${N8N_DB_PORT; then
  echo "Dumping n8n database from postgres-n8n..."
  docker exec -e PGPASSWORD="${N8N_DB_PASSWORD}" postgres-n8n \
    pg_dump -U postgres -d "${N8N_DB_NAME}" -Fc -f "/tmp/n8n_${TS}.dump" 2>/dev/null || {
    echo "n8n DB may not exist yet; dumping postgres..." >&2
    docker exec -e PGPASSWORD="${N8N_DB_PASSWORD}" postgres-n8n \
      pg_dump -U postgres -d postgres -Fc -f "/tmp/n8n_${TS}.dump"
  }
  docker cp "postgres-n8n:/tmp/n8n_${TS}.dump" "backups/n8n_${TS}.dump"
  docker exec postgres-n8n rm -f "/tmp/n8n_${TS}.dump"
  echo "n8n backup saved: backups/n8n_${TS}.dump"
fi

# Если есть Supabase — бэкапим и его
if docker ps --format '{{.Names}}' | grep -q '^supabase-db}
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - EXECUTIONS_MODE=${N8N_EXEC_MODE}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
    depends_on:
      redis:
        condition: service_healthy
      pg-init-n8n:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`${N8N_HOST}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    networks:
      - default
EOF

# Добавляем n8n-worker только для FULL режима
if [ "$INSTALLATION_MODE" = "full" ]; then
  cat >> "${PROJECT_DIR}/docker-compose.yml" <<'EOF'

  n8n-worker:
    <<: *common
    image: n8nio/n8n:1.75.0
    container_name: n8n-worker
    command: worker
    environment:
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${N8N_DB_HOST}
      - DB_POSTGRESDB_PORT=${N8N_DB_PORT; then
  echo "Dumping supabase database from supabase-db..."
  docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" supabase-db \
    pg_dump -U postgres -d "${POSTGRES_DB}" -Fc -f "/tmp/supabase_${TS}.dump"
  docker cp "supabase-db:/tmp/supabase_${TS}.dump" "backups/supabase_${TS}.dump"
  docker exec supabase-db rm -f "/tmp/supabase_${TS}.dump"
  echo "Supabase backup saved: backups/supabase_${TS}.dump"
fi

# Архивируем важные конфиги
tar -czf "backups/configs_${TS}.tar.gz" .env configs/ credentials.txt 2>/dev/null || true

echo "All backups completed in ./backups/"
ls -lh backups/
EOF
chmod +x "${PROJECT_DIR}/scripts/backup.sh"

cat > "${PROJECT_DIR}/scripts/update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Создаём резервную копию перед обновлением..."
./scripts/backup.sh

echo "Получаем последние образы..."
./scripts/manage.sh pull

echo "Перезапускаем сервисы с новыми образами..."
./scripts/manage.sh up

echo "Ждём инициализации..."
sleep 5

echo "Проверяем статус сервисов..."
./scripts/manage.sh ps

echo "Обновление завершено!"
EOF
chmod +x "${PROJECT_DIR}/scripts/update.sh"

cat > "${PROJECT_DIR}/scripts/health.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; *=*) export "$line" ;; esac
done < .env
set +a

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

check_service() {
  local name="$1" check_cmd="$2"
  printf "%-20s" "$name:"
  if eval "$check_cmd" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ OK${NC}"
    return 0
  else
    echo -e "${RED}✗ FAIL${NC}"
    return 1
  fi
}

echo "=== Health Check ==="
echo

# Core services
check_service "Traefik" "docker exec traefik wget --spider -q http://localhost:80/"
check_service "Redis" "docker exec redis redis-cli -a '${REDIS_PASSWORD}' ping"
check_service "PostgreSQL (n8n)" "docker exec postgres-n8n pg_isready -U postgres"
check_service "n8n" "curl -sf http://localhost:5678/healthz"

if [ "${INSTALLATION_MODE}" = "full" ]; then
  check_service "n8n Worker" "docker ps --format '{{.Names}}' | grep -q '^n8n-worker}
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - EXECUTIONS_MODE=${N8N_EXEC_MODE}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
    depends_on:
      redis:
        condition: service_healthy
      pg-init-n8n:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`${N8N_HOST}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    networks:
      - default
EOF

# Добавляем n8n-worker только для FULL режима
if [ "$INSTALLATION_MODE" = "full" ]; then
  cat >> "${PROJECT_DIR}/docker-compose.yml" <<'EOF'

  n8n-worker:
    <<: *common
    image: n8nio/n8n:1.75.0
    container_name: n8n-worker
    command: worker
    environment:
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${N8N_DB_HOST}
      - DB_POSTGRESDB_PORT=${N8N_DB_PORT"
fi

if [ "${INSTALLATION_MODE}" != "light" ]; then
  echo
  echo "--- Supabase Services ---"
  check_service "Supabase DB" "docker exec supabase-db pg_isready -U postgres"
  check_service "Kong API" "docker exec supabase-kong wget --spider -q http://localhost:8000/"
  check_service "PostgREST" "curl -sf http://localhost:3000/"
  check_service "Auth Service" "curl -sf http://localhost:9999/health"
  check_service "Studio" "curl -sf http://localhost:3000/"
fi

echo
echo "=== External Access ==="
check_service "n8n (${N8N_HOST})" "curl -sfL https://${N8N_HOST}/ -o /dev/null"

if [ "${INSTALLATION_MODE}" != "light" ]; then
  check_service "Studio (${STUDIO_HOST})" "curl -sfL https://${STUDIO_HOST}/ -o /dev/null"
  check_service "API (${API_HOST})" "curl -sfL https://${API_HOST}/ -o /dev/null"
fi

echo
EOF
chmod +x "${PROJECT_DIR}/scripts/health.sh"

info "Управляющие скрипты созданы в ${PROJECT_DIR}/scripts/"

# ---------- Credentials ----------
info "Записываем credentials..."
cat > "${PROJECT_DIR}/credentials.txt" <<EOF
==== MEDIA WORKS — Credentials (${PROJECT_NAME}) ====

Mode: ${INSTALLATION_MODE^^}

=== DOMAINS ===
n8n:     https://${N8N_HOST}
studio:  https://${STUDIO_HOST}
api:     https://${API_HOST}

=== SUPABASE ===
PostgreSQL:
  Host: supabase-db
  Port: 5432
  Database: postgres
  User: postgres
  Password: ${POSTGRES_PASSWORD}

JWT & Keys:
  JWT_SECRET: ${JWT_SECRET}
  ANON_KEY: ${ANON_KEY}
  SERVICE_ROLE_KEY: ${SERVICE_ROLE_KEY}

Studio Dashboard:
  Username: ${DASHBOARD_USERNAME}
  Password: ${DASHBOARD_PASSWORD}

=== N8N DATABASE ===
PostgreSQL (отдельный):
  Host: postgres-n8n
  Port: 5432
  Database: n8n
  User: n8n
  Password: ${N8N_PG_PASSWORD}

n8n Encryption:
  Key: ${N8N_ENCRYPTION_KEY}

=== REDIS ===
Host: redis
Port: 6379
Password: ${REDIS_PASSWORD}

=== CONFIGURATION ===
ACME Email: ${ACME_EMAIL}
OpenAI API Key: ${OPENAI_API_KEY:-[not set]}

=== SMTP ===
Enabled: $([[ "${WANT_SMTP}" =~ ^[Yy]$ ]] && echo YES || echo NO)
Host: ${SMTP_HOST}
Port: ${SMTP_PORT}
User: ${SMTP_USER}
Pass: ${SMTP_PASS}
Sender: ${SMTP_SENDER_NAME}
Admin: ${SMTP_ADMIN_EMAIL}

=== УПРАВЛЕНИЕ ===
Start:   ${PROJECT_DIR}/scripts/manage.sh up
Stop:    ${PROJECT_DIR}/scripts/manage.sh down
Status:  ${PROJECT_DIR}/scripts/manage.sh ps
Logs:    ${PROJECT_DIR}/scripts/manage.sh logs [service]
Backup:  ${PROJECT_DIR}/scripts/backup.sh
Update:  ${PROJECT_DIR}/scripts/update.sh
Health:  ${PROJECT_DIR}/scripts/health.sh
EOF
chmod 600 "${PROJECT_DIR}/credentials.txt"

# ---------- Start stack ----------
info "Запускаем стек..."
pushd "${PROJECT_DIR}" >/dev/null

if [ "$INSTALLATION_MODE" = "light" ]; then
  info "Режим LIGHT: запускаем только n8n стек..."
  ./scripts/manage.sh up
  sleep 10
  wait_for_postgres postgres-n8n || err "PostgreSQL (n8n) не поднялся."
else
  info "Запускаем Supabase и n8n стеки..."
  
  # Сначала базовые сервисы Supabase (vector, db)
  docker compose --env-file .env -f compose.supabase.yml up -d vector 2>/dev/null || true
  sleep 2
  docker compose --env-file .env -f compose.supabase.yml up -d db || err "Не удалось запустить supabase-db"
  
  info "Ждём готовности Supabase DB..."
  wait_for_postgres supabase-db || err "Supabase DB не поднялся."
  
  # Теперь запускаем всё остальное
  ./scripts/manage.sh up
  
  info "Ждём готовности PostgreSQL для n8n..."
  wait_for_postgres postgres-n8n || err "PostgreSQL (n8n) не поднялся."
fi

popd >/dev/null

# ---------- Wait for services ----------
info "Ждём инициализации сервисов (30 секунд)..."
sleep 30

# ---------- Health checks ----------
info "Выполняем health-check'и..."
health_check_all_services || warn "Некоторые сервисы требуют больше времени для запуска"

# ---------- Final check with health script ----------
info "Финальная проверка доступности..."
"${PROJECT_DIR}/scripts/health.sh" || true

# ---------- FOOTER ----------
echo
echo "==============================================="
echo -e "${GREEN}✅ Установка завершена успешно!${NC}"
echo "🚀 MEDIA WORKS Stack развёрнут"
echo "==============================================="
echo
echo "📁 Файлы проекта: ${PROJECT_DIR}"
echo
echo "🔧 Управление:"
echo "   Start/Stop:  ${PROJECT_DIR}/scripts/manage.sh {up|down}"
echo "   Статус:      ${PROJECT_DIR}/scripts/manage.sh ps"
echo "   Логи:        ${PROJECT_DIR}/scripts/manage.sh logs [service]"
echo "   Backup:      ${PROJECT_DIR}/scripts/backup.sh"
echo "   Update:      ${PROJECT_DIR}/scripts/update.sh"
echo "   Health:      ${PROJECT_DIR}/scripts/health.sh"
echo
echo "🔑 Доступы: ${PROJECT_DIR}/credentials.txt (chmod 600)"
echo
echo "🌐 URL адреса:"
echo "   n8n:         https://${N8N_HOST}"
if [ "$INSTALLATION_MODE" != "light" ]; then
  echo "   Studio:      https://${STUDIO_HOST}"
  echo "   API:         https://${API_HOST}"
  echo
  echo "   Dashboard:   ${DASHBOARD_USERNAME} / ${DASHBOARD_PASSWORD}"
fi
echo
echo "⚠️  ВАЖНО:"
echo "   1. Проверьте DNS записи для всех доменов"
echo "   2. Убедитесь, что порты 80/443 открыты в firewall"
echo "   3. Первый запуск может занять до 5 минут"
echo "   4. SSL сертификаты генерируются автоматически"
echo
echo "📖 Документация:"
echo "   Supabase:    https://supabase.com/docs"
echo "   n8n:         https://docs.n8n.io"
echo
echo "💡 Совет: используйте 'tail -f ${PROJECT_DIR}/logs/*.log' для мониторинга"
echo}
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - EXECUTIONS_MODE=${N8N_EXEC_MODE}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
    depends_on:
      redis:
        condition: service_healthy
      pg-init-n8n:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`${N8N_HOST}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    networks:
      - default
EOF

# Добавляем n8n-worker только для FULL режима
if [ "$INSTALLATION_MODE" = "full" ]; then
  cat >> "${PROJECT_DIR}/docker-compose.yml" <<'EOF'

  n8n-worker:
    <<: *common
    image: n8nio/n8n:1.75.0
    container_name: n8n-worker
    command: worker
    environment:
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${N8N_DB_HOST}
      - DB_POSTGRESDB_PORT=${N8N_DB_PORT
