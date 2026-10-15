# Legacy fork progress / continuation checkpoint

Branch: `legacy-2.2.7.5-memfix`
Patch base: `064365c5bbccd30febccb64cb3459f750d051627`.
Updated: 2026-10-15.

## r3 installer comparison fix

- Fix base: `20e326c1d1f434397d14cf43aeb87de8572b87c8`.
- The owner published r3 and reported successful router preflight, followed
  by a false `The installed Xray version is too old` error and paired rollback.
- OpenWrt opkg treats `>` as `>=`; strict greater-than is `>>`. The previous
  mock incorrectly treated `>` as strict and missed the equal-version case.
- All four installer comparisons now use `>>`; unreadable and genuinely old
  installed versions have separate diagnostics and still trigger rollback.
- The mock now models opkg relations, with regression scenarios for the
  reported held-r2 upgrade plus duplicate-feed warnings, an existing exact
  target Xray, the already-installed pair, and real invalid/old core output.
- Package versions stay `2.2.7.5-r3` / `26.3.27-r1`; no backend/core source or
  architecture/build changes are required. A push publishes a new commit tag
  with the corrected installer through the existing workflow.
- [x] 31 installer scenarios passed under /bin/sh and BusyBox ash, including
  reproduction of the reported failure with the old installer. ShellCheck,
  syntax and clean patch application checks passed before delivery.
- [ ] Owner: push this fix, download the new Release installer, retry router
  installation, then perform Hysteria2/previous-protocol and memory tests.

## Previous published state

- The owner applied the memory backport and multi-architecture patches.
- `2.2.7.5-r2` was reported working on GL.iNet GL-MT3600BE,
  OpenWrt 21.02-SNAPSHOT, kernel 5.4.281, `aarch64_cortex-a53`.
- The owner reported successful Actions/Release publication after the
  unprivileged-runner installer test fix in commit `064365c5`.
- Router Xray before this change: `25.10.15`.

## Native Hysteria2 update

- [x] Bump v2raya to `2.2.7.5-r3`; retain the GeoIP memory backport,
  legacy Go 1.21.13 build, firmware dependencies, UCI/procd/LuCI.
- [x] Add backend patch `020-native-hysteria2-xray.patch`: URI and
  subscription import, DB persistence, sharing, TCP/UDP native outbound,
  Xray version guard, SNI/h3, Salamander, port ranges, S-UI bandwidth.
- [x] Use Xray's `finalmask/quicParams` schema; do not emit obsolete
  Hysteria bandwidth/hopping fields. Do not bypass TLS verification.
- [x] Build unmodified Xray `26.3.27-r1` with pinned Go 1.26.8,
  CGO disabled, for all nine existing opkg architectures.
- [x] All 18 local IPK builds and static ELF checks passed.
- [x] Go import/subscription/database/config tests passed.
- [x] Real Xray config checks cover Hysteria2, Salamander/hopping/bandwidth,
  Trojan, VLESS WS+TLS and TUIC's existing SOCKS outbound.
- [x] Loopback TCP/UDP with trusted TLS passed for Hysteria2, Salamander,
  Trojan and VLESS WS+TLS. Date-dependent allowInsecure rejection confirmed.
- [x] Installer handles feed and held r2 upgrades, older/newer Xray,
  preflight without stopping the service, paired backup/rollback,
  architecture/checksum/metadata and service state.
- [x] The original 26 installer scenarios ran under /bin/sh and BusyBox ash;
  the incorrect opkg-comparison model is superseded by the fix above.
- [x] README and Russian installation/testing/paired-rollback guide updated.
- [x] ShellCheck, actionlint, syntax and complete 18-package manifest passed.
- [x] Clean patch application check completed against the exact base commit.
- [x] Downloadable patch and memo prepared; no remote commit/push performed.

## Owner actions after applying the patch

- [ ] Commit/push on the existing branch; wait for prepare, nine paired
  build jobs, host compatibility and Release to pass.
- [ ] Confirm 18 IPKs, checksum files, manifest format 2 and new installer.
- [ ] Resolve incompatible saved TLS settings before updating the router.
- [ ] Download the r3 installer afresh; run --check, then install.
- [ ] Test the previous protocols and Hysteria2 against the real S-UI
  servers, transparent proxy/DNS, restart/reboot, hopping and memory.
- [ ] Record 24–72 hours of normal memory/connection behavior.

No real-router r3 or S-UI server test has been performed here. TUIC's native
client implementation is unchanged; its SOCKS link to the new core is checked.
Hopping is validated as Xray configuration, not as real-server packet traffic.
Inactive nodes outside the saved core config need individual tests.

## Deferred

AnyTLS, Naive, Snell, auxiliary sing-box, public opkg feed,
firewall4/apk support and a v2rayA 2.4.x migration.
