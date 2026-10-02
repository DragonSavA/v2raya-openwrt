#!/bin/sh
# Run on the router after installing v2raya and its dependencies from the feed.
set -eu
umask 077

repository='DragonSavA/v2raya-openwrt'
version='2.2.7.5-r2'
check_only=0
reinstall=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--check) check_only=1 ;;
		--reinstall) reinstall=1 ;;
		--help)
			echo 'Usage: sh install-release.sh [--check] [--reinstall]'
			echo '--check: report availability without changing the installed package.'
			echo '--reinstall: install even if the same package version is present.'
			exit 0 ;;
		*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

# The test harness supplies an isolated root and mock router commands.
router_root="${V2RAYA_TEST_ROOT:-}"
service_script="$router_root/etc/init.d/v2raya"
status_file="$router_root/usr/lib/opkg/status"
backup_dir=''
work_dir=''
lock_dir=''
install_started=0
service_stopped=0
success=0
was_running=0
was_enabled=0

log() { printf '%s\n' "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
leave_feed() {
	log "$*"
	log 'No update was installed. The existing/feed version has been left in place.'
	exit 0
}
download() {
	if command -v curl >/dev/null 2>&1; then
		curl --fail --location --retry 2 --connect-timeout 20 --max-time 300 \
			--proto '=https' --proto-redir '=https' --output "$2" "$1"
	else
		wget -T 60 -O "$2" "$1"
	fi
}
rollback() {
	log "Installation failed. Restoring the backup in $backup_dir ..." >&2
	"$service_script" stop >/dev/null 2>&1 || true
	tar -xzf "$backup_dir/files.tar.gz" -C "${router_root:-/}" || return 1
	# Restore only this package's status stanza; retain other package records.
	awk 'BEGIN { RS=""; ORS="\n\n" } $0 !~ /^Package: v2raya\n/ { print }' \
		"$status_file" > "$work_dir/status-restored" || return 1
	cat "$backup_dir/package-status.txt" >> "$work_dir/status-restored" || return 1
	cp "$work_dir/status-restored" "$status_file" || return 1
	if [ "$was_enabled" -eq 1 ]; then
		"$service_script" enable || return 1
	else
		"$service_script" disable || return 1
	fi
	if [ "$was_running" -eq 1 ]; then
		"$service_script" start || return 1
	fi
	log 'The previous binary, configuration and opkg metadata were restored.' >&2
}
cleanup() {
	code=$?
	trap - 0
	if [ "$install_started" -eq 1 ] && [ "$success" -eq 0 ]; then
		if ! rollback; then
			log "Automatic restore failed. Keep $backup_dir and follow docs/INSTALL-RU.md." >&2
		fi
	elif [ "$service_stopped" -eq 1 ] && [ "$success" -eq 0 ] && [ "$was_running" -eq 1 ]; then
		"$service_script" start >/dev/null 2>&1 || true
	fi
	[ -z "$work_dir" ] || rm -rf "$work_dir"
	[ -z "$lock_dir" ] || rmdir "$lock_dir" 2>/dev/null || true
	exit "$code"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM HUP

[ "$(id -u)" -eq 0 ] || fail 'Run this script as root.'
for cmd in opkg tar sha256sum awk sed grep mktemp df du wc uname cut tr date cp cat mkdir rm rmdir sleep; do
	command -v "$cmd" >/dev/null 2>&1 || fail "Required command is missing: $cmd"
done
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
	fail 'Install ca-bundle and wget-ssl from the firmware feed first.'
fi
[ -r "$router_root/etc/openwrt_release" ] || leave_feed 'This is not a recognized OpenWrt environment.'
if command -v fw4 >/dev/null 2>&1; then
	leave_feed 'This release targets iptables/firewall3. A firewall4 environment is outside its supported scope.'
fi
command -v fw3 >/dev/null 2>&1 || leave_feed 'No legacy firewall3 environment was detected.'

current_status="$(opkg status v2raya)" || fail 'Install v2raya from the original feed first.'
printf '%s\n' "$current_status" | grep -Eq '^Status: .* installed$' || fail 'Install v2raya from the original feed first.'
current_version="$(printf '%s\n' "$current_status" | sed -n 's/^Version: //p')"
[ -n "$current_version" ] || fail 'Cannot determine the installed version.'
if opkg compare-versions "$current_version" '>' "$version"; then
	leave_feed "Installed $current_version is newer than $version; downgrades are not automatic."
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/v2raya-release.XXXXXX")"
manifest="$work_dir/release-manifest.tsv"
if ! download "https://github.com/$repository/releases/latest/download/release-manifest.tsv" "$manifest"; then
	fail 'Cannot download a completed release. The installed package was not changed.'
fi
# Parse as data, never as shell code. Reject duplicates and unexpected fields.
awk -F '\t' '
  $1 == "package" {
    if (NF != 7 || $2 !~ /^[a-z0-9_-]+$/ || seen_arch[$2]++ ||
        $3 !~ /^[a-zA-Z0-9_.-]+\.ipk$/ || length($4) != 64 || $4 ~ /[^0-9a-f]/ ||
        $5 !~ /^[1-9][0-9]*$/ || $6 !~ /^[1-9][0-9]*$/ || $5 < 1 || $6 < 1 ||
        $5 > 536870912 || $6 > 536870912 ||
        ($7 != "router-tested" && $7 != "build-only")) exit 1
    packages++; next
  }
  $1 == "format" || $1 == "repository" || $1 == "version" ||
  $1 == "tag" || $1 == "source_commit" {
    if (NF != 2 || seen[$1]++) exit 1
    headers++
    next
  }
  { exit 1 }
  END { if (!packages || headers != 5) exit 1 }
' "$manifest" || fail 'Invalid release manifest; nothing was installed.'
[ "$(awk -F '\t' '$1 == "format" { print $2 }' "$manifest")" = 1 ] || fail 'Unsupported manifest format.'
[ "$(awk -F '\t' '$1 == "repository" { print $2 }' "$manifest")" = "$repository" ] || fail 'Unexpected release repository.'
[ "$(awk -F '\t' '$1 == "version" { print $2 }' "$manifest")" = "$version" ] || fail 'Unexpected release version.'
commit="$(awk -F '\t' '$1 == "source_commit" { print $2 }' "$manifest")"
[ "${#commit}" -eq 40 ] || fail 'Invalid source commit.'
case "$commit" in *[!0-9a-f]*) fail 'Invalid source commit.' ;; esac
tag="$(awk -F '\t' '$1 == "tag" { print $2 }' "$manifest")"
[ "$tag" = "v$version-$(printf '%.12s' "$commit")" ] || fail 'Release tag does not match the source commit.'

opkg print-architecture > "$work_dir/opkg-architectures"
row="$(awk -F '\t' '
  NR == FNR { if ($1 == "package") row[$2] = $0; next }
  { split($0, a, /[ \t]+/)
    if (a[1] == "arch" && a[3] ~ /^[0-9]+$/ && a[2] in row && (!found || a[3]+0 > priority)) {
      selected=row[a[2]]; priority=a[3]+0; found=1
    }
  }
  END { if (found) print selected }
' "$manifest" "$work_dir/opkg-architectures")"
[ -n "$row" ] || leave_feed "There is no release package for the architectures accepted by opkg ($(uname -m))."
arch="$(printf '%s\n' "$row" | cut -f2)"
filename="$(printf '%s\n' "$row" | cut -f3)"
hash="$(printf '%s\n' "$row" | cut -f4)"
package_bytes="$(printf '%s\n' "$row" | cut -f5)"
installed_bytes="$(printf '%s\n' "$row" | cut -f6)"
test_status="$(printf '%s\n' "$row" | cut -f7)"
[ "$filename" = "v2raya_${version}_${arch}.ipk" ] || fail 'Unexpected package filename.'
log "Release: $tag; architecture: $arch; installed: $current_version; available: $version."
if [ "$arch" != aarch64_cortex-a53 ] || [ "$test_status" != router-tested ]; then
	log "WARNING: $arch has build/ELF checks only. It has not been tested on a real router."
else
	log 'Device testing is reported for GL.iNet GL-MT3600BE only; other devices with this architecture still need testing.'
fi
[ "$check_only" -eq 0 ] || exit 0
if [ "$current_version" = "$version" ] && [ "$reinstall" -eq 0 ]; then
	opkg flag hold v2raya || fail 'Cannot hold the existing package.'
	log 'This package version is already installed. Use --reinstall only if you need to replace it.'
	log 'opkg hold is set to prevent accidental replacement from the feed.'
	exit 0
fi

tmp_free_kb="$(df -Pk "$work_dir" | awk 'END { print $4 }')"
[ "$tmp_free_kb" -ge "$((package_bytes / 1024 + 4096))" ] || fail 'Not enough free space in /tmp to download the package.'
package_file="$work_dir/$filename"
# Pin the package URL to the manifest tag even if Latest changes meanwhile.
download "https://github.com/$repository/releases/download/$tag/$filename" "$package_file" || fail 'Package download failed; nothing was installed.'
[ "$(wc -c < "$package_file" | tr -d ' ')" = "$package_bytes" ] || fail 'Package size mismatch.'
printf '%s  %s\n' "$hash" "$package_file" | sha256sum -c - || fail 'Checksum mismatch; nothing was installed.'
tar -xzOf "$package_file" ./control.tar.gz > "$work_dir/control.tar.gz" || fail 'Invalid IPK archive.'
tar -xzOf "$work_dir/control.tar.gz" ./control > "$work_dir/control" || fail 'Missing package metadata.'
grep -qx 'Package: v2raya' "$work_dir/control" || fail 'Unexpected package name.'
grep -qx "Version: $version" "$work_dir/control" || fail 'Unexpected package version.'
grep -qx "Architecture: $arch" "$work_dir/control" || fail 'Unexpected package architecture.'
grep -qx "Installed-Size: $installed_bytes" "$work_dir/control" || fail 'Unexpected installed size.'
if grep -Eq '^Depends: .*kmod-nft-tproxy' "$work_dir/control"; then
	fail 'Unexpected firewall4 dependency.'
fi

mkdir -p "$router_root/var/lock"
candidate_lock="$router_root/var/lock/v2raya-release-install"
mkdir "$candidate_lock" 2>/dev/null || fail 'Another release installer is running.'
lock_dir="$candidate_lock"
if [ ! -x "$service_script" ] || [ ! -x "$router_root/usr/bin/v2raya" ]; then
	fail 'The feed package installation is incomplete.'
fi
[ -r "$status_file" ] || fail 'Cannot back up opkg status.'

# Keep a persistent backup of files AND the package's opkg metadata.
set -- usr/bin/v2raya etc/init.d/v2raya etc/config/v2raya
if [ -d "$router_root/etc/v2raya" ]; then set -- "$@" etc/v2raya; fi
if [ -f "$router_root/lib/upgrade/keep.d/v2raya" ]; then set -- "$@" lib/upgrade/keep.d/v2raya; fi
for info_file in "$router_root"/usr/lib/opkg/info/v2raya.*; do
	[ -f "$info_file" ] || continue
	set -- "$@" "${info_file#"$router_root"/}"
done
backup_kb="$(cd "${router_root:-/}" && du -sk "$@" | awk '{ total += $1 } END { print total+0 }')"
persistent_free_kb="$(df -Pk "$router_root/root" | awk 'END { print $4 }')"
[ "$persistent_free_kb" -ge "$((backup_kb + installed_bytes / 1024 + 8192))" ] || fail 'Not enough persistent space for a backup and the new package.'
backup_dir="$router_root/root/v2raya-backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup_dir"
awk 'BEGIN { RS=""; ORS="\n\n" } $0 ~ /^Package: v2raya\n/ { print; count++ } END { if (count != 1) exit 1 }' \
	"$status_file" > "$backup_dir/package-status.txt" || fail 'Cannot back up the package status record.'
"$service_script" running >/dev/null 2>&1 && was_running=1
"$service_script" enabled >/dev/null 2>&1 && was_enabled=1
printf '%s\n' "$was_running" > "$backup_dir/was-running"
printf '%s\n' "$was_enabled" > "$backup_dir/was-enabled"
printf '%s\n' "$tag" > "$backup_dir/update-release"
# Stop only after the download, checksum and preflight checks have passed.
service_stopped=1
if [ "$was_running" -eq 1 ]; then
	"$service_script" stop || fail 'Cannot stop the service.'
else
	"$service_script" stop >/dev/null 2>&1 || true
fi
if ! tar -czf "$backup_dir/files.tar.gz" -C "${router_root:-/}" "$@"; then
	# No installation has occurred; restarting the old service is sufficient.
	fail 'Cannot create the backup archive; nothing was installed.'
fi
install_started=1
log "Backup: $backup_dir"
# An explicit update/reinstall must be allowed even if a previous fork
# installation set hold. The old flag is included in the rollback record.
opkg flag ok v2raya || fail 'Cannot temporarily clear the package hold.'
if [ "$current_version" = "$version" ]; then
	opkg install --force-reinstall "$package_file" || fail 'opkg reinstallation failed.'
else
	opkg install "$package_file" || fail 'opkg installation failed.'
fi
opkg status v2raya | grep -qx "Version: $version" || fail 'opkg did not install the expected version.'
"$router_root/usr/bin/v2raya" --version > "$work_dir/version-output" 2>&1 || fail 'The new binary cannot run on this device.'
grep -Fq '2.2.7.5' "$work_dir/version-output" || fail 'The new binary reports an unexpected version.'
if [ "$was_enabled" -eq 1 ]; then
	"$service_script" enable || fail 'Cannot preserve boot enablement.'
else
	"$service_script" disable || fail 'Cannot preserve boot disablement.'
fi
if [ "$was_running" -eq 1 ]; then
	"$service_script" start || fail 'Cannot restart the service.'
	sleep 2
	"$service_script" running >/dev/null 2>&1 || fail 'The updated service did not remain running.'
else
	"$service_script" stop >/dev/null 2>&1 || true
	if "$service_script" running >/dev/null 2>&1; then
		fail 'Cannot preserve the stopped service state.'
	fi
fi
opkg flag hold v2raya || fail 'Cannot hold the package against accidental replacement from the feed.'
success=1
log "Installed v2raya $version for $arch; opkg hold is set."
log 'UCI configuration and LuCI integration are retained. Test WebUI, Xray, DNS and transparent proxy next.'
log "Rollback files remain in $backup_dir."
