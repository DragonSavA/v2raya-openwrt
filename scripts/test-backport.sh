#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source_dir="${1:-}"
temporary_dir=""

cleanup() {
	if [ -n "$temporary_dir" ] && [ -d "$temporary_dir" ]; then
		rm -rf -- "$temporary_dir"
	fi
}
trap cleanup EXIT HUP INT TERM

if [ -z "$source_dir" ]; then
	temporary_dir="$(mktemp -d)"
	source_dir="$temporary_dir/v2rayA"
	git clone --depth 1 --branch v2.2.7.5 \
		https://github.com/v2rayA/v2rayA.git "$source_dir"
fi

test -f "$source_dir/service/go.mod"
test -f "$source_dir/service/common/parseGeoIP/parser.go"

patch_file="$repo_root/v2raya/patches/010-reduce-geoip-parser-memory.patch"
patch -d "$source_dir/service" -p1 --dry-run < "$patch_file"
patch -d "$source_dir/service" -p1 < "$patch_file"

(
	cd "$source_dir/service"
	go test ./common/parseGeoIP
)
