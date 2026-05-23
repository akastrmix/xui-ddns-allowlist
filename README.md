# xui-ddns-allowlist

Dynamic DDNS source allowlist for x-ui / 3x-ui panel ports on Debian 12/13 hosts with UFW.

The installer creates a small nftables guard that runs before UFW. It resolves configured DDNS names every minute and only allows those current or recently seen IPs to reach the configured panel port.

Default allowlist domains:

- `hkt.akastrmix.com`
- `cmhk.akastrmix.com`
- `hkbn.akastrmix.com`
- `hinet.akastrmix.com`

Default panel port:

- `9621`

## Install

Clone the repository, then run the installer:

```bash
git clone https://github.com/akastrmix/xui-ddns-allowlist.git
cd xui-ddns-allowlist
sudo bash install-xui-ddns-allowlist.sh
```

If the repository is private, use an SSH deploy key on the VPS and clone through SSH. One-time VPS setup:

```bash
sudo install -d -m 700 /root/.ssh
sudo ssh-keygen -t ed25519 -f /root/.ssh/xui-ddns-allowlist-github -N '' -C 'xui-ddns-allowlist'
sudo cat /root/.ssh/xui-ddns-allowlist-github.pub
```

Add the printed public key to the GitHub repository under `Settings -> Deploy keys` without write access, then configure SSH:

```bash
sudo tee -a /root/.ssh/config >/dev/null <<'EOF'
Host github.com-xui-ddns-allowlist
    HostName github.com
    User git
    IdentityFile /root/.ssh/xui-ddns-allowlist-github
    IdentitiesOnly yes
EOF
sudo chmod 600 /root/.ssh/config
```

Then clone and install:

```bash
git clone github.com-xui-ddns-allowlist:akastrmix/xui-ddns-allowlist.git
cd xui-ddns-allowlist
sudo bash install-xui-ddns-allowlist.sh
```

If you already have the script locally on the VPS:

```bash
sudo bash install-xui-ddns-allowlist.sh
```

If UFW does not already allow the panel port:

```bash
sudo ENSURE_UFW_ALLOW=1 bash install-xui-ddns-allowlist.sh
```

## Update

```bash
cd xui-ddns-allowlist
git pull
sudo bash install-xui-ddns-allowlist.sh
```

## Customize

```bash
sudo DDNS_DOMAINS="hkt.akastrmix.com cmhk.akastrmix.com" PORTS="9621" bash install-xui-ddns-allowlist.sh
```

Optional environment variables:

```bash
DDNS_DOMAINS="hkt.akastrmix.com cmhk.akastrmix.com hkbn.akastrmix.com hinet.akastrmix.com"
PORTS="9621"
RESOLVERS="1.1.1.1,8.8.8.8,9.9.9.9"
GRACE_SECONDS=900
INTERVAL_SECONDS=60
MANAGE_UDP=1
ENSURE_UFW_ALLOW=0
```

## Status

```bash
sudo bash install-xui-ddns-allowlist.sh --status
sudo nft list table inet xui_ddns_guard
sudo systemctl list-timers xui-ddns-allowlist.timer
sudo journalctl -u xui-ddns-allowlist.service -n 50 --no-pager
```

## Uninstall

```bash
sudo bash install-xui-ddns-allowlist.sh --uninstall
```

The uninstall command removes the systemd units, updater script, and nftables guard table. It keeps `/etc/default/xui-ddns-allowlist` and `/var/lib/xui-ddns-allowlist` for inspection or later reuse.

## Notes

- UFW should still allow the configured panel port. This nftables guard only pre-filters source IPs before UFW.
- If DNS resolution fails, the updater keeps the existing allowlist instead of clearing it.
- Old resolved IPs remain allowed for `GRACE_SECONDS` to reduce lockout risk during DDNS changes.
