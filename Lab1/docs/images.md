# Часть 6. Сборка и проверка образов

Статус части 6: практические проверки и проверка понимания завершены пользователем 2026-10-19; named volume lab1-images-data сохранён для защиты.

## 1. Перенести файлы

В каталоге сервера должны быть main.go, go.mod, Dockerfile.single, Dockerfile и .dockerignore. Существующий go.mod пользователя уже совпадает с подготовленным. Бинарник хоста lab1-serv не копируется в образы: оба Dockerfile компилируют исходный код сами.

~~~bash
ls -la Dockerfile Dockerfile.single .dockerignore go.mod main.go
~~~

.dockerignore исключает отчёт, скриншоты и остальные артефакты из контекста. Не заменять точный COPY на COPY всего каталога.

## 2. Проверить сборщик и получить базовый образ

~~~bash
sudo docker buildx version
sudo docker pull golang:1.24.4
sudo docker image inspect golang:1.24.4 --format '{{json .RepoDigests}}'
~~~

Сохранить версию buildx либо сообщение о его отсутствии, а также digest полученного образа. Ошибка отсутствия buildx сама по себе не требует установки: Docker 26 может использовать legacy builder. Если pull завершился ошибкой, остановиться и прислать её. Не менять тег Go молча.

## 3. Собрать оба образа

~~~bash
sudo env BUILDKIT_PROGRESS=plain docker build -f Dockerfile.single -t lab1-api:single .
sudo env BUILDKIT_PROGRESS=plain docker build -f Dockerfile -t lab1-api:multi .
~~~

BUILDKIT_PROGRESS=plain задаёт читаемый лог для BuildKit; legacy builder этот параметр окружения не использует. Использованный builder определяется по версии и выводу. Если Docker требует отсутствующий buildx вместо доступного legacy builder, прислать ошибку перед изменением способа сборки.

В single конечный образ сохраняет Go SDK, исходники и кэш компилятора. В multi компиляция та же, но конечная стадия scratch получает только /lab1-serv. CGO_ENABLED=0 исключает зависимость бинарника от libc; в scratch нет ни libc, ни shell. Одинаковые команды сборки нужны для честного сравнения состава образов.

Сохранить логи обеих сборок. Первая multi-сборка уже может переиспользовать слои single-сборки; это не ошибка и не повод очищать кэш.

## 4. Запустить single и проверить HTTP

~~~bash
sudo docker run -d --rm --name lab1-images-single \
  --memory 128m --memory-swap 128m --cpus 0.5 --pids-limit 64 \
  --cap-drop ALL --security-opt no-new-privileges=true \
  --publish 8081:8080 lab1-api:single
~~~

Перед проверкой пользователь читает логи запуска:

~~~bash
sudo docker logs lab1-images-single
curl --noproxy '*' -i --max-time 5 http://127.0.0.1:8081/health
test "$(curl --noproxy '*' -sS --max-time 5 -w '%{http_code}' http://127.0.0.1:8081/health)" = ok200 \
  && echo 'single: HTTP 200 и точное тело ok — OK'
~~~

Последняя команда проверяет вместе точное тело и HTTP-статус; при несовпадении test возвращает ненулевой код и строка OK не печатается. Если сервис ещё не успел стартовать, сначала прочитать логи; сам по себе запуск в фоне не доказывает готовность. При ошибке имени или порта не удалять чужой контейнер и не завершать неизвестный процесс.

## 5. Запустить multi и повторить проверку

~~~bash
sudo docker run -d --rm --name lab1-images-multi \
  --memory 128m --memory-swap 128m --cpus 0.5 --pids-limit 64 \
  --cap-drop ALL --security-opt no-new-privileges=true \
  --publish 8082:8080 lab1-api:multi
sudo docker logs lab1-images-multi
curl --noproxy '*' -i --max-time 5 http://127.0.0.1:8082/health
test "$(curl --noproxy '*' -sS --max-time 5 -w '%{http_code}' http://127.0.0.1:8082/health)" = ok200 \
  && echo 'multi: HTTP 200 и точное тело ok — OK'
~~~

Для scratch нельзя использовать docker exec с sh, curl или ls: этих программ в образе нет. HTTP проверяется с хоста.

## 6. Проверить метаданные

~~~bash
sudo docker image inspect lab1-api:single lab1-api:multi \
  --format '{{json .RepoTags}} User={{.Config.User}} Entrypoint={{json .Config.Entrypoint}} Ports={{json .Config.ExposedPorts}}'
~~~

Для обоих тегов ожидается User=1000:1000, Entrypoint=["/lab1-serv"] и объявленный 8080/tcp. EXPOSE описывает порт, а фактическую публикацию задают 8081:8080 и 8082:8080.

Сохранить HTTP-проверки и метаданные в screenshots/part6-health.png. Прислать логи сборок, digest сборщика, результат проверок и метаданные. Контейнеры можно остановить после снимков:

~~~bash
sudo docker stop lab1-images-single lab1-images-multi
~~~

Из-за --rm тестовые контейнеры удалятся, образы останутся для следующего опыта. Порты 8081 и 8082 во время работы опубликованы на интерфейсах сервера.

## 7. Подтвердить точное тело ответа

Оба контейнера по выводу пользователя запустились с PID 1, вернули HTTP 200 и имеют нужные метаданные. У multi в присланной копии тело ответа не отобразилось. Пока контейнеры запущены:

~~~bash
test "$(curl --noproxy '*' -sS --max-time 5 -w '%{http_code}' http://127.0.0.1:8081/health)" = ok200 \
  && echo 'single: OK'
test "$(curl --noproxy '*' -sS --max-time 5 -w '%{http_code}' http://127.0.0.1:8082/health)" = ok200 \
  && echo 'multi: OK'
~~~

Если контейнеры уже остановлены и удалены через --rm, повторить их запуск из разделов 4–5. Для команд сравнения ниже запущенные контейнеры не нужны, достаточно собранных образов.

## 8. Измерить размер и файловые слои

Из каталога lab1:

~~~bash
mkdir -p results
set -o pipefail
sudo docker image inspect lab1-api:single lab1-api:multi \
  --format '{{json .RepoTags}} Size={{.Size}} Layers={{len .RootFS.Layers}} ID={{.Id}}' \
  | tee results/images-inspect.txt
sudo docker history --no-trunc lab1-api:single | tee results/history-single.txt
sudo docker history --no-trunc lab1-api:multi | tee results/history-multi.txt
~~~

Size указан в байтах; Layers — число файловых слоёв. Строки history, меняющие только USER, EXPOSE или ENTRYPOINT, не следует считать отдельными файловыми слоями. Сравниваем фактический вывод; предполагаемые размеры не записываем.

## 9. Повторить сборки без изменения входных файлов

Не изменять main.go, go.mod и Dockerfile, не очищать кэш и не использовать --no-cache или --pull.

~~~bash
sudo env BUILDKIT_PROGRESS=plain docker build -f Dockerfile.single -t lab1-api:single . \
  2>&1 | tee results/build-single-repeat.log
sudo env BUILDKIT_PROGRESS=plain docker build -f Dockerfile -t lab1-api:multi . \
  2>&1 | tee results/build-multi-repeat.log
~~~

set -o pipefail из раздела 8 нужен, чтобы tee не скрыл ошибку docker build. Если сборка завершилась ошибкой, остановиться и прислать полный лог.

В логах найти CACHED у BuildKit либо Using cache у legacy builder, особенно на COPY исходников и RUN go build. Повторная сборка должна переиспользовать их при неизменных входах. Логи results/ исключены из контекста через .dockerignore и не мешают этому опыту.

Версия buildx и digest сборщика нужны для отчёта, если они ещё не сохранены:

~~~bash
sudo docker buildx version
sudo docker image inspect golang:1.24.4 --format '{{json .RepoDigests}}'
~~~

Если buildx отсутствует, сохранить этот факт вместе с логом сборки; не устанавливать его только ради этой проверки. В отчёте пользователя уже указан digest golang:1.24.4: sha256:20a022e5112a144aa7b7aeb3f22ebf2cdaefcc4aac0d64e8deeee8cdc18b9c0f. Повторно скачивать базовый образ для проверки кэша не нужно.

## Результаты и вопросы

Прислать вывод двух HTTP-проверок, images-inspect.txt, обе истории и логи повторных сборок. Сохранить скриншоты в screenshots/part6-images.png и screenshots/part6-cache.png.

После выполнения ответить:

1. Что осталось в обычном образе и было исключено из конечного scratch?
2. Почему бинарник с зависимостью от отсутствующего динамического загрузчика не запустился бы в scratch?
3. Если изменить main.go, сможет ли RUN go build в наших Dockerfile использовать старый результат из кэша?

К файловому эксперименту переходить после фактических результатов и правильных ответов.

## 10. Writable layer: restart и пересоздание

Текущий файловый опыт выполняется на lab1-api:single, потому что там есть shell и cat. Новые HTTP-endpoint не нужны. Порт хоста не публикуется: этот опыт не конфликтует с работающими контейнерами на 8081/8082.

Все команды выполнять в одном терминале хоста Debian. Сначала убедиться, что имя lab1-files свободно:

~~~bash
sudo docker ps -a --filter 'name=^/lab1-files

После подтверждения опыта с writable layer повторим запись и пересоздание с named volume.

Статус на 2026-10-17: оба точных HTTP-теста OK; single — 945094396 байт и 10 слоёв, multi — 8089538 байт и 1 слой. BuildKit default/docker переиспользовал COPY/RUN в обоих образах и COPY из builder у multi. Проверка понимания завершена; подготовлены команды опыта с writable layer.

Источники: [multi-stage](https://docs.docker.com/build/building/multi-stage/), [контекст сборки и dockerignore](https://docs.docker.com/build/concepts/context/), [BUILDKIT_PROGRESS](https://docs.docker.com/build/building/variables/#buildkit_progress).

~~~

Если выведен существующий контейнер, остановиться и выяснить его происхождение. Команды удаления ниже относятся только к контейнеру, созданному в этом опыте.

### 10.1. Запустить контейнер из зафиксированного образа

~~~bash
cd ~/lab1
IMAGE=$(sudo docker image inspect --format '{{.Id}}' lab1-api:single)
echo "$IMAGE"
sudo docker run -d --name lab1-files \
  --memory 128m --memory-swap 128m --cpus 0.5 --pids-limit 64 \
  --cap-drop ALL --security-opt no-new-privileges=true \
  "$IMAGE"
OLD_CONTAINER=$(sudo docker inspect --format '{{.Id}}' lab1-files)
sudo docker inspect --format 'ID={{.Id}} Image={{.Image}} Mounts={{json .Mounts}}' lab1-files
~~~

IMAGE фиксирует ID образа: новый контейнер позже создаётся из того же самого образа, даже если тег случайно изменится. Здесь намеренно нет --rm: остановка не должна автоматически удалять контейнер.

### 10.2. Записать и прочитать файл

~~~bash
sudo docker exec --user 0 lab1-files sh -eu -c \
  'printf "lab1-proof\n" > /tmp/lab1-proof.txt; cat /tmp/lab1-proof.txt'
sudo docker diff lab1-files
~~~

Ожидается строка lab1-proof, а в diff — добавленный /tmp/lab1-proof.txt и, возможно, изменение каталога /tmp. Запись через docker exec --user 0 нужна только для диагностического опыта; UID основного сервиса остаётся 1000. Файл с обычными правами чтения далее проверяется от пользователя образа.

### 10.3. Проверить обычный restart

~~~bash
sudo docker restart lab1-files
test "$(sudo docker inspect --format '{{.Id}}' lab1-files)" = "$OLD_CONTAINER" \
  && echo "Это тот же контейнер"
sudo docker exec lab1-files cat /tmp/lab1-proof.txt
~~~

Ожидается тот же ID и прежняя строка. Restart меняет состояние процессов, но сохраняет существующий writable layer.

### 10.4. Удалить и создать новый контейнер

~~~bash
sudo docker stop lab1-files
sudo docker rm lab1-files
sudo docker run -d --name lab1-files \
  --memory 128m --memory-swap 128m --cpus 0.5 --pids-limit 64 \
  --cap-drop ALL --security-opt no-new-privileges=true \
  "$IMAGE"
test "$(sudo docker inspect --format '{{.Id}}' lab1-files)" != "$OLD_CONTAINER" \
  && echo "Создан новый контейнер"
sudo docker exec lab1-files sh -ec \
  'test ! -e /tmp/lab1-proof.txt; echo "Файл отсутствует в новом контейнере"'
~~~

Ожидаются сообщения о новом контейнере и отсутствующем файле. Отсутствие подтверждается командой test внутри доступного контейнера, а не произвольной ошибкой cat или Docker.

Сохранить вывод ID, содержимого до/после restart и отсутствия после пересоздания; скриншот screenshots/part6-writable-layer.png. Новый lab1-files пока оставить для следующего опыта: перед подключением volume он будет явно остановлен и удалён.

### Вопросы после результата

1. Почему restart сохранил файл?
2. Почему новый контейнер из того же образа уже не содержит этот файл: изменился ли сам образ при записи?

Статус: команды подготовлены, файловые результаты ещё не получены. После проверки этого наблюдения выдаются команды named volume: чужие существующие тома не удаляются.

## 11. Named volume: данные после удаления контейнера

Предыдущий опыт подтвердил сохранение /tmp/lab1-proof.txt после restart и его отсутствие после удаления контейнера и создания нового. Образ при записи не изменялся. Теперь запись направляется в отдельный named volume.

### 11.1. Убедиться, что имя тома свободно

~~~bash
sudo docker volume ls --format '{{.Name}}'
~~~

Если в списке уже есть точное имя lab1-images-data, остановиться и прислать вывод; существующий том не перезаписывать и не удалять. Если имени нет:

~~~bash
sudo docker volume create lab1-images-data
~~~

### 11.2. Подключить том к тестовому контейнеру

Текущий lab1-files создан в предыдущем опыте и не содержит нужных данных. Удаляется только он:

~~~bash
sudo docker stop lab1-files
sudo docker rm lab1-files
sudo docker run -d --name lab1-files \
  --memory 128m --memory-swap 128m --cpus 0.5 --pids-limit 64 \
  --cap-drop ALL --security-opt no-new-privileges=true \
  --mount type=volume,src=lab1-images-data,dst=/lab-data \
  lab1-api:single
sudo docker inspect --format 'ID={{.Id}} Mounts={{json .Mounts}}' lab1-files
~~~

В Mounts должны быть Type=volume, Name=lab1-images-data, Destination=/lab-data и RW=true. Порт не публикуется.

### 11.3. Записать контрольные данные

~~~bash
sudo docker exec --user 0 lab1-files sh -eu -c \
  'printf "volume-proof\n" > /lab-data/lab1-proof.txt; cat /lab-data/lab1-proof.txt'
~~~

Ожидается volume-proof. Root используется только для диагностической записи в новый том, чтобы не спутать права на каталог с механизмом хранения. Сервис остаётся под UID 1000; созданный файл читается этим UID.

### 11.4. Пересоздать контейнер с тем же томом

~~~bash
sudo docker stop lab1-files
sudo docker rm lab1-files
sudo docker run -d --name lab1-files \
  --memory 128m --memory-swap 128m --cpus 0.5 --pids-limit 64 \
  --cap-drop ALL --security-opt no-new-privileges=true \
  --mount type=volume,src=lab1-images-data,dst=/lab-data \
  lab1-api:single
sudo docker inspect --format 'ID={{.Id}} Mounts={{json .Mounts}}' lab1-files
sudo docker exec lab1-files sh -ec \
  'test "$(cat /lab-data/lab1-proof.txt)" = "volume-proof"; echo "Данные сохранились после пересоздания"'
~~~

ID контейнера должен отличаться, а имя тома в Mounts остаться тем же. Ожидается сообщение о сохранении данных. Непустой файл или успешное чтение другого содержимого не заменяет проверку точной строки.

### 11.5. Удалить тестовый контейнер, сохранить том

После скриншотов:

~~~bash
sudo docker stop lab1-files
sudo docker rm lab1-files
sudo docker volume inspect lab1-images-data
~~~

Volume должен по-прежнему существовать. Не выполнять volume rm или prune: данные сохраняются для защиты. Контейнеры lab1-images-single/multi, если ещё работают, можно остановить отдельно командой из раздела 6; они запускались с --rm.

### Вопросы после результата

1. Почему удаление контейнера в этом опыте не уничтожило файл?
2. Что произойдёт, если при следующем запуске вместо lab1-images-data подключить другой, новый пустой volume?

Сохранить скриншоты записи, Mounts/ID до и после пересоздания, успешной проверки данных и существования тома после удаления контейнера в screenshots/part6-volume.png. Результат подтверждён пользователем 2026-10-19: строка volume-proof сохранилась после пересоздания; после удаления контейнера том существует. Проверка понимания завершена.

Источники: [жизненный цикл volume](https://docs.docker.com/engine/storage/volumes/#a-volumes-lifecycle), [подключение volume](https://docs.docker.com/engine/storage/volumes/#start-a-container-with-a-volume).

## Дальше по плану

Часть 6 практически завершена: данные в named volume пережили пересоздание, тестовый контейнер удалён, том сохранён. Следующая учебная часть — gVisor; её подготовка начинается с проверки runsc и зарегистрированных Docker runtimes.

Статус на 2026-10-17: оба точных HTTP-теста OK; single — 945094396 байт и 10 слоёв, multi — 8089538 байт и 1 слой. BuildKit default/docker переиспользовал COPY/RUN в обоих образах и COPY из builder у multi. Проверка понимания сборок и опыт с writable layer завершены; named volume дополнительно проверен 2026-10-19.

Источники: [multi-stage](https://docs.docker.com/build/building/multi-stage/), [контекст сборки и dockerignore](https://docs.docker.com/build/concepts/context/), [BUILDKIT_PROGRESS](https://docs.docker.com/build/building/variables/#buildkit_progress).
