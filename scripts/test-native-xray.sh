#!/usr/bin/env bash
set -euo pipefail
repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/package-config.sh
source "$repo_root/scripts/package-config.sh"
[[ "$#" == 1 ]] || { echo "Usage: $0 IPK-directory" >&2; exit 2; }
packages="$(CDPATH='' cd -- "$1" && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
for file in "v2raya_${full_version}_x86_64.ipk" "xray-core_${xray_full_version}_x86_64.ipk"; do
	(cd "$packages" && sha256sum --check "$file.sha256")
	bash "$repo_root/scripts/verify-ipk.sh" "$packages/$file" x86_64
done
tar -xzOf "$packages/xray-core_${xray_full_version}_x86_64.ipk" ./data.tar.gz |
	tar -xzf - -C "$test_dir" ./usr/bin/xray
tar -xzOf "$packages/v2raya_${full_version}_x86_64.ipk" ./data.tar.gz |
	tar -xzf - -C "$test_dir" ./usr/bin/v2raya
"$test_dir/usr/bin/v2raya" --version | grep -Fx "$package_version"
"$test_dir/usr/bin/xray" version | grep -F "Xray $xray_version "
archive="$test_dir/v2rayA.tar.gz"
if [[ -n "${ARCHIVE_DIR:-}" ]]; then
	cp "$ARCHIVE_DIR/v2rayA-$package_version.tar.gz" "$archive"
else
	curl --fail --location --retry 3 --connect-timeout 20 \
		"https://codeload.github.com/v2rayA/v2rayA/tar.gz/v$package_version" --output "$archive"
fi
printf '%s  %s\n' "$source_hash" "$archive" | sha256sum --check -
mkdir "$test_dir/source"
tar --no-same-owner --strip-components=1 -xzf "$archive" -C "$test_dir/source"
for patch_file in "$repo_root"/v2raya/patches/*.patch; do
	patch -d "$test_dir/source/service" -p1 < "$patch_file"
done
export XRAY_BIN="$test_dir/usr/bin/xray" XRAY_FIXTURE_DIR="$test_dir/fixtures"
bash "$repo_root/scripts/test-protocols.sh" "$test_dir/source/service"
python3 "$repo_root/scripts/tests/test-xray-loopback.py" "$XRAY_BIN" "$XRAY_FIXTURE_DIR"
