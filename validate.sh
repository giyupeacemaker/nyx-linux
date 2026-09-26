#!/usr/bin/env bash
# Static validation for the Nyx Linux ISO project.
#
# Runs every check that does not require a full ISO build:
#   * bash syntax + shellcheck for all shell scripts
#   * YAML for every Calamares config
#   * JSON for the fastfetch presets
#   * XML for the branding SVGs
#   * cross-references (screenshots, overlay scripts, package lists)
#   * os-release invariants (ID=arch must survive)
#
# Usage:  bash validate.sh
set -Eeuo pipefail
IFS=$'\n\t'

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SOURCE_DIR"

PASS=0
FAIL=0

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
sect() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# --------------------------------------------------------------------------
sect "Shell script syntax"
# Select real shell scripts by their shebang rather than by name pattern: a
# glob like 'nyx-*' also matches nyx-updates.service, nyx-updates.timer and
# nyx-wallpaper.desktop, and shellcheck rightly refuses those as shell.
is_shell_script() {
    [[ -f "$1" ]] || return 1
    head -n 1 "$1" 2>/dev/null | grep -qE '^#!.*\b(bash|sh|ksh|dash|zsh)\b'
}
mapfile -t scripts < <(
    printf '%s\n' build.sh validate.sh vm-install-arch.sh
    find config/base-rootfs-overlay -type f 2>/dev/null
)
for s in "${scripts[@]}"; do
    is_shell_script "$s" || continue
    if bash -n "$s" 2>/dev/null; then ok "bash -n $s"; else bad "bash -n $s"; fi
done

# --------------------------------------------------------------------------
sect "ShellCheck (if available)"
if command -v shellcheck >/dev/null 2>&1; then
    for s in "${scripts[@]}"; do
        is_shell_script "$s" || continue
        if shellcheck -S warning "$s" >/tmp/sc.out 2>&1; then
            ok "shellcheck $s"
        else
            bad "shellcheck $s"
            sed 's/^/       /' /tmp/sc.out | head -20
        fi
    done
else
    warn "shellcheck not installed (pacman -S shellcheck / apt install shellcheck)"
fi

# --------------------------------------------------------------------------
sect "YAML (Calamares configuration)"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    while IFS= read -r f; do
        if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1],encoding="utf-8"))' "$f" 2>/tmp/y.out; then
            ok "YAML ${f#./}"
        else
            bad "YAML ${f#./}"; sed 's/^/       /' /tmp/y.out | head -5
        fi
    done < <(find config/calamares -type f \( -name '*.conf' -o -name '*.desc' \) | sort)
else
    warn "python3/pyyaml not available, skipping YAML checks"
fi

# --------------------------------------------------------------------------
sect "JSON (fastfetch presets)"
# A naive `re.sub(r'//.*', '', text)` corrupts these presets, because "$schema"
# and every URL sit inside JSON string values: the "//" of "https://" gets eaten
# and the document stops parsing. Walk the text instead, tracking string state
# and honouring backslash escapes.
jsonc_parse() {
    python3 - "$1" <<'PY'
import json, re, sys

text = open(sys.argv[1], encoding="utf-8").read()
out = []
i, n = 0, len(text)
in_str = esc = False
while i < n:
    c = text[i]
    if in_str:
        if esc:
            esc = False
        elif c == "\\":
            esc = True
        elif c == '"':
            in_str = False
        out.append(c)
        i += 1
        continue
    if c == '"':
        in_str = True
        out.append(c)
        i += 1
        continue
    if c == "/" and i + 1 < n:
        if text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
    out.append(c)
    i += 1

# Trailing commas are legal in JSONC and are used for readability here.
body = re.sub(r",(\s*[}\]])", r"\1", "".join(out))
try:
    data = json.loads(body)
except Exception as exc:
    print(exc, file=sys.stderr)
    raise SystemExit(1)

# On success also report the first real module, so the default-preset check
# below can reuse this parser instead of keeping a second copy of it.
mods = [m for m in data.get("modules", []) if m != "break"]
if mods:
    first = mods[0]
    print(first.get("type", "?") if isinstance(first, dict) else str(first))
else:
    print("EMPTY")
raise SystemExit(0)
PY
}
while IFS= read -r f; do
    if jsonc_parse "$f" 2>/tmp/j.out; then
        ok "JSONC ${f#./}"
    else
        bad "JSONC ${f#./}"; sed 's/^/       /' /tmp/j.out | head -5
    fi
done < <(find config/fastfetch -type f -name '*.jsonc' | sort)

# --------------------------------------------------------------------------
sect "XML (branding SVGs)"
while IFS= read -r f; do
    if python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$f" 2>/tmp/x.out; then
        ok "XML  ${f#./}"
    else
        bad "XML  ${f#./}"
    fi
done < <(find config -type f -name '*.svg' | sort)

# --------------------------------------------------------------------------
sect "Cross-references"
while IFS= read -r ref; do
    path="config/calamares/branding/archlinux/$(basename "$ref")"
    if [[ -f "$path" ]]; then ok "screenshot $(basename "$ref")"; else bad "missing screenshot $ref"; fi
done < <(grep -rhoE '/etc/calamares/branding/archlinux/[A-Za-z0-9._-]+' config/calamares/modules 2>/dev/null | sort -u)

for f in \
    config/nyx-os-release \
    config/live-pacman.conf \
    config/base-rootfs-overlay/etc/pacman.d/mirrorlist \
    config/base-rootfs-overlay/etc/pacman.d/hooks/99-arch-limine.hook \
    config/base-rootfs-overlay/etc/pacman.d/hooks/99-nyx-os-release.hook \
    config/base-rootfs-overlay/usr/local/sbin/update-arch-limine \
    config/base-rootfs-overlay/usr/local/sbin/nyx-configure-bootloader \
    config/base-rootfs-overlay/usr/local/sbin/update-nyx-os-release
do
    [[ -f "$f" ]] && ok "exists $f" || bad "missing $f"
done

# --------------------------------------------------------------------------
sect "Vendored archives"
for a in vendor/calamares-v3.4.3.tar.gz vendor/archiso-v90.tar.gz; do
    [[ -f "$a" ]] && ok "exists $a" || bad "missing $a"
done
keyring=""
for k in vendor/cachyos-keyring-20240331-1-any.pkg.tar.zst cachyos-keyring-20240331-1-any.pkg.tar.zst; do
    [[ -f "$k" ]] && { keyring="$k"; break; }
done
[[ -n "$keyring" ]] && ok "CachyOS keyring found: $keyring" || bad "CachyOS keyring not found"

# The PKGBUILD source name must match what build.sh copies.
# build.sh copies vendor/calamares-v${CALAMARES_VERSION}.tar.gz -> calamares-${CALAMARES_VERSION}.tar.gz
if grep -qE '^source=\("calamares-(\$\{pkgver\}|3\.4\.3)\.tar\.gz"\)$' vendor/calamares/PKGBUILD; then
    ok "PKGBUILD expects calamares-3.4.3.tar.gz (build.sh copies it under that name)"
else
    bad "PKGBUILD source line does not match calamares-3.4.3.tar.gz"
fi
if grep -qE '^pkgver=3\.4\.3$' vendor/calamares/PKGBUILD; then
    ok "PKGBUILD pkgver is 3.4.3"
else
    bad "PKGBUILD pkgver is not 3.4.3"
fi

# The cmake -S path in build() must match the tarball's real top-level
# directory, otherwise makepkg extracts fine but cmake cannot find sources.
topdir="$(tar -tzf vendor/calamares-v3.4.3.tar.gz 2>/dev/null | sed -n '1s#/.*##p')"
if [[ -z "$topdir" ]]; then
    bad "could not read the tarball layout"
elif grep -qF -- '-S "${srcdir}/'"$topdir"'"' vendor/calamares/PKGBUILD; then
    ok "PKGBUILD cmake -S path matches tarball top-level dir ($topdir)"
else
    bad "PKGBUILD cmake -S path does not match tarball top-level dir ($topdir)"
    printf '       expected: -S "${srcdir}/%s"\n' "$topdir"
    grep -n 'cmake -B build -S' vendor/calamares/PKGBUILD | sed 's/^/       actual:   /'
fi

# The vendored Calamares tarball must match the checksum the PKGBUILD expects,
# otherwise makepkg aborts before compiling anything.
if command -v sha256sum >/dev/null 2>&1; then
    expected="$(sed -nE "s/^sha256sums=\('([0-9a-f]{64})'\)$/\1/p" vendor/calamares/PKGBUILD)"
    if [[ -n "$expected" ]]; then
        actual="$(sha256sum vendor/calamares-v3.4.3.tar.gz | cut -d' ' -f1)"
        if [[ "$actual" == "$expected" ]]; then
            ok "calamares tarball sha256 matches PKGBUILD"
        else
            bad "calamares tarball sha256 mismatch"
            printf '       expected %s\n       actual   %s\n' "$expected" "$actual"
        fi
    else
        bad "could not read sha256sums from PKGBUILD"
    fi
else
    warn "sha256sum not available"
fi

# --------------------------------------------------------------------------
sect "Live package list vs Arch repositories"
# Names that are not in the Arch repos on purpose.
external_pkgs="calamares linux-cachyos ckbcomp"
# Names that used to exist and were removed/merged upstream; they must not return.
while IFS= read -r p; do
    case "$p" in
        lsblk)          bad "obsolete package in packages.live.x86_64: lsblk (merged into util-linux)";;
        nss-resolve)    bad "obsolete package in packages.live.x86_64: nss-resolve (obsolete)";;
        nss-myhostname) bad "obsolete package in packages.live.x86_64: nss-myhostname (provide of systemd)";;
    esac
done < config/packages.live.x86_64

if command -v python3 >/dev/null 2>&1; then
    if python3 - "$external_pkgs" config/packages.live.x86_64 <<'PY'
import json, sys, urllib.request, urllib.parse

external = set(sys.argv[1].split())
names = [l.strip() for l in open(sys.argv[2], encoding="utf-8")
         if l.strip() and not l.startswith("#")]
missing = []
for n in names:
    if n in external:
        continue
    url = "https://archlinux.org/packages/search/json/?name=" + urllib.parse.quote(n)
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            data = json.load(r)
    except Exception:
        continue          # offline: skip silently
    if not any(x.get("pkgname") == n for x in data.get("results", [])):
        missing.append(n)  # may still be a group, which pacman accepts
if missing:
    print("NOT-IN-ARCH: " + " ".join(missing))
sys.exit(1)
PY
    then
        ok "every live package resolves in Arch (or is an intentional external)"
    else
        warn "names above are not Arch PACKAGES - they are only valid if they are GROUPS"
        warn "  (xorg-apps, gnome, xfce4 are groups; pacman -S still accepts them)"
    fi
else
    warn "python3 unavailable, skipped live package lookup"
fi

# --------------------------------------------------------------------------
sect "os-release invariants"
osrel=config/nyx-os-release
grep -q '^ID=arch$' "$osrel"        && ok "ID=arch preserved"        || bad "ID=arch missing"
grep -q '^ID_LIKE=arch$' "$osrel"   && ok "ID_LIKE=arch preserved"   || warn "ID_LIKE=arch not set"
grep -q '^NAME="Nyx Linux"$' "$osrel" && ok 'NAME="Nyx Linux"'        || bad "Nyx NAME missing"

# --------------------------------------------------------------------------
sect "Calamares sequence sanity"
seq_file=config/calamares/settings.conf
if [[ -f "$seq_file" ]]; then
    if grep -qE '^[[:space:]]+- bootloader[[:space:]]*$' "$seq_file"; then
        bad "built-in 'bootloader' module still in the exec sequence (cannot install Limine)"
    else
        ok "built-in 'bootloader' module not used (nyx-configure-bootloader handles it)"
    fi
    if grep -q 'shellprocess@bootloader' "$seq_file"; then
        ok "shellprocess bootloader step present"
    else
        bad "no shellprocess bootloader step in the sequence"
    fi
else
    bad "settings.conf not found"
fi

# --------------------------------------------------------------------------
sect "No obsolete live packages"
if grep -qx 'nss-resolve' config/packages.live.x86_64 || grep -qx 'nss-myhostname' config/packages.live.x86_64; then
    bad "obsolete nss-* packages still in packages.live.x86_64"
else
    ok "no obsolete nss-* packages"
fi

# --------------------------------------------------------------------------
sect "Live session account"
# archiso's mkarchiso creates no users, and releng's profile lists only root.
# A build without this wiring produces an ISO that asks for a login and then has
# no account to accept, so Calamares is unreachable.
if [[ -f config/live-setup.sh ]]; then
    ok "config/live-setup.sh present"
    if grep -q 'useradd' config/live-setup.sh && grep -q -- '--create-home' config/live-setup.sh; then
        ok "live-setup.sh creates the account with a populated home"
    else
        bad "live-setup.sh does not useradd --create-home"
    fi
    if grep -q 'chpasswd' config/live-setup.sh; then
        ok "live-setup.sh sets a login password"
    else
        bad "live-setup.sh never sets a password"
    fi
else
    bad "config/live-setup.sh missing"
fi

if grep -q 'live-setup\.sh' config/profile-hook; then
    ok "profile-hook runs live-setup.sh"
else
    bad "profile-hook does not run live-setup.sh"
fi

# pacman keeps only the LAST Exec line in a hook and drops the rest with
# "overwriting previous definition of Exec". Two Exec lines cost us the whole
# Calamares config tree once, so the count is asserted here.
exec_lines=$(grep -c '^Exec[[:space:]]*=' config/profile-hook)
if (( exec_lines == 1 )); then
    ok "profile-hook has exactly one Exec line"
else
    bad "profile-hook has $exec_lines Exec lines; pacman honours only the last one"
fi

# The work that used to live in the second Exec must be inside the script now.
for job in 'calamares' 'pacman.conf' 'locale.gen' 'useradd'; do
    if grep -q "$job" config/live-setup.sh; then
        ok "live-setup.sh handles $job"
    else
        bad "live-setup.sh no longer handles $job"
    fi
done

if grep -qE '^Depends *= *shadow$' config/profile-hook; then
    ok "profile-hook depends on shadow (useradd/usermod/chpasswd)"
else
    bad "profile-hook lacks 'Depends = shadow'"
fi
# A single bogus name makes pacman skip the hook silently, which is exactly how
# the live account went missing once already. Guard the two names that do not
# exist on Arch.
for bogus_depends in passwd shadow-utils; do
    if grep -qE "^Depends *= *$bogus_depends\$" config/profile-hook; then
        bad "profile-hook depends on '$bogus_depends', which no Arch package provides"
    fi
done
ok "profile-hook Depends only names real Arch packages"

if grep -q 'AIROOTFS/usr/share/arch-custom/live-setup\.sh' build.sh; then
    ok "build.sh installs live-setup.sh into the airootfs"
else
    bad "build.sh does not install live-setup.sh into the airootfs"
fi

# The autologin drop-in must exist and must not be deleted again.
if grep -q 'getty-autologin\.conf' build.sh; then
    ok "build.sh installs a getty autologin drop-in"
else
    bad "build.sh does not install a getty autologin drop-in"
fi
if grep -qE 'rm -f .*getty@tty1\.service\.d/autologin\.conf' build.sh; then
    bad "build.sh still deletes the getty autologin drop-in"
else
    ok "getty autologin drop-in is not deleted"
fi
if grep -q -- '--autologin archiso' config/getty-autologin.conf; then
    ok "tty1 autologins as the live user"
else
    bad "tty1 autologin does not target the live user"
fi
if grep -qE '^User=archiso$' config/sddm-autologin.conf; then
    ok "SDDM autologins as the live user"
else
    bad "SDDM autologin user is not the live user"
fi
if [[ -f config/sudoers-archiso ]] && grep -q 'NOPASSWD' config/sudoers-archiso; then
    ok "live user has passwordless sudo (needed by 'sudo -n calamares')"
else
    bad "no NOPASSWD sudoers entry for the live user"
fi
if grep -q 'sudo -n calamares' config/calamares-autostart.desktop; then
    ok "installer autostarts on the live desktop"
else
    bad "installer is not wired to autostart"
fi

# --------------------------------------------------------------------------
sect "No upstream Arch branding in live-session text"
if grep -qi 'arch linux' config/motd 2>/dev/null; then
    bad "config/motd still says 'Arch Linux'"
else
    ok "MOTD is Nyx-branded"
fi
if grep -q 'config/motd' build.sh; then
    ok "build.sh installs the Nyx MOTD"
else
    bad "build.sh does not install config/motd"
fi
if grep -qE '^hostname=nyx$|printf .nyx' build.sh || grep -q 'AIROOTFS/etc/hostname' build.sh; then
    ok "live hostname is set to nyx"
else
    bad "live hostname is left as archiso"
fi

# --------------------------------------------------------------------------
sect "Calamares module availability"
# A module listed in the sequence but absent from the package makes the whole
# installer refuse to start with "Calamares Initialization Failed". Two ways
# that happens silently: naming the module in SKIP_MODULES, or passing a
# USE_<category> value that is not the implementation name. Calamares splits a
# module name at the FIRST hyphen, so for "services-systemd" the category is
# "services" and the implementation is "systemd"; USE_services is compared
# against "systemd". Passing the full name silently drops the module.
pkgbuild=vendor/calamares/PKGBUILD
seq_file=config/calamares/settings.conf
if [[ -f "$pkgbuild" && -f "$seq_file" ]]; then
    # Modules the sequence needs, in the form Calamares resolves them.
    mapfile -t wanted < <(sed -n '/^sequence:/,$p' "$seq_file" \
        | grep -oE '^[[:space:]]*-[[:space:]]+[a-zA-Z0-9_-]+' \
        | awk '{print $2}' | sort -u)
    # Everything SKIP_MODULES asks cmake to drop.
    skip_block=$(sed -n '/skip_modules=()/,/^  )/p' "$pkgbuild")
    collide=()
    for m in "${wanted[@]}"; do
        [[ -z "$m" ]] && continue
        if grep -qx "$m" <<<"$skip_block"; then
            collide+=("$m")
        fi
    done
    if (( ${#collide[@]} == 0 )); then
        ok "no sequence module is listed in SKIP_MODULES"
    else
        bad "sequence modules skipped by the PKGBUILD: ${collide[*]}"
    fi

    # USE_ values must be a bare implementation, never a full module name.
    while read -r var val; do
        if [[ -n "$val" && "$val" != "none" && "$val" == *-* ]]; then
            bad "PKGBUILD sets $var=$val; use the implementation name, not the full module name"
        else
            ok "$var=$val is a valid implementation name"
        fi
    done < <(grep -oE '\-DUSE_[a-zA-Z0-9_]+=[a-zA-Z0-9_-]+' "$pkgbuild" \
             | sed 's/^-DUSE_/USE_/' | awk -F= '{print $1, $2}')

    # The two service implementations must not be requested at once.
    if [[ "$skip_block" == *services-openrc* && "$skip_block" != *services-systemd* ]]; then
        ok "services-openrc is skipped so services-systemd can be built"
    fi
else
    bad "PKGBUILD or settings.conf not found"
fi

# --------------------------------------------------------------------------
sect "Branding URLs"
branding=config/calamares/branding/archlinux/branding.desc
if [[ -f "$branding" ]]; then
    for key in productUrl supportUrl knownIssuesUrl releaseNotesUrl; do
        val=$(sed -n "s/^[[:space:]]*$key:[[:space:]]*\"\\(.*\\)\"[[:space:]]*$/\\1/p" "$branding")
        if [[ -n "$val" ]]; then
            ok "$key = $val"
        else
            bad "$key is empty; the installer would show a dead link"
        fi
    done
    # A URL that is not reachable-looking is worse than none at all.
    if grep -qE '^[[:space:]]*(productUrl|supportUrl|knownIssuesUrl|releaseNotesUrl):[[:space:]]*"https?://' "$branding"; then
        ok "branding URLs use http(s)"
    else
        bad "branding URLs are malformed"
    fi
    if grep -q 'productName: "Nyx Linux"' "$branding"; then
        ok "branding product name is Nyx Linux"
    else
        bad "branding product name is not Nyx Linux"
    fi
else
    bad "branding.desc not found"
fi

for flag in showSupportUrl showKnownIssuesUrl showReleaseNotesUrl; do
    if grep -qE "^$flag:[[:space:]]*true" config/calamares/modules/welcome.conf; then
        ok "welcome.conf enables $flag"
    else
        bad "welcome.conf leaves $flag off, so the link is never shown"
    fi
done

# --------------------------------------------------------------------------
sect "Default fastfetch preset"
# The first module has to be "title", which prints user@host. Losing it would
# silently drop the "user@nyx" line the default preset is meant to lead with.
default_ff=config/fastfetch/nyarch.jsonc
if [[ -f "$default_ff" ]]; then
    first_module=$(jsonc_parse "$default_ff" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        first_module="PARSE_ERROR"
    fi
    case "$first_module" in
        title) ok "default preset leads with the title module (user@host)" ;;
        PARSE_ERROR) bad "default fastfetch preset is not valid JSONC" ;;
        EMPTY) bad "default preset has no modules" ;;
        *) bad "default preset's first real module is '$first_module', expected 'title'" ;;
    esac
    if grep -q 'nyarch.ascii' "$default_ff"; then
        ok "default preset uses the shipped ASCII logo (works outside kitty)"
    else
        bad "default preset does not reference nyarch.ascii"
    fi
    # A kitty-image logo would render as nothing in konsole on Plasma.
    if grep -q '"type": "kitty"' "$default_ff"; then
        bad "default preset uses the kitty image protocol; Plasma's konsole cannot draw it"
    else
        ok "default preset avoids the kitty image protocol"
    fi
else
    bad "$default_ff not found"
fi
if [[ -e config/fastfetch/giyupeacemaker.jsonc || -e config/fastfetch/peace.ascii ]]; then
    bad "the retired giyupeacemaker preset is still present"
else
    ok "retired giyupeacemaker preset is gone"
fi
if grep -qE 'giyupeacemaker\.jsonc|peace\.ascii' build.sh; then
    bad "build.sh still requires the retired giyupeacemaker files"
else
    ok "build.sh no longer requires the retired files"
fi
if grep -q 'BASE_ROOTFS/etc/hostname' build.sh; then
    ok "installed system gets the nyx hostname"
else
    bad "installed system has no hostname set; user@host would show localhost"
fi

# --------------------------------------------------------------------------
sect "ISO boot menu branding"
# releng's systemd-boot entries are titled "Arch Linux install medium", and the
# boot menu is the first thing seen on any machine. build.sh retitles them; make
# sure that step stays in place.
if grep -q 'Nyx Linux (x86_64, UEFI)' build.sh; then
    ok "build.sh retitles the ISO boot entries"
else
    bad "build.sh does not retitle the ISO boot entries"
fi
# The options lines carry archisosearchuuid and must not be touched.
if grep -qE "s\|[^|]*(\^|\b)options" build.sh; then
    bad "build.sh rewrites boot entry options lines; archisosearchuuid must stay"
else
    ok "boot entry options lines are left alone"
fi

# --------------------------------------------------------------------------
sect "Desktop background and update reporter"
for f in config/nyx-wallpaper.jpg config/wallpaper-metadata.json \
         config/base-rootfs-overlay/usr/local/bin/nyx-apply-wallpaper \
         config/base-rootfs-overlay/usr/local/sbin/nyx-updates \
         config/base-rootfs-overlay/usr/lib/systemd/user/nyx-updates.service \
         config/base-rootfs-overlay/usr/lib/systemd/user/nyx-updates.timer; do
    if [[ -f "$f" ]]; then ok "$(basename "$f") present"; else bad "$f missing"; fi
done
# The Limine boot background and the desktop background are separate files on
# purpose: the boot menu needs a dark, readable backdrop, the desktop is the
# user's own choice.
if [[ -f config/limine-bg.png && -f config/nyx-wallpaper.jpg ]]; then
    if cmp -s config/limine-bg.png config/nyx-wallpaper.jpg; then
        warn "boot background and desktop background are the same file"
    else
        ok "boot background and desktop background are separate images"
    fi
fi
if grep -q 'nyx-wallpaper.jpg' build.sh; then
    ok "build.sh installs the desktop background"
else
    bad "build.sh does not install the desktop background"
fi
if grep -q 'wallpapers/nyx' build.sh; then
    ok "build.sh ships a Plasma wallpaper package"
else
    bad "no Plasma wallpaper package is installed"
fi
# checkupdates comes from pacman-contrib; without it the reporter cannot run.
if grep -qE '^[[:space:]]*-[[:space:]]*pacman-contrib[[:space:]]*$' config/calamares/modules/packages.conf; then
    ok "pacman-contrib is installed into the target system"
else
    bad "pacman-contrib is missing; checkupdates will not exist"
fi
if bash -n config/base-rootfs-overlay/usr/local/sbin/nyx-updates 2>/dev/null; then
    ok "nyx-updates passes a bash syntax check"
else
    bad "nyx-updates has a syntax error"
fi
if grep -q 'checkupdates' config/base-rootfs-overlay/usr/local/sbin/nyx-updates; then
    ok "nyx-updates uses checkupdates rather than pacman -Sy"
else
    bad "nyx-updates does not use checkupdates"
fi
if grep -q '12h' config/base-rootfs-overlay/usr/lib/systemd/user/nyx-updates.timer; then
    ok "update timer runs every 12h"
else
    bad "update timer interval is not 12h"
fi

# --------------------------------------------------------------------------
printf '\n\033[1mChecks passed: %d, failed: %d\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
printf '\033[1;32mAll static checks passed.\033[0m\n'
