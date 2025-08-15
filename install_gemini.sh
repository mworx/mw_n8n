#!/bin/bash

# ==============================================================================
# Скрипт для развертывания стека n8n + RAG (Qdrant) с Traefik
# © 2025 MEDIA WORKS. Все права защищены.
# Версия: 2.5.0
# Изменения:
# - Изменен формат переменных окружения в docker-compose.yml на 'ключ: значение'
#   для устранения синтаксической ошибки парсинга YAML.
# ==============================================================================

# -- Глобальные переменные и константы --
set -e
set -o pipefail
PROJECT_DIR="/opt/mediaworks-stack"

# -- Цвета --
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'

# -- Функции --

function display_banner() {
    echo -e "${C_CYAN}"
    echo "    __  ___      __           __  __           __      "
    echo "   /  |/  /___ _/ /_____     / / / /___  _____/ /_     "
    echo "  / /|_/ / __ \`/ __/ __ \   / /_/ / __ \/ ___/ __/     "
    echo " / /  / / /_/ / /_/ /_/ /  / __  / /_/ / /__/ /_       "
    echo "/_/  /_/\__,_/\__/\____/  /_/ /_/\____/\___/\__/       "
    echo "                                                       "
    echo "         AI-агенты и системная интеграция${C_RESET}"
    echo "Добро пожаловать в установщик стека n8n+RAG от MEDIA WORKS!"
    echo "------------------------------------------------------------------"
}

function spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p $pid > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf " \b\b\b\b\b"
}

function log_step() {
    echo -e "\n${C_BLUE}➡️  $1${C_RESET}"
}

function log_success() {
    echo -e "${C_GREEN}✅  $1${C_RESET}"
}

function log_warning() {
    echo -e "${C_YELLOW}⚠️  $1${C_RESET}"
}

function log_error() {
    echo -e "${C_RED}❌  $1${C_RESET}" >&2
    exit 1
}

# 1. Проверки
function initial_checks() {
    log_step "Запуск первоначальных проверок..."
    if [[ "$EUID" -ne 0 ]]; then log_error "Этот скрипт должен быть запущен с правами root."; fi
    if [ -f /etc/os-release ]; then . /etc/os-release; if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then log_error "Этот скрипт поддерживает только Debian и Ubuntu."; fi
    else log_error "Не удалось определить операционную систему."; fi
    for port in 80 443; do
        if ss -tuln | grep -q ":$port\s"; then
            log_warning "Порт $port занят. Попытка остановить конфликтующие сервисы..."; systemctl stop nginx 2>/dev/null || true; systemctl stop apache2 2>/dev/null || true; sleep 2
            if ss -tuln | grep -q ":$port\s"; then log_error "Порт $port все еще занят. Освободите порт."; else log_success "Порт $port успешно освобожден."; fi
        fi
    done
    log_success "Системные требования в норме."
}

# 2. Установка зависимостей
function install_dependencies() {
    log_step "Установка необходимых пакетов (включая apache2-utils)..."
    apt-get update -qq && apt-get install -y -qq curl git openssl jq net-tools ca-certificates gnupg dnsutils apache2-utils >/dev/null || log_error "Не удалось установить базовые зависимости."
    if ! command -v docker &> /dev/null; then
        log_step "Установка Docker..."; ( install -m 0755 -d /etc/apt/keyrings; curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc; chmod a+r /etc/apt/keyrings/docker.asc; echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null; apt-get update -qq; apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; ) >/dev/null 2>&1 &
        spinner $!; wait $! || log_error "Ошибка при установке Docker."
    fi
    if ! docker compose version &> /dev/null; then log_error "Docker Compose не установлен или не работает корректно."; fi
    log_success "Все зависимости установлены."
}

# 3. Сбор данных
function prompt_for_input() {
    log_step "Сбор необходимой информации..."
    while true; do read -p "Введите основной домен (например, example.com): " ROOT_DOMAIN; if [[ "$ROOT_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then break; else log_warning "Неверный формат домена."; fi; done
    while true; do read -p "Введите ваш email для SSL-сертификатов Let's Encrypt: " ACME_EMAIL; if [[ "$ACME_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then break; else log_warning "Неверный формат email."; fi; done
    read -p "Поддомен для n8n [n8n]: " N8N_SUBDOMAIN; N8N_SUBDOMAIN=${N8N_SUBDOMAIN:-n8n}
    read -p "Поддомен для Qdrant Studio [studio]: " QDRANT_SUBDOMAIN; QDRANT_SUBDOMAIN=${QDRANT_SUBDOMAIN:-studio}
    read -p "Поддомен для Traefik Dashboard [traefik]: " TRAEFIK_SUBDOMAIN; TRAEFIK_SUBDOMAIN=${TRAEFIK_SUBDOMAIN:-traefik}
    echo "Выберите режим установки:"; echo "  1) QUEUE MODE  — Полный стек: n8n (main+worker), Qdrant, Redis, Postgres, Traefik."; echo "  2) RAG MODE    — Стандартный RAG: n8n (один инстанс), Qdrant, Postgres, Traefik."; echo "  3) ONLY N8N    — Только n8n: n8n (один инстанс), Postgres, Traefik."
    while true; do read -p "Ваш выбор [2]: " INSTALL_MODE; INSTALL_MODE=${INSTALL_MODE:-2}; if [[ "$INSTALL_MODE" =~ ^[1-3]$ ]]; then break; else log_warning "Неверный выбор."; fi; done
}

# 4. Проверка DNS
function verify_dns() {
    log_step "Проверка соответствия DNS-записи и IP-адреса сервера..."
    local domain_to_check="${N8N_SUBDOMAIN}.${ROOT_DOMAIN}"; local server_ip; server_ip=$(curl -4 -s --max-time 10 ifconfig.me); local resolved_ip; resolved_ip=$(nslookup "$domain_to_check" | awk '/^Address: / { print $2 }' | tail -n1 || true)
    if [[ -z "$resolved_ip" || "$server_ip" != "$resolved_ip" ]]; then
        log_warning "DNS-запись для '${domain_to_check}' не найдена или указывает на неверный IP."; log_warning "ТРЕБУЕТСЯ ДЕЙСТВИЕ: Пропишите A-запись для ваших доменов на IP-адрес: ${server_ip}"
    else log_success "DNS-запись для '$domain_to_check' корректно указывает на этот сервер ($server_ip)."; fi
}

# 5. Подготовка окружения
function setup_environment() {
    log_step "Подготовка директорий и файлов проекта в $PROJECT_DIR..."
    mkdir -p "$PROJECT_DIR"/{configs/traefik,volumes/{postgres-n8n,n8n-data,qdrant-data,traefik-acme,redis-data},scripts}
    
    log_step "Установка прав доступа для тома n8n..."
    # touch "$PROJECT_DIR/volumes/n8n-data/config"
    # chmod 600 "$PROJECT_DIR/volumes/n8n-data/config"
    chown -R 1000:1000 "$PROJECT_DIR/volumes/n8n-data"
    for file in .env docker-compose.yml configs/traefik/traefik.yml scripts/manage.sh scripts/update.sh README.md; do
        if [ -f "$PROJECT_DIR/$file" ]; then mv "$PROJECT_DIR/$file" "$PROJECT_DIR/$file.bak_$(date +%s)"; log_warning "Существующий файл $file был сохранен как $file.bak_..."; fi
    done
    touch "$PROJECT_DIR/volumes/traefik-acme/acme.json"; chmod 600 "$PROJECT_DIR/volumes/traefik-acme/acme.json"; log_success "Структура проекта создана."
}

function generate_secret() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$1"; }
function set_env_var() { local key=$1 value=$2 env_file="$PROJECT_DIR/.env"; if grep -q "^${key}=" "$env_file"; then sed -i "/^${key}=/d" "$env_file"; fi; echo "${key}=${value}" >> "$env_file"; }

# 6. Генерация конфигураций
function generate_configs() {
    log_step "Генерация секретов и конфигурационных файлов..."; > "$PROJECT_DIR/.env"
    POSTGRES_USER="n8nuser"; POSTGRES_PASSWORD=$(generate_secret 32); N8N_ENCRYPTION_KEY=$(generate_secret 32); TRAEFIK_DASHBOARD_USER="admin"; TRAEFIK_DASHBOARD_PASSWORD=$(generate_secret 24); REDIS_PASSWORD=$(generate_secret 32)
    set_env_var "ROOT_DOMAIN" "$ROOT_DOMAIN"; set_env_var "ACME_EMAIL" "$ACME_EMAIL"; set_env_var "N8N_HOST" "${N8N_SUBDOMAIN}.${ROOT_DOMAIN}"; set_env_var "QDRANT_HOST" "${QDRANT_SUBDOMAIN}.${ROOT_DOMAIN}"; set_env_var "TRAEFIK_HOST" "${TRAEFIK_SUBDOMAIN}.${ROOT_DOMAIN}"; set_env_var "POSTGRES_DB" "n8n"; set_env_var "POSTGRES_USER" "$POSTGRES_USER"; set_env_var "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"; set_env_var "N8N_ENCRYPTION_KEY" "$N8N_ENCRYPTION_KEY"; set_env_var "N8N_VERSION" "latest"; set_env_var "GENERIC_TIMEZONE" "Europe/Moscow"; set_env_var "TRAEFIK_DASHBOARD_USER" "$TRAEFIK_DASHBOARD_USER"; set_env_var "TRAEFIK_DASHBOARD_PASSWORD" "$TRAEFIK_DASHBOARD_PASSWORD"
    if [ "$INSTALL_MODE" == "1" ]; then set_env_var "REDIS_PASSWORD" "$REDIS_PASSWORD"; fi
    
    TRAEFIK_DASHBOARD_PASSWORD_HASHED=$(htpasswd -nb "$TRAEFIK_DASHBOARD_USER" "$TRAEFIK_DASHBOARD_PASSWORD" | sed -e 's/\$/\$\$/g')
    set_env_var "TRAEFIK_DASHBOARD_PASSWORD_HASHED" "$TRAEFIK_DASHBOARD_PASSWORD_HASHED"

    cat > "$PROJECT_DIR/configs/traefik/traefik.yml" <<EOF
global:
  checkNewVersion: true
  sendAnonymousUsage: false
log:
  level: INFO
entryPoints:
  http:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: https
          scheme: https
  https:
    address: ":443"
providers:
  docker:
    exposedByDefault: false
    endpoint: "unix:///var/run/docker.sock"
    network: mediaworks_public
api:
  dashboard: true
  insecure: false
certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ACME_EMAIL}"
      storage: "/etc/traefik/acme/acme.json"
      httpChallenge:
        entryPoint: http
EOF

    cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
networks:
  mediaworks_public:
    name: mediaworks_public
    driver: bridge

services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./configs/traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./volumes/traefik-acme:/etc/traefik/acme
    networks:
      - mediaworks_public
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-dashboard.rule=Host(\`\${TRAEFIK_HOST}\`)"
      - "traefik.http.routers.traefik-dashboard.service=api@internal"
      - "traefik.http.routers.traefik-dashboard.tls=true"
      - "traefik.http.routers.traefik-dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik-dashboard.middlewares=auth"
      - "traefik.http.middlewares.auth.basicauth.users=\${TRAEFIK_DASHBOARD_PASSWORD_HASHED}"

  postgres:
    image: pgvector/pgvector:pg16
    container_name: postgres-n8n
    restart: always
    environment:
      POSTGRES_DB: \${POSTGRES_DB}
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - ./volumes/postgres-n8n:/var/lib/postgresql/data
    networks:
      - mediaworks_public
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  n8n:
    image: docker.n8n.io/n8nio/n8n:\${N8N_VERSION}
    container_name: n8n-main
    restart: always
    entrypoint:
      - tini
      - --
    command:
      - n8n
    ports:
      - "127.0.0.1:5678:5678"
    # ИЗМЕНЕНО: Формат переменных окружения на "ключ: значение"
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: \${POSTGRES_DB}
      DB_POSTGRESDB_USER: \${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: \${POSTGRES_PASSWORD}
      N8N_ENCRYPTION_KEY: \${N8N_ENCRYPTION_KEY}
      N8N_HOST: \${N8N_HOST}
      N8N_PROTOCOL: https
      NODE_ENV: production
      GENERIC_TIMEZONE: \${GENERIC_TIMEZONE}
      WEBHOOK_URL: https://\${N8N_HOST}/
      N8N_RUNNERS_ENABLED: true
    volumes:
      - ./volumes/n8n-data:/home/node/.n8n
    networks:
      - mediaworks_public
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(\`\${N8N_HOST}\`)"
      - "traefik.http.routers.n8n.entrypoints=https"
      - "traefik.http.routers.n8n.tls=true"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
    depends_on:
      postgres:
        condition: service_healthy
EOF
    if [ "$INSTALL_MODE" == "1" ]; then
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF

      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: 6379
      QUEUE_BULL_REDIS_PASSWORD: \${REDIS_PASSWORD}
EOF
    fi
    if [ "$INSTALL_MODE" == "1" ] || [ "$INSTALL_MODE" == "2" ]; then
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF

  qdrant:
    image: qdrant/qdrant:latest
    container_name: qdrant
    restart: always
    expose:
      - 6333
      - 6334
    volumes:
      - ./volumes/qdrant-data:/qdrant/storage
    networks:
      - mediaworks_public
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.qdrant.rule=Host(\`\${QDRANT_HOST}\`)"
      - "traefik.http.routers.qdrant.entrypoints=https"
      - "traefik.http.routers.qdrant.tls=true"
      - "traefik.http.routers.qdrant.tls.certresolver=letsencrypt"
      - "traefik.http.services.qdrant.loadbalancer.server.port=6333"
EOF
    fi
    if [ "$INSTALL_MODE" == "1" ]; then
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF

  redis:
    image: redis:7-alpine
    container_name: redis
    restart: always
    command: redis-server --requirepass \${REDIS_PASSWORD}
    volumes:
      - ./volumes/redis-data:/data
    networks:
      - mediaworks_public

  n8n-worker:
    image: docker.n8n.io/n8nio/n8n:\${N8N_VERSION}
    container_name: n8n-worker
    command: worker
    restart: always
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: \${POSTGRES_DB}
      DB_POSTGRESDB_USER: \${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: \${POSTGRES_PASSWORD}
      N8N_ENCRYPTION_KEY: \${N8N_ENCRYPTION_KEY}
      GENERIC_TIMEZONE: \${GENERIC_TIMEZONE}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: 6379
      QUEUE_BULL_REDIS_PASSWORD: \${REDIS_PASSWORD}
      N8N_RUNNERS_ENABLED: true
    volumes:
      - ./volumes/n8n-data:/home/node/.n8n
    networks:
      - mediaworks_public
    depends_on:
      - n8n
      - redis
EOF
    fi
    log_success "Файлы конфигурации успешно созданы."
}

# 7. Служебные скрипты
function create_helper_scripts() {
    log_step "Создание скриптов для управления стеком..."
    cat > "$PROJECT_DIR/scripts/manage.sh" <<EOF
#!/bin/bash
cd "$PROJECT_DIR" || exit
case "\$1" in
  start) echo "Запуск..." && docker compose up -d;;
  stop) echo "Остановка..." && docker compose down;;
  restart) echo "Перезапуск..." && docker compose down && docker compose up -d;;
  logs) docker compose logs -f "\$2";;
  status) docker compose ps;;
  *) echo "Использование: \$0 {start|stop|restart|logs|status}";;
esac
EOF
    cat > "$PROJECT_DIR/scripts/update.sh" <<EOF
#!/bin/bash
cd "$PROJECT_DIR" || exit
echo "Обновление образов..."
docker compose pull
echo "Пересоздание контейнеров..."
docker compose up -d --remove-orphans
echo "Очистка..."
docker image prune -f
echo "Готово!"
EOF
    chmod +x "$PROJECT_DIR/scripts/manage.sh"
    chmod +x "$PROJECT_DIR/scripts/update.sh"
    log_success "Служебные скрипты созданы."
}

# 8. Запуск и проверка
function start_services() {
    log_step "Запуск Docker Compose контейнеров..."
    cd "$PROJECT_DIR" && docker compose up -d
    log_success "Команда на запуск контейнеров отправлена."
}

function verify_n8n_readiness() {
    log_step "Ожидание полной готовности n8n (может занять до 3 минут)..."
    log_warning "Если вы еще не настроили DNS, эта проверка не пройдет, и это нормально."
    local retries=1 count=0 success=false
    local n8n_url="https://$(grep N8N_HOST "$PROJECT_DIR/.env" | cut -d '=' -f2)"
    while [ $count -lt $retries ]; do
        count=$((count + 1))
        echo -n "Проверка n8n (попытка $count/$retries)... "
        local status
        status=$(curl --max-time 10 -s -o /dev/null -w "%{http_code}" "$n8n_url" || true)
        if [ "$status" = "200" ] || [ "$status" = "302" ]; then
            log_success "n8n полностью готов и отвечает!"
            success=true
            break
        else
            case "$status" in
                "404"|"502") echo "Traefik работает, но n8n еще не готов (статус $status). Ждем...";;
                "000"|*) echo "Сервис еще не отвечает (проблема с DNS или сетью). Ждем...";;
            esac
            sleep 15
        fi
    done
    if [ "$success" = false ]; then
        log_warning "Не удалось дождаться ответа от n8n."
        log_warning "После настройки DNS и обновления кеша перезапустите сервисы командой: ./scripts/manage.sh restart"
    fi
}

# 9. Финал
function final_summary() {
    source "$PROJECT_DIR/.env"; local credentials_file="$PROJECT_DIR/credentials.txt"
    cat > "$credentials_file" <<EOF
# ==========================================================
# Учетные данные для стека MEDIA WORKS (сгенерировано: $(date))
# ВНИМАНИЕ: Сохраните эти данные и удалите файл с сервера!
# ==========================================================

# -- URL Сервисов --
n8n: https://${N8N_HOST}
Qdrant Studio: https://${QDRANT_HOST}
Traefik Dashboard: https://${TRAEFIK_HOST}

# -- Учетные данные --
Traefik Dashboard:
  Пользователь: ${TRAEFIK_DASHBOARD_USER}
  Пароль: ${TRAEFIK_DASHBOARD_PASSWORD}

PostgreSQL (для n8n, v16 с pgvector):
  Пользователь: ${POSTGRES_USER}
  Пароль: ${POSTGRES_PASSWORD}
  База данных: ${POSTGRES_DB}
EOF
    if [ -n "$REDIS_PASSWORD" ]; then echo -e "\nRedis:\n  Пароль: ${REDIS_PASSWORD}" >> "$credentials_file"; fi
    echo -e "\n# -- Ключ шифрования n8n --\nN8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}" >> "$credentials_file"
    echo -e "${C_GREEN}\n=================================================================="; echo "                 🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА! 🎉"; echo "==================================================================${C_RESET}"
    echo "Программное обеспечение развернуто. Учетные данные сохранены в файл:"; echo -e "  ${C_RED}$credentials_file${C_RESET}"
    echo "Скопируйте их и удалите файл командой: \`rm $credentials_file\`"; echo ""
    echo "--- Управление проектом ---"; echo "Директория: $PROJECT_DIR | Скрипты: $PROJECT_DIR/scripts/"; echo ""
    echo "--- Следующие шаги ---"; echo "1. Если вы еще не сделали этого, настройте A-записи DNS для ваших доменов."; echo "2. Дождитесь обновления DNS (может занять от 5 минут до нескольких часов)."; echo "3. После этого сервисы станут доступны по указанным выше URL."; echo ""
    echo -e "${C_GREEN}==================================================================${C_RESET}"
}

# -- Основной поток выполнения --
main() {
    display_banner
    initial_checks
    install_dependencies
    prompt_for_input
    verify_dns
    setup_environment
    generate_configs
    create_helper_scripts
    start_services
    verify_n8n_readiness
    final_summary
}

main
