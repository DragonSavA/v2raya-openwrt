#!/usr/bin/env bash

set -euo pipefail

readonly package_version="2.2.7.5"
readonly package_release="2"
readonly package_arch="aarch64_cortex-a53"
readonly source_hash="d0daccace51572d730fb710f7df190beed47d51ec1091d2fba38719b9417b385"
readonly web_hash="89bff9248a9cba8b7bda6e1202ac565dbca377319423868835235deddbfb182a"
readonly source_date_epoch="1769301139"

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
output_dir="${OUTPUT_DIR:-$repo_root/artifacts}"
mkdir -p "$output_dir"
output_dir="$(CDPATH= cd -- "$output_dir" && pwd)"

build_dir="$(mktemp -d)"
cleanup() {
	rm -rf -- "$build_dir"
}
trap cleanup EXIT HUP INT TERM

source_archive="$build_dir/v2rayA-$package_version.tar.gz"
web_archive="$build_dir/v2rayA-web-$package_version.tar.gz"
source_root="$build_dir/source"
data_root="$build_dir/data"
control_root="$build_dir/control"
package_root="$build_dir/package"

curl --fail --location --retry 3 --connect-timeout 20 \
	"https://codeload.github.com/v2rayA/v2rayA/tar.gz/v$package_version" \
	--output "$source_archive"
curl --fail --location --retry 3 --connect-timeout 20 \
	"https://github.com/v2rayA/v2rayA/releases/download/v$package_version/web.tar.gz" \
	--output "$web_archive"

printf '%s  %s\n' "$source_hash" "$source_archive" | sha256sum --check -
printf '%s  %s\n' "$web_hash" "$web_archive" | sha256sum --check -

mkdir -p "$source_root"
tar --no-same-owner --strip-components=1 -xzf "$source_archive" -C "$source_root"
patch -d "$source_root/service" -p1 \
	< "$repo_root/v2raya/patches/010-reduce-geoip-parser-memory.patch"

mkdir -p "$source_root/service/server/router/web"
tar --no-same-owner --strip-components=1 -xzf "$web_archive" \
	-C "$source_root/service/server/router/web"

(
	cd "$source_root/service"
	GOTOOLCHAIN=local CGO_ENABLED=0 go test ./common/parseGeoIP
	GOTOOLCHAIN=local GOOS=linux GOARCH=arm64 GOARM64=v8.0 CGO_ENABLED=0 \
		go build -trimpath -buildvcs=false \
		-ldflags "-s -w -buildid= \
		-X github.com/v2rayA/v2rayA/conf.Version=$package_version \
		-X github.com/v2rayA/v2rayA/core/iptables.TproxyNotSkipBr=true" \
		-o "$build_dir/v2raya" .
)

install -d -m 0755 \
	"$data_root/usr/bin" \
	"$data_root/etc/config" \
	"$data_root/etc/init.d" \
	"$data_root/lib/upgrade/keep.d"
install -m 0755 "$build_dir/v2raya" "$data_root/usr/bin/v2raya"
install -m 0600 "$repo_root/v2raya/files/v2raya.config" \
	"$data_root/etc/config/v2raya"
install -m 0755 "$repo_root/v2raya/files/v2raya.init" \
	"$data_root/etc/init.d/v2raya"
printf '/etc/v2raya/\n' > "$data_root/lib/upgrade/keep.d/v2raya"

mkdir -p "$control_root" "$package_root"
installed_size="$(du -sb "$data_root" | awk '{print $1}')"

cat > "$control_root/control" <<EOF
Package: v2raya
Version: $package_version-r$package_release
Depends: libc, ca-bundle
Source: feeds/v2raya-legacy/v2raya
SourceName: v2rayA
License: AGPL-3.0-only
LicenseFiles: LICENSE
Section: net
SourceDateEpoch: $source_date_epoch
URL: https://v2raya.org
Maintainer: Tianling Shen <cnsztl@immortalwrt.org>
Architecture: $package_arch
Installed-Size: $installed_size
Description:  v2rayA is a V2Ray Linux client supporting global transparent proxy,
 compatible with SS, SSR, Trojan(trojan-go), PingTunnel protocols.
EOF

printf '/etc/config/v2raya\n' > "$control_root/conffiles"
cat > "$control_root/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
EOF
cat > "$control_root/prerm" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
EOF
chmod 0755 "$control_root/postinst" "$control_root/prerm"

printf '2.0\n' > "$package_root/debian-binary"

tar --sort=name --mtime="@$source_date_epoch" --owner=0 --group=0 \
	--numeric-owner -C "$data_root" -cf - . |
	gzip -n -9 > "$package_root/data.tar.gz"
tar --sort=name --mtime="@$source_date_epoch" --owner=0 --group=0 \
	--numeric-owner -C "$control_root" -cf - . |
	gzip -n -9 > "$package_root/control.tar.gz"

package_file="$output_dir/v2raya_${package_version}-r${package_release}_${package_arch}.ipk"
tar --mtime="@$source_date_epoch" --owner=0 --group=0 --numeric-owner \
	-C "$package_root" -cf - ./debian-binary ./data.tar.gz ./control.tar.gz |
	gzip -n -9 > "$package_file"

bash "$repo_root/scripts/verify-ipk.sh" "$package_file"
(
	cd "$output_dir"
	sha256sum "$(basename -- "$package_file")" \
		> "$(basename -- "$package_file").sha256"
)

printf 'Created %s\n' "$package_file"
