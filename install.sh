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

wait_for_postgres() { # container name
  local svc="$1" max=60 i=1
  while [ $i -le $max ]; do
    if docker exec "$svc" pg_isready -U postgres >/dev/null 2>&1; then return 0; fi
    sleep 2; i=$((i+1))
  done
  return 1
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
    if ! docker exec supabase-kong sh -c 'wget --spider -q http://localhost:8000/ || wget --spider -q http://localhost:8000/status' >/dev/null 2>&1; then
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
mkdir -p "${PROJECT_DIR}/"{configs/traefik,volumes/traefik,volumes/n8n,volumes/postgres_n8n,volumes/logs,volumes/pooler,volumes/db,volumes/api,data,logs,scripts}
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

# Vector / Docker socket (важно!)
DOCKER_SOCKET_LOCATION=/var/run/docker.sock

# Studio defaults
STUDIO_DEFAULT_ORGANIZATION="MEDIA WORKS"
STUDIO_DEFAULT_PROJECT=${PROJECT_NAME}

# n8n / Redis
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
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

# Defaults to silence WARNs
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

# SMTP (даже если не используем — порт должен быть числом)
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
SMTP_SENDER_NAME=${SMTP_SENDER_NAME}
SMTP_ADMIN_EMAIL=${SMTP_ADMIN_EMAIL}
EOF

if [[ "$WANT_SMTP" =~ ^[Yy]$ ]]; then
  cat >> "${PROJECT_DIR}/.env" <<EOF
ENABLE_EMAIL_SIGNUP=true
ENABLE_ANONYMOUS_USERS=false
ENABLE_EMAIL_AUTOCONFIRM=true
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false
EOF
fi

# sanitize
sed -i 's/[[:space:]]*$//' "${PROJECT_DIR}/.env"
sed -i 's/\r$//' "${PROJECT_DIR}/.env"
sed -i '/^[A-Za-z0-9_]\+:\s\+.*/d' "${PROJECT_DIR}/.env"
sed -i 's/^\([A-Z0-9_]\+\)[[:space:]]*=[[:space:]]*/\1=/' "${PROJECT_DIR}/.env"
grep -E '^[A-Z0-9_]+=' "${PROJECT_DIR}/.env" >/dev/null || err "Invalid .env format (нет KEY=VALUE)."

# ---------- Traefik (максимально просто) ----------
info "Создаём конфигурацию Traefik..."
cat > "${PROJECT_DIR}/configs/traefik/traefik.yml" <<'EOF'
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

certificatesResolvers:
  myresolver:
    acme:
      email: "${ACME_EMAIL}"
      storage: /acme/acme.json
      httpChallenge:
        entryPoint: web
EOF

# ---------- Compose files ----------
info "Готовим Docker Compose файлы..."

# 1) Supabase compose (минимальные правки)
if [ "$INSTALLATION_MODE" != "light" ]; then
  cp /root/supabase/docker/docker-compose.yml "${PROJECT_DIR}/compose.supabase.yml"

  # Чистим/копируем volumes
  rm -rf "${PROJECT_DIR}/volumes/logs" "${PROJECT_DIR}/volumes/db" "${PROJECT_DIR}/volumes/pooler" "${PROJECT_DIR}/volumes/api"
  mkdir -p "${PROJECT_DIR}/volumes"
  cp -a /root/supabase/docker/volumes/logs   "${PROJECT_DIR}/volumes/"
  cp -a /root/supabase/docker/volumes/db     "${PROJECT_DIR}/volumes/"
  cp -a /root/supabase/docker/volumes/pooler "${PROJECT_DIR}/volumes/"
  cp -a /root/supabase/docker/volumes/api    "${PROJECT_DIR}/volumes/"

  # db не ждёт vector:healthy (только started) — меньше флапов
  sed -i '0,/\bdb:\b/{:a;N;/depends_on:/!ba;s/vector:\s*\n\s*condition:\s*service_healthy/vector:\n        condition: service_started/}' "${PROJECT_DIR}/compose.supabase.yml"
  # vector монтирует папку, а не файл
  sed -i 's#- \./volumes/logs/vector\.yml:/etc/vector/vector\.yml:ro,z#- ./volumes/logs:/etc/vector:ro,z#' "${PROJECT_DIR}/compose.supabase.yml"
fi

# 2) Наш compose: Traefik + Redis + n8n + отдельный Postgres для n8n
cat > "${PROJECT_DIR}/docker-compose.yml" <<'EOF'
x-common: &common
  restart: unless-stopped
  logging:
    driver: "json-file"
    options: { max-size: "10m", max-file: "3" }

networks: { web: {}, internal: {} }

services:
  traefik:
    <<: *common
    image: traefik:2.11.9
    container_name: traefik
    command:
      - "--providers.docker=true"
      - "--providers.docker.network=${PROJECT_WEB_NET}"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.myresolver.acme.email=${ACME_EMAIL}"
      - "--certificatesresolvers.myresolver.acme.storage=/acme/acme.json"
      - "--certificatesresolvers.myresolver.acme.httpchallenge.entrypoint=web"
    ports: [ "80:80", "443:443" ]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./configs/traefik/traefik.yml:/traefik.yml:ro
      - ./volumes/traefik/acme.json:/acme/acme.json
    networks: [ web ]

  redis:
    <<: *common
    image: redis:7.4.0-alpine
    container_name: redis
    command: ["redis-server","--requirepass","${REDIS_PASSWORD}"]
    networks: [ internal ]

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
    networks: [ internal ]

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
    networks: [ internal ]

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
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
    networks: [ web, internal ]

  n8n-worker:
    <<: *common
    image: n8nio/n8n:1.75.0
    container_name: n8n-worker
    environment:
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
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
    depends_on: [ redis, pg-init-n8n ]
    networks: [ internal ]

  # Лейблы для сервисов Supabase (если они есть в compose.supabase.yml)
  kong:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.kong.rule=Host(`${API_HOST}`)"
      - "traefik.http.routers.kong.entrypoints=web,websecure"
      - "traefik.http.routers.kong.tls.certresolver=myresolver"

  studio:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.studio.rule=Host(`${STUDIO_HOST}`)"
      - "traefik.http.routers.studio.entrypoints=web,websecure"
      - "traefik.http.routers.studio.tls.certresolver=myresolver"
EOF

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

# Имя сети Traefik
if grep -qE '^[[:space:]]*name:[[:space:]]*supabase\b' compose.supabase.yml 2>/dev/null; then
  PROJECT_NAME="supabase"
else
  PROJECT_NAME="$(basename "$PWD")"
fi
export PROJECT_WEB_NET="${PROJECT_NAME}_web"

MODE="${INSTALLATION_MODE:-standard}"

compose_args=()
case "$MODE" in
  full|standard|rag)
    compose_args=(--env-file .env -f compose.supabase.yml -f docker-compose.yml)
    ;;
  light)
    compose_args=(--env-file .env -f docker-compose.yml)
    ;;
  *)
    echo "Unknown mode: $MODE" >&2; exit 1;;
esac

case "${1:-up}" in
  up) docker compose "${compose_args[@]}" up -d ;;
  down) docker compose "${compose_args[@]}" down ;;
  ps) docker compose "${compose_args[@]}" ps ;;
  logs) shift || true
        if [ $# -gt 0 ]; then docker compose "${compose_args[@]}" logs -f --tail=200 "$@"
        else docker compose "${compose_args[@]}" logs -f --tail=200; fi ;;
  restart) docker compose "${compose_args[@]}" restart ;;
  pull) docker compose "${compose_args[@]}" pull ;;
  *) echo "Usage: $0 {up|down|ps|logs|restart|pull}" ;;
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

# Бэкапим БД n8n (отдельный Postgres)
DB_CONT="postgres-n8n"
echo "Dumping n8n database from ${DB_CONT}..."
docker exec -e PGPASSWORD="${N8N_DB_PASSWORD}" "${DB_CONT}" pg_dump -U postgres -d "${N8N_DB_NAME}" -Fc -f "/tmp/n8n_${TS}.dump" || {
  echo "n8n DB may not exist yet; trying postgres..." >&2
  docker exec -e PGPASSWORD="${N8N_DB_PASSWORD}" "${DB_CONT}" pg_dump -U postgres -d postgres -Fc -f "/tmp/n8n_${TS}.dump"
}
docker cp "${DB_CONT}:/tmp/n8n_${TS}.dump" "backups/n8n_${TS}.dump"
docker exec "${DB_CONT}" rm -f "/tmp/n8n_${TS}.dump"

# Если есть Supabase — бэкапим и его
if docker ps --format '{{.Names}}' | grep -q '^supabase-db$'; then
  echo "Dumping supabase database from supabase-db..."
  docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" supabase-db pg_dump -U postgres -d "${POSTGRES_DB}" -Fc -f "/tmp/supabase_${TS}.dump"
  docker cp "supabase-db:/tmp/supabase_${TS}.dump" "backups/supabase_${TS}.dump"
  docker exec "supabase-db" rm -f "/tmp/supabase_${TS}.dump"
fi

echo "Backups saved in ./backups/"
EOF
chmod +x "${PROJECT_DIR}/scripts/backup.sh"

cat > "${PROJECT_DIR}/scripts/update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/manage.sh pull
./scripts/manage.sh up
sleep 3
EOF
chmod +x "${PROJECT_DIR}/scripts/update.sh"

info "Важно: для управления стеком используйте:"
echo "  ${PROJECT_DIR}/scripts/manage.sh (он подставляет нужные compose-файлы)."

# ---------- Credentials ----------
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
  Studio Dashboard: ${DASHBOARD_USERNAME} / ${DASHBOARD_PASSWORD}

n8n Postgres (отдельный):
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

# ---------- Start stack ----------
info "Запускаем стек по зависимостям..."
pushd "${PROJECT_DIR}" >/dev/null

if [ "$INSTALLATION_MODE" = "light" ]; then
  ./scripts/manage.sh up
  wait_for_postgres postgres-n8n || err "PostgreSQL (n8n) не поднялся."
else
  # Сначала supabase core (vector + db) с явным --env-file
  docker compose --env-file .env -f compose.supabase.yml up -d vector || true
  docker compose --env-file .env -f compose.supabase.yml up -d db || err "Не удалось запустить supabase-db"
  wait_for_postgres supabase-db || err "Supabase DB не поднялся."
  ./scripts/manage.sh up
  wait_for_postgres postgres-n8n || err "PostgreSQL (n8n) не поднялся."
fi

# ---------- Health checks ----------
info "Выполняем health-check’и..."
health_check_all_services

popd >/dev/null

# ---------- FOOTER ----------
echo
echo "==============================================="
echo -e "✅ ${GREEN}Установка завершена успешно!${NC}"
echo "🚀 MEDIA WORKS — отдельные Postgres для Supabase и n8n"
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
