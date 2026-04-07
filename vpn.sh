#!/bin/bash
# =====================================================================
# vpn.sh - Развертывание VPN-сервера (3X-UI) с интеграцией на одном домене
# Версия: 3.7 (исправлена логика проверки Nginx, восстановление)
# =====================================================================

set -euo pipefail

# Подключаем общую библиотеку
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    echo -e "\033[0;31mОшибка: файл lib.sh не найден в директории $SCRIPT_DIR.\033[0m"
    exit 1
fi
source "$SCRIPT_DIR/lib.sh"

# Инициализация флага принудительной перезаписи
init_force_mode "$@"

# Функция экранирования для SQLite
sqlite3_escape() {
    sed "s/'/''/g"
}

# Функция безопасного добавления переменной в .env (без дублей)
add_to_env() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$SCRIPT_DIR/.env"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$SCRIPT_DIR/.env"
    else
        echo "${key}=\"${value}\"" >> "$SCRIPT_DIR/.env"
    fi
}

# --- Проверка прав root ---
if [[ $EUID -ne 0 ]]; then
    log "${RED}Ошибка: скрипт должен запускаться от root (или с sudo).${NC}"
    exit 1
fi

# --- Загрузка конфигурации ---
load_env "DOMAIN" "ADMIN_EMAIL"

# --- Определение дополнительных переменных ---
SITE_DIR="${WEB_ROOT_BASE:-/var/www}/${DOMAIN}"
PHP_SOCKET="/run/php/php8.3-fpm.sock"

# --- Проверка наличия необходимых утилит ---
for pkg in sqlite3 jq curl; do
    if ! command -v $pkg &>/dev/null; then
        log "${YELLOW}Установка $pkg...${NC}"
        apt update && apt install -y $pkg >> "$LOG_FILE" 2>&1
    fi
done

# --- Проверка наличия SSL-сертификата ---
SSL_DIR="/etc/letsencrypt/live/$DOMAIN"
if [[ ! -f "$SSL_DIR/fullchain.pem" || ! -f "$SSL_DIR/privkey.pem" ]]; then
    log "${YELLOW}SSL-сертификат для $DOMAIN не найден. Получаем через Let's Encrypt...${NC}"
    if ! command -v certbot &>/dev/null; then
        apt update && apt install -y certbot python3-certbot-nginx >> "$LOG_FILE" 2>&1
    fi
    if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL" >> "$LOG_FILE" 2>&1; then
        log "${GREEN}SSL-сертификат успешно получен.${NC}"
    else
        log "${RED}Не удалось получить SSL-сертификат. Убедитесь, что домен делегирован на этот сервер.${NC}"
        exit 1
    fi
else
    log "${GREEN}SSL-сертификат уже существует.${NC}"
fi

# --- Определение свободного локального порта для Nginx ---
NGINX_LOCAL_PORT="${NGINX_LOCAL_PORT:-}"
if [[ -z "$NGINX_LOCAL_PORT" ]]; then
    for port in {10443..10543}; do
        if ! ss -tlnp | grep -q ":$port "; then
            NGINX_LOCAL_PORT=$port
            break
        fi
    done
    if [[ -z "$NGINX_LOCAL_PORT" ]]; then
        log "${RED}Не найден свободный порт в диапазоне 10443-10543.${NC}"
        exit 1
    fi
    add_to_env "NGINX_LOCAL_PORT" "$NGINX_LOCAL_PORT"
    log_only "Выбран локальный порт для Nginx: $NGINX_LOCAL_PORT"
fi

# --- Модификация конфигурации Nginx (исправленная логика) ---
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
if [[ ! -f "$NGINX_CONF" ]]; then
    log "${RED}Конфигурация Nginx для $DOMAIN не найдена. Сначала выполните cms.sh.${NC}"
    exit 1
fi

# Функция генерации правильной конфигурации Nginx
generate_nginx_config() {
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 127.0.0.1:$NGINX_LOCAL_PORT ssl;
    listen [::1]:$NGINX_LOCAL_PORT ssl;
    server_name $DOMAIN;
    root $SITE_DIR;
    index index.php index.html;

    ssl_certificate $SSL_DIR/fullchain.pem;
    ssl_certificate_key $SSL_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCKET;
    }

    location ^~ /uploads {
        location ~ \.php\$ { deny all; }
    }

    server_tokens off;
}
EOF
}

# Проверяем текущую конфигурацию на валидность
if nginx -t 2>/dev/null; then
    log "${GREEN}Конфигурация Nginx корректна.${NC}"
    # Если конфигурация валидна, но fallback не настроен – перенастраиваем
    if ! grep -q "listen 127.0.0.1:$NGINX_LOCAL_PORT" "$NGINX_CONF"; then
        log "${YELLOW}Fallback не настроен, но конфигурация валидна. Создаём резервную копию и перенастраиваем.${NC}"
        cp "$NGINX_CONF" "$NGINX_CONF.bak"
        generate_nginx_config
        if nginx -t >> "$LOG_FILE" 2>&1; then
            systemctl reload nginx
            log "${GREEN}Конфигурация Nginx обновлена для fallback.${NC}"
        else
            log "${RED}Ошибка при обновлении конфигурации. Восстанавливаем.${NC}"
            mv "$NGINX_CONF.bak" "$NGINX_CONF"
            systemctl reload nginx
            exit 1
        fi
    else
        log "${GREEN}Fallback уже настроен, конфигурация корректна. Пропускаем.${NC}"
    fi
else
    log "${RED}Текущая конфигурация Nginx невалидна. Пытаемся восстановить.${NC}"
    nginx -t 2>&1 | tee -a "$LOG_FILE"
    # Пытаемся восстановить из резервной копии
    if [[ -f "$NGINX_CONF.bak" ]]; then
        log "${YELLOW}Восстанавливаем из резервной копии.${NC}"
        mv "$NGINX_CONF.bak" "$NGINX_CONF"
        if nginx -t >> "$LOG_FILE" 2>&1; then
            systemctl reload nginx
            log "${GREEN}Конфигурация восстановлена.${NC}"
        else
            log "${RED}Резервная копия тоже невалидна. Генерируем новую конфигурацию.${NC}"
            generate_nginx_config
            if nginx -t >> "$LOG_FILE" 2>&1; then
                systemctl reload nginx
                log "${GREEN}Сгенерирована новая конфигурация.${NC}"
            else
                log "${RED}Не удалось создать валидную конфигурацию. Выход.${NC}"
                exit 1
            fi
        fi
    else
        log "${YELLOW}Резервной копии нет. Генерируем новую конфигурацию.${NC}"
        generate_nginx_config
        if nginx -t >> "$LOG_FILE" 2>&1; then
            systemctl reload nginx
            log "${GREEN}Сгенерирована новая конфигурация.${NC}"
        else
            log "${RED}Не удалось создать валидную конфигурацию. Выход.${NC}"
            exit 1
        fi
    fi
fi

# --- Установка 3X-UI (если не установлен) ---
XUI_SERVICE="x-ui"
if systemctl list-units --full --all | grep -q "$XUI_SERVICE.service"; then
    log "${GREEN}3X-UI уже установлен.${NC}"
else
    log "${YELLOW}Установка 3X-UI...${NC}"
    INSTALL_SCRIPT="/tmp/install_3xui.sh"
    if curl -fsSL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$INSTALL_SCRIPT"; then
        chmod +x "$INSTALL_SCRIPT"
        if timeout 300 bash "$INSTALL_SCRIPT" </dev/null >> "$LOG_FILE" 2>&1; then
            rm -f "$INSTALL_SCRIPT"
            systemctl stop $XUI_SERVICE
            log "${GREEN}3X-UI установлен.${NC}"
        else
            rm -f "$INSTALL_SCRIPT"
            log "${RED}Установка 3X-UI не завершилась успешно или превысила время ожидания.${NC}"
            exit 1
        fi
    else
        log "${RED}Не удалось загрузить скрипт установки 3X-UI. Проверьте подключение к интернету.${NC}"
        exit 1
    fi
fi

# --- Генерация параметров панели (если не заданы в .env) ---
if [[ -z "${XUI_PORT:-}" ]]; then
    XUI_PORT=$(( RANDOM % 1000 + 52000 ))
    add_to_env "XUI_PORT" "$XUI_PORT"
fi
if [[ -z "${XUI_PATH:-}" ]]; then
    XUI_PATH="/$(openssl rand -hex 8)"
    add_to_env "XUI_PATH" "$XUI_PATH"
fi
if [[ -z "${XUI_USERNAME:-}" ]]; then
    XUI_USERNAME="admin_$(openssl rand -hex 4)"
    add_to_env "XUI_USERNAME" "$XUI_USERNAME"
fi
if [[ -z "${XUI_PASSWORD:-}" ]]; then
    XUI_PASSWORD=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!?@#' | head -c20)
    add_to_env "XUI_PASSWORD" "$XUI_PASSWORD"
fi

# --- Настройка панели через утилиту x-ui ---
log "Настройка параметров панели 3X-UI..."
x-ui setting -port "$XUI_PORT" -username "$XUI_USERNAME" -password "$XUI_PASSWORD" >> "$LOG_FILE" 2>&1

DB_PATH="/etc/x-ui/x-ui.db"
if [[ ! -f "$DB_PATH" ]]; then
    log "${RED}База данных 3X-UI не найдена.${NC}"
    exit 1
fi
sqlite3 "$DB_PATH" "UPDATE settings SET value='$XUI_PATH' WHERE key='webBasePath';" >> "$LOG_FILE" 2>&1
log_only "Путь к панели установлен: $XUI_PATH"

# --- Настройка UFW ---
log "Настройка UFW для панели 3X-UI..."
if [[ -n "${ADMIN_IP:-}" ]]; then
    ufw allow from "$ADMIN_IP" to any port "$XUI_PORT" proto tcp >> "$LOG_FILE" 2>&1
    log "${GREEN}Доступ к панели разрешён только с IP $ADMIN_IP.${NC}"
else
    ufw allow "$XUI_PORT"/tcp >> "$LOG_FILE" 2>&1
    log "${YELLOW}⚠️ Доступ к панели открыт для всех. Рекомендуется ограничить через ADMIN_IP в .env.${NC}"
fi
ufw allow 443/tcp >> "$LOG_FILE" 2>&1
ufw allow 443/udp >> "$LOG_FILE" 2>&1

SUBSCRIPTION_PORT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='subscriptionPort';" 2>/dev/null)
if [[ -z "$SUBSCRIPTION_PORT" ]]; then
    SUBSCRIPTION_PORT="2096"
fi
ufw allow "$SUBSCRIPTION_PORT"/tcp >> "$LOG_FILE" 2>&1
ufw reload >> "$LOG_FILE" 2>&1
log "UFW настроен."

# --- Генерация ключей Reality ---
log "Генерация ключей Reality..."

# Функция установки xray-core
install_xray() {
    log "${YELLOW}xray-core не найден. Устанавливаем...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >> "$LOG_FILE" 2>&1
}

if ! command -v xray &>/dev/null; then
    install_xray
fi

XRAY_BIN=$(which xray 2>/dev/null || find /usr/local -name xray -type f 2>/dev/null | head -1)
if [[ -z "$XRAY_BIN" || ! -x "$XRAY_BIN" ]]; then
    log "${RED}Не найден исполняемый файл xray.${NC}"
    exit 1
fi

log "Используется xray: $XRAY_BIN"

KEY_PAIR=$("$XRAY_BIN" x25519)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep -E "(Private key:|PrivateKey:)" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep -E "(Public key:|Password \(PublicKey\):|PublicKey:)" | awk '{print $2}')

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    log "${RED}Не удалось сгенерировать ключи Reality. Вывод xray:${NC}"
    echo "$KEY_PAIR"
    exit 1
fi
log_only "Reality ключи сгенерированы."

# --- Создание inbound для VPN ---
INBOUND_JSON=$(cat <<EOF
{
  "protocol": "vless",
  "port": 443,
  "settings": {
    "clients": [],
    "decryption": "none",
    "fallbacks": [{"dest": "127.0.0.1:$NGINX_LOCAL_PORT", "xver": 0}]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "$DOMAIN:443",
      "xver": 0,
      "serverNames": ["$DOMAIN"],
      "privateKey": "$PRIVATE_KEY",
      "publicKey": "$PUBLIC_KEY",
      "minClientVer": "",
      "maxClientVer": "",
      "maxTimeDiff": 0,
      "shortIds": ["", "1234567890abcdef"]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls"]
  }
}
EOF
)

EXISTING_INBOUND=$(sqlite3 "$DB_PATH" "SELECT id FROM inbounds WHERE port=443 LIMIT 1;" 2>/dev/null)
if [[ -z "$EXISTING_INBOUND" ]] || $FORCE_MODE; then
    if [[ -n "$EXISTING_INBOUND" ]]; then
        sqlite3 "$DB_PATH" "DELETE FROM inbounds WHERE id=$EXISTING_INBOUND;" >> "$LOG_FILE" 2>&1
        log_only "Удалён старый inbound на порту 443."
    fi
    ESCAPED_JSON=$(echo "$INBOUND_JSON" | sqlite3_escape)
    sqlite3 "$DB_PATH" "INSERT INTO inbounds (port, protocol, settings, stream_settings, sniffing, enable, tag) VALUES (443, 'vless', '$ESCAPED_JSON', '$ESCAPED_JSON', '$ESCAPED_JSON', 1, 'vless-reality-inbound');" >> "$LOG_FILE" 2>&1
    log "${GREEN}Inbound для VPN создан.${NC}"
else
    log "${YELLOW}Inbound на порту 443 уже существует. Пропуск (используйте --force для перезаписи).${NC}"
fi

# --- Создание первого клиента ---
CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
CLIENT_JSON=$(cat <<EOF
{
  "id": "$CLIENT_UUID",
  "flow": "xtls-rprx-vision",
  "email": "user1@$DOMAIN",
  "limitIp": 0,
  "totalGB": 0,
  "expiryTime": 0,
  "enable": true,
  "tgId": "",
  "subId": ""
}
EOF
)

INBOUND_ID=$(sqlite3 "$DB_PATH" "SELECT id FROM inbounds WHERE port=443 LIMIT 1;")
if [[ -n "$INBOUND_ID" ]]; then
    CURRENT_SETTINGS=$(sqlite3 "$DB_PATH" "SELECT settings FROM inbounds WHERE id=$INBOUND_ID;")
    NEW_SETTINGS=$(echo "$CURRENT_SETTINGS" | jq ".clients += [$CLIENT_JSON]")
    ESCAPED_SETTINGS=$(echo "$NEW_SETTINGS" | sqlite3_escape)
    sqlite3 "$DB_PATH" "UPDATE inbounds SET settings='$ESCAPED_SETTINGS' WHERE id=$INBOUND_ID;" >> "$LOG_FILE" 2>&1
    log "${GREEN}Клиент добавлен (UUID: $CLIENT_UUID).${NC}"
else
    log "${RED}Не найден inbound для добавления клиента.${NC}"
fi

# --- Перезапуск служб ---
log "Перезапуск Xray и Nginx..."
systemctl restart $XUI_SERVICE >> "$LOG_FILE" 2>&1
systemctl reload nginx

# --- Итоговая информация ---
PROTOCOL="https"
if [[ ! -f "$SSL_DIR/fullchain.pem" ]]; then
    PROTOCOL="http"
fi

echo ""
log "${GREEN}======================================================"
log "${GREEN}✅ VPN-сервер успешно развёрнут!${NC}"
log "${GREEN}======================================================"
echo ""
log "🌐 Панель управления 3X-UI:"
log "   URL: ${PROTOCOL}://${DOMAIN}:${XUI_PORT}${XUI_PATH}"
log "   Логин: ${XUI_USERNAME}"
log "   Пароль: ${XUI_PASSWORD}"
echo ""
log "🔐 Параметры VPN-клиента (VLESS + Reality):"
log "   Адрес: ${DOMAIN}"
log "   Порт: 443"
log "   UUID: ${CLIENT_UUID}"
log "   Flow: xtls-rprx-vision"
log "   SNI: ${DOMAIN}"
log "   PublicKey: ${PUBLIC_KEY}"
log "   ShortId: 1234567890abcdef (или пустой)"
echo ""
log "📱 Для подключения используйте любой клиент с поддержкой VLESS + Reality."
log "   Рекомендуемые клиенты: v2rayN, NekoBox, Hiddify, Shadowrocket."
echo ""
log "📡 Порт для подписок: ${SUBSCRIPTION_PORT} (если используется)"
log "   Ссылка на подписку: ${PROTOCOL}://${DOMAIN}:${SUBSCRIPTION_PORT}/sub/${CLIENT_UUID}"
echo ""
log "${YELLOW}⚠️  Важно:"
log "   - Убедитесь, что порт 443 открыт в UFW и не блокируется провайдером."
log "   - Если сайт перестал открываться, проверьте, что Nginx слушает на 127.0.0.1:${NGINX_LOCAL_PORT}"
log "   - Для ограничения доступа к панели установите ADMIN_IP в .env и выполните ufw reload."
echo ""
log "📝 Лог установки: ${LOG_FILE}"
log "======================================================"

exit 0