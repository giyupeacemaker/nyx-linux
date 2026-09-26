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
- `nyx-update` — Arch news, a snapshot, then the update, in that order
- `nyx-rollback` — filesystem snapshots, and a way back after a bad update
- `nyx-tweaks` — eleven opinionated switches, and a menu to set them
- `nyx-motd` — the login greeting
- `nyx-apply-wallpaper` — applies the default background on first login

### `nyx-update`

Arch breaks in one specific way: a partial upgrade. Holding pacman back on a
library while everything else moves is how a system that was fine yesterday
starts failing today, which is why Arch publishes upgrade news at all. The news
is right there and most people never read it.

```bash
sudo nyx-update           # news, snapshot, then the update
nyx-update --news         # only the news since you last updated
nyx-update --check        # what is waiting, install nothing
sudo nyx-update --skip-news
sudo nyx-update --no-snapshot
```

The snapshot is taken before anything is removed, and if the machine does not
come back up, `nyx-rollback list` followed by `nyx-rollback revert <number>`
goes back to it. A newer kernel is called out at the end, because a running
kernel cannot change under a live system and the update is not finished until
you restart.

Nothing is decided for you: there is no `-y`, every package pacman is about to
touch is asked about, and a removal is spelled out. `--news` stops after reading
and updates nothing.


### `nyx-tweaks`

Eleven switches for the things people spend an evening tuning by hand. Every one
of them is a value in a file; none needs a kernel patch, and none downloads
anything.

```bash
sudo nyx-tweaks                  # the menu
nyx-tweaks list                  # what is set now, no root needed
sudo nyx-tweaks set KEY VALUE    # record one change
sudo nyx-tweaks apply            # make the system match
sudo nyx-tweaks reset            # back to the defaults
```

| switch | what it does |
|---|---|
| `governor` | CPU frequency governor |
| `boost` | turbo, where the firmware allows it |
| `zram` | compressed swap in RAM, sized from RAM or fixed |
| `thp` | transparent huge pages |
| `zswap` | compressed swap cache, before it reaches disk |
| `mitigations` | CPU side-channel mitigation — faster off, less safe |
| `watchdog` | hardware watchdog, off for boards that reboot on their own |
| `pstate` | frequency scaling driver, chosen for your CPU vendor |
| `power-profile` | desktop power profile |
| `ananicy` | automatic process priorities |
| `congestion` | network congestion control: `cubic`, `bbr`, `bbr3` |

`congestion` is the one worth knowing about. BBR and BBR3 are already built into
the CachyOS kernel this distribution installs, as modules, so turning one on
costs no package, no disk and no reboot. It is a real improvement on a busy or
lossy link, and it is free here in a way it is not on stock Arch.

The switch writes two files, because they solve two problems: `sysctl.d` holds
the setting, and `modules-load.d` makes sure the algorithm is actually loaded by
the time sysctl runs. Without the second one the line is applied at boot to a
setting that does not exist yet, and fails silently.

### The kernel and the scheduler

Nyx Linux installs `linux-cachyos`, which is the **EEVDF + LTO + AutoFDO +
Propeller** build. That is the one to want, and it is worth being precise about
why: the performance work in CachyOS is mostly in the *compilation* — LTO,
AutoFDO and Propeller — not in the scheduler.

The scheduler is compiled into the kernel, not a module. There is no `modprobe`
and no boot parameter for it; choosing BORE means installing a different kernel
package, and that package is `linux-cachyos-bore`, which drops the LTO, AutoFDO
and Propeller build to get it. You would be trading general throughput for
latency in some games, plus 166 MB and a reboot. That is a trade-off rather than
an improvement, so it is not offered as a menu entry.

What is offered instead is BBR, which is free, and keeping the kernel that is
actually the fastest one.

`set` and `apply` are separate on purpose: you can line up several changes and
write them in one go. The five kernel parameters need a reboot, and `nyx-tweaks`
reports that by comparing what it wants against `/proc/cmdline`, so it never has
to guess whether a change is in force.

The parameters live in `/etc/nyx/kernel-params` and are read by
`/usr/local/lib/nyx/boot-params`, which both bootloader writers use. That is the
part worth knowing about: writing to `/etc/default/grub` would have done nothing
on Limine or systemd-boot, and the two scripts that assemble the command line
had already drifted apart, one of them appending `rootflags=` after the LUKS
reassignment and the other not.

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
