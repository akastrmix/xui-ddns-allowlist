#!/usr/bin/env bash
set -euo pipefail

# Install a dynamic nftables source allowlist for x-ui / 3x-ui panel ports.
# Designed for Debian 12/13 hosts that commonly use UFW. The nftables guard
# runs before UFW and only handles the configured panel port(s).

SCRIPT_NAME="xui-ddns-allowlist"
UPDATER="/usr/local/sbin/xui-ddns-allowlist-update"
CONFIG="/etc/default/xui-ddns-allowlist"
SERVICE="/etc/systemd/system/xui-ddns-allowlist.service"
TIMER="/etc/systemd/system/xui-ddns-allowlist.timer"
INIT_SERVICE="/etc/systemd/system/xui-ddns-guard-init.service"
STATE_DIR="/var/lib/xui-ddns-allowlist"

DEFAULT_DDNS_DOMAINS="hkt.akastrmix.com cmhk.akastrmix.com hkbn.akastrmix.com hinet.akastrmix.com"
DEFAULT_PORTS="9621"
DEFAULT_RESOLVERS="1.1.1.1,8.8.8.8,9.9.9.9"
DEFAULT_GRACE_SECONDS="900"
DEFAULT_INTERVAL_SECONDS="60"
DEFAULT_TABLE="xui_ddns_guard"
DEFAULT_SET4="admin4"
DEFAULT_SET6="admin6"
DEFAULT_CHAIN="input"
DEFAULT_PRIORITY="-100"
DEFAULT_MANAGE_UDP="1"
DEFAULT_ENSURE_UFW_ALLOW="0"

usage() {
  cat <<'EOF'
Usage:
  sudo bash install-xui-ddns-allowlist.sh [--install|--uninstall|--status]

Environment overrides:
  DDNS_DOMAINS="hkt.akastrmix.com cmhk.akastrmix.com hkbn.akastrmix.com hinet.akastrmix.com"
  PORTS="9621"
  RESOLVERS="1.1.1.1,8.8.8.8,9.9.9.9"
  GRACE_SECONDS=900
  INTERVAL_SECONDS=60
  MANAGE_UDP=1
  ENSURE_UFW_ALLOW=0

Examples:
  sudo DDNS_DOMAINS="hkt.akastrmix.com cmhk.akastrmix.com" PORTS="9621" bash install-xui-ddns-allowlist.sh
  sudo bash install-xui-ddns-allowlist.sh --status
  sudo bash install-xui-ddns-allowlist.sh --uninstall
EOF
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "ERROR: run as root." >&2
    exit 1
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_packages_if_needed() {
  local missing=()
  have_cmd nft || missing+=(nftables)
  have_cmd dig || missing+=(dnsutils)
  have_cmd python3 || missing+=(python3)
  have_cmd systemctl || missing+=(systemd)

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  if ! have_cmd apt-get; then
    echo "ERROR: missing commands and apt-get is unavailable: ${missing[*]}" >&2
    exit 1
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${missing[@]}"
}

normalize_list() {
  printf '%s' "$1" | tr ',' ' ' | xargs
}

write_updater() {
  install -d -m 0755 "$(dirname "$UPDATER")"
  cat > "$UPDATER" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import ipaddress
import json
import os
import subprocess
import sys
import tempfile
import time

CONFIG_PATH = "/etc/default/xui-ddns-allowlist"
DEFAULTS = {
    "DDNS_DOMAINS": "hkt.akastrmix.com cmhk.akastrmix.com hkbn.akastrmix.com hinet.akastrmix.com",
    "DDNS_DOMAIN": "",
    "PORTS": "9621",
    "RESOLVERS": "1.1.1.1,8.8.8.8,9.9.9.9",
    "GRACE_SECONDS": "900",
    "TABLE": "xui_ddns_guard",
    "SET4": "admin4",
    "SET6": "admin6",
    "CHAIN": "input",
    "PRIORITY": "-100",
    "MANAGE_UDP": "1",
    "STATE_FILE": "/var/lib/xui-ddns-allowlist/state.json",
}


def load_config(path):
    cfg = DEFAULTS.copy()
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if key:
                    cfg[key] = value
    return cfg


def split_words(value):
    return [item.strip() for item in value.replace(",", " ").split() if item.strip()]


def configured_domains(cfg):
    domains = split_words(cfg.get("DDNS_DOMAINS", ""))
    legacy = split_words(cfg.get("DDNS_DOMAIN", ""))
    merged = []
    seen = set()
    for domain in domains + legacy:
        lowered = domain.lower().rstrip(".")
        if lowered and lowered not in seen:
            seen.add(lowered)
            merged.append(lowered)
    if not merged:
        raise ValueError("DDNS_DOMAINS cannot be empty")
    return merged


def run(cmd, input_text=None, check=True):
    proc = subprocess.run(
        cmd,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"command failed: {' '.join(cmd)}\nstdout={proc.stdout}\nstderr={proc.stderr}"
        )
    return proc


def parse_ports(value):
    ports = []
    for part in split_words(value):
        port = int(part)
        if not 1 <= port <= 65535:
            raise ValueError(f"invalid port: {port}")
        ports.append(port)
    if not ports:
        raise ValueError("PORTS cannot be empty")
    return sorted(set(ports))


def nft_port_expr(ports):
    if len(ports) == 1:
        return str(ports[0])
    return "{ " + ", ".join(str(p) for p in ports) + " }"


def bool_config(value):
    return str(value).strip() not in ("0", "false", "False", "no", "NO", "off", "OFF")


def desired_ruleset(cfg):
    table = cfg["TABLE"]
    set4 = cfg["SET4"]
    set6 = cfg["SET6"]
    chain = cfg["CHAIN"]
    priority = int(cfg["PRIORITY"])
    ports = nft_port_expr(parse_ports(cfg["PORTS"]))
    udp_rules = ""
    if bool_config(cfg.get("MANAGE_UDP", "1")):
        udp_rules = f"""
        udp dport {ports} ip saddr @{set4} accept
        udp dport {ports} ip6 saddr @{set6} accept
        udp dport {ports} drop"""
    return f"""table inet {table} {{
    set {set4} {{
        type ipv4_addr
        flags timeout
    }}

    set {set6} {{
        type ipv6_addr
        flags timeout
    }}

    chain {chain} {{
        type filter hook input priority {priority}; policy accept;
        iifname "lo" accept
        tcp dport {ports} ip saddr @{set4} accept
        tcp dport {ports} ip6 saddr @{set6} accept{udp_rules}
        tcp dport {ports} drop
    }}
}}
"""


def table_complete(cfg):
    table = cfg["TABLE"]
    checks = [
        ["nft", "list", "table", "inet", table],
        ["nft", "list", "set", "inet", table, cfg["SET4"]],
        ["nft", "list", "set", "inet", table, cfg["SET6"]],
        ["nft", "list", "chain", "inet", table, cfg["CHAIN"]],
    ]
    return all(run(cmd, check=False).returncode == 0 for cmd in checks)


def ensure_table(cfg, force=False):
    if table_complete(cfg) and not force:
        return False
    table = cfg["TABLE"]
    run(["nft", "delete", "table", "inet", table], check=False)
    rules = desired_ruleset(cfg)
    run(["nft", "-c", "-f", "-"], input_text=rules)
    run(["nft", "-f", "-"], input_text=rules)
    return True


def resolve_domains(domains, resolvers):
    found = {"4": set(), "6": set()}
    details = {}
    for domain in domains:
        details[domain] = {"4": [], "6": []}
        for resolver in resolvers:
            for rrtype, version in (("A", 4), ("AAAA", 6)):
                cmd = ["dig", "+short", rrtype, domain]
                if resolver:
                    cmd.append(f"@{resolver}")
                proc = run(cmd, check=False)
                if proc.returncode != 0:
                    continue
                for raw in proc.stdout.splitlines():
                    candidate = raw.strip().rstrip(".")
                    if not candidate:
                        continue
                    try:
                        ip = ipaddress.ip_address(candidate)
                    except ValueError:
                        continue
                    if ip.version != version:
                        continue
                    if ip.is_loopback or ip.is_unspecified or ip.is_multicast:
                        continue
                    normalized = str(ip)
                    found[str(version)].add(normalized)
                    details[domain][str(version)].append(normalized)
    return found, details


def load_state(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            state = json.load(f)
    except Exception:
        state = {"4": {}, "6": {}}
    for fam in ("4", "6"):
        if fam not in state or not isinstance(state[fam], dict):
            state[fam] = {}
    return state


def save_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="state.", dir=os.path.dirname(path), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2, sort_keys=True)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        try:
            if os.path.exists(tmp):
                os.unlink(tmp)
        except OSError:
            pass


def validate_state(state, now):
    clean = {"4": {}, "6": {}}
    for fam, version in (("4", 4), ("6", 6)):
        for ip, expiry in state.get(fam, {}).items():
            try:
                parsed = ipaddress.ip_address(ip)
                expiry = int(expiry)
            except Exception:
                continue
            if parsed.version == version and expiry > now:
                clean[fam][str(parsed)] = expiry
    return clean


def apply_sets(cfg, state, now):
    table = cfg["TABLE"]
    set4 = cfg["SET4"]
    set6 = cfg["SET6"]

    def elems(fam):
        parts = []
        for ip, expiry in sorted(state[fam].items()):
            timeout = max(1, int(expiry) - now)
            parts.append(f"{ip} timeout {timeout}s")
        return parts

    batch = [
        f"flush set inet {table} {set4}",
        f"flush set inet {table} {set6}",
    ]
    e4 = elems("4")
    e6 = elems("6")
    if e4:
        batch.append(f"add element inet {table} {set4} {{ {', '.join(e4)} }}")
    if e6:
        batch.append(f"add element inet {table} {set6} {{ {', '.join(e6)} }}")
    run(["nft", "-f", "-"], input_text="\n".join(batch) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--init-only", action="store_true", help="create nft guard only; do not resolve DNS")
    parser.add_argument("--force-table", action="store_true", help="rebuild the nft guard table")
    parser.add_argument("--print-config", action="store_true")
    args = parser.parse_args()

    cfg = load_config(CONFIG_PATH)
    domains = configured_domains(cfg)
    created = ensure_table(cfg, force=args.force_table)
    if args.init_only:
        print(f"guard table ready: table={cfg['TABLE']} created={created}")
        return 0
    if args.print_config:
        print(json.dumps({**cfg, "DOMAINS": domains}, indent=2, sort_keys=True))
        return 0

    now = int(time.time())
    state_path = cfg["STATE_FILE"]
    state = validate_state(load_state(state_path), now)
    resolvers = split_words(cfg["RESOLVERS"])
    if not resolvers:
        resolvers = [""]
    resolved, details = resolve_domains(domains, resolvers)
    resolved_count = len(resolved["4"]) + len(resolved["6"])
    if resolved_count == 0:
        print(
            f"ERROR: no valid A/AAAA records resolved for {', '.join(domains)}; keeping existing nft set",
            file=sys.stderr,
        )
        return 2

    grace = int(cfg["GRACE_SECONDS"])
    expiry = now + grace
    for fam in ("4", "6"):
        for ip in resolved[fam]:
            state[fam][ip] = expiry
    state = validate_state(state, now)
    save_state(state_path, state)
    apply_sets(cfg, state, now)
    print(
        "updated allowlist: "
        f"domains={','.join(domains)} "
        f"ports={cfg['PORTS']} "
        f"ipv4={','.join(sorted(state['4'])) or '-'} "
        f"ipv6={','.join(sorted(state['6'])) or '-'} "
        f"ttl={grace}s"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
PYEOF
  chmod 0755 "$UPDATER"
}

write_config() {
  install -d -m 0755 "$(dirname "$CONFIG")"

  local ddns_domains="${DDNS_DOMAINS:-${DDNS_DOMAIN:-$DEFAULT_DDNS_DOMAINS}}"
  ddns_domains="$(normalize_list "$ddns_domains")"
  local ports="${PORTS:-$DEFAULT_PORTS}"
  ports="$(normalize_list "$ports")"
  local resolvers="${RESOLVERS:-$DEFAULT_RESOLVERS}"
  resolvers="$(normalize_list "$resolvers")"
  local grace="${GRACE_SECONDS:-$DEFAULT_GRACE_SECONDS}"
  local table="${TABLE:-$DEFAULT_TABLE}"
  local set4="${SET4:-$DEFAULT_SET4}"
  local set6="${SET6:-$DEFAULT_SET6}"
  local chain="${CHAIN:-$DEFAULT_CHAIN}"
  local priority="${PRIORITY:-$DEFAULT_PRIORITY}"
  local manage_udp="${MANAGE_UDP:-$DEFAULT_MANAGE_UDP}"

  if [ -f "$CONFIG" ]; then
    cp -a "$CONFIG" "$CONFIG.bak-$(date +%s)"
  fi

  cat > "$CONFIG" <<EOF
# Dynamic source allowlist for x-ui / 3x-ui panel ports.
# The updater resolves these DDNS names and allows current and recent IPs only.
DDNS_DOMAINS="$ddns_domains"
PORTS="$ports"
RESOLVERS="$resolvers"
GRACE_SECONDS="$grace"
TABLE="$table"
SET4="$set4"
SET6="$set6"
CHAIN="$chain"
PRIORITY="$priority"
MANAGE_UDP="$manage_udp"
STATE_FILE="$STATE_DIR/state.json"
EOF
  chmod 0644 "$CONFIG"
}

write_systemd_units() {
  local interval="${INTERVAL_SECONDS:-$DEFAULT_INTERVAL_SECONDS}"

  cat > "$SERVICE" <<EOF
[Unit]
Description=Update x-ui DDNS nftables allowlist
Wants=network-online.target
After=network-online.target
ConditionPathExists=$UPDATER

[Service]
Type=oneshot
ExecStart=$UPDATER
EOF

  cat > "$TIMER" <<EOF
[Unit]
Description=Refresh x-ui DDNS nftables allowlist

[Timer]
OnBootSec=20s
OnActiveSec=${interval}s
OnUnitActiveSec=${interval}s
AccuracySec=10s
Persistent=true
Unit=$(basename "$SERVICE")

[Install]
WantedBy=timers.target
EOF

  cat > "$INIT_SERVICE" <<EOF
[Unit]
Description=Install early nftables guard for x-ui panel ports
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target ufw.service
Wants=network-pre.target
ConditionPathExists=$UPDATER

[Service]
Type=oneshot
ExecStart=$UPDATER --init-only
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

  chmod 0644 "$SERVICE" "$TIMER" "$INIT_SERVICE"
}

maybe_ensure_ufw_allow() {
  local ensure="${ENSURE_UFW_ALLOW:-$DEFAULT_ENSURE_UFW_ALLOW}"
  if [ "$ensure" != "1" ]; then
    return 0
  fi
  if ! have_cmd ufw; then
    echo "WARN: ENSURE_UFW_ALLOW=1 but ufw is not installed." >&2
    return 0
  fi
  local ports="${PORTS:-$DEFAULT_PORTS}"
  ports="$(normalize_list "$ports")"
  local port
  for port in $ports; do
    ufw allow "$port" >/dev/null || true
  done
}

warn_ufw_status() {
  if ! have_cmd ufw; then
    return 0
  fi
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "INFO: UFW is active. Keep UFW allowing the configured panel port(s), because nftables only pre-filters sources."
  fi
}

install_all() {
  require_root
  install_packages_if_needed
  install -d -m 0700 "$STATE_DIR"
  write_updater
  write_config
  write_systemd_units
  maybe_ensure_ufw_allow
  systemctl daemon-reload
  "$UPDATER" --force-table --init-only
  "$UPDATER"
  systemctl enable --now "$(basename "$INIT_SERVICE")" "$(basename "$TIMER")"
  warn_ufw_status
  echo
  echo "Installed $SCRIPT_NAME."
  echo "Config: $CONFIG"
  echo "Status commands:"
  echo "  nft list table inet ${TABLE:-$DEFAULT_TABLE}"
  echo "  systemctl list-timers $(basename "$TIMER")"
  echo "  journalctl -u $(basename "$SERVICE") -n 50 --no-pager"
}

uninstall_all() {
  require_root
  local table="${TABLE:-$DEFAULT_TABLE}"
  if [ -f "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG" || true
    table="${TABLE:-$table}"
  fi
  systemctl disable --now "$(basename "$TIMER")" "$(basename "$INIT_SERVICE")" >/dev/null 2>&1 || true
  systemctl stop "$(basename "$SERVICE")" >/dev/null 2>&1 || true
  nft delete table inet "$table" >/dev/null 2>&1 || true
  rm -f "$UPDATER" "$SERVICE" "$TIMER" "$INIT_SERVICE"
  systemctl daemon-reload
  echo "Uninstalled $SCRIPT_NAME. Config and state were kept:"
  echo "  $CONFIG"
  echo "  $STATE_DIR"
  echo "Remove them manually if no longer needed."
}

status_all() {
  require_root
  local table="${TABLE:-$DEFAULT_TABLE}"
  local set4="${SET4:-$DEFAULT_SET4}"
  local set6="${SET6:-$DEFAULT_SET6}"
  local ports="${PORTS:-$DEFAULT_PORTS}"
  local domains="${DDNS_DOMAINS:-${DDNS_DOMAIN:-$DEFAULT_DDNS_DOMAINS}}"
  local resolvers="${RESOLVERS:-$DEFAULT_RESOLVERS}"
  local grace="${GRACE_SECONDS:-$DEFAULT_GRACE_SECONDS}"
  local manage_udp="${MANAGE_UDP:-$DEFAULT_MANAGE_UDP}"

  if [ -f "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG" || true
    table="${TABLE:-$table}"
    set4="${SET4:-$set4}"
    set6="${SET6:-$set6}"
    ports="${PORTS:-$ports}"
    domains="${DDNS_DOMAINS:-${DDNS_DOMAIN:-$domains}}"
    resolvers="${RESOLVERS:-$resolvers}"
    grace="${GRACE_SECONDS:-$grace}"
    manage_udp="${MANAGE_UDP:-$manage_udp}"
  fi

  local timer_unit service_unit guard_state timer_state timer_enabled next_timer last_log first_resolver
  timer_unit="$(basename "$TIMER")"
  service_unit="$(basename "$SERVICE")"
  if nft list table inet "$table" >/dev/null 2>&1; then
    guard_state="active"
  else
    guard_state="missing"
  fi

  timer_state="$(systemctl is-active "$timer_unit" 2>/dev/null || true)"
  timer_enabled="$(systemctl is-enabled "$timer_unit" 2>/dev/null || true)"
  next_timer="$(systemctl list-timers --no-pager --all "$timer_unit" 2>/dev/null | awk 'NR==2 {print $1, $2, $3, $4, $5}')"
  last_log="$(journalctl -u "$service_unit" -n 40 -o cat --no-pager 2>/dev/null | grep -E 'updated allowlist|ERROR:' | tail -n 1 || true)"
  first_resolver="$(normalize_list "$resolvers" | awk '{print $1}')"

  echo "xui-ddns-allowlist status"
  echo "========================="
  printf "Guard:            %s (nft table inet %s)\n" "$guard_state" "$table"
  printf "Protected ports:  %s/tcp" "$(normalize_list "$ports")"
  if [ "$manage_udp" = "1" ]; then
    printf " and %s/udp" "$(normalize_list "$ports")"
  fi
  printf "\n"
  printf "Timer:            %s, %s\n" "${timer_state:-unknown}" "${timer_enabled:-unknown}"
  if [ -n "$next_timer" ]; then
    printf "Next refresh:     %s\n" "$next_timer"
  fi
  printf "Grace window:     %ss\n" "$grace"
  printf "Config:           %s\n" "$CONFIG"
  if [ -n "$last_log" ]; then
    printf "Last update:      %s\n" "$last_log"
  else
    printf "Last update:      no update log found\n"
  fi

  echo
  echo "DDNS domains"
  echo "------------"
  local domain a_records aaaa_records
  for domain in $(normalize_list "$domains"); do
    if [ -n "$first_resolver" ]; then
      a_records="$(dig +short A "$domain" @"$first_resolver" 2>/dev/null | xargs || true)"
      aaaa_records="$(dig +short AAAA "$domain" @"$first_resolver" 2>/dev/null | xargs || true)"
    else
      a_records="$(dig +short A "$domain" 2>/dev/null | xargs || true)"
      aaaa_records="$(dig +short AAAA "$domain" 2>/dev/null | xargs || true)"
    fi
    if [ -z "$a_records$aaaa_records" ]; then
      printf "  %-24s -> %s\n" "$domain" "no A/AAAA records"
    else
      printf "  %-24s -> %s%s%s\n" "$domain" "${a_records:-}" "$([ -n "$a_records" ] && [ -n "$aaaa_records" ] && printf ' | ')" "${aaaa_records:-}"
    fi
  done

  echo
  echo "Allowed source IPs"
  echo "------------------"
  python3 - "$table" "$set4" "$set6" <<'PYEOF'
import re
import subprocess
import sys

table, set4, set6 = sys.argv[1:4]

def show_set(label, set_name):
    proc = subprocess.run(
        ["nft", "list", "set", "inet", table, set_name],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        print(f"  {label}: set missing or unreadable")
        return
    text = " ".join(proc.stdout.split())
    pattern = re.compile(r"((?:\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F:]{2,})\s+timeout\s+\S+\s+expires\s+([^,}]+)")
    rows = pattern.findall(text)
    if not rows:
        print(f"  {label}: none")
        return
    for ip, expires in rows:
        print(f"  {label}: {ip:<39} expires in {expires.strip()}")

show_set("IPv4", set4)
show_set("IPv6", set6)
PYEOF

  echo
  echo "UFW"
  echo "---"
  if have_cmd ufw; then
    ufw status | sed -n '1,40p'
  else
    echo "ufw not installed"
  fi

  echo
  echo "Useful commands"
  echo "---------------"
  echo "  sudo /usr/local/sbin/xui-ddns-allowlist-update"
  echo "  sudo nft list table inet $table"
  echo "  sudo journalctl -u $service_unit -n 50 --no-pager"
}

main() {
  local action="${1:---install}"
  case "$action" in
    --install|-i)
      install_all
      ;;
    --uninstall)
      uninstall_all
      ;;
    --status)
      status_all
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "ERROR: unknown argument: $action" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
