# gVisor: установка и проверка

Все команды выполнять на удалённом Debian из каталога Lab1 (в опытах — ~/lab1). Результаты и сравнение изоляции сохранены в [отчёте](../Lab1.md).

## Установка runsc

Для проверенного окружения Debian 13 amd64 использован официальный apt-репозиторий gVisor, канал release. Фактически установлена версия 20261012.0. Канал release обновляется, поэтому при повторении записать полученную версию.

Перед изменением Docker проверить работающие контейнеры и существующий daemon.json; если он есть, сохранить резервную копию. В проведённом опыте файл отсутствовал, старые тестовые контейнеры были остановлены.

```bash
sudo apt-get update &&
sudo apt-get install -y ca-certificates curl gnupg

curl -fsSL https://gvisor.dev/archive.key -o gvisor-archive.key &&
gpg --batch --yes --dearmor --output gvisor-archive-keyring.gpg gvisor-archive.key &&
sudo install -m 0644 gvisor-archive-keyring.gpg /usr/share/keyrings/gvisor-archive-keyring.gpg

printf '%s\n' 'deb [arch=amd64 signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main' |
  sudo tee /etc/apt/sources.list.d/gvisor.list
sudo apt-get update && sudo apt-get install -y runsc
runsc --version
```

Пакет в нашем опыте не зарегистрировал runtime автоматически, поэтому выполнили штатную регистрацию:

```bash
sudo runsc install
sudo cat /etc/docker/daemon.json
sudo dockerd --validate --config-file=/etc/docker/daemon.json &&
sudo systemctl restart docker
sudo systemctl is-active docker
sudo docker info --format 'Default={{.DefaultRuntime}} Runsc={{json (index .Runtimes "runsc")}}'
```

Перезапуск Docker учитывать для всех работающих контейнеров. В проверенной конфигурации runsc указывает на /usr/bin/runsc, default runtime остался runc.

## Запуск образа

Образ lab1-api:multi предварительно собирается по [инструкции](images.md). Если lab1-gvisor уже существует, сначала проверить его состояние: повторный run с тем же именем не создаёт новый контейнер.

```bash
sudo docker run -d --name lab1-gvisor --runtime=runsc \
  --memory 128m --memory-swap 128m --cpus 0.5 --pids-limit 64 \
  --cap-drop ALL --security-opt no-new-privileges=true \
  --publish 127.0.0.1:8083:8080 lab1-api:multi

sudo docker ps -a --filter 'name=^/lab1-gvisor$'
sudo docker logs lab1-gvisor
sudo docker inspect --format 'Runtime={{.HostConfig.Runtime}} Status={{.State.Status}} PID={{.State.Pid}} OOMKilled={{.State.OOMKilled}} Error={{.State.Error}}' lab1-gvisor
curl --noproxy '*' -i --max-time 10 http://127.0.0.1:8083/health
```

## Процессы и cgroup на хосте

Следующие команды выполнять только при Status=running и положительном PID.

```bash
PID=$(sudo docker inspect --format '{{.State.Pid}}' lab1-gvisor)
ps -o pid,ppid,uid,user,args -p "$PID"
sudo pgrep -a -f 'runsc|gvisor.*(sentry|gofer)'
CGPATH=$(sudo awk -F: '$1=="0" {print $3}' "/proc/$PID/cgroup")
CG="/sys/fs/cgroup$CGPATH"
for name in memory.max memory.swap.max cpu.max pids.max; do
  printf '%s: ' "$name"
  sudo cat "$CG/$name"
done
```

В опыте /health вернул HTTP 200 и ok. В логе приложения PID=1, а State.Pid на хосте относится к runsc-sandbox; также видны Gofer и процессы gvisor_sentry. Host UID sandbox не является UID приложения внутри gVisor. Файлы cgroup подтвердили 134217728, 0, 50000 100000 и 64 соответственно.

Sentry реализует интерфейсы ядра для приложения в пользовательском пространстве. Для хостовых ресурсов сами компоненты gVisor обращаются к ядру хоста. Это дополнительная граница с расходами CPU/памяти и ограничениями совместимости; полное Linux-ядро гостевой ВМ здесь не запускается.

[Мониторинг этого контейнера](../monitoring/README.md).

Источники: [установка](https://gvisor.dev/docs/user_guide/install/), [Docker Quick Start](https://gvisor.dev/docs/user_guide/quick_start/docker/), [systemd cgroup driver](https://gvisor.dev/docs/user_guide/systemd/).
