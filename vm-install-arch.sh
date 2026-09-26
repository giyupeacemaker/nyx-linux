#!/usr/bin/env bash
# Install Arch Linux onto the Nyx build VM from the official live ISO.
#
# Run from the LIVE session of the nyx-build VM:
#   bash vm-install-arch.sh
#
# Uses the interactive archinstall TUI (the scripted JSON profile is no longer
# reliable because archinstall's config schema has changed). Everything is
# logged to /root/nyx-install.log so failures can be copied out.
set -Eeuo pipefail

LOG=/root/nyx-install.log
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "==> nyx build VM installer, log: $LOG"
echo

# --- sanity checks ---------------------------------------------------------
if [[ ! -d /run/archiso/bootmnt ]]; then
    echo "ERROR: this does not look like the Arch live ISO session." >&2
    echo "Boot archlinux-2026.09.01-x86_64.iso in UEFI mode and try again." >&2
    exit 1
fi

lsblk -dno NAME,SIZE,MODEL | sed 's/^/  /'
echo

if ! command -v archinstall >/dev/null 2>&1; then
    echo "==> archinstall is not present, installing it"
    pacman -Sy --needed --noconfirm archinstall
fi
archinstall --version || true
echo

cat <<'EOF'
================================================================
 Choose these options in the archinstall TUI:

   Locale ................ en_US.UTF-8
   Keyboard layout ....... us
   Mirrors ............... use the geo mirror, keep defaults
   Disk configuration ... Use a best-effort filesystem layout
                          (or manual: /boot 1GiB EFI, / rest ext4)
   Disk encryption ....... No encryption
   Swap .................. zram
   Kernel ................ linux + linux-firmware
   Network ............... NetworkManager
   Root password ........ arch
   User .................. nyx / arch, in group "wheel", sudo: yes
   Profile ............... Minimal / (do not pick a desktop)
   Optional packages .... virtualbox-guest-utils-nox
   Services ............. NetworkManager, sshd
   Time .................. UTC
   Kernel install ....... yes
   First boot ........... GRUB (default is fine; the host ISO stays UEFI)
================================================================
EOF
echo
read -r -p "Press Enter to start archinstall (or Ctrl-C to abort)... " _
echo
echo "==> starting archinstall"
archinstall
status=$?

echo
echo "==> archinstall exited with status $status"
if (( status != 0 )); then
    echo "Installation did NOT complete. The full log is at $LOG" >&2
    exit "$status"
fi

cat <<'EOF'

============================================================
 Arch installed. Now:

 1. Eject archlinux-2026.09.01-x86_64.iso from VirtualBox
    (right click the disc -> Eject) BEFORE rebooting.
 2. Reboot the VM.
 3. Log in as nyx / arch, then:

    sudo pacman -Syu --needed virtualbox-guest-utils-nox
    sudo modprobe vboxsf
    sudo mkdir -p /mnt/project
    sudo mount -t vboxsf archcustom /mnt/project
    cd /mnt/project
    df -h /            # need ~45 GiB free
    sudo env KEEP_BUILD=1 JOBS=4 bash build.sh
============================================================
EOF
