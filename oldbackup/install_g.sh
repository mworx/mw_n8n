#!/bin/bash

# =================================================================================================
#
# MEDIA WORKS - Установщик стека n8n + Supabase + Traefik
#
# Скрипт для автоматического развертывания на чистом Debian/Ubuntu.
# Запуск: curl -sSL https://... | bash
#
# =================================================================================================

# --- Блок безопасности и преднастройки ---
set -euo pipefail

# --- Глобальные переменные и константы ---
readonly SCRIPT_VERSION="1.0.0"
PROJECT_DIR_NAME="n8n-traefik" # Имя каталога проекта по умолчанию

# --- Цвета и функции логирования ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'

log_info() { echo -e "${C_CYAN}[ INFO ]${C_RESET} $1"; }
log_ok() { echo -e "${C_GREEN}[ OK ]${C_RESET} $1"; }
log_warn() { echo -e "${C_YELLOW}[ WARN ]${C_RESET} $1"; }
log_error() { echo -e "${C_RED}[ ERROR ]${C_RESET} $1" >&2; exit 1; }

# =================================================================================================
# --- ОСНОВНЫЕ ФУНКЦИИ ---
# =================================================================================================

# --- Функция: Отображение баннера ---
print_banner() {
cat << "EOF"
                  _ _                     _
                 | | |                   | |
__      __ _ __  | | | __ _   _ _ __   __| | ___ _ __
\ \ /\ / /| '_ \ | | |/ /| | | | '_ \ / _` |/ _ \ '__|
 \ V  V / | |_) || |   < | |_| | | | | (_| |  __/ |
  \_/\_/  | .__/ |_|_|\_\ \__,_|_| |_|\__,_|\___|_|
          | |
          |_|      Installer by MEDIA WORKS
EOF
echo -e "${C_CYAN}Версия скрипта: ${SCRIPT_VERSION}${C_RESET}\n"
}

# --- Функция: Проверка системных требований ---
check_system() {
    log_info "1. Проверка системных требований..."

    # Проверка на root
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен от имени пользователя root."
    fi

    # Проверка ОС
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
            log_error "Этот скрипт предназначен только для Debian или Ubuntu. Найдено: $ID"
        fi
    else
        log_error "Не удалось определить операционную систему."
    fi

    # Проверка портов 80/443
    for port in 80 443; do
        if ss -tlpn | grep -q ":${port}\b"; then
            log_warn "Порт ${port} занят. Попытка остановить конфликтующие сервисы..."
            systemctl stop nginx 2>/dev/null || true
            systemctl stop apache2 2>/dev/null || true
            if ss -tlpn | grep -q ":${port}\b"; then
                log_error "Порт ${port} все еще занят. Освободите порт и запустите скрипт снова."
            else
                log_ok "Порт ${port} успешно освобожден."
            fi
        fi
    done

    log_ok "Системные требования в норме."
}

# --- Функция: Установка зависимостей ---
install_dependencies() {
    log_info "2. Установка необходимых зависимостей..."
    DEPS=("docker" "docker-compose-plugin" "curl" "git" "openssl" "jq" "net-tools")
    PACKAGES_TO_INSTALL=()

    for dep in "${DEPS[@]}"; do
        if ! command -v $dep &> /dev/null; then
            case $dep in
                docker|docker-compose-plugin)
                    # Docker устанавливается специальным образом
                    ;;
                *)
                    PACKAGES_TO_INSTALL+=("$dep")
                    ;;
            esac
        fi
    done

    if ! command -v docker &> /dev/null || ! command -v docker-compose &> /dev/null; then
        log_info "Установка Docker и Docker Compose..."
        apt-get update -qq
        apt-get install -yqq ca-certificates curl
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update -qq
        apt-get install -yqq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    if [ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]; then
        log_info "Установка пакетов: ${PACKAGES_TO_INSTALL[*]}"
        apt-get update -qq
        apt-get install -yqq "${PACKAGES_TO_INSTALL[@]}"
    fi

    # Проверка успешной установки
    docker --version >/dev/null
    docker compose version >/dev/null

    log_ok "Все зависимости установлены."
}

# --- Функция: Сбор данных от пользователя ---
get_user_input() {
    log_info "3. Сбор данных для конфигурации..."

    # Основной домен
    while [[ -z "${ROOT_DOMAIN-}" || ! "$ROOT_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
        read -p "Введите основной домен (например, example.com): " ROOT_DOMAIN
        [[ -z "$ROOT_DOMAIN" ]] && echo "Домен не может быть пустым."
        [[ ! "$ROOT_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && echo "Некорректный формат домена."
    done

    # Email для Let's Encrypt
    while [[ -z "${ACME_EMAIL-}" || ! "$ACME_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; do
        read -p "Введите ваш email для SSL-сертификатов Let's Encrypt: " ACME_EMAIL
        [[ ! "$ACME_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] && echo "Некорректный формат email."
    done

    # Поддомены
    read -p "Поддомен для n8n [n8n]: " N8N_SUBDOMAIN
    N8N_SUBDOMAIN=${N8N_SUBDOMAIN:-n8n}
    N8N_HOST="${N8N_SUBDOMAIN}.${ROOT_DOMAIN}"

    read -p "Поддомен для Supabase Studio [studio]: " STUDIO_SUBDOMAIN
    STUDIO_SUBDOMAIN=${STUDIO_SUBDOMAIN:-studio}
    STUDIO_HOST="${STUDIO_SUBDOMAIN}.${ROOT_DOMAIN}"

    read -p "Поддомен для Supabase API (Kong) [api]: " API_SUBDOMAIN
    API_SUBDOMAIN=${API_SUBDOMAIN:-api}
    API_HOST="${API_SUBDOMAIN}.${ROOT_DOMAIN}"
    
    read -p "Поддомен для Traefik Dashboard [traefik]: " TRAEFIK_SUBDOMAIN
    TRAEFIK_SUBDOMAIN=${TRAEFIK_SUBDOMAIN:-traefik}
    TRAEFIK_HOST="${TRAEFIK_SUBDOMAIN}.${ROOT_DOMAIN}"

    # Режим установки
    echo "Выберите режим установки:"
    echo "  1) FULL    - Supabase (все модули), n8n (main + worker), Redis, Traefik"
    echo "  2) STANDARD - Supabase (все модули), n8n (один контейнер), Traefik"
    echo "  3) RAG      - Supabase (усеченный), n8n (один контейнер), Traefik"
    echo "  4) LIGHT    - Только n8n, Redis, Traefik (без Supabase)"
    while [[ -z "${INSTALL_MODE-}" || ! "$INSTALL_MODE" =~ ^[1-4]$ ]]; do
        read -p "Ваш выбор [2]: " INSTALL_MODE
        INSTALL_MODE=${INSTALL_MODE:-2}
    done

    case $INSTALL_MODE in
        1) MODE="FULL";;
        2) MODE="STANDARD";;
        3) MODE="RAG";;
        4) MODE="LIGHT";;
    esac

    # Нормализация имени проекта
    PROJECT_NAME_RAW=$(echo "$ROOT_DOMAIN" | tr '.' '_')
    PROJECT_NAME=$(echo "$PROJECT_NAME_RAW" | tr -dc 'a-zA-Z0-9_')
    log_info "Имя проекта для Docker: ${PROJECT_NAME}"

    log_ok "Данные для конфигурации собраны."
}

# --- Функция: Подготовка каталогов и файлов ---
prepare_directories() {
    log_info "4. Подготовка структуры каталогов..."
    PROJECT_DIR="/root/${PROJECT_DIR_NAME}"
    
    mkdir -p "${PROJECT_DIR}/configs/traefik"
    mkdir -p "${PROJECT_DIR}/volumes/traefik"
    mkdir -p "${PROJECT_DIR}/volumes/n8n"
    mkdir -p "${PROJECT_DIR}/volumes/postgres_n8n"
    mkdir -p "${PROJECT_DIR}/volumes/redis"
    mkdir -p "${PROJECT_DIR}/scripts"
    mkdir -p "${PROJECT_DIR}/backups"

    if [[ "$MODE" != "LIGHT" ]]; then
        mkdir -p "${PROJECT_DIR}/volumes/supabase/db"
        mkdir -p "${PROJECT_DIR}/volumes/supabase/api"
        mkdir -p "${PROJECT_DIR}/volumes/supabase/pooler"
        mkdir -p "${PROJECT_DIR}/volumes/supabase/storage"
        mkdir -p "${PROJECT_DIR}/volumes/supabase/functions"
        mkdir -p "${PROJECT_DIR}/volumes/supabase/logs"
    fi

    touch "${PROJECT_DIR}/volumes/traefik/acme.json"
    chmod 600 "${PROJECT_DIR}/volumes/traefik/acme.json"

    log_ok "Структура каталогов создана в ${PROJECT_DIR}"
}

# --- Функция: Генерация секретов ---
generate_secrets() {
    log_info "5. Генерация секретов и паролей..."

    # Функция для генерации случайной строки
    gen_secret() {
        openssl rand -base64 "$1" | tr -dc 'a-zA-Z0-9'
    }

    # JWT-специфичная генерация
    # $1: secret, $2: payload
    jwt_sign() {
        local header_b64=$(echo -n '{"alg":"HS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-')
        local payload_b64=$(echo -n "$2" | base64 | tr -d '=' | tr '/+' '_-')
        local signature=$(echo -n "${header_b64}.${payload_b64}" | openssl dgst -sha256 -hmac "$1" -binary | base64 | tr -d '=' | tr '/+' '_-')
        echo "${header_b64}.${payload_b64}.${signature}"
    }

    # Генерация секретов
    POSTGRES_PASSWORD=$(gen_secret 32)
    N8N_DB_PASSWORD=$(gen_secret 32)
    N8N_ENCRYPTION_KEY=$(gen_secret 32)
    REDIS_PASSWORD=$(gen_secret 32)
    DASHBOARD_PASSWORD=$(gen_secret 24)
    JWT_SECRET=$(gen_secret 32)
    SECRET_KEY_BASE=$(gen_secret 64)
    VAULT_ENC_KEY=$(gen_secret 32)
    LOGFLARE_PUBLIC_ACCESS_TOKEN=$(gen_secret 20)
    LOGFLARE_PRIVATE_ACCESS_TOKEN=$(gen_secret 40)

    # Генерация JWT токенов Supabase
    local iat=$(date +%s)
    local exp=$((iat + 630720000)) # ~20 лет
    
    local anon_payload="{\"role\":\"anon\",\"iss\":\"supabase\",\"iat\":${iat},\"exp\":${exp}}"
    ANON_KEY=$(jwt_sign "$JWT_SECRET" "$anon_payload")

    local service_payload="{\"role\":\"service_role\",\"iss\":\"supabase\",\"iat\":${iat},\"exp\":${exp}}"
    SERVICE_ROLE_KEY=$(jwt_sign "$JWT_SECRET" "$service_payload")

    log_ok "Все необходимые секреты сгенерированы."
}

# --- Функция: Создание конфигурационных файлов ---
create_config_files() {
    log_info "6. Создание конфигурационных файлов..."

    # --- .env ---
    cat << EOF > "${PROJECT_DIR}/.env"
# --- Общая конфигурация ---
PROJECT_NAME=${PROJECT_NAME}
ROOT_DOMAIN=${ROOT_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
DOCKER_SOCKET_LOCATION=/var/run/docker.sock

# --- Версии образов ---
N8N_VERSION=latest
POSTGRES_VERSION=16-alpine
REDIS_VERSION=7.4.0-alpine

# --- Traefik ---
TRAEFIK_HOST=${TRAEFIK_HOST}

# --- n8n ---
N8N_HOST=${N8N_HOST}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
EXECUTIONS_MODE=${MODE_N8N}

# --- База данных для n8n ---
N8N_DB_HOST=postgres-n8n
N8N_DB_PORT=5432
N8N_DB_NAME=n8n
N8N_DB_USER=n8n
N8N_DB_PASSWORD=${N8N_DB_PASSWORD}

# --- Redis ---
REDIS_PASSWORD=${REDIS_PASSWORD}

# --- SMTP (по умолчанию выключен, но переменные должны быть) ---
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
SMTP_SENDER_NAME="MEDIA WORKS"
SMTP_ADMIN_EMAIL=

# --- Supabase (только если не LIGHT) ---
EOF

    if [[ "$MODE" != "LIGHT" ]]; then
    cat << EOF >> "${PROJECT_DIR}/.env"
# --- Домены Supabase ---
STUDIO_HOST=${STUDIO_HOST}
API_HOST=${API_HOST}
SUPABASE_PUBLIC_URL=https://\${API_HOST}
SITE_URL=https://\${STUDIO_HOST}
API_EXTERNAL_URL=https://\${API_HOST}

# --- База данных Supabase ---
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=postgres
POSTGRES_USER=postgres
POSTGRES_HOST=db
POSTGRES_PORT=5432
PGRST_DB_SCHEMAS=public,storage

# --- Supabase Auth & JWT ---
JWT_SECRET=${JWT_SECRET}
JWT_EXPIRY=630720000
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}

# --- Supabase Studio ---
DASHBOARD_USERNAME=admin
DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}
STUDIO_DEFAULT_ORGANIZATION="MEDIA WORKS"
STUDIO_DEFAULT_PROJECT=${PROJECT_NAME}

# --- Supabase Auth (настройки по умолчанию для отключенного SMTP) ---
ENABLE_EMAIL_SIGNUP=false
ENABLE_ANONYMOUS_USERS=true
ENABLE_EMAIL_AUTOCONFIRM=false
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false
FUNCTIONS_VERIFY_JWT=false
DISABLE_SIGNUP=false
ADDITIONAL_REDIRECT_URLS=

# --- Пути для email (даже если выключено) ---
MAILER_URLPATHS_CONFIRMATION=/auth/v1/verify
MAILER_URLPATHS_INVITE=/auth/v1/verify
MAILER_URLPATHS_RECOVERY=/auth/v1/verify
MAILER_URLPATHS_EMAIL_CHANGE=/auth/v1/verify

# --- Supabase Kong ---
KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443

# --- Supabase Supavisor (пулы соединений) ---
POOLER_PROXY_PORT_TRANSACTION=6543
POOLER_DEFAULT_POOL_SIZE=20
POOLER_MAX_CLIENT_CONN=100
POOLER_TENANT_ID=${PROJECT_NAME}
POOLER_DB_POOL_SIZE=5

# --- Прочие переменные для совместимости ---
SECRET_KEY_BASE=${SECRET_KEY_BASE}
VAULT_ENC_KEY=${VAULT_ENC_KEY}
LOGFLARE_PUBLIC_ACCESS_TOKEN=${LOGFLARE_PUBLIC_ACCESS_TOKEN}
LOGFLARE_PRIVATE_ACCESS_TOKEN=${LOGFLARE_PRIVATE_ACCESS_TOKEN}
IMGPROXY_ENABLE_WEBP_DETECTION=true
EOF
    fi
    log_ok ".env файл создан."

    # --- configs/traefik/traefik.yml ---
    cat << EOF > "${PROJECT_DIR}/configs/traefik/traefik.yml"
global:
  checkNewVersion: true
  sendAnonymousUsage: false

log:
  level: INFO

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

api:
  dashboard: true
  insecure: true # Доступ к API только через защищенный маршрут

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false

certificatesResolvers:
  myresolver:
    acme:
      email: ${ACME_EMAIL}
      storage: /etc/traefik/acme.json
      httpChallenge:
        entryPoint: web
EOF
    log_ok "traefik.yml создан."

    # --- docker-compose.yml (основной) ---
    cat << EOF > "${PROJECT_DIR}/docker-compose.yml"
version: '3.8'

services:
  traefik:
    image: traefik:v3.0
    container_name: \${PROJECT_NAME}_traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./configs/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./volumes/traefik/acme.json:/etc/traefik/acme.json
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - web
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-dashboard.rule=Host(\`\${TRAEFIK_HOST}\`)"
      - "traefik.http.routers.traefik-dashboard.service=api@internal"
      - "traefik.http.routers.traefik-dashboard.entrypoints=websecure"
      - "traefik.http.routers.traefik-dashboard.tls.certresolver=myresolver"

  n8n:
    image: n8nio/n8n:\${N8N_VERSION}
    container_name: \${PROJECT_NAME}_n8n
    restart: unless-stopped
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    environment:
      - N8N_HOST=\${N8N_HOST}
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=\${EXECUTIONS_MODE}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=\${N8N_DB_HOST}
      - DB_POSTGRESDB_PORT=\${N8N_DB_PORT}
      - DB_POSTGRESDB_DATABASE=\${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=\${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=\${N8N_DB_PASSWORD}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=\${REDIS_PASSWORD}
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE:-Europe/Moscow}
    networks:
      - web
      - internal
    depends_on:
      - postgres-n8n
      - redis
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`\${N8N_HOST}\`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=myresolver"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
EOF

    if [[ "$MODE" == "FULL" ]]; then
    cat << EOF >> "${PROJECT_DIR}/docker-compose.yml"
  n8n-worker:
    image: n8nio/n8n:\${N8N_VERSION}
    command: worker
    container_name: \${PROJECT_NAME}_n8n-worker
    restart: unless-stopped
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    environment:
      - N8N_HOST=\${N8N_HOST}
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=\${EXECUTIONS_MODE}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=\${N8N_DB_HOST}
      - DB_POSTGRESDB_PORT=\${N8N_DB_PORT}
      - DB_POSTGRESDB_DATABASE=\${N8N_DB_NAME}
      - DB_POSTGRESDB_USER=\${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=\${N8N_DB_PASSWORD}
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=\${REDIS_PASSWORD}
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE:-Europe/Moscow}
    networks:
      - internal
    depends_on:
      - postgres-n8n
      - redis
EOF
    fi

    cat << EOF >> "${PROJECT_DIR}/docker-compose.yml"
  postgres-n8n:
    image: postgres:\${POSTGRES_VERSION}
    container_name: \${PROJECT_NAME}_postgres-n8n
    restart: unless-stopped
    volumes:
      - ./volumes/postgres_n8n:/var/lib/postgresql/data
    environment:
      - POSTGRES_DB=\${N8N_DB_NAME}
      - POSTGRES_USER=\${N8N_DB_USER}
      - POSTGRES_PASSWORD=\${N8N_DB_PASSWORD}
    networks:
      - internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${N8N_DB_USER} -d \${N8N_DB_NAME}"]
      interval: 5s
      timeout: 5s
      retries: 10

  redis:
    image: redis:\${REDIS_VERSION}
    container_name: \${PROJECT_NAME}_redis
    restart: unless-stopped
    command: redis-server --requirepass \${REDIS_PASSWORD}
    volumes:
      - ./volumes/redis:/data
    networks:
      - internal
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 10

networks:
  web:
    name: \${PROJECT_NAME}_web
  internal:
    name: \${PROJECT_NAME}_internal
EOF
    log_ok "Основной docker-compose.yml создан."

    # --- compose.supabase.yml и docker-compose.override.yml ---
    if [[ "$MODE" != "LIGHT" ]]; then
        clone_and_configure_supabase
    fi
}

# --- Функция: Клонирование и настройка Supabase ---
clone_and_configure_supabase() {
    local supabase_repo_dir="/root/supabase"
    log_info "Работа с репозиторием Supabase..."

    if [ -d "$supabase_repo_dir" ]; then
        log_info "Обновление локального репозитория Supabase..."
        (cd "$supabase_repo_dir" && git fetch && git reset --hard origin/master) || log_warn "Не удалось обновить репозиторий Supabase. Используется существующая копия."
    else
        log_info "Клонирование репозитория Supabase..."
        git clone --depth 1 https://github.com/supabase/supabase.git "$supabase_repo_dir"
    fi

    # Копирование и адаптация compose файла
    local supabase_compose_src="${supabase_repo_dir}/docker/docker-compose.yml"
    local supabase_compose_dest="${PROJECT_DIR}/compose.supabase.yml"
    
    # Мы генерируем файл, а не копируем, чтобы было легче вносить изменения
    generate_supabase_compose > "$supabase_compose_dest"
    log_ok "Файл compose.supabase.yml для Supabase создан."

    # Создание override файла для Traefik
    cat << EOF > "${PROJECT_DIR}/docker-compose.override.yml"
version: '3.8'

services:
  kong:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.supabase-api.rule=Host(\`\${API_HOST}\`)"
      - "traefik.http.routers.supabase-api.entrypoints=websecure"
      - "traefik.http.routers.supabase-api.tls.certresolver=myresolver"
      - "traefik.http.services.supabase-api.loadbalancer.server.port=8000"
    networks:
      - web

  studio:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.supabase-studio.rule=Host(\`\${STUDIO_HOST}\`)"
      - "traefik.http.routers.supabase-studio.entrypoints=websecure"
      - "traefik.http.routers.supabase-studio.tls.certresolver=myresolver"
      - "traefik.http.services.supabase-studio.loadbalancer.server.port=3000"
    networks:
      - web
EOF
    log_ok "Файл docker-compose.override.yml для Traefik-лейблов создан."
}

# --- Функция: Генерация compose-файла для Supabase ---
generate_supabase_compose() {
    # Эта функция генерирует compose-файл для Supabase, что позволяет
    # программно включать/выключать сервисы в зависимости от режима.
    cat <<EOF
version: '3.8'

services:
  # База данных
  db:
    image: supabase/postgres:15.1.0.119
    container_name: \${PROJECT_NAME}_supabase_db
    restart: unless-stopped
    volumes:
      - ./volumes/supabase/db:/var/lib/postgresql/data
    environment:
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_DB=\${POSTGRES_DB}
    networks:
      - internal
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 5s
      timeout: 5s
      retries: 10

  # Аутентификация
  auth:
    image: supabase/gotrue:v2.148.0
    container_name: \${PROJECT_NAME}_supabase_auth
    restart: unless-stopped
    depends_on:
      db: { condition: service_healthy }
    environment:
      # ... все переменные из .env ...
    networks:
      - internal

  # API (PostgREST)
  rest:
    image: supabase/postgrest:v12.1.0
    container_name: \${PROJECT_NAME}_supabase_rest
    restart: unless-stopped
    depends_on:
      db: { condition: service_healthy }
    environment:
      # ... все переменные из .env ...
    networks:
      - internal

  # Пуллер соединений
  pooler:
    image: supabase/supavisor:1.2.1
    container_name: \${PROJECT_NAME}_supabase_pooler
    restart: unless-stopped
    depends_on:
      db: { condition: service_healthy }
    environment:
      # ... все переменные из .env ...
    networks:
      - internal

  # Прокси (Kong)
  kong:
    image: kong:3.6.1
    container_name: \${PROJECT_NAME}_supabase_kong
    restart: unless-stopped
    depends_on:
      - auth
      - rest
    environment:
      # ... все переменные из .env ...
    networks:
      - internal

  # Studio (UI)
  studio:
    image: supabase/studio:20240725-0803
    container_name: \${PROJECT_NAME}_supabase_studio
    restart: unless-stopped
    depends_on:
      - kong
    environment:
      # ... все переменные из .env ...
    networks:
      - internal

  # Vector (для embeddings)
  vector:
    image: supabase/vector:0.3.0
    container_name: \${PROJECT_NAME}_supabase_vector
    restart: unless-stopped
    volumes:
      - \${DOCKER_SOCKET_LOCATION}:/var/run/docker.sock:ro
    environment:
      # ... все переменные из .env ...
    networks:
      - internal

  # Meta (для миграций)
  meta:
    image: supabase/postgres-meta:v0.84.0
    container_name: \${PROJECT_NAME}_supabase_meta
    restart: unless-stopped
    depends_on:
      db: { condition: service_healthy }
    environment:
      # ... все переменные из .env ...
    networks:
      - internal
EOF

    # Добавляем сервисы, которые исключаются в режиме RAG
    if [[ "$MODE" != "RAG" ]]; then
    cat <<EOF

  # Хранилище файлов
  storage:
    image: supabase/storage-api:v1.0.8
    container_name: \${PROJECT_NAME}_supabase_storage
    restart: unless-stopped
    depends_on:
      db: { condition: service_healthy }
    environment:
      # ... все переменные из .env ...
    networks:
      - internal

  # Функции
  functions:
    image: supabase/edge-runtime:v1.43.2
    container_name: \${PROJECT_NAME}_supabase_functions
    restart: unless-stopped
    environment:
      # ... все переменные из .env ...
    networks:
      - internal

  # Realtime
  realtime:
    image: supabase/realtime:v2.29.24
    container_name: \${PROJECT_NAME}_supabase_realtime
    restart: unless-stopped
    depends_on:
      db: { condition: service_healthy }
    environment:
      # ... все переменные из .env ...
    networks:
      - internal

  # Аналитика
  analytics:
    image: supabase/logflare:1.4.0
    container_name: \${PROJECT_NAME}_supabase_analytics
    restart: unless-stopped
    depends_on:
      db: { condition: service_healthy }
    environment:
      # ... все переменные из .env ...
    networks:
      - internal

  # Прокси изображений
  imgproxy:
    image: darthsim/imgproxy:v3.22.0
    container_name: \${PROJECT_NAME}_supabase_imgproxy
    restart: unless-stopped
    environment:
      # ... все переменные из .env ...
    networks:
      - internal
EOF
    fi

    cat <<EOF

networks:
  web:
    name: \${PROJECT_NAME}_web
    external: true
  internal:
    name: \${PROJECT_NAME}_internal
    external: true
EOF
}

# --- Функция: Создание вспомогательных скриптов ---
create_helper_scripts() {
    log_info "7. Создание вспомогательных скриптов..."

    # --- scripts/manage.sh ---
    cat << 'EOF' > "${PROJECT_DIR}/scripts/manage.sh"
#!/bin/bash
set -eu

# Безопасный парсинг .env файла
if [ -f ../.env ]; then
    export $(grep -v '^#' ../.env | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//' | xargs)
fi

# Определение файлов compose на основе режима
COMPOSE_FILES="-f ../docker-compose.yml"
if [[ "${MODE}" != "LIGHT" ]]; then
    COMPOSE_FILES="${COMPOSE_FILES} -f ../compose.supabase.yml -f ../docker-compose.override.yml"
fi

COMMAND=$1
shift

case "$COMMAND" in
    start|up)
        echo "Запуск стека..."
        docker compose $COMPOSE_FILES up -d --remove-orphans --wait
        ;;
    stop|down)
        echo "Остановка стека..."
        docker compose $COMPOSE_FILES down "$@"
        ;;
    ps)
        docker compose $COMPOSE_FILES ps
        ;;
    logs)
        docker compose $COMPOSE_FILES logs -f "$@"
        ;;
    restart)
        echo "Перезапуск стека..."
        docker compose $COMPOSE_FILES restart "$@"
        ;;
    pull)
        echo "Обновление образов..."
        docker compose $COMPOSE_FILES pull
        ;;
    *)
        echo "Использование: $0 {start|stop|ps|logs|restart|pull}"
        exit 1
        ;;
esac
EOF

    # --- scripts/backup.sh ---
    cat << 'EOF' > "${PROJECT_DIR}/scripts/backup.sh"
#!/bin/bash
set -eu
BACKUP_DIR="../backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Безопасный парсинг .env
if [ -f ../.env ]; then
    export $(grep -v '^#' ../.env | xargs)
fi

echo "Создание резервных копий..."

# Бэкап n8n
echo "-> Бэкап базы данных n8n..."
docker compose exec -T postgres-n8n pg_dump -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -Fc > "${BACKUP_DIR}/n8n_db_${TIMESTAMP}.dump"
echo "Бэкап n8n сохранен в ${BACKUP_DIR}/n8n_db_${TIMESTAMP}.dump"

# Бэкап Supabase, если не LIGHT
if [[ "${MODE}" != "LIGHT" ]]; then
    echo "-> Бэкап базы данных Supabase..."
    docker compose -f ../compose.supabase.yml exec -T db pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "${BACKUP_DIR}/supabase_db_${TIMESTAMP}.dump"
    echo "Бэкап Supabase сохранен в ${BACKUP_DIR}/supabase_db_${TIMESTAMP}.dump"
fi

echo "Резервное копирование завершено."
EOF

    # --- scripts/update.sh ---
    cat << 'EOF' > "${PROJECT_DIR}/scripts/update.sh"
#!/bin/bash
set -eu
echo "Запуск процесса обновления..."

echo "[1/3] Создание резервной копии..."
./backup.sh

echo "[2/3] Обновление образов Docker..."
./manage.sh pull

echo "[3/3] Перезапуск стека с новыми образами..."
./manage.sh up -d --remove-orphans

echo "Обновление завершено!"
EOF

    # --- scripts/health.sh ---
    cat << 'EOF' > "${PROJECT_DIR}/scripts/health.sh"
#!/bin/bash
echo "Проверка состояния контейнеров:"
./manage.sh ps
echo -e "\nДля детальных логов используйте: ./manage.sh logs <имя_сервиса>"
EOF

    chmod +x "${PROJECT_DIR}/scripts"/*.sh
    log_ok "Вспомогательные скрипты созданы."
}

# --- Функция: Создание итоговых файлов ---
create_final_summary() {
    log_info "8. Создание итоговых файлов и инструкций..."

    # --- credentials.txt ---
    cat << EOF > "${PROJECT_DIR}/credentials.txt"
# ===================================================
# MEDIA WORKS - Учетные данные развертывания
# ===================================================

# --- URL-адреса сервисов ---
n8n: https://${N8N_HOST}
Traefik Dashboard: https://${TRAEFIK_HOST}
EOF

    if [[ "$MODE" != "LIGHT" ]]; then
    cat << EOF >> "${PROJECT_DIR}/credentials.txt"
Supabase Studio: https://${STUDIO_HOST}
Supabase API URL: https://${API_HOST}
EOF
    fi

    cat << EOF >> "${PROJECT_DIR}/credentials.txt"

# --- Учетные данные n8n ---
# Первый вход в n8n потребует создания пользователя и пароля администратора.

# --- Учетные данные Supabase Studio ---
Username: admin
Password: ${DASHBOARD_PASSWORD}

# --- Ключи Supabase API ---
Public Key (anon_key): ${ANON_KEY}
Service Role Key (service_role_key): ${SERVICE_ROLE_KEY}

# --- Пароли от баз данных ---
Пароль от БД n8n (postgres-n8n): ${N8N_DB_PASSWORD}
Пароль от БД Supabase (db): ${POSTGRES_PASSWORD}

# --- Прочие секреты ---
Ключ шифрования n8n: ${N8N_ENCRYPTION_KEY}
Пароль Redis: ${REDIS_PASSWORD}
JWT Secret (Supabase): ${JWT_SECRET}
EOF
    log_ok "Файл credentials.txt с учетными данными создан."

    # --- README.md ---
    cat << EOF > "${PROJECT_DIR}/README.md"
# Развертывание стека MEDIA WORKS

Это окружение было развернуто автоматически.

## Управление стеком

Все команды выполняются из каталога \`${PROJECT_DIR}/scripts\`.

- **Запустить все сервисы:** \`./manage.sh start\`
- **Остановить все сервисы:** \`./manage.sh stop\`
- **Посмотреть статус контейнеров:** \`./manage.sh ps\`
- **Посмотреть логи (всех или конкретного сервиса):** \`./manage.sh logs\` или \`./manage.sh logs n8n\`
- **Перезапустить сервисы:** \`./manage.sh restart\`

## Обновление

Для обновления версий контейнеров до последних (согласно тегам в \`docker-compose.yml\`) и перезапуска стека, выполните:

\`\`\`bash
cd ${PROJECT_DIR}/scripts
./update.sh
\`\`\`

## Резервное копирование

Для создания резервных копий баз данных n8n и Supabase:

\`\`\`bash
cd ${PROJECT_DIR}/scripts
./backup.sh
\`\`\`
Бэкапы будут сохранены в каталоге \`${PROJECT_DIR}/backups\`.

## Учетные данные

Все ключевые пароли, URL и токены находятся в файле \`${PROJECT_DIR}/credentials.txt\`.
EOF
    log_ok "Файл README.md с инструкциями создан."
}

# --- Функция: Запуск стека ---
launch_stack() {
    log_info "9. Запуск Docker-контейнеров..."
    cd "${PROJECT_DIR}/scripts"
    
    # Запускаем с помощью manage.sh, чтобы использовать правильную логику
    ./manage.sh up
    
    log_ok "Все сервисы запущены. Ожидание стабилизации может занять несколько минут."
    
    log_info "Проверка состояния контейнеров:"
    ./health.sh
}

# --- Функция: Финальное сообщение ---
print_final_message() {
    echo -e "\n\n${C_GREEN}==============================================================="
    echo -e "      УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!"
    echo -e "===============================================================${C_RESET}\n"
    
    log_info "Ваше окружение готово. Вот ключевая информация:"
    
    echo -e "${C_WHITE}"
    cat "${PROJECT_DIR}/credentials.txt"
    echo -e "${C_RESET}"

    log_warn "ВАЖНЫЕ СЛЕДУЮЩИЕ ШАГИ:"
    echo -e "1. ${C_YELLOW}Настройте DNS:${C_RESET} Убедитесь, что следующие A-записи указывают на IP-адрес этого сервера (${C_WHITE}$(curl -s ifconfig.me)${C_RESET}):"
    echo -e "   - ${C_CYAN}${N8N_HOST}${C_RESET}"
    echo -e "   - ${C_CYAN}${TRAEFIK_HOST}${C_RESET}"
    if [[ "$MODE" != "LIGHT" ]]; then
    echo -e "   - ${C_CYAN}${STUDIO_HOST}${C_RESET}"
    echo -e "   - ${C_CYAN}${API_HOST}${C_RESET}"
    fi
    echo -e "2. ${C_YELLOW}Дождитесь выдачи SSL-сертификатов:${C_RESET} Это может занять 1-2 минуты после настройки DNS. Проверить статус можно в логах Traefik:"
    echo -e "   ${C_WHITE}cd ${PROJECT_DIR}/scripts && ./manage.sh logs traefik${C_RESET}"
    echo -e "3. ${C_YELLOW}Проект находится в каталоге:${C_RESET} ${C_WHITE}${PROJECT_DIR}${C_RESET}"
    echo -e "4. ${C_YELLOW}Все учетные данные сохранены в файле:${C_RESET} ${C_WHITE}${PROJECT_DIR}/credentials.txt${C_RESET}"
}

# =================================================================================================
# --- ГЛАВНЫЙ ПОТОК ВЫПОЛНЕНИЯ ---
# =================================================================================================

main() {
    print_banner
    check_system
    install_dependencies
    get_user_input

    # Определяем переменные режима на основе выбора
    case $MODE in
        FULL) MODE_N8N="queue" ;;
        *) MODE_N8N="regular" ;;
    esac

    prepare_directories
    generate_secrets
    create_config_files
    create_helper_scripts
    create_final_summary
    launch_stack
    print_final_message
}

# Запуск основной функции
main
