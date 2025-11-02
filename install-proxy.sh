#!/bin/bash

# ==============================================================================
# Установщик MEDIA WORKS для Claude Code и Proxy (v4)
# Поддержка: Ubuntu, Debian, Astra Linux, CentOS
#
# Логика:
# - Определяет CentOS 7.
# - На CentOS 7 отключает несовместимый метод Node.js (Вариант 3).
# - Варианты 3 и 4 сначала устанавливают proxychains, а затем
#   запускают установку Claude/Node через него.
# ==============================================================================

# --- Цвета для вывода ---
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_NC='\033[0m' # No Color

# --- Глобальные переменные ---
PKG_MANAGER=""
OS_TYPE=""
IS_CENTOS7=false # Флаг для несовместимой ОС
PROXY_IP="" # Будет запрошен у пользователя
PROXY_USER="proxyuser" # Фиксированный пользователь
PROXYCHAINS_CONF_FILE="" # Путь к конфигу

# ==============================================================================
# ФУНКЦИИ
# ==============================================================================

# --- Отображение логотипа ---
fn_show_logo() {
    clear
    echo -e "${C_CYAN}"
    echo "  ███╗   ███╗███████╗██████╗ ██╗ █████╗     ██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗███████╗"
    echo "  ████╗ ████║██╔════╝██╔══██╗██║██╔══██╗    ██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝██╔════╝"
    echo "  ██╔████╔██║█████╗  ██║  ██║██║███████║    ██║ █╗ ██║██║   ██║██████╔╝█████╔╝ ███████╗"
    echo "  ██║╚██╔╝██║██╔══╝  ██║  ██║██║██╔══██║    ██║███╗██║██║   ██║██╔══██╗██╔═██╗ ╚════██║"
    echo "  ██║ ╚═╝ ██║███████╗██████╔╝██║██║  ██║    ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗███████║"
    echo "  ╚═╝     ╚═╝╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝     ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝"
    echo "  ═════════════════════════════════════════════════════════════════════════════════════"
    echo "                                  Установщик Claude Code"
    echo "  ═════════════════════════════════════════════════════════════════════════════════════"
}

# --- Проверка на Root ---
fn_check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${C_RED}Ошибка: Пожалуйста, запустите этот скрипт с правами root (через sudo).${C_NC}"
        exit 1
    fi
}

# --- Определение ОС и менеджера пакетов ---
fn_detect_os_and_pkg_manager() {
    echo -e "${C_YELLOW}--- Определение операционной системы ---${C_NC}"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID_LOWER=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
        
        if [[ $ID_LOWER == "ubuntu" || $ID_LOWER == "debian" || $ID_LOWER == "astra" ]]; then
            OS_TYPE="debian_based"
            PKG_MANAGER="apt"
            echo "Обнаружена ОС: $PRETTY_NAME (apt)"
        elif [[ $ID_LOWER == "centos" || $ID_LOWER == "rhel" ]]; then
            OS_TYPE="rhel_based"
            PKG_MANAGER="yum"
            echo "Обнаружена ОС: $PRETTY_NAME (yum)"
            
            # Проверяем на CentOS 7
            if [[ $ID_LOWER == "centos" && $VERSION_ID == "7" ]]; then
                echo -e "${C_RED}Обнаружен CentOS 7. Метод установки Node.js (Вариант 3) будет отключен из-за несовместимости glibc.${C_NC}"
                echo -e "${C_YELLOW}Рекомендуется использовать 'Вариант 4' (Native Install через прокси).${C_NC}"
                IS_CENTOS7=true
            fi
        else
            echo -e "${C_RED}Ошибка: Ваша ОС ($PRETTY_NAME) не поддерживается этим скриптом.${C_NC}"
            exit 1
        fi
    else
        echo -e "${C_RED}Ошибка: не удалось определить ОС (файл /etc/os-release не найден).${C_NC}"
        exit 1
    fi
    echo "--------------------------------------------------------"
}

# --- Обновление системы и базовые пакеты ---
fn_update_system() {
    echo -e "${C_YELLOW}--- 1. Обновление системы и установка зависимостей ---${C_NC}"
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt update || { echo -e "${C_RED}Ошибка: apt update не удался.${C_NC}"; exit 1; }
        apt install -y curl ca-certificates build-essential || { echo -e "${C_RED}Ошибка: не удалось установить базовые зависимости (apt).${C_NC}"; exit 1; }
    elif [ "$PKG_MANAGER" == "yum" ]; then
        yum install -y curl ca-certificates gcc-c++ make || { echo -e "${C_RED}Ошибка: не удалось установить базовые зависимости (yum).${C_NC}"; exit 1; }
    fi
    echo -e "${C_GREEN}Система обновлена.${C_NC}"
}

# --- Установка Node.js и Claude (через NPM) ---
# $1 - Префикс (пусто или "proxychains4")
fn_install_node_claude() {
    local prefix_cmd="$1"
    
    echo -e "${C_YELLOW}--- 2A. Установка Node.js (v18+ требуется) ---${C_NC}"
    
    # ИСПРАВЛЕНО: Проверка на v18+
    if command -v node &> /dev/null && [[ $(node -v | cut -d'v' -f2 | cut -d'.' -f1) -ge 18 ]]; then
        echo "Node.js (v18+) уже установлен. Пропускаем."
    else
        echo "Установка Node.js v20 (LTS)..."
        
        if [ "$PKG_MANAGER" == "apt" ]; then
             echo "Добавление репозитория NodeSource (Debian)..."
             $prefix_cmd curl -fsSL https://deb.nodesource.com/setup_20.x | $prefix_cmd bash - || { echo -e "${C_RED}Ошибка: не удалось выполнить скрипт NodeSource (deb).${C_NC}"; exit 1; }
             $prefix_cmd apt install -y nodejs || { echo -e "${C_RED}Ошибка: не удалось установить Node.js (apt).${C_NC}"; exit 1; }
        
        elif [ "$PKG_MANAGER" == "yum" ]; then
             echo "Добавление репозитория NodeSource (RHEL/CentOS)..."
             $prefix_cmd curl -fsSL https://rpm.nodesource.com/setup_20.x | $prefix_cmd bash - || { echo -e "${C_RED}Ошибка: не удалось выполнить скрипт NodeSource (rpm).${C_NC}"; exit 1; }
             $prefix_cmd yum install -y nodejs || { echo -e "${C_RED}Ошибка: не удалось установить Node.js (yum).${C_NC}"; exit 1; }
        fi
        echo -e "${C_GREEN}Node.js v20 установлен.${C_NC}"
    fi
    
    echo -e "${C_YELLOW}--- 2B. Установка Claude Code CLI ---${C_NC}"
    if ! $prefix_cmd npm install -g @anthropic-ai/claude-code; then
        echo -e "${C_RED}Ошибка: не удалось установить @anthropic-ai/claude-code.${C_NC}"
        exit 1
    fi
    echo -e "${C_GREEN}Claude Code CLI (npm) успешно установлен.${C_NC}"
}

# --- Установка Claude (Нативный метод) ---
# $1 - Префикс (пусто или "proxychains4")
fn_install_claude_native() {
    local prefix_cmd="$1"
    
    echo -e "${C_YELLOW}--- 2A. Установка Claude Code (Native Install) ---${C_NC}"
    
    if command -v claude &> /dev/null; then
        echo "Claude CLI уже установлен. Пропускаем."
    else
        echo "Запуск официального установщика: $prefix_cmd curl -fsSL https://claude.ai/install.sh | $prefix_cmd bash"
        
        # Мы должны обернуть curl И bash в прокси
        # Создаем временный скрипт для proxychains
        local tmp_script="/tmp/claude_install_via_proxy.sh"
        echo '#!/bin/bash' > "$tmp_script"
        echo 'curl -fsSL https://claude.ai/install.sh | bash' >> "$tmp_script"
        chmod +x "$tmp_script"
        
        if ! $prefix_cmd "$tmp_script"; then
             echo -e "${C_RED}Ошибка: не удалось установить Claude Code (Native).${C_NC}"
             exit 1
        fi
        rm "$tmp_script"
        echo -e "${C_GREEN}Claude Code CLI успешно установлен.${C_NC}"
    fi
}


# --- Установка и настройка Proxychains ---
fn_install_proxychains() {
    echo -e "${C_YELLOW}--- 2X. Установка Proxychains4 ---${C_NC}"
    
    if command -v proxychains4 &> /dev/null; then
        echo "Proxychains4 уже установлен. Пропускаем настройку."
        PROXYCHAINS_CONF_FILE=$(command -v proxychains4 | sed 's/bin/etc/' | sed 's/4$/4.conf/' | head -n 1)
        if [ ! -f "$PROXYCHAINS_CONF_FILE" ]; then
             PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf" # Fallback
        fi
        return
    fi
    
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt install -y proxychains-ng || { echo -e "${C_RED}Ошибка: не удалось установить proxychains-ng (apt).${C_NC}"; exit 1; }
        PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"
    
    elif [ "$PKG_MANAGER" == "yum" ]; then
        yum install -y epel-release || { echo -e "${C_RED}Ошибка: не удалось установить epel-release. Proxychains не будет найден.${C_NC}"; exit 1; }
        yum install -y proxychains-ng || { echo -e "${C_RED}Ошибка: не удалось установить proxychains-ng (yum).${C_NC}"; exit 1; }
        
        if [ -f /etc/proxychains4.conf ]; then
            PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"
        else
            PROXYCHAINS_CONF_FILE="/etc/proxychains.conf"
        fi
    fi

    echo -e "${C_YELLOW}--- Настройка Proxychains ---${C_NC}"
    read -p "Введите IP-адрес вашего SOCKS5 прокси: " PROXY_IP
    read -sp "Введите пароль для пользователя '$PROXY_USER': " PROXY_PASS
    echo
    
    if [ -z "$PROXY_IP" ] || [ -z "$PROXY_PASS" ]; then
        echo -e "${C_RED}Ошибка: IP-адрес и пароль не могут быть пустыми. Установка прервана.${C_NC}"
        exit 1
    fi

    echo "Создаем бэкап: ${PROXYCHAINS_CONF_FILE}.bak"
    cp "$PROXYCHAINS_CONF_FILE" "${PROXYCHAINS_CONF_FILE}.bak"

    echo "Запись новой конфигурации в $PROXYCHAINS_CONF_FILE..."
    cat << EOF > "$PROXYCHAINS_CONF_FILE"
#
# proxychains.conf  VER 4.x
# Конфигурация от MEDIA WORKS
#
dynamic_chain
quiet_mode
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 $PROXY_IP 1080 $PROXY_USER $PROXY_PASS
EOF
    unset PROXY_PASS
    echo -e "${C_GREEN}Proxychains4 успешно установлен и настроен.${C_NC}"
}

# --- Вывод финальной инструкции ---
fn_show_instructions() {
    # Получаем IP из конфига, если он уже был установлен
    if [ -z "$PROXY_IP" ] && [ -n "$PROXYCHAINS_CONF_FILE" ] && [ -f "$PROXYCHAINS_CONF_FILE" ]; then
        PROXY_IP=$(grep -E "socks5|socks4" "$PROXYCHAINS_CONF_FILE" | tail -n 1 | awk '{print $2}')
    fi
    
    echo
    echo -e "${C_GREEN}=================================================${C_NC}"
    echo -e "${C_GREEN}✅ УСТАНОВКА ЗАВЕРШЕНА ${C_NC}"
    echo -e "${C_GREEN}=================================================${C_NC}"
    echo
    echo "ИНСТРУКЦИИ ПО ИСПОЛЬЗОВАНИЮ:"
    echo

    case $CHOICE in
        1)
            echo -e "Вы установили: ${C_YELLOW}Node.js + Claude Code (Без прокси)${C_NC}"
            echo -e "Запуск Claude: ${C_BLUE}claude \"Ваш запрос\"${C_NC}"
            ;;
        2)
            echo -e "Вы установили: ${C_YELLOW}Только Proxychains4${C_NC}"
            echo "Конфигурационный файл: $PROXYCHAINS_CONF_FILE"
            echo "Проверка прокси (должен показать IP $PROXY_IP):"
            echo -e "   ${C_BLUE}proxychains4 curl https://ifconfig.me${C_NC}"
            ;;
        3)
            echo -e "Вы установили: ${C_YELLOW}Полный стэк (Node.js + Claude через прокси)${C_NC}"
            echo "Конфигурационный файл: $PROXYCHAINS_CONF_FILE"
            echo "1. Проверка прокси (должен показать IP $PROXY_IP):"
            echo -e "   ${C_BLUE}proxychains4 curl https://ifconfig.me${C_NC}"
            echo "2. Запуск Claude Code (уже через прокси):"
            echo -e "   ${C_BLUE}proxychains4 claude \"Ваш запрос\"${C_NC}"
            ;;
        4)
            echo -e "Вы установили: ${C_YELLOW}Полный стэк (Native Claude через прокси)${C_NC}"
            echo "Конфигурационный файл: $PROXYCHAINS_CONF_FILE"
            echo "1. Проверка прокси (должен показать IP $PROXY_IP):"
            echo -e "   ${C_BLUE}proxychains4 curl https://ifconfig.me${C_NC}"
            echo "2. Запуск Claude Code (уже через прокси):"
            echo -e "   ${C_BLUE}proxychains4 claude \"Ваш запрос\"${C_NC}"
            ;;
    esac
    echo
    echo "--------------------------------------------------------"
}

# ==============================================================================
# ГЛАВНЫЙ СКРИПТ
# ==============================================================================

fn_check_root
fn_show_logo
fn_detect_os_and_pkg_manager

echo "Выберите вариант установки:"
echo "  1) Только Node.js + Claude Code (требует Node 18+, нужен прямой доступ в сеть)"
echo "  2) Только Proxychains4 (настройка прокси)"

# Показываем несовместимый вариант только если ОС НЕ CentOS 7
if [ "$IS_CENTOS7" = false ]; then
echo "  3) Полный стэк [Node.js] (Сначала Proxy, потом Node+Claude через прокси)"
fi

echo "  4) Полный стэк [Native] (Сначала Proxy, потом Claude Native через прокси)"
echo
read -p "Ваш выбор: " CHOICE

case $CHOICE in
    1)
        echo "Выбран вариант 1: Node.js + Claude"
        fn_update_system
        fn_install_node_claude "" # Пустой префикс (без прокси)
        ;;
    2)
        echo "Выбран вариант 2: Только Proxychains4"
        fn_update_system
        fn_install_proxychains
        ;;
    3)
        if [ "$IS_CENTOS7" = true ]; then
             echo -e "${C_RED}Ошибка: Вариант 3 недоступен для CentOS 7.${C_NC}"
             exit 1
        fi
        echo "Выбран вариант 3: Полный стэк (Node.js)"
        fn_update_system
        fn_install_proxychains
        fn_install_node_claude "proxychains4" # Установка через прокси
        ;;
    4)
        echo "Выбран вариант 4: Полный стэк (Native)"
        fn_update_system
        fn_install_proxychains
        fn_install_claude_native "proxychains4" # Установка через прокси
        ;;
    *)
        echo -e "${C_RED}Неверный выбор. Выход.${C_NC}"
        exit 1
        ;;
esac

fn_show_instructions
