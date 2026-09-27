#!/usr/bin/env bash
# Диагностика целевой системы: почему pacman -Sy падает в chroot.
#
# Запускается в live-сессии образа, не в установленной системе. Распаковывает
# base-rootfs.squashfs во временный каталог, собирает вокруг него настоящий
# chroot — с /proc, /sys, /dev и /run, — и выполняет pacman -Sy внутри, печатая
# stderr. Ничего не устанавливает и не меняет: цель в том, чтобы увидеть текст
# ошибки, а не починить наугад.
#
# Squashfs целевой системы лежит в live-окружении по пути из unpackfs.conf, так
# что монтировать ISO не нужно.
#
#   sudo bash diagnose-target.sh
#
# В конце все монтирования снимаются, временный каталог удаляется.

set -uo pipefail

SQUASH=/usr/share/archlive/base-rootfs.squashfs
T=/tmp/nyx-target

say()  { printf '\n=== %s ===\n' "$*"; }
note() { printf '  %s\n' "$*"; }

say "0. исходник"
if [[ ! -f "$SQUASH" ]]; then
    echo "  ✗ нет $SQUASH"
    echo "    Этот скрипт надо запускать из live-сессии образа Nyx, а не из"
    echo "    установленной системы. Если вы в установленной системе, скажите."
    exit 1
fi
note "$(stat -c %s "$SQUASH") байт"

cleanup() {
    for m in run dev sys proc; do
        mountpoint -q "$T/$m" 2>/dev/null && umount -R "$T/$m" 2>/dev/null
    done
    rm -rf "$T" 2>/dev/null
}
trap cleanup EXIT

say "1. распаковываю целевую систему"
rm -rf "$T"
if ! unsquashfs -d "$T" "$SQUASH" >/dev/null 2>&1; then
    echo "  ✗ не распаковалось"
    exit 1
fi
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

say "3. что вообще видно в целевой системе"
IN 'echo "  os:      $(. /etc/os-release; echo "$PRETTY_NAME")"
    echo "  pacman:  $(pacman --version | head -1)"
    echo "  uid:     $(id -u)"'

say "4. resolv.conf в целевой системе"
IN 'ls -l /etc/resolv.conf
    echo "  ---"
    cat /etc/resolv.conf'

say "5. РАЗРЕШЕНИЕ ИМЁН — главный подозреваемый"
IN 'for h in geo.mirror.pkgbuild.com mirror.cachyos.org archlinux.org; do
        printf "  %-30s " "$h"
        if getent hosts "$h" >/dev/null 2>&1; then echo "ОК"; else echo "НЕ РАЗРЕШАЕТСЯ"; fi
    done'

say "6. СЕТЬ В CHROOT"
IN 'ip -brief addr 2>/dev/null | sed "s/^/  /"
    echo "  --- маршрут:"
    ip route 2>/dev/null | sed "s/^/  /"'

say "7. ПРАВИЛА И КЛЮЧИ"
IN 'echo "  активных серверов в mirrorlist: $(grep -c "^Server" /etc/pacman.d/mirrorlist)"
    echo "  --- репозитории:"
    grep -E "^\[|^Server|^Include" /etc/pacman.conf | sed "s/^/    /"
    echo "  --- gnupg:"
    ls -ld /etc/pacman.d/gnupg | sed "s/^/    /"
    echo "  ключей в pubring: $(gpg --homedir /etc/pacman.d/gnupg --list-keys 2>/dev/null | grep -c "^pub")"'

say "8. КЛЮЧЕВОЙ ТЕСТ: pacman -Sy целиком, с настоящим stderr"
IN 'out=$(pacman -Sy 2>&1); rc=$?
    echo "$out" | sed "s/^/  /"
    echo "  >>> код возврата: $rc"'

say "9. РАЗДЕЛЕНИЕ ПО РЕПОЗИТОРИЯМ — какой именно падает"
# Каждый репозиторий проверяется отдельно с пустой базой. Так видно, какой из
# них даёт ошибку, а не просто что pacman -Sy вернул 1.
mkdir -p /tmp/nyx-dbshared
for repo in core extra cachyos nyx; do
    printf '  %-9s ' "$repo"
    chroot "$T" /bin/bash -c "
        printf '[%s]\n' '$repo' > /tmp/only.conf
        case '$repo' in
            core|extra) printf 'Include = /etc/pacman.d/mirrorlist\n' >> /tmp/only.conf ;;
            cachyos)    printf 'SigLevel = Optional TrustAll\nServer = https://mirror.cachyos.org/repo/\$arch/cachyos\n' >> /tmp/only.conf ;;
            nyx)        printf 'SigLevel = Optional TrustAll\nServer = file:///var/cache/nyx-repo\n' >> /tmp/only.conf ;;
        esac
        out=\$(pacman --config /tmp/only.conf --dbpath /tmp/dbshared --logfile /dev/null -Sy 2>&1)
        rc=\$?
        if [ \"\$rc\" -eq 0 ]; then
            echo 'ОК'
        else
            echo \"КОД \$rc\"
            echo \"\$out\" | tail -4 | sed 's/^/              /'
        fi
    " 2>/dev/null
    rm -rf /tmp/nyx-dbshared
    mkdir -p /tmp/nyx-dbshared
done

say "10. ИТОГ"
echo "  Нужен именно этот вывод, больше ничего делать не надо."
