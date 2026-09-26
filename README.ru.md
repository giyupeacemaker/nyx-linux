# Nyx Linux

Nyx Linux — Arch-based live ISO с Calamares.

Репозиторий: <https://github.com/giyupeacemaker/nyx-linux>

## Что внутри

- Arch Linux userland и официальные репозитории `core`/`extra`.
- CachyOS-репозиторий подключён **после** Arch-репозиториев, поэтому обычные пакеты берутся из Arch, а из CachyOS доступны `linux-cachyos`, `ckbcomp`, `yay` и `paru`.
- Calamares 3.4.3 собирается локально из исходников с Python job-модулями.
- Live-окружение: KDE Plasma, SDDM, Calamares, NetworkManager, VirtualBox Guest Additions.
- Устанавливаемая система: минимальная Arch-based база, `git`, `wget`, `curl`, `sudo`, `base-devel`, NetworkManager, `fastfetch`, `noto-fonts-emoji` и `noto-fonts-cjk`.
- Выбор рабочего стола: KDE Plasma, GNOME, XFCE, MATE, Cinnamon, Budgie, LXQt, Deepin, Enlightenment, Pantheon, Sway, Hyprland, i3 или минимальная система.
- Выбор AUR-помощника: Yay, Paru или не устанавливать.
- Выбор загрузчика: Limine (по умолчанию), systemd-boot или GRUB. Все три настраивает собственный скрипт `nyx-configure-bootloader` (встроенный модуль Calamares не умеет ставить Limine).
- UEFI/GPT, Limine/systemd-boot/GRUB, поддержка LUKS и ручной разметки.
- `fastfetch` установлен в live и итоговую систему.
- В target rootfs кладутся `mirrorlist` и служебные скрипты, поэтому установка пакетов Calamares работает автономно от настроек хостовой VM.

## Что понадобится в VirtualBox

1. Создай VM типа Linux, версия Arch Linux 64-bit.
2. RAM: 6 ГБ (при 16 ГБ на хосте), CPU: 4 ядра.
3. VDI: динамический диск 80–100 ГБ. Внутри VM нужно **не меньше 45 ГБ** свободного места: сам build занимает ~35 ГБ, плюс место под установленную Arch и итоговый ISO.
4. Включи **EFI** и отключи **Secure Boot**.
5. Сеть: NAT.
6. Подключи папку проекта как VirtualBox Shared Folder с именем `archcustom` и правом записи.
7. Подключи официальный `archlinux-2026.09.01-x86_64.iso` как оптический диск.

## Важно: собирать нужно из установленной Arch, а не из live-сессии

Live-сессия Arch целиком живёт в tmpfs, то есть в оперативной памяти. Сборке нужно
~35 ГБ на диске, поэтому прямо в live-сессии она упадёт с ошибкой
`At least 35 GiB of free space is required in the VM`.

Порядок такой:

1. Загрузись с официального Arch ISO в UEFI-режиме.
2. Смонтируй общую папку и запусти готовый скрипт установки:

   ```bash
   mkdir -p /mnt/project
   mount -t vboxsf archcustom /mnt/project
   cd /mnt/project
   bash vm-install-arch.sh
   ```

   Скрипт разметит диск, поставит Arch, создаст пользователя `nyx` (пароль `arch`)
   с `sudo` и сразу покажет команды для сборки. Если ставишь Arch руками, нужен
   раздел `/` на 50+ ГБ, ESP `/boot` 1 ГБ, GPT и пользователь в группе `wheel`.

3. **Извлеки ISO из VirtualBox** и перезагрузись в установленную систему.
4. Подключи общую папку и запусти сборку.

## Сборка

В установленной Arch подключи общую папку:

```bash
sudo pacman -Syu --needed virtualbox-guest-utils-nox
sudo modprobe vboxsf
sudo mkdir -p /mnt/project
sudo mount -t vboxsf archcustom /mnt/project
cd /mnt/project
```

Проверь, что места хватает (должно быть свободно не меньше 45 ГБ):

```bash
df -h /
```

Запуск сборки:

```bash
sudo bash build.sh
```

Для диагностики можно оставить временные файлы сборки:

```bash
sudo env KEEP_BUILD=1 JOBS=4 bash build.sh
```

Сборка делается внутри Linux VM, а не в Windows. Скрипт:

1. установит сборочные зависимости;
2. соберёт Calamares 3.4.3;
3. создаст минимальный rootfs с CachyOS-репозиторием и собственным `mirrorlist`;
4. подготовит профиль `archiso`;
5. соберёт UEFI ISO;
6. проверит наличие ядра, Calamares, base rootfs, служебных скриптов, CachyOS keyring и всех fastfetch-пресетов.

Результат появится в общей папке:

```text
out/nyx-linux-cachyos-calamares-2026.09.01-x86_64.iso
out/nyx-linux-cachyos-calamares-2026.09.01-x86_64.iso.sha256
out/build-2026.09.01.log
```

## Сборка в WSL2 (проверенный путь)

Сборка на Windows идёт через WSL2 с отдельным Arch-окружением. Прямо в
live-сессии Arch собрать нельзя: она целиком в tmpfs, то есть в оперативной
памяти, а сборке нужно ~35 ГБ на диске.

`wsl-build.sh` готовит это окружение с нуля: распаковывает `airootfs.sfs` из
официального ISO в chroot, поднимает в нём настоящий `pacman`/`pacstrap` и
`archiso`, после чего запускает `build.sh`. Диск WSL должен быть расширен
примерно до 950 ГБ — на стандартном 100 ГБ сборка не поместится.

```powershell
# синхронизировать проект в WSL и прогнать статические проверки
wsl -d Ubuntu -u root -e bash /mnt/c/Users/giyu/AppData/Local/Temp/opencode/wsl-sync-validate.sh

# собрать ISO
wsl -d Ubuntu -u root -e bash /mnt/c/Users/giyu/AppData/Local/Temp/opencode/wsl-build.sh
```

Лог пишется в `out/build-2026.09.01.log`. Готовый образ появляется в `out/`
вместе с `.sha256`.

Особенности окружения, без которых chroot не стартует:

- `pacstrap` требует, чтобы каталог назначения уже существовал;
- в chroot нужен `/etc/pacman.d/gnupg`, иначе `pacman-key` не инициализируется —
  лечится `pacman-key --init`;
- корень WSL не виден в `mountinfo` изнутри chroot, поэтому `/build` приходится
  монтировать через `mount --rbind ... --make-rprivate`: обычный `--bind`
  перекрывает подмонтирования.

## Первая установка

1. Создай новую тестовую VM и подключи собранный ISO.
2. Загрузись в UEFI. Calamares должен открыться автоматически через SDDM.
3. Сделай выбор рабочего стола, AUR-помощника и загрузчика.
4. Для обычной установки выбери `Erase` и GPT. Ручная разметка тоже доступна.
5. Оставь UEFI, `/boot` на ESP и желательно LUKS2 для root.
6. После завершения **извлеки исходный ISO из VirtualBox перед перезагрузкой**, иначе UEFI может продолжить загружать установочный диск.

Limine устанавливается в UEFI, получает NVRAM-запись и fallback-путь. Его тема и меню находятся в `config/limine-bg.png`; конфигурация обновляется pacman hook после обновления ядра. Secure Boot для этой первой версии не поддерживается.

Выбор загрузчика обрабатывает `nyx-configure-bootloader`:

- **Limine** — ставит NVRAM-запись `Nyx Linux (Limine)`, fallback `EFI/BOOT/BOOTX64.EFI` и меню из `update-arch-limine`;
- **systemd-boot** — пишет `loader/entries/10-nyx-linux.conf` и `loader.conf`, затем вызывает `bootctl install` и регистрирует запись `Nyx Linux (systemd-boot)`;
- **GRUB** — `grub-install --target=x86_64-efi` c `--bootloader-id=NyxLinux`, затем `grub-mkconfig`, запись `Nyx Linux (GRUB)`.

Все три варианта читают `/etc/fstab` и `/etc/crypttab`, поэтому корректно собирают cmdline для btrfs-подтомов и LUKS (`rd.luks.uuid=`).

## Название и fastfetch

В системе:

- `ID=arch` — Arch-based совместимость сохранена;
- `NAME="Nyx Linux"`;
- `PRETTY_NAME="Nyx Linux (Arch-based)"`;
- `VERSION_ID` соответствует дате сборки.

Обычные обновления `filesystem`/`base` могут вернуть `/usr/lib/os-release` к оригиналу Arch, поэтому pacman hook `99-nyx-os-release.hook` автоматически восстанавливает брендинг Nyx, сохраняя `ID=arch`. Шаблон лежит в `/usr/share/arch-custom/nyx-os-release`.

По умолчанию для Nyx Linux:

```bash
fastfetch
```

Первая строка вывода — `user@host` (на живой сессии это `archiso@nyx`, после
установки — твой пользователь на `nyx`). Дальше идёт собственный логотип Nyx — знак мира и слово NYX — и
список модулей с ключами `~`. Раскладка взята из официального пресета Nyarch:
<https://github.com/LierB/fastfetch> (`presets/nyarch.jsonc`), оттуда же модуль
`title`, который и печатает `user@host`.

Одно осознанное отличие от апстрима: логотип подключён файлом, а не картинкой
через графический протокол kitty. Живая и установленная системы работают на
Plasma, где konsole этот протокол не понимает, и PNG-логотип не отрисовался бы
вообще. Чтобы вернуть картинку, замени в пресете `"type": "file"` на
`"type": "kitty"` и укажи путь к PNG.

Хостнейм по умолчанию — `nyx`, и он прописан и в live-образ, и в устанавливаемую
систему. Модуль `hostname` Calamares находится в `SKIP_MODULES`, поэтому имя
больше ничем не перебивается.

Отдельный обычный Arch-вариант:

```bash
fastfetch -c arch
```

Явный запуск пресета Nyx:

```bash
fastfetch -c nyx
```

Логотип нарисован специально для этого дистрибутива. Название в `/etc/os-release` — Nyx Linux, но `ID=arch` сохранён, поэтому Arch-based совместимость и пакетная база остаются без изменений. Сборка не объявляется официальным релизом Arch Linux или Nyarch. Раскладка модулей пресета fastfetch позаимствована из сообщества: <https://github.com/LierB/fastfetch> (`presets/nyarch.jsonc`). Логотип — `config/fastfetch/nyx.ascii`, он оригинальный.

Файлы `fastfetch` кладутся в `/etc/skel/.config/fastfetch`, поэтому пресеты появляются у live-пользователя и у пользователя после установки Calamares. В `/etc/os-release` меняется только имя Nyx Linux; `ID=arch` и Arch-репозитории сохраняются.

Для личного использования это нормально. Публикуя ISO, указывай Nyx Linux как отдельную сборку, производную от Arch Linux: Arch Linux — зарегистрированная торговая марка, а модифицированный продукт не должен выглядеть официальным ISO Arch.

## Важные ограничения первой версии

- Только UEFI/GPT; Legacy BIOS не поддерживается.
- Limine, GRUB и Calamares нужно тестировать в отдельной VM перед установкой на физический компьютер.
- CachyOS-репозиторий остаётся в установленной системе для обновления `linux-cachyos`; порядок репозиториев специально оставлен Arch-first.
- Перед физической установкой сделай резервную копию диска.
