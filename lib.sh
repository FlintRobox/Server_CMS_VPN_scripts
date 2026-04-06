#!/bin/bash
# =====================================================================
# lib.sh - Общая библиотека для скриптов установки CMS, VPN, AI
# Версия: 1.0
# Содержит унифицированные функции логирования, создания файлов,
# работы с БД, запроса переменных и прогресс-бара.
# =====================================================================

# --- Цвета для вывода в консоль ---
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export NC='\033[0m' # No Color

# --- Глобальные переменные ---
export LOG_FILE="/var/log/setup.log"
export FORCE_MODE=false   # устанавливается из аргументов скрипта

# ----------------------------------------------------------------------
# Функции логирования
# ----------------------------------------------------------------------

# Логирование только в файл (без вывода в консоль)
log_only() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Логирование в файл и цветной вывод в консоль
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

# Выполнение команды с логированием (stdout/stderr направляются в лог)
run_cmd() {
    log_only "Выполнение: $*"
    "$@" >> "$LOG_FILE" 2>&1
}

# ----------------------------------------------------------------------
# Функция прогресса
# ----------------------------------------------------------------------
# Выводит процент выполнения и сообщение
# Использование: show_progress <текущий_шаг> <всего_шагов> "Сообщение"
show_progress() {
    local current=$1
    local total=$2
    local message=$3
    local percent=$(( current * 100 / total ))
    echo -e "[${percent}%] ${message}"
}

# ----------------------------------------------------------------------
# Функции создания файлов
# ----------------------------------------------------------------------

# Создание PHP-файла с проверкой синтаксиса и резервным копированием
# Аргументы: create_php_file <путь_к_файлу> "содержимое"
create_php_file() {
    local file="$1"
    local backup_ext=".backup.$(date +%Y%m%d%H%M%S)"
    
    if [[ -f "$file" ]] && [[ "$FORCE_MODE" == false ]]; then
        log "${YELLOW}⚠ Файл $file уже существует. Пропуск (используйте --force для перезаписи).${NC}"
        return 1
    fi
    
    if [[ -f "$file" ]]; then
        cp "$file" "$file$backup_ext"
        log_only "Создана резервная копия $file$backup_ext"
    fi
    
    mkdir -p "$(dirname "$file")"
    
    # Если передан второй аргумент – записываем его, иначе читаем stdin
    if [[ $# -ge 2 ]]; then
        printf '%s' "$2" > "$file"
    else
        cat > "$file"
    fi
    
    log_only "Файл $file создан/обновлён."
    
    if [[ "$file" == *.php ]]; then
        if ! php -l "$file" >> "$LOG_FILE" 2>&1; then
            log "${RED}КРИТИЧЕСКАЯ ОШИБКА: Файл $file содержит синтаксическую ошибку.${NC}"
            log "Проверьте его содержимое вручную. Резервная копия: $file$backup_ext"
            exit 1
        fi
    fi
}

# ----------------------------------------------------------------------
# Функции для интерактивного ввода переменных
# ----------------------------------------------------------------------

# Валидация доменного имени
validate_domain() {
    local domain="$1"
    [[ -n "$domain" && "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# Валидация email
validate_email() {
    local email="$1"
    [[ -n "$email" && "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# Универсальный запрос переменной с дефолтным значением и валидацией
# Аргументы: ask_var <имя_переменной> "подсказка" "значение_по_умолчанию" "функция_валидации"
# Результат: переменная окружения с указанным именем получает введённое значение
ask_var() {
    local var_name="$1"
    local prompt="$2"
    local default_value="$3"
    local validation_func="$4"
    local value
    
    while true; do
        read -p "$prompt [$default_value]: " value
        if [[ -z "$value" ]]; then
            value="$default_value"
        fi
        if [[ -n "$validation_func" ]]; then
            if $validation_func "$value"; then
                break
            else
                log "${RED}Некорректное значение. Попробуйте снова.${NC}"
            fi
        else
            break
        fi
    done
    
    # Устанавливаем переменную окружения
    export "$var_name=$value"
    log_only "$var_name = $value"
}

# ----------------------------------------------------------------------
# Функции для работы с .env файлом
# ----------------------------------------------------------------------

# Загрузка .env и проверка наличия обязательных переменных
# Аргументы: load_env <переменная1> <переменная2> ...
# Если файл .env отсутствует – ошибка.
# Если какая-то из переданных переменных не задана – ошибка.
load_env() {
    local env_file="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)/.env"
    
    if [[ ! -f "$env_file" ]]; then
        log "${RED}Ошибка: файл .env не найден в директории скрипта.${NC}"
        exit 1
    fi
    
    # Загружаем переменные
    set -a
    source "$env_file"
    set +a
    
    # Проверяем наличие обязательных переменных
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "${RED}Ошибка: следующие обязательные переменные не заданы в .env: ${missing[*]}${NC}"
        exit 1
    fi
    
    log_only ".env загружен, переменные проверены."
}

# ----------------------------------------------------------------------
# Функции для работы с базой данных
# ----------------------------------------------------------------------

# Вспомогательная функция для выполнения mysql-запросов с безопасной передачей пароля
# Использует /root/.my.cnf, если доступен, иначе – переменные окружения
_mysql() {
    local mysql_opts=""
    if [[ -f "/root/.my.cnf" ]]; then
        mysql_opts="--defaults-file=/root/.my.cnf"
    elif [[ -n "${DB_USER:-}" && -n "${DB_PASSWORD:-}" ]]; then
        mysql_opts="-u${DB_USER} -p${DB_PASSWORD}"
    else
        log "${RED}Ошибка: нет доступа к MySQL (нет /root/.my.cnf и не заданы DB_USER/DB_PASSWORD).${NC}"
        return 1
    fi
    mysql $mysql_opts "$@"
}

# Проверка существования таблицы в текущей БД
# Аргументы: table_exists <имя_таблицы>
table_exists() {
    local table="$1"
    local db_name="${DB_NAME:-}"
    if [[ -z "$db_name" ]]; then
        log "${RED}Ошибка: переменная DB_NAME не задана.${NC}"
        return 1
    fi
    _mysql -N -s -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db_name' AND table_name='$table';" 2>/dev/null | grep -q '^1$'
}

# Проверка существования колонки в таблице
# Аргументы: column_exists <таблица> <колонка>
column_exists() {
    local table="$1"
    local column="$2"
    local db_name="${DB_NAME:-}"
    if [[ -z "$db_name" ]]; then
        log "${RED}Ошибка: переменная DB_NAME не задана.${NC}"
        return 1
    fi
    _mysql -N -s -e "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='$db_name' AND table_name='$table' AND column_name='$column';" 2>/dev/null | grep -q '^1$'
}

# ----------------------------------------------------------------------
# Функции для работы с пакетами
# ----------------------------------------------------------------------

# Проверка, установлен ли deb-пакет
is_pkg_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q '^ii'
}

# ----------------------------------------------------------------------
# Инициализация глобальной переменной FORCE_MODE из аргументов скрипта
# Эту функцию должен вызывать каждый скрипт после подключения lib.sh
# Пример: init_force_mode "$@"
init_force_mode() {
    for arg in "$@"; do
        if [[ "$arg" == "--force" || "$arg" == "-f" ]]; then
            FORCE_MODE=true
            log "${YELLOW}Режим принудительной перезаписи включён.${NC}"
            break
        fi
    done
}