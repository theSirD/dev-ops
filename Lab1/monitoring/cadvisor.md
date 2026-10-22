# cAdvisor хоста: источник метрик lab1-gvisor

## Текущий этап

Grafana открыта пользователем через port-forward и SSH-туннель. Далее запустить cAdvisor на Debian-хосте, проверить наличие метрик cgroup lab1-gvisor и только после этого подключить Prometheus. cAdvisor из kubelet узла kind не заменяет этот источник: lab1-gvisor работает во внешнем Docker хоста.

Используется официальный ghcr.io/google/cadvisor:0.60.6. cAdvisor присоединяется к Docker-сети kind для будущего доступа из Kubernetes, а порт хоста 8084 опубликован только на 127.0.0.1. Адрес в сети kind получаем из inspect и не угадываем. Будущий scrape будет настроен по фактическому адресу, он может измениться при пересоздании контейнера.

## Запуск пользователем на удалённом Debian

~~~bash
cd ~/lab1
sudo docker run -d --name lab1-cadvisor \
  --runtime=runc --privileged --cgroupns=host \
  --network kind \
  --publish 127.0.0.1:8084:8080 \
  --volume /:/rootfs:ro \
  --volume /var/run:/var/run:ro \
  --volume /sys:/sys:ro \
  --volume /var/lib/docker:/var/lib/docker:ro \
  ghcr.io/google/cadvisor:0.60.6 \
  --housekeeping_interval=5s \
  --allow_dynamic_housekeeping=false \
  --store_container_labels=false \
  --enable_metrics=cpu,memory
~~~

--privileged, host cgroup namespace и монтирования нужны агенту для наблюдения cgroups и метаданных Docker хоста. Это полномочия агента мониторинга; ограничения сервиса lab1-gvisor не меняются. Read-only mount Docker socket не превращает Docker API в API только для чтения. Использовать здесь как доверенный учебный агент. Дисковые/сетевые/прочие группы метрик не включаются: текущая цель — память, CPU и throttling. ОOM event exporter на этом шаге не включён.

При ошибке не создавать повторно одноимённый контейнер; прислать полный текст. После запуска дать агенту около 20 секунд на обнаружение контейнеров, затем:

~~~bash
sudo docker ps -a --filter 'name=^/lab1-cadvisor$'
sudo docker logs --tail 50 lab1-cadvisor
sudo docker inspect --format 'Status={{.State.Status}} IP={{(index .NetworkSettings.Networks "kind").IPAddress}}' lab1-cadvisor
~~~

## Проверка конкретного контейнера

~~~bash
cd ~/lab1
mkdir -p results
curl --noproxy '*' -fsS --max-time 15 \
  http://127.0.0.1:8084/metrics -o results/cadvisor-metrics.prom
~~~

Если curl завершился успешно:

~~~bash
CID=$(sudo docker inspect --format '{{.Id}}' lab1-gvisor)
grep -E '^container_(memory_usage_bytes|spec_memory_limit_bytes|cpu_usage_seconds_total|cpu_cfs_(periods|throttled_periods|throttled_seconds)_total)' \
  results/cadvisor-metrics.prom | grep -F "$CID"
~~~

Ожидаются серии с полным ID lab1-gvisor в id и, при распознавании Docker, name=lab1-gvisor: память, лимит 134217728 байт, накопленное CPU-время и CFS throttling. Значение памяти может отличаться от исходного замера: это новый момент времени. Если строки отсутствуют или видна только часть метрик, прислать вывод и логи: не считать scrape настроенным только по успешному HTTP-запросу.

~~~bash
sudo docker image inspect ghcr.io/google/cadvisor:0.60.6 --format '{{json .RepoDigests}}'
df -h /var/lib/docker
~~~

Сохранить вывод запуска, адрес в сети kind, выбранные серии, digest образа и свободный диск. Метрики относятся к cgroup sandbox с накладными расходами gVisor, а не только к heap HTTP-приложения. Сырые счётчики CPU/CFS впоследствии преобразуются в скорости/доли по интервалу.

## Следующий этап

По подтверждённому IP cAdvisor настроить scrape Prometheus через Helm values, проверить up и наличие серий lab1-gvisor в Prometheus/Grafana. На текущем шаге Helm values не меняются. Установка источника и проверка сбора объединяются в один учебный этап; вопросы по роли накопительных счётчиков и источника — после успешного scrape, без проверки Kubernetes/Helm.

Источники: [официальный запуск cAdvisor](https://github.com/google/cadvisor/tree/v0.60.6#quick-start-running-cadvisor-in-a-docker-container), [runtime options](https://github.com/google/cadvisor/blob/v0.60.6/docs/runtime_options.md), [release](https://github.com/google/cadvisor/releases/tag/v0.60.6).

Статус: команды подготовлены, cAdvisor и метрики lab1-gvisor ещё не проверены пользователем.

## Подтверждённый запуск cAdvisor

Пользователь запустил cAdvisor v0.60.6, revision 5bf5d43. Образ digest `sha256:b8e7d1093144fd088f425ff003d75a4aa405de075db78dae3bc563730b1bd07a`; контейнер `82ba578bf05ebedb8263f10765f847edb2d47ac18e986c69021f9be74fdb8ec8`, Status=running, IP в сети kind `172.18.0.3`. Docker factory зарегистрирована; отсутствие сокетов CRI-O/Podman не препятствует этому источнику. /metrics успешно сохранён пользователем. Для name=lab1-gvisor, image=lab1-api:multi и полного ID c7031988... подтверждены: memory_usage_bytes=25235456, spec_memory_limit_bytes=134217728, cpu_usage_seconds_total=10.668821, cpu_cfs_periods_total=9129, cpu_cfs_throttled_periods_total=1, cpu_cfs_throttled_seconds_total=0.156957. Это накопительные счётчики нового замера; никакой скорости по одному значению не вычисляли.

## Подключение к Prometheus

values.yaml обновлён: prometheus.prometheusSpec.additionalScrapeConfigs добавляет job lab1-host-cadvisor, target 172.18.0.3:8080, интервал 15s. metric_relabel_configs сохраняет только серии name=lab1-gvisor; автоматически формируемый up остаётся доступным. Не использовать localhost:8084 как target внутри пода Prometheus: localhost там обозначает сам под.

Перенести актуальный values.yaml с Windows на сервер:

~~~powershell
scp "D:\Programming\DevOps\Lab1\monitoring\values.yaml" eruano@192.168.2.156:~/lab1/monitoring/values.yaml
~~~

На сервере:

~~~bash
cd ~/lab1
export KUBECONFIG="$HOME/.kube/lab1-monitoring"
helm upgrade --install lab1 prometheus-community/kube-prometheus-stack \
  --version 92.10.1 \
  --namespace monitoring \
  --values monitoring/values.yaml \
  --wait --timeout 10m
kubectl get pods -n monitoring
~~~

После успешного обновления подождать около минуты. В Grafana открыть Explore, выбрать источник Prometheus, режим Code, выполнить отдельно:

~~~promql
up{job="lab1-host-cadvisor"}
~~~

Ожидается 1 (успешен scrape endpoint). Затем:

~~~promql
container_memory_usage_bytes{job="lab1-host-cadvisor",name="lab1-gvisor"}
~~~

Ожидается фактическое потребление в байтах. Наконец:

~~~promql
rate(container_cpu_usage_seconds_total{job="lab1-host-cadvisor",name="lab1-gvisor"}[1m])
~~~

Результат — среднее потребление в ядрах; до накопления хотя бы двух точек ряд может быть пустым. Небольшой CPU без нагрузки ожидаем, но численное значение заранее не задано. Если Grafana после Helm upgrade потеряла port-forward из-за пересоздания пода, повторно запустить прежний port-forward, SSH-туннель оставить.

Прислать результат Helm upgrade и запросов; сохранить скриншот Explore без пароля. up=0 означает ошибку scrape, пустой up — отсутствие выбранного job/серии либо проблему выбора источника/интервала; не менять запросы дашборда наугад.

Источник настройки: [additionalScrapeConfigs chart](https://github.com/prometheus-community/helm-charts/blob/kube-prometheus-stack-92.10.1/charts/kube-prometheus-stack/values.yaml), [Prometheus configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/).

Актуальный статус: cAdvisor и метрики контейнера подтверждены; конфигурация scrape подготовлена, применение Helm и данные в Prometheus/Grafana ещё не подтверждены.

Пользователь сообщил: Grafana вновь работает после повторного port-forward, три предложенных графика добавлены. Численные значения запросов и снимки пока не представлены. Дальше — [дашборд памяти/CPU/throttling и опыт под нагрузкой](experiment.md). Причина предыдущего обрыва port-forward без диагностических логов остаётся неподтверждённой.
