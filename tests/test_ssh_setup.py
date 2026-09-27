"""Regression tests: SSH configuration and key writes stay in temp folders."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "ssh-setup.sh"
SSHD = shutil.which("sshd") or "/usr/sbin/sshd"
LINUX_ROOT = os.uname().sysname == "Linux" and os.geteuid() == 0


class SSHSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ssh-setup-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "sshd_config"
        self.key = self.root / "hostkey"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "",
                        "-f", str(self.key)], check=True)
        self.original = f"HostKey {self.key}\nUsePAM no\nPort 22\n"
        self.config.write_text(self.original)
        self.prefix = f"""
source {shlex.quote(str(SCRIPT))}
SUDO=""
TEST_ROOT={shlex.quote(str(self.root))}
SSHD_CONFIG="$TEST_ROOT/sshd_config"
SSHD_TARGET="$SSHD_CONFIG"
SSHD_INCLUDE_BASE="$TEST_ROOT"
SYSTEMD_CONFIG_DIR="$TEST_ROOT/systemd"
TARGET_USER="$(id -un)"
TARGET_HOME="$TEST_ROOT/home"
BACKUP_DIR="$TEST_ROOT/backups"
SSH_CONNECTION="192.0.2.20 45000 192.0.2.1 22"
SSHD_BIN={shlex.quote(SSHD)}
export PATH="/usr/sbin:$PATH"
mkdir -p "$TARGET_HOME/.ssh" "$BACKUP_DIR"
reset_modified_files
install() {{
    local args=()
    while (( $# )); do
        case "$1" in
            -o|-g) shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    command install "${{args[@]}}"
}}
chown() {{ return 0; }}
sshd() {{ "$SSHD_BIN" "$@"; }}
"""

    def run_shell(self, code, expected=0):
        run = subprocess.run(["bash", "-c", self.prefix + "\n" + code],
                             text=True, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, timeout=35)
        self.assertEqual(run.returncode, expected, run.stdout)
        return run.stdout

    def assert_config(self, expected):
        self.assertEqual(self.config.read_text(), expected)

    def test_main_guard_and_help(self):
        self.assertEqual(subprocess.run(["bash", "-n", str(SCRIPT)]).returncode, 0)
        output = subprocess.check_output(["bash", str(SCRIPT), "--help"], text=True)
        self.assertIn("Usage", output)

    def test_match_override_rejected_before_writes(self):
        self.original += "Match User *\n PasswordAuthentication yes\n"
        self.config.write_text(self.original)
        self.run_shell("""
if set_sshd_option PasswordAuthentication no; then exit 90; fi
[[ -z "${MODIFIED_FILES[*]:-}" ]]
""")
        self.assert_config(self.original)

    def test_nested_conditional_include_rejected(self):
        included = self.root / "nested auth.conf"
        included.write_text("pAsSwOrDaUtHeNtIcAtIoN yes\n")
        self.original += f'Match Address 192.0.2.*\n Include "{included}"\n'
        self.config.write_text(self.original)
        self.run_shell("if set_sshd_option PasswordAuthentication no; then exit 90; fi")
        self.assert_config(self.original)

    def test_alias_conflict_rejected(self):
        self.original += "Match User *\n ChallengeResponseAuthentication yes\n"
        self.config.write_text(self.original)
        self.run_shell("if set_sshd_option KbdInteractiveAuthentication no; then exit 90; fi")
        self.assert_config(self.original)

    def test_verification_applies_match_context(self):
        self.config.write_text(self.original +
                               "PasswordAuthentication no\nMatch User *\n PasswordAuthentication yes\n")
        self.run_shell("if verify_sshd_option PasswordAuthentication no; then exit 90; fi")

    def test_port_stays_global_before_match(self):
        self.config.write_text(self.original + "Match User nobody\n X11Forwarding no\n")
        self.run_shell("""
set_sshd_option Port 2222 || exit
sshd -t -f "$SSHD_CONFIG" || exit
verify_sshd_option Port 2222
""")
        self.assertTrue(self.config.read_text().startswith("port 2222\n"))
        self.assertIn("Match User nobody\n X11Forwarding no", self.config.read_text())

    def test_global_auth_overrides_include_without_editing_it(self):
        cloud = self.root / "cloud.conf"
        cloud.write_text("PasswordAuthentication yes\n")
        self.config.write_text(f"Include {cloud}\n" + self.original)
        self.run_shell("""
set_sshd_option PasswordAuthentication no || exit
verify_sshd_option PasswordAuthentication no
""")
        self.assertEqual(cloud.read_text(), "PasswordAuthentication yes\n")

    def test_additive_ports_removed_from_includes_and_rollback(self):
        cloud = self.root / "cloud.conf"
        cloud.write_text("Port 2022\n")
        original = f"Include {cloud}\n" + self.original
        self.config.write_text(original)
        self.run_shell("""
set_sshd_option Port 2222 || exit
verify_sshd_option Port 2222 || exit
restore_modified_files
""")
        self.assert_config(original)
        self.assertEqual(cloud.read_text(), "Port 2022\n")

    def test_repeated_changes_keep_preflow_backup(self):
        self.run_shell("""
set_sshd_option PasswordAuthentication no || exit
set_sshd_option KbdInteractiveAuthentication no || exit
set_sshd_option PasswordAuthentication yes || exit
restore_modified_files
""")
        self.assert_config(self.original)

    def test_backup_failure_stops_mutation(self):
        self.run_shell("""
cp() { return 1; }
if set_sshd_option Port 2222; then exit 90; fi
[[ -z "${MODIFIED_FILES[*]:-}" ]]
""")
        self.assert_config(self.original)

    def test_install_failure_does_not_truncate_config(self):
        self.run_shell("""
install() { return 1; }
if set_sshd_option Port 2222; then exit 90; fi
""")
        self.assert_config(self.original)

    def test_parse_failure_stops_mutation(self):
        self.run_shell("""
awk() { return 1; }
if set_sshd_option Port 2222; then exit 90; fi
""")
        self.assert_config(self.original)

    def test_missing_backup_makes_restore_fail(self):
        self.run_shell("""
MODIFIED_FILES=("$SSHD_CONFIG")
if restore_modified_files; then exit 90; fi
""")
        self.assert_config(self.original)

    def test_key_install_failure_is_not_reported_success(self):
        output = self.run_shell("""
printf 'old key\\n' > "$TARGET_HOME/.ssh/authorized_keys"
install() { return 1; }
if install_public_key 'ssh-ed25519 invalid'; then exit 90; fi
[[ "$(cat "$TARGET_HOME/.ssh/authorized_keys")" == 'old key' ]]
""")
        self.assertNotIn("Public key installed", output)

    def test_key_backup_failure_preserves_existing_file(self):
        self.run_shell("""
printf 'old key\\n' > "$TARGET_HOME/.ssh/authorized_keys"
cp() { return 1; }
if install_public_key 'ssh-ed25519 invalid'; then exit 90; fi
[[ "$(cat "$TARGET_HOME/.ssh/authorized_keys")" == 'old key' ]]
""")

    def test_key_append_handles_missing_newline(self):
        self.run_shell("""
printf '%s' "$(cat "$TEST_ROOT/hostkey.pub")" > "$TARGET_HOME/.ssh/authorized_keys"
install_public_key "$(cat "$TEST_ROOT/hostkey.pub") second" || exit
[[ "$(ssh-keygen -l -f "$TARGET_HOME/.ssh/authorized_keys" | wc -l | tr -d ' ')" == 2 ]]
""")

    def test_new_key_file_removed_on_rollback(self):
        self.run_shell("""
install_public_key "$(cat "$TEST_ROOT/hostkey.pub")" || exit
restore_modified_files || exit
[[ ! -e "$TARGET_HOME/.ssh/authorized_keys" ]]
""")

    def test_socket_keeps_admin_override_and_addresses(self):
        self.run_shell("""
SSH_SOCKET=ssh.socket
mkdir -p "$SYSTEMD_CONFIG_DIR/ssh.socket.d"
printf '[Socket]\\nBindToDevice=lo\\nListenStream=127.0.0.1:22\\n' > "$SYSTEMD_CONFIG_DIR/ssh.socket.d/override.conf"
cp "$SYSTEMD_CONFIG_DIR/ssh.socket.d/override.conf" "$TEST_ROOT/override-before"
systemctl() {
    if [[ "$1" == show ]]; then printf '127.0.0.1:22 (Stream) [::1]:22 (Stream)\\n'; fi
}
SOCKET_LISTEN_LINES="$(socket_listen_lines 2222 | sort -u)" || exit
write_socket_dropin || exit
cmp "$TEST_ROOT/override-before" "$SYSTEMD_CONFIG_DIR/ssh.socket.d/override.conf" || exit
grep -qxF 'ListenStream=127.0.0.1:2222' "$SOCKET_DROPIN_FILE" || exit
grep -qxF 'ListenStream=[::1]:2222' "$SOCKET_DROPIN_FILE" || exit
restore_modified_files || exit
[[ ! -e "$SOCKET_DROPIN_FILE" ]]
""")

    def test_unsupported_socket_address_fails_closed(self):
        self.run_shell("""
SSH_SOCKET=ssh.socket
systemctl() { printf '/run/ssh.sock (Stream)\\n'; }
if socket_listen_lines 2222; then exit 90; fi
""")

    def ufw_prefix(self):
        return r'''
grep() {
    if [[ "$*" == *"/etc/default/ufw"* ]]; then return 0; fi
    command grep "$@"
}
ufw() {
    printf '%s\n' "$*" >> "$TEST_ROOT/ufw-log"
    if [[ "$1" == allow ]]; then
        if [[ "$*" == *"0.0.0.0/0"* ]]; then
            printf 'Skipping adding existing rule\n'
        else
            printf 'Rule added (v6)\n'
        fi
    fi
}
'''

    def test_ufw_mixed_families_only_revert_new_rule(self):
        self.run_shell(self.ufw_prefix() + r'''
firewall_open_port ufw 2222 || exit
[[ "${FIREWALL_ADDED[*]}" == ufw6 ]] || exit 90
rollback_firewall 2222 || exit
if grep -F -- '--force delete allow proto tcp from 0.0.0.0/0' "$TEST_ROOT/ufw-log"; then exit 90; fi
grep -F -- '--force delete allow proto tcp from ::/0' "$TEST_ROOT/ufw-log"
''')

    def test_ufw_existing_rules_are_never_removed(self):
        self.run_shell(self.ufw_prefix() + r'''
ufw() { printf 'Skipping adding existing rule\n'; }
firewall_open_port ufw 2222 || exit
[[ -z "${FIREWALL_ADDED[*]:-}" ]] || exit 90
ufw() { exit 90; }
rollback_firewall 2222
''')

    def test_declined_firewall_changes_have_nothing_to_revert(self):
        self.run_shell("""
ufw() { exit 90; }
firewall_open_port "" 2222 || exit
rollback_firewall 2222
""")

    def test_firewalld_tracks_runtime_and_permanent_separately(self):
        self.run_shell(r'''
firewall-cmd() {
    printf '%s\n' "$*" >> "$TEST_ROOT/firewalld-log"
    case "$*" in
        --get-default-zone) printf 'public\n' ;;
        *--query-port*)
            if [[ "$*" == *--permanent* ]]; then return 1; fi ;;
    esac
}
firewall_open_port firewalld 2222 || exit
[[ "${FIREWALL_ADDED[*]}" == firewalld-permanent ]] || exit 90
rollback_firewall 2222 || exit
[[ "$(grep -c -- --remove-port "$TEST_ROOT/firewalld-log")" == 1 ]] || exit 90
grep -F -- '--zone=public --permanent --remove-port=2222/tcp' "$TEST_ROOT/firewalld-log" || exit
if grep -F -- --reload "$TEST_ROOT/firewalld-log"; then exit 90; fi
''')

    def test_firewalld_query_error_aborts(self):
        self.run_shell(r'''
firewall-cmd() {
    case "$*" in
        --get-default-zone) printf 'public\n' ;;
        *--query-port*) return 2 ;;
        *--add-port*) exit 90 ;;
    esac
}
if firewall_open_port firewalld 2222; then exit 90; fi
[[ -z "${FIREWALL_ADDED[*]:-}" ]]
''')

    def test_disable_password_rejects_malformed_key(self):
        self.run_shell("""
printf 'ssh-ed25519 invalid\\n' > "$TARGET_HOME/.ssh/authorized_keys"
if disable_password_auth_flow <<< YES; then exit 90; fi
""")
        self.assert_config(self.original)

    def test_disable_password_full_success(self):
        self.run_shell("""
cp "$TEST_ROOT/hostkey.pub" "$TARGET_HOME/.ssh/authorized_keys"
restart_ssh() { sshd -t -f "$SSHD_CONFIG"; }
disable_password_auth_flow <<< YES || exit
verify_sshd_option PasswordAuthentication no || exit
verify_sshd_option KbdInteractiveAuthentication no
""")

    def test_full_disable_rejects_other_user_exception(self):
        self.original += "Match User another-user\n PasswordAuthentication yes\n"
        self.config.write_text(self.original)
        self.run_shell("""
cp "$TEST_ROOT/hostkey.pub" "$TARGET_HOME/.ssh/authorized_keys"
restart_ssh() { exit 90; }
if disable_password_auth_flow <<< YES; then exit 90; fi
""")
        self.assert_config(self.original)

    def test_preflight_failure_rolls_back_new_key(self):
        self.config.write_text(self.original + "Match User *\n PubkeyAuthentication no\n")
        self.run_shell("""
restart_ssh() { return 0; }
install_public_key "$(cat "$TEST_ROOT/hostkey.pub")" || exit
if enable_pubkey_auth_flow --preserve-tracking; then exit 90; fi
[[ ! -e "$TARGET_HOME/.ssh/authorized_keys" ]]
""")

    def test_port_rejects_octal_and_overflow(self):
        self.run_shell("""
for value in 080 00022 0 65536 18446744073709551617; do
    if validate_port "$value"; then exit 90; fi
done
validate_port 22 && validate_port 65535
""")

    def test_eof_requests_rollback(self):
        output = self.run_shell("""
get_current_port() { echo 22; }
port_in_use() { return 1; }
detect_firewall() { return 0; }
arm_port_rollback() {
    PORT_RUNNER="$TEST_ROOT/fake-runner"
    printf '#!/bin/bash\\nexit 0\\n' > "$PORT_RUNNER"
}
finish_port_transaction() { echo "DECISION=$1"; PORT_RUNNER=""; }
change_port_flow <<'INPUT'
2222
y
INPUT
""", expected=1)
        self.assertIn("DECISION=rollback", output)

    @unittest.skipUnless(LINUX_ROOT, "serialized recovery helper requires Linux root")
    def test_guard_serialization_and_expired_confirmation(self):
        self.run_shell("""
unset -f install chown
PORT_NEW=2222 PORT_OLD=22 PORT_FIREWALL=""
systemd-run() { return 0; }
restart_ssh() { return 0; }
verify_port_listener() { return 0; }
arm_port_rollback || exit
/bin/bash "$PORT_RUNNER" apply || exit
grep -qx 'port 2222' "$SSHD_CONFIG" || exit
/bin/bash "$PORT_RUNNER" rollback || exit
if /bin/bash "$PORT_RUNNER" commit; then exit 90; fi
[[ "$(cat "$PORT_RUNNER.status")" == rolled-back ]]
""")
        self.assert_config(self.original)

    @unittest.skipUnless(LINUX_ROOT, "real flock concurrency requires Linux root")
    def test_guard_confirmation_and_timeout_are_serialized(self):
        self.run_shell("""
unset -f install chown
PORT_NEW=2222 PORT_OLD=22 PORT_FIREWALL=""
systemd-run() { return 0; }
restart_ssh() { return 0; }
verify_port_listener() { return 0; }
arm_port_rollback || exit
/bin/bash "$PORT_RUNNER" apply || exit
/bin/bash "$PORT_RUNNER" commit & commit_pid=$!
/bin/bash "$PORT_RUNNER" rollback & rollback_pid=$!
wait "$commit_pid"; commit_rc=$?
wait "$rollback_pid" || exit
state="$(cat "$PORT_RUNNER.status")"
case "$state" in
    committed) [[ "$commit_rc" == 0 ]] && grep -qx 'port 2222' "$SSHD_CONFIG" ;;
    rolled-back) [[ "$commit_rc" != 0 ]] && grep -qx 'Port 22' "$SSHD_CONFIG" ;;
    *) exit 90 ;;
esac
""")

    @unittest.skipUnless(LINUX_ROOT and Path("/run/systemd/system").is_dir(),
                         "needs a running systemd")
    def test_real_timer_recovers_after_parent_is_killed(self):
        code = """
unset -f install chown
PORT_NEW=2222 PORT_OLD=22 PORT_FIREWALL="" PORT_TIMEOUT=3
restart_ssh() { return 0; }
verify_port_listener() { return 0; }
arm_port_rollback || exit
printf '%s' "$PORT_TIMER_UNIT" > "$TEST_ROOT/timer-unit"
/bin/bash "$PORT_RUNNER" apply || exit
kill -KILL $$
"""
        run = subprocess.run(["bash", "-c", self.prefix + code],
                             text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=25)
        self.assertEqual(run.returncode, -9, run.stdout)
        timer = (self.root / "timer-unit").read_text()
        self.addCleanup(subprocess.run, ["systemctl", "stop", timer + ".timer", timer + ".service"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        status = self.root / "backups/flow-1/port-transaction.sh.status"
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if status.exists() and status.read_text().strip() == "rolled-back":
                break
            time.sleep(0.2)
        self.assertEqual(status.read_text().strip(), "rolled-back", run.stdout)
        self.assert_config(self.original)

    @unittest.skipUnless(LINUX_ROOT and os.environ.get("SSH_SETUP_SOCKET_INTEGRATION") == "1",
                         "requires Ubuntu socket-activation support")
    def test_real_socket_port_change_preserves_loopback_and_rolls_back(self):
        import socket
        with socket.socket() as first, socket.socket() as second:
            first.bind(("127.0.0.1", 0))
            second.bind(("127.0.0.1", 0))
            old, new = first.getsockname()[1], second.getsockname()[1]
        stem = f"ssh-setup-test-{os.getpid()}"
        units = Path("/run/systemd/system")
        service_path = units / (stem + ".service")
        socket_path = units / (stem + ".socket")
        dropin_dir = units / (stem + ".socket.d")

        def cleanup():
            timer_path = self.root / "timer-unit"
            if timer_path.exists():
                timer = timer_path.read_text()
                subprocess.run(["systemctl", "stop", timer + ".timer", timer + ".service"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["systemctl", "stop", stem + ".service", stem + ".socket"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            service_path.unlink(missing_ok=True)
            socket_path.unlink(missing_ok=True)
            shutil.rmtree(dropin_dir, ignore_errors=True)
            subprocess.run(["systemctl", "daemon-reload"], check=True)
        self.addCleanup(cleanup)

        self.original = f"HostKey {self.key}\nPort {old}\nListenAddress 127.0.0.1\n"
        self.config.write_text(self.original)
        service_path.write_text(
            f"[Unit]\nRequires={stem}.socket\nAfter={stem}.socket\n"
            f"[Service]\nExecStart={SSHD} -D -e -f {self.config}\nKillMode=process\n")
        socket_path.write_text(f"[Socket]\nListenStream=127.0.0.1:{old}\nAccept=no\n")
        dropin_dir.mkdir()
        admin = dropin_dir / "override.conf"
        admin.write_text("[Socket]\nBindToDevice=lo\n")
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        subprocess.run(["systemctl", "start", stem + ".socket"], check=True)
        guard_prefix = f"""
unset -f install chown
SSH_SOCKET={stem}.socket
SSH_SERVICE={stem}.service
SYSTEMD_CONFIG_DIR=/run/systemd/system
PORT_NEW={new} PORT_OLD={old} PORT_FIREWALL="" PORT_TIMEOUT=30
SOCKET_LISTEN_LINES="$(socket_listen_lines "$PORT_NEW" | sort -u)" || exit
"""
        self.run_shell(guard_prefix + """
arm_port_rollback || exit
printf '%s' "$PORT_TIMER_UNIT" > "$TEST_ROOT/timer-unit"
/bin/bash "$PORT_RUNNER" apply
""")
        with socket.create_connection(("127.0.0.1", new), timeout=3) as connection:
            self.assertTrue(connection.recv(128).startswith(b"SSH-"))
        self.assertEqual(admin.read_text(), "[Socket]\nBindToDevice=lo\n")
        self.run_shell("""
/bin/bash "$TEST_ROOT/backups/flow-1/port-transaction.sh" rollback
""")
        with socket.create_connection(("127.0.0.1", old), timeout=3) as connection:
            self.assertTrue(connection.recv(128).startswith(b"SSH-"))
        self.assert_config(self.original)


if __name__ == "__main__":
    unittest.main(verbosity=2)
