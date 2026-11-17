#!/bin/sh
# Pinned release; update unchanged backends only when their file hashes differ.
set -eu
umask 077
VERSION=0.1.13
BACKEND_VERSION=0.1.0
BASE=https://github.com/moz9/cloudflare-warp-openwrt-podkop/releases/download/v$VERSION
fail() { echo "CF WARP: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'root required'
[ -f /etc/openwrt_release ] || fail 'OpenWrt required'
if command -v apk >/dev/null; then pm=apk
elif command -v opkg >/dev/null; then pm=opkg
else fail 'opkg or apk required'; fi
arch=$(sed -n "s/^DISTRIB_ARCH='\([^']*\)'/\1/p" /etc/openwrt_release)
[ "$arch" = aarch64_cortex-a53 ] || fail "Unsupported architecture: $arch (no changes made)"
# Existing installations must be protected even before dependency preparation.
if command -v uci >/dev/null; then [ -z "$(uci changes)" ] || fail 'Save pending LuCI changes first'; fi
if command -v flock >/dev/null; then
    exec 9>>/var/lock/warp-operation.lock
    flock -n 9 || fail 'A WARP operation is active.'
    exec 7>>/var/lock/warp-test.lock
    flock -n 7 || fail 'A WARP test is active.'
fi
installed() {
    if [ "$pm" = apk ]; then apk info -e "$1" >/dev/null 2>&1
    else opkg status "$1" 2>/dev/null | grep -q 'Status: .* installed'; fi
}
download() {
    if command -v curl >/dev/null; then curl -fsSL --retry 2 --retry-all-errors --retry-delay 1 --connect-timeout 10 --max-time 120 "$1" -o "$2"
    else wget -T 120 -qO "$2" "$1"; fi
}
# Bootstrap only missing prerequisites. Package-manager dependency changes are
# retained on application rollback; never force a kernel-module version.
missing=
for p in curl ca-bundle luci-base rpcd-mod-ucode jsonfilter flock kmod-tun; do
    installed "$p" || missing="$missing $p"
done
command -v nft >/dev/null || missing="$missing nftables-json"
if [ -x /etc/init.d/zerotier ] && ! command -v jq >/dev/null; then missing="$missing jq"; fi
if [ -n "$missing" ]; then
    echo "Installing missing prerequisites:$missing"
    if [ "$pm" = apk ]; then apk add $missing || fail 'Dependency installation failed'
    else opkg update && opkg install $missing || fail 'Dependency installation failed'; fi
fi
for cmd in curl uci flock jsonfilter nft; do command -v "$cmd" >/dev/null || fail "Missing prerequisite: $cmd"; done
exec 9>>/var/lock/warp-operation.lock
flock -n 9 || fail 'A WARP operation is active.'
exec 7>>/var/lock/warp-test.lock
flock -n 7 || fail 'A WARP stability test is active. Stop it before updating.'
[ -z "$(uci changes)" ] || fail 'Save or discard pending LuCI changes first.'
# Old-generation workers do not use flock yet.
for f in /var/lock/warp-job.lock/pid /var/lock/warp-manager.lock/pid; do
    p=$(cat "$f" 2>/dev/null || true)
    case "$p" in ''|*[!0-9]*) ;; *) kill -0 "$p" 2>/dev/null && fail 'Wait for the legacy WARP operation.' ;; esac
done
work=$(mktemp -d /tmp/cfwarp-install.XXXXXX)
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
package_file() {
    case "$1" in luci-app-warp) v=$VERSION; a=all;; *) v=$BACKEND_VERSION; a=aarch64_cortex-a53;; esac
    if [ "$pm" = apk ]; then echo "$1-$v-r1.apk"; else echo "$1"_"$v"_"$a.ipk"; fi
}
manifest=SHA256SUMS
[ "$pm" != apk ] || manifest=SHA256SUMS-APK
for f in "$manifest" FILES.sha256 INSTALL-SIZES "$(package_file warp-awg)" "$(package_file warp-warpscout)" "$(package_file luci-app-warp)"; do
    if [ -n "${WARP_BUNDLE_DIR:-}" ]; then cp "$WARP_BUNDLE_DIR/$f" "$work/$f"
    else download "$BASE/$f" "$work/$f"; fi
done
: > "$work/checked-sums"
for f in FILES.sha256 INSTALL-SIZES "$(package_file warp-awg)" "$(package_file warp-warpscout)" "$(package_file luci-app-warp)"; do
    awk -v f="$f" 'NF==2 && $2==f && length($1)==64 && $1 !~ /[^0-9a-f]/ {print}' "$work/$manifest" > "$work/one-sum"
    [ "$(wc -l < "$work/one-sum")" -eq 1 ] || fail "Missing or duplicate checksum: $f"
    cat "$work/one-sum" >> "$work/checked-sums"
done
(cd "$work" && sha256sum -c checked-sums) || fail 'Checksum mismatch'
packages='luci-app-warp'
backend_changed=0
for p in warp-awg warp-warpscout; do
    case "$p" in warp-awg) pattern='/(warp-amneziawg-go|warp-awgctl)$' ;; *) pattern='/warp-warpscout$' ;; esac
    grep -E "$pattern" "$work/FILES.sha256" > "$work/backend.sha256"
    if ! installed "$p" || ! sha256sum -c "$work/backend.sha256" >/dev/null 2>&1; then
        packages="$p $packages"
        backend_changed=1
    fi
done
# Ignore directory entries from opkg; never back up unrelated sibling files.
: > "$work/previous-files"
for p in $packages; do
    { if [ "$pm" = apk ]; then apk info -L "$p" 2>/dev/null | sed -n '\|^[a-z][^: ]*/|s|^|/|p';
      else opkg files "$p" 2>/dev/null | sed -n '\|^/|p'; fi; } | while IFS= read -r f; do
        [ "$f" != /etc/config/warp ] || continue
        [ ! -f "$f" ] && [ ! -L "$f" ] || printf '%s\n' "$f"
    done >> "$work/previous-files"
done
payload=0
for p in $packages; do
    n=$(awk -v p="$p" '$1==p {print $2}' "$work/INSTALL-SIZES")
    case "$n" in ''|*[!0-9]*) fail 'Invalid size manifest' ;; esac
    payload=$((payload+n))
done
old_size=0
while IFS= read -r f; do
    n=$(du -k "$f" | awk '{print $1}')
    old_size=$((old_size+n))
done < "$work/previous-files"
reserve=${WARP_INSTALL_RESERVE_KB:-2048}
case "$reserve" in ''|*[!0-9]*) fail 'Invalid reserve size' ;; esac
available=$(df -k /overlay | awk 'END {print $4}')
required=$((payload+old_size+reserve))
[ "$available" -ge "$required" ] || fail "Insufficient flash: need ${required} KiB, available ${available} KiB. No changes made."
backup_root=/etc/warp/backups
mkdir -p "$backup_root"
chmod 700 /etc/warp "$backup_root"
backup=$backup_root/install-$(date +%Y%m%d-%H%M%S)-$$
mkdir -m 700 "$backup"
cp "$work/previous-files" "$backup/previous-files"
if [ "$pm" = opkg ]; then cp /usr/lib/opkg/status "$backup/opkg-status"; fi
printf '%s\n' $packages > "$backup/packages"
: > "$backup/metadata-files"
for p in $packages; do
    [ "$pm" = opkg ] || continue
    for f in /usr/lib/opkg/info/"$p".*; do [ ! -f "$f" ] || printf '%s\n' "$f"; done
done > "$backup/metadata-files"
[ ! -s "$backup/metadata-files" ] || tar -czf "$backup/metadata.tar.gz" -T "$backup/metadata-files"
[ ! -s "$backup/previous-files" ] || tar -czf "$backup/previous-files.tar.gz" -T "$backup/previous-files"
# Use native APK transactions for rollback, never replace its global database.
new_packages=
if [ "$pm" = apk ]; then
    mkdir "$backup/apk"
    for p in $packages; do
        if ! installed "$p"; then new_packages="$new_packages $p"; continue; fi
        old=$(awk -v p="$p" 'BEGIN{RS="";FS="\n"} {name="";ver="";for(i=1;i<=NF;i++){if($i~/^P:/)name=substr($i,3);if($i~/^V:/)ver=substr($i,3)} if(name==p)print ver}' /lib/apk/db/installed)
        printf '%s' "$old" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$' || fail "Cannot prepare APK rollback for $p"
        oldfile="$p-$old.apk"
        if [ "$oldfile" = "$(package_file "$p")" ]; then cp "$work/$oldfile" "$backup/apk/$oldfile"
        else
            oldbase="https://github.com/moz9/cloudflare-warp-openwrt-podkop/releases/download/v${old%-r*}"
            download "$oldbase/SHA256SUMS-APK" "$work/old-sums"
            grep -F "  $oldfile" "$work/old-sums" > "$work/old-check"
            [ "$(wc -l < "$work/old-check")" -eq 1 ] || fail 'Missing rollback checksum'
            download "$oldbase/$oldfile" "$backup/apk/$oldfile"
            (cd "$backup/apk" && sha256sum -c "$work/old-check") || fail 'Rollback APK checksum mismatch'
        fi
    done
fi
config_existed=0
[ ! -e /etc/config/warp ] || { config_existed=1; cp /etc/config/warp "$backup/warp-config"; }
running=0
watchdog_running=0
[ ! -x /etc/init.d/warp ] || { /etc/init.d/warp status >/dev/null 2>&1 && running=1 || true; }
[ ! -x /etc/init.d/warp-watchdog ] || { /etc/init.d/warp-watchdog status >/dev/null 2>&1 && watchdog_running=1 || true; }
rollback_packages() {
    if [ "$watchdog_running" = 1 ]; then /etc/init.d/warp-watchdog stop || return 1; fi
    if [ "$backend_changed" = 1 ] && [ "$running" = 1 ]; then /etc/init.d/warp stop || return 1; fi
    if [ "$pm" = apk ]; then
        [ -z "$new_packages" ] || apk del $new_packages || return 1
        set -- "$backup"/apk/*.apk
        [ ! -f "$1" ] || apk add --no-network --allow-untrusted "$@" || return 1
    else
    for p in $packages; do rm -f /usr/lib/opkg/info/"$p".* || return 1; done
    if [ -f "$backup/metadata.tar.gz" ]; then tar -xzf "$backup/metadata.tar.gz" -C / || return 1; fi
    awk -v names="$packages" 'BEGIN {RS="";ORS="\n\n";split(names,n," ");for(i in n) own[n[i]]=1} {split($0,a,"\n");sub(/^Package: /,"",a[1]);if(!(a[1] in own)) print}' /usr/lib/opkg/status > "$work/status" || return 1
    awk -v names="$packages" 'BEGIN {RS="";ORS="\n\n";split(names,n," ");for(i in n) own[n[i]]=1} {split($0,a,"\n");sub(/^Package: /,"",a[1]);if(a[1] in own) print}' "$backup/opkg-status" >> "$work/status" || return 1
    cat "$work/status" > /usr/lib/opkg/status || return 1
    fi
    awk '{print $2}' "$work/FILES.sha256" | while IFS= read -r f; do
        case "$f" in /usr/libexec/warp-*|/usr/share/warp-test/*|/usr/share/rpcd/acl.d/luci-app-warp.json|/usr/share/rpcd/ucode/warp.uc|/usr/share/luci/menu.d/luci-app-warp.json|/www/luci-static/resources/view/warp/cfwarp*.js|/etc/init.d/warp|/etc/init.d/warp-watchdog|/lib/upgrade/keep.d/cfwarp) ;;
        *) continue ;; esac
        grep -Fxq "$f" "$backup/previous-files" || {
            case "$f" in
                /usr/libexec/warp-amneziawg-go|/usr/libexec/warp-awgctl) case " $packages " in *' warp-awg '*) rm -f "$f" || exit 1;; esac;;
                /usr/libexec/warp-warpscout) case " $packages " in *' warp-warpscout '*) rm -f "$f" || exit 1;; esac;;
                *) rm -f "$f" || exit 1;;
            esac
        }
    done || return 1
    if [ -f "$backup/previous-files.tar.gz" ]; then tar -xzf "$backup/previous-files.tar.gz" -C / || return 1; fi
    # Existing conffiles belong to the user; opkg preserves them. Never overwrite
    # a concurrent LuCI edit while rolling back executable files.
    if [ "$config_existed" = 0 ]; then
        cmp -s /etc/config/warp "$work/default-warp" && rm -f /etc/config/warp || true
    fi
    return 0
}
restore_runtime() {
    if [ "$backend_changed" = 1 ] && [ "$running" = 1 ]; then /etc/init.d/warp start || return 1; fi
    if [ "$watchdog_running" = 1 ]; then /etc/init.d/warp-watchdog start || return 1; fi
    return 0
}
install_started=0
install_cleanup() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$install_started" = 1 ]; then
        if rollback_packages && restore_runtime; then
            : > "$backup/complete"
            echo "Previous version restored. Backup: $backup" >&2
            /etc/init.d/rpcd restart || true
        else echo "Rollback needs attention. Backup: $backup" >&2; fi
    fi
    rm -rf "$work"
    exit "$rc"
}
trap install_cleanup EXIT
[ -z "$(uci changes)" ] || fail 'Pending configuration changes appeared during preparation.'
if [ "$pm" = opkg ]; then
    tar -xzOf "$work/luci-app-warp_${VERSION}_all.ipk" ./data.tar.gz | tar -xzO ./etc/config/warp > "$work/default-warp"
else
    # APK v2 has concatenated gzip streams; gzip -dc expands both tar segments.
    gzip -dc "$work/$(package_file luci-app-warp)" | tar -xO etc/config/warp > "$work/default-warp"
fi
install_started=1
if [ "$watchdog_running" = 1 ]; then /etc/init.d/warp-watchdog stop; fi
if [ "$backend_changed" = 1 ] && [ "$running" = 1 ]; then /etc/init.d/warp stop; fi
set --
for p in $packages; do
    set -- "$@" "$work/$(package_file "$p")"
done
if [ "$pm" = apk ]; then apk add --no-network --allow-untrusted "$@" || fail "Package installation failed. Backup: $backup"
else opkg --force-reinstall install "$@" || fail "Package installation failed. Backup: $backup"; fi
sha256sum -c "$work/FILES.sha256" || fail "Installed files differ. Backup: $backup"
restore_runtime
if [ "$running" = 1 ]; then
    iface=$(uci -q get warp.main.actual_interface)
    "${WARP_INSTALL_PROBE:-/usr/libexec/warp-probe}" "$iface" >/dev/null || fail 'WARP readiness check failed'
fi
/etc/init.d/rpcd restart
n=0
until ubus list luci.warp 2>/dev/null | grep -q '^luci.warp$'; do
    n=$((n+1)); [ "$n" -lt 10 ] || fail 'rpcd did not expose luci.warp'
    sleep 1
done
install_started=0
: > "$backup/complete"
# Only completed, owned snapshots rotate. A failed rollback is always preserved.
count=0
for old in $(ls -1d "$backup_root"/install-* 2>/dev/null | sort -r); do
    [ -f "$old/complete" ] && [ ! -L "$old" ] || continue
    [ "$(readlink -f "$old")" = "$old" ] || continue
    count=$((count+1))
    [ "$count" -le 2 ] || rm -rf -- "$old"
done
rm -f /tmp/luci-indexcache.*
echo "Installed $VERSION. Backend changed: $backend_changed. Backup: $backup"
/usr/libexec/warp-setup || fail 'Packages installed, but setup is incomplete. Fix the reported problem and rerun this command.'
