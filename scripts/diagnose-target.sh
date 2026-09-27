#!/usr/bin/env bash
# Диагностика целевой системы: почему pacman -Sy падает в chroot.
#
# Вторая версия. Первая перехватывала вывод pacman командной подстановкой и
# печатала его только после завершения, поэтому на экране была пустота и
# непонятно было: идёт загрузка или всё зависло. Теперь вывод потоковый,
# с таймаутом и в режиме verbose, где видно, на каком зеркале остановилось.
#
#   sudo bash diagnose-target.sh
#
# Ничего не устанавливает и не меняет. В конце снимает монтирования.

set -uo pipefail

SQUASH=/usr/share/archlive/base-rootfs.squashfs
T=/tmp/nyx-target
LOG=/tmp/nyx-pacman.log
LIMIT="${LIMIT:-150}"        # секунд на одну попытку pacman -Sy

say()  { printf '\n=== %s ===\n' "$*"; }
note() { printf '  %s\n' "$*"; }

if [[ ! -f "$SQUASH" ]]; then
    echo "✗ нет $SQUASH — скрипт запускается из live-сессии образа Nyx"
    exit 1
fi

cleanup() {
    for m in run dev sys proc; do
        mountpoint -q "$T/$m" 2>/dev/null && umount -R "$T/$m" 2>/dev/null
    done
    rm -rf "$T" 2>/dev/null
}
trap cleanup EXIT

say "0. исходник"
note "$(stat -c %s "$SQUASH") байт"

say "1. распаковываю целевую систему"
rm -rf "$T"
unsquashfs -d "$T" "$SQUASH" >/dev/null 2>&1 || { echo "  ✗ не распаковалось"; exit 1; }
note "файлов: $(find "$T" -mindepth 1 | wc -l)"

say "2. собираю chroot"
mkdir -p "$T/proc" "$T/sys" "$T/dev" "$T/run"
mount -t proc     proc     "$T/proc" 2>/dev/null || true
mount -t sysfs    sysfs    "$T/sys"   2>/dev/null || true
mount --rbind /dev "$T/dev"           2>/dev/null || true
mount -t tmpfs    tmpfs    "$T/run"   2>/dev/null || true
for m in proc sys dev run; do
    if mountpoint -q "$T/$m"; then note "$m: смонтирован"; else note "$m: НЕ смонтирован"; fi
done

IN() { chroot "$T" /bin/bash -c "$1"; }

# Запускает pacman с потоковым выводом в файл и таймаутом, затем печатает хвост.
# Пока идёт — в фоне каждые пять секунд дописывается размер, чтобы было видно,
# что процесс жив и не стоит.
run_pacman() {
    local label="$1" conf="$2" secs="$3"
    local db=/tmp/dbx; rm -rf "$db"; mkdir -p "$db"
    : > "$LOG"
    note "--- $label (таймаут ${secs}s) ---"
    ( chroot "$T" /bin/bash -c "
          out=\$(timeout $secs pacman --config $conf --dbpath $db --logfile /dev/null \
                  -Sy --verbose 2>&1); rc=\$?
          echo \"__RC__\$rc\"
      " >"$LOG" 2>&1 ) &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        waited=$((waited + 5))
        printf '    [%3ds] %s строк, последняя: %s\n' \
            "$waited" "$(wc -l < "$LOG")" \
            "$(tail -1 "$LOG" 2>/dev/null | cut -c1-70)"
        if (( waited >= secs + 15 )); then
            note "✗ не дождались, снимаю процесс"
            pkill -P "$pid" 2>/dev/null
            kill "$pid" 2>/dev/null
            break
        fi
    done
    wait "$pid" 2>/dev/null
    rm -rf "$db"
    say "вывод: $label"
    if [[ -s "$LOG" ]]; then
        tail -25 "$LOG" | sed 's/^/  /'
    else
        note "(пусто — pacman не printed ни строки)"
    fi
    rm -f "$LOG"
}

say "3. разрешение имён и сеть"
IN 'for h in geo.mirror.pkgbuild.com mirror.cachyos.org; do
        printf "  %-30s " "$h"
        getent hosts "$h" >/dev/null 2>&1 && echo ОК || echo НЕ_РАЗРЕШАЕТСЯ
    done
    ip -brief addr 2>/dev/null | awk "{print \"  \" \$1, \$3}" | head -3'

say "4. сколько зеркал в списке целевой системы"
n=$(IN 'grep -c "^Server" /etc/pacman.d/mirrorlist' 2>/dev/null | tr -d ' \r')
note "активных серверов: ${n:-?}"
IN 'grep "^Server" /etc/pacman.d/mirrorlist | head -5 | sed "s/^/    /"'

say "5. ГЛАВНОЕ: pacman -Sy на полном списке зеркал, потоковый вывод"
# Именно этот запуск повторяет то, что делает установщик. Если он висит, значит
# зависает на зеркале, и это уже половина ответа.
run_pacman "425 зеркал, как в образе" /etc/pacman.conf "$LIMIT"

say "6. ТО ЖЕ, но на трёх зеркалах"
# Если на коротком списке pacman отрабатывает сразу, дело в количестве зеркал,
# а не в сети. Берём именно первые три рабочих строки, а не первые строки
# файла: там комментарии, и в список могли попасть не серверы.
grep '^Server' "$T/etc/pacman.d/mirrorlist" | head -3 > "$T/etc/pacman.d/mirrorlist.three"
printf '  короткий список (%s серверов):\n' "$(grep -c '^Server' "$T/etc/pacman.d/mirrorlist.three")"
sed 's/^/    /' "$T/etc/pacman.d/mirrorlist.three"
printf '[core]\nInclude = /etc/pacman.d/mirrorlist.three\n' > "$T/etc/pacman.conf.three"
run_pacman "3 зеркала" /etc/pacman.conf.three 60

say "7. РАЗДЕЛЕНИЕ ПО РЕПОЗИТОРИЯМ — какой именно падает"
mkdir -p /tmp/nyx-dbshared
for repo in core extra cachyos nyx; do
    printf '  %-9s ' "$repo"
    chroot "$T" /bin/bash -c "
        printf '[%s]\n' '$repo' > /tmp/only.conf
        case '$repo' in
            core|extra) printf 'Include = /etc/pacman.d/mirrorlist.three\n' >> /tmp/only.conf ;;
            cachyos)    printf 'SigLevel = Optional TrustAll\nServer = https://mirror.cachyos.org/repo/\$arch/cachyos\n' >> /tmp/only.conf ;;
            nyx)        printf 'SigLevel = Optional TrustAll\nServer = file:///var/cache/nyx-repo\n' >> /tmp/only.conf ;;
        esac
        out=\$(timeout 60 pacman --config /tmp/only.conf --dbpath /tmp/dbshared --logfile /dev/null -Sy 2>&1)
        rc=\$?
        if [ \"\$rc\" -eq 0 ]; then echo 'ОК'
        elif [ \"\$rc\" -eq 124 ]; then echo 'ЗАВИС (таймаут 60s)'
        else echo \"КОД \$rc\"; echo \"\$out\" | tail -3 | sed 's/^/              /'; fi
    " 2>/dev/null
    rm -rf /tmp/nyx-dbshared; mkdir -p /tmp/nyx-dbshared
done

say "8. ИТОГ"
echo "  Нужен весь вывод, особенно раздел 5 и 7."
echo "  Если в разделе 5 стоит ЗАВИС, а в разделе 7 всё ОК — причина в списке"
echo "  зеркал целевой системы, и лечится он коротким списком, а не сетью."
