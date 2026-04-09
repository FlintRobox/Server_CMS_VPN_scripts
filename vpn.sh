#!/bin/bash
# =====================================================================
# vpn.sh - Развертывание VPN-сервера (3X-UI) с интеграцией на одном домене
# Версия: 5.0 (финальная, работающая с первого раза)
# =====================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    echo -e "\033[0;31mОшибка: файл lib.sh не найден в директории $SCRIPT_DIR.\033[0m"
    exit 1
fi
source "$SCRIPT_DIR/lib.sh"

init_force_mode "$@"

sqlite3_escape() {
    sed "s/'/''/g"
}

add_to_env() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$SCRIPT_DIR/.env"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$SCRIPT_DIR/.env"
    else
        echo "${key}=\"${value}\"" >> "$SCRIPT_DIR/.env"
    fi
}

if [[ $EUID -ne 0 ]]; then
    log "${RED}Ошибка: скрипт должен запускаться от root (или с sudo).${NC}"
    exit 1
fi

load_env "DOMAIN" "ADMIN_EMAIL"

SITE_DIR="${WEB_ROOT_BASE:-/var/www}/${DOMAIN}"
PHP_SOCKET="/run/php/php8.3-fpm.sock"

for pkg in sqlite3 jq curl; do
    if ! command -v $pkg &>/dev/null; then
        log "${YELLOW}Установка $pkg...${NC}"
        apt update && apt install -y $pkg >> "$LOG_FILE" 2>&1
    fi
done

SSL_DIR="/etc/letsencrypt/live/$DOMAIN"
if [[ ! -f "$SSL_DIR/fullchain.pem" || ! -f "$SSL_DIR/privkey.pem" ]]; then
    log "${YELLOW}SSL-сертификат для $DOMAIN не найден. Получаем через Let's Encrypt...${NC}"
    if ! command -v certbot &>/dev/null; then
        apt update && apt install -y certbot python3-certbot-nginx >> "$LOG_FILE" 2>&1
    fi
    if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL" >> "$LOG_FILE" 2>&1; then
        log "${GREEN}SSL-сертификат успешно получен.${NC}"
    else
        log "${RED}Не удалось получить SSL-сертификат.${NC}"
        exit 1
    fi
else
    log "${GREEN}SSL-сертификат уже существует.${NC}"
fi

NGINX_LOCAL_PORT="${NGINX_LOCAL_PORT:-}"
if [[ -z "$NGINX_LOCAL_PORT" ]]; then
    for port in {10443..10543}; do
        if ! ss -tlnp | grep -q ":$port "; then
            NGINX_LOCAL_PORT=$port
            break
        fi
    done
    if [[ -z "$NGINX_LOCAL_PORT" ]]; then
        log "${RED}Не найден свободный порт.${NC}"
        exit 1
    fi
    add_to_env "NGINX_LOCAL_PORT" "$NGINX_LOCAL_PORT"
fi

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
if [[ ! -f "$NGINX_CONF" ]]; then
    log "${RED}Конфигурация Nginx для $DOMAIN не найдена. Сначала выполните cms.sh.${NC}"
    exit 1
fi

log "${YELLOW}Создаём резервную копию и генерируем новую конфигурацию (локальный порт без SSL)...${NC}"
cp "$NGINX_CONF" "$NGINX_CONF.bak.$(date +%Y%m%d%H%M%S)"
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 127.0.0.1:$NGINX_LOCAL_PORT;
    server_name $DOMAIN;
    root $SITE_DIR;
    index index.php index.html;

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

if nginx -t >> "$LOG_FILE" 2>&1; then
    systemctl reload nginx
    log "${GREEN}Конфигурация Nginx успешно обновлена.${NC}"
else
    log "${RED}Ошибка: сгенерированная конфигурация невалидна. Выход.${NC}"
    nginx -t 2>&1 | tee -a "$LOG_FILE"
    exit 1
fi

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
            log "${RED}Установка 3X-UI не удалась.${NC}"
            exit 1
        fi
    else
        log "${RED}Не удалось загрузить скрипт установки.${NC}"
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

# --- Настройка панели через прямое редактирование БД (надёжный способ) ---
log "Настройка параметров панели 3X-UI..."

DB_PATH="/etc/x-ui/x-ui.db"
if [[ ! -f "$DB_PATH" ]]; then
    log "${RED}База данных 3X-UI не найдена.${NC}"
    exit 1
fi

# Останавливаем панель и убиваем процессы
systemctl stop $XUI_SERVICE
pkill -f "x-ui" 2>/dev/null || true
sleep 2

# Обновляем параметры в БД (порт, путь, логин, пароль, HTTPS)
sqlite3 "$DB_PATH" <<EOF
UPDATE settings SET value='$XUI_PORT' WHERE key='webPort';
UPDATE settings SET value='$XUI_PATH' WHERE key='webBasePath';
UPDATE settings SET value='$XUI_USERNAME' WHERE key='webUsername';
UPDATE settings SET value='$XUI_PASSWORD' WHERE key='webPassword';
UPDATE settings SET value='true' WHERE key='webEnable';
EOF
log_only "Параметры панели обновлены в БД."

# Копируем сертификаты для HTTPS
CERT_DIR="/etc/x-ui/certs"
mkdir -p "$CERT_DIR"
cp "$SSL_DIR/fullchain.pem" "$CERT_DIR/fullchain.pem"
cp "$SSL_DIR/privkey.pem" "$CERT_DIR/privkey.pem"
chown -R x-ui:x-ui "$CERT_DIR" 2>/dev/null || true
chmod 600 "$CERT_DIR/privkey.pem"
sqlite3 "$DB_PATH" <<EOF
UPDATE settings SET value='$CERT_DIR/fullchain.pem' WHERE key='webCertFile';
UPDATE settings SET value='$CERT_DIR/privkey.pem' WHERE key='webKeyFile';
EOF

# Запускаем панель
systemctl start $XUI_SERVICE
sleep 3

# Проверяем реальный порт
ACTUAL_PORT=$(ss -tlnp | grep x-ui | grep -oP ':\K\d+' | head -1)
if [[ -z "$ACTUAL_PORT" ]]; then
    log "${RED}Панель не запустилась. Проверьте логи: journalctl -u x-ui -n 20${NC}"
    exit 1
fi

if [[ "$ACTUAL_PORT" != "$XUI_PORT" ]]; then
    log "${YELLOW}Панель запустилась на порту $ACTUAL_PORT, обновляем .env.${NC}"
    add_to_env "XUI_PORT" "$ACTUAL_PORT"
    XUI_PORT=$ACTUAL_PORT
fi

# Проверяем HTTPS
if journalctl -u x-ui -n 5 --no-pager | grep -q "Web server running HTTPS"; then
    PANEL_PROTOCOL="https"
    log "${GREEN}Панель работает по HTTPS на порту $XUI_PORT.${NC}"
else
    PANEL_PROTOCOL="http"
    log "${YELLOW}Панель работает по HTTP. Возможно, ошибка сертификатов.${NC}"
fi

# --- Настройка UFW ---
log "Настройка UFW для панели 3X-UI..."
if [[ -n "${ADMIN_IP:-}" ]]; then
    ufw allow from "$ADMIN_IP" to any port "$XUI_PORT" proto tcp >> "$LOG_FILE" 2>&1
    log "${GREEN}Доступ к панели ограничен IP $ADMIN_IP.${NC}"
else
    ufw allow "$XUI_PORT"/tcp >> "$LOG_FILE" 2>&1
    log "${YELLOW}Доступ к панели открыт для всех. Рекомендуется ограничить через ADMIN_IP.${NC}"
fi
ufw allow 443/tcp >> "$LOG_FILE" 2>&1
ufw allow 443/udp >> "$LOG_FILE" 2>&1

SUBSCRIPTION_PORT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='subscriptionPort';" 2>/dev/null)
[[ -z "$SUBSCRIPTION_PORT" ]] && SUBSCRIPTION_PORT="2096"
ufw allow "$SUBSCRIPTION_PORT"/tcp >> "$LOG_FILE" 2>&1
ufw reload >> "$LOG_FILE" 2>&1

# --- Создание inbound с TLS (не Reality) ---
log "Создание inbound VLESS+TLS на порту 443 (удаляем старые)..."
# Принудительно удаляем все inbound на порту 443
sqlite3 "$DB_PATH" "DELETE FROM inbounds WHERE port=443;" >> "$LOG_FILE" 2>&1
log_only "Удалены все старые inbound на порту 443."

CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)

SETTINGS_JSON=$(jq -c -n \
    --arg uuid "$CLIENT_UUID" \
    --arg local_port "$NGINX_LOCAL_PORT" \
'{
    clients: [{
        id: $uuid,
        flow: "xtls-rprx-vision",
        email: "client1",
        enable: true
    }],
    decryption: "none",
    fallbacks: [{
        dest: ("127.0.0.1:" + $local_port)
    }]
}')

STREAM_JSON=$(jq -c -n \
    --arg domain "$DOMAIN" \
    --arg fullchain "$SSL_DIR/fullchain.pem" \
    --arg key "$SSL_DIR/privkey.pem" \
'{
    network: "tcp",
    security: "tls",
    tlsSettings: {
        serverName: $domain,
        certificates: [{
            certificateFile: $fullchain,
            keyFile: $key
        }],
        alpn: ["http/1.1"]
    },
    tcpSettings: {
        header: {
            type: "none"
        }
    }
}')

SNIFFING_JSON='{"enabled":true,"destOverride":["http","tls"]}'

ESCAPED_SETTINGS=$(echo "$SETTINGS_JSON" | sqlite3_escape)
ESCAPED_STREAM=$(echo "$STREAM_JSON" | sqlite3_escape)
ESCAPED_SNIFFING=$(echo "$SNIFFING_JSON" | sqlite3_escape)

sqlite3 "$DB_PATH" <<EOF
INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
VALUES (1, 0, 0, 0, 'VLESS+TLS', 1, 0, '', 443, 'vless', '$ESCAPED_SETTINGS', '$ESCAPED_STREAM', 'inbound-443', '$ESCAPED_SNIFFING');
EOF

log "${GREEN}Inbound для VPN создан (TLS, ALPN http/1.1).${NC}"
log "Клиент UUID: $CLIENT_UUID"

# --- Перезапуск служб (ещё раз для надёжности) ---
systemctl restart $XUI_SERVICE >> "$LOG_FILE" 2>&1
systemctl reload nginx

# --- Итоговая информация ---
echo ""
log "${GREEN}======================================================"
log "${GREEN}✅ VPN-сервер успешно развёрнут!${NC}"
log "${GREEN}======================================================"
echo ""
log "🌐 Панель управления 3X-UI (${PANEL_PROTOCOL}):"
log "   URL: ${PANEL_PROTOCOL}://${DOMAIN}:${XUI_PORT}${XUI_PATH}"
log "   Логин: ${XUI_USERNAME}"
log "   Пароль: ${XUI_PASSWORD}"
echo ""
log "🔐 Параметры VPN-клиента (VLESS + TLS):"
log "   Адрес: ${DOMAIN}"
log "   Порт: 443"
log "   UUID: ${CLIENT_UUID}"
log "   Flow: xtls-rprx-vision"
log "   SNI: ${DOMAIN}"
log "   ALPN: http/1.1"
echo ""
log "📡 Порт подписок: ${SUBSCRIPTION_PORT}"
log "   Ссылка: https://${DOMAIN}:${SUBSCRIPTION_PORT}/sub/${CLIENT_UUID}"
echo ""
log "${YELLOW}⚠️  Убедитесь, что порт ${XUI_PORT} открыт в UFW (уже должно быть).${NC}"
log "======================================================"
exit 0