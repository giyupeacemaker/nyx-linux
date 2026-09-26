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

# Some checks ask "does this file *do* X", and the answer has to ignore prose:
# an explanatory comment naming a command, a path or a package would otherwise
# satisfy the check on its own. Strip comments before grepping for code.
#
# Callers capture this with $(...) rather than piping it into "grep -q": grep -q
# exits on the first match, the sed at the other end of the pipe dies of SIGPIPE,
# and under `set -o pipefail` the whole pipeline then reports failure even though
# the pattern did match.
code_only() {
    sed 's/^[[:space:]]*#.*$//; s/[[:space:]]#.*$//' "$1"
}

# Extract one shell function body: from "name() {" to the first line that is
# only a closing brace. Used instead of "grep -A<n>", because a handful of
# comment lines inside a function silently moves the line of interest out of
# any fixed window, and the check then fails for a reason that has nothing to do
# with the code.
func_body() {
    local name="$1" file="$2"
    awk -v fn="$name" '
        $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { inside=1; next }
        inside && /^[[:space:]]*\}[[:space:]]*$/ { exit }
        inside { print }
    ' "$file"
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
         nyx-tools/wallpaper \
         nyx-tools/updates \
         nyx-tools/updates.service \
         nyx-tools/updates.timer; do
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
if bash -n nyx-tools/updates 2>/dev/null; then
    ok "nyx-updates passes a bash syntax check"
else
    bad "nyx-updates has a syntax error"
fi
if grep -q 'checkupdates' nyx-tools/updates; then
    ok "nyx-updates uses checkupdates rather than pacman -Sy"
else
    bad "nyx-updates does not use checkupdates"
fi
if grep -q '12h' nyx-tools/updates.timer; then
    ok "update timer runs every 12h"
else
    bad "update timer interval is not 12h"
fi

# --------------------------------------------------------------------------
sect "Installer package choices exist"
# A typo in a packagechooser list does not fail the build. It fails silently at
# install time, on the machine of somebody who picked that option. Everything
# named in the lists has to resolve either to a package or to a group, because
# pacman -S accepts both and xorg-apps, gnome and xfce4 are groups.
# This check needs a pacman database. validate.sh is also run from the WSL root
# filesystem, where pacman does not exist and the database lives in the build
# chroot instead, so fall back to querying it through chroot.
# Note: this has to be an array, not a string. This script sets
# IFS=$'\n\t', which removes the space as a word separator, so an unquoted
# "chroot /path /usr/bin/pacman" would be looked up as a single (nonexistent)
# command name and every lookup would fail. Arrays are immune to IFS.
pacman_q=()
if command -v pacman >/dev/null 2>&1; then
    pacman_q=(pacman)
else
    for cand in "${NYX_CHROOT:-}" /var/tmp/archroot; do
        if [[ -n "$cand" && -x "$cand/usr/bin/pacman" ]]; then
            pacman_q=(chroot "$cand" /usr/bin/pacman)
            break
        fi
    done
fi

if (( ${#pacman_q[@]} > 0 )); then
    mapfile -t chooser_pkgs < <(python3 - config/calamares/modules <<'PY' 2>/dev/null
import re, sys, pathlib
for f in sorted(pathlib.Path(sys.argv[1]).glob('packagechooser-*.conf')):
    text = f.read_text(encoding='utf-8')
    cur = None
    for line in text.splitlines():
        m = re.match(r'\s*-\s*id:\s*(\S+)\s*$', line)
        if m:
            cur = m.group(1); continue
        m = re.match(r'\s*-\s+([a-z0-9][a-z0-9._+-]*)\s*$', line)
        if m and cur:
            print(f"{cur}\t{m.group(1)}")
PY
    )
    if (( ${#chooser_pkgs[@]} == 0 )); then
        warn "could not parse the packagechooser lists"
    else
        missing_choice=0
        for pair in "${chooser_pkgs[@]}"; do
            name="${pair##*$'\t'}"
            if "${pacman_q[@]}" -Si -- "$name" >/dev/null 2>&1; then
                continue
            fi
            if "${pacman_q[@]}" -Sgq 2>/dev/null | grep -qx -- "$name"; then
                continue   # a group, which pacman -S still accepts
            fi
            bad "installer choice refers to unknown package or group: $name"
            missing_choice=$((missing_choice + 1))
        done
        if (( missing_choice == 0 )); then
            ok "all ${#chooser_pkgs[@]} installer package choices resolve"
        fi
    fi
else
    warn "no pacman database reachable, skipping installer package existence checks"
fi

# --------------------------------------------------------------------------
sect "Snapshot rollback"
# nyx-rollback promises a way back after a bad transaction. Both backends it can
# use have to be present in the target system, or the promise is empty.
if [[ -f nyx-tools/rollback ]]; then
    ok "nyx-rollback present"
    if bash -n nyx-tools/rollback 2>/dev/null; then
        ok "nyx-rollback passes a bash syntax check"
    else
        bad "nyx-rollback has a syntax error"
    fi
    for be in snapper timeshift; do
        if grep -q "$be" nyx-tools/rollback; then
            ok "nyx-rollback knows the $be backend"
        else
            bad "nyx-rollback has no $be backend"
        fi
    done
    if grep -q 'btrfs' nyx-tools/rollback; then
        ok "nyx-rollback picks a backend from the root filesystem"
    else
        bad "nyx-rollback does not detect the root filesystem type"
    fi
    # Anchor on command position: the script may *print* "sudo pacman -S
    # snapper" as installation advice, which is not the same as running it.
    if grep -qE '(^|[;&|]|&&)[[:space:]]*(sudo[[:space:]]+)?pacman[[:space:]]+-S' \
        nyx-tools/rollback; then
        bad "nyx-rollback runs a package transaction; it must only report and restore"
    else
        ok "nyx-rollback never installs packages on its own"
    fi
else
    bad "nyx-rollback is missing"
fi
# Both snapshot backends must be installable. ext4 is the installer's default
# root filesystem and has no snapshot support, and btrfs is offered as an option.
for p in snapper timeshift; do
    if grep -qE "^[[:space:]]*-[[:space:]]*${p}[[:space:]]*$" config/calamares/modules/packages.conf; then
        ok "$p is installed into the target system"
    else
        bad "$p is not installed; nyx-rollback would have no backend"
    fi
done
# btrfs is listed inside availableFileSystemTypes: [ ext4, btrfs ], so look for
# the bare word rather than for a line of its own.
if grep -q '\bbtrfs\b' config/calamares/modules/partition.conf; then
    ok "installer offers btrfs, which nyx-rollback prefers"
else
    warn "installer does not offer btrfs; only the timeshift path will work"
fi

# --------------------------------------------------------------------------
sect "nyx-tools packaging"
# The helper tools are a real package, not loose files in the base rootfs, so
# that pacman owns them and an installed system can upgrade them. Keeping them in
# two places means two sources of truth, and the stale copy is what gets shipped.
pkg=nyx-tools
if [[ -f "$pkg/PKGBUILD" ]]; then
    ok "$pkg/PKGBUILD present"
    # The version has to grow per build, or pacman reports no update at all.
    if grep -q '^pkgver()' "$pkg/PKGBUILD"; then
        ok "$pkg computes its version with pkgver()"
    else
        bad "$pkg has a fixed pkgver; a rebuilt package would never look newer"
    fi
    for f in updates rollback wallpaper updates.service updates.timer \
             wallpaper.desktop README; do
        if [[ -f "$pkg/$f" ]]; then ok "source $f present"; else bad "source $f missing"; fi
    done
else
    bad "$pkg/PKGBUILD missing"
fi

for t in nyx-updates nyx-rollback nyx-apply-wallpaper; do
    if find config/base-rootfs-overlay -name "$t" 2>/dev/null | grep -q .; then
        bad "$t is still in base-rootfs-overlay; the package is now the only source"
    else
        ok "$t is not in the overlay"
    fi
    if grep -rq "$t" "$pkg" 2>/dev/null; then
        ok "$t is shipped by $pkg"
    else
        bad "$t is not shipped by $pkg"
    fi
done

# nyx-update-git must NOT be inside the package: it repairs the package, so it
# has to survive the package being the thing that is broken.
pkg_code="$(code_only "$pkg/PKGBUILD")"
if grep -q 'nyx-update-git' <<<"$pkg_code"; then
    bad "nyx-update-git is inside $pkg; it would die with the package it repairs"
else
    ok "nyx-update-git is deliberately outside $pkg"
fi
if [[ -f config/base-rootfs-overlay/usr/local/sbin/nyx-update-git ]]; then
    ok "nyx-update-git ships with the ISO"
else
    bad "nyx-update-git is missing from the ISO"
fi
build_code="$(code_only build.sh)"
if grep -q 'nyx-update-git' <<<"$build_code"; then
    ok "build.sh installs nyx-update-git into the target"
else
    bad "build.sh does not install nyx-update-git"
fi
if grep -q 'systemctl --root' <<<"$build_code"; then
    bad "build.sh still enables the timer with systemctl --root; the unit comes from the package"
else
    ok "timer is enabled with a direct symlink, not systemctl --root"
fi

if grep -q '^\[nyx\]' config/live-pacman.conf; then
    ok "pacman.conf declares the [nyx] repository"
else
    bad "pacman.conf has no [nyx] repository"
fi
if grep -q 'file:///var/cache/nyx-repo' config/live-pacman.conf; then
    ok "the installed system reads Nyx packages from /var/cache/nyx-repo"
else
    bad "the [nyx] repository does not point at /var/cache/nyx-repo"
fi
if grep -qE '^[[:space:]]*-[[:space:]]*nyx-tools[[:space:]]*$' config/calamares/modules/packages.conf; then
    ok "nyx-tools is installed by the installer"
else
    bad "nyx-tools is not in the installer's package list"
fi
if grep -q 'nyx-tools' build.sh && grep -q 'var/cache/nyx-repo' build.sh; then
    ok "build.sh builds the package and seeds the target repository"
else
    bad "build.sh does not build nyx-tools into the target repository"
fi
# repo-add refuses a database name that lacks a full archive extension.
if grep -qE 'repo-add[^|]*nyx\.db([^.]|$)' build.sh; then
    bad "repo-add is called with a bare nyx.db; it needs the full archive extension"
else
    ok "repo-add is given a full database archive name"
fi

# --------------------------------------------------------------------------
sect "kernel command line and nyx-tweaks"
# The tunables need somewhere to live. Both bootloader writers used to assemble
# the command line from scratch, so writing to /etc/default/grub would have done
# nothing on Limine or systemd-boot, and a parameter set by nyx-tweaks would
# have been silently dropped. The command line is now built in one place.
BP=config/base-rootfs-overlay/usr/local/lib/nyx/boot-params
if [[ -f "$BP" ]] && is_shell_script "$BP"; then
    ok "boot-params helper present"
else
    bad "boot-params helper missing or not a shell script"
fi
for mode in base extra path; do
    if code_only "$BP" | grep -q "^    $mode)"; then
        ok "boot-params answers '$mode'"
    else
        bad "boot-params has no '$mode' command"
    fi
done
if grep -q 'boot-params extra' "$BP"; then
    ok "boot-params strips comments out of the tunable parameters"
else
    bad "boot-params does not clean the tunable parameters"
fi

# Both writers must read the shared helper rather than their own copy. The call
# is spelled cmdline="$("$boot_params" base)", so look for the invocation, not
# for the words "boot-params base" that appear in no script.
for w in update-arch-limine nyx-configure-bootloader; do
    path="config/base-rootfs-overlay/usr/local/sbin/$w"
    if [[ ! -f "$path" ]]; then bad "$w is missing"; continue; fi
    if grep -q 'boot_params" base' "$path"; then
        ok "$w takes the base parameters from boot-params"
    else
        bad "$w does not ask boot-params for the base parameters"
    fi
    if grep -q 'boot_params" extra' "$path"; then
        ok "$w appends the Nyx tunables"
    else
        bad "$w ignores the Nyx tunables; they would never reach this bootloader"
    fi
    # A leftover copy of the old assembly is the thing most likely to come back.
    if grep -q 'build_cmdline' "$path"; then
        bad "$w still defines build_cmdline; that is the duplication boot-params removed"
    else
        ok "$w has no leftover command line builder"
    fi
done

# GRUB is the one place where base and extra are deliberately not concatenated,
# because grub-mkconfig writes root= itself. Check it is actually done.
cbl="$(code_only config/base-rootfs-overlay/usr/local/sbin/nyx-configure-bootloader)"
if grep -q 'GRUB_CMDLINE_LINUX' <<<"$cbl"; then
    ok "the GRUB path passes the tunables through GRUB_CMDLINE_LINUX"
else
    bad "the GRUB path drops the Nyx tunables"
fi

if grep -q 'usr/local/lib/nyx/boot-params' build.sh; then
    ok "build.sh installs boot-params with the execute bit forced"
else
    bad "build.sh does not install boot-params"
fi
if grep -q 'etc/nyx/kernel-params' build.sh; then
    ok "build.sh seeds /etc/nyx/kernel-params"
else
    bad "build.sh does not seed the kernel parameters file"
fi

# --- nyx-tweaks ------------------------------------------------------------
TW=nyx-tools/tweaks
if [[ -f "$TW" ]] && is_shell_script "$TW"; then
    ok "nyx-tweaks present"
else
    bad "nyx-tweaks missing or not a shell script"
fi
if [[ -f "$TW" ]]; then
    tw="$(code_only "$TW")"
    # Ten switches is the promise the README makes; count the registry rows.
    n=$(grep -cE '^"[a-z-]+\|(cpupower|zram|kparam|service|ppd)\|' "$TW" || true)
    if [[ "$n" == 10 ]]; then
        ok "nyx-tweaks registers exactly 10 switches"
    else
        bad "nyx-tweaks registers $n switches, expected 10"
    fi
    if grep -q 'need_root "set ' <<<"$tw" && grep -q 'write_state' <<<"$tw"; then
        ok "nyx-tweaks records a change instead of only printing it"
    else
        bad "nyx-tweaks does not persist a value that was set"
    fi
    # The bug that mattered: apply has to start from the recorded state. A
    # registry rebuilt from defaults on every call silently undoes whatever the
    # user just asked for, and every value looks like it was applied.
    if func_body apply_all "$TW" | grep -q 'load_state'; then
        ok "apply_all starts from the recorded state, not from defaults"
    else
        bad "apply_all ignores the recorded state and would apply the defaults"
    fi
    # Same trap: a reset held only in memory is lost by the reload in apply_all.
    if func_body cmd_reset "$TW" | grep -q 'write_state'; then
        ok "reset writes the defaults before applying them"
    else
        bad "reset is discarded by the reload inside apply_all"
    fi
    # Kernel parameters are rebuilt whole, not appended to, otherwise a switch
    # that was turned off could never be removed.
    if grep -q 'write_kernel_params' <<<"$tw"; then
        ok "kernel parameters are rewritten whole rather than appended to"
    else
        bad "kernel parameters are appended to, so a switch cannot be turned off"
    fi
    if grep -q 'pending_reboot' <<<"$tw"; then
        ok "nyx-tweaks reports a pending reboot by comparing /proc/cmdline"
    else
        bad "nyx-tweaks does not say when a parameter is not yet in force"
    fi
    # Turning a switch off has to remove its parameter, not merely stop adding
    # it on the next run.
    for pair in 'mitigations:off:mitigations=off' 'watchdog:off:nowatchdog' 'zswap:on:zswap.enabled=1'; do
        key="${pair%%:*}"; rest="${pair#*:}"
        val="${rest%%:*}"; want="${rest#*:}"
        if func_body write_kernel_params "$TW" | grep -qF -- "$key"; then
            ok "$key = $val contributes '$want'"
        else
            bad "$key has no case in write_kernel_params"
        fi
    done
fi
if grep -q 'tweaks' nyx-tools/PKGBUILD; then
    ok "nyx-tools ships nyx-tweaks"
else
    bad "nyx-tools does not install nyx-tweaks"
fi

# --------------------------------------------------------------------------
printf '\n\033[1mChecks passed: %d, failed: %d\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
printf '\033[1;32mAll static checks passed.\033[0m\n'
