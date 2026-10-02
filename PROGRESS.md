# Legacy fork progress

Branch: `legacy-2.2.7.5-memfix`

## Existing fork and device report

- Original upstream baseline: `d288e54992b03365a2f6cf2e8932b5031dc2cf70`.
- The owner applied the original patch and pushed the fork at
  `755e9db4405269c2133542168add6dfd7b131644`.
- The owner reports that the original `2.2.7.5-r2` IPK works correctly on
  GL.iNet GL-MT3600BE, OpenWrt 21.02-SNAPSHOT, kernel 5.4.281,
  `aarch64_cortex-a53`.
- No report of a completed 24–72 hour comparative memory test is assumed.

## Multi-architecture extension completed locally

- [x] Keep v2rayA version `2.2.7.5-r2`, the GeoIP backport, UCI/init/LuCI,
  package dependencies and external core unchanged.
- [x] One architecture table drives host builds, ELF verification and CI.
  It contains nine opkg architectures across ARM64, ARMv7, MIPS/MIPSel and
  x86_64; see `scripts/architectures.tsv`.
- [x] All nine local IPK builds and their GeoIP tests passed with Go 1.21.13.
- [x] Static ELF machine/class/endianness and build settings checked.
- [x] `--version` passed under QEMU for ARM64, ARMv7, MIPS and MIPSel;
  x86_64 startup passed natively. These are not real-router/network tests.
- [x] The new `aarch64_cortex-a53` package is byte-for-byte identical to the
  router-tested original, SHA-256
  `bee524207972d122145c5055e1c2d22b05a6f168f53a86f18ebfec1cfd31f58c`.
- [x] A push-triggered architecture matrix and complete-release publication
  job are prepared, using commit-specific tags and `GITHUB_TOKEN`.
- [x] Router installer selects from opkg priorities, pins package URLs to
  the manifest tag, checks hashes/metadata, leaves unsupported environments
  unchanged, backs up files/opkg state and restores on installation/startup
  failures. It prevents automatic downgrades and preserves service state.
- [x] Sixteen installer tests passed under `/bin/sh` and BusyBox ash with
  BusyBox applets and mock router commands, including rollback cases.
- [x] ShellCheck, shell syntax checks and actionlint passed.
- [x] README and Russian installation/test/rollback guides updated.

## After applying the extension patch

- [ ] Push the change to `DragonSavA/v2raya-openwrt` on the existing branch.
- [ ] Enable Actions in the fork if necessary; wait for all nine build jobs
  and the release job to succeed.
- [ ] Confirm that a published Release contains all IPKs, SHA-256 files,
  manifest, installer and Russian guide.
- [ ] Run the release installer with `--check` on the GL-MT3600BE. An
  explicit `--reinstall` can test the new delivery path; it is not required
  to obtain a different binary on this router.
- [ ] Collect real-router/network tests for other architectures and run
  comparative memory observation. Update test status only after evidence.

## Deferred

- Public opkg feed, firewall4/apk support and v2rayA 2.4.x migration.
- Other memory/process fixes unless measurements show they are needed.

This file is a continuation checkpoint. Local builds and mock/emulated
tests do not constitute a published GitHub Actions run or device testing.
