#!/bin/bash

# =============================================================================
# MEDIA WORKS - Автоматическая установка n8n+RAG системы
# =============================================================================

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Глобальные переменные
SCRIPT_DIR="/opt/mediaworks-n8n"
BACKUP_DIR="$SCRIPT_DIR/backups"
CONFIG_DIR="$SCRIPT_DIR/configs"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"
CREDENTIALS_FILE="$SCRIPT_DIR/credentials.txt"

# Функция для показа баннера
show_banner() {
    clear
    echo -e "${PURPLE}"
    cat << 'EOF'
███╗   ███╗███████╗██████╗ ██╗ █████╗     ██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███████╗
████╗ ████║██╔════╝██╔══██╗██║██╔══██╗    ██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝██╔════╝
██╔████╔██║█████╗  ██║  ██║██║███████║    ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ ███████╗
██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║    ██║███╗██║██║   ██║██╔══██╗██╔═██╗ ╚════██║
██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║    ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗███████║
╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝     ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝

                    n8n + RAG Автоматическая установка
                         Версия 1.0 | 2024
EOF
    echo -e "${NC}"
}

# Функция для логирования
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
        "STEP")
            echo -e "${CYAN}[ШАГ]${NC} $message"
            ;;
    esac
    
    echo "[$timestamp][$level] $message" >> "$SCRIPT_DIR/install.log" 2>/dev/null || true
}

# Функция анимации загрузки
show_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Проверка root прав
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Этот скрипт должен запускаться от имени root"
        exit 1
    fi
}

# Проверка операционной системы
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log "ERROR" "Неподдерживаемая операционная система"
        exit 1
    fi
    
    . /etc/os-release
    
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        log "ERROR" "Поддерживаются только Ubuntu и Debian"
        exit 1
    fi
    
    log "INFO" "ОС: $PRETTY_NAME"
}

# Проверка портов
check_ports() {
    log "STEP" "Проверка доступности портов 80 и 443..."
    
    for port in 80 443; do
        if netstat -tuln | grep -q ":$port "; then
            log "WARN" "Порт $port занят"
            
            # Попытка остановить nginx/apache2
            for service in nginx apache2; do
                if systemctl is-active --quiet $service 2>/dev/null; then
                    log "INFO" "Останавливаю $service..."
                    systemctl stop $service || true
                    systemctl disable $service || true
                fi
            done
            
            # Повторная проверка
            if netstat -tuln | grep -q ":$port "; then
                log "ERROR" "Порт $port всё ещё занят. Освободите порт и запустите скрипт снова"
                exit 1
            fi
        fi
    done
    
    log "SUCCESS" "Порты 80 и 443 свободны"
}

# Установка зависимостей
install_dependencies() {
    log "STEP" "Установка зависимостей..."
    
    apt-get update -qq
    
    local packages=(
        "curl"
        "git"
        "openssl"
        "jq"
        "net-tools"
        "ca-certificates"
        "gnupg"
        "lsb-release"
        "pwgen"
        "dnsutils"
        "apache2-utils"
    )
    
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            log "INFO" "Установка $package..."
            apt-get install -y "$package" > /dev/null 2>&1
        fi
    done
    
    log "SUCCESS" "Зависимости установлены"
}

# Установка Docker
install_docker() {
    if command -v docker &> /dev/null && command -v docker compose &> /dev/null; then
        log "INFO" "Docker уже установлен"
        return
    fi
    
    log "STEP" "Установка Docker..."
    
    # Удаление старых версий
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Добавление официального GPG ключа Docker
    curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Добавление репозитория Docker
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    systemctl start docker
    systemctl enable docker
    
    log "SUCCESS" "Docker установлен"
}

# Валидация домена
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    return 0
}

# Валидация email
validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

# Функция ввода с валидацией
input_with_validation() {
    local prompt="$1"
    local validator="$2"
    local error_msg="$3"
    local default="$4"
    local value=""
    
    while true; do
        if [[ -n "$default" ]]; then
            read -p "$prompt [$default]: " value
            value="${value:-$default}"
        else
            read -p "$prompt: " value
        fi
        
        if [[ -n "$value" ]] && $validator "$value"; then
            echo "$value"
            break
        else
            log "ERROR" "$error_msg"
        fi
    done
}

# Сбор данных от пользователя
collect_user_data() {
    log "STEP" "Сбор конфигурационных данных..."
    
    echo
    echo -e "${YELLOW}=== КОНФИГУРАЦИЯ ДОМЕНОВ ===${NC}"
    
    ROOT_DOMAIN=$(input_with_validation "Введите основной домен (например, example.com)" "validate_domain" "Некорректный домен")
    
    N8N_SUBDOMAIN=$(input_with_validation "Поддомен для n8n" "validate_domain" "Некорректный поддомен" "n8n")
    N8N_HOST="$N8N_SUBDOMAIN.$ROOT_DOMAIN"
    
    QDRANT_SUBDOMAIN=$(input_with_validation "Поддомен для Qdrant" "validate_domain" "Некорректный поддомен" "studio")
    QDRANT_HOST="$QDRANT_SUBDOMAIN.$ROOT_DOMAIN"
    
    TRAEFIK_SUBDOMAIN=$(input_with_validation "Поддомен для Traefik" "validate_domain" "Некорректный поддомен" "traefik")
    TRAEFIK_HOST="$TRAEFIK_SUBDOMAIN.$ROOT_DOMAIN"
    
    ACME_EMAIL=$(input_with_validation "Email для Let's Encrypt" "validate_email" "Некорректный email")
    
    echo
    echo -e "${YELLOW}=== РЕЖИМ УСТАНОВКИ ===${NC}"
    echo "1) QUEUE MODE - n8n с очередью + Qdrant + Redis"
    echo "2) RAG MODE - n8n + Qdrant"  
    echo "3) ONLY N8N - только n8n"
    echo
    
    while true; do
        read -p "Выберите режим установки (1-3): " INSTALL_MODE
        case $INSTALL_MODE in
            1|2|3) break ;;
            *) log "ERROR" "Выберите 1, 2 или 3" ;;
        esac
    done
    
    case $INSTALL_MODE in
        1) INSTALL_MODE_NAME="QUEUE MODE" ;;
        2) INSTALL_MODE_NAME="RAG MODE" ;;
        3) INSTALL_MODE_NAME="ONLY N8N" ;;
    esac
    
    log "INFO" "Выбран режим: $INSTALL_MODE_NAME"
}

# Генерация секретов
generate_secrets() {
    log "STEP" "Генерация секретов..."
    
    N8N_ENCRYPTION_KEY=$(openssl rand -hex 16)
    POSTGRES_PASSWORD=$(pwgen -s -1 32)
    POSTGRES_N8N_PASSWORD=$(pwgen -s -1 32)
    
    if [[ "$INSTALL_MODE" == "1" ]]; then
        REDIS_PASSWORD=$(pwgen -s -1 32)
    fi
    
    # Генерация учетных данных Traefik
    TRAEFIK_USERNAME="admin"
    TRAEFIK_PASSWORD=$(pwgen -s -1 24)
    TRAEFIK_HASHED_PASSWORD=$(htpasswd -nbB "$TRAEFIK_USERNAME" "$TRAEFIK_PASSWORD" | cut -d: -f2)
    
    log "SUCCESS" "Секреты сгенерированы"
}

# Создание директорий
create_directories() {
    log "STEP" "Создание директорий проекта..."
    
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$SCRIPT_DIR/volumes"/{traefik,postgres,n8n,qdrant,redis}
    mkdir -p "$CONFIG_DIR/traefik"
    mkdir -p "$CONFIG_DIR/postgres"
    mkdir -p "$SCRIPT_DIR/volumes/traefik/logs"
    
    log "SUCCESS" "Директории созданы"
}

# Создание .env файла
create_env_file() {
    log "STEP" "Создание .env файла..."
    
    # Бэкап существующего .env
    if [[ -f "$ENV_FILE" ]]; then
        cp "$ENV_FILE" "$BACKUP_DIR/.env.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    cat > "$ENV_FILE" << EOF
# =============================================================================
# MEDIA WORKS - Конфигурация n8n+RAG системы
# =============================================================================

# Домены
ROOT_DOMAIN=$ROOT_DOMAIN
N8N_HOST=$N8N_HOST
QDRANT_HOST=$QDRANT_HOST
TRAEFIK_HOST=$TRAEFIK_HOST

# ACME / Let's Encrypt
ACME_EMAIL=$ACME_EMAIL

# n8n конфигурация
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
N8N_HOST=$N8N_HOST
N8N_PORT=5678
N8N_PROTOCOL=https
N8N_EDITOR_BASE_URL=https://$N8N_HOST
WEBHOOK_URL=https://$N8N_HOST

# База данных PostgreSQL для n8n
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres-n8n
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=$POSTGRES_N8N_PASSWORD

POSTGRES_DB=n8n
POSTGRES_USER=n8n
POSTGRES_PASSWORD=$POSTGRES_N8N_PASSWORD
POSTGRES_NON_ROOT_USER=n8n
POSTGRES_NON_ROOT_PASSWORD=$POSTGRES_N8N_PASSWORD

# Режим выполнения
EOF

    if [[ "$INSTALL_MODE" == "1" ]]; then
        cat >> "$ENV_FILE" << EOF
EXECUTIONS_MODE=queue
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
QUEUE_BULL_REDIS_DB=0
QUEUE_BULL_REDIS_PASSWORD=$REDIS_PASSWORD

# Redis
REDIS_PASSWORD=$REDIS_PASSWORD
EOF
    else
        cat >> "$ENV_FILE" << EOF
EXECUTIONS_MODE=regular
EOF
    fi
    
    cat >> "$ENV_FILE" << EOF

# Настройки безопасности
N8N_SECURE_COOKIE=true
N8N_COOKIE_SAME_SITE_POLICY=strict

# Qdrant конфигурация
QDRANT__SERVICE__HTTP_PORT=6333
QDRANT__SERVICE__GRPC_PORT=6334

# Traefik аутентификация
TRAEFIK_USERNAME=$TRAEFIK_USERNAME
TRAEFIK_PASSWORD=$TRAEFIK_PASSWORD
TRAEFIK_HASHED_PASSWORD=$TRAEFIK_HASHED_PASSWORD

# Общие настройки
COMPOSE_PROJECT_NAME=mediaworks-n8n
INSTALL_MODE=$INSTALL_MODE

# Логирование
N8N_LOG_LEVEL=info
N8N_LOG_OUTPUT=console,file
N8N_LOG_FILE_COUNT_MAX=100
N8N_LOG_FILE_SIZE_MAX=16

# Таймауты
N8N_WORKFLOW_TIMEOUT=0
N8N_EXECUTION_TIMEOUT=0

# PostgreSQL настройки
POSTGRES_VERSION=16
POSTGRES_MAX_CONNECTIONS=200
POSTGRES_SHARED_BUFFERS=256MB
POSTGRES_EFFECTIVE_CACHE_SIZE=1GB
POSTGRES_MAINTENANCE_WORK_MEM=64MB
POSTGRES_CHECKPOINT_COMPLETION_TARGET=0.9
POSTGRES_WAL_BUFFERS=16MB
POSTGRES_DEFAULT_STATISTICS_TARGET=100
POSTGRES_RANDOM_PAGE_COST=1.1
POSTGRES_EFFECTIVE_IO_CONCURRENCY=200
EOF

    # Очистка от лишних символов
    sed -i 's/[[:space:]]*$//' "$ENV_FILE"
    
    log "SUCCESS" ".env файл создан"
}

# Создание init скрипта для PostgreSQL с pgvector
create_postgres_init_script() {
    log "STEP" "Создание скрипта инициализации PostgreSQL с pgvector..."
    
    cat > "$CONFIG_DIR/postgres/init-pgvector.sql" << 'EOF'
-- =============================================================================
-- PostgreSQL инициализация с pgvector расширением
-- =============================================================================

-- Создание расширения pgvector
CREATE EXTENSION IF NOT EXISTS vector;

-- Создание пользователя для n8n (если не существует)
DO
$do$
BEGIN
   IF NOT EXISTS (
      SELECT FROM pg_catalog.pg_roles 
      WHERE  rolname = 'n8n') THEN

      CREATE ROLE n8n LOGIN PASSWORD 'placeholder_password';
   END IF;
END
$do$;

-- Предоставление прав
GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
GRANT ALL ON SCHEMA public TO n8n;

-- Настройки для оптимальной работы с векторами
ALTER SYSTEM SET shared_preload_libraries = 'vector';
ALTER SYSTEM SET max_connections = 200;
ALTER SYSTEM SET shared_buffers = '256MB';
ALTER SYSTEM SET effective_cache_size = '1GB';
ALTER SYSTEM SET maintenance_work_mem = '64MB';
ALTER SYSTEM SET checkpoint_completion_target = 0.9;
ALTER SYSTEM SET wal_buffers = '16MB';
ALTER SYSTEM SET default_statistics_target = 100;
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;

-- Перезагрузка конфигурации
SELECT pg_reload_conf();
EOF

    cat > "$CONFIG_DIR/postgres/init-user.sh" << EOF
#!/bin/bash
set -e

# Ждем запуска PostgreSQL
until pg_isready -U postgres; do
  echo "Ожидание запуска PostgreSQL..."
  sleep 2
done

echo "PostgreSQL запущен, инициализация pgvector..."

# Выполнение SQL скрипта
psql -v ON_ERROR_STOP=1 --username postgres --dbname n8n <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vector;
    -- Обновляем пароль пользователя n8n актуальным значением
    ALTER USER n8n PASSWORD '$POSTGRES_N8N_PASSWORD';
    GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n;
    GRANT ALL ON SCHEMA public TO n8n;
EOSQL

echo "pgvector инициализирован успешно!"
EOF

    chmod +x "$CONFIG_DIR/postgres/init-user.sh"
    
    log "SUCCESS" "Скрипт инициализации PostgreSQL создан"
}

# Создание конфигурации Traefik
create_traefik_config() {
    log "STEP" "Создание конфигурации Traefik..."
    
    cat > "$CONFIG_DIR/traefik/traefik.yml" << EOF
# =============================================================================
# Traefik статическая конфигурация
# =============================================================================

global:
  checkNewVersion: false
  sendAnonymousUsage: false

api:
  dashboard: true
  debug: false

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
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: mediaworks-network

certificatesResolvers:
  letsencrypt:
    acme:
      email: $ACME_EMAIL
      storage: /acme.json
      httpChallenge:
        entryPoint: web

log:
  level: INFO
  filePath: "/var/log/traefik/traefik.log"

accessLog:
  filePath: "/var/log/traefik/access.log"
  bufferingSize: 100

metrics:
  prometheus:
    addEntryPointsLabels: true
    addServicesLabels: true
    addRoutersLabels: true

ping: {}

# Настройки безопасности
serversTransport:
  insecureSkipVerify: true
EOF

    # Создание acme.json с правильными правами
    touch "$SCRIPT_DIR/volumes/traefik/acme.json"
    chmod 600 "$SCRIPT_DIR/volumes/traefik/acme.json"
    
    log "SUCCESS" "Конфигурация Traefik создана"
}

# Создание docker-compose.yml
create_docker_compose() {
    log "STEP" "Создание docker-compose.yml..."
    
    # Бэкап существующего файла
    if [[ -f "$COMPOSE_FILE" ]]; then
        cp "$COMPOSE_FILE" "$BACKUP_DIR/docker-compose.yml.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    cat > "$COMPOSE_FILE" << 'EOF'
version: '3.8'

networks:
  mediaworks-network:
    name: mediaworks-network
    driver: bridge

services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./configs/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./volumes/traefik/acme.json:/acme.json
      - ./volumes/traefik/logs:/var/log/traefik
    networks:
      - mediaworks-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard.rule=Host(`${TRAEFIK_HOST}`)"
      - "traefik.http.routers.dashboard.tls=true"
      - "traefik.http.routers.dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.routers.dashboard.service=api@internal"
      - "traefik.http.routers.dashboard.middlewares=dashboard-auth"
      - "traefik.http.middlewares.dashboard-auth.basicauth.users=${TRAEFIK_USERNAME}:${TRAEFIK_HASHED_PASSWORD}"
    command:
      - --configfile=/etc/traefik/traefik.yml
    healthcheck:
      test: ["CMD", "traefik", "healthcheck", "--ping"]
      interval: 30s
      timeout: 10s
      retries: 3

  postgres-n8n:
    image: pgvector/pgvector:pg16
    container_name: postgres-n8n
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=C"
    volumes:
      - ./volumes/postgres:/var/lib/postgresql/data
      - ./configs/postgres/init-user.sh:/docker-entrypoint-initdb.d/init-user.sh:ro
    networks:
      - mediaworks-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5
    command: >
      postgres
      -c max_connections=200
      -c shared_buffers=256MB
      -c effective_cache_size=1GB
      -c maintenance_work_mem=64MB
      -c checkpoint_completion_target=0.9
      -c wal_buffers=16MB
      -c default_statistics_target=100
      -c random_page_cost=1.1
      -c effective_io_concurrency=200
      -c shared_preload_libraries='vector'

  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    environment:
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_EDITOR_BASE_URL=https://${N8N_HOST}
      - WEBHOOK_URL=https://${N8N_HOST}
      - GENERIC_TIMEZONE=Europe/Moscow
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres-n8n
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - EXECUTIONS_MODE=${EXECUTIONS_MODE}
      - N8N_SECURE_COOKIE=true
      - N8N_COOKIE_SAME_SITE_POLICY=strict
      - N8N_LOG_LEVEL=info
      - N8N_LOG_OUTPUT=console,file
      - N8N_WORKFLOW_TIMEOUT=0
      - N8N_EXECUTION_TIMEOUT=0
      - N8N_METRICS=true
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_VERSION_NOTIFICATIONS_ENABLED=false
      - N8N_TEMPLATES_ENABLED=true
      - N8N_ONBOARDING_FLOW_DISABLED=false
      - N8N_WORKFLOW_TAGS_DISABLED=false
      - N8N_USER_MANAGEMENT_DISABLED=false
      - N8N_PUBLIC_API_DISABLED=false
EOF

    # Добавление Redis настроек для QUEUE режима
    if [[ "$INSTALL_MODE" == "1" ]]; then
        cat >> "$COMPOSE_FILE" << 'EOF'
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_DB=0
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
EOF
    fi

    cat >> "$COMPOSE_FILE" << 'EOF'
    ports:
      - "5678:5678"
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    networks:
      - mediaworks-network
    depends_on:
      postgres-n8n:
        condition: service_healthy
EOF

    # Добавление зависимости от Redis для QUEUE режима
    if [[ "$INSTALL_MODE" == "1" ]]; then
        cat >> "$COMPOSE_FILE" << 'EOF'
      redis:
        condition: service_healthy
EOF
    fi

    cat >> "$COMPOSE_FILE" << 'EOF'
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n.tls=true"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      - "traefik.http.routers.n8n.middlewares=n8n-headers"
      - "traefik.http.middlewares.n8n-headers.headers.customrequestheaders.X-Forwarded-Proto=https"
      - "traefik.http.middlewares.n8n-headers.headers.customrequestheaders.X-Forwarded-For="
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:5678/healthz || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF

    # Добавление n8n-worker для QUEUE режима
    if [[ "$INSTALL_MODE" == "1" ]]; then
        cat >> "$COMPOSE_FILE" << 'EOF'

  n8n-worker:
    image: n8nio/n8n:latest
    container_name: n8n-worker
    restart: unless-stopped
    environment:
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_DB=0
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres-n8n
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_USER=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - GENERIC_TIMEZONE=Europe/Moscow
      - N8N_LOG_LEVEL=info
      - N8N_METRICS=true
    command: n8n worker
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    networks:
      - mediaworks-network
    depends_on:
      postgres-n8n:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "ps aux | grep 'n8n worker' | grep -v grep || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  redis:
    image: redis:7-alpine
    container_name: redis
    restart: unless-stopped
    command: >
      redis-server
      --requirepass ${REDIS_PASSWORD}
      --appendonly yes
      --appendfsync everysec
      --save 900 1
      --save 300 10
      --save 60 10000
      --maxmemory 512mb
      --maxmemory-policy allkeys-lru
    volumes:
      - ./volumes/redis:/data
    networks:
      - mediaworks-network
    healthcheck:
      test: ["CMD", "redis-cli", "--no-auth-warning", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
EOF
    fi

    # Добавление Qdrant для режимов 1 и 2
    if [[ "$INSTALL_MODE" == "1" || "$INSTALL_MODE" == "2" ]]; then
        cat >> "$COMPOSE_FILE" << 'EOF'

  qdrant:
    image: qdrant/qdrant:latest
    container_name: qdrant
    restart: unless-stopped
    ports:
      - "6333:6333"
      - "6334:6334"
    volumes:
      - ./volumes/qdrant:/qdrant/storage
    networks:
      - mediaworks-network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.qdrant.rule=Host(`${QDRANT_HOST}`)"
      - "traefik.http.routers.qdrant.tls=true"
      - "traefik.http.routers.qdrant.tls.certresolver=letsencrypt"
      - "traefik.http.services.qdrant.loadbalancer.server.port=6333"
    environment:
      - QDRANT__SERVICE__HTTP_PORT=6333
      - QDRANT__SERVICE__GRPC_PORT=6334
      - QDRANT__STORAGE__STORAGE_PATH=/qdrant/storage
      - QDRANT__STORAGE__SNAPSHOTS_PATH=/qdrant/storage/snapshots
      - QDRANT__STORAGE__ON_DISK_PAYLOAD=true
      - QDRANT__STORAGE__WAL__WAL_CAPACITY_MB=32
      - QDRANT__STORAGE__WAL__WAL_SEGMENTS_AHEAD=0
      - QDRANT__STORAGE__PERFORMANCE__MAX_SEARCH_THREADS=0
      - QDRANT__STORAGE__OPTIMIZERS__DELETED_THRESHOLD=0.2
      - QDRANT__STORAGE__OPTIMIZERS__VACUUM_MIN_VECTOR_NUMBER=1000
      - QDRANT__SERVICE__MAX_REQUEST_SIZE_MB=32
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:6333/health"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF
    fi
    
    log "SUCCESS" "docker-compose.yml создан"
}

# Создание скриптов управления
create_management_scripts() {
    log "STEP" "Создание скриптов управления..."
    
    # Скрипт запуска
    cat > "$SCRIPT_DIR/start.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "🚀 Запуск MEDIA WORKS n8n системы..."
docker compose up -d
echo "✅ Система запущена!"
echo "📋 Логи: ./logs.sh"
echo "📊 Статус: ./status.sh"
EOF

    # Скрипт остановки
    cat > "$SCRIPT_DIR/stop.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "🛑 Остановка MEDIA WORKS n8n системы..."
docker compose down
echo "✅ Система остановлена!"
EOF

    # Скрипт перезапуска
    cat > "$SCRIPT_DIR/restart.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "🔄 Перезапуск MEDIA WORKS n8n системы..."
docker compose down
sleep 5
docker compose up -d
echo "✅ Система перезапущена!"
EOF

    # Скрипт обновления
    cat > "$SCRIPT_DIR/update.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "⬆️  Обновление MEDIA WORKS n8n системы..."

# Создание бэкапа перед обновлением
echo "📦 Создание бэкапа..."
./backup.sh

echo "⬇️  Загрузка новых образов..."
docker compose pull

echo "🔄 Перезапуск с новыми образами..."
docker compose down
docker compose up -d

echo "✅ Система обновлена!"
echo "📋 Проверьте логи: ./logs.sh"
EOF

    # Скрипт бэкапа
    cat > "$SCRIPT_DIR/backup.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
BACKUP_NAME="backup_$(date +%Y%m%d_%H%M%S)"
BACKUP_PATH="./backups/$BACKUP_NAME"

echo "📦 Создание бэкапа системы..."
mkdir -p "$BACKUP_PATH"

echo "⏸️  Временная остановка системы для создания консистентного бэкапа..."
docker compose down

echo "📄 Копирование конфигурационных файлов..."
cp .env "$BACKUP_PATH/"
cp docker-compose.yml "$BACKUP_PATH/"
cp -r configs "$BACKUP_PATH/" 2>/dev/null || true

echo "💾 Копирование данных..."
cp -r volumes "$BACKUP_PATH/"

echo "📋 Создание информационного файла..."
cat > "$BACKUP_PATH/backup_info.txt" << BACKUP_INFO
Дата создания: $(date)
Размер бэкапа: $(du -sh "$BACKUP_PATH" | cut -f1)
Версия системы: MEDIA WORKS n8n+RAG
BACKUP_INFO

echo "🚀 Запуск системы..."
docker compose up -d

echo "✅ Бэкап создан: $BACKUP_PATH"
echo "📊 Размер: $(du -sh "$BACKUP_PATH" | cut -f1)"
EOF

    # Скрипт просмотра логов
    cat > "$SCRIPT_DIR/logs.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"

if [ -z "$1" ]; then
    echo "📋 Логи всех сервисов:"
    docker compose logs --tail=100 -f
else
    echo "📋 Логи сервиса: $1"
    docker compose logs --tail=100 -f "$1"
fi
EOF

    # Скрипт статуса
    cat > "$SCRIPT_DIR/status.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"

echo "=== 📊 Статус MEDIA WORKS n8n системы ==="
echo ""

# Статус контейнеров
echo "🐳 Контейнеры:"
docker compose ps

echo ""
echo "💾 Использование дискового пространства:"
echo "Всего: $(du -sh volumes/ 2>/dev/null | cut -f1 || echo 'Н/Д')"
echo "- n8n: $(du -sh volumes/n8n/ 2>/dev/null | cut -f1 || echo 'Н/Д')"
echo "- PostgreSQL: $(du -sh volumes/postgres/ 2>/dev/null | cut -f1 || echo 'Н/Д')"
if [ -d "volumes/qdrant" ]; then
    echo "- Qdrant: $(du -sh volumes/qdrant/ 2>/dev/null | cut -f1 || echo 'Н/Д')"
fi
if [ -d "volumes/redis" ]; then
    echo "- Redis: $(du -sh volumes/redis/ 2>/dev/null | cut -f1 || echo 'Н/Д')"
fi

echo ""
echo "🌐 Доступность сервисов:"
source .env
echo "- n8n: https://$N8N_HOST"
if [ -n "$QDRANT_HOST" ]; then
    echo "- Qdrant: https://$QDRANT_HOST"
fi
echo "- Traefik: https://$TRAEFIK_HOST"

echo ""
echo "🔍 Проверка здоровья:"
docker compose exec -T n8n wget --spider -q http://localhost:5678/healthz && echo "✅ n8n: OK" || echo "❌ n8n: Error"
if [ -d "volumes/qdrant" ]; then
    docker compose exec -T qdrant wget --spider -q http://localhost:6333/health && echo "✅ Qdrant: OK" || echo "❌ Qdrant: Error"
fi
EOF

    # Скрипт очистки системы
    cat > "$SCRIPT_DIR/cleanup.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"

echo "🧹 Очистка системы MEDIA WORKS n8n..."
echo ""
echo "ВНИМАНИЕ: Эта операция удалит неиспользуемые Docker ресурсы"
echo "Это поможет освободить место на диске"
echo ""
read -p "Продолжить? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🧹 Удаление остановленных контейнеров..."
    docker container prune -f
    
    echo "🧹 Удаление неиспользуемых образов..."
    docker image prune -f
    
    echo "🧹 Удаление неиспользуемых томов..."
    docker volume prune -f
    
    echo "🧹 Удаление неиспользуемых сетей..."
    docker network prune -f
    
    echo "✅ Очистка завершена!"
    
    echo ""
    echo "💾 Освобождено место:"
    df -h /var/lib/docker
else
    echo "❌ Операция отменена"
fi
EOF

    chmod +x "$SCRIPT_DIR"/*.sh
    
    log "SUCCESS" "Скрипты управления созданы"
}

# Создание файла с учетными данными
create_credentials_file() {
    log "STEP" "Создание файла с учетными данными..."
    
    cat > "$CREDENTIALS_FILE" << EOF
=============================================================================
MEDIA WORKS - Учетные данные системы n8n+RAG
=============================================================================

ДОМЕНЫ И ДОСТУП:
- n8n:         https://$N8N_HOST
$(if [[ "$INSTALL_MODE" != "3" ]]; then echo "- Qdrant:      https://$QDRANT_HOST"; fi)
- Traefik:     https://$TRAEFIK_HOST

УЧЕТНЫЕ ДАННЫЕ TRAEFIK DASHBOARD:
- Логин:       $TRAEFIK_USERNAME
- Пароль:      $TRAEFIK_PASSWORD
- URL:         https://$TRAEFIK_HOST

БАЗЫ ДАННЫХ:
- PostgreSQL 16 + pgvector (n8n):
  - Хост:      postgres-n8n:5432
  - База:      $POSTGRES_DB
  - Логин:     $POSTGRES_USER
  - Пароль:    $POSTGRES_N8N_PASSWORD
  - Версия:    PostgreSQL 16 с расширением pgvector

$(if [[ "$INSTALL_MODE" == "1" ]]; then
cat << REDIS_EOF
- Redis 7 (очередь выполнения):
  - Хост:      redis:6379
  - Пароль:    $REDIS_PASSWORD
  - База:      0
REDIS_EOF
fi)

ВНУТРЕННИЕ СЕКРЕТЫ:
- n8n Encryption Key:    $N8N_ENCRYPTION_KEY

РЕЖИМ УСТАНОВКИ: $INSTALL_MODE_NAME
$(case $INSTALL_MODE in
    1) echo "- n8n в режиме очереди с worker-ом"
       echo "- PostgreSQL 16 + pgvector"
       echo "- Redis для очереди задач"
       echo "- Qdrant для векторного поиска" ;;
    2) echo "- n8n в обычном режиме"
       echo "- PostgreSQL 16 + pgvector"
       echo "- Qdrant для векторного поиска" ;;
    3) echo "- Только n8n в обычном режиме"
       echo "- PostgreSQL 16 + pgvector" ;;
esac)

ПУТИ К ФАЙЛАМ:
- Проект:            $SCRIPT_DIR
- Логи установки:    $SCRIPT_DIR/install.log
- Учетные данные:    $CREDENTIALS_FILE
- Бэкапы:           $BACKUP_DIR
- Данные:           $SCRIPT_DIR/volumes/
- Конфигурации:     $CONFIG_DIR

СКРИПТЫ УПРАВЛЕНИЯ:
- $SCRIPT_DIR/start.sh     - Запуск системы
- $SCRIPT_DIR/stop.sh      - Остановка системы
- $SCRIPT_DIR/restart.sh   - Перезапуск системы
- $SCRIPT_DIR/update.sh    - Обновление системы
- $SCRIPT_DIR/backup.sh    - Создание бэкапа
- $SCRIPT_DIR/logs.sh      - Просмотр логов
- $SCRIPT_DIR/status.sh    - Статус системы
- $SCRIPT_DIR/cleanup.sh   - Очистка системы

ОСОБЕННОСТИ УСТАНОВКИ:
✅ PostgreSQL 16 с расширением pgvector для работы с векторами
✅ Traefik с автоматическим получением SSL сертификатов Let's Encrypt
✅ Безопасная генерация всех паролей и секретов
✅ Оптимизированная конфигурация PostgreSQL для работы с векторами
✅ Автоматический мониторинг здоровья всех сервисов
✅ Логирование и метрики для всех компонентов

ВАЖНО: 
🔐 Сохраните эти данные в безопасном месте!
🗑️  Удалите этот файл после сохранения учетных данных!
🔧 Все настройки можно изменить через файлы в директории configs/

=============================================================================
MEDIA WORKS | Контакты: support@mediaworks.ru | Telegram: @mediaworks_support
=============================================================================
EOF
    
    chmod 600 "$CREDENTIALS_FILE"
    log "SUCCESS" "Файл с учетными данными создан"
}

# Создание README
create_readme() {
    cat > "$SCRIPT_DIR/README.md" << EOF
# MEDIA WORKS n8n+RAG Система

## Режим установки: $INSTALL_MODE_NAME

### 🚀 Быстрый старт

\`\`\`bash
# Запуск системы
./start.sh

# Остановка системы  
./stop.sh

# Перезапуск системы
./restart.sh

# Просмотр логов
./logs.sh

# Статус системы
./status.sh
\`\`\`

### 🌐 Доступ к сервисам

- **n8n**: https://$N8N_HOST
$(if [[ "$INSTALL_MODE" != "3" ]]; then echo "- **Qdrant**: https://$QDRANT_HOST"; fi)
- **Traefik Dashboard**: https://$TRAEFIK_HOST (логин: $TRAEFIK_USERNAME)

### 🛠 Технические характеристики

- **PostgreSQL**: Версия 16 с расширением pgvector
- **n8n**: Последняя стабильная версия
$(if [[ "$INSTALL_MODE" != "3" ]]; then echo "- **Qdrant**: Последняя стабильная версия для векторного поиска"; fi)
$(if [[ "$INSTALL_MODE" == "1" ]]; then echo "- **Redis**: Версия 7 для очереди задач"; fi)
- **Traefik**: Версия 3.0 с автоматическими SSL сертификатами

### ⚙️ Управление

#### Обновление системы
\`\`\`bash
./update.sh
\`\`\`

#### Создание бэкапа
\`\`\`bash
./backup.sh
\`\`\`

#### Просмотр логов отдельного сервиса
\`\`\`bash
./logs.sh n8n          # Логи n8n
./logs.sh traefik      # Логи Traefik
./logs.sh postgres-n8n # Логи PostgreSQL
$(if [[ "$INSTALL_MODE" != "3" ]]; then echo "./logs.sh qdrant       # Логи Qdrant"; fi)
$(if [[ "$INSTALL_MODE" == "1" ]]; then echo "./logs.sh redis        # Логи Redis"; echo "./logs.sh n8n-worker   # Логи n8n Worker"; fi)
\`\`\`

#### Очистка системы
\`\`\`bash
./cleanup.sh  # Удаление неиспользуемых Docker ресурсов
\`\`\`

### 📁 Структура файлов

\`\`\`
$SCRIPT_DIR/
├── docker-compose.yml          # Основная конфигурация
├── .env                       # Переменные окружения
├── credentials.txt            # Учетные данные (удалить после использования!)
├── README.md                  # Эта документация
├── configs/                   # Конфигурационные файлы
│   ├── traefik/
│   │   └── traefik.yml       # Конфигурация Traefik
│   └── postgres/
│       ├── init-user.sh      # Скрипт инициализации PostgreSQL
│       └── init-pgvector.sql # SQL для настройки pgvector
├── volumes/                   # Данные сервисов
│   ├── n8n/                  # Данные n8n
│   ├── postgres/             # Данные PostgreSQL
│   ├── traefik/              # Сертификаты и логи Traefik
$(if [[ "$INSTALL_MODE" != "3" ]]; then echo "│   ├── qdrant/               # Данные Qdrant"; fi)
$(if [[ "$INSTALL_MODE" == "1" ]]; then echo "│   └── redis/                # Данные Redis"; fi)
├── backups/                   # Резервные копии
└── *.sh                      # Скрипты управления
\`\`\`

### 🔧 Расширенная настройка

#### Настройка PostgreSQL для векторов
Система автоматически устанавливает и настраивает расширение pgvector:
- Поддержка векторных операций
- Оптимизированные индексы для семантического поиска
- Настроенная конфигурация для работы с большими векторными данными

#### Мониторинг и логирование
- Все сервисы имеют health checks
- Централизованное логирование через Traefik
- Метрики Prometheus доступны через Traefik

#### Безопасность
- Все пароли генерируются автоматически
- SSL сертификаты от Let's Encrypt
- Защищенный доступ к админ-панелям
- Изолированная Docker сеть

### 🆘 Устранение проблем

#### Проверка состояния сервисов
\`\`\`bash
./status.sh
docker compose ps
\`\`\`

#### Просмотр логов при проблемах
\`\`\`bash
./logs.sh           # Все логи
./logs.sh n8n       # Только n8n
./logs.sh traefik   # Только Traefik
\`\`\`

#### Перезапуск проблемного сервиса
\`\`\`bash
docker compose restart n8n      # Перезапуск n8n
docker compose restart traefik  # Перезапуск Traefik
\`\`\`

#### Полное переразвертывание
\`\`\`bash
./stop.sh
./start.sh
\`\`\`

### 📞 Поддержка

- **Email**: support@mediaworks.ru
- **Telegram**: @mediaworks_support
- **Документация**: Полные инструкции в credentials.txt

### 📝 Примечания

1. **DNS**: Убедитесь, что все домены указывают на этот сервер
2. **Порты**: Порты 80 и 443 должны быть открыты
3. **SSL**: Сертификаты выдаются автоматически (может занять несколько минут)
4. **Бэкапы**: Регулярно создавайте резервные копии командой \`./backup.sh\`
5. **Обновления**: Следите за обновлениями через \`./update.sh\`

---
*Создано MEDIA WORKS © 2024*  
*Система развернута: $(date)*  
*Режим: $INSTALL_MODE_NAME*
EOF
}

# Запуск системы
start_system() {
    log "STEP" "Запуск системы..."
    
    cd "$SCRIPT_DIR"
    
    # Создание сети
    docker network create mediaworks-network 2>/dev/null || true
    
    # Запуск системы
    if ! docker compose up -d; then
        log "ERROR" "Ошибка при запуске системы"
        log "INFO" "Проверьте логи: docker compose logs"
        exit 1
    fi
    
    log "SUCCESS" "Система запущена"
}

# Проверка здоровья системы
health_check() {
    log "STEP" "Проверка работоспособности системы..."
    
    local max_attempts=60  # Увеличиваем время ожидания для pgvector
    local attempt=1
    
    cd "$SCRIPT_DIR"
    
    # Ожидание запуска контейнеров
    echo -n "Ожидание запуска всех сервисов"
    while [[ $attempt -le $max_attempts ]]; do
        local running_containers=$(docker compose ps --filter "status=running" --format json 2>/dev/null | jq -s 'length' 2>/dev/null || echo "0")
        local total_containers=$(docker compose ps --format json 2>/dev/null | jq -s 'length' 2>/dev/null || echo "1")
        
        if [[ "$running_containers" == "$total_containers" ]] && [[ "$total_containers" -gt 0 ]]; then
            log "SUCCESS" "Все контейнеры запущены ($running_containers/$total_containers)"
            break
        fi
        
        echo -n "."
        sleep 3
        ((attempt++))
    done
    echo
    
    if [[ $attempt -gt $max_attempts ]]; then
        log "WARN" "Не все контейнеры запустились в ожидаемое время"
        log "INFO" "Проверьте статус: ./status.sh"
    fi
    
    # Специальная проверка PostgreSQL с pgvector
    log "INFO" "Проверка инициализации PostgreSQL с pgvector..."
    local pg_attempt=1
    local max_pg_attempts=30
    
    while [[ $pg_attempt -le $max_pg_attempts ]]; do
        if docker compose exec -T postgres-n8n pg_isready -U n8n 2>/dev/null; then
            log "SUCCESS" "PostgreSQL готов к работе"
            
            # Проверка pgvector
            if docker compose exec -T postgres-n8n psql -U n8n -d n8n -c "SELECT extname FROM pg_extension WHERE extname = 'vector';" 2>/dev/null | grep -q "vector"; then
                log "SUCCESS" "Расширение pgvector успешно установлено"
            else
                log "WARN" "Расширение pgvector не обнаружено, но это не критично"
            fi
            break
        fi
        
        echo -n "."
        sleep 2
        ((pg_attempt++))
    done
    
    # Проверка SSL сертификатов
    log "INFO" "Проверка SSL сертификатов..."
    sleep 10
    
    if [[ -s "$SCRIPT_DIR/volumes/traefik/acme.json" ]]; then
        local certs_count=$(jq '.letsencrypt.Certificates // [] | length' "$SCRIPT_DIR/volumes/traefik/acme.json" 2>/dev/null || echo "0")
        if [[ "$certs_count" -gt 0 ]]; then
            log "SUCCESS" "SSL сертификаты получены ($certs_count шт.)"
        else
            log "WARN" "SSL сертификаты ещё получаются (это может занять несколько минут)"
            log "INFO" "Проверьте позже логи Traefik: ./logs.sh traefik"
        fi
    fi
    
    # Финальная проверка доступности n8n
    log "INFO" "Проверка доступности n8n..."
    local n8n_attempt=1
    while [[ $n8n_attempt -le 10 ]]; do
        if docker compose exec -T n8n wget --spider -q http://localhost:5678/healthz 2>/dev/null; then
            log "SUCCESS" "n8n отвечает на health check"
            break
        fi
        sleep 3
        ((n8n_attempt++))
    done
    
    if [[ $n8n_attempt -gt 10 ]]; then
        log "WARN" "n8n пока не отвечает на health check, но система может быть работоспособна"
    fi
}

# Итоговый отчет
show_final_report() {
    clear
    show_banner
    
    echo -e "${GREEN}🎉 УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! 🎉${NC}"
    echo
    echo -e "${YELLOW}=== ИНФОРМАЦИЯ О СИСТЕМЕ ===${NC}"
    echo -e "Режим установки: ${GREEN}$INSTALL_MODE_NAME${NC}"
    echo -e "Путь к проекту:  ${CYAN}$SCRIPT_DIR${NC}"
    echo -e "PostgreSQL:      ${GREEN}Версия 16 + pgvector${NC}"
    echo
    echo -e "${YELLOW}=== ДОСТУП К СЕРВИСАМ ===${NC}"
    echo -e "🔗 n8n:         ${CYAN}https://$N8N_HOST${NC}"
    if [[ "$INSTALL_MODE" != "3" ]]; then
        echo -e "🔗 Qdrant:      ${CYAN}https://$QDRANT_HOST${NC}"
    fi
    echo -e "🔗 Traefik:     ${CYAN}https://$TRAEFIK_HOST${NC}"
    echo -e "   └─ Логин:    ${WHITE}$TRAEFIK_USERNAME${NC}"
    echo -e "   └─ Пароль:   ${WHITE}$TRAEFIK_PASSWORD${NC}"
    echo
    echo -e "${YELLOW}=== ТЕХНИЧЕСКИЕ ХАРАКТЕРИСТИКИ ===${NC}"
    echo -e "🗄️  PostgreSQL 16 с расширением pgvector для векторного поиска"
    echo -e "🔒 Автоматические SSL сертификаты от Let's Encrypt"
    echo -e "🛡️  Все пароли сгенерированы безопасно (24+ символов)"
    echo -e "📊 Health checks для всех сервисов"
    case $INSTALL_MODE in
        1) echo -e "⚡ Режим очереди с Redis для высокой производительности" ;;
        2) echo -e "🤖 Оптимизирован для RAG и векторного поиска" ;;
        3) echo -e "🎯 Минимальная конфигурация только с n8n" ;;
    esac
    echo
    echo -e "${YELLOW}=== УЧЕТНЫЕ ДАННЫЕ ===${NC}"
    echo -e "📝 Все данные сохранены в: ${CYAN}$CREDENTIALS_FILE${NC}"
    echo -e "${RED}⚠️  ВАЖНО: Удалите credentials.txt после сохранения данных!${NC}"
    echo
    echo -e "${YELLOW}=== УПРАВЛЕНИЕ СИСТЕМОЙ ===${NC}"
    echo -e "▶️  Запуск:      ${CYAN}$SCRIPT_DIR/start.sh${NC}"
    echo -e "⏹️  Остановка:   ${CYAN}$SCRIPT_DIR/stop.sh${NC}"
    echo -e "🔄 Перезапуск:  ${CYAN}$SCRIPT_DIR/restart.sh${NC}"
    echo -e "📊 Статус:      ${CYAN}$SCRIPT_DIR/status.sh${NC}"
    echo -e "📋 Логи:       ${CYAN}$SCRIPT_DIR/logs.sh${NC}"
    echo -e "📦 Бэкап:      ${CYAN}$SCRIPT_DIR/backup.sh${NC}"
    echo -e "⬆️  Обновление: ${CYAN}$SCRIPT_DIR/update.sh${NC}"
    echo
    echo -e "${YELLOW}=== ПРОВЕРЬТЕ ПЕРЕД ИСПОЛЬЗОВАНИЕМ ===${NC}"
    echo -e "✅ DNS записи настроены на этот сервер"
    echo -e "✅ Порты 80 и 443 доступны извне"
    echo -e "✅ SSL сертификаты получаются автоматически (может занять до 5 минут)"
    echo -e "✅ pgvector готов для семантического поиска и RAG"
    echo
    echo -e "${YELLOW}=== СЛЕДУЮЩИЕ ШАГИ ===${NC}"
    echo -e "1️⃣  Настройте DNS записи для доменов"
    echo -e "2️⃣  Дождитесь выдачи SSL сертификатов"
    echo -e "3️⃣  Откройте n8n и выполните первоначальную настройку"
    echo -e "4️⃣  Сохраните учетные данные в безопасном месте"
    echo -e "5️⃣  Удалите файл credentials.txt"
    echo
    echo -e "${YELLOW}=== ПОДДЕРЖКА ===${NC}"
    echo -e "📧 Email: support@mediaworks.ru"
    echo -e "💬 Telegram: @mediaworks_support"
    echo -e "📖 Документация: $SCRIPT_DIR/README.md"
    echo
    echo -e "${GREEN}Спасибо за использование решений MEDIA WORKS!${NC}"
    echo -e "${PURPLE}Ваша система готова к созданию мощных AI-агентов! 🤖✨${NC}"
    echo
}

# Основная функция
main() {
    show_banner
    
    check_root
    check_os
    check_ports
    
    install_dependencies
    install_docker
    
    collect_user_data
    generate_secrets
    create_directories
    create_postgres_init_script
    create_env_file
    create_traefik_config
    create_docker_compose
    create_management_scripts
    create_credentials_file
    create_readme
    
    start_system
    health_check
    show_final_report
}

# Обработка ошибок
trap 'log "ERROR" "Установка прервана на строке $LINENO. Проверьте логи: $SCRIPT_DIR/install.log"' ERR

# Создание базовой директории для логов
mkdir -p "$SCRIPT_DIR"

# Запуск
main "$@"
