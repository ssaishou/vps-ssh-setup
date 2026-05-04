#!/usr/bin/env bash
#
# Interactive SSH hardening script for Debian / Ubuntu servers.
#
# Features:
#   1) Change SSH port (handles systemd socket activation, ssh vs sshd names)
#   2) Add an SSH public key to authorized_keys
#   3) Disable password authentication (only after verifying key is in place)
#
# The port-change step backs up every file it touches and offers a rollback
# prompt so the user can restore the previous state from the same session
# if a new-port test connection fails.

set -uo pipefail

# ---------- output helpers ----------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
NC=$'\033[0m'

info()  { printf '%s[INFO]%s %s\n'  "$BLUE"   "$NC" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n'  "$GREEN"  "$NC" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'  "$YELLOW" "$NC" "$*"; }
err()   { printf '%s[ERR ]%s %s\n'  "$RED"    "$NC" "$*" >&2; }
ask()   { printf '%s%s%s '          "$BOLD"   "$*"  "$NC"; }

# ---------- privilege ----------
SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
        info "Not running as root, will use sudo for privileged commands."
    else
        err "This script needs root privileges (or sudo installed)."
        exit 1
    fi
fi

# ---------- globals filled in by detect_* ----------
SSH_SERVICE=""        # e.g. ssh.service or sshd.service
SSH_SOCKET=""         # e.g. ssh.socket if socket activation is in use, else empty
SSHD_CONFIG="/etc/ssh/sshd_config"
TARGET_USER=""        # whose authorized_keys we'll write to
TARGET_HOME=""

# ---------- detection ----------
detect_ssh_units() {
    local name
    SSH_SERVICE=""
    for name in ssh sshd; do
        if systemctl list-unit-files --type=service 2>/dev/null \
                | awk '{print $1}' | grep -qx "${name}.service"; then
            SSH_SERVICE="${name}.service"
            break
        fi
    done
    if [[ -z "$SSH_SERVICE" ]]; then
        err "Could not find an ssh.service or sshd.service unit."
        err "This script only supports systemd-managed OpenSSH on Debian/Ubuntu."
        exit 1
    fi
    ok  "Detected SSH service unit: $SSH_SERVICE"

    SSH_SOCKET=""
    for name in ssh sshd; do
        if systemctl list-unit-files --type=socket 2>/dev/null \
                | awk '{print $1}' | grep -qx "${name}.socket"; then
            if systemctl is-active --quiet "${name}.socket"; then
                SSH_SOCKET="${name}.socket"
                break
            fi
        fi
    done
    if [[ -n "$SSH_SOCKET" ]]; then
        warn "Socket activation is in use ($SSH_SOCKET)."
        warn "Port will be changed via a systemd drop-in, not just sshd_config."
    else
        info "No SSH socket activation detected; using sshd_config only."
    fi
}

detect_target_user() {
    # If invoked via sudo, prefer the original user; otherwise current user.
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        TARGET_USER="$SUDO_USER"
    else
        TARGET_USER="$(id -un)"
    fi
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
        err "Could not resolve home directory for user '$TARGET_USER'."
        exit 1
    fi
    info "Target user for SSH key: $TARGET_USER ($TARGET_HOME)"
}

get_current_port() {
    # Prefer the actual listening port (works for both classic and socket setups).
    local port
    port="$(ss -H -tlnp 2>/dev/null \
            | awk '$NF ~ /sshd|systemd/ {print $4}' \
            | awk -F: '{print $NF}' | sort -u | head -n1)"
    if [[ -z "$port" ]]; then
        port="$($SUDO sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
    fi
    if [[ -z "$port" ]]; then
        port="$(grep -Ei '^[[:space:]]*Port[[:space:]]+[0-9]+' "$SSHD_CONFIG" \
                | awk '{print $2}' | head -n1)"
    fi
    echo "${port:-22}"
}

# ---------- port validation ----------
validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        err "Port must be a positive integer."
        return 1
    fi
    if (( port < 1 || port > 65535 )); then
        err "Port must be in range 1-65535."
        return 1
    fi
    return 0
}

port_in_use() {
    local port="$1"
    ss -H -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
}

# ---------- backup helpers ----------
BACKUP_DIR=""
init_backup_dir() {
    BACKUP_DIR="/var/backups/ssh-setup-$(date +%Y%m%d-%H%M%S)-$$"
    $SUDO mkdir -p "$BACKUP_DIR"
    $SUDO chmod 700 "$BACKUP_DIR"
    info "Backups will be stored in $BACKUP_DIR"
}

backup_file() {
    local src="$1"
    [[ -e "$src" ]] || return 0
    local dest="$BACKUP_DIR/$(echo "$src" | sed 's|/|_|g')"
    $SUDO cp -a "$src" "$dest"
    echo "$dest"
}

# ---------- firewall ----------
detect_firewall() {
    if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "ufw"
    elif command -v firewall-cmd >/dev/null 2>&1 && $SUDO firewall-cmd --state 2>/dev/null | grep -q "running"; then
        echo "firewalld"
    else
        echo ""
    fi
}

firewall_open_port() {
    local fw="$1" port="$2"
    case "$fw" in
        ufw)       $SUDO ufw allow "${port}/tcp" >/dev/null && ok "ufw: allowed ${port}/tcp" ;;
        firewalld) $SUDO firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null \
                   && $SUDO firewall-cmd --reload >/dev/null \
                   && ok "firewalld: added ${port}/tcp" ;;
    esac
}

firewall_close_port() {
    local fw="$1" port="$2"
    case "$fw" in
        ufw)       $SUDO ufw delete allow "${port}/tcp" >/dev/null 2>&1 \
                   && ok "ufw: removed ${port}/tcp rule" ;;
        firewalld) $SUDO firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 \
                   && $SUDO firewall-cmd --reload >/dev/null \
                   && ok "firewalld: removed ${port}/tcp" ;;
    esac
}

# ---------- sshd_config edit ----------
# Set "Key Value" in sshd_config; replaces existing line(s) or appends.
set_sshd_option() {
    local key="$1" value="$2"
    local tmp
    tmp="$(mktemp)"
    # Strip every existing (commented or not) occurrence, then append the new one.
    $SUDO awk -v k="$key" 'BEGIN{IGNORECASE=1}
        {
            line=$0
            sub(/^[ \t]+/,"",line)
            sub(/^#+[ \t]*/,"",line)
            split(line,a,/[ \t]+/)
            if (tolower(a[1])==tolower(k)) next
            print
        }' "$SSHD_CONFIG" > "$tmp"
    printf '%s %s\n' "$key" "$value" >> "$tmp"
    $SUDO install -m 0644 -o root -g root "$tmp" "$SSHD_CONFIG"
    rm -f "$tmp"
}

# ---------- socket drop-in ----------
SOCKET_DROPIN_DIR=""
SOCKET_DROPIN_FILE=""
write_socket_dropin() {
    local port="$1"
    SOCKET_DROPIN_DIR="/etc/systemd/system/${SSH_SOCKET}.d"
    SOCKET_DROPIN_FILE="${SOCKET_DROPIN_DIR}/override.conf"
    $SUDO mkdir -p "$SOCKET_DROPIN_DIR"
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
[Socket]
ListenStream=
ListenStream=${port}
EOF
    $SUDO install -m 0644 -o root -g root "$tmp" "$SOCKET_DROPIN_FILE"
    rm -f "$tmp"
    $SUDO systemctl daemon-reload
}

remove_socket_dropin() {
    if [[ -n "$SOCKET_DROPIN_FILE" && -f "$SOCKET_DROPIN_FILE" ]]; then
        $SUDO rm -f "$SOCKET_DROPIN_FILE"
        $SUDO rmdir --ignore-fail-on-non-empty "$SOCKET_DROPIN_DIR" 2>/dev/null || true
        $SUDO systemctl daemon-reload
    fi
}

# ---------- restart logic ----------
restart_ssh() {
    if [[ -n "$SSH_SOCKET" ]]; then
        $SUDO systemctl restart "$SSH_SOCKET"
    fi
    # Validate config before restarting the service.
    if ! $SUDO sshd -t; then
        err "sshd -t reported a configuration error. NOT restarting service."
        return 1
    fi
    $SUDO systemctl restart "$SSH_SERVICE"
}

# =====================================================================
# Feature 1: change SSH port
# =====================================================================
change_port_flow() {
    local current_port new_port
    current_port="$(get_current_port)"
    info "Current SSH port appears to be: ${BOLD}${current_port}${NC}"

    while true; do
        ask "Enter the new SSH port (1-65535):"
        read -r new_port
        validate_port "$new_port" || continue
        if [[ "$new_port" == "$current_port" ]]; then
            warn "New port is the same as current port. Choose a different one."
            continue
        fi
        if (( new_port < 1024 )); then
            ask "Port $new_port is a privileged port (<1024). Continue? [y/N]:"
            read -r yn
            [[ "$yn" =~ ^[Yy]$ ]] || continue
        fi
        if port_in_use "$new_port"; then
            warn "Port $new_port appears to be in use by another service."
            ask "Continue anyway? [y/N]:"
            read -r yn
            [[ "$yn" =~ ^[Yy]$ ]] || continue
        fi
        break
    done

    # Backup
    local backup_sshd_config backup_socket_state="none"
    backup_sshd_config="$(backup_file "$SSHD_CONFIG")"
    if [[ -n "$SSH_SOCKET" ]]; then
        local existing_dropin="/etc/systemd/system/${SSH_SOCKET}.d/override.conf"
        if [[ -f "$existing_dropin" ]]; then
            backup_file "$existing_dropin" >/dev/null
            backup_socket_state="existed"
        else
            backup_socket_state="absent"
        fi
    fi

    # Apply
    info "Updating $SSHD_CONFIG (Port $new_port)..."
    set_sshd_option "Port" "$new_port"

    if [[ -n "$SSH_SOCKET" ]]; then
        info "Writing systemd socket drop-in for $SSH_SOCKET..."
        write_socket_dropin "$new_port"
    fi

    # Firewall
    local fw
    fw="$(detect_firewall)"
    if [[ -n "$fw" ]]; then
        info "Detected active firewall: $fw"
        ask "Allow new port ${new_port}/tcp through ${fw}? [Y/n]:"
        read -r yn
        if [[ ! "$yn" =~ ^[Nn]$ ]]; then
            firewall_open_port "$fw" "$new_port"
        fi
    else
        warn "No local firewall (ufw/firewalld) detected as active."
        warn "If your VPS uses a cloud security group, open port ${new_port}/tcp there before testing."
    fi

    # Restart
    info "Restarting SSH..."
    if ! restart_ssh; then
        err "SSH restart failed. Rolling back automatically."
        rollback_port "$current_port" "$backup_sshd_config" "$backup_socket_state" "$fw" "$new_port"
        return 1
    fi

    ok "SSH is now configured to listen on port ${new_port}."
    sleep 1
    if ! port_in_use "$new_port"; then
        warn "Port ${new_port} does not appear in 'ss -tln' output. Something may be off."
    fi

    # Test prompt with rollback
    cat <<EOF

${BOLD}=== IMPORTANT: TEST BEFORE CONTINUING ===${NC}
Keep THIS session open. From another terminal, run:

    ssh -p ${new_port} ${TARGET_USER}@<this-server>

Did the new connection succeed?
  [1] Yes, keep the new port (${new_port})
  [2] No, roll back to the old port (${current_port})
  [3] Skip the test (NOT recommended)
EOF
    while true; do
        ask "Choose [1/2/3]:"
        read -r choice
        case "$choice" in
            1) ok "Keeping new port ${new_port}."
               # Close old port in firewall (only if changed)
               if [[ -n "$fw" ]]; then
                   ask "Remove firewall rule for OLD port ${current_port}/tcp? [y/N]:"
                   read -r yn
                   [[ "$yn" =~ ^[Yy]$ ]] && firewall_close_port "$fw" "$current_port"
               fi
               return 0 ;;
            2) rollback_port "$current_port" "$backup_sshd_config" "$backup_socket_state" "$fw" "$new_port"
               return 0 ;;
            3) warn "Skipping test. Make sure you can reconnect before logging out!"
               return 0 ;;
            *) err "Invalid choice." ;;
        esac
    done
}

rollback_port() {
    local old_port="$1" backup_sshd="$2" socket_state="$3" fw="$4" failed_port="$5"
    warn "Rolling back to port ${old_port}..."

    if [[ -n "$backup_sshd" && -f "$backup_sshd" ]]; then
        $SUDO cp -a "$backup_sshd" "$SSHD_CONFIG"
        ok "Restored $SSHD_CONFIG"
    fi

    if [[ -n "$SSH_SOCKET" ]]; then
        local dropin="/etc/systemd/system/${SSH_SOCKET}.d/override.conf"
        case "$socket_state" in
            absent)
                $SUDO rm -f "$dropin"
                $SUDO rmdir --ignore-fail-on-non-empty "/etc/systemd/system/${SSH_SOCKET}.d" 2>/dev/null || true
                ;;
            existed)
                local backup_file_path="$BACKUP_DIR/$(echo "$dropin" | sed 's|/|_|g')"
                [[ -f "$backup_file_path" ]] && $SUDO cp -a "$backup_file_path" "$dropin"
                ;;
        esac
        $SUDO systemctl daemon-reload
    fi

    if [[ -n "$fw" && -n "$failed_port" ]]; then
        firewall_close_port "$fw" "$failed_port"
    fi

    if restart_ssh; then
        ok "Rolled back. SSH is again on port ${old_port}."
    else
        err "Rollback restart failed. Manual intervention required."
        err "Backups are in: $BACKUP_DIR"
    fi
}

# =====================================================================
# Feature 2: add SSH public key
# =====================================================================
add_key_flow() {
    local ssh_dir="${TARGET_HOME}/.ssh"
    local auth_file="${ssh_dir}/authorized_keys"

    cat <<EOF

Paste the public key (single line beginning with ssh-rsa / ssh-ed25519 / ecdsa-sha2-...).
Press ENTER when done:
EOF
    local pubkey
    read -r pubkey

    # Trim whitespace
    pubkey="$(echo "$pubkey" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [[ -z "$pubkey" ]]; then
        err "Empty input. Aborting."
        return 1
    fi
    if ! [[ "$pubkey" =~ ^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-[a-z0-9-]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256))[[:space:]]+[A-Za-z0-9+/=]+([[:space:]]+.*)?$ ]]; then
        err "That does not look like a valid OpenSSH public key."
        return 1
    fi

    # Use ssh-keygen to validate format if available.
    if command -v ssh-keygen >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        echo "$pubkey" > "$tmp"
        if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
            err "ssh-keygen rejected the key as malformed."
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
    fi

    # Ensure ~/.ssh exists with correct perms (run as the target user).
    $SUDO -u "$TARGET_USER" mkdir -p "$ssh_dir"
    $SUDO chmod 700 "$ssh_dir"
    $SUDO chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$ssh_dir"

    if [[ -f "$auth_file" ]] && $SUDO grep -qxF "$pubkey" "$auth_file"; then
        warn "This exact key is already present in $auth_file. Nothing to do."
        return 0
    fi

    backup_file "$auth_file" >/dev/null
    echo "$pubkey" | $SUDO tee -a "$auth_file" >/dev/null
    $SUDO chmod 600 "$auth_file"
    $SUDO chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$auth_file"
    ok "Public key appended to $auth_file"
}

# =====================================================================
# Feature 3: disable password authentication
# =====================================================================
disable_password_auth_flow() {
    local auth_file="${TARGET_HOME}/.ssh/authorized_keys"

    info "Pre-flight checks before disabling password authentication..."

    # 1. authorized_keys must exist and contain at least one key
    if [[ ! -s "$auth_file" ]] && ! $SUDO test -s "$auth_file"; then
        err "No authorized_keys found for $TARGET_USER ($auth_file)."
        err "Add a key first (option 2). Refusing to disable password login."
        return 1
    fi
    local key_count
    key_count="$($SUDO grep -cE '^(ssh-|ecdsa-|sk-)' "$auth_file" 2>/dev/null || echo 0)"
    if (( key_count < 1 )); then
        err "$auth_file has no recognizable public keys. Aborting."
        return 1
    fi
    ok "Found $key_count key(s) in $auth_file"

    # 2. Effective sshd config must allow pubkey auth
    local pubkey_auth
    pubkey_auth="$($SUDO sshd -T 2>/dev/null | awk '$1=="pubkeyauthentication"{print $2; exit}')"
    if [[ "$pubkey_auth" != "yes" ]]; then
        err "Effective PubkeyAuthentication is '$pubkey_auth' (need 'yes'). Aborting."
        return 1
    fi
    ok "PubkeyAuthentication is enabled."

    # 3. Confirm
    cat <<EOF

${YELLOW}You are about to disable password-based SSH login.${NC}
After this, ${BOLD}only key-based${NC} authentication will work for SSH.
Make sure you have already verified that your key works.

EOF
    ask "Type 'YES' (uppercase) to proceed:"
    read -r confirm
    if [[ "$confirm" != "YES" ]]; then
        info "Aborted by user."
        return 0
    fi

    backup_file "$SSHD_CONFIG" >/dev/null
    set_sshd_option "PasswordAuthentication" "no"
    set_sshd_option "ChallengeResponseAuthentication" "no"
    set_sshd_option "KbdInteractiveAuthentication" "no"
    set_sshd_option "UsePAM" "yes"  # leave PAM on; the auth method flags above gate it

    if ! restart_ssh; then
        err "SSH restart failed after disabling password auth. Check $BACKUP_DIR for the previous sshd_config."
        return 1
    fi
    ok "Password authentication disabled. SSH restarted."
}

# =====================================================================
# Menu
# =====================================================================
main_menu() {
    while true; do
        cat <<EOF

${BOLD}=== SSH setup menu ===${NC}
  1) Change SSH port
  2) Add SSH public key for ${TARGET_USER}
  3) Disable password authentication
  q) Quit
EOF
        ask "Choose:"
        read -r c
        case "$c" in
            1) change_port_flow ;;
            2) add_key_flow ;;
            3) disable_password_auth_flow ;;
            q|Q) info "Bye."; exit 0 ;;
            *) err "Invalid choice." ;;
        esac
    done
}

# ---------- entry ----------
main() {
    info "Interactive SSH setup for Debian/Ubuntu"
    if [[ ! -f "$SSHD_CONFIG" ]]; then
        err "$SSHD_CONFIG not found. Is OpenSSH server installed?"
        exit 1
    fi
    detect_ssh_units
    detect_target_user
    init_backup_dir
    main_menu
}

main "$@"
