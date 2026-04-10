#!/bin/bash
# =====================================================================
# vpn.sh - Развертывание VPN-сервера (3X-UI) с интеграцией на одном домене
# Версия: 6.1 (исправлена установка 3X-UI с таймаутом)
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

# --- Функция безопасного добавления переменной в .env ---
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

# --- Вспомогательные функции определения параметров ---
detect_domain() {
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        source "$SCRIPT_DIR/.env"
        if [[ -n "${DOMAIN:-}" ]]; then
            echo "$DOMAIN"
            return
        fi
    fi
    local domain=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README | head -1)
    if [[ -n "$domain" ]]; then
        echo "$domain"
        return
    fi
    domain=$(grep -h "server_name" /etc/nginx/sites-enabled/* 2>/dev/null | head -1 | awk '{print $2}' | sed 's/;//')
    echo "${domain:-}"
}

detect_site_root() {
    local domain="$1"
    if [[ -d "/var/www/$domain" ]]; then
        echo "/var/www/$domain"
        return
    fi
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        source "$SCRIPT_DIR/.env"
        if [[ -n "${SITE_ROOT:-}" && -d "$SITE_ROOT" ]]; then
            echo "$SITE_ROOT"
            return
        fi
    fi
    local conf_file="/etc/nginx/sites-enabled/$domain"
    if [[ -f "$conf_file" ]]; then
        local root=$(grep -h "root" "$conf_file" | grep -v "#" | head -1 | awk '{print $2}' | sed 's/;//')
        if [[ -n "$root" && -d "$root" ]]; then
            echo "$root"
            return
        fi
    fi
    echo "/var/www/$domain"
}

detect_php_socket() {
    for ver in 8.3 8.2 8.1 8.0; do
        if [[ -S "/run/php/php${ver}-fpm.sock" ]]; then
            echo "/run/php/php${ver}-fpm.sock"
            return
        fi
    done
    echo "/run/php/php8.3-fpm.sock"
}

get_free_port() {
    local port=$1
    while ss -tln | grep -q ":$port"; do
        port=$((port + 1))
    done
    echo "$port"
}

# --- Определение домена, корня, PHP ---
DOMAIN=$(detect_domain)
if [[ -z "$DOMAIN" ]]; then
    log "${RED}Не удалось определить домен. Убедитесь, что сайт настроен (выполнен cms.sh).${NC}"
    exit 1
fi
SITE_ROOT=$(detect_site_root "$DOMAIN")
PHP_SOCKET=$(detect_php_socket)
log_only "Домен: $DOMAIN, Корень: $SITE_ROOT, PHP сокет: $PHP_SOCKET"

# --- SSL-сертификаты ---
SSL_DIR="/etc/letsencrypt/live/$DOMAIN"
if [[ -f "$SSL_DIR/fullchain.pem" && -f "$SSL_DIR/privkey.pem" ]]; then
    SSL_CERT="$SSL_DIR/fullchain.pem"
    SSL_KEY="$SSL_DIR/privkey.pem"
    log "${GREEN}SSL-сертификаты найдены.${NC}"
else
    SSL_CERT=""
    SSL_KEY=""
    log "${YELLOW}SSL-сертификаты не найдены. HTTPS для панели не будет включён.${NC}"
fi

# --- Шаги ---
TOTAL_STEPS=7
CURRENT_STEP=0
next_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    echo "[${percent}%] $1"
}

# ----------------------------------------------------------------------
# 1. Остановка Nginx для установки 3X-UI (освобождение порта 80)
# ----------------------------------------------------------------------
next_step "Остановка Nginx для освобождения порта 80"
systemctl stop nginx
log_only "Nginx остановлен."

# ----------------------------------------------------------------------
# 2. Установка 3X-UI (с таймаутом)
# ----------------------------------------------------------------------
next_step "Установка 3X-UI (может занять 1-2 минуты)"
if systemctl list-units --full --all | grep -q "x-ui.service"; then
    log "${GREEN}3X-UI уже установлен.${NC}"
else
    log "${YELLOW}Установка 3X-UI...${NC}"
    INSTALL_SCRIPT="/tmp/install_3xui.sh"
    if curl -fsSL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$INSTALL_SCRIPT"; then
        chmod +x "$INSTALL_SCRIPT"
        # Запускаем скрипт с таймаутом 300 секунд, отключая интерактивность
        timeout 300 bash "$INSTALL_SCRIPT" </dev/null >> "$LOG_FILE" 2>&1
        local exit_code=$?
        rm -f "$INSTALL_SCRIPT"
        if [[ $exit_code -eq 0 ]]; then
            log "${GREEN}3X-UI установлен.${NC}"
        else
            log "${RED}Ошибка установки 3X-UI (код $exit_code).${NC}"
            exit 1
        fi
    else
        log "${RED}Не удалось загрузить скрипт установки 3X-UI.${NC}"
        exit 1
    fi
fi

# ----------------------------------------------------------------------
# 3. Запуск Nginx обратно
# ----------------------------------------------------------------------
next_step "Запуск Nginx"
systemctl start nginx
log_only "Nginx запущен."

# ----------------------------------------------------------------------
# 4. Настройка Nginx на локальный порт (без SSL)
# ----------------------------------------------------------------------
next_step "Настройка Nginx на локальный порт"
LOCAL_PORT=$(get_free_port 10443)
add_to_env "NGINX_LOCAL_PORT" "$LOCAL_PORT"
log_only "Локальный порт для Nginx: $LOCAL_PORT"

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$LOCAL_PORT;
    server_name $DOMAIN;
    root $SITE_ROOT;
    index index.php index.html;
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log /var/log/nginx/${DOMAIN}_error.log;
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCKET;
    }
    location ^~ /uploads {
        location ~ \.php$ { deny all; }
    }
}
EOF

ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"
if nginx -t >> "$LOG_FILE" 2>&1; then
    systemctl reload nginx
    log "${GREEN}Конфигурация Nginx обновлена.${NC}"
else
    log "${RED}Ошибка конфигурации Nginx.${NC}"
    exit 1
fi

# ----------------------------------------------------------------------
# 5. Настройка панели 3X-UI (через прямое редактирование БД)
# ----------------------------------------------------------------------
next_step "Настройка параметров панели 3X-UI"

DB_PATH="/etc/x-ui/x-ui.db"
if [[ ! -f "$DB_PATH" ]]; then
    log "${RED}База данных 3X-UI не найдена.${NC}"
    exit 1
fi

# Останавливаем панель
systemctl stop x-ui 2>/dev/null || true
sleep 2

# Создаём таблицу settings, если её нет
sqlite3 "$DB_PATH" "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);" 2>/dev/null || true

# Генерируем параметры панели
PANEL_PORT=$(shuf -i 52000-53000 -n1)
PANEL_PATH="/$(openssl rand -hex 8)"
PANEL_USER="admin_$(openssl rand -hex 4)"
PANEL_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!?@#' | head -c20)

# Сохраняем в .env
add_to_env "XUI_PORT" "$PANEL_PORT"
add_to_env "XUI_PATH" "$PANEL_PATH"
add_to_env "XUI_USERNAME" "$PANEL_USER"
add_to_env "XUI_PASSWORD" "$PANEL_PASS"

# Удаляем старые записи (если есть) и вставляем новые
sqlite3 "$DB_PATH" <<EOF
INSERT OR REPLACE INTO settings (key, value) VALUES ('webPort', '$PANEL_PORT');
INSERT OR REPLACE INTO settings (key, value) VALUES ('webBasePath', '$PANEL_PATH');
INSERT OR REPLACE INTO settings (key, value) VALUES ('username', '$PANEL_USER');
INSERT OR REPLACE INTO settings (key, value) VALUES ('password', '$PANEL_PASS');
EOF

# Включаем HTTPS для панели, если есть сертификаты
if [[ -n "$SSL_CERT" && -n "$SSL_KEY" ]]; then
    sqlite3 "$DB_PATH" <<EOF
INSERT OR REPLACE INTO settings (key, value) VALUES ('webCertFile', '$SSL_CERT');
INSERT OR REPLACE INTO settings (key, value) VALUES ('webKeyFile', '$SSL_KEY');
INSERT OR REPLACE INTO settings (key, value) VALUES ('webEnable', 'true');
EOF
    log "HTTPS для панели включён."
else
    sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webEnable', 'false');"
    log "${YELLOW}HTTPS для панели не включён (нет сертификатов).${NC}"
fi

# Запускаем панель
systemctl start x-ui
sleep 3

if ! systemctl is-active --quiet x-ui; then
    log "${RED}Ошибка: панель 3X-UI не запустилась.${NC}"
    exit 1
fi
log "${GREEN}Панель 3X-UI запущена.${NC}"

# ----------------------------------------------------------------------
# 6. Создание inbound VLESS+TLS на порту 443
# ----------------------------------------------------------------------
next_step "Создание inbound VLESS+TLS на порту 443"

# Создаём таблицу inbounds, если её нет
sqlite3 "$DB_PATH" "CREATE TABLE IF NOT EXISTS inbounds (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER,
    up INTEGER,
    down INTEGER,
    total INTEGER,
    remark TEXT,
    enable INTEGER,
    expiry_time INTEGER,
    listen TEXT,
    port INTEGER,
    protocol TEXT,
    settings TEXT,
    stream_settings TEXT,
    tag TEXT,
    sniffing TEXT
);" 2>/dev/null || true

COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM inbounds WHERE port=443 AND enable=1;" 2>/dev/null || echo "0")
if [[ "$COUNT" -eq 0 ]] || $FORCE_MODE; then
    if [[ "$COUNT" -ne 0 ]] && $FORCE_MODE; then
        sqlite3 "$DB_PATH" "DELETE FROM inbounds WHERE port=443;" >> "$LOG_FILE" 2>&1
        log_only "Удалён старый inbound на порту 443."
    fi
    CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
    SETTINGS_JSON=$(jq -n \
        --arg uuid "$CLIENT_UUID" \
        --arg port "$LOCAL_PORT" \
        '{
            clients: [{ id: $uuid, flow: "xtls-rprx-vision", email: "client1", enable: true }],
            decryption: "none",
            fallbacks: [{ dest: ("127.0.0.1:" + $port) }]
        }')
    STREAM_JSON=$(jq -n \
        --arg domain "$DOMAIN" \
        --arg cert "$SSL_CERT" \
        --arg key "$SSL_KEY" \
        '{
            network: "tcp",
            security: "tls",
            tlsSettings: {
                serverName: $domain,
                certificates: [{ certificateFile: $cert, keyFile: $key }],
                alpn: ["http/1.1"]
            },
            tcpSettings: { header: { type: "none" } }
        }')
    SNIFFING_JSON='{"enabled":true,"destOverride":["http","tls"]}'
    sqlite3 "$DB_PATH" <<EOF
INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) 
VALUES (1, 0, 0, 0, 'VLESS+TLS', 1, 0, '', 443, 'vless', '$SETTINGS_JSON', '$STREAM_JSON', 'inbound-443', '$SNIFFING_JSON');
EOF
    log "${GREEN}Inbound создан, UUID клиента: $CLIENT_UUID${NC}"
else
    CLIENT_UUID=$(sqlite3 "$DB_PATH" "SELECT json_extract(settings, '$.clients[0].id') FROM inbounds WHERE port=443;" 2>/dev/null || echo "")
    log "${YELLOW}Inbound уже существует, UUID: ${CLIENT_UUID:-не определён}${NC}"
fi

# ----------------------------------------------------------------------
# 7. Настройка UFW и перезапуск служб
# ----------------------------------------------------------------------
next_step "Настройка брандмауэра и перезапуск служб"

ufw allow 443/tcp comment 'VLESS TCP' >> "$LOG_FILE" 2>&1 || true
ufw allow 443/udp comment 'VLESS UDP' >> "$LOG_FILE" 2>&1 || true
ufw allow "$PANEL_PORT"/tcp comment '3X-UI Panel' >> "$LOG_FILE" 2>&1 || true
SUB_PORT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='subPort';" 2>/dev/null || echo "2096")
[[ -n "$SUB_PORT" ]] && ufw allow "$SUB_PORT"/tcp comment 'Subscription' >> "$LOG_FILE" 2>&1 || true
ufw reload >> "$LOG_FILE" 2>&1

systemctl restart x-ui
systemctl reload nginx

# --- Итоговая информация ---
echo ""
log "${GREEN}======================================================"
log "${GREEN}✅ VPN-сервер успешно развёрнут!${NC}"
log "${GREEN}======================================================"
echo ""
log "🌐 Панель управления 3X-UI (HTTPS):"
log "   URL: https://${DOMAIN}:${PANEL_PORT}${PANEL_PATH}"
log "   Логин: ${PANEL_USER}"
log "   Пароль: ${PANEL_PASS}"
echo ""
log "🔐 Параметры VPN-клиента (VLESS + TLS):"
log "   Адрес: ${DOMAIN}"
log "   Порт: 443"
log "   UUID: ${CLIENT_UUID}"
log "   Flow: xtls-rprx-vision"
log "   SNI: ${DOMAIN}"
log "   ALPN: http/1.1"
echo ""
log "📡 Порт подписок: ${SUB_PORT}"
log "   Ссылка: https://${DOMAIN}:${SUB_PORT}/sub/${CLIENT_UUID}"
echo ""
log "${YELLOW}⚠️  Убедитесь, что порт ${PANEL_PORT} открыт в UFW (уже должно быть).${NC}"
log "======================================================"

exit 0