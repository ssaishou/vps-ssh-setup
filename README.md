<div align="right">

English | [简体中文](README.zh-CN.md)

</div>

# ssh-setup.sh

A script for Debian / Ubuntu servers that changes the SSH port and manages SSH password / key login.

---

### What it does

A menu-driven Bash script with two main areas:

1. **Change SSH port** — handles both classic `sshd.service` setups and
   modern systemd socket activation (Ubuntu 22.04+). Updates `ufw` /
   `firewalld` if present, then keeps your current session alive and
   asks you to verify the new port from another terminal. If the test
   fails, you can roll everything back from the same prompt.
2. **Password & key management** — a submenu for changing the target
   user's SSH login password, adding a public key and enabling key
   login, removing a selected public key after restoring password
   login, and disabling password authentication only after a working
   key is in place.

### Requirements

- Debian or Ubuntu with systemd
- OpenSSH server installed
- `root` or a user with `sudo`

### Usage

**One-liner (no clone needed):**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ssaishou/vps-ssh-setup/main/ssh-setup.sh)
```

**Install a reusable command:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ssaishou/vps-ssh-setup/main/ssh-setup.sh) --install
ssh-setup
```

This installs the script to `/usr/local/bin/ssh-setup`, so you can open
the interactive menu later by typing `ssh-setup` from any directory.

Other command-line options:

```bash
ssh-setup --help
ssh-setup --uninstall
```

**Or download and run manually:**

```bash
# Download / clone, then:
chmod +x ssh-setup.sh
sudo ./ssh-setup.sh
```

You'll see a bilingual menu — pick the operations you need. The
recommended sequence on a fresh VPS is: enter **2) Password & key
management**, choose **2) Generate key pair and enable key login** or
**3) Add public key and enable key login**, then return and choose
**1) Change SSH port**. After you have verified key login works, use
**2 → 5** to disable password login.

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
- Disabling password auth is gated on real key presence and effective
  `sshd -T` verification.
- Removing a public key restores password login first and asks you to
  test password login from another terminal before deleting the key.

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
