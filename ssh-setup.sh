#!/usr/bin/env bash
#
# Interactive SSH hardening script for Debian / Ubuntu servers.
#
# Features:
#   1) Change SSH port (handles systemd socket activation, ssh vs sshd names)
#   2) Manage SSH password and keys
#      - Change the target user's SSH login password
#      - Add a public key and enable public-key authentication
#      - Remove a public key after restoring password login
#      - Disable password authentication after verifying a key is in place
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
SSH_SERVICE_MANAGER="systemctl"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR_CFG="/etc/ssh/sshd_config.d"
SSHD_TARGET=""        # file we write directives to (main config or 00-ssh-setup.conf)
SSHD_USE_DROPIN=0     # 1 if the main config Includes sshd_config.d/*.conf
TARGET_USER=""        # whose authorized_keys we'll write to
TARGET_HOME=""
INSTALL_PATH="/usr/local/bin/ssh-setup"
INSTALL_SOURCE_URL="https://raw.githubusercontent.com/ssaishou/vps-ssh-setup/main/ssh-setup.sh"

# Files modified / created in the current flow, used for rollback.
MODIFIED_FILES=()
CREATED_FILES=()

# ---------- install / CLI helpers ----------
usage() {
    cat <<EOF
Usage / 用法:
  ssh-setup
      Open the interactive menu / 打开交互菜单

  ssh-setup --install
      Install this script as ${INSTALL_PATH} / 安装命令到 ${INSTALL_PATH}

  ssh-setup --uninstall
      Remove ${INSTALL_PATH} / 删除 ${INSTALL_PATH}

  ssh-setup --help
      Show this help / 显示帮助

Remote one-liner / 远程一键运行:
  bash <(curl -fsSL ${INSTALL_SOURCE_URL})

Remote install / 远程安装:
  bash <(curl -fsSL ${INSTALL_SOURCE_URL}) --install

After installing, run anytime with / 安装后可随时运行:
  ssh-setup
EOF
}

install_self() {
    local src="${BASH_SOURCE[0]}"
    local tmp=""

    if [[ "$src" == /dev/fd/* || "$src" == /proc/self/fd/* ]]; then
        tmp="$(mktemp)"
        if ! command -v curl >/dev/null 2>&1; then
            err "curl is required to install from a remote one-liner."
            err "通过远程一键命令安装需要 curl。"
            rm -f "$tmp"
            return 1
        fi
        if ! curl -fsSL -H 'Cache-Control: no-cache' "${INSTALL_SOURCE_URL}?ts=$(date +%s)" -o "$tmp"; then
            err "Failed to download installer from ${INSTALL_SOURCE_URL}"
            err "无法从 ${INSTALL_SOURCE_URL} 下载安装文件。"
            rm -f "$tmp"
            return 1
        fi
        src="$tmp"
    elif [[ ! -r "$src" ]]; then
        err "Cannot read current script source: $src"
        err "无法读取当前脚本源文件：$src"
        return 1
    fi

    if command -v ssh-setup >/dev/null 2>&1; then
        local existing
        existing="$(command -v ssh-setup)"
        if [[ "$existing" != "$INSTALL_PATH" ]]; then
            warn "Another ssh-setup command already exists at: $existing"
            warn "系统里已经存在另一个 ssh-setup 命令：$existing"
            ask "Continue installing to ${INSTALL_PATH}? / 仍然安装到 ${INSTALL_PATH} 吗？[y/N]:"
            local yn
            read -r yn
            if [[ ! "$yn" =~ ^[Yy]$ ]]; then
                rm -f "$tmp"
                info "Aborted by user / 用户已取消。"
                return 0
            fi
        fi
    fi

    if ! $SUDO install -m 0755 -o root -g root "$src" "$INSTALL_PATH"; then
        err "Failed to install to ${INSTALL_PATH}"
        err "无法安装到 ${INSTALL_PATH}。"
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    ok "Installed to ${INSTALL_PATH} / 已安装到 ${INSTALL_PATH}"
    printf '\nRun anytime with / 以后可随时运行：\n  ssh-setup\n'
}

uninstall_self() {
    if [[ ! -e "$INSTALL_PATH" ]] && ! $SUDO test -e "$INSTALL_PATH"; then
        warn "${INSTALL_PATH} is not installed / ${INSTALL_PATH} 尚未安装。"
        return 0
    fi

    ask "Remove ${INSTALL_PATH}? / 删除 ${INSTALL_PATH} 吗？[y/N]:"
    local yn
    read -r yn
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        info "Aborted by user / 用户已取消。"
        return 0
    fi

    $SUDO rm -f "$INSTALL_PATH"
    ok "Removed ${INSTALL_PATH} / 已删除 ${INSTALL_PATH}"
}

handle_cli_args() {
    case "${1:-}" in
        "" ) return 0 ;;
        --install)
            install_self
            exit $?
            ;;
        --uninstall)
            uninstall_self
            exit $?
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            err "未知参数：$1"
            usage
            exit 1
            ;;
    esac
}

# ---------- detection ----------
systemd_unit_exists() {
    local unit="$1"
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl cat "$unit" >/dev/null 2>&1 && return 0
    systemctl list-unit-files --all "$unit" --no-legend 2>/dev/null \
        | awk '{print $1}' | grep -qx "$unit" && return 0
    systemctl list-units --all "$unit" --no-legend 2>/dev/null \
        | awk '{print $1}' | grep -qx "$unit" && return 0
    return 1
}

detect_ssh_units() {
    local name
    SSH_SERVICE=""
    SSH_SOCKET=""
    SSH_SERVICE_MANAGER="systemctl"

    for name in ssh sshd; do
        if systemd_unit_exists "${name}.socket" && systemctl is-active --quiet "${name}.socket"; then
            SSH_SOCKET="${name}.socket"
            break
        fi
    done

    for name in ssh sshd; do
        if systemd_unit_exists "${name}.service"; then
            SSH_SERVICE="${name}.service"
            break
        fi
    done

    if [[ -z "$SSH_SERVICE" && -z "$SSH_SOCKET" ]] && command -v service >/dev/null 2>&1; then
        for name in ssh sshd; do
            if [[ -x "/etc/init.d/${name}" ]] || service "$name" status >/dev/null 2>&1; then
                SSH_SERVICE="$name"
                SSH_SERVICE_MANAGER="service"
                break
            fi
        done
    fi

    if [[ -n "$SSH_SERVICE" ]]; then
        ok  "Detected SSH service unit / 检测到 SSH 服务单元: $SSH_SERVICE"
    elif [[ -n "$SSH_SOCKET" ]]; then
        ok  "Detected SSH socket activation / 检测到 SSH socket 激活: $SSH_SOCKET"
        warn "No standalone ssh.service/sshd.service was found; socket restart will be used."
        warn "未找到独立的 ssh.service/sshd.service，将使用 socket 重启。"
    else
        err "Could not find an ssh.service, sshd.service, or active ssh.socket unit."
        err "未找到 ssh.service、sshd.service 或启用中的 ssh.socket。"
        err "If this VPS uses OpenSSH, please send the output of:"
        err "如果这台 VPS 使用 OpenSSH，请把下面命令的输出发给我："
        err "  systemctl list-units --all 'ssh*' 'sshd*'"
        err "  systemctl list-unit-files 'ssh*' 'sshd*'"
        exit 1
    fi

    if [[ -n "$SSH_SOCKET" ]]; then
        warn "Socket activation is in use / 当前使用 socket 激活 ($SSH_SOCKET)."
        warn "Port will be changed via a systemd drop-in / 端口会通过 systemd drop-in 修改。"
    else
        info "No SSH socket activation detected; using sshd_config only / 未检测到 socket 激活，仅修改 sshd_config。"
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
    info "Target user for SSH key / SSH 密钥目标用户: $TARGET_USER ($TARGET_HOME)"
}

get_current_port() {
    # Prefer the active socket unit when socket activation is in use.
    local port=""
    if [[ -n "$SSH_SOCKET" ]]; then
        port="$($SUDO systemctl show "$SSH_SOCKET" --property=Listen --value 2>/dev/null \
                | sed 's/ (Stream)//g' \
                | tr ' ' '\n' \
                | sed -nE 's/.*:([0-9]+)$/\1/p; s/^([0-9]+)$/\1/p' \
                | sort -un | head -n1)"
    fi
    if [[ -z "$port" ]]; then
        port="$($SUDO ss -H -tlnp 2>/dev/null \
                | grep -E 'sshd' \
                | awk '{print $4}' \
                | awk -F: '{print $NF}' | sort -un | head -n1)"
    fi
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

# ---------- change tracking (per-flow rollback) ----------
reset_modified_files() {
    MODIFIED_FILES=()
    CREATED_FILES=()
}

is_created() {
    local f="$1" existing
    for existing in "${CREATED_FILES[@]+"${CREATED_FILES[@]}"}"; do
        [[ "$existing" == "$f" ]] && return 0
    done
    return 1
}

remember_modified() {
    local f="$1" existing
    is_created "$f" && return 0
    for existing in "${MODIFIED_FILES[@]+"${MODIFIED_FILES[@]}"}"; do
        [[ "$existing" == "$f" ]] && return 0
    done
    MODIFIED_FILES+=("$f")
}

remember_created() {
    CREATED_FILES+=("$1")
}

# Restore every file we touched in the current flow to its pre-flow state.
restore_modified_files() {
    local f backup_path
    for f in "${MODIFIED_FILES[@]+"${MODIFIED_FILES[@]}"}"; do
        backup_path="$BACKUP_DIR/$(echo "$f" | sed 's|/|_|g')"
        if $SUDO test -f "$backup_path"; then
            $SUDO cp -a "$backup_path" "$f"
            ok "Restored $f"
        fi
    done
    for f in "${CREATED_FILES[@]+"${CREATED_FILES[@]}"}"; do
        $SUDO rm -f "$f"
        ok "Removed $f"
    done
}

# ---------- sshd_config target detection ----------
detect_sshd_target() {
    SSHD_TARGET="$SSHD_CONFIG"
    SSHD_USE_DROPIN=0
    if $SUDO grep -qE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d' "$SSHD_CONFIG" 2>/dev/null; then
        if $SUDO test -d "$SSHD_DROPIN_DIR_CFG"; then
            SSHD_TARGET="$SSHD_DROPIN_DIR_CFG/00-ssh-setup.conf"
            SSHD_USE_DROPIN=1
            info "sshd_config Includes ${SSHD_DROPIN_DIR_CFG}/*.conf"
            info "Will write directives to: $SSHD_TARGET"
        fi
    fi
}

# Echo every effective sshd config file (main + included drop-ins), one per line.
list_sshd_config_files() {
    echo "$SSHD_CONFIG"
    if (( SSHD_USE_DROPIN )); then
        $SUDO find "$SSHD_DROPIN_DIR_CFG" -maxdepth 1 -type f -name '*.conf' 2>/dev/null
    fi
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
# Set "Key Value" so it actually wins. sshd_config uses first-match-wins
# semantics, which means a value in /etc/ssh/sshd_config.d/50-cloud-init.conf
# (loaded earlier via Include) overrides anything we append at the bottom of
# the main config. To get the value we want:
#   1) Strip uncommented occurrences of $key from every other config file in
#      the global section (Match blocks left alone).
#   2) Write the directive to $SSHD_TARGET, which is either the main config
#      (no Include) or a low-numbered drop-in (00-ssh-setup.conf) that wins
#      first-match-wins lexically.
set_sshd_option() {
    local key="$1" value="$2"
    local f tmp

    # Phase 1: strip from every file except SSHD_TARGET.
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        [[ "$f" == "$SSHD_TARGET" ]] && continue
        $SUDO test -f "$f" || continue
        if ! $SUDO grep -qiE "^[[:space:]]*${key}[[:space:]]+" "$f"; then
            continue
        fi
        info "Removing conflicting '$key' from $f"
        backup_file "$f" >/dev/null
        remember_modified "$f"
        tmp="$(mktemp)"
        $SUDO awk -v k="$key" '
            BEGIN { in_match=0 }
            {
                if (!in_match) {
                    stripped=$0
                    sub(/^[ \t]+/,"",stripped)
                    if (stripped ~ /^[Mm]atch[[:space:]]/) {
                        in_match=1
                    } else if (stripped !~ /^#/) {
                        split(stripped,a," ")
                        if (tolower(a[1])==tolower(k)) next
                    }
                }
                print
            }' "$f" > "$tmp"
        $SUDO install -m 0644 -o root -g root "$tmp" "$f"
        rm -f "$tmp"
    done < <(list_sshd_config_files)

    # Phase 2: write the directive to SSHD_TARGET.
    if $SUDO test -e "$SSHD_TARGET"; then
        if ! is_created "$SSHD_TARGET"; then
            backup_file "$SSHD_TARGET" >/dev/null
            remember_modified "$SSHD_TARGET"
        fi
        tmp="$(mktemp)"
        $SUDO awk -v k="$key" '
            BEGIN { in_match=0 }
            {
                if (!in_match) {
                    stripped=$0
                    sub(/^[ \t]+/,"",stripped)
                    if (stripped ~ /^[Mm]atch[[:space:]]/) {
                        in_match=1
                    } else {
                        uncommented=stripped
                        sub(/^#+[ \t]*/,"",uncommented)
                        split(uncommented,a," ")
                        if (tolower(a[1])==tolower(k)) next
                    }
                }
                print
            }' "$SSHD_TARGET" > "$tmp"
        printf '%s %s\n' "$key" "$value" >> "$tmp"
        $SUDO install -m 0644 -o root -g root "$tmp" "$SSHD_TARGET"
        rm -f "$tmp"
    else
        tmp="$(mktemp)"
        {
            echo "# Managed by ssh-setup.sh"
            echo "# Loaded early via Include; wins first-match-wins over later definitions."
            printf '%s %s\n' "$key" "$value"
        } > "$tmp"
        $SUDO install -m 0644 -o root -g root "$tmp" "$SSHD_TARGET"
        rm -f "$tmp"
        remember_created "$SSHD_TARGET"
    fi
}

# Verify the effective value of a sshd keyword equals $expected.
# Returns 0 on match, 1 otherwise. Skips silently if sshd -T can't answer.
verify_sshd_option() {
    local key="$1" expected="$2"
    local lc_key actual
    lc_key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    actual="$($SUDO sshd -T 2>/dev/null | awk -v k="$lc_key" '$1==k {print $2; exit}')"
    if [[ -z "$actual" ]]; then
        warn "Could not query effective $key via sshd -T."
        return 1
    fi
    if [[ "$actual" != "$expected" ]]; then
        err "Effective $key is '$actual', expected '$expected'."
        err "Another file is overriding it. Check $SSHD_CONFIG and ${SSHD_DROPIN_DIR_CFG}/*.conf."
        return 1
    fi
    return 0
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
    # Validate config before touching any running service or socket.
    if ! $SUDO sshd -t; then
        err "sshd -t reported a configuration error. NOT restarting service."
        return 1
    fi
    if [[ -n "$SSH_SOCKET" ]]; then
        if ! $SUDO systemctl restart "$SSH_SOCKET"; then
            err "Failed to restart $SSH_SOCKET"
            err "重启 $SSH_SOCKET 失败。"
            return 1
        fi
    fi
    if [[ -z "$SSH_SERVICE" ]]; then
        return 0
    fi
    if [[ "$SSH_SERVICE_MANAGER" == "service" ]]; then
        $SUDO service "$SSH_SERVICE" restart
    else
        $SUDO systemctl restart "$SSH_SERVICE"
    fi
}

restore_password_auth() {
    reset_modified_files
    set_sshd_option "PasswordAuthentication" "yes"
    set_sshd_option "KbdInteractiveAuthentication" "yes"
    set_sshd_option "UsePAM" "yes"

    if ! restart_ssh; then
        err "SSH restart failed after restoring password login. Rolling back."
        err "恢复密码登录后重启 SSH 失败，正在回滚。"
        restore_modified_files
        restart_ssh >/dev/null 2>&1 || err "Rollback restart failed. Manual intervention required."
        return 1
    fi

    if ! verify_sshd_option PasswordAuthentication yes; then
        err "Password login is NOT effectively enabled. Rolling back."
        err "密码登录没有真正启用，正在回滚。"
        restore_modified_files
        restart_ssh >/dev/null 2>&1 || err "Rollback restart failed. Manual intervention required."
        return 1
    fi
    ok "Password login restored and verified / 密码登录已恢复并验证。"
}

# =====================================================================
# Feature 1: change SSH port
# =====================================================================
change_port_flow() {
    local current_port new_port yn choice
    current_port="$(get_current_port)"
    info "Current SSH port appears to be / 当前 SSH 端口似乎是: ${BOLD}${current_port}${NC}"

    while true; do
        ask "Enter the new SSH port / 输入新的 SSH 端口 (1-65535):"
        read -r new_port
        validate_port "$new_port" || continue
        if [[ "$new_port" == "$current_port" ]]; then
            warn "New port is the same as current port / 新端口和当前端口相同，请换一个。"
            continue
        fi
        if (( new_port < 1024 )); then
            ask "Port $new_port is a privileged port (<1024). Continue? / 这是特权端口，继续吗？[y/N]:"
            read -r yn
            [[ "$yn" =~ ^[Yy]$ ]] || continue
        fi
        if port_in_use "$new_port"; then
            warn "Port $new_port appears to be in use by another service / 该端口可能已被其他服务占用。"
            ask "Continue anyway? / 仍然继续吗？[y/N]:"
            read -r yn
            [[ "$yn" =~ ^[Yy]$ ]] || continue
        fi
        break
    done

    # Reset per-flow change tracking so a rollback restores only this flow's
    # modifications, not prior ones in the same session.
    reset_modified_files

    # Backup the systemd socket drop-in if it already exists, so rollback can
    # restore it. socket_state lets rollback know whether to delete vs. restore.
    local backup_socket_state="none"
    if [[ -n "$SSH_SOCKET" ]]; then
        local existing_dropin="/etc/systemd/system/${SSH_SOCKET}.d/override.conf"
        if [[ -f "$existing_dropin" ]]; then
            backup_file "$existing_dropin" >/dev/null
            remember_modified "$existing_dropin"
            backup_socket_state="existed"
        else
            backup_socket_state="absent"
        fi
    fi

    # Apply
    info "Updating SSH config / 正在更新 SSH 配置 (Port $new_port) via $SSHD_TARGET..."
    set_sshd_option "Port" "$new_port"

    if [[ -n "$SSH_SOCKET" ]]; then
        info "Writing systemd socket drop-in / 正在写入 systemd socket drop-in for $SSH_SOCKET..."
        write_socket_dropin "$new_port"
    fi

    # Firewall
    local fw
    fw="$(detect_firewall)"
    if [[ -n "$fw" ]]; then
        info "Detected active firewall / 检测到启用的防火墙: $fw"
        ask "Allow new port ${new_port}/tcp through ${fw}? / 放行新端口吗？[Y/n]:"
        read -r yn
        if [[ ! "$yn" =~ ^[Nn]$ ]]; then
            firewall_open_port "$fw" "$new_port"
        fi
    else
        warn "No local firewall (ufw/firewalld) detected as active / 未检测到启用的本机防火墙。"
        warn "If your VPS uses a cloud security group, open port ${new_port}/tcp there before testing / 如果有云安全组，请先放行新端口。"
    fi

    # Restart
    info "Restarting SSH / 正在重启 SSH..."
    if ! restart_ssh; then
        err "SSH restart failed. Rolling back automatically / SSH 重启失败，正在自动回滚。"
        rollback_port "$current_port" "$backup_socket_state" "$fw" "$new_port"
        return 1
    fi

    ok "SSH is now configured to listen on port ${new_port} / SSH 已配置为监听端口 ${new_port}。"
    sleep 1
    if ! port_in_use "$new_port"; then
        warn "Port ${new_port} does not appear in 'ss -tln' output / 未在监听端口列表中看到 ${new_port}，请留意。"
    fi

    # Test prompt with rollback
    cat <<EOF

${BOLD}=== IMPORTANT / 重要：继续前请先测试 ===${NC}
Keep THIS session open. From another terminal, run:
请保持当前会话不要关闭，并在另一个终端运行：

    ssh -p ${new_port} ${TARGET_USER}@<this-server>

Did the new connection succeed? / 新连接是否成功？
  [1] Yes, keep the new port / 成功，保留新端口 (${new_port})
  [2] No, roll back to old port / 失败，回滚到旧端口 (${current_port})
  [3] Skip the test / 跳过测试（不推荐）
EOF
    while true; do
        ask "Choose / 请选择 [1/2/3]:"
        read -r choice
        case "$choice" in
            1) ok "Keeping new port ${new_port} / 保留新端口 ${new_port}。"
               # Close old port in firewall (only if changed)
               if [[ -n "$fw" ]]; then
                   ask "Remove firewall rule for OLD port ${current_port}/tcp? / 删除旧端口防火墙规则吗？[y/N]:"
                   read -r yn
                   [[ "$yn" =~ ^[Yy]$ ]] && firewall_close_port "$fw" "$current_port"
               fi
               return 0 ;;
            2) rollback_port "$current_port" "$backup_socket_state" "$fw" "$new_port"
               return 0 ;;
            3) warn "Skipping test. Make sure you can reconnect before logging out / 已跳过测试，退出前务必确认能重新连接！"
               return 0 ;;
            *) err "Invalid choice." ;;
        esac
    done
}

rollback_port() {
    local old_port="$1" socket_state="$2" fw="$3" failed_port="$4"
    warn "Rolling back to port ${old_port} / 正在回滚到端口 ${old_port}..."

    # Restore every sshd config file we touched (main + drop-ins + any
    # 00-ssh-setup.conf we created) and delete files we created from scratch.
    restore_modified_files

    # The socket drop-in is handled separately because the "absent" case
    # means we created the file ourselves during this flow.
    if [[ -n "$SSH_SOCKET" ]]; then
        local dropin="/etc/systemd/system/${SSH_SOCKET}.d/override.conf"
        if [[ "$socket_state" == "absent" ]]; then
            $SUDO rm -f "$dropin"
            $SUDO rmdir --ignore-fail-on-non-empty "/etc/systemd/system/${SSH_SOCKET}.d" 2>/dev/null || true
        fi
        $SUDO systemctl daemon-reload
    fi

    if [[ -n "$fw" && -n "$failed_port" ]]; then
        firewall_close_port "$fw" "$failed_port"
    fi

    if restart_ssh; then
        ok "Rolled back. SSH is again on port ${old_port} / 已回滚，SSH 重新使用端口 ${old_port}。"
    else
        err "Rollback restart failed. Manual intervention required."
        err "Backups are in: $BACKUP_DIR"
    fi
}

# =====================================================================
# Feature 2: password and key management
# =====================================================================
install_public_key() {
    local pubkey="$1"
    local ssh_dir="${TARGET_HOME}/.ssh"
    local auth_file="${ssh_dir}/authorized_keys"

    # Ensure ~/.ssh exists with correct perms.
    # When running as root (SUDO=""), $SUDO -u ... would expand to "-u ...",
    # so fall back to a plain mkdir and let the chown below fix ownership.
    if [[ -n "$SUDO" ]]; then
        $SUDO -u "$TARGET_USER" mkdir -p "$ssh_dir"
    else
        mkdir -p "$ssh_dir"
    fi
    $SUDO chmod 700 "$ssh_dir"
    $SUDO chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$ssh_dir"

    if [[ -f "$auth_file" ]] && $SUDO grep -qxF "$pubkey" "$auth_file"; then
        warn "This exact key is already present in $auth_file. Nothing to do / 该公钥已存在，无需重复添加。"
        return 0
    fi

    local auth_existed=0
    if $SUDO test -e "$auth_file"; then
        auth_existed=1
        backup_file "$auth_file" >/dev/null
        remember_modified "$auth_file"
    fi

    printf '%s\n' "$pubkey" | $SUDO tee -a "$auth_file" >/dev/null
    if (( auth_existed == 0 )); then
        remember_created "$auth_file"
    fi
    $SUDO chmod 600 "$auth_file"
    $SUDO chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$auth_file"
    ok "Public key appended to $auth_file / 公钥已添加到 $auth_file"
}

add_key_flow() {
    cat <<EOF

Paste the public key (single line beginning with ssh-rsa / ssh-ed25519 / ecdsa-sha2-...).
请粘贴 SSH 公钥（单行，以 ssh-rsa / ssh-ed25519 / ecdsa-sha2-... 开头）。
Press ENTER when done / 粘贴后按回车：
EOF
    local pubkey
    read -r pubkey

    # Trim whitespace
    pubkey="$(echo "$pubkey" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [[ -z "$pubkey" ]]; then
        err "Empty input. Aborting / 输入为空，已取消。"
        return 1
    fi
    if ! [[ "$pubkey" =~ ^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-[a-z0-9-]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256))[[:space:]]+[A-Za-z0-9+/=]+([[:space:]]+.*)?$ ]]; then
        err "That does not look like a valid OpenSSH public key / 这不像有效的 OpenSSH 公钥。"
        return 1
    fi

    # Use ssh-keygen to validate format if available.
    if command -v ssh-keygen >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)"
        printf '%s\n' "$pubkey" > "$tmp"
        if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
            err "ssh-keygen rejected the key as malformed / ssh-keygen 认为该公钥格式错误。"
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
    fi

    install_public_key "$pubkey"
}

enable_pubkey_auth_flow() {
    if [[ "${1:-}" != "--preserve-tracking" ]]; then
        reset_modified_files
    fi
    set_sshd_option "PubkeyAuthentication" "yes"

    if ! restart_ssh; then
        err "SSH restart failed after enabling public-key login. Rolling back."
        err "启用密钥登录后重启 SSH 失败，正在回滚。"
        restore_modified_files
        restart_ssh >/dev/null 2>&1 || err "Rollback restart failed. Manual intervention required."
        return 1
    fi

    if ! verify_sshd_option PubkeyAuthentication yes; then
        err "Public-key login is NOT effectively enabled. Rolling back."
        err "密钥登录没有真正启用，正在回滚。"
        restore_modified_files
        restart_ssh >/dev/null 2>&1 || err "Rollback restart failed. Manual intervention required."
        return 1
    fi
    ok "Public-key authentication enabled and verified / 密钥登录已启用并验证。"
}

ask_disable_password_after_key_setup() {
    cat <<EOF

Public-key login is enabled.
密钥登录已启用。

Before disabling password login, open a NEW terminal and verify that key login works.
关闭密码登录前，请打开一个新的终端，确认密钥登录可以成功。

EOF
    ask "Disable password login now? / 现在关闭密码登录吗？[y/N]:"
    local yn
    read -r yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        disable_password_auth_flow
    else
        info "Password login unchanged / 密码登录保持不变。"
    fi
}

add_key_and_enable_flow() {
    reset_modified_files
    add_key_flow || return 1
    enable_pubkey_auth_flow --preserve-tracking || return 1
    ask_disable_password_after_key_setup
}

generate_key_and_enable_flow() {
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        err "ssh-keygen is required to generate a key pair."
        err "生成密钥对需要 ssh-keygen。"
        return 1
    fi

    local host key_comment input tmp_dir key_path pubkey
    host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo vps)"
    key_comment="ssh-setup-${TARGET_USER}@${host}-$(date +%Y%m%d)"

    cat <<EOF

This will generate a new ED25519 key pair on this server, add the public key
to ${TARGET_USER}'s authorized_keys, and enable public-key login.

此操作会在本服务器生成一对新的 ED25519 密钥，把公钥加入 ${TARGET_USER} 的
authorized_keys，并启用密钥登录。

The PRIVATE key will be shown once so you can copy it to your local computer.
私钥只会显示一次，请复制保存到你的本地电脑。

EOF
    ask "Key comment / 密钥备注 [${key_comment}]:"
    read -r input
    [[ -n "$input" ]] && key_comment="$input"

    warn "The generated private key will have no passphrase unless you add one later locally."
    warn "生成的私钥默认没有密码保护；复制到本地后建议自行加密保存。"
    ask "Continue generating a key pair? / 继续生成密钥对吗？[y/N]:"
    local yn
    read -r yn
    [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted by user / 用户已取消。"; return 0; }

    tmp_dir="$(mktemp -d)"
    chmod 700 "$tmp_dir"
    key_path="${tmp_dir}/id_ed25519"

    if ! ssh-keygen -q -t ed25519 -a 100 -N "" -C "$key_comment" -f "$key_path"; then
        err "Failed to generate key pair / 生成密钥对失败。"
        rm -rf "$tmp_dir"
        return 1
    fi

    pubkey="$(cat "${key_path}.pub")"
    reset_modified_files
    install_public_key "$pubkey" || {
        rm -rf "$tmp_dir"
        return 1
    }
    enable_pubkey_auth_flow --preserve-tracking || {
        warn "Key pair is still in: $tmp_dir"
        warn "密钥文件暂时保留在：$tmp_dir"
        return 1
    }

    cat <<EOF

${BOLD}=== PRIVATE KEY / 私钥 ===${NC}
Copy everything between the BEGIN and END lines to a local file, for example:
请复制 BEGIN 到 END 之间的全部内容到本地文件，例如：

  ~/.ssh/${host}_ed25519

Then set local permissions / 然后在本地设置权限：

  chmod 600 ~/.ssh/${host}_ed25519

$(cat "$key_path")

${BOLD}=== PUBLIC KEY / 公钥 ===${NC}
$pubkey

EOF
    ask "After saving the private key locally, type SAVED to delete the server copy / 本地保存私钥后，输入 SAVED 删除服务器临时副本:"
    local confirm
    read -r confirm
    if [[ "$confirm" == "SAVED" ]]; then
        rm -rf "$tmp_dir"
        ok "Temporary private key deleted from server / 服务器上的临时私钥已删除。"
    else
        warn "Temporary key files were kept at: $tmp_dir"
        warn "临时密钥文件仍保留在：$tmp_dir"
        warn "Delete them after copying the private key / 复制私钥后请手动删除。"
    fi

    ask_disable_password_after_key_setup
}

change_password_flow() {
    cat <<EOF

This will run passwd for user: ${TARGET_USER}
即将为用户 ${TARGET_USER} 修改 SSH 登录密码。
The password is handled by the system passwd command; this script will not read or store it.
密码由系统 passwd 命令处理，脚本不会读取或保存密码。

EOF
    ask "Continue? / 继续吗？[y/N]:"
    local yn
    read -r yn
    [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted by user / 用户已取消。"; return 0; }

    if $SUDO passwd "$TARGET_USER"; then
        ok "Password changed for $TARGET_USER / 已修改 $TARGET_USER 的密码。"
    else
        err "passwd failed / passwd 执行失败。"
        return 1
    fi
}

list_authorized_key_lines() {
    local auth_file="$1"
    $SUDO awk '
        /^[[:space:]]*(ssh-|ecdsa-|sk-)/ {
            comment=""
            if (NF >= 3) {
                for (i=3; i<=NF; i++) {
                    comment = comment (i==3 ? "" : " ") $i
                }
            }
            printf "%d) %s %s\n", NR, $1, comment
        }
    ' "$auth_file"
}

remove_public_key_flow() {
    local auth_file="${TARGET_HOME}/.ssh/authorized_keys"
    if [[ ! -s "$auth_file" ]] && ! $SUDO test -s "$auth_file"; then
        err "No authorized_keys found for $TARGET_USER ($auth_file)."
        err "未找到 ${TARGET_USER} 的 authorized_keys 文件。"
        return 1
    fi

    cat <<EOF

This will restore password login first, ask you to test it from another terminal,
then remove the selected public key from:
  $auth_file

此操作会先恢复密码登录，并要求你在另一个终端测试成功后，
再从以下文件删除选中的公钥：
  $auth_file

EOF
    ask "Continue? / 继续吗？[y/N]:"
    local yn
    read -r yn
    [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted by user / 用户已取消。"; return 0; }

    restore_password_auth || return 1

    cat <<EOF

${BOLD}=== IMPORTANT / 重要：删除公钥前请先测试密码登录 ===${NC}
Keep THIS session open. From another terminal, run:
请保持当前会话不要关闭，并在另一个终端运行：

    ssh ${TARGET_USER}@<this-server>

If you changed the SSH port, add -p <port>.
如果你改过 SSH 端口，请加上 -p <端口>。

EOF
    ask "Did password login succeed? / 密码登录是否成功？[y/N]:"
    read -r yn
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        warn "Password login was not confirmed. Keeping keys unchanged."
        warn "未确认密码登录成功，公钥保持不变。"
        return 1
    fi

    local keys
    keys="$(list_authorized_key_lines "$auth_file")"
    if [[ -z "$keys" ]]; then
        err "$auth_file has no recognizable public keys."
        err "$auth_file 中没有可识别的公钥。"
        return 1
    fi

    cat <<EOF

Recognized public keys / 可识别的公钥：
$keys

EOF
    ask "Enter the line number to remove / 输入要删除的行号:"
    local line_no
    read -r line_no
    if ! [[ "$line_no" =~ ^[0-9]+$ ]]; then
        err "Line number must be an integer / 行号必须是整数。"
        return 1
    fi
    if ! $SUDO awk -v n="$line_no" 'NR==n && /^[[:space:]]*(ssh-|ecdsa-|sk-)/ {found=1} END{exit found?0:1}' "$auth_file"; then
        err "Line $line_no is not a recognizable public key line."
        err "第 $line_no 行不是可识别的公钥行。"
        return 1
    fi

    ask "Type DELETE to remove line ${line_no} / 输入 DELETE 删除第 ${line_no} 行:"
    local confirm
    read -r confirm
    if [[ "$confirm" != "DELETE" ]]; then
        info "Aborted by user / 用户已取消。"
        return 0
    fi

    backup_file "$auth_file" >/dev/null
    local tmp
    tmp="$(mktemp)"
    $SUDO awk -v n="$line_no" 'NR != n {print}' "$auth_file" > "$tmp"
    $SUDO install -m 0600 -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" "$tmp" "$auth_file"
    rm -f "$tmp"
    ok "Removed public key line ${line_no}. Password login remains enabled."
    ok "已删除第 ${line_no} 行公钥，密码登录保持启用。"
}

# =====================================================================
# Feature 3: disable password authentication
# =====================================================================
disable_password_auth_flow() {
    local auth_file="${TARGET_HOME}/.ssh/authorized_keys"

    info "Pre-flight checks before disabling password authentication / 关闭密码登录前检查..."

    # 1. authorized_keys must exist and contain at least one key
    if [[ ! -s "$auth_file" ]] && ! $SUDO test -s "$auth_file"; then
        err "No authorized_keys found for $TARGET_USER ($auth_file)."
        err "未找到 ${TARGET_USER} 的 authorized_keys。请先添加密钥，拒绝关闭密码登录。"
        return 1
    fi
    local key_count
    key_count="$($SUDO grep -cE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$auth_file" 2>/dev/null || echo 0)"
    if (( key_count < 1 )); then
        err "$auth_file has no recognizable public keys. Aborting / 没有可识别的公钥，已取消。"
        return 1
    fi
    ok "Found $key_count key(s) in $auth_file / 在 $auth_file 中找到 $key_count 个公钥。"

    # 2. Effective sshd config must allow pubkey auth
    local pubkey_auth
    pubkey_auth="$($SUDO sshd -T 2>/dev/null | awk '$1=="pubkeyauthentication"{print $2; exit}')"
    if [[ "$pubkey_auth" != "yes" ]]; then
        err "Effective PubkeyAuthentication is '$pubkey_auth' (need 'yes'). Aborting."
        err "当前有效 PubkeyAuthentication 为 '$pubkey_auth'，需要为 'yes'，已取消。"
        return 1
    fi
    ok "PubkeyAuthentication is enabled / 密钥登录已启用。"

    # 3. Confirm
    cat <<EOF

${YELLOW}You are about to disable password-based SSH login.${NC}
${YELLOW}你即将关闭 SSH 密码登录。${NC}
After this, ${BOLD}only key-based${NC} authentication will work for SSH.
之后 SSH 将只能使用密钥登录。
Make sure you have already verified that your key works.
请务必确认你的密钥已经可以登录。

EOF
    ask "Type 'YES' (uppercase) to proceed / 输入大写 YES 继续:"
    read -r confirm
    if [[ "$confirm" != "YES" ]]; then
        info "Aborted by user / 用户已取消。"
        return 0
    fi

    reset_modified_files
    set_sshd_option "PasswordAuthentication" "no"
    set_sshd_option "ChallengeResponseAuthentication" "no"
    set_sshd_option "KbdInteractiveAuthentication" "no"
    set_sshd_option "UsePAM" "yes"  # leave PAM on; the auth method flags above gate it

    if ! restart_ssh; then
        err "SSH restart failed after disabling password auth. Rolling back."
        err "关闭密码登录后重启 SSH 失败，正在回滚。"
        restore_modified_files
        restart_ssh && ok "Rolled back; password auth state unchanged." \
            || err "Rollback restart also failed. Backups are in: $BACKUP_DIR"
        return 1
    fi

    # Verify the change actually took effect — sshd_config first-match-wins
    # means a drop-in we missed could still be saying 'yes'.
    local mismatch=0
    verify_sshd_option PasswordAuthentication no || mismatch=1
    verify_sshd_option KbdInteractiveAuthentication no || mismatch=1
    if (( mismatch )); then
        err "Password authentication is NOT effectively disabled. Rolling back."
        err "密码登录没有真正关闭，正在回滚。"
        restore_modified_files
        restart_ssh && warn "Rolled back. Investigate the conflicting file and try again." \
            || err "Rollback restart failed. Backups are in: $BACKUP_DIR"
        return 1
    fi
    ok "Password authentication disabled and verified. SSH restarted / 密码登录已关闭并验证，SSH 已重启。"
}

# =====================================================================
# Menu
# =====================================================================
password_key_menu() {
    while true; do
        cat <<EOF

${BOLD}=== Password & key management / 密码与密钥管理 ===${NC}
  1) Change SSH login password / 修改 SSH 登录密码
  2) Generate key pair and enable key login / 生成密钥并启用密钥登录
  3) Add public key and enable key login / 添加公钥并启用密钥登录
  4) Remove public key and restore password login / 删除公钥并恢复密码登录
  5) Disable password login (key required) / 关闭密码登录（必须先设置好密钥）
  b) Back / 返回
EOF
        ask "Choose / 请选择:"
        local c
        read -r c
        case "$c" in
            1) change_password_flow ;;
            2) generate_key_and_enable_flow ;;
            3) add_key_and_enable_flow ;;
            4) remove_public_key_flow ;;
            5) disable_password_auth_flow ;;
            b|B) return 0 ;;
            *) err "Invalid choice / 无效选项。" ;;
        esac
    done
}

main_menu() {
    while true; do
        cat <<EOF

${BOLD}=== SSH setup menu / SSH 设置菜单 ===${NC}
  1) Change SSH port / 修改 SSH 端口
  2) Password & key management / 密码与密钥管理
  q) Quit / 退出
EOF
        ask "Choose / 请选择:"
        read -r c
        case "$c" in
            1) change_port_flow ;;
            2) password_key_menu ;;
            q|Q) info "Bye / 再见。"; exit 0 ;;
            *) err "Invalid choice / 无效选项。" ;;
        esac
    done
}

# ---------- entry ----------
main() {
    handle_cli_args "$@"

    info "Interactive SSH setup for Debian/Ubuntu / Debian/Ubuntu 交互式 SSH 设置"
    if [[ ! -f "$SSHD_CONFIG" ]]; then
        err "$SSHD_CONFIG not found. Is OpenSSH server installed?"
        exit 1
    fi
    detect_ssh_units
    detect_sshd_target
    detect_target_user
    init_backup_dir
    main_menu
}

main "$@"
