# --- Вывод финальной инструкции ---
fn_show_instructions() {
    echo
    echo -e "${C_GREEN}=================================================${C_NC}"
    echo -e "${C_GREEN}✅ УСТАНОВКА ЗАВЕРШЕНА ${C_NC}"
    echo -e "${C_GREEN}=================================================${C_NC}"
    echo
    echo "ИНСТРУКЦИИ ПО ИСПОЛЬЗОВАНИЮ:"
    echo

    case $CHOICE in
        1)
            # ИСПРАВЛЕНО: Добавлен флаг -e
            echo -e "Вы установили: ${C_YELLOW}Claude Code (Native)${C_NC}"
            echo -e "Запуск Claude: ${C_BLUE}claude \"Ваш запрос\"${C_NC}"
            echo "(Proxychains не был установлен)"
            ;;
        2)
            # ИСПРАВЛЕНО: Добавлен флаг -e
            echo -e "Вы установили: ${C_YELLOW}Proxychains4${C_NC}"
            echo "Конфигурационный файл: $PROXYCHAINS_CONF_FILE"
            echo "Проверка прокси (должен показать IP $PROXY_IP):"
            echo -e "   ${C_BLUE}proxychains4 curl https://ifconfig.me${C_NC}"
            echo -e "Запуск любой команды: ${C_BLUE}proxychains4 [команда]${C_NC}"
            echo "(Claude Code не был установлен)"
            ;;
        3)
            # ИСПРАВЛЕНО: Добавлен флаг -e
            echo -e "Вы установили: ${C_YELLOW}Полный стэк (Claude + Proxy)${C_NC}"
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
