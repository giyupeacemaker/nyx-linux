#!/usr/bin/env bash
# Диагностика целевой системы: почему pacman -Sy падает в chroot.
#
# Запускается в live-сессии образа Nyx. Распаковывает base-rootfs.squashfs,
# который уже лежит в live-окружении, собирает вокруг него настоящий chroot с
# /proc, /sys, /dev и /run, и выполняет pacman -Sy внутри, печатая stderr.
# Ничего не устанавливает и не меняет.
#
#   sudo bash diagnose-target.sh
#
# Вывод потоковый, с таймаутом: прошлый вариант перехватывал вывод подстановкой
# и печатал его только после возврата команды, из-за чего на экране была
# пустота и нельзя было отличить работу от зависания.

set -uo pipefail

SQUASH=/usr/share/archlive/base-rootfs.squashfs
T=/tmp/nyx-target
LOG=/tmp/nyx-pacman.log
LIMIT="${LIMIT:-150}"

say()  { printf '\n=== %s ===\n' "$*"; }
note() { printf '  %s\n' "$*"; }

if [[ ! -f "$SQUASH" ]]; then
    echo "x нет $SQUASH: скрипт запускается из live-сессии образа Nyx"
    exit 1
fi

cleanup() {
    # -l -f: снимать приходится рекурсивно и силой. Прерванный прогон оставляет
    # примонтированный /dev, и обычный rm через него не проходит.
    for m in run dev sys proc; do
        mountpoint -q "$T/$m" 2>/dev/null && umount -Rlf "$T/$m" 2>/dev/null
    done
    rm -rf "$T" 2>/dev/null
}
trap cleanup EXIT INT TERM

say "0. исходник"
note "$(stat -c %s "$SQUASH") байт"

say "1. убираю остатки прошлого прогона"
# Каталог /tmp/nyx-target/dev после прерывания остаётся точкой монтирования,
# и rm -rf на нём падает с "Operation not permitted". Это стоило одного
# перезапуска, поэтому снимаем остатки до распаковки, а не после.
if [[ -d "$T" ]] || mountpoint -q "$T/dev" 2>/dev/null; then
    note "найдены остатки, снимаю"
    cleanup
fi
if mountpoint -q "$T/dev" 2>/dev/null; then
    echo "  x /dev все еще смонтирован. Выполните вручную:"
    echo "      sudo umount -Rlf /tmp/nyx-target/dev"
    exit 1
fi
note "чисто"

say "2. распаковываю целевую систему"
rm -rf "$T"
if ! unsquashfs -d "$T" "$SQUASH" >/dev/null 2>&1; then
    echo "  x не распаковалось"
    exit 1
fi
note "файлов: $(find "$T" -mindepth 1 | wc -l)"

say "3. собираю chroot"
mkdir -p "$T/proc" "$T/sys" "$T/dev" "$T/run"
mount -t proc     proc     "$T/proc" 2>/dev/null || true
mount -t sysfs    sysfs    "$T/sys"   2>/dev/null || true
mount --rbind /dev "$T/dev"           2>/dev/null || true
mount -t tmpfs    tmpfs    "$T/run"   2>/dev/null || true
for m in proc sys dev run; do
    if mountpoint -q "$T/$m"; then
        note "$m: смонтирован"
    else
        note "$m: НЕ смонтирован"
    fi
done

IN() { chroot "$T" /bin/bash -c "$1"; }

say "4. разрешение имен и сеть"
IN 'for h in geo.mirror.pkgbuild.com mirror.cachyos.org; do
        printf "  %-30s " "$h"
        getent hosts "$h" >/dev/null 2>&1 && echo OK || echo NE_RESOLVED
    done
    ip -brief addr 2>/dev/null | awk "{print \"  \" \$1, \$3}" | head -3'

say "5. сколько зеркал в списке целевой системы"
note "активных серверов: $(IN 'grep -c "^Server" /etc/pacman.d/mirrorlist' 2>/dev/null | tr -d ' \r')"
IN 'grep "^Server" /etc/pacman.d/mirrorlist | head -5 | sed "s/^/    /"'

# Запускает pacman с потоковым выводом в файл и таймаутом. Пока идёт, каждые
# пять секунд печатается состояние: иначе пустота на экране неотличима от
# зависания, и это была главная ошибка первой версии.
run_pacman() {
    local label="$1" conf="$2" secs="$3"
    local db=/tmp/dbx
    rm -rf "$db"; mkdir -p "$db"
    : > "$LOG"
    note "--- $label (таймаут ${secs}s) ---"
    ( chroot "$T" /bin/bash -c "
          out=\$(timeout $secs pacman --config $conf --dbpath $db --logfile /dev/null -Sy --verbose 2>&1)
          echo \"__RC__\$?\"
      " >"$LOG" 2>&1 ) &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        waited=$((waited + 5))
        printf '    [%3ds] строк: %-4s последняя: %s\n' \
            "$waited" "$(wc -l < "$LOG")" \
            "$(tail -1 "$LOG" 2>/dev/null | cut -c1-64)"
        if (( waited >= secs + 15 )); then
            note "x не дождались, снимаю процесс"
            pkill -P "$pid" 2>/dev/null
            kill "$pid" 2>/dev/null
            break
        fi
    done
    wait "$pid" 2>/dev/null
    rm -rf "$db"
    printf '  вывод: %s\n' "$label"
    if [[ -s "$LOG" ]]; then
        tail -25 "$LOG" | sed 's/^/    /'
    else
        note "(пусто: pacman не напечатал ни строки)"
    fi
    rm -f "$LOG"
}

say "6. ГЛАВНОЕ: pacman -Sy на полном списке зеркал, потоковый вывод"
# Ровно то, что делает установщик. Если здесь завис, значит завис на зеркале.
run_pacman "полный список" /etc/pacman.conf "$LIMIT"

say "7. ТО ЖЕ на трёх зеркалах из того же файла"
# Разделяет "сеть недоступна" от "список слишком длинный". Берутся именно
# рабочие строки Server, а не первые строки файла: там комментарии.
grep '^Server' "$T/etc/pacman.d/mirrorlist" | head -3 > "$T/etc/pacman.d/mirrorlist.three"
note "короткий список, $(grep -c '^Server' "$T/etc/pacman.d/mirrorlist.three") серверов:"
sed 's/^/    /' "$T/etc/pacman.d/mirrorlist.three"
printf '[core]\nInclude = /etc/pacman.d/mirrorlist.three\n' > "$T/etc/pacman.conf.three"
run_pacman "3 зеркала" /etc/pacman.conf.three 60

say "8. РАЗДЕЛЕНИЕ ПО РЕПОЗИТОРИЯМ: какой именно падает"
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
        if [ \"\$rc\" -eq 0 ]; then
            echo OK
        elif [ \"\$rc\" -eq 124 ]; then
            echo 'ZAVIS (таймаут 60s)'
        else
            echo \"KOD \$rc\"
            echo \"\$out\" | tail -3 | sed 's/^/              /'
        fi
    " 2>/dev/null
    rm -rf /tmp/nyx-dbshared
    mkdir -p /tmp/nyx-dbshared
done

say "9. ИТОГ"
echo "  Нужен весь вывод, особенно разделы 6, 7 и 8."
echo "  Если в разделе 6 стоит ZAVIS, а в разделе 7 все OK, то причина в длине"
echo "  списка зеркал целевой системы, и лечится он коротким списком."
