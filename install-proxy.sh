#!/bin/bash

# ==============================================================================
# Установщик MEDIA WORKS для Claude Code и Proxy (v2.1 - исправлен)
# Поддержка: Ubuntu, Debian, Astra Linux, CentOS
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
PROXY_IP="" # Будет запрошен у пользователя
PROXY_USER="proxyuser" # Фиксированный пользователь
PROXYCHAINS_CONF_FILE="" # Путь к конфигу (разный в разных ОС)

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
    echo "  ═════════════════════════════════════════════════════════════════════════════════════${C_NC}"
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
        ID=$(echo "$ID" | tr '[:upper:]' '[:lower:]')
        
        if [[ $ID == "ubuntu" || $ID == "debian" || $ID == "astra" ]]; then
            OS_TYPE="debian_based"
            PKG_MANAGER="apt"
            echo "Обнаружена ОС: $PRETTY_NAME (apt)"
        elif [[ $ID == "centos" || $ID == "rhel" ]]; then
            OS_TYPE="rhel_based"
            PKG_MANAGER="yum"
            echo "Обнаружена ОС: $PRETTY_NAME (yum)"
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

# --- Установка Node.js и Claude ---
fn_install_node_claude() {
    echo -e "${C_YELLOW}--- 2A. Установка Node.js (v20 LTS) ---${C_NC}"
    
    if command -v node &> /dev/null && [[ $(node -v | cut -d'v' -f2 | cut -d'.' -f1) -ge 20 ]]; then
        echo "Node.js (v20+) уже установлен. Пропускаем."
    else
        #
        # ===== ИСПРАВЛЕНИЕ 1: Разные скрипты для apt и yum =====
        #
        if [ "$PKG_MANAGER" == "apt" ]; then
             echo "Добавление репозитория NodeSource (Debian)..."
             curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || { echo -e "${C_RED}Ошибка: не удалось выполнить скрипт NodeSource (deb).${C_NC}"; exit 1; }
             apt install -y nodejs || { echo -e "${C_RED}Ошибка: не удалось установить Node.js (apt).${C_NC}"; exit 1; }
        
        elif [ "$PKG_MANAGER" == "yum" ]; then
             echo "Добавление репозитория NodeSource (RHEL/CentOS)..."
             curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - || { echo -e "${C_RED}Ошибка: не удалось выполнить скрипт NodeSource (rpm).${C_NC}"; exit 1; }
             yum install -y nodejs || { echo -e "${C_RED}Ошибка: не удалось установить Node.js (yum).${C_NC}"; exit 1; }
        fi
        echo -e "${C_GREEN}Node.js v20 установлен.${C_NC}"
    fi
    
    echo -e "${C_YELLOW}--- 2B. Установка Claude Code CLI ---${C_NC}"
    #
    # ===== ИСПРАВЛЕНИЕ 2: Правильное имя NPM пакета =====
    #
    if ! npm install -g @anthropic-ai/cli; then
        echo -e "${C_RED}Ошибка: не удалось установить @anthropic-ai/cli.${C_NC}"
        echo -e "${C_YELLOW}Возможно, registry.npmjs.org недоступен без прокси?${C_NC}"
        exit 1
    fi
    echo -e "${C_GREEN}Claude Code CLI (npm) успешно установлен.${C_NC}"
}

# --- Установка и настройка Proxychains ---
fn_install_proxychains() {
    echo -e "${C_YELLOW}--- 2C. Установка Proxychains4 ---${C_NC}"
    
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt install -y proxychains-ng || { echo -e "${C_RED}Ошибка: не удалось установить proxychains-ng (apt).${C_NC}"; exit 1; }
        PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"
    
    elif [ "$PKG_MANAGER" == "yum" ]; then
        #
        # ===== ИСПРАВЛЕНИЕ 3: Жесткая ошибка, если EPEL не установлен =====
        #
        yum install -y epel-release || { echo -e "${C_RED}Ошибка: не удалось установить epel-release. Proxychains не будет найден.${C_NC}"; exit 1; }
        yum install -y proxychains-ng || { echo -e "${C_RED}Ошибка: не удалось установить proxychains-ng (yum).${C_NC}"; exit 1; }
        
        if [ -f /etc/proxychains4.conf ]; then
            PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"
        else
            PROXYCHAINS_CONF_FILE="/etc/proxychains.conf"
        fi
    fi

    # --- Запрос данных для прокси ---
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
    echo
    echo -e "${C_GREEN}=================================================${C_NC}"
    echo -e "${C_GREEN}✅ УСТАНОВКА ЗАВЕРШЕНА ${C_NC}"
    echo -e "${C_GREEN}=================================================${C_NC}"
    echo
    echo "ИНСТРУКЦИИ ПО ИСПОЛЬЗОВАНИЮ:"
    echo

    #
    # ===== ИСПРАВЛЕНИЕ 4: Добавлен флаг -e для echo =====
    #
    case $CHOICE in
        1)
            echo -e "Вы установили: ${C_YELLOW}Node.js + Claude Code${C_NC}"
            echo -e "Запуск Claude: ${C_BLUE}claude \"Ваш запрос\"${C_NC}"
            echo "(Proxychains не был установлен)"
            ;;
        2)
            echo -e "Вы установили: ${C_YELLOW}Proxychains4${C_NC}"
            echo "Конфигурационный файл: $PROXYCHAINS_CONF_FILE"
            echo "Проверка прокси (должен показать IP $PROXY_IP):"
            echo -e "   ${C_BLUE}proxychains4 curl https://ifconfig.me${C_NC}"
            echo -e "Запуск любой команды: ${C_BLUE}proxychains4 [команда]${C_NC}"
            echo "(Claude Code не был установлен)"
            ;;
        3)
            echo -e "Вы установили: ${C_YELLOW}Полный стэк (Node.js + Claude + Proxy)${C_NC}"
            echo "Конфигурационный файл: $PROXYCHAINS_CONF_FILE"
            echo
            echo "1. Проверка прокси (должен показать IP $PROXY_IP):"
            echo -e "   ${C_BLUE}proxychains4 curl https://ifconfig.me${C_NC}"
            echo
            echo "2. Запуск Claude Code через прокси:"
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
echo "  1) Только Node.js + Claude Code"
echo "  2) Только Proxychains4 (с настройками)"
echo "  3) Полный стэк (Node.js, Claude, Proxychains)"
echo
read -p "Ваш выбор [1, 2 или 3]: " CHOICE

case $CHOICE in
    1)
        echo "Выбран вариант 1: Claude Code"
        fn_update_system
        fn_install_node_claude
        ;;
    2)
        echo "Выбран вариант 2: Proxychains4"
        fn_update_system
        fn_install_proxychains
        ;;
    3)
        echo "Выбран вариант 3: Полный стэк"
        fn_update_system
        fn_install_node_claude
        fn_install_proxychains
        ;;
    *)
        echo -e "${C_RED}Неверный выбор. Выход.${C_NC}"
        exit 1
        ;;
esac

fn_show_instructions
