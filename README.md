# xui-ddns-allowlist

Dynamic DDNS source allowlist for x-ui / 3x-ui panel ports on Debian 12/13 systemd hosts with UFW.

The installer creates a small nftables guard that runs before UFW. It resolves configured DDNS names every minute and only allows those current or recently seen IPs to reach the configured panel port.

Default allowlist domains:

- `hkt.akastrmix.com`
- `cmhk.akastrmix.com`
- `hkbn.akastrmix.com`
- `hinet.akastrmix.com`

The repo copy of this list lives in `allowlist-domains.txt`.

Default panel port:

- `9621`

## Install

Clone the public repository, then run the installer:

```bash
git clone https://github.com/akastrmix/xui-ddns-allowlist.git
cd xui-ddns-allowlist
sudo bash install-xui-ddns-allowlist.sh
```

Or as a single command:

```bash
git clone https://github.com/akastrmix/xui-ddns-allowlist.git && cd xui-ddns-allowlist && sudo bash install-xui-ddns-allowlist.sh
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

Existing `/etc/default/xui-ddns-allowlist` values are preserved during updates. Pass environment variables again only when you intentionally want to change the installed configuration.

Use `DDNS_DOMAINS` for one or more names. The older singular `DDNS_DOMAIN` key is intentionally rejected instead of being guessed.

## Update Domains

For the fastest allowlist update workflow, edit `allowlist-domains.txt` in the repo, commit and push it, then run this on each VPS:

```bash
cd xui-ddns-allowlist
git pull
sudo bash install-xui-ddns-allowlist.sh --sync-domains
```

`--sync-domains` applies the repo domain list to `/etc/default/xui-ddns-allowlist`, refreshes the guard, and preserves the other local settings such as ports, resolvers, grace window, and timer interval.

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

Human-friendly status summary:

```bash
sudo bash install-xui-ddns-allowlist.sh --status
```

Low-level troubleshooting:

```bash
sudo nft list table inet xui_ddns_guard
sudo systemctl list-timers xui-ddns-allowlist.timer
sudo journalctl -u xui-ddns-allowlist.service -n 50 --no-pager
```

## Uninstall

```bash
sudo bash install-xui-ddns-allowlist.sh --uninstall
```

The uninstall command removes the systemd units, updater script, and nftables guard table. It keeps `/etc/default/xui-ddns-allowlist` and `/var/lib/xui-ddns-allowlist` for inspection or later reuse.

Uninstall does not remove UFW rules. If UFW allows the panel port, removing this guard can make that port public again.

## Design

This is intentionally a small guard, not a general firewall manager.

- It only manages its own nftables table, systemd units, updater script, config file, and state directory.
- It does not guess legacy or ambiguous configuration. Invalid config fails fast and leaves the current kernel rules untouched.
- It rebuilds the guard table when the active rule shape drifts from the expected generated shape.
- It keeps old resolved IPs briefly for DDNS changes, but it does not try to infer per-domain intent from partial DNS failures.

## Notes

- UFW should still allow the configured panel port. This nftables guard only pre-filters source IPs before UFW.
- First install requires at least one DDNS domain to resolve. If DNS fails and no previous state exists, the installer exits without creating an empty drop-only guard.
- If DNS resolution later fails, the updater extends the existing state for another `GRACE_SECONDS` instead of clearing it.
- Old resolved IPs remain allowed for `GRACE_SECONDS` to reduce lockout risk during DDNS changes.
