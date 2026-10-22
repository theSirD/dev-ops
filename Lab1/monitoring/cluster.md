# Часть 8: учебный кластер для мониторинга

## Подтверждённое окружение

Debian 13 amd64, Docker 26.1.5, cgroup v2/systemd, DefaultRuntime=runc. Пользователь сообщил: nproc=16; память 15 GiB, available 14 GiB; на / свободно 27 GiB, на /var (включая /var/lib/docker) — 9,4 GiB. lab1-gvisor работает. curl и tar доступны; kind, kubectl, helm отсутствуют.

## Текущий этап

Установить CLI и создать один узел kind. Метрики и Helm-релизы устанавливаются следующим этапом, после проверки готовности и свободного диска. Версии зафиксированы: kind v0.33.0, Kubernetes/kubectl v1.35.8, Helm v4.3.1. Образ узла взят из списка поддерживаемых образов релиза kind v0.33.0. Все команды выполняет пользователь на сервере; ассистент их не запускал.

Запускать блоки последовательно. При ошибке не продолжать, прислать полный вывод. Контрольная сумма должна дать OK перед установкой бинарника.

## 1. Каталог загрузок и kind

~~~bash
mkdir -p ~/lab1/tools
cd ~/lab1/tools
curl -fL https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64 -o kind &&
curl -fL https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64.sha256sum -o kind.sha256sum &&
printf '%s  kind\n' "$(awk '{print $1}' kind.sha256sum)" | sha256sum --check &&
sudo install -m 0755 kind /usr/local/bin/kind
~~~

## 2. kubectl той же версии, что Kubernetes

~~~bash
cd ~/lab1/tools
curl -fL https://dl.k8s.io/release/v1.35.8/bin/linux/amd64/kubectl -o kubectl &&
curl -fL https://dl.k8s.io/release/v1.35.8/bin/linux/amd64/kubectl.sha256 -o kubectl.sha256 &&
printf '%s  kubectl\n' "$(cat kubectl.sha256)" | sha256sum --check &&
sudo install -m 0755 kubectl /usr/local/bin/kubectl
~~~

## 3. Helm

SHA256 ниже опубликован в официальном релизе Helm v4.3.1 для Linux amd64.

~~~bash
cd ~/lab1/tools
curl -fL https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz -o helm-v4.3.1-linux-amd64.tar.gz &&
printf '%s\n' '0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b  helm-v4.3.1-linux-amd64.tar.gz' | sha256sum --check &&
tar -xzf helm-v4.3.1-linux-amd64.tar.gz &&
sudo install -m 0755 linux-amd64/helm /usr/local/bin/helm

kind version
kubectl version --client
helm version --short
~~~

## 4. Создание одного узла

Docker сейчас используется через sudo. Поэтому kind создаёт узел через sudo, а kubeconfig явно записывается в отдельный файл домашнего каталога пользователя. Существующий ~/.kube/config не меняется. Если ~/.kube/lab1-monitoring уже есть, не перезаписывать: прислать информацию об этом. Kubeconfig содержит учётные данные и не включается в Git/отчёт.

~~~bash
mkdir -p "$HOME/.kube"
cd ~/lab1
sudo env KIND_EXPERIMENTAL_PROVIDER=docker kind create cluster \
  --name lab1-monitoring \
  --image kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0 \
  --kubeconfig "$HOME/.kube/lab1-monitoring" \
  --wait 5m
~~~

Только после успешного создания:

~~~bash
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/lab1-monitoring" &&
chmod 0600 "$HOME/.kube/lab1-monitoring"
export KUBECONFIG="$HOME/.kube/lab1-monitoring"
kubectl get nodes -o wide
kubectl get pods -A
sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
df -h /var/lib/docker
~~~

В новом терминале повторять export KUBECONFIG, прежде чем обращаться к этому кластеру. Kubernetes API остаётся на loopback сервера; команды kubectl выполнять на сервере. Для браузерного доступа к Grafana позже подготовить SSH-туннель.

Ожидается один узел lab1-monitoring-control-plane в Ready и системные поды Running (возможны краткие переходные состояния). Сохранить вывод версий, узлов/подов и свободного диска. Если создание не удалось, кластер не удалять автоматически: сохранить ошибку для диагностики.

## Проверка понимания после готовности

1. Чем узел kind является с точки зрения Docker хоста и какое ядро он использует?
2. Какую роль выполняет kubeconfig и почему его нельзя включать в репозиторий?

## Дальнейший порядок

После проверки: Helm-релиз мониторинга с небольшим хранением метрик; затем cAdvisor для внешнего Docker-контейнера, проверка scrape, дашборд, нагрузка и обоснование трёх метрик. cAdvisor узла kind сам по себе не считается доказательством наблюдения lab1-gvisor на хосте: доступ к host cgroup/метрикам нужно настроить явно. Логи, трейсы и полная реализация второй лабы не входят в текущий этап.

## Источники

- [kind v0.33.0, совместимые образы](https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0)
- [Установка kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
- [Helm v4.3.1 и контрольные суммы](https://github.com/helm/helm/releases/tag/v4.3.1)

Статус: установка CLI и готовность кластера подтверждены выводом пользователя. Мониторинг ещё не установлен.

## Подтверждённый результат создания кластера

Пользователь выполнил установку и создание на удалённом сервере. Версии: kind v0.33.0 (go1.26.7 linux/amd64), kubectl v1.35.8 (Kustomize v5.7.1), Helm v4.3.1+gc0d08d0. Кластер lab1-monitoring создан успешно, Ready after 15s. Узел lab1-monitoring-control-plane: Ready, Kubernetes v1.35.8, IP 172.18.0.2, Debian 13, ядро 6.12.111+deb13-amd64, containerd 2.3.4. Все девять системных подов Running, по 0 перезапусков в предоставленном замере. На /var свободно 7,5 GiB (32% занято). Kubeconfig используется из /home/eruano/.kube/lab1-monitoring, содержимое не запрашивалось и в репозиторий не добавлялось.

Helm-релизы мониторинга ещё не установлены. Следующий этап — после ответов на вопросы об устройстве узла kind и назначении kubeconfig. Остаток диска учитывать при настройке хранения метрик.
