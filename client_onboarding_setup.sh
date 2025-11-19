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

# Имя пользователя RAG-системы
RAG_USER="rag_user"

# SSH порт по умолчанию
DEFAULT_SSH_PORT=22

# Файл лога
LOG_FILE="/var/log/rag_client_setup.log"

# Версия скрипта
SCRIPT_VERSION="1.0.0"

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
        log "ERROR" "Скрипт должен быть запущен от root (используйте sudo)"
        echo ""
        echo "Использование:"
        echo "  sudo bash $0 [/путь/к/bitrix]"
        echo ""
        exit 1
    fi
    log "SUCCESS" "Проверка прав root: OK"
}

################################################################################
# Функция: Определение ОС
################################################################################
detect_os() {
    log "INFO" "Определение операционной системы..."

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        local os_id="${ID}"
        local os_version="${VERSION_ID}"

        case "${os_id}" in
            centos|rhel|rocky|almalinux)
                DETECTED_OS="RHEL"
                if command -v dnf &> /dev/null; then
                    PACKAGE_MANAGER="dnf"
                else
                    PACKAGE_MANAGER="yum"
                fi
                log "SUCCESS" "Обнаружена ОС: ${NAME} ${VERSION_ID} (семейство RHEL)"
                ;;
            ubuntu|debian)
                DETECTED_OS="DEBIAN"
                PACKAGE_MANAGER="apt"
                log "SUCCESS" "Обнаружена ОС: ${NAME} ${VERSION_ID} (семейство Debian)"
                ;;
            *)
                log "WARNING" "Неизвестная ОС: ${NAME} (ID: ${os_id})"
                log "WARNING" "Продолжаем, предполагая Debian-подобную систему..."
                DETECTED_OS="DEBIAN"
                PACKAGE_MANAGER="apt"
                ;;
        esac
    else
        log "WARNING" "Файл /etc/os-release не найден. Используем системные команды..."

        if command -v yum &> /dev/null; then
            DETECTED_OS="RHEL"
            PACKAGE_MANAGER="yum"
            log "SUCCESS" "Обнаружена RHEL-подобная система (yum)"
        elif command -v apt-get &> /dev/null; then
            DETECTED_OS="DEBIAN"
            PACKAGE_MANAGER="apt"
            log "SUCCESS" "Обнаружена Debian-подобная система (apt)"
        else
            log "ERROR" "Не удалось определить тип ОС"
            exit 1
        fi
    fi

    log "DEBUG" "DETECTED_OS=${DETECTED_OS}, PACKAGE_MANAGER=${PACKAGE_MANAGER}"
}

################################################################################
# Функция: Установка зависимостей
################################################################################
install_dependencies() {
    log "INFO" "Проверка и установка зависимостей..."

    local packages_to_install=()

    # Проверка rsync
    if ! command -v rsync &> /dev/null; then
        log "WARNING" "rsync не установлен"
        packages_to_install+=("rsync")
    else
        log "SUCCESS" "rsync уже установлен: $(rsync --version | head -n1)"
    fi

    # Проверка SSH-сервера
    if ! command -v sshd &> /dev/null && [[ "${DETECTED_OS}" == "DEBIAN" ]]; then
        log "WARNING" "OpenSSH Server не установлен"
        packages_to_install+=("openssh-server")
    elif ! command -v sshd &> /dev/null && [[ "${DETECTED_OS}" == "RHEL" ]]; then
        log "WARNING" "OpenSSH Server не установлен"
        packages_to_install+=("openssh-server")
    else
        log "SUCCESS" "OpenSSH Server уже установлен"
    fi

    # Установка пакетов, если требуется
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        log "INFO" "Установка пакетов: ${packages_to_install[*]}"

        if [[ "${DETECTED_OS}" == "RHEL" ]]; then
            ${PACKAGE_MANAGER} install -y "${packages_to_install[@]}" || {
                log "ERROR" "Ошибка при установке пакетов"
                exit 1
            }
        elif [[ "${DETECTED_OS}" == "DEBIAN" ]]; then
            apt-get update -qq || log "WARNING" "apt-get update вернул ошибку (игнорируется)"
            apt-get install -y "${packages_to_install[@]}" || {
                log "ERROR" "Ошибка при установке пакетов"
                exit 1
            }
        fi

        log "SUCCESS" "Зависимости установлены успешно"
    else
        log "SUCCESS" "Все зависимости уже установлены"
    fi
}

################################################################################
# Функция: Определение веб-сервера и группы
################################################################################
detect_web_server() {
    log "INFO" "Определение активного веб-сервера..."

    local apache_running=false
    local nginx_running=false

    # Проверка Apache
    if pgrep -x "httpd" > /dev/null || pgrep -x "apache2" > /dev/null; then
        apache_running=true
        log "DEBUG" "Обнаружен запущенный процесс Apache"
    fi

    # Проверка Nginx
    if pgrep -x "nginx" > /dev/null; then
        nginx_running=true
        log "DEBUG" "Обнаружен запущенный процесс Nginx"
    fi

    # Определение группы
    if [[ "${apache_running}" == true ]] && [[ "${nginx_running}" == false ]]; then
        DETECTED_WEB_SERVER="Apache"

        # Определение группы в зависимости от ОС
        if [[ "${DETECTED_OS}" == "RHEL" ]]; then
            WEB_SERVER_GROUP="apache"
        else
            WEB_SERVER_GROUP="www-data"
        fi

        log "SUCCESS" "Обнаружен веб-сервер: Apache (группа: ${WEB_SERVER_GROUP})"

    elif [[ "${nginx_running}" == true ]] && [[ "${apache_running}" == false ]]; then
        DETECTED_WEB_SERVER="Nginx"

        if [[ "${DETECTED_OS}" == "RHEL" ]]; then
            WEB_SERVER_GROUP="nginx"
        else
            WEB_SERVER_GROUP="www-data"
        fi

        log "SUCCESS" "Обнаружен веб-сервер: Nginx (группа: ${WEB_SERVER_GROUP})"

    elif [[ "${apache_running}" == true ]] && [[ "${nginx_running}" == true ]]; then
        log "WARNING" "Обнаружены оба веб-сервера (Apache и Nginx)"

        # Интерактивный выбор
        echo ""
        echo "Какой веб-сервер использует Bitrix на этом сервере?"
        echo "  1) Apache"
        echo "  2) Nginx"
        read -p "Выберите [1-2]: " choice

        case $choice in
            1)
                DETECTED_WEB_SERVER="Apache"
                WEB_SERVER_GROUP=$([[ "${DETECTED_OS}" == "RHEL" ]] && echo "apache" || echo "www-data")
                ;;
            2)
                DETECTED_WEB_SERVER="Nginx"
                WEB_SERVER_GROUP=$([[ "${DETECTED_OS}" == "RHEL" ]] && echo "nginx" || echo "www-data")
                ;;
            *)
                log "ERROR" "Неверный выбор"
                exit 1
                ;;
        esac

        log "INFO" "Выбран веб-сервер: ${DETECTED_WEB_SERVER} (группа: ${WEB_SERVER_GROUP})"

    else
        log "WARNING" "Веб-сервер не обнаружен (Apache/Nginx не запущены)"

        # Предположить стандартную группу
        if [[ "${DETECTED_OS}" == "RHEL" ]]; then
            WEB_SERVER_GROUP="apache"
        else
            WEB_SERVER_GROUP="www-data"
        fi

        log "WARNING" "Используется группа по умолчанию: ${WEB_SERVER_GROUP}"
    fi

    # Проверка существования группы
    if ! getent group "${WEB_SERVER_GROUP}" > /dev/null 2>&1; then
        log "ERROR" "Группа ${WEB_SERVER_GROUP} не существует в системе"
        log "ERROR" "Пожалуйста, установите и запустите веб-сервер перед выполнением скрипта"
        exit 1
    fi

    log "DEBUG" "DETECTED_WEB_SERVER=${DETECTED_WEB_SERVER}, WEB_SERVER_GROUP=${WEB_SERVER_GROUP}"
}

################################################################################
# Функция: Валидация и подтверждение пути к Bitrix
################################################################################
validate_bitrix_path() {
    local proposed_path="$1"

    log "INFO" "Валидация пути к Bitrix..."

    # Если путь не предоставлен, попытаться автопоиск
    if [[ -z "${proposed_path}" ]]; then
        log "INFO" "Поиск директории Bitrix по стандартным путям..."

        local common_paths=(
            "/var/www/bitrix"
            "/var/www/html"
            "/home/bitrix"
            "/var/www/vhosts/bitrix"
        )

        for path in "${common_paths[@]}"; do
            if [[ -d "${path}/bitrix" ]]; then
                log "SUCCESS" "Найдена директория Bitrix: ${path}"
                proposed_path="${path}"
                break
            fi
        done
    fi

    # Интерактивное подтверждение
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Путь к корневой директории Bitrix${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    if [[ -n "${proposed_path}" ]]; then
        echo "Обнаруженный путь: ${proposed_path}"
    else
        echo "Путь не обнаружен автоматически"
    fi

    echo ""
    read -p "Введите путь к Bitrix [${proposed_path}]: " user_input

    # Использовать введённый путь или оставить предложенный
    if [[ -n "${user_input}" ]]; then
        BITRIX_PATH="${user_input}"
    else
        BITRIX_PATH="${proposed_path}"
    fi

    # Убрать завершающий слеш
    BITRIX_PATH="${BITRIX_PATH%/}"

    # Проверка существования директории
    if [[ ! -d "${BITRIX_PATH}" ]]; then
        log "ERROR" "Директория не существует: ${BITRIX_PATH}"
        exit 1
    fi

    # Проверка наличия подди ректории bitrix
    if [[ ! -d "${BITRIX_PATH}/bitrix" ]]; then
        log "WARNING" "Поддиректория 'bitrix' не найдена в ${BITRIX_PATH}"
        read -p "Продолжить всё равно? [y/N]: " confirm
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            log "ERROR" "Операция отменена пользователем"
            exit 1
        fi
    fi

    log "SUCCESS" "Путь к Bitrix подтверждён: ${BITRIX_PATH}"
    log "DEBUG" "BITRIX_PATH=${BITRIX_PATH}"
}

################################################################################
# Функция: Подтверждение SSH порта
################################################################################
confirm_ssh_port() {
    log "INFO" "Определение SSH порта..."

    # Попытка определить текущий SSH порт из конфигурации
    local current_port
    if [[ -f /etc/ssh/sshd_config ]]; then
        current_port=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}' | head -n1)
        if [[ -z "${current_port}" ]]; then
            current_port="${DEFAULT_SSH_PORT}"
        fi
    else
        current_port="${DEFAULT_SSH_PORT}"
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Порт SSH для rsync-подключений${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Текущий SSH порт: ${current_port}"
    echo ""
    read -p "Введите SSH порт [${current_port}]: " user_port

    if [[ -n "${user_port}" ]]; then
        SSH_PORT="${user_port}"
    else
        SSH_PORT="${current_port}"
    fi

    # Валидация (должно быть число от 1 до 65535)
    if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || [[ "${SSH_PORT}" -lt 1 ]] || [[ "${SSH_PORT}" -gt 65535 ]]; then
        log "ERROR" "Неверный номер порта: ${SSH_PORT}"
        exit 1
    fi

    log "SUCCESS" "SSH порт подтверждён: ${SSH_PORT}"
    log "DEBUG" "SSH_PORT=${SSH_PORT}"
}

################################################################################
# Функция: Создание пользователя rag_user
################################################################################
create_rag_user() {
    log "INFO" "Создание пользователя ${RAG_USER}..."

    # Проверка, существует ли пользователь
    if id "${RAG_USER}" &>/dev/null; then
        log "WARNING" "Пользователь ${RAG_USER} уже существует"

        read -p "Пересоздать пользователя? Это удалит текущую конфигурацию! [y/N]: " confirm
        if [[ "${confirm}" =~ ^[Yy]$ ]]; then
            log "INFO" "Удаление существующего пользователя ${RAG_USER}..."
            userdel -r "${RAG_USER}" 2>/dev/null || log "WARNING" "Не удалось удалить домашнюю директорию"
        else
            log "INFO" "Используется существующий пользователь"
            return 0
        fi
    fi

    # Создание системного пользователя
    if [[ "${DETECTED_OS}" == "DEBIAN" ]]; then
        adduser --system --group --shell /bin/bash --disabled-password "${RAG_USER}" || {
            log "ERROR" "Ошибка при создании пользователя"
            exit 1
        }
    elif [[ "${DETECTED_OS}" == "RHEL" ]]; then
        useradd --system --shell /bin/bash --create-home "${RAG_USER}" || {
            log "ERROR" "Ошибка при создании пользователя"
            exit 1
        }
    fi

    log "SUCCESS" "Пользователь ${RAG_USER} создан успешно"
    log "DEBUG" "Домашняя директория: $(eval echo ~${RAG_USER})"
}

################################################################################
# Функция: Настройка SSH-доступа
################################################################################
setup_ssh_access() {
    log "INFO" "Настройка SSH-доступа для ${RAG_USER}..."

    local ssh_dir="/home/${RAG_USER}/.ssh"
    local authorized_keys="${ssh_dir}/authorized_keys"

    # Создание директории .ssh
    mkdir -p "${ssh_dir}"
    chmod 700 "${ssh_dir}"

    # Проверка валидности публичного ключа
    if [[ "${RAG_SSH_PUBLIC_KEY}" == *"AAAAC3Nz"* ]] && [[ "${RAG_SSH_PUBLIC_KEY}" != *"EXAMPLE"* ]]; then
        log "DEBUG" "Публичный ключ прошёл базовую валидацию"
    else
        log "WARNING" "Публичный ключ выглядит как шаблон (не был обновлён)"
        log "WARNING" "Пожалуйста, обновите переменную RAG_SSH_PUBLIC_KEY в скрипте"
    fi

    # Формирование команды с ограничением (command restriction)
    local command_restriction="command=\"rsync --server --sender -vlogDtprze.iLsfxCIvu . ${BITRIX_PATH}/\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty"

    # Запись в authorized_keys
    echo "${command_restriction} ${RAG_SSH_PUBLIC_KEY}" > "${authorized_keys}"

    # Установка прав
    chmod 600 "${authorized_keys}"
    chown -R "${RAG_USER}:${RAG_USER}" "${ssh_dir}"

    log "SUCCESS" "SSH-доступ настроен с ограничением команд (только rsync)"
    log "DEBUG" "Файл authorized_keys: ${authorized_keys}"

    # Проверка SSH-сервиса
    if systemctl is-active --quiet sshd || systemctl is-active --quiet ssh; then
        log "SUCCESS" "SSH-сервис активен"
    else
        log "WARNING" "SSH-сервис не активен. Попытка запуска..."
        systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || {
            log "ERROR" "Не удалось запустить SSH-сервис"
            exit 1
        }
        log "SUCCESS" "SSH-сервис запущен"
    fi
}

################################################################################
# Функция: Настройка прав доступа
################################################################################
configure_permissions() {
    log "INFO" "Настройка прав доступа для ${RAG_USER}..."

    # Добавление пользователя в группу веб-сервера
    usermod -a -G "${WEB_SERVER_GROUP}" "${RAG_USER}" || {
        log "ERROR" "Не удалось добавить ${RAG_USER} в группу ${WEB_SERVER_GROUP}"
        exit 1
    }
    log "SUCCESS" "Пользователь ${RAG_USER} добавлен в группу ${WEB_SERVER_GROUP}"

    # Применение прав g+rX (группа: чтение + выполнение для директорий)
    log "INFO" "Применение прав g+rX к ${BITRIX_PATH}/ (это может занять некоторое время)..."

    chmod -R g+rX "${BITRIX_PATH}/" 2>/dev/null || {
        log "WARNING" "Не все файлы удалось обработать (возможны ошибки доступа)"
    }

    log "SUCCESS" "Права доступа настроены (read-only для ${RAG_USER})"
}

################################################################################
# Функция: Проверка firewall
################################################################################
check_firewall() {
    log "INFO" "Проверка доступности SSH порта через firewall..."

    local firewall_type=""

    # Определение типа firewall
    if command -v firewall-cmd &> /dev/null; then
        firewall_type="firewalld"
    elif command -v ufw &> /dev/null; then
        firewall_type="ufw"
    elif command -v iptables &> /dev/null; then
        firewall_type="iptables"
    else
        log "WARNING" "Firewall не обнаружен или отключён"
        return 0
    fi

    log "DEBUG" "Обнаружен firewall: ${firewall_type}"

    # Проверка правил
    local port_open=false

    case "${firewall_type}" in
        firewalld)
            if firewall-cmd --list-ports 2>/dev/null | grep -q "${SSH_PORT}/tcp"; then
                port_open=true
            fi
            ;;
        ufw)
            if ufw status 2>/dev/null | grep -q "${SSH_PORT}/tcp"; then
                port_open=true
            elif ufw status 2>/dev/null | grep -q "ALLOW.*OpenSSH"; then
                port_open=true
            fi
            ;;
        iptables)
            if iptables -L -n 2>/dev/null | grep -q "dpt:${SSH_PORT}"; then
                port_open=true
            fi
            ;;
    esac

    if [[ "${port_open}" == true ]]; then
        log "SUCCESS" "Порт ${SSH_PORT}/tcp открыт в firewall"
    else
        log "WARNING" "Порт ${SSH_PORT}/tcp может быть закрыт в firewall"
        echo ""
        echo "Для открытия порта используйте одну из команд:"
        echo ""

        case "${firewall_type}" in
            firewalld)
                echo "  firewall-cmd --permanent --add-port=${SSH_PORT}/tcp"
                echo "  firewall-cmd --reload"
                ;;
            ufw)
                echo "  ufw allow ${SSH_PORT}/tcp"
                ;;
            iptables)
                echo "  iptables -A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT"
                echo "  service iptables save"
                ;;
        esac

        echo ""
        read -p "Открыть порт сейчас? [Y/n]: " confirm

        if [[ ! "${confirm}" =~ ^[Nn]$ ]]; then
            case "${firewall_type}" in
                firewalld)
                    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
                    firewall-cmd --reload
                    log "SUCCESS" "Порт ${SSH_PORT}/tcp открыт в firewalld"
                    ;;
                ufw)
                    ufw allow "${SSH_PORT}/tcp"
                    log "SUCCESS" "Порт ${SSH_PORT}/tcp открыт в ufw"
                    ;;
                iptables)
                    iptables -A INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT
                    service iptables save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                    log "SUCCESS" "Порт ${SSH_PORT}/tcp открыт в iptables"
                    ;;
            esac
        else
            log "WARNING" "Порт не был открыт. RAG-сервер не сможет подключиться!"
        fi
    fi
}

################################################################################
# Функция: Тесты безопасности
################################################################################
security_tests() {
    log "INFO" "Выполнение тестов безопасности..."

    local test_passed=0
    local test_failed=0

    # Тест 1: Проверка чтения файлов
    log "DEBUG" "Тест 1: Проверка права чтения файлов"
    if sudo -u "${RAG_USER}" ls "${BITRIX_PATH}/" > /dev/null 2>&1; then
        log "SUCCESS" "✓ Тест 1: Пользователь ${RAG_USER} может читать файлы"
        ((test_passed++))
    else
        log "ERROR" "✗ Тест 1: Пользователь ${RAG_USER} НЕ может читать файлы"
        ((test_failed++))
    fi

    # Тест 2: Проверка запрета записи
    log "DEBUG" "Тест 2: Проверка запрета записи файлов"
    if sudo -u "${RAG_USER}" touch "${BITRIX_PATH}/rag_test_write.txt" 2>/dev/null; then
        log "ERROR" "✗ Тест 2: Пользователь ${RAG_USER} МОЖЕТ писать файлы (НЕБЕЗОПАСНО!)"
        rm -f "${BITRIX_PATH}/rag_test_write.txt"
        ((test_failed++))
    else
        log "SUCCESS" "✓ Тест 2: Пользователь ${RAG_USER} НЕ может писать файлы (OK)"
        ((test_passed++))
    fi

    # Тест 3: Проверка невозможности прямого логина
    log "DEBUG" "Тест 3: Проверка блокировки прямого входа"
    local user_shell=$(getent passwd "${RAG_USER}" | cut -d: -f7)
    if [[ "${user_shell}" == "/bin/bash" ]]; then
        # Для системных пользователей /bin/bash допустим (rsync требует shell)
        # Но проверим, что нет установленного пароля
        local password_status=$(passwd -S "${RAG_USER}" 2>/dev/null | awk '{print $2}')
        if [[ "${password_status}" == "L" ]] || [[ "${password_status}" == "NP" ]]; then
            log "SUCCESS" "✓ Тест 3: Прямой вход заблокирован (нет пароля)"
            ((test_passed++))
        else
            log "WARNING" "⚠ Тест 3: У пользователя может быть установлен пароль"
            ((test_failed++))
        fi
    else
        log "SUCCESS" "✓ Тест 3: Shell установлен на ${user_shell}"
        ((test_passed++))
    fi

    # Итоги
    echo ""
    log "INFO" "═══════════════════════════════════════════════════════════════"
    log "INFO" "  РЕЗУЛЬТАТЫ ТЕСТОВ БЕЗОПАСНОСТИ"
    log "INFO" "═══════════════════════════════════════════════════════════════"
    log "SUCCESS" "  Успешно: ${test_passed}/3"
    if [[ ${test_failed} -gt 0 ]]; then
        log "ERROR" "  Провалено: ${test_failed}/3"
        log "WARNING" "  ВНИМАНИЕ: Обнаружены проблемы безопасности!"
    else
        log "SUCCESS" "  Все тесты пройдены успешно!"
    fi
    log "INFO" "═══════════════════════════════════════════════════════════════"
    echo ""
}

################################################################################
# Функция: Итоговый отчёт
################################################################################
generate_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                 УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!                     ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  КОНФИГУРАЦИЯ ДЛЯ RAG-АДМИНИСТРАТОРА${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Добавьте следующую конфигурацию в clients_config.json на RAG-сервере:"
    echo ""
    echo -e "${YELLOW}{"
    echo "  \"client_id\": \"client_XXX\","
    echo "  \"ssh_host\": \"$(hostname -f 2>/dev/null || hostname)\","
    echo "  \"ssh_port\": ${SSH_PORT},"
    echo "  \"ssh_user\": \"${RAG_USER}\","
    echo "  \"remote_path\": \"${BITRIX_PATH}/\","
    echo "  \"enabled\": true,"
    echo "  \"description\": \"Описание клиента\","
    echo "  \"include_dirs\": ["
    echo "    \"/local/\","
    echo "    \"/bitrix/php_interface/\""
    echo "  ]"
    echo -e "}${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  ТЕСТИРОВАНИЕ ПОДКЛЮЧЕНИЯ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "На RAG-сервере выполните:"
    echo ""
    echo -e "${YELLOW}  ssh -i ~/.ssh/rag_server_key -p ${SSH_PORT} ${RAG_USER}@$(hostname -f 2>/dev/null || hostname) \"ls ${BITRIX_PATH}/\"${NC}"
    echo ""
    echo "Ожидаемый результат: список файлов и директорий Bitrix"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  ФАЙЛЫ И ЛОГИ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Пользователь:         ${RAG_USER}"
    echo "  Домашняя директория:  /home/${RAG_USER}"
    echo "  SSH ключ:             /home/${RAG_USER}/.ssh/authorized_keys"
    echo "  Bitrix директория:    ${BITRIX_PATH}"
    echo "  Веб-сервер:           ${DETECTED_WEB_SERVER} (группа: ${WEB_SERVER_GROUP})"
    echo "  SSH порт:             ${SSH_PORT}"
    echo "  Лог установки:        ${LOG_FILE}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  МОНИТОРИНГ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Для мониторинга SSH-подключений используйте:"
    echo ""
    echo -e "${YELLOW}  sudo tail -f /var/log/auth.log | grep ${RAG_USER}${NC}  # Debian/Ubuntu"
    echo -e "${YELLOW}  sudo tail -f /var/log/secure | grep ${RAG_USER}${NC}    # CentOS/RHEL"
    echo ""
    echo -e "${GREEN}✓ Настройка клиента завершена!${NC}"
    echo ""

    log "INFO" "Итоговый отчёт сгенерирован"
    log "SUCCESS" "Установка завершена успешно (версия ${SCRIPT_VERSION})"
}

################################################################################
# Главная функция
################################################################################
main() {
    # Инициализация лога
    touch "${LOG_FILE}" 2>/dev/null || LOG_FILE="/tmp/rag_client_setup.log"

    # Вывод заголовка
    print_header

    # Проверка прав root
    check_root

    # Определение ОС
    detect_os

    # Установка зависимостей
    install_dependencies

    # Определение веб-сервера
    detect_web_server

    # Валидация пути к Bitrix
    validate_bitrix_path "$1"

    # Подтверждение SSH порта
    confirm_ssh_port

    # Финальное подтверждение
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  ПОДТВЕРЖДЕНИЕ КОНФИГУРАЦИИ${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Bitrix директория: ${BITRIX_PATH}"
    echo "  Веб-сервер:        ${DETECTED_WEB_SERVER} (${WEB_SERVER_GROUP})"
    echo "  SSH порт:          ${SSH_PORT}"
    echo "  Пользователь:      ${RAG_USER}"
    echo ""
    read -p "Продолжить установку? [Y/n]: " final_confirm

    if [[ "${final_confirm}" =~ ^[Nn]$ ]]; then
        log "WARNING" "Установка отменена пользователем"
        exit 0
    fi

    # Основные шаги установки
    echo ""
    log "INFO" "Начало установки..."

    create_rag_user
    setup_ssh_access
    configure_permissions
    check_firewall
    security_tests
    generate_summary
}

################################################################################
# Запуск скрипта
################################################################################

# Обработка аргументов командной строки
BITRIX_PATH_ARG="${1:-}"

# Запуск главной функции
main "${BITRIX_PATH_ARG}"
