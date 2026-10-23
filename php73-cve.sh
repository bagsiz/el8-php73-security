#!/bin/bash
# Patched PHP 7.3 packages for CVE-2026-109618 / CVE-2026-109619 (Remi SCL, EL8: Rocky/Alma/RHEL 8)
#
# Usage:
#   ./php73-cve.sh status              show the PHP installs on this server and their patch status
#   ./php73-cve.sh install [-y]        upgrade the installed PHP 7.3 packages to the patched version
#   ./php73-cve.sh uninstall [-y]      roll back to the versions installed before
#
# Install type handled: Remi's SCL packages php73-php-* (/opt/remi/php73, php73-php-fpm
# service). Other PHP installs (AppStream php 7.2/7.4, Remi module php:remi-7.3 ...) are
# shown by "status" but left as they are.
# Only PHP packages that are already installed are changed. Packages not shipped here
# (PECL extensions such as apcu/imagick/mcrypt/zip, php-pear, php73-runtime, ionCube ...)
# are left as they are.
# If verification fails after install, the upgrade is rolled back automatically.
#
# USE AT YOUR OWN RISK. Unofficial rebuilds of Remi's PHP 7.3 packages, provided
# "AS IS", WITHOUT WARRANTY OF ANY KIND. The authors are not liable for any damage.
# See README.md and LICENSE: https://github.com/bagsiz/el8-php73-security
set -uo pipefail

PATCHED_VR=7.3.33-22.1.el8
CVE=CVE-2026-109618
HERE=$(cd "$(dirname "$0")" && pwd)
STATE_ROOT=/var/lib/php73-cve-2026

# The RPMs are GitHub release assets: when rpms/scl is missing, the archive is
# downloaded and checked against the SHA256 below. Without access (no internet), download
# the archive by hand and put it next to this script.
RELEASE_URL=${PHP73CVE_RELEASE_URL:-https://github.com/bagsiz/el8-php73-security/releases/download/v7.3.33-22.1}
SHA256_scl=8218369b77806ca7aa2a6a9ddfa65a1655293b25ff5f60aa38744b130b13c1f5

# rpmrebuild + rpm-build for every EL8 rpm version (rpm-build must match the installed rpm
# exactly; servers on an old minor release cannot get it from the current repositories).
# Same release.
TOOLS_ASSET=el8-rpmrebuild-tools.tar.gz
SHA256_tools=3b689e57364d2a87331e1b0c7c79157c4dde538db4905174614812ddcea9ce98
TOOLS_DIR=$HERE/tools
# backup_rpm runs in a subshell ($(...)): state shared with it lives in files
TOOLS_STATE=$(mktemp)      # names of the tool packages this script installed
RR_FILTER=$(mktemp)        # rpmrebuild %files filter, see ensure_rpmrebuild

# Network timeouts (seconds). curl gives up when it cannot connect, or when the download
# stalls (below 1 KB/s), for NET_TIMEOUT seconds; a slow but moving download is not cut off.
# dnf: per-request timeout, one retry, unreachable repositories are skipped (servers on
# an old minor release often still list mirrors that are gone).
NET_TIMEOUT=${PHP73CVE_NET_TIMEOUT:-10}
CURL_NET=(--connect-timeout "$NET_TIMEOUT" --speed-time "$NET_TIMEOUT" --speed-limit 1024)
DNF_NET=(--setopt=timeout="$NET_TIMEOUT" --setopt=retries=1 --setopt=skip_if_unavailable=True)

# packages that have a patched build
PKGS_scl="php73-php php73-php-bcmath php73-php-cli php73-php-common php73-php-dba php73-php-dbg php73-php-devel php73-php-embedded php73-php-enchant php73-php-fpm php73-php-gd php73-php-gmp php73-php-imap php73-php-interbase php73-php-intl php73-php-json php73-php-ldap php73-php-litespeed php73-php-mbstring php73-php-mysqlnd php73-php-odbc php73-php-opcache php73-php-pdo php73-php-pdo-dblib php73-php-pgsql php73-php-process php73-php-pspell php73-php-recode php73-php-snmp php73-php-soap php73-php-sodium php73-php-tidy php73-php-xml php73-php-xmlrpc"

ASSUME_YES=0
CMD=${1:-status}
[ "${2:-}" = "-y" ] && ASSUME_YES=1

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "$1 [y/N] " a
    [ "$a" = y ] || [ "$a" = Y ]
}

# per install type settings
set_mode() {
    MODE=$1
    case $MODE in
    scl)
        TITLE="php73 (Remi SCL)"
        COMMON=php73-php-common
        GLOBS="php73-php php73-php-*"
        PHP=/opt/remi/php73/root/usr/bin/php
        FPM=/opt/remi/php73/root/usr/sbin/php-fpm
        CONF_PATHS="etc/opt/remi/php73 etc/httpd/conf.d/php73-php.conf"
        SERVICES="php73-php-fpm httpd"
        ;;
    esac
    RPM_DIR=$HERE/rpms/$MODE
    STATE_DIR=$STATE_ROOT/$MODE
    eval "PKGS=\$PKGS_$MODE ASSET_SHA=\$SHA256_$MODE"
    ASSET=php73-rpms-$MODE.tar.gz
}

has_patched() { # NAME: is there a patched build of this package
    case " $PKGS " in *" $1 "*) return 0 ;; esac
    return 1
}

# when rpms/<mode> is missing: download the release archive, verify it, extract it
fetch_rpms() {
    [ -f "$RPM_DIR/SHA256SUMS" ] && return 0
    local f=$HERE/$ASSET
    if [ ! -f "$f" ]; then
        say "Downloading RPMs: $RELEASE_URL/$ASSET"
        local rc=0
        curl -fL "${CURL_NET[@]}" -o "$f.part" "$RELEASE_URL/$ASSET" && mv "$f.part" "$f" || rc=$?
        if [ "$rc" != 0 ]; then
            rm -f "$f.part"
            # 35/60: TLS handshake / certificate not trusted (outdated CA bundle)
            case $rc in 35|51|58|60|77)
                warn "TLS/certificate error (curl exit $rc): update the CA bundle with 'dnf update ca-certificates', or download the file on another machine" ;;
            esac
            die "could not download $ASSET. Download it from the release by hand, put it in $HERE/ and run again"
        fi
    fi
    echo "$ASSET_SHA  $f" | sha256sum --quiet -c - || die "$ASSET SHA256 mismatch (corrupted or modified); delete it and download again"
    tar xzf "$f" -C "$HERE" || die "could not extract $ASSET"
}

# PHP 7.3 install types on this server (scl)
detect_modes() {
    rpm -q php73-php-common >/dev/null 2>&1 && echo scl
    return 0
}

# package name -> install type: scl | description of an unsupported install
classify_pkg() { # NAME VERSION
    case "$1" in
        php73-php|php73-php-*)          echo scl ;;
        php73w*|mod_php73w*)            echo "Webtatic php73w (not supported)" ;;
        php73u*|mod_php73u*)            echo "IUS php73u (not supported)" ;;
        php|php-cli|php-fpm|php-cgi|php-common)
            case "$2" in 7.3.*) echo "PHP $2 from the php module stream (not supported, only php73-php-*)" ;; *) echo "PHP $2 (not 7.3)" ;; esac ;;
        php[0-9]*-php*)                 echo "Remi SCL ${1%%-*} (not 7.3)" ;;
        *)                              echo "package $1 (not recognized)" ;;
    esac
}

# owner of a file: "rpm NAME VERSION", "dpkg NAME" or "none"
owner_of() { # PATH
    local q
    if command -v rpm >/dev/null 2>&1 && q=$(rpm -qf --qf '%{NAME} %{VERSION}\n' "$1" 2>/dev/null | head -1); then
        echo "rpm $q"
    elif command -v dpkg >/dev/null 2>&1 && q=$(dpkg -S "$1" 2>/dev/null | head -1 | cut -d: -f1); then
        echo "dpkg $q"
    else
        echo none
    fi
}

php_version_of() { # BINARY (php / php-fpm / php-cgi)
    local v
    v=$("$1" -v 2>/dev/null | head -1) || true
    v=${v#PHP }; echo "${v%% *}"
}

# Finds every PHP on the server and how it is used.
# Each line: TYPE|DESCRIPTION   (TYPE: scl or - )
discover() {
    local cands=() p real own ver kind how pid exe conf mod f cmd
    local -A hows=() order=()
    local n=0
    local names="php php73 php7.3 php-fpm php-fpm74 php-fpm7.3 php73-php-fpm php-cgi php-cgi74 php-cgi7.3"
    for p in $names; do
        f=$(command -v "$p" 2>/dev/null) && cands+=("$f|command '$p'")
    done
    for f in /usr/bin/php* /usr/sbin/php-fpm* /usr/local/bin/php* /usr/local/sbin/php-fpm* \
             /opt/remi/php*/root/usr/bin/php /opt/remi/php*/root/usr/sbin/php-fpm \
             /usr/local/php*/bin/php /usr/local/php*/sbin/php-fpm /opt/php*/bin/php /opt/php*/sbin/php-fpm; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        # interpreters only: php, php73, php7.3, php-cgi*, php73-cgi, php-fpm* (not phpize, php-config, phar)
        case "${f##*/}" in
            php|php[0-9]|php[0-9][0-9]|php[0-9].[0-9]|php-fpm*|php-cgi*|php[0-9]*-cgi) cands+=("$f|$f") ;;
        esac
    done
    # running php-fpm master processes: title "php-fpm: master process (conf)";
    # if the title was not changed, the first argument of the command line is the php-fpm path
    local ppid_
    for p in /proc/[0-9]*; do
        cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
        pid=${p#/proc/}
        exe=$(readlink -f "$p/exe" 2>/dev/null)
        case "$cmd" in
            "php-fpm: master"*) ;;
            /*)
                case "${cmd%% *}" in */php-fpm*) ;; *) continue ;; esac
                # master: a process whose parent is not php-fpm
                ppid_=$(awk '/^PPid:/{print $2}' "$p/status" 2>/dev/null)
                case "$(tr '\0' ' ' < "/proc/$ppid_/cmdline" 2>/dev/null)" in *php-fpm*) continue ;; esac
                [ -n "$exe" ] || exe=${cmd%% *}
                ;;
            *) continue ;;
        esac
        [ -n "$exe" ] || continue
        conf=$(echo "$cmd" | sed -n 's/.*(\(.*\)).*/\1/p')
        cands+=("$exe|RUNNING: php-fpm master pid $pid${conf:+ ($conf)}")
    done
    # PHP module loaded by Apache (mod_php)
    for f in /etc/httpd/conf.modules.d/*.conf /etc/httpd/conf.d/*.conf; do
        [ -f "$f" ] || continue
        while read -r mod; do
            [ -n "$mod" ] || continue
            case "$mod" in /*) ;; *) mod=/etc/httpd/$mod ;; esac
            cands+=("$(readlink -f "$mod")|Apache module ($f)")
        done < <(sed -n 's/^[[:space:]]*LoadModule[[:space:]]\+php[0-9_]*module[[:space:]]\+\([^[:space:]]\+\).*/\1/p' "$f")
    done

    # merge paths that lead to the same real file into one line
    [ ${#cands[@]} -gt 0 ] || return 0
    for p in "${cands[@]}"; do
        f=${p%%|*}; how=${p#*|}
        real=$(readlink -f "$f" 2>/dev/null || echo "$f")
        [ "$how" = "$f" ] && { [ "$f" = "$real" ] && how="" || how="link: $f"; }
        if [ -z "${order[$real]+x}" ]; then order[$real]=$n; n=$((n+1)); hows[$real]=$how
        elif [ -n "$how" ]; then
            case "; ${hows[$real]}; " in *"; $how; "*) ;; *) hows[$real]="${hows[$real]:+${hows[$real]}; }$how" ;; esac
        fi
    done

    for real in $(for r in "${!order[@]}"; do echo "${order[$r]} $r"; done | sort -n | cut -d' ' -f2-); do
        how=${hows[$real]}
        own=$(owner_of "$real")
        case "$real" in *.so) ver="" ;; *) ver=$(php_version_of "$real") ;; esac
        case "$own" in
            rpm\ *) set -- $own; kind=$(classify_pkg "$2" "$3"); [ -z "$ver" ] && ver=$3 ;;
            dpkg\ *) kind="Debian/Ubuntu package ${own#dpkg } (not supported)" ;;
            *) kind="not owned by any package: built from source / copied by hand (not supported)" ;;
        esac
        f="$real  [PHP ${ver:-?}]${how:+  ($how)}"
        case "$kind" in scl) echo "$kind|$f" ;;
                        *)        echo "-|$f : $kind" ;; esac
    done
}

print_discovery() {
    local line k found=0
    say "PHP on this server"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        found=1; k=${line%%|*}
        case $k in
            scl) echo "  [patchable ] ${line#*|}" ;;
            *)   echo "  [left as is] ${line#*|}" ;;
        esac
    done < <(discover)
    [ "$found" = 1 ] || echo "  (no PHP found)"
}

# "NAME VERSION-RELEASE" lines
installed_pkgs() {
    rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' $GLOBS | sort
}

is_patched() { # NAME
    [ "$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null)" = "$PATCHED_VR" ]
}

# Back up the RPM of an installed version, for rollback. Sources, in order:
#   cache  : the dnf cache (/var/cache/dnf, when keepcache=1 or downloaded earlier)
#   repo   : the repositories (dnf download)
#   rebuild: rpmrebuild, rebuilds the RPM from the RPM database and the files on disk.
#            Unsigned; config files go in as they are now (that is what a rollback needs).
# Prints the source used; returns 1 if none worked.
# PHP73CVE_BACKUP_SOURCES limits the sources (testing); PHP73CVE_NO_DOWNLOAD=1 disables all.
backup_rpm() { # NAME VERSION-RELEASE DESTDIR
    local name=$1 vr=$2 dest=$3 nevra="$1-$2.x86_64" src f tmp
    local sources=${PHP73CVE_BACKUP_SOURCES:-cache repo rebuild}
    [ -n "${PHP73CVE_NO_DOWNLOAD:-}" ] && sources=""
    for src in $sources; do
        case $src in
        cache)
            while IFS= read -r f; do
                [ "$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$f" 2>/dev/null)" = "$nevra" ] || continue
                rpm -K --nosignature "$f" >/dev/null 2>&1 || continue
                cp "$f" "$dest/$nevra.rpm" && { echo cache; return 0; }
            done < <(find /var/cache/dnf /var/cache/yum -name "$nevra.rpm" 2>/dev/null)
            ;;
        repo)
            dnf "${DNF_NET[@]}" -q download --destdir "$dest" "$nevra" >/dev/null 2>&1 && [ -f "$dest/$nevra.rpm" ] && { echo repo; return 0; }
            ;;
        rebuild)
            ensure_rpmrebuild || continue
            tmp=$(mktemp -d)
            # SHA256 file digests and xz payload like the original packages (normally set by
            # redhat-rpm-config, which the bundled tools do not pull in); files missing on
            # disk (docs not installed, deleted by hand) are dropped from %files
            if rpmrebuild --batch --notest-install \
                    --define '_binary_filedigest_algorithm 8' --define '_binary_payload w9.xzdio' \
                    --change-spec-files="$RR_FILTER" --directory="$tmp" "$name" >/dev/null 2>&1; then
                f=$(find "$tmp" -name "$nevra.rpm" | head -1)
                [ -n "$f" ] && mv "$f" "$dest/$nevra.rpm" && { rm -rf "$tmp"; echo rebuild; return 0; }
            fi
            rm -rf "$tmp"
            ;;
        esac
    done
    return 1
}

# Make rpmrebuild usable: already installed, else the bundled tools from the release
# (rpm-build matching this server's rpm + rpmrebuild, installed with --nodeps: rebuilding
# installed files needs neither perl, gdb nor redhat-rpm-config), else dnf (EPEL).
# Packages installed here are removed again by cleanup_tools.
ensure_rpmrebuild() {
    local f r add=()
    if [ ! -s "$RR_FILTER" ]; then
        cat > "$RR_FILTER" <<'FILTER'
#!/bin/bash
while IFS= read -r line; do
    p=$(printf '%s\n' "$line" | sed -n 's/.*"\(\/[^"]*\)"[[:space:]]*$/\1/p')
    if [ -n "$p" ] && [ ! -e "$p" ] && [ ! -L "$p" ]; then continue; fi
    printf '%s\n' "$line"
done
FILTER
        chmod +x "$RR_FILTER"
    fi
    command -v rpmrebuild >/dev/null 2>&1 && command -v rpmbuild >/dev/null 2>&1 && return 0

    if [ ! -f "$TOOLS_DIR/SHA256SUMS" ]; then
        f=$HERE/$TOOLS_ASSET
        if [ ! -f "$f" ]; then
            curl -fsL "${CURL_NET[@]}" -o "$f.part" "$RELEASE_URL/$TOOLS_ASSET" && mv "$f.part" "$f"
            rm -f "$f.part"
        fi
        if [ -f "$f" ] && echo "$SHA256_tools  $f" | sha256sum --quiet -c - >/dev/null 2>&1; then
            tar xzf "$f" -C "$HERE" 2>/dev/null
        fi
    fi
    if [ -f "$TOOLS_DIR/SHA256SUMS" ] && (cd "$TOOLS_DIR" && sha256sum --quiet -c SHA256SUMS >/dev/null 2>&1); then
        r=$(rpm -q --qf '%{VERSION}-%{RELEASE}' rpm)
        if ! rpm -q rpm-build >/dev/null 2>&1; then
            [ -f "$TOOLS_DIR/rpm-build-$r.x86_64.rpm" ] && add+=("$TOOLS_DIR/rpm-build-$r.x86_64.rpm")
        fi
        if ! rpm -q rpmrebuild >/dev/null 2>&1; then
            for f in "$TOOLS_DIR"/rpmrebuild-*.noarch.rpm; do [ -f "$f" ] && add+=("$f"); done
        fi
        if [ ${#add[@]} -gt 0 ] && rpm -i --nodeps "${add[@]}" >/dev/null 2>&1; then
            for f in "${add[@]}"; do rpm -qp --qf '%{NAME}\n' "$f" 2>/dev/null >> "$TOOLS_STATE"; done
        fi
        command -v rpmrebuild >/dev/null 2>&1 && command -v rpmbuild >/dev/null 2>&1 && return 0
    fi
    dnf "${DNF_NET[@]}" -y -q install rpmrebuild >/dev/null 2>&1
    command -v rpmrebuild >/dev/null 2>&1 && command -v rpmbuild >/dev/null 2>&1
}

# remove the rpm-build/rpmrebuild packages installed by ensure_rpmrebuild
cleanup_tools() {
    if [ -s "$TOOLS_STATE" ]; then
        rpm -e --nodeps $(sort -u "$TOOLS_STATE") >/dev/null 2>&1
        : > "$TOOLS_STATE"
    fi
}
trap 'cleanup_tools; rm -f "$TOOLS_STATE" "$RR_FILTER"' EXIT

active_services() {
    local s
    for s in $SERVICES; do
        systemctl is-active --quiet "$s" >/dev/null 2>&1 && echo "$s"
    done
}

preflight() {
    [ "$(id -u)" = 0 ] || die "run as root"
    # EL8: Rocky, AlmaLinux, RHEL, CentOS (Stream) 8, Oracle Linux 8
    ( . /etc/os-release 2>/dev/null && case " ${ID:-} ${ID_LIKE:-} " in *" rhel "*|*" centos "*) ;; *) exit 1 ;; esac \
        && case "${VERSION_ID:-}" in 8|8.*) ;; *) exit 1 ;; esac ) || die "EL8 only (Rocky/Alma/RHEL 8)"
    [ "$(uname -m)" = x86_64 ] || die "x86_64 only"
}

# post-install checks; returns 1 on failure
verify() {
    local ok=0 out
    say "Verifying ($TITLE)"
    # the cli package may be missing (e.g. only a leftover php73-php-common)
    if [ -x "$PHP" ]; then
        if out=$("$PHP" -v 2>&1); then echo "  php -v: $(echo "$out" | head -1)"; else echo "  php -v FAILED: $out"; ok=1; fi
        out=$("$PHP" -m 2>&1 | grep -iE 'warning|error|fatal|unable to')
        if [ -n "$out" ]; then echo "  php -m reported warnings/errors:"; echo "$out" | sed 's/^/    /'; ok=1; else echo "  modules: loaded without warnings"; fi
    else
        echo "  php -v / php -m: skipped ($PHP missing, cli package not installed)"
    fi
    if rpm -q --changelog "$COMMON" | grep -q "$CVE"; then echo "  changelog: contains $CVE"; else echo "  changelog: $CVE MISSING"; ok=1; fi
    if [ -x "$FPM" ]; then
        if out=$("$FPM" -t 2>&1); then echo "  php-fpm -t: ok"; else echo "  php-fpm -t FAILED:"; echo "$out" | sed 's/^/    /'; ok=1; fi
    fi
    if systemctl is-active --quiet httpd >/dev/null 2>&1 || [ -n "${HTTPD_CHECK:-}" ]; then
        if command -v apachectl >/dev/null 2>&1; then
            if out=$(apachectl -t 2>&1); then echo "  apachectl -t: ok"; else echo "  apachectl -t FAILED:"; echo "$out" | sed 's/^/    /'; ok=1; fi
        fi
    fi
    # testing only: exercise the automatic rollback path
    [ -n "${PHP73CVE_TEST_FAIL_VERIFY:-}" ] && { echo "  (test) verification forced to fail"; ok=1; }
    return $ok
}

restart_services() { # service list
    local s ok=0
    for s in "$@"; do
        say "Restarting $s"
        if systemctl restart "$s" && sleep 2 && systemctl is-active --quiet "$s" >/dev/null 2>&1; then
            echo "  $s: active"
        else
            echo "  $s: FAILED TO START"; systemctl status "$s" --no-pager -l 2>&1 | tail -15 | sed 's/^/    /'; ok=1
        fi
    done
    return $ok
}

status_mode() {
    local name vr mark
    say "Installed packages: $TITLE"
    while read -r name vr; do
        [ -n "$name" ] || continue
        if [ "$vr" = "$PATCHED_VR" ]; then mark="patched"
        elif has_patched "$name"; then mark="UNPATCHED (patched build available)"
        else mark="left as is (not shipped here)"; fi
        printf '  %-32s %-24s %s\n' "$name" "$vr" "$mark"
    done < <(installed_pkgs)
    say "Services"
    for s in $SERVICES; do printf '  %-16s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"; done
    if [ -L "$STATE_DIR/current" ]; then say "Backup of the last install: $(readlink "$STATE_DIR/current")"; fi
}

install_mode() {
    fetch_rpms
    say "Checking package integrity ($TITLE)"
    (cd "$RPM_DIR" && sha256sum --quiet -c SHA256SUMS) || die "RPM files are corrupted or modified"

    local name vr files=() upgrade=() skipped=()
    while read -r name vr; do
        [ -n "$name" ] || continue
        if is_patched "$name"; then continue; fi
        if has_patched "$name"; then
            [ -f "$RPM_DIR/$name-$PATCHED_VR.x86_64.rpm" ] || die "$RPM_DIR/$name-$PATCHED_VR.x86_64.rpm is missing"
            files+=("$RPM_DIR/$name-$PATCHED_VR.x86_64.rpm"); upgrade+=("$name $vr")
        else
            skipped+=("$name $vr")
        fi
    done < <(installed_pkgs)

    if [ ${#upgrade[@]} -eq 0 ]; then
        say "$TITLE: nothing to upgrade, the installed packages are already patched"
        return 0
    fi

    say "$TITLE: packages to upgrade (-> $PATCHED_VR)"
    printf '  %s\n' "${upgrade[@]}"
    if [ ${#skipped[@]} -gt 0 ]; then
        say "$TITLE: packages left as is"
        printf '  %s\n' "${skipped[@]}"
    fi

    if [ -x "$FPM" ] && ! "$FPM" -t >/dev/null 2>&1; then
        "$FPM" -t
        die "the php-fpm configuration is already broken BEFORE the install; fix that first"
    fi

    local services
    services=$(active_services)
    say "Services to restart after the install: ${services:-(none)}"

    confirm "Continue?" || die "aborted"

    # backup
    local backup=$STATE_DIR/backup-$(date +%Y%m%d-%H%M%S) p existing=()
    mkdir -p "$backup/rpms"
    say "Creating backup: $backup"
    printf '%s\n' "${upgrade[@]}" > "$backup/upgraded.txt"
    echo "$services" > "$backup/services.txt"
    for p in $CONF_PATHS; do [ -e "/$p" ] && existing+=("$p"); done
    if [ ${#existing[@]} -gt 0 ] && tar czf "$backup/config.tar.gz" -C / "${existing[@]}" 2>/dev/null; then
        echo "  configuration: $backup/config.tar.gz"
    fi

    # RPMs of the current versions, for rollback: dnf cache, then repositories, then rpmrebuild
    local missing=() nevra line src
    for line in "${upgrade[@]}"; do
        set -- $line
        nevra="$1-$2.x86_64"
        if src=$(backup_rpm "$1" "$2" "$backup/rpms"); then
            echo "$nevra $src" >> "$backup/sources.txt"
            printf '  %-48s %s\n' "$nevra" "$src"
        else
            missing+=("$nevra")
        fi
    done
    cleanup_tools
    echo "  RPMs of the current versions: $(( ${#upgrade[@]} - ${#missing[@]} ))/${#upgrade[@]} backed up"
    if grep -q ' rebuild$' "$backup/sources.txt" 2>/dev/null; then
        warn "some RPMs were rebuilt from the installed files with rpmrebuild (unsigned, not identical to the original)"
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        warn "These versions could not be backed up (not in the dnf cache or the repositories, rpmrebuild failed):"
        printf '    %s\n' "${missing[@]}" >&2
        warn "for these, uninstall goes back to the newest version in the repositories (unpatched)"
        confirm "Continue anyway?" || { rm -rf "$backup"; die "aborted"; }
    fi
    ln -sfn "$backup" "$STATE_DIR/current"

    say "Installing the patched packages ($TITLE)"
    if ! dnf "${DNF_NET[@]}" -y install "${files[@]}"; then
        die "dnf install failed; nothing was changed (the dnf transaction was rolled back). Backup: $backup"
    fi

    local failed=0
    verify || failed=1
    if [ "$failed" = 0 ] && [ -n "$services" ]; then
        restart_services $services || failed=1
    fi

    if [ "$failed" = 1 ]; then
        warn "Verification failed, rolling back automatically ($TITLE)"
        ASSUME_YES=1 uninstall_mode
        die "the install was rolled back"
    fi
    say "Done: $TITLE upgraded to the patched version ($PATCHED_VR)"
}

uninstall_mode() {
    if [ ! -L "$STATE_DIR/current" ]; then
        say "$TITLE: no install backup, not installed by this script; skipping"
        return 0
    fi
    local backup
    backup=$(readlink "$STATE_DIR/current")
    [ -f "$backup/upgraded.txt" ] || die "$backup/upgraded.txt is missing"

    local name vr local_rpms=() repo_pkgs=()
    while read -r name vr; do
        [ -n "$name" ] || continue
        is_patched "$name" || continue
        if [ -f "$backup/rpms/$name-$vr.x86_64.rpm" ]; then
            local_rpms+=("$backup/rpms/$name-$vr.x86_64.rpm")
        else
            repo_pkgs+=("$name")
        fi
    done < "$backup/upgraded.txt"

    if [ ${#local_rpms[@]} -eq 0 ] && [ ${#repo_pkgs[@]} -eq 0 ]; then
        say "$TITLE: no patched packages to roll back"
        rm -f "$STATE_DIR/current"; return 0
    fi

    say "$TITLE: rolling back to"
    local r s
    for r in ${local_rpms[@]+"${local_rpms[@]}"}; do
        s=$(awk -v n="$(basename "$r" .rpm)" '$1 == n {print $2}' "$backup/sources.txt" 2>/dev/null)
        printf '  %s (from backup%s)\n' "${r##*/}" "${s:+: $s}"
    done
    [ ${#repo_pkgs[@]} -gt 0 ] && printf '  %s -> newest version in the repositories\n' "${repo_pkgs[@]}"
    confirm "Continue?" || die "aborted"

    if [ ${#local_rpms[@]} -gt 0 ]; then
        rpm -Uvh --oldpackage "${local_rpms[@]}" || die "rpm downgrade failed"
    fi
    if [ ${#repo_pkgs[@]} -gt 0 ]; then
        dnf "${DNF_NET[@]}" -y downgrade "${repo_pkgs[@]}" || die "dnf downgrade failed"
    fi

    local services
    services=$(cat "$backup/services.txt" 2>/dev/null)
    [ -n "$services" ] && restart_services $services

    rm -f "$STATE_DIR/current"
    say "$TITLE rolled back. Configuration backup: $backup/config.tar.gz (not restored automatically)"
}

main() {
    local modes m
    case "$CMD" in
        status|install|uninstall) ;;
        *) sed -n '2,14p' "$0"; exit 2 ;;
    esac
    # status works on any server (report only); install/uninstall need EL8
    [ "$CMD" = status ] || preflight

    if [ "$CMD" = uninstall ]; then
        # rollback: every install type installed by this script
        modes=$(for m in scl; do [ -L "$STATE_ROOT/$m/current" ] && echo $m; done)
        [ -n "$modes" ] || die "nothing to roll back ($STATE_ROOT); nothing was installed by this script"
    else
        print_discovery
        command -v rpm >/dev/null 2>&1 && modes=$(detect_modes) || modes=""
        if [ -z "$modes" ]; then
            say "No patchable PHP 7.3 install (Remi php73-php-*)"
            [ "$CMD" = status ] && exit 0 || exit 1
        fi
    fi

    for m in $modes; do
        set_mode "$m"
        case "$CMD" in
            status)    status_mode ;;
            install)   install_mode ;;
            uninstall) uninstall_mode ;;
        esac
    done
    [ "$CMD" = install ] && say "To roll back: $0 uninstall"
    return 0
}

main
