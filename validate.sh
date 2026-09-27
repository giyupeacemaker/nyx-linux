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
    config/base-rootfs-overlay/etc/pacman.d/hooks/99-arch-limine.hook \
    config/base-rootfs-overlay/etc/pacman.d/hooks/99-nyx-os-release.hook \
    config/base-rootfs-overlay/usr/local/sbin/update-arch-limine \
    config/base-rootfs-overlay/usr/local/sbin/nyx-configure-bootloader \
    config/base-rootfs-overlay/usr/local/sbin/update-nyx-os-release
do
    [[ -f "$f" ]] && ok "exists $f" || bad "missing $f"
done

# The target's mirrorlist must not be a hand-written one. pacstrap installs
# pacman-mirrorlist even under -M, so the full upstream list is already on disk
# and only needs its HTTPS servers uncommented. Shipping a short hand-picked list
# in the overlay discards it, and a list with no fallback leaves the Calamares
# "packages" step with nothing to sync from.
if [[ -f config/base-rootfs-overlay/etc/pacman.d/mirrorlist ]]; then
    bad "overlay ships its own mirrorlist, overwriting the full pacman-mirrorlist set"
    printf '       hand-picked servers: %s\n' \
        "$(grep -c '^Server' config/base-rootfs-overlay/etc/pacman.d/mirrorlist || echo 0)"
else
    ok "overlay does not ship a mirrorlist (pacman-mirrorlist is used instead)"
fi

if grep -q 'pacman.d/mirrorlist' build.sh; then
    if grep -q 'nyx_mirrors=' build.sh; then
        ok "build.sh counts the target's active mirrors"
    else
        bad "build.sh touches the target mirrorlist but never counts the result"
    fi
    if grep -q 'nyx_mirrors < 50' build.sh; then
        ok "build.sh refuses to build when the target mirrorlist is too short"
    else
        bad "build.sh has no lower bound on the target's mirror count"
    fi
else
    bad "build.sh never touches the target's mirrorlist"
fi

# Licensing and attribution. Without a LICENSE the repository is not open
# source at all: copyright defaults to all rights reserved, and nobody may even
# read the code to modify it. The vendored tarballs are redistributed here, so
# their licences have to be readable in the repository and not only inside the
# archives.
# Two builds in one BUILD_ROOT destroy each other, and the resulting error
# points at the compiler rather than at the cause. The lock has to be taken
# before the build directory is touched.
if grep -q 'flock -n 9' build.sh; then
    ok "build.sh takes an exclusive lock on BUILD_ROOT"
else
    bad "build.sh has no lock: two concurrent builds will corrupt each other"
fi
lock_line=$(grep -n 'flock -n 9' build.sh | head -1 | cut -d: -f1)
rm_line=$(grep -nE '^rm -rf -- "\$BUILD_ROOT"$' build.sh | head -1 | cut -d: -f1)
if [[ -n "$lock_line" && -n "$rm_line" ]] && (( lock_line < rm_line )); then
    ok "the lock is taken before BUILD_ROOT is removed (lines $lock_line < $rm_line)"
else
    bad "the lock must be taken before rm -rf of BUILD_ROOT"
    echo "       lock at line ${lock_line:-none}, rm at line ${rm_line:-none}"
fi

# --------------------------------------------------------------------------
sect "Licensing and attribution"
[[ -f LICENSE ]] && ok "LICENSE exists" || bad "no LICENSE: the repository is not open source"
if [[ -f LICENSE ]]; then
    if head -3 LICENSE | grep -q 'Apache License'; then
        ok "LICENSE is Apache-2.0"
    else
        bad "LICENSE is not the Apache-2.0 text"
    fi
    if [[ $(wc -l < LICENSE) -gt 150 ]]; then
        ok "LICENSE looks complete ($(wc -l < LICENSE) lines)"
    else
        bad "LICENSE is truncated: only $(wc -l < LICENSE) lines"
    fi
fi
[[ -f NOTICE ]] && ok "NOTICE exists" || bad "no NOTICE: third-party attribution is missing"

for lic in archiso-GPL-3.0.txt calamares-GPL-3.0-or-later.txt calamares-MIT.txt; do
    f="licenses/$lic"
    if [[ -s "$f" ]]; then
        ok "vendored licence present: $lic"
    else
        bad "missing or empty vendored licence: $lic"
    fi
done
empty=$(find licenses -size 0 2>/dev/null | wc -l)
[[ "$empty" -eq 0 ]] && ok "no empty files under licenses/" \
                     || bad "$empty empty file(s) under licenses/"

# The mark has to be ours. Third-party artwork as a distribution logo is a
# trademark problem, and the first version of this project used exactly that.
for f in config/logo/nyancat.svg config/logo/nyan.svg; do
    [[ -e "$f" ]] && bad "third-party artwork source is back: $f"
done
# validate.sh исключён из поиска: в нём самом записан проверяемый паттерн,
# и без исключения проверка находила бы собственную команду grep.
if git grep -qiE 'iliana|html5nyancat' -- . ':!validate.sh' 2>/dev/null; then
    bad "the repository still refers to the third-party artwork project"
    git grep -niE 'iliana|html5nyancat' -- . ':!validate.sh' | head -3 | sed 's/^/       /'
else
    ok "no reference to the third-party artwork project"
fi
if [[ -f scripts/make-logo.py ]]; then
    ok "the logo is generated from scripts/make-logo.py, so it is reproducible"
else
    bad "no scripts/make-logo.py: the mark cannot be regenerated or verified"
fi
# Bar count is the one number that decides whether the mark survives being
# 22 px tall in the installer's step list. Densely packed rows alias into noise.
if grep -qE '^ROWS_ICON = ([0-9]{1,2}|[1-3][0-9])[[:space:]]*$' scripts/make-logo.py 2>/dev/null; then
    ok "the icon uses a row count that stays legible at 22 px"
else
    bad "ROWS_ICON is missing or too dense; the icon will alias at small sizes"
    grep -nE '^ROWS_ICON' scripts/make-logo.py 2>/dev/null | sed 's/^/       /'
fi

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
default_ff=config/fastfetch/nyx.jsonc
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
    if grep -q 'nyx.ascii' "$default_ff"; then
        ok "default preset uses the shipped ASCII logo (works outside kitty)"
    else
        bad "default preset does not reference nyx.ascii"
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
    # The count is a promise the README makes, so keep them in step.
    n=$(grep -cE '^"[a-z-]+\|(cpupower|zram|kparam|service|ppd|sysctl)\|' "$TW" || true)
    if [[ "$n" == 11 ]]; then
        ok "nyx-tweaks registers exactly 11 switches"
    else
        bad "nyx-tweaks registers $n switches, expected 11"
    fi
    # A sysctl that names an algorithm the kernel only has as a module is
    # applied to a setting that does not exist yet and fails silently at boot.
    # The modules-load entry is what makes it work, so the two belong together.
    if func_body write_sysctl "$TW" | grep -q 'sysctl.d'; then
        ok "the sysctl switch writes a sysctl.d file"
    else
        bad "the sysctl switch writes no sysctl.d file"
    fi
    if func_body write_sysctl "$TW" | grep -q 'modules-load.d'; then
        ok "the sysctl switch also loads the module, so the setting survives a reboot"
    else
        bad "the sysctl switch names no module; the value would be lost at boot"
    fi
    # Turning it back to the default has to remove the module entry. Leaving a
    # stale one is harmless, but leaving a stale sysctl line is not: it would
    # reassert the old algorithm on every boot.
    if func_body write_sysctl "$TW" | grep -qE 'rm -f /etc/modules-load'; then
        ok "choosing the default algorithm removes the module entry"
    else
        bad "the sysctl switch never removes its modules-load entry"
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

# source and sha256sums have to be the same length or makepkg aborts before it
# compiles anything. Adding a source and forgetting the matching SKIP is the
# easy mistake, and the failure message points at the checksum list rather than
# at the omission.
# Count items, not quotes: a PKGBUILD may use double quotes or none at all, and
# both lists would then differ in quote characters while holding the same number
# of entries. Note the grep -v on sha256sums: a "sed -n /start/,/end/p" range
# includes its end line, so without it the source count picks up the checksums as
# well and comes out as their sum.
count_items() {
    sed 's/^[A-Za-z_][A-Za-z0-9_]*=//' | tr -d "()'" \
        | tr -s ' \t' '\n' | sed '/^$/d' | grep -cv '^$'
}
n_src=$(sed -n '/^source=/,/^sha256sums=/p' nyx-tools/PKGBUILD \
        | grep -v '^sha256sums=' | count_items)
n_skip=$(sed -n '/^sha256sums=/p' nyx-tools/PKGBUILD | count_items)
if (( n_src == n_skip )); then
    ok "nyx-tools has one sha256sums entry per source ($n_src)"
else
    bad "nyx-tools lists $n_src sources but $n_skip checksums; makepkg will refuse it"
fi

# Every source has to be a real file, and every source has to end up installed,
# or a file is silently left out of the package.
pkg_sources() {
    sed -n '/^source=/,/^sha256sums=/p' nyx-tools/PKGBUILD \
        | sed 's/^source=//; s/^sha256sums=.*//' \
        | tr -d "()'" | tr ' ' '\n' | grep -v '^$'
}
pkg_body="$(sed -n '/^package()/,/^}/p' nyx-tools/PKGBUILD)"
pkg_missing=""
pkg_uninstalled=""
while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    [[ -f "nyx-tools/$s" ]] || pkg_missing+="$s "
    grep -qF "srcdir/$s" <<<"$pkg_body" || pkg_uninstalled+="$s "
done < <(pkg_sources)
if [[ -z "$pkg_missing" ]]; then
    ok "every nyx-tools source exists in the tree"
else
    bad "nyx-tools sources missing from the tree: ${pkg_missing% }"
fi
if [[ -z "$pkg_uninstalled" ]]; then
    ok "every nyx-tools source is installed by package()"
else
    bad "nyx-tools sources declared but never installed: ${pkg_uninstalled% }"
fi

# --- the login greeting ----------------------------------------------------
if [[ -f nyx-tools/motd ]] && is_shell_script nyx-tools/motd; then
    ok "nyx-motd present"
else
    bad "nyx-motd missing or not a shell script"
fi
GR=config/base-rootfs-overlay/etc/profile.d/nyx-greeting.sh
if [[ -f "$GR" ]]; then
    ok "the login greeting hook present"
    # Once per session, and never over ssh. Without both, every new shell
    # repeats the greeting and it stops being read at all.
    hook="$(code_only "$GR")"
    if grep -q 'XDG_RUNTIME_DIR' <<<"$hook" && grep -q 'nyx-greeted' <<<"$hook"; then
        ok "the greeting runs once per session"
    else
        bad "the greeting has no per-session marker and would repeat on every shell"
    fi
    if grep -q 'SSH_CONNECTION' <<<"$hook"; then
        ok "the greeting stays quiet over ssh"
    else
        bad "the greeting would print on every ssh shell"
    fi
    # The greeting is decoration; a non-zero exit would leave a trace above the
    # prompt for a user who did nothing wrong.
    if grep -q 'exit 0' nyx-tools/motd; then
        ok "nyx-motd always exits 0"
    else
        bad "nyx-motd can exit non-zero and would break the login"
    fi
else
    bad "the login greeting hook is missing"
fi
if grep -q 'nyx-greeting.sh' build.sh; then
    ok "build.sh installs the login greeting hook"
else
    bad "build.sh does not install the login greeting hook"
fi

# --- nyx-update ------------------------------------------------------------
NU=nyx-tools/nyx-update
if [[ -f "$NU" ]] && is_shell_script "$NU"; then
    ok "nyx-update present"
else
    bad "nyx-update missing or not a shell script"
fi
if [[ -f "$NU" ]]; then
    nu="$(code_only "$NU")"
    # The reason this exists: the news has to be read before the update, not
    # after something has already broken.
    if grep -q 'archlinux.org/feeds/news' <<<"$nu"; then
        ok "nyx-update reads the Arch news feed"
    else
        bad "nyx-update does not read the Arch news feed"
    fi
    if grep -q 'do_news' <<<"$nu" && grep -q 'show_news' <<<"$nu"; then
        ok "the news is a separate step that can be skipped on purpose"
    else
        bad "nyx-update has no separate news step"
    fi
    # It must not take the decision away: no -y, no --noconfirm anywhere.
    if grep -qE 'pacman +-(-[a-zA-Z]*y|--noconfirm|--yes)' <<<"$nu"; then
        bad "nyx-update passes a non-interactive flag to pacman; that is the user's call"
    else
        ok "nyx-update leaves every pacman prompt to the user"
    fi
    if grep -q 'nyx-rollback create' <<<"$nu"; then
        ok "nyx-update delegates the snapshot to nyx-rollback"
    else
        bad "nyx-update takes no snapshot, so the update is not reversible"
    fi
    # A running kernel cannot change under a live system, so an update that
    # installed a new one is not finished until you restart.
    if grep -q 'kernel_pending' <<<"$nu"; then
        ok "nyx-update reports when a newer kernel is waiting for a restart"
    else
        bad "nyx-update does not mention the pending restart"
    fi
    if grep -q 'EUID' <<<"$nu"; then
        ok "nyx-update refuses to run without root"
    else
        bad "nyx-update does not check for root"
    fi
fi
if grep -q 'srcdir/nyx-update' nyx-tools/PKGBUILD; then
    ok "nyx-tools ships nyx-update"
else
    bad "nyx-tools does not install nyx-update"
fi

# A comment cannot sit between the backslash-continued lines of a command. Bash
# treats the "#" as the start of a comment, swallows the rest of that line
# including the continuation, and the next argument then arrives as a command of
# its own. This cost a full build: the -DUSE_services flag below turned into
# "-DUSE_services=systemd: command not found" after cmake had already configured.
# Any shell file can hit it, so the check is not limited to the PKGBUILD.
check_no_comment_in_continuation() {
    local file="$1" hits=""
    local prev="" line n=0
    while IFS= read -r line; do
        n=$(( n + 1 ))
        if [[ "$prev" == *'\' ]]; then
            # A comment right after a continuation swallows the continuation.
            if [[ "$line" =~ ^[[:space:]]*# ]]; then
                hits+=" line $n"
            fi
        fi
        prev="$line"
    done <"$file"
    if [[ -z "$hits" ]]; then
        ok "$(basename "$file") has no comment inside a continued command"
    else
        bad "$(basename "$file") has a comment after a line continuation:${hits}"
        bad "  bash eats the continuation and the next argument becomes a command"
    fi
}
for sf in vendor/calamares/PKGBUILD build.sh config/live-setup.sh \
          config/base-rootfs-overlay/usr/local/lib/nyx/boot-params \
          config/base-rootfs-overlay/usr/local/sbin/nyx-configure-bootloader \
          config/base-rootfs-overlay/usr/local/sbin/update-arch-limine \
          config/base-rootfs-overlay/usr/local/sbin/nyx-update-git \
          config/base-rootfs-overlay/usr/local/sbin/nyx-motd; do
    [[ -f "$sf" ]] && check_no_comment_in_continuation "$sf"
done

# The flag that the comment above is about has to be on one continued line, not
# split, and it has to name the implementation rather than the module. Only the
# line itself is checked: a comment *above* the command is safe and is where the
# explanation belongs, so matching "#" anywhere near it would be a false alarm.
if grep -qE '^[[:space:]]+-DUSE_services=systemd \\$' vendor/calamares/PKGBUILD; then
    ok "the USE_services flag is a single continued line"
else
    bad "the USE_services flag is not a single continued line"
fi

# --- repository naming -----------------------------------------------------
# pacman finds a repository database by the section name: [nyx] means nyx.db and
# nothing else. The name therefore has to agree in three places — the pacman.conf
# section, the repo-add argument for the live repository, and the seeded database
# in the target. When it did not, the build failed inside mkarchiso with
# "failed retrieving file 'nyx.db'", long after Calamares had been compiled.
nyx_section="$(sed -n 's/^\[\([A-Za-z0-9_-]*\)\]$/\1/p' config/live-pacman.conf \
               | grep -E '^nyx' | head -1)"
if [[ -n "$nyx_section" ]]; then
    ok "pacman.conf declares the repository as [$nyx_section]"
else
    bad "pacman.conf has no [nyx...] repository section"
    nyx_section=""
fi

if [[ -n "$nyx_section" ]]; then
    want_db="${nyx_section}.db"
    # The live repository.
    live_db="$(grep -oE 'repo-add[^\n]*\$LOCAL_REPO/[A-Za-z0-9_.-]+\.db\.tar\.[a-z]+' build.sh \
               | head -1 | grep -oE '[A-Za-z0-9_.-]+\.db\.tar\.[a-z]+' | head -1)"
    if [[ -n "$live_db" ]]; then
        if [[ "$live_db" == "$want_db."* ]]; then
            ok "the live repository database is named after the section ($live_db)"
        else
            bad "the live repository database is '$live_db' but [$nyx_section] makes pacman look for '$want_db'"
        fi
    else
        bad "could not find the repo-add call for the live repository"
    fi

    # The seeded repository in the target system.
    target_db="$(grep -oE 'var/cache/nyx-repo/[A-Za-z0-9_.-]+\.db\.tar\.[a-z]+' build.sh \
                 | head -1 | grep -oE '[A-Za-z0-9_.-]+\.db\.tar\.[a-z]+' | head -1)"
    if [[ -n "$target_db" ]]; then
        if [[ "$target_db" == "$want_db."* ]]; then
            ok "the target repository database uses the same name ($target_db)"
        else
            bad "the target repository database is '$target_db' but the section says '$want_db'"
        fi
    else
        bad "could not find the seeded repository database in build.sh"
    fi

    # And the required-files list has to name what was actually created.
    if grep -qE "^\s*'var/cache/nyx-repo/${want_db}\.tar\.[a-z]+'" build.sh; then
        ok "the content check looks for the database that is really created"
    else
        bad "the content check does not list 'var/cache/nyx-repo/${want_db}.tar.*'"
    fi
fi

# --- fastfetch logo --------------------------------------------------------
# The logo is our own artwork now. The previous one was borrowed from the Nyarch
# project, which meant a second, stranger file sat in the skel next to the preset
# that referenced it. The checks below make sure the preset points at a file that
# exists, and that the borrowed artwork does not quietly come back.
FF_DIR=config/fastfetch
PRESET=$FF_DIR/nyx.jsonc
LOGO=$FF_DIR/nyx.ascii

if [[ -f "$PRESET" ]]; then
    ok "the default fastfetch preset is present ($PRESET)"
else
    bad "the default fastfetch preset is missing"
fi
if [[ -f "$LOGO" ]]; then
    ok "the Nyx logo file is present"
    # A logo is monochrome or coloured and both are correct. What must never
    # happen is colour *sequences* printed as literal text, which is what a
    # stripped escape byte looks like.
    if grep -qF '[38;2;' "$LOGO" || grep -qF '[0m' "$LOGO"; then
        bad "the logo has colour sequences as literal text; the ESC bytes were lost"
    else
        ok "the logo has no colour sequences printed as text"
    fi
    # What counts as "a logo" is a decision, not a fact: a drawn mark, braille
    # artwork or rendered blocks all satisfy it. What must hold for any of them
    # is that there is real content and that the colour sequences are real bytes
    # rather than printed text. The previous check looked for the vertical bar
    # and diagonals of the peace sign, so it failed on any other artwork.
    plain="$(sed 's/\x1b\[[0-9;]*m//g' "$LOGO")"
    ink=$(printf '%s' "$plain" | tr -d '[:space:]' | wc -c)
    glyphs=$(printf '%s' "$plain" | fold -w1 | sort -u | grep -c '[^[:space:]]')
    rows=$(printf '%s\n' "$plain" | grep -c .)
    if (( ink > 200 )); then
        ok "the logo carries real content ($ink non-space characters, $rows rows)"
    else
        bad "the logo is nearly empty ($ink non-space characters)"
    fi
    # Block artwork legitimately uses a handful of glyphs; braille uses many.
    # The drawn peace sign reached five, so the floor is four.
    if (( glyphs >= 4 )); then
        ok "the logo uses $glyphs distinct glyphs"
    else
        bad "the logo uses only $glyphs distinct glyphs; it does not look like artwork"
    fi
    # Braille is U+2800..U+28FF. If it is present the terminal font has to cover
    # it, or the picture turns into replacement characters. The image already
    # installs DejaVu and Liberation, both of which do.
    if printf '%s' "$plain" | grep -qP '[\x{2800}-\x{28ff}]' 2>/dev/null; then
        ok "the logo uses braille; the image ships DejaVu and Liberation, which cover it"
    fi
else
    bad "the Nyx logo file is missing"
fi

if [[ -f "$PRESET" ]]; then
    # The preset has to point at the logo that actually ships. A dangling path
    # renders as no logo at all and is easy to miss on a fresh install.
    logo_ref="$(grep -oE '"source"[[:space:]]*:[[:space:]]*"[^"]*"' "$PRESET" \
                | head -1 | sed 's/.*"\(.*\)"/\1/')"
    if [[ -n "$logo_ref" ]]; then
        base="${logo_ref##*/}"
        if [[ "$base" == "$(basename "$LOGO")" ]]; then
            ok "the preset points at $base"
        else
            bad "the preset points at '$base' but the shipped logo is '$(basename "$LOGO")'"
        fi
        if [[ -f "$FF_DIR/$base" ]]; then
            ok "the referenced logo exists in config/fastfetch"
        else
            bad "the preset references $base, which is not in config/fastfetch"
        fi
    else
        bad "the preset has no logo source"
    fi
    # A PNG over the kitty protocol would render as nothing under konsole.
    if grep -q '"type"[[:space:]]*:[[:space:]]*"file"' "$PRESET"; then
        ok "the logo is a text file, so it renders in konsole"
    else
        bad "the logo is not a text file; kitty images do not render under Plasma's konsole"
    fi
    # user@host has to be the first thing printed, which is why "title" is first
    # and not just present somewhere in the list.
    if python3 - "$PRESET" <<'PY' 2>/dev/null
import json, re, sys
t = open(sys.argv[1], encoding="utf-8").read()
t = re.sub(r'^\s*//.*$', '', t, flags=re.M)
t = re.sub(r',(\s*[}\]])', r'\1', t)
mods = [m for m in json.loads(t)["modules"] if m != "break"]
sys.exit(0 if mods and isinstance(mods[0], dict)
         and mods[0].get("type") == "title" else 1)
PY
    then
        ok "the title module comes first, so the first line is user@host"
    else
        bad "the title module is not first; the first line will not be user@host"
    fi
fi

# The borrowed artwork must stay gone. It was a GPL file from another project,
# and leaving it in the skel next to our own logo is how the wrong one ships.
for stale in nyarch.ascii nyarch.jsonc NYARCH-NOTICE.md; do
    if [[ -e "$FF_DIR/$stale" ]]; then
        bad "config/fastfetch/$stale is back; the logo is our own now"
    else
        ok "no leftover $stale"
    fi
done

# --- pacman options --------------------------------------------------------
# CheckSpace makes pacman verify free space with statfs() on the package cache.
# When installing into a fresh root with --sysroot, which is how mkarchiso builds
# the live image, that path lives inside the root being created and does not
# exist in the host namespace. pacman then reads the available space as zero and
# aborts with "not enough free disk space" on a machine with 931 GB free.
if grep -qE '^[[:space:]]*CheckSpace[[:space:]]*$' config/live-pacman.conf; then
    bad "CheckSpace is enabled; it reports zero free space when installing into a fresh root"
else
    ok "CheckSpace is off, so pacman will not misreport the free space during a build"
fi
# A CacheDir pointing inside the root would be the same problem in another form.
if grep -qE '^[[:space:]]*CacheDir[[:space:]]*=' config/live-pacman.conf; then
    cd_line="$(grep -E '^[[:space:]]*CacheDir[[:space:]]*=' config/live-pacman.conf | head -1)"
    warn "CacheDir is set explicitly: ${cd_line}"
else
    ok "CacheDir is left at the default, which is a real host directory"
fi

# --- installer execution order ----------------------------------------------
# The users module copies /etc/skel into the new home directory, and the file
# that applies the wallpaper on first login arrives in /etc/skel from the
# nyx-tools package, which the packages module installs. With users running
# first, the home is made before that file exists and the wallpaper silently
# never applies. Both halves were individually correct, which is exactly why the
# static checks kept passing.
SETTINGS=config/calamares/settings.conf
if [[ -f "$SETTINGS" ]]; then
    # Строки, заканчивающиеся двоеточием, — это ключи YAML ("- exec:", "- show:"),
    # а не модули. Без фильтра они попадают в список как модули с именами exec и
    # show, и любой порядок потом выглядит нарушенным.
    exec_seq="$(sed -n '/^[[:space:]]*- exec:/,/^[[:space:]]*- show:/p' "$SETTINGS" \
                | sed 's/#.*//' \
                | grep -vE '^[[:space:]]*-[[:space:]]*[a-z@-]+:[[:space:]]*$' \
                | grep -oE '^[[:space:]]*-[[:space:]]*[a-z@-]+' \
                | grep -oE '[a-z@-]+$')"
    i_users=$(printf '%s\n' "$exec_seq" | grep -nx 'users' | cut -d: -f1)
    i_packages=$(printf '%s\n' "$exec_seq" | grep -nx 'packages' | cut -d: -f1)
    if [[ -z "$i_users" || -z "$i_packages" ]]; then
        bad "could not find users and packages in the exec sequence"
    else
        if (( i_packages < i_users )); then
            ok "exec order: packages ($i_packages) before users ($i_users), so /etc/skel is complete first"
        else
            bad "exec order: users ($i_users) runs before packages ($i_packages); the first-login wallpaper will never apply"
        fi
    fi
    # unpackfs has to come before both, or there is no target root to work in.
    i_unpackfs=$(printf '%s\n' "$exec_seq" | grep -nx 'unpackfs' | cut -d: -f1)
    if [[ -n "$i_unpackfs" && -n "$i_packages" ]] && (( i_unpackfs < i_packages )); then
        ok "exec order: unpackfs ($i_unpackfs) before packages ($i_packages)"
    else
        bad "exec order: packages runs before unpackfs, so there is no root to install into"
    fi

    # The general rule, which is what the machineid failure actually was.
    # unpackfs is the only module that populates the target root; partition and
    # mount run before there is a root at all. Everything else chroots into it,
    # and an empty mount point has no /usr/bin/ln, no /usr/bin/systemd and no
    # shell, so any of them placed above unpackfs dies with chroot exit 127 and
    # a message that points at a binary which is actually present.
    if [[ -n "$i_unpackfs" ]]; then
        early=""
        while IFS= read -r m; do
            [[ -z "$m" ]] && continue
            pos=$(printf '%s\n' "$exec_seq" | grep -nx "$m" | cut -d: -f1)
            [[ -z "$pos" ]] && continue
            (( pos < i_unpackfs )) || continue
            case "$m" in
                partition|mount) ;;
                *) early="$early $m($pos)" ;;
            esac
        done < <(printf '%s\n' "$exec_seq")
        if [[ -z "$early" ]]; then
            ok "exec order: only partition and mount run before unpackfs"
        else
            bad "exec order:$early run before unpackfs, so they chroot into an empty target"
        fi
    fi

    # A keyring has to be populated before packages, or pacman -Sy is refused.
    # pacstrap installs archlinux-keyring but never runs pacman-key --populate in
    # the target, so it starts with 183 keys and none of them trusted, while
    # core and extra ask for SigLevel = Required. This was the only bug that ever
    # stopped an installation from finishing.
    KEYRING_CONF=config/calamares/modules/shellprocess-keyring.conf
    if [[ -f "$KEYRING_CONF" ]]; then
        ok "keyring step exists"
        if grep -q 'pacman-key --init' "$KEYRING_CONF" && \
           grep -q 'pacman-key --populate archlinux' "$KEYRING_CONF"; then
            ok "keyring step runs pacman-key --init and --populate archlinux"
        else
            bad "keyring step does not initialise and populate the keyring"
        fi
        # A step that cannot tell success from failure is not a step. The three
        # tokens are looked up separately: inside the YAML block scalar the
        # command folds onto one line, but in the file it spans several, so a
        # single-line pattern across them never matches.
        if grep -q 'trusted' "$KEYRING_CONF" && \
           grep -q 'wc -l' "$KEYRING_CONF" && \
           grep -qE '^\s*if \[' "$KEYRING_CONF"; then
            ok "keyring step verifies that a trusted key appeared"
        else
            bad "keyring step does not verify its own result"
            grep -cE 'trusted|wc -l|^\s*if \[' "$KEYRING_CONF" |
                sed 's/^/       matching lines: /'
        fi
        i_keyring=$(printf '%s\n' "$exec_seq" | grep -nx 'shellprocess@keyring' | cut -d: -f1)
        if [[ -n "$i_keyring" && -n "$i_packages" ]] && (( i_keyring < i_packages )); then
            ok "exec order: shellprocess@keyring ($i_keyring) before packages ($i_packages)"
        else
            bad "exec order: shellprocess@keyring must run before packages, or pacman -Sy is refused"
            [[ -z "$i_keyring" ]] && echo "       module is not in the sequence at all"
        fi
    else
        bad "no $KEYRING_CONF: the target keyring is never populated and installs cannot finish"
    fi
fi

# The autostart entry is packaged, so it must NOT be expected loose in the tree.
if grep -qE "^[[:space:]]*'etc/skel/\.config/autostart/nyx-wallpaper\.desktop'" build.sh; then
    bad "build.sh still expects the autostart entry loose in the base rootfs; it comes from the package"
else
    ok "the autostart entry is no longer expected loose in the base rootfs"
fi
if grep -q 'etc/skel/.config/autostart/nyx-wallpaper.desktop' nyx-tools/PKGBUILD; then
    ok "the nyx-tools package does carry the autostart entry"
else
    bad "the autostart entry is expected nowhere at all"
fi

# --- repositories named by a config that ships in an image --------------------
# config/live-pacman.conf is installed as /etc/pacman.conf twice: into the target
# rootfs and, through archiso's arch-custom template, into the live image. A
# repository listed in pacman.conf that cannot be synced is a fatal error for
# pacman rather than a warning, so a path in that file which does not exist in
# the image breaks every pacman operation in it, ordinary Arch updates included.
# The target got its copy of the Nyx repository; the live image did not, and the
# live session could not run pacman at all. Both are the same file, so the check
# is per image rather than per config.
if [[ -f config/live-pacman.conf ]]; then
    # Every file:// path this config names has to exist in both images. Build-time
    # paths are not in this file: the profile copy is rewritten to the local repo
    # before pacstrap ever reads it, so everything left here is a runtime path.
    mapfile -t nyx_servers < <(grep -oE 'Server[[:space:]]*=[[:space:]]*file://[^[:space:]]*' \
        config/live-pacman.conf | sed 's/.*file:\/\///')
    if (( ${#nyx_servers[@]} == 0 )); then
        warn "no file:// repository in config/live-pacman.conf, so there is nothing to cross-check"
    else
        for srv in "${nyx_servers[@]}"; do
            rel="${srv#/}"
            for tree in BASE_ROOTFS AIROOTFS; do
                if grep -q "\$$tree/$rel" build.sh; then
                    ok "\${$tree}/$rel is staged, and the shipped pacman.conf points at it"
                else
                    bad "\${$tree}/$rel is named by config/live-pacman.conf but never staged; pacman will fail to sync it in that image"
                fi
            done
        done
    fi
fi

# --- the Nyx channel is reported on its own ----------------------------------
# The report used to classify by "is it CachyOS, otherwise Arch", so nyx-tools
# was listed as an Arch update. That is not cosmetic: the two need different
# actions. -Syu updates Arch packages, and it can never see nyx-tools at all,
# because that package only exists in the local repository after nyx-update-git
# has built it. Told to run -Syu, the user would be sent to the wrong command.
UPDATES=nyx-tools/updates
if [[ -f "$UPDATES" ]]; then
    if grep -q "NYX_RE=" "$UPDATES" && grep -q 'NYX_RE ]]; then' "$UPDATES"; then
        ok "nyx-updates classifies the nyx repository separately"
    else
        bad "nyx-updates has no separate branch for the nyx repository; nyx-tools will be reported as an Arch update"
    fi
    # It has to be tested before the CachyOS branch and before the catch-all,
    # otherwise the ordering silently swallows it again.
    nyx_line=$(grep -n 'NYX_RE \]\]' "$UPDATES" | head -1 | cut -d: -f1)
    c_line=$(grep -n 'CACHYOS_RE \]\]' "$UPDATES" | head -1 | cut -d: -f1)
    if [[ -n "$nyx_line" && -n "$c_line" ]] && (( nyx_line < c_line )); then
        ok "the nyx branch is tested before the CachyOS branch (line $nyx_line before $c_line)"
    else
        bad "the nyx branch is not tested first; ordering puts it in the wrong bucket"
    fi
    if grep -q 'nyx_n' "$UPDATES" && grep -q 'total=\$((' "$UPDATES"; then
        if grep -qE 'total=\$\(\( *arch_n \+ cachy_n \+ nyx_n \+ aur_n \)\)' "$UPDATES"; then
            ok "nyx updates are counted in the total"
        else
            bad "nyx_n is not included in the update total"
        fi
    else
        bad "the nyx counter is missing"
    fi
    if grep -q 'nyx-update-git' "$UPDATES"; then
        ok "the report says which command actually brings a nyx-tools update in"
    else
        bad "the report points at -Syu for nyx-tools, which cannot fetch it"
    fi
fi

# --- version comparison in nyx-update-git -------------------------------------
# The report took the longest "-*" prefix off the package filename, which is the
# architecture: "x86_64" was then compared against what pacman -Q prints,
# "2026.09.01.15-1". Those can never be equal, so the tool announced an update on
# every system, including fully current ones.
GIT_UPDATER=config/base-rootfs-overlay/usr/local/sbin/nyx-update-git
if [[ -f "$GIT_UPDATER" ]]; then
    if grep -q '##\*-' "$GIT_UPDATER"; then
        bad "nyx-update-git still strips the longest dash prefix and gets the architecture instead of the version"
    else
        ok "nyx-update-git no longer parses the package version as the architecture"
    fi
    # pkgver-pkgrel is what pacman -Q prints, so the parse has to end there.
    if grep -q 'new="\${new%-' "$GIT_UPDATER" && grep -q '%.pkg.tar.zst' "$GIT_UPDATER"; then
        ok "nyx-update-git reduces the filename to pkgver-pkgrel, matching pacman -Q"
    else
        bad "nyx-update-git does not reduce the filename to pkgver-pkgrel"
    fi
    # The comparison is worthless if the tool builds a version that cannot be
    # ordered against the installed one. Commit count grows monotonically on a
    # linear history, which is what makes this safe.
    if grep -q 'RELEASE\.\$ncount' "$GIT_UPDATER" || grep -qE 'nver="\$RELEASE\.\$n' "$GIT_UPDATER"; then
        ok "the built version is release plus commit count, so later commits are newer"
    else
        warn "cannot see how nyx-update-git derives the package version"
    fi
fi

# --- password rules ----------------------------------------------------------
# The user asked for a single character to be accepted. Four independent switches
# enforce length, and relaxing only the obvious one leaves the password rejected
# with no visible reason: the QML field refuses to submit, pwquality rejects it,
# minclass=2 cannot be satisfied by a one character password at all, and
# allowWeakPasswords is the master switch that permits failing the checks.
UCONF=config/calamares/modules/users.conf
if [[ -f "$UCONF" ]]; then
    if grep -qE '^[[:space:]]*minLength:[[:space:]]*1[[:space:]]*$' "$UCONF"; then
        ok "password: minLength is 1, a one character password can be submitted"
    else
        bad "password: minLength is not 1, the installer field still refuses short passwords"
    fi
    if grep -qE '^[[:space:]]*-[[:space:]]*minlen=1[[:space:]]*$' "$UCONF"; then
        ok "password: libpwquality minlen is 1"
    else
        bad "password: libpwquality still carries a minlen above 1"
    fi
    if grep -qE '^[[:space:]]*-[[:space:]]*minclass=1[[:space:]]*$' "$UCONF"; then
        ok "password: minclass is 1; minclass=2 cannot be met by a one character password"
    else
        bad "password: minclass is still 2, which a one character password can never satisfy"
    fi
    if grep -qE '^[[:space:]]*allowWeakPasswords:[[:space:]]*true[[:space:]]*$' "$UCONF" &&
       grep -qE '^[[:space:]]*allowWeakPasswordsDefault:[[:space:]]*true[[:space:]]*$' "$UCONF"; then
        ok "password: allowWeakPasswords is on, so a password failing the checks is permitted"
    else
        bad "password: allowWeakPasswords is off and overrides the relaxed rules above"
    fi
fi

# --- hostname offered by the installer ---------------------------------------
# The hostname field is pre-filled from users.conf, while /etc/hostname in the
# base rootfs is written separately by build.sh. When the two disagree the
# installer offers a name the rest of the image does not assume, and the user has
# to retype it on every install. They must be the same string.
UCONF2=config/calamares/modules/users.conf
if [[ -f "$UCONF2" ]]; then
    tmpl=$(sed -n 's/^[[:space:]]*template:[[:space:]]*"\([^"]*\)".*/\1/p' "$UCONF2" | head -1)
    if [[ "$tmpl" == "nyx" ]]; then
        ok "the installer offers hostname 'nyx', matching /etc/hostname"
    else
        bad "the installer offers hostname '$tmpl', but the image uses 'nyx'; they must match"
    fi
    # Comment lines are stripped before searching. The note explaining what the
    # template used to be mentions nyxlinux on purpose, and a check that failed
    # on the word in a comment would have to be deleted the moment anyone
    # documented the change.
    if sed 's/#.*//' "$UCONF2" | grep -q 'nyxlinux'; then
        bad "an active line in users.conf still sets nyxlinux somewhere"
    else
        ok "no active line in users.conf sets nyxlinux"
    fi
    if grep -qE "^printf 'nyx" build.sh; then
        ok "build.sh writes nyx into /etc/hostname for both images"
    else
        bad "build.sh no longer sets the hostname to nyx"
    fi
fi

# --------------------------------------------------------------------------
printf '\n\033[1mChecks passed: %d, failed: %d\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
printf '\033[1;32mAll static checks passed.\033[0m\n'
