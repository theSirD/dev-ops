# Установка основы мониторинга через Helm

## Назначение

Текущий этап: Prometheus, Grafana, Alertmanager и оператор в существующем kind lab1-monitoring. Release lab1, namespace monitoring, chart kube-prometheus-stack 92.10.1. Пользователь выполняет команды на удалённом Debian. Файл values.yaml подготовлен ассистентом, установка им не запускалась.

Kubernetes/Helm здесь — подготовка; по просьбе пользователя не проводить проверку знаний второй лабораторной. Узел kind является Docker-контейнером с ядром хоста. Kubeconfig содержит адрес API, настройки доверия и учётные данные, его не включать в Git.

## Настройки и границы этапа

- Скопировать values.yaml в ~/lab1/monitoring/values.yaml на сервере.
- Prometheus: одна реплика, scrape/evaluation 15s, хранение 6h, retentionSize 512MB, PVC 1Gi.
- Grafana: PVC 256Mi, случайный пароль создаёт chart в Secret.
- Alertmanager: PVC 128Mi; отправка уведомлений пока не настроена.
- Используется default StorageClass kind. Локальные тома переживают перезапуск пода, но не удаление kind-кластера. Размер PVC local-path не является гарантированной файловой квотой. retentionSize также не ограничивает весь расход Prometheus (в том числе WAL); перед следующими этапами проверять диск.
- Control-plane scrape для etcd/controller-manager/scheduler/proxy отключён: endpoints не подготовлены для сбора. Стандартные alert rules отключены; три метрики и обоснование пользователь выберет после наблюдения сервиса.
- Доступ только через ClusterIP и port-forward/SSH. cAdvisor хоста и scrape lab1-gvisor пока не настроены. Встроенные targets относятся к Kubernetes, это ещё не графики лабораторного контейнера.
- Экспорт дашборда в JSON и скриншоты будут храниться в Lab1/, чтобы результат защиты не зависел от сохранности кластера.

## Установка на сервере

Выполнить из ~/lab1; при ошибке остановиться и прислать её, не удалять release/кластер/PVC.

~~~bash
cd ~/lab1
export KUBECONFIG="$HOME/.kube/lab1-monitoring"
test -f monitoring/values.yaml
kubectl get nodes
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
~~~

Убедиться, что test завершился успешно и узел Ready. Затем:

~~~bash
helm upgrade --install lab1 prometheus-community/kube-prometheus-stack \
  --version 92.10.1 \
  --namespace monitoring --create-namespace \
  --values monitoring/values.yaml \
  --wait --timeout 10m
~~~

Проверки:

~~~bash
helm list -n monitoring
kubectl get pods,pvc,svc -n monitoring
df -h /var/lib/docker
~~~

Ожидаются статус Helm deployed, рабочие поды, PVC Bound. Hook jobs могут быть Completed. При таймауте дополнительно:

~~~bash
kubectl get events -n monitoring --sort-by=.lastTimestamp
~~~

Сохранить версии/статусы и свободный диск в отчёт. Пароли и Secret не присылать.

## Открытие Grafana

После подтверждения работающих подов, в отдельном SSH-терминале на сервере:

~~~bash
export KUBECONFIG="$HOME/.kube/lab1-monitoring"
kubectl -n monitoring port-forward --address 127.0.0.1 svc/lab1-grafana 3000:80
~~~

Оставить работающим. На своём Windows-компьютере в PowerShell открыть другой терминал:

~~~powershell
ssh -N -L 3000:127.0.0.1:3000 eruano@192.168.2.156
~~~

IP приведён по ранее указанному адресу сервера; если он изменился, использовать актуальный SSH-адрес. Оставить туннель работающим, открыть на компьютере http://127.0.0.1:3000. Если локальный 3000 занят, поменять первый 3000 в команде ssh и адресе браузера, например на 13000.

Получить пароль только для собственного входа, в ещё одной SSH-сессии сервера:

~~~bash
export KUBECONFIG="$HOME/.kube/lab1-monitoring"
kubectl -n monitoring get secret lab1-grafana \
  -o jsonpath='{.data.admin-password}' | base64 --decode
printf '\n'
~~~

Логин admin. Пароль не включать в скриншоты и отчёт. Проверить, что Grafana открывается и источник Prometheus provisioned. Доступность реальных targets проверим отдельно.

## Следующий этап

После вывода проверки установки — cAdvisor хоста и подключение его /metrics к Prometheus. Только после подтверждения метрик lab1-gvisor — графики, управляемая нагрузка и три метрики под алерты. Логи/трейсы из второй лабораторной на данном этапе не разворачиваем.

Источник: [chart 92.10.1](https://github.com/prometheus-community/helm-charts/tree/kube-prometheus-stack-92.10.1/charts/kube-prometheus-stack).

Статус: установка Helm-релиза подтверждена пользователем. Пользователь подтвердил вход в Grafana через браузер. Подключение внешнего контейнера ещё предстоит.

## Подтверждённый результат установки

Пользователь установил release lab1 в namespace monitoring 2026-10-20 14:16:17 +0300: revision 1, status deployed, chart kube-prometheus-stack-92.10.1, app version v0.94.1 (версия оператора, не версия каждого компонента). Все шесть подов Running и готовы, перезапусков 0: Alertmanager 2/2, Grafana 3/3, kube-state-metrics 1/1, operator 1/1, node-exporter 1/1, Prometheus 2/2. PVC Alertmanager 128Mi, Grafana 256Mi и Prometheus 1Gi — Bound, StorageClass standard. Сервисы lab1-grafana:80 и lab1-monitoring-prometheus:9090 доступны как ClusterIP. На /var свободно 5,4 GiB, занято 51%.

Первый запуск до переноса values.yaml остановился с ошибкой отсутствия файла, ресурсов не создал. После переноса установка успешна. Случайная вставка приглашения shell и строк вывода вызвала ошибки команды не найдены; итоговая проверка подтвердила работающий релиз. Пользователь затем подтвердил успешный вход в Grafana. Scrape внешнего lab1-gvisor пока не подтверждён.

## Текущий следующий шаг

[Запуск cAdvisor на хосте и проверка метрик конкретного контейнера](cadvisor.md). Prometheus scrape на внешний источник ещё не настроен.
