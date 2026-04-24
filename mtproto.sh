#!/bin/bash
# =====================================================================
# mtproto.sh - Установка MTProto-прокси для Telegram с SNI-маршрутизацией
# Версия: 3.1 (исправленная, с резервным копированием и проверками)
# =====================================================================

set -euo pipefail

# Подключаем общую библиотеку
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    echo -e "\033[0;31mОшибка: файл lib.sh не найден в директории $SCRIPT_DIR.\033[0m"
    exit 1
fi
source "$SCRIPT_DIR/lib.sh"

init_force_mode "$@"

add_to_env() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$SCRIPT_DIR/.env"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$SCRIPT_DIR/.env"
    else
        echo "${key}=\"${value}\"" >> "$SCRIPT_DIR/.env"
    fi
}

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
        log_only "Создана резервная копия $file"
    fi
}

if [[ $EUID -ne 0 ]]; then
    log "${RED}Ошибка: скрипт должен запускаться от root (или с sudo).${NC}"
    exit 1
fi

# --- Принудительная очистка при --force ---
if $FORCE_MODE; then
    log "${YELLOW}Режим --force: очистка старых конфигураций...${NC}"
    rm -f /etc/nginx/sites-enabled/"$DOMAIN"* 2>/dev/null || true
    rm -f /etc/nginx/stream.conf.d/"$DOMAIN"*.conf 2>/dev/null || true
    systemctl stop mtproto-proxy 2>/dev/null || true
    systemctl disable mtproto-proxy 2>/dev/null || true
fi

# --- Определение текущей конфигурации сайта (должен быть выполнен cms.sh) ---
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

DOMAIN=$(detect_domain)
if [[ -z "$DOMAIN" ]]; then
    log "${RED}Не удалось определить домен. Убедитесь, что сайт настроен (выполнен cms.sh).${NC}"
    exit 1
fi
SITE_ROOT=$(detect_site_root "$DOMAIN")
PHP_SOCKET=$(detect_php_socket)
SSL_DIR="/etc/letsencrypt/live/$DOMAIN"
SSL_CERT="$SSL_DIR/fullchain.pem"
SSL_KEY="$SSL_DIR/privkey.pem"

if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
    log "${RED}SSL-сертификаты не найдены. Сначала выполните cms.sh.${NC}"
    exit 1
fi

log "Домен: $DOMAIN, Корень: $SITE_ROOT"
log "SSL-сертификаты найдены."

# --- Определение IP-адреса ---
SERVER_IP=$(ip route get 1 | awk '{print $NF;exit}' 2>/dev/null)
if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
fi
if [[ -z "$SERVER_IP" ]]; then
    log "${RED}Не удалось определить IP-адрес.${NC}"
    exit 1
fi
log_only "IP: $SERVER_IP"

# --- Проверка свободных портов ---
check_port_free() {
    local port=$1
    if ss -tln | grep -q ":$port "; then
        return 1
    fi
    return 0
}

if ! check_port_free 8443; then
    log "${RED}Порт 8443 занят. Не удаётся перенастроить веб-сервер.${NC}"
    exit 1
fi
if ! check_port_free 1443; then
    log "${RED}Порт 1443 занят. Не удаётся запустить MTProto-прокси.${NC}"
    exit 1
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
# 1. Установка зависимостей
# ----------------------------------------------------------------------
next_step "Установка необходимых пакетов"
apt update >> "$LOG_FILE" 2>&1
apt install -y git build-essential libssl-dev zlib1g-dev erlang libsodium-dev >> "$LOG_FILE" 2>&1
log_only "Зависимости установлены."

# ----------------------------------------------------------------------
# 2. Перенастройка веб-сервера на локальный порт
# ----------------------------------------------------------------------
next_step "Перенастройка веб-сервера на локальный порт 8443"
WEB_LOCAL_PORT="8443"
add_to_env "WEB_LOCAL_PORT" "$WEB_LOCAL_PORT"

backup_file "/etc/nginx/sites-available/$DOMAIN"
backup_file "/etc/nginx/sites-available/$DOMAIN-local"

cat > /etc/nginx/sites-available/"$DOMAIN"-local <<EOF
server {
    listen 127.0.0.1:$WEB_LOCAL_PORT;
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

ln -sf /etc/nginx/sites-available/"$DOMAIN"-local /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/"$DOMAIN" 2>/dev/null || true
nginx -t >> "$LOG_FILE" 2>&1
systemctl reload nginx
log "${GREEN}Веб-сервер перенастроен на порт $WEB_LOCAL_PORT.${NC}"

# ----------------------------------------------------------------------
# 3. Установка MTProto-прокси на локальный порт
# ----------------------------------------------------------------------
next_step "Установка MTProto-прокси на локальный порт 1443"
MTPROTO_LOCAL_PORT="1443"
add_to_env "MTPROTO_LOCAL_PORT" "$MTPROTO_LOCAL_PORT"

cd /opt
if [[ ! -d "/opt/MTProxy" ]]; then
    git clone https://github.com/TelegramMessenger/MTProxy.git >> "$LOG_FILE" 2>&1
fi
cd MTProxy
make >> "$LOG_FILE" 2>&1

SECRET=$(head -c 16 /dev/urandom | xxd -ps)
add_to_env "MTPROTO_SECRET" "$SECRET"

cp /opt/MTProxy/objs/bin/mtproto-proxy /usr/local/bin/
cp /opt/MTProxy/proxy-secret /opt/MTProxy/proxy-multi.conf /etc/

backup_file "/etc/systemd/system/mtproto-proxy.service"
cat > /etc/systemd/system/mtproto-proxy.service <<EOF
[Unit]
Description=MTProto Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/MTProxy
ExecStart=/usr/local/bin/mtproto-proxy -u nobody -p 8889 -H $MTPROTO_LOCAL_PORT -S $SECRET --aes-pwd /etc/proxy-secret /etc/proxy-multi.conf -M 1
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtproto-proxy >> "$LOG_FILE" 2>&1
systemctl start mtproto-proxy
sleep 2

if systemctl is-active --quiet mtproto-proxy; then
    log "${GREEN}MTProto-прокси запущен на порту $MTPROTO_LOCAL_PORT.${NC}"
else
    log "${RED}Ошибка: MTProto-прокси не запустился.${NC}"
    journalctl -u mtproto-proxy -n 20 --no-pager | tee -a "$LOG_FILE"
    exit 1
fi

# ----------------------------------------------------------------------
# 4. Настройка SNI-маршрутизации на порту 443
# ----------------------------------------------------------------------
next_step "Настройка SNI-маршрутизации на порту 443"

# Проверяем наличие модуля stream
if ! nginx 2>&1 | grep -q "stream module"; then
    log "${RED}Модуль stream не найден. Переустановите nginx с поддержкой stream_ssl_preread_module.${NC}"
    exit 1
fi

mkdir -p /etc/nginx/stream.conf.d
backup_file "/etc/nginx/stream.conf.d/$DOMAIN-sni.conf"

cat > /etc/nginx/stream.conf.d/"$DOMAIN"-sni.conf <<EOF
stream {
    upstream web_backend {
        server 127.0.0.1:$WEB_LOCAL_PORT;
    }
    upstream mtproto_backend {
        server 127.0.0.1:$MTPROTO_LOCAL_PORT;
    }

    map \$ssl_preread_server_name \$backend {
        $DOMAIN web_backend;
        default mtproto_backend;
    }

    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        proxy_pass \$backend;
        ssl_preread on;
    }
}
EOF

if ! grep -q "include /etc/nginx/stream.conf.d/\*.conf" /etc/nginx/nginx.conf; then
    backup_file "/etc/nginx/nginx.conf"
    sed -i '/http {/i include /etc/nginx/stream.conf.d/*.conf;' /etc/nginx/nginx.conf
fi

nginx -t >> "$LOG_FILE" 2>&1
systemctl reload nginx
log "${GREEN}SNI-маршрутизация настроена.${NC}"

# ----------------------------------------------------------------------
# 5. Настройка UFW
# ----------------------------------------------------------------------
next_step "Настройка брандмауэра"
ufw allow 443/tcp >> "$LOG_FILE" 2>&1
ufw reload >> "$LOG_FILE" 2>&1
log "Порт 443 открыт в UFW."

# ----------------------------------------------------------------------
# 6. Генерация ссылки для Telegram
# ----------------------------------------------------------------------
next_step "Генерация ссылки для Telegram"
PROXY_LINK="tg://proxy?server=$DOMAIN&port=443&secret=$SECRET"
add_to_env "MTPROTO_LINK" "$PROXY_LINK"

# ----------------------------------------------------------------------
# 7. Итоговая информация
# ----------------------------------------------------------------------
next_step "Готово"

echo ""
log "${GREEN}======================================================"
log "${GREEN}✅ MTProto-прокси и SNI-маршрутизация настроены!${NC}"
log "${GREEN}======================================================"
echo ""
log "🌐 Сайт (HTTPS): https://$DOMAIN"
log "🔗 MTProto-прокси для Telegram:"
log "   $PROXY_LINK"
echo ""
log "⚙️ Параметры для ручного ввода:"
log "   Тип прокси: MTProto"
log "   Адрес: $DOMAIN (или $SERVER_IP)"
log "   Порт: 443"
log "   Секрет: $SECRET"
echo ""
log "📁 Локальные порты:"
log "   Веб-сервер: 127.0.0.1:$WEB_LOCAL_PORT"
log "   MTProto-прокси: 127.0.0.1:$MTPROTO_LOCAL_PORT"
echo ""
log "📝 Лог установки: ${LOG_FILE}"
log "======================================================"

exit 0