# Legacy fork progress

Branch: `legacy-2.2.7.5-memfix`

Target device:

- GL.iNet GL-MT3600BE;
- Linux userspace architecture: `aarch64`;
- opkg architecture: `aarch64_cortex-a53`;
- installed package: `v2raya 2.2.7.4-r1`;
- persistent free space observed before development: about 199 MiB.

## Completed

- [x] Fork baseline fixed at upstream `v2raya-openwrt` commit
  `d288e54992b03365a2f6cf2e8932b5031dc2cf70`.
- [x] Package updated from v2rayA 2.2.7.4-r1 to 2.2.7.5-r2.
- [x] Official source and web archive SHA-256 values verified.
- [x] Existing package dependencies, UCI config, init script and LuCI source
  preserved.
- [x] Upstream GeoIP memory fix from v2rayA PR #1933 adapted to the 2.2.x
  `core/v2ray/asset` import path.
- [x] Upstream focused GeoIP tests included in the OpenWrt patch.
- [x] Patch dry-run checked against the exact v2RayA 2.2.7.5 tag.
- [x] Single-architecture standalone build and GitHub Actions workflow
  prepared; no mismatched OpenWrt SDK is required.
- [x] Package metadata/content verifier prepared.
- [x] A complete local ARM64 build passed; the resulting ELF is static
  AArch64 and the package layout matches the OpenWrt ipk format.
- [x] A second clean build produced the same package SHA-256:
  `bee524207972d122145c5055e1c2d22b05a6f168f53a86f18ebfec1cfd31f58c`.
- [x] BusyBox-compatible router memory monitor prepared.
- [x] Installation, validation and rollback guide prepared.

## Still requires external execution

- [ ] Push this branch to the user's GitHub fork.
- [ ] Run `Build legacy v2rayA for GL-MT3600BE` in GitHub Actions.
- [ ] Confirm the focused `go test ./common/parseGeoIP` job succeeds.
- [ ] Confirm the clean GitHub Actions build succeeds and download the
  generated `.ipk`.
- [ ] Run `scripts/verify-ipk.sh` against the resulting package
  (the workflow does this automatically).
- [ ] Upgrade the router from 2.2.7.4-r1 following
  `docs/GL-MT3600BE-RU.md`.
- [ ] Run the functional checks and 24–72 hour memory observation.

## Deliberately deferred

- Observatory connection-error cleanup: add only if memory still grows and
  the growth correlates with repeated core/API connection failures.
- Linux parent-death signal for Xray: add only if testing confirms orphaned
  Xray after stopping or killing v2rayA.
- Other CPU families, public package feed and v2rayA 2.4.x migration.

This file is the continuation checkpoint if work is resumed in another
session.
