#!/usr/bin/env bash

set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/package-config.sh
source "$repo_root/scripts/package-config.sh"
if [[ "$#" -gt 1 ]]; then
	printf 'Usage: %s [opkg-architecture]\n' "$0" >&2
	exit 2
fi
load_architecture "${1:-aarch64_cortex-a53}"
if [[ "$(GOTOOLCHAIN=local go env GOVERSION)" != go1.21.13 ]]; then
	echo "Use Go 1.21.13 to preserve the tested legacy build." >&2
	exit 1
fi
output_dir="${OUTPUT_DIR:-$repo_root/artifacts}"
mkdir -p "$output_dir"
output_dir="$(CDPATH='' cd -- "$output_dir" && pwd)"

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

# Optional archive directory allows offline/repeated builds with the same
# hash-checked inputs. CI downloads directly from upstream.
if [[ -n "${ARCHIVE_DIR:-}" ]]; then
	cp "$ARCHIVE_DIR/v2rayA-$package_version.tar.gz" "$source_archive"
	cp "$ARCHIVE_DIR/v2rayA-web-$package_version.tar.gz" "$web_archive"
else
	curl --fail --location --retry 3 --connect-timeout 20 \
		"https://codeload.github.com/v2rayA/v2rayA/tar.gz/v$package_version" \
		--output "$source_archive"
	curl --fail --location --retry 3 --connect-timeout 20 \
		"https://github.com/v2rayA/v2rayA/releases/download/v$package_version/web.tar.gz" \
		--output "$web_archive"
fi

printf '%s  %s\n' "$source_hash" "$source_archive" | sha256sum --check -
printf '%s  %s\n' "$web_hash" "$web_archive" | sha256sum --check -

mkdir -p "$source_root"
tar --no-same-owner --strip-components=1 -xzf "$source_archive" -C "$source_root"
for patch_file in "$repo_root"/v2raya/patches/*.patch; do
	patch -d "$source_root/service" -p1 < "$patch_file"
done

mkdir -p "$source_root/service/server/router/web"
	tar --no-same-owner --strip-components=1 -xzf "$web_archive" \
	-C "$source_root/service/server/router/web"

(
	cd "$source_root/service"
	bash "$repo_root/scripts/test-protocols.sh" "$source_root/service"
	build_env=(GOTOOLCHAIN=local GOOS=linux "GOARCH=$go_arch" CGO_ENABLED=0 GOAMD64=v1)
	[[ "$go_arm" == - ]] || build_env+=("GOARM=$go_arm")
	[[ "$go_mips" == - ]] || build_env+=("GOMIPS=$go_mips")
	[[ "$go_386" == - ]] || build_env+=("GO386=$go_386")
	env "${build_env[@]}" go build -trimpath -buildvcs=false \
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
 with a GeoIP memory backport and native Hysteria2 via Xray 26.3.27+.
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

bash "$repo_root/scripts/verify-ipk.sh" "$package_file" "$package_arch"
(
	cd "$output_dir"
	sha256sum "$(basename -- "$package_file")" \
		> "$(basename -- "$package_file").sha256"
)

printf 'Created %s\n' "$package_file"
