# Nyx Linux

**Comfy · Gaming · Bloatless**

An Arch-based live ISO with a Calamares graphical installer, built from source
and packaged reproducibly.

- Arch userland, `ID=arch`, official `core`/`extra` only
- CachyOS repository appended **after** the Arch repositories, so ordinary
  packages keep coming from Arch while `linux-cachyos`, `ckbcomp`, `yay` and
  `paru` are available
- Calamares 3.4.3 compiled locally with Python job modules
- 13 desktop choices, 3 AUR helper choices, 3 bootloader choices
- Default hostname `nyx`, branded `os-release` that keeps `ID=arch`
- An update reporter that tells you what is available and installs nothing

## Installer choices

| Choice | Options |
| --- | --- |
| Desktop | KDE Plasma, GNOME, XFCE, MATE, Cinnamon, Budgie, LXQt, Deepin, Enlightenment, Pantheon, Sway, Hyprland, i3, or none |
| AUR helper | Yay, Paru, or none |
| Bootloader | Limine (default), systemd-boot, or GRUB |

Limine is installed as a UEFI NVRAM entry with a fallback path. Calamares' own
`bootloader` module is replaced by `nyx-configure-bootloader`, because the
built-in module cannot install Limine. All three options read `/etc/fstab` and
`/etc/crypttab`, so they build correct kernel command lines for btrfs
subvolumes and LUKS (`rd.luks.uuid=`).

## Building

The build needs a real Linux root with about 45 GB free, and roughly 10 GB of
RAM. It cannot run inside an Arch live session: that session lives entirely in
tmpfs, so the build fails with
`At least 35 GiB of free space is required`.

### WSL2 (verified path)

`wsl-build.sh` prepares everything from scratch: it unpacks `airootfs.sfs` from
the official Arch ISO into a chroot, brings up a genuine `pacman`, `pacstrap`
and `archiso` inside it, and then runs `build.sh`. The WSL disk has to be
expanded to roughly 950 GB; the default 100 GB is not enough.

```powershell
# sync the project into WSL and run the static checks
wsl -d Ubuntu -u root -e bash /path/to/wsl-sync-validate.sh

# build the ISO
wsl -d Ubuntu -u root -e bash /path/to/wsl-build.sh
```

Notes on that environment, all of which are load-bearing:

- `pacstrap` requires the target directory to exist beforehand
- the chroot needs `/etc/pacman.d/gnupg`, otherwise `pacman-key --init` cannot
  populate the keyring
- the WSL root does not appear in `mountinfo` from inside the chroot, so `/build`
  has to be bind-mounted with `mount --rbind` **and** `--make-rprivate`; a plain
  `--bind` hides the submounts underneath
- `/proc`, `/dev` and `/sys` must be `rbind`-mounted from the host, otherwise
  `/dev/fd` is missing and `build.sh` dies on its first line, because it logs
  through `exec > >(tee ...)`
- `/build/nyx` is a bind mount, but `/build/archbuild` must stay a plain
  directory: `build.sh` begins with `rm -rf "$BUILD_ROOT"` and that fails on a
  mount point

### VirtualBox

1. Create a Linux VM, Arch Linux 64-bit.
2. RAM 6 GB with 16 GB on the host, 4 CPU cores.
3. Dynamically allocated disk, 80–100 GB.
4. Enable **EFI**, disable **Secure Boot**.
5. Network: NAT.
6. Mount the project as a VirtualBox Shared Folder named `archcustom`, writable.
7. Attach the official `archlinux-2026.09.01-x86_64.iso` as optical media.
8. Boot it, mount the share and run `vm-install-arch.sh`, which partitions,
   installs Arch and creates the `nyx` user (password `arch`) with `sudo`.
9. **Detach the installer ISO** before rebooting into the installed system.
10. From the installed system, mount the share and run `sudo bash build.sh`.

```bash
sudo env KEEP_BUILD=1 JOBS=4 bash build.sh   # keep the tree for diagnostics
```

## Output

```
out/nyx-linux-cachyos-calamares-2026.09.01-x86_64.iso
out/nyx-linux-cachyos-calamares-2026.09.01-x86_64.iso.sha256
out/build-2026.09.01.log
```

`build.sh` refuses to finish successfully unless the finished image passes its
content checks: CachyOS kernel present, Calamares present, the target rootfs
carrying the service scripts and the fastfetch presets, a live account that can
actually be logged into, and skel populated so the presets land in a home
directory.

## Branding

- `NAME="Nyx Linux"`, `PRETTY_NAME="Nyx Linux (Arch-based)"`, `ID=arch`
- Bootloader entries read `Nyx Linux (Limine)`, `Nyx Linux (systemd-boot)`,
  `Nyx Linux (GRUB)`; GRUB's bootloader ID is `NyxLinux`
- ISO metadata: publisher `Nyx Linux Project`
- Default hostname `nyx`, in both the live image and the installed system
- MOTD on the live console, and the Calamares welcome screen

`filesystem` or `base` upgrades can restore `/usr/lib/os-release` from Arch, so
the pacman hook `99-nyx-os-release.hook` puts the Nyx branding back while
keeping `ID=arch`. The template lives at `/usr/share/arch-custom/nyx-os-release`.

The ASCII logo is the [Nyarch Linux](https://github.com/fastfetch-cli/fastfetch)
one, used as a visual reference; see `config/fastfetch/NYARCH-NOTICE.md` for
its source and licence. Nyx Linux is a separate Arch-based derivative and does
not claim to be an official Nyarch release.

## fastfetch

The default preset leads with fastfetch's `title` module, so the first line is
`user@host` — `archiso@nyx` on the live session, your user on `nyx` after
installing. The rest follows the official Nyarch preset from
<https://github.com/LierB/fastfetch> (`presets/nyarch.jsonc`, by Bina).

One deliberate deviation: the logo is a text file rather than a PNG over the
kitty graphics protocol. Plasma's konsole does not speak kitty images, so a PNG
logo would render as nothing. To switch back, set `"type": "kitty"` in the
preset and point `source` at the image.

```bash
fastfetch            # default: user@host, then the Nyarch ASCII logo
fastfetch -c nyarch  # same preset, named
fastfetch -c arch    # plain Arch preset
fastfetch --list 2>/dev/null; nyx-updates --list
```

## Update reporter

`nyx-updates` reports what is available and installs nothing.

```bash
nyx-updates          # check, print a report, send a notification
nyx-updates --list   # full package list
nyx-updates --status # replay the last result, no network access
nyx-updates --reset  # forget the baseline, next check reports everything
```

It uses `checkupdates` from `pacman-contrib`, which syncs into a throwaway
directory. `pacman -Sy` without `-u` would leave the real database out of step
with the installed packages, which is a well known way to break a system.

Arch, CachyOS and AUR are counted separately, and a kernel update is called out
on its own line together with the reboot it requires. A `systemd` user timer
runs the check five minutes after login and every twelve hours afterwards, with
a random delay so a fleet of machines does not hit the mirrors in lockstep. It
is a user unit because `notify-send` has to reach the running graphical
session.

## Desktop background

The default background ships in `/usr/share/backgrounds/nyx.jpg` and as a Plasma
wallpaper package in `/usr/share/wallpapers/nyx/`, so it appears in the
wallpaper chooser. It is applied once on first login by
`/usr/local/bin/nyx-apply-wallpaper` rather than by seeding
`plasma-org.kde.plasma.desktop-appletsrc` into the skeleton, which is large and
version-specific.

The Limine boot background is a separate, darker image: the boot menu needs a
dark backdrop for the text to stay readable.

## Checks

`validate.sh` runs 136 static checks and needs no root: branding invariants, the
Calamares sequence, module availability, pacman hook wiring, JSONC, YAML, XML,
shellcheck, and the fastfetch preset layout.

Two failure modes it exists to prevent, both of which shipped broken builds at
some point:

- a module named in `settings.conf` that the package does not build makes
  Calamares refuse to start with *Calamares Initialization Failed*. Calamares
  splits a module name at the **first** hyphen, so for `services-systemd` the
  category is `services` and the implementation is `systemd`; `USE_services`
  must be `systemd`, not the full module name
- pacman honours only the **last** `Exec` line of a hook, and silently skips a
  hook whose `Depends` names a package Arch does not ship (`chpasswd` is in
  `shadow`, there is no `passwd` package)

## Requirements and limits

- UEFI/GPT only; Legacy BIOS is not supported
- Secure Boot is not supported in this version
- Test Limine, GRUB and Calamares in a VM before installing to real hardware
- The CachyOS repository stays enabled in the installed system so that
  `linux-cachyos` keeps updating; the repository order is deliberately
  Arch-first
- Back up your disk before a physical install

## Legal

Arch Linux is a registered trademark. Nyx Linux is a derivative distribution
and must not be presented as an official Arch Linux image. The ISO is for
personal use; publishing it means presenting Nyx Linux as a separate build.
