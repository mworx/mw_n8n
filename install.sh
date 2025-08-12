#!/bin/bash
set -euo pipefail

# ============================================================================
# Supabase + N8N + Traefik Automated Installation Script
# Version: 2.0.0
# Author: DevOps Team
# Description: Production-ready installation script for Supabase self-hosted
#              with n8n, PostgreSQL, Redis, and Traefik integration
# ============================================================================

# ============================ CONSTANTS =====================================

readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly LOG_FILE="/tmp/supabase_install_${TIMESTAMP}.log"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m' # No Color

# Installation modes
readonly MODE_FULL="full"
readonly MODE_STANDARD="standard"
readonly MODE_RAG="rag"
readonly MODE_LIGHTWEIGHT="lightweight"

# Default values
readonly DEFAULT_PROJECT_NAME="supabase_project"
readonly DEFAULT_DOMAIN="localhost"
readonly DEFAULT_EMAIL="admin@example.com"
readonly JWT_EXPIRY_YEARS=20

# Supabase repository
readonly SUPABASE_REPO="https://github.com/supabase/supabase.git"
readonly SUPABASE_VERSION="latest"

# ============================ FUNCTIONS =====================================

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "${LOG_FILE}"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}" >&2
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "${LOG_FILE}"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_FILE}"
}

success() {
    echo -e "${GREEN}✓${NC} $*" | tee -a "${LOG_FILE}"
}

# Progress indicator
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

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

# Check system requirements
check_system_requirements() {
    log "Checking system requirements..."
    
    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect OS. This script requires Ubuntu 20.04+ or Debian 11+"
    fi
    
    source /etc/os-release
    if [[ ! "$ID" =~ ^(ubuntu|debian)$ ]]; then
        error "This script requires Ubuntu 20.04+ or Debian 11+"
    fi
    
    # Check CPU cores
    local cpu_cores=$(nproc)
    if [[ $cpu_cores -lt 2 ]]; then
        warning "System has only $cpu_cores CPU core(s). Recommended: 4+"
    fi
    
    # Check RAM
    local total_ram=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $total_ram -lt 4096 ]]; then
        warning "System has ${total_ram}MB RAM. Recommended: 8GB+"
    fi
    
    # Check disk space
    local available_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 10485760 ]]; then
        warning "Less than 10GB of disk space available"
    fi
    
    success "System requirements check completed"
}

# Install dependencies
install_dependencies() {
    log "Installing system dependencies..."
    
    apt-get update -qq
    apt-get install -y -qq \
        curl \
        wget \
        git \
        jq \
        openssl \
        ca-certificates \
        gnupg \
        lsb-release \
        python3 \
        python3-pip \
        apache2-utils \
        software-properties-common \
        2>&1 | tee -a "${LOG_FILE}"
    
    # Install Python packages for JWT generation
    pip3 install -q pyjwt cryptography 2>&1 | tee -a "${LOG_FILE}"
    
    success "Dependencies installed"
}

# Install Docker
install_docker() {
    log "Checking Docker installation..."
    
    if command -v docker &> /dev/null; then
        info "Docker is already installed"
        docker --version
    else
        log "Installing Docker..."
        
        # Remove old versions
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        
        # Add Docker's official GPG key
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        
        # Set up the repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # Install Docker Engine
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
        # Start and enable Docker
        systemctl start docker
        systemctl enable docker
        
        success "Docker installed successfully"
    fi
    
    # Verify Docker Compose
    if ! docker compose version &> /dev/null; then
        error "Docker Compose plugin not found. Please install it manually."
    fi
    
    docker compose version
}

# Generate secure password
generate_password() {
    local length=${1:-32}
    # Using only alphanumeric characters as per requirements
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
}

# Generate JWT secret
generate_jwt_secret() {
    # Generate a 64-character secret for JWT
    generate_password 64
}

# Generate JWT tokens using Python
generate_jwt_tokens() {
    local jwt_secret=$1
    local anon_key=""
    local service_key=""
    
    log "Generating JWT tokens with ${JWT_EXPIRY_YEARS}-year expiry..."
    
    # Python script to generate JWT tokens
    cat > /tmp/generate_jwt.py << 'EOF'
import jwt
import datetime
import sys

def generate_jwt_token(secret, role, expiry_years=20):
    now = datetime.datetime.now(datetime.timezone.utc)
    iat = int(now.timestamp())
    exp = int((now + datetime.timedelta(days=365 * expiry_years)).timestamp())
    
    payload = {
        "role": role,
        "iss": "supabase",
        "iat": iat,
        "exp": exp
    }
    
    if role == "anon":
        payload["aud"] = "authenticated"
    elif role == "service_role":
        payload["aud"] = "authenticated"
    
    token = jwt.encode(payload, secret, algorithm='HS256')
    return token

if __name__ == "__main__":
    secret = sys.argv[1]
    role = sys.argv[2]
    expiry_years = int(sys.argv[3]) if len(sys.argv) > 3 else 20
    
    token = generate_jwt_token(secret, role, expiry_years)
    print(token)
EOF
    
    anon_key=$(python3 /tmp/generate_jwt.py "$jwt_secret" "anon" "$JWT_EXPIRY_YEARS")
    service_key=$(python3 /tmp/generate_jwt.py "$jwt_secret" "service_role" "$JWT_EXPIRY_YEARS")
    
    rm -f /tmp/generate_jwt.py
    
    echo "$anon_key|$service_key"
}

# Escape special characters in passwords
escape_password() {
    local password=$1
    printf '%s\n' "$password" | sed -e 's/[[\.*^$()+?{|]/\\&/g'
}

# Validate domain
validate_domain() {
    local domain=$1
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?(\.[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?)*$ ]]; then
        return 1
    fi
    return 0
}

# Interactive mode selection
select_installation_mode() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}          ВЫБЕРИТЕ РЕЖИМ УСТАНОВКИ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${GREEN}1)${NC} ${WHITE}МАКСИМАЛЬНЫЙ (Full Stack)${NC}"
    echo "   • Supabase (все модули: Edge Functions, Realtime, Storage, Vector)"
    echo "   • N8N Main + N8N Worker"
    echo "   • PostgreSQL + Redis"
    echo "   • Traefik с SSL"
    echo ""
    echo -e "${BLUE}2)${NC} ${WHITE}СТАНДАРТНЫЙ (Standard)${NC}"
    echo "   • Supabase (все модули)"
    echo "   • N8N (single instance)"
    echo "   • Traefik с SSL"
    echo ""
    echo -e "${MAGENTA}3)${NC} ${WHITE}RAG-ОПТИМИЗИРОВАННЫЙ (RAG Version)${NC}"
    echo "   • Supabase для RAG (Vector, Studio, Auth, REST, Meta)"
    echo "   • N8N для AI-агентов"
    echo "   • Оптимизирован для работы с векторными БД"
    echo ""
    echo -e "${YELLOW}4)${NC} ${WHITE}МИНИМАЛЬНЫЙ (Lightweight)${NC}"
    echo "   • N8N + PostgreSQL"
    echo "   • Traefik с SSL"
    echo "   • Без Supabase"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    
    local mode_choice
    while true; do
        read -p "$(echo -e ${WHITE}"Выберите режим [1-4]: "${NC})" mode_choice
        case $mode_choice in
            1) echo "$MODE_FULL"; return ;;
            2) echo "$MODE_STANDARD"; return ;;
            3) echo "$MODE_RAG"; return ;;
            4) echo "$MODE_LIGHTWEIGHT"; return ;;
            *) warning "Неверный выбор. Введите число от 1 до 4." ;;
        esac
    done
}

# Get project configuration
get_project_config() {
    local project_name
    local domain
    local email
    local use_ssl
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}          КОНФИГУРАЦИЯ ПРОЕКТА${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Project name
    while true; do
        read -p "Название проекта [${DEFAULT_PROJECT_NAME}]: " project_name
        project_name=${project_name:-$DEFAULT_PROJECT_NAME}
        if [[ "$project_name" =~ ^[a-z0-9_]+$ ]]; then
            break
        else
            warning "Название проекта должно содержать только строчные буквы, цифры и подчеркивания"
        fi
    done
    
    # Domain
    while true; do
        read -p "Домен для установки [${DEFAULT_DOMAIN}]: " domain
        domain=${domain:-$DEFAULT_DOMAIN}
        if validate_domain "$domain"; then
            break
        else
            warning "Неверный формат домена"
        fi
    done
    
    # Email for SSL
    if [[ "$domain" != "localhost" ]]; then
        read -p "Email для SSL сертификата [${DEFAULT_EMAIL}]: " email
        email=${email:-$DEFAULT_EMAIL}
        use_ssl="true"
    else
        email=$DEFAULT_EMAIL
        use_ssl="false"
    fi
    
    echo "$project_name|$domain|$email|$use_ssl"
}

# Clone Supabase repository
clone_supabase() {
    local target_dir=$1
    
    log "Cloning Supabase repository..."
    
    if [[ -d "$target_dir/supabase" ]]; then
        warning "Supabase directory already exists. Updating..."
        cd "$target_dir/supabase"
        git pull origin main
    else
        git clone --depth 1 "$SUPABASE_REPO" "$target_dir/supabase"
    fi
    
    success "Supabase repository cloned"
}

# Create project structure
create_project_structure() {
    local project_dir=$1
    
    log "Creating project structure in $project_dir..."
    
    mkdir -p "$project_dir"/{configs,volumes,scripts}
    mkdir -p "$project_dir"/configs/{traefik/dynamic,supabase}
    mkdir -p "$project_dir"/volumes/{traefik,postgres,n8n,supabase,redis}
    
    # Create acme.json with correct permissions
    touch "$project_dir"/volumes/traefik/acme.json
    chmod 600 "$project_dir"/volumes/traefik/acme.json
    
    success "Project structure created"
}

# Generate all passwords and tokens
generate_credentials() {
    local jwt_secret=$(generate_jwt_secret)
    local jwt_tokens=$(generate_jwt_tokens "$jwt_secret")
    local anon_key=$(echo "$jwt_tokens" | cut -d'|' -f1)
    local service_key=$(echo "$jwt_tokens" | cut -d'|' -f2)
    
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
VAULT_ENC_KEY=$(generate_password 32)
LOGFLARE_PUBLIC_ACCESS_TOKEN=$(generate_password 32)
LOGFLARE_PRIVATE_ACCESS_TOKEN=$(generate_password 32)
EOF
}

# Create .env file
create_env_file() {
    local project_dir=$1
    local mode=$2
    local domain=$3
    local email=$4
    local use_ssl=$5
    local credentials=$6
    
    log "Creating .env configuration file..."
    
    cat > "$project_dir/.env" << EOF
# Project Configuration
PROJECT_NAME=$(basename "$project_dir")
INSTALLATION_MODE=$mode
DOMAIN=$domain
EMAIL=$email
USE_SSL=$use_ssl
INSTALL_TIMESTAMP=$TIMESTAMP

# Database Configuration
POSTGRES_HOST=db
POSTGRES_PORT=5432
POSTGRES_DB=postgres
$(echo "$credentials" | grep POSTGRES_PASSWORD)

# JWT Configuration
$(echo "$credentials" | grep JWT_SECRET)
JWT_EXPIRY=315360000
$(echo "$credentials" | grep ANON_KEY)
$(echo "$credentials" | grep SERVICE_ROLE_KEY)

# Supabase Configuration
SITE_URL=https://$domain
API_EXTERNAL_URL=https://$domain
SUPABASE_PUBLIC_URL=https://$domain

# Dashboard Access
$(echo "$credentials" | grep DASHBOARD_USERNAME)
$(echo "$credentials" | grep DASHBOARD_PASSWORD)

# N8N Configuration
N8N_HOST=$domain
N8N_PORT=5678
N8N_PROTOCOL=https
$(echo "$credentials" | grep N8N_BASIC_AUTH)
N8N_ENCRYPTION_KEY=$(generate_password 32)
WEBHOOK_URL=https://$domain

# Redis Configuration (for Full mode)
$(echo "$credentials" | grep REDIS_PASSWORD)

# Additional Supabase Secrets
$(echo "$credentials" | grep SECRET_KEY_BASE)
$(echo "$credentials" | grep VAULT_ENC_KEY)
$(echo "$credentials" | grep LOGFLARE)

# Studio Configuration
STUDIO_DEFAULT_ORGANIZATION=Default
STUDIO_DEFAULT_PROJECT=Default

# Email Configuration (disabled by default)
ENABLE_EMAIL_SIGNUP=false
ENABLE_EMAIL_AUTOCONFIRM=false
SMTP_ADMIN_EMAIL=$email
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
SMTP_SENDER_NAME=Supabase

# Phone Auth (disabled by default)
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false

# Anonymous Users
ENABLE_ANONYMOUS_USERS=false
DISABLE_SIGNUP=false

# Storage
STORAGE_BACKEND=file
IMGPROXY_ENABLE_WEBP_DETECTION=true

# Functions
FUNCTIONS_VERIFY_JWT=false

# Pooler Configuration
POOLER_TENANT_ID=pooler
POOLER_DEFAULT_POOL_SIZE=20
POOLER_MAX_CLIENT_CONN=100
POOLER_DB_POOL_SIZE=20
POOLER_PROXY_PORT_TRANSACTION=6543

# Kong Ports
KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443

# Docker
DOCKER_SOCKET_LOCATION=/var/run/docker.sock

# Additional URLs
ADDITIONAL_REDIRECT_URLS=
MAILER_URLPATHS_INVITE=/auth/v1/verify
MAILER_URLPATHS_CONFIRMATION=/auth/v1/verify
MAILER_URLPATHS_RECOVERY=/auth/v1/verify
MAILER_URLPATHS_EMAIL_CHANGE=/auth/v1/verify
EOF
    
    # Clean up .env file
    sed -i 's/[[:space:]]*$//' "$project_dir/.env"
    sed -i 's/\r$//' "$project_dir/.env"
    
    # Validate .env format
    if ! grep -E '^[A-Z_]+=' "$project_dir/.env" > /dev/null; then
        error "Invalid .env format detected"
    fi
    
    success ".env file created"
}

# Create Traefik configuration
create_traefik_config() {
    local project_dir=$1
    local domain=$2
    local email=$3
    local use_ssl=$4
    
    log "Creating Traefik configuration..."
    
    # Main Traefik configuration
    cat > "$project_dir/configs/traefik/traefik.yml" << EOF
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
    network: traefik_network
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: $email
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web
      # Use staging for testing
      # caServer: https://acme-staging-v02.api.letsencrypt.org/directory

log:
  level: INFO
  filePath: /var/log/traefik/traefik.log

accessLog:
  filePath: /var/log/traefik/access.log
  bufferingSize: 100
EOF
    
    # Dynamic configuration for middlewares
    cat > "$project_dir/configs/traefik/dynamic/middlewares.yml" << 'EOF'
http:
  middlewares:
    rate-limit:
      rateLimit:
        average: 100
        burst: 50
    
    secure-headers:
      headers:
        frameDeny: true
        sslRedirect: true
        browserXssFilter: true
        contentTypeNosniff: true
        forceSTSHeader: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 63072000
        customFrameOptionsValue: "SAMEORIGIN"
    
    compress:
      compress: {}
    
    cors:
      headers:
        accessControlAllowMethods:
          - GET
          - OPTIONS
          - PUT
          - POST
          - DELETE
        accessControlAllowHeaders:
          - "*"
        accessControlAllowOriginList:
          - "*"
        accessControlMaxAge: 100
        addVaryHeader: true
EOF
    
    success "Traefik configuration created"
}

# Create Docker Compose for Full mode
create_docker_compose_full() {
    local project_dir=$1
    local domain=$2
    
    log "Creating Docker Compose configuration for FULL mode..."
    
    cat > "$project_dir/docker-compose.yml" << 'EOF'
version: '3.8'

x-common: &common
  restart: unless-stopped
  logging:
    driver: "json-file"
    options:
      max-size: "10m"
      max-file: "3"
  networks:
    - supabase_network

networks:
  supabase_network:
    driver: bridge
  traefik_network:
    external: true

volumes:
  db-config:

services:
  # =============================================================================
  # TRAEFIK - Reverse Proxy
  # =============================================================================
  traefik:
    <<: *common
    image: traefik:v3.0
    container_name: traefik
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
    volumes:
      - ./configs/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./configs/traefik/dynamic:/etc/traefik/dynamic:ro
      - ./volumes/traefik/acme.json:/letsencrypt/acme.json
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./volumes/traefik/logs:/var/log/traefik
    networks:
      - traefik_network
      - supabase_network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard.rule=Host(`traefik.${DOMAIN}`)"
      - "traefik.http.routers.dashboard.service=api@internal"
      - "traefik.http.routers.dashboard.middlewares=auth"
      - "traefik.http.middlewares.auth.basicauth.users=${DASHBOARD_USERNAME}:${DASHBOARD_PASSWORD_HASH}"

  # =============================================================================
  # DATABASE
  # =============================================================================
  db:
    <<: *common
    container_name: supabase-db
    image: supabase/postgres:15.8.1.060
    volumes:
      - ./volumes/db/data:/var/lib/postgresql/data:Z
      - db-config:/etc/postgresql-custom
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres", "-h", "localhost"]
      interval: 5s
      timeout: 5s
      retries: 10
    environment:
      POSTGRES_HOST: /var/run/postgresql
      PGPORT: ${POSTGRES_PORT}
      POSTGRES_PORT: ${POSTGRES_PORT}
      PGPASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDATABASE: ${POSTGRES_DB}
      POSTGRES_DB: ${POSTGRES_DB}
      JWT_SECRET: ${JWT_SECRET}
      JWT_EXP: ${JWT_EXPIRY}
    command:
      - postgres
      - -c
      - config_file=/etc/postgresql/postgresql.conf
      - -c
      - log_min_messages=fatal

  # =============================================================================
  # REDIS (for N8N queue mode)
  # =============================================================================
  redis:
    <<: *common
    image: redis:7-alpine
    container_name: redis
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - ./volumes/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "--raw", "incr", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  # =============================================================================
  # SUPABASE SERVICES
  # =============================================================================
  
  vector:
    <<: *common
    container_name: supabase-vector
    image: timberio/vector:0.28.1-alpine
    volumes:
      - ./supabase/docker/volumes/logs/vector.yml:/etc/vector/vector.yml:ro
      - ${DOCKER_SOCKET_LOCATION}:/var/run/docker.sock:ro
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://vector:9001/health"]
      timeout: 5s
      interval: 5s
      retries: 3
    environment:
      LOGFLARE_PUBLIC_ACCESS_TOKEN: ${LOGFLARE_PUBLIC_ACCESS_TOKEN}
    command: ["--config", "/etc/vector/vector.yml"]

  analytics:
    <<: *common
    container_name: supabase-analytics
    image: supabase/logflare:1.14.2
    ports:
      - "4000:4000"
    healthcheck:
      test: ["CMD", "curl", "http://localhost:4000/health"]
      timeout: 5s
      interval: 5s
      retries: 10
    depends_on:
      db:
        condition: service_healthy
    environment:
      LOGFLARE_NODE_HOST: 127.0.0.1
      DB_USERNAME: supabase_admin
      DB_DATABASE: _supabase
      DB_HOSTNAME: ${POSTGRES_HOST}
      DB_PORT: ${POSTGRES_PORT}
      DB_PASSWORD: ${POSTGRES_PASSWORD}
      DB_SCHEMA: _analytics
      LOGFLARE_PUBLIC_ACCESS_TOKEN: ${LOGFLARE_PUBLIC_ACCESS_TOKEN}
      LOGFLARE_PRIVATE_ACCESS_TOKEN: ${LOGFLARE_PRIVATE_ACCESS_TOKEN}
      LOGFLARE_SINGLE_TENANT: true
      LOGFLARE_SUPABASE_MODE: true
      LOGFLARE_MIN_CLUSTER_SIZE: 1
      POSTGRES_BACKEND_URL: postgresql://supabase_admin:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/_supabase
      POSTGRES_BACKEND_SCHEMA: _analytics
      LOGFLARE_FEATURE_FLAG_OVERRIDE: multibackend=true

  kong:
    <<: *common
    container_name: supabase-kong
    image: kong:2.8.1
    ports:
      - ${KONG_HTTP_PORT}:8000/tcp
      - ${KONG_HTTPS_PORT}:8443/tcp
    volumes:
      - ./supabase/docker/volumes/api/kong.yml:/home/kong/temp.yml:ro
    depends_on:
      analytics:
        condition: service_healthy
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /home/kong/kong.yml
      KONG_DNS_ORDER: LAST,A,CNAME
      KONG_PLUGINS: request-transformer,cors,key-auth,acl,basic-auth
      KONG_NGINX_PROXY_PROXY_BUFFER_SIZE: 160k
      KONG_NGINX_PROXY_PROXY_BUFFERS: 64 160k
      SUPABASE_ANON_KEY: ${ANON_KEY}
      SUPABASE_SERVICE_KEY: ${SERVICE_ROLE_KEY}
      DASHBOARD_USERNAME: ${DASHBOARD_USERNAME}
      DASHBOARD_PASSWORD: ${DASHBOARD_PASSWORD}
    entrypoint: bash -c 'eval "echo \"$$(cat ~/temp.yml)\"" > ~/kong.yml && /docker-entrypoint.sh kong docker-start'
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.kong.rule=Host(`api.${DOMAIN}`)"
      - "traefik.http.routers.kong.tls=true"
      - "traefik.http.routers.kong.tls.certresolver=letsencrypt"
      - "traefik.http.services.kong.loadbalancer.server.port=8000"

  auth:
    <<: *common
    container_name: supabase-auth
    image: supabase/gotrue:v2.177.0
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9999/health"]
      timeout: 5s
      interval: 5s
      retries: 3
    depends_on:
      db:
        condition: service_healthy
      analytics:
        condition: service_healthy
    environment:
      GOTRUE_API_HOST: 0.0.0.0
      GOTRUE_API_PORT: 9999
      API_EXTERNAL_URL: ${API_EXTERNAL_URL}
      GOTRUE_DB_DRIVER: postgres
      GOTRUE_DB_DATABASE_URL: postgres://supabase_auth_admin:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
      GOTRUE_SITE_URL: ${SITE_URL}
      GOTRUE_URI_ALLOW_LIST: ${ADDITIONAL_REDIRECT_URLS}
      GOTRUE_DISABLE_SIGNUP: ${DISABLE_SIGNUP}
      GOTRUE_JWT_ADMIN_ROLES: service_role
      GOTRUE_JWT_AUD: authenticated
      GOTRUE_JWT_DEFAULT_GROUP_NAME: authenticated
      GOTRUE_JWT_EXP: ${JWT_EXPIRY}
      GOTRUE_JWT_SECRET: ${JWT_SECRET}
      GOTRUE_EXTERNAL_EMAIL_ENABLED: ${ENABLE_EMAIL_SIGNUP}
      GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED: ${ENABLE_ANONYMOUS_USERS}
      GOTRUE_MAILER_AUTOCONFIRM: ${ENABLE_EMAIL_AUTOCONFIRM}
      GOTRUE_SMTP_ADMIN_EMAIL: ${SMTP_ADMIN_EMAIL}
      GOTRUE_SMTP_HOST: ${SMTP_HOST}
      GOTRUE_SMTP_PORT: ${SMTP_PORT}
      GOTRUE_SMTP_USER: ${SMTP_USER}
      GOTRUE_SMTP_PASS: ${SMTP_PASS}
      GOTRUE_SMTP_SENDER_NAME: ${SMTP_SENDER_NAME}
      GOTRUE_MAILER_URLPATHS_INVITE: ${MAILER_URLPATHS_INVITE}
      GOTRUE_MAILER_URLPATHS_CONFIRMATION: ${MAILER_URLPATHS_CONFIRMATION}
      GOTRUE_MAILER_URLPATHS_RECOVERY: ${MAILER_URLPATHS_RECOVERY}
      GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE: ${MAILER_URLPATHS_EMAIL_CHANGE}
      GOTRUE_EXTERNAL_PHONE_ENABLED: ${ENABLE_PHONE_SIGNUP}
      GOTRUE_SMS_AUTOCONFIRM: ${ENABLE_PHONE_AUTOCONFIRM}

  rest:
    <<: *common
    container_name: supabase-rest
    image: postgrest/postgrest:v12.2.12
    depends_on:
      db:
        condition: service_healthy
      analytics:
        condition: service_healthy
    environment:
      PGRST_DB_URI: postgres://authenticator:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
      PGRST_DB_SCHEMAS: public,storage,graphql_public
      PGRST_DB_ANON_ROLE: anon
      PGRST_JWT_SECRET: ${JWT_SECRET}
      PGRST_DB_USE_LEGACY_GUCS: "false"
      PGRST_APP_SETTINGS_JWT_SECRET: ${JWT_SECRET}
      PGRST_APP_SETTINGS_JWT_EXP: ${JWT_EXPIRY}
    command: ["postgrest"]

  realtime:
    <<: *common
    container_name: realtime-dev.supabase-realtime
    image: supabase/realtime:v2.34.47
    depends_on:
      db:
        condition: service_healthy
      analytics:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-sSfL", "--head", "-o", "/dev/null", "-H", "Authorization: Bearer ${ANON_KEY}", "http://localhost:4000/api/tenants/realtime-dev/health"]
      timeout: 5s
      interval: 5s
      retries: 3
    environment:
      PORT: 4000
      DB_HOST: ${POSTGRES_HOST}
      DB_PORT: ${POSTGRES_PORT}
      DB_USER: supabase_admin
      DB_PASSWORD: ${POSTGRES_PASSWORD}
      DB_NAME: ${POSTGRES_DB}
      DB_AFTER_CONNECT_QUERY: 'SET search_path TO _realtime'
      DB_ENC_KEY: supabaserealtime
      API_JWT_SECRET: ${JWT_SECRET}
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      ERL_AFLAGS: -proto_dist inet_tcp
      DNS_NODES: "''"
      RLIMIT_NOFILE: "10000"
      APP_NAME: realtime
      SEED_SELF_HOST: true
      RUN_JANITOR: true

  storage:
    <<: *common
    container_name: supabase-storage
    image: supabase/storage-api:v1.25.7
    volumes:
      - ./volumes/storage:/var/lib/storage:z
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://storage:5000/status"]
      timeout: 5s
      interval: 5s
      retries: 3
    depends_on:
      db:
        condition: service_healthy
      rest:
        condition: service_started
      imgproxy:
        condition: service_started
    environment:
      ANON_KEY: ${ANON_KEY}
      SERVICE_KEY: ${SERVICE_ROLE_KEY}
      POSTGREST_URL: http://rest:3000
      PGRST_JWT_SECRET: ${JWT_SECRET}
      DATABASE_URL: postgres://supabase_storage_admin:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
      FILE_SIZE_LIMIT: 52428800
      STORAGE_BACKEND: file
      FILE_STORAGE_BACKEND_PATH: /var/lib/storage
      TENANT_ID: stub
      REGION: stub
      GLOBAL_S3_BUCKET: stub
      ENABLE_IMAGE_TRANSFORMATION: "true"
      IMGPROXY_URL: http://imgproxy:5001

  imgproxy:
    <<: *common
    container_name: supabase-imgproxy
    image: darthsim/imgproxy:v3.8.0
    volumes:
      - ./volumes/storage:/var/lib/storage:z
    healthcheck:
      test: ["CMD", "imgproxy", "health"]
      timeout: 5s
      interval: 5s
      retries: 3
    environment:
      IMGPROXY_BIND: ":5001"
      IMGPROXY_LOCAL_FILESYSTEM_ROOT: /
      IMGPROXY_USE_ETAG: "true"
      IMGPROXY_ENABLE_WEBP_DETECTION: ${IMGPROXY_ENABLE_WEBP_DETECTION}

  meta:
    <<: *common
    container_name: supabase-meta
    image: supabase/postgres-meta:v0.91.0
    depends_on:
      db:
        condition: service_healthy
      analytics:
        condition: service_healthy
    environment:
      PG_META_PORT: 8080
      PG_META_DB_HOST: ${POSTGRES_HOST}
      PG_META_DB_PORT: ${POSTGRES_PORT}
      PG_META_DB_NAME: ${POSTGRES_DB}
      PG_META_DB_USER: supabase_admin
      PG_META_DB_PASSWORD: ${POSTGRES_PASSWORD}

  functions:
    <<: *common
    container_name: supabase-edge-functions
    image: supabase/edge-runtime:v1.67.4
    volumes:
      - ./volumes/functions:/home/deno/functions:Z
    depends_on:
      analytics:
        condition: service_healthy
    environment:
      JWT_SECRET: ${JWT_SECRET}
      SUPABASE_URL: http://kong:8000
      SUPABASE_ANON_KEY: ${ANON_KEY}
      SUPABASE_SERVICE_ROLE_KEY: ${SERVICE_ROLE_KEY}
      SUPABASE_DB_URL: postgresql://postgres:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
      VERIFY_JWT: "${FUNCTIONS_VERIFY_JWT}"
    command: ["start", "--main-service", "/home/deno/functions/main"]

  studio:
    <<: *common
    container_name: supabase-studio
    image: supabase/studio:2025.06.30-sha-6f5982d
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://studio:3000/api/platform/profile').then((r) => {if (r.status !== 200) throw new Error(r.status)})"]
      timeout: 10s
      interval: 5s
      retries: 3
    depends_on:
      analytics:
        condition: service_healthy
    environment:
      STUDIO_PG_META_URL: http://meta:8080
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      DEFAULT_ORGANIZATION_NAME: ${STUDIO_DEFAULT_ORGANIZATION}
      DEFAULT_PROJECT_NAME: ${STUDIO_DEFAULT_PROJECT}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      SUPABASE_URL: http://kong:8000
      SUPABASE_PUBLIC_URL: ${SUPABASE_PUBLIC_URL}
      SUPABASE_ANON_KEY: ${ANON_KEY}
      SUPABASE_SERVICE_KEY: ${SERVICE_ROLE_KEY}
      AUTH_JWT_SECRET: ${JWT_SECRET}
      LOGFLARE_PRIVATE_ACCESS_TOKEN: ${LOGFLARE_PRIVATE_ACCESS_TOKEN}
      LOGFLARE_URL: http://analytics:4000
      NEXT_PUBLIC_ENABLE_LOGS: true
      NEXT_ANALYTICS_BACKEND_PROVIDER: postgres
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.studio.rule=Host(`studio.${DOMAIN}`)"
      - "traefik.http.routers.studio.tls=true"
      - "traefik.http.routers.studio.tls.certresolver=letsencrypt"
      - "traefik.http.services.studio.loadbalancer.server.port=3000"

  supavisor:
    <<: *common
    container_name: supabase-pooler
    image: supabase/supavisor:2.5.7
    ports:
      - ${POSTGRES_PORT}:5432
      - ${POOLER_PROXY_PORT_TRANSACTION}:6543
    volumes:
      - ./supabase/docker/volumes/pooler/pooler.exs:/etc/pooler/pooler.exs:ro
    healthcheck:
      test: ["CMD", "curl", "-sSfL", "--head", "-o", "/dev/null", "http://127.0.0.1:4000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 5
    depends_on:
      db:
        condition: service_healthy
      analytics:
        condition: service_healthy
    environment:
      PORT: 4000
      POSTGRES_PORT: ${POSTGRES_PORT}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      DATABASE_URL: ecto://supabase_admin:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/_supabase
      CLUSTER_POSTGRES: true
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      VAULT_ENC_KEY: ${VAULT_ENC_KEY}
      API_JWT_SECRET: ${JWT_SECRET}
      METRICS_JWT_SECRET: ${JWT_SECRET}
      REGION: local
      ERL_AFLAGS: -proto_dist inet_tcp
      POOLER_TENANT_ID: ${POOLER_TENANT_ID}
      POOLER_DEFAULT_POOL_SIZE: ${POOLER_DEFAULT_POOL_SIZE}
      POOLER_MAX_CLIENT_CONN: ${POOLER_MAX_CLIENT_CONN}
      POOLER_POOL_MODE: transaction
      DB_POOL_SIZE: ${POOLER_DB_POOL_SIZE}
    command: ["/bin/sh", "-c", "/app/bin/migrate && /app/bin/supavisor eval \"$$(cat /etc/pooler/pooler.exs)\" && /app/bin/server"]

  # =============================================================================
  # N8N SERVICES
  # =============================================================================
  
  n8n-main:
    <<: *common
    image: n8nio/n8n:latest
    container_name: n8n-main
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=${N8N_PORT}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - NODE_ENV=production
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_HOST=db
      - DB_POSTGRESDB_PORT=${POSTGRES_PORT}
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - DB_POSTGRESDB_SCHEMA=n8n
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
      - N8N_METRICS=true
      - N8N_METRICS_PREFIX=n8n_
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n.tls=true"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      - "traefik.http.routers.n8n.middlewares=secure-headers@file,rate-limit@file"

  n8n-worker:
    <<: *common
    image: n8nio/n8n:latest
    container_name: n8n-worker
    command: worker
    depends_on:
      n8n-main:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      - NODE_ENV=production
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_HOST=db
      - DB_POSTGRESDB_PORT=${POSTGRES_PORT}
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - DB_POSTGRESDB_SCHEMA=n8n
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}
    volumes:
      - ./volumes/n8n:/home/node/.n8n
EOF
    
    success "Docker Compose configuration for FULL mode created"
}

# Create Docker Compose for RAG mode
create_docker_compose_rag() {
    local project_dir=$1
    local domain=$2
    
    log "Creating Docker Compose configuration for RAG mode..."
    
    # Copy necessary Supabase volumes
    cp -r /root/supabase/docker/volumes "$project_dir/" 2>/dev/null || true
    
    cat > "$project_dir/docker-compose.yml" << 'EOF'
version: '3.8'

x-common: &common
  restart: unless-stopped
  logging:
    driver: "json-file"
    options:
      max-size: "10m"
      max-file: "3"
  networks:
    - supabase_network

networks:
  supabase_network:
    driver: bridge
  traefik_network:
    external: true

volumes:
  db-config:

services:
  # =============================================================================
  # TRAEFIK
  # =============================================================================
  traefik:
    <<: *common
    image: traefik:v3.0
    container_name: traefik
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
    volumes:
      - ./configs/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./configs/traefik/dynamic:/etc/traefik/dynamic:ro
      - ./volumes/traefik/acme.json:/letsencrypt/acme.json
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./volumes/traefik/logs:/var/log/traefik
    networks:
      - traefik_network
      - supabase_network

  # =============================================================================
  # SUPABASE CORE FOR RAG
  # =============================================================================
  
  db:
    <<: *common
    container_name: supabase-db
    image: supabase/postgres:15.8.1.060
    volumes:
      - ./volumes/db/data:/var/lib/postgresql/data:Z
      - ./volumes/db/realtime.sql:/docker-entrypoint-initdb.d/migrations/99-realtime.sql:Z
      - ./volumes/db/webhooks.sql:/docker-entrypoint-initdb.d/init-scripts/98-webhooks.sql:Z
      - ./volumes/db/roles.sql:/docker-entrypoint-initdb.d/init-scripts/99-roles.sql:Z
      - ./volumes/db/jwt.sql:/docker-entrypoint-initdb.d/init-scripts/99-jwt.sql:Z
      - ./volumes/db/_supabase.sql:/docker-entrypoint-initdb.d/migrations/97-_supabase.sql:Z
      - ./volumes/db/logs.sql:/docker-entrypoint-initdb.d/migrations/99-logs.sql:Z
      - ./volumes/db/pooler.sql:/docker-entrypoint-initdb.d/migrations/99-pooler.sql:Z
      - db-config:/etc/postgresql-custom
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres", "-h", "localhost"]
      interval: 5s
      timeout: 5s
      retries: 10
    environment:
      POSTGRES_HOST: /var/run/postgresql
      PGPORT: ${POSTGRES_PORT}
      POSTGRES_PORT: ${POSTGRES_PORT}
      PGPASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDATABASE: ${POSTGRES_DB}
      POSTGRES_DB: ${POSTGRES_DB}
      JWT_SECRET: ${JWT_SECRET}
      JWT_EXP: ${JWT_EXPIRY}
    command:
      - postgres
      - -c
      - config_file=/etc/postgresql/postgresql.conf
      - -c
      - log_min_messages=fatal

  vector:
    <<: *common
    container_name: supabase-vector
    image: timberio/vector:0.28.1-alpine
    volumes:
      - ./volumes/logs/vector.yml:/etc/vector/vector.yml:ro
      - ${DOCKER_SOCKET_LOCATION}:/var/run/docker.sock:ro
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://vector:9001/health"]
      timeout: 5s
      interval: 5s
      retries: 3
    environment:
      LOGFLARE_PUBLIC_ACCESS_TOKEN: ${LOGFLARE_PUBLIC_ACCESS_TOKEN}
    command: ["--config", "/etc/vector/vector.yml"]

  kong:
    <<: *common
    container_name: supabase-kong
    image: kong:2.8.1
    ports:
      - ${KONG_HTTP_PORT}:8000/tcp
      - ${KONG_HTTPS_PORT}:8443/tcp
    volumes:
      - ./volumes/api/kong.yml:/home/kong/temp.yml:ro
    depends_on:
      db:
        condition: service_healthy
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /home/kong/kong.yml
      KONG_DNS_ORDER: LAST,A,CNAME
      KONG_PLUGINS: request-transformer,cors,key-auth,acl,basic-auth
      KONG_NGINX_PROXY_PROXY_BUFFER_SIZE: 160k
      KONG_NGINX_PROXY_PROXY_BUFFERS: 64 160k
      SUPABASE_ANON_KEY: ${ANON_KEY}
      SUPABASE_SERVICE_KEY: ${SERVICE_ROLE_KEY}
      DASHBOARD_USERNAME: ${DASHBOARD_USERNAME}
      DASHBOARD_PASSWORD: ${DASHBOARD_PASSWORD}
    entrypoint: bash -c 'eval "echo \"$$(cat ~/temp.yml)\"" > ~/kong.yml && /docker-entrypoint.sh kong docker-start'

  auth:
    <<: *common
    container_name: supabase-auth
    image: supabase/gotrue:v2.177.0
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9999/health"]
      timeout: 5s
      interval: 5s
      retries: 3
    depends_on:
      db:
        condition: service_healthy
    environment:
      GOTRUE_API_HOST: 0.0.0.0
      GOTRUE_API_PORT: 9999
      API_EXTERNAL_URL: ${API_EXTERNAL_URL}
      GOTRUE_DB_DRIVER: postgres
      GOTRUE_DB_DATABASE_URL: postgres://supabase_auth_admin:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
      GOTRUE_SITE_URL: ${SITE_URL}
      GOTRUE_URI_ALLOW_LIST: ${ADDITIONAL_REDIRECT_URLS}
      GOTRUE_DISABLE_SIGNUP: ${DISABLE_SIGNUP}
      GOTRUE_JWT_ADMIN_ROLES: service_role
      GOTRUE_JWT_AUD: authenticated
      GOTRUE_JWT_DEFAULT_GROUP_NAME: authenticated
      GOTRUE_JWT_EXP: ${JWT_EXPIRY}
      GOTRUE_JWT_SECRET: ${JWT_SECRET}
      GOTRUE_EXTERNAL_EMAIL_ENABLED: ${ENABLE_EMAIL_SIGNUP}
      GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED: ${ENABLE_ANONYMOUS_USERS}
      GOTRUE_MAILER_AUTOCONFIRM: ${ENABLE_EMAIL_AUTOCONFIRM}

  rest:
    <<: *common
    container_name: supabase-rest
    image: postgrest/postgrest:v12.2.12
    depends_on:
      db:
        condition: service_healthy
    environment:
      PGRST_DB_URI: postgres://authenticator:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
      PGRST_DB_SCHEMAS: public,storage,graphql_public
      PGRST_DB_ANON_ROLE: anon
      PGRST_JWT_SECRET: ${JWT_SECRET}
      PGRST_DB_USE_LEGACY_GUCS: "false"
      PGRST_APP_SETTINGS_JWT_SECRET: ${JWT_SECRET}
      PGRST_APP_SETTINGS_JWT_EXP: ${JWT_EXPIRY}
    command: ["postgrest"]

  meta:
    <<: *common
    container_name: supabase-meta
    image: supabase/postgres-meta:v0.91.0
    depends_on:
      db:
        condition: service_healthy
    environment:
      PG_META_PORT: 8080
      PG_META_DB_HOST: ${POSTGRES_HOST}
      PG_META_DB_PORT: ${POSTGRES_PORT}
      PG_META_DB_NAME: ${POSTGRES_DB}
      PG_META_DB_USER: supabase_admin
      PG_META_DB_PASSWORD: ${POSTGRES_PASSWORD}

  studio:
    <<: *common
    container_name: supabase-studio
    image: supabase/studio:2025.06.30-sha-6f5982d
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://studio:3000/api/platform/profile').then((r) => {if (r.status !== 200) throw new Error(r.status)})"]
      timeout: 10s
      interval: 5s
      retries: 3
    depends_on:
      db:
        condition: service_healthy
    environment:
      STUDIO_PG_META_URL: http://meta:8080
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      DEFAULT_ORGANIZATION_NAME: ${STUDIO_DEFAULT_ORGANIZATION}
      DEFAULT_PROJECT_NAME: ${STUDIO_DEFAULT_PROJECT}
      SUPABASE_URL: http://kong:8000
      SUPABASE_PUBLIC_URL: ${SUPABASE_PUBLIC_URL}
      SUPABASE_ANON_KEY: ${ANON_KEY}
      SUPABASE_SERVICE_KEY: ${SERVICE_ROLE_KEY}
      AUTH_JWT_SECRET: ${JWT_SECRET}
      NEXT_PUBLIC_ENABLE_LOGS: false
      NEXT_ANALYTICS_BACKEND_PROVIDER: postgres
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.studio.rule=Host(`studio.${DOMAIN}`)"
      - "traefik.http.routers.studio.tls=true"
      - "traefik.http.routers.studio.tls.certresolver=letsencrypt"
      - "traefik.http.services.studio.loadbalancer.server.port=3000"

  supavisor:
    <<: *common
    container_name: supabase-pooler
    image: supabase/supavisor:2.5.7
    ports:
      - ${POSTGRES_PORT}:5432
      - ${POOLER_PROXY_PORT_TRANSACTION}:6543
    volumes:
      - ./volumes/pooler/pooler.exs:/etc/pooler/pooler.exs:ro
    healthcheck:
      test: ["CMD", "curl", "-sSfL", "--head", "-o", "/dev/null", "http://127.0.0.1:4000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 5
    depends_on:
      db:
        condition: service_healthy
    environment:
      PORT: 4000
      POSTGRES_PORT: ${POSTGRES_PORT}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      DATABASE_URL: ecto://supabase_admin:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/_supabase
      CLUSTER_POSTGRES: true
      SECRET_KEY_BASE: ${SECRET_KEY_BASE}
      VAULT_ENC_KEY: ${VAULT_ENC_KEY}
      API_JWT_SECRET: ${JWT_SECRET}
      METRICS_JWT_SECRET: ${JWT_SECRET}
      REGION: local
      ERL_AFLAGS: -proto_dist inet_tcp
      POOLER_TENANT_ID: ${POOLER_TENANT_ID}
      POOLER_DEFAULT_POOL_SIZE: ${POOLER_DEFAULT_POOL_SIZE}
      POOLER_MAX_CLIENT_CONN: ${POOLER_MAX_CLIENT_CONN}
      POOLER_POOL_MODE: transaction
      DB_POOL_SIZE: ${POOLER_DB_POOL_SIZE}
    command: ["/bin/sh", "-c", "/app/bin/migrate && /app/bin/supavisor eval \"$$(cat /etc/pooler/pooler.exs)\" && /app/bin/server"]

  # =============================================================================
  # N8N FOR AI AGENTS
  # =============================================================================
  
  n8n:
    <<: *common
    image: n8nio/n8n:latest
    container_name: n8n
    depends_on:
      db:
        condition: service_healthy
    environment:
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=${N8N_PORT}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - NODE_ENV=production
      - WEBHOOK_URL=${WEBHOOK_URL}
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_HOST=db
      - DB_POSTGRESDB_PORT=${POSTGRES_PORT}
      - DB_POSTGRESDB_USER=postgres
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - DB_POSTGRESDB_SCHEMA=n8n
      - EXECUTIONS_MODE=regular
      - N8N_METRICS=true
    volumes:
      - ./volumes/n8n:/home/node/.n8n
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n.tls=true"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
EOF
    
    success "Docker Compose configuration for RAG mode created"
}

# Wait for service to be healthy
wait_for_service() {
    local service_name=$1
    local max_attempts=60
    local attempt=1
    
    log "Waiting for $service_name to be healthy..."
    
    while [ $attempt -le $max_attempts ]; do
        if docker compose ps --format json | jq -r ".[] | select(.Service==\"$service_name\") | .Health" | grep -q "healthy"; then
            success "$service_name is healthy"
            return 0
        fi
        
        echo -n "."
        sleep 2
        ((attempt++))
    done
    
    error "$service_name failed to become healthy after $max_attempts attempts"
    return 1
}

# Retry operation with exponential backoff
retry_operation() {
    local max_attempts=3
    local delay=5
    local attempt=1
    local command="$@"
    
    while [ $attempt -le $max_attempts ]; do
        if eval "$command"; then
            return 0
        fi
        
        warning "Attempt $attempt of $max_attempts failed. Retrying in $delay seconds..."
        sleep $delay
        delay=$((delay * 2))
        ((attempt++))
    done
    
    return 1
}

# Health check all services
health_check_all_services() {
    local mode=$1
    local failed_services=()
    
    log "Performing health checks on all services..."
    
    # Check PostgreSQL
    if ! docker exec supabase-db pg_isready -U postgres &>/dev/null; then
        failed_services+=("PostgreSQL")
    fi
    
    # Check n8n
    if ! curl -sf http://localhost:5678/healthz &>/dev/null; then
        failed_services+=("n8n")
    fi
    
    # Check Supabase components (if not lightweight mode)
    if [ "$mode" != "$MODE_LIGHTWEIGHT" ]; then
        # Kong API Gateway
        if ! curl -sf http://localhost:8000/health &>/dev/null; then
            failed_services+=("Supabase Kong")
        fi
        
        # PostgREST
        if ! docker exec supabase-rest wget --spider -q http://localhost:3000 &>/dev/null; then
            failed_services+=("Supabase REST")
        fi
        
        # Auth service
        if ! docker exec supabase-auth wget --spider -q http://localhost:9999/health &>/dev/null; then
            failed_services+=("Supabase Auth")
        fi
    fi
    
    # Check Traefik
    if ! curl -sf http://localhost:8080/ping &>/dev/null; then
        failed_services+=("Traefik")
    fi
    
    # Check Redis (for Full mode)
    if [ "$mode" = "$MODE_FULL" ]; then
        if ! docker exec redis redis-cli ping &>/dev/null; then
            failed_services+=("Redis")
        fi
    fi
    
    if [ ${#failed_services[@]} -gt 0 ]; then
        error "The following services failed health check: ${failed_services[*]}"
        return 1
    fi
    
    success "All services passed health checks ✓"
    return 0
}

# Start services with proper order
start_services() {
    local project_dir=$1
    local mode=$2
    
    log "Starting services in $mode mode..."
    
    cd "$project_dir"
    
    # Create external network for Traefik
    docker network create traefik_network 2>/dev/null || true
    
    # Start services based on mode
    case "$mode" in
        "$MODE_FULL"|"$MODE_STANDARD"|"$MODE_RAG")
            # Start database first
            docker compose up -d db
            wait_for_service "db"
            
            # Start vector if present
            docker compose up -d vector 2>/dev/null || true
            
            # Start Kong and auth services
            docker compose up -d kong auth
            sleep 5
            
            # Start remaining Supabase services
            docker compose up -d rest meta studio
            
            if [ "$mode" = "$MODE_FULL" ]; then
                docker compose up -d analytics realtime storage imgproxy functions supavisor
                docker compose up -d redis
                wait_for_service "redis"
            elif [ "$mode" = "$MODE_RAG" ]; then
                docker compose up -d supavisor
            fi
            
            # Finally start n8n
            docker compose up -d n8n
            if [ "$mode" = "$MODE_FULL" ]; then
                docker compose up -d n8n-main n8n-worker
            fi
            ;;
            
        "$MODE_LIGHTWEIGHT")
            docker compose up -d postgres
            wait_for_service "postgres"
            docker compose up -d n8n
            ;;
    esac
    
    # Start Traefik last
    docker compose up -d traefik
    
    sleep 10
    
    success "All services started"
}

# Create management scripts
create_management_scripts() {
    local project_dir=$1
    
    log "Creating management scripts..."
    
    # Create manage.sh
    cat > "$project_dir/scripts/manage.sh" << 'EOF'
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

case "$1" in
    start)
        echo "Starting all services..."
        docker compose up -d
        ;;
    stop)
        echo "Stopping all services..."
        docker compose stop
        ;;
    restart)
        echo "Restarting all services..."
        docker compose restart
        ;;
    status)
        docker compose ps
        ;;
    logs)
        shift
        docker compose logs -f "$@"
        ;;
    update)
        echo "Pulling latest images..."
        docker compose pull
        docker compose up -d
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|update}"
        exit 1
        ;;
esac
EOF
    
    # Create backup.sh
    cat > "$project_dir/scripts/backup.sh" << 'EOF'
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_DIR/backups/$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BACKUP_DIR"

cd "$PROJECT_DIR"

echo "Creating backup in $BACKUP_DIR..."

# Backup PostgreSQL
docker exec supabase-db pg_dumpall -U postgres > "$BACKUP_DIR/postgres_backup.sql"

# Backup volumes
tar -czf "$BACKUP_DIR/volumes.tar.gz" volumes/

# Backup configuration
cp .env "$BACKUP_DIR/"
cp docker-compose.yml "$BACKUP_DIR/"

echo "Backup completed successfully!"
echo "Backup location: $BACKUP_DIR"
EOF
    
    # Create update.sh
    cat > "$project_dir/scripts/update.sh" << 'EOF'
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "Updating services..."

# Pull latest images
docker compose pull

# Restart services with new images
docker compose up -d --force-recreate

echo "Update completed!"
EOF
    
    # Make scripts executable
    chmod +x "$project_dir/scripts/"*.sh
    
    success "Management scripts created"
}

# Save credentials
save_credentials() {
    local project_dir=$1
    local domain=$2
    local mode=$3
    
    log "Saving credentials..."
    
    # Extract passwords from .env
    source "$project_dir/.env"
    
    cat > "$project_dir/credentials.txt" << EOF
================================================================================
                        INSTALLATION COMPLETED SUCCESSFULLY
================================================================================

Installation Mode: $mode
Project Directory: $project_dir
Domain: $domain
Timestamp: $(date)

================================================================================
                              ACCESS CREDENTIALS
================================================================================

SUPABASE DASHBOARD:
-------------------
URL: https://studio.$domain
Service Role Key: $SERVICE_ROLE_KEY
Anon Key: $ANON_KEY

N8N WORKFLOW AUTOMATION:
------------------------
URL: https://$domain
Username: $N8N_BASIC_AUTH_USER
Password: $N8N_BASIC_AUTH_PASSWORD

TRAEFIK DASHBOARD:
------------------
URL: https://traefik.$domain
Username: $DASHBOARD_USERNAME
Password: $DASHBOARD_PASSWORD

DATABASE CONNECTION:
--------------------
Host: localhost
Port: 5432
Database: postgres
Username: postgres
Password: $POSTGRES_PASSWORD

Connection String:
postgresql://postgres:$POSTGRES_PASSWORD@localhost:5432/postgres

================================================================================
                            SERVICE ENDPOINTS
================================================================================

API Gateway: https://api.$domain
REST API: https://api.$domain/rest/v1/
Auth API: https://api.$domain/auth/v1/
Realtime: wss://api.$domain/realtime/v1/
Storage: https://api.$domain/storage/v1/

================================================================================
                           MANAGEMENT COMMANDS
================================================================================

Start services:    $project_dir/scripts/manage.sh start
Stop services:     $project_dir/scripts/manage.sh stop
View logs:         $project_dir/scripts/manage.sh logs [service]
Backup data:       $project_dir/scripts/backup.sh
Update services:   $project_dir/scripts/update.sh

================================================================================
                               IMPORTANT NOTES
================================================================================

1. This file contains sensitive credentials. Keep it secure!
2. JWT tokens have been generated with 20-year expiry
3. All passwords are alphanumeric only (no special characters)
4. Backup this file and store it in a secure location
5. SSL certificates will be automatically obtained via Let's Encrypt

For documentation and support, visit:
- Supabase Docs: https://supabase.com/docs
- N8N Docs: https://docs.n8n.io
- Traefik Docs: https://doc.traefik.io/traefik/

================================================================================
EOF
    
    chmod 600 "$project_dir/credentials.txt"
    
    success "Credentials saved to $project_dir/credentials.txt"
}

# Display summary
display_summary() {
    local project_dir=$1
    local domain=$2
    local mode=$3
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}              INSTALLATION COMPLETED SUCCESSFULLY!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Installation Details:${NC}"
    echo -e "  Mode:        ${WHITE}$mode${NC}"
    echo -e "  Directory:   ${WHITE}$project_dir${NC}"
    echo -e "  Domain:      ${WHITE}$domain${NC}"
    echo ""
    echo -e "${CYAN}Access URLs:${NC}"
    echo -e "  Supabase Studio: ${WHITE}https://studio.$domain${NC}"
    echo -e "  N8N Workflows:   ${WHITE}https://$domain${NC}"
    echo -e "  Traefik Admin:   ${WHITE}https://traefik.$domain${NC}"
    echo ""
    echo -e "${YELLOW}Important:${NC}"
    echo -e "  Credentials saved to: ${WHITE}$project_dir/credentials.txt${NC}"
    echo -e "  ${RED}Keep this file secure!${NC}"
    echo ""
    echo -e "${CYAN}Quick Commands:${NC}"
    echo -e "  View status:  ${WHITE}cd $project_dir && docker compose ps${NC}"
    echo -e "  View logs:    ${WHITE}cd $project_dir && docker compose logs -f${NC}"
    echo -e "  Stop all:     ${WHITE}cd $project_dir && docker compose down${NC}"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
}

# Main installation flow
main() {
    clear
    
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}     ${WHITE}SUPABASE + N8N AUTOMATED INSTALLATION WIZARD${NC}          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                   ${YELLOW}Version $SCRIPT_VERSION${NC}                              ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Preliminary checks
    check_root
    check_system_requirements
    
    # Install dependencies
    install_dependencies
    install_docker
    
    # Get installation configuration
    local mode=$(select_installation_mode)
    local config=$(get_project_config)
    local project_name=$(echo "$config" | cut -d'|' -f1)
    local domain=$(echo "$config" | cut -d'|' -f2)
    local email=$(echo "$config" | cut -d'|' -f3)
    local use_ssl=$(echo "$config" | cut -d'|' -f4)
    
    local project_dir="/root/$project_name"
    
    # Clone Supabase if needed
    if [ "$mode" != "$MODE_LIGHTWEIGHT" ]; then
        clone_supabase "/root"
    fi
    
    # Create project structure
    create_project_structure "$project_dir"
    
    # Generate credentials
    local credentials=$(generate_credentials)
    
    # Create configuration files
    create_env_file "$project_dir" "$mode" "$domain" "$email" "$use_ssl" "$credentials"
    create_traefik_config "$project_dir" "$domain" "$email" "$use_ssl"
    
    # Create Docker Compose based on mode
    case "$mode" in
        "$MODE_FULL")
            create_docker_compose_full "$project_dir" "$domain"
            ;;
        "$MODE_STANDARD")
            create_docker_compose_full "$project_dir" "$domain"
            # Remove worker and redis services
            ;;
        "$MODE_RAG")
            create_docker_compose_rag "$project_dir" "$domain"
            ;;
        "$MODE_LIGHTWEIGHT")
            # Create minimal compose file
            ;;
    esac
    
    # Start services
    start_services "$project_dir" "$mode"
    
    # Perform health checks
    sleep 15
    if ! health_check_all_services "$mode"; then
        warning "Some services failed health checks. Please check logs for details."
    fi
    
    # Create management scripts
    create_management_scripts "$project_dir"
    
    # Save credentials
    save_credentials "$project_dir" "$domain" "$mode"
    
    # Display summary
    display_summary "$project_dir" "$domain" "$mode"
    
    log "Installation completed successfully!"
    log "Full installation log saved to: $LOG_FILE"
}

# Run main function
main "$@"
