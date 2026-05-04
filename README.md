# ssh-setup.sh

An interactive SSH hardening script for Debian / Ubuntu servers.
一个用于 Debian / Ubuntu 服务器的交互式 SSH 加固脚本。

---

## English

### What it does

A menu-driven Bash script with three operations:

1. **Change SSH port** — handles both classic `sshd.service` setups and
   modern systemd socket activation (Ubuntu 22.04+). Updates `ufw` /
   `firewalld` if present, then keeps your current session alive and
   asks you to verify the new port from another terminal. If the test
   fails, you can roll everything back from the same prompt.
2. **Add an SSH public key** — paste a public key (`ssh-rsa`,
   `ssh-ed25519`, `ecdsa-…`, or `sk-…`). The script validates the
   format, ensures `~/.ssh` and `authorized_keys` have correct
   permissions, and skips duplicates.
3. **Disable password authentication** — refuses to run unless an
   `authorized_keys` file with at least one key exists *and* the
   effective `PubkeyAuthentication` is `yes`. Prevents lock-outs.

### Requirements

- Debian or Ubuntu with systemd
- OpenSSH server installed
- `root` or a user with `sudo`

### Usage

**One-liner (no clone needed):**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ssaishou/vps-ssh-setup/main/ssh-setup.sh)
```

**Or download and run manually:**

```bash
# Download / clone, then:
chmod +x ssh-setup.sh
sudo ./ssh-setup.sh
```

You'll see a menu — pick the operations you need, in any order. The
recommended sequence on a fresh VPS is **2 → 1 → 3**: add your key,
change the port (and test it), then disable password login.

### Safety features

- Every modified file is backed up under
  `/var/backups/ssh-setup-<timestamp>-<pid>/` before changes.
- `sshd -t` is run before every restart; if the config is invalid the
  service is **not** restarted.
- Service / socket names (`ssh` vs `sshd`) are auto-detected.
- Socket activation is handled with a systemd drop-in
  (`/etc/systemd/system/ssh.socket.d/override.conf`) instead of
  editing distro-shipped unit files.
- Port-change flow keeps the existing SSH session open and offers an
  in-script rollback.
- Disabling password auth is gated on real key presence — you cannot
  accidentally lock yourself out by running step 3 first.

### What the script does NOT do

- It does **not** test that your private key actually logs you in —
  that requires a second terminal, which is why the port-change flow
  pauses for you to verify.
- It cannot touch cloud-provider security groups (AWS / GCP / Aliyun
  console firewalls). If your VPS uses one, open the new port there
  before testing.
- It does not install OpenSSH, fail2ban, or any other package.

### License

MIT — use at your own risk. Always have console / VNC access to your
VPS as a fallback before changing SSH settings.

---

## 中文

### 功能简介

一个菜单式的 Bash 脚本，提供三个操作：

1. **修改 SSH 端口** — 同时兼容传统 `sshd.service` 模式和 Ubuntu 22.04+
   的 systemd socket 激活模式。会自动更新 `ufw` / `firewalld`（如已启用），
   然后**保留当前 SSH 会话**让你从另一个终端测试新端口。如果测试失败，
   可以在同一交互界面里一键回退。
2. **添加 SSH 公钥** — 粘贴公钥（支持 `ssh-rsa` / `ssh-ed25519` /
   `ecdsa-…` / `sk-…`）。脚本会校验格式、自动创建 `~/.ssh`、设置正确权限，
   并跳过重复的密钥。
3. **关闭密码登录** — 只有在 `authorized_keys` 中确实存在公钥
   **并且** `sshd -T` 显示 `PubkeyAuthentication yes` 的情况下才会执行，
   避免把自己锁在外面。

### 环境要求

- Debian 或 Ubuntu，使用 systemd
- 已安装 OpenSSH server
- `root` 用户，或具备 `sudo` 权限的用户

### 使用方法

**一条命令直接运行（无需 clone）：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ssaishou/vps-ssh-setup/main/ssh-setup.sh)
```

**或下载后手动运行：**

```bash
# 下载或 clone 仓库后：
chmod +x ssh-setup.sh
sudo ./ssh-setup.sh
```

进入菜单后按需选择操作，顺序任意。新 VPS 推荐的执行顺序是
**2 → 1 → 3**：先加公钥，再改端口（并测试），最后关闭密码登录。

### 安全机制

- 所有被修改的文件都会备份到
  `/var/backups/ssh-setup-<时间戳>-<进程号>/`
- 每次重启 sshd 前都会先跑 `sshd -t` 校验配置，不通过就**不重启**
- 自动识别服务名 / socket 名（`ssh` 或 `sshd`）
- socket 激活模式下使用 systemd drop-in
  （`/etc/systemd/system/ssh.socket.d/override.conf`），
  不会改动发行版自带的 unit 文件
- 改端口流程会**保留当前会话**，并提供脚本内回退选项
- 关闭密码登录前强制检查密钥是否真实存在 —
  即使你第一步就误选 3，也无法把自己锁出去

### 脚本不会做的事

- **不会**真正测试你的私钥能否登录 — 这需要另开一个终端，
  所以改端口流程会专门停下来等你手动测试
- 触碰不到云厂商控制台的**安全组**（AWS / GCP / 阿里云 等）。
  如果你的 VPS 在用安全组，请在控制台先放行新端口再测试
- 不会安装 OpenSSH、fail2ban 或任何其他软件包

### 许可证

MIT，使用风险自负。修改 SSH 配置前，**务必确认你有 VPS 控制台 / VNC 的
紧急访问方式**作为兜底。
