# Пакет проверки готовности релиза

Эта папка — самостоятельная копия лабораторной работы по проверке готовности релиза. Все команды ниже выполняются в PowerShell; сначала перейдите из корня репозитория в `lab7/artifacts`.

## Требования

Windows с Docker Desktop в режиме Linux containers и поддержкой NVIDIA GPU, актуальный драйвер NVIDIA, Git и Python 3. Node.js нужен только для локальных модульных тестов. Для загрузки образов и модели потребуется несколько гигабайт свободного места на диске; выделите Docker около 16 ГБ RAM. Для запуска нужны порты localhost 5678 (n8n), 11434 (Ollama), 9098 (Prometheus) и 3008 (Grafana).

## Запуск чистого экземпляра

Если эти порты заняты текущим стендом lab8, остановите его перед запуском. Из корня репозитория выполните:

```powershell
docker compose -p lab8-release -f lab8/release-readiness/compose.yaml stop
```

Затем перейдите в пакет и запустите Compose с отдельным проектом и томами:

```powershell
Set-Location lab7/artifacts
$env:COMPOSE_PROJECT_NAME = 'lab7-check'
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
# Отредактируйте .env и задайте новый локальный пароль GRAFANA_ADMIN_PASSWORD.
python scripts/prepare_fixtures.py
python scripts/build_workflow.py
python scripts/build_dashboard.py
docker compose build git-mcp
docker compose up -d
```

`prepare_fixtures.py` создаёт небольшой Git-репозиторий, каталог, примеры evidence и папку reports. `build_workflow.py` встраивает свежий SHA созданного fixture-коммита в `workflow.json`. Повторно запускайте оба генератора после пересоздания fixtures. Не копируйте в пакет старые `.env`, `runtime/account.json`, credentials или reports.

Проверка готовности n8n ограничена 60 попытками по 5 секунд:

```powershell
$ready = $false
for ($attempt = 0; $attempt -lt 60; $attempt++) {
  try {
    Invoke-RestMethod -Uri http://localhost:5678/healthz/readiness -TimeoutSec 5 | Out-Null
    $ready = $true
    break
  } catch {
    Start-Sleep -Seconds 5
  }
}
if (-not $ready) { throw 'n8n не стал готов после 60 попыток; проверьте docker compose logs.' }
```

Создайте или авторизуйте локального владельца n8n, импортируйте локальные Ollama credential и workflow, затем активируйте workflow:

```powershell
python scripts/n8n_local.py
docker compose exec -T n8n n8n import:credentials --input=/lab/ollama-credential.json
docker compose exec -T n8n n8n import:workflow --input=/lab/workflow.json
python scripts/n8n_local.py publish
docker compose exec -T ollama ollama pull qwen3:4b-instruct-2507-q4_K_M
python scripts/check_model.py
docker compose exec -T n8n node /lab/scripts/check_mcp.cjs
python scripts/smoke.py
```

`n8n_local.py` при первом запуске создаёт случайный пароль владельца и сохраняет его только в игнорируемом `runtime/account.json`. Если владелец n8n уже существует, но этого приватного файла нет, скрипт остановится и не будет заменять учётные данные. Войдите в UI n8n под владельцем этого экземпляра, создайте Ollama credential с адресом `http://ollama:11434`, импортируйте `workflow.json`, выберите созданный credential в узле Local Qwen3 и опубликуйте workflow. Не добавляйте в пакет файл учётной записи существующего владельца или его credentials.

Ollama выгружает неиспользуемую модель через 10 минут. Первая загрузка модели и первый запрос могут занять время; `check_model.py` после загрузки проверяет, что модель действительно вызывает инструмент.

## Остановка и повторный запуск

Остановить службы, сохранив тома и данные:

```powershell
docker compose stop
```

Чтобы запустить их снова в этой же PowerShell-сессии:

```powershell
docker compose up -d
```

В новом окне PowerShell сначала задайте имя проекта снова, иначе `compose.yaml` выберет проект `lab8-release`:

```powershell
Set-Location lab7/artifacts
$env:COMPOSE_PROJECT_NAME = 'lab7-check'
docker compose up -d
```

## Проверка и демонстрация

```powershell
node --test tests/logic.test.cjs
```

Набор содержит 5 модульных тестов. `check_mcp.cjs` проверяет allowlist обоих MCP-серверов, чтение Git/evidence и запрет операций записи. `smoke.py` выполняет 8 проверок webhook, включая некорректные и неизвестные запросы, а также релизы ready, blocked и incomplete; при успехе он выводит 8 строк `PASS`.

Пример запроса:

```powershell
Invoke-RestMethod -Method Post -Uri http://localhost:5678/webhook/release-readiness -ContentType application/json -Body '{"release_id":"shop-ready"}'
```

Ответ содержит `release_id`, `status`, `report_path` и Markdown `report`. Три примера должны возвращать HTTP 200 со статусами `ready`, `blocked` и `incomplete`. `blocked` — решение по релизу, а не технический сбой workflow. Некорректный запрос возвращает 400, неизвестный релиз — 404; технические сбои, например недоступность MCP/модели или неверный анализ, возвращают 502. Отчёты сохраняются в `reports/`, диагностика smoke/model — в игнорируемой папке `runtime/`.

## Состав пакета

- `compose.yaml`, `.env.example`, `.gitignore`: локальные службы и игнорируемые локальные данные.
- `mcp/`, `workflow/logic.cjs`, `workflow.json`, `ollama-credential.json`: ограниченные MCP-серверы, логика workflow и импортируемые настройки n8n.
- `fixtures/catalog.json`, `fixtures/evidence/`: примеры релизов; репозиторий fixture создаётся локально.
- `scripts/`, `tests/`, `skills/`, `api/openapi.yaml`: настройка и проверки, модульные тесты, инструкции агента и контракт API.
- `monitoring/`: конфигурация Prometheus и Grafana.

Интерфейсы: n8n `http://localhost:5678`, Grafana `http://localhost:3008/d/lab8-release` (анонимная роль Viewer), Prometheus `http://localhost:9098`, список процессов Ollama `http://localhost:11434/api/ps`. Текущее состояние Ollama можно посмотреть командой `docker compose exec -T ollama ollama ps`; логи — `docker compose logs --tail 100 <service>`.

Экспортированный workflow содержит SHA fixtures и должен быть заново сгенерирован после создания fixtures на каждой машине. Для проверки используйте отдельные тома проекта `lab7-check`; старый стенд lab8 должен быть остановлен, пока вы тестируете этот пакет, поскольку оба набора служб публикуют те же порты localhost. Команда `down -v` не требуется.
