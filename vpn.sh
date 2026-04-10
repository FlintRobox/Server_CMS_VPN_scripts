#!/bin/bash
# =====================================================================
# vpn.sh - Развертывание VPN-сервера (3X-UI) с интеграцией на одном домене
# Версия: 8.1 (добавлен выбор SSL в автономном режиме)
# =====================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    echo -e "\033[0;31mОшибка: файл lib.sh не найден в директории $SCRIPT_DIR.\033[0m"
    exit 1
fi
source "$SCRIPT_DIR/lib.sh"

init_force_mode "$@"

# --- Константы ---
XUI_DB="/etc/x-ui/x-ui.db"
XUI_BIN="/usr/local/x-ui/x-ui"
FALLBACK_PORT_START=10443
TOTAL_STEPS=10
CURRENT_STEP=0

# --- Проверка наличия необходимых утилит ---
if ! command -v jq &>/dev/null; then
    log "${RED}Ошибка: jq не установлен. Выполните init.sh с целью 3 или установите вручную.${NC}"
    exit 1
fi

# --- Функция прогресса ---
next_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress $CURRENT_STEP $TOTAL_STEPS "$1"
}

# ----------------------------------------------------------------------
# Шаг 0: Определение режима работы и подготовка окружения
# ----------------------------------------------------------------------
next_step "Определение режима установки"

ENV_FILE="$SCRIPT_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

is_site_installed() {
    local domain="${1:-}"
    [[ -n "$domain" ]] || return 1
    [[ -f "/etc/nginx/sites-available/$domain" ]] && [[ -d "/var/www/$domain" ]]
}

if [[ -n "${DOMAIN:-}" ]] && is_site_installed "$DOMAIN"; then
    MODE="integrated"
    log "${GREEN}Обнаружен установленный сайт для домена $DOMAIN. Режим интеграции.${NC}"
else
    MODE="standalone"
    log "${YELLOW}Сайт не обнаружен. Работа в автономном режиме (только VPN).${NC}"
    if [[ -z "${DOMAIN:-}" ]]; then
        ask_var DOMAIN "Введите доменное имя для VPN" "" validate_domain
        add_to_env "DOMAIN" "$DOMAIN"
    fi
    if [[ -z "${ADMIN_EMAIL:-}" ]]; then
        ask_var ADMIN_EMAIL "Введите email администратора (для Let's Encrypt)" "admin@$DOMAIN" validate_email
        add_to_env "ADMIN_EMAIL" "$ADMIN_EMAIL"
    fi
fi

DOMAIN="${DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
SITE_DIR="/var/www/$DOMAIN"

# ----------------------------------------------------------------------
# Автономный режим: выбор SSL и настройка Nginx
# ----------------------------------------------------------------------
if [[ "$MODE" == "standalone" ]]; then
    next_step "Настройка SSL для домена $DOMAIN"

    # Запрос необходимости SSL
    DEFAULT_NEED_SSL="${NEED_SSL:-y}"
    while true; do
        read -p "Требуется ли SSL-сертификат? (y/n) [$DEFAULT_NEED_SSL]: " ssl_answer
        if [[ -z "$ssl_answer" ]]; then
            ssl_answer="$DEFAULT_NEED_SSL"
        fi
        if [[ "$ssl_answer" =~ ^([YyДд]|[Yy]es|YES)$ ]]; then
            NEED_SSL="y"
            break
        elif [[ "$ssl_answer" =~ ^([NnНн]|[Nn]o|NO)$ ]]; then
            NEED_SSL="n"
            break
        else
            echo -e "${RED}Пожалуйста, введите y или n.${NC}" >&2
        fi
    done
    add_to_env "NEED_SSL" "$NEED_SSL"

    SSL_TYPE=""
    if [[ "$NEED_SSL" == "y" ]]; then
        DEFAULT_SSL_TYPE="${SSL_TYPE:-letsencrypt}"
        while true; do
            read -p "Использовать существующий сертификат или получить через Let's Encrypt? (existing/letsencrypt) [$DEFAULT_SSL_TYPE]: " ssl_type_answer
            if [[ -z "$ssl_type_answer" ]]; then
                ssl_type_answer="$DEFAULT_SSL_TYPE"
            fi
            if [[ "$ssl_type_answer" == "existing" || "$ssl_type_answer" == "letsencrypt" ]]; then
                SSL_TYPE="$ssl_type_answer"
                break
            else
                echo -e "${RED}Введите 'existing' или 'letsencrypt'.${NC}" >&2
            fi
        done
        add_to_env "SSL_TYPE" "$SSL_TYPE"

        if [[ "$SSL_TYPE" == "existing" ]]; then
            # Запрос папки с сертификатами
            DEFAULT_CERT_DIR="${SSL_CERT_DIR:-}"
            if [[ -z "$DEFAULT_CERT_DIR" ]]; then
                if [[ -d "/root/${DOMAIN}" ]]; then
                    DEFAULT_CERT_DIR="/root/${DOMAIN}"
                elif [[ -d "/root/ssl/${DOMAIN}" ]]; then
                    DEFAULT_CERT_DIR="/root/ssl/${DOMAIN}"
                fi
            fi
            read -p "Введите путь к папке с файлами сертификатов (должны быть .key, .crt/.cer, ca.cer/ca.crt) [$DEFAULT_CERT_DIR]: " CERT_DIR
            if [[ -z "$CERT_DIR" ]]; then
                CERT_DIR="$DEFAULT_CERT_DIR"
            fi
            while [[ ! -d "$CERT_DIR" ]]; do
                echo -e "${RED}Папка $CERT_DIR не существует.${NC}" >&2
                read -p "Введите путь к папке с сертификатами: " CERT_DIR
            done

            KEY_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f \( -name "*.key" -o -name "*.pem" \) | grep -i "key" | head -n1)
            [[ -z "$KEY_FILE" ]] && KEY_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f -name "*.key" | head -n1)

            CERT_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f \( -name "*.cer" -o -name "*.crt" -o -name "*.pem" \) | grep -v "ca" | grep -v "key" | head -n1)
            if [[ -z "$CERT_FILE" ]]; then
                CERT_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f -name "*.crt" | head -n1)
            fi
            [[ -z "$CERT_FILE" ]] && CERT_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f -name "*.cer" | head -n1)

            CA_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f \( -name "ca.cer" -o -name "ca.crt" -o -name "*.ca" \) | head -n1)
            if [[ -z "$CA_FILE" ]]; then
                CA_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f \( -name "*.cer" -o -name "*.crt" -o -name "*.pem" \) | grep -v -F "$KEY_FILE" | grep -v -F "$CERT_FILE" | head -n1)
            fi

            if [[ -z "$KEY_FILE" || -z "$CERT_FILE" ]]; then
                echo -e "${RED}Не удалось найти ключ или сертификат в папке $CERT_DIR.${NC}" >&2
                exit 1
            fi

            echo -e "${GREEN}Найдены файлы:${NC}"
            echo "  Ключ: $KEY_FILE"
            echo "  Сертификат: $CERT_FILE"
            [[ -n "$CA_FILE" ]] && echo "  CA-цепочка: $CA_FILE"

            SSL_TARGET="/etc/letsencrypt/live/$DOMAIN"
            mkdir -p "$SSL_TARGET"
            if [[ -n "$CA_FILE" ]]; then
                cat "$CERT_FILE" "$CA_FILE" > "$SSL_TARGET/fullchain.pem"
            else
                cp "$CERT_FILE" "$SSL_TARGET/fullchain.pem"
            fi
            cp "$KEY_FILE" "$SSL_TARGET/privkey.pem"
            chmod 644 "$SSL_TARGET/fullchain.pem"
            chmod 600 "$SSL_TARGET/privkey.pem"
            add_to_env "SSL_CERT_PATH" "$SSL_TARGET/fullchain.pem"
            add_to_env "SSL_KEY_PATH" "$SSL_TARGET/privkey.pem"
            add_to_env "SSL_CERT_DIR" "$CERT_DIR"
            echo -e "${GREEN}Сертификаты сконвертированы и сохранены в $SSL_TARGET${NC}"
        fi
    fi

    # Установка Nginx, если отсутствует
    if ! command -v nginx &>/dev/null; then
        apt update && apt install -y nginx >> "$LOG_FILE" 2>&1
    fi

    # Создание директории сайта и простой индексной страницы
    mkdir -p "$SITE_DIR"
    if [[ ! -f "$SITE_DIR/index.html" ]]; then
        cat > "$SITE_DIR/index.html" <<EOF
<!DOCTYPE html>
<html>
<head><title>$DOMAIN – VPN Server</title></head>
<body>
<h1>Домен $DOMAIN используется для VPN</h1>
<p>Этот сервер предоставляет услуги VPN (VLESS + TLS) на порту 443.</p>
<p>Управление осуществляется через панель 3X-UI.</p>
</body>
</html>
EOF
    fi
    chown -R www-data:www-data "$SITE_DIR" 2>/dev/null || true

    # Получение SSL-сертификата, если выбран letsencrypt
    SSL_DIR="/etc/letsencrypt/live/$DOMAIN"
    if [[ "$NEED_SSL" == "y" && "$SSL_TYPE" == "letsencrypt" ]]; then
        if [[ ! -f "$SSL_DIR/fullchain.pem" ]]; then
            log "Получение SSL-сертификата Let's Encrypt..."
            systemctl stop nginx
            if ! certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL" >> "$LOG_FILE" 2>&1; then
                log "${RED}Ошибка получения сертификата. Проверьте, что домен $DOMAIN указывает на IP этого сервера и порт 80 доступен.${NC}"
                systemctl start nginx
                exit 1
            fi
            systemctl start nginx
            log "${GREEN}SSL-сертификат получен.${NC}"
        else
            log "SSL-сертификат уже существует."
        fi
    fi

    # Создание основного конфига Nginx
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
    if [[ "$NEED_SSL" == "y" ]]; then
        cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root $SITE_DIR;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php$ {
        return 404;
    }

    server_tokens off;
}
EOF
    else
        cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root $SITE_DIR;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    fi

    ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/"
    rm -f "/etc/nginx/sites-enabled/default"
    nginx -t >> "$LOG_FILE" 2>&1
    systemctl reload nginx
    log "${GREEN}Nginx настроен для домена $DOMAIN.${NC}"
fi

# ----------------------------------------------------------------------
# Определение PHP-сокета (если есть)
# ----------------------------------------------------------------------
detect_php_socket() {
    for ver in 8.3 8.2 8.1 8.0; do
        if [[ -S "/run/php/php${ver}-fpm.sock" ]]; then
            echo "/run/php/php${ver}-fpm.sock"
            return
        fi
    done
    echo ""
}
PHP_SOCKET=$(detect_php_socket)
if [[ -n "$PHP_SOCKET" ]]; then
    log_only "Обнаружен PHP-FPM сокет: $PHP_SOCKET"
else
    log_only "PHP-FPM не установлен. Fallback-сервер будет отдавать только статику."
fi

# ----------------------------------------------------------------------
# Определение порта для fallback
# ----------------------------------------------------------------------
next_step "Определение порта для fallback-сервера Nginx"

EXISTING_INBOUND=$(sqlite3 "$XUI_DB" "SELECT id, settings FROM inbounds WHERE port=443 AND enable=1 LIMIT 1;" 2>/dev/null || echo "")
if [[ -n "$EXISTING_INBOUND" ]]; then
    INBOUND_ID=$(echo "$EXISTING_INBOUND" | cut -d'|' -f1)
    FALLBACK_PORT=$(echo "$EXISTING_INBOUND" | cut -d'|' -f2 | jq -r '.fallbacks[0].dest' 2>/dev/null | grep -oP '\d+$' || echo "")
    if [[ -n "$FALLBACK_PORT" ]]; then
        LOCAL_PORT="$FALLBACK_PORT"
        log_only "Найден существующий inbound (ID: $INBOUND_ID) с fallback на порт $LOCAL_PORT"
    else
        LOCAL_PORT=$FALLBACK_PORT_START
        while ss -tuln | grep -q ":$LOCAL_PORT "; do
            LOCAL_PORT=$((LOCAL_PORT + 1))
        done
    fi
else
    LOCAL_PORT=$FALLBACK_PORT_START
    while ss -tuln | grep -q ":$LOCAL_PORT "; do
        LOCAL_PORT=$((LOCAL_PORT + 1))
        if [[ $LOCAL_PORT -gt 65535 ]]; then
            log "${RED}Не удалось найти свободный порт.${NC}"
            exit 1
        fi
    done
fi
add_to_env "NGINX_LOCAL_PORT" "$LOCAL_PORT"
log_only "Используется локальный порт: $LOCAL_PORT"

# ----------------------------------------------------------------------
# Создание fallback-сервера Nginx
# ----------------------------------------------------------------------
next_step "Настройка fallback-сервера Nginx на порт $LOCAL_PORT"

FALLBACK_CONF="/etc/nginx/sites-available/${DOMAIN}-fallback"
FALLBACK_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}-fallback"
rm -f "$FALLBACK_ENABLED"

cat > "$FALLBACK_CONF" <<EOF
server {
    listen 127.0.0.1:$LOCAL_PORT;
    server_name $DOMAIN;
    root $SITE_DIR;
    index index.html index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

EOF

if [[ -n "$PHP_SOCKET" ]]; then
    cat >> "$FALLBACK_CONF" <<EOF
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCKET;
    }
EOF
fi

cat >> "$FALLBACK_CONF" <<EOF
    location ^~ /uploads {
        location ~ \.php$ { deny all; }
    }
}
EOF

ln -sf "$FALLBACK_CONF" "$FALLBACK_ENABLED"
nginx -t >> "$LOG_FILE" 2>&1
systemctl reload nginx
log "${GREEN}Fallback-сервер добавлен.${NC}"

# ----------------------------------------------------------------------
# Установка 3X-UI
# ----------------------------------------------------------------------
next_step "Установка 3X-UI"
if systemctl list-units --full --all | grep -q "x-ui.service"; then
    log "${GREEN}3X-UI уже установлен.${NC}"
else
    log "${YELLOW}Установка 3X-UI...${NC}"
    INSTALL_SCRIPT="/tmp/install_3xui.sh"
    if curl -fsSL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$INSTALL_SCRIPT"; then
        chmod +x "$INSTALL_SCRIPT"
        # Передаём два 'y' для автоматического подтверждения (установка и настройка)
        printf 'y\ny\n' | bash "$INSTALL_SCRIPT" >> "$LOG_FILE" 2>&1
        install_result=$?
        rm -f "$INSTALL_SCRIPT"
        if [[ $install_result -eq 0 ]]; then
            log "${GREEN}3X-UI установлен.${NC}"
        else
            log "${RED}Ошибка установки 3X-UI (код $install_result). Проверьте лог $LOG_FILE.${NC}"
            exit 1
        fi
    else
        log "${RED}Не удалось загрузить скрипт установки 3X-UI.${NC}"
        exit 1
    fi
fi

# ----------------------------------------------------------------------
# Настройка панели 3X-UI (через прямое редактирование БД)
# ----------------------------------------------------------------------
next_step "Настройка параметров панели 3X-UI"

if [[ -z "${XUI_PORT:-}" ]]; then
    XUI_PORT=$(shuf -i 52000-53000 -n1)
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

# Останавливаем панель для безопасного редактирования БД
systemctl stop x-ui

# Убедимся, что таблица settings существует
sqlite3 "$XUI_DB" "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);" 2>/dev/null || true

# Применяем настройки через SQLite
sqlite3 "$XUI_DB" <<EOF
INSERT OR REPLACE INTO settings (key, value) VALUES ('webPort', '$XUI_PORT');
INSERT OR REPLACE INTO settings (key, value) VALUES ('webBasePath', '$XUI_PATH');
INSERT OR REPLACE INTO settings (key, value) VALUES ('username', '$XUI_USERNAME');
INSERT OR REPLACE INTO settings (key, value) VALUES ('password', '$XUI_PASSWORD');
EOF

SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
if [[ -f "$SSL_CERT" && -f "$SSL_KEY" ]]; then
    sqlite3 "$XUI_DB" <<EOF
INSERT OR REPLACE INTO settings (key, value) VALUES ('webCertFile', '$SSL_CERT');
INSERT OR REPLACE INTO settings (key, value) VALUES ('webKeyFile', '$SSL_KEY');
INSERT OR REPLACE INTO settings (key, value) VALUES ('webEnable', 'true');
EOF
    log "HTTPS для панели включён."
else
    sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webEnable', 'false');"
    log "${YELLOW}SSL-сертификаты не найдены, панель будет работать по HTTP.${NC}"
fi

systemctl start x-ui
sleep 3
if ! systemctl is-active --quiet x-ui; then
    log "${RED}Ошибка: панель 3X-UI не запустилась.${NC}"
    exit 1
fi
log "${GREEN}Панель настроена.${NC}"

# ----------------------------------------------------------------------
# Создание inbound VLESS+TLS на порту 443
# ----------------------------------------------------------------------
next_step "Создание inbound VLESS+TLS на порту 443"

sqlite3 "$XUI_DB" "CREATE TABLE IF NOT EXISTS inbounds (
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

if [[ -n "$EXISTING_INBOUND" ]] && [[ "$FORCE_MODE" == false ]]; then
    log "${YELLOW}Inbound на порту 443 уже существует (ID: $INBOUND_ID). Пропуск.${NC}"
    CLIENT_UUID=$(echo "$EXISTING_INBOUND" | cut -d'|' -f2 | jq -r '.clients[0].id' 2>/dev/null || echo "")
else
    if [[ -n "$EXISTING_INBOUND" ]]; then
        log "${YELLOW}Удаление существующего inbound на порту 443...${NC}"
        sqlite3 "$XUI_DB" "DELETE FROM inbounds WHERE port=443;" >> "$LOG_FILE" 2>&1
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

    sqlite3 "$XUI_DB" <<EOF
INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) 
VALUES (1, 0, 0, 0, 'VLESS+TLS', 1, 0, '', 443, 'vless', '$SETTINGS_JSON', '$STREAM_JSON', 'inbound-443', '$SNIFFING_JSON');
EOF
    log "${GREEN}Inbound создан, UUID клиента: $CLIENT_UUID${NC}"
    add_to_env "CLIENT_UUID" "$CLIENT_UUID"
fi

# ----------------------------------------------------------------------
# Перезапуск Xray и проверка
# ----------------------------------------------------------------------
next_step "Перезапуск Xray и проверка"

systemctl restart x-ui
sleep 5

if ! ss -tlnp | grep -q ':443.*xray\|:443.*x-ui'; then
    log "${RED}Ошибка: порт 443 не прослушивается Xray.${NC}"
    log "Проверьте логи: journalctl -u x-ui -n 30"
    exit 1
fi
log "${GREEN}Xray запущен и слушает порт 443.${NC}"

# ----------------------------------------------------------------------
# Настройка UFW
# ----------------------------------------------------------------------
next_step "Настройка брандмауэра (UFW)"

ufw allow 443/tcp comment 'VLESS TCP' >> "$LOG_FILE" 2>&1 || true
ufw allow 443/udp comment 'VLESS UDP' >> "$LOG_FILE" 2>&1 || true
ufw allow "$XUI_PORT"/tcp comment '3X-UI Panel' >> "$LOG_FILE" 2>&1 || true

SUB_PORT=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPort';" 2>/dev/null || echo "2096")
[[ -n "$SUB_PORT" ]] && ufw allow "$SUB_PORT"/tcp comment 'Subscription' >> "$LOG_FILE" 2>&1 || true

ufw reload >> "$LOG_FILE" 2>&1

# ----------------------------------------------------------------------
# Итоговая информация
# ----------------------------------------------------------------------
next_step "Завершение установки"

PROTOCOL="https"
if [[ ! -f "$SSL_CERT" ]]; then
    PROTOCOL="http"
fi
PANEL_URL="${PROTOCOL}://${DOMAIN}:${XUI_PORT}${XUI_PATH}"

echo ""
log "${GREEN}======================================================"
log "${GREEN}✅ VPN-сервер успешно развёрнут!${NC}"
log "${GREEN}======================================================"
echo ""
log "🌐 Панель управления 3X-UI:"
log "   URL: $PANEL_URL"
log "   Логин: $XUI_USERNAME"
log "   Пароль: $XUI_PASSWORD"
echo ""
log "🔐 Параметры VPN-клиента (VLESS + TLS):"
log "   Адрес: $DOMAIN"
log "   Порт: 443"
log "   UUID: ${CLIENT_UUID:-не определён (проверьте в панели)}"
log "   Flow: xtls-rprx-vision"
log "   SNI: $DOMAIN"
log "   ALPN: http/1.1"
echo ""
log "📡 Порт подписок: $SUB_PORT"
if [[ -n "${CLIENT_UUID:-}" ]]; then
    log "   Ссылка: ${PROTOCOL}://${DOMAIN}:${SUB_PORT}/sub/${CLIENT_UUID}"
fi
echo ""
if [[ "$MODE" == "standalone" ]]; then
    log "${YELLOW}ℹ️  Работа в автономном режиме: сайт не установлен.${NC}"
    log "   При необходимости вы можете позже запустить cms.sh для установки CMS."
    log "   Текущий конфиг Nginx будет обновлён автоматически."
fi
log "${YELLOW}⚠️  Убедитесь, что порты 443 и $XUI_PORT открыты в облачном файерволе (если есть).${NC}"
log "======================================================"

exit 0