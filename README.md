# Nyx Linux

An Arch-based Linux distribution delivered as a bootable ISO with a graphical
installer. The installer runs from the ISO itself: boot it, pick your
desktop, and it installs a working system to your disk.

![UEFI only](https://img.shields.io/badge/boot-UEFI%20%2F%20GPT-blue)
![Secure Boot](https://img.shields.io/badge/Secure%20Boot-not%20supported-orange)

## What it is

- Arch Linux userland, official `core` and `extra` repositories
- The CachyOS repository is added **after** the Arch repositories, so ordinary
  packages keep coming from Arch while `linux-cachyos` and the AUR helpers are
  available
- The CachyOS kernel, with its own initramfs
- KDE Plasma on the installer, so the whole process is graphical
- Branding throughout, with `ID=arch` deliberately left intact so Arch-based
  package compatibility is unaffected

## Requirements

| | |
| --- | --- |
| Boot mode | UEFI only, GPT partitioned |
| Secure Boot | must be disabled |
| Architecture | x86_64 |
| Free disk | 20 GB minimum |
| RAM | 3 GB minimum |

Legacy BIOS is not supported.

## Getting the ISO

Download the image and check it against the published checksum before writing
it to a USB stick:

```bash
sha256sum -c nyx-linux-cachyos-calamares-2026.09.01-x86_64.iso.sha256
```

Use a DD-mode writer (Rufus, balenaEtcher) so the image is written verbatim
You can use Ventoy too.
rather than reinterpreted.

## Installing

1. Boot the USB stick in UEFI mode.
2. The desktop comes up with the installer already open. There is no login to
   type: the live session is a working environment on its own, and the
   installer starts by itself.
3. Work through the steps: locale, keyboard, desktop, AUR helper, partitioning,
   user account, summary.
4. For a normal install choose **Erase Disk** with GPT. Manual partitioning is
   available if you want to lay out the partitions yourself.
5. Keep the boot partition on the ESP. LUKS2 encryption for root is supported.
6. When it finishes, remove the USB stick before rebooting, otherwise the
   firmware may keep booting the installer.

### Choices

| Choice | Options |
| --- | --- |
| Desktop | KDE Plasma, GNOME, XFCE, MATE, Cinnamon, Budgie, LXQt, Deepin, Enlightenment, Pantheon, Sway, Hyprland, Niri, i3, or none |
| AUR helper | Yay, Paru, or none |
| Bootloader | Limine (default), systemd-boot, or GRUB |

The bootloader choice is handled by Nyx's own script, because the installer's
built-in module cannot install Limine. All three options read `/etc/fstab` and
`/etc/crypttab`, so the kernel command line is built correctly for btrfs
subvolumes and encrypted roots.

Boot entries are registered as `Nyx Linux (Limine)`, `Nyx Linux (systemd-boot)`
and `Nyx Linux (GRUB)`.

## On the installed system

| | |
| --- | --- |
| Kernel | `linux-cachyos` |
| Repositories | Arch first, CachyOS appended |
| Hostname | `nyx` |
| `os-release` | `NAME="Nyx Linux"`, `PRETTY_NAME="Nyx Linux (Arch-based)"`, `ID=arch` |
| Shell tooling | `base-devel`, `bash-completion`, `git`, `sudo`, `vim`, `nano`, `htop`, `jq` |
| Media | `ffmpeg`, `pipewire`, `wireplumber` |
| Networking | NetworkManager, `iwd`, `network-manager-applet` |
| Disks | `btrfs-progs`, `lvm2`, `cryptsetup`, `smartmontools`, `nvme-cli` |
| Fonts | Noto family, DejaVu, Liberation, including CJK and emoji |

`ID=arch` is intentional. A `filesystem` or `base` upgrade can restore the stock
`os-release` from Arch, so a pacman hook puts the Nyx branding back afterwards
while leaving `ID=arch` alone. Distro-agnostic tooling keeps working.

### Desktop background

The default background ships with the system and appears in the wallpaper
chooser as **Nyx**. It is applied once, on first login. Change it whenever you
like, nothing enforces it.

### Limine

The Limine boot menu has its own darker background, separate from the desktop
one, because a boot menu needs a dark backdrop for the text to stay readable.
Limine is refreshed automatically after a kernel update.

## Command line extras

### `nyx-tools`

The helper tools ship as one ordinary Arch package, so pacman owns them and a
system update brings a new version along:

- `nyx-updates` — what is available to install. Installs nothing
- `nyx-rollback` — filesystem snapshots, and a way back after a bad update
- `nyx-apply-wallpaper` — applies the default background on first login

### `nyx-updates`

Reports what is available to install. It installs nothing.

```bash
nyx-updates          # check now, print a report, send a notification
nyx-updates --list   # every package that is waiting
nyx-updates --status # replay the last result, no network access
nyx-updates --reset  # forget the baseline, so the next check reports everything
```

Arch, CachyOS, AUR and Nyx's own `nyx-tools` are counted separately, because
they move on different schedules. When the kernel is among the updates it is
called out on its own line together with the reboot it requires.

A background check runs shortly after you log in and every twelve hours after
that, with a random delay so a lot of machines do not query the mirrors in
lockstep. It uses a throwaway package database, so checking never leaves your
system's own database out of step with what is installed.

### Updating the tools themselves

The installed system keeps its own Nyx repository at `/var/cache/nyx-repo`.
`nyx-update-git` fetches this repository, builds `nyx-tools` from it and appends
the result to that local repository. It **only builds**:

```bash
sudo nyx-update-git          # fetch and build
sudo nyx-update-git --check  # only report whether new commits exist
sudo nyx-update-git --diff   # list commits not yet built
sudo pacman -S nyx-tools     # you decide whether to install
```

After the build the new version shows up in `nyx-updates` next to everything
else, and installing it is an ordinary `pacman -S`. The version is
`<release>.<commit count>`, so every build is strictly newer than the last.

Deciding stays with you at every step: the checker only reports, and the
builder only builds.

### `nyx-rollback`

Takes a snapshot of the root filesystem so a bad update is reversible.

```bash
nyx-rollback status     # what is configured, which backend, how many kernels
nyx-rollback list       # snapshots
nyx-rollback create     # take one now
nyx-rollback revert 5   # roll back
```

The backend follows the root filesystem. On **btrfs** it uses `snapper`: the
`/.snapshots` subvolume is created if missing, an hourly timeline is enabled,
and a hook takes a snapshot before and after every `pacman` transaction. On
**ext4**, the installer's default, there are no snapshots to take, so it uses
`timeshift` with an only-if-changed tag and a daily one, so hours without
changes cost no space.

Kernels live on the EFI partition and are deliberately outside the snapshot, so
a filesystem rollback always keeps the installed kernel. `status` lists the
kernels present and says whether rolling one back is possible at all. It only
reports and restores: it never installs a kernel, never edits a bootloader and
never deletes anything without confirmation.

### `fastfetch`

```bash
fastfetch
```

The first line is `user@host` — `archiso@nyx` on the installer, your user on
`nyx` once installed. The layout follows the community Nyarch preset, with a
text logo so it renders in any terminal.

```bash
fastfetch -c nyarch   # the same preset, named
fastfetch -c arch     # a plain Arch preset
```

## This repository

Contains the sources the image is built from, the branding, the installer
configuration and the shipped helper scripts, together with a static checker
that verifies the configuration before an image is produced.

## Notes

- Test the installer in a virtual machine before using it on real hardware.
- The CachyOS repository stays enabled after installation so that
  `linux-cachyos` keeps receiving updates.
- Back up your disk before installing to a physical machine.

## Legal

Arch Linux is a registered trademark. Nyx Linux is an independent derivative
distribution and is not affiliated with, endorsed by, or presented as an
official Arch Linux image.

The ASCII logo in the default `fastfetch` preset is derived from the community
Nyarch project; see `config/fastfetch/NYARCH-NOTICE.md` for its source and
licence. Nyx Linux is not an official Nyarch release.
