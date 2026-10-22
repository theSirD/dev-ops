# Часть 7. Подготовка gVisor

## Цель

Запустить существующий образ lab1-api:multi через runsc, сравнить устройство изоляции с обычным Docker/runc и mydocker.sh. Установка и настройка выполняются пользователем на удалённом Debian, все результаты заносятся в Lab1.md.

## Подтверждённое состояние перед установкой

- Debian 13 amd64, ядро 6.12; Docker 26.1.5, cgroup v2 и драйвер systemd.
- command -v runsc не вывел путь; runtime runsc не зарегистрирован. Docker перечисляет runc и io.containerd.runc.v2.
- Пользователь остановил lab1-images-single и lab1-images-multi; docker ps показал пустой список. Контейнеры были созданы с --rm.
- /etc/docker/daemon.json отсутствует — подтверждено пользователем до установки.
- Named volume lab1-images-data оставлен для защиты; он не относится к установке runtime и не удаляется.

## Выбранный способ

Официальный apt-репозиторий gVisor, канал release, пакет runsc. Документация рекомендует пакетную установку и описывает автоматическую интеграцию с Docker. Однако в подтверждённом опыте пакет 20261012.0 не создал daemon.json и не зарегистрировал runsc; требуется явная регистрация. Точную установленную версию фиксируем по фактическому выводу. Готовый runtime выбираем явно для опыта, не меняя default-runtime.

Прежде чем пакет изменит конфигурацию Docker, изучить существующий daemon.json и подготовить резервную копию его текущего состояния. Если файла нет, зафиксировать отсутствие. Не записывать готовый JSON поверх неизвестной конфигурации.

## Текущий шаг: установка пакета

Выполнить на удалённом Debian из ~/lab1. При ошибке остановиться и прислать вывод; не переходить к следующему блоку.

### Зависимости и ключ репозитория

~~~bash
cd ~/lab1
sudo apt-get update &&
sudo apt-get install -y ca-certificates curl gnupg
~~~

~~~bash
curl -fsSL https://gvisor.dev/archive.key -o gvisor-archive.key &&
gpg --batch --yes --dearmor --output gvisor-archive-keyring.gpg gvisor-archive.key &&
sudo install -m 0644 gvisor-archive-keyring.gpg /usr/share/keyrings/gvisor-archive-keyring.gpg
~~~

Ключ ограничен этим репозиторием через signed-by. Публичный ключ и его преобразованная копия остаются в рабочем каталоге удалённой машины.

### Репозиторий и пакет

Для подтверждённой архитектуры amd64:

~~~bash
printf '%s\n' 'deb [arch=amd64 signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main' | sudo tee /etc/apt/sources.list.d/gvisor.list
sudo apt-get update && sudo apt-get install -y runsc
~~~

Пакет устанавливает runtime и сопутствующие компоненты. В данном окружении автоматическая регистрация Docker не произошла: после установки daemon.json отсутствует, а docker info перечисляет только прежние runtimes. Повторно устанавливать пакет не требуется.

### Регистрация, проверка и применение настроек

Установлено пользователем: runsc version release-20261012.0, spec 1.2.1, пакет 20261012.0. Docker active, Default=runc. Первая проверка dockerd --validate завершилась ошибкой отсутствия файла; перезапуск после && не выполнялся. Причина отсутствия автоматической регистрации пакетом не установлена. Следующий шаг использует штатную команду регистрации из Docker Quick Start:

~~~bash
sudo runsc install
~~~

После её успешного выполнения:

~~~bash
sudo cat /etc/docker/daemon.json
sudo dockerd --validate --config-file=/etc/docker/daemon.json &&
sudo systemctl restart docker
~~~

Перезапуск применяется после успешной проверки конфигурации; отсутствие работающих контейнеров уже подтверждено. Если файл не появился или проверка завершилась ошибкой, не перезапускать Docker и прислать вывод.

~~~bash
runsc --version
dpkg-query -W runsc
sudo systemctl is-active docker
sudo docker info --format 'Default={{.DefaultRuntime}} Runtimes={{json .Runtimes}}'
~~~

Ожидается active и runtime runsc; runtime по умолчанию должен остаться runc. Сохранить вывод версии, daemon.json и docker info для отчёта. Это ожидаемые результаты, а не подтверждение установки.

## Запуск сервиса через gVisor

Регистрация подтверждена пользователем: sudo runsc install создал runtimes.runsc.path=/usr/bin/runsc; dockerd --validate выдал configuration OK; после перезапуска Docker active, Default=runc. В объявленных runtime параметрах platform=systrap; это значение конфигурации, а не отдельное доказательство фактической платформы запущенного контейнера. Поля cgroup.v2=false/systemd=false в features не заменяют проверку запуска и действующих лимитов на хосте.

На удалённом Debian, из ~/lab1, запустить существующий multi-stage образ с теми же заданными лимитами, что в предыдущем опыте. Контейнер сохраняется после завершения для диагностики.

~~~bash
sudo docker run -d --name lab1-gvisor --runtime=runsc \
  --memory 128m --memory-swap 128m --cpus 0.5 --pids-limit 64 \
  --cap-drop ALL --security-opt no-new-privileges=true \
  --publish 127.0.0.1:8083:8080 lab1-api:multi
~~~

Если запуск завершился ошибкой, сохранить полный текст ошибки и не повторять создание контейнера с тем же именем. Лимиты пока заданы командой, их фактическое применение будет проверено отдельно.

~~~bash
sudo docker ps -a --filter 'name=^/lab1-gvisor

1. Выполнить приведённую установку из официального apt-репозитория. Исходный daemon.json отсутствовал, поэтому резервировать его содержимое не требуется.
2. Проверить runsc --version, наличие runtime runsc в docker info и неизменность runtime по умолчанию. Применение конфигурации и необходимость reload/restart определяются по результату установки; перед этим учитываются работающие контейнеры.
3. После подтверждения установки выдать команды запуска того же образа через runsc и сравнения изоляции. Платформа runtime и фактические результаты не предполагаются заранее.
4. После опыта проверить понимание дополнительной границы gVisor, общего ядра обычных контейнеров и компромиссов.

Статус: исходная проверка, остановка контейнеров и проверка отсутствия daemon.json выполнены пользователем; пакет runsc 20261012.0 установлен; регистрация runsc подтверждена, запуск приложения под gVisor и HTTP 200 подтверждены; чтение лимитов cgroup и вопросы по механизму остаются.

Источники: [установка](https://gvisor.dev/docs/user_guide/install/), [Docker Quick Start](https://gvisor.dev/docs/user_guide/quick_start/docker/), [systemd cgroup driver](https://gvisor.dev/docs/user_guide/systemd/).

sudo docker logs lab1-gvisor
sudo docker inspect --format 'Runtime={{.HostConfig.Runtime}} Image={{.Image}} Status={{.State.Status}} PID={{.State.Pid}} OOMKilled={{.State.OOMKilled}} Error={{.State.Error}}' lab1-gvisor
~~~

При работающем контейнере:

~~~bash
curl --noproxy '*' -i --max-time 10 http://127.0.0.1:8083/health
PID=$(sudo docker inspect --format '{{.State.Pid}}' lab1-gvisor)
ps -o pid,ppid,uid,user,args -p "$PID"
sudo pgrep -a -f 'runsc|gvisor.*(sentry|gofer)'
~~~

Цель: проверить HTTP 200 с телом ok, выбранный runtime и сопоставить PID из лога приложения с процессом на хосте. Не предполагать, что State.Pid у gVisor обозначает обычный Linux-процесс приложения, как при runc. Отсутствие sh/dmesg в scratch ожидаемо, поэтому docker exec этих утилит здесь не используется. Порт опубликован только на loopback хоста; проверка выполняется на сервере.

Сохранить вывод запуска, логов, inspect, HTTP и процессов для отчёта. Работа приложения, процессы sandbox и действующие ограничения пока не подтверждены.

## Проверка cgroup после успешного запуска

HTTP и процессы подтверждены пользователем; фактические лимиты cgroup ещё предстоит прочитать. На сервере выполнить в одном терминале:

~~~bash
PID=$(sudo docker inspect --format '{{.State.Pid}}' lab1-gvisor)
CGPATH=$(sudo awk -F: '$1=="0" {print $3}' "/proc/$PID/cgroup")
CG="/sys/fs/cgroup$CGPATH"
printf 'Sandbox PID=%s\nCgroup=%s\n' "$PID" "$CG"
for name in memory.max memory.swap.max cpu.max pids.max; do
  printf '%s: ' "$name"
  sudo cat "$CG/$name"
done
~~~

Ожидаются memory.max=134217728, memory.swap.max=0, cpu.max='50000 100000', pids.max=64. При другом результате сохранить вывод: ограничения могут быть расположены на предке cgroup, это требуется проверить, а не объявлять лимиты отсутствующими.

Sentry реализует системный интерфейс для приложения в пользовательском пространстве; Gofer обслуживает доступ к файловой системе в рамках конфигурации. Host UID sandbox не определяет UID виртуального процесса приложения. Для анализа полномочий sandbox отдельно нужны uid_map и capabilities, одного ps недостаточно.

Вопросы после проверки: какой компонент обрабатывает системные вызовы приложения при runc и при gVisor; почему gVisor всё равно зависит от ядра хоста; какие издержки по производительности и совместимости может дать этот дополнительный слой?

Источник: [архитектура gVisor](https://gvisor.dev/docs/architecture_guide/intro/).

## Дальнейший порядок

1. Выполнить приведённую установку из официального apt-репозитория. Исходный daemon.json отсутствовал, поэтому резервировать его содержимое не требуется.
2. Проверить runsc --version, наличие runtime runsc в docker info и неизменность runtime по умолчанию. Применение конфигурации и необходимость reload/restart определяются по результату установки; перед этим учитываются работающие контейнеры.
3. После подтверждения установки выдать команды запуска того же образа через runsc и сравнения изоляции. Платформа runtime и фактические результаты не предполагаются заранее.
4. После опыта проверить понимание дополнительной границы gVisor, общего ядра обычных контейнеров и компромиссов.

Статус: исходная проверка, остановка контейнеров и проверка отсутствия daemon.json выполнены пользователем; пакет runsc 20261012.0 установлен; регистрация runsc и запуск под gVisor ещё не подтверждены.

Источники: [установка](https://gvisor.dev/docs/user_guide/install/), [Docker Quick Start](https://gvisor.dev/docs/user_guide/quick_start/docker/), [systemd cgroup driver](https://gvisor.dev/docs/user_guide/systemd/).
