#!/usr/bin/env bash
# Live-environment setup for the Nyx Linux ISO, run from a pacman PostTransaction
# hook (see config/profile-hook).
#
# pacman keeps only ONE Exec line per hook: a second one silently replaces the
# first. Everything therefore has to live in this single script, otherwise one
# task quietly cancels the other.
#
# Jobs, in order:
#   1. private pacman.conf and locale.gen
#   2. the Calamares configuration tree
#   3. the live account, which archiso's mkarchiso never creates
set -euo pipefail

readonly ARCH_CUSTOM=/usr/share/arch-custom
readonly LIVE_USER=archiso
readonly LIVE_UID=1000
readonly LIVE_GID=1000
readonly LIVE_PASSWORD=archiso
readonly LIVE_GROUPS=(wheel audio video storage network lp adm input power)

# --- 1. private pacman configuration ---------------------------------------
install -Dm0644 "$ARCH_CUSTOM/pacman.conf" /etc/pacman.conf
install -Dm0644 "$ARCH_CUSTOM/locale.gen" /etc/locale.gen

# --- 2. Calamares configuration --------------------------------------------
install -d -m 0755 /etc/calamares
cp -a "$ARCH_CUSTOM/calamares/." /etc/calamares/

# --- 3. the live account ----------------------------------------------------
# Without this the ISO has nobody to log in as: tty1 asks for credentials, SDDM's
# autologin points at a user that does not exist, and the installer never starts.
# useradd --create-home also copies /etc/skel, which is how the fastfetch presets
# and the "Install Nyx Linux" launcher end up in the home directory.
if ! getent group "$LIVE_GID" >/dev/null; then
    groupadd --gid "$LIVE_GID" "$LIVE_USER"
fi

if ! getent passwd "$LIVE_USER" >/dev/null; then
    useradd \
        --create-home \
        --uid "$LIVE_UID" \
        --gid "$LIVE_GID" \
        --shell /bin/bash \
        --comment "Nyx Linux live user" \
        "$LIVE_USER"
fi

printf '%s:%s\n' "$LIVE_USER" "$LIVE_PASSWORD" | chpasswd
usermod --shell /bin/bash "$LIVE_USER"
usermod -a -G "$(IFS=,; printf '%s' "${LIVE_GROUPS[*]}")" "$LIVE_USER"

# NOPASSWD sudo ships in /etc/sudoers.d/archiso; the installer autostart runs
# "sudo -n calamares", so it has to be there. Create the directory as well: the
# build installs the file only into the live airootfs, and a missing directory
# makes the redirect fail, which under 'set -e' would abort the whole hook.
install -d -m 0755 /etc/sudoers.d
if ! grep -q '^archiso ALL=' /etc/sudoers.d/archiso 2>/dev/null; then
    printf 'archiso ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/archiso
fi
chmod 0440 /etc/sudoers.d/archiso

printf 'Nyx live-setup: account %s ready, calamares config in place.\n' "$LIVE_USER"
