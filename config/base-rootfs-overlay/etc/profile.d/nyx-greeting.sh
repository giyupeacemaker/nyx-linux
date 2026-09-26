# Nyx login greeting: the offline notice, then the two things worth knowing
# right away — the kernel you are running versus the one installed, and what
# changed in Nyx itself.
#
# Guarded three ways, because /etc/profile.d is sourced by every login shell and
# by the display manager, and a greeting that costs a network round trip on each
# one would be worse than no greeting:
#
#   1. only once per session, via a marker in the runtime directory
#   2. never over ssh, where the same text would scroll away on every new shell
#   3. nyx-motd itself fails silently and never exits non-zero
#
# shellcheck shell=bash
# This file is sourced, never executed, so it has no shebang on purpose. Bash is
# the right dialect to declare: on Arch /bin/sh is bash, and both the login shell
# and the display manager source /etc/profile through it.

# The runtime directory is the right place for the marker: it is per user and
# per session, so the next login greets again without anything having to clean
# up, and two terminals opened at once do not both print.
#
# The marker is deliberately NOT removed afterwards. An earlier version removed
# it from an EXIT trap, which meant the marker was gone before the second shell
# started and the greeting printed on every single one — the exact thing the
# marker exists to prevent.
if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "${XDG_RUNTIME_DIR:-}" ]]; then
    _nyx_greeted="${XDG_RUNTIME_DIR}/nyx-greeted"
else
    # No runtime directory. /tmp is usually a tmpfs, so the boot id in the name
    # makes this per boot without needing a cleanup path either.
    _nyx_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
    _nyx_greeted="/tmp/nyx-greeted-${UID:-0}-${_nyx_boot}"
fi

if [[ -z "${SSH_CONNECTION:-}" && ! -r "${_nyx_greeted}" ]] \
   && [[ -x /usr/local/sbin/nyx-motd ]]; then
    # Marked before running, so a re-entrant shell cannot print it twice.
    : >"${_nyx_greeted}" 2>/dev/null || true
    /usr/local/sbin/nyx-motd 2>/dev/null || true
fi
unset _nyx_greeted _nyx_boot
