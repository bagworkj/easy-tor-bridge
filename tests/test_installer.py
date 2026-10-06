"""Run on macOS: python3 -m unittest discover -s tests -v.

No containers, packages, or real LaunchAgents are modified. Compose config
is evaluated for real; Docker observations and launchctl are isolated doubles.
"""
import json
import os
from pathlib import Path
import plistlib
import pty
import re
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def functions(*names):
    source = (ROOT / 'install.sh').read_text()
    runtime = ROOT / 'scripts/bridge-runtime.sh'
    if runtime.exists():
        source += '\n' + runtime.read_text()
    found = []
    for name in names:
        match = re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S)
        if not match:  # One-line functions in the original installer.
            match = re.search(r'^' + name + r'\(\) \{[^\n]*\}', source, re.M)
        if match:
            found.append(match.group())
    return '\n'.join(found)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / 'colima').write_text('#!/bin/sh\necho Unexpected Colima invocation >&2\nexit 99\n')
        (self.home / 'colima').chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.home) + os.pathsep + os.environ['PATH'], HOME=str(self.home), PROJECT_DIR=str(self.home),
                        PROFILE='easy-tor-bridge', CONTEXT='colima-easy-tor-bridge',
                        BOOTSTRAP_CACHE=str(self.home / 'bootstrap'), GREEN='', RESET='')

    def shell(self, script, timeout=5, tty=False):
        if tty:
            master, slave = pty.openpty()
            proc = subprocess.Popen(['/bin/bash', '-c', script], stdin=slave,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    cwd=self.home, env=self.env, text=True)
            os.close(slave)
            try:
                os.write(master, b'y\n')
                out, err = proc.communicate(timeout=timeout)
                return subprocess.CompletedProcess(proc.args, proc.returncode, out, err)
            finally:
                if proc.poll() is None:
                    proc.kill(); proc.wait()
                os.close(master)
        return subprocess.run(['/bin/bash', '-c', script], cwd=self.home,
                              env=self.env, capture_output=True, text=True, timeout=timeout)

    def test_saved_configuration_and_identity_ignore_shell_overrides(self):
        compose = shutil.which('docker-compose')
        if not compose:
            self.skipTest('Docker Compose required for config-only test')
        shutil.copyfile(ROOT / 'compose.yaml', self.home / 'compose.yaml')
        (self.home / '.env').write_text('EMAIL=saved@example.invalid\nOR_PORT=9001\nPT_PORT=8443\n')
        self.env.update(COMPOSE=compose, EMAIL='wrong@example.invalid', PT_PORT='12345',
                        COMPOSE_PROJECT_NAME='wrong-project', COMPOSE_FILE='/does/not/exist.yaml',
                        COMPOSE_ENV_FILES='/does/not/exist.env')
        result = self.shell(functions('compose') + '\ncompose config --format json')
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(result.stdout)
        self.assertEqual(config['name'], 'easy-tor-bridge')
        self.assertEqual(config['services']['obfs4-bridge']['environment']['EMAIL'], 'saved@example.invalid')
        self.assertEqual(config['services']['obfs4-bridge']['environment']['PT_PORT'], '8443')
        self.assertEqual(config['volumes']['tor-data']['name'], 'easy-tor-bridge_tor-data')

    def bootstrap_script(self):
        return functions('wait_for_bootstrap') + r'''
success() { printf '%s\n' "$*"; }
compose() { echo "${CID:-container}"; }
DOCKER=fake_docker
fake_docker() {
    shift 2
    case "$1" in
        inspect) printf '%s|%s\n' "${STATUS:-running}" "$SESSION" ;;
        logs) if [[ $LOGS == present ]]; then echo 'Bootstrapped 100% (done): Done'; fi ;;
    esac
}
sleep() { SECONDS=$((SECONDS + 301)); }
'''

    def test_bootstrap_record_survives_rotation_but_not_restart(self):
        script = self.bootstrap_script() + '''
SESSION=first LOGS=present
wait_for_bootstrap || exit 10
LOGS=rotated
wait_for_bootstrap || exit 11
SESSION=second
if wait_for_bootstrap; then exit 12; fi
SESSION=first CID=replacement
if wait_for_bootstrap; then exit 13; fi
CID=container STATUS=exited
if wait_for_bootstrap; then exit 14; fi
'''
        result = self.shell(script)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_hung_check_is_killed_with_its_child(self):
        started = time.monotonic()
        result = self.shell(functions('run_bounded') + r'''
run_bounded 1 /bin/bash -c 'sleep 2; touch "$HOME/late-write"'
''', timeout=4)
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertLess(time.monotonic() - started, 2)
        time.sleep(1.3)
        self.assertFalse((self.home / 'late-write').exists())

    def test_watchdog_bounds_actual_worker_when_compose_hangs(self):
        worker = ROOT / 'scripts/bridge-runtime.sh'
        if not worker.exists():
            self.fail('Bootstrap worker missing')
        fake = self.home / 'hung-compose'
        fake.write_text('#!/bin/bash\nsleep 30\n')
        fake.chmod(0o755)
        self.env.update(WORKER=str(worker), FAKE=str(fake))
        result = self.shell(functions('run_bounded') + '\nrun_bounded 1 /bin/bash "$WORKER" /bin/false "$FAKE" "$PROJECT_DIR" "$CONTEXT" "$BOOTSTRAP_CACHE"')
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertFalse((self.home / 'bootstrap').exists())

    def test_watchdog_preserves_failure_status(self):
        result = self.shell(functions('run_bounded') + "\nrun_bounded 2 /bin/bash -c 'exit 7'")
        self.assertEqual(result.returncode, 7, result.stderr)

    def test_login_agent_preserves_daemons_and_retries_failed_starts(self):
        script = '''set -e
heading() { :; }
warning() { :; }
fail() { echo "$*" >&2; exit 1; }
launchctl() { [[ $1 != print ]]; }
BREW_PREFIX='/opt/test & brew'
''' + functions('configure_autostart') + '\nconfigure_autostart'
        result = self.shell(script, tty=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.home / 'Library/LaunchAgents/org.easy-tor-bridge.colima.plist'
        data = plistlib.loads(path.read_bytes())
        self.assertTrue(data.get('AbandonProcessGroup'))
        self.assertEqual(data.get('KeepAlive'), {'SuccessfulExit': False})
        self.assertEqual(data['ProgramArguments'][:3], ['/opt/test & brew/bin/colima', 'start', 'easy-tor-bridge'])


class NetworkTests(unittest.TestCase):
    setUp = InstallerTests.setUp
    shell = InstallerTests.shell

    def diagnostics(self, scenario, mode='post'):
        self.env.update(NETWORK_SCRIPT=str(ROOT / 'scripts/network-check.sh'),
                        RUNTIME=str(ROOT / 'scripts/bridge-runtime.sh'),
                        SCENARIO=scenario, MODE=mode, DOCKER='fake-docker')
        script = r'''
set -eu
source "$RUNTIME"
source "$NETWORK_SCRIPT"
success() { printf 'PASS %s\n' "$*"; }
warning() { printf 'WARN %s\n' "$*"; }
heading() { printf '%s\n' "$*"; }
compose() {
    [[ $SCENARIO != config-unknown ]] || return 1
    echo '{"services":{"obfs4-bridge":{"environment":{"OR_PORT":"9001","PT_PORT":"8443"}}}}'
}
network_command() {
    case "$1" in
        /sbin/route)
            [[ $SCENARIO != no-route ]] || return 1
            printf '   gateway: 192.168.1.1\n interface: en0\n' ;;
        /usr/sbin/ipconfig) echo 192.168.1.42 ;;
        /sbin/ifconfig) echo 'inet6 fe80::1%en0 prefixlen 64 scopeid 0x4' ;;
        /usr/sbin/lsof)
            if [[ $SCENARIO == occupied || $SCENARIO == occupied-prefix ]]; then
                echo 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME'
                echo 'otherapp 123 me 4u IPv4 1 0t0 TCP *:9001 (LISTEN)'
            else return 1; fi ;;
        /usr/bin/nc) [[ $SCENARIO != failed-probe ]] ;;
        /usr/libexec/ApplicationFirewall/socketfilterfw)
            if [[ $SCENARIO == firewall-unknown ]]; then return 1; fi
            if [[ $2 == --getglobalstate ]]; then echo 'Firewall is enabled. (State = 1)';
            elif [[ $SCENARIO == block-all ]]; then echo 'Firewall has block all state set to enabled.';
            else echo 'Firewall has block all state set to disabled.'; fi ;;
        /sbin/pfctl) return 1 ;;
        fake-docker)
            shift 3
            case "$1" in
                ps) echo container ;;
                port)
                    [[ $SCENARIO != occupied ]] || return 1
                    if [[ $SCENARIO == occupied-prefix ]]; then echo '0.0.0.0:90010';
                    else printf '0.0.0.0:%s\n' "${3%/tcp}"; fi ;;
                inspect) echo 'running|2026-10-06T01:00:00Z' ;;
                logs)
                    if [[ $SCENARIO == failed-probe ]]; then
                        echo 'Your server has not managed to confirm reachability for its ORPort(s)'
                    else
                        echo 'Self-testing indicates your ORPort is reachable from outside. Excellent.'
                    fi ;;
            esac ;;
        *) echo 'Unexpected command' >&2; return 99 ;;
    esac
}
network_diagnostics "$MODE"
'''
        return self.shell(script)

    def test_local_success_still_leaves_external_obfs4_unverified(self):
        result = self.diagnostics('healthy')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('192.168.1.42:8443', result.stdout)
        self.assertIn('OR port — Tor reported external reachability', result.stdout)
        self.assertIn('obfs4 Internet reachability — Unverified', result.stdout)

    def test_failed_local_probe_gives_forwarding_context_without_claiming_success(self):
        result = self.diagnostics('failed-probe')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Local-address TCP test failed', result.stdout)
        self.assertIn('8443 → 192.168.1.42:8443', result.stdout)
        self.assertIn('OR port — Tor has not confirmed external reachability', result.stdout)

    def test_missing_route_is_unknown_and_does_not_abort_other_checks(self):
        result = self.diagnostics('no-route')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('IPv4 route — Unavailable', result.stdout)
        self.assertIn('macOS application firewall', result.stdout)
        self.assertIn('obfs4 Internet reachability — Unverified', result.stdout)

    def test_preflight_reports_port_conflict(self):
        result = self.diagnostics('occupied', mode='pre')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('9001 — Occupied', result.stdout)
        self.assertIn('otherapp', result.stdout)

    def test_configuration_command_has_its_own_watchdog(self):
        self.env.update(NETWORK_SCRIPT=str(ROOT / 'scripts/network-check.sh'),
                        RUNTIME=str(ROOT / 'scripts/bridge-runtime.sh'))
        result = self.shell(r"""
source "$RUNTIME"
source "$NETWORK_SCRIPT"
# Use the actual watchdog with a shorter deadline for this regression check.
eval "$(declare -f run_bounded | sed '1s/run_bounded/original_run_bounded/')"
run_bounded() { shift; original_run_bounded 1 "$@"; }
compose() { sleep 30; }
network_config
""")
        self.assertEqual(result.returncode, 124, result.stderr)

    def test_config_failure_preserves_independent_observations(self):
        result = self.diagnostics('config-unknown')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Mac IPv4 address', result.stdout)
        self.assertIn('macOS application firewall', result.stdout)
        self.assertIn('obfs4 Internet reachability — Unverified', result.stdout)

    def test_mapping_requires_exact_port_match(self):
        result = self.diagnostics('occupied-prefix', mode='pre')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('9001 — Occupied', result.stdout)

    def test_block_all_firewall_is_a_warning(self):
        result = self.diagnostics('block-all')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('Block all incoming connections — Enabled', result.stdout)

    def test_unreadable_firewall_is_unknown_not_disabled(self):
        result = self.diagnostics('firewall-unknown')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('macOS application firewall — Unknown', result.stdout)


if __name__ == '__main__':
    unittest.main()
