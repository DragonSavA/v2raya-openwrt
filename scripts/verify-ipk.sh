#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 ]]; then
	echo "Usage: $0 path/to/v2raya.ipk [expected-opkg-architecture]" >&2
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
repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/package-config.sh
source "$repo_root/scripts/package-config.sh"
actual_arch="$(sed -n 's/^Architecture: //p' <<< "$control")"
load_architecture "${2:-$actual_arch}"

grep -qx 'Package: v2raya' <<<"$control"
grep -qx "Version: $full_version" <<<"$control"
grep -qx "Architecture: $package_arch" <<<"$control"
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
file "$temporary_dir/usr/bin/v2raya" | grep -q 'statically linked'
elf_header="$(LC_ALL=C readelf -h "$temporary_dir/usr/bin/v2raya")"
case "$go_arch" in
	arm64) machine='AArch64'; elf_class='ELF64'; byte_order='little endian' ;;
	arm) machine='ARM'; elf_class='ELF32'; byte_order='little endian' ;;
	mips) machine='MIPS R3000'; elf_class='ELF32'; byte_order='big endian' ;;
	mipsle) machine='MIPS R3000'; elf_class='ELF32'; byte_order='little endian' ;;
	amd64) machine='Advanced Micro Devices X86-64'; elf_class='ELF64'; byte_order='little endian' ;;
	*) echo "No ELF verifier for $go_arch" >&2; exit 1 ;;
esac
grep -Eq "Class: +$elf_class$" <<< "$elf_header"
grep -Eq "Machine: +$machine$" <<< "$elf_header"
grep -Eq "Data: +2's complement, $byte_order$" <<< "$elf_header"
grep -Eq 'Type: +EXEC ' <<< "$elf_header"
if readelf -l "$temporary_dir/usr/bin/v2raya" | grep -q INTERP; then
	echo "Unexpected dynamic ELF interpreter" >&2
	exit 1
fi

echo "Verified: v2raya $full_version for $package_arch ($test_status)"
