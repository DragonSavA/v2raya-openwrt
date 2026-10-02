#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
	echo "Usage: $0 path/to/v2raya.ipk" >&2
	exit 2
fi

package_file="$1"
[[ -f "$package_file" ]]

temporary_dir="$(mktemp -d)"
cleanup() {
	rm -rf -- "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

control="$(tar -xzOf "$package_file" ./control.tar.gz | tar -xzOf - ./control)"

grep -qx 'Package: v2raya' <<<"$control"
grep -qx 'Version: 2.2.7.5-r2' <<<"$control"
grep -qx 'Architecture: aarch64_cortex-a53' <<<"$control"
grep -Eq '^Depends: ([^,]+, )*libc(, |$)' <<<"$control"
grep -Eq '^Depends: .*ca-bundle' <<<"$control"

data_listing="$(tar -xzOf "$package_file" ./data.tar.gz | tar -tzf -)"
grep -qx './usr/bin/v2raya' <<<"$data_listing"
grep -qx './etc/init.d/v2raya' <<<"$data_listing"
grep -qx './etc/config/v2raya' <<<"$data_listing"
grep -qx './lib/upgrade/keep.d/v2raya' <<<"$data_listing"

if grep -Eq '^Depends: .*kmod-nft-tproxy' <<<"$control"; then
	echo "Unexpected firewall4 dependency in legacy package" >&2
	exit 1
fi

tar -xzOf "$package_file" ./data.tar.gz |
	tar -xzf - -C "$temporary_dir" ./usr/bin/v2raya
file "$temporary_dir/usr/bin/v2raya" |
	grep -Eq 'ELF 64-bit LSB executable, ARM aarch64,.*statically linked'
if readelf -l "$temporary_dir/usr/bin/v2raya" | grep -q INTERP; then
	echo "Unexpected dynamic ELF interpreter" >&2
	exit 1
fi

echo "Verified: v2raya 2.2.7.5-r2 for aarch64_cortex-a53"
