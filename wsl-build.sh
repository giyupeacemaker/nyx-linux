#!/usr/bin/env bash
# Create a complete Arch Linux build environment inside WSL2 and build the ISO.
#
# Run from an elevated WSL shell (PowerShell: wsl -d Ubuntu -u root -e bash
# /mnt/c/.../wsl-build.sh) or directly under WSL root.
#
# Why this exists
# ---------------
# The Arch live ISO keeps its whole root filesystem in tmpfs (RAM), so a ~35 GiB
# ISO build cannot run from the live session. A normal VirtualBox VM works but is
# slow to iterate on. This script instead unpacks the ISO's own airootfs into a
# chroot on the WSL-native disk, which gives a real pacman/pacstrap/archiso with
# ~900 GiB of space, so the build can be re-run quickly while iterating.
#
# WSL2 specifics that have to be worked around:
#   * /etc/pacman.d/gnupg is missing from the unpacked rootfs -> pacman refuses
#     to run ("keyring is not writable"). pacman-key --init fixes it.
#   * The WSL root filesystem has no entry in /proc/self/mountinfo, so pacman
#     cannot resolve mount points -> "could not determine cachedir/root mount
#     point". Bind-mounting a work directory at /build gives it a real mount
#     point, and CheckSpace is disabled because there is ample space.
#   * CacheDir is moved onto the WSL-native disk for speed.
set -Eeuo pipefail

ARCHROOT=/var/tmp/archroot
WORK=/var/tmp/nyx-work          # host-side, WSL-native disk
BUILD_MP=/build                 # where WORK appears inside the chroot
SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ "$(id -u)" -eq 0 ]] || { echo "Run as root inside WSL." >&2; exit 1; }

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# --- locate the official ISO ------------------------------------------------
ISO="$(find /mnt/c -maxdepth 4 -name 'archlinux-*.iso' 2>/dev/null | head -1)"
[[ -n "$ISO" ]] || { echo "Arch ISO not found under /mnt/c" >&2; exit 1; }
log "ISO: $ISO"

# --- mount and unpack -------------------------------------------------------
MOUNT=/mnt/archiso
mkdir -p "$MOUNT"
mountpoint -q "$MOUNT" || mount -o loop,ro "$ISO" "$MOUNT"
SFS="$(find "$MOUNT" -name 'airootfs.sfs' | head -1)"
[[ -n "$SFS" ]] || { echo "airootfs.sfs not found" >&2; exit 1; }

if [[ ! -x "$ARCHROOT/usr/bin/pacman" ]]; then
    log "unpacking airootfs.sfs"
    rm -rf "$ARCHROOT"; mkdir -p "$ARCHROOT"
    unsquashfs -f -d "$ARCHROOT" "$SFS" >/dev/null
else
    log "rootfs already present, reusing"
fi

# --- kernel filesystems -----------------------------------------------------
# Order matters: the kernel filesystems first, then the recursive bind of the
# root. A plain --bind would shadow the submounts, so --rbind + --make-rprivate.
for m in proc sys dev dev/pts dev/shm run; do mkdir -p "$ARCHROOT/$m"; done
mountpoint -q "$ARCHROOT/proc"    || mount -t proc  proc  "$ARCHROOT/proc"
mountpoint -q "$ARCHROOT/sys"     || mount -t sysfs sysfs "$ARCHROOT/sys"
mountpoint -q "$ARCHROOT/dev"     || mount --bind /dev     "$ARCHROOT/dev"
mountpoint -q "$ARCHROOT/dev/pts" || mount --bind /dev/pts "$ARCHROOT/dev/pts"
mountpoint -q "$ARCHROOT/dev/shm" || mount --bind /dev/shm "$ARCHROOT/dev/shm"
mountpoint -q "$ARCHROOT/run"     || mount --bind /run     "$ARCHROOT/run"

if ! findmnt -n -o TARGET "$ARCHROOT" 2>/dev/null | grep -qx "$ARCHROOT"; then
    mount --rbind "$ARCHROOT" "$ARCHROOT"
fi
mount --make-rprivate "$ARCHROOT" 2>/dev/null || true

# Sanity: /proc and /dev must survive, otherwise the build cannot mount the ISO.
chroot "$ARCHROOT" /usr/bin/bash -c '
    [ -r /proc/self/mountinfo ] || { echo "/proc missing in chroot" >&2; exit 1; }
    [ -e /dev/null ]           || { echo "/dev missing in chroot"  >&2; exit 1; }
'

# --- DNS --------------------------------------------------------------------
rm -f "$ARCHROOT/etc/resolv.conf"
cp -L /etc/resolv.conf "$ARCHROOT/etc/resolv.conf"

# --- give pacman a usable keyring and mount point --------------------------
mkdir -p "$WORK" "$ARCHROOT$BUILD_MP"
mountpoint -q "$ARCHROOT$BUILD_MP" || mount --bind "$WORK" "$ARCHROOT$BUILD_MP"

chroot "$ARCHROOT" /usr/bin/bash -lc "
  set -e
  mkdir -p /etc/pacman.d/gnupg && chmod 700 /etc/pacman.d/gnupg
  [ -f /etc/pacman.d/gnupg/trustdb.gpg ] || { pacman-key --init >/dev/null 2>&1; pacman-key --populate archlinux >/dev/null 2>&1; }
  python3 - /etc/pacman.conf <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = re.sub(r'(?m)^#?CacheDir\s*=.*\n', '', s)
s = re.sub(r'(?m)^#?CheckSpace\s*$',   '#CheckSpace', s)
s = s.replace('[options]', '[options]\nCacheDir = ${BUILD_MP}/cache/pkg', 1)
open(p, 'w', encoding='utf-8').write(s)
PY
  mkdir -p ${BUILD_MP}/cache/pkg
"

# --- build prerequisites ----------------------------------------------------
log "installing build prerequisites"
chroot "$ARCHROOT" /usr/bin/bash -lc '
  pacman -Sy --needed --noconfirm --disable-download-timeout >/dev/null
  pacman -S --needed --noconfirm --disable-download-timeout \
      git archiso xorriso mtools dosfstools arch-install-scripts >/dev/null
  for t in pacstrap makepkg mkarchiso unsquashfs mksquashfs xorriso bsdtar git rsync python; do
    command -v "$t" >/dev/null || { echo "missing $t" >&2; exit 1; }
  done
  echo "all build tools present"
'

# --- stage the project on the fast disk -------------------------------------
log "staging project"
mkdir -p "$WORK/nyx"
rsync -a --delete --exclude '/out/' --exclude '*.iso' --exclude '*.log' "$SRC_DIR/" "$WORK/nyx/"

# --- build ------------------------------------------------------------------
log "starting build.sh (this takes 40-80 minutes)"
exec chroot "$ARCHROOT" /usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/usr/sbin \
    HOME=/root TERM=xterm \
    BUILD_ROOT="${BUILD_MP}/archbuild" JOBS=4 KEEP_BUILD=1 \
    /usr/bin/bash -lc "cd ${BUILD_MP}/nyx && bash build.sh"
