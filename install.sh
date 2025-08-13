#!/bin/bash
set -euo pipefail

# Проверяем, запущен ли скрипт через pipe. Если да, сохраняем его и перезапускаем
# для корректной работы интерактивных `read` команд.
if [ ! -t 0 ]; then
    TEMP_SCRIPT=$(mktemp)
    cat > "$TEMP_SCRIPT"
    chmod +x "$TEMP_SCRIPT"
    exec bash "$TEMP_SCRIPT" "$@"
fi

# ============================================================================
# MEDIA WORKS - Автоматизированная установка Supabase + N8N + Traefik
# Версия: 4.1.1 (Исправленная)
# Автор: MEDIA WORKS DevOps Team
# Описание: Production-ready установщик с 4 режимами и генерацией
#           корректных Docker Compose конфигураций.
# ============================================================================

# ============================ КОНСТАНТЫ =====================================
readonly SCRIPT_VERSION="4.1.1"
readonly SCRIPT_NAME="$(basename "$0")"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly LOG_FILE="/tmp/mediaworks_install_${TIMESTAMP}.log"

# Цветовая палитра
readonly RED='\033[0;31m'; readonly GREEN='\033[0;32m'; readonly YELLOW='\033[1;33m'; readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'; readonly CYAN='\033[0;36m'; readonly WHITE='\033[1;37m'; readonly GRAY='\033[0;90m'
readonly NC='\033[0m'; readonly BOLD='\033[1m'

# Эмодзи и иконки
readonly CHECK_MARK="✓"; readonly CROSS_MARK="✗"; readonly ARROW="➜"; readonly ROCKET="🚀"
readonly PACKAGE="📦"; readonly LOCK="🔒"; readonly KEY="🔑"; readonly GEAR="⚙️"; readonly SPARKLES="✨"

# Режимы установки
readonly MODE_FULL="full"; readonly MODE_STANDARD="standard"; readonly MODE_RAG="rag"; readonly MODE_LIGHTWEIGHT="lightweight"

# Значения по умолчанию
readonly DEFAULT_PROJECT_NAME="mediaworks_project"; readonly DEFAULT_DOMAIN="localhost"; readonly DEFAULT_EMAIL="admin@mediaworks.pro"
readonly JWT_EXPIRY_YEARS=20

# Репозиторий Supabase
readonly SUPABASE_REPO="https://github.com/supabase/supabase.git"

# ============================ ФУНКЦИИ ЛОГИРОВАНИЯ И UI =====================
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "${LOG_FILE}" >&2; }
error() { echo -e "\n${RED}${CROSS_MARK} ОШИБКА:${NC} $*" | tee -a "${LOG_FILE}" >&2; echo -e "${YELLOW}Проверьте лог-файл: ${LOG_FILE}${NC}" >&2; exit 1; }
warning() { echo -e "${YELLOW}⚠ ПРЕДУПРЕЖДЕНИЕ:${NC} $*" | tee -a "${LOG_FILE}" >&2; }
info() { echo -e "${BLUE}ℹ ИНФОРМАЦИЯ:${NC} $*" >&2; echo "[INFO] $*" >> "${LOG_FILE}"; }
success() { echo -e "${GREEN}${CHECK_MARK}${NC} $*" | tee -a "${LOG_FILE}" >&2; }

show_spinner() {
    local pid=$1; local message=${2:-"Обработка..."}; local spinner="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"; local delay=0.1; local i=0
    while kill -0 $pid 2>/dev/null; do
        printf "\r${CYAN}[${spinner:i:1}]${NC} ${message}" >&2; i=$(( (i+1) % ${#spinner} )); sleep $delay
    done
    printf "\r${GREEN}[${CHECK_MARK}]${NC} ${message} ${GREEN}Готово!${NC}\n" >&2
}

show_media_works_logo() {
    # ИСПРАВЛЕНИЕ: `clear || true` не прервет выполнение скрипта, если `clear` недоступен
    clear || true
    cat << 'EOF'
    ███╗   ███╗███████╗██████╗ ██╗ █████╗     ██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███████╗
    ████╗ ████║██╔════╝██╔══██╗██║██╔══██╗    ██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝██╔════╝
    ██╔████╔██║█████╗  ██║  ██║██║███████║    ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ ███████╗
    ██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║    ██║███╗██║██║   ██║██╔══██╗██╔═██╗ ╚════██║
    ██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║    ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗███████║
    ╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝     ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝
EOF
    echo -e "${CYAN}    ═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}                          ENTERPRISE INFRASTRUCTURE AUTOMATION${NC}\n"
}

# ============================ СИСТЕМНЫЕ ПРОВЕРКИ ============================

check_root() { [[ $EUID -ne 0 ]] && error "Этот скрипт должен быть запущен с правами root (sudo)"; }

check_system_requirements() {
    info "Проверка системных требований..."
    local checks_passed=true
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        [[ ! "$ID" =~ ^(ubuntu|debian)$ ]] && checks_passed=false
    else
        checks_passed=false
    fi
    [[ "$checks_passed" == false ]] && error "Система не соответствует требованиям. Требуется Ubuntu 20.04+ или Debian 11+."
    success "Система поддерживается."
}

# ============================ УСТАНОВКА ЗАВИСИМОСТЕЙ =======================

install_dependencies() {
    info "Установка системных зависимостей..."
    {
        apt-get update -qq
        apt-get install -y -qq curl wget git jq openssl ca-certificates gnupg lsb-release python3 python3-pip apache2-utils software-properties-common
        pip3 install -q pyjwt cryptography
    } &> /dev/null &
    show_spinner $! "Обновление и установка пакетов"
    success "Все зависимости успешно установлены."
}

install_docker() {
    info "Проверка и установка Docker..."
    if command -v docker &> /dev/null && docker compose version &>/dev/null; then
        success "Docker и Docker Compose уже установлены."
        return
    fi

    {
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl start docker && systemctl enable docker
    } &> /dev/null &
    show_spinner $! "Установка Docker Engine и Docker Compose"

    if ! command -v docker &> /dev/null || ! docker compose version &> /dev/null; then
        error "Не удалось установить Docker или Docker Compose. Проверьте лог."
    fi
    success "Docker и Docker Compose успешно установлены."
}

# ============================ ВЫБОР РЕЖИМА УСТАНОВКИ =======================

select_installation_mode() {
    exec < /dev/tty
    echo -e "\n${CYAN}${ROCKET} ВЫБЕРИТЕ РЕЖИМ УСТАНОВКИ${NC}\n"
    echo -e "${GREEN}  [1]${NC} ${BOLD}МАКСИМАЛЬНЫЙ${NC} ${GRAY}(N8N-Cluster, Redis, Supabase-Full)${NC}"
    echo -e "${BLUE}  [2]${NC} ${BOLD}СТАНДАРТНЫЙ${NC} ${GRAY}(N8N, Supabase-Full)${NC}"
    echo -e "${MAGENTA}  [3]${NC} ${BOLD}RAG-ОПТИМИЗИРОВАННЫЙ${NC} ${GRAY}(N8N, Supabase-RAG)${NC}"
    echo -e "${YELLOW}  [4]${NC} ${BOLD}МИНИМАЛЬНЫЙ${NC} ${GRAY}(N8N, PostgreSQL)${NC}\n"

    local mode_choice
    while true; do
        read -p "$(echo -e "${CYAN}${ARROW}${NC} Введите номер режима ${WHITE}[1-4]${NC}: ")" mode_choice
        case "$mode_choice" in
            1) INSTALLATION_MODE="$MODE_FULL"; break ;;
            2) INSTALLATION_MODE="$MODE_STANDARD"; break ;;
            3) INSTALLATION_MODE="$MODE_RAG"; break ;;
            4) INSTALLATION_MODE="$MODE_LIGHTWEIGHT"; break ;;
            *) echo -e "${RED}${CROSS_MARK} Неверный выбор.${NC}" ;;
        esac
    done
    success "Выбран режим: $INSTALLATION_MODE"
}

# ============================ КОНФИГУРАЦИЯ ПРОЕКТА =========================

get_project_config() {
    info "Сбор конфигурации проекта..."
    exec < /dev/tty
    read -p "$(echo -e "${ARROW} Название проекта ${GRAY}[$DEFAULT_PROJECT_NAME]${NC}: ")" p_name
    PROJECT_NAME=${p_name:-$DEFAULT_PROJECT_NAME}

    read -p "$(echo -e "${ARROW} Домен для установки ${GRAY}[$DEFAULT_DOMAIN]${NC}: ")" d_name
    DOMAIN=${d_name:-$DEFAULT_DOMAIN}

    if [[ "$DOMAIN" != "localhost" ]]; then
        read -p "$(echo -e "${ARROW} Email для SSL сертификата ${GRAY}[$DEFAULT_EMAIL]${NC}: ")" e_name
        EMAIL=${e_name:-$DEFAULT_EMAIL}
        USE_SSL="true"
    else
        EMAIL=$DEFAULT_EMAIL
        USE_SSL="false"
        info "SSL будет отключен для домена localhost."
    fi
    success "Конфигурация проекта сохранена."
}

# ============================ ГЕНЕРАЦИЯ ДАННЫХ ============================

generate_password() { tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "${1:-32}"; }

generate_credentials() {
    info "Генерация безопасных учетных данных..." >&2
    local jwt_secret=$(generate_password 64)
    # Python-скрипт для генерации токенов
    cat > /tmp/generate_jwt.py << 'EOF'
import jwt, datetime, sys
def generate_jwt_token(secret, role, expiry_years=20):
    now = datetime.datetime.now(datetime.timezone.utc)
    payload = {"role": role, "iss": "supabase", "iat": int(now.timestamp()), "exp": int((now + datetime.timedelta(days=365 * expiry_years)).timestamp())}
    return jwt.encode(payload, secret, algorithm='HS256')
if __name__ == "__main__":
    print(generate_jwt_token(sys.argv[1], sys.argv[2], int(sys.argv[3])))
EOF
    local anon_key=$(python3 /tmp/generate_jwt.py "$jwt_secret" "anon" "$JWT_EXPIRY_YEARS")
    local service_key=$(python3 /tmp/generate_jwt.py "$jwt_secret" "service_role" "$JWT_EXPIRY_YEARS")
    rm -f /tmp/generate_jwt.py

    # Только этот вывод пойдет в stdout для захвата переменной
    cat << EOF
JWT_SECRET=$jwt_secret
ANON_KEY=$anon_key
SERVICE_ROLE_KEY=$service_key
POSTGRES_PASSWORD=$(generate_password 32)
DASHBOARD_USERNAME=admin
DASHBOARD_PASSWORD=$(generate_password 24)
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=$(generate_password 24)
REDIS_PASSWORD=$(generate_password 32)
SECRET_KEY_BASE=$(generate_password 64)
VAULT_ENC_KEY=$(generate_password 64)
LOGFLARE_PUBLIC_ACCESS_TOKEN=sb_$(generate_password 32)
LOGFLARE_PRIVATE_ACCESS_TOKEN=lf_$(generate_password 32)
N8N_ENCRYPTION_KEY=$(generate_password 32)
EOF
}

# ======================= Файловая система и Конфиги =======================

create_project_structure() {
    info "Создание структуры проекта в $1..."
    mkdir -p "$1"/{configs/{traefik/dynamic,supabase},volumes/{db/migrations,db/init-scripts,n8n,redis,storage,functions,traefik},scripts,backups}
    touch "$1"/volumes/traefik/acme.json && chmod 600 "$1"/volumes/traefik/acme.json
    success "Структура проекта создана."
}

clone_supabase() {
    info "Загрузка репозитория Supabase..."
    if [[ -d "/root/supabase" ]]; then
        info "Репозиторий Supabase уже существует. Пропускаем."
        return
    fi
    git clone --depth 1 "$SUPABASE_REPO" "/root/supabase" &> /dev/null &
    show_spinner $! "Клонирование репозитория Supabase"
    success "Репозиторий Supabase готов."
}

prepare_supabase_files() {
    local project_dir=$1
    local supabase_docker_dir="/root/supabase/docker"
    info "Копирование файлов инициализации Supabase..."
    set -e # Включим строгий режим на время копирования
    cp "$supabase_docker_dir"/volumes/db/*.sql "$project_dir/volumes/db/migrations/"
    # Создаем пустые файлы, если их нет, чтобы избежать ошибок в docker-compose
    touch "$project_dir/volumes/db/init-scripts/98-webhooks.sql"
    touch "$project_dir/volumes/db/init-scripts/99-roles.sql"
    
    mkdir -p "$project_dir/configs/supabase"
    cp "$supabase_docker_dir"/kong.yml "$project_dir/configs/supabase/kong.yml"
    cp "$supabase_docker_dir"/volumes/logs/vector.yml "$project_dir/configs/vector.yml"
    cp "$supabase_docker_dir"/volumes/pooler/pooler.exs "$project_dir/configs/pooler.exs"
    set +e
    success "Файлы инициализации Supabase скопированы."
}

create_env_file() {
    local project_dir=$1 mode=$2 domain=$3 email=$4 use_ssl=$5
    info "Создание конфигурационного файла .env..."
    # Загружаем сгенерированные учетные данные в переменные
    eval "$6"

    cat > "$project_dir/.env" << EOF
# Основная конфигурация
PROJECT_NAME=$(basename "$project_dir")
DOMAIN=$domain
SITE_URL=https://$domain
API_EXTERNAL_URL=https://api.$domain
SUPABASE_PUBLIC_URL=https://$domain

# Учетные данные
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
DASHBOARD_USERNAME=$DASHBOARD_USERNAME
DASHBOARD_PASSWORD=$DASHBOARD_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD

# JWT & Keys
JWT_SECRET=$JWT_SECRET
JWT_EXPIRY=315360000
ANON_KEY=$ANON_KEY
SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY
SECRET_KEY_BASE=$SECRET_KEY_BASE
VAULT_ENC_KEY=$VAULT_ENC_KEY

# N8N
N8N_HOST=n8n.$domain
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=$N8N_BASIC_AUTH_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_BASIC_AUTH_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
WEBHOOK_URL=https://$domain/

# Traefik & SSL
EMAIL=$email
USE_SSL=$use_ssl

# Компоненты
POSTGRES_HOST=db
POSTGRES_PORT=5432
POSTGRES_DB=postgres
PGRST_DB_SCHEMAS=public,storage,graphql_public
FUNCTIONS_VERIFY_JWT=true
POOLER_PROXY_PORT_TRANSACTION=6543
EOF
    sed -i 's/[[:space:]]*$//; s/\r$//' "$project_dir/.env"
    success "Файл .env создан."
}


create_traefik_configuration() {
    local project_dir=$1
    info "Настройка Traefik..."
    # Основной конфиг traefik.yml не нужен, все настраивается через CLI arguments в docker-compose
    # Middleware для безопасности
    cat > "$project_dir/configs/traefik/dynamic/middlewares.yml" << EOF
http:
  middlewares:
    secure-headers:
      headers:
        frameDeny: true
        sslRedirect: true
        browserXssFilter: true
        contentTypeNosniff: true
EOF
    success "Конфигурация Traefik создана."
}

# ======================= Генерация Docker Compose ========================

generate_compose_header() {
    cat > "$1" <<EOF
version: '3.8'

x-common: &common
  restart: unless-stopped
  logging:
    driver: "json-file"
    options:
      max-size: "10m"
      max-file: "3"
  networks:
    - internal_net

networks:
  internal_net:
    name: \${PROJECT_NAME}_internal_net
  traefik_public:
    external: true
    name: traefik_public

volumes:
  db-data:
  db-config:
  n8n-data:
  redis-data:
  storage-data:
  functions-data:
  acme-data:

services:
EOF
}

generate_service_traefik() {
    cat >> "$1" <<EOF
  traefik:
    image: traefik:v3.0
    container_name: \${PROJECT_NAME}_traefik
    command:
      - "--api.dashboard=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=traefik_public"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--certificatesresolvers.letsencrypt.acme.email=\${EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
    ports: ["80:80", "443:443", "8080:8080"]
    volumes:
      - acme-data:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./configs/traefik/dynamic:/etc/traefik/dynamic:ro
    networks: { traefik_public: {} }
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-dashboard.rule=Host(\`traefik.\${DOMAIN}\`)"
      - "traefik.http.routers.traefik-dashboard.service=api@internal"
      - "traefik.http.routers.traefik-dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik-dashboard.middlewares=traefik-auth"
      - "traefik.http.middlewares.traefik-auth.basicauth.users=\${DASHBOARD_USERNAME}:\${DASHBOARD_HASH}"
EOF
}

generate_service_db() {
  local container_name=${2:-db}
  cat >> "$1" <<EOF
  $container_name:
    <<: *common
    image: supabase/postgres:15.8.1.060
    container_name: \${PROJECT_NAME}_${container_name}
    volumes:
      - db-data:/var/lib/postgresql/data
      - db-config:/etc/postgresql-custom
      - ./volumes/db/migrations:/docker-entrypoint-initdb.d
    environment:
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d \${POSTGRES_DB}"]
      interval: 10s; timeout: 5s; retries: 5
EOF
}

generate_service_n8n_single() {
  cat >> "$1" <<EOF
  n8n:
    <<: *common
    image: n8nio/n8n:latest
    container_name: \${PROJECT_NAME}_n8n
    depends_on:
      db:
        condition: service_healthy
    volumes: [ "n8n-data:/home/node/.n8n" ]
    environment:
      - N8N_HOST=\${N8N_HOST}
      - WEBHOOK_URL=\${WEBHOOK_URL}
      - N8N_BASIC_AUTH_ACTIVE=\${N8N_BASIC_AUTH_ACTIVE}
      - N8N_BASIC_AUTH_USER=\${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=\${N8N_BASIC_AUTH_PASSWORD}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=db
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`\${N8N_HOST}\`)"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      - "traefik.docker.network=traefik_public"
    networks: [ "internal_net", "traefik_public" ]
EOF
}

generate_service_n8n_cluster() {
  cat >> "$1" <<EOF
  redis:
    <<: *common
    image: redis:6.2-alpine
    container_name: \${PROJECT_NAME}_redis
    command: redis-server --save 60 1 --loglevel warning --requirepass \${REDIS_PASSWORD}
    volumes: [ "redis-data:/data" ]
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${REDIS_PASSWORD}", "ping"]
      interval: 10s; timeout: 5s; retries: 5

  n8n-main:
    <<: *common
    image: n8nio/n8n:latest
    container_name: \${PROJECT_NAME}_n8n_main
    depends_on: { db: { condition: service_healthy }, redis: { condition: service_healthy } }
    volumes: [ "n8n-data:/home/node/.n8n" ]
    environment:
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=\${REDIS_PASSWORD}
      - N8N_HOST=\${N8N_HOST}
      - N8N_BASIC_AUTH_USER=\${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=\${N8N_BASIC_AUTH_PASSWORD}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=db
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`\${N8N_HOST}\`)"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      - "traefik.docker.network=traefik_public"
    networks: [ "internal_net", "traefik_public" ]

  n8n-worker:
    <<: *common
    image: n8nio/n8n:latest
    container_name: \${PROJECT_NAME}_n8n_worker
    command: worker
    depends_on: { db: { condition: service_healthy }, redis: { condition: service_healthy } }
    volumes: [ "n8n-data:/home/node/.n8n" ]
    environment:
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=\${REDIS_PASSWORD}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=db
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
EOF
}

generate_service_kong() {
  cat >> "$1" <<EOF
  kong:
    <<: *common
    image: kong:2.8.1
    container_name: \${PROJECT_NAME}_kong
    depends_on: { db: { condition: service_healthy } }
    volumes:
      - ./configs/supabase/kong.yml:/home/kong/kong.yml:ro
    environment:
      - KONG_DATABASE=off
      - KONG_DECLARATIVE_CONFIG=/home/kong/kong.yml
      - KONG_DNS_ORDER=LAST,A,CNAME
      - KONG_PLUGINS=request-transformer,cors,key-auth,acl
      - SUPABASE_ANON_KEY=\${ANON_KEY}
      - SUPABASE_SERVICE_KEY=\${SERVICE_ROLE_KEY}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.kong-api.rule=Host(\`api.\${DOMAIN}\`)"
      - "traefik.http.routers.kong-api.tls.certresolver=letsencrypt"
      - "traefik.http.services.kong-api.loadbalancer.server.port=8000"
      - "traefik.docker.network=traefik_public"
    networks: [ "internal_net", "traefik_public" ]
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:8001/status || exit 1"]
      interval: 10s; timeout: 5s; retries: 5
EOF
}

generate_service_auth() {
  cat >> "$1" <<EOF
  auth:
    <<: *common
    image: supabase/gotrue:v2.177.0
    container_name: \${PROJECT_NAME}_auth
    depends_on: { db: { condition: service_healthy } }
    environment:
      - API_EXTERNAL_URL=\${API_EXTERNAL_URL}
      - GOTRUE_DB_DATABASE_URL=postgresql://supabase_auth_admin:\${POSTGRES_PASSWORD}@db:\${POSTGRES_PORT}/\${POSTGRES_DB}
      - GOTRUE_JWT_SECRET=\${JWT_SECRET}
      - GOTRUE_JWT_EXP=\${JWT_EXPIRY}
      - GOTRUE_SITE_URL=\${SITE_URL}
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:9999/health"]
      interval: 10s; timeout: 5s; retries: 5
EOF
}

generate_service_rest() {
  cat >> "$1" <<EOF
  rest:
    <<: *common
    image: postgrest/postgrest:v12.2.12
    container_name: \${PROJECT_NAME}_rest
    depends_on: { db: { condition: service_healthy } }
    environment:
      - PGRST_DB_URI=postgresql://authenticator:\${POSTGRES_PASSWORD}@db:\${POSTGRES_PORT}/\${POSTGRES_DB}
      - PGRST_DB_SCHEMAS=\${PGRST_DB_SCHEMAS}
      - PGRST_DB_ANON_ROLE=anon
      - PGRST_JWT_SECRET=\${JWT_SECRET}
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:3000 || exit 1"]
      interval: 10s; timeout: 5s; retries: 5
EOF
}

generate_service_meta() {
  cat >> "$1" <<EOF
  meta:
    <<: *common
    image: supabase/postgres-meta:v0.91.0
    container_name: \${PROJECT_NAME}_meta
    depends_on: { db: { condition: service_healthy } }
    environment:
      - PG_META_DB_HOST=db
      - PG_META_DB_PORT=\${POSTGRES_PORT}
      - PG_META_DB_NAME=\${POSTGRES_DB}
      - PG_META_DB_USER=supabase_admin
      - PG_META_DB_PASSWORD=\${POSTGRES_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:8080/ || exit 1"]
      interval: 10s; timeout: 5s; retries: 5
EOF
}

generate_service_studio() {
  cat >> "$1" <<EOF
  studio:
    <<: *common
    image: supabase/studio:2025.06.30-sha-6f5982d
    container_name: \${PROJECT_NAME}_studio
    depends_on: { kong: { condition: service_healthy }, auth: { condition: service_healthy }, rest: { condition: service_healthy } }
    environment:
      - STUDIO_PG_META_URL=http://meta:8080
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - SUPABASE_URL=http://kong:8000
      - SUPABASE_PUBLIC_URL=\${SUPABASE_PUBLIC_URL}
      - SUPABASE_ANON_KEY=\${ANON_KEY}
      - SUPABASE_SERVICE_KEY=\${SERVICE_ROLE_KEY}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.studio.rule=Host(\`studio.\${DOMAIN}\`)"
      - "traefik.http.routers.studio.tls.certresolver=letsencrypt"
      - "traefik.http.services.studio.loadbalancer.server.port=3000"
      - "traefik.docker.network=traefik_public"
    networks: [ "internal_net", "traefik_public" ]
EOF
}

generate_service_storage() {
  cat >> "$1" <<EOF
  storage:
    <<: *common
    image: supabase/storage-api:v1.25.7
    container_name: \${PROJECT_NAME}_storage
    depends_on: { db: { condition: service_healthy }, rest: { condition: service_healthy } }
    volumes: [ "storage-data:/var/lib/storage" ]
    environment:
      - ANON_KEY=\${ANON_KEY}
      - SERVICE_KEY=\${SERVICE_ROLE_KEY}
      - POSTGREST_URL=http://rest:3000
      - PGRST_JWT_SECRET=\${JWT_SECRET}
      - DATABASE_URL=postgresql://supabase_storage_admin:\${POSTGRES_PASSWORD}@db:\${POSTGRES_PORT}/\${POSTGRES_DB}
      - STORAGE_BACKEND=file
      - FILE_STORAGE_BACKEND_PATH=/var/lib/storage
      - TENANT_ID=stub
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:5000/status || exit 1"]
      interval: 10s; timeout: 5s; retries: 5
EOF
}

generate_service_functions() {
  cat >> "$1" <<EOF
  functions:
    <<: *common
    image: supabase/edge-runtime:v1.67.4
    container_name: \${PROJECT_NAME}_functions
    depends_on: { db: { condition: service_healthy } }
    volumes: [ "functions-data:/home/deno/functions" ]
    environment:
      - JWT_SECRET=\${JWT_SECRET}
      - SUPABASE_DB_URL=postgresql://postgres:\${POSTGRES_PASSWORD}@db:\${POSTGRES_PORT}/\${POSTGRES_DB}
      - VERIFY_JWT=\${FUNCTIONS_VERIFY_JWT}
EOF
}


create_docker_compose_file() {
    local project_dir=$1 mode=$2
    local compose_file="$project_dir/docker-compose.yml"
    info "Генерация docker-compose.yml для режима '$mode'..."

    generate_compose_header "$compose_file"
    generate_service_traefik "$compose_file"

    case "$mode" in
        "$MODE_FULL")
            generate_service_db "$compose_file"
            generate_service_n8n_cluster "$compose_file"
            generate_service_kong "$compose_file"; generate_service_auth "$compose_file"; generate_service_rest "$compose_file"
            generate_service_meta "$compose_file"; generate_service_storage "$compose_file"; generate_service_functions "$compose_file"
            generate_service_studio "$compose_file"
            ;;
        "$MODE_STANDARD")
            generate_service_db "$compose_file"
            generate_service_n8n_single "$compose_file"
            generate_service_kong "$compose_file"; generate_service_auth "$compose_file"; generate_service_rest "$compose_file"
            generate_service_meta "$compose_file"; generate_service_storage "$compose_file"; generate_service_functions "$compose_file"
            generate_service_studio "$compose_file"
            ;;
        "$MODE_RAG")
            generate_service_db "$compose_file"
            generate_service_n8n_single "$compose_file"
            generate_service_kong "$compose_file"; generate_service_auth "$compose_file"; generate_service_rest "$compose_file"
            generate_service_meta "$compose_file" # Исключаем storage, functions, realtime
            generate_service_studio "$compose_file"
            ;;
        "$MODE_LIGHTWEIGHT")
            generate_service_db "$compose_file" "postgres"
            generate_service_n8n_single "$compose_file"
            # Корректируем зависимость n8n на postgres
            sed -i 's/depends_on:\s*db:/depends_on:\n      postgres:/' "$compose_file"
            sed -i 's/DB_POSTGRESDB_HOST=db/DB_POSTGRESDB_HOST=postgres/' "$compose_file"
            ;;
    esac
    
    # Хешируем пароль для Traefik Basic Auth и вставляем его в docker-compose
    source "$project_dir/.env"
    DASHBOARD_HASH=$(htpasswd -nbB admin "$DASHBOARD_PASSWORD" | cut -d ':' -f 2 | sed -e 's/\$/\$\$/g')
    sed -i "s|DASHBOARD_HASH|$DASHBOARD_HASH|" "$compose_file"
    
    success "Файл docker-compose.yml успешно сгенерирован."
}

# ============================ ЗАПУСК, УПРАВЛЕНИЕ И ПРОВЕРКА ============================

start_services() {
    local project_dir=$1
    info "Запуск всех сервисов... Это может занять несколько минут."
    cd "$project_dir"
    # Создаем внешнюю сеть для Traefik перед запуском
    docker network create traefik_public 2>/dev/null || true
    
    { docker compose up -d --remove-orphans 2>&1 | tee -a "${LOG_FILE}"; } &
    show_spinner $! "Загрузка образов и запуск контейнеров"
    # Проверяем код возврата `docker compose up`
    local status=${PIPESTATUS[0]}
    if [[ $status -ne 0 ]]; then
        error "Ошибка при запуске сервисов (код: $status). Проверьте 'docker compose -f $project_dir/docker-compose.yml logs'."
    fi
    success "Все сервисы запущены в фоновом режиме."
}

health_check() {
    local project_dir=$1
    info "Проверка работоспособности сервисов (может занять до минуты)..."
    cd "$project_dir"
    sleep 20 # Даем время на инициализацию

    local all_ok=true
    local services=$(docker compose ps --services)

    for s in $services; do
        printf "  ${ARROW} Проверка статуса ${BOLD}%-15s${NC} ... " "$s"
        local state=$(docker compose ps -a --format '{{.State}}' "$s")
        if [[ "$state" == "running" ]]; then
             local health=$(docker compose ps -a --format '{{.Health}}' "$s")
             if [[ "$health" == *"healthy"* || -z "$health" ]]; then
                echo -e "${GREEN}${CHECK_MARK} Работает${NC}"
             else
                echo -e "${YELLOW}⚠ Работает (unhealthy)${NC}"
             fi
        else
            echo -e "${RED}${CROSS_MARK} Не запущен (status: $state)${NC}"
            all_ok=false
        fi
    done

    if [[ "$all_ok" == false ]]; then
        error "Некоторые сервисы не запустились. Используйте 'docker compose logs' для диагностики."
    fi
    success "Все сервисы работают корректно!"
}


create_management_scripts() {
    local project_dir=$1
    info "Создание скриптов управления..."
    cat > "$project_dir/scripts/manage.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")/.."
CMD=$1; shift
case "$CMD" in
    start|stop|restart|logs|ps) docker compose "$CMD" "$@";;
    update) docker compose pull && docker compose up -d;;
    *) echo "Usage: $0 {start|stop|restart|ps|logs|update}";;
esac
EOF
    chmod +x "$project_dir/scripts/manage.sh"
    success "Скрипты управления созданы."
}


save_credentials() {
    local project_dir=$1 domain=$2 mode=$3
    info "Сохранение учетных данных..."
    source "$project_dir/.env"
    cat > "$project_dir/credentials.txt" << EOF
==================== MEDIA WORKS: УЧЕТНЫЕ ДАННЫЕ ====================
Проект: $PROJECT_NAME | Режим: $mode | Домен: $domain

[ N8N Automation ]
URL: https://$N8N_HOST
Пользователь: $N8N_BASIC_AUTH_USER
Пароль: $N8N_BASIC_AUTH_PASSWORD

[ Supabase Studio ]
URL: https://studio.$domain
Service Role Key: $SERVICE_ROLE_KEY
Anon Key: $ANON_KEY

[ Traefik Dashboard ]
URL: https://traefik.$domain
Пользователь: $DASHBOARD_USERNAME
Пароль: $DASHBOARD_PASSWORD

[ API Endpoints ]
Gateway/REST: https://api.$domain/rest/v1/

[ Команды управления ]
cd $project_dir
./scripts/manage.sh {start|stop|restart|logs|update}
=====================================================================
EOF
    chmod 600 "$project_dir/credentials.txt"
    success "Учетные данные сохранены в $project_dir/credentials.txt"
}


display_final_summary() {
    local project_dir=$1 domain=$2 mode=$3
    source "$project_dir/.env"
    clear || true
    show_media_works_logo
    echo -e "${GREEN}${SPARKLES} УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! ${SPARKLES}${NC}\n"
    echo -e "    ${CYAN}Режим:${NC} $mode | ${CYAN}Проект:${NC} $(basename $project_dir) | ${CYAN}Домен:${NC} $domain\n"
    echo -e "    ${BOLD}Ключевая информация сохранена в:${NC} ${YELLOW}$project_dir/credentials.txt${NC}\n"
    echo -e "    ${GREEN}➜ N8N URL:${NC} https://$N8N_HOST"
    [[ "$mode" != "$MODE_LIGHTWEIGHT" ]] && echo -e "    ${GREEN}➜ Supabase Studio URL:${NC} https://studio.$domain"
    echo -e "    ${GREEN}➜ Traefik Dashboard URL:${NC} https://traefik.$domain\n"
}

# ============================ ОСНОВНАЯ ФУНКЦИЯ ==============================

main() {
    show_media_works_logo && sleep 1
    check_root
    check_system_requirements
    install_dependencies
    install_docker

    select_installation_mode
    get_project_config
    local project_dir="/root/$PROJECT_NAME"

    create_project_structure "$project_dir"
    if [[ "$INSTALLATION_MODE" != "$MODE_LIGHTWEIGHT" ]]; then
        clone_supabase
        prepare_supabase_files "$project_dir"
    fi

    local credentials=$(generate_credentials)
    create_env_file "$project_dir" "$INSTALLATION_MODE" "$DOMAIN" "$EMAIL" "$USE_SSL" "$credentials"
    create_traefik_configuration "$project_dir"
    create_docker_compose_file "$project_dir" "$INSTALLATION_MODE"

    start_services "$project_dir"
    health_check "$project_dir"

    create_management_scripts "$project_dir"
    save_credentials "$project_dir" "$DOMAIN" "$INSTALLATION_MODE"
    display_final_summary "$project_dir" "$DOMAIN" "$INSTALLATION_MODE"
}

# ============================ ЗАПУСК СКРИПТА ================================
main "$@"
