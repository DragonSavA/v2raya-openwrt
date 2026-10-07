#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
	echo "Usage: $0 artifact-directory release-tag source-commit" >&2
	exit 2
fi
repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/package-config.sh
source "$repo_root/scripts/package-config.sh"
output_dir="$(CDPATH='' cd -- "$1" && pwd)"
tag="$2"
commit="$3"
repository="${GITHUB_REPOSITORY:-DragonSavA/v2raya-openwrt}"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]]
[[ "$tag" == "v$full_version-${commit:0:12}" ]]
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]

manifest="$output_dir/release-manifest.tsv"
printf 'format\t2\nrepository\t%s\nversion\t%s\nxray_version\t%s\ntag\t%s\nsource_commit\t%s\n' \
	"$repository" "$full_version" "$xray_full_version" "$tag" "$commit" > "$manifest"
count=0
while IFS=$'\t' read -r arch _; do
	[[ -n "$arch" && "$arch" != \#* ]] || continue
	load_architecture "$arch"
	for component in v2raya xray-core; do
	if [[ "$component" == v2raya ]]; then
		filename="v2raya_${full_version}_${arch}.ipk"; row_type=package
	else
		filename="xray-core_${xray_full_version}_${arch}.ipk"; row_type=xray-core
	fi
	package_file="$output_dir/$filename"
	bash "$repo_root/scripts/verify-ipk.sh" "$package_file" "$arch"
	(cd "$output_dir" && sha256sum --check "$filename.sha256")
	hash="$(sha256sum "$package_file" | awk '{print $1}')"
	size="$(stat -c %s "$package_file")"
	installed_size="$(tar -xzOf "$package_file" ./control.tar.gz |
		tar -xzOf - ./control | sed -n 's/^Installed-Size: //p')"
	[[ "$installed_size" =~ ^[0-9]+$ ]]
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$row_type" "$arch" "$filename" "$hash" "$size" "$installed_size" "$test_status" >> "$manifest"
	count=$((count + 1))
	done
done < "$repo_root/scripts/architectures.tsv"
shopt -s nullglob
packages=("$output_dir"/*.ipk)
[[ "$count" -gt 0 && "${#packages[@]}" -eq "$count" ]]

cp "$repo_root/scripts/install-release.sh" "$output_dir/install-release.sh"
cp "$repo_root/scripts/architectures.tsv" "$output_dir/architectures.tsv"
cp "$repo_root/docs/INSTALL-RU.md" "$output_dir/INSTALL-RU.md"
(
	cd "$output_dir"
	sha256sum ./*.ipk release-manifest.tsv install-release.sh architectures.tsv INSTALL-RU.md > SHA256SUMS
)
echo "Release complete: $count packages, $tag ($commit)"
