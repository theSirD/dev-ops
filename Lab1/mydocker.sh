#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PORT=8080

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

[[ $# == 0 ]] || die 'Аргументы не принимаются; запуск: sudo ./mydocker.sh'
[[ $EUID == 0 ]] || die 'Запустите через sudo от обычного пользователя.'
[[ -v SUDO_UID && -v SUDO_GID ]] || die 'Не определены SUDO_UID/SUDO_GID; используйте sudo.'
[[ $SUDO_UID =~ ^[1-9][0-9]*$ && $SUDO_GID =~ ^[0-9]+$ ]] ||
    die 'Нужен обычный вызывающий пользователь с ненулевым UID.'

for cmd in bash setpriv unshare nsenter ip hostname pgrep curl grep stat dirname sleep rmdir; do
    command -v "$cmd" >/dev/null || die "Не найдена команда: $cmd"
done

dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
[[ -x "$dir/lab1-serv" ]] || die "Нет исполняемого файла $dir/lab1-serv"
[[ -s "$dir/seccomp.bpf" ]] || die "Нет непустого профиля $dir/seccomp.bpf"
[[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || die 'Нужен cgroup v2.'
for controller in memory cpu pids; do
    grep -qw "$controller" /sys/fs/cgroup/cgroup.subtree_control ||
        die "В корне cgroup v2 не включён контроллер $controller"
done

group_name="lab1-$SUDO_UID-$$"
cg="/sys/fs/cgroup/$group_name"
created=0
worker=

cleanup() {
    local result=$? removed=0 attempt
    trap - EXIT
    trap '' INT TERM HUP
    if (( created )); then
        # Повторение закрывает гонку между входом дочернего процесса в группу и остановкой.
        for ((attempt=0; attempt<50; attempt++)); do
            if ! printf '1\n' > "$cg/cgroup.kill"; then
                printf 'Не удалось остановить cgroup: %s\n' "$cg" >&2
                exit 1
            fi
            if rmdir "$cg" 2>/dev/null; then
                removed=1
                break
            fi
            sleep 0.1
        done
        if (( ! removed )); then
            printf 'Не удалось удалить cgroup; проверьте вручную: %s\n' "$cg" >&2
            exit 1
        fi
    fi
    [[ -z "$worker" ]] || wait "$worker" 2>/dev/null || true
    exit "$result"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir "$cg"
created=1
printf '134217728\n' > "$cg/memory.max"
printf '0\n' > "$cg/memory.swap.max"
printf '50000 100000\n' > "$cg/cpu.max"
printf '64\n' > "$cg/pids.max"

start_service() {
    # Управляющий процесс снаружи, только эта дочерняя оболочка входит в cgroup.
    printf '%s\n' "$BASHPID" > "$cg/cgroup.procs"
    exec setpriv --reuid="$SUDO_UID" --regid="$SUDO_GID" --init-groups \
        unshare --user --map-root-user --pid --fork --kill-child \
        --mount --mount-proc --net --uts --ipc \
        bash -eu -c '
            hostname lab1
            ip link set lo up
            exec setpriv --bounding-set=-all --inh-caps=-all --ambient-caps=-all \
                --no-new-privs --seccomp-filter "$1/seccomp.bpf" "$1/lab1-serv"
        ' bash "$dir"
}

printf 'MANAGER_PID=%s\nCGROUP=%s\nHOST_UID=%s\n' "$$" "$cg" "$SUDO_UID"
start_service &
worker=$!

api_pid=
ready=0
deadline=$((SECONDS + 10))
while (( SECONDS < deadline )); do
    api_pid=$(pgrep -P "$worker" -x lab1-serv || true)
    if [[ $api_pid =~ ^[0-9]+$ ]] &&
        health=$(nsenter --target "$api_pid" --net \
            curl --noproxy '*' -fsS --max-time 1 http://127.0.0.1:8080/health 2>/dev/null) &&
        [[ $health == ok ]]; then
        ready=1
        break
    fi
    sleep 0.1
done
(( ready )) || die 'Сервис не ответил ok за время проверки запуска.'

# Самопроверка измеряет состояние процесса, а не только факт выполнения команд.
grep -Fxq "0::/$group_name" "/proc/$api_pid/cgroup" || die 'Сервис не в ожидаемой cgroup.'
grep -Eq '^NSpid:[[:space:]]+[0-9]+[[:space:]]+1$' "/proc/$api_pid/status" ||
    die 'Сервис не имеет PID 1 в новом namespace.'
for field in CapInh CapPrm CapEff CapBnd CapAmb; do
    grep -Eq "^$field:[[:space:]]+0+$" "/proc/$api_pid/status" ||
        die "Набор $field не пуст."
done
grep -Eq '^NoNewPrivs:[[:space:]]+1$' "/proc/$api_pid/status" || die 'Не установлен no_new_privs.'
grep -Eq '^Seccomp:[[:space:]]+2$' "/proc/$api_pid/status" || die 'Не включён seccomp filter.'
grep -Eq "^Uid:[[:space:]]+$SUDO_UID[[:space:]]+$SUDO_UID[[:space:]]+$SUDO_UID[[:space:]]+$SUDO_UID$" \
    "/proc/$api_pid/status" || die 'UID сервиса на хосте отличается от UID вызывающего пользователя.'

printf 'Самопроверка запуска: OK\nHOST_PID=%s\n' "$api_pid"
printf 'HTTP: sudo nsenter --target %s --net curl --noproxy %q -fsS http://127.0.0.1:8080/health\n' "$api_pid" '*'
printf 'Остановка: Ctrl+C или sudo kill -TERM %s\n' "$$"
# shortcut: SIGKILL управляющему процессу не запускает trap; тогда нужна ручная очистка напечатанной cgroup.
wait "$worker"
