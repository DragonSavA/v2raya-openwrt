# shellcheck shell=bash disable=SC2034,SC2154
# Shared by the host-side scripts. The caller supplies repo_root and uses
# the constants and architecture variables defined here.
readonly package_version="2.2.7.5"
readonly package_release="2"
readonly full_version="$package_version-r$package_release"
readonly source_hash="d0daccace51572d730fb710f7df190beed47d51ec1091d2fba38719b9417b385"
readonly web_hash="89bff9248a9cba8b7bda6e1202ac565dbca377319423868835235deddbfb182a"
readonly source_date_epoch="1769301139"

load_architecture() {
	local row
	row="$(awk -F '\t' -v arch="$1" '$1 == arch { print; count++ } END { if (count != 1) exit 1 }' \
		"$repo_root/scripts/architectures.tsv")" || {
		printf 'Unsupported package architecture: %s\n' "$1" >&2
		return 1
	}
	IFS=$'\t' read -r package_arch go_arch go_arm go_mips go_386 test_status <<< "$row"
}
