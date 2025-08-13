#!/usr/bin/env bash
set -euo pipefail

# =============== MEDIA WORKS — MASTER INSTALLER ===============
# Supabase (self-hosted) + n8n + PostgreSQL + Redis + Traefik
# Режимы: FULL | STANDARD | RAG | LIGHT
# Debian/Ubuntu, запуск ТОЛЬКО от root
# =============================================================

# ---------- Оформление ----------
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

          MEDIA WORKS — Автоматизированная установка стека
         (Supabase self-hosted + n8n + PostgreSQL + Redis + Traefik)
BANNER
}
banner

# ---------- Проверки окружения ----------
[ "$(id -u)" -eq 0 ] || err "Запустите скрипт от root (sudo -i)."
[ -f /etc/os-release ] || err "Не найден /etc/os-release — не могу определить дистрибутив."
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ok "Обнаружена ОС: ${NAME}";;
  *) err "Поддерживаются только Debian/Ubuntu. Обнаружено: ${NAME}";;
esac

# ---------- Хелперы ----------
retry() { # retry <cmd...>
  local attempt=1 max=3 delay=5
  while true; do
    if "$@"; then return 0; fi
    if [ $attempt -ge $max ]; then return 1; fi
    warn "Попытка ${attempt}/${max} не удалась. Повтор через ${delay}s..."
    attempt=$((attempt+1)); sleep $delay
  done
}

gen_alnum() { # gen_alnum <len>
  local len="${1:-32}"
  (tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len") || true
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

wait_pg_ready() { # wait_pg_ready <container_name> [timeout_sec]
  local svc="$1" timeout="${2:-120}" t=0
  while [ $t -lt $timeout ]; do
    if docker exec "$svc" pg_isready -U postgres >/dev/null 2>&1; then return 0; fi
    sleep 2; t=$((t+2))
  done
  return 1
}

check_ports() {
  info "Проверяем порты 80/443..."
  for p in 80 443; do
    if ss -tln "( sport = :$p )" | grep -q ":$p"; then
      if systemctl is-active --quiet nginx 2>/dev/null; then
        warn "Порт $p занят nginx — пробую остановить nginx..."
        systemctl stop nginx || true
      fi
      if systemctl is-active --quiet apache2 2>/dev/null; then
        warn "Порт $p занят apache2 — пробую остановить apache2..."
        systemctl stop apache2 || true
      fi
    fi
    if ss -tln "( sport = :$p )" | grep -q ":$p"; then
      warn "Порт $p всё ещё занят. Traefik может не запуститься."
    fi
  done
  ok "Проверка портов завершена."
}

# ---------- Ввод параметров ----------
echo
info "Введите параметры установки (обязательные помечены *)."

# Имя проекта — только буквы (требование), переводим в нижний регистр
read -rp " * Имя проекта/каталога (только буквы): " RAW_NAME
RAW_NAME="${RAW_NAME//[[:space:]]/}"
[[ -n "$RAW_NAME" && "$RAW_NAME" =~ ^[A-Za-z]+$ ]] || err "Имя проекта обязательно и должно состоять только из букв (A–Z, a–z)."
PROJECT_NAME="$(echo "$RAW_NAME" | tr '[:upper:]' '[:lower:]')"
PROJECT_DIR="/root/${PROJECT_NAME}"

read -rp " * Основной домен (пример: example.com): " ROOT_DOMAIN
[ -n "${ROOT_DOMAIN:-}" ] || err "Основной домен обязателен."

DEF_N8N="n8n.${ROOT_DOMAIN}"
read -rp " * Поддомен для n8n [${DEF_N8N}]: " N8N_HOST
N8N_HOST="${N8N_HOST:-$DEF_N8N}"

DEF_STUDIO="studio.${ROOT_DOMAIN}"
read -rp "   Поддомен Supabase Studio [${DEF_STUDIO}]: " STUDIO_HOST
STUDIO_HOST="${STUDIO_HOST:-$DEF_STUDIO}"

DEF_API="api.${ROOT_DOMAIN}"
read -rp "   Поддомен API (Kong) [${DEF_API}]: " API_HOST
API_HOST="${API_HOST:-$DEF_API}"

read -rp " * Email для Let's Encrypt (ACME): " ACME_EMAIL
[ -n "${ACME_EMAIL:-}" ] || err "Email обязателен."

read -rp "   OpenAI API Key (опционально, Enter чтобы пропустить): " OPENAI_API_KEY
OPENAI_API_KEY="${OPENAI_API_KEY:-}"

read -rp "   Настроить SMTP для Supabase (y/N)? " WANT_SMTP
WANT_SMTP="${WANT_SMTP:-N}"
if [[ "$WANT_SMTP" =~ ^[Yy]$ ]]; then
  read -rp "   SMTP Host: " SMTP_HOST
  read -rp "   SMTP Port (587/465): " SMTP_PORT
  read -rp "   SMTP User: " SMTP_USER
  read -rsp "   SMTP Password: " SMTP_PASS; echo
  read -rp "   SMTP Sender Name (например 'My App'): " SMTP_SENDER_NAME
  read -rp "   SMTP Admin Email: " SMTP_ADMIN_EMAIL
else
  SMTP_HOST=""; SMTP_PORT="587"; SMTP_USER=""; SMTP_PASS=""
  SMTP_SENDER_NAME=""; SMTP_ADMIN_EMAIL="admin@${ROOT_DOMAIN}"
fi

echo
info "Выберите режим установки:"
echo "  1) FULL     — Supabase(всё) + n8n main+worker (queue) + Redis + Traefik"
echo "  2) STANDARD — Supabase(всё) + n8n (single) + Redis + Traefik"
echo "  3) RAG      — Supabase (vector+studio+kong+rest+meta+pooler+auth+db) + n8n + Traefik"
echo "  4) LIGHT    — n8n + PostgreSQL (отд.) + Redis + Traefik (без Supabase)"
read -rp "Ваш выбор [1-4]: " MODE
case "${MODE:-}" in
  1) INSTALLATION_MODE="full" ;;
  2) INSTALLATION_MODE="standard" ;;
  3) INSTALLATION_MODE="rag" ;;
  4) INSTALLATION_MODE="light" ;;
  *) err "Неверный выбор." ;;
esac
ok "Режим: ${INSTALLATION_MODE^^}"

# ---------- Проверка портов ----------
check_ports

# ---------- Зависимости (Docker, compose, утилиты) ----------
info "Устанавливаем зависимости..."
retry apt-get update -y || err "apt-get update не удалось."
retry apt-get install -y ca-certificates curl gnupg lsb-release git wget openssl net-tools jq || err "Не удалось установить базовые пакеты."
if ! command -v docker >/dev/null 2>&1; then
  info "Устанавливаем Docker (официальный install script)..."
  retry sh -c "curl -fsSL https://get.docker.com | sh" || err "Установка Docker не удалась."
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true
fi
ok "Docker установлен."
if ! docker compose version >/dev/null 2>&1; then
  info "Устанавливаем docker compose plugin..."
  retry apt-get install -y docker-compose-plugin || warn "Не удалось поставить docker-compose-plugin из APT."
fi
docker compose version >/dev/null 2>&1 || err "Не найден docker compose."

# ---------- Каталоги ----------
info "Готовим структуру каталогов..."
mkdir -p "/root/supabase"
mkdir -p "${PROJECT_DIR}"/{configs/traefik,volumes/traefik,volumes/n8n,volumes/postgres_n8n,volumes/logs,volumes/pooler,volumes/db,volumes/api,volumes/storage,volumes/functions,backups,scripts}
touch "${PROJECT_DIR}/volumes/traefik/acme.json"
chmod 600 "${PROJECT_DIR}/volumes/traefik/acme.json"
ok "Каталоги готовы: ${PROJECT_DIR}"

# ---------- Supabase репозиторий ----------
if [ ! -d "/root/supabase/.git" ]; then
  info "Клонируем Supabase (self-hosted) репозиторий..."
  git clone --depth=1 https://github.com/supabase/supabase.git /root/supabase || err "Клонирование supabase не удалось."
else
  info "Обновляем Supabase репозиторий..."
  (cd /root/supabase && git fetch --depth 1 origin && git reset --hard origin/HEAD) || warn "Не удалось обновить supabase, продолжаем с текущей копией."
fi

# ---------- Секреты / ключи ----------
info "Генерируем секреты и ключи..."
POSTGRES_PASSWORD="$(gen_alnum 32)"      # Supabase DB (postgres user)
N8N_PG_PASSWORD="$(gen_alnum 32)"        # postgres-n8n (postgres user пароль)
N8N_ENCRYPTION_KEY="$(gen_alnum 32)"
REDIS_PASSWORD="$(gen_alnum 24)"
DASHBOARD_USERNAME="admin"
DASHBOARD_PASSWORD="$(gen_alnum 24)"
JWT_SECRET="$(gen_alnum 40)"

now_epoch=$(date +%s)
exp_epoch=$(( now_epoch + 20*365*24*3600 )) # 20 лет
ANON_PAYLOAD=$(printf '{"role":"anon","iss":"supabase","iat":%d,"exp":%d}' "$now_epoch" "$exp_epoch")
SERVICE_PAYLOAD=$(printf '{"role":"service_role","iss":"supabase","iat":%d,"exp":%d}' "$now_epoch" "$exp_epoch")
ANON_KEY="$(jwt_hs256 "$JWT_SECRET" "$ANON_PAYLOAD")"
SERVICE_ROLE_KEY="$(jwt_hs256 "$JWT_SECRET" "$SERVICE_PAYLOAD")"

# Доп. значения для Supabase
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

: "${SMTP_HOST:=}"
: "${SMTP_PORT:=587}"
: "${SMTP_USER:=}"
: "${SMTP_PASS:=}"
: "${SMTP_SENDER_NAME:=}"
: "${SMTP_ADMIN_EMAIL:=admin@${ROOT_DOMAIN}}"

# Режим исполнения n8n
if [ "$INSTALLATION_MODE" = "full" ]; then
  N8N_EXEC_MODE="queue"
else
  N8N_EXEC_MODE="regular"
fi
ok "Секреты сгенерированы."

# ---------- .env ----------
info "Формируем .env..."
cat > "${PROJECT_DIR}/.env" <<EOF
# === MEDIA WORKS generated .env (${PROJECT_NAME}) ===

# Mode / domains
INSTALLATION_MODE=${INSTALLATION_MODE}
ROOT_DOMAIN=${ROOT_DOMAIN}
N8N_HOST=${N8N_HOST}
STUDIO_HOST=${STUDIO_HOST}
API_HOST=${API_HOST}
ACME_EMAIL=${ACME_EMAIL}

# OpenAI (опционально)
OPENAI_API_KEY=${OPENAI_API_KEY}

# Supabase core
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=postgres
POSTGRES_HOST=db
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

# Studio defaults (брендинг)
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
N8N_DB_USER=postgres
N8N_DB_PASSWORD=${N8N_PG_PASSWORD}

# Auth toggles
ENABLE_EMAIL_SIGNUP=false
ENABLE_ANONYMOUS_USERS=true
ENABLE_EMAIL_AUTOCONFIRM=false
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false

# Defaults / secrets
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

# Очистка .env
sed -i 's/[[:space:]]*$//' "${PROJECT_DIR}/.env"
sed -i 's/\r$//' "${PROJECT_DIR}/.env"
grep -E '^[A-Z0-9_]+=' "${PROJECT_DIR}/.env" >/dev/null || err "Некорректный .env (нет строк KEY=VALUE)."
ok ".env готов."

# ---------- Traefik ----------
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

certificatesResolvers:
  myresolver:
    acme:
      email: "${ACME_EMAIL}"
      storage: /acme/acme.json
      httpChallenge:
        entryPoint: web

log:
  level: WARN
accessLog: {}
EOF
ok "Traefik конфигурация создана."

# ---------- Compose файлы ----------
info "Готовим Docker Compose файлы..."

# 1) Supabase compose (копируем как есть; список сервисов выберем при запуске)
if [ "$INSTALLATION_MODE" != "light" ]; then
  cp /root/supabase/docker/docker-compose.yml "${PROJECT_DIR}/compose.supabase.yml"
  # Скопируем шаблонные volume-папки (если есть)
  for d in logs db pooler api storage functions; do
    [ -d "/root/supabase/docker/volumes/$d" ] && cp -a "/root/supabase/docker/volumes/$d" "${PROJECT_DIR}/volumes/" || true
  done
fi

# 2) Наш compose: Traefik + Redis + PostgreSQL (n8n) + n8n (+ worker при FULL)
cat > "${PROJECT_DIR}/docker-compose.yml" <<'EOF'
version: '3.8'

x-common: &common
  restart: unless-stopped
  logging:
    driver: "json-file"
    options: { max-size: "10m", max-file: "3" }

services:
  traefik:
    <<: *common
    image: traefik:2.11
    container_name: traefik
    command:
      - "--providers.docker=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.myresolver.acme.email=${ACME_EMAIL}"
      - "--certificatesresolvers.myresolver.acme.storage=/acme/acme.json"
      - "--certificatesresolvers.myresolver.acme.httpchallenge.entrypoint=web"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./volumes/traefik/acme.json:/acme/acme.json:rw

  redis:
    <<: *common
    image: redis:7.4.0-alpine
    container_name: redis
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]

  postgres-n8n:
    <<: *common
    image: postgres:15-alpine
    container_name: postgres-n8n
    environment:
      POSTGRES_PASSWORD: ${N8N_DB_PASSWORD}
      POSTGRES_DB: ${N8N_DB_NAME}
      POSTGRES_USER: ${N8N_DB_USER}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${N8N_DB_USER} -d ${N8N_DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 10
    volumes:
      - ./volumes/postgres_n8n:/var/lib/postgresql/data

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
      - DB_POSTGRESDB_HOST=postgres-n8n
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - EXECUTIONS_MODE=${N8N_EXEC_MODE}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - NODE_FUNCTION_ALLOW_EXTERNAL=*
    depends_on:
      postgres-n8n:
        condition: service_healthy
      redis:
        condition: service_started
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
EOF

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
      - DB_POSTGRESDB_HOST=postgres-n8n
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=${N8N_DB_PASSWORD}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
    depends_on:
      postgres-n8n:
        condition: service_healthy
      redis:
        condition: service_started
EOF
fi

# 3) Override для Traefik (Supabase Studio + Kong)
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

# ---------- Служебные скрипты ----------
info "Создаём служебные скрипты..."

# manage.sh — единая точка управления
cat > "${PROJECT_DIR}/scripts/manage.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Загружаем .env в окружение
set -a
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; *=*)
    key="${line%%=*}"; val="${line#*=}"
    if [[ "$val" =~ ^\".*\"$ ]]; then val="${val:1:${#val}-2}"; fi
    if [[ "$val" =~ ^\'.*\'$ ]]; then val="${val:1:${#val}-2}"; fi
    printf -v "$key" '%s' "$val"; export "$key";;
  esac
done < .env
set +a

MODE="${INSTALLATION_MODE:-standard}"

supabase_up() {
  # Запуск supabase сервисов в зависимости от режима
  if [ "$MODE" = "light" ]; then return 0; fi
  if [ ! -f compose.supabase.yml ]; then
    echo "compose.supabase.yml не найден" >&2; exit 1
  fi
  if [ "$MODE" = "rag" ]; then
    # Старт только нужных сервисов RAG
    docker compose --env-file .env -f compose.supabase.yml up -d db vector meta pooler rest auth kong studio
  else
    # FULL/STANDARD — весь набор Supabase
    docker compose --env-file .env -f compose.supabase.yml up -d
  fi
}

supabase_down() {
  [ "$MODE" = "light" ] || docker compose --env-file .env -f compose.supabase.yml down || true
}

stack_up() {
  supabase_up
  # Наш основной compose + override для Traefik/Studio/Kong
  if [ "$MODE" = "light" ]; then
    docker compose --env-file .env -f docker-compose.yml up -d
  else
    docker compose --env-file .env -f docker-compose.yml -f docker-compose.override.yml up -d
  fi
}

case "${1:-up}" in
  up) stack_up ;;
  down)
      docker compose --env-file .env -f docker-compose.yml down || true
      supabase_down
      ;;
  ps)
      if [ "$MODE" = "light" ]; then
        docker compose --env-file .env -f docker-compose.yml ps
      else
        docker compose --env-file .env -f compose.supabase.yml ps
        docker compose --env-file .env -f docker-compose.yml ps
      fi
      ;;
  logs)
      shift || true
      if [ "$MODE" = "light" ]; then
        docker compose --env-file .env -f docker-compose.yml logs -f --tail=200 "$@"
      else
        docker compose --env-file .env -f compose.supabase.yml logs -f --tail=100 || true &
        docker compose --env-file .env -f docker-compose.yml logs -f --tail=200 "$@"
      fi
      ;;
  restart) ./scripts/manage.sh down && ./scripts/manage.sh up ;;
  pull)
      [ "$MODE" = "light" ] || docker compose --env-file .env -f compose.supabase.yml pull
      docker compose --env-file .env -f docker-compose.yml pull
      ;;
  *) echo "Usage: $0 {up|down|ps|logs|restart|pull} [service]";;
esac
EOF
chmod +x "${PROJECT_DIR}/scripts/manage.sh"

# backup.sh — резервные копии БД
cat > "${PROJECT_DIR}/scripts/backup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
. ./.env
set +a

TS=$(date +%Y%m%d_%H%M%S)
mkdir -p backups

# n8n Postgres
if docker ps --format '{{.Names}}' | grep -q '^postgres-n8n$'; then
  echo "Резервное копирование БД n8n..."
  docker exec -e PGPASSWORD="${N8N_DB_PASSWORD}" postgres-n8n \
    pg_dump -U "${N8N_DB_USER}" -d "${N8N_DB_NAME}" -Fc -f "/tmp/n8n_${TS}.dump" || {
      echo "Не найдено БД ${N8N_DB_NAME}, пробую postgres..." >&2
      docker exec -e PGPASSWORD="${N8N_DB_PASSWORD}" postgres-n8n \
        pg_dump -U "${N8N_DB_USER}" -d postgres -Fc -f "/tmp/n8n_${TS}.dump"
    }
  docker cp "postgres-n8n:/tmp/n8n_${TS}.dump" "backups/n8n_${TS}.dump"
  docker exec postgres-n8n rm -f "/tmp/n8n_${TS}.dump"
fi

# Supabase Postgres
if docker ps --format '{{.Names}}' | grep -Eq '^(db|supabase-db)$'; then
  DB_CONT="$(docker ps --format '{{.Names}}' | grep -E '^(db|supabase-db)$' | head -n1)"
  echo "Резервное копирование БД Supabase (${DB_CONT})..."
  docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${DB_CONT}" \
    pg_dump -U postgres -d "${POSTGRES_DB}" -Fc -f "/tmp/supabase_${TS}.dump"
  docker cp "${DB_CONT}:/tmp/supabase_${TS}.dump" "backups/supabase_${TS}.dump"
  docker exec "${DB_CONT}" rm -f "/tmp/supabase_${TS}.dump"
fi

echo "Готово. Файлы в ./backups/"
EOF
chmod +x "${PROJECT_DIR}/scripts/backup.sh"

# update.sh — обновление образов
cat > "${PROJECT_DIR}/scripts/update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== Бэкап перед обновлением =="
./scripts/backup.sh || true
echo "== Получаем последние образы =="
./scripts/manage.sh pull
echo "== Перезапускаем стек =="
./scripts/manage.sh up
echo "Готово."
EOF
chmod +x "${PROJECT_DIR}/scripts/update.sh"

# health.sh — простые проверки доступности
cat > "${PROJECT_DIR}/scripts/health.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok(){ echo -e "${GREEN}OK${NC} $*"; }
bad(){ echo -e "${RED}FAIL${NC} $*"; }

chk_running(){ docker ps --format '{{.Names}}' | grep -q "^$1$"; }
chk_healthy(){ [ "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo "")" = "healthy" ] || [ "$(docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo "")" = "running" ]; }

# Основные
for s in traefik redis postgres-n8n n8n; do
  if chk_running "$s" && chk_healthy "$s"; then ok "$s"; else bad "$s"; fi
done

# Supabase (если есть)
if docker ps --format '{{.Names}}' | grep -Eq '^(db|supabase-db)$'; then
  DB_CONT="$(docker ps --format '{{.Names}}' | grep -E '^(db|supabase-db)$' | head -n1)"
  chk_healthy "$DB_CONT" && ok "supabase-db" || bad "supabase-db"
fi
for s in kong studio rest auth; do
  if docker ps --format '{{.Names}}' | grep -q "^$s$"; then
    chk_healthy "$s" && ok "$s" || bad "$s"
  fi
done
EOF
chmod +x "${PROJECT_DIR}/scripts/health.sh"

ok "Скрипты готовы."

# ---------- Credentials ----------
info "Записываем credentials..."
cat > "${PROJECT_DIR}/credentials.txt" <<EOF
==== MEDIA WORKS — Credentials (${PROJECT_NAME}) ====

Режим: ${INSTALLATION_MODE^^}

ДОМЕНЫ / URL:
  n8n:    https://${N8N_HOST}
  studio: https://${STUDIO_HOST}
  api:    https://${API_HOST}

SUPABASE:
  PostgreSQL:
    Host: db
    Port: 5432
    DB:   ${POSTGRES_DB}
    User: postgres
    Pass: ${POSTGRES_PASSWORD}

  JWT:
    JWT_SECRET: ${JWT_SECRET}
    ANON_KEY: ${ANON_KEY}
    SERVICE_ROLE_KEY: ${SERVICE_ROLE_KEY}

  Studio (вход):
    User: ${DASHBOARD_USERNAME}
    Pass: ${DASHBOARD_PASSWORD}

n8n DATABASE (отдельный Postgres):
  Host: postgres-n8n
  Port: 5432
  DB:   ${N8N_DB_NAME}
  User: ${N8N_DB_USER}
  Pass: ${N8N_DB_PASSWORD}

n8n:
  ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
  EXECUTIONS_MODE: ${N8N_EXEC_MODE}

Redis:
  Host: redis
  Port: 6379
  Pass: ${REDIS_PASSWORD}

ACME email: ${ACME_EMAIL}
OpenAI API Key: ${OPENAI_API_KEY:-[not set]}

SMTP:
  Enabled: $([[ "${WANT_SMTP}" =~ ^[Yy]$ ]] && echo YES || echo NO)
  Host: ${SMTP_HOST}
  Port: ${SMTP_PORT}
  User: ${SMTP_USER}
  Pass: ${SMTP_PASS}
  Sender: ${SMTP_SENDER_NAME}
  Admin: ${SMTP_ADMIN_EMAIL}

УПРАВЛЕНИЕ:
  Start/Stop: ${PROJECT_DIR}/scripts/manage.sh {up|down}
  Status:     ${PROJECT_DIR}/scripts/manage.sh ps
  Logs:       ${PROJECT_DIR}/scripts/manage.sh logs [service]
  Backup:     ${PROJECT_DIR}/scripts/backup.sh
  Update:     ${PROJECT_DIR}/scripts/update.sh
  Health:     ${PROJECT_DIR}/scripts/health.sh
EOF
chmod 600 "${PROJECT_DIR}/credentials.txt"
ok "Credentials: ${PROJECT_DIR}/credentials.txt"

# ---------- Запуск стека ----------
info "Запускаем стек..."
pushd "${PROJECT_DIR}" >/dev/null

# Сначала — Supabase DB, затем всё остальное (для режимов кроме LIGHT)
if [ "$INSTALLATION_MODE" = "light" ]; then
  ./scripts/manage.sh up
  sleep 6
  wait_pg_ready postgres-n8n || err "PostgreSQL (n8n) не стартовал."
else
  # Старт supabase (как минимум db), затем основной стек
  if [ -f compose.supabase.yml ]; then
    if [ "$INSTALLATION_MODE" = "rag" ]; then
      docker compose --env-file .env -f compose.supabase.yml up -d db
    else
      docker compose --env-file .env -f compose.supabase.yml up -d db
    fi
    sleep 3
    # контейнер DB называется 'db' в supabase compose
    wait_pg_ready db || err "Supabase DB не стартовал."
  fi
  ./scripts/manage.sh up
  sleep 6
  wait_pg_ready postgres-n8n || warn "PostgreSQL (n8n) ещё инициализируется."
fi

# Небольшая пауза и health-check
info "Ожидание инициализации сервисов (30 секунд)..."
sleep 30
./scripts/health.sh || true
popd >/dev/null

ok "Установка завершена."
echo
echo "Директория проекта: ${PROJECT_DIR}"
echo "Credentials:        ${PROJECT_DIR}/credentials.txt"
echo
echo "URL-адреса:"
echo "  n8n:    https://${N8N_HOST}"
if [ "$INSTALLATION_MODE" != "light" ]; then
  echo "  Studio: https://${STUDIO_HOST}"
  echo "  API:    https://${API_HOST}"
  echo "  Вход в Studio: ${DASHBOARD_USERNAME} / ${DASHBOARD_PASSWORD}"
fi
echo
echo "Важно:"
echo " • Убедитесь, что DNS поддомены указывают на этот сервер."
echo " • Порты 80/443 должны быть открыты во внешнем фаерволе."
echo " • SSL-сертификаты выпустятся автоматически (ACME) при первом доступе."
echo
echo "Команды:"
echo "  ${PROJECT_DIR}/scripts/manage.sh up      # запустить/перезапустить"
echo "  ${PROJECT_DIR}/scripts/manage.sh logs    # логи (можно добавить имя сервиса)"
echo "  ${PROJECT_DIR}/scripts/health.sh         # быстрый health-check"
echo "  ${PROJECT_DIR}/scripts/backup.sh         # резервная копия БД"
echo "  ${PROJECT_DIR}/scripts/update.sh         # обновление образов"
