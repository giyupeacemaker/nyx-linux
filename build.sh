#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/var/tmp/arch-cachyos-calamares-build}"
JOBS="${JOBS:-$(nproc)}"
KEEP_BUILD="${KEEP_BUILD:-0}"
RELEASE="2026.09.01"
CALAMARES_VERSION="3.4.3"
FINAL_NAME="nyx-linux-cachyos-calamares-${RELEASE}-x86_64.iso"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '\033[0;36m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
    local code=$? line="${1:-?}" cmd="${2:-?}"
    printf '\n\033[1;31mBuild failed (exit %s) at line %s.\033[0m\n' "$code" "$line" >&2
    printf 'Failing command: %s\n' "$cmd" >&2
    printf 'The build directory was kept for diagnostics: %s\n' "$BUILD_ROOT" >&2
    if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
        printf 'Full log: %s\n' "$LOG_FILE" >&2
    fi
    exit "$code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

[[ "${EUID}" -eq 0 ]] || die "Run this script as root: sudo bash build.sh"

# Set up logging as early as possible so early failures are captured too.
LOG_DIR="${LOG_DIR:-$SOURCE_DIR/out}"
install -d -m 0755 "$LOG_DIR" 2>/dev/null || LOG_DIR=/var/tmp
LOG_FILE="$LOG_DIR/build-${RELEASE}.log"
: >"$LOG_FILE" 2>/dev/null || LOG_FILE=/var/tmp/build-${RELEASE}.log
exec > >(tee -a "$LOG_FILE") 2>&1
info "Logging to $LOG_FILE"

grep -q '^ID=arch$' /etc/os-release || die "This script must run inside Arch Linux."
[[ -f "$SOURCE_DIR/archlinux-${RELEASE}-x86_64.iso" ]] || warn "The official source ISO is not next to the project; it is not needed by the build itself."

BUILD_ROOT="$(realpath -m "$BUILD_ROOT")"
[[ "$BUILD_ROOT" != "/" && "$BUILD_ROOT" != "/var/tmp" && "$BUILD_ROOT" != "$SOURCE_DIR" ]] || die "Unsafe BUILD_ROOT: $BUILD_ROOT"

log "Preparing build directory"
df -h "$SOURCE_DIR" | sed -n '1,2p'
rm -rf -- "$BUILD_ROOT"
install -d -m 0755 "$BUILD_ROOT/source"
rsync -a --delete \
    --exclude '/out/' \
    --exclude '/work/' \
    --exclude '*.iso' \
    --exclude '*.log' \
    "$SOURCE_DIR/" "$BUILD_ROOT/source/"

SRC="$BUILD_ROOT/source"
PROFILE="$BUILD_ROOT/profile"
WORK_DIR="$BUILD_ROOT/work"
LOCAL_REPO="$BUILD_ROOT/localrepo"
CALAMARES_BUILD="$BUILD_ROOT/calamares-build"
BASE_ROOTFS="$BUILD_ROOT/base-rootfs"
BASE_SQUASHFS="$BASE_ROOTFS.squashfs"
PROFILE_OUT="$BUILD_ROOT/out"
ARCHISO_SRC="$BUILD_ROOT/archiso-source"
AIROOTFS="$PROFILE/airootfs"
MOUNT_DIR=""
ISO_MOUNTED=0

cleanup_iso() {
    if (( ISO_MOUNTED == 1 )); then
        umount "$MOUNT_DIR" 2>/dev/null || true
        ISO_MOUNTED=0
    fi
    # Must not end on a false test: as an EXIT trap the return value is the
    # script's exit status, and a bare "[[ ... ]] && rm" yields 1 when the mount
    # dir is already gone, which made a fully successful build report exit 1.
    if [[ -n "$MOUNT_DIR" ]]; then
        rm -rf -- "$MOUNT_DIR" || true
    fi
    return 0
}

install_nyx_os_release() {
    local root="$1"
    # Arch normally keeps /etc/os-release as a symlink to /usr/lib/os-release.
    # Replace both sides so tools reading either path see the Nyx name while ID=arch stays intact.
    install -d -m 0755 "$root/etc" "$root/usr/lib" "$root/usr/share/arch-custom"
    rm -f "$root/etc/os-release" "$root/usr/lib/os-release"
    sed "s/@RELEASE@/${RELEASE}/g" "$SRC/config/nyx-os-release" >"$root/usr/lib/os-release"
    chmod 0644 "$root/usr/lib/os-release"
    ln -s ../usr/lib/os-release "$root/etc/os-release"
    # Keep a rendered copy so the pacman hook can restore the branding
    # after filesystem/base upgrades replace /usr/lib/os-release.
    cp -a "$root/usr/lib/os-release" "$root/usr/share/arch-custom/nyx-os-release"
}

# For the live image, pacman still owns /usr/lib/os-release via the filesystem
# package, so writing it up front makes the whole transaction fail with
# "conflicting files". Stage only the template here; the installed
# 99-nyx-os-release.hook applies the branding right after the transaction.
stage_nyx_os_release() {
    local root="$1"
    install -d -m 0755 "$root/usr/share/arch-custom"
    sed "s/@RELEASE@/${RELEASE}/g" "$SRC/config/nyx-os-release" \
        >"$root/usr/share/arch-custom/nyx-os-release"
    chmod 0644 "$root/usr/share/arch-custom/nyx-os-release"
}

trap cleanup_iso EXIT

avail_kib="$(df -Pk "$BUILD_ROOT" | awk 'NR == 2 { print $4 }')"
build_fs="$(df -PT "$BUILD_ROOT" | awk 'NR == 2 { print $2 }')"
if [[ "$build_fs" == "tmpfs" ]]; then
    die "BUILD_ROOT ($BUILD_ROOT) is on tmpfs (RAM). The live ISO session cannot hold the ~35 GiB build. Install Arch to the VM disk first, then run build.sh from the installed system."
fi
(( avail_kib >= 35 * 1024 * 1024 )) || die "At least 35 GiB of free space is required in the VM (currently $((avail_kib / 1024 / 1024)) GiB on $build_fs at $BUILD_ROOT)."

if (( JOBS > 8 )); then
    JOBS=8
    warn "Parallel build jobs capped at 8 to keep memory usage reasonable."
fi

log "Installing build dependencies"
pacman -Syu --needed --noconfirm
pacman -S --needed --noconfirm \
    arch-install-scripts \
    archiso \
    base-devel \
    cmake \
    cpio \
    curl \
    extra-cmake-modules \
    kcoreaddons \
    kpmcore \
    libarchive \
    libpwquality \
    ninja \
    polkit-qt6 \
    python \
    python-yaml \
    qt6-base \
    qt6-declarative \
    qt6-svg \
    qt6-tools \
    qt6-translations \
    rsync \
    squashfs-tools \
    yaml-cpp

# Network is verified only after the build dependencies (including curl) exist.
# This check is advisory on purpose: a single failed probe must not abort a
# build, because a mirror or CDN may reset an occasional connection while pacman
# itself keeps working. A real outage surfaces loudly at the first transaction.
for probe in https://archlinux.org/ https://mirror.cachyos.org/; do
    if ! curl -fsSL --max-time 30 -o /dev/null --retry 3 --retry-delay 2 "$probe"; then
        warn "Probe failed for ${probe}; continuing. If pacman then fails, the network really is down."
    fi
done

log "Building Calamares 3.4.3"
rm -rf -- "$CALAMARES_BUILD"
install -d -m 0755 "$CALAMARES_BUILD" "$LOCAL_REPO"
cp "$SRC/vendor/calamares-v${CALAMARES_VERSION}.tar.gz" \
    "$CALAMARES_BUILD/calamares-${CALAMARES_VERSION}.tar.gz"
cp "$SRC/vendor/calamares/PKGBUILD" "$CALAMARES_BUILD/"

if ! id iso-builder >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash iso-builder
fi
chown -R iso-builder:iso-builder "$CALAMARES_BUILD"
runuser -u iso-builder -- env "MAKEFLAGS=-j${JOBS}" bash -c \
    "cd '$CALAMARES_BUILD' && makepkg --noconfirm --cleanbuild --nodeps"

# makepkg also emits a split -debug package; only the main one belongs in the
# local repository used by the ISO.
mapfile -t calamares_packages < <(
    find "$CALAMARES_BUILD" -maxdepth 1 -type f \
        -name 'calamares-[0-9]*-x86_64.pkg.tar.zst' \
        ! -name 'calamares-debug-*' -print
)
(( ${#calamares_packages[@]} == 1 )) || die "Expected exactly one Calamares package, found ${#calamares_packages[@]}."
cp "${calamares_packages[0]}" "$LOCAL_REPO/"

# nyx-tools is a real package rather than loose files in the base rootfs, so
# that pacman owns the files and so that an installed system can upgrade them
# from the GitHub repository. It is built before the target rootfs is created,
# because the target has to be seeded with it.
log "Building nyx-tools"
NYX_TOOLS_BUILD="$BUILD_ROOT/nyx-tools-build"
rm -rf -- "$NYX_TOOLS_BUILD"
install -d -m 0755 "$NYX_TOOLS_BUILD"
cp -a "$SRC/nyx-tools/." "$NYX_TOOLS_BUILD/"
# The version has to be a real one even for the ISO build, so that a later
# rebuild from git produces something strictly newer.
printf '%s.%s\n' "$RELEASE" "$(git -C "$SRC" rev-list --count HEAD 2>/dev/null || echo 0)" \
    >"$NYX_TOOLS_BUILD/VERSION"
chown -R iso-builder:iso-builder "$NYX_TOOLS_BUILD"
runuser -u iso-builder -- env "MAKEFLAGS=-j${JOBS}" bash -c \
    "cd '$NYX_TOOLS_BUILD' && makepkg --noconfirm --cleanbuild --nodeps"

mapfile -t nyx_tools_packages < <(
    find "$NYX_TOOLS_BUILD" -maxdepth 1 -type f \
        -name 'nyx-tools-[0-9]*-x86_64.pkg.tar.zst' -print
)
(( ${#nyx_tools_packages[@]} == 1 )) \
    || die "Expected exactly one nyx-tools package, found ${#nyx_tools_packages[@]}."
cp "${nyx_tools_packages[0]}" "$LOCAL_REPO/"
info "nyx-tools: $(basename "${nyx_tools_packages[0]}")"

# The database name has to match the repository section in pacman.conf, because
# that is literally how pacman finds it: the [nyx] section looks for "nyx.db" and
# nothing else. A database called nyx-local.db under a [nyx] section fails with
# "failed retrieving file 'nyx.db'", and it does so deep inside mkarchiso, after
# Calamares and everything else has already been built. The installed system's
# repository is seeded as nyx.db for the same reason, so the two now agree.
repo-add "$LOCAL_REPO/nyx.db.tar.zst" "$LOCAL_REPO"/*.pkg.tar.zst

log "Creating the minimal target root filesystem"
rm -rf -- "$BASE_ROOTFS" "$BASE_SQUASHFS"
# arch-install-scripts >= 31 requires the target directory to exist already;
# older pacstrap created it itself.
install -d -m 0755 "$BASE_ROOTFS"
pacstrap -K -G -M "$BASE_ROOTFS" base
install_nyx_os_release "$BASE_ROOTFS"
install -Dm0644 "$SRC/config/live-pacman.conf" "$BASE_ROOTFS/etc/pacman.conf"
install -Dm0644 "$SRC/config/locale.gen" "$BASE_ROOTFS/etc/locale.gen"
cp -a "$SRC/config/base-rootfs-overlay/." "$BASE_ROOTFS/"
# The overlay comes from a Windows working copy, so force sane permissions.
# nyx-updates, nyx-rollback and nyx-apply-wallpaper are deliberately not in this
# list: they belong to the nyx-tools package now, and having them in two places
# would mean two sources of truth.
for helper in update-arch-limine nyx-configure-bootloader update-nyx-os-release; do
    install -Dm0755 "$SRC/config/base-rootfs-overlay/usr/local/sbin/$helper" \
        "$BASE_ROOTFS/usr/local/sbin/$helper"
done
install -Dm0755 "$SRC/config/base-rootfs-overlay/usr/local/sbin/nyx-update-git" \
    "$BASE_ROOTFS/usr/local/sbin/nyx-update-git"
# The kernel command line helper. Both bootloader writers refuse to run without
# it, so a missing execute bit here would break the installer rather than just
# one bootloader: cp -a carries whatever mode came from the working copy.
install -Dm0755 "$SRC/config/base-rootfs-overlay/usr/local/lib/nyx/boot-params" \
    "$BASE_ROOTFS/usr/local/lib/nyx/boot-params"
# The login greeting hook. It has to be readable and sourced rather than
# executed, and the overlay arrives from a working copy, so state the mode.
install -Dm0644 "$SRC/config/base-rootfs-overlay/etc/profile.d/nyx-greeting.sh" \
    "$BASE_ROOTFS/etc/profile.d/nyx-greeting.sh"
install -d -m 0755 "$BASE_ROOTFS/etc/nyx"
cat >"$BASE_ROOTFS/etc/nyx/kernel-params" <<'EOF'
# Nyx kernel parameters, appended after the ones the bootloader cannot boot
# without. Managed by nyx-tweaks; edit it by hand only if you know why.
#
# One parameter per line. Comments and blank lines are ignored. Everything here
# applies to Limine, systemd-boot and GRUB alike, and takes effect on the next
# boot.
EOF
chmod 0644 "$BASE_ROOTFS/etc/nyx/kernel-params"

# The installed system's own Nyx repository starts out holding the package built
# into the ISO. nyx-update-git appends newer builds to the same directory, which
# is what makes nyx-updates report them alongside ordinary Arch updates.
install -d -m 0755 "$BASE_ROOTFS/var/cache/nyx-repo"
install -m 0644 "${nyx_tools_packages[0]}" "$BASE_ROOTFS/var/cache/nyx-repo/"
# repo-add insists on a full archive extension. One database serves both the
# package from the ISO and every later build that nyx-update-git appends.
repo-add --quiet "$BASE_ROOTFS/var/cache/nyx-repo/nyx.db.tar.zst" \
    "$BASE_ROOTFS/var/cache/nyx-repo"/*.pkg.tar.zst
install -Dm0644 "$SRC/config/base-rootfs-overlay/etc/pacman.d/mirrorlist" \
    "$BASE_ROOTFS/etc/pacman.d/mirrorlist"
install -Dm0644 "$SRC/config/base-rootfs-overlay/etc/pacman.d/hooks/99-arch-limine.hook" \
    "$BASE_ROOTFS/etc/pacman.d/hooks/99-arch-limine.hook"
install -Dm0644 "$SRC/config/base-rootfs-overlay/etc/pacman.d/hooks/99-nyx-os-release.hook" \
    "$BASE_ROOTFS/etc/pacman.d/hooks/99-nyx-os-release.hook"
install -Dm0644 "$SRC/config/limine-bg.png" \
    "$BASE_ROOTFS/usr/share/arch-custom/limine-bg.png"

# Desktop background for the installed system. The image goes to the canonical
# /usr/share/backgrounds path, and a Plasma wallpaper package makes it show up
# in the wallpaper chooser by name. Setting it as the default is done by
# /usr/local/bin/nyx-apply-wallpaper on first login rather than by seeding
# plasma-org.kde.plasma.desktop-appletsrc, which is version-specific.
install -Dm0644 "$SRC/config/nyx-wallpaper.jpg" \
    "$BASE_ROOTFS/usr/share/backgrounds/nyx.jpg"
install -d -m 0755 "$BASE_ROOTFS/usr/share/wallpapers/nyx"
install -Dm0644 "$SRC/config/wallpaper-metadata.json" \
    "$BASE_ROOTFS/usr/share/wallpapers/nyx/metadata.json"
install -Dm0644 "$SRC/config/nyx-wallpaper.jpg" \
    "$BASE_ROOTFS/usr/share/wallpapers/nyx/contents.jpg"
install -d -m 0755 "$BASE_ROOTFS/etc/skel/.config/fastfetch"
cp -a "$SRC/config/fastfetch/." "$BASE_ROOTFS/etc/skel/.config/fastfetch/"
install -m 0644 "$SRC/config/fastfetch/nyarch.jsonc" \
    "$BASE_ROOTFS/etc/skel/.config/fastfetch/config.jsonc"

# The default fastfetch preset starts with the "title" module, which prints
# user@host. Calamares' hostname module is in SKIP_MODULES, so nothing sets the
# name on the installed system and it would keep the base default of "localhost".
printf 'nyx\n' >"$BASE_ROOTFS/etc/hostname"
chmod 0644 "$BASE_ROOTFS/etc/hostname"

# Enable the update reporter for every desktop session. It is a *user* timer
# because notify-send has to reach the running graphical session. The unit
# itself arrives with the nyx-tools package, so the symlink is written directly
# instead of through "systemctl --root --global enable", which would need the
# unit to be installed already at build time.
install -d -m 0755 "$BASE_ROOTFS/etc/systemd/user/timers.target.wants"
ln -sfn /usr/lib/systemd/user/nyx-updates.timer \
    "$BASE_ROOTFS/etc/systemd/user/timers.target.wants/nyx-updates.timer"

# Calamares executes pacman in a chroot where systemd-resolved is not running.
# Use temporary public resolvers during installation; the shell process restores
# the normal systemd-resolved symlink after packages have been installed.
rm -f "$BASE_ROOTFS/etc/resolv.conf"
cat >"$BASE_ROOTFS/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
options timeout:2 attempts:2
EOF

keyring_pkg=""
for candidate in \
    "$SRC/vendor/cachyos-keyring-20240331-1-any.pkg.tar.zst" \
    "$SRC/cachyos-keyring-20240331-1-any.pkg.tar.zst"
do
    if [[ -f "$candidate" ]]; then
        keyring_pkg="$candidate"
        break
    fi
done
[[ -n "$keyring_pkg" ]] || die "CachyOS keyring package not found under vendor/ or the project root."

for key_file in cachyos.gpg cachyos-trusted cachyos-revoked; do
    bsdtar -xf "$keyring_pkg" -C "$BASE_ROOTFS" \
        "usr/share/pacman/keyrings/${key_file}"
done
chown -R root:root "$BASE_ROOTFS/usr/share/pacman/keyrings"
chmod 0644 "$BASE_ROOTFS"/usr/share/pacman/keyrings/cachyos*

rm -rf -- "$BASE_ROOTFS/var/cache/pacman/pkg"/*
rm -f -- "$BASE_ROOTFS"/var/lib/pacman/sync/*
rm -f -- "$BASE_ROOTFS/etc/machine-id"
find "$BASE_ROOTFS/var/log" -mindepth 1 -type f -delete
mksquashfs "$BASE_ROOTFS" "$BASE_SQUASHFS" -noappend -comp gzip -quiet
info "Base rootfs image: $(du -h "$BASE_SQUASHFS" | awk '{print $1}')"

log "Preparing the archiso profile"
rm -rf -- "$ARCHISO_SRC" "$PROFILE"
install -d -m 0755 "$ARCHISO_SRC" "$PROFILE"
tar -xzf "$SRC/vendor/archiso-v90.tar.gz" --strip-components=1 -C "$ARCHISO_SRC"
# Copy the contents of releng/ into the profile itself; airootfs/ and efiboot/
# must be top-level entries of the profile directory.
cp -a "$ARCHISO_SRC/configs/releng/." "$PROFILE/"
[[ -d "$AIROOTFS" ]] || die "archiso releng profile layout is unexpected: $AIROOTFS is missing."
[[ -d "$PROFILE/efiboot" ]] || die "archiso releng profile layout is unexpected: $PROFILE/efiboot is missing."
install -m 0644 "$SRC/config/packages.live.x86_64" "$PROFILE/packages.x86_64"

# releng's systemd-boot entries are titled "Arch Linux install medium", which is
# the first thing anyone sees on the machine. Retitle them for Nyx Linux. Only
# the title changes: the options lines carry archisosearchuuid and the other
# archiso parameters, and those must stay untouched.
for entry in "$PROFILE"/efiboot/loader/entries/*.conf; do
    [[ -f "$entry" ]] || continue
    case "$(basename "$entry")" in
        01-*) sed -i 's|^title .*|title    Nyx Linux (x86_64, UEFI)|'                  "$entry" ;;
        02-*) sed -i 's|^title .*|title    Nyx Linux (x86_64, UEFI) with speech|'       "$entry" ;;
        03-*) sed -i 's|^title .*|title    Memtest86+ (memory test)|'                   "$entry" ;;
    esac
done
if grep -rqs '^title .*Arch Linux' "$PROFILE/efiboot/loader/entries/"; then
    die "an ISO boot entry still advertises 'Arch Linux' in its title."
fi

cat >"$PROFILE/profiledef.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2034
iso_name="nyx-linux-cachyos-calamares"
iso_label="NYX_LINUX_CACHYOS"
iso_publisher="Nyx Linux Project"
iso_application="Nyx Linux Live/Rescue with Calamares"
iso_version="2026.09.01-nyx.1"
install_dir="arch"
buildmodes=('iso')
bootmodes=('uefi.systemd-boot')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86,arm64' '-b' '1M' '-Xdict-size' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
  ["/etc/sudoers.d/archiso"]="0:0:440"
  ["/etc/sddm.conf.d/autologin.conf"]="0:0:644"
  # mkarchiso copies the profile with --no-preserve=mode, so every mode set by
  # install -m is discarded on the way into the pacstrap dir. Anything that must
  # keep a specific mode has to be re-applied here.
  ["/etc/motd"]="0:0:644"
  ["/etc/hostname"]="0:0:644"
  ["/etc/systemd/system/getty@tty1.service.d/autologin.conf"]="0:0:644"
  ["/usr/local/sbin/update-nyx-os-release"]="0:0:755"
  ["/usr/share/arch-custom/live-setup.sh"]="0:0:755"
)
EOF

install -m 0644 "$SRC/config/live-pacman.conf" "$PROFILE/pacman.conf"
python - "$PROFILE/pacman.conf" "$LOCAL_REPO" <<'PY'
from pathlib import Path
import re
import sys

config = Path(sys.argv[1])
local_repo = Path(sys.argv[2]).resolve()
text = config.read_text()

# The live image must read the Nyx repository from the build-time directory,
# while the installed system keeps /var/cache/nyx-repo. Both come from the same
# source file, so only the Server line inside the [nyx] section is rewritten,
# and only for the live profile.
text, n = re.subn(
    r"(\[nyx\][^\[]*?Server\s*=\s*)file://[^\s]*",
    lambda m: m.group(1) + f"file://{local_repo}",
    text,
    count=1,
    flags=re.S,
)
if n != 1:
    print("WARNING: no [nyx] Server line was rewritten", file=sys.stderr)
config.write_text(text)
PY

for key_file in cachyos.gpg cachyos-trusted cachyos-revoked; do
    bsdtar -xf "$keyring_pkg" -C "$AIROOTFS" \
        "usr/share/pacman/keyrings/${key_file}"
done

# The live airootfs is about to receive the filesystem package, which owns
# /usr/lib/os-release. Writing it now would abort the whole transaction with
# "conflicting files", so stage only the template; the pacman hook applies the
# branding right after the transaction completes.
stage_nyx_os_release "$AIROOTFS"

install -Dm0644 "$SRC/config/live-pacman.conf" \
    "$AIROOTFS/usr/share/arch-custom/pacman.conf"
# archiso's mkarchiso never creates accounts, and releng's profile lists only
# root, so the live session used to have no user to log into: SDDM's autologin
# pointed at nobody and Calamares never started. config/live-setup.sh runs from
# the pacman hook and creates the account with useradd --create-home, which also
# pulls /etc/skel (the fastfetch presets and the installer launcher) into the
# home directory.
install -Dm0755 "$SRC/config/live-setup.sh" \
    "$AIROOTFS/usr/share/arch-custom/live-setup.sh"
install -Dm0644 "$SRC/config/motd" \
    "$AIROOTFS/etc/motd"
printf 'nyx\n' >"$AIROOTFS/etc/hostname"
install -Dm0644 "$SRC/config/locale.gen" \
    "$AIROOTFS/usr/share/arch-custom/locale.gen"
install -Dm0644 "$SRC/config/profile-hook" \
    "$AIROOTFS/etc/pacman.d/hooks/99-private-arch.hook"
install -Dm0644 "$SRC/config/profile-kernel.hook" \
    "$AIROOTFS/etc/pacman.d/hooks/98-private-kernel.hook"
install -Dm0755 "$SRC/config/base-rootfs-overlay/usr/local/sbin/update-nyx-os-release" \
    "$AIROOTFS/usr/local/sbin/update-nyx-os-release"
install -Dm0644 "$SRC/config/base-rootfs-overlay/etc/pacman.d/hooks/99-nyx-os-release.hook" \
    "$AIROOTFS/etc/pacman.d/hooks/99-nyx-os-release.hook"
install -Dm0644 "$SRC/config/sddm-autologin.conf" \
    "$AIROOTFS/etc/sddm.conf.d/autologin.conf"
install -Dm0440 "$SRC/config/sudoers-archiso" \
    "$AIROOTFS/etc/sudoers.d/archiso"
install -Dm0644 "$SRC/config/calamares-autostart.desktop" \
    "$AIROOTFS/etc/xdg/autostart/calamares.desktop"
install -Dm0644 "$SRC/config/calamares-desktop.desktop" \
    "$AIROOTFS/etc/skel/Desktop/Install Nyx Linux.desktop"
install -Dm0644 "$SRC/config/limine-bg.png" \
    "$AIROOTFS/usr/share/arch-custom/limine-bg.png"
install -d -m 0755 "$AIROOTFS/etc/skel/.config/fastfetch"
cp -a "$SRC/config/fastfetch/." "$AIROOTFS/etc/skel/.config/fastfetch/"
install -m 0644 "$SRC/config/fastfetch/nyarch.jsonc" \
    "$AIROOTFS/etc/skel/.config/fastfetch/config.jsonc"
install -d -m 0755 "$AIROOTFS/usr/share/arch-custom/calamares"
cp -a "$SRC/config/calamares/." "$AIROOTFS/usr/share/arch-custom/calamares/"

# archiso ships this file autologging in as root. Log in as the live user
# instead, so the console matches the graphical session and the MOTD is the
# Nyx one. Dropping it (as an earlier revision did) left a login prompt for an
# account that does not exist, which made the installer unreachable.
install -Dm0644 "$SRC/config/getty-autologin.conf" \
    "$AIROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf"
ln -sfn /usr/lib/systemd/system/sddm.service \
    "$AIROOTFS/etc/systemd/system/display-manager.service"

# Use NetworkManager in the live desktop instead of archiso's systemd-networkd.
rm -f \
    "$AIROOTFS/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
    "$AIROOTFS/etc/systemd/system/dbus-org.freedesktop.network1.service" \
    "$AIROOTFS/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" \
    "$AIROOTFS/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service"
install -d -m 0755 "$AIROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/NetworkManager.service \
    "$AIROOTFS/etc/systemd/system/multi-user.target.wants/NetworkManager.service"

install -d -m 0755 "$AIROOTFS/usr/share/archlive"
install -m 0644 "$BASE_SQUASHFS" \
    "$AIROOTFS/usr/share/archlive/base-rootfs.squashfs"

while IFS= read -r boot_config; do
    sed -i \
        -e 's/vmlinuz-linux/vmlinuz-linux-cachyos/g' \
        -e 's/initramfs-linux\.img/initramfs-linux-cachyos.img/g' \
        -e '/^options / s/$/ cow_spacesize=4G/' \
        "$boot_config"
done < <(find "$PROFILE/efiboot" -type f -name '*.conf' -print)

info "Boot entries now reference linux-cachyos."
grep -R -m1 --line-number 'vmlinuz-linux-cachyos' "$PROFILE/efiboot" || true

log "Validating generated configuration"
python - "$SRC/config/calamares" <<'PY'
from pathlib import Path
import sys
import yaml

root = Path(sys.argv[1])
for path in sorted(list(root.rglob("*.conf")) + list(root.rglob("*.desc"))):
    with path.open("r", encoding="utf-8") as stream:
        yaml.safe_load(stream)
    print(f"YAML OK: {path.relative_to(root)}")
PY

for helper in update-arch-limine nyx-configure-bootloader update-nyx-os-release; do
    bash -n "$SRC/config/base-rootfs-overlay/usr/local/sbin/$helper"
done
bash -n "$SRC/build.sh"

log "Building the ISO"
install -d -m 0755 "$WORK_DIR" "$PROFILE_OUT"
# $RELEASE uses the dotted form (2026.09.01); date(1) needs the dashed ISO form.
SOURCE_DATE_EPOCH="$(date --date="${RELEASE//./-} 17:22:00 UTC" +%s)"
export SOURCE_DATE_EPOCH
mkarchiso -v -w "$WORK_DIR" -o "$PROFILE_OUT" "$PROFILE"

mapfile -t built_isos < <(find "$PROFILE_OUT" -maxdepth 1 -type f -name '*.iso' -print)
(( ${#built_isos[@]} == 1 )) || die "Expected one built ISO, found ${#built_isos[@]}."
BUILT_ISO="${built_isos[0]}"

log "Checking ISO contents"
MOUNT_DIR="$(mktemp -d /tmp/arch-iso-check.XXXXXX)"
mount -o loop,ro "$BUILT_ISO" "$MOUNT_DIR"
ISO_MOUNTED=1

kernel_check="$(mktemp)"
find "$MOUNT_DIR/arch" -type f -name 'vmlinuz-linux-cachyos' -print -quit >"$kernel_check"
[[ -s "$kernel_check" ]] || die "CachyOS kernel is missing from the ISO."
rm -f "$kernel_check"

# archiso v90 names the live image airootfs.sfs and places it under $install_dir/$arch.
ISO_SQUASHFS="$(find "$MOUNT_DIR/arch" -type f -name 'airootfs.sfs' -print -quit)"
[[ -n "$ISO_SQUASHFS" ]] || die "airootfs.sfs is missing from the ISO."

listing="$(mktemp)"
unsquashfs -ll "$ISO_SQUASHFS" >"$listing"
for required in \
    'usr/bin/calamares' \
    'etc/calamares/settings.conf' \
    'packagechooser' \
    'base-rootfs.squashfs' \
    'cachyos.gpg'
do
    grep -F -- "$required" "$listing" >/dev/null || die "Missing from the live image: $required"
done
rm -f "$listing"

# A live image without an account is unusable: tty1 asks for a login, SDDM's
# autologin points at a user that does not exist, and the installer never
# starts. Assert the account and the skel population directly.
live_passwd="$(unsquashfs -cat "$ISO_SQUASHFS" etc/passwd 2>/dev/null || true)"
if grep -q '^archiso:' <<<"$live_passwd"; then
    info "Live account: archiso (uid $(cut -d: -f3 <<<"$(grep '^archiso:' <<<"$live_passwd")"))"
else
    die "The live image has no 'archiso' account; the installer would be unreachable."
fi
if unsquashfs -cat "$ISO_SQUASHFS" etc/skel/.config/fastfetch/config.jsonc >/dev/null 2>&1; then
    info "Live skel carries the fastfetch presets"
else
    die "The live skel is missing the fastfetch presets."
fi

base_listing="$(mktemp)"
unsquashfs -ll "$BASE_SQUASHFS" >"$base_listing"
for required in \
    'usr/bin/pacman' \
    'usr/local/sbin/update-arch-limine' \
    'usr/local/sbin/nyx-configure-bootloader' \
    'usr/local/sbin/nyx-update-git' \
    'usr/local/lib/nyx/boot-params' \
    'etc/profile.d/nyx-greeting.sh' \
    'etc/nyx/kernel-params' \
    'var/cache/nyx-repo/nyx.db.tar.zst' \
    'var/cache/nyx-repo/nyx-tools' \
    'etc/systemd/user/timers.target.wants/nyx-updates.timer' \
    'usr/share/backgrounds/nyx.jpg' \
    'usr/share/wallpapers/nyx/metadata.json' \
    'usr/share/wallpapers/nyx/contents.jpg' \
    'etc/skel/.config/autostart/nyx-wallpaper.desktop' \
    'etc/pacman.d/mirrorlist' \
    'etc/skel/.config/fastfetch/config.jsonc' \
    'etc/skel/.config/fastfetch/arch.jsonc' \
    'etc/skel/.config/fastfetch/nyarch.ascii' \
    'etc/skel/.config/fastfetch/nyarch.jsonc' \
    'etc/hostname' \
    'usr/share/arch-custom/nyx-os-release'
do
    grep -F -- "$required" "$base_listing" >/dev/null || die "Missing from the target rootfs: $required"
done
rm -f "$base_listing"

umount "$MOUNT_DIR"
ISO_MOUNTED=0
rm -rf -- "$MOUNT_DIR"
MOUNT_DIR=""

log "Copying the result to the host project"
FINAL_ISO="$SOURCE_DIR/out/$FINAL_NAME"
install -m 0644 "$BUILT_ISO" "$FINAL_ISO"
(
    cd "$SOURCE_DIR/out"
    sha256sum "$FINAL_NAME" >"$FINAL_NAME.sha256"
)

info "ISO: $FINAL_ISO"
info "SHA-256: $(cut -d' ' -f1 "$FINAL_ISO.sha256")"
info "Build log: $LOG_FILE"

if [[ "$KEEP_BUILD" != "1" ]]; then
    log "Removing temporary VM build data"
    cd /
    rm -rf -- "$BUILD_ROOT"
else
    info "KEEP_BUILD=1: $BUILD_ROOT"
fi

printf '\n\033[1;32mBuild completed successfully.\033[0m\n'
printf 'Write the ISO to a USB stick or attach it to a UEFI VM to test it.\n'
