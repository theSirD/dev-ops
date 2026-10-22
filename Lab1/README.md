# Лаба 1 — свой Docker

Подопытный сервис написан на Go. На нём проверил namespaces, лимиты cgroup v2, capabilities и seccomp, собрал свой запуск в `mydocker.sh` и сравнил его с Docker и gVisor.

Подробный отчёт с результатами и скриншотами — [Lab1.md](Lab1.md).

## Что где лежит

```text
Lab1/
├── Lab1.md                  # отчёт
├── main.go, go.mod          # HTTP-сервис
├── Dockerfile               # multi-stage, финальный образ scratch
├── Dockerfile.single        # обычная сборка для сравнения
├── mydocker.sh              # запуск с namespaces, cgroup и урезанными правами
├── api/openapi.yaml         # HTTP-контракт
├── docs/                    # команды и пояснения к опытам
│   └── contracts/           # контракты запуска и образов
├── monitoring/              # Helm values и инструкции мониторинга
└── screenshots/part-1…8/    # скриншоты по частям отчёта
```

Исходники, Dockerfile и скрипт оставлены в одном каталоге: контекст сборки и пути запуска не менялись. Все команды ниже выполняются на удалённом Debian из каталога `Lab1` (в проведённых опытах — `~/lab1`).

## Сервис и свой запуск

Сервис отдаёт `/health`, удерживает память через `/eat?mb=N` и включает CPU-нагрузку через `/burn`. [HTTP-контракт](api/openapi.yaml).

Подготовить бинарник и учебный seccomp-профиль на Debian:

```bash
go build -o lab1-serv .
enosys --syscall getppid:EPERM --dump=seccomp.bpf
```

`mydocker.sh` ожидает эти два файла рядом с собой. Для запуска нужны cgroup v2 с контроллерами `memory`, `cpu`, `pids`, `sudo`, `unshare`, `setpriv` с поддержкой seccomp и сетевые утилиты. Проверенное окружение описано в отчёте.

```bash
chmod +x mydocker.sh
bash -n mydocker.sh
sudo ./mydocker.sh
```

Скрипт выводит готовую команду проверки через `nsenter`. Остановка — Ctrl+C. [Контракт и проверки запуска](docs/contracts/mydocker.md).

## Команды опытов

- [Namespaces](docs/namespaces.md).
- [Сравнение своего запуска с Docker](docs/docker-comparison.md).
- [Сборка образов, кэш, writable layer и volumes](docs/images.md).
- [Запуск через gVisor](docs/gvisor.md).
- [Подготовка kind](monitoring/cluster.md).
- [Prometheus, Grafana и Alertmanager через Helm](monitoring/README.md).
- [cAdvisor хоста и подключение к Prometheus](monitoring/cadvisor.md).
- [Панели и опыт с нагрузкой](monitoring/experiment.md).

## Что получилось

- Namespaces изменяют видимость ресурсов, cgroups ограничивают их потребление, capabilities и seccomp ограничивают действия процесса.
- `mydocker.sh` объединяет эти механизмы. Docker дополнительно предоставляет rootfs из образа, сеть, публикацию портов и управление контейнером.
- Single-stage образ — 945094396 байт и 10 файловых слоёв; multi-stage — 8089538 байт и 1 слой. Повторная сборка использует кэш.
- Файл в writable layer переживает `restart`, но исчезает после удаления контейнера. Файл в named volume пережил пересоздание контейнера.
- gVisor добавляет обработку системных вызовов через Sentry. Ядро хоста остаётся необходимым, но приложение отделено от него дополнительной границей.
- На дашборде видны рост памяти, CPU около 0,5 ядра и throttling почти в каждом периоде под нагрузкой.

Пока не приложен экспорт JSON дашборда и не оформлено обоснование трёх метрик под алерты. Бинарник и `seccomp.bpf` создаются на Debian приведёнными выше командами; в репозитории их нет. Численные результаты и ограничения проверок — в отчёте.
