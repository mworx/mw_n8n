#!/bin/bash

# ==============================================================================
# Установщик MEDIA WORKS для Claude Code и Proxy (v3)
# Поддержка: Ubuntu, Debian, Astra Linux, CentOS
# ==============================================================================

# --- Цвета для вывода ---
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
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
        # build-essential больше не нужен для Claude, но может быть полезен для proxychains
        apt install -y curl ca-certificates build-essential || { echo -e "${C_RED}Ошибка: не удалось установить базовые зависимости (apt).${C_NC}"; exit 1; }
    
    elif [ "$PKG_MANAGER" == "yum" ]; then
        # yum check-update
        yum install -y curl ca-certificates gcc-c++ make || { echo -e "${C_RED}Ошибка: не удалось установить базовые зависимости (yum).${C_NC}"; exit 1; }
    fi
    
    echo -e "${C_GREEN}Система обновлена.${C_NC}"
}

# --- Установка Claude Code (Нативный метод) ---
fn_install_claude() {
    echo -e "${C_YELLOW}--- 2A. Установка Claude Code (Native Install) ---${C_NC}"
    
    if command -v claude &> /dev/null; then
        echo "Claude CLI уже установлен. Пропускаем."
    else
        echo "Запуск официального установщика: curl -fsSL https://claude.ai/install.sh | bash"
        if ! curl -fsSL https://claude.ai/install.sh | bash; then
            echo -e "${C_RED}Ошибка: не удалось установить Claude Code.${C_NC}"
            echo -e "${C_YELLOW}Возможно, доступ к claude.ai заблокирован?${C_NC}"
            exit 1
        fi
        echo -e "${C_GREEN}Claude Code CLI успешно установлен.${C_NC}"
    fi
}

# --- Установка и настройка Proxychains ---
fn_install_proxychains() {
    echo -e "${C_YELLOW}--- 2B. Установка Proxychains4 ---${C_NC}"
    
    if [ "$PKG_MANAGER" == "apt" ]; then
        apt install -y proxychains-ng || { echo -e "${C_RED}Ошибка: не удалось установить proxychains-ng (apt).${C_NC}"; exit 1; }
        PROXYCHAINS_CONF_FILE="/etc/proxychains4.conf"
    
    elif [ "$PKG_MANAGER" == "yum" ]; then
        yum install -y epel-release || { echo -e "${C_RED}Внимание: не удалось установить epel-release. Попытка продолжить...${C_NC}"; }
        yum install -y proxychains-ng || { echo -e "${C_RED}Ошибка: не удалось установить proxychains-ng (yum). Убедитесь, что EPEL-репозиторий подключен.${C_NC}"; exit 1; }
        
        # На CentOS/RHEL конфиг часто называется proxychains.conf
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

    echo "Создаем бэкап: ${PROXYCHAINS_CONF_FILE
