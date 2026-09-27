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
# Port changes are protected by an independent systemd rollback timer.
# Only a confirmed connection cancels the rollback.

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
init_privileges() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
            info "Not running as root, will use sudo for privileged commands."
        else
            err "This script needs root privileges (or sudo installed)."
            exit 1
        fi
    fi
}

# ---------- stdin ----------
# When run as `curl ... | bash`, stdin is the script pipe and every read
# would hit EOF, leaving the menu loops spinning. Reattach to the terminal
# when possible.
ensure_tty_stdin() {
    [[ -t 0 ]] && return 0
    if (exec </dev/tty) 2>/dev/null; then
        exec </dev/tty
        return 0
    fi
    return 1
}

# ---------- globals filled in by detect_* ----------
SSH_SERVICE=""        # e.g. ssh.service or sshd.service
SSH_SOCKET=""         # e.g. ssh.socket if socket activation is in use, else empty
SSH_SERVICE_MANAGER="systemctl"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR_CFG="/etc/ssh/sshd_config.d"
SSHD_TARGET=""        # main config; managed global settings are prepended
SSHD_INCLUDE_BASE="/etc/ssh"
SSHD_CONFIG_FILES=()
SYSTEMD_CONFIG_DIR="/etc/systemd/system"
TARGET_USER=""        # whose authorized_keys we'll write to
TARGET_HOME=""
INSTALL_PATH="/usr/local/bin/ssh-setup"
INSTALL_SOURCE_URL="https://raw.githubusercontent.com/ssaishou/vps-ssh-setup/main/ssh-setup.sh"

# Files modified / created in the current flow, used for rollback.
MODIFIED_FILES=()
CREATED_FILES=()
FIREWALL_ADDED=()
TRACKING_FILE=""
PORT_RUNNER=""
PORT_TIMER_UNIT=""
PORT_TIMEOUT=180
PORT_NEW=""
PORT_OLD=""
PORT_FIREWALL=""
FIREWALL_ZONE=""
SOCKET_LISTEN_LINES=""

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
        tmp="$(mktemp)" || return 1
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
            read -r yn || return 1
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
    read -r yn || return 1
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        info "Aborted by user / 用户已取消。"
        return 0
    fi

    $SUDO rm -f "$INSTALL_PATH" || return 1
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
    if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]]; then
        err "Port must be a decimal integer without leading zeroes / 端口须为无前导零的十进制整数。"
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

# ---------- checked file writes and rollback journal ----------
BACKUP_DIR=""
FLOW_SEQ=0
init_backup_dir() {
    BACKUP_DIR="$($SUDO mktemp -d /var/backups/ssh-setup-XXXXXXXX)" || return 1
    $SUDO chmod 700 "$BACKUP_DIR" || return 1
    info "Backups / 备份目录: $BACKUP_DIR"
}

current_flow_dir() {
    printf '%s/flow-%s\n' "$BACKUP_DIR" "$FLOW_SEQ"
}

# Stage beside the destination so a failed write cannot truncate a live file.
atomic_install() {
    local src="$1" dst="$2" mode="$3" owner="$4" group="$5" staged
    if $SUDO test -L "$dst"; then
        err "Refusing to replace a symlink / 拒绝覆盖符号链接: $dst"
        return 1
    fi
    staged="$($SUDO mktemp "${dst}.ssh-setup.XXXXXX")" || return 1
    if ! $SUDO install -m "$mode" -o "$owner" -g "$group" "$src" "$staged" ||
       ! $SUDO mv -f "$staged" "$dst"; then
        $SUDO rm -f "$staged"
        err "Failed to write / 写入失败: $dst"
        return 1
    fi
}

persist_tracking() {
    [[ -n "$TRACKING_FILE" ]] || return 0
    local tmp
    tmp="$(mktemp)" || return 1
    if ! declare -p MODIFIED_FILES CREATED_FILES FIREWALL_ADDED FIREWALL_ZONE > "$tmp" ||
       ! atomic_install "$tmp" "$TRACKING_FILE" 0600 root root; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

backup_file() {
    local src="$1" dest
    [[ "$src" == /* ]] || return 1
    $SUDO test -f "$src" || { err "Cannot back up / 无法备份: $src"; return 1; }
    dest="$(current_flow_dir)/files${src}"
    $SUDO mkdir -p "${dest%/*}" || return 1
    $SUDO cp -a "$src" "$dest" || { err "Backup failed / 备份失败: $src"; return 1; }
    printf '%s\n' "$dest"
}

reset_modified_files() {
    MODIFIED_FILES=()
    CREATED_FILES=()
    FIREWALL_ADDED=()
    FLOW_SEQ=$((FLOW_SEQ + 1))
}

is_created() {
    local f="$1" existing
    for existing in "${CREATED_FILES[@]+"${CREATED_FILES[@]}"}"; do
        [[ "$existing" == "$f" ]] && return 0
    done
    return 1
}

track_modified() {
    local f="$1" existing
    is_created "$f" && return 0
    for existing in "${MODIFIED_FILES[@]+"${MODIFIED_FILES[@]}"}"; do
        [[ "$existing" == "$f" ]] && return 0
    done
    backup_file "$f" >/dev/null || return 1
    MODIFIED_FILES+=("$f")
    persist_tracking
}

remember_created() {
    is_created "$1" && return 0
    CREATED_FILES+=("$1")
    persist_tracking
}

prepare_file_change() {
    if $SUDO test -e "$1"; then
        track_modified "$1"
    else
        # Journal before writing: partial creation also needs to be undone.
        remember_created "$1"
    fi
}

restore_modified_files() {
    local f backup_path tmp failed=0
    for f in "${MODIFIED_FILES[@]+"${MODIFIED_FILES[@]}"}"; do
        backup_path="$(current_flow_dir)/files${f}"
        if ! $SUDO test -f "$backup_path"; then
            err "Missing backup / 备份缺失: $backup_path"
            failed=1
            continue
        fi
        tmp="$($SUDO mktemp "${f}.restore.XXXXXX")" || { failed=1; continue; }
        if $SUDO cp -a "$backup_path" "$tmp" && $SUDO mv -f "$tmp" "$f"; then
            ok "Restored / 已恢复: $f"
        else
            $SUDO rm -f "$tmp"
            err "Restore failed / 恢复失败: $f"
            failed=1
        fi
    done
    for f in "${CREATED_FILES[@]+"${CREATED_FILES[@]}"}"; do
        if $SUDO rm -f "$f"; then
            ok "Removed / 已删除: $f"
        else
            failed=1
        fi
    done
    return "$failed"
}

# ---------- sshd configuration discovery ----------
detect_sshd_target() {
    # Prefix the main file: first global value wins, before any Include/Match.
    SSHD_TARGET="$SSHD_CONFIG"
    info "Managed global settings / 全局配置写入: $SSHD_TARGET"
}

# Tokenize without eval; reject ambiguous syntax instead of skipping a file.
config_entries() {
    # shellcheck disable=SC2016
    $SUDO awk '
        function emit(s,    i,c,q,escape,n,token,a) {
            n=0; token=""; q=""; escape=0
            for (i=1;i<=length(s);i++) {
                c=substr(s,i,1)
                if (escape) { token=token c; escape=0; continue }
                if (c=="\\") { escape=1; continue }
                if (q!="") {
                    if (c==q) q=""; else token=token c
                    continue
                }
                if (c=="\"" || c==sprintf("%c",39)) { q=c; continue }
                if (c=="#" && token=="") break
                if (c ~ /[ \t]/ || (c=="=" && n==0)) {
                    if (token!="") { a[++n]=token; token="" }
                } else token=token c
            }
            if (q!="" || escape) { bad=1; return }
            if (token!="") a[++n]=token
            if (!n) return
            a[1]=tolower(a[1])
            if (a[1]=="include") {
                for (i=2;i<=n;i++) {
                    if (a[i] ~ /[\t\r\n]/) { bad=1; return }
                    print "include\t" a[i]
                }
            } else if (a[1]=="match") print "match\t1"
            else {
                if (a[1]=="challengeresponseauthentication")
                    a[1]="kbdinteractiveauthentication"
                print "option\t" a[1] "\t" tolower(a[2])
            }
        }
        { emit($0) }
        END { if (bad) exit 2 }
    ' "$1"
}

# Conservatively carry conditional scope across Includes.
SCAN_IN_MATCH=0
SCAN_KEY=""
SCAN_VALUE=""
scan_config_file() {
    local file="$1" depth="$2" entries type name value pattern matches child
    (( depth < 32 )) || { err "Include recursion is too deep / Include 嵌套过深。"; return 1; }
    $SUDO test -f "$file" || return 1
    entries="$(config_entries "$file")" || { err "Cannot parse / 无法解析: $file"; return 1; }
    SSHD_CONFIG_FILES+=("$file")
    while IFS=$'\t' read -r type name value; do
        case "$type" in
            match) SCAN_IN_MATCH=1 ;;
            option)
                if (( SCAN_IN_MATCH )) && [[ "$name" == "$SCAN_KEY" && "$value" != "$SCAN_VALUE" ]]; then
                    err "Conflicting Match option / Match 条件配置冲突: $file ($name $value)"
                    err "Resolve this exception first / 请先处理该例外，再修改认证方式。"
                    return 1
                fi
                ;;
            include)
                pattern="$name"
                [[ "$pattern" == /* ]] || pattern="$SSHD_INCLUDE_BASE/$pattern"
                matches="$($SUDO bash -c 'compgen -G "$1" || test "$?" -eq 1' _ "$pattern")" || return 1
                matches="$(printf '%s\n' "$matches" | LC_ALL=C sort)" || return 1
                while IFS= read -r child; do
                    [[ -n "$child" ]] || continue
                    scan_config_file "$child" "$((depth + 1))" || return 1
                done <<< "$matches"
                ;;
        esac
    done <<< "$entries"
}

scan_sshd_config() {
    SSHD_CONFIG_FILES=()
    SCAN_IN_MATCH=0
    SCAN_KEY="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    [[ "$SCAN_KEY" != challengeresponseauthentication ]] || SCAN_KEY=kbdinteractiveauthentication
    SCAN_VALUE="${2:-}"
    scan_config_file "$SSHD_CONFIG" 0
}

# ---------- firewall ----------
detect_firewall() {
    local output
    if command -v ufw >/dev/null 2>&1; then
        output="$(LC_ALL=C $SUDO ufw status)" || return 1
        if [[ "$output" == *"Status: active"* ]]; then
            printf 'ufw\n'
            return 0
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        output="$($SUDO firewall-cmd --state 2>/dev/null)" || output=""
        [[ "$output" != running ]] || { printf 'firewalld\n'; return 0; }
    fi
}

firewall_open_port() {
    local fw="$1" port="$2" family address output result ipv6=0 kind status
    case "$fw" in
        ufw)
            # Run families separately: an existing IPv4 rule must survive
            # rollback even if this operation adds a new IPv6 rule.
            if $SUDO grep -qiE '^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*yes' /etc/default/ufw; then
                ipv6=1
            fi
            for family in 4 6; do
                [[ "$family" != 6 || "$ipv6" == 1 ]] || continue
                if [[ "$family" == 4 ]]; then address=0.0.0.0/0; else address=::/0; fi
                result=0
                output="$(LC_ALL=C $SUDO ufw allow proto tcp from "$address" to any port "$port" 2>&1)" || result=$?
                if [[ "$output" == *"Rule added"* || "$output" == *"Rules updated"* ]]; then
                    FIREWALL_ADDED+=("ufw$family")
                    persist_tracking || return 1
                elif [[ "$output" != *"Skipping adding existing rule"* ]]; then
                    err "Could not confirm firewall update / 无法确认防火墙更新: $output"
                    return 1
                fi
                (( result == 0 )) || { err "$output"; return 1; }
            done
            ;;
        firewalld)
            FIREWALL_ZONE="$($SUDO firewall-cmd --get-default-zone)" || return 1
            for kind in runtime permanent; do
                local flags=("--zone=$FIREWALL_ZONE")
                [[ "$kind" != permanent ]] || flags+=(--permanent)
                status=0
                $SUDO firewall-cmd "${flags[@]}" --query-port="${port}/tcp" >/dev/null || status=$?
                if (( status == 0 )); then continue; fi
                (( status == 1 )) || return 1
                # The queried rule was absent; journal intent before adding.
                FIREWALL_ADDED+=("firewalld-$kind")
                persist_tracking || return 1
                $SUDO firewall-cmd "${flags[@]}" --add-port="${port}/tcp" >/dev/null || return 1
            done
            ;;
        "") return 0 ;;
        *) return 1 ;;
    esac
    ok "Firewall ready for ${port}/tcp / 防火墙已准备好新端口。"
}

rollback_firewall() {
    local port="$1" kind address failed=0
    for kind in "${FIREWALL_ADDED[@]+"${FIREWALL_ADDED[@]}"}"; do
        case "$kind" in
            ufw4|ufw6)
                if [[ "$kind" == ufw4 ]]; then address=0.0.0.0/0; else address=::/0; fi
                $SUDO ufw --force delete allow proto tcp from "$address" to any port "$port" >/dev/null || failed=1
                ;;
            firewalld-runtime)
                $SUDO firewall-cmd "--zone=$FIREWALL_ZONE" --remove-port="${port}/tcp" >/dev/null || failed=1 ;;
            firewalld-permanent)
                $SUDO firewall-cmd "--zone=$FIREWALL_ZONE" --permanent --remove-port="${port}/tcp" >/dev/null || failed=1 ;;
        esac
    done
    return "$failed"
}

firewall_close_port() {
    local fw="$1" port="$2" zone
    case "$fw" in
        ufw) $SUDO ufw delete allow "${port}/tcp" ;;
        firewalld)
            zone="$($SUDO firewall-cmd --get-default-zone)" || return 1
            $SUDO firewall-cmd "--zone=$zone" --remove-port="${port}/tcp" &&
                $SUDO firewall-cmd "--zone=$zone" --permanent --remove-port="${port}/tcp"
            ;;
    esac
}

# ---------- sshd_config edit ----------
set_sshd_option() {
    local key="$1" value="$2" f tmp files
    scan_sshd_config "$key" "$value" || return 1
    files="$(printf '%s\n' "${SSHD_CONFIG_FILES[@]}" | LC_ALL=C sort -u)" || return 1
    while IFS= read -r f; do
        # Port is additive across Includes; other global settings use the
        # first value, so only the main file needs to change for them.
        [[ "$key" == Port || "$f" == "$SSHD_TARGET" ]] || continue
        tmp="$(mktemp)" || return 1
        # shellcheck disable=SC2016
        if ! $SUDO awk -v k="$key" -v v="$value" -v target="$SSHD_TARGET" '
            BEGIN { k=tolower(k); in_match=0; wrote=0 }
            FNR==1 { if (FILENAME==target) { print k " " v; wrote=1 } }
            {
                line=$0; sub(/^[ \t]+/,"",line)
                split(line,a,/[ \t=]+/)
                option=tolower(a[1])
                if (option=="match") in_match=1
                if (option=="challengeresponseauthentication") option="kbdinteractiveauthentication"
                normalized=k
                if (normalized=="challengeresponseauthentication") normalized="kbdinteractiveauthentication"
                if (!in_match && option==normalized) next
                print
            }
            END { if (!wrote && FILENAME==target) print k " " v }
        ' "$f" > "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        if $SUDO cmp -s "$tmp" "$f"; then
            rm -f "$tmp"
            continue
        fi
        if ! prepare_file_change "$f" || ! atomic_install "$tmp" "$f" 0644 root root; then
            rm -f "$tmp"
            return 1
        fi
        rm -f "$tmp"
    done <<< "$files"
}

connection_spec() {
    local addr=127.0.0.1 _remote_port=0 laddr=127.0.0.1 lport=22 extra=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r addr _remote_port laddr lport extra <<< "$SSH_CONNECTION"
        [[ -n "$addr" && -n "$laddr" && "$lport" =~ ^[0-9]+$ && -z "$extra" ]] || return 1
    fi
    printf 'user=%s,host=%s,addr=%s,laddr=%s,lport=%s\n' "$TARGET_USER" "$addr" "$addr" "$laddr" "$lport"
}

effective_sshd_config() {
    if [[ "${1:-}" == connection ]]; then
        local spec
        spec="$(connection_spec)" || return 1
        $SUDO sshd -T -f "$SSHD_CONFIG" -C "$spec"
    else
        $SUDO sshd -T -f "$SSHD_CONFIG"
    fi
}

verify_sshd_option() {
    local key="$1" expected="$2" lc_key config actual scope
    lc_key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    [[ "$lc_key" != challengeresponseauthentication ]] || lc_key=kbdinteractiveauthentication
    for scope in global connection; do
        config="$(effective_sshd_config "$scope")" || return 1
        actual="$(awk -v k="$lc_key" '$1==k {print $2}' <<< "$config")"
        if [[ "$actual" != "$expected" ]]; then
            err "Effective $key ($scope) is '$actual', expected '$expected' / 实际配置不符合预期。"
            return 1
        fi
    done
}

rollback_config_flow() {
    err "Operation failed; restoring backups / 操作失败，正在恢复备份。"
    [[ -n "${MODIFIED_FILES[*]:-}${CREATED_FILES[*]:-}" ]] || return 1
    if restore_modified_files && restart_ssh; then
        warn "Previous configuration restored / 已恢复原配置。"
    else
        err "Recovery failed; backups / 恢复失败，备份位于: $BACKUP_DIR"
    fi
    return 1
}

apply_auth_options() {
    local pairs=("$@") key value i
    # Check every conditional exception before making any changes.
    for ((i=0; i<${#pairs[@]}; i+=2)); do
        scan_sshd_config "${pairs[i]}" "${pairs[i+1]}" || { rollback_config_flow; return 1; }
    done
    for ((i=0; i<${#pairs[@]}; i+=2)); do
        key="${pairs[i]}" value="${pairs[i+1]}"
        set_sshd_option "$key" "$value" || { rollback_config_flow; return 1; }
    done
    $SUDO sshd -t -f "$SSHD_CONFIG" || { rollback_config_flow; return 1; }
    for ((i=0; i<${#pairs[@]}; i+=2)); do
        verify_sshd_option "${pairs[i]}" "${pairs[i+1]}" || { rollback_config_flow; return 1; }
    done
    restart_ssh || { rollback_config_flow; return 1; }
}

# ---------- socket drop-in ----------
SOCKET_DROPIN_DIR=""
SOCKET_DROPIN_FILE=""
socket_listen_lines() {
    local port="$1" output address type rest
    output="$($SUDO systemctl show "$SSH_SOCKET" --property=Listen --value)" || return 1
    [[ -n "$output" ]] || return 1
    while [[ -n "$output" ]]; do
        read -r address type rest <<< "$output"
        [[ "$type" == "(Stream)" ]] || { err "Unsupported SSH socket listener / 不支持的 socket 监听配置。"; return 1; }
        case "$address" in
            \[*\]:[0-9]*|[0-9]*.[0-9]*.[0-9]*.[0-9]*:[0-9]*)
                printf 'ListenStream=%s:%s\n' "${address%:*}" "$port" ;;
            *)
                err "Cannot safely preserve socket address / 无法安全保留监听地址: $address"
                return 1 ;;
        esac
        output="$rest"
    done
}

write_socket_dropin() {
    local tmp
    SOCKET_DROPIN_DIR="$SYSTEMD_CONFIG_DIR/${SSH_SOCKET}.d"
    # Never overwrite an administrator's override.conf.
    SOCKET_DROPIN_FILE="$SOCKET_DROPIN_DIR/zzzz-ssh-setup-port.conf"
    $SUDO mkdir -p "$SOCKET_DROPIN_DIR" || return 1
    tmp="$(mktemp)" || return 1
    if ! printf '[Socket]\nListenStream=\n%s\n' "$SOCKET_LISTEN_LINES" > "$tmp" ||
       ! prepare_file_change "$SOCKET_DROPIN_FILE" ||
       ! atomic_install "$tmp" "$SOCKET_DROPIN_FILE" 0644 root root; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    $SUDO systemctl daemon-reload
}

# ---------- restart logic ----------
restart_ssh() {
    # Validate config before touching any running service or socket.
    if ! $SUDO sshd -t -f "$SSHD_CONFIG"; then
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
    apply_auth_options PasswordAuthentication yes KbdInteractiveAuthentication yes UsePAM yes || return 1
    if [[ "$TARGET_USER" == root ]]; then
        if ! verify_sshd_option PermitRootLogin yes; then
            err "Root password login is restricted by PermitRootLogin / root 密码登录仍受 PermitRootLogin 限制。"
            rollback_config_flow
            return 1
        fi
    fi
    ok "Password login restored and verified / 密码登录已恢复并验证。"
}

# =====================================================================
# Feature 1: guarded SSH port transaction
# =====================================================================
verify_port_listener() {
    local output listeners
    if [[ -n "$SSH_SOCKET" ]]; then
        listeners="$(socket_listen_lines "$PORT_NEW" | LC_ALL=C sort -u)" || return 1
        [[ "$listeners" == "$SOCKET_LISTEN_LINES" ]] || return 1
        output="$($SUDO systemctl show "$SSH_SOCKET" --property=Listen --value)" || return 1
        # The queried active socket must use the new port on every address.
        local address type rest
        while [[ -n "$output" ]]; do
            read -r address type rest <<< "$output"
            [[ "$type" == "(Stream)" && "${address##*:}" == "$PORT_NEW" ]] || return 1
            output="$rest"
        done
    fi
    output="$($SUDO ss -H -tlnp)" || return 1
    awk -v p="$PORT_NEW" '
        $4 ~ (":" p "$") && ($0 ~ /"sshd"/ || $0 ~ /"systemd"/) {found=1}
        END {exit !found}
    ' <<< "$output"
}

apply_port_changes() {
    set_sshd_option Port "$PORT_NEW" || return 1
    if [[ -n "$SSH_SOCKET" ]]; then
        write_socket_dropin || return 1
    fi
    firewall_open_port "$PORT_FIREWALL" "$PORT_NEW" || return 1
    verify_sshd_option Port "$PORT_NEW" || return 1
    restart_ssh || return 1
    verify_port_listener || { err "New SSH listener not verified / 未能验证新的 SSH 监听端口。"; return 1; }
}

rollback_port() {
    local failed=0 config_failed=0
    warn "Restoring SSH port $PORT_OLD / 正在恢复 SSH 端口 $PORT_OLD..."
    restore_modified_files || config_failed=1
    if [[ -n "$SSH_SOCKET" ]]; then
        $SUDO systemctl daemon-reload || config_failed=1
    fi
    rollback_firewall "$PORT_NEW" || failed=1
    # Do not restart using partially restored configuration.
    if (( config_failed == 0 )); then
        restart_ssh || failed=1
    else
        failed=1
    fi
    if (( failed )); then
        err "Rollback incomplete; backups / 回滚未完成，备份位于: $BACKUP_DIR"
        return 1
    fi
    ok "Previous SSH configuration restored / 已恢复原 SSH 配置。"
}

write_port_status() {
    local tmp
    tmp="$(mktemp)" || return 1
    if ! printf '%s\n' "$1" > "$tmp" ||
       ! atomic_install "$tmp" "${PORT_RUNNER}.status" 0600 root root; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

port_transaction() (
    # A separate root process holds this lock for mutations only. The timer
    # can restore while the interactive parent waits, even after SIGKILL/HUP.
    exec 9>"${PORT_RUNNER}.lock" || exit 1
    flock -x 9 || exit 1
    local state
    state="$(cat "${PORT_RUNNER}.status")" || exit 1
    if [[ -f "$TRACKING_FILE" ]]; then
        # Root-owned state generated solely with declare -p.
        # shellcheck disable=SC1090
        source "$TRACKING_FILE" || exit 1
    fi
    case "$1" in
        apply)
            [[ "$state" == pending ]] || exit 1
            if ! apply_port_changes; then
                if rollback_port; then write_port_status rolled-back; fi
                exit 1
            fi
            ;;
        commit)
            [[ "$state" == pending ]] || {
                err "Port was already rolled back / 端口已回滚，不能确认保留。"
                exit 1
            }
            verify_port_listener || exit 1
            write_port_status committed || exit 1
            ;;
        rollback)
            [[ "$state" == pending ]] || exit 0
            rollback_port && write_port_status rolled-back
            ;;
        *) exit 1 ;;
    esac
)

arm_port_rollback() {
    local dir tmp function_name
    command -v systemd-run >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || {
        err "Port changes require systemd-run and flock for automatic recovery / 改端口需要 systemd-run 和 flock 提供自动恢复。"
        return 1
    }
    dir="$(current_flow_dir)"
    $SUDO mkdir -p "$dir" || return 1
    PORT_RUNNER="$dir/port-transaction.sh"
    PORT_TIMER_UNIT="ssh-setup-rollback-$$-$FLOW_SEQ"
    TRACKING_FILE="$dir/tracking.sh"
    tmp="$(mktemp)" || return 1
    {
        printf '#!/bin/bash\nset -uo pipefail\nPATH=/usr/sbin:/usr/bin:/sbin:/bin\nexport PATH\n'
        declare -p RED GREEN YELLOW BLUE BOLD NC BACKUP_DIR FLOW_SEQ \
            SSH_SERVICE SSH_SOCKET SSH_SERVICE_MANAGER SSHD_CONFIG SSHD_TARGET \
            SSHD_DROPIN_DIR_CFG SSHD_INCLUDE_BASE SSHD_CONFIG_FILES SYSTEMD_CONFIG_DIR \
            SCAN_IN_MATCH SCAN_KEY SCAN_VALUE SOCKET_LISTEN_LINES \
            MODIFIED_FILES CREATED_FILES FIREWALL_ADDED FIREWALL_ZONE \
            PORT_NEW PORT_OLD PORT_FIREWALL PORT_RUNNER TRACKING_FILE
        printf 'SUDO=""\nSSH_CONNECTION=%q\n' "${SSH_CONNECTION:-}"
        for function_name in info ok warn err atomic_install persist_tracking \
            current_flow_dir backup_file is_created track_modified remember_created \
            prepare_file_change restore_modified_files config_entries scan_config_file \
            scan_sshd_config set_sshd_option connection_spec effective_sshd_config \
            verify_sshd_option socket_listen_lines write_socket_dropin restart_ssh \
            firewall_open_port rollback_firewall verify_port_listener apply_port_changes \
            rollback_port write_port_status port_transaction; do
            declare -f "$function_name" || exit 1
        done
        printf 'port_transaction "$@"\n'
    } > "$tmp"
    local result=$?
    if (( result != 0 )) || ! atomic_install "$tmp" "$PORT_RUNNER" 0700 root root ||
       ! write_port_status pending; then
        rm -f "$tmp"
        PORT_RUNNER=""
        TRACKING_FILE=""
        return 1
    fi
    rm -f "$tmp"
    if ! $SUDO systemd-run --quiet --collect --unit="$PORT_TIMER_UNIT" \
        --on-active="${PORT_TIMEOUT}s" --timer-property=AccuracySec=1s \
        /bin/bash "$PORT_RUNNER" rollback; then
        PORT_RUNNER=""
        TRACKING_FILE=""
        err "Recovery timer could not start; no SSH changes made / 无法启动恢复定时器，未修改 SSH。"
        return 1
    fi
    info "Automatic rollback in $PORT_TIMEOUT seconds / $PORT_TIMEOUT 秒后将自动回滚，确认连接成功后取消。"
}

finish_port_transaction() {
    local action="$1"
    [[ -n "$PORT_RUNNER" ]] || return 0
    if ! $SUDO /bin/bash "$PORT_RUNNER" "$action"; then
        err "Recovery remains armed / 恢复定时器仍然保留。"
        return 1
    fi
    # A timer racing with confirmation sees committed under the same lock.
    $SUDO systemctl stop "${PORT_TIMER_UNIT}.timer" >/dev/null 2>&1 ||
        warn "Could not stop timer; completed state prevents further changes / 未停止定时器，但完成状态会阻止重复修改。"
    PORT_RUNNER=""
    TRACKING_FILE=""
}

port_exit_cleanup() {
    if [[ -n "$PORT_RUNNER" ]]; then
        finish_port_transaction rollback || true
    fi
}

change_port_flow() {
    local yn choice fw
    PORT_OLD="$(get_current_port)"
    info "Current SSH port / 当前 SSH 端口: $PORT_OLD"
    while true; do
        ask "New SSH port / 新 SSH 端口 (1-65535):"
        read -r PORT_NEW || return 1
        validate_port "$PORT_NEW" || continue
        [[ "$PORT_NEW" != "$PORT_OLD" ]] || { warn "Port unchanged / 端口未改变。"; continue; }
        if port_in_use "$PORT_NEW"; then
            warn "Port already in use; choose another / 端口已占用，请选择其他端口。"
            continue
        fi
        break
    done

    $SUDO sshd -t -f "$SSHD_CONFIG" || return 1
    scan_sshd_config Port "$PORT_NEW" || return 1
    SOCKET_LISTEN_LINES=""
    if [[ -n "$SSH_SOCKET" ]]; then
        SOCKET_LISTEN_LINES="$(socket_listen_lines "$PORT_NEW" | LC_ALL=C sort -u)" || return 1
        [[ -n "$SOCKET_LISTEN_LINES" ]] || return 1
    fi
    fw="$(detect_firewall)" || return 1
    PORT_FIREWALL=""
    if [[ -n "$fw" ]]; then
        ask "Allow ${PORT_NEW}/tcp through $fw? / 在 $fw 放行新端口吗？[Y/n]:"
        read -r yn || return 1
        [[ "$yn" =~ ^[Nn]$ ]] || PORT_FIREWALL="$fw"
    fi
    warn "Open ${PORT_NEW}/tcp in cloud security groups before continuing / 请先在云安全组放行新端口。"
    ask "Apply with automatic rollback? / 应用修改并启用自动回滚？[y/N]:"
    read -r yn || return 1
    [[ "$yn" =~ ^[Yy]$ ]] || return 0

    reset_modified_files
    arm_port_rollback || return 1
    if ! $SUDO /bin/bash "$PORT_RUNNER" apply; then
        finish_port_transaction rollback
        return 1
    fi
    cat <<EOF

Keep this session open and test from another terminal / 保持当前会话，在另一个终端测试：
    ssh -p $PORT_NEW $TARGET_USER@<this-server>

[1] Connection succeeded: keep port / 新连接成功，保留端口
[2] Restore previous port / 恢复旧端口
No confirmation within $PORT_TIMEOUT seconds means rollback / 未在 $PORT_TIMEOUT 秒内确认将自动回滚。
EOF
    ask "Choose / 请选择 [1/2]:"
    if ! read -r -t "$PORT_TIMEOUT" choice || [[ "$choice" != 1 ]]; then
        finish_port_transaction rollback
        return 1
    fi
    finish_port_transaction commit || return 1
    ok "Confirmed SSH port $PORT_NEW / 已确认 SSH 新端口 $PORT_NEW。"
    if [[ -n "$fw" ]]; then
        ask "Remove old ${PORT_OLD}/tcp firewall rule? / 删除旧端口防火墙规则吗？[y/N]:"
        read -r yn || return 0
        if [[ "$yn" =~ ^[Yy]$ ]]; then
            firewall_close_port "$fw" "$PORT_OLD" || return 1
        fi
    fi
}

# =====================================================================
# Feature 2: password and key management
# =====================================================================
install_public_key() {
    local pubkey="$1" ssh_dir="${TARGET_HOME}/.ssh" auth_file="${TARGET_HOME}/.ssh/authorized_keys"
    local tmp group
    group="$(id -gn "$TARGET_USER")" || return 1
    $SUDO mkdir -p "$ssh_dir" || return 1
    $SUDO chmod 700 "$ssh_dir" || return 1
    $SUDO chown "$TARGET_USER:$group" "$ssh_dir" || return 1
    if $SUDO test -f "$auth_file" && $SUDO grep -qxF "$pubkey" "$auth_file"; then
        ok "Public key already present / 公钥已存在。"
        return 0
    fi
    tmp="$(mktemp)" || return 1
    if $SUDO test -e "$auth_file"; then
        if ! $SUDO cat "$auth_file" > "$tmp"; then rm -f "$tmp"; return 1; fi
    fi
    # A missing trailing newline in the old file must not join two key lines.
    if ! printf '\n%s\n' "$pubkey" >> "$tmp" ||
       ! prepare_file_change "$auth_file" ||
       ! atomic_install "$tmp" "$auth_file" 0600 "$TARGET_USER" "$group"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    ok "Public key installed / 公钥已写入: $auth_file"
}

add_key_flow() {
    cat <<EOF

Paste the public key (single line beginning with ssh-rsa / ssh-ed25519 / ecdsa-sha2-... / sk-...).
请粘贴 SSH 公钥（单行，以 ssh-rsa / ssh-ed25519 / ecdsa-sha2-... / sk-... 开头）。
Press ENTER when done / 粘贴后按回车：
EOF
    local pubkey
    read -r pubkey || return 1

    # Trim whitespace
    pubkey="$(echo "$pubkey" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [[ -z "$pubkey" ]]; then
        err "Empty input. Aborting / 输入为空，已取消。"
        return 1
    fi
    if ! [[ "$pubkey" =~ ^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-[a-z0-9-]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]]+.*)?$ ]]; then
        err "That does not look like a valid OpenSSH public key / 这不像有效的 OpenSSH 公钥。"
        return 1
    fi

    # Use ssh-keygen to validate format if available.
    if command -v ssh-keygen >/dev/null 2>&1; then
        local tmp
        tmp="$(mktemp)" || return 1
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
    apply_auth_options PubkeyAuthentication yes || return 1
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
    read -r yn || return 1
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        disable_password_auth_flow
    else
        info "Password login unchanged / 密码登录保持不变。"
    fi
}

add_key_and_enable_flow() {
    reset_modified_files
    add_key_flow || { rollback_config_flow; return 1; }
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
    read -r input || return 1
    [[ -n "$input" ]] && key_comment="$input"

    warn "The generated private key will have no passphrase unless you add one later locally."
    warn "生成的私钥默认没有密码保护；复制到本地后建议自行加密保存。"
    ask "Continue generating a key pair? / 继续生成密钥对吗？[y/N]:"
    local yn
    read -r yn || return 1
    [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted by user / 用户已取消。"; return 0; }

    tmp_dir="$(mktemp -d)" || return 1
    chmod 700 "$tmp_dir" || { rm -rf "$tmp_dir"; return 1; }
    key_path="${tmp_dir}/id_ed25519"

    if ! ssh-keygen -q -t ed25519 -a 100 -N "" -C "$key_comment" -f "$key_path"; then
        err "Failed to generate key pair / 生成密钥对失败。"
        rm -rf "$tmp_dir"
        return 1
    fi

    pubkey="$(cat "${key_path}.pub")" || { rm -rf "$tmp_dir"; return 1; }
    reset_modified_files
    install_public_key "$pubkey" || {
        rollback_config_flow
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
    read -r confirm || return 1
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
    read -r yn || return 1
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
    read -r yn || return 1
    [[ "$yn" =~ ^[Yy]$ ]] || { info "Aborted by user / 用户已取消。"; return 0; }

    restore_password_auth || return 1

    cat <<EOF

${BOLD}=== IMPORTANT / 重要：删除公钥前请先测试密码登录 ===${NC}
Keep THIS session open. From another terminal, run:
请保持当前会话不要关闭，并在另一个终端运行：

    ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -o ControlPath=none ${TARGET_USER}@<this-server>

If you changed the SSH port, add -p <port>.
如果你改过 SSH 端口，请加上 -p <端口>。

EOF
    ask "Did password login succeed? / 密码登录是否成功？[y/N]:"
    read -r yn || return 1
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
    read -r line_no || return 1
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
    read -r confirm || return 1
    if [[ "$confirm" != "DELETE" ]]; then
        info "Aborted by user / 用户已取消。"
        return 0
    fi

    reset_modified_files
    local tmp group
    tmp="$(mktemp)" || return 1
    group="$(id -gn "$TARGET_USER")" || { rm -f "$tmp"; return 1; }
    if ! $SUDO awk -v n="$line_no" 'NR != n {print}' "$auth_file" > "$tmp" ||
       ! track_modified "$auth_file" ||
       ! atomic_install "$tmp" "$auth_file" 0600 "$TARGET_USER" "$group"; then
        rm -f "$tmp"
        rollback_config_flow
        return 1
    fi
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

    # Validate real public keys, not just text beginning with "ssh-".
    local fingerprints key_count config authorized_paths path key_file_used=0
    fingerprints="$($SUDO ssh-keygen -l -f "$auth_file" 2>/dev/null)" || {
        err "No valid authorized key / 没有有效的授权公钥: $auth_file"
        return 1
    }
    key_count="$(printf '%s\n' "$fingerprints" | wc -l | tr -d ' ')"
    (( key_count > 0 )) || return 1
    config="$(effective_sshd_config connection)" || return 1
    authorized_paths="$(awk '$1=="authorizedkeysfile" {$1=""; print}' <<< "$config")"
    for path in $authorized_paths; do
        case "$path" in
            .ssh/authorized_keys|"$auth_file"|'%h/.ssh/authorized_keys') key_file_used=1 ;;
        esac
    done
    if (( ! key_file_used )); then
        err "sshd uses a different AuthorizedKeysFile / sshd 使用了不同的公钥文件，拒绝关闭密码登录。"
        return 1
    fi
    verify_sshd_option PubkeyAuthentication yes || return 1
    # Refuse all conflicting Match exceptions, including other users/addresses.
    scan_sshd_config PasswordAuthentication no &&
        scan_sshd_config KbdInteractiveAuthentication no || return 1
    ok "Found $key_count valid key(s); pubkey auth enabled / 已找到有效公钥并启用密钥认证。"

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
    read -r confirm || return 1
    if [[ "$confirm" != "YES" ]]; then
        info "Aborted by user / 用户已取消。"
        return 0
    fi

    reset_modified_files
    apply_auth_options PasswordAuthentication no KbdInteractiveAuthentication no UsePAM yes || return 1
    ok "Password authentication disabled and verified / 密码登录已关闭并验证。"

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
        read -r c || { echo; return 0; }
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
        local c
        read -r c || { echo; info "Bye / 再见。"; exit 0; }
        case "$c" in
            1) change_port_flow; [[ -z "$PORT_RUNNER" ]] || exit 1 ;;
            2) password_key_menu ;;
            q|Q) info "Bye / 再见。"; exit 0 ;;
            *) err "Invalid choice / 无效选项。" ;;
        esac
    done
}

# ---------- entry ----------
main() {
    init_privileges || exit 1
    local stdin_ok=1
    ensure_tty_stdin || stdin_ok=0

    handle_cli_args "$@"

    if (( ! stdin_ok )); then
        err "This script is interactive and needs a terminal on stdin."
        err "脚本需要交互式终端输入，请改用以下方式运行："
        err "  bash <(curl -fsSL ${INSTALL_SOURCE_URL})"
        exit 1
    fi

    info "Interactive SSH setup for Debian/Ubuntu / Debian/Ubuntu 交互式 SSH 设置"
    if [[ ! -f "$SSHD_CONFIG" ]]; then
        err "$SSHD_CONFIG not found. Is OpenSSH server installed?"
        exit 1
    fi
    detect_ssh_units
    detect_sshd_target
    detect_target_user
    init_backup_dir || exit 1
    trap port_exit_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    main_menu
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
