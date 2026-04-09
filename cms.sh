#!/bin/bash
# =====================================================================
# cms.sh - Полная установка CMS, админ-панели, AI DeepSeek
# Версия: 7.3 (исправлены analytics.php и settings.php)
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

# --- Константы ---
WEB_ROOT_BASE="/var/www"
PHP_VERSION="8.3"
PHP_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
TINYMCE_VERSION="6.8.3"

# --- Проверка прав root ---
if [[ $EUID -ne 0 ]]; then
    log "${RED}Ошибка: скрипт должен запускаться от root (или с sudo).${NC}"
    exit 1
fi

# --- Проверка наличия curl и расширения PHP curl для AI ---
if ! command -v curl &>/dev/null; then
    log "${YELLOW}Установка php8.3-curl...${NC}"
    apt update && apt install -y php8.3-curl >> "$LOG_FILE" 2>&1
    systemctl restart php8.3-fpm
fi

# --- Загрузка/создание .env и запрос параметров ---
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

if [[ -z "${DOMAIN:-}" ]]; then
    ask_var DOMAIN "Введите доменное имя сайта" "example.com" validate_domain
    add_to_env "DOMAIN" "$DOMAIN"
fi

if [[ -z "${ADMIN_EMAIL:-}" ]]; then
    ask_var ADMIN_EMAIL "Введите email администратора (для уведомлений и сертификатов)" "admin@$DOMAIN" validate_email
    add_to_env "ADMIN_EMAIL" "$ADMIN_EMAIL"
fi

set -a
source "$SCRIPT_DIR/.env"
set +a

# --- Выбор SSL (исправлено регулярное выражение) ---
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

    if [[ "$SSL_TYPE" == "existing" ]]; then
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

        SSL_CERT="$CERT_FILE"
        SSL_KEY="$KEY_FILE"
        SSL_CA="$CA_FILE"
        SSL_CERT_DIR="$CERT_DIR"
    fi
fi

add_to_env "NEED_SSL" "$NEED_SSL"
if [[ "$NEED_SSL" == "y" ]]; then
    add_to_env "SSL_TYPE" "$SSL_TYPE"
    if [[ "$SSL_TYPE" == "existing" ]]; then
        add_to_env "SSL_CERT_DIR" "$SSL_CERT_DIR"
        SSL_TARGET="/etc/letsencrypt/live/$DOMAIN"
        mkdir -p "$SSL_TARGET"
        if [[ -n "$SSL_CA" ]]; then
            cat "$SSL_CERT" "$SSL_CA" > "$SSL_TARGET/fullchain.pem"
        else
            cp "$SSL_CERT" "$SSL_TARGET/fullchain.pem"
        fi
        cp "$SSL_KEY" "$SSL_TARGET/privkey.pem"
        chmod 644 "$SSL_TARGET/fullchain.pem"
        chmod 600 "$SSL_TARGET/privkey.pem"
        SSL_CERT_PATH="$SSL_TARGET/fullchain.pem"
        SSL_KEY_PATH="$SSL_TARGET/privkey.pem"
        add_to_env "SSL_CERT_PATH" "$SSL_CERT_PATH"
        add_to_env "SSL_KEY_PATH" "$SSL_KEY_PATH"
        echo -e "${GREEN}Сертификаты сконвертированы и сохранены в $SSL_TARGET${NC}"
    fi
fi

# --- Генерация параметров базы данных ---
if [[ -z "${DB_NAME:-}" ]]; then
    DB_NAME="$(echo "$DOMAIN" | tr '.' '_')"
    add_to_env "DB_NAME" "$DB_NAME"
fi
if [[ -z "${DB_USER:-}" ]]; then
    DB_USER="user_${DB_NAME}"
    add_to_env "DB_USER" "$DB_USER"
fi
if [[ -z "${DB_PASSWORD:-}" ]]; then
    DB_PASSWORD="$(openssl rand -base64 20 | tr -dc 'A-Za-z0-9' | head -c20)"
    add_to_env "DB_PASSWORD" "$DB_PASSWORD"
fi
if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
    ADMIN_PASSWORD="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c16)"
    add_to_env "ADMIN_PASSWORD" "$ADMIN_PASSWORD"
fi
if [[ -z "${SITE_NAME:-}" ]]; then
    SITE_NAME="Мой сайт"
    add_to_env "SITE_NAME" "$SITE_NAME"
fi

# --- Пути ---
SITE_DIR="${WEB_ROOT_BASE}/${DOMAIN}"
ADMIN_DIR="${SITE_DIR}/admin"
UPLOADS_DIR="${SITE_DIR}/uploads"
TEMPLATES_DIR="${SITE_DIR}/templates"
CONFIG_PATH="${SITE_DIR}/config.php"

# --- Шаги ---
TOTAL_STEPS=16
CURRENT_STEP=0

next_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    echo "[${percent}%] $1"
}

# ----------------------------------------------------------------------
# 1. Структура директорий
# ----------------------------------------------------------------------
next_step "Создание структуры директорий сайта"
mkdir -p "$SITE_DIR"/{core,admin,templates,uploads}
mkdir -p "$ADMIN_DIR"/{css,js,includes,api,locale}
chown -R www-data:www-data "$SITE_DIR"
chmod 750 "$UPLOADS_DIR"
log_only "Директории созданы."

# ----------------------------------------------------------------------
# 2. config.php (исправлено: удалена константа-объект)
# ----------------------------------------------------------------------
next_step "Создание config.php"
if [[ ! -f "$CONFIG_PATH" ]] || $FORCE_MODE; then
    cat > "$CONFIG_PATH" <<EOF
<?php
define('SITE_NAME', '${SITE_NAME}');
define('DB_HOST', 'localhost');
define('DB_NAME', '${DB_NAME}');
define('DB_USER', '${DB_USER}');
define('DB_PASS', '${DB_PASSWORD}');
define('DEBUG_MODE', false);

try {
    \$dsn = 'mysql:host=' . DB_HOST . ';dbname=' . DB_NAME . ';charset=utf8mb4';
    \$pdo = new PDO(\$dsn, DB_USER, DB_PASS);
    \$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    // Объект PDO доступен как глобальная переменная
} catch (PDOException \$e) {
    if (DEBUG_MODE) die('Ошибка БД: ' . \$e->getMessage());
    else die('Ошибка подключения к базе данных.');
}
EOF
    chown www-data:www-data "$CONFIG_PATH"
    chmod 644 "$CONFIG_PATH"
    log_only "config.php создан."
else
    log "${YELLOW}config.php уже существует, пропуск.${NC}"
fi

# ----------------------------------------------------------------------
# 3. База данных и пользователь
# ----------------------------------------------------------------------
next_step "Создание базы данных и пользователя"
if [[ -f "/root/.my.cnf" ]]; then
    MYSQL_ROOT_OPTS="--defaults-file=/root/.my.cnf"
else
    log "${RED}Ошибка: /root/.my.cnf не найден. Сначала выполните init.sh.${NC}"
    exit 1
fi

mysql $MYSQL_ROOT_OPTS -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql $MYSQL_ROOT_OPTS -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
mysql $MYSQL_ROOT_OPTS -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
mysql $MYSQL_ROOT_OPTS -e "FLUSH PRIVILEGES;"
log_only "База данных и пользователь созданы."

# ----------------------------------------------------------------------
# 4. Таблицы CMS (включая ai_requests)
# ----------------------------------------------------------------------
next_step "Создание таблиц CMS"
mysql $MYSQL_ROOT_OPTS "$DB_NAME" <<EOF
CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    login VARCHAR(50) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role ENUM('admin','editor','viewer') DEFAULT 'viewer',
    email VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS pages (
    id INT AUTO_INCREMENT PRIMARY KEY,
    slug VARCHAR(100) UNIQUE NOT NULL,
    title VARCHAR(200) NOT NULL,
    content TEXT,
    meta_description VARCHAR(255),
    status ENUM('draft','published') DEFAULT 'draft',
    template VARCHAR(100) DEFAULT 'default',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS settings (
    \`key\` VARCHAR(100) PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS visits (
    id INT AUTO_INCREMENT PRIMARY KEY,
    visit_date DATE NOT NULL,
    visitor_ip VARCHAR(45),
    user_agent TEXT,
    page_url VARCHAR(255),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX (visit_date)
);

CREATE TABLE IF NOT EXISTS server_stats (
    id INT AUTO_INCREMENT PRIMARY KEY,
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    load_1min FLOAT,
    load_5min FLOAT,
    load_15min FLOAT,
    memory_total BIGINT,
    memory_used BIGINT,
    disk_total BIGINT,
    disk_used BIGINT,
    INDEX (recorded_at)
);

CREATE TABLE IF NOT EXISTS sessions (
    session_id VARCHAR(128) PRIMARY KEY,
    data TEXT,
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS files (
    id INT AUTO_INCREMENT PRIMARY KEY,
    original_name VARCHAR(255) NOT NULL,
    path VARCHAR(255) NOT NULL,
    size INT NOT NULL,
    type VARCHAR(100) NOT NULL,
    uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uploaded_by INT NOT NULL,
    INDEX (uploaded_by),
    FOREIGN KEY (uploaded_by) REFERENCES users(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS ai_requests (
    id INT AUTO_INCREMENT PRIMARY KEY,
    prompt TEXT NOT NULL,
    response TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    user_id INT NOT NULL,
    INDEX (user_id),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);
EOF

ADMIN_HASH=$(php -r "echo password_hash('$ADMIN_PASSWORD', PASSWORD_DEFAULT);")
mysql $MYSQL_ROOT_OPTS "$DB_NAME" -e "INSERT IGNORE INTO users (login, password_hash, role, email) VALUES ('admin', '$ADMIN_HASH', 'admin', '$ADMIN_EMAIL');"
log_only "Таблицы CMS и AI созданы, администратор добавлен."

# ---- Инициализация настроек по умолчанию ----
mysql $MYSQL_ROOT_OPTS "$DB_NAME" <<EOF
INSERT INTO settings (\`key\`, \`value\`) VALUES 
('site_name', '${SITE_NAME}'),
('admin_email', '${ADMIN_EMAIL}'),
('admin_theme', 'light'),
('stats_retention', '30'),
('admin_lang', 'ru'),
('deepseek_model', 'deepseek-chat'),
('deepseek_max_tokens', '2000')
ON DUPLICATE KEY UPDATE \`value\` = VALUES(\`value\`);
EOF
log_only "Настройки по умолчанию добавлены в БД."

# ----------------------------------------------------------------------
# 5. Языковые файлы (полные, включая AI, добавлен ключ remove_tracker)
# ----------------------------------------------------------------------
next_step "Создание языковых файлов"

cat > "$ADMIN_DIR/locale/ru.php" <<'RUEOF'
<?php
return [
    'dashboard' => 'Дашборд',
    'users' => 'Пользователи',
    'content' => 'Управление контентом',
    'files' => 'Загруженные файлы',
    'server_stats' => 'Статистика сервера',
    'visitors' => 'Посетители',
    'settings' => 'Настройки',
    'logout' => 'Выход',
    'login' => 'Вход в панель управления',
    'invalid_credentials' => 'Неверный логин или пароль',
    'welcome' => 'Добро пожаловать',
    'cpu_load' => 'CPU Load',
    'ram_usage' => 'RAM',
    'disk_usage' => 'Диск',
    'pages_count' => 'Страниц',
    'visits_last_7_days' => 'Посещаемость за последние 7 дней',
    'last_visits' => 'Последние 5 посещений',
    'time' => 'Время',
    'ip' => 'IP',
    'page' => 'Страница',
    'user_agent' => 'User Agent',
    'total_visits' => 'Всего посещений',
    'unique_ips' => 'Уникальных IP',
    'filter' => 'Фильтр',
    'reset' => 'Сбросить',
    'save' => 'Сохранить',
    'delete' => 'Удалить',
    'edit' => 'Редактировать',
    'add' => 'Добавить',
    'new_page' => 'Новая страница',
    'title' => 'Заголовок',
    'slug' => 'Slug (URL)',
    'content' => 'Содержимое',
    'meta_description' => 'Мета-описание',
    'status' => 'Статус',
    'draft' => 'Черновик',
    'published' => 'Опубликовано',
    'template' => 'Шаблон',
    'source' => 'Источник',
    'database' => 'База данных',
    'file_system' => 'Файловая система',
    'upload_file' => 'Загрузить файл',
    'original_name' => 'Оригинальное имя',
    'size' => 'Размер',
    'type' => 'Тип',
    'uploaded_at' => 'Загружен',
    'site_name' => 'Название сайта',
    'admin_email' => 'Email администратора',
    'admin_theme' => 'Тема админки',
    'light' => 'Светлая',
    'dark' => 'Тёмная',
    'stats_retention' => 'Срок хранения статистики (дней)',
    'admin_lang' => 'Язык админки',
    'search' => 'Поиск',
    'created_at' => 'Дата создания',
    'actions' => 'Действия',
    'file' => 'Файл',
    'slug_auto' => 'Оставьте пустым для автоматической генерации',
    'cancel' => 'Отмена',
    'preview' => 'Предпросмотр',
    'back' => 'Назад',
    'title_required' => 'Заголовок обязателен',
    'slug_exists' => 'Такой URL уже существует',
    'page_created' => 'Страница создана',
    'page_saved' => 'Страница сохранена',
    'edit_page' => 'Редактирование страницы',
    'edit_file' => 'Редактирование файла',
    'code_warning' => 'Файл содержит CSS/JS код. Редактирование в визуальном режиме может повредить оформление.',
    'editing' => 'Редактирование',
    'file_not_found' => 'Файл не найден',
    'file_saved' => 'Файл сохранён. Бэкап: ',
    'file_not_writable' => 'Файл не доступен для записи',
    'error' => 'Ошибка',
    'path' => 'Путь',
    'confirm_delete' => 'Удалить?',
    'file_uploaded' => 'Файл загружен',
    'file_deleted' => 'Файл удалён',
    'select_file' => 'Выберите файл',
    'upload' => 'Загрузить',
    'from' => 'С',
    'to' => 'По',
    'user_added' => 'Пользователь добавлен',
    'user_deleted' => 'Пользователь удалён',
    'existing_users' => 'Существующие пользователи',
    'role' => 'Роль',
    'add_user' => 'Добавить пользователя',
    'password' => 'Пароль',
    'editor' => 'Редактор',
    'viewer' => 'Наблюдатель',
    'settings_saved' => 'Настройки сохранены',
    'visits' => 'Посещения',
    'analytics' => 'Аналитика',
    'inject_tracker' => 'Встроить аналитику',
    'select_files' => 'Выберите файлы для внедрения трекера',
    'tracker_added' => 'Трекер успешно добавлен в выбранные файлы',
    'tracker_removed' => 'Трекер удалён из выбранных файлов',
    'manual_instruction' => 'Ручная установка',
    'manual_text_php' => 'Скопируйте этот код и вставьте в начало каждого PHP-файла (после &lt;?php), для которого нужен сбор статистики:',
    'manual_text_html' => 'Скопируйте этот код и вставьте перед закрывающим тегом &lt;/body&gt; в HTML-файлах:',
    'manual_note' => 'Примечание: Файл /js/tracker.js уже создан системой. Убедитесь, что он доступен по указанному пути.',
    'ai_generator' => 'Генератор AI',
    'ai_history' => 'История AI',
    'remove_tracker' => 'Удалить трекер',
];
RUEOF

cat > "$ADMIN_DIR/locale/en.php" <<'ENEOF'
<?php
return [
    'dashboard' => 'Dashboard',
    'users' => 'Users',
    'content' => 'Content Management',
    'files' => 'Uploaded Files',
    'server_stats' => 'Server Statistics',
    'visitors' => 'Visitors',
    'settings' => 'Settings',
    'logout' => 'Logout',
    'login' => 'Admin Login',
    'invalid_credentials' => 'Invalid login or password',
    'welcome' => 'Welcome',
    'cpu_load' => 'CPU Load',
    'ram_usage' => 'RAM',
    'disk_usage' => 'Disk',
    'pages_count' => 'Pages',
    'visits_last_7_days' => 'Visits (last 7 days)',
    'last_visits' => 'Last 5 visits',
    'time' => 'Time',
    'ip' => 'IP',
    'page' => 'Page',
    'user_agent' => 'User Agent',
    'total_visits' => 'Total visits',
    'unique_ips' => 'Unique IPs',
    'filter' => 'Filter',
    'reset' => 'Reset',
    'save' => 'Save',
    'delete' => 'Delete',
    'edit' => 'Edit',
    'add' => 'Add',
    'new_page' => 'New Page',
    'title' => 'Title',
    'slug' => 'Slug (URL)',
    'content' => 'Content',
    'meta_description' => 'Meta description',
    'status' => 'Status',
    'draft' => 'Draft',
    'published' => 'Published',
    'template' => 'Template',
    'source' => 'Source',
    'database' => 'Database',
    'file_system' => 'File System',
    'upload_file' => 'Upload File',
    'original_name' => 'Original Name',
    'size' => 'Size',
    'type' => 'Type',
    'uploaded_at' => 'Uploaded',
    'site_name' => 'Site Name',
    'admin_email' => 'Admin Email',
    'admin_theme' => 'Admin Theme',
    'light' => 'Light',
    'dark' => 'Dark',
    'stats_retention' => 'Statistics retention (days)',
    'admin_lang' => 'Admin Language',
    'search' => 'Search',
    'created_at' => 'Created at',
    'actions' => 'Actions',
    'file' => 'File',
    'slug_auto' => 'Leave empty to auto-generate',
    'cancel' => 'Cancel',
    'preview' => 'Preview',
    'back' => 'Back',
    'title_required' => 'Title is required',
    'slug_exists' => 'Slug already exists',
    'page_created' => 'Page created',
    'page_saved' => 'Page saved',
    'edit_page' => 'Edit Page',
    'edit_file' => 'Edit File',
    'code_warning' => 'File contains CSS/JS code. Editing in visual mode may break styling.',
    'editing' => 'Editing',
    'file_not_found' => 'File not found',
    'file_saved' => 'File saved. Backup: ',
    'file_not_writable' => 'File is not writable',
    'error' => 'Error',
    'path' => 'Path',
    'confirm_delete' => 'Delete?',
    'file_uploaded' => 'File uploaded',
    'file_deleted' => 'File deleted',
    'select_file' => 'Select file',
    'upload' => 'Upload',
    'from' => 'From',
    'to' => 'To',
    'user_added' => 'User added',
    'user_deleted' => 'User deleted',
    'existing_users' => 'Existing users',
    'role' => 'Role',
    'add_user' => 'Add user',
    'password' => 'Password',
    'editor' => 'Editor',
    'viewer' => 'Viewer',
    'settings_saved' => 'Settings saved',
    'visits' => 'Visits',
    'analytics' => 'Analytics',
    'inject_tracker' => 'Inject analytics',
    'select_files' => 'Select files to inject tracker',
    'tracker_added' => 'Tracker successfully added to selected files',
    'tracker_removed' => 'Tracker removed from selected files',
    'manual_instruction' => 'Manual installation',
    'manual_text_php' => 'Copy this code and paste it at the beginning of each PHP file (after &lt;?php) that needs statistics:',
    'manual_text_html' => 'Copy this code and paste it before the closing &lt;/body&gt; tag in HTML files:',
    'manual_note' => 'Note: The file /js/tracker.js has already been created by the system. Make sure it is accessible at the specified path.',
    'ai_generator' => 'AI Generator',
    'ai_history' => 'AI History',
    'remove_tracker' => 'Remove tracker',
];
ENEOF
log_only "Языковые файлы созданы."

# ----------------------------------------------------------------------
# 6. Создание всех файлов административной панели (включая AI)
# ----------------------------------------------------------------------
next_step "Создание файлов админ-панели"

# 6.1 functions.php
create_php_file "$ADMIN_DIR/includes/functions.php" <<'FUNCS'
<?php
function getSetting($key, $default = "") {
    global $pdo;
    static $settings = null;
    if ($settings === null) {
        $stmt = $pdo->query("SELECT `key`, `value` FROM settings");
        $settings = $stmt->fetchAll(PDO::FETCH_KEY_PAIR);
    }
    return $settings[$key] ?? $default;
}
function setLanguage($lang) { $_SESSION["lang"] = $lang; }
function currentLanguage() { return $_SESSION["lang"] ?? getSetting("admin_lang", "ru"); }
function __($key) {
    static $translations = null;
    $lang = currentLanguage();
    if ($translations === null) {
        $file = __DIR__ . "/../locale/{$lang}.php";
        if (file_exists($file)) $translations = include $file;
        else $translations = include __DIR__ . "/../locale/ru.php";
    }
    return $translations[$key] ?? $key;
}
FUNCS

# 6.2 auth.php
create_php_file "$ADMIN_DIR/includes/auth.php" <<'AUTH'
<?php
session_start();
require_once __DIR__ . "/../../config.php";
require_once __DIR__ . "/functions.php";
function isLoggedIn() { return isset($_SESSION["user_id"]); }
function requireLogin() { if (!isLoggedIn()) { header("Location: /admin/login.php"); exit; } }
function isAdmin() { return isset($_SESSION["role"]) && $_SESSION["role"] === "admin"; }
function requireAdmin() { requireLogin(); if (!isAdmin()) die("Access denied"); }
function currentUser() {
    global $pdo;
    if (!isset($_SESSION["user_id"])) return null;
    $stmt = $pdo->prepare("SELECT * FROM users WHERE id = ?");
    $stmt->execute([$_SESSION["user_id"]]);
    return $stmt->fetch(PDO::FETCH_ASSOC);
}
AUTH

# 6.3 login.php (исправлен: добавлен session_start, обработка lang)
create_php_file "$ADMIN_DIR/login.php" <<'LOGIN'
<?php
session_start();

// Переключение языка через GET
if (isset($_GET["lang"]) && in_array($_GET["lang"], ["ru","en"])) {
    $_SESSION["lang"] = $_GET["lang"];
    header("Location: /admin/login.php");
    exit;
}

require_once __DIR__ . "/../config.php";
require_once "includes/functions.php";
$lang = currentLanguage();
$translations = include "locale/{$lang}.php";
if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $login = $_POST["login"] ?? "";
    $password = $_POST["password"] ?? "";
    $stmt = $pdo->prepare("SELECT * FROM users WHERE login = ?");
    $stmt->execute([$login]);
    $user = $stmt->fetch(PDO::FETCH_ASSOC);
    if ($user && password_verify($password, $user["password_hash"])) {
        $_SESSION["user_id"] = $user["id"];
        $_SESSION["role"] = $user["role"];
        header("Location: /admin/");
        exit;
    } else $error = $translations["invalid_credentials"];
}
?><!DOCTYPE html><html lang="<?= $lang ?>"><head><meta charset="UTF-8"><title><?= $translations["login"] ?></title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="/admin/css/admin.css"><style>body{display:flex;align-items:center;height:100vh;}.login-form{max-width:400px;margin:0 auto;background:var(--card-bg);padding:30px;border-radius:var(--border-radius);border:2px solid var(--accent-gold);}</style></head><body><div class="container"><div class="login-form"><h2 class="text-center mb-4"><?= $translations["login"] ?></h2><?php if(isset($error)) echo "<div class=\"alert alert-danger\">".htmlspecialchars($error)."</div>"; ?><form method="post"><div class="mb-3"><label class="form-label">Login</label><input type="text" class="form-control" name="login" required></div><div class="mb-3"><label class="form-label">Password</label><input type="password" class="form-control" name="password" required></div><button type="submit" class="btn btn-primary w-100"><?= $translations["login"] ?></button></form><div class="mt-3 text-center"><a href="?lang=ru">Русский</a> | <a href="?lang=en">English</a></div></div></div></body></html>
LOGIN

# 6.4 logout.php
create_php_file "$ADMIN_DIR/logout.php" '<?php session_start(); session_destroy(); header("Location: /admin/login.php"); exit;'

# 6.5 header.php (исправлен: добавлен require auth.php)
create_php_file "$ADMIN_DIR/includes/header.php" <<'HEADER'
<?php
require_once __DIR__ . "/auth.php";
if (!isset($pageTitle)) $pageTitle = __("dashboard");
$current_user = currentUser();
$site_name = getSetting("site_name", SITE_NAME);
?><header class="navbar navbar-dark sticky-top bg-dark flex-md-nowrap p-0 shadow"><a class="navbar-brand col-md-3 col-lg-2 me-0 px-3" href="/admin/"><?= htmlspecialchars($site_name) ?></a><button class="navbar-toggler position-absolute d-md-none collapsed" type="button" data-bs-toggle="collapse" data-bs-target="#sidebarMenu"><span class="navbar-toggler-icon"></span></button><div class="w-100"></div><div class="navbar-nav"><div class="nav-item text-nowrap dropdown"><a class="nav-link dropdown-toggle text-white" href="#" id="langDropdown" data-bs-toggle="dropdown"><?= strtoupper(currentLanguage()) ?></a><ul class="dropdown-menu dropdown-menu-end"><li><a class="dropdown-item" href="?lang=ru">Русский</a></li><li><a class="dropdown-item" href="?lang=en">English</a></li></ul></div><div class="nav-item text-nowrap"><span class="nav-link px-3 text-white"><?= htmlspecialchars($current_user["login"] ?? "") ?></span></div></div></header><?php if(isset($_GET["lang"]) && in_array($_GET["lang"], ["ru","en"])) { $_SESSION["lang"] = $_GET["lang"]; header("Location: " . strtok($_SERVER["REQUEST_URI"], "?")); exit; } ?>
HEADER

# 6.6 sidebar.php
create_php_file "$ADMIN_DIR/includes/sidebar.php" <<'SIDEBAR'
<?php $current_page = basename($_SERVER["PHP_SELF"]); ?><nav id="sidebarMenu" class="col-md-3 col-lg-2 d-md-block bg-light sidebar collapse"><div class="position-sticky pt-3"><ul class="nav flex-column"><li class="nav-item"><a class="nav-link <?= $current_page=="index.php"?"active":"" ?>" href="/admin/"><i class="bi bi-speedometer2"></i> <?= __("dashboard") ?></a></li><?php if(isAdmin()): ?><li class="nav-item"><a class="nav-link <?= $current_page=="users.php"?"active":"" ?>" href="/admin/users.php"><i class="bi bi-people"></i> <?= __("users") ?></a></li><?php endif; ?><li class="nav-item"><a class="nav-link <?= $current_page=="content.php"?"active":"" ?>" href="/admin/content.php"><i class="bi bi-files"></i> <?= __("content") ?></a></li><li class="nav-item"><a class="nav-link <?= $current_page=="files.php"?"active":"" ?>" href="/admin/files.php"><i class="bi bi-upload"></i> <?= __("files") ?></a></li><li class="nav-item"><a class="nav-link <?= $current_page=="stats.php"?"active":"" ?>" href="/admin/stats.php"><i class="bi bi-graph-up"></i> <?= __("server_stats") ?></a></li><li class="nav-item"><a class="nav-link <?= $current_page=="visitors.php"?"active":"" ?>" href="/admin/visitors.php"><i class="bi bi-eye"></i> <?= __("visitors") ?></a></li><li class="nav-item"><a class="nav-link <?= $current_page=="analytics.php"?"active":"" ?>" href="/admin/analytics.php"><i class="bi bi-bar-chart-steps"></i> <?= __("analytics") ?></a></li><li class="nav-item"><a class="nav-link <?= $current_page=="ai_generator.php"?"active":"" ?>" href="/admin/ai_generator.php"><i class="bi bi-robot"></i> <?= __("ai_generator") ?></a></li><li class="nav-item"><a class="nav-link <?= $current_page=="ai_history.php"?"active":"" ?>" href="/admin/ai_history.php"><i class="bi bi-clock-history"></i> <?= __("ai_history") ?></a></li><li class="nav-item"><a class="nav-link <?= $current_page=="settings.php"?"active":"" ?>" href="/admin/settings.php"><i class="bi bi-gear"></i> <?= __("settings") ?></a></li><li class="nav-item"><a class="nav-link" href="/admin/logout.php"><i class="bi bi-box-arrow-right"></i> <?= __("logout") ?></a></li></ul></div></nav>
SIDEBAR

# 6.7 index.php (дашборд)
create_php_file "$ADMIN_DIR/index.php" <<'DASHBOARD'
<?php require_once "includes/auth.php"; requireLogin(); $site_name = getSetting("site_name", SITE_NAME); $pageTitle = __("dashboard"); ?>
<!DOCTYPE html><html lang="<?= currentLanguage() ?>"><head><meta charset="UTF-8"><title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css"><link rel="stylesheet" href="/admin/css/admin.css"><script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script></head><body class="theme-<?= getSetting("admin_theme", "light") ?>"><?php include "includes/header.php"; ?><div class="container-fluid"><div class="row"><?php include "includes/sidebar.php"; ?><main class="col-md-9 ms-sm-auto col-lg-10 px-md-4"><div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom"><h1 class="h2"><?= $pageTitle ?></h1></div><div class="row"><?php $load = sys_getloadavg(); $cpu_load = $load[0] ?? 0; $meminfo = file_get_contents("/proc/meminfo"); preg_match("/MemTotal:\s+(\d+)/", $meminfo, $matches); $mem_total = $matches[1] ?? 0; preg_match("/MemAvailable:\s+(\d+)/", $meminfo, $matches); $mem_avail = $matches[1] ?? 0; $mem_used_percent = $mem_total ? round(($mem_total - $mem_avail) / $mem_total * 100, 1) : 0; $disk_total = disk_total_space("/"); $disk_free = disk_free_space("/"); $disk_used_percent = $disk_total ? round(($disk_total - $disk_free) / $disk_total * 100, 1) : 0; $stmt = $pdo->query("SELECT COUNT(*) FROM pages WHERE status=\"published\""); $pages_count = $stmt->fetchColumn(); ?><div class="col-md-3 mb-3"><div class="card text-white bg-primary"><div class="card-body"><h5 class="card-title"><i class="bi bi-cpu"></i> <?= __("cpu_load") ?></h5><p class="display-6"><?= $cpu_load ?></p></div></div></div><div class="col-md-3 mb-3"><div class="card text-white bg-success"><div class="card-body"><h5 class="card-title"><i class="bi bi-memory"></i> <?= __("ram_usage") ?></h5><p class="display-6"><?= $mem_used_percent ?>%</p></div></div></div><div class="col-md-3 mb-3"><div class="card text-white bg-warning"><div class="card-body"><h5 class="card-title"><i class="bi bi-hdd"></i> <?= __("disk_usage") ?></h5><p class="display-6"><?= $disk_used_percent ?>%</p></div></div></div><div class="col-md-3 mb-3"><div class="card text-white bg-info"><div class="card-body"><h5 class="card-title"><i class="bi bi-file-text"></i> <?= __("pages_count") ?></h5><p class="display-6"><?= $pages_count ?></p></div></div></div></div><div class="row mt-4"><div class="col-md-12"><div class="card"><div class="card-header"><i class="bi bi-bar-chart-line"></i> <?= __("visits_last_7_days") ?></div><div class="card-body"><canvas id="visitsChart" style="height:300px;"></canvas></div></div></div></div><div class="row mt-4"><div class="col-md-12"><div class="card"><div class="card-header"><i class="bi bi-clock-history"></i> <?= __("last_visits") ?></div><div class="card-body"><table class="table table-sm"><thead><tr><th><?= __("time") ?></th><th><?= __("ip") ?></th><th><?= __("page") ?></th><th><?= __("user_agent") ?></th></tr></thead><tbody><?php $stmt = $pdo->query("SELECT * FROM visits ORDER BY created_at DESC LIMIT 5"); while($row = $stmt->fetch(PDO::FETCH_ASSOC)): ?><tr><td><?= htmlspecialchars($row["created_at"]) ?></td><td><?= htmlspecialchars($row["visitor_ip"]) ?></td><td><?= htmlspecialchars($row["page_url"]) ?></td><td><?= htmlspecialchars(substr($row["user_agent"],0,50)) ?>…</td></tr><?php endwhile; ?></tbody></table></div></div></div></div></main></div></div><script>fetch("/admin/api/visits_last_7.php").then(r=>r.json()).then(data=>{new Chart(document.getElementById("visitsChart"),{type:"line",data:{labels:data.labels,datasets:[{label:"<?= __("visits") ?>",data:data.values,borderColor:"rgb(75,192,192)",tension:0.1}]}})});</script><script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script></body></html>
DASHBOARD

# 6.8 API visits_last_7.php
create_php_file "$ADMIN_DIR/api/visits_last_7.php" '<?php require_once __DIR__ . "/../../config.php"; $stmt = $pdo->query("SELECT DATE(visit_date) as day, COUNT(*) as cnt FROM visits WHERE visit_date >= DATE_SUB(CURDATE(), INTERVAL 6 DAY) GROUP BY day ORDER BY day"); $data = ["labels" => [], "values" => []]; while($row = $stmt->fetch(PDO::FETCH_ASSOC)) { $data["labels"][] = $row["day"]; $data["values"][] = (int)$row["cnt"]; } header("Content-Type: application/json"); echo json_encode($data);'

# 6.9 API server_stats.php
create_php_file "$ADMIN_DIR/api/server_stats.php" '<?php require_once __DIR__ . "/../../config.php"; $type = $_GET["type"] ?? "cpu"; $period = $_GET["period"] ?? 24; $stmt = $pdo->prepare("SELECT recorded_at, load_1min, memory_used, disk_used FROM server_stats WHERE recorded_at >= DATE_SUB(NOW(), INTERVAL :period HOUR) ORDER BY recorded_at"); $stmt->execute(["period" => $period]); $rows = $stmt->fetchAll(PDO::FETCH_ASSOC); $labels = []; $values = []; foreach($rows as $row) { $labels[] = date("H:i", strtotime($row["recorded_at"])); if($type === "cpu") $values[] = $row["load_1min"]; elseif($type === "ram") $values[] = round($row["memory_used"] / 1024 / 1024, 2); elseif($type === "disk") $values[] = round($row["disk_used"] / 1024 / 1024 / 1024, 2); } header("Content-Type: application/json"); echo json_encode(["labels" => $labels, "values" => $values]);'

# 6.10 stats.php
create_php_file "$ADMIN_DIR/stats.php" <<'STATS'
<?php require_once "includes/auth.php"; requireLogin(); $site_name = getSetting("site_name", SITE_NAME); $pageTitle = __("server_stats"); ?><!DOCTYPE html><html lang="<?= currentLanguage() ?>"><head><meta charset="UTF-8"><title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css"><link rel="stylesheet" href="/admin/css/admin.css"><script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script></head><body class="theme-<?= getSetting("admin_theme", "light") ?>"><?php include "includes/header.php"; ?><div class="container-fluid"><div class="row"><?php include "includes/sidebar.php"; ?><main class="col-md-9 ms-sm-auto col-lg-10 px-md-4"><div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom"><h1 class="h2"><?= $pageTitle ?></h1></div><div class="row"><div class="col-md-12 mb-4"><canvas id="cpuChart" style="height:200px;"></canvas></div><div class="col-md-12 mb-4"><canvas id="ramChart" style="height:200px;"></canvas></div><div class="col-md-12 mb-4"><canvas id="diskChart" style="height:200px;"></canvas></div></div></main></div></div><script>fetch("/admin/api/server_stats.php?type=cpu").then(r=>r.json()).then(d=>{new Chart(document.getElementById("cpuChart"),{type:"line",data:{labels:d.labels,datasets:[{label:"Load Average (1 min)",data:d.values,borderColor:"rgb(255,99,132)",tension:0.1}]},options:{responsive:true,maintainAspectRatio:false}})});fetch("/admin/api/server_stats.php?type=ram").then(r=>r.json()).then(d=>{new Chart(document.getElementById("ramChart"),{type:"line",data:{labels:d.labels,datasets:[{label:"RAM (MB)",data:d.values,borderColor:"rgb(54,162,235)",tension:0.1}]},options:{responsive:true,maintainAspectRatio:false}})});fetch("/admin/api/server_stats.php?type=disk").then(r=>r.json()).then(d=>{new Chart(document.getElementById("diskChart"),{type:"line",data:{labels:d.labels,datasets:[{label:"Disk (GB)",data:d.values,borderColor:"rgb(75,192,192)",tension:0.1}]},options:{responsive:true,maintainAspectRatio:false}})});</script><script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script></body></html>
STATS

# 6.11 visitors.php
create_php_file "$ADMIN_DIR/visitors.php" <<'VISITORS'
<?php require_once "includes/auth.php"; requireLogin(); $site_name = getSetting("site_name", SITE_NAME); $pageTitle = __("visitors"); $date_from = $_GET["date_from"] ?? date("Y-m-d", strtotime("-7 days")); $date_to = $_GET["date_to"] ?? date("Y-m-d"); $ip_filter = $_GET["ip"] ?? ""; $sql = "SELECT * FROM visits WHERE visit_date BETWEEN :from AND :to"; $params = ["from" => $date_from, "to" => $date_to]; if($ip_filter) { $sql .= " AND visitor_ip LIKE :ip"; $params["ip"] = "%$ip_filter%"; } $sql .= " ORDER BY created_at DESC"; $stmt = $pdo->prepare($sql); $stmt->execute($params); $visits = $stmt->fetchAll(PDO::FETCH_ASSOC); $total_visits = count($visits); $unique_ips = count(array_unique(array_column($visits, "visitor_ip"))); ?><!DOCTYPE html><html lang="<?= currentLanguage() ?>"><head><meta charset="UTF-8"><title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css"><link rel="stylesheet" href="/admin/css/admin.css"></head><body class="theme-<?= getSetting("admin_theme", "light") ?>"><?php include "includes/header.php"; ?><div class="container-fluid"><div class="row"><?php include "includes/sidebar.php"; ?><main class="col-md-9 ms-sm-auto col-lg-10 px-md-4"><div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom"><h1 class="h2"><?= $pageTitle ?></h1></div><div class="row mb-3"><div class="col-md-3"><div class="card text-white bg-info"><div class="card-body"><h5 class="card-title"><?= __("total_visits") ?></h5><p class="display-6"><?= $total_visits ?></p></div></div></div><div class="col-md-3"><div class="card text-white bg-success"><div class="card-body"><h5 class="card-title"><?= __("unique_ips") ?></h5><p class="display-6"><?= $unique_ips ?></p></div></div></div></div><form method="get" class="row g-3 mb-4"><div class="col-auto"><label class="form-label"><?= __("from") ?>:</label><input type="date" class="form-control" name="date_from" value="<?= $date_from ?>"></div><div class="col-auto"><label class="form-label"><?= __("to") ?>:</label><input type="date" class="form-control" name="date_to" value="<?= $date_to ?>"></div><div class="col-auto"><label class="form-label">IP</label><input type="text" class="form-control" name="ip" placeholder="часть IP" value="<?= htmlspecialchars($ip_filter) ?>"></div><div class="col-auto align-self-end"><button type="submit" class="btn btn-primary"><?= __("filter") ?></button><a href="visitors.php" class="btn btn-secondary ms-2"><?= __("reset") ?></a></div></form><table class="table table-striped"><thead><tr><th><?= __("time") ?></th><th><?= __("ip") ?></th><th><?= __("page") ?></th><th><?= __("user_agent") ?></th></tr></thead><tbody><?php foreach($visits as $v): ?><tr><td><?= htmlspecialchars($v["created_at"]) ?></td><td><?= htmlspecialchars($v["visitor_ip"]) ?></td><td><?= htmlspecialchars($v["page_url"]) ?></td><td><?= htmlspecialchars($v["user_agent"]) ?></td></tr><?php endforeach; ?></tbody></table></main></div></div><script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script></body></html>
VISITORS

# 6.12 settings.php (исправлены неопределённые константы)
next_step "Создание страницы настроек (settings.php)"
create_php_file "$ADMIN_DIR/settings.php" <<'EOF'
<?php
require_once "includes/auth.php";
requireAdmin();

$site_name = getSetting("site_name", "Мой сайт");
$pageTitle = "Настройки";

$settings = [];
$stmt = $pdo->query("SELECT `key`, `value` FROM settings");
while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
    $settings[$row["key"]] = $row["value"];
}

if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $keys = ['site_name', 'admin_email', 'admin_theme', 'stats_retention', 'admin_lang', 'deepseek_api_key', 'deepseek_model', 'deepseek_max_tokens'];
    foreach ($keys as $key) {
        if (isset($_POST[$key])) {
            $value = $_POST[$key];
            $pdo->prepare("INSERT INTO settings (`key`, `value`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)")
                ->execute([$key, $value]);
        }
    }
    $message = "<div class=\"alert alert-success\">Настройки сохранены</div>";
    $stmt = $pdo->query("SELECT `key`, `value` FROM settings");
    $settings = [];
    while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
        $settings[$row["key"]] = $row["value"];
    }
}
?>
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <link rel="stylesheet" href="/admin/css/admin.css">
</head>
<body class="theme-<?= getSetting("admin_theme", "light") ?>">
    <?php include "includes/header.php"; ?>
    <div class="container-fluid">
        <div class="row">
            <?php include "includes/sidebar.php"; ?>
            <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4">
                <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
                    <h1 class="h2"><?= $pageTitle ?></h1>
                </div>

                <?php if (isset($message)) echo $message; ?>

                <form method="post">
                    <div class="mb-3">
                        <label for="site_name" class="form-label">Название сайта</label>
                        <input type="text" class="form-control" id="site_name" name="site_name" value="<?= htmlspecialchars($settings["site_name"] ?? getSetting("site_name", "Мой сайт")) ?>">
                    </div>
                    <div class="mb-3">
                        <label for="admin_email" class="form-label">Email администратора</label>
                        <input type="email" class="form-control" id="admin_email" name="admin_email" value="<?= htmlspecialchars($settings["admin_email"] ?? getSetting("admin_email", "")) ?>">
                    </div>
                    <div class="mb-3">
                        <label for="theme" class="form-label">Тема админки</label>
                        <select class="form-select" id="theme" name="admin_theme">
                            <option value="light" <?= ($settings["admin_theme"] ?? "light") == "light" ? "selected" : "" ?>>Светлая</option>
                            <option value="dark" <?= ($settings["admin_theme"] ?? "") == "dark" ? "selected" : "" ?>>Тёмная</option>
                        </select>
                    </div>
                    <div class="mb-3">
                        <label for="stats_retention" class="form-label">Срок хранения статистики (дней)</label>
                        <input type="number" class="form-control" id="stats_retention" name="stats_retention" value="<?= htmlspecialchars($settings["stats_retention"] ?? 30) ?>" min="1" max="365">
                    </div>
                    <div class="mb-3">
                        <label for="admin_lang" class="form-label">Язык админки</label>
                        <select class="form-select" id="admin_lang" name="admin_lang">
                            <option value="ru" <?= ($settings["admin_lang"] ?? "ru") == "ru" ? "selected" : "" ?>>Русский</option>
                            <option value="en" <?= ($settings["admin_lang"] ?? "") == "en" ? "selected" : "" ?>>English</option>
                        </select>
                    </div>
                    <hr>
                    <h4 class="mt-4">DeepSeek AI Settings</h4>
                    <div class="mb-3">
                        <label for="deepseek_api_key" class="form-label">API Key DeepSeek</label>
                        <input type="password" class="form-control" id="deepseek_api_key" name="deepseek_api_key" value="<?= htmlspecialchars($settings["deepseek_api_key"] ?? "") ?>">
                        <div class="form-text">Получите ключ на platform.deepseek.com</div>
                    </div>
                    <div class="mb-3">
                        <label for="deepseek_model" class="form-label">Модель</label>
                        <select class="form-select" id="deepseek_model" name="deepseek_model">
                            <option value="deepseek-chat" <?= ($settings["deepseek_model"] ?? "deepseek-chat") == "deepseek-chat" ? "selected" : "" ?>>DeepSeek Chat</option>
                            <option value="deepseek-coder" <?= ($settings["deepseek_model"] ?? "") == "deepseek-coder" ? "selected" : "" ?>>DeepSeek Coder</option>
                        </select>
                    </div>
                    <div class="mb-3">
                        <label for="deepseek_max_tokens" class="form-label">Max tokens</label>
                        <input type="number" class="form-control" id="deepseek_max_tokens" name="deepseek_max_tokens" value="<?= htmlspecialchars($settings["deepseek_max_tokens"] ?? 2000) ?>" min="100" max="8000">
                    </div>
                    <button type="submit" class="btn btn-primary">Сохранить</button>
                </form>
            </main>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF
chown www-data:www-data "$ADMIN_DIR/settings.php"
chmod 644 "$ADMIN_DIR/settings.php"
log_only "settings.php создан."

# 6.13 users.php
create_php_file "$ADMIN_DIR/users.php" <<'USERS'
<?php
require_once "includes/auth.php";
requireAdmin();
$message = "";
if ($_SERVER["REQUEST_METHOD"] === "POST") {
    if (isset($_POST["add"])) {
        $login = $_POST["login"];
        $password = $_POST["password"];
        $role = $_POST["role"];
        $email = $_POST["email"];
        $hash = password_hash($password, PASSWORD_DEFAULT);
        $stmt = $pdo->prepare("INSERT INTO users (login, password_hash, role, email) VALUES (?,?,?,?)");
        if ($stmt->execute([$login, $hash, $role, $email])) {
            $message = "<div class=\"alert alert-success\">".__("user_added")."</div>";
        } else {
            $message = "<div class=\"alert alert-danger\">".__("error")."</div>";
        }
    } elseif (isset($_POST["delete"])) {
        $id = $_POST["id"];
        $stmt = $pdo->prepare("DELETE FROM users WHERE id = ? AND role != \"admin\"");
        if ($stmt->execute([$id])) {
            $message = "<div class=\"alert alert-success\">".__("user_deleted")."</div>";
        } else {
            $message = "<div class=\"alert alert-danger\">".__("error")."</div>";
        }
    }
}
$users = $pdo->query("SELECT * FROM users ORDER BY id")->fetchAll(PDO::FETCH_ASSOC);
$site_name = getSetting("site_name", SITE_NAME);
$pageTitle = __("users");
?>
<!DOCTYPE html>
<html lang="<?= currentLanguage() ?>">
<head>
    <meta charset="UTF-8">
    <title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <link rel="stylesheet" href="/admin/css/admin.css">
</head>
<body class="theme-<?= getSetting("admin_theme", "light") ?>">
    <?php include "includes/header.php"; ?>
    <div class="container-fluid">
        <div class="row">
            <?php include "includes/sidebar.php"; ?>
            <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4">
                <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
                    <h1 class="h2"><?= $pageTitle ?></h1>
                </div>
                <?= $message ?>
                <div class="row">
                    <div class="col-md-6">
                        <h4><?= __("existing_users") ?></h4>
                        <table class="table table-striped">
                            <thead>
                                <tr>
                                    <th>ID</th>
                                    <th><?= __("login") ?></th>
                                    <th><?= __("role") ?></th>
                                    <th>Email</th>
                                    <th><?= __("actions") ?></th>
                                </tr>
                            </thead>
                            <tbody>
                                <?php foreach ($users as $user): ?>
                                <tr>
                                    <td><?= $user["id"] ?></td>
                                    <td><?= htmlspecialchars($user["login"]) ?></td>
                                    <td><?= $user["role"] ?></td>
                                    <td><?= htmlspecialchars($user["email"]) ?></td>
                                    <td>
                                        <?php if ($user["role"] !== "admin"): ?>
                                        <form method="post" style="display:inline;">
                                            <input type="hidden" name="id" value="<?= $user["id"] ?>">
                                            <button type="submit" name="delete" class="btn btn-sm btn-danger" onclick="return confirm('<?= __("confirm_delete") ?>')"><i class="bi bi-trash"></i></button>
                                        </form>
                                        <?php endif; ?>
                                    </td>
                                </tr>
                                <?php endforeach; ?>
                            </tbody>
                        </table>
                    </div>
                    <div class="col-md-6">
                        <h4><?= __("add_user") ?></h4>
                        <form method="post">
                            <div class="mb-3">
                                <label class="form-label"><?= __("login") ?></label>
                                <input type="text" class="form-control" name="login" required>
                            </div>
                            <div class="mb-3">
                                <label class="form-label"><?= __("password") ?></label>
                                <input type="password" class="form-control" name="password" required>
                            </div>
                            <div class="mb-3">
                                <label class="form-label"><?= __("role") ?></label>
                                <select class="form-select" name="role">
                                    <option value="editor"><?= __("editor") ?></option>
                                    <option value="viewer"><?= __("viewer") ?></option>
                                </select>
                            </div>
                            <div class="mb-3">
                                <label class="form-label">Email</label>
                                <input type="email" class="form-control" name="email">
                            </div>
                            <button type="submit" name="add" class="btn btn-primary"><?= __("add") ?></button>
                        </form>
                    </div>
                </div>
            </main>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
USERS

# 6.14 content_functions.php
create_php_file "$ADMIN_DIR/includes/content_functions.php" <<'CONTENT_FUNCS'
<?php
function getPageStatus($status) { return $status == "published" ? __("published") : __("draft"); }
function getPageStatusBadge($status) { $class = $status == "published" ? "success" : "secondary"; return "<span class=\"badge bg-{$class}\">".getPageStatus($status)."</span>"; }
function getPageTemplates() { $templates = []; $dir = __DIR__ . "/../../templates"; if(is_dir($dir)) foreach(glob($dir . "/*.php") as $file) $templates[] = basename($file, ".php"); if(empty($templates)) $templates[] = "default"; return $templates; }
function generateSlug($title) { $slug = preg_replace("/[^a-z0-9-]+/", "-", strtolower($title)); $slug = trim($slug, "-"); return $slug ?: "page"; }
CONTENT_FUNCS

# 6.15 content.php
create_php_file "$ADMIN_DIR/content.php" <<'CONTENT'
<?php require_once __DIR__ . "/../config.php"; require_once "includes/auth.php"; requireLogin(); require_once "includes/content_functions.php"; $site_name = getSetting("site_name", SITE_NAME); $pageTitle = __("content"); $root_dir = __DIR__ . "/../"; $excluded_files = ["config.php","cms-router.php","index.php"]; $excluded_dirs = ["admin","uploads","core","templates","tinymce"]; $search = trim($_GET["search"] ?? ""); $order_by = $_GET["order_by"] ?? "created_at"; $order_dir = strtoupper($_GET["order_dir"] ?? "DESC"); $allowed_order = ["title","source","created_at"]; if(!in_array($order_by, $allowed_order)) $order_by = "created_at"; $order_dir = ($order_dir === "ASC") ? "ASC" : "DESC"; $db_pages = $pdo->query("SELECT id, title, slug, status, created_at, \"database\" as source FROM pages ORDER BY created_at DESC")->fetchAll(PDO::FETCH_ASSOC); $existing_slugs = array_column($db_pages, "slug"); $file_pages = []; $dir_handle = opendir($root_dir); while($entry = readdir($dir_handle)) { if($entry == "." || $entry == "..") continue; $full_path = $root_dir . $entry; if(is_dir($full_path)) continue; $ext = pathinfo($entry, PATHINFO_EXTENSION); $slug_without_ext = pathinfo($entry, PATHINFO_FILENAME); if(in_array($slug_without_ext, $existing_slugs)) continue; if(in_array($ext, ["php","html","htm"]) && !in_array($entry, $excluded_files)) { $file_pages[] = ["id" => null, "title" => $slug_without_ext, "slug" => $entry, "status" => "file", "created_at" => date("Y-m-d H:i:s", filemtime($full_path)), "source" => "file"]; } } closedir($dir_handle); if($search) { $db_pages = array_filter($db_pages, fn($i) => stripos($i["title"], $search) !== false); $file_pages = array_filter($file_pages, fn($i) => stripos($i["title"], $search) !== false); } $all_pages = array_merge($db_pages, $file_pages); usort($all_pages, function($a, $b) use ($order_by, $order_dir) { $val_a = $a[$order_by] ?? ""; $val_b = $b[$order_by] ?? ""; if($order_by === "created_at") { $val_a = strtotime($val_a); $val_b = strtotime($val_b); } return $order_dir === "ASC" ? $val_a <=> $val_b : $val_b <=> $val_a; }); function sort_link($field, $current_field, $current_dir) { $new_dir = ($current_field == $field && $current_dir == "DESC") ? "ASC" : "DESC"; $params = $_GET; $params["order_by"] = $field; $params["order_dir"] = $new_dir; $query = http_build_query($params); return "?$query"; } ?><!DOCTYPE html><html lang="<?= currentLanguage() ?>"><head><meta charset="UTF-8"><title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css"><link rel="stylesheet" href="/admin/css/admin.css"></head><body class="theme-<?= getSetting("admin_theme", "light") ?>"><?php include "includes/header.php"; ?><div class="container-fluid"><div class="row"><?php include "includes/sidebar.php"; ?><main class="col-md-9 ms-sm-auto col-lg-10 px-md-4"><div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom"><h1 class="h2"><?= $pageTitle ?></h1><div><a href="edit_page.php" class="btn btn-sm btn-primary"><i class="bi bi-plus"></i> <?= __("new_page") ?></a></div></div><form method="get" class="row g-3 mb-4"><div class="col-auto"><input type="text" class="form-control" name="search" placeholder="<?= __("search") ?>" value="<?= htmlspecialchars($search) ?>"></div><div class="col-auto"><button type="submit" class="btn btn-primary"><?= __("filter") ?></button><a href="content.php" class="btn btn-secondary"><?= __("reset") ?></a></div></form><div class="table-responsive"><table class="table table-striped"><thead><tr><th><a href="<?= sort_link("title", $order_by, $order_dir) ?>"><?= __("title") ?></a></th><th><?= __("slug") ?></th><th><?= __("status") ?></th><th><a href="<?= sort_link("source", $order_by, $order_dir) ?>"><?= __("source") ?></a></th><th><a href="<?= sort_link("created_at", $order_by, $order_dir) ?>"><?= __("created_at") ?></a></th><th><?= __("actions") ?></th></tr></thead><tbody><?php foreach($all_pages as $item): ?><tr><td><?= htmlspecialchars($item["title"]) ?></td><td><?= htmlspecialchars($item["slug"]) ?></td><td><?php if($item["source"] == "database"): ?><?= getPageStatusBadge($item["status"]) ?><?php else: ?><span class="badge bg-secondary"><?= __("file") ?></span><?php endif; ?></td><td><?php if($item["source"] == "database"): ?><i class="bi bi-database"></i> <?= __("database") ?><?php else: ?><i class="bi bi-file-earmark-code"></i> <?= __("file_system") ?><?php endif; ?></td><td><?= htmlspecialchars($item["created_at"]) ?></td><td><?php if($item["source"] == "database"): ?><a href="edit_page.php?id=<?= $item["id"] ?>" class="btn btn-sm btn-primary"><i class="bi bi-pencil"></i> <?= __("edit") ?></a><a href="delete_page.php?id=<?= $item["id"] ?>" class="btn btn-sm btn-danger" onclick="return confirm(\'<?= __("confirm_delete") ?>\')"><i class="bi bi-trash"></i></a><?php else: ?><a href="edit_file.php?file=<?= urlencode($item["slug"]) ?>" class="btn btn-sm btn-primary"><i class="bi bi-pencil"></i> <?= __("edit") ?></a><?php endif; ?></td></tr><?php endforeach; ?></tbody></table></div></main></div></div><script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script></body></html>
CONTENT

# 6.16 edit_page.php
create_php_file "$ADMIN_DIR/edit_page.php" <<'EDITPAGE'
<?php require_once __DIR__ . "/../config.php"; require_once "includes/auth.php"; requireLogin(); require_once "includes/content_functions.php"; $site_name = getSetting("site_name", SITE_NAME); $pageTitle = __("edit_page"); $id = isset($_GET["id"]) ? (int)$_GET["id"] : 0; $is_new = $id === 0; if($is_new) { $page = ["id"=>0,"title"=>"","slug"=>"","content"=>"","meta_description"=>"","status"=>"draft","template"=>"default"]; } else { $stmt = $pdo->prepare("SELECT * FROM pages WHERE id = ?"); $stmt->execute([$id]); $page = $stmt->fetch(PDO::FETCH_ASSOC); if(!$page) die("Page not found"); } // Предзаполнение из GET-параметров (для AI) if(isset($_GET["prefill_title"])) { $page["title"] = htmlspecialchars($_GET["prefill_title"]); $page["content"] = $_GET["prefill_content"] ?? ""; } $message = ""; if($_SERVER["REQUEST_METHOD"] === "POST") { $title = trim($_POST["title"] ?? ""); $slug = trim($_POST["slug"] ?? ""); $content = $_POST["content"] ?? ""; $meta_description = trim($_POST["meta_description"] ?? ""); $status = $_POST["status"] ?? "draft"; $template = $_POST["template"] ?? "default"; $errors = []; if(empty($title)) $errors[] = __("title_required"); if(empty($slug)) $slug = generateSlug($title); $stmt = $pdo->prepare("SELECT id FROM pages WHERE slug = ? AND id != ?"); $stmt->execute([$slug, $id]); if($stmt->fetch()) $errors[] = __("slug_exists"); if(empty($errors)) { if($is_new) { $stmt = $pdo->prepare("INSERT INTO pages (title, slug, content, meta_description, status, template) VALUES (?,?,?,?,?,?)"); $stmt->execute([$title, $slug, $content, $meta_description, $status, $template]); $message = "<div class=\"alert alert-success\">".__("page_created")."</div>"; $id = $pdo->lastInsertId(); $is_new = false; } else { $stmt = $pdo->prepare("UPDATE pages SET title = ?, slug = ?, content = ?, meta_description = ?, status = ?, template = ? WHERE id = ?"); $stmt->execute([$title, $slug, $content, $meta_description, $status, $template, $id]); $message = "<div class=\"alert alert-success\">".__("page_saved")."</div>"; } $stmt = $pdo->prepare("SELECT * FROM pages WHERE id = ?"); $stmt->execute([$id]); $page = $stmt->fetch(PDO::FETCH_ASSOC); } else { $message = "<div class=\"alert alert-danger\"><ul><li>".implode("</li><li>", $errors)."</li></ul></div>"; } } $templates = getPageTemplates(); ?><!DOCTYPE html><html lang="<?= currentLanguage() ?>"><head><meta charset="UTF-8"><title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css"><link rel="stylesheet" href="/admin/css/admin.css"><script src="/admin/tinymce/tinymce.min.js" referrerpolicy="origin"></script><script>tinymce.init({selector:"#content",height:500,plugins:"advlist anchor autolink autosave code codesample directionality emoticons fullscreen help hr image insertdatetime link lists media nonbreaking pagebreak paste preview print save searchreplace table visualblocks visualchars wordcount",toolbar:"undo redo | styles | bold italic underline strikethrough removeformat | alignleft aligncenter alignright alignjustify | bullist numlist outdent indent | link anchor image media | forecolor backcolor | fontselect fontsizeselect | code codesample | table | hr charmap pagebreak | visualblocks visualchars | fullscreen preview | wordcount save print | searchreplace | help",toolbar_mode:"floating",fontsize_formats:"8pt 10pt 12pt 14pt 16pt 18pt 24pt 36pt",image_title:true,automatic_uploads:true,images_upload_url:"/admin/upload.php",file_picker_types:"image",file_picker_callback:function(cb,value,meta){var input=document.createElement("input");input.setAttribute("type","file");input.setAttribute("accept","image/*");input.onchange=function(){var file=this.files[0];var formData=new FormData();formData.append("file",file);fetch("/admin/upload.php",{method:"POST",body:formData}).then(response=>response.json()).then(result=>{cb(result.location,{title:result.original_name});}).catch(error=>console.error(error));};input.click();},content_css:"/admin/css/editor.css",external_plugins:{"ai_button":"/admin/js/ai_tinymce_plugin.js"}});function previewPage(){var title=document.getElementById("title").value;var content=tinymce.get("content").getContent();var win=window.open("","_blank","width=1024,height=768");win.document.write(`<!DOCTYPE html><html><head><title>${escapeHtml(title)}</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"></head><body><h1>${escapeHtml(title)}</h1>${content}</body></html>`);win.document.close();}function escapeHtml(text){var div=document.createElement("div");div.appendChild(document.createTextNode(text));return div.innerHTML;}</script></head><body class="theme-<?= getSetting("admin_theme", "light") ?>"><?php include "includes/header.php"; ?><div class="container-fluid"><div class="row"><?php include "includes/sidebar.php"; ?><main class="col-md-9 ms-sm-auto col-lg-10 px-md-4"><div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom"><h1 class="h2"><?= $is_new ? __("new_page") : __("edit_page") ?></h1><div><button type="button" class="btn btn-sm btn-info" onclick="previewPage()"><i class="bi bi-eye"></i> <?= __("preview") ?></button><a href="content.php" class="btn btn-sm btn-secondary ms-2"><i class="bi bi-arrow-left"></i> <?= __("back") ?></a></div></div><?= $message ?><form method="post"><div class="mb-3"><label class="form-label"><?= __("title") ?> *</label><input type="text" class="form-control" id="title" name="title" value="<?= htmlspecialchars($page["title"]) ?>" required></div><div class="mb-3"><label class="form-label"><?= __("slug") ?></label><input type="text" class="form-control" id="slug" name="slug" value="<?= htmlspecialchars($page["slug"]) ?>"><div class="form-text"><?= __("slug_auto") ?></div></div><div class="mb-3"><label class="form-label"><?= __("content") ?></label><textarea class="form-control" id="content" name="content" rows="10"><?= htmlspecialchars($page["content"]) ?></textarea></div><div class="mb-3"><label class="form-label"><?= __("meta_description") ?></label><textarea class="form-control" id="meta_description" name="meta_description" rows="3"><?= htmlspecialchars($page["meta_description"]) ?></textarea></div><div class="mb-3"><label class="form-label"><?= __("status") ?></label><select class="form-select" name="status"><option value="draft" <?= $page["status"] == "draft" ? "selected" : "" ?>><?= __("draft") ?></option><option value="published" <?= $page["status"] == "published" ? "selected" : "" ?>><?= __("published") ?></option></select></div><div class="mb-3"><label class="form-label"><?= __("template") ?></label><select class="form-select" name="template"><?php foreach($templates as $tpl): ?><option value="<?= $tpl ?>" <?= ($page["template"] ?? "default") == $tpl ? "selected" : "" ?>><?= ucfirst($tpl) ?></option><?php endforeach; ?></select></div><button type="submit" class="btn btn-primary"><?= __("save") ?></button><a href="content.php" class="btn btn-secondary"><?= __("cancel") ?></a></form></main></div></div><script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script></body></html>
EDITPAGE

# 6.17 delete_page.php
create_php_file "$ADMIN_DIR/delete_page.php" '<?php require_once __DIR__ . "/../config.php"; require_once "includes/auth.php"; requireAdmin(); $id = isset($_GET["id"]) ? (int)$_GET["id"] : 0; if($id) { $stmt = $pdo->prepare("DELETE FROM pages WHERE id = ?"); $stmt->execute([$id]); } header("Location: content.php"); exit;'

# 6.18 edit_file.php (исправлен: универсальная функция previewFile)
create_php_file "$ADMIN_DIR/edit_file.php" <<'EDITFILE'
<?php require_once __DIR__ . "/../config.php"; require_once "includes/auth.php"; requireLogin(); require_once "includes/content_functions.php"; $site_name = getSetting("site_name", SITE_NAME); $pageTitle = __("edit_file"); $root_dir = __DIR__ . "/../"; $file_name = isset($_GET["file"]) ? basename($_GET["file"]) : ""; $file_path = $root_dir . $file_name; $message = ""; if($_SERVER["REQUEST_METHOD"] === "POST" && isset($_POST["save_file"])) { $content = $_POST["content"]; if(is_writable($file_path)) { $backup = $file_path . ".bak." . date("Ymd_His"); copy($file_path, $backup); if(file_put_contents($file_path, $content) !== false) $message = "<div class=\"alert alert-success\">".__("file_saved")." ".basename($backup)."</div>"; else $message = "<div class=\"alert alert-danger\">".__("error")."</div>"; } else $message = "<div class=\"alert alert-danger\">".__("file_not_writable")."</div>"; } $content = ""; $is_html = false; $has_code = false; if($file_name && file_exists($file_path) && is_readable($file_path)) { $content = file_get_contents($file_path); $ext = pathinfo($file_name, PATHINFO_EXTENSION); $is_html = in_array($ext, ["html","htm","php","phtml","inc"]); if($is_html) $has_code = preg_match("/<(style|script)/i", $content) ? true : false; } ?><!DOCTYPE html><html lang="<?= currentLanguage() ?>"><head><meta charset="UTF-8"><title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css"><link rel="stylesheet" href="/admin/css/admin.css"><?php if($is_html && $file_name): ?><script src="/admin/tinymce/tinymce.min.js" referrerpolicy="origin"></script><script>tinymce.init({selector:"#content",height:500,plugins:"advlist anchor autolink autosave code codesample directionality emoticons fullscreen help hr image insertdatetime link lists media nonbreaking pagebreak paste preview print save searchreplace table visualblocks visualchars wordcount",toolbar:"undo redo | styles | bold italic underline strikethrough removeformat | alignleft aligncenter alignright alignjustify | bullist numlist outdent indent | link anchor image media | forecolor backcolor | fontselect fontsizeselect | code codesample | table | hr charmap pagebreak | visualblocks visualchars | fullscreen preview | wordcount save print | searchreplace | help",toolbar_mode:"floating",fontsize_formats:"8pt 10pt 12pt 14pt 16pt 18pt 24pt 36pt",image_title:true,automatic_uploads:true,images_upload_url:"/admin/upload.php",file_picker_types:"image",file_picker_callback:function(cb,value,meta){var input=document.createElement("input");input.setAttribute("type","file");input.setAttribute("accept","image/*");input.onchange=function(){var file=this.files[0];var formData=new FormData();formData.append("file",file);fetch("/admin/upload.php",{method:"POST",body:formData}).then(response=>response.json()).then(result=>{cb(result.location,{title:result.original_name});}).catch(error=>console.error(error));};input.click();},content_css:"/admin/css/editor.css",external_plugins:{"ai_button":"/admin/js/ai_tinymce_plugin.js"}});</script><?php endif; ?><script>function previewFile(){var content;if(typeof tinymce !== "undefined" && tinymce.get("content")){content = tinymce.get("content").getContent();}else{content = document.getElementById("content").value;}var win = window.open("","_blank","width=1024,height=768");win.document.write(content);win.document.close();}</script></head><body class="theme-<?= getSetting("admin_theme", "light") ?>"><?php include "includes/header.php"; ?><div class="container-fluid"><div class="row"><?php include "includes/sidebar.php"; ?><main class="col-md-9 ms-sm-auto col-lg-10 px-md-4"><div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom"><h1 class="h2"><?= $pageTitle ?></h1><a href="content.php" class="btn btn-sm btn-secondary"><i class="bi bi-arrow-left"></i> <?= __("back") ?></a></div><?= $message ?><?php if($has_code): ?><div class="alert alert-warning"><i class="bi bi-exclamation-triangle"></i> <?= __("code_warning") ?></div><?php endif; ?><?php if($file_name): ?><form method="post"><div class="mb-3"><label class="form-label"><?= __("editing") ?>: <?= htmlspecialchars($file_name) ?></label><?php if($is_html): ?><textarea id="content" name="content" style="height:500px;"><?= htmlspecialchars($content) ?></textarea><?php else: ?><textarea name="content" class="form-control" rows="20"><?= htmlspecialchars($content) ?></textarea><?php endif; ?></div><button type="submit" name="save_file" class="btn btn-primary"><?= __("save") ?></button><button type="button" class="btn btn-info" onclick="previewFile()"><i class="bi bi-eye"></i> <?= __("preview") ?></button><a href="content.php" class="btn btn-secondary"><?= __("cancel") ?></a></form><?php else: ?><div class="alert alert-danger"><?= __("file_not_found") ?></div><?php endif; ?></main></div></div><script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script></body></html>
EDITFILE

# 6.19 upload.php
create_php_file "$ADMIN_DIR/upload.php" <<'UPLOAD'
<?php require_once __DIR__ . "/../config.php"; require_once "includes/auth.php"; requireLogin(); $response = ["error"=>true,"message"=>""]; if($_SERVER["REQUEST_METHOD"] !== "POST") { $response["message"] = "Method not allowed"; header("Content-Type: application/json"); echo json_encode($response); exit; } if(empty($_FILES["file"])) { $response["message"] = "No file"; header("Content-Type: application/json"); echo json_encode($response); exit; } $file = $_FILES["file"]; $original_name = $file["name"]; $tmp_name = $file["tmp_name"]; $size = $file["size"]; $error = $file["error"]; if($error !== UPLOAD_ERR_OK) { $response["message"] = "Upload error code $error"; header("Content-Type: application/json"); echo json_encode($response); exit; } $allowed_mimes = ["image/jpeg","image/png","image/gif","image/webp","application/pdf","text/plain","application/msword","application/vnd.openxmlformats-officedocument.wordprocessingml.document"]; $finfo = finfo_open(FILEINFO_MIME_TYPE); $mime_type = finfo_file($finfo, $tmp_name); finfo_close($finfo); if(!in_array($mime_type, $allowed_mimes)) { $response["message"] = "Invalid file type: $mime_type"; header("Content-Type: application/json"); echo json_encode($response); exit; } $max_size = getSetting("max_upload_size", 10*1024*1024); if($size > $max_size) { $response["message"] = "File exceeds max size"; header("Content-Type: application/json"); echo json_encode($response); exit; } $upload_dir = __DIR__ . "/../uploads/"; if(!is_dir($upload_dir)) mkdir($upload_dir, 0750, true); $year = date("Y"); $month = date("m"); $target_dir = $upload_dir . $year . "/" . $month . "/"; if(!is_dir($target_dir)) mkdir($target_dir, 0750, true); $ext = pathinfo($original_name, PATHINFO_EXTENSION); $new_name = uniqid() . "." . $ext; $target_path = $target_dir . $new_name; if(!move_uploaded_file($tmp_name, $target_path)) { $response["message"] = "Failed to save file"; header("Content-Type: application/json"); echo json_encode($response); exit; } $relative_path = "/uploads/" . $year . "/" . $month . "/" . $new_name; $stmt = $pdo->prepare("INSERT INTO files (original_name, path, size, type, uploaded_by) VALUES (?,?,?,?,?)"); $stmt->execute([$original_name, $relative_path, $size, $mime_type, $_SESSION["user_id"]]); $response = ["error"=>false,"location"=>$relative_path,"original_name"=>$original_name,"id"=>$pdo->lastInsertId()]; header("Content-Type: application/json"); echo json_encode($response);
UPLOAD

# 6.20 files.php
create_php_file "$ADMIN_DIR/files.php" <<'FILES'
<?php require_once __DIR__ . "/../config.php"; require_once "includes/auth.php"; requireLogin(); $site_name = getSetting("site_name", SITE_NAME); $pageTitle = __("files"); $message = ""; $search = trim($_GET["search"] ?? ""); $order_by = $_GET["order_by"] ?? "id"; $order_dir = strtoupper($_GET["order_dir"] ?? "DESC"); $allowed_order = ["id","original_name","type","size","uploaded_at"]; if(!in_array($order_by, $allowed_order)) $order_by = "id"; $order_dir = ($order_dir === "ASC") ? "ASC" : "DESC"; if($_SERVER["REQUEST_METHOD"] === "POST" && isset($_FILES["file"])) { $file = $_FILES["file"]; $original_name = $file["name"]; $tmp_name = $file["tmp_name"]; $size = $file["size"]; $error = $file["error"]; if($error !== UPLOAD_ERR_OK) $message = "<div class=\"alert alert-danger\">Upload error</div>"; else { $allowed_mimes = ["image/jpeg","image/png","image/gif","image/webp","application/pdf","text/plain","application/msword","application/vnd.openxmlformats-officedocument.wordprocessingml.document"]; $finfo = finfo_open(FILEINFO_MIME_TYPE); $mime_type = finfo_file($finfo, $tmp_name); finfo_close($finfo); if(!in_array($mime_type, $allowed_mimes)) $message = "<div class=\"alert alert-danger\">Invalid file type</div>"; else { $max_size = getSetting("max_upload_size", 10*1024*1024); if($size > $max_size) $message = "<div class=\"alert alert-danger\">File too large</div>"; else { $upload_dir = __DIR__ . "/../uploads/"; if(!is_dir($upload_dir)) mkdir($upload_dir, 0750, true); $year = date("Y"); $month = date("m"); $target_dir = $upload_dir . $year . "/" . $month . "/"; if(!is_dir($target_dir)) mkdir($target_dir, 0750, true); $ext = pathinfo($original_name, PATHINFO_EXTENSION); $new_name = uniqid() . "." . $ext; $target_path = $target_dir . $new_name; if(move_uploaded_file($tmp_name, $target_path)) { $relative_path = "/uploads/" . $year . "/" . $month . "/" . $new_name; $stmt = $pdo->prepare("INSERT INTO files (original_name, path, size, type, uploaded_by) VALUES (?,?,?,?,?)"); $stmt->execute([$original_name, $relative_path, $size, $mime_type, $_SESSION["user_id"]]); $message = "<div class=\"alert alert-success\">".__("file_uploaded")."</div>"; } else $message = "<div class=\"alert alert-danger\">Failed to save</div>"; } } } } if(isset($_GET["delete"])) { $id = (int)$_GET["delete"]; $stmt = $pdo->prepare("SELECT path FROM files WHERE id = ?"); $stmt->execute([$id]); $file = $stmt->fetch(PDO::FETCH_ASSOC); if($file) { if (strpos($file["path"], '/uploads/') !== 0) { $message = "<div class=\"alert alert-danger\">Invalid file path</div>"; } else { $full_path = __DIR__ . "/.." . $file["path"]; if(file_exists($full_path)) unlink($full_path); $stmt = $pdo->prepare("DELETE FROM files WHERE id = ?"); $stmt->execute([$id]); $message = "<div class=\"alert alert-success\">".__("file_deleted")."</div>"; } } else $message = "<div class=\"alert alert-danger\">".__("file_not_found")."</div>"; } $sql = "SELECT * FROM files WHERE 1=1"; $params = []; if($search) { $sql .= " AND original_name LIKE :search"; $params[":search"] = "%$search%"; } $sql .= " ORDER BY $order_by $order_dir"; $stmt = $pdo->prepare($sql); $stmt->execute($params); $files = $stmt->fetchAll(PDO::FETCH_ASSOC); function sort_link($field, $current_field, $current_dir) { $new_dir = ($current_field == $field && $current_dir == "DESC") ? "ASC" : "DESC"; $params = $_GET; $params["order_by"] = $field; $params["order_dir"] = $new_dir; unset($params["delete"]); $query = http_build_query($params); return "?$query"; } ?><!DOCTYPE html><html lang="<?= currentLanguage() ?>"><head><meta charset="UTF-8"><title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css"><link rel="stylesheet" href="/admin/css/admin.css"></head><body class="theme-<?= getSetting("admin_theme", "light") ?>"><?php include "includes/header.php"; ?><div class="container-fluid"><div class="row"><?php include "includes/sidebar.php"; ?><main class="col-md-9 ms-sm-auto col-lg-10 px-md-4"><div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom"><h1 class="h2"><?= $pageTitle ?></h1><button type="button" class="btn btn-sm btn-primary" data-bs-toggle="modal" data-bs-target="#uploadModal"><i class="bi bi-upload"></i> <?= __("upload_file") ?></button></div><form method="get" class="row g-3 mb-4"><div class="col-auto"><input type="text" class="form-control" name="search" placeholder="<?= __("search") ?>" value="<?= htmlspecialchars($search) ?>"></div><div class="col-auto"><button type="submit" class="btn btn-primary"><?= __("filter") ?></button><a href="files.php" class="btn btn-secondary"><?= __("reset") ?></a></div></form><?= $message ?><div class="table-responsive"><table class="table table-striped"><thead><tr><th><a href="<?= sort_link("id", $order_by, $order_dir) ?>">ID</a></th><th><a href="<?= sort_link("original_name", $order_by, $order_dir) ?>"><?= __("original_name") ?></a></th><th><?= __("path") ?></th><th><a href="<?= sort_link("type", $order_by, $order_dir) ?>"><?= __("type") ?></a></th><th><a href="<?= sort_link("size", $order_by, $order_dir) ?>"><?= __("size") ?> (KB)</a></th><th><a href="<?= sort_link("uploaded_at", $order_by, $order_dir) ?>"><?= __("uploaded_at") ?></a></th><th><?= __("actions") ?></th></tr></thead><tbody><?php foreach($files as $file): ?><tr><td><?= $file["id"] ?></td><td><?= htmlspecialchars($file["original_name"]) ?></td><td><a href="<?= htmlspecialchars($file["path"]) ?>" target="_blank"><?= htmlspecialchars($file["path"]) ?></a></td><td><?= htmlspecialchars($file["type"]) ?></td><td><?= round($file["size"] / 1024, 2) ?></td><td><?= $file["uploaded_at"] ?></td><td><a href="?delete=<?= $file["id"] ?>&<?= http_build_query(array_diff_key($_GET, ["delete"=>1])) ?>" class="btn btn-sm btn-danger" onclick="return confirm(\'<?= __("confirm_delete") ?>\')"><i class="bi bi-trash"></i></a></td></tr><?php endforeach; ?></tbody></table></div></main></div></div><div class="modal fade" id="uploadModal" tabindex="-1"><div class="modal-dialog"><div class="modal-content"><form method="post" enctype="multipart/form-data"><div class="modal-header"><h5 class="modal-title"><?= __("upload_file") ?></h5><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div><div class="modal-body"><div class="mb-3"><label class="form-label"><?= __("select_file") ?></label><input type="file" class="form-control" name="file" required></div></div><div class="modal-footer"><button type="button" class="btn btn-secondary" data-bs-dismiss="modal"><?= __("cancel") ?></button><button type="submit" class="btn btn-primary"><?= __("upload") ?></button></div></form></div></div></div><script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script></body></html>
FILES

# 6.21 file-list.php
create_php_file "$ADMIN_DIR/file-list.php" '<?php require_once __DIR__ . "/../config.php"; require_once "includes/auth.php"; requireLogin(); $stmt = $pdo->query("SELECT id, original_name, path, type, size, uploaded_at FROM files ORDER BY uploaded_at DESC"); $files = $stmt->fetchAll(PDO::FETCH_ASSOC); header("Content-Type: application/json"); echo json_encode($files);'

# 6.22 file-picker.html
cat > "$ADMIN_DIR/file-picker.html" <<'PICKER'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><title>Выбор файла</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><style>.file-item{cursor:pointer}.file-item:hover{background:#f0f0f0}.thumbnail{width:100px;height:auto;max-height:100px;object-fit:cover;margin-right:15px}</style></head><body><div class="container"><h2>Выберите файл</h2><div id="file-list" class="list-group"><div class="text-center"><div class="spinner-border"></div></div></div></div><script>function escapeHtml(str){return str.replace(/[&<>]/g,function(m){if(m==="&") return "&amp;"; if(m==="<") return "&lt;"; if(m===">") return "&gt;"; return m;});}fetch("/admin/file-list.php").then(r=>r.json()).then(files=>{const c=document.getElementById("file-list");c.innerHTML="";if(files.length===0){c.innerHTML="<div class=\"alert alert-info\">Нет загруженных файлов</div>";return;}files.forEach(f=>{const d=document.createElement("div");d.className="list-group-item file-item";d.innerHTML=`<div class="row align-items-center"><div class="col-auto"><img src="${escapeHtml(f.path)}" class="thumbnail" onerror="this.style.display='none'"></div><div class="col"><strong>${escapeHtml(f.original_name)}</strong><br><small>${escapeHtml(f.type)} | ${(f.size/1024).toFixed(2)} KB</small><br><small>Загружен: ${escapeHtml(f.uploaded_at)}</small></div></div>`;d.addEventListener("click",()=>{window.parent.postMessage({mceAction:"FileSelected",url:f.path,title:f.original_name},"*");window.close();});c.appendChild(d);});}).catch(e=>{console.error(e);document.getElementById("file-list").innerHTML="<div class=\"alert alert-danger\">Ошибка</div>";});</script></body></html>
PICKER

# 6.23 analytics.php (с автоматической коррекцией прав)
create_php_file "$ADMIN_DIR/analytics.php" <<'ANALYTICS'
<?php
require_once "includes/auth.php";
requireLogin();
$site_name = getSetting("site_name", SITE_NAME);
$pageTitle = __("analytics");
$message = "";
$root_dir = __DIR__ . "/../";
$tracker_js_code = '<script src="/js/tracker.js"></script>';
$tracker_php_code = '<?php
if (isset($pdo) && strpos($_SERVER["REQUEST_URI"], "/admin") !== 0) {
    try {
        $ip = $_SERVER["REMOTE_ADDR"] ?? "";
        $ua = $_SERVER["HTTP_USER_AGENT"] ?? "";
        $url = $_SERVER["REQUEST_URI"] ?? "";
        $stmt = $pdo->prepare("INSERT INTO visits (visit_date, visitor_ip, user_agent, page_url) VALUES (CURDATE(), ?, ?, ?)");
        $stmt->execute([$ip, $ua, $url]);
    } catch (Exception $e) {}
}
?>';

if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $action = $_POST["action"] ?? "";
    $files = $_POST["files"] ?? [];
    $errors = [];
    if ($action === "inject") {
        foreach ($files as $file) {
            $file_path = $root_dir . $file;
            if (!file_exists($file_path)) {
                $errors[] = "Файл $file не существует";
                continue;
            }
            // Пытаемся сделать файл доступным для записи
            if (!is_writable($file_path)) {
                @chmod($file_path, 0644);
                clearstatcache();
                if (!is_writable($file_path)) {
                    $errors[] = "Файл $file не доступен для записи (проверьте права)";
                    continue;
                }
            }
            $ext = pathinfo($file, PATHINFO_EXTENSION);
            $backup = $file_path . ".bak." . date("Ymd_His");
            copy($file_path, $backup);
            $content = file_get_contents($file_path);
            if (in_array($ext, ["php", "phtml", "inc"])) {
                if (strpos($content, "INSERT INTO visits") === false) {
                    if (preg_match("/^<\?php/", $content)) {
                        $new_content = preg_replace("/^<\?php/", "<?php\n" . $tracker_php_code, $content);
                    } else {
                        $new_content = $tracker_php_code . "\n" . $content;
                    }
                    file_put_contents($file_path, $new_content);
                }
            } elseif (in_array($ext, ["html", "htm"])) {
                if (strpos($content, "tracker.js") === false) {
                    if (preg_match("/<\/body\s*>/i", $content, $matches, PREG_OFFSET_CAPTURE)) {
                        $pos = $matches[0][1];
                        $new_content = substr_replace($content, $tracker_js_code . "\n" . $matches[0][0], $pos, strlen($matches[0][0]));
                    } elseif (preg_match("/<\/html\s*>/i", $content, $matches, PREG_OFFSET_CAPTURE)) {
                        $pos = $matches[0][1];
                        $new_content = substr_replace($content, $tracker_js_code . "\n" . $matches[0][0], $pos, strlen($matches[0][0]));
                    } else {
                        $new_content = $content . "\n" . $tracker_js_code;
                    }
                    file_put_contents($file_path, $new_content);
                }
            }
        }
        if (empty($errors)) {
            $message = "<div class=\"alert alert-success\">" . __("tracker_added") . "</div>";
        } else {
            $message = "<div class=\"alert alert-danger\">Ошибка при обработке файлов:<br>" . implode("<br>", $errors) . "</div>";
        }
    } elseif ($action === "remove") {
        foreach ($files as $file) {
            $file_path = $root_dir . $file;
            if (!file_exists($file_path)) continue;
            if (!is_writable($file_path)) {
                @chmod($file_path, 0644);
                clearstatcache();
                if (!is_writable($file_path)) {
                    $errors[] = "Файл $file не доступен для записи";
                    continue;
                }
            }
            $ext = pathinfo($file, PATHINFO_EXTENSION);
            $content = file_get_contents($file_path);
            if (in_array($ext, ["php", "phtml", "inc"])) {
                $new_content = preg_replace("/<\?php\nif \(isset\(\$pdo\).*?}\n\?>/s", "", $content);
                if ($new_content !== $content) file_put_contents($file_path, $new_content);
            } elseif (in_array($ext, ["html", "htm"])) {
                $new_content = str_replace($tracker_js_code, "", $content);
                if ($new_content !== $content) file_put_contents($file_path, $new_content);
            }
        }
        if (empty($errors)) {
            $message = "<div class=\"alert alert-success\">" . __("tracker_removed") . "</div>";
        } else {
            $message = "<div class=\"alert alert-danger\">Ошибка при удалении трекера:<br>" . implode("<br>", $errors) . "</div>";
        }
    }
}

$files_list = [];
$excluded = ["admin", "uploads", "core", "templates", "tinymce", "js", "css"];
foreach (glob($root_dir . "*") as $item) {
    $basename = basename($item);
    if (is_file($item) && !in_array($basename, $excluded) && in_array(pathinfo($item, PATHINFO_EXTENSION), ["php", "html", "htm", "phtml", "inc"])) {
        $files_list[] = $basename;
    }
}
?>
<!DOCTYPE html>
<html lang="<?= currentLanguage() ?>">
<head>
    <meta charset="UTF-8">
    <title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <link rel="stylesheet" href="/admin/css/admin.css">
</head>
<body class="theme-<?= getSetting("admin_theme", "light") ?>">
    <?php include "includes/header.php"; ?>
    <div class="container-fluid">
        <div class="row">
            <?php include "includes/sidebar.php"; ?>
            <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4">
                <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
                    <h1 class="h2"><?= $pageTitle ?></h1>
                </div>
                <?= $message ?>
                
                <div class="card mb-4">
                    <div class="card-header"><i class="bi bi-magic"></i> <?= __("inject_tracker") ?></div>
                    <div class="card-body">
                        <form method="post">
                            <div class="mb-3">
                                <label class="form-label"><?= __("select_files") ?></label>
                                <select class="form-select" name="files[]" multiple size="10">
                                    <?php foreach ($files_list as $f): ?>
                                        <option value="<?= htmlspecialchars($f) ?>"><?= htmlspecialchars($f) ?></option>
                                    <?php endforeach; ?>
                                </select>
                                <div class="form-text">Удерживайте Ctrl для выбора нескольких файлов.</div>
                            </div>
                            <button type="submit" name="action" value="inject" class="btn btn-primary"><i class="bi bi-code-slash"></i> <?= __("inject_tracker") ?></button>
                            <button type="submit" name="action" value="remove" class="btn btn-danger ms-2"><i class="bi bi-trash"></i> <?= __("remove_tracker") ?></button>
                        </form>
                    </div>
                </div>

                <div class="card mb-4">
                    <div class="card-header"><i class="bi bi-filetype-php"></i> PHP – <?= __("manual_instruction") ?></div>
                    <div class="card-body">
                        <p><?= __("manual_text_php") ?></p>
                        <pre class="bg-light p-3 border rounded"><code><?= htmlspecialchars($tracker_php_code) ?></code></pre>
                    </div>
                </div>

                <div class="card">
                    <div class="card-header"><i class="bi bi-filetype-html"></i> HTML/JS – <?= __("manual_instruction") ?></div>
                    <div class="card-body">
                        <p><?= __("manual_text_html") ?></p>
                        <pre class="bg-light p-3 border rounded"><code><?= htmlspecialchars($tracker_js_code) ?></code></pre>
                        <p class="mt-2"><small><?= __("manual_note") ?></small></p>
                    </div>
                </div>
            </main>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
ANALYTICS

# 6.24 ai_generator.php
create_php_file "$ADMIN_DIR/ai_generator.php" <<'AIGEN'
<?php
require_once __DIR__ . "/includes/auth.php";
requireLogin();
$site_name = getSetting("site_name", SITE_NAME);
$pageTitle = __("ai_generator");

$api_key = getSetting("deepseek_api_key", "");
$model = getSetting("deepseek_model", "deepseek-chat");
$max_tokens = (int)getSetting("deepseek_max_tokens", 2000);

$generated_text = "";
$error = "";
$prompt = "";

if ($_SERVER["REQUEST_METHOD"] === "POST" && isset($_POST["prompt"])) {
    $prompt = trim($_POST["prompt"]);
    if (empty($prompt)) {
        $error = "Промпт не может быть пустым";
    } elseif (empty($api_key)) {
        $error = "API ключ DeepSeek не настроен. Перейдите в Настройки и добавьте ключ.";
    } else {
        $ch = curl_init("https://api.deepseek.com/v1/chat/completions");
        $data = [
            "model" => $model,
            "messages" => [
                ["role" => "user", "content" => $prompt]
            ],
            "max_tokens" => $max_tokens,
            "temperature" => 0.7
        ];
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_TIMEOUT, 30);
        curl_setopt($ch, CURLOPT_HTTPHEADER, [
            "Content-Type: application/json",
            "Authorization: Bearer $api_key"
        ]);
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
        $response = curl_exec($ch);
        $http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        
        if ($http_code === 200) {
            $result = json_decode($response, true);
            $generated_text = $result["choices"][0]["message"]["content"] ?? "";
            $stmt = $pdo->prepare("INSERT INTO ai_requests (prompt, response, user_id) VALUES (?, ?, ?)");
            $stmt->execute([$prompt, $generated_text, $_SESSION["user_id"]]);
        } else {
            $error = "Ошибка API: HTTP $http_code. " . ($response ?: "Нет ответа");
        }
    }
}
?>
<!DOCTYPE html>
<html lang="<?= currentLanguage() ?>">
<head>
    <meta charset="UTF-8">
    <title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <link rel="stylesheet" href="/admin/css/admin.css">
</head>
<body class="theme-<?= getSetting("admin_theme", "light") ?>">
    <?php include "includes/header.php"; ?>
    <div class="container-fluid">
        <div class="row">
            <?php include "includes/sidebar.php"; ?>
            <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4">
                <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
                    <h1 class="h2"><?= $pageTitle ?></h1>
                </div>
                
                <form method="post" class="mb-4">
                    <div class="mb-3">
                        <label for="prompt" class="form-label">Промпт (запрос к AI)</label>
                        <textarea class="form-control" id="prompt" name="prompt" rows="4" required><?= htmlspecialchars($prompt) ?></textarea>
                    </div>
                    <button type="submit" class="btn btn-primary"><i class="bi bi-send"></i> Отправить</button>
                </form>
                
                <?php if ($error): ?>
                    <div class="alert alert-danger"><?= htmlspecialchars($error) ?></div>
                <?php endif; ?>
                
                <?php if ($generated_text): ?>
                <div class="card mt-4">
                    <div class="card-header">
                        <i class="bi bi-robot"></i> Результат генерации
                    </div>
                    <div class="card-body">
                        <div class="mb-3">
                            <label class="form-label">Заголовок для страницы</label>
                            <input type="text" id="generated_title" class="form-control" placeholder="Введите заголовок">
                        </div>
                        <div class="mb-3">
                            <label class="form-label">Содержимое (HTML)</label>
                            <div id="generated_text" class="border p-3 bg-light" style="max-height: 400px; overflow: auto;"><?= $generated_text ?></div>
                        </div>
                        <button class="btn btn-success" onclick="createPage()"><i class="bi bi-file-earmark-plus"></i> Создать страницу</button>
                        <button class="btn btn-info" onclick="insertToEditor()"><i class="bi bi-pencil-square"></i> Вставить в редактор</button>
                        <p class="mt-2 text-muted small">Примечание: кнопка «Создать страницу» создаст пустую страницу, содержимое нужно будет вставить вручную.</p>
                    </div>
                </div>
                <?php endif; ?>
                
                <div class="mt-4">
                    <a href="ai_history.php" class="btn btn-secondary"><i class="bi bi-clock-history"></i> История запросов</a>
                </div>
            </main>
        </div>
    </div>
    <script>
    function insertToEditor() {
        if (!window.opener || !window.opener.tinymce) {
            alert("Эта функция работает только при вызове из редактора TinyMCE");
            return;
        }
        var contentDiv = document.getElementById("generated_text");
        var htmlContent = contentDiv.innerHTML;
        var editor = window.opener.tinymce.activeEditor;
        if (editor) {
            editor.insertContent(htmlContent);
            window.close();
        } else {
            alert("Редактор не найден");
        }
    }
    function createPage() {
        var title = document.getElementById("generated_title").value;
        var contentDiv = document.getElementById("generated_text");
        var htmlContent = contentDiv.innerHTML;
        if (!title) title = "Новая страница";
        var url = "/admin/edit_page.php?prefill_title=" + encodeURIComponent(title) + "&prefill_content=" + encodeURIComponent(htmlContent);
        window.open(url, "_blank");
    }
    </script>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
AIGEN

# 6.25 ai_history.php
create_php_file "$ADMIN_DIR/ai_history.php" <<'AIHIST'
<?php
require_once __DIR__ . "/includes/auth.php";
requireAdmin();
$site_name = getSetting("site_name", SITE_NAME);
$pageTitle = __("ai_history");

$page = isset($_GET["page"]) ? max(1, (int)$_GET["page"]) : 1;
$per_page = 20;
$offset = ($page - 1) * $per_page;

$total = $pdo->query("SELECT COUNT(*) FROM ai_requests")->fetchColumn();
$stmt = $pdo->prepare("SELECT r.*, u.login FROM ai_requests r JOIN users u ON r.user_id = u.id ORDER BY r.created_at DESC LIMIT :limit OFFSET :offset");
$stmt->bindValue(":limit", $per_page, PDO::PARAM_INT);
$stmt->bindValue(":offset", $offset, PDO::PARAM_INT);
$stmt->execute();
$requests = $stmt->fetchAll(PDO::FETCH_ASSOC);
?>
<!DOCTYPE html>
<html lang="<?= currentLanguage() ?>">
<head>
    <meta charset="UTF-8">
    <title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <link rel="stylesheet" href="/admin/css/admin.css">
</head>
<body class="theme-<?= getSetting("admin_theme", "light") ?>">
    <?php include "includes/header.php"; ?>
    <div class="container-fluid">
        <div class="row">
            <?php include "includes/sidebar.php"; ?>
            <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4">
                <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
                    <h1 class="h2"><?= $pageTitle ?></h1>
                    <a href="ai_generator.php" class="btn btn-primary"><i class="bi bi-plus"></i> Новый запрос</a>
                </div>
                
                <div class="table-responsive">
                    <table class="table table-striped">
                        <thead>
                            <tr>
                                <th>ID</th>
                                <th>Пользователь</th>
                                <th>Промпт</th>
                                <th>Дата</th>
                                <th>Действия</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php foreach ($requests as $req): ?>
                            <tr>
                                <td><?= $req["id"] ?></td>
                                <td><?= htmlspecialchars($req["login"]) ?></td>
                                <td><?= htmlspecialchars(mb_substr($req["prompt"], 0, 100)) ?>…</td>
                                <td><?= $req["created_at"] ?></td>
                                <td>
                                    <button class="btn btn-sm btn-info" data-bs-toggle="modal" data-bs-target="#modal_<?= $req["id"] ?>"><i class="bi bi-eye"></i></button>
                                </td>
                            </tr>
                            <div class="modal fade" id="modal_<?= $req["id"] ?>" tabindex="-1">
                                <div class="modal-dialog modal-lg">
                                    <div class="modal-content">
                                        <div class="modal-header">
                                            <h5 class="modal-title">Запрос #<?= $req["id"] ?></h5>
                                            <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                                        </div>
                                        <div class="modal-body">
                                            <h6>Промпт:</h6>
                                            <p><?= nl2br(htmlspecialchars($req["prompt"])) ?></p>
                                            <h6>Ответ AI:</h6>
                                            <div><?= nl2br(htmlspecialchars($req["response"])) ?></div>
                                        </div>
                                    </div>
                                </div>
                            </div>
                            <?php endforeach; ?>
                        </tbody>
                    </table>
                </div>
                
                <?php if ($total > $per_page): ?>
                <nav>
                    <ul class="pagination">
                        <?php for ($i = 1; $i <= ceil($total / $per_page); $i++): ?>
                            <li class="page-item <?= $i == $page ? "active" : "" ?>">
                                <a class="page-link" href="?page=<?= $i ?>"><?= $i ?></a>
                            </li>
                        <?php endfor; ?>
                    </ul>
                </nav>
                <?php endif; ?>
            </main>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
AIHIST

# 6.26 ai_api.php
create_php_file "$ADMIN_DIR/ai_api.php" <<'AIPHP'
<?php
require_once __DIR__ . "/../config.php";
require_once "includes/functions.php";
require_once "includes/auth.php";
requireLogin();
header("Content-Type: application/json");

if ($_SERVER["REQUEST_METHOD"] !== "POST") {
    http_response_code(405);
    echo json_encode(["error" => "Method not allowed"]);
    exit;
}

$prompt = trim($_POST["prompt"] ?? "");
if (empty($prompt)) {
    echo json_encode(["error" => "Промпт не может быть пустым"]);
    exit;
}

$api_key = getSetting("deepseek_api_key", "");
if (empty($api_key)) {
    echo json_encode(["error" => "API ключ DeepSeek не настроен"]);
    exit;
}

$model = getSetting("deepseek_model", "deepseek-chat");
$max_tokens = (int)getSetting("deepseek_max_tokens", 2000);

$ch = curl_init("https://api.deepseek.com/v1/chat/completions");
$data = [
    "model" => $model,
    "messages" => [["role" => "user", "content" => $prompt]],
    "max_tokens" => $max_tokens,
    "temperature" => 0.7
];
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_POST, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 30);
curl_setopt($ch, CURLOPT_HTTPHEADER, [
    "Content-Type: application/json",
    "Authorization: Bearer $api_key"
]);
curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
$response = curl_exec($ch);
$http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

if ($http_code === 200) {
    $result = json_decode($response, true);
    $generated_text = $result["choices"][0]["message"]["content"] ?? "";
    $stmt = $pdo->prepare("INSERT INTO ai_requests (prompt, response, user_id) VALUES (?, ?, ?)");
    $stmt->execute([$prompt, $generated_text, $_SESSION["user_id"]]);
    echo json_encode(["response" => $generated_text]);
} else {
    echo json_encode(["error" => "Ошибка API: HTTP $http_code"]);
}
AIPHP

# 6.27 ai_tinymce_plugin.js
mkdir -p "$ADMIN_DIR/js"
cat > "$ADMIN_DIR/js/ai_tinymce_plugin.js" <<'JSPLUGIN'
tinymce.PluginManager.add('ai_button', function(editor, url) {
    editor.ui.registry.addButton('ai_button', {
        text: 'AI',
        tooltip: 'Generate with DeepSeek',
        icon: 'robot',
        onAction: function() {
            var prompt = prompt("Введите запрос для AI:");
            if (prompt) {
                fetch("/admin/ai_api.php", {
                    method: "POST",
                    headers: { "Content-Type": "application/x-www-form-urlencoded" },
                    body: "prompt=" + encodeURIComponent(prompt)
                })
                .then(response => response.json())
                .then(data => {
                    if (data.response) {
                        editor.insertContent(data.response);
                    } else if (data.error) {
                        alert(data.error);
                    }
                })
                .catch(err => alert("Ошибка: " + err));
            }
        }
    });
});
JSPLUGIN

log_only "Все файлы админ-панели (включая AI) созданы."

# ----------------------------------------------------------------------
# 7. CSS-файл
# ----------------------------------------------------------------------
next_step "Создание CSS-файла"
cat > "$ADMIN_DIR/css/admin.css" <<'CSSEOF'
@import url('https://fonts.googleapis.com/css2?family=Playfair+Display:wght@400;700&display=swap');
:root{--primary-dark:#1a3b4e;--primary-light:#0f5e7a;--accent-gold:#c9a96b;--accent-dark:#8a6d3b;--bg-light:#f0f7fa;--card-bg:rgba(255,255,255,0.9);--text-dark:#2d3e4f;--border-radius:20px;}
body{background:linear-gradient(145deg,#f0f7fa 0%,#daeef5 100%);font-family:'Segoe UI',Roboto,sans-serif;color:var(--text-dark);min-height:100vh;}
body.theme-dark{background:linear-gradient(145deg,#1e2f3a 0%,#0f2a33 100%);--card-bg:rgba(30,40,50,0.9);--text-dark:#e0e8f0;}
.navbar-dark.bg-dark{background:linear-gradient(135deg,var(--primary-dark),var(--primary-light)) !important;border-bottom:3px solid var(--accent-gold);box-shadow:0 4px 15px rgba(0,40,50,0.2);}
.navbar-brand{font-family:'Playfair Display',serif;font-weight:700;font-size:1.5rem;letter-spacing:0.5px;}
.sidebar{background:rgba(255,255,255,0.8) !important;backdrop-filter:blur(5px);border-right:2px solid var(--accent-gold);box-shadow:5px 0 15px rgba(0,0,0,0.05);}
body.theme-dark .sidebar{background:rgba(30,40,50,0.8) !important;color:#e0e8f0;}
.sidebar .nav-link{color:var(--primary-dark);font-weight:500;border-radius:10px;margin:2px 8px;transition:all 0.3s;}
body.theme-dark .sidebar .nav-link{color:#e0e8f0;}
.sidebar .nav-link:hover,.sidebar .nav-link.active{background:var(--accent-gold);color:var(--primary-dark);transform:translateX(5px);box-shadow:0 2px 8px rgba(201,169,107,0.4);}
.sidebar .nav-link i{margin-right:8px;color:var(--primary-light);}
.card{background:var(--card-bg);backdrop-filter:blur(3px);border:2px solid var(--accent-gold);border-radius:var(--border-radius);box-shadow:0 10px 20px rgba(0,30,40,0.1);transition:transform 0.3s,box-shadow 0.3s;overflow:hidden;}
.card:hover{transform:translateY(-5px);box-shadow:0 15px 30px rgba(0,50,60,0.2);}
.card-header{background:rgba(201,169,107,0.15);border-bottom:2px dotted var(--accent-gold);font-weight:600;color:var(--primary-dark);font-family:'Playfair Display',serif;}
body.theme-dark .card-header{color:#e0e8f0;}
.btn-primary{background:var(--primary-dark);border:2px solid var(--accent-gold);color:white;border-radius:40px;padding:0.5rem 1.5rem;font-weight:600;transition:all 0.3s;}
.btn-primary:hover{background:var(--accent-gold);border-color:var(--primary-dark);color:var(--primary-dark);transform:scale(1.02);box-shadow:0 5px 15px rgba(201,169,107,0.4);}
.btn-danger{border-radius:40px;border:2px solid #dc3545;}
.table{background:rgba(255,255,255,0.7);border-radius:15px;overflow:hidden;border:2px solid var(--accent-gold);}
body.theme-dark .table{background:rgba(30,40,50,0.7);color:#e0e8f0;}
.table thead{background:var(--primary-dark);color:white;font-family:'Playfair Display',serif;}
.table-striped tbody tr:nth-of-type(odd){background-color:rgba(201,169,107,0.1);}
h1,h2,h3,h4,.h1,.h2,.h3,.h4{font-family:'Playfair Display',serif;color:var(--primary-dark);border-bottom:3px dotted var(--accent-gold);padding-bottom:0.5rem;margin-bottom:1.5rem;}
body.theme-dark h1,body.theme-dark h2,body.theme-dark h3,body.theme-dark h4{color:#e0e8f0;}
@keyframes fadeIn{from{opacity:0;transform:translateY(20px);}to{opacity:1;transform:translateY(0);}}
main{animation:fadeIn 0.6s ease-out;}
CSSEOF

# ----------------------------------------------------------------------
# 8. TinyMCE
# ----------------------------------------------------------------------
next_step "Установка TinyMCE"
if ! command -v npm &>/dev/null; then
    log "${YELLOW}npm не установлен. Устанавливаем Node.js и npm...${NC}"
    apt update && apt install -y nodejs npm >> "$LOG_FILE" 2>&1
fi
if [[ ! -d "$ADMIN_DIR/tinymce" ]] || $FORCE_MODE; then
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    npm install tinymce@${TINYMCE_VERSION} --production --no-audit --no-fund >> "$LOG_FILE" 2>&1
    rm -rf "$ADMIN_DIR/tinymce"
    cp -r "$TMP_DIR/node_modules/tinymce" "$ADMIN_DIR/tinymce"
    cd - >/dev/null
    rm -rf "$TMP_DIR"
    log_only "TinyMCE установлен."
fi

# ----------------------------------------------------------------------
# 9. Роутер cms-router.php
# ----------------------------------------------------------------------
next_step "Создание роутера"
create_php_file "$SITE_DIR/cms-router.php" '<?php
require_once __DIR__ . "/config.php";
$request = trim($_SERVER["REQUEST_URI"], "/");
$slug = $request === "" ? "index" : $request;
$stmt = $pdo->prepare("SELECT * FROM pages WHERE slug = ? AND status = \"published\"");
$stmt->execute([$slug]);
$page = $stmt->fetch(PDO::FETCH_ASSOC);
if ($page) {
    $template_file = __DIR__ . "/templates/" . ($page["template"] ?? "default") . ".php";
    if (file_exists($template_file)) include $template_file;
    else { http_response_code(404); echo "Template not found"; }
    exit;
}
$file_path = __DIR__ . "/" . ($slug === "index" ? "index.html" : $slug . ".html");
if (file_exists($file_path)) {
    $mime = mime_content_type($file_path);
    header("Content-Type: $mime");
    readfile($file_path);
    exit;
}
http_response_code(404);
echo "<h1>404 - Page not found</h1>";
'

# ----------------------------------------------------------------------
# 10. Трекер (PHP + JS) с проверкой на существование index.php/index.html
# ----------------------------------------------------------------------
next_step "Интеграция трекера посещений"

if [[ ! -f "$SITE_DIR/track.php" ]] || $FORCE_MODE; then
    cat > "$SITE_DIR/track.php" <<'TRACKPHP'
<?php
require_once __DIR__ . "/config.php";
if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $ip = $_SERVER["HTTP_X_FORWARDED_FOR"] ?? $_SERVER["REMOTE_ADDR"] ?? "";
    $ua = $_SERVER["HTTP_USER_AGENT"] ?? "";
    $url = $_POST["url"] ?? $_SERVER["HTTP_REFERER"] ?? "";
    try {
        $stmt = $pdo->prepare("INSERT INTO visits (visit_date, visitor_ip, user_agent, page_url) VALUES (CURDATE(), ?, ?, ?)");
        $stmt->execute([$ip, $ua, $url]);
        http_response_code(204);
    } catch (Exception $e) {
        http_response_code(500);
    }
} else {
    http_response_code(405);
}
TRACKPHP
    log_only "track.php создан."
fi

mkdir -p "$SITE_DIR/js"
if [[ ! -f "$SITE_DIR/js/tracker.js" ]] || $FORCE_MODE; then
    cat > "$SITE_DIR/js/tracker.js" <<'JSCODE'
(function() {
    if (window._trackerInited) return;
    window._trackerInited = true;
    function trackVisit() {
        const url = window.location.pathname + window.location.search;
        const data = new URLSearchParams();
        data.append("url", url);
        navigator.sendBeacon("/track.php", data);
    }
    if (document.readyState === "complete") {
        trackVisit();
    } else {
        window.addEventListener("load", trackVisit);
    }
})();
JSCODE
    chown www-data:www-data "$SITE_DIR/js/tracker.js"
    log_only "JS-трекер создан."
fi

TRACKER_PHP='
if (isset($pdo) && strpos($_SERVER["REQUEST_URI"], "/admin") !== 0) {
    try {
        $ip = $_SERVER["REMOTE_ADDR"] ?? "";
        $ua = $_SERVER["HTTP_USER_AGENT"] ?? "";
        $url = $_SERVER["REQUEST_URI"] ?? "";
        $stmt = $pdo->prepare("INSERT INTO visits (visit_date, visitor_ip, user_agent, page_url) VALUES (CURDATE(), ?, ?, ?)");
        $stmt->execute([$ip, $ua, $url]);
    } catch (Exception $e) {}
}
'

INDEX_FILE="$SITE_DIR/index.php"
if [[ -f "$INDEX_FILE" ]] || [[ -f "$SITE_DIR/index.html" ]]; then
    if [[ -f "$INDEX_FILE" ]]; then
        if ! grep -q "INSERT INTO visits" "$INDEX_FILE"; then
            cp "$INDEX_FILE" "$INDEX_FILE.bak"
            if grep -q "^<?php" "$INDEX_FILE"; then
                { echo "<?php"; echo "$TRACKER_PHP"; tail -n +2 "$INDEX_FILE"; } > "$INDEX_FILE.tmp"
            else
                { echo "<?php"; echo "$TRACKER_PHP"; cat "$INDEX_FILE"; } > "$INDEX_FILE.tmp"
            fi
            mv "$INDEX_FILE.tmp" "$INDEX_FILE"
            log_only "Трекер добавлен в существующий index.php"
        else
            log_only "Трекер уже присутствует в index.php"
        fi
    else
        log "${YELLOW}Файл index.html найден, но не index.php. JS-трекер будет добавлен через analytics.php.${NC}"
    fi
else
    cat > "$INDEX_FILE" <<EOF
<?php
require_once __DIR__ . "/config.php";
$TRACKER_PHP
require_once __DIR__ . "/cms-router.php";
EOF
    log_only "Создан новый index.php с трекером (index.html отсутствовал)"
fi

# ----------------------------------------------------------------------
# 11. Шаблон по умолчанию
# ----------------------------------------------------------------------
next_step "Создание шаблона по умолчанию"
mkdir -p "$TEMPLATES_DIR"
if [[ ! -f "$TEMPLATES_DIR/default.php" ]] || $FORCE_MODE; then
    cat > "$TEMPLATES_DIR/default.php" <<'DEFAULTTEMPLATE'
<?php require_once __DIR__ . "/../config.php"; ?>
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><title><?= htmlspecialchars($page["title"]) ?> | <?= htmlspecialchars(getSetting("site_name", SITE_NAME)) ?></title><meta name="description" content="<?= htmlspecialchars($page["meta_description"] ?? "") ?>"><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><style>body{font-family:"Segoe UI",Arial,sans-serif;line-height:1.6}header{background:#f8f9fa;padding:1rem;border-bottom:1px solid #dee2e6}main{padding:2rem}footer{background:#f8f9fa;padding:1rem;text-align:center;margin-top:2rem}</style></head><body><header><div class="container"><h1><a href="/" style="text-decoration:none;color:inherit;"><?= htmlspecialchars(getSetting("site_name", SITE_NAME)) ?></a></h1></div></header><main class="container"><article><h1><?= htmlspecialchars($page["title"]) ?></h1><?= $page["content"] ?></article></main><footer><div class="container">&copy; <?= date("Y") ?> <?= htmlspecialchars(getSetting("site_name", SITE_NAME)) ?></div></footer></body></html>
DEFAULTTEMPLATE
fi

# ----------------------------------------------------------------------
# 12. Настройка Nginx и SSL
# ----------------------------------------------------------------------
next_step "Настройка Nginx и SSL"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
if [[ ! -f "$NGINX_CONF" ]] || $FORCE_MODE; then
    if [[ "$SSL_TYPE" == "letsencrypt" ]]; then
        cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $SITE_DIR;
    index index.php index.html;
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:$PHP_SOCKET; }
    location ^~ /uploads { location ~ \.php\$ { deny all; } }
    server_tokens off;
}
EOF
        ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/"
        nginx -t && systemctl reload nginx
        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL" >> "$LOG_FILE" 2>&1
    else
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
    root $SITE_DIR;
    index index.php index.html;
    ssl_certificate $SSL_CERT_PATH;
    ssl_certificate_key $SSL_KEY_PATH;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:$PHP_SOCKET; }
    location ^~ /uploads { location ~ \.php\$ { deny all; } }
    server_tokens off;
}
EOF
        ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/"
        nginx -t && systemctl reload nginx
    fi
fi

# ----------------------------------------------------------------------
# 13. Cron для метрик (исправлен: добавлены set -e, SCRIPT_DIR, проверки)
# ----------------------------------------------------------------------
next_step "Настройка cron для метрик"
CRON_SCRIPT="/usr/local/bin/collect_server_stats.sh"
if [[ ! -f "$CRON_SCRIPT" ]] || $FORCE_MODE; then
    cat > "$CRON_SCRIPT" <<EOF
#!/bin/bash
set -e
SCRIPT_DIR="$SCRIPT_DIR"
source "\$SCRIPT_DIR/.env" || exit 1
if [[ -z "\$DB_NAME" ]]; then
    echo "DB_NAME not set" >&2
    exit 1
fi
load=\$(awk '{print \$1}' /proc/loadavg)
mem_total=\$(grep MemTotal /proc/meminfo | awk '{print \$2}')
mem_avail=\$(grep MemAvailable /proc/meminfo | awk '{print \$2}')
mem_used=\$((mem_total - mem_avail))
disk_total=\$(df / | tail -1 | awk '{print \$2}')
disk_used=\$(df / | tail -1 | awk '{print \$3}')
mysql --defaults-file=/root/.my.cnf "\$DB_NAME" <<SQL
INSERT INTO server_stats (load_1min, memory_total, memory_used, disk_total, disk_used)
VALUES (\$load, \$mem_total, \$mem_used, \$disk_total, \$disk_used);
SQL
retention=\$(mysql --defaults-file=/root/.my.cnf "\$DB_NAME" -N -e "SELECT value FROM settings WHERE key='stats_retention'" 2>/dev/null)
retention=\${retention:-30}
mysql --defaults-file=/root/.my.cnf "\$DB_NAME" -e "DELETE FROM visits WHERE visit_date < DATE_SUB(CURDATE(), INTERVAL \$retention DAY)"
mysql --defaults-file=/root/.my.cnf "\$DB_NAME" -e "DELETE FROM server_stats WHERE recorded_at < DATE_SUB(NOW(), INTERVAL \$retention DAY)"
EOF
    chmod +x "$CRON_SCRIPT"
    log_only "Cron-скрипт создан/обновлён."
    if ! grep -q "$CRON_SCRIPT" /etc/crontab; then
        echo "*/5 * * * * root $CRON_SCRIPT > /dev/null 2>&1" >> /etc/crontab
        log_only "Cron-задание добавлено."
    fi
fi

# ----------------------------------------------------------------------
# 14. Права доступа
# ----------------------------------------------------------------------
next_step "Установка прав доступа"
chown -R www-data:www-data "$SITE_DIR"
find "$SITE_DIR" -type d -exec chmod 755 {} \;
find "$SITE_DIR" -type f -exec chmod 644 {} \;
chmod 750 "$UPLOADS_DIR"
chmod 600 "$SCRIPT_DIR/.env"
log_only "Права доступа установлены."

# ----------------------------------------------------------------------
# 15. Перезапуск служб
# ----------------------------------------------------------------------
next_step "Перезапуск PHP-FPM и Nginx"
systemctl restart php${PHP_VERSION}-fpm || systemctl restart php8.3-fpm || true
systemctl reload nginx

# ----------------------------------------------------------------------
# 16. Итоговое сообщение
# ----------------------------------------------------------------------
next_step "Завершение установки"
PROTOCOL="https"
if [[ "$SSL_TYPE" != "letsencrypt" && ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    PROTOCOL="http"
fi

echo ""
log "${GREEN}======================================================"
log "${GREEN}✅ CMS и AI полностью установлены!${NC}"
log "${GREEN}======================================================"
echo ""
log "🌐 Сайт доступен по адресу: ${PROTOCOL}://${DOMAIN}"
log "🔐 Админ-панель: ${PROTOCOL}://${DOMAIN}/admin"
log "   Логин: admin"
log "   Пароль: ${ADMIN_PASSWORD}"
echo ""
log "🤖 AI-функционал:"
log "   - Генератор контента: ${PROTOCOL}://${DOMAIN}/admin/ai_generator.php"
log "   - История запросов: ${PROTOCOL}://${DOMAIN}/admin/ai_history.php"
log "   - Кнопка AI в редакторе TinyMCE (при создании/редактировании страниц)"
echo ""
log "🔧 Для работы AI необходимо:"
log "   1. Зарегистрироваться на platform.deepseek.com"
log "   2. Получить API ключ"
log "   3. В админ-панели перейти в Настройки → ввести API ключ, выбрать модель, сохранить."
echo ""
log "${YELLOW}📁 Если у вас есть готовые файлы сайта (index.html, стили, изображения):${NC}"
log "   Разместите их в директории: ${SITE_DIR}"
echo ""
log "${YELLOW}📊 Для автоматического сбора статистики посещений:${NC}"
log "   Зайдите в админ-панель → раздел «Аналитика» (или на дашборде нажмите кнопку «Встроить аналитику»)."
log "   Выберите нужные файлы (index.html, about.html и т.д.) и нажмите «Добавить трекер»."
log "   Система сама внедрит код и создаст резервные копии."
echo ""
log "⏲️  Сбор метрик сервера запущен (каждые 5 минут)."
log "📝 Лог установки: ${LOG_FILE}"
echo ""
log "💡 Для перезаписи существующих файлов используйте: ./cms.sh --force"
log "======================================================"

exit 0