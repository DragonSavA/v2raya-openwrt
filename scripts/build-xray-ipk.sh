#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/package-config.sh
source "$repo_root/scripts/package-config.sh"
[[ "$#" -le 1 ]] || { echo "Usage: $0 [opkg-architecture]" >&2; exit 2; }
load_architecture "${1:-aarch64_cortex-a53}"
if [[ "$(GOTOOLCHAIN=local go env GOVERSION)" != "go$xray_go_version" ]]; then
	echo "Use Go $xray_go_version for Xray $xray_version." >&2
	exit 1
fi
output_dir="${OUTPUT_DIR:-$repo_root/artifacts}"
mkdir -p "$output_dir"
output_dir="$(CDPATH='' cd -- "$output_dir" && pwd)"
build_dir="$(mktemp -d)"
trap 'rm -rf -- "$build_dir"' EXIT HUP INT TERM
archive="$build_dir/Xray-core-$xray_version.tar.gz"
if [[ -n "${ARCHIVE_DIR:-}" ]]; then
	cp "$ARCHIVE_DIR/Xray-core-$xray_version.tar.gz" "$archive"
else
	curl --fail --location --retry 3 --connect-timeout 20 \
		"https://codeload.github.com/XTLS/Xray-core/tar.gz/v$xray_version" --output "$archive"
fi
printf '%s  %s\n' "$xray_source_hash" "$archive" | sha256sum --check -
mkdir -p "$build_dir/source" "$build_dir/data/usr/bin" "$build_dir/control" "$build_dir/package"
tar --no-same-owner --strip-components=1 -xzf "$archive" -C "$build_dir/source"
build_env=(GOTOOLCHAIN=local GOOS=linux "GOARCH=$go_arch" CGO_ENABLED=0 GOAMD64=v1)
[[ "$go_arm" == - ]] || build_env+=("GOARM=$go_arm")
[[ "$go_mips" == - ]] || build_env+=("GOMIPS=$go_mips")
[[ "$go_386" == - ]] || build_env+=("GO386=$go_386")
(
	cd "$build_dir/source"
	env "${build_env[@]}" go build -mod=readonly -trimpath -buildvcs=false \
		-ldflags "-s -w -buildid= -X github.com/xtls/xray-core/core.build=OpenWrt -X github.com/xtls/xray-core/core.version=$xray_version" \
		-o "$build_dir/data/usr/bin/xray" ./main
)
chmod 0755 "$build_dir/data/usr/bin/xray"
installed_size="$(du -sb "$build_dir/data" | awk '{print $1}')"
cat > "$build_dir/control/control" <<EOF
Package: xray-core
Version: $xray_full_version
Depends: libc, ca-bundle
Source: feeds/v2raya-legacy/xray-core
SourceName: Xray-core
License: MPL-2.0
LicenseFiles: LICENSE
Section: net
SourceDateEpoch: $xray_source_date_epoch
URL: https://github.com/XTLS/Xray-core
Architecture: $package_arch
Installed-Size: $installed_size
Description: Xray core with native Hysteria2 outbound for legacy OpenWrt.
EOF
printf '2.0\n' > "$build_dir/package/debian-binary"
for part in data control; do
	tar --sort=name --mtime="@$xray_source_date_epoch" --owner=0 --group=0 --numeric-owner \
		-C "$build_dir/$part" -cf - . | gzip -n -9 > "$build_dir/package/$part.tar.gz"
done
package_file="$output_dir/xray-core_${xray_full_version}_${package_arch}.ipk"
tar --mtime="@$xray_source_date_epoch" --owner=0 --group=0 --numeric-owner \
	-C "$build_dir/package" -cf - ./debian-binary ./data.tar.gz ./control.tar.gz | gzip -n -9 > "$package_file"
bash "$repo_root/scripts/verify-ipk.sh" "$package_file" "$package_arch"
(cd "$output_dir" && sha256sum "$(basename -- "$package_file")" > "$(basename -- "$package_file").sha256")
echo "Created $package_file"
