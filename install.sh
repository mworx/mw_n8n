#!/usr/bin/env bash
set -euo pipefail

# ====================================================================
#  Supabase Self-Hosted — Автоматический установщик (Debian/Ubuntu)
#  - Без Node.js: ключи генерируются в bash/openssl
#  - Тихие дефолты для env (SMTP_PORT и пр.), чтобы GoTrue не падал
#  - Патчи к compose: vector монтирует папку, db не ждёт vector:healthy
#  - Используется docker compose v2 (плагин), а не устаревший бинарник
# ====================================================================

# ---------- Вывод ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log(){ echo -e "${GREEN}[$(date +'%F %T')]${NC} $*"; }
info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err(){ echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

banner(){ cat <<'EOF'
 __  _____________  _______       _       ______  ____  __ _______
/  |/  / ____/ __ \/  _/   |     | |     / / __ \/ __ \/ //_/ ___/
 / /|_/ / __/ / / / // // /| |     | | /| / / / / / /_/ / ,<  \__ \
/ /  / / /___/ /_/ // // ___ |     | |/ |/ / /_/ / _, _/ /| |___/ /
_/  /_/_____/_____/___/_/  |_|     |__/|__/\____/_/ |_/_/ |_/____/
            Supabase Self-Hosted Installer (mworks.ru)
EOF
}

# ---------- Настройки ----------
INSTALL_DIR="${HOME}/supabase"          # куда развернём проект
REPO_URL="https://github.com/supabase/supabase.git"
KEYS_BACKUP_FILE="${INSTALL_DIR}/supabase_credentials.txt"

# ---------- Проверки окружения ----------
[ "$(id -u)" -eq 0 ] || err "Запустите скрипт от root (sudo)."
if [[ -f /etc/os-release ]]; then . /etc/os-release; else err "Нет /etc/os-release"; fi
case "${ID:-}" in ubuntu|debian) : ;; *) err "Поддерживаются только Debian/Ubuntu. Обнаружено: ${PRETTY_NAME:-unknown}";; esac

# ---------- Хелперы ----------
retry() { # retry <cmd...>
  local n=0; local max=3; local delay=5
  until "$@"; do
    n=$((n+1)); [[ $n -ge $max ]] && return 1
    warn "Повтор через ${delay}s: $*"
    sleep $delay
  done
}

gen_alnum(){ tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}" || true; }
b64url(){ openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt_hs256(){ # jwt_hs256 <secret> <json-payload>
  local secret="$1" payload="$2" header='{"alg":"HS256","typ":"JWT"}'
  local h b s
  h=$(printf '%s' "$header" | b64url)
  b=$(printf '%s' "$payload" | b64url)
  s=$(printf '%s' "${h}.${b}" | openssl dgst -binary -sha256 -hmac "$secret" | b64url)
  printf '%s.%s.%s\n' "$h" "$b" "$s"
}

# ---------- Установка зависимостей ----------
install_deps(){
  log "Обнаружена ОС: ${PRETTY_NAME}"
  info "Устанавливаем базовые пакеты…"
  retry apt-get update -y >/dev/null
  retry apt-get install -y ca-certificates curl gnupg lsb-release git wget openssl >/dev/null

  if ! command -v docker >/dev/null 2>&1; then
    info "Устанавливаем Docker…"
    retry sh -c "curl -fsSL https://get.docker.com | sh" || err "Не удалось установить Docker"
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker  >/dev/null 2>&1 || true
  fi
  log "Docker установлен ✓"

  if ! docker compose version >/dev/null 2>&1; then
    info "Устанавливаем docker compose plugin…"
    retry apt-get install -y docker-compose-plugin >/dev/null || warn "compose-plugin из apt не поставился"
  fi
  docker compose version >/dev/null 2>&1 || err "docker compose недоступен"
  log "Docker Compose v2 доступен ✓"
}

# ---------- Подготовка проекта и репозитория ----------
prepare_project(){
  info "Готовим каталог проекта: ${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"
  chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "${INSTALL_DIR}"

  local tmp="/tmp/supabase-clone-$$"
  rm -rf "$tmp"; mkdir -p "$tmp"

  info "Клонируем Supabase (self-hosted)…"
  retry git clone --depth 1 "${REPO_URL}" "$tmp" >/dev/null || err "clone failed"

  info "Копируем docker-каталог в проект…"
  cp -a "${tmp}/docker/." "${INSTALL_DIR}/"
  rm -rf "$tmp"

  # Фиксируем, что будем работать в INSTALL_DIR
  cd "${INSTALL_DIR}"
}

# ---------- Генерация и запись .env ----------
generate_env(){
  info "Готовим .env…"
  # берем .env.example если есть, иначе создаём новый
  if [[ -f ".env.example" && ! -f ".env" ]]; then
    cp .env.example .env
  elif [[ ! -f ".env" ]]; then
    touch .env
  fi

  # Генерим секреты
  local POSTGRES_PASSWORD JWT_SECRET ANON_KEY SERVICE_ROLE_KEY
  local now exp
  POSTGRES_PASSWORD="$(gen_alnum 32)"
  JWT_SECRET="$(gen_alnum 40)"
  now=$(date +%s); exp=$(( now + 20*365*24*3600 )) # ~20 лет
  ANON_KEY="$(jwt_hs256 "$JWT_SECRET" "$(printf '{"role":"anon","iss":"supabase","iat":%d,"exp":%d}' "$now" "$exp")")"
  SERVICE_ROLE_KEY="$(jwt_hs256 "$JWT_SECRET" "$(printf '{"role":"service_role","iss":"supabase","iat":%d,"exp":%d}' "$now" "$exp")")"

  # Доп.дефолты, чтобы сервисы не падали и не шумели
  local SECRET_KEY_BASE VAULT_ENC_KEY LOGFLARE_PUBLIC_ACCESS_TOKEN LOGFLARE_PRIVATE_ACCESS_TOKEN
  SECRET_KEY_BASE="$(gen_alnum 64)"
  VAULT_ENC_KEY="$(gen_alnum 64)"
  LOGFLARE_PUBLIC_ACCESS_TOKEN="$(gen_alnum 48)"
  LOGFLARE_PRIVATE_ACCESS_TOKEN="$(gen_alnum 48)"

  # Безопасно выставляем/заменяем ключи в .env
  set_kv(){ local k="$1" v="$2"; if grep -qE "^${k}=" .env; then sed -i "s|^${k}=.*|${k}=${v}|" .env; else echo "${k}=${v}" >> .env; fi; }

  set_kv "POSTGRES_PASSWORD" "${POSTGRES_PASSWORD}"
  set_kv "POSTGRES_DB" "postgres"
  set_kv "POSTGRES_PORT" "5432"
  set_kv "POSTGRES_HOST" "db"

  set_kv "JWT_SECRET" "${JWT_SECRET}"
  set_kv "ANON_KEY" "${ANON_KEY}"
  set_kv "SERVICE_ROLE_KEY" "${SERVICE_ROLE_KEY}"
  set_kv "JWT_EXPIRY" "630720000"

  # в оф. compose есть vector с docker.sock — зададим явный путь
  set_kv "DOCKER_SOCKET_LOCATION" "/var/run/docker.sock"

  # Тихие значения по умолчанию
  set_kv "SECRET_KEY_BASE" "${SECRET_KEY_BASE}"
  set_kv "VAULT_ENC_KEY" "${VAULT_ENC_KEY}"
  set_kv "LOGFLARE_PUBLIC_ACCESS_TOKEN" "${LOGFLARE_PUBLIC_ACCESS_TOKEN}"
  set_kv "LOGFLARE_PRIVATE_ACCESS_TOKEN" "${LOGFLARE_PRIVATE_ACCESS_TOKEN}"

  # SMTP_PORT должен быть числом — иначе gotrue падает
  grep -qE "^SMTP_PORT=" .env || echo "SMTP_PORT=587" >> .env

  # Резервная копия ключей
  {
    echo "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"
    echo "JWT_SECRET=${JWT_SECRET}"
    echo "ANON_KEY=${ANON_KEY}"
    echo "SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}"
    echo "SECRET_KEY_BASE=${SECRET_KEY_BASE}"
    echo "VAULT_ENC_KEY=${VAULT_ENC_KEY}"
    echo "LOGFLARE_PUBLIC_ACCESS_TOKEN=${LOGFLARE_PUBLIC_ACCESS_TOKEN}"
    echo "LOGFLARE_PRIVATE_ACCESS_TOKEN=${LOGFLARE_PRIVATE_ACCESS_TOKEN}"
  } > "${KEYS_BACKUP_FILE}"

  log "Ключи записаны в .env и ${KEYS_BACKUP_FILE} ✓"

  # Санитация .env
  sed -i 's/\r$//' .env
  sed -i 's/[[:space:]]*$//' .env
}

# ---------- Патчи docker-compose под локальный запуск ----------
patch_compose(){
  info "Патчим compose под устойчивый старт…"
  # 1) db не должен зависеть от vector:healthy (только started)
  sed -i '0,/\bdb:\b/{:a;N;/depends_on:/!ba;s/vector:\s*\n\s*condition:\s*service_healthy/vector:\n        condition: service_started/}' docker-compose.yml || true
  # 2) vector монтирует директорию, а не файл (иначе иногда "not a directory")
  sed -i 's#- \./volumes/logs/vector\.yml:/etc/vector/vector\.yml:ro,z#- ./volumes/logs:/etc/vector:ro,z#' docker-compose.yml || true
}

# ---------- Фаервол (минимально) ----------
setup_firewall(){
  if command -v ufw >/dev/null 2>&1; then
    info "Открываем порты UFW (80/443/5432/8000)…"
    ufw allow 22/tcp || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw allow 5432/tcp || true
    ufw allow 8000/tcp || true
  fi
}

# ---------- Запуск стеков ----------
start_stack(){
  info "Загрузка образов…"
  docker compose --env-file .env pull

  info "Старт Supabase (поштучно: vector → db, затем всё)…"
  docker compose --env-file .env up -d vector || true
  docker compose --env-file .env up -d db
  # Дождёмся Postgres
  info "Ожидание готовности Postgres…"
  for i in $(seq 1 30); do
    if docker exec supabase-db pg_isready -U postgres >/dev/null 2>&1; then break; fi
    sleep 2
  done
  docker compose --env-file .env up -d

  log "Контейнеры запущены ✓"
}

# ---------- Основной ход ----------
main(){
  clear; banner
  echo -e "${CYAN}Начинаем установку Supabase…${NC}"
  install_deps
  prepare_project
  generate_env
  patch_compose
  setup_firewall
  start_stack

  echo
  echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}Установка Supabase завершена!${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
  info "Каталог проекта: ${INSTALL_DIR}"
  info "Резервные ключи: ${KEYS_BACKUP_FILE}"
  echo
  info "Полезные команды:"
  echo "  cd ${INSTALL_DIR}"
  echo "  docker compose ps"
  echo "  docker compose logs -f"
  echo
  warn "Подождите 1–3 минуты, пока все сервисы станут healthy."
  info "Studio (по умолчанию внутри сети): http://studio:3000 (через прокси/порт-форвардинг или Traefik)."
  info "Kong API: http://localhost:8000 (при пробросе порта)."
}

main "$@"
