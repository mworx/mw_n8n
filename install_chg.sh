#!/usr/bin/env bash
# =============================================================================
# MEDIA WORKS — Универсальный установщик
# Supabase (self-hosted) + n8n + Traefik (+ Redis, отдельный Postgres для n8n)
# Режимы: FULL | STANDARD | RAG | LIGHT
# Запуск: curl -fsSL https://.../install.sh | bash
# =============================================================================
set -euo pipefail

# ----------------------------- Цвета/оформление ------------------------------
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
/_/  /_/_____/_____/___/_/  |_|     |__/|__/\____/_/ |_/_/ |_/____/
                     MEDIA WORKS — Авторазвёртывание
    Supabase + n8n + Traefik (LE) | FULL / STANDARD / RAG / LIGHT
BANNER
}
banner

# ----------------------------- Предварительные проверки -----------------------
[ "$(id -u)" -eq 0 ] || err "Скрипт требуется запускать от root."

# Проверка ОС
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VER="${VERSION_ID:-unknown}"
else
  err "Не удалось определить ОС. Нужен Debian/Ubuntu."
fi
case "$OS_ID" in
  ubuntu|debian) ok "Обнаружена ОС: $PRETTY_NAME";;
  *) err "Поддерживаются только Debian/Ubuntu. Найдено: $PRETTY_NAME";;
esac

# ----------------------------- Переменные и пути ------------------------------
PROJECT_DIR="/root/n8n-traefik"
SUPABASE_REPO_DIR="/root/supabase"
CONFIGS_DIR="$PROJECT_DIR/configs"
TRAEFIK_DIR="$CONFIGS_DIR/traefik"
VOLUMES_DIR="$PROJECT_DIR/volumes"
SCRIPTS_DIR="$PROJECT_DIR/scripts"
BACKUPS_DIR="$PROJECT_DIR/backups"
ENV_FILE="$PROJECT_DIR/.env"
CREDS_FILE="$PROJECT_DIR/credentials.txt"
COMPOSE_MAIN="$PROJECT_DIR/docker-compose.yml"
COMPOSE_SUPABASE="$PROJECT_DIR/compose.supabase.yml"
COMPOSE_OVERRIDE="$PROJECT_DIR/docker-compose.override.yml"

# Docker сети/префиксы
COMPOSE_PROJECT_NAME="n8n_supabase"
export COMPOSE_PROJECT_NAME

# ----------------------------- Установка зависимостей -------------------------
retry_apt() {
  local tries=3
  for i in $(seq 1 $tries); do
    if apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; then
      return 0
    fi
    warn "apt-get попытка $i из $tries не удалась. Повтор..."
    sleep 3
  done
  return 1
}

info "Проверка и установка зависимостей: curl, git, jq, openssl, ca-certificates, net-tools/ss..."
retry_apt ca-certificates curl git jq openssl lsb-release gnupg net-tools iproute2 > /dev/null 2>&1 || err "Не удалось установить базовые пакеты."

# Docker
if ! command -v docker >/dev/null 2>&1; then
  info "Установка Docker Engine и плагина compose..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
  retry_apt docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1 || err "Не удалось установить Docker."
  systemctl enable --now docker
  ok "Docker установлен."
else
  ok "Docker уже установлен."
fi

if ! docker compose version >/dev/null 2>&1; then
  err "Плагин docker compose не найден. Проверьте установку Docker."
fi

# ----------------------------- Проверка портов 80/443 -------------------------
check_and_free_port() {
  local port="$1"
  if ss -ltn '( sport = :'"$port"' )' | awk 'NR>1{exit 0} END{exit 1}'; then
    return 0 # свободен
  fi
  warn "Порт $port занят. Попытка остановить nginx/apache2..."
  systemctl stop nginx 2>/dev/null || true
  systemctl stop apache2 2>/dev/null || true
  sleep 1
  if ss -ltn '( sport = :'"$port"' )' | awk 'NR>1{exit 0} END{exit 1}'; then
    return 0
  fi
  warn "Порт $port по-прежнему занят. Traefik/ACME могут не заработать."
  return 1
}
check_and_free_port 80 || true
check_and_free_port 443 || true

# ----------------------------- Ввод пользователя ------------------------------
read_nonempty() {
  local prompt="$1"
  local var
  while true; do
    read -rp "$prompt" var || true
    [ -n "${var:-}" ] && { echo "$var"; return 0; }
    echo "Поле обязательно. Повторите ввод."
  done
}

valid_domain() {
  local d="$1"
  [[ "$d" =~ ^([a-zA-Z0-9](-*[a-zA-Z0-9])*\.)+[a-zA-Z]{2,}$ ]]
}

ROOT_DOMAIN=""
while true; do
  ROOT_DOMAIN="$(read_nonempty "Введите корневой домен (например, example.com): ")"
  if valid_domain "$ROOT_DOMAIN"; then break; else echo "Некорректный домен. Пример: example.com"; fi
done

# Поддомены с дефолтами
default_n8n_sub="n8n"
default_studio_sub="studio"
default_api_sub="api"
default_traefik_sub="traefik"

read -rp "Поддомен для n8n (по умолч. ${default_n8n_sub}): " N8N_SUB || true
N8N_SUB="${N8N_SUB:-$default_n8n_sub}"

read -rp "Поддомен для Supabase Studio (по умолч. ${default_studio_sub}): " STUDIO_SUB || true
STUDIO_SUB="${STUDIO_SUB:-$default_studio_sub}"

read -rp "Поддомен для API (Kong) (по умолч. ${default_api_sub}): " API_SUB || true
API_SUB="${API_SUB:-$default_api_sub}"

read -rp "Поддомен для Traefik (по умолч. ${default_traefik_sub}): " TRAEFIK_SUB || true
TRAEFIK_SUB="${TRAEFIK_SUB:-$default_traefik_sub}"

N8N_HOST="${N8N_SUB}.${ROOT_DOMAIN}"
STUDIO_HOST="${STUDIO_SUB}.${ROOT_DOMAIN}"
API_HOST="${API_SUB}.${ROOT_DOMAIN}"
TRAEFIK_HOST="${TRAEFIK_SUB}.${ROOT_DOMAIN}"

# Email для ACME
ACME_EMAIL="$(read_nonempty "Email для Let's Encrypt (ACME): ")"

# Выбор режима
echo "Выберите режим установки:"
echo "  1) FULL     — Supabase (все модули), n8n queue (main+worker), Redis, Traefik, Postgres для n8n"
echo "  2) STANDARD — Supabase (все модули), n8n regular, Traefik, Postgres для n8n"
echo "  3) RAG      — Supabase урезанный (db, auth, rest, meta, pooler, kong, studio, vector), n8n regular"
echo "  4) LIGHT    — только Traefik + n8n regular (+ Redis не нужен) + Postgres для n8n"
MODE=""
while true; do
  read -rp "Режим [1-4]: " choice || true
  case "$choice" in
    1) MODE="FULL"; break;;
    2) MODE="STANDARD"; break;;
    3) MODE="RAG"; break;;
    4) MODE="LIGHT"; break;;
    *) echo "Введите 1, 2, 3 или 4.";;
  esac
done
ok "Выбран режим: $MODE"

# ----------------------------- Генерация секретов -----------------------------
# Только A–Za–z0–9
rand_alnum() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"; }

# base64url без '=' и замены символов
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# JWT HS256 генерация: header.payload.signature
jwt_hs256() {
  local role="$1" secret="$2" iat exp header payload signing_input sig
  iat="$(date +%s)"
  # 20 лет ~ 630720000 секунд
  exp=$((iat + 630720000))
  header='{"alg":"HS256","typ":"JWT"}'
  payload=$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$role" "$iat" "$exp")
  header_b64="$(printf '%s' "$header" | b64url)"
  payload_b64="$(printf '%s' "$payload" | b64url)"
  signing_input="${header_b64}.${payload_b64}"
  # raw binary HMAC-SHA256, затем base64url
  sig="$(printf '%s' "$signing_input" | openssl dgst -binary -sha256 -hmac "$secret" | b64url)"
  printf '%s.%s' "$signing_input" "$sig"
}

DOCKER_SOCKET_LOCATION="/var/run/docker.sock"

# Создадим каталоги
mkdir -p "$PROJECT_DIR" "$TRAEFIK_DIR" "$VOLUMES_DIR/traefik" "$VOLUMES_DIR/postgres_n8n" "$VOLUMES_DIR/n8n" \
         "$VOLUMES_DIR/db" "$VOLUMES_DIR/pooler" "$VOLUMES_DIR/logs" "$SCRIPTS_DIR" "$BACKUPS_DIR"

# acme.json
touch "$VOLUMES_DIR/traefik/acme.json"
chmod 600 "$VOLUMES_DIR/traefik/acme.json"

# Если .env уже есть — подгрузим значения, но не перезатираем секреты
declare -A EXISTING
if [ -f "$ENV_FILE" ]; then
  info "Обнаружен существующий .env — значения секретов будут сохранены."
  while IFS='=' read -r k v; do
    [[ -z "${k// }" || "$k" =~ ^# ]] && continue
    v="${v%$'\r'}"
    v="${v%\"}"; v="${v#\"}"  # убрать возможные кавычки
    EXISTING["$k"]="$v"
  done < "$ENV_FILE"
fi

# Заполнение переменных, сохраняя прежние (если были)
POSTGRES_PASSWORD="${EXISTING[POSTGRES_PASSWORD]:-$(rand_alnum 32)}"
N8N_DB_PASSWORD="${EXISTING[N8N_DB_PASSWORD]:-$(rand_alnum 32)}"
JWT_SECRET="${EXISTING[JWT_SECRET]:-$(rand_alnum 40)}"
ANON_KEY="${EXISTING[ANON_KEY]:-$(jwt_hs256 anon "$JWT_SECRET")}"
SERVICE_ROLE_KEY="${EXISTING[SERVICE_ROLE_KEY]:-$(jwt_hs256 service_role "$JWT_SECRET")}"
DASHBOARD_USERNAME="${EXISTING[DASHBOARD_USERNAME]:-admin}"
DASHBOARD_PASSWORD="${EXISTING[DASHBOARD_PASSWORD]:-$(rand_alnum 28)}"
N8N_ENCRYPTION_KEY="${EXISTING[N8N_ENCRYPTION_KEY]:-$(rand_alnum 32)}"
REDIS_PASSWORD="${EXISTING[REDIS_PASSWORD]:-$(rand_alnum 28)}"
SECRET_KEY_BASE="${EXISTING[SECRET_KEY_BASE]:-$(rand_alnum 64)}"
VAULT_ENC_KEY="${EXISTING[VAULT_ENC_KEY]:-$(rand_alnum 64)}"
LOGFLARE_API_KEY="${EXISTING[LOGFLARE_API_KEY]:-$(rand_alnum 40)}"
LOGFLARE_LOGGER_BACKEND_API_KEY="${EXISTING[LOGFLARE_LOGGER_BACKEND_API_KEY]:-$(rand_alnum 40)}"
POOLER_TENANT_ID="${EXISTING[POOLER_TENANT_ID]:-$(rand_alnum 12)}"

# SMTP (по умолчанию выключено, но SMTP_PORT обязателен числом)
SMTP_HOST="${EXISTING[SMTP_HOST]:-}"
SMTP_PORT="${EXISTING[SMTP_PORT]:-587}"
SMTP_USER="${EXISTING[SMTP_USER]:-}"
SMTP_PASS="${EXISTING[SMTP_PASS]:-}"
SMTP_SENDER_NAME="${EXISTING[SMTP_SENDER_NAME]:-}"
SMTP_ADMIN_EMAIL="${EXISTING[SMTP_ADMIN_EMAIL]:-$ACME_EMAIL}"

if [[ -z "$SMTP_HOST" ]]; then
  ENABLE_EMAIL_SIGNUP="false"; ENABLE_ANONYMOUS_USERS="true"; ENABLE_EMAIL_AUTOCONFIRM="false"
else
  ENABLE_EMAIL_SIGNUP="true"; ENABLE_ANONYMOUS_USERS="false"; ENABLE_EMAIL_AUTOCONFIRM="true"
fi

# ----------------------------- Запись .env ------------------------------------
cat > "$ENV_FILE" <<EOF
# ======================= БАЗОВЫЕ ДОМЕНЫ/ПОЧТА =======================
ROOT_DOMAIN=${ROOT_DOMAIN}
N8N_HOST=${N8N_HOST}
STUDIO_HOST=${STUDIO_HOST}
API_HOST=${API_HOST}
TRAEFIK_HOST=${TRAEFIK_HOST}
ACME_EMAIL=${ACME_EMAIL}

# ======================= КОНФИГ SUPABASE ============================
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=postgres
POSTGRES_HOST=db
POSTGRES_PORT=5432

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
DOCKER_SOCKET_LOCATION=${DOCKER_SOCKET_LOCATION}
IMGPROXY_ENABLE_WEBP_DETECTION=true
PGRST_DB_SCHEMAS=public

SECRET_KEY_BASE=${SECRET_KEY_BASE}
VAULT_ENC_KEY=${VAULT_ENC_KEY}
LOGFLARE_API_KEY=${LOGFLARE_API_KEY}
LOGFLARE_LOGGER_BACKEND_API_KEY=${LOGFLARE_LOGGER_BACKEND_API_KEY}

POOLER_PROXY_PORT_TRANSACTION=6543
POOLER_DEFAULT_POOL_SIZE=20
POOLER_MAX_CLIENT_CONN=100
POOLER_TENANT_ID=${POOLER_TENANT_ID}
POOLER_DB_POOL_SIZE=5
STUDIO_DEFAULT_ORGANIZATION=MEDIA WORKS
STUDIO_DEFAULT_PROJECT=${POOLER_TENANT_ID}

# ======================= АВТОРИЗАЦИЯ (GoTrue) =======================
ENABLE_EMAIL_SIGNUP=${ENABLE_EMAIL_SIGNUP}
ENABLE_ANONYMOUS_USERS=${ENABLE_ANONYMOUS_USERS}
ENABLE_EMAIL_AUTOCONFIRM=${ENABLE_EMAIL_AUTOCONFIRM}
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false
FUNCTIONS_VERIFY_JWT=false
DISABLE_SIGNUP=false
ADDITIONAL_REDIRECT_URLS=
MAILER_URLPATHS_CONFIRMATION=/auth/v1/verify
MAILER_URLPATHS_INVITE=/auth/v1/verify
MAILER_URLPATHS_RECOVERY=/auth/v1/verify
MAILER_URLPATHS_EMAIL_CHANGE=/auth/v1/verify

# ======================= SMTP (опц.) =================================
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS}
SMTP_SENDER_NAME=${SMTP_SENDER_NAME}
SMTP_ADMIN_EMAIL=${SMTP_ADMIN_EMAIL}

# ======================= n8n / Redis / Postgres-n8n ==================
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_DB_HOST=postgres-n8n
N8N_DB_PORT=5432
N8N_DB_NAME=n8n
N8N_DB_USER=n8n
N8N_DB_PASSWORD=${N8N_DB_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}

# ======================= ПРОЧЕЕ =====================================
INSTALL_MODE=${MODE}
EOF

ok "Создан .env с параметрами окружения."

# ----------------------------- Traefik конфиг -------------------------------
cat > "$TRAEFIK_DIR/traefik.yml" <<'EOF'
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true
  websecure:
    address: ":443"

providers:
  docker:
    exposedByDefault: false

api:
  dashboard: false

certificatesResolvers:
  myresolver:
    acme:
      email: "${ACME_EMAIL}"
      storage: "/acme/acme.json"
      httpChallenge:
        entryPoint: web
EOF
ok "Записан статический конфиг Traefik."

# ----------------------------- docker-compose (наш) --------------------------
cat > "$COMPOSE_MAIN" <<'EOF'
services:
  traefik:
    image: traefik:2.11
    command: ["--providers.docker=true","--providers.docker.exposedbydefault=false","--entrypoints.web.address=:80","--entrypoints.websecure.address=:443"]
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - ACME_EMAIL=${ACME_EMAIL}
    volumes:
      - ./configs/traefik/traefik.yml:/traefik.yml:ro
      - ./volumes/traefik/acme.json:/acme/acme.json
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
      - "traefik.enable=true"

  postgres-n8n:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${N8N_DB_NAME}
      - POSTGRES_USER=${N8N_DB_USER}
      - POSTGRES_PASSWORD=${N8N_DB_PASSWORD}
    volumes:
      - ./volumes/postgres_n8n:/var/lib/postgresql/data

  redis:
    image: redis:7.4-alpine
    restart: unless-stopped
    command: ["redis-server","--appendonly","yes","--requirepass","${REDIS_PASSWORD}"]
    volumes:
      - ./volumes/n8n:/data
    # запускается и используется только в режиме FULL (n8n queue)
    deploy:
      replicas: 1

  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    environment:
      - GENERIC_TIMEZONE=Europe/Berlin
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${N8N_DB_HOST}
      - DB_POSTGRESDB_PORT=${N8N_DB_PORT}
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - N8N_PROTOCOL=https
      - N8N_HOST=${N8N_HOST}
      - WEBHOOK_URL=https://${N8N_HOST}/
      - EXECUTIONS_MODE=${EXECUTIONS_MODE:-regular}
      # Параметры очереди (будут проигнорированы, если EXECUTIONS_MODE=regular)
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
    depends_on:
      - postgres-n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"

  n8n-worker:
    image: n8nio/n8n:latest
    restart: unless-stopped
    command: ["n8n","worker"]
    environment:
      - GENERIC_TIMEZONE=Europe/Berlin
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=${N8N_DB_HOST}
      - DB_POSTGRESDB_PORT=${N8N_DB_PORT}
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
    depends_on:
      - postgres-n8n
      - redis
    deploy:
      replicas: 0   # по умолчанию выключен; в режиме FULL включим через override

networks:
  default:
    name: ${COMPOSE_PROJECT_NAME}_web
EOF
ok "Создан наш docker-compose.yml."

# ----------------------------- compose Supabase -------------------------------
if [ "$MODE" != "LIGHT" ]; then
  info "Генерируем compose.supabase.yml для Supabase (${MODE})."
  if [ "$MODE" = "RAG" ]; then
    # Урезанный набор сервисов
    cat > "$COMPOSE_SUPABASE" <<'EOF'
services:
  db:
    image: supabase/postgres:15.1.1.81
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - ./volumes/db:/var/lib/postgresql/data

  pooler:
    image: supabase/supavisor:1.1.56
    restart: unless-stopped
    environment:
      - DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/postgres
      - PROXY_PORT_TRANSACTION=${POOLER_PROXY_PORT_TRANSACTION}
      - DEFAULT_POOL_SIZE=${POOLER_DEFAULT_POOL_SIZE}
      - MAX_CLIENT_CONN=${POOLER_MAX_CLIENT_CONN}
      - TENANT_ID=${POOLER_TENANT_ID}
      - DB_POOL_SIZE=${POOLER_DB_POOL_SIZE}
    depends_on:
      - db

  auth:
    image: supabase/gotrue:v2.164.0
    restart: unless-stopped
    environment:
      - GOTRUE_DB_DRIVER=postgres
      - DB_NAMESPACE=auth
      - API_EXTERNAL_URL=${API_EXTERNAL_URL}
      - SITE_URL=${SITE_URL}
      - GOTRUE_JWT_SECRET=${JWT_SECRET}
      - GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated
      - GOTRUE_AUD=authenticated
      - ENABLE_EMAIL_SIGNUP=${ENABLE_EMAIL_SIGNUP}
      - ENABLE_EMAIL_AUTOCONFIRM=${ENABLE_EMAIL_AUTOCONFIRM}
      - ENABLE_ANONYMOUS_USERS=${ENABLE_ANONYMOUS_USERS}
      - SMTP_HOST=${SMTP_HOST}
      - SMTP_PORT=${SMTP_PORT}
      - SMTP_USER=${SMTP_USER}
      - SMTP_PASS=${SMTP_PASS}
      - SMTP_ADMIN_EMAIL=${SMTP_ADMIN_EMAIL}
      - MAILER_URLPATHS_CONFIRMATION=${MAILER_URLPATHS_CONFIRMATION}
      - MAILER_URLPATHS_INVITE=${MAILER_URLPATHS_INVITE}
      - MAILER_URLPATHS_RECOVERY=${MAILER_URLPATHS_RECOVERY}
      - MAILER_URLPATHS_EMAIL_CHANGE=${MAILER_URLPATHS_EMAIL_CHANGE}
      - GOTRUE_LOG_LEVEL=info
      - DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/postgres
    depends_on:
      - db

  rest:
    image: postgrest/postgrest:v12.2.3
    restart: unless-stopped
    environment:
      - PGRST_DB_URI=postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/postgres
      - PGRST_DB_SCHEMAS=${PGRST_DB_SCHEMAS}
      - PGRST_DB_ANON_ROLE=anon
      - PGRST_APP_SETTINGS.external_api_url=${SUPABASE_PUBLIC_URL}
    depends_on:
      - db

  meta:
    image: supabase/pg-meta:v0.84.11
    restart: unless-stopped
    environment:
      - PG_META_DB_HOST=db
      - PG_META_DB_PORT=5432
      - PG_META_DB_NAME=postgres
      - PG_META_DB_USER=postgres
      - PG_META_DB_PASSWORD=${POSTGRES_PASSWORD}
    depends_on:
      - db

  vector:
    image: supabase/vector:0.40.0
    restart: unless-stopped
    environment:
      - DOCKER_SOCKET_LOCATION=${DOCKER_SOCKET_LOCATION}
    volumes:
      - ${DOCKER_SOCKET_LOCATION}:${DOCKER_SOCKET_LOCATION}:ro

  kong:
    image: kong:3.6
    restart: unless-stopped
    environment:
      - KONG_DATABASE=off
      - KONG_DECLARATIVE_CONFIG=/kong.yml
      - KONG_LOG_LEVEL=warn
      - SUPABASE_ANON_KEY=${ANON_KEY}
      - SUPABASE_SERVICE_KEY=${SERVICE_ROLE_KEY}
      - SUPABASE_JWT_SECRET=${JWT_SECRET}
      - SUPABASE_REST_URL=http://rest:3000
      - SUPABASE_META_URL=http://meta:8080
      - SUPABASE_AUTH_URL=http://auth:9999
      - SUPABASE_PUBLIC_URL=${SUPABASE_PUBLIC_URL}
    depends_on:
      - auth
      - rest
      - meta
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.api.rule=Host(`${API_HOST}`)"
      - "traefik.http.routers.api.entrypoints=websecure"
      - "traefik.http.routers.api.tls.certresolver=myresolver"
      - "traefik.http.services.api.loadbalancer.server.port=8000"
    ports:
      - "8000"

  studio:
    image: supabase/studio:20250702-93b9d5f
    restart: unless-stopped
    environment:
      - NEXT_PUBLIC_SUPABASE_URL=${SUPABASE_PUBLIC_URL}
      - NEXT_PUBLIC_SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
      - DASHBOARD_USERNAME=${DASHBOARD_USERNAME}
      - DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}
      - STUDIO_DEFAULT_ORGANIZATION=${STUDIO_DEFAULT_ORGANIZATION}
      - STUDIO_DEFAULT_PROJECT=${STUDIO_DEFAULT_PROJECT}
    depends_on:
      - kong
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.studio.rule=Host(`${STUDIO_HOST}`)"
      - "traefik.http.routers.studio.entrypoints=websecure"
      - "traefik.http.routers.studio.tls.certresolver=myresolver"
      - "traefik.http.services.studio.loadbalancer.server.port=3000"
EOF
  else
    # Полный стек (на основе актуальных образов; без storage/realtime/etc. метим позже через update)
    cat > "$COMPOSE_SUPABASE" <<'EOF'
services:
  db:
    image: supabase/postgres:15.1.1.81
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - ./volumes/db:/var/lib/postgresql/data

  pooler:
    image: supabase/supavisor:1.1.56
    restart: unless-stopped
    environment:
      - DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/postgres
      - PROXY_PORT_TRANSACTION=${POOLER_PROXY_PORT_TRANSACTION}
      - DEFAULT_POOL_SIZE=${POOLER_DEFAULT_POOL_SIZE}
      - MAX_CLIENT_CONN=${POOLER_MAX_CLIENT_CONN}
      - TENANT_ID=${POOLER_TENANT_ID}
      - DB_POOL_SIZE=${POOLER_DB_POOL_SIZE}
    depends_on:
      - db

  auth:
    image: supabase/gotrue:v2.164.0
    restart: unless-stopped
    environment:
      - GOTRUE_DB_DRIVER=postgres
      - DB_NAMESPACE=auth
      - API_EXTERNAL_URL=${API_EXTERNAL_URL}
      - SITE_URL=${SITE_URL}
      - GOTRUE_JWT_SECRET=${JWT_SECRET}
      - GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated
      - GOTRUE_AUD=authenticated
      - ENABLE_EMAIL_SIGNUP=${ENABLE_EMAIL_SIGNUP}
      - ENABLE_EMAIL_AUTOCONFIRM=${ENABLE_EMAIL_AUTOCONFIRM}
      - ENABLE_ANONYMOUS_USERS=${ENABLE_ANONYMOUS_USERS}
      - SMTP_HOST=${SMTP_HOST}
      - SMTP_PORT=${SMTP_PORT}
      - SMTP_USER=${SMTP_USER}
      - SMTP_PASS=${SMTP_PASS}
      - SMTP_ADMIN_EMAIL=${SMTP_ADMIN_EMAIL}
      - MAILER_URLPATHS_CONFIRMATION=${MAILER_URLPATHS_CONFIRMATION}
      - MAILER_URLPATHS_INVITE=${MAILER_URLPATHS_INVITE}
      - MAILER_URLPATHS_RECOVERY=${MAILER_URLPATHS_RECOVERY}
      - MAILER_URLPATHS_EMAIL_CHANGE=${MAILER_URLPATHS_EMAIL_CHANGE}
      - GOTRUE_LOG_LEVEL=info
      - DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/postgres
    depends_on:
      - db

  rest:
    image: postgrest/postgrest:v12.2.3
    restart: unless-stopped
    environment:
      - PGRST_DB_URI=postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/postgres
      - PGRST_DB_SCHEMAS=${PGRST_DB_SCHEMAS}
      - PGRST_DB_ANON_ROLE=anon
      - PGRST_APP_SETTINGS.external_api_url=${SUPABASE_PUBLIC_URL}
    depends_on:
      - db

  meta:
    image: supabase/pg-meta:v0.84.11
    restart: unless-stopped
    environment:
      - PG_META_DB_HOST=db
      - PG_META_DB_PORT=5432
      - PG_META_DB_NAME=postgres
      - PG_META_DB_USER=postgres
      - PG_META_DB_PASSWORD=${POSTGRES_PASSWORD}
    depends_on:
      - db

  vector:
    image: supabase/vector:0.40.0
    restart: unless-stopped
    environment:
      - DOCKER_SOCKET_LOCATION=${DOCKER_SOCKET_LOCATION}
    volumes:
      - ${DOCKER_SOCKET_LOCATION}:${DOCKER_SOCKET_LOCATION}:ro

  kong:
    image: kong:3.6
    restart: unless-stopped
    environment:
      - KONG_DATABASE=off
      - KONG_DECLARATIVE_CONFIG=/kong.yml
      - KONG_LOG_LEVEL=warn
      - SUPABASE_ANON_KEY=${ANON_KEY}
      - SUPABASE_SERVICE_KEY=${SERVICE_ROLE_KEY}
      - SUPABASE_JWT_SECRET=${JWT_SECRET}
      - SUPABASE_REST_URL=http://rest:3000
      - SUPABASE_META_URL=http://meta:8080
      - SUPABASE_AUTH_URL=http://auth:9999
      - SUPABASE_PUBLIC_URL=${SUPABASE_PUBLIC_URL}
    depends_on:
      - auth
      - rest
      - meta
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.api.rule=Host(`${API_HOST}`)"
      - "traefik.http.routers.api.entrypoints=websecure"
      - "traefik.http.routers.api.tls.certresolver=myresolver"
      - "traefik.http.services.api.loadbalancer.server.port=8000"
    ports:
      - "8000"

  studio:
    image: supabase/studio:20250702-93b9d5f
    restart: unless-stopped
    environment:
      - NEXT_PUBLIC_SUPABASE_URL=${SUPABASE_PUBLIC_URL}
      - NEXT_PUBLIC_SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
      - DASHBOARD_USERNAME=${DASHBOARD_USERNAME}
      - DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}
      - STUDIO_DEFAULT_ORGANIZATION=${STUDIO_DEFAULT_ORGANIZATION}
      - STUDIO_DEFAULT_PROJECT=${STUDIO_DEFAULT_PROJECT}
    depends_on:
      - kong
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.studio.rule=Host(`${STUDIO_HOST}`)"
      - "traefik.http.routers.studio.entrypoints=websecure"
      - "traefik.http.routers.studio.tls.certresolver=myresolver"
      - "traefik.http.services.studio.loadbalancer.server.port=3000"
EOF
  fi
  ok "Создан compose.supabase.yml."
fi

# ----------------------------- override для FULL ------------------------------
if [ "$MODE" = "FULL" ]; then
  cat > "$COMPOSE_OVERRIDE" <<'EOF'
services:
  n8n-worker:
    deploy:
      replicas: 1
  redis:
    deploy:
      replicas: 1
  n8n:
    environment:
      - EXECUTIONS_MODE=queue
EOF
  ok "Создан docker-compose.override.yml для режима FULL (включён worker и Redis)."
fi

# ----------------------------- Скрипты обслуживания ---------------------------
# manage.sh
cat > "$SCRIPTS_DIR/manage.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
COMPOSE_MAIN="$ROOT_DIR/docker-compose.yml"
COMPOSE_SUPABASE="$ROOT_DIR/compose.supabase.yml"
COMPOSE_OVERRIDE="$ROOT_DIR/docker-compose.override.yml"

# безопасный импорт .env в окружение (без source)
if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r k v; do
    [[ -z "${k// }" || "$k" =~ ^# ]] && continue
    v="${v%$'\r'}"; v="${v%\"}"; v="${v#\"}"
    export "$k=$v"
  done < "$ENV_FILE"
fi

MODE="${INSTALL_MODE:-LIGHT}"

compose_cmd=(docker compose)
files=(-f "$COMPOSE_MAIN")
if [ "$MODE" != "LIGHT" ] && [ -f "$COMPOSE_SUPABASE" ]; then
  files=(-f "$COMPOSE_SUPABASE" -f "$COMPOSE_MAIN")
fi
if [ "$MODE" = "FULL" ] && [ -f "$COMPOSE_OVERRIDE" ]; then
  files+=(-f "$COMPOSE_OVERRIDE")
fi

case "${1:-}" in
  up)        "${compose_cmd[@]}" "${files[@]}" up -d;;
  down)      "${compose_cmd[@]}" "${files[@]}" down;;
  restart)   "${compose_cmd[@]}" "${files[@]}" down; "${compose_cmd[@]}" "${files[@]}" up -d;;
  logs)      shift; "${compose_cmd[@]}" "${files[@]}" logs -f --tail=200 "${@:-}";;
  ps)        "${compose_cmd[@]}" "${files[@]}" ps;;
  pull)      "${compose_cmd[@]}" "${files[@]}" pull;;
  *) echo "Использование: $0 {up|down|restart|logs [svc]|ps|pull}"; exit 1;;
esac
EOF
chmod +x "$SCRIPTS_DIR/manage.sh"

# backup.sh
cat > "$SCRIPTS_DIR/backup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUPS="$ROOT_DIR/backups"
mkdir -p "$BACKUPS"
ts="$(date +%Y%m%d_%H%M%S)"

echo "[ INFO ] Бэкап n8n БД..."
docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T postgres-n8n pg_dump -U n8n -d n8n > "$BACKUPS/n8n_${ts}.sql" || {
  echo "[ WARN ] Не удалось снять бэкап n8n через exec. Попытка через отдельный контейнер..."
  docker run --rm --network ${COMPOSE_PROJECT_NAME}_web -e PGPASSWORD=$(grep '^N8N_DB_PASSWORD=' "$ROOT_DIR/.env" | cut -d= -f2) postgres:16-alpine \
    pg_dump -h postgres-n8n -U n8n -d n8n > "$BACKUPS/n8n_${ts}.sql"
}

if [ -f "$ROOT_DIR/compose.supabase.yml" ]; then
  echo "[ INFO ] Бэкап Supabase (postgres)..."
  docker compose -f "$ROOT_DIR/compose.supabase.yml" -f "$ROOT_DIR/docker-compose.yml" exec -T db pg_dump -U postgres -d postgres > "$BACKUPS/supabase_${ts}.sql" || true
fi

echo "[ OK ] Бэкап сохранён в $BACKUPS"
EOF
chmod +x "$SCRIPTS_DIR/backup.sh"

# update.sh
cat > "$SCRIPTS_DIR/update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "[ INFO ] Создание бэкапа перед обновлением..."
"$ROOT_DIR/scripts/backup.sh" || true
echo "[ INFO ] Обновление образов..."
docker compose -f "$ROOT_DIR/docker-compose.yml" pull || true
if [ -f "$ROOT_DIR/compose.supabase.yml" ]; then
  docker compose -f "$ROOT_DIR/compose.supabase.yml" -f "$ROOT_DIR/docker-compose.yml" pull || true
fi
echo "[ INFO ] Перезапуск..."
"$ROOT_DIR/scripts/manage.sh" restart
echo "[ OK ] Обновление завершено."
EOF
chmod +x "$SCRIPTS_DIR/update.sh"

# health.sh
cat > "$SCRIPTS_DIR/health.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "[ INFO ] Статусы контейнеров:"
docker compose -f "$ROOT_DIR/docker-compose.yml" ps
if [ -f "$ROOT_DIR/compose.supabase.yml" ]; then
  docker compose -f "$ROOT_DIR/compose.supabase.yml" -f "$ROOT_DIR/docker-compose.yml" ps
fi
echo "[ INFO ] Быстрые HTTP проверки (может занять время при первом старте)..."
set +e
curl -sS -I "https://$(grep '^N8N_HOST=' "$ROOT_DIR/.env" | cut -d= -f2)" | head -n1
curl -sS -I "https://$(grep '^STUDIO_HOST=' "$ROOT_DIR/.env" | cut -d= -f2)" | head -n1
curl -sS -I "https://$(grep '^API_HOST=' "$ROOT_DIR/.env" | cut -d= -f2)" | head -n1
set -e
echo "[ OK ] Проверка завершена."
EOF
chmod +x "$SCRIPTS_DIR/health.sh"

ok "Созданы скрипты manage/backup/update/health."

# ----------------------------- README и креды --------------------------------
cat > "$PROJECT_DIR/README.md" <<EOF
# MEDIA WORKS — Развёрнутое окружение

## URL-адреса
- n8n: https://${N8N_HOST}
- Supabase Studio: https://${STUDIO_HOST}
- Supabase API (Kong): https://${API_HOST}

## Полезные команды
\`\`\`bash
cd $PROJECT_DIR
./scripts/manage.sh up         # запуск
./scripts/manage.sh ps         # статус
./scripts/manage.sh logs       # логи
./scripts/manage.sh restart    # рестарт
./scripts/health.sh            # быстрый health-check
./scripts/backup.sh            # бэкап БД
./scripts/update.sh            # обновление образов и перезапуск
\`\`\`

## Важно
1. Убедитесь, что DNS записи для поддоменов указывают на IP сервера.
2. Порты 80/443 должны быть свободны (Traefik + ACME).
3. Файл \`credentials.txt\` содержит сгенерированные ключи и пароли — храните в секрете.
4. SMTP по умолчанию отключён. Для включения писем Supabase заполните SMTP_* в .env и перезапустите.
EOF

cat > "$CREDS_FILE" <<EOF
================= СГЕНЕРИРОВАННЫЕ ДАННЫЕ (ХРАНИТЬ В СЕКРЕТЕ) =================
Домены:
  ROOT_DOMAIN=${ROOT_DOMAIN}
  n8n:    https://${N8N_HOST}
  studio: https://${STUDIO_HOST}
  api:    https://${API_HOST}

Supabase:
  POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
  JWT_SECRET=${JWT_SECRET}
  ANON_KEY=${ANON_KEY}
  SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
  DASHBOARD_USERNAME=${DASHBOARD_USERNAME}
  DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}

n8n / Redis / Postgres-n8n:
  N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
  N8N_DB_USER=n8n
  N8N_DB_PASSWORD=${N8N_DB_PASSWORD}
  N8N_DB_NAME=n8n
  REDIS_PASSWORD=${REDIS_PASSWORD}

SMTP:
  SMTP_HOST=${SMTP_HOST}
  SMTP_PORT=${SMTP_PORT}
  SMTP_USER=${SMTP_USER}
  SMTP_PASS=${SMTP_PASS}
  SMTP_ADMIN_EMAIL=${SMTP_ADMIN_EMAIL}
===============================================================================
EOF
chmod 600 "$CREDS_FILE"

ok "Сгенерирован credentials.txt и README.md."

# ----------------------------- Запуск стеков ----------------------------------
info "Загрузка образов (docker compose pull)... это может занять некоторое время."
if [ "$MODE" = "LIGHT" ]; then
  docker compose -f "$COMPOSE_MAIN" pull || true
else
  if [ "$MODE" = "FULL" ] && [ -f "$COMPOSE_OVERRIDE" ]; then
    docker compose -f "$COMPOSE_SUPABASE" -f "$COMPOSE_MAIN" -f "$COMPOSE_OVERRIDE" pull || true
  else
    docker compose -f "$COMPOSE_SUPABASE" -f "$COMPOSE_MAIN" pull || true
  fi
fi

info "Запуск сервисов..."
if [ "$MODE" = "LIGHT" ]; then
  EXECUTIONS_MODE="regular" docker compose -f "$COMPOSE_MAIN" up -d
else
  if [ "$MODE" = "STANDARD" ] || [ "$MODE" = "RAG" ]; then
    EXECUTIONS_MODE="regular" docker compose -f "$COMPOSE_SUPABASE" -f "$COMPOSE_MAIN" up -d
  elif [ "$MODE" = "FULL" ]; then
    EXECUTIONS_MODE="queue" docker compose -f "$COMPOSE_SUPABASE" -f "$COMPOSE_MAIN" -f "$COMPOSE_OVERRIDE" up -d
  fi
fi

# ----------------------------- Health-check -----------------------------------
info "Проверка статуса контейнеров..."
sleep 5
if [ "$MODE" = "LIGHT" ]; then
  docker compose -f "$COMPOSE_MAIN" ps
else
  if [ "$MODE" = "FULL" ] && [ -f "$COMPOSE_OVERRIDE" ]; then
    docker compose -f "$COMPOSE_SUPABASE" -f "$COMPOSE_MAIN" -f "$COMPOSE_OVERRIDE" ps
  else
    docker compose -f "$COMPOSE_SUPABASE" -f "$COMPOSE_MAIN" ps
  fi
fi

# Быстрая проверка HTTP заголовков (может вернуть 404/200 — главное, что отвечает)
set +e
curl -sS -I "https://${N8N_HOST}" | head -n1
[ "$MODE" != "LIGHT" ] && curl -sS -I "https://${STUDIO_HOST}" | head -n1
[ "$MODE" != "LIGHT" ] && curl -sS -I "https://${API_HOST}" | head -n1
set -e

ok "Установка завершена!"

cat <<EOF

══════════════════════════════════════════════════════════════════════
Готово! Ваше окружение запущено.

URL:
  - n8n:               https://${N8N_HOST}
  - Supabase Studio:   https://${STUDIO_HOST}   (логин: ${DASHBOARD_USERNAME})
  - Supabase API:      https://${API_HOST}

Файлы и скрипты:
  - Проект:            ${PROJECT_DIR}
  - Конфиги Traefik:   ${TRAEFIK_DIR}/traefik.yml
  - Compose:           ${COMPOSE_MAIN} $( [ "$MODE" != "LIGHT" ] && echo "+ ${COMPOSE_SUPABASE}" )
  - Скрипты:           ${SCRIPTS_DIR}/manage.sh | backup.sh | update.sh | health.sh
  - Креды:             ${CREDS_FILE}

Чек-лист:
  1) Проверьте DNS для поддоменов: ${N8N_HOST}, ${STUDIO_HOST}, ${API_HOST}
  2) Убедитесь, что порты 80/443 открыты
  3) Если TLS не выпустился — смотрите логи Traefik:  ./scripts/manage.sh logs traefik
  4) Для писем (SMTP) заполните SMTP_* в .env и перезапустите: ./scripts/manage.sh restart

Повторный запуск скрипта не ломает текущую установку (секреты сохраняются).
Удачной работы!
══════════════════════════════════════════════════════════════════════
EOF
