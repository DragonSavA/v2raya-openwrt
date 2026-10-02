# v2raya-openwrt: legacy GeoIP memory fix

This branch provides **v2rayA 2.2.7.5-r2** for OpenWrt 21.02 and compatible
vendor firmware using **opkg and iptables/firewall3**. It backports the
incremental GeoIP parser from [upstream PR #1933](https://github.com/v2rayA/v2rayA/pull/1933)
to reduce peak memory use when reading `geoip.dat`. It retains the UCI,
procd and LuCI integration and the separately installed Xray/V2Ray core.

[Русская инструкция: установка и откат](docs/INSTALL-RU.md) ·
[GL-MT3600BE testing guide](docs/GL-MT3600BE-RU.md) ·
[Download releases](https://github.com/DragonSavA/v2raya-openwrt/releases)

The fork publishes replacement **v2raya IPKs**, not its own opkg feed.
Install the original feed packages first, then replace only v2raya using
the installer below. Firewall4/nftables and apk-based firmware are outside
this legacy release's supported scope.

## Supported package architectures

Selection uses `opkg print-architecture`, not the router model or `uname -m`.
The installer picks the supported architecture with the highest opkg priority.

| opkg architecture | Go target | Device testing |
| --- | --- | --- |
| `aarch64_cortex-a53` | ARM64 | Reported working on GL.iNet GL-MT3600BE |
| `aarch64_generic` | ARM64 | Build/ELF checks only |
| `aarch64_cortex-a72` | ARM64 | Build/ELF checks only |
| `arm_cortex-a7_neon-vfpv4` | ARMv7 | Build/ELF checks only |
| `arm_cortex-a9_vfpv3-d16` | ARMv7 | Build/ELF checks only |
| `mips_24kc` | MIPS32, big endian, soft float | Build/ELF checks only |
| `mipsel_24kc` | MIPS32, little endian, soft float | Build/ELF checks only |
| `mipsel_74kc` | MIPS32, little endian, soft float | Build/ELF checks only |
| `x86_64` | AMD64 v1 | Build/ELF checks only |

The GL-MT3600BE report confirms operation on that device; it does not prove
that the memory issue is resolved under every workload. Other routers,
including other `aarch64_cortex-a53` devices, still need functional testing.
The kernel modules and external core must match the device's firmware.

## Clean installation of this fork's version

Run these commands in an SSH shell on the router as root. Nothing needs to
be downloaded on a PC or transferred to the router beforehand. A completed
fork Release must exist before step 4; check the Releases link above.

1. Check the environment and install an HTTPS downloader from the firmware feeds:

   ```sh
   opkg print-architecture
   command -v fw3
   opkg update
   opkg install ca-bundle wget-ssl
   ```

   Continue with this legacy installation on firewall3 firmware only. Do not
   change kernel-module feeds to another firmware version.

2. Add the original v2rayA feed and its signing key:

   ```sh
   wget -O /etc/opkg/keys/94cc2a834fb0aa03 \
     https://downloads.sourceforge.net/project/v2raya/openwrt/v2raya.pub
   feed_arch="$(. /etc/openwrt_release && printf '%s' "$DISTRIB_ARCH")"
   touch /etc/opkg/customfeeds.conf
   sed -i '/^src\/gz v2raya /d' /etc/opkg/customfeeds.conf
   printf 'src/gz v2raya https://downloads.sourceforge.net/project/v2raya/openwrt/%s\n' \
     "$feed_arch" >> /etc/opkg/customfeeds.conf
   opkg update
   ```

3. Install the base package, core, LuCI and firewall3 dependencies:

   ```sh
   opkg install v2raya xray-core luci-app-v2raya
   opkg install iptables-mod-conntrack-extra iptables-mod-extra \
     iptables-mod-filter iptables-mod-tproxy kmod-ipt-nat6
   # Optional routing data:
   # opkg install v2fly-geoip v2fly-geosite
   ```

   Check that all these commands succeed. At this point v2raya is the
   version supplied by the original feed, not necessarily this fork.

4. Download and run this fork's release installer:

   ```sh
   wget -O /tmp/install-v2raya-release.sh \
     https://github.com/DragonSavA/v2raya-openwrt/releases/latest/download/install-release.sh &&
   sh /tmp/install-v2raya-release.sh
   ```

   The installer downloads the matching IPK from a specific release tag,
   checks its SHA-256 and package metadata, saves a persistent backup under
   `/root/v2raya-backups/`, and installs `2.2.7.5-r2`. It warns before
   installing an architecture without real-router testing. If the environment
   or architecture is unsupported, it reports this and leaves the feed
   version in place. Download/checksum errors abort before stopping the service.
   A feed version newer than `2.2.7.5-r2` is not downgraded automatically.

   The installer preserves the previous running/stopped and boot enablement states and sets
   `opkg flag hold v2raya` after success, so feed upgrades do not silently
   replace it. The package version is unchanged for rebuilds: use
   `sh /tmp/install-v2raya-release.sh --reinstall` to install another release
   of `2.2.7.5-r2` explicitly. Use `--check` to report availability without
   modifying the installed package.

5. Confirm the installed version, then enable the service:

   ```sh
   opkg status v2raya
   /usr/bin/v2raya --version
   uci set v2raya.config.enabled='1'
   uci commit v2raya
   /etc/init.d/v2raya enable
   /etc/init.d/v2raya start
   ```

   Expect `Version: 2.2.7.5-r2` in opkg status. Open
   `http://<router-ip>/cgi-bin/luci/admin/services/v2raya` and the v2rayA
   WebUI at `http://<router-ip>:2017`, then configure your servers and routing.
   If step 4 reported an unsupported architecture, these commands start the
   feed version instead; it does not contain this fork's backport.

## Updating an existing installation

Keep the existing feed/core/LuCI packages and run step 4 above. The installer
preserves `/etc/config/v2raya` and `/etc/v2raya`; it stops a running service
only after download and verification. Existing connections may disconnect
during the upgrade. It restores the previous files and opkg record if
installation, binary startup or basic service restart fails.

For manual rollback and post-install tests, see [INSTALL-RU.md](docs/INSTALL-RU.md).
To allow a future feed upgrade deliberately, run `opkg flag ok v2raya`.

## Building and publishing

Every push to `legacy-2.2.7.5-memfix` runs the architecture matrix. After all
packages pass verification, GitHub Actions publishes a Release with a
commit-specific tag `v2.2.7.5-r2-<12-character-commit>`, all nine IPKs,
per-package SHA-256 files, `SHA256SUMS`, a manifest, the installer and the
Russian guide. Failed/incomplete matrices are not published. Re-running an
already published commit leaves its release assets intact.

The release job uses `GITHUB_TOKEN` with `contents: write`; no SourceForge
credentials, SDK or separate feed signing key are required. Enable Actions
in the fork if GitHub has disabled them. PRs build/test without publishing.
`workflow_dispatch` also builds; publication is restricted to this branch.

With **Go 1.21.13**, Bash, curl, patch, GNU tar, gzip, file and binutils:

```sh
bash scripts/build-standalone-ipk.sh mipsel_24kc
bash scripts/verify-ipk.sh artifacts/v2raya_2.2.7.5-r2_mipsel_24kc.ipk mipsel_24kc
python3 scripts/tests/test-install-release.py
```

Omitting the architecture builds `aarch64_cortex-a53`. The shared supported
list is [scripts/architectures.tsv](scripts/architectures.tsv). All binaries
use `CGO_ENABLED=0`; ARMv7 targets use `GOARM=7`, MIPS targets use
`GOMIPS=softfloat`, and x86_64 uses `GOAMD64=v1`. No router-specific
instructions, new libc dependencies or kernel modules are bundled.
