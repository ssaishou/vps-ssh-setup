<div align="right">

[English](#english) | [简体中文](#简体中文)

</div>

# ssh-setup.sh

<a id="english"></a>

## English

An interactive, bilingual SSH configuration script for Debian / Ubuntu.

### Features

- Change SSH ports on traditional services and systemd socket activation
  (the Ubuntu default since 22.10), preserving listening addresses and existing
  socket configuration.
- Change the current user's password, add or generate a key, remove a selected
  key after testing password login, and disable password authentication.
- Update active UFW / firewalld rules when requested.

### Requirements

- Debian / Ubuntu with systemd, OpenSSH server, and `ssh-keygen`.
- Root or sudo privileges.
- `ss` (iproute2), `flock` (util-linux), and `systemd-run` for guarded port changes.

The script does not install dependencies or modify cloud security groups.

### Usage

Run directly:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ssaishou/vps-ssh-setup/main/ssh-setup.sh)
```

Install a reusable command:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ssaishou/vps-ssh-setup/main/ssh-setup.sh) --install
ssh-setup
```

Or run a downloaded copy with `sudo bash ssh-setup.sh`.
Use `ssh-setup --help` or `ssh-setup --uninstall` to manage the command installed
at `/usr/local/bin/ssh-setup`.

For a fresh VPS, add your public key first, test it from a separate terminal,
then change the port. Disable password login only after confirming key login.
If generating a key on the server, save its displayed private key locally and
follow the prompt to delete the temporary server copy.

### Recovery and validation

- Every changed file is backed up under
  `/var/backups/ssh-setup-<random>/flow-<number>/files/`.
  Failed backups or writes abort the operation. Config and key files are staged
  and atomically renamed, avoiding truncation on a failed write.
- A separate root-owned systemd timer restores port changes after **180 seconds**
  unless you confirm a successful new connection. EOF, interruption, and failed
  changes also trigger rollback. Confirmation and rollback share a lock, so
  confirmation cannot race with an already completed rollback.
- The timer survives SSH disconnection or a killed interactive process, but is
  **not persistent across a server reboot**. Do not reboot before confirmation.
- Port changes use a dedicated
  `/etc/systemd/system/ssh.socket.d/zzzz-ssh-setup-port.conf` drop-in; existing
  `override.conf` files, listening addresses, and interface restrictions remain.
- Firewall rollback removes only rules added by this operation. IPv4/IPv6 and
  firewalld runtime/permanent rules are tracked separately.
- Global settings are placed before all `Include` and `Match` blocks. Conflicting
  conditional authentication exceptions, including nested Includes, stop the
  operation; resolve them explicitly before proceeding.
- `sshd -t` validates before every restart. Authentication is checked with both
  global `sshd -T` and connection-specific `sshd -T -C` values. From a local
  console, the latter uses a loopback connection context.
- Disabling password login validates actual public-key data and confirms that
  sshd uses the expected authorized-key file. It cannot test possession of your
  private key; verify that separately.
- Key removal provides a password-only test command with connection sharing
  disabled. Restricted root password login is detected; the script does not
  automatically relax `PermitRootLogin`.
- Symlinked config/key files are not replaced; resolve their intended target
  and ownership manually before using the corresponding edit.

If recovery reports an error, use console access and the printed backup path.
A port transaction also leaves its root-owned recovery helper there; run
`sudo bash <flow-directory>/port-transaction.sh rollback` to retry recovery.
Open any required cloud security-group rule before changing ports.

### Tests

```bash
bash -n ssh-setup.sh
shellcheck --severity=warning ssh-setup.sh
python3 -m unittest discover -s tests -v
```

Tests use temporary configurations and mock firewall commands. Linux root
enables recovery-helper and real systemd timer tests. CI also tests a separate
loopback-only SSH socket on Ubuntu 24.04; it does not modify the runner's normal
SSH service.

### License

MIT — use at your own risk. Keep console / VNC access available before changing
remote SSH configuration.

---

<a id="简体中文"></a>

## 简体中文

用于 Debian / Ubuntu 的中英双语交互式 SSH 配置脚本。

### 功能与环境要求

- 修改 SSH 端口，兼容传统服务和 Ubuntu 22.10 起默认使用的 systemd socket 激活模式，
  保留原有监听地址及 socket 配置。
- 修改当前用户密码、添加或生成密钥、测试密码登录后删除选定公钥，以及关闭密码认证。
- 按需更新已启用的 UFW / firewalld。

需要 systemd、OpenSSH server、`ssh-keygen` 和 root / sudo 权限。
改端口还需要 `ss`（iproute2）、`flock`（util-linux）和 `systemd-run`。
脚本不会安装依赖，也无法修改云安全组。

### 使用方法

直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ssaishou/vps-ssh-setup/main/ssh-setup.sh)
```

安装为可重复使用的命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ssaishou/vps-ssh-setup/main/ssh-setup.sh) --install
ssh-setup
```

也可以下载后运行 `sudo bash ssh-setup.sh`。
使用 `ssh-setup --help` 查看帮助，`ssh-setup --uninstall` 删除安装在
`/usr/local/bin/ssh-setup` 的命令。

新 VPS 建议先添加公钥，在另一个终端确认密钥登录成功，再修改端口。
最后再关闭密码登录。如果选择在服务器生成密钥，请先在本地保存显示的私钥，
再按提示删除服务器的临时副本。

### 恢复与验证机制

- 修改前备份至 `/var/backups/ssh-setup-<随机标识>/flow-<流程编号>/files/`。
  备份或写入失败会中止操作；配置和公钥先写入临时文件，成功后原子替换。
- 改端口前启动独立的 root systemd 定时器，**180 秒内未确认新连接成功就自动回滚**。
  输入结束、中断和操作失败也会回滚；确认和回滚共用锁，避免两者同时发生导致状态错乱。
- SSH 断线或交互进程被杀不会取消定时器，但定时器**无法跨服务器重启保留**；
  确认新连接前不要重启服务器。
- socket 配置使用独立的
  `/etc/systemd/system/ssh.socket.d/zzzz-ssh-setup-port.conf`，
  保留管理员已有的 `override.conf`、监听地址和网卡限制。
- 防火墙回滚只撤销本次新增规则，分别跟踪 IPv4/IPv6 和 firewalld 的运行时/永久规则。
- 全局选项写在所有 `Include`、`Match` 之前。条件认证配置存在冲突时会停止，
  包括嵌套 Include 中的例外，需要明确处理后再继续。
- 每次重启前运行 `sshd -t`，并用 `sshd -T` 和带连接条件的 `sshd -T -C`
  检查认证配置；从本地控制台运行时使用回环地址作为连接条件。
- 关闭密码认证前检查公钥内容有效，并确认 sshd 实际使用该公钥文件。
  脚本无法代替你验证私钥能否登录，仍需另开终端测试。
- 删除公钥前提供禁用公钥认证和连接复用的密码测试命令。
  root 密码登录仍受 `PermitRootLogin` 限制时会停止，不会自动放宽该策略。
- 拒绝覆盖符号链接形式的配置或公钥文件，需先人工明确其链接目标和管理方式。

如果恢复失败，请通过控制台使用输出的备份目录处理。端口修改流程还会保留
root 管理的恢复脚本，可运行
`sudo bash <流程目录>/port-transaction.sh rollback` 重试。
改端口前，请先在云安全组放行新端口。

### 测试

```bash
bash -n ssh-setup.sh
shellcheck --severity=warning ssh-setup.sh
python3 -m unittest discover -s tests -v
```

测试使用临时配置和模拟防火墙命令。Linux root 环境还会测试独立恢复进程和真实
systemd 定时器。CI 在 Ubuntu 24.04 额外创建仅监听回环地址的独立 SSH socket，
验证改端口和回滚，不会修改测试机原有的 SSH 服务。

### 许可证

MIT，使用风险自负。修改远程 SSH 配置前，请确保有控制台 / VNC 紧急访问方式。
