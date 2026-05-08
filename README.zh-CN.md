<div align="right">

[English](README.md) | 简体中文

</div>

# ssh-setup.sh

一个用于 Debian / Ubuntu 服务器的修改 SSH 端口以及管理密码 / 密钥登录的脚本。

---

### 功能简介

一个菜单式的 Bash 脚本，提供两个主要功能：

1. **修改 SSH 端口** — 同时兼容传统 `sshd.service` 模式和 Ubuntu 22.04+
   的 systemd socket 激活模式。会自动更新 `ufw` / `firewalld`（如已启用），
   然后**保留当前 SSH 会话**让你从另一个终端测试新端口。如果测试失败，
   可以在同一交互界面里一键回退。
2. **密码与密钥管理** — 子菜单内可以修改目标用户的 SSH 登录密码、添加公钥并启用密钥登录、
   先恢复密码登录再删除指定公钥，以及在确认密钥可用后关闭密码登录。

### 环境要求

- Debian 或 Ubuntu，使用 systemd
- 已安装 OpenSSH server
- `root` 用户，或具备 `sudo` 权限的用户

### 使用方法

**一条命令直接运行（无需 clone）：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ssaishou/vps-ssh-setup/main/ssh-setup.sh)
```

**安装成可重复使用的命令：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ssaishou/vps-ssh-setup/main/ssh-setup.sh) --install
ssh-setup
```

这会把脚本安装到 `/usr/local/bin/ssh-setup`，之后在任意目录输入
`ssh-setup` 就可以重新打开交互菜单。

其他命令行选项：

```bash
ssh-setup --help
ssh-setup --uninstall
```

**或下载后手动运行：**

```bash
# 下载或 clone 仓库后：
chmod +x ssh-setup.sh
sudo ./ssh-setup.sh
```

进入菜单后按需选择操作。新 VPS 推荐的执行顺序是：进入
**2) 密码与密钥管理**，选择 **2) 生成密钥并启用密钥登录** 或
**3) 添加公钥并启用密钥登录**，然后返回主菜单选择 **1) 修改 SSH 端口**。
确认密钥登录可用后，再使用 **2 → 5** 关闭密码登录。

### 安全机制

- 所有被修改的文件都会备份到
  `/var/backups/ssh-setup-<时间戳>-<进程号>/`
- 每次重启 sshd 前都会先跑 `sshd -t` 校验配置，不通过就**不重启**
- 自动识别服务名 / socket 名（`ssh` 或 `sshd`）
- socket 激活模式下使用 systemd drop-in
  （`/etc/systemd/system/ssh.socket.d/override.conf`），
  不会改动发行版自带的 unit 文件
- 改端口流程会**保留当前会话**，并提供脚本内回退选项
- 关闭密码登录前强制检查密钥是否真实存在，并通过 `sshd -T` 验证最终有效配置
- 删除公钥前会先恢复密码登录，并要求你从另一个终端测试密码登录成功后再删除

### 脚本不会做的事

- **不会**真正测试你的私钥能否登录 — 这需要另开一个终端，
  所以改端口流程会专门停下来等你手动测试
- 触碰不到云厂商控制台的**安全组**（AWS / GCP / 阿里云 等）。
  如果你的 VPS 在用安全组，请在控制台先放行新端口再测试
- 不会安装 OpenSSH、fail2ban 或任何其他软件包

### 许可证

MIT，使用风险自负。修改 SSH 配置前，**务必确认你有 VPS 控制台 / VNC 的
紧急访问方式**作为兜底。
