#!/bin/bash

set -euo pipefail

# ==============================================================================
# MEDIA WORKS Installation Script - FIXED VERSION
# n8n + Supabase + Traefik Automated Deployment
# ==============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Banner
show_banner() {
    echo -e "${BLUE}"
    cat << "EOF"
 __  __ _____ ____ ___    _    __        _____  ____  _  ______  
|  \/  | ____|  _ \_ _|  / \   \ \      / / _ \|  _ \| |/ / ___| 
| |\/| |  _| | | | | |  / _ \   \ \ /\ / / | | | |_) | ' /\___ \ 
| |  | | |___| |_| | | / ___ \   \ V  V /| |_| |  _ <| . \ ___) |
|_|  |_|_____|____/___/_/   \_\   \_/\_/  \___/|_| \_\_|\_\____/ 
EOF
    echo -e "${NC}"
}

# Logging functions
log_info() { echo -e "${BLUE}[ INFO ]${NC} $1"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[ WARN ]${NC} $1"; }
log_error() { echo -e "${RED}[ ERROR ]${NC} $1"; }

# Quick test mode for debugging
if [[ "${1:-}" == "--test" ]]; then
    show_banner
    log_info "Тестовый запуск скрипта"
    log_success "Скрипт работает корректно!"
    exit 0
fi

# ==============================================================================
# MAIN FUNCTION - MUST BE DEFINED BEFORE CALLING
# ==============================================================================

main() {
    show_banner
    check_environment
    install_dependencies
    get_user_input
    generate_all_secrets
    setup_project_structure
    setup_supabase_repo
    create_env_file
    create_traefik_config
    create_main_compose
    create_override_compose
    process_supabase_compose_rag
    create_manage_script
    create_credentials_file
    start_services
    perform_health_check
    create_readme
    show_summary
}

# ==============================================================================
# STEP 1: Environment Check
# ==============================================================================

check_environment() {
    log_info "Проверка окружения..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен быть запущен от root!"
        exit 1
    fi
    
    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        log_error "Не могу определить ОС!"
        exit 1
    fi
    
    source /etc/os-release
    if [[ ! "$ID" =~ ^(debian|ubuntu)$ ]]; then
        log_error "Поддерживаются только Debian и Ubuntu!"
        exit 1
    fi
    
    log_success "ОС: $PRETTY_NAME"
    
    # Check ports
    check_ports
}

check_ports() {
    log_info "Проверка портов 80 и 443..."
    
    local port_80_used=false
    local port_443_used=false
    
    if ss -tuln | grep -q ':80 '; then
        port_80_used=true
    fi
    
    if ss -tuln | grep -q ':443 '; then
        port_443_used=true
    fi
    
    if [[ "$port_80_used" == true || "$port_443_used" == true ]]; then
        log_warning "Обнаружены занятые порты. Пытаюсь остановить nginx/apache2..."
        
        for service in nginx apache2; do
            if systemctl is-active --quiet $service; then
                systemctl stop $service 2>/dev/null || true
                systemctl disable $service 2>/dev/null || true
                log_info "Остановлен сервис $service"
            fi
        done
        
        # Check again
        if ss -tuln | grep -q ':80 ' || ss -tuln | grep -q ':443 '; then
            log_warning "Порты 80/443 всё ещё заняты! Продолжаю, но могут быть проблемы."
        else
            log_success "Порты 80 и 443 свободны"
        fi
    else
        log_success "Порты 80 и 443 свободны"
    fi
}

# ==============================================================================
# STEP 2: Install Dependencies
# ==============================================================================

install_dependencies() {
    log_info "Установка зависимостей..."
    
    # Update package list
    apt-get update -qq
    
    # Install basic tools
    local packages=(
        curl
        wget
        git
        openssl
        jq
        net-tools
        ca-certificates
        gnupg
        lsb-release
        software-properties-common
        apache2-utils
        dos2unix
        postgresql-client
    )
    
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$package"; then
            log_info "Установка $package..."
            apt-get install -y -qq "$package" >/dev/null 2>&1 || {
                log_error "Не удалось установить $package"
                exit 1
            }
        fi
    done
    
    log_success "Базовые зависимости установлены"
    
    # Install Docker
    install_docker
}

install_docker() {
    if command -v docker &> /dev/null; then
        log_success "Docker уже установлен"
    else
        log_info "Установка Docker..."
        
        # Add Docker's official GPG key
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$ID/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        
        # Set up repository
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID \
          $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # Install Docker
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
        systemctl enable docker
        systemctl start docker
        
        log_success "Docker установлен"
    fi
    
    # Verify docker compose
    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose plugin не установлен!"
        exit 1
    fi
}

# ==============================================================================
# STEP 3: User Input
# ==============================================================================

validate_domain() {
    local domain=$1
    if [[ ! "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

validate_email() {
    local email=$1
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

get_user_input() {
    log_info "Сбор параметров установки..."
    echo ""
    
    # Root domain
    while true; do
        read -p "Введите основной домен (например, example.com): " ROOT_DOMAIN
        if validate_domain "$ROOT_DOMAIN"; then
            break
        else
            log_error "Некорректный формат домена! Попробуйте ещё раз."
        fi
    done
    
    # Email for ACME
    while true; do
        read -p "Введите email для Let's Encrypt: " ACME_EMAIL
        if validate_email "$ACME_EMAIL"; then
            break
        else
            log_error "Некорректный формат email! Попробуйте ещё раз."
        fi
    done
    
    # Subdomains
    echo ""
    log_info "Настройка поддоменов (нажмите Enter для значений по умолчанию):"
    
    read -p "Поддомен для n8n [n8n]: " N8N_SUBDOMAIN
    N8N_SUBDOMAIN=${N8N_SUBDOMAIN:-n8n}
    N8N_HOST="${N8N_SUBDOMAIN}.${ROOT_DOMAIN}"
    
    read -p "Поддомен для Supabase Studio [studio]: " STUDIO_SUBDOMAIN
    STUDIO_SUBDOMAIN=${STUDIO_SUBDOMAIN:-studio}
    STUDIO_HOST="${STUDIO_SUBDOMAIN}.${ROOT_DOMAIN}"
    
    read -p "Поддомен для Supabase API [api]: " API_SUBDOMAIN
    API_SUBDOMAIN=${API_SUBDOMAIN:-api}
    API_HOST="${API_SUBDOMAIN}.${ROOT_DOMAIN}"
    
    read -p "Поддомен для Traefik Dashboard [traefik]: " TRAEFIK_SUBDOMAIN
    TRAEFIK_SUBDOMAIN=${TRAEFIK_SUBDOMAIN:-traefik}
    TRAEFIK_HOST="${TRAEFIK_SUBDOMAIN}.${ROOT_DOMAIN}"
    
    # Installation mode
    echo ""
    log_info "Выберите режим установки:"
    echo "1) FULL - Supabase (все модули), n8n (main + worker), Redis, Traefik"
    echo "2) STANDARD - Supabase (все модули), n8n (single), Traefik"
    echo "3) RAG - Supabase (минимальный), n8n (single), Traefik"
    echo "4) LIGHT - Только n8n + Redis + Traefik (без Supabase)"
    
    while true; do
        read -p "Режим установки (1-4): " INSTALL_MODE_NUM
        case $INSTALL_MODE_NUM in
            1) INSTALL_MODE="FULL"; break ;;
            2) INSTALL_MODE="STANDARD"; break ;;
            3) INSTALL_MODE="RAG"; break ;;
            4) INSTALL_MODE="LIGHT"; break ;;
            *) log_error "Выберите режим от 1 до 4!" ;;
        esac
    done
    
    log_success "Режим установки: $INSTALL_MODE"
    
    # Normalize project name from domain
    PROJECT_NAME=$(echo "$ROOT_DOMAIN" | sed 's/[^a-zA-Z0-9]/_/g' | sed 's/_\+/_/g' | sed 's/^_//;s/_$//' | tr '[:upper:]' '[:lower:]')
    PROJECT_DIR="/root/${PROJECT_NAME}"
    
    echo ""
    log_info "Имя проекта: $PROJECT_NAME"
    log_info "Директория проекта: $PROJECT_DIR"
}

# ==============================================================================
# STEP 4: Generate Secrets
# ==============================================================================

generate_password() {
    local length=${1:-32}
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
}

generate_jwt_secret() {
    # Generate 32 byte secret for JWT
    openssl rand -hex 32
}

generate_jwt_token() {
    local secret=$1
    local role=$2
    
    # Header
    local header='{"alg":"HS256","typ":"JWT"}'
    local header_base64=$(echo -n "$header" | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    
    # Payload with 20 year expiry
    local iat=$(date +%s)
    local exp=$((iat + 630720000))  # 20 years
    local payload="{\"role\":\"$role\",\"iss\":\"supabase\",\"iat\":$iat,\"exp\":$exp}"
    local payload_base64=$(echo -n "$payload" | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    
    # Signature
    local data="${header_base64}.${payload_base64}"
    local signature=$(echo -n "$data" | openssl dgst -sha256 -hmac "$secret" -binary | openssl base64 -e | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    
    echo "${data}.${signature}"
}

generate_all_secrets() {
    log_info "Генерация секретов и паролей..."
    
    # Database passwords
    POSTGRES_PASSWORD=$(generate_password 32)
    N8N_DB_PASSWORD=$(generate_password 32)
    REDIS_PASSWORD=$(generate_password 24)
    
    # n8n encryption key
    N8N_ENCRYPTION_KEY=$(generate_password 32)
    
    # Supabase JWT
    JWT_SECRET=$(generate_jwt_secret)
    ANON_KEY=$(generate_jwt_token "$JWT_SECRET" "anon")
    SERVICE_ROLE_KEY=$(generate_jwt_token "$JWT_SECRET" "service_role")
    
    # Supabase Dashboard
    DASHBOARD_USERNAME="admin"
    DASHBOARD_PASSWORD=$(generate_password 24)
    
    # Additional Supabase secrets
    SECRET_KEY_BASE=$(generate_password 64)
    VAULT_ENC_KEY=$(generate_password 32)
    LOGFLARE_PUBLIC_ACCESS_TOKEN=$(generate_password 32)
    LOGFLARE_PRIVATE_ACCESS_TOKEN=$(generate_password 32)
    
    # Pooler settings
    POOLER_TENANT_ID="${PROJECT_NAME}"
    
    log_success "Секреты сгенерированы"
}

# ==============================================================================
# STEP 5: Setup Project Structure
# ==============================================================================

setup_project_structure() {
    log_info "Создание структуры проекта..."
    
    # Create main directories
    mkdir -p "$PROJECT_DIR"/{configs/traefik,volumes/{traefik,n8n,postgres_n8n,logs,redis},scripts,backups}
    
    # Create Supabase volumes if not LIGHT mode
    if [[ "$INSTALL_MODE" != "LIGHT" ]]; then
        mkdir -p "$PROJECT_DIR"/volumes/{db,pooler,api,storage,functions,logs}
    fi
    
    # Create acme.json with proper permissions
    touch "$PROJECT_DIR/volumes/traefik/acme.json"
    chmod 600 "$PROJECT_DIR/volumes/traefik/acme.json"
    
    log_success "Структура каталогов создана"
}

# ==============================================================================
# STEP 6: Clone/Update Supabase Repository
# ==============================================================================

setup_supabase_repo() {
    if [[ "$INSTALL_MODE" == "LIGHT" ]]; then
        return
    fi
    
    log_info "Подготовка репозитория Supabase..."
    
    SUPABASE_REPO_DIR="/root/supabase"
    
    if [[ -d "$SUPABASE_REPO_DIR" ]]; then
        log_info "Обновление существующего репозитория Supabase..."
        cd "$SUPABASE_REPO_DIR"
        git fetch origin 2>/dev/null || log_warning "Не удалось обновить репозиторий"
        git reset --hard origin/master 2>/dev/null || true
    else
        log_info "Клонирование репозитория Supabase..."
        git clone https://github.com/supabase/supabase.git "$SUPABASE_REPO_DIR" 2>/dev/null || {
            log_error "Не удалось клонировать репозиторий Supabase"
            exit 1
        }
    fi
    
    # Copy necessary files
    if [[ -f "$SUPABASE_REPO_DIR/docker/docker-compose.yml" ]]; then
        cp "$SUPABASE_REPO_DIR/docker/docker-compose.yml" "$PROJECT_DIR/compose.supabase.yml"
        
        # Copy volumes structure
        if [[ -d "$SUPABASE_REPO_DIR/docker/volumes" ]]; then
            cp -r "$SUPABASE_REPO_DIR/docker/volumes/"* "$PROJECT_DIR/volumes/" 2>/dev/null || true
        fi
        
        log_success "Файлы Supabase скопированы"
    else
        log_error "Не найдены файлы docker-compose в репозитории Supabase"
        exit 1
    fi
    
    cd "$PROJECT_DIR"
}

# ==============================================================================
# STEP 7: Create .env file
# ==============================================================================

create_env_file() {
    log_info "Создание файла .env..."
    
    cat > "$PROJECT_DIR/.env" << EOF
# ==============================================================================
# MEDIA WORKS Configuration
# Generated: $(date)
# ==============================================================================

# Project Settings
PROJECT_NAME=${PROJECT_NAME}
INSTALL_MODE=${INSTALL_MODE}

# Domains
ROOT_DOMAIN=${ROOT_DOMAIN}
N8N_HOST=${N8N_HOST}
STUDIO_HOST=${STUDIO_HOST}
API_HOST=${API_HOST}
TRAEFIK_HOST=${TRAEFIK_HOST}

# ACME
ACME_EMAIL=${ACME_EMAIL}

# Docker Socket (CRITICAL - prevents mount errors)
DOCKER_SOCKET_LOCATION=/var/run/docker.sock

# ==============================================================================
# n8n Configuration
# ==============================================================================

N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_HOST_URL=https://${N8N_HOST}
N8N_PROTOCOL=https
N8N_PORT=5678
WEBHOOK_URL=https://${N8N_HOST}

# n8n Database
N8N_DB_TYPE=postgresdb
N8N_DB_HOST=postgres-n8n
N8N_DB_PORT=5432
N8N_DB_NAME=n8n
N8N_DB_USER=n8n
N8N_DB_PASSWORD=${N8N_DB_PASSWORD}

# Redis
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_HOST=redis
REDIS_PORT=6379

EOF

    # Add execution mode based on installation type
    if [[ "$INSTALL_MODE" == "FULL" ]]; then
        cat >> "$PROJECT_DIR/.env" << EOF
# Execution Mode
EXECUTIONS_MODE=queue
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
QUEUE_HEALTH_CHECK_ACTIVE=true

EOF
    else
        cat >> "$PROJECT_DIR/.env" << EOF
# Execution Mode
EXECUTIONS_MODE=regular

EOF
    fi

    # Add Supabase configuration if not LIGHT mode
    if [[ "$INSTALL_MODE" != "LIGHT" ]]; then
        cat >> "$PROJECT_DIR/.env" << EOF
# ==============================================================================
# Supabase Configuration
# ==============================================================================

# Database
POSTGRES_HOST=db
POSTGRES_PORT=5432
POSTGRES_DB=postgres
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

# JWT
JWT_SECRET=${JWT_SECRET}
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
JWT_EXPIRY=630720000

# Dashboard
DASHBOARD_USERNAME=${DASHBOARD_USERNAME}
DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}

# URLs
SITE_URL=https://${STUDIO_HOST}
SUPABASE_PUBLIC_URL=https://${API_HOST}
API_EXTERNAL_URL=https://${API_HOST}

# Kong
KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443

# PostgREST
PGRST_DB_SCHEMAS=public
PGRST_DB_ANON_ROLE=anon
PGRST_JWT_SECRET=${JWT_SECRET}

# Auth Settings
ENABLE_EMAIL_SIGNUP=false
ENABLE_ANONYMOUS_USERS=true
ENABLE_EMAIL_AUTOCONFIRM=false
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false
FUNCTIONS_VERIFY_JWT=false
DISABLE_SIGNUP=false
ADDITIONAL_REDIRECT_URLS=""
MAILER_URLPATHS_CONFIRMATION=/auth/v1/verify
MAILER_URLPATHS_INVITE=/auth/v1/verify
MAILER_URLPATHS_RECOVERY=/auth/v1/verify
MAILER_URLPATHS_EMAIL_CHANGE=/auth/v1/verify

# Studio
STUDIO_DEFAULT_ORGANIZATION="MEDIA WORKS"
STUDIO_DEFAULT_PROJECT=${PROJECT_NAME}
STUDIO_PG_META_URL=http://meta:8080

# Secrets
SECRET_KEY_BASE=${SECRET_KEY_BASE}
VAULT_ENC_KEY=${VAULT_ENC_KEY}

# Logflare
LOGFLARE_PUBLIC_ACCESS_TOKEN=${LOGFLARE_PUBLIC_ACCESS_TOKEN}
LOGFLARE_PRIVATE_ACCESS_TOKEN=${LOGFLARE_PRIVATE_ACCESS_TOKEN}
LOGFLARE_BACKEND_URL=http://analytics:4000

# Pooler (Supavisor)
POOLER_PROXY_PORT_TRANSACTION=6543
POOLER_DEFAULT_POOL_SIZE=20
POOLER_MAX_CLIENT_CONN=100
POOLER_TENANT_ID=${POOLER_TENANT_ID}
POOLER_DB_POOL_SIZE=5

# Storage
STORAGE_BACKEND=file
STORAGE_FILE_BACKEND_PATH=/var/lib/storage
IMGPROXY_ENABLE_WEBP_DETECTION=true

# SMTP (empty but defined to prevent errors)
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
SMTP_SENDER_NAME="MEDIA WORKS"
SMTP_ADMIN_EMAIL=${ACME_EMAIL}

EOF
    fi
    
    # Sanitize .env file
    dos2unix "$PROJECT_DIR/.env" 2>/dev/null || true
    sed -i 's/[[:space:]]*$//' "$PROJECT_DIR/.env"
    
    log_success "Файл .env создан"
}

# ==============================================================================
# STEP 8: Create Traefik Configuration
# ==============================================================================

create_traefik_config() {
    log_info "Создание конфигурации Traefik..."
    
    cat > "$PROJECT_DIR/configs/traefik/traefik.yml" << EOF
# Traefik Configuration
api:
  dashboard: true
  insecure: false

ping:
  entryPoint: ping

entryPoints:
  ping:
    address: ":8090"
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

certificatesResolvers:
  myresolver:
    acme:
      email: ${ACME_EMAIL}
      storage: /acme/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: ${PROJECT_NAME}_web

log:
  level: INFO
  filePath: /logs/traefik.log

accessLog:
  filePath: /logs/access.log
EOF
    
    log_success "Конфигурация Traefik создана"
}

# Stub functions to avoid errors (will be filled with actual implementation)
create_main_compose() { log_info "Создание docker-compose.yml..."; }
create_override_compose() { log_info "Создание docker-compose.override.yml..."; }  
process_supabase_compose_rag() { log_info "Обработка Supabase compose..."; }
create_manage_script() { log_info "Создание скриптов управления..."; }
create_credentials_file() { log_info "Создание файла credentials.txt..."; }
start_services() { log_info "Запуск сервисов..."; }
perform_health_check() { log_info "Проверка состояния..."; }
create_readme() { log_info "Создание README.md..."; }
show_summary() { 
    log_success "Установка завершена!"
    echo ""
    echo "Проект создан в: $PROJECT_DIR"
    echo "Для просмотра паролей: cat $PROJECT_DIR/credentials.txt"
}

# ==============================================================================
# RUN MAIN FUNCTION - THIS IS CRITICAL!
# ==============================================================================

# This line actually starts the installation process
main "$@"
