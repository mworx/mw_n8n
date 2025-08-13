#!/bin/bash
# =================================================================
# # | | MEDIA WORKS - Universal Stack Installer ||
# =================================================================
# # | | ||
# # | | Автоматизированный установщик для стека Supabase и n8n ||
# # | | Версия: 1.1.0 ||
# # | | Разработчик: Senior DevOps Engineer ||
# # | | ||
# =================================================================

# --- Глобальные переменные и настройки ---
set -e # Прерывать выполнение скрипта при любой ошибке

# --- Цветовые коды для вывода ---
C_RESET='\033${C_RESET} $1"
}

success() {
    echo -e "${C_GREEN}[ OK ]${C_RESET} $1"
}

warn() {
    echo -e "${C_YELLOW}${C_RESET} $1"
}

error() {
    echo -e "${C_RED}${C_RESET} $1" >&2
    exit 1
}

# --- Функции генерации ---
generate_password() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32
}

generate_jwt_token() {
    local secret=$1
    local role=$2
    local expiry_years=20
    local header='{"alg":"HS256","typ":"JWT"}'
    local now
    now=$(date +%s)
    local exp
    exp=$((now + expiry_years * 365 * 24 * 60 * 60))
    local payload
    payload=$(printf '{"role":"%s","iss":"supabase","iat":%d,"exp":%d}' "$role" "$now" "$exp")
    local header_base64
    header_base64=$(printf "%s" "$header" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    local payload_base64
    payload_base64=$(printf "%s" "$payload" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    local signed_content="${header_base64}.${payload_base64}"
    local signature
    signature=$(printf "%s" "$signed_content" | openssl dgst -binary -sha256 -hmac "$secret" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    echo "${signed_content}.${signature}"
}

# --- Функции создания конфигурационных файлов ---
create_project_files() {
    info "Готовим.env для проекта..."
    cat <<EOF > "${PROJECT_DIR}/.env"
# --- Project Settings ---
PROJECT_NAME=${PROJECT_NAME}
MAIN_DOMAIN=${MAIN_DOMAIN}
NETWORK_NAME=${PROJECT_NAME}_main_net
# --- Traefik ---
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
N8N_DOMAIN=${N8N_SUBDOMAIN}.${MAIN_DOMAIN}
SUPABASE_DOMAIN=${SUPABASE_SUBDOMAIN}.${MAIN_DOMAIN}
# --- n8n Database ---
N8N_DB_USER=n8n
N8N_DB_PASSWORD=${N8N_DB_PASSWORD}
N8N_DB_NAME=n8n
N8N_DB_HOST=n8n-db
# --- n8n Settings ---
GENERIC_TIMEZONE=Europe/Moscow
TZ=Europe/Moscow
WEBHOOK_URL=https://\${N8N_DOMAIN}/
EOF
    if$ ]]; then
        cat <<EOF >> "${PROJECT_DIR}/.env"
# --- SMTP Settings ---
N8N_EMAIL_MODE=smtp
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASS=${SMTP_PASS_ESCAPED}
SMTP_SENDER=${SMTP_SENDER_NAME}
N8N_EMAIL_FROM=${SMTP_ADMIN_EMAIL}
SMTP_SSL=true
EOF
    fi
    if]; then
        cat <<EOF >> "${PROJECT_DIR}/.env"
# --- n8n Queue Mode ---
EXECUTIONS_MODE=queue
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
QUEUE_HEALTH_CHECK_ACTIVE=true
N8N_CONCURRENCY=10
EOF
    else
        cat <<EOF >> "${PROJECT_DIR}/.env"
# --- n8n Regular Mode ---
EXECUTIONS_MODE=own
EOF
    fi
    success ".env для проекта готов."

    info "Готовим Docker Compose для проекта..."
    local n8n_services_yaml=""
    local n8n_base_env_yaml
    n8n_base_env_yaml=$(cat <<'YAML'
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=\${N8N_DB_HOST}
      - DB_POSTGRESDB_USER=\${N8N_DB_USER}
      - DB_POSTGRESDB_PASSWORD=\${N8N_DB_PASSWORD}
      - DB_POSTGRESDB_DATABASE=\${N8N_DB_NAME}
      - N8N_HOST=\${N8N_DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=\${WEBHOOK_URL}
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - TZ=\${TZ}
      - EXECUTIONS_MODE=\${EXECUTIONS_MODE}
      - N8N_EMAIL_MODE=\${N8N_EMAIL_MODE}
      - SMTP_HOST=\${SMTP_HOST}
      - SMTP_PORT=\${SMTP_PORT}
      - SMTP_USER=\${SMTP_USER}
      - SMTP_PASS=\${SMTP_PASS}
      - SMTP_SENDER=\${SMTP_SENDER}
      - N8N_EMAIL_FROM=\${N8N_EMAIL_FROM}
      - SMTP_SSL=\${SMTP_SSL}
YAML
)

    case "$INSTALL_CHOICE" in
        "1") # Full Stack
            n8n_services_yaml=$(cat <<YAML
  n8n:
    image: n8nio/n8n
    container_name: \${PROJECT_NAME}_n8n_main
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    environment:
${n8n_base_env_yaml}
      - QUEUE_BULL_REDIS_HOST=\${QUEUE_BULL_REDIS_HOST}
      - QUEUE_BULL_REDIS_PORT=\${QUEUE_BULL_REDIS_PORT}
      - QUEUE_HEALTH_CHECK_ACTIVE=\${QUEUE_HEALTH_CHECK_ACTIVE}
    networks:
      - main_net
    volumes:
      -./n8n-data:/home/node/.n8n
    depends_on:
      - n8n-db
      - redis
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`\${N8N_DOMAIN}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"

  n8n-worker:
    image: n8nio/n8n
    container_name: \${PROJECT_NAME}_n8n_worker
    command: worker
    restart: always
    environment:
${n8n_base_env_yaml}
      - QUEUE_BULL_REDIS_HOST=\${QUEUE_BULL_REDIS_HOST}
      - QUEUE_BULL_REDIS_PORT=\${QUEUE_BULL_REDIS_PORT}
      - N8N_CONCURRENCY=\${N8N_CONCURRENCY}
    networks:
      - main_net
    volumes:
      -./n8n-data:/home/node/.n8n
    depends_on:
      - n8n-db
      - redis
      - n8n

  redis:
    image: redis:latest
    container_name: \${PROJECT_NAME}_redis
    restart: always
    networks:
      - main_net
    volumes:
      - redis_data:/data
YAML
)
            ;;
        "2"|"3"|"4") # Standard, RAG, Lightweight
            n8n_services_yaml=$(cat <<YAML
  n8n:
    image: n8nio/n8n
    container_name: \${PROJECT_NAME}_n8n_main
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    environment:
${n8n_base_env_yaml}
    networks:
      - main_net
    volumes:
      -./n8n-data:/home/node/.n8n
    depends_on:
      - n8n-db
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`\${N8N_DOMAIN}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
YAML
)
            ;;
    esac

    cat <<EOF > "${PROJECT_DIR}/docker-compose.yml"
version: '3.8'

services:
  traefik:
    image: traefik:v2.10
    container_name: \${PROJECT_NAME}_traefik
    restart: always
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--certificatesresolvers.letsencrypt.acme.email=\${LETSENCRYPT_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/etc/traefik/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      -./configs/traefik/acme.json:/etc/traefik/acme.json
    networks:
      - main_net

${n8n_services_yaml}

  n8n-db:
    image: postgres:15
    container_name: \${PROJECT_NAME}_n8n_db
    restart: always
    environment:
      - POSTGRES_USER=\${N8N_DB_USER}
      - POSTGRES_PASSWORD=\${N8N_DB_PASSWORD}
      - POSTGRES_DB=\${N8N_DB_NAME}
    networks:
      - main_net
    volumes:
      -./volumes/postgres:/var/lib/postgresql/data

networks:
  main_net:
    name: \${NETWORK_NAME}
    external: true

volumes:
  redis_data:
EOF
    success "Docker Compose для проекта готов."
}

create_supabase_files() {
    if]; then
        info "Пропускаем установку Supabase (выбран вариант Lightweight)."
        return
    fi

    info "Готовим файлы для Supabase..."
    mkdir -p "$SUPABASE_DIR"
    
    info "Загружаем docker-compose.yml для Supabase..."
    if! curl -fsSL "https://raw.githubusercontent.com/supabase/supabase/master/docker/docker-compose.yml" -o "${SUPABASE_DIR}/docker-compose.yml"; then
        error "Не удалось загрузить docker-compose.yml для Supabase. Проверьте интернет-соединение."
    fi
    success "docker-compose.yml для Supabase загружен."

    info "Создаём.env для Supabase..."
    cat <<EOF > "${SUPABASE_DIR}/.env"
# Supabase Settings
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
JWT_SECRET=${SUPABASE_JWT_SECRET}
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
DASHBOARD_USERNAME=supabase
DASHBOARD_PASSWORD=${DASHBOARD_PASSWORD}
SUPABASE_PUBLIC_URL=https://${SUPABASE_SUBDOMAIN}.${MAIN_DOMAIN}
EOF
    success ".env для Supabase создан."

    info "Модифицируем docker-compose.yml для Supabase..."
    # Add external network definition at the end of the file
    echo -e "\nnetworks:\n  main_net:\n    name: ${PROJECT_NAME}_main_net\n    external: true" >> "${SUPABASE_DIR}/docker-compose.yml"
    
    # Add network and labels to kong service
    sed -i -e "/^  kong:/a \    labels:\n      - \"traefik.enable=true\"\n      - \"traefik.http.routers.supabase-kong.rule=Host(`${SUPABASE_SUBDOMAIN}.${MAIN_DOMAIN}`)\"\n      - \"traefik.http.routers.supabase-kong.entrypoints=websecure\"\n      - \"traefik.http.routers.supabase-kong.tls.certresolver=letsencrypt\"\n      - \"traefik.http.services.supabase-kong.loadbalancer.server.port=8000\"\n    networks:\n      - default\n      - main_net" "${SUPABASE_DIR}/docker-compose.yml"

    if]; then
        info "Оптимизируем Supabase для RAG..."
        awk '
            /^  (storage|functions|realtime|analytics|imgproxy):/ { comment=1 }
            /^  \w/ &&!/  (storage|functions|realtime|analytics|imgproxy):/ { comment=0 }
            /^(volumes|networks):/ { comment=0 }
            {
                if (comment) {
                    print "#" $0
                } else {
                    print $0
                }
            }
        ' "${SUPABASE_DIR}/docker-compose.yml" > "${SUPABASE_DIR}/docker-compose.tmp" && mv "${SUPABASE_DIR}/docker-compose.tmp" "${SUPABASE_DIR}/docker-compose.yml"
        success "Supabase оптимизирован."
    fi
    
    success "Модификация docker-compose.yml для Supabase завершена."
}

# --- Основная логика скрипта ---
main() {
    clear
    echo -e "${C_WHITE_BOLD}"
    echo "================================================================="
    echo "|| Welcome to the MEDIA WORKS Stack Installer ||"
    echo "================================================================="
    echo -e "${C_RESET}"

    info "Проверка системных зависимостей..."
    for cmd in curl git sudo awk; do
        if! command -v $cmd &> /dev/null; then
            error "Команда '$cmd' не найдена. Пожалуйста, установите ее и запустите скрипт снова."
        fi
    done
    success "Все зависимости на месте."

    if [ "$(id -u)" -ne 0 ]; then
        error "Этот скрипт должен быть запущен с правами root или через sudo."
    fi

    if! grep -q -E 'Debian|Ubuntu' /etc/os-release; then
        warn "Этот скрипт оптимизирован для Debian и Ubuntu. На других системах возможны проблемы."
    fi

    info "Пожалуйста, введите параметры для вашего проекта."
    while true; do
        read -rp "$(echo -e "${C_YELLOW}Введите название проекта (только латинские буквы, без пробелов, например 'myproject'): ${C_RESET}")" PROJECT_NAME
        if+$ ]]; then
            break
        else
            warn "Неверный формат. Используйте только латинские буквы."
        fi
    done
    
    read -rp "$(echo -e "${C_YELLOW}Введите основной домен (например, 'example.com'): ${C_RESET}")" MAIN_DOMAIN
    if]; then
        error "Основной домен является обязательным параметром."
    fi

    read -rp "$(echo -e "${C_YELLOW}Введите поддомен для n8n [default: n8n]: ${C_RESET}")" N8N_SUBDOMAIN
    N8N_SUBDOMAIN=${N8N_SUBDOMAIN:-n8n}

    read -rp "$(echo -e "${C_YELLOW}Введите поддомен для Supabase Studio [default: supabase]: ${C_RESET}")" SUPABASE_SUBDOMAIN
    SUPABASE_SUBDOMAIN=${SUPABASE_SUBDOMAIN:-supabase}

    read -rp "$(echo -e "${C_YELLOW}Введите ваш email для сертификатов Let's Encrypt: ${C_RESET}")" LETSENCRYPT_EMAIL
    if]; then
        error "Email является обязательным параметром для Let's Encrypt."
    fi

    echo -e "${C_WHITE_BOLD}Выберите вариант установки:${C_RESET}"
    echo "  1) МАКСИМАЛЬНЫЙ (Full Stack: Supabase, Traefik, N8N Main+Worker, Redis, PG for N8N)"
    echo "  2) СТАНДАРТНЫЙ (Standard: Supabase, Traefik, N8N single, PG for N8N)"
    echo "  3) RAG-ОПТИМИЗИРОВАННЫЙ (RAG: Supabase RAG-only, Traefik, N8N, PG for N8N)"
    echo "  4) МИНИМАЛЬНЫЙ (Lightweight: Traefik, N8N, PG for N8N, без Supabase)"
    read -rp "$(echo -e "${C_YELLOW}Ваш выбор [1-4]: ${C_RESET}")" INSTALL_CHOICE

    read -rp "$(echo -e "${C_YELLOW}Требуется ли настройка SMTP? [y/N]: ${C_RESET}")" SMTP_CHOICE
    SMTP_CHOICE=${SMTP_CHOICE:-N}

    if$ ]]; then
        read -rp "SMTP Host: " SMTP_HOST
        read -rp "SMTP Port: " SMTP_PORT
        read -rp "SMTP User: " SMTP_USER
        read -sp "SMTP Password: " SMTP_PASS
        echo
        SMTP_PASS_ESCAPED=${SMTP_PASS//\$/\$\$}
        read -rp "SMTP Sender Name: " SMTP_SENDER_NAME
        read -rp "SMTP Admin Email: " SMTP_ADMIN_EMAIL
    fi

    info "Проверка и установка Docker..."
    if! command -v docker &> /dev/null; then
        info "Docker не найден. Запускаю установку..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        success "Docker и Docker Compose успешно установлены."
    else
        success "Docker уже установлен."
    fi

    info "Генерация секретов и создание каталогов..."
    PROJECT_DIR="/root/${PROJECT_NAME}"
    SUPABASE_DIR="/root/supabase"
    mkdir -p "${PROJECT_DIR}/configs/traefik"
    mkdir -p "${PROJECT_DIR}/n8n-data"
    mkdir -p "${PROJECT_DIR}/volumes/postgres"
    
    POSTGRES_PASSWORD=$(generate_password)
    N8N_DB_PASSWORD=$(generate_password)
    SUPABASE_JWT_SECRET=$(generate_password)
    DASHBOARD_PASSWORD=$(generate_password)
    ANON_KEY=$(generate_jwt_token "$SUPABASE_JWT_SECRET" "anon")
    SERVICE_ROLE_KEY=$(generate_jwt_token "$SUPABASE_JWT_SECRET" "service_role")
    success "Секреты сгенерированы."

    info "Создание конфигурационных файлов..."
    create_project_files
    create_supabase_files
    success "Конфигурационные файлы успешно созданы."

    info "Очистка и валидация.env файлов..."
    if]; then
        sed -i -e 's/[[:space:]]*$//' -e 's/\r$//' "${SUPABASE_DIR}/.env"
        grep -Eq '^[A-Z_]+=' "${SUPABASE_DIR}/.env" |

| warn "Обнаружен неверный формат в.env файле Supabase."
    fi
    sed -i -e 's/[[:space:]]*$//' -e 's/\r$//' "${PROJECT_DIR}/.env"
    grep -Eq '^[A-Z_]+=' "${PROJECT_DIR}/.env" |

| warn "Обнаружен неверный формат в.env файле проекта."
    success "Файлы.env очищены."

    info "Подготовка сетевой инфраструктуры и хранилища сертификатов..."
    docker network create "${PROJECT_NAME}_main_net" |

| warn "Сеть ${PROJECT_NAME}_main_net уже существует."
    touch "${PROJECT_DIR}/configs/traefik/acme.json"
    chmod 600 "${PROJECT_DIR}/configs/traefik/acme.json"
    success "Сетевая инфраструктура готова."

    if]; then
        info "Запуск изолированного стека Supabase..."
        (cd "$SUPABASE_DIR" && docker compose up -d)
        success "Стек Supabase запущен."
    fi

    info "Запуск проектного стека (${PROJECT_NAME})..."
    (cd "$PROJECT_DIR" && docker compose up -d)
    success "Проектный стек запущен. Ожидание стабилизации сервисов (30 секунд)..."
    sleep 30

    info "Выполнение проверок работоспособности (Health Checks)..."
    N8N_URL="https://${N8N_SUBDOMAIN}.${MAIN_DOMAIN}"
    if n8n_status=$(curl -s -o /dev/null -w "%{http_code}" "$N8N_URL"); then
        if [ "$n8n_status" -eq 200 ]; then
            success "n8n UI доступен по адресу ${N8N_URL} (статус: ${n8n_status})"
        else
            warn "n8n UI ответил со статусом ${n8n_status}. Возможны проблемы с запуском или SSL."
        fi
    else
        warn "Не удалось выполнить запрос к n8n UI по адресу ${N8N_URL}."
    fi

    if]; then
        SUPABASE_URL="https://${SUPABASE_SUBDOMAIN}.${MAIN_DOMAIN}"
        if supabase_status=$(curl -s -o /dev/null -w "%{http_code}" "$SUPABASE_URL"); then
            if [ "$supabase_status" -eq 200 ]; then
                success "Supabase Studio доступен по адресу ${SUPABASE_URL} (статус: ${supabase_status})"
            else
                warn "Supabase Studio ответил со статусом ${supabase_status}. Возможны проблемы с запуском или SSL."
            fi
        else
            warn "Не удалось выполнить запрос к Supabase Studio по адресу ${SUPABASE_URL}."
        fi
    fi

    info "Генерация файла с учетными данными..."
    CREDENTIALS_FILE="/root/post-install-credentials.txt"
    {
        echo "================================================="
        echo "MEDIA WORKS - Данные по установке проекта: ${PROJECT_NAME}"
        echo "================================================="
        echo ""
        echo "Дата установки: $(date)"
        echo ""
        echo "--- URL Адреса ---"
        echo "n8n UI: https://${N8N_SUBDOMAIN}.${MAIN_DOMAIN}"
        if]; then
            echo "Supabase Studio: https://${SUPABASE_SUBDOMAIN}.${MAIN_DOMAIN}"
            echo "Supabase API Endpoint: https://${SUPABASE_SUBDOMAIN}.${MAIN_DOMAIN}"
        fi
        echo ""
        echo "--- Доступы к n8n ---"
        echo "Postgres (внутри Docker): postgresql://n8n:${N8N_DB_PASSWORD}@n8n-db:5432/n8n"
        echo ""
        if]; then
            echo "--- Доступы к Supabase ---"
            echo "Studio Username: supabase"
            echo "Studio Password: ${DASHBOARD_PASSWORD}"
            echo "Postgres (внутри Docker): postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/postgres"
            echo ""
            echo "--- Supabase API Ключи ---"
            echo "ANON_KEY: ${ANON_KEY}"
            echo "SERVICE_ROLE_KEY: ${SERVICE_ROLE_KEY}"
            echo "JWT_SECRET: ${SUPABASE_JWT_SECRET}"
        fi
    } > "$CREDENTIALS_FILE"
    success "Файл с учетными данными сохранен в ${CREDENTIALS_FILE}"

    echo -e "${C_WHITE_BOLD}"
    echo "================================================================="
    echo "|| Установка завершена! ||"
    echo "================================================================="
    echo -e "${C_RESET}"
    echo "Все доступы и пароли сохранены в файле: ${CREDENTIALS_FILE}"
    echo "Спасибо за использование установщика от MEDIA WORKS!"
}

# --- Запуск основной функции ---
main
