#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 1 ]] || { echo "Usage: $0 patched-v2rayA-service-directory" >&2; exit 2; }
source_dir="$(CDPATH='' cd -- "$1" && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
(
	cd "$source_dir"
	GOTOOLCHAIN=local CGO_ENABLED=0 go test ./common/parseGeoIP ./core/serverObj ./db/configure
	# Legacy service initialization parses CLI flags before Go's TestMain.
	# Compile and run without go-test flags, using an isolated configuration.
	GOTOOLCHAIN=local CGO_ENABLED=0 go test -c -o "$test_dir/service-tests" ./server/service
	V2RAYA_CONFIG="$test_dir/config" V2RAYA_LITE=true "$test_dir/service-tests"
)
