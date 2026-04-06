#!/bin/bash
# =====================================================================
# ai.sh - Интеграция AI DeepSeek в админ-панель CMS
# Версия: 2.0 (безопасная, без повреждения файлов админки)
# Добавляет раздел генерации контента, историю запросов,
# кнопку в TinyMCE через отдельный плагин, настройки API ключа.
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

# --- Проверка прав root ---
if [[ $EUID -ne 0 ]]; then
    log "${RED}Ошибка: скрипт должен запускаться от root (или с sudo).${NC}"
    exit 1
fi

# --- Загрузка конфигурации ---
load_env "DOMAIN" "DB_NAME" "DB_USER" "DB_PASSWORD"

# --- Пути ---
SITE_DIR="${WEB_ROOT_BASE:-/var/www}/${DOMAIN}"
ADMIN_DIR="${SITE_DIR}/admin"
CONFIG_PATH="${SITE_DIR}/config.php"

# --- Проверка существования сайта и админки ---
if [[ ! -d "$ADMIN_DIR" ]]; then
    log "${RED}Админ-панель не найдена. Сначала выполните cms.sh.${NC}"
    exit 1
fi

# --- Подсчёт шагов ---
TOTAL_STEPS=8
CURRENT_STEP=0

next_step() {
    CURRENT_STEP=$((CURRENT_STEPS + 1))
    local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    echo "[${percent}%] $1"
}

# ----------------------------------------------------------------------
# 1. Добавление таблицы истории запросов
# ----------------------------------------------------------------------
next_step "Создание таблицы ai_requests"
mysql --defaults-file=/root/.my.cnf "$DB_NAME" <<EOF
CREATE TABLE IF NOT EXISTS ai_requests (
    id INT AUTO_INCREMENT PRIMARY KEY,
    prompt TEXT NOT NULL,
    response TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    user_id INT NOT NULL,
    INDEX (user_id),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
EOF
log_only "Таблица ai_requests создана."

# ----------------------------------------------------------------------
# 2. Добавление настроек API в settings.php
# ----------------------------------------------------------------------
next_step "Добавление настроек DeepSeek в админ-панель"

if ! grep -q "deepseek_api_key" "$ADMIN_DIR/settings.php"; then
    cp "$ADMIN_DIR/settings.php" "$ADMIN_DIR/settings.php.bak.$(date +%Y%m%d%H%M%S)"
    
    # Вставляем блок настроек перед кнопкой сохранения
    sed -i '/<button type="submit" class="btn btn-primary">/i \
    <hr>\
    <h4 class="mt-4">DeepSeek AI Settings</h4>\
    <div class="mb-3">\
        <label class="form-label">API Key DeepSeek</label>\
        <input type="password" class="form-control" name="deepseek_api_key" value="<?= htmlspecialchars($settings["deepseek_api_key"] ?? "") ?>">\
        <div class="form-text">Получите ключ на platform.deepseek.com</div>\
    </div>\
    <div class="mb-3">\
        <label class="form-label">Модель</label>\
        <select class="form-select" name="deepseek_model">\
            <option value="deepseek-chat" <?= ($settings["deepseek_model"] ?? "deepseek-chat") == "deepseek-chat" ? "selected" : "" ?>>DeepSeek Chat</option>\
            <option value="deepseek-coder" <?= ($settings["deepseek_model"] ?? "") == "deepseek-coder" ? "selected" : "" ?>>DeepSeek Coder</option>\
        </select>\
    </div>\
    <div class="mb-3">\
        <label class="form-label">Max tokens</label>\
        <input type="number" class="form-control" name="deepseek_max_tokens" value="<?= htmlspecialchars($settings["deepseek_max_tokens"] ?? 2000) ?>" min="100" max="8000">\
    </div>' "$ADMIN_DIR/settings.php"
    
    # Добавляем ключи в массив $keys в обработчике POST
    sed -i "/\$keys = \[/a \ \ \ \ \"deepseek_api_key\",\"deepseek_model\",\"deepseek_max_tokens\"," "$ADMIN_DIR/settings.php"
    
    log_only "Настройки DeepSeek добавлены в settings.php"
else
    log "${YELLOW}Настройки DeepSeek уже присутствуют в settings.php. Пропуск.${NC}"
fi

# ----------------------------------------------------------------------
# 3. Создание страницы генерации контента ai_generator.php
# ----------------------------------------------------------------------
next_step "Создание ai_generator.php"
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
                            <div id="generated_text" class="border p-3 bg-light" style="max-height: 400px; overflow: auto;"><?= nl2br(htmlspecialchars($generated_text)) ?></div>
                        </div>
                        <button class="btn btn-success" onclick="createPage()"><i class="bi bi-file-earmark-plus"></i> Создать страницу</button>
                        <button class="btn btn-info" onclick="insertToEditor()"><i class="bi bi-pencil-square"></i> Вставить в редактор</button>
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
        var text = document.getElementById("generated_text").innerText;
        if (window.opener && window.opener.tinymce) {
            var editor = window.opener.tinymce.activeEditor;
            if (editor) {
                editor.insertContent(text);
                window.close();
            } else {
                alert("Редактор не найден");
            }
        } else {
            alert("Окно не связано с редактором");
        }
    }
    function createPage() {
        var title = document.getElementById("generated_title").value;
        var content = document.getElementById("generated_text").innerText;
        if (!title) title = "Новая страница";
        var url = "/admin/edit_page.php?prefill_title=" + encodeURIComponent(title) + "&prefill_content=" + encodeURIComponent(content);
        window.open(url, "_blank");
    }
    </script>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
AIGEN
log_only "ai_generator.php создан."

# ----------------------------------------------------------------------
# 4. Создание страницы истории запросов ai_history.php
# ----------------------------------------------------------------------
next_step "Создание ai_history.php"
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
log_only "ai_history.php создан."

# ----------------------------------------------------------------------
# 5. Создание API эндпоинта для TinyMCE (ai_api.php)
# ----------------------------------------------------------------------
next_step "Создание ai_api.php для AJAX-запросов из редактора"
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
    global $pdo;
    $stmt = $pdo->prepare("INSERT INTO ai_requests (prompt, response, user_id) VALUES (?, ?, ?)");
    $stmt->execute([$prompt, $generated_text, $_SESSION["user_id"]]);
    echo json_encode(["response" => $generated_text]);
} else {
    echo json_encode(["error" => "Ошибка API: HTTP $http_code"]);
}
AIPHP
log_only "ai_api.php создан."

# ----------------------------------------------------------------------
# 6. Интеграция кнопки AI в TinyMCE (безопасная версия – отдельный плагин)
# ----------------------------------------------------------------------
next_step "Интеграция кнопки AI в редактор TinyMCE"

# Создаём отдельный JavaScript-файл плагина
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
log_only "Плагин AI для TinyMCE создан."

# Добавляем подключение плагина в tinymce.init для edit_page.php и edit_file.php
for file in "$ADMIN_DIR/edit_page.php" "$ADMIN_DIR/edit_file.php"; do
    if [[ -f "$file" ]]; then
        if ! grep -q "external_plugins" "$file"; then
            cp "$file" "$file.bak.$(date +%Y%m%d%H%M%S)"
            # Вставляем external_plugins после строки selector
            sed -i '/selector: "#content",/a \ \ \ \ external_plugins: { "ai_button": "/admin/js/ai_tinymce_plugin.js" },' "$file"
            # Добавляем кнопку в toolbar, если её нет
            if ! grep -q "ai_button" "$file"; then
                sed -i 's/toolbar: "\(.*\)"/toolbar: "\1 ai_button"/' "$file"
            fi
        fi
    fi
done
log_only "Кнопка AI добавлена в редакторы TinyMCE."

# ----------------------------------------------------------------------
# 7. Добавление пунктов меню в sidebar.php
# ----------------------------------------------------------------------
next_step "Добавление пунктов меню для AI"
SIDEBAR="$ADMIN_DIR/includes/sidebar.php"
if [[ -f "$SIDEBAR" ]]; then
    if ! grep -q "ai_generator.php" "$SIDEBAR"; then
        cp "$SIDEBAR" "$SIDEBAR.bak.$(date +%Y%m%d%H%M%S)"
        sed -i '/<li class="nav-item">.*content.php/a \
<li class="nav-item">\
    <a class="nav-link <?= $current_page=="ai_generator.php"?"active":"" ?>" href="/admin/ai_generator.php">\
        <i class="bi bi-robot"></i> <?= __("ai_generator") ?>\
    </a>\
</li>' "$SIDEBAR"
        log_only "Пункт меню AI Generator добавлен."
    fi
    if ! grep -q "ai_history.php" "$SIDEBAR"; then
        sed -i '/<li class="nav-item">.*settings.php/i \
<li class="nav-item">\
    <a class="nav-link <?= $current_page=="ai_history.php"?"active":"" ?>" href="/admin/ai_history.php">\
        <i class="bi bi-clock-history"></i> <?= __("ai_history") ?>\
    </a>\
</li>' "$SIDEBAR"
        log_only "Пункт меню AI History добавлен."
    fi
else
    log "${YELLOW}sidebar.php не найден, пропуск добавления пунктов меню.${NC}"
fi

# ----------------------------------------------------------------------
# 8. Обновление языковых файлов (безопасное, через временный файл)
# ----------------------------------------------------------------------
next_step "Обновление языковых файлов"
for lang in ru en; do
    LOCALE_FILE="$ADMIN_DIR/locale/$lang.php"
    if [[ -f "$LOCALE_FILE" ]]; then
        if ! grep -q "ai_generator" "$LOCALE_FILE"; then
            TMP_FILE=$(mktemp)
            # Копируем всё, кроме последней строки "];"
            sed '$d' "$LOCALE_FILE" > "$TMP_FILE"
            # Добавляем новые ключи
            if [[ "$lang" == "ru" ]]; then
                echo '    "ai_generator" => "Генератор AI",' >> "$TMP_FILE"
                echo '    "ai_history" => "История AI",' >> "$TMP_FILE"
            else
                echo '    "ai_generator" => "AI Generator",' >> "$TMP_FILE"
                echo '    "ai_history" => "AI History",' >> "$TMP_FILE"
            fi
            # Добавляем закрывающую строку
            echo '];' >> "$TMP_FILE"
            mv "$TMP_FILE" "$LOCALE_FILE"
            log_only "Добавлены языковые ключи для AI в $lang.php"
        fi
    fi
done

# ----------------------------------------------------------------------
# Итоговое сообщение
# ----------------------------------------------------------------------
log "${GREEN}======================================================"
log "${GREEN}✅ Интеграция DeepSeek AI успешно завершена!${NC}"
log "${GREEN}======================================================"
echo ""
log "🤖 Новые разделы админ-панели:"
log "   - Генератор контента: https://${DOMAIN}/admin/ai_generator.php"
log "   - История запросов: https://${DOMAIN}/admin/ai_history.php"
echo ""
log "✏️ В редакторе TinyMCE (при создании/редактировании страниц) появилась кнопка \"AI\"."
log "   Нажмите её, введите запрос, и сгенерированный текст будет вставлен в редактор."
echo ""
log "🔧 Для работы необходимо:"
log "   1. Зарегистрироваться на platform.deepseek.com"
log "   2. Получить API ключ"
log "   3. В админ-панели перейти в Настройки → ввести API ключ, выбрать модель, сохранить."
echo ""
log "📊 Все запросы сохраняются в таблицу ai_requests и доступны в истории."
echo ""
log "💡 Для принудительной перезаписи используйте: ./ai.sh --force"
log "======================================================"

exit 0