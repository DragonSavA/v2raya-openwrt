# v2raya-openwrt: legacy GeoIP memory fix and native Hysteria2

This branch provides **v2rayA 2.2.7.5-r3** for OpenWrt 21.02 and compatible
vendor firmware using **opkg and iptables/firewall3**. It backports the
incremental GeoIP parser from [upstream PR #1933](https://github.com/v2rayA/v2rayA/pull/1933)
to reduce peak memory use when reading `geoip.dat`. It retains the UCI,
procd and LuCI integration. A second backend patch adds **native Hysteria2
through Xray 26.3.27+**, without an auxiliary proxy process. Releases include
**Xray 26.3.27-r1**, built from unmodified upstream source with Go 1.26.8.

[Русская инструкция: установка и откат](docs/INSTALL-RU.md) ·
[GL-MT3600BE testing guide](docs/GL-MT3600BE-RU.md) ·
[Download releases](https://github.com/DragonSavA/v2raya-openwrt/releases)

The fork publishes replacement **v2raya and xray-core IPKs**, not its own opkg feed.
Install the original feed packages first, then upgrade v2raya and an older Xray using
the installer below. Firewall4/nftables and apk-based firmware are outside
this legacy release's supported scope.

## Supported package architectures

Selection uses `opkg print-architecture`, not the router model or `uname -m`.
The installer picks the supported architecture with the highest opkg priority.

| opkg architecture | Go target | Device testing |
| --- | --- | --- |
| `aarch64_cortex-a53` | ARM64 | Previous r2 worked on GL-MT3600BE; r3 needs device testing |
| `aarch64_generic` | ARM64 | Build/ELF checks only |
| `aarch64_cortex-a72` | ARM64 | Build/ELF checks only |
| `arm_cortex-a7_neon-vfpv4` | ARMv7 | Build/ELF checks only |
| `arm_cortex-a9_vfpv3-d16` | ARMv7 | Build/ELF checks only |
| `mips_24kc` | MIPS32, big endian, soft float | Build/ELF checks only |
| `mipsel_24kc` | MIPS32, little endian, soft float | Build/ELF checks only |
| `mipsel_74kc` | MIPS32, little endian, soft float | Build/ELF checks only |
| `x86_64` | AMD64 v1 | Build/ELF checks only |

All r3 packages have build/ELF checks; the previous router report concerns r2.
Host integration tests validate Xray configuration and TCP/UDP over trusted
TLS for Hysteria2, Salamander, Trojan and VLESS WS+TLS. TUIC retains its
existing in-process client and SOCKS outbound. These tests do not replace
real-router, transparent-proxy, server or memory tests.

## Hysteria2 and Xray compatibility

Import a `hysteria2://` or `hy2://` URL, or refresh an existing S-UI URI/base64
subscription in the WebUI. Supported S-UI options: `sni`, ALPN `h3`,
`obfs=salamander`, `obfs-password`, `mport` (single ports/ranges), and decimal
`upmbps`/`downmbps`. Authentication, IPv6, escaped passwords, sharing and
stored subscriptions are supported. TCP Fast Open in S-UI links has no
QUIC effect. Hysteria v1, AnyTLS, Naive and Snell are not added.

The unchanged embedded legacy WebUI has no dedicated Hysteria2 manual-edit
form. Use Import/subscriptions to add a node and reimport an edited URL to
change it. Listing, selection, sharing and routing use the existing backend.

**Check TLS before upgrading.** Xray 26.3.27 rejects `allowInsecure: true`
after 2026-06-01. This affects existing Xray TLS outbounds as well as Hysteria2.
Use a valid/trusted certificate, the correct SNI and certificate verification;
then refresh the S-UI links. Hysteria2 `insecure=1`/`true` is retained on import
but gives an explicit error on connection, rather than bypassing verification.
Certificate-pinning URL parameters are not supported by this first backport.
The installer does not disable verification or rewrite your server settings.

The installer requires the standard `/usr/bin/xray` selected automatically
or through `v2raya.config.v2ray_bin`. It leaves a newer working Xray in place,
checks native Hysteria2 support, and tests the saved core config plus the
additional config directory from UCI **before stopping the service**. If
preflight fails, both installed packages remain in place. Inactive nodes
outside that saved config still need individual connection tests. Missing
GeoIP/geosite files and removed core settings can also cause preflight errors.

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
   checks the SHA-256 and metadata of both packages, tests the candidate core,
   saves a persistent backup under `/root/v2raya-backups/`, and installs
   `2.2.7.5-r3` plus Xray `26.3.27-r1` when the installed Xray is older. It warns before
   installing an architecture without real-router testing. If the environment
   or architecture is unsupported, it reports this and leaves the feed
   version in place. Download/checksum errors abort before stopping the service.
   A feed version newer than `2.2.7.5-r3` is not downgraded automatically.

   The installer preserves the previous running/stopped and boot enablement states and sets
   `opkg flag hold v2raya` and `opkg flag hold xray-core` after success,
   so feed upgrades do not silently replace the tested pair. The package version is unchanged for rebuilds: use
   `sh /tmp/install-v2raya-release.sh --reinstall` to install another release
   of `2.2.7.5-r3` explicitly. Use `--check` to download/verify and test Xray compatibility without
   replacing packages or stopping the service. Download the new installer
   even if a previous r2 installer is still in `/tmp`.

5. Confirm the installed version, then enable the service:

   ```sh
   opkg status v2raya xray-core
   /usr/bin/v2raya --version
   /usr/bin/xray version
   uci set v2raya.config.enabled='1'
   uci commit v2raya
   /etc/init.d/v2raya enable
   /etc/init.d/v2raya start
   ```

   Expect `Version: 2.2.7.5-r3` in opkg status. Open
   `http://<router-ip>/cgi-bin/luci/admin/services/v2raya` and the v2rayA
   WebUI at `http://<router-ip>:2017`, then configure your servers and routing.
   If step 4 reported an unsupported architecture, these commands start the
   feed version instead; it does not contain this fork's backport.

## Updating an existing installation

From feed `2.2.7.4-r1` or our `2.2.7.5-r2`, run step 4 above; do not reinstall
the feed packages. A held r2 package is handled automatically. Keep LuCI
and firmware-specific dependencies. The installer
preserves `/etc/config/v2raya` and `/etc/v2raya`; it stops a running service
only after download and verification. Existing connections may disconnect
during the upgrade. It restores both binaries, configuration and both opkg records if
installation, binary startup or basic service restart fails.

For manual rollback and post-install tests, see [INSTALL-RU.md](docs/INSTALL-RU.md).
To allow a future feed upgrade deliberately, run `opkg flag ok v2raya` and `opkg flag ok xray-core`.

## Building and publishing

Every push to `legacy-2.2.7.5-memfix` runs the architecture matrix. After all
packages pass verification, GitHub Actions publishes a Release with a
commit-specific tag `v2.2.7.5-r3-<12-character-commit>`, all **18 IPKs** (two per architecture),
per-package SHA-256 files, `SHA256SUMS`, a manifest, the installer and the
Russian guide. Failed/incomplete matrices or failed host TCP/UDP compatibility tests are not published. Re-running an
already published commit leaves its release assets intact.

The release job uses `GITHUB_TOKEN` with `contents: write`; no SourceForge
credentials, SDK or separate feed signing key are required. Enable Actions
in the fork if GitHub has disabled them. PRs build/test without publishing.
`workflow_dispatch` also builds; publication is restricted to this branch.

Build v2rayA with **Go 1.21.13**, and Xray with **Go 1.26.8**, using Bash,
curl, patch, GNU tar, gzip, file and binutils. Switch Go toolchains between
the first two commands:

```sh
bash scripts/build-standalone-ipk.sh mipsel_24kc
# Switch PATH to Go 1.26.8:
bash scripts/build-xray-ipk.sh mipsel_24kc
bash scripts/verify-ipk.sh artifacts/v2raya_2.2.7.5-r3_mipsel_24kc.ipk mipsel_24kc
python3 scripts/tests/test-install-release.py
# With both x86_64 IPKs built and Go 1.21.13 selected:
bash scripts/test-native-xray.sh artifacts
```

Omitting the architecture builds `aarch64_cortex-a53`. The shared supported
list is [scripts/architectures.tsv](scripts/architectures.tsv). All binaries
use `CGO_ENABLED=0`; ARMv7 targets use `GOARM=7`, MIPS targets use
`GOMIPS=softfloat`, and x86_64 uses `GOAMD64=v1`. No router-specific
instructions, new libc dependencies or kernel modules are bundled.
