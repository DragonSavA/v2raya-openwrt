#!/usr/bin/env python3
"""Exercise the actual installer with mock router commands and isolated files."""
import hashlib
import io
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
VERSION = "2.2.7.5-r3"
XRAY_VERSION = "26.3.27-r1"
COMMIT = "a" * 40
TAG = "v" + VERSION + "-" + COMMIT[:12]

MOCK = r'''#!/usr/bin/env python3
import io, os, re, shutil, sys, tarfile
from pathlib import Path
root = Path(os.environ['V2RAYA_TEST_ROOT'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls').open('a') as log:
    log.write(name + ' ' + ' '.join(args) + '\n')
status_path = root / 'usr/lib/opkg/status'
if name == 'id':
    if args == ['-u']:
        print(os.environ['TEST_UID']); sys.exit(0)
    sys.exit(2)
if name == 'opkg':
    if args[0] == 'status':
        text = status_path.read_text()
        for block in text.split('\n\n'):
            if block.startswith('Package: ' + args[1] + '\n'):
                print(block); sys.exit(0)
        sys.exit(1)
    if args[0] == 'print-architecture':
        print(os.environ['TEST_ARCHITECTURES']); sys.exit(0)
    if args[0] == 'compare-versions':
        values = lambda v: tuple(int(x) for x in re.findall(r'\d+', v))
        sys.exit(0 if values(args[1]) > values(args[3]) else 1)
    if args[0] == 'install':
        with tarfile.open(args[-1], 'r:gz') as outer:
            data = outer.extractfile('./data.tar.gz').read()
            meta = outer.extractfile('./control.tar.gz').read()
        with tarfile.open(fileobj=io.BytesIO(meta), mode='r:gz') as control:
            text = control.extractfile('./control').read().decode()
        package = re.search(r'^Package: (.+)$', text, re.M)[1]
        version = re.search(r'^Version: (.+)$', text, re.M)[1]
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as payload:
            payload.extractall(root, filter='data')
        if os.environ.get('TEST_FAIL_INSTALL') in ('1', package): sys.exit(1)
        text = status_path.read_text()
        blocks = text.split('\n\n')
        blocks = [re.sub(r'^Status: .* installed$', 'Status: install user installed',
                        re.sub(r'Version: [^\n]+', 'Version: ' + version, b, count=1), flags=re.M)
                  if b.startswith('Package: ' + package + '\n') else b for b in blocks]
        status_path.write_text('\n\n'.join(blocks))
        # OpenWrt postinst may enable the init script automatically.
        if package == 'v2raya': (root / 'enabled').touch()
        (root / ('usr/lib/opkg/info/' + package + '.control')).write_text('new control\n')
        sys.exit(0)
    if args[0] == 'flag':
        if args[1] == 'hold':
            if os.environ.get('TEST_FAIL_HOLD') == '1': sys.exit(1)
        blocks = status_path.read_text().split('\n\n')
        blocks = [re.sub(r'^Status: .* installed$', 'Status: install ' + args[1] + ' installed', b, flags=re.M)
                  if b.startswith('Package: ' + args[2] + '\n') else b for b in blocks]
        status_path.write_text('\n\n'.join(blocks))
        sys.exit(0)
    sys.exit(2)
if name == 'uci':
    key = args[-1].rsplit('.', 1)[-1]
    value = os.environ.get('TEST_UCI_' + key.upper(), '')
    if value: print(value); sys.exit(0)
    sys.exit(1)
if name == 'pidof':
    if (root / 'running').exists() and os.environ.get('TEST_CORE_RUNNING') == '1':
        if os.environ.get('TEST_CORE_FAIL_NEW') == '1' and '26.3.27' in (root / 'usr/bin/xray').read_text(): sys.exit(1)
        print('999'); sys.exit(0)
    sys.exit(1)
if name in ('curl', 'wget'):
    flag = '--output' if name == 'curl' else '-O'
    destination = args[args.index(flag) + 1]
    url = next(x for x in args if x.startswith('https://'))
    if os.environ.get('TEST_FAIL_DOWNLOAD') == '1': sys.exit(1)
    filename = url.rsplit('/', 1)[-1]
    if filename.endswith('.ipk'):
        tag = os.environ['TEST_RELEASE_TAG']
        assert '/releases/download/' + tag + '/' in url, url
    source = root / 'assets' / filename
    if not source.is_file(): sys.exit(1)
    shutil.copyfile(source, destination)
    sys.exit(0)
if name == 'df':
    amount = os.environ.get('TEST_FREE_KB', '1000000')
    print('Filesystem 1024-blocks Used Available Capacity Mounted on')
    print('mock 2000000 10 ' + amount + ' 1% /')
    sys.exit(0)
if name in ('fw3', 'fw4', 'sleep'): sys.exit(0)
sys.exit(2)
'''

SERVICE = '''#!/bin/sh
root="$V2RAYA_TEST_ROOT"
echo "service $1" >> "$root/calls"
case "$1" in
  running) test -f "$root/running" ;;
  enabled) test -f "$root/enabled" ;;
  enable) touch "$root/enabled" ;;
  disable) rm -f "$root/enabled" ;;
  stop)
    if [ "${TEST_STOP_NOTRUNNING:-0}" = 1 ] && [ ! -f "$root/running" ]; then exit 1; fi
    rm -f "$root/running" ;;
  start)
    if [ "${TEST_FAIL_START:-0}" = 1 ] && grep -q '2.2.7.5' "$root/usr/bin/v2raya"; then exit 1; fi
    touch "$root/running" ;;
esac
'''


def gz_tar(files):
    result = io.BytesIO()
    with tarfile.open(fileobj=result, mode="w:gz") as archive:
        for name, (data, mode) in files.items():
            entry = tarfile.TarInfo(name)
            entry.mode, entry.size = mode, len(data)
            archive.addfile(entry, io.BytesIO(data))
    return result.getvalue()


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in ("bin", "tmp", "root", "etc/init.d", "etc/config", "etc/v2raya",
                     "usr/bin", "usr/lib/opkg/info", "assets", "var/lock"):
            (self.root / path).mkdir(parents=True, exist_ok=True)
        self.write("etc/openwrt_release", "DISTRIB_RELEASE='21.02'\n")
        self.write("etc/config/v2raya", "old UCI config\n")
        self.write("etc/v2raya/database", "old database\n")
        self.write("usr/lib/opkg/info/v2raya.control", "old control\n")
        self.write("usr/bin/v2raya", "#!/bin/sh\necho '2.2.7.4'\n", executable=True)
        self.write("usr/bin/xray", "#!/bin/sh\necho 'Xray 25.10.15 OpenWrt'\n", executable=True)
        self.write("usr/lib/opkg/info/xray-core.control", "old xray control\n")
        self.write("etc/init.d/v2raya", SERVICE, executable=True)
        self.write("usr/lib/opkg/status", "Package: v2raya\nVersion: 2.2.7.4-r1\nStatus: install user installed\n\nPackage: xray-core\nVersion: 25.10.15-r1\nStatus: install user installed\n\nPackage: libc\nVersion: 1\nStatus: install ok installed\n\n")
        self.write("bin/router-mock", MOCK, executable=True)
        for command in ("id", "opkg", "fw3", "curl", "wget", "df", "sleep", "uci", "pidof"):
            (self.root / "bin" / command).symlink_to("router-mock")
        if os.environ.get("INSTALL_TEST_BUSYBOX"):
            for command in ("awk", "tar", "sha256sum", "sed", "grep", "mktemp", "du", "wc", "uname",
                            "cut", "tr", "date", "cp", "cat", "mkdir", "rm", "rmdir", "touch"):
                (self.root / "bin" / command).symlink_to(os.environ["INSTALL_TEST_BUSYBOX"])
        self.env = dict(os.environ, V2RAYA_TEST_ROOT=str(self.root),
                        TMPDIR=str(self.root / "tmp"),
                        PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                        TEST_UID="0",
                        TEST_ARCHITECTURES="arch all 1\narch noarch 1\narch aarch64_cortex-a53 10",
                        TEST_RELEASE_TAG=TAG)
        self.env["TEST_INSTALLER_SCRIPT"] = str(REPO / "scripts/install-release.sh")
        # Simulate the router UID without requiring root on the test host.
        # BusyBox ash can execute embedded applets before searching PATH;
        # shell functions keep id/df/sleep mocked under either test shell.
        self.write("bin/test-entry", '''#!/bin/sh
id() { "$V2RAYA_TEST_ROOT/bin/id" "$@"; }
df() { "$V2RAYA_TEST_ROOT/bin/df" "$@"; }
sleep() { "$V2RAYA_TEST_ROOT/bin/sleep" "$@"; }
pidof() { "$V2RAYA_TEST_ROOT/bin/pidof" "$@"; }
. "$TEST_INSTALLER_SCRIPT"
''', executable=True)
        self.make_release()

    def write(self, path, text, executable=False):
        file = self.root / path
        file.write_text(text)
        file.chmod(0o755 if executable else 0o600)

    def make_release(self, arch="aarch64_cortex-a53", bad_binary=False):
        rows = []
        for package, version, binary_name in (("v2raya", VERSION, "v2raya"), ("xray-core", XRAY_VERSION, "xray")):
            filename = f"{package}_{version}_{arch}.ipk"
            control = gz_tar({"./control": (f"Package: {package}\nVersion: {version}\nArchitecture: {arch}\nInstalled-Size: 1024\nDepends: libc, ca-bundle\n".encode(), 0o644)})
            if package == 'v2raya':
                binary = b"#!/bin/sh\nexit 1\n" if bad_binary else b"#!/bin/sh\necho '2.2.7.5'\n"
            else:
                binary = b"""#!/bin/sh
if [ "$1" = version ]; then
  [ "${TEST_BAD_XRAY_BINARY:-0}" = 0 ] || exit 1
  echo 'Xray 26.3.27 OpenWrt'
  exit 0
fi
if [ "$1" = run ]; then
  echo "xray preflight $*" >> "$V2RAYA_TEST_ROOT/calls"
  case "$*" in
    *hysteria2-probe.json*) [ "${TEST_FAIL_HY2_PREFLIGHT:-0}" = 0 ] || exit 1 ;;
    *) [ "${TEST_FAIL_CONFIG_PREFLIGHT:-0}" = 0 ] || exit 1 ;;
  esac
  for arg in "$@"; do
    if [ -f "$arg" ] && grep -Eq '"allowInsecure"[[:space:]]*:[[:space:]]*true' "$arg"; then
      echo 'allowInsecure has been removed' >&2; exit 1
    fi
  done
  exit 0
fi
exit 2
"""
            payload = gz_tar({"./usr/bin/" + binary_name: (binary, 0o755)})
            ipk = gz_tar({"./control.tar.gz": (control, 0o644), "./data.tar.gz": (payload, 0o644), "./debian-binary": (b"2.0\n", 0o644)})
            (self.root / "assets" / filename).write_bytes(ipk)
            row_type = 'package' if package == 'v2raya' else 'xray-core'
            rows.append(f"{row_type}\t{arch}\t{filename}\t{hashlib.sha256(ipk).hexdigest()}\t{len(ipk)}\t1024\tbuild-only")
        self.write("assets/release-manifest.tsv", f"format\t2\nrepository\tDragonSavA/v2raya-openwrt\nversion\t{VERSION}\nxray_version\t{XRAY_VERSION}\ntag\t{TAG}\nsource_commit\t{COMMIT}\n" + "\n".join(rows) + "\n")

    def run_installer(self, *args, ok=True):
        shell = shlex.split(os.environ.get("INSTALL_TEST_SHELL", "/bin/sh"))
        entry = self.root / "bin/test-entry"
        result = subprocess.run(shell + [str(entry), *args], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def set_xray_current(self, version="26.3.27"):
        file = self.root / "usr/lib/opkg/status"
        file.write_text(file.read_text().replace("25.10.15-r1", version + "-r1"))
        self.write("usr/bin/xray", "#!/bin/sh\n[ \"$1\" != version ] || echo 'Xray " + version + " OpenWrt'\n", executable=True)

    def calls(self):
        file = self.root / "calls"
        return file.read_text() if file.exists() else ""

    def assert_untouched(self):
        self.assertNotIn("opkg install", self.calls())
        self.assertNotIn("service stop", self.calls())
        self.assertIn("2.2.7.4", (self.root / "usr/bin/v2raya").read_text())

    def test_previous_held_fork_upgrades_both_packages(self):
        status = self.root / 'usr/lib/opkg/status'
        status.write_text(status.read_text().replace('2.2.7.4-r1', '2.2.7.5-r2').replace('Status: install user installed', 'Status: install hold installed'))
        self.write('usr/bin/v2raya', "#!/bin/sh\necho '2.2.7.5'\n", executable=True)
        self.write('running', '')
        self.env['TEST_CORE_RUNNING'] = '1'
        self.run_installer()
        self.assertIn('Version: ' + VERSION, status.read_text())
        self.assertIn('Version: ' + XRAY_VERSION, status.read_text())
        self.assertIn('opkg flag ok xray-core', self.calls())
        self.assertIn('opkg flag ok v2raya', self.calls())

    def test_check_validates_actual_config_without_changes(self):
        self.write('etc/v2raya/config.json', '{"outbounds":[]}')
        self.env['TEST_UCI_V2RAY_CONFDIR'] = '/etc/xray-extra'
        self.run_installer('--check')
        self.assertIn('xray preflight run -test -config', self.calls())
        self.assertIn('-confdir ' + str(self.root / 'etc/xray-extra'), self.calls())
        self.assert_untouched()
        self.assertNotIn('opkg flag', self.calls())

    def test_tls_or_candidate_preflight_failure_never_stops_service(self):
        self.write('running', '')
        self.write('etc/v2raya/config.json', '{"outbounds":[]}')
        for flag in ('TEST_FAIL_HY2_PREFLIGHT', 'TEST_FAIL_CONFIG_PREFLIGHT', 'TEST_BAD_XRAY_BINARY'):
            with self.subTest(flag=flag):
                self.env[flag] = '1'
                self.run_installer(ok=False)
                self.assert_untouched()
                self.env.pop(flag)
        self.write('etc/v2raya/config.json', '{"tlsSettings":{"allowInsecure":true}}')
        self.assertIn('allowInsecure', self.run_installer(ok=False))
        self.assert_untouched()
        self.assertTrue((self.root / 'running').exists())

    def test_core_install_or_restart_failure_restores_both_packages(self):
        for flag, value in (('TEST_FAIL_INSTALL', 'xray-core'), ('TEST_FAIL_INSTALL', 'v2raya'), ('TEST_CORE_FAIL_NEW', '1')):
            with self.subTest(flag=flag, value=value):
                self.write('running', '')
                self.env['TEST_CORE_RUNNING'] = '1'
                self.env[flag] = value
                old_status = (self.root / 'usr/lib/opkg/status').read_text()
                self.assertIn('restored', self.run_installer(ok=False))
                self.assertIn('25.10.15', (self.root / 'usr/bin/xray').read_text())
                self.assertEqual((self.root / 'usr/lib/opkg/info/xray-core.control').read_text(), 'old xray control\n')
                self.assertEqual(sorted(old_status.strip().split('\n\n')), sorted((self.root / 'usr/lib/opkg/status').read_text().strip().split('\n\n')))
                self.assertTrue((self.root / 'running').exists())
                self.env.pop(flag)

    def test_newer_xray_is_kept(self):
        self.set_xray_current('26.5.1')
        self.run_installer()
        self.assertIn('Version: 26.5.1-r1', (self.root / 'usr/lib/opkg/status').read_text())
        self.assertNotIn('opkg flag ok xray-core', self.calls())
        self.assertNotIn('xray-core_26.3.27-r1_', self.calls())

    def test_same_v2raya_still_updates_old_core(self):
        status = self.root / 'usr/lib/opkg/status'
        status.write_text(status.read_text().replace('2.2.7.4-r1', VERSION))
        self.write('usr/bin/v2raya', "#!/bin/sh\necho '2.2.7.5'\n", executable=True)
        self.run_installer()
        installs = [line for line in self.calls().splitlines() if line.startswith('opkg install')]
        self.assertEqual(len(installs), 1)
        self.assertIn('xray-core_', installs[0])

    def test_custom_or_v2ray_core_is_not_replaced(self):
        for binary in ('/usr/bin/v2ray', '/opt/bin/xray'):
            self.env['TEST_UCI_V2RAY_BIN'] = binary
            self.assertIn('standard /usr/bin/xray', self.run_installer(ok=False))
            self.assert_untouched()

    def test_missing_core_package_aborts(self):
        status = self.root / 'usr/lib/opkg/status'
        blocks = [b for b in status.read_text().split('\n\n') if not b.startswith('Package: xray-core\n')]
        status.write_text('\n\n'.join(blocks))
        self.assertIn('Install xray-core', self.run_installer(ok=False))
        self.assert_untouched()

    def test_bad_xray_checksum_aborts(self):
        path = self.root / 'assets/release-manifest.tsv'
        rows = path.read_text().splitlines()
        fields = rows[-1].split('\t'); fields[3] = '0' * 64
        path.write_text('\n'.join(rows[:-1] + ['\t'.join(fields)]) + '\n')
        self.run_installer(ok=False)
        self.assert_untouched()


    def test_non_root_rejected_before_router_commands(self):
        self.env["TEST_UID"] = "1000"
        output = self.run_installer(ok=False)
        self.assertIn("Run this script as root.", output)
        self.assertEqual(self.calls(), "id -u\n")
        self.assert_untouched()

    def test_checked_upgrade_preserves_config_and_running_service(self):
        self.write("running", "")
        self.write("enabled", "")
        output = self.run_installer()
        self.assertIn("Installed v2raya", output)
        self.assertIn("Status: install hold installed", (self.root / "usr/lib/opkg/status").read_text())
        self.assertEqual((self.root / "etc/config/v2raya").read_text(), "old UCI config\n")
        self.assertEqual((self.root / "etc/v2raya/database").read_text(), "old database\n")
        self.assertTrue((self.root / "running").exists())
        self.assertTrue((self.root / "enabled").exists())
        self.assertEqual(len(list((self.root / "root/v2raya-backups").glob("*/files.tar.gz"))), 1)

    def test_stopped_service_stays_stopped(self):
        self.env["TEST_STOP_NOTRUNNING"] = "1"
        self.run_installer()
        self.assertFalse((self.root / "running").exists())
        self.assertFalse((self.root / "enabled").exists())
        self.assertNotIn("service start", self.calls())

    def test_unverified_architecture_warns_but_installs(self):
        self.env["TEST_ARCHITECTURES"] = "arch all 1\narch mipsel_24kc 10"
        self.make_release("mipsel_24kc")
        self.assertIn("WARNING: mipsel_24kc", self.run_installer())

    def test_unsupported_architecture_leaves_feed(self):
        self.env["TEST_ARCHITECTURES"] = "arch all 1\narch riscv64_generic 10"
        self.assertIn("no release package", self.run_installer())
        self.assert_untouched()

    def test_highest_opkg_priority_wins(self):
        path = self.root / "assets/release-manifest.tsv"
        tested_row = "\n".join(path.read_text().splitlines()[-2:])
        self.make_release("aarch64_generic")
        path.write_text(path.read_text() + tested_row + "\n")
        self.env["TEST_ARCHITECTURES"] = "arch all 1\narch aarch64_generic 5\narch aarch64_cortex-a53 10"
        self.assertIn("architecture: aarch64_cortex-a53", self.run_installer("--check"))

    def test_missing_feed_package_is_not_installed_implicitly(self):
        self.write("usr/lib/opkg/status", "Package: libc\nVersion: 1\nStatus: install ok installed\n\n")
        self.assertIn("original feed first", self.run_installer(ok=False))
        self.assert_untouched()

    def test_firewall4_leaves_feed(self):
        (self.root / "bin/fw4").symlink_to("router-mock")
        self.assertIn("firewall4", self.run_installer())
        self.assert_untouched()

    def test_check_has_no_mutations(self):
        self.run_installer("--check")
        self.assert_untouched()
        self.assertNotIn("opkg flag", self.calls())

    def test_same_version_skips_reinstall(self):
        path = self.root / "usr/lib/opkg/status"
        path.write_text(path.read_text().replace("2.2.7.4-r1", VERSION))
        self.set_xray_current()
        self.assertIn("already installed", self.run_installer())
        self.assertNotIn("opkg install", self.calls())
        self.assertNotIn("service stop", self.calls())

    def test_explicit_reinstall(self):
        path = self.root / "usr/lib/opkg/status"
        path.write_text(path.read_text().replace("2.2.7.4-r1", VERSION).replace("Status: install user installed", "Status: install hold installed"))
        self.run_installer("--reinstall")
        self.assertIn("opkg install", self.calls())
        self.assertLess(self.calls().index("opkg flag ok"), self.calls().index("opkg install"))
        self.assertIn("Status: install hold installed", path.read_text())

    def test_newer_version_not_downgraded(self):
        path = self.root / "usr/lib/opkg/status"
        path.write_text(path.read_text().replace("2.2.7.4-r1", "2.4.17-r1"))
        self.assertIn("newer", self.run_installer())
        self.assert_untouched()

    def test_bad_checksum_aborts_before_stopping_service(self):
        path = self.root / "assets/release-manifest.tsv"
        text = path.read_text().splitlines()
        row = text[-2].split("\t")
        row[3] = "0" * 64
        path.write_text("\n".join(text[:-2] + ["\t".join(row), text[-1]]) + "\n")
        self.run_installer(ok=False)
        self.assert_untouched()

    def test_invalid_manifest_is_never_evaluated(self):
        path = self.root / "assets/release-manifest.tsv"
        path.write_text(path.read_text() + "tag\t$(touch unsafe)\n")
        self.run_installer(ok=False)
        self.assert_untouched()

    def test_no_release_or_network_failure_aborts(self):
        self.env["TEST_FAIL_DOWNLOAD"] = "1"
        self.run_installer(ok=False)
        self.assert_untouched()

    def test_insufficient_space_aborts(self):
        self.env["TEST_FREE_KB"] = "1"
        self.run_installer(ok=False)
        self.assert_untouched()

    def test_partial_install_and_runtime_failures_restore_backup(self):
        for failure in ("TEST_FAIL_INSTALL", "TEST_FAIL_START", "TEST_FAIL_HOLD", "bad_binary"):
            with self.subTest(failure=failure):
                if failure == "bad_binary":
                    self.make_release(bad_binary=True)
                else:
                    self.env[failure] = "1"
                self.write("running", "")
                old_status = (self.root / "usr/lib/opkg/status").read_text()
                self.assertIn("restored", self.run_installer(ok=False))
                self.assertIn("2.2.7.4", (self.root / "usr/bin/v2raya").read_text())
                restored = (self.root / "usr/lib/opkg/status").read_text()
                self.assertEqual(sorted(restored.strip().split("\n\n")), sorted(old_status.strip().split("\n\n")))
                self.assertEqual((self.root / "usr/lib/opkg/info/v2raya.control").read_text(), "old control\n")
                self.assertTrue((self.root / "running").exists())
                self.assertFalse((self.root / "enabled").exists())
                self.env.pop(failure, None)


if __name__ == "__main__":
    unittest.main(verbosity=2)
