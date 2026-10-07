#!/bin/sh
# Run on the router after installing v2raya and its dependencies from the feed.
set -eu
umask 077

repository='DragonSavA/v2raya-openwrt'
version='2.2.7.5-r3'
xray_version='26.3.27'
xray_package_version='26.3.27-r1'
check_only=0
reinstall=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--check) check_only=1 ;;
		--reinstall) reinstall=1 ;;
		--help)
			echo 'Usage: sh install-release.sh [--check] [--reinstall]'
			echo '--check: download, verify and preflight without replacing packages.'
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
core_was_running=0

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
	rm -f "$router_root"/usr/lib/opkg/info/v2raya.* "$router_root"/usr/lib/opkg/info/xray-core.*
	tar -xzf "$backup_dir/files.tar.gz" -C "${router_root:-/}" || return 1
	# Restore both package records; retain unrelated package records.
	awk 'BEGIN { RS=""; ORS="\n\n" } $0 !~ /^Package: (v2raya|xray-core)\n/ { print }' \
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
	log 'The previous binary, Xray binary, configuration and both opkg records were restored.' >&2
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
for cmd in opkg tar sha256sum awk sed grep mktemp df du wc uname cut tr date cp cat mkdir rm rmdir sleep chmod env uci pidof; do
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
  $1 == "package" || $1 == "xray-core" {
    if (NF != 7 || $2 !~ /^[a-z0-9_-]+$/ || seen_arch[$1 SUBSEP $2]++ ||
        $3 !~ /^[a-zA-Z0-9_.-]+\.ipk$/ || length($4) != 64 || $4 ~ /[^0-9a-f]/ ||
        $5 !~ /^[1-9][0-9]*$/ || $6 !~ /^[1-9][0-9]*$/ || $5 < 1 || $6 < 1 ||
        $5 > 536870912 || $6 > 536870912 ||
        ($7 != "router-tested" && $7 != "build-only")) exit 1
    packages[$1]++; next
  }
  $1 == "format" || $1 == "repository" || $1 == "version" ||
  $1 == "tag" || $1 == "source_commit" || $1 == "xray_version" {
    if (NF != 2 || seen[$1]++) exit 1
    headers++
    next
  }
  { exit 1 }
  END { if (!packages["package"] || packages["package"] != packages["xray-core"] || headers != 6) exit 1 }
' "$manifest" || fail 'Invalid release manifest; nothing was installed.'
[ "$(awk -F '\t' '$1 == "format" { print $2 }' "$manifest")" = 2 ] || fail 'Unsupported manifest format.'
[ "$(awk -F '\t' '$1 == "repository" { print $2 }' "$manifest")" = "$repository" ] || fail 'Unexpected release repository.'
[ "$(awk -F '\t' '$1 == "version" { print $2 }' "$manifest")" = "$version" ] || fail 'Unexpected release version.'
[ "$(awk -F '\t' '$1 == "xray_version" { print $2 }' "$manifest")" = "$xray_package_version" ] || fail 'Unexpected Xray release version.'
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
[ "$filename" = "v2raya_${version}_${arch}.ipk" ] || fail 'Unexpected package filename.'
xray_row="$(awk -F '\t' -v arch="$arch" '$1 == "xray-core" && $2 == arch { print }' "$manifest")"
[ -n "$xray_row" ] || fail 'Missing matching Xray package; nothing was installed.'
xray_filename="$(printf '%s\n' "$xray_row" | cut -f3)"
xray_hash="$(printf '%s\n' "$xray_row" | cut -f4)"
xray_package_bytes="$(printf '%s\n' "$xray_row" | cut -f5)"
xray_installed_bytes="$(printf '%s\n' "$xray_row" | cut -f6)"
[ "$xray_filename" = "xray-core_${xray_package_version}_${arch}.ipk" ] || fail 'Unexpected Xray package filename.'
configured_core="$(uci -q get v2raya.config.v2ray_bin 2>/dev/null || true)"
case "$configured_core" in
  ''|/usr/bin/xray) ;;
  *) fail 'This installer requires the standard /usr/bin/xray core. Select it in v2raya UCI first; custom/V2Ray binaries are not replaced.' ;;
esac
xray_status="$(opkg status xray-core)" || fail 'Install xray-core from the original feed first.'
printf '%s\n' "$xray_status" | grep -Eq '^Status: .* installed$' || fail 'Install xray-core from the original feed first.'
[ -x "$router_root/usr/bin/xray" ] || fail 'The installed Xray binary is missing.'
"$router_root/usr/bin/xray" version > "$work_dir/current-xray-version" 2>&1 || fail 'The installed Xray binary cannot run.'
current_xray="$(awk 'NR == 1 && $1 == "Xray" { print $2 }' "$work_dir/current-xray-version")"
printf '%s\n' "$current_xray" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail 'Cannot determine the actual Xray binary version.'
need_xray=0
if opkg compare-versions "$xray_version" '>' "$current_xray"; then need_xray=1; fi
current_xray_package="$(printf '%s\n' "$xray_status" | sed -n 's/^Version: //p')"
if [ "$need_xray" -eq 1 ] && opkg compare-versions "$current_xray_package" '>' "$xray_package_version"; then
  fail 'Xray binary and opkg version disagree; resolve this before upgrading.'
fi
need_v2raya=1
if [ "$current_version" = "$version" ] && [ "$reinstall" -eq 0 ]; then need_v2raya=0; fi
log "Release: $tag; architecture: $arch; v2raya: $current_version -> $version; Xray: $current_xray (minimum $xray_version)."
if [ "$arch" != aarch64_cortex-a53 ]; then
  log "WARNING: $arch has build/ELF checks only. It has not been tested on a real router."
else
  log 'The previous r2 worked on GL-MT3600BE. This r3/Hysteria2/Xray update still needs a router test.'
fi
if [ -x "$router_root/etc/init.d/xray" ] && "$router_root/etc/init.d/xray" running >/dev/null 2>&1; then
  fail 'An independent Xray service is running. Stop it for maintenance before updating the shared binary.'
fi

# Download only components that need replacing. Reserve space for the unpacked
# candidate Xray as well as the compressed IPKs, before stopping any service.
required_tmp_kb=8192
if [ "$need_v2raya" -eq 1 ]; then required_tmp_kb=$((required_tmp_kb + package_bytes / 1024)); fi
if [ "$need_xray" -eq 1 ]; then required_tmp_kb=$((required_tmp_kb + (2 * xray_package_bytes + xray_installed_bytes) / 1024)); fi
tmp_free_kb="$(df -Pk "$work_dir" | awk 'END { print $4 }')"
[ "$tmp_free_kb" -ge "$required_tmp_kb" ] || fail 'Not enough free space in /tmp for downloads and Xray preflight.'
verify_download() {
  component="$1"; component_version="$2"; component_file="$3"; component_hash="$4"; component_bytes="$5"; component_installed="$6"
  download "https://github.com/$repository/releases/download/$tag/$component_file" "$work_dir/$component_file" || fail "Download of $component failed; nothing was installed."
  [ "$(wc -c < "$work_dir/$component_file" | tr -d ' ')" = "$component_bytes" ] || fail "$component package size mismatch."
  printf '%s  %s\n' "$component_hash" "$work_dir/$component_file" | sha256sum -c - || fail "$component checksum mismatch; nothing was installed."
  tar -xzOf "$work_dir/$component_file" ./control.tar.gz > "$work_dir/control.tar.gz" || fail 'Invalid IPK archive.'
  tar -xzOf "$work_dir/control.tar.gz" ./control > "$work_dir/control" || fail 'Missing package metadata.'
  grep -qx "Package: $component" "$work_dir/control" || fail 'Unexpected package name.'
  grep -qx "Version: $component_version" "$work_dir/control" || fail 'Unexpected package version.'
  grep -qx "Architecture: $arch" "$work_dir/control" || fail 'Unexpected package architecture.'
  grep -qx "Installed-Size: $component_installed" "$work_dir/control" || fail 'Unexpected installed size.'
  if grep -Eq '^Depends: .*kmod-nft-tproxy' "$work_dir/control"; then fail 'Unexpected firewall4 dependency.'; fi
}
package_file="$work_dir/$filename"
xray_package_file="$work_dir/$xray_filename"
if [ "$need_v2raya" -eq 1 ]; then
  verify_download v2raya "$version" "$filename" "$hash" "$package_bytes" "$installed_bytes"
fi
candidate_xray="$router_root/usr/bin/xray"
if [ "$need_xray" -eq 1 ]; then
  verify_download xray-core "$xray_package_version" "$xray_filename" "$xray_hash" "$xray_package_bytes" "$xray_installed_bytes"
  mkdir -p "$work_dir/candidate"
  tar -xzOf "$xray_package_file" ./data.tar.gz > "$work_dir/xray-data.tar.gz" || fail 'Missing Xray payload.'
  tar -xzf "$work_dir/xray-data.tar.gz" -C "$work_dir/candidate" ./usr/bin/xray || fail 'Missing candidate Xray binary.'
  rm -f "$work_dir/xray-data.tar.gz"
  candidate_xray="$work_dir/candidate/usr/bin/xray"
  chmod 0755 "$candidate_xray"
  "$candidate_xray" version > "$work_dir/candidate-version" 2>&1 || fail 'Candidate Xray cannot run on this device; nothing was installed.'
  [ "$(awk 'NR == 1 && $1 == "Xray" { print $2 }' "$work_dir/candidate-version")" = "$xray_version" ] || fail 'Unexpected candidate Xray binary version.'
fi

# Both an existing/newer core and the downloaded candidate must accept the
# native outbound and the current combined configuration. -test does not
# listen on ports, contact servers or launch a second proxy daemon.
cat > "$work_dir/hysteria2-probe.json" <<'EOF'
{"outbounds":[{"tag":"hy2-probe","protocol":"hysteria","settings":{"version":2,"address":"example.invalid","port":443},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"serverName":"example.invalid","alpn":["h3"]},"hysteriaSettings":{"version":2,"auth":"preflight"},"finalmask":{"udp":[{"type":"salamander","settings":{"password":"preflight"}}],"quicParams":{"congestion":"brutal","brutalUp":"20 mbps","brutalDown":"80 mbps","udpHop":{"ports":"443,10000-10010","interval":30}}}}}]}
EOF
"$candidate_xray" run -test -config "$work_dir/hysteria2-probe.json" > "$work_dir/preflight.log" 2>&1 || {
  cat "$work_dir/preflight.log" >&2
  fail 'Xray does not accept the native Hysteria2 configuration; nothing was installed.'
}
config_dir="$(uci -q get v2raya.config.v2ray_confdir 2>/dev/null || true)"
case "$config_dir" in ''|/*) ;; *) fail 'Additional Xray configuration directory must be absolute.' ;; esac
asset_dir="${XRAY_LOCATION_ASSET:-${V2RAY_LOCATION_ASSET:-$router_root/run/user/0/v2raya}}"
if [ ! -r "$asset_dir/geoip.dat" ] || [ ! -r "$asset_dir/geosite.dat" ]; then
  for asset_candidate in "$router_root/usr/share/xray" "$router_root/usr/share/v2ray" "$router_root/etc/v2raya"; do
    if [ -r "$asset_candidate/geoip.dat" ] && [ -r "$asset_candidate/geosite.dat" ]; then asset_dir="$asset_candidate"; break; fi
  done
fi
set -- run -test
if [ -s "$router_root/etc/v2raya/config.json" ]; then
  set -- "$@" -config "$router_root/etc/v2raya/config.json"
else
  set -- "$@" -config "$work_dir/hysteria2-probe.json"
  log 'No saved core config: native Hysteria2 was checked. Saved/inactive servers need connection tests after installation.'
fi
if [ -n "$config_dir" ]; then set -- "$@" -confdir "$router_root$config_dir"; fi
if ! env XRAY_LOCATION_ASSET="$asset_dir" V2RAY_LOCATION_ASSET="$asset_dir" V2RAY_CONF_GEOLOADER=memconservative \
    "$candidate_xray" "$@" > "$work_dir/preflight.log" 2>&1; then
  cat "$work_dir/preflight.log" >&2
  fail 'Current Xray configuration is incompatible. Check allowInsecure=true, removed transports/options and GeoIP/geosite files; neither package was changed.'
fi
log 'Xray configuration preflight passed. Inactive nodes and actual server connections still need functional tests.'
[ "$check_only" -eq 0 ] || { log 'Check complete; packages and service were not changed.'; exit 0; }
if [ "$need_v2raya" -eq 0 ] && [ "$need_xray" -eq 0 ]; then
  opkg flag hold v2raya || fail 'Cannot hold the existing package.'
  opkg flag hold xray-core || fail 'Cannot hold the existing Xray package.'
  log 'The required versions are already installed. Use --reinstall to replace v2raya explicitly.'
  exit 0
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
set -- usr/bin/v2raya usr/bin/xray etc/init.d/v2raya etc/config/v2raya
# Preserve old Xray-owned files even when a vendor package includes more than the binary.
if [ -r "$router_root/usr/lib/opkg/info/xray-core.list" ]; then
  while IFS= read -r old_file; do
    case "$old_file" in /*) old_file="${old_file#/}" ;; *) continue ;; esac
    if [ -f "$router_root/$old_file" ] || [ -L "$router_root/$old_file" ]; then set -- "$@" "$old_file"; fi
  done < "$router_root/usr/lib/opkg/info/xray-core.list"
fi
if [ -d "$router_root/etc/v2raya" ]; then set -- "$@" etc/v2raya; fi
if [ -f "$router_root/lib/upgrade/keep.d/v2raya" ]; then set -- "$@" lib/upgrade/keep.d/v2raya; fi
for info_file in "$router_root"/usr/lib/opkg/info/v2raya.* "$router_root"/usr/lib/opkg/info/xray-core.*; do
	[ -f "$info_file" ] || continue
	set -- "$@" "${info_file#"$router_root"/}"
done
backup_kb="$(cd "${router_root:-/}" && du -sk "$@" | awk '{ total += $1 } END { print total+0 }')"
persistent_free_kb="$(df -Pk "$router_root/root" | awk 'END { print $4 }')"
[ "$persistent_free_kb" -ge "$((backup_kb + (installed_bytes + xray_installed_bytes) / 1024 + 8192))" ] || fail 'Not enough persistent space for a backup and the new package.'
backup_dir="$router_root/root/v2raya-backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$backup_dir"
awk 'BEGIN { RS=""; ORS="\n\n" } $0 ~ /^Package: (v2raya|xray-core)\n/ { print; count++ } END { if (count != 2) exit 1 }' \
	"$status_file" > "$backup_dir/package-status.txt" || fail 'Cannot back up the package status record.'
"$service_script" running >/dev/null 2>&1 && was_running=1
if [ "$was_running" -eq 1 ] && pidof xray >/dev/null 2>&1; then core_was_running=1; fi
"$service_script" enabled >/dev/null 2>&1 && was_enabled=1
printf '%s\n' "$was_running" > "$backup_dir/was-running"
printf '%s\n' "$was_enabled" > "$backup_dir/was-enabled"
printf '%s\n' "$core_was_running" > "$backup_dir/core-was-running"
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
if [ "$need_xray" -eq 1 ]; then
  opkg flag ok xray-core || fail 'Cannot temporarily clear the Xray package hold.'
  opkg install "$xray_package_file" || fail 'Xray installation failed.'
  opkg status xray-core | grep -qx "Version: $xray_package_version" || fail 'opkg did not install the expected Xray version.'
fi
if [ "$need_v2raya" -eq 1 ]; then
  opkg flag ok v2raya || fail 'Cannot temporarily clear the v2raya package hold.'
  if [ "$current_version" = "$version" ]; then
    opkg install --force-reinstall "$package_file" || fail 'opkg reinstallation failed.'
  else
    opkg install "$package_file" || fail 'opkg installation failed.'
  fi
fi
"$router_root/usr/bin/xray" version > "$work_dir/new-xray-version" 2>&1 || fail 'The installed Xray binary cannot run.'
new_xray="$(awk 'NR == 1 && $1 == "Xray" { print $2 }' "$work_dir/new-xray-version")"
if [ -z "$new_xray" ] || opkg compare-versions "$xray_version" '>' "$new_xray"; then
  fail 'The installed Xray version is too old.'
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
if [ "$was_running" -eq 1 ] && [ "$core_was_running" -eq 1 ]; then
  attempt=0
  while ! pidof xray >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -le 15 ] || fail 'Xray was running before the upgrade but did not restart.'
    sleep 1
  done
fi
opkg flag hold v2raya || fail 'Cannot hold v2raya against accidental replacement from the feed.'
opkg flag hold xray-core || fail 'Cannot hold Xray against accidental replacement from the feed.'
success=1
log "Installed v2raya $version and Xray $new_xray for $arch; both packages are held."
log 'UCI configuration and LuCI integration are retained. Test WebUI, Xray, DNS and transparent proxy next.'
log "Rollback files remain in $backup_dir."
