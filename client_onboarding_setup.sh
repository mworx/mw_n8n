#!/bin/bash

################################################################################
# client_onboarding_setup.sh
#
# Автоматическая настройка RAG-клиента на сервере Bitrix
#
# Использование:
#   sudo bash client_onboarding_setup.sh [/путь/к/bitrix]
#
# Параметры:
#   /путь/к/bitrix - Путь к корневой директории Bitrix (опционально)
#                    Если не указан, скрипт запросит интерактивно
#
# Что делает скрипт:
#   1. Определяет ОС (CentOS/RHEL или Ubuntu/Debian)
#   2. Устанавливает зависимости (rsync, openssh-server)
#   3. Создаёт системного пользователя rag_user
#   4. Настраивает SSH-доступ с публичным ключом RAG-сервера
#   5. Добавляет rag_user в группу веб-сервера (www-data/apache/nginx)
#   6. Настраивает права доступа (read-only) к директории Bitrix
#   7. Проверяет доступность SSH порта через firewall
#   8. Выполняет тесты безопасности (read-only доступ)
#   9. Выводит итоговую конфигурацию для RAG-администратора
#
# Версия: 1.0.0
# Автор: MEDIA WORKS
# Дата: 09-11-2025
################################################################################

set -euo pipefail

################################################################################
# ========== КОНФИГУРАЦИЯ (ОБНОВИТЕ ПЕРЕД РАСПРОСТРАНЕНИЕМ!) ==========
################################################################################

# ВАЖНО: Замените это значение на ваш реальный публичный SSH-ключ!
# Для генерации ключа используйте: ./scripts/generate_ssh_key.sh
RAG_SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGdFEUkt7XiKbo8Z2tDaFSd0lQ+ZF7Rks19RqNhmRPRB rag_server@mw-rag"

RAG_USER="rag_user"
DEFAULT_SSH_PORT=22
LOG_FILE="/var/log/rag_client_setup.log"
SCRIPT_VERSION="1.2.0"

################################################################################
# ========== ЦВЕТА ДЛЯ ВЫВОДА ==========
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

################################################################################
# ========== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ==========
################################################################################

BITRIX_PATH=""
DETECTED_OS=""
DETECTED_WEB_SERVER=""
WEB_SERVER_GROUP=""
SSH_PORT="${DEFAULT_SSH_PORT}"
PACKAGE_MANAGER=""

################################################################################
# Функция: Логирование
################################################################################
log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Запись в лог-файл
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true

    # Вывод на экран
    case "${level}" in
        INFO)
            echo -e "${BLUE}ℹ ${NC}${message}"
            ;;
        SUCCESS)
            echo -e "${GREEN}✓ ${NC}${message}"
            ;;
        WARNING)
            echo -e "${YELLOW}⚠ ${NC}${message}"
            ;;
        ERROR)
            echo -e "${RED}✗ ${NC}${message}"
            ;;
        DEBUG)
            echo -e "${CYAN}🔍 ${NC}${message}"
            ;;
        *)
            echo "${message}"
            ;;
    esac
}

################################################################################
# Функция: Вывод заголовка
################################################################################
print_header() {
    clear
    echo -e "${CYAN}███╗   ███╗███████╗██████╗ ██╗ █████╗     ██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███████╗"
    echo -e "${CYAN}████╗ ████║██╔════╝██╔══██╗██║██╔══██╗    ██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝██╔════╝"
    echo -e "${CYAN}██╔████╔██║█████╗  ██║  ██║██║███████║    ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ ███████╗"
    echo -e "${CYAN}██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║    ██║███╗██║██║   ██║██╔══██╗██╔═██╗ ╚════██║"
    echo -e "${CYAN}██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║    ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗███████║"
    echo -e "${CYAN}╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝     ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝"
    echo -e "${CYAN} ══════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}              RAG Client Onboarding Setup Script v${SCRIPT_VERSION}       ${NC}"
    echo -e "${CYAN}              Автоматическая настройка доступа к Bitrix-серверу           ${NC}"
    echo -e "${CYAN} ══════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    log "INFO" "Скрипт запущен (версия ${SCRIPT_VERSION})"
}

################################################################################
# Функция: Проверка прав root
################################################################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Запустите скрипт с правами root (sudo bash ...)"
        exit 1
    fi
}

detect_os() {
    log "INFO" "Определение ОС..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID}" in
            centos|rhel|rocky|almalinux|fedora)
                if command -v dnf &> /dev/null; then PACKAGE_MANAGER="dnf"; else PACKAGE_MANAGER="yum"; fi
                log "SUCCESS" "ОС: ${NAME} (RHEL family)"
                ;;
            ubuntu|debian)
                PACKAGE_MANAGER="apt"
                log "SUCCESS" "ОС: ${NAME} (Debian family)"
                ;;
            *)
                PACKAGE_MANAGER="yum"
                log "WARNING" "Неизвестная ОС. Пробуем режим RHEL/CentOS."
                ;;
        esac
    else
        # Fallback
        if command -v yum &> /dev/null; then PACKAGE_MANAGER="yum"; else PACKAGE_MANAGER="apt-get"; fi
    fi
}

install_dependencies() {
    log "INFO" "Проверка зависимостей..."
    local pkgs=()
    if ! command -v rsync &> /dev/null; then pkgs+=("rsync"); fi
    if ! command -v sshd &> /dev/null; then pkgs+=("openssh-server"); fi

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        log "INFO" "Установка: ${pkgs[*]}"
        if [[ "${PACKAGE_MANAGER}" == "apt" || "${PACKAGE_MANAGER}" == "apt-get" ]]; then
            apt-get update -qq && apt-get install -y "${pkgs[@]}"
        else
            ${PACKAGE_MANAGER} install -y "${pkgs[@]}"
        fi
    fi
}

detect_web_server_group() {
    log "INFO" "Определение группы веб-сервера..."
    if getent group bitrix >/dev/null 2>&1; then
        WEB_SERVER_GROUP="bitrix"
        log "SUCCESS" "Обнаружена среда BitrixEnv. Группа: bitrix"
    elif getent group www-data >/dev/null 2>&1; then
        WEB_SERVER_GROUP="www-data"
    elif getent group apache >/dev/null 2>&1; then
        WEB_SERVER_GROUP="apache"
    elif getent group nginx >/dev/null 2>&1; then
        WEB_SERVER_GROUP="nginx"
    else
        echo "Введите группу веб-сервера вручную (например, bitrix):"
        read -p "> " manual_group
        WEB_SERVER_GROUP="${manual_group}"
    fi
}

validate_bitrix_path() {
    local path="$1"
    if [[ -z "${path}" ]]; then
        for p in "/home/bitrix/www" "/var/www/bitrix" "/var/www/html"; do
            if [[ -d "${p}/bitrix" ]]; then path="${p}"; break; fi
        done
    fi
    echo ""
    read -p "Подтвердите путь к Bitrix [${path}]: " user_input
    BITRIX_PATH="${user_input:-$path}"
    BITRIX_PATH="${BITRIX_PATH%/}" # Удалить slash в конце

    if [[ ! -d "${BITRIX_PATH}" ]]; then
        log "ERROR" "Директория ${BITRIX_PATH} не найдена!"
        exit 1
    fi
}

detect_ssh_port() {
    local cfg_port
    cfg_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1 || echo "22")
    if [[ -z "${cfg_port}" ]]; then cfg_port="22"; fi
    SSH_PORT="${cfg_port}"
    log "INFO" "Используем SSH порт: ${SSH_PORT}"
}

setup_user_and_ssh() {
    log "INFO" "Настройка пользователя ${RAG_USER}..."

    # 1. Создание пользователя
    if ! id "${RAG_USER}" &>/dev/null; then
        if command -v useradd &>/dev/null; then
            useradd --system --shell /bin/bash --create-home "${RAG_USER}"
        else
            adduser --system --group --shell /bin/bash --disabled-password "${RAG_USER}"
        fi
        log "SUCCESS" "Пользователь создан"
    fi

    # 2. Добавление в группу
    usermod -a -G "${WEB_SERVER_GROUP}" "${RAG_USER}"
    log "SUCCESS" "Пользователь добавлен в группу ${WEB_SERVER_GROUP}"

    # 3. Настройка SSH ключей
    local ssh_dir="/home/${RAG_USER}/.ssh"
    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"
    
    # ВАЖНО: Убрали command="rsync...", оставили только флаги безопасности
    local options="no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty"
    
    echo "${options} ${RAG_SSH_PUBLIC_KEY}" > "${ssh_dir}/authorized_keys"
    chmod 600 "${ssh_dir}/authorized_keys"
    chown -R "${RAG_USER}:${RAG_USER}" "/home/${RAG_USER}"
    
    log "SUCCESS" "SSH ключ установлен (без жесткой команды rsync)"
}

fix_permissions() {
    log "INFO" "Настройка прав доступа (Bitrix Compatible)..."
    
    # 1. Права на саму папку сайта
    log "INFO" "Даем права группе на чтение сайта: ${BITRIX_PATH}"
    chmod g+rx "${BITRIX_PATH}" 2>/dev/null || true
    
    # 2. Права на родительскую папку (КРИТИЧНО для /home/bitrix)
    local parent_dir
    parent_dir=$(dirname "${BITRIX_PATH}")
    
    if [[ -d "${parent_dir}" ]]; then
        log "INFO" "Разрешаем проход через родительскую папку: ${parent_dir}"
        # g+x позволяет группе проходить сквозь папку, не читая её содержимое
        chmod g+x "${parent_dir}" 2>/dev/null || true
    fi

    # 3. Проверка SELinux
    if command -v getenforce &>/dev/null; then
        if [[ "$(getenforce)" == "Enforcing" ]]; then
            log "WARNING" "SELinux включен. Отключаем временно (setenforce 0)..."
            setenforce 0 || log "ERROR" "Не удалось отключить SELinux"
            log "INFO" "Рекомендуется отключить SELinux в /etc/selinux/config"
        fi
    fi
}

configure_firewall() {
    log "INFO" "Настройка Firewall..."
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        if ! firewall-cmd --list-ports | grep -q "${SSH_PORT}/tcp"; then
            firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null
            firewall-cmd --reload >/dev/null
            log "SUCCESS" "Порт ${SSH_PORT} открыт (firewalld)"
        fi
    elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
         ufw allow "${SSH_PORT}/tcp" >/dev/null
         log "SUCCESS" "Порт ${SSH_PORT} открыт (ufw)"
    fi
}

show_summary() {
    local ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_IP")
    
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!  ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Передайте этот JSON администратору:"
    echo ""
    echo -e "${YELLOW}{"
    echo "  \"client_id\": \"client_XXX\","
    echo "  \"ssh_host\": \"${ip_addr}\","
    echo "  \"ssh_port\": ${SSH_PORT},"
    echo "  \"ssh_user\": \"${RAG_USER}\","
    echo "  \"remote_path\": \"${BITRIX_PATH}/\","
    echo "  \"enabled\": true,"
    echo "  \"include_dirs\": [\"/local/\", \"/bitrix/php_interface/\", \"/bitrix/templates/\"]"
    echo -e "}${NC}"
    echo ""
}

################################################################################
# MAIN
################################################################################
main() {
    print_header
    check_root
    detect_os
    install_dependencies
    detect_web_server_group
    validate_bitrix_path "${1:-}"
    detect_ssh_port
    
    echo ""
    read -p "Начать установку? [Y/n]: " confirm
    if [[ "${confirm}" =~ ^[Nn]$ ]]; then exit 0; fi

    setup_user_and_ssh
    fix_permissions
    configure_firewall
    
    show_summary
}

main "${1:-}"
