#!/bin/bash
# =============================================================================
# MEDIA WORKS - Система развертывания n8n + RAG
# =============================================================================
# Версия: 1.0.3
# Автор: MEDIA WORKS
# Описание: Автоматическая установка n8n с Qdrant для RAG
# =============================================================================

set -euo pipefail

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Базовые переменные
PROJECT_DIR="/opt/mworks-n8n"
BACKUP_DIR="${PROJECT_DIR}/backups/$(date +%Y%m%d_%H%M%S)"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
ENV_FILE="${PROJECT_DIR}/.env"
CREDENTIALS_FILE="${PROJECT_DIR}/credentials.txt"
NETWORK_NAME="mworks-network"

# Глобальные переменные для хранения введенных данных
ROOT_DOMAIN=""
ACME_EMAIL=""
N8N_SUBDOMAIN=""
QDRANT_SUBDOMAIN=""
TRAEFIK_SUBDOMAIN=""
N8N_HOST=""
QDRANT_HOST=""
TRAEFIK_HOST=""
INSTALL_MODE=""

# Переменные для паролей
N8N_ENCRYPTION_KEY=""
POSTGRES_PASSWORD=""
REDIS_PASSWORD=""
QDRANT_API_KEY=""
TRAEFIK_DASHBOARD_PASSWORD=""
TRAEFIK_DASHBOARD_HASH=""
QDRANT_DASHBOARD_PASSWORD=""
QDRANT_DASHBOARD_HASH=""

# =============================================================================
# Функции утилиты
# =============================================================================

# Баннер MEDIA WORKS
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
    
  ███╗   ███╗███████╗██████╗ ██╗ █████╗     ██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███████╗
  ████╗ ████║██╔════╝██╔══██╗██║██╔══██╗    ██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝██╔════╝
  ██╔████╔██║█████╗  ██║  ██║██║███████║    ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ ███████╗
  ██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║    ██║███╗██║██║   ██║██╔══██╗██╔═██╗ ╚════██║
  ██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║    ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗███████║
  ╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝     ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝
  ═════════════════════════════════════════════════════════════════════════════════════
                Инсталлятор стека n8n (queue mode) + Qdrant + pgvector
                //AI-агенты и системная интеграция — https://mworks.ru/
  ═════════════════════════════════════════════════════════════════════════════════════
EOF
    echo -e "${NC}"
    echo
}

# Анимация загрузки
spinner() {
  local pid="$1"
  # кадры спиннера (юникод)
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  local i=0
  # первый «пустой» кадр
  printf "[ ] "
  # пока процесс жив
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r [%s] " "${frames[i]}"
    i=$(( (i + 1) % ${#frames[@]} ))
    sleep 0.1
  done
  # зачистить строку
  printf "\r     \r"
}

# Вывод с форматированием
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# Проверка выполнения команды
check_command() {
    if ! command -v "$1" &> /dev/null; then
        return 1
    fi
    return 0
}

# Генерация безопасного пароля
generate_password() {
    local length=${1:-32}
    openssl rand -base64 48 | tr -d "=+/" | cut -c1-${length}
}

# Валидация домена
validate_domain() {
    local domain=$1
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    return 0
}

# Валидация email
validate_email() {
    local email=$1
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# Проверки системы
# =============================================================================

check_os() {
    log_info "Проверка операционной системы..."
    
    if [ ! -f /etc/os-release ]; then
        log_error "Не удается определить ОС. Требуется Debian или Ubuntu."
        exit 1
    fi
    
    . /etc/os-release
    
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
        log_error "Поддерживаются только Debian и Ubuntu. Обнаружена: $ID"
        exit 1
    fi
    
    log_success "ОС: $PRETTY_NAME"
}

check_root() {
    log_info "Проверка прав доступа..."
    
    if [ "$EUID" -ne 0 ]; then
        log_error "Скрипт должен запускаться от root"
        exit 1
    fi
    
    log_success "Запуск от root подтвержден"
}

check_ports() {
    log_info "Проверка доступности портов 80 и 443..."
    
    local ports_busy=false
    
    for port in 80 443; do
        if ss -tuln | grep -q ":$port "; then
            log_warning "Порт $port занят"
            ports_busy=true
            
            # Попытка остановить nginx/apache
            for service in nginx apache2 httpd; do
                if systemctl is-active --quiet $service; then
                    log_info "Останавливаем $service..."
                    systemctl stop $service || true
                    systemctl disable $service || true
                fi
            done
        fi
    done
    
    # Повторная проверка
    for port in 80 443; do
        if ss -tuln | grep -q ":$port "; then
            log_error "Порт $port все еще занят. Освободите порты 80 и 443 перед установкой."
            exit 1
        fi
    done
    
    log_success "Порты 80 и 443 свободны"
}

# =============================================================================
# Установка зависимостей
# =============================================================================

install_dependencies() {
    log_info "Установка системных зависимостей..."
    
    # Обновление пакетов
    (
        apt-get update -qq
        apt-get install -y -qq \
            apt-transport-https \
            ca-certificates \
            curl \
            gnupg \
            lsb-release \
            software-properties-common \
            git \
            openssl \
            jq \
            net-tools \
            htop \
            vim \
            wget
    ) &
    spinner $!
    
    log_success "Системные зависимости установлены"
}

enable_overcommit_memory() {
  log_info "Включаем vm.overcommit_memory=1 для Redis..."
  # применим прямо сейчас
  sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 || true
  # и сохраним в отдельный конфиг
  mkdir -p /etc/sysctl.d
  echo "vm.overcommit_memory = 1" > /etc/sysctl.d/99-mworks.conf
  # полезно также поднять backlog для Redis
  echo "net.core.somaxconn = 1024" >> /etc/sysctl.d/99-mworks.conf
  sysctl --system >/dev/null 2>&1 || true
  log_success "vm.overcommit_memory=1 включён"
}


install_docker() {
    log_info "Установка Docker..."
    
    if check_command docker; then
        log_success "Docker уже установлен: $(docker --version)"
        return
    fi
    
    # Установка Docker
    (
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh > /dev/null 2>&1
        rm /tmp/get-docker.sh
    ) &
    spinner $!
    
    # Проверка docker compose plugin
    if ! docker compose version &> /dev/null; then
        log_info "Установка Docker Compose plugin..."
        (
            apt-get update -qq
            apt-get install -y -qq docker-compose-plugin
        ) &
        spinner $!
    fi
    
    # Запуск и включение Docker
    systemctl start docker
    systemctl enable docker
    
    log_success "Docker установлен: $(docker --version)"
    log_success "Docker Compose: $(docker compose version)"
}

# =============================================================================
# Сбор данных от пользователя
# =============================================================================

collect_user_input() {
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                                 НАСТРОЙКА ПАРАМЕТРОВ          ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo
    
    # Основной домен
    while true; do
        echo -ne "${CYAN}Введите основной домен (например: example.com): ${NC}"
        read -r ROOT_DOMAIN
        if validate_domain "$ROOT_DOMAIN"; then
            break
        else
            log_error "Некорректный домен. Попробуйте снова."
        fi
    done
    
    # Email для Let's Encrypt
    while true; do
        echo -ne "${CYAN}Введите email для Let's Encrypt: ${NC}"
        read -r ACME_EMAIL
        if validate_email "$ACME_EMAIL"; then
            break
        else
            log_error "Некорректный email. Попробуйте снова."
        fi
    done
    
    # Поддомены
    echo
    log_info "Настройка поддоменов (нажмите Enter для значений по умолчанию):"
    
    echo -ne "${CYAN}  Поддомен для n8n [n8n]: ${NC}"
    read -r N8N_SUBDOMAIN
    N8N_SUBDOMAIN=${N8N_SUBDOMAIN:-n8n}
    
    echo -ne "${CYAN}  Поддомен для Qdrant [studio]: ${NC}"
    read -r QDRANT_SUBDOMAIN
    QDRANT_SUBDOMAIN=${QDRANT_SUBDOMAIN:-studio}
    
    echo -ne "${CYAN}  Поддомен для Traefik [traefik]: ${NC}"
    read -r TRAEFIK_SUBDOMAIN
    TRAEFIK_SUBDOMAIN=${TRAEFIK_SUBDOMAIN:-traefik}
    
    # Формирование полных доменов
    N8N_HOST="${N8N_SUBDOMAIN}.${ROOT_DOMAIN}"
    QDRANT_HOST="${QDRANT_SUBDOMAIN}.${ROOT_DOMAIN}"
    TRAEFIK_HOST="${TRAEFIK_SUBDOMAIN}.${ROOT_DOMAIN}"
    
    # Выбор режима установки
    echo
    echo -e "${MAGENTA}Выберите режим установки:${NC}"
    echo "  1) QUEUE MODE - n8n с воркерами + Redis + Qdrant"
    echo "  2) RAG MODE - n8n стандартный + Qdrant"
    echo "  3) ONLY N8N - только n8n без Qdrant"
    echo
    
    while true; do
        read -p "Ваш выбор [1-3]: " choice
        case $choice in
            1)
                INSTALL_MODE="queue"
                log_success "Выбран режим: QUEUE MODE"
                break
                ;;
            2)
                INSTALL_MODE="rag"
                log_success "Выбран режим: RAG MODE"
                break
                ;;
            3)
                INSTALL_MODE="n8n-only"
                log_success "Выбран режим: ONLY N8N"
                break
                ;;
            *)
                log_error "Некорректный выбор. Введите 1, 2 или 3."
                ;;
        esac
    done
    
    # Подтверждение
# Подтверждение
echo
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}                                   ПРОВЕРЬТЕ НАСТРОЙКИ                  ${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════${NC}"
echo
echo -e "  Основной домен: ${GREEN}${ROOT_DOMAIN}${NC}"
echo -e "  Email: ${GREEN}${ACME_EMAIL}${NC}"
echo -e "  n8n: ${GREEN}https://${N8N_HOST}${NC}"
if [ "$INSTALL_MODE" != "n8n-only" ]; then
    echo -e "  Qdrant: ${GREEN}https://${QDRANT_HOST}${NC}"
fi
echo -e "  Traefik: ${GREEN}https://${TRAEFIK_HOST}${NC}"
echo -e "  Режим: ${GREEN}${INSTALL_MODE}${NC}"
echo
    
    read -p "Продолжить установку? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Установка отменена"
        exit 0
    fi
}

# =============================================================================
# Создание структуры проекта
# =============================================================================

create_project_structure() {
    log_info "Создание структуры проекта..."
    
    # Бэкап существующего проекта
    if [ -d "$PROJECT_DIR" ] && [ "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]; then
      log_warning "Обнаружен существующий проект. Создание резервной копии..."
      mkdir -p "$PROJECT_DIR/backups"
      local TS="$(date +%Y%m%d_%H%M%S)"
      local BK="$PROJECT_DIR/backups/${TS}.tar.gz"
      tar --exclude='backups/*' -czf "$BK" -C "$PROJECT_DIR" . 
      log_success "Резервная копия создана: $BK"
    fi
    
    # Создание директорий
    mkdir -p "${PROJECT_DIR}"/{configs,volumes,scripts,backups}
    mkdir -p "${PROJECT_DIR}/configs"/{traefik,n8n}
    mkdir -p "${PROJECT_DIR}/volumes"/{traefik,postgres-n8n,n8n,qdrant,redis}
    
    log_info "Установка прав доступа для тома n8n..."
    chown -R 1000:1000 "$PROJECT_DIR/volumes/n8n"
    chmod -R go-rwx "$PROJECT_DIR/volumes/n8n" || true
    [ -f "$PROJECT_DIR/volumes/n8n/config" ] && chmod 600 "$PROJECT_DIR/volumes/n8n/config" || true
    
    log_success "Структура проекта создана"
}

# =============================================================================
# Генерация секретов
# =============================================================================

generate_secrets() {
  log_info "Генерация/загрузка секретов и паролей..."

  # если есть старый .env — подхватим из него, чтобы совпасть с имеющейся БД
  local OLD_ENV="${PROJECT_DIR}/.env"
  if [ -f "$OLD_ENV" ]; then
    # читаем только нужные строки, без eval
    local OLD_PGPASS
    local OLD_N8NKEY
    local OLD_REDIS
    OLD_PGPASS="$(grep -E '^POSTGRES_PASSWORD=' "$OLD_ENV" | head -n1 | cut -d= -f2- || true)"
    OLD_N8NKEY="$(grep -E '^N8N_ENCRYPTION_KEY=' "$OLD_ENV" | head -n1 | cut -d= -f2- || true)"
    OLD_REDIS="$(grep -E '^REDIS_PASSWORD=' "$OLD_ENV" | head -n1 | cut -d= -f2- || true)"
    if [ -n "$OLD_PGPASS" ]; then POSTGRES_PASSWORD="$OLD_PGPASS"; fi
    if [ -n "$OLD_N8NKEY" ]; then N8N_ENCRYPTION_KEY="$OLD_N8NKEY"; fi
    if [ -n "$OLD_REDIS" ]; then REDIS_PASSWORD="$OLD_REDIS"; fi
  fi

  # если значения всё ещё пустые — сгенерируем
  if [ -z "${N8N_ENCRYPTION_KEY:-}" ]; then N8N_ENCRYPTION_KEY="$(generate_password 32)"; fi
  if [ -z "${POSTGRES_PASSWORD:-}" ]; then POSTGRES_PASSWORD="$(generate_password 32)"; fi
  if [ -z "${REDIS_PASSWORD:-}" ]; then REDIS_PASSWORD="$(generate_password 32)"; fi

  QDRANT_API_KEY="$(generate_password 40)"
  TRAEFIK_DASHBOARD_PASSWORD="$(generate_password 24)"
  QDRANT_DASHBOARD_PASSWORD="$(generate_password 24)"

  QDRANT_DASHBOARD_HASH=$(docker run --rm httpd:alpine htpasswd -nbB qdrant "$QDRANT_DASHBOARD_PASSWORD" | sed -e 's/\$/\$\$/g')
  TRAEFIK_DASHBOARD_HASH=$(docker run --rm httpd:alpine htpasswd -nbB admin "$TRAEFIK_DASHBOARD_PASSWORD" | sed -e 's/\$/\$\$/g')

  log_success "Секреты готовы"
}


# =============================================================================
# Создание конфигурационных файлов
# =============================================================================

create_env_file() {
    log_info "Создание файла .env..."

    # вычисляем режим для n8n
    local EXEC_MODE="regular"
    if [ "$INSTALL_MODE" = "queue" ]; then
        EXEC_MODE="queue"
    fi

    cat > "$ENV_FILE" << EOF
# =============================================================================
# MEDIA WORKS - Конфигурация окружения
# Сгенерировано: $(date)
# =============================================================================

# Основные настройки
ROOT_DOMAIN=${ROOT_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
INSTALL_MODE=${INSTALL_MODE}
NETWORK_NAME=${NETWORK_NAME}

# Домены сервисов
N8N_HOST=${N8N_HOST}
QDRANT_HOST=${QDRANT_HOST}
TRAEFIK_HOST=${TRAEFIK_HOST}

# PostgreSQL для n8n
POSTGRES_USER=n8n
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=n8n
POSTGRES_HOST=postgres-n8n
POSTGRES_PORT=5432

# n8n настройки
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_PROTOCOL=https
N8N_PORT=5678
N8N_WEBHOOK_URL=https://${N8N_HOST}/
N8N_EDITOR_BASE_URL=https://${N8N_HOST}/
WEBHOOK_URL=https://${N8N_HOST}/
N8N_LOG_LEVEL=info
N8N_METRICS=true
N8N_VERSION_NOTIFICATIONS_ENABLED=true
GENERIC_TIMEZONE=Europe/Moscow

# База данных n8n
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres-n8n
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}

# рекомендации для QUEUE/раннеров и корректного выключения
N8N_RUNNERS_ENABLED=true
OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
N8N_CONCURRENCY_PRODUCTION_LIMIT=10
N8N_QUEUE_BULL_GRACEFULSHUTDOWNTIMEOUT=300
N8N_GRACEFUL_SHUTDOWN_TIMEOUT=300

# Redis (для queue mode)
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASSWORD}

# Режим исполнений n8n
EXECUTIONS_MODE=${EXEC_MODE}
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
QUEUE_HEALTH_CHECK_ACTIVE=true

# Qdrant
QDRANT_API_KEY=${QDRANT_API_KEY}
QDRANT_PORT=6333
QDRANT_GRPC_PORT=6334
QDRANT_DASHBOARD_USER=qdrant
QDRANT_DASHBOARD_PASSWORD=${QDRANT_DASHBOARD_PASSWORD}
QDRANT_DASHBOARD_HASH=${QDRANT_DASHBOARD_HASH}

# Traefik
TRAEFIK_DASHBOARD_USER=admin
TRAEFIK_DASHBOARD_PASSWORD=${TRAEFIK_DASHBOARD_PASSWORD}
TRAEFIK_DASHBOARD_HASH=${TRAEFIK_DASHBOARD_HASH}

# Версии образов
N8N_VERSION=latest
POSTGRES_VERSION=15-alpine
REDIS_VERSION=7-alpine
QDRANT_VERSION=latest
TRAEFIK_VERSION=3.0
EOF

    sed -i 's/[[:space:]]*$//' "$ENV_FILE"
    log_success "Файл .env создан"
}


create_traefik_config() {
    log_info "Создание конфигурации Traefik..."
    
    # Статическая конфигурация
    cat > "${PROJECT_DIR}/configs/traefik/traefik.yml" << EOF
# Статическая конфигурация Traefik
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
    http:
      tls:
        certResolver: letsencrypt
  traefik:
    address: ":8080"  # API/Dashboard изнутри контейнера

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: mworks-network
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${ACME_EMAIL}
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web

log:
  level: DEBUG
  format: common

accessLog:
  format: common

EOF
    
    # Создание acme.json
    touch "${PROJECT_DIR}/volumes/traefik/acme.json"
    chmod 600 "${PROJECT_DIR}/volumes/traefik/acme.json"
    
    log_success "Конфигурация Traefik создана"
}

create_docker_compose() {
    log_info "Создание docker-compose.yml..."
    
    # Базовая часть compose файла с фиксированными значениями
    cat > "$COMPOSE_FILE" << 'EOF'
networks:
  mworks-network:
    external: true

services:
  # =============================================================================
  # Traefik - Reverse Proxy
  # =============================================================================
  traefik:
    image: traefik:3.0
    container_name: mworks-traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - mworks-network
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./volumes/traefik/acme.json:/letsencrypt/acme.json
      - ./configs/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(`${TRAEFIK_HOST}`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls=true"
      - "traefik.http.routers.traefik.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.routers.traefik.middlewares=traefik-auth"
      - "traefik.http.middlewares.traefik-auth.basicauth.users=${TRAEFIK_DASHBOARD_HASH}"

  # =============================================================================
  # PostgreSQL для n8n
  # =============================================================================
  postgres-n8n:
    image: postgres:15-alpine
    container_name: mworks-postgres-n8n
    restart: unless-stopped
    networks:
      - mworks-network
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=n8n
      - PGDATA=/var/lib/postgresql/data/pgdata
    volumes:
      - ./volumes/postgres-n8n:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8n"]
      interval: 10s
      timeout: 5s
      retries: 5
EOF
    
    # Добавление n8n в зависимости от режима
    if [ "$INSTALL_MODE" = "queue" ]; then
        # Queue mode с Redis и воркерами
        cat >> "$COMPOSE_FILE" << 'EOF'

  # =============================================================================
  # Redis для Queue Mode
  # =============================================================================
  redis:
    image: redis:7-alpine
    container_name: mworks-redis
    restart: unless-stopped
    networks:
      - mworks-network
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - ./volumes/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "--raw", "PING"]
      interval: 10s
      timeout: 5s
      retries: 5

  # =============================================================================
  # n8n — Web/UI (main) в режиме queue
  # =============================================================================
  n8n-main:
    image: n8nio/n8n:${N8N_VERSION}
    container_name: mworks-n8n-main
    restart: unless-stopped
    networks:
      - mworks-network
    command: start
    environment:
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - N8N_HOST=${N8N_HOST}
      - N8N_EDITOR_BASE_URL=https://${N8N_HOST}/
      - WEBHOOK_URL=https://${N8N_HOST}/
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_LOG_LEVEL=info
      - N8N_METRICS=true
      - N8N_VERSION_NOTIFICATIONS_ENABLED=true
      - GENERIC_TIMEZONE=Europe/Moscow
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres-n8n
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - QUEUE_HEALTH_CHECK_ACTIVE=true
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_PERSONALIZATION_ENABLED=false
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      - OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
      - N8N_RUNNERS_ENABLED=true
      - OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
      - N8N_QUEUE_BULL_GRACEFULSHUTDOWNTIMEOUT=300
      - N8N_GRACEFUL_SHUTDOWN_TIMEOUT=300     

    volumes:
      - ./volumes/n8n:/home/node/.n8n
    depends_on:
      postgres-n8n:
        condition: service_healthy
      redis:
        condition: service_started
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n-main.priority=50"
      - "traefik.http.routers.n8n-main.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n-main.entrypoints=websecure"
      - "traefik.http.routers.n8n-main.tls=true"
      - "traefik.http.routers.n8n-main.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n-main.loadbalancer.server.port=5678"
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:5678/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 60s # Даём контейнеру 60 секунд на запуск до начала проверок      

  # =============================================================================
  # n8n — Worker (обрабатывает задания очереди)
  # =============================================================================
  n8n-worker:
    image: n8nio/n8n:${N8N_VERSION}
    container_name: mworks-n8n-worker
    restart: unless-stopped
    networks:
      - mworks-network
    command: worker
    environment:
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_LOG_LEVEL=info
      - GENERIC_TIMEZONE=Europe/Moscow
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres-n8n
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_CONCURRENCY_PRODUCTION_LIMIT=10
      - N8N_QUEUE_BULL_GRACEFULSHUTDOWNTIMEOUT=300
      - N8N_GRACEFUL_SHUTDOWN_TIMEOUT=300
      - N8N_RUNNERS_ENABLED=true
      - QUEUE_HEALTH_CHECK_ACTIVE=true       
    depends_on:
      postgres-n8n:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - ./volumes/n8n:/home/node/.n8n   

  # =============================================================================
  # n8n — Webhook processor (для внешних вебхуков в QUEUE)
  # =============================================================================
  n8n-webhook:
    image: n8nio/n8n:${N8N_VERSION}
    container_name: mworks-n8n-webhook
    restart: unless-stopped
    networks:
      - mworks-network
    command: webhook
    environment:
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_LOG_LEVEL=info
      - GENERIC_TIMEZONE=Europe/Moscow
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres-n8n
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      - N8N_QUEUE_BULL_GRACEFULSHUTDOWNTIMEOUT=300
      - N8N_GRACEFUL_SHUTDOWN_TIMEOUT=300
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    depends_on:
      postgres-n8n:
        condition: service_healthy
      redis:
        condition: service_healthy # service_healthy надежнее, чем service_started
    labels:
    - "traefik.enable=true"
    - "traefik.http.routers.n8n-webhook.rule=Host(${N8N_HOST}) && (PathPrefix(`/webhook`) || PathPrefix(`/webhook-test`))"
    - "traefik.http.routers.n8n-webhook.entrypoints=websecure"
    - "traefik.http.routers.n8n-webhook.tls=true"
    - "traefik.http.routers.n8n-webhook.tls.certresolver=letsencrypt"
    - "traefik.http.routers.n8n-webhook.priority=100"
    - "traefik.http.services.n8n-webhook.loadbalancer.server.port=5678"



EOF
    fi
    
    # Добавляем одиночный n8n для режимов RAG и ONLY N8N
    if [ "$INSTALL_MODE" = "rag" ] || [ "$INSTALL_MODE" = "n8n-only" ]; then
        cat >> "$COMPOSE_FILE" << 'EOF'

  # =============================================================================
  # n8n (Regular / Single instance)
  # =============================================================================
  n8n:
    image: n8nio/n8n:${N8N_VERSION}
    container_name: mworks-n8n
    restart: unless-stopped
    networks:
      - mworks-network
    # command: start -- это command по умолчанию, его можно не указывать
    # Все переменные окружения уже в .env!
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    environment:
      - N8N_PROTOCOL=https
      - N8N_PORT=5678
      - N8N_HOST=${N8N_HOST}
      - N8N_EDITOR_BASE_URL=https://${N8N_HOST}/
      - WEBHOOK_URL=https://${N8N_HOST}/
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_LOG_LEVEL=info
      - N8N_METRICS=true
      - N8N_VERSION_NOTIFICATIONS_ENABLED=true
      - GENERIC_TIMEZONE=Europe/Moscow
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres-n8n
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - EXECUTIONS_MODE=regular
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
      - N8N_RUNNERS_ENABLED=true
      - N8N_TRUST_PROXY=true
    depends_on:
      postgres-n8n:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls=true"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:5678/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 15s
      timeout: 5s
      retries: 10
EOF
    fi

    # Qdrant нужен для RAG и QUEUE (кроме n8n-only)
    if [ "$INSTALL_MODE" != "n8n-only" ]; then
        cat >> "$COMPOSE_FILE" << 'EOF'

  # =============================================================================
  # Qdrant Vector Database
  # =============================================================================
  # =============================================================================
  # Qdrant Vector Database
  # =============================================================================
  qdrant:
    image: qdrant/qdrant:${QDRANT_VERSION}
    container_name: mworks-qdrant
    restart: unless-stopped
    networks:
      - mworks-network
    volumes:
      - ./volumes/qdrant:/qdrant/storage
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=mworks-network"

      # ---------- SERVICE (явное имя/порт) ----------
      - "traefik.http.services.qdrant-svc.loadbalancer.server.port=6333"

      # ---------- MIDDLEWARES ----------
      # 1) редирект корня '/' -> '/dashboard'
      - "traefik.http.middlewares.qdrant-rootredir.redirectregex.regex=^/$"
      - "traefik.http.middlewares.qdrant-rootredir.redirectregex.replacement=/dashboard"
      - "traefik.http.middlewares.qdrant-rootredir.redirectregex.permanent=true"

      # 2) https-редирект для http-роутера (одним шагом в https)
      - "traefik.http.middlewares.qdrant-https.redirectscheme.scheme=https"
      - "traefik.http.middlewares.qdrant-https.redirectscheme.permanent=true"

      # 3) basic auth для https
      - "traefik.http.middlewares.qdrant-auth.basicauth.users=${QDRANT_DASHBOARD_HASH}"

      # ---------- ROUTERS ----------
      # HTTP router: Host → сразу редиректим и по схеме (http->https), и по пути (/ -> /dashboard)
      - "traefik.http.routers.qdrant-web.rule=Host(`${QDRANT_HOST}`)"
      - "traefik.http.routers.qdrant-web.entrypoints=web"
      - "traefik.http.routers.qdrant-web.middlewares=qdrant-rootredir,qdrant-https"

      # HTTPS router: Host → сервис + редирект корня + basic auth
      - "traefik.http.routers.qdrant-secure.rule=Host(`${QDRANT_HOST}`)"
      - "traefik.http.routers.qdrant-secure.entrypoints=websecure"
      - "traefik.http.routers.qdrant-secure.tls=true"
      - "traefik.http.routers.qdrant-secure.tls.certresolver=letsencrypt"
      - "traefik.http.routers.qdrant-secure.service=qdrant-svc"
      - "traefik.http.routers.qdrant-secure.middlewares=qdrant-rootredir,qdrant-auth"

EOF
    fi

    log_success "Docker Compose файл создан"
}

# =============================================================================
# Создание скриптов управления
# =============================================================================

create_management_scripts() {
    log_info "Создание скриптов управления..."
    
    # Скрипт запуска
    cat > "${PROJECT_DIR}/scripts/start.sh" << 'EOF'
#!/bin/bash
# Запуск сервисов MEDIA WORKS n8n

cd /opt/mworks-n8n
docker compose up -d
echo "Сервисы запущены"
docker compose ps
EOF
    
    # Скрипт остановки
    cat > "${PROJECT_DIR}/scripts/stop.sh" << 'EOF'
#!/bin/bash
# Остановка сервисов MEDIA WORKS n8n

cd /opt/mworks-n8n
docker compose down
echo "Сервисы остановлены"
EOF
    
    # Скрипт перезапуска
    cat > "${PROJECT_DIR}/scripts/restart.sh" << 'EOF'
#!/bin/bash
# Перезапуск сервисов MEDIA WORKS n8n

cd /opt/mworks-n8n
docker compose restart
echo "Сервисы перезапущены"
docker compose ps
EOF

    # Скрипт масштабирования
cat > "${PROJECT_DIR}/scripts/scale.sh" << 'EOF'
#!/bin/bash
# Масштабирование сервисов: ./scripts/scale.sh n8n-worker 3
set -euo pipefail
cd /opt/mworks-n8n
svc="${1:-}"; replicas="${2:-}"
if [ -z "$svc" ] || [ -z "$replicas" ]; then
  echo "Usage: $0 <service> <replicas>"
  exit 1
fi
docker compose up -d --scale "${svc}=${replicas}"
docker compose ps
EOF
chmod +x "${PROJECT_DIR}/scripts/scale.sh"

    
    # Скрипт обновления
    cat > "${PROJECT_DIR}/scripts/update.sh" << 'EOF'
#!/bin/bash
# Обновление сервисов MEDIA WORKS n8n

set -e

echo "Начинаем обновление сервисов..."
cd /opt/mworks-n8n

# Создание резервной копии
BACKUP_DIR="./backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp docker-compose.yml "$BACKUP_DIR/"
cp .env "$BACKUP_DIR/"
echo "Резервная копия создана: $BACKUP_DIR"

# Получение новых образов
echo "Загрузка новых образов..."
docker compose pull

# Перезапуск с новыми образами
echo "Перезапуск сервисов..."
docker compose up -d

# Очистка старых образов
echo "Очистка старых образов..."
docker image prune -f

echo "Обновление завершено!"
docker compose ps
EOF
    
# Скрипт резервного копирования
cat > "${PROJECT_DIR}/scripts/backup.sh" << 'EOF'
#!/bin/bash
# Резервное копирование MEDIA WORKS n8n
set -euo pipefail

PROJECT_DIR="/opt/mworks-n8n"
BACKUPS_DIR="${PROJECT_DIR}/backups"
TS="$(date +%Y%m%d_%H%M%S)"
ARCHIVE="${BACKUPS_DIR}/${TS}.tar.gz"

mkdir -p "${BACKUPS_DIR}"

echo "Создание резервной копии в ${ARCHIVE}..."

cd "${PROJECT_DIR}"

# Останавливаем контейнеры (быстро и корректно)
docker compose stop

# Упаковываем весь проект, исключая каталог backups (чтобы не заархивировать сам архив)
# Включаются: docker-compose.yml, .env, configs/, volumes/, scripts/, README.md и др.
tar --exclude='backups/*' -czf "${ARCHIVE}" -C "${PROJECT_DIR}" .

# Запускаем обратно
docker compose start

echo "Готово. Архив: ${ARCHIVE}"
ls -lh "${ARCHIVE}"
EOF

    
    # Скрипт просмотра логов
    cat > "${PROJECT_DIR}/scripts/logs.sh" << 'EOF'
#!/bin/bash
# Просмотр логов MEDIA WORKS n8n

cd /opt/mworks-n8n

if [ -z "$1" ]; then
    docker compose logs -f --tail=100
else
    docker compose logs -f --tail=100 "$1"
fi
EOF
    
    # Скрипт статуса
    cat > "${PROJECT_DIR}/scripts/status.sh" << 'EOF'
#!/bin/bash
# Статус сервисов MEDIA WORKS n8n

cd /opt/mworks-n8n
echo "═══════════════════════════════════════════════════════════════════════════════════════"
echo "                                  СТАТУС СЕРВИСОВ"
echo "═══════════════════════════════════════════════════════════════════════════════════════"
docker compose ps
echo
echo "═══════════════════════════════════════════════════════════════════════════════════════"
echo "                              ИСПОЛЬЗОВАНИЕ РЕСУРСОВ"
echo "═══════════════════════════════════════════════════════════════════════════════════════"
docker stats --no-stream
EOF
    
    # Делаем скрипты исполняемыми
    chmod +x "${PROJECT_DIR}/scripts/"*.sh
    
    log_success "Скрипты управления созданы"
}

# =============================================================================
# Создание документации
# =============================================================================

create_documentation() {
    log_info "Создание документации..."
    
    # README.md
    cat > "${PROJECT_DIR}/README.md" << EOF
# MEDIA WORKS n8n Platform

## Информация об установке

- **Дата установки:** $(date)
- **Режим:** ${INSTALL_MODE}
- **Основной домен:** ${ROOT_DOMAIN}

## Доступ к сервисам

- **n8n:** https://${N8N_HOST}
EOF
    
    if [ "$INSTALL_MODE" != "n8n-only" ]; then
        cat >> "${PROJECT_DIR}/README.md" << EOF
- **Qdrant:** https://${QDRANT_HOST}
EOF
    fi
    
    cat >> "${PROJECT_DIR}/README.md" << EOF
- **Traefik Dashboard:** https://${TRAEFIK_HOST}

## Управление сервисами

### Основные команды

\`\`\`bash
# Запуск всех сервисов
./scripts/start.sh

# Остановка всех сервисов
./scripts/stop.sh

# Перезапуск сервисов
./scripts/restart.sh

# Просмотр статуса
./scripts/status.sh

# Просмотр логов
./scripts/logs.sh
./scripts/logs.sh n8n  # логи конкретного сервиса

# Обновление сервисов
./scripts/update.sh

# Создание резервной копии
./scripts/backup.sh
\`\`\`

### Docker Compose команды

\`\`\`bash
cd /opt/mworks-n8n

# Просмотр запущенных контейнеров
docker compose ps

# Просмотр логов
docker compose logs -f

# Перезапуск отдельного сервиса
docker compose restart n8n

# Выполнение команды в контейнере
docker compose exec n8n sh
\`\`\`

## Структура проекта

\`\`\`
/opt/mworks-n8n/
├── docker-compose.yml    # Основной файл конфигурации
├── .env                  # Переменные окружения
├── configs/              # Конфигурационные файлы
│   └── traefik/         # Конфигурация Traefik
├── volumes/              # Данные сервисов
│   ├── n8n/             # Данные n8n
│   ├── postgres-n8n/    # База данных n8n
│   ├── qdrant/          # Векторная база данных
│   └── traefik/         # Сертификаты SSL
├── scripts/              # Скрипты управления
├── backups/              # Резервные копии
└── credentials.txt       # Учетные данные (УДАЛИТЬ ПОСЛЕ СОХРАНЕНИЯ!)
\`\`\`
EOF
    
    log_success "Документация создана"
}

wait_for_postgres() {
  log_info "Ждём готовности Postgres (health=healthy)..."
  local tries=60
  while [ $tries -gt 0 ]; do
    if docker ps --format '{{.Names}} {{.Status}}' | grep -q 'mworks-postgres-n8n .*healthy'; then
      log_success "Postgres готов"
      return 0
    fi
    sleep 2
    tries=$((tries-1))
  done
  log_error "Postgres не стал healthy за отведённое время"
  return 1
}

sync_postgres_password() {
  # Принудительно выставляем пароль роли n8n в значение из .env, даже если том уже инициализирован
  log_info "Синхронизируем пароль роли Postgres 'n8n' с .env..."
  # Попробуем локальное подключение внутри контейнера — как правило, для local сокетов пароль не нужен
  if docker exec -i mworks-postgres-n8n psql -U n8n -d postgres -c "ALTER USER n8n WITH PASSWORD '${POSTGRES_PASSWORD}';" >/dev/null 2>&1; then
    log_success "Пароль роли 'n8n' синхронизирован"
  else
    # запасной вариант — через пользователя postgres (если доступен)
    if docker exec -i mworks-postgres-n8n psql -U postgres -d postgres -c "ALTER USER n8n WITH PASSWORD '${POSTGRES_PASSWORD}';" >/dev/null 2>&1; then
      log_success "Пароль роли 'n8n' синхронизирован через суперпользователя 'postgres'"
    else
      log_warning "Не удалось синхронизировать пароль автоматически. Проверь pg_hba.conf/доступ. Продолжаем."
    fi
  fi
}


save_credentials() {
    log_info "Сохранение учетных данных..."
    
    cat > "$CREDENTIALS_FILE" << EOF
═══════════════════════════════════════════════════════════════════════════════════════
                        MEDIA WORKS - УЧЕТНЫЕ ДАННЫЕ
═══════════════════════════════════════════════════════════════════════════════════════
Дата создания: $(date)
Режим установки: ${INSTALL_MODE}
═══════════════════════════════════════════════════════════════════════════════════════

ДОСТУП К СЕРВИСАМ
───────────────────────────────────────────────────────────────────────────────────────

n8n:
  URL: https://${N8N_HOST}
  Примечание: При первом входе нужно создать учетную запись администратора

EOF
    
    if [ "$INSTALL_MODE" != "n8n-only" ]; then
        cat >> "$CREDENTIALS_FILE" << EOF
Qdrant:
  URL: https://${QDRANT_HOST}
  Dashboard User: qdrant
  Dashboard Password: ${QDRANT_DASHBOARD_PASSWORD}
  API Key: ${QDRANT_API_KEY}
  Внутренний адрес: qdrant:6333
  gRPC порт: 6334

EOF
    fi
    
    cat >> "$CREDENTIALS_FILE" << EOF
Traefik Dashboard:
  URL: https://${TRAEFIK_HOST}
  Логин: admin
  Пароль: ${TRAEFIK_DASHBOARD_PASSWORD}

═══════════════════════════════════════════════════════════════════════════════════════

БАЗЫ ДАННЫХ И СЕРВИСЫ
───────────────────────────────────────────────────────────────────────────────────────

PostgreSQL (n8n):
  Host: postgres-n8n
  Port: 5432
  Database: n8n
  Username: n8n
  Password: ${POSTGRES_PASSWORD}

EOF
    
    if [ "$INSTALL_MODE" = "queue" ]; then
        cat >> "$CREDENTIALS_FILE" << EOF
Redis:
  Host: redis
  Port: 6379
  Password: ${REDIS_PASSWORD}

EOF
    fi
    
    cat >> "$CREDENTIALS_FILE" << EOF
═══════════════════════════════════════════════════════════════════════════════════════

КЛЮЧИ И СЕКРЕТЫ
───────────────────────────────────────────────────────────────────────────────────────

N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}

═══════════════════════════════════════════════════════════════════════════════════════

ВАЖНО!
═══════════════════════════════════════════════════════════════════════════════════════

1. СОХРАНИТЕ этот файл в безопасном месте
2. УДАЛИТЕ этот файл с сервера после сохранения
3. Никому не передавайте эти данные
4. При утере паролей восстановление невозможно

═══════════════════════════════════════════════════════════════════════════════════════

Путь к проекту: ${PROJECT_DIR}
Конфигурация: ${PROJECT_DIR}/.env
Управление: ${PROJECT_DIR}/scripts/

═══════════════════════════════════════════════════════════════════════════════════════
EOF
    
    chmod 600 "$CREDENTIALS_FILE"
    log_success "Учетные данные сохранены в $CREDENTIALS_FILE"
}

# =============================================================================
# Запуск сервисов
# =============================================================================

start_services() {
  log_info "Запуск сервисов по этапам..."
  cd "$PROJECT_DIR"

  # Пересоздаём сеть
  docker network rm $NETWORK_NAME 2>/dev/null || true
  docker network create $NETWORK_NAME || true

  # 1) Поднимаем только базовые зависимости
    # всегда
    docker compose up -d traefik postgres-n8n

    # redis только для queue
    if [ "$INSTALL_MODE" = "queue" ]; then
      docker compose up -d redis
    fi

    # qdrant кроме n8n-only
    if [ "$INSTALL_MODE" != "n8n-only" ]; then
      docker compose up -d qdrant
    fi


  # 2) Ждём Postgres и синхронизируем пароль роли n8n
  wait_for_postgres
  # Загружаем переменные из .env, чтобы получить POSTGRES_PASSWORD
  # (без eval; просто source)
  set -a
  . "$ENV_FILE"
  set +a
  sync_postgres_password

  # 3) Поднимаем n8n-слой
    if [ "$INSTALL_MODE" = "queue" ]; then
      docker compose rm -sf n8n 2>/dev/null || true

      docker compose up -d n8n-main

      log_info "Ждём окончания миграций n8n-main..."
      for i in $(seq 1 120); do
        if docker logs --since 30s mworks-n8n-main 2>&1 | grep -q "Editor is now accessible"; then
          log_success "Миграции n8n-main завершены"
          break
        fi
        sleep 2
      done

      docker compose up -d n8n-webhook
      docker compose up -d n8n-worker
    else
      docker compose up -d n8n
    fi


  log_info "Ожидание стабилизации контейнеров..."
  sleep 5
  docker compose ps
}


# =============================================================================
# Финальный вывод
# =============================================================================

show_completion() {
    echo
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}           УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo
    
    echo -e "${CYAN}ДОСТУП К СЕРВИСАМ:${NC}"
    echo -e "  n8n:      ${GREEN}https://${N8N_HOST}${NC}"
    if [ "$INSTALL_MODE" != "n8n-only" ]; then
        echo -e "  Qdrant:   ${GREEN}https://${QDRANT_HOST}/dashboard/${NC}"
    fi
    echo -e "  Traefik:  ${GREEN}https://${TRAEFIK_HOST}/dashboard/${NC}"
    echo
    
    echo -e "${CYAN}ФАЙЛЫ ПРОЕКТА:${NC}"
    echo -e "  Каталог проекта:  ${GREEN}${PROJECT_DIR}${NC}"
    echo -e "  Учетные данные:   ${YELLOW}${CREDENTIALS_FILE}${NC}"
    echo -e "  Скрипты:          ${GREEN}${PROJECT_DIR}/scripts/${NC}"
    echo
    
    echo -e "${YELLOW}ВАЖНЫЕ ДЕЙСТВИЯ:${NC}"
    echo -e "  1. Настройте DNS записи для доменов"
    echo -e "  2. Сохраните файл ${CREDENTIALS_FILE}"
    echo -e "  3. ${RED}УДАЛИТЕ${NC} файл credentials.txt после сохранения"
    echo -e "  4. Дождитесь выдачи SSL сертификатов (2-3 минуты)"
    echo
    
    echo -e "${CYAN}УПРАВЛЕНИЕ:${NC}"
    echo -e "  Статус:           ${PROJECT_DIR}/scripts/status.sh"
    echo -e "  Логи:             ${PROJECT_DIR}/scripts/logs.sh"
    echo -e "  Перезапуск:       ${PROJECT_DIR}/scripts/restart.sh"
    echo -e "  Резервная копия:  ${PROJECT_DIR}/scripts/backup.sh"
    echo
    
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}                        MEDIA WORKS${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "  📧 Email:     hello@mworks.ru"
    echo -e "  🌐 Сайт:      https://mworks.ru"
    echo -e "  💬 Telegram:  @mworks_support"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo
}

# =============================================================================
# Основная функция
# =============================================================================

main() {
    # Показ баннера
    show_banner
    
    # Проверки системы
    check_os
    check_root
    check_ports
    
    # Установка зависимостей
    install_dependencies
    enable_overcommit_memory
    install_docker
    
    # Сбор данных от пользователя
    collect_user_input
    
    # Создание проекта
    create_project_structure
    generate_secrets
    
    # Создание конфигураций
    create_env_file
    create_traefik_config
    create_docker_compose
    
    # Создание скриптов и документации
    create_management_scripts
    create_documentation
    save_credentials
    
    # Запуск сервисов
    start_services
    
    # Финальный вывод
    show_completion
}

# Запуск основной функции
main "$@"
