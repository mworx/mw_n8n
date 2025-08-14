#!/bin/bash

# ==============================================================================
# Скрипт для развертывания стека n8n + RAG (Qdrant) с Traefik
# © 2025 MEDIA WORKS. Все права защищены.
# Версия: 1.1.0
# Изменения: Обновлен Postgres до v16 с поддержкой pgvector.
# ==============================================================================

# -- Глобальные переменные и константы --
# Выход при ошибке
set -e
# Выход при ошибке в пайплайне
set -o pipefail

# Директория для установки проекта
PROJECT_DIR="/opt/mediaworks-stack"

# Цвета для вывода
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'

# -- Функции --

# Отображение баннера
function display_banner() {
    echo -e "${C_CYAN}"
    echo "    __  ___      __           __  __           __      "
    echo "   /  |/  /___ _/ /_____     / / / /___  _____/ /_     "
    echo "  / /|_/ / __ \`/ __/ __ \   / /_/ / __ \/ ___/ __/     "
    echo " / /  / / /_/ / /_/ /_/ /  / __  / /_/ / /__/ /_       "
    echo "/_/  /_/\__,_/\__/\____/  /_/ /_/\____/\___/\__/       "
    echo "                                                       "
    echo "         AI-агенты и системная интеграция"
    echo -e "${C_RESET}"
    echo "Добро пожаловать в установщик стека n8n+RAG от MEDIA WORKS!"
    echo "------------------------------------------------------------------"
}

# Анимация процесса
function spinner() {
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
    printf " \b\b\b\b\b"
}

# Функция для логирования шагов
function log_step() {
    echo -e "\n${C_BLUE}➡️  $1${C_RESET}"
}

# Функция для вывода успеха
function log_success() {
    echo -e "${C_GREEN}✅  $1${C_RESET}"
}

# Функция для вывода предупреждения
function log_warning() {
    echo -e "${C_YELLOW}⚠️  $1${C_RESET}"
}

# Функция для вывода ошибки и выхода
function log_error() {
    echo -e "${C_RED}❌  $1${C_RESET}" >&2
    exit 1
}

# 1. Проверка системных требований
function initial_checks() {
    log_step "Запуск первоначальных проверок..."

    # Проверка на root
    if [[ "$EUID" -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root."
    fi

    # Проверка ОС
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
            log_error "Этот скрипт поддерживает только Debian и Ubuntu."
        fi
    else
        log_error "Не удалось определить операционную систему."
    fi

    # Проверка портов 80/443
    for port in 80 443; do
        if ss -tuln | grep -q ":$port\s"; then
            log_warning "Порт $port занят. Попытка остановить конфликтующие сервисы..."
            systemctl stop nginx 2>/dev/null || true
            systemctl stop apache2 2>/dev/null || true
            sleep 2
            if ss -tuln | grep -q ":$port\s"; then
                log_error "Порт $port все еще занят. Освободите порт и запустите скрипт заново."
            else
                log_success "Порт $port успешно освобожден."
            fi
        fi
    done

    log_success "Системные требования в норме."
}

# 2. Установка зависимостей
function install_dependencies() {
    log_step "Установка необходимых пакетов (curl, git, openssl, jq, net-tools)..."
    for i in {1..3}; do
        apt-get update && apt-get install -y curl git openssl jq net-tools ca-certificates gnupg >/dev/null && break
        log_warning "Попытка $i не удалась. Повтор через 5 секунд..."
        sleep 5
    done || log_error "Не удалось установить базовые зависимости."
    
    # Установка Docker
    if ! command -v docker &> /dev/null; then
        log_step "Установка Docker..."
        (
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
              $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
              tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
        ) &
        spinner $!
    fi
    # Проверка Docker Compose
     if ! docker compose version &> /dev/null; then
        log_error "Docker Compose не установлен или не работает корректно. Пожалуйста, установите его вручную."
    fi

    log_success "Все зависимости установлены."
}

# 3. Сбор данных от пользователя
function prompt_for_input() {
    log_step "Сбор необходимой информации..."

    # Основной домен
    while true; do
        read -p "Введите основной домен (например, example.com): " ROOT_DOMAIN
        if [[ "$ROOT_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            log_warning "Неверный формат домена. Попробуйте еще раз."
        fi
    done

    # Email для Let's Encrypt
    while true; do
        read -p "Введите ваш email для SSL-сертификатов Let's Encrypt: " ACME_EMAIL
        if [[ "$ACME_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            log_warning "Неверный формат email. Попробуйте еще раз."
        fi
    done

    # Поддомены
    read -p "Поддомен для n8n [n8n]: " N8N_SUBDOMAIN
    N8N_SUBDOMAIN=${N8N_SUBDOMAIN:-n8n}

    read -p "Поддомен для Qdrant Studio [studio]: " QDRANT_SUBDOMAIN
    QDRANT_SUBDOMAIN=${QDRANT_SUBDOMAIN:-studio}
    
    read -p "Поддомен для Traefik Dashboard [traefik]: " TRAEFIK_SUBDOMAIN
    TRAEFIK_SUBDOMAIN=${TRAEFIK_SUBDOMAIN:-traefik}

    # Режим установки
    echo "Выберите режим установки:"
    echo "  1) QUEUE MODE  — Полный стек: n8n (main+worker), Qdrant, Redis, Postgres, Traefik."
    echo "  2) RAG MODE    — Стандартный RAG: n8n (один инстанс), Qdrant, Postgres, Traefik."
    echo "  3) ONLY N8N    — Только n8n: n8n (один инстанс), Postgres, Traefik."
    while true; do
        read -p "Ваш выбор [2]: " INSTALL_MODE
        INSTALL_MODE=${INSTALL_MODE:-2}
        if [[ "$INSTALL_MODE" =~ ^[1-3]$ ]]; then
            break
        else
            log_warning "Неверный выбор. Введите число от 1 до 3."
        fi
    done
}

# 4. Подготовка окружения
function setup_environment() {
    log_step "Подготовка директорий и файлов проекта в $PROJECT_DIR..."
    
    # Создание директорий
    mkdir -p "$PROJECT_DIR"/{configs/traefik,volumes/{postgres-n8n,n8n-data,qdrant-data,traefik-acme,redis-data},scripts}

    # Бэкап существующих файлов
    for file in .env docker-compose.yml configs/traefik/traefik.yml scripts/manage.sh scripts/update.sh README.md; do
        if [ -f "$PROJECT_DIR/$file" ]; then
            mv "$PROJECT_DIR/$file" "$PROJECT_DIR/$file.bak_$(date +%s)"
            log_warning "Существующий файл $file был сохранен как $file.bak_..."
        fi
    done

    # Создание acme.json с правильными правами
    touch "$PROJECT_DIR/volumes/traefik-acme/acme.json"
    chmod 600 "$PROJECT_DIR/volumes/traefik-acme/acme.json"

    log_success "Структура проекта создана."
}

# Генерация случайной строки
function generate_secret() {
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$1"
}

# Функция для безопасного обновления .env файла
function set_env_var() {
    local key=$1
    local value=$2
    local env_file="$PROJECT_DIR/.env"

    if grep -q "^${key}=" "$env_file"; then
        # Заменяем существующее значение
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
        # Добавляем новую переменную
        echo "${key}=${value}" >> "$env_file"
    fi
}

# 5. Генерация конфигураций
function generate_configs() {
    log_step "Генерация секретов и конфигурационных файлов..."
    
    # Создаем/очищаем .env
    > "$PROJECT_DIR/.env"

    # -- Генерация секретов --
    POSTGRES_USER="n8nuser"
    POSTGRES_PASSWORD=$(generate_secret 32)
    N8N_ENCRYPTION_KEY=$(generate_secret 32)
    TRAEFIK_DASHBOARD_USER="admin"
    TRAEFIK_DASHBOARD_PASSWORD=$(generate_secret 24)
    REDIS_PASSWORD=$(generate_secret 32)

    # -- Заполнение .env файла --
    set_env_var "ROOT_DOMAIN" "$ROOT_DOMAIN"
    set_env_var "ACME_EMAIL" "$ACME_EMAIL"
    set_env_var "N8N_HOST" "${N8N_SUBDOMAIN}.${ROOT_DOMAIN}"
    set_env_var "QDRANT_HOST" "${QDRANT_SUBDOMAIN}.${ROOT_DOMAIN}"
    set_env_var "TRAEFIK_HOST" "${TRAEFIK_SUBDOMAIN}.${ROOT_DOMAIN}"
    
    set_env_var "POSTGRES_DB" "n8n"
    set_env_var "POSTGRES_USER" "$POSTGRES_USER"
    set_env_var "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"
    
    set_env_var "N8N_ENCRYPTION_KEY" "$N8N_ENCRYPTION_KEY"
    set_env_var "N8N_VERSION" "latest"
    set_env_var "GENERIC_TIMEZONE" "Europe/Moscow" # Рекомендуется для консистентности
    
    set_env_var "TRAEFIK_DASHBOARD_USER" "$TRAEFIK_DASHBOARD_USER"
    set_env_var "TRAEFIK_DASHBOARD_PASSWORD" "$TRAEFIK_DASHBOARD_PASSWORD"
    
    if [ "$INSTALL_MODE" == "1" ]; then
        set_env_var "REDIS_PASSWORD" "$REDIS_PASSWORD"
    fi

    # Генерация htpasswd для Traefik (требует apache2-utils)
    if ! command -v htpasswd &> /dev/null; then
        apt-get install -y apache2-utils >/dev/null
    fi
    # Обновляем .env с хешированным паролем
    TRAEFIK_DASHBOARD_PASSWORD_HASHED=$(htpasswd -nb -B "$TRAEFIK_DASHBOARD_USER" "$TRAEFIK_DASHBOARD_PASSWORD" | sed -e 's/\$/\$\$/g')
    set_env_var "TRAEFIK_DASHBOARD_PASSWORD_HASHED" "$TRAEFIK_DASHBOARD_PASSWORD_HASHED"


    # -- Создание статической конфигурации Traefik --
    cat > "$PROJECT_DIR/configs/traefik/traefik.yml" <<EOF
# configs/traefik/traefik.yml
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

    # -- Создание docker-compose.yml --
    cat > "$PROJECT_DIR/docker-compose.yml" <<EOF
# docker-compose.yml
version: '3.8'

networks:
  mediaworks_public:
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
      # Dashboard
      - "traefik.http.routers.traefik-dashboard.rule=Host(\`\${TRAEFIK_HOST}\`)"
      - "traefik.http.routers.traefik-dashboard.service=api@internal"
      - "traefik.http.routers.traefik-dashboard.tls=true"
      - "traefik.http.routers.traefik-dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.routers.traefik-dashboard.middlewares=auth"
      # Middleware for Basic Auth
      - "traefik.http.middlewares.auth.basicauth.users=\${TRAEFIK_DASHBOARD_USER}:\${TRAEFIK_DASHBOARD_PASSWORD_HASHED}"

  postgres:
    image: pgvector/pgvector:pg16
    container_name: postgres-n8n
    restart: always
    environment:
      - POSTGRES_DB=\${POSTGRES_DB}
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
    volumes:
      - ./volumes/postgres-n8n:/var/lib/postgresql/data
    networks:
      - mediaworks_public
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

EOF

    # Добавляем n8n
    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
  n8n:
    image: n8n.io/n8n:\${N8N_VERSION}
    container_name: n8n-main
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_USER=\${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - N8N_HOST=\${N8N_HOST}
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - WEBHOOK_URL=https://\${N8N_HOST}/
EOF

    if [ "$INSTALL_MODE" == "1" ]; then
        # Настройки для QUEUE MODE
        cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=\${REDIS_PASSWORD}
EOF
    fi

    cat >> "$PROJECT_DIR/docker-compose.yml" <<EOF
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

    # Добавляем Qdrant (для режимов 1 и 2)
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

    # Добавляем Redis и n8n-worker (для режима 1)
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
    image: n8n.io/n8n:\${N8N_VERSION}
    container_name: n8n-worker
    command: worker
    restart: always
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_USER=\${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
      - N8N_ENCRYPTION_KEY=\${N8N_ENCRYPTION_KEY}
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - QUEUE_BULL_REDIS_PASSWORD=\${REDIS_PASSWORD}
    volumes:
      - ./volumes/n8n-data:/home/node/.n8n
    networks:
      - mediaworks_public
    depends_on:
      - n8n
      - redis
EOF
    fi

    log_success "Файлы конфигурации (.env, docker-compose.yml, traefik.yml) успешно созданы."
}

# 6. Создание служебных скриптов и README
function create_helper_scripts() {
    log_step "Создание скриптов для управления стеком..."

    # manage.sh
    cat > "$PROJECT_DIR/scripts/manage.sh" <<EOF
#!/bin/bash
# Скрипт для управления стеком MEDIA WORKS
cd "$PROJECT_DIR" || exit

case "\$1" in
  start)
    echo "Запуск стека..."
    docker compose up -d
    ;;
  stop)
    echo "Остановка стека..."
    docker compose down
    ;;
  restart)
    echo "Перезапуск стека..."
    docker compose down && docker compose up -d
    ;;
  logs)
    echo "Просмотр логов (нажмите Ctrl+C для выхода)..."
    docker compose logs -f "\$2"
    ;;
  status)
    echo "Текущий статус контейнеров:"
    docker compose ps
    ;;
  *)
    echo "Использование: \$0 {start|stop|restart|logs [service_name]|status}"
    exit 1
    ;;
esac
EOF
    chmod +x "$PROJECT_DIR/scripts/manage.sh"

    # update.sh
    cat > "$PROJECT_DIR/scripts/update.sh" <<EOF
#!/bin/bash
# Скрипт для обновления компонентов стека MEDIA WORKS
cd "$PROJECT_DIR" || exit

echo "Обновление образов Docker..."
docker compose pull

echo "Пересоздание контейнеров с новыми образами..."
docker compose up -d

echo "Очистка старых образов..."
docker image prune -f

echo "Обновление завершено!"
EOF
    chmod +x "$PROJECT_DIR/scripts/update.sh"

    # README.md
    cat > "$PROJECT_DIR/README.md" <<EOF
# AI-стек от MEDIA WORKS

Этот проект содержит все необходимое для запуска и управления вашим n8n+RAG окружением.

## Управление

Все команды нужно выполнять из директории \`$PROJECT_DIR\`.

-   **Запуск:** \`./scripts/manage.sh start\`
-   **Остановка:** \`./scripts/manage.sh stop\`
-   **Перезапуск:** \`./scripts/manage.sh restart\`
-   **Статус:** \`./scripts/manage.sh status\`
-   **Просмотр логов всех сервисов:** \`./scripts/manage.sh logs\`
-   **Просмотр логов конкретного сервиса (например, n8n):** \`./scripts/manage.sh logs n8n\`

## Обновление

Для обновления всех компонентов до последних стабильных версий:

\`\`\`bash
./scripts/update.sh
\`\`\`

## Важные файлы

-   **\`docker-compose.yml\`**: Основной файл, описывающий все сервисы.
-   **\`.env\`**: Конфигурация и секреты. **Никогда не передавайте этот файл!**
-   **\`credentials.txt\`**: Файл с учетными данными, сгенерированный при установке. **Рекомендуется удалить после сохранения паролей в безопасном месте.**
-   **\`volumes/\`**: Директория с постоянными данными (базы данных, конфигурации и т.д.).
EOF

    log_success "Служебные скрипты и README.md созданы."
}

# 7. Запуск стека и проверка
function start_and_verify() {
    log_step "Запуск Docker Compose контейнеров..."
    (
        cd "$PROJECT_DIR" && docker compose up -d
    ) &
    spinner $!
    
    log_step "Ожидание запуска сервисов и получения SSL-сертификатов (может занять 2-3 минуты)..."
    sleep 15 # Даем время на первоначальный запуск
    
    local retries=20
    local count=0
    local success=false
    while [ $count -lt $retries ]; do
        count=$((count + 1))
        echo -n "Проверка n8n... "
        local status
        status=$(curl -s -o /dev/null -w "%{http_code}" "https://$(grep N8N_HOST "$PROJECT_DIR/.env" | cut -d '=' -f2)")
        if [ "$status" = "200" ] || [ "$status" = "302" ]; then
            log_success "n8n доступен!"
            success=true
            break
        else
            echo "Статус $status. Повтор через 10 секунд... ($count/$retries)"
        fi
        sleep 10
    done

    if [ "$success" = false ]; then
        log_error "Не удалось подтвердить запуск n8n. Проверьте логи: cd $PROJECT_DIR && ./scripts/manage.sh logs n8n"
    fi
    log_success "Стек успешно запущен!"
}


# 8. Финальный отчет
function final_summary() {
    source "$PROJECT_DIR/.env"
    
    local credentials_file="$PROJECT_DIR/credentials.txt"
    # Создаем credentials.txt
    cat > "$credentials_file" <<EOF
# ==========================================================
# Учетные данные для стека MEDIA WORKS
# Дата генерации: $(date)
# 
# ВНИМАНИЕ: Сохраните эти данные в надежном месте
# и удалите этот файл с сервера!
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

    if [ -n "$REDIS_PASSWORD" ]; then
        echo -e "\nRedis:\n  Пароль: ${REDIS_PASSWORD}" >> "$credentials_file"
    fi

    echo -e "\n# -- Ключ шифрования n8n --" >> "$credentials_file"
    echo "N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}" >> "$credentials_file"

    # Вывод на экран
    echo -e "${C_GREEN}"
    echo "=================================================================="
    echo "                 🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА! 🎉"
    echo "=================================================================="
    echo -e "${C_RESET}"

    echo "Ваши сервисы доступны по адресам:"
    echo -e "  - n8n:               ${C_CYAN}https://${N8N_HOST}${C_RESET}"
    if [ "$INSTALL_MODE" != "3" ]; then
    echo -e "  - Qdrant Studio:     ${C_CYAN}https://${QDRANT_HOST}${C_RESET}"
    fi
    echo -e "  - Traefik Dashboard: ${C_CYAN}https://${TRAEFIK_HOST}${C_RESET}"
    echo ""
    echo -e "${C_YELLOW}ВАЖНО: Все учетные данные были сохранены в файл:${C_RESET}"
    echo -e "  ${C_RED}$credentials_file${C_RESET}"
    echo "  Скопируйте его содержимое в безопасное место и удалите файл с сервера командой:"
    echo -e "  \`rm $credentials_file\`"
    echo ""
    echo "--- Чек-лист следующих шагов ---"
    echo "  1. [ ] Убедитесь, что DNS A-записи для доменов указывают на IP этого сервера."
    echo "  2. [ ] Проверьте доступность всех сервисов в браузере."
    echo "  3. [ ] Войдите в n8n и выполните первоначальную настройку пользователя."
    echo "  4. [ ] Сохраните и удалите файл с учетными данными."
    echo ""
    echo "--- Управление проектом ---"
    echo "  Директория проекта: $PROJECT_DIR"
    echo "  Скрипты управления: $PROJECT_DIR/scripts/"
    echo "  (./scripts/manage.sh start|stop|restart|logs|status, ./scripts/update.sh)"
    echo ""
    echo "---"
    echo "Спасибо за выбор MEDIA WORKS!"
    echo "Связь с нами: contact@mediaworks.example.com | https://mediaworks.example.com"
    echo "=================================================================="
}


# -- Основной поток выполнения --
main() {
    display_banner
    initial_checks
    install_dependencies
    prompt_for_input
    setup_environment
    generate_configs
    create_helper_scripts
    start_and_verify
    final_summary
}

main
