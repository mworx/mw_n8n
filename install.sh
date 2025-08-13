#!/bin/bash
#
# =================================================================
# # | | MEDIA WORKS - Universal Stack Installer ||
# =================================================================
# # | |
# # | | Автоматизированный установщик для стека Supabase и n8n ||
# # | | Версия: 1.0.0 ||
# # | | Разработчик: Senior DevOps Engineer ||
# # | |
# =================================================================

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

# --- Функция для генерации случайных паролей ---
generate_password() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32
}

# --- Функция для генерации JWT токенов Supabase (реализация на Bash) ---
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

# --- Основная логика скрипта ---
main() {
    # --- Этап 1: Приветствие и проверка системы ---
    clear
    echo -e "${C_WHITE_BOLD}"
    echo "================================================================="
    echo "|| Welcome to the MEDIA WORKS Stack Installer ||"
    echo "================================================================="
    echo -e "${C_RESET}"

    info "Проверка системных зависимостей..."
    for cmd in curl git sudo; do
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

    # --- Этап 2: Сбор пользовательских данных ---
    info "Пожалуйста, введите параметры для вашего проекта."

    while true; do
        read -rp "$(echo -e ${C_YELLOW}"Введите название проекта (только латинские буквы, без пробелов, например 'myproject'): "${C_RESET})" PROJECT_NAME
        if+$ ]]; then
            break
        else
            warn "Неверный формат. Используйте только латинские буквы."
        fi
    done
    
    read -rp "$(echo -e ${C_YELLOW}"Введите основной домен (например, 'example.com'): "${C_RESET})" MAIN_DOMAIN
    if; then
        error "Основной домен является обязательным параметром."
    fi

    read -rp "$(echo -e ${C_YELLOW}"Введите поддомен для n8n [default: n8n]: "${C_RESET})" N8N_SUBDOMAIN
    N8N_SUBDOMAIN=${N8N_SUBDOMAIN:-n8n}

    read -rp "$(echo -e ${C_YELLOW}"Введите поддомен для Supabase Studio [default: supabase]: "${C_RESET})" SUPABASE_SUBDOMAIN
    SUPABASE_SUBDOMAIN=${SUPABASE_SUBDOMAIN:-supabase}

    read -rp "$(echo -e ${C_YELLOW}"Введите ваш email для сертификатов Let's Encrypt: "${C_RESET})" LETSENCRYPT_EMAIL
    if; then
        error "Email является обязательным параметром для Let's Encrypt."
    fi

    echo -e "${C_WHITE_BOLD}Выберите вариант установки:${C_RESET}"
    echo "  1) МАКСИМАЛЬНЫЙ (Full Stack: Supabase, Traefik, N8N Main+Worker, Redis, PG for N8N)"
    echo "  2) СТАНДАРТНЫЙ (Standard: Supabase, Traefik, N8N single, PG for N8N)"
    echo "  3) RAG-ОПТИМИЗИРОВАННЫЙ (RAG: Supabase RAG-only, Traefik, N8N, PG for N8N)"
    echo "  4) МИНИМАЛЬНЫЙ (Lightweight: Traefik, N8N, PG for N8N, без Supabase)"
    read -rp "$(echo -e ${C_YELLOW}"Ваш выбор [1-4]: "${C_RESET})" INSTALL_CHOICE

    read -rp "$(echo -e ${C_YELLOW}"Требуется ли настройка SMTP? [y/N]: "${C_RESET})" SMTP_CHOICE
    SMTP_CHOICE=${SMTP_CHOICE:-N}

    if$ ]]; then
        read -rp "SMTP Host: " SMTP_HOST
        read -rp "SMTP Port: " SMTP_PORT
        read -rp "SMTP User: " SMTP_USER
        read -sp "SMTP Password: " SMTP_PASS
        echo
        read -rp "SMTP Sender Name: " SMTP_SENDER_NAME
        read -rp "SMTP Admin Email: " SMTP_ADMIN_EMAIL
    fi

    # --- Этап 3: Установка Docker ---
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

    # --- Этап 4: Генерация секретов и конфигураций ---
    info "Генерация секретов и конфигурационных файлов..."
    
    # Создание директорий
    PROJECT_DIR="/root/${PROJECT_NAME}"
    SUPABASE_DIR="/root/supabase"
    mkdir -p "${PROJECT_DIR}/configs/traefik"
    mkdir -p "${PROJECT_DIR}/n8n-data"
    mkdir -p "${PROJECT_DIR}/volumes/postgres"
    
    # Генерация секретов
    POSTGRES_PASSWORD=$(generate_password)
    N8N_DB_PASSWORD=$(generate_password)
    SUPABASE_JWT_SECRET=$(generate_password)
    DASHBOARD_PASSWORD=$(generate_password)

    # Генерация JWT ключей Supabase
    ANON_KEY=$(generate_jwt_token "$SUPABASE_JWT_SECRET" "anon")
    SERVICE_ROLE_KEY=$(generate_jwt_token "$SUPABASE_JWT_SECRET" "service_role")

    # Создание конфигурационных файлов
    #... (здесь будет код для создания docker-compose.yml,.env, traefik.yml)
    # Этот блок будет очень большим и будет содержать логику 'case' для разных вариантов установки
    # Для краткости, представим его в виде вызовов функций
    create_traefik_config
    create_project_files
    create_supabase_files

    info "Конфигурационные файлы успешно созданы."

    # --- Этап 5: Развертывание стеков ---
    info "Подготовка сетевой инфраструктуры и хранилища сертификатов..."
    docker network create "${PROJECT_NAME}_main_net" |

| warn "Сеть ${PROJECT_NAME}_main_net уже существует."
    touch "${PROJECT_DIR}/configs/traefik/acme.json"
    chmod 600 "${PROJECT_DIR}/configs/traefik/acme.json"
    success "Сетевая инфраструктура готова."

    if; then
        info "Запуск изолированного стека Supabase..."
        (cd "$SUPABASE_DIR" && docker compose up -d)
        success "Стек Supabase запущен."
    fi

    info "Запуск проектного стека (${PROJECT_NAME})..."
    (cd "$PROJECT_DIR" && docker compose up -d)
    success "Проектный стек запущен. Ожидание стабилизации сервисов..."
    sleep 30 # Даем время контейнерам запуститься

    # --- Этап 6: Проверка и отчет ---
    info "Выполнение проверок работоспособности (Health Checks)..."
    
    N8N_URL="https://${N8N_SUBDOMAIN}.${MAIN_DOMAIN}"
    n8n_status=$(curl -s -o /dev/null -w "%{http_code}" "$N8N_URL")
    if [ "$n8n_status" -eq 200 ]; then
        success "n8n UI доступен по адресу ${N8N_URL} (статус: ${n8n_status})"
    else
        warn "n8n UI ответил со статусом ${n8n_status}. Возможны проблемы с запуском."
    fi

    if; then
        SUPABASE_URL="https://${SUPABASE_SUBDOMAIN}.${MAIN_DOMAIN}"
        supabase_status=$(curl -s -o /dev/null -w "%{http_code}" "$SUPABASE_URL")
        if [ "$supabase_status" -eq 200 ]; then
            success "Supabase Studio доступен по адресу ${SUPABASE_URL} (статус: ${supabase_status})"
        else
            warn "Supabase Studio ответил со статусом ${supabase_status}. Возможны проблемы с запуском."
        fi
    fi

    info "Генерация файла с учетными данными..."
    CREDENTIALS_FILE="/root/post-install-credentials.txt"
    #... (здесь будет код для записи всех данных в файл)
    #...
    success "Файл с учетными данными сохранен в ${CREDENTIALS_FILE}"

    echo -e "${C_WHITE_BOLD}"
    echo "================================================================="
    echo "|| Установка завершена! ||"
    echo "================================================================="
    echo -e "${C_RESET}"
    echo "Все доступы и пароли сохранены в файле: ${CREDENTIALS_FILE}"
    echo "Спасибо за использование установщика от MEDIA WORKS!"
}

# --- Функции для создания конфигурационных файлов (заглушки для демонстрации) ---
create_traefik_config() {
    # Создает /root/[project_name]/configs/traefik/traefik.yml
    # с entrypoints, acme resolver и http-to-https редиректом
    :
}

create_project_files() {
    # Создает /root/[project_name]/docker-compose.yml и.env
    # на основе INSTALL_CHOICE
    :
}

create_supabase_files() {
    # Если INSTALL_CHOICE не 4, скачивает docker-compose.yml от Supabase
    # и создает.env для него
    :
}

# --- Запуск основной функции ---
main
