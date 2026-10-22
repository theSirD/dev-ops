# Часть 5. Сравнение с docker run

## Подтверждённое окружение

По выводу пользователя: Docker Client/Engine 26.1.5+dfsg1, containerd 1.7.24, runc 1.1.15. Cgroup v2, драйвер systemd; активны AppArmor, встроенный seccomp и cgroup namespace.

Все команды выполняет пользователь на удалённом Debian. Готовый lab1-serv уже собран на этой машине. Собственный образ и Dockerfile будут подготовлены в части 6; здесь используется официальный debian:13-slim и подключённый бинарник.

## Запуск

Из каталога Lab1 на сервере:

~~~bash
sudo docker run --rm --name lab1-docker \
  --hostname lab1 \
  --user 1000:1000 \
  --memory 128m --memory-swap 128m \
  --cpus 0.5 --pids-limit 64 \
  --cap-drop ALL \
  --security-opt no-new-privileges=true \
  --publish 8081:8080 \
  --mount type=bind,src="$PWD/lab1-serv",dst=/usr/local/bin/lab1-serv,readonly \
  debian:13-slim /usr/local/bin/lab1-serv
~~~

Первый запуск может скачать образ. Если имя контейнера уже занято, не удалять неизвестный контейнер: сначала выяснить, откуда он появился.

Лимиты соответствуют mydocker.sh. В Docker memory-swap задаёт суммарный лимит RAM+swap: равенство memory и memory-swap запрещает swap. Значение 0 здесь не является способом запретить swap.

Порт 8081 публикуется на интерфейсах сервера, внутри сервис по-прежнему слушает 8080. Для скрипта публикация порта не настраивалась. Бинарник подключён только для чтения; остальная корневая файловая система предоставляется образом Debian.

Сохраняются встроенный seccomp Docker и AppArmor хоста. Это не тот профиль, который использовался в mydocker.sh: seccomp.bpf сюда не передаётся. Наличие Seccomp=2 не означает равенства правил.

USER 1000:1000 задаёт UID/GID процесса внутри контейнера; он не создаёт user namespace. В нашем скрипте root внутри отображался в UID 1000 снаружи, а здесь ожидается UID 1000 и внутри, и на хосте. Фактическое отображение проверяется через uid_map.

## Проверки во втором терминале хоста

~~~bash
curl -fsS http://127.0.0.1:8081/health
echo
PID=$(sudo docker inspect --format '{{.State.Pid}}' lab1-docker)
echo "$PID"
ps -o pid,ppid,uid,user,args -p "$PID"
grep -E '^(NSpid|Uid|CapEff|NoNewPrivs|Seccomp):' "/proc/$PID/status"
cat "/proc/$PID/uid_map"
~~~

Ожидается ok, PID 1 внутри, UID 1000, CapEff=0, NoNewPrivs=1, Seccomp=2. Политику AppArmor можно увидеть отдельно:

~~~bash
sudo cat "/proc/$PID/attr/current"
~~~

Найти cgroup, созданную Docker, и прочитать фактические лимиты:

~~~bash
CGPATH=$(sudo awk -F: '$1=="0" {print $3}' "/proc/$PID/cgroup")
CG="/sys/fs/cgroup$CGPATH"
echo "$CG"
sudo cat "$CG/memory.max" "$CG/memory.swap.max" "$CG/cpu.max" "$CG/pids.max"
~~~

Ожидаются 134217728, 0, 50000 100000, 64. Путь при драйвере systemd отличается от пути ручной группы, но механизм ограничений тот же.

Посмотреть UID, hostname и сеть изнутри образа:

~~~bash
sudo docker exec lab1-docker sh -c 'id; cat /proc/sys/kernel/hostname; cat /proc/net/dev; cat /proc/net/route'
~~~

Ожидается отдельный интерфейс помимо loopback и маршрут в bridge-сети Docker. Сохранить фактический вывод: конкретные адреса и имена не выдумывать.

## Завершение

После снимков экрана:

~~~bash
sudo docker stop lab1-docker
sudo docker ps -a --filter 'name=^/lab1-docker$'
~~~

Из-за --rm контейнер должен исчезнуть из списка. Скачанный образ и бинарник хоста остаются. Не удалять другие контейнеры и образы.

## Что сравнить в отчёте после проверки

- Совпавшие значения cgroup и статус процесса как PID 1.
- Различие UID внутри и отображения user namespace.
- Сеть только с loopback у скрипта и bridge/публикация порта у Docker.
- Хостовая корневая файловая система у скрипта и rootfs из образа с отдельным writable layer у Docker.
- Наш демонстрационный запрет getppid и встроенный seccomp Docker; AppArmor в Docker.
- Управление образами, жизненным циклом, сетью и логами через CLI/daemon/runtime вместо нашего ограниченного запуска.

## Вопросы после выполнения

1. Почему HTTP теперь доступен через порт хоста без nsenter, хотя network namespace остаётся отдельным?
2. Почему --user 1000:1000 не равнозначен нашему --user --map-root-user у unshare?

Статус: пользователь подтвердил HTTP-ответ ok, PID 1, UID 1000, отсутствие effective capabilities, no_new_privs, seccomp, совпадение четырёх лимитов cgroup и удаление контейнера после docker stop с --rm (2026-10-16). Результаты сравнения внесены в Lab1.md.

Источники: [лимиты ресурсов](https://docs.docker.com/engine/containers/resource_constraints/), [seccomp](https://docs.docker.com/engine/security/seccomp/), [публикация портов](https://docs.docker.com/engine/network/port-publishing/), [официальный образ Debian](https://hub.docker.com/_/debian).
