#!/usr/bin/env bash
set -euo pipefail

# ================================
# MEDIA WORKS — n8n + RAG Installer
# Traefik + n8n (+worker) + Qdrant + Postgres16(pgvector) + Redis
# One-line ready: curl https://.../install_chatgpt.sh | bash
# ================================

# ---------- Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
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
/_/  /_/_____/_____/___/_/  |_|     |__/|__/\____/_/ |_/_/ |_/____/  mworks.ru

MEDIA WORKS — Автоматическая установка n8n + RAG
BANNER
}

# ---------- Preconditions ----------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Запустите скрипт от root (sudo -i; затем ./install_chatgpt.sh)"
  fi
}

check_os() {
  source /etc/os-release || err "Не удалось прочитать /etc/os-release"
  case "${ID,,}" in
    ubuntu|debian) ;;
    *) err "Поддерживаются только Ubuntu 22.04–24.04 и Debian 11/12" ;;
  esac
  ok "Обнаружена ОС: $PRETTY_NAME"
}

check_ports() {
  local conflicts=""
  command -v netstat >/dev/null 2>&1 || apt-get update -y && apt-get install -y net-tools >/dev/null
  if netstat -tulpen | grep -qE "LISTEN\s+0\s+.*:80\s"; then conflicts="80"; fi
  if netstat -tulpen | grep -qE "LISTEN\s+0\s+.*:443\s"; then conflicts="${conflicts} 443"; fi

  if [[ -n "$conflicts" ]]; then
    warn "Порты заняты:${conflicts}"
    # Пытаемся остановить стандартные веб-сервера
    systemctl stop nginx  >/dev/null 2>&1 || true
    systemctl stop apache2 >/dev/null 2>&1 || true
    sleep 1
    conflicts=""
    if netstat -tulpen | grep -qE "LISTEN\s+0\s+.*:80\s";  then conflicts="80"; fi
    if netstat -tulpen | grep -qE "LISTEN\s+0\s+.*:443\s"; then conflicts="${conflicts} 443"; fi
    [[ -n "$conflicts" ]] && err "Порты ${conflicts} всё ещё заняты. Освободите 80/443 и запустите снова."
  fi
  ok "Порты 80/443 свободны"
}

# ---------- Install dependencies ----------
install_deps() {
  info "Устанавливаем зависимости: curl git jq openssl apache2-utils docker docker compose..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release git jq openssl apache2-utils >/dev/null

  if ! command -v docker >/dev/null 2>&1; then
    info "Устанавливаем Docker Engine..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
      $(. /etc/os-release; echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
    apt-get update -y >/dev/null
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    systemctl enable docker >/dev/null; systemctl start docker >/dev/null
  fi
  docker --version | grep -q "Docker" || err "Docker не установлен"
  docker compose version >/dev/null 2>&1 || err "Docker Compose plugin не установлен"
  ok "Docker/Compose готовы"
}

# ---------- Helpers ----------
read_nonempty() {
  local prompt="$1" var
  while true; do
    read -rp "$prompt" var
    [[ -n "${var// /}" ]] && echo "$var" && return
    echo "Значение не может быть пустым."
  done
}

is_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

is_email() {
  [[ "$1" =~ ^[^@]+@[^@]+\.[^@]+$ ]]
}

rand_alnum() {
  # length as $1, default 32
  local len="${1:-32}"
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

escape_for_env() {
  # escape '$' for docker-compose env interpolation in basicauth hashes
  sed 's/\$/$$/g'
}

upsert_env() {
  # upsert KEY=VALUE into .env (no duplicates)
  local key="$1"; shift
  local value="$*"
  if grep -qE "^${key}=" .env 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    echo "${key}=${value}" >> .env
  fi
}

backup_if_exists() {
  local f="$1"
  [[ -f "$f" ]] && cp -f "$f" "${f}.bak_$(date +%Y%m%d_%H%M%S)"
}

# ---------- Paths ----------
PROJECT_DIR="/opt/mworks-n8n-rag"
CONF_DIR="${PROJECT_DIR}/configs"
TRAEFIK_DIR="${CONF_DIR}/traefik"
VOL_DIR="${PROJECT_DIR}/volumes"
INITDB_DIR="${PROJECT_DIR}/initdb"

prepare_dirs() {
  mkdir -p "$PROJECT_DIR" "$CONF_DIR" "$TRAEFIK_DIR" "$VOL_DIR/traefik/letsencrypt" "$VOL_DIR/postgres" "$VOL_DIR/qdrant" "$INITDB_DIR"
  touch "$VOL_DIR/traefik/letsencrypt/acme.json"
  chmod 600 "$VOL_DIR/traefik/letsencrypt/acme.json"
}

# ---------- Interactive ----------
collect_inputs() {
  echo
  info "Сбор параметров установки"
  while true; do
    ROOT_DOMAIN=$(read_nonempty "Основной домен (например, example.com): ")
    is_domain "$ROOT_DOMAIN" && break || echo "Введите корректный домен."
  done

  DEF_N8N_HOST="n8n.${ROOT_DOMAIN}"
  DEF_QDRANT_HOST="studio.${ROOT_DOMAIN}"
  DEF_TRAEFIK_HOST="traefik.${ROOT_DOMAIN}"

  read -rp "Поддомен для n8n [${DEF_N8N_HOST}]: " N8N_HOST; N8N_HOST="${N8N_HOST:-$DEF_N8N_HOST}"
  is_domain "$N8N_HOST" || err "Некорректный домен для n8n"
  read -rp "Поддомен для Qdrant [${DEF_QDRANT_HOST}]: " QDRANT_HOST; QDRANT_HOST="${QDRANT_HOST:-$DEF_QDRANT_HOST}"
  is_domain "$QDRANT_HOST" || err "Некорректный домен для Qdrant"
  read -rp "Поддомен для Traefik [${DEF_TRAEFIK_HOST}]: " TRAEFIK_HOST; TRAEFIK_HOST="${TRAEFIK_HOST:-$DEF_TRAEFIK_HOST}"
  is_domain "$TRAEFIK_HOST" || err "Некорректный домен для Traefik"

  while true; do
    ACME_EMAIL=$(read_nonempty "Email для ACME (Let's Encrypt): ")
    is_email "$ACME_EMAIL" && break || echo "Введите корректный email."
  done

  echo
  echo "Режим установки:"
  echo "  1) ONLY N8N — Traefik + n8n + Postgres"
  echo "  2) RAG — Traefik + n8n (single) + Postgres + Qdrant"
  echo "  3) QUEUE MODE — Traefik + n8n (main+worker, queue) + Postgres + Redis + Qdrant"
  while true; do
    read -rp "Выберите режим [1-3]: " MODE
    case "$MODE" in
      1) INSTALL_MODE="only"; COMPOSE_PROFILES=""; break;;
      2) INSTALL_MODE="rag";  COMPOSE_PROFILES="rag"; break;;
      3) INSTALL_MODE="queue"; COMPOSE_PROFILES="queue"; break;;
      *) echo "Введите 1, 2 или 3.";;
    esac
  done

  info "Параметры:"
  echo "  ROOT_DOMAIN   = ${ROOT_DOMAIN}"
  echo "  N8N_HOST      = ${N8N_HOST}"
  echo "  QDRANT_HOST   = ${QDRANT_HOST}"
  echo "  TRAEFIK_HOST  = ${TRAEFIK_HOST}"
  echo "  ACME_EMAIL    = ${ACME_EMAIL}"
  echo "  INSTALL_MODE  = ${INSTALL_MODE}"
  echo "  PROFILES      = ${COMPOSE_PROFILES:-<none>}"
}

# ---------- Secrets ----------
generate_secrets() {
  cd "$PROJECT_DIR"
  backup_if_exists ".env"
  touch .env

  # Upsert basics
  upsert_env ROOT_DOMAIN "$ROOT_DOMAIN"
  upsert_env N8N_HOST "$N8N_HOST"
  upsert_env QDRANT_HOST "$QDRANT_HOST"
  upsert_env TRAEFIK_HOST "$TRAEFIK_HOST"
  upsert_env ACME_EMAIL "$ACME_EMAIL"
  upsert_env INSTALL_MODE "$INSTALL_MODE"
  upsert_env COMPOSE_PROFILES "$COMPOSE_PROFILES"

  # n8n URLs
  upsert_env N8N_EDITOR_BASE_URL "https://${N8N_HOST}"
  upsert_env WEBHOOK_URL "https://${N8N_HOST}"
  upsert_env N8N_PROTOCOL "http"
  upsert_env N8N_PORT "5678"
  upsert_env N8N_HOST_BIND "0.0.0.0"
  upsert_env N8N_DIAGNOSTICS_ENABLED "false"
  upsert_env GENERIC_TIMEZONE "Europe/Berlin"

  # DB defaults
  upsert_env POSTGRES_IMAGE "pgvector/pgvector:pg16"
  upsert_env POSTGRES_DB "n8n"
  upsert_env POSTGRES_USER "n8n"

  if ! grep -q "^POSTGRES_PASSWORD=" .env; then upsert_env POSTGRES_PASSWORD "$(rand_alnum 32)"; fi

  # Redis password (if queue later), generate anyway
  if ! grep -q "^REDIS_PASSWORD=" .env; then upsert_env REDIS_PASSWORD "$(rand_alnum 32)"; fi

  # n8n encryption key (critical, don't overwrite)
  if ! grep -q "^N8N_ENCRYPTION_KEY=" .env; then upsert_env N8N_ENCRYPTION_KEY "$(rand_alnum 32)"; fi

  # EXECUTIONS_MODE
  case "$INSTALL_MODE" in
    queue) upsert_env EXECUTIONS_MODE "queue";;
    *)     upsert_env EXECUTIONS_MODE "regular";;
  esac

  # Traefik BasicAuth (bcrypt)
  # Generate only once; do not overwrite on rerun
  local ta_user ta_pass ta_hash ta_hash_escaped
  if ! grep -q "^TRAEFIK_BASIC_AUTH_USER=" .env; then
    ta_user="admin"
    ta_pass="$(rand_alnum 24)"
    ta_hash="$(htpasswd -nbB "$ta_user" "$ta_pass" | cut -d: -f2-)"
    ta_hash_escaped="$(echo "${ta_user}:${ta_hash}" | escape_for_env)"
    upsert_env TRAEFIK_BASIC_AUTH_USER "$ta_user"
    upsert_env TRAEFIK_BASIC_AUTH_PASS "$ta_pass"
    upsert_env TRAEFIK_BASIC_AUTH_USERS "$ta_hash_escaped"
  fi

  # tidy line endings
  sed -i 's/\r$//' .env
  ok ".env создан/обновлён"
}

# ---------- Compose & Configs ----------
write_traefik_static() {
  cat > "${TRAEFIK_DIR}/traefik.yml" <<'YAML'
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"

api:
  dashboard: true

providers:
  docker:
    exposedByDefault: false

certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ACME_EMAIL}"
      storage: "/letsencrypt/acme.json"
      tlsChallenge: {}
YAML
}

write_pg_init_vector() {
  cat > "${INITDB_DIR}/01-pgvector.sql" <<'SQL'
-- Создаём расширение pgvector в БД по умолчанию
CREATE EXTENSION IF NOT EXISTS vector;
SQL
}

write_compose() {
  local f="${PROJECT_DIR}/docker-compose.yml"
  backup_if_exists "$f"
  cat > "$f" <<'YAML'
version: "3.9"

services:
  traefik:
    image: traefik:2.11
    container_name: traefik
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.letsencrypt.acme.tlschallenge=true
      - --certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL}
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
      - --api.dashboard=true
    ports:
      - "80:80"
      - "443:443"
    environment:
      - TZ=${GENERIC_TIMEZONE}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./volumes/traefik/letsencrypt:/letsencrypt
      - ./configs/traefik/traefik.yml:/traefik.yml:ro
    labels:
      - traefik.enable=true
      # Traefik Dashboard (BasicAuth)
      - traefik.http.routers.traefik.rule=Host(`${TRAEFIK_HOST}`)
      - traefik.http.routers.traefik.entrypoints=websecure
      - traefik.http.routers.traefik.tls.certresolver=letsencrypt
      - traefik.http.routers.traefik.service=api@internal
      - traefik.http.routers.traefik.middlewares=traefik-auth
      - traefik.http.middlewares.traefik-auth.basicauth.users=${TRAEFIK_BASIC_AUTH_USERS}

  postgres:
    image: ${POSTGRES_IMAGE}
    container_name: postgres
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - TZ=${GENERIC_TIMEZONE}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10
    volumes:
      - ./volumes/postgres:/var/lib/postgresql/data
      - ./initdb:/docker-entrypoint-initdb.d

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      - N8N_HOST=${N8N_HOST_BIND}
      - N8N_PORT=${N8N_PORT}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - N8N_EDITOR_BASE_URL=${N8N_EDITOR_BASE_URL}
      - WEBHOOK_URL=${WEBHOOK_URL}
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - N8N_DIAGNOSTICS_ENABLED=${N8N_DIAGNOSTICS_ENABLED}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE}
      # Queue mode Redis settings (harmless if unused)
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      # Optional: disable main execs in queue mode (worker does the jobs)
      - N8N_DISABLE_PRODUCTION_MAIN_PROCESS=true
    volumes:
      - n8n_data:/home/node/.n8n
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls.certresolver=letsencrypt
      - traefik.http.services.n8n.loadbalancer.server.port=5678

  # Qdrant доступен в режимах RAG и QUEUE
  qdrant:
    profiles: ["rag", "queue"]
    image: qdrant/qdrant:latest
    container_name: qdrant
    restart: unless-stopped
    environment:
      - TZ=${GENERIC_TIMEZONE}
    volumes:
      - ./volumes/qdrant:/qdrant/storage
    labels:
      - traefik.enable=true
      - traefik.http.routers.qdrant.rule=Host(`${QDRANT_HOST}`)
      - traefik.http.routers.qdrant.entrypoints=websecure
      - traefik.http.routers.qdrant.tls.certresolver=letsencrypt
      - traefik.http.services.qdrant.loadbalancer.server.port=6333

  # Redis только для QUEUE
  redis:
    profiles: ["queue"]
    image: redis:7-alpine
    container_name: redis
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 5s
      timeout: 3s
      retries: 20

  # n8n worker только для QUEUE
  n8n-worker:
    profiles: ["queue"]
    image: n8nio/n8n:latest
    container_name: n8n-worker
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    command: ["n8n", "worker"]
    environment:
      - GENERIC_TIMEZONE=${GENERIC_TIMEZONE}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
    volumes:
      - n8n_data:/home/node/.n8n

volumes:
  n8n_data:
YAML
  ok "docker-compose.yml создан/обновлён"
}

# ---------- Run stack ----------
bring_up() {
  cd "$PROJECT_DIR"
  info "Запускаем контейнеры (профили: ${COMPOSE_PROFILES:-<none>})..."
  if [[ -n "${COMPOSE_PROFILES:-}" ]]; then
    COMPOSE_PROFILES="${COMPOSE_PROFILES}" docker compose up -d
  else
    docker compose up -d
  fi
  ok "Контейнеры запущены"
}

ensure_pgvector_enabled() {
  # На случай повторного запуска без первичной инициализации — убедимся, что расширение есть
  info "Проверяем расширение pgvector..."
  docker compose exec -T postgres psql -U "$(grep ^POSTGRES_USER= .env | cut -d= -f2)" -d "$(grep ^POSTGRES_DB= .env | cut -d= -f2)" -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1 || true
  ok "pgvector доступен"
}

# ---------- Helper scripts & README ----------
write_helpers() {
  cat > "${PROJECT_DIR}/manage.sh" <<'SH'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
case "$1" in
  start) docker compose up -d;;
  stop) docker compose down;;
  restart) docker compose down && docker compose up -d;;
  logs) docker compose logs -f ${2:-};;
  *) echo "Usage: $0 {start|stop|restart|logs [service]}"; exit 1;;
esac
SH
  chmod +x "${PROJECT_DIR}/manage.sh"

  cat > "${PROJECT_DIR}/update.sh" <<'SH'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
docker compose pull
docker compose up -d
SH
  chmod +x "${PROJECT_DIR}/update.sh"

  cat > "${PROJECT_DIR}/backup.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
TS="$(date +%Y%m%d_%H%M%S)"
BK_DIR="./backups/${TS}"
mkdir -p "$BK_DIR"
# Postgres dump
source .env
docker compose exec -T postgres pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" > "${BK_DIR}/postgres_${POSTGRES_DB}.sql"
echo "Postgres dump saved to ${BK_DIR}/postgres_${POSTGRES_DB}.sql"
# Qdrant storage (cold copy) — остановите qdrant для консистентной копии при больших данных
tar -czf "${BK_DIR}/qdrant_storage.tgz" -C ./volumes qdrant
echo "Qdrant storage archived to ${BK_DIR}/qdrant_storage.tgz"
SH
  chmod +x "${PROJECT_DIR}/backup.sh"

  cat > "${PROJECT_DIR}/README.md" <<'MD'
# MEDIA WORKS — n8n + RAG Stack

## Адреса
- n8n: `https://${N8N_HOST}`
- Qdrant UI: `https://${QDRANT_HOST}/dashboard`
- Traefik Dashboard: `https://${TRAEFIK_HOST}` (BasicAuth)

## Управление
```bash
./manage.sh start|stop|restart|logs [service]
./update.sh
./backup.sh
