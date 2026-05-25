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
DEFAULT_STATE_FILE="$STATE_DIR/state.json"

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

is_truthy() {
  case "$1" in
    1|true|True|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

config_get() {
  local key="$1"
  local default_value="$2"
  if [ ! -f "$CONFIG" ]; then
    printf '%s' "$default_value"
    return 0
  fi
  local value
  value="$(awk -v want="$key" '
    /^[[:space:]]*#/ { next }
    index($0, "=") == 0 { next }
    {
      k = substr($0, 1, index($0, "=") - 1)
      v = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (k == want) {
        if ((v ~ /^".*"$/) || (v ~ /^\047.*\047$/)) {
          v = substr(v, 2, length(v) - 2)
        }
        print v
        exit
      }
    }
  ' "$CONFIG")"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$default_value"
  fi
}

config_has_key() {
  local key="$1"
  [ -f "$CONFIG" ] || return 1
  awk -v want="$key" '
    /^[[:space:]]*#/ { next }
    index($0, "=") == 0 { next }
    {
      k = substr($0, 1, index($0, "=") - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      if (k == want) {
        found = 1
        exit
      }
    }
    END { exit found ? 0 : 1 }
  ' "$CONFIG"
}

is_valid_ip() {
  python3 - "$1" <<'PYEOF'
import ipaddress
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PYEOF
}

env_or_config() {
  local env_name="$1"
  local config_key="$2"
  local default_value="$3"
  if [ "${!env_name+x}" = "x" ]; then
    printf '%s' "${!env_name}"
  else
    config_get "$config_key" "$default_value"
  fi
}

load_effective_config() {
  if [ "${DDNS_DOMAIN+x}" = "x" ] || config_has_key DDNS_DOMAIN; then
    echo "ERROR: DDNS_DOMAIN is not supported; use DDNS_DOMAINS." >&2
    exit 1
  fi
  if [ "${DDNS_DOMAINS+x}" = "x" ]; then
    EFFECTIVE_DDNS_DOMAINS="$DDNS_DOMAINS"
  else
    EFFECTIVE_DDNS_DOMAINS="$(config_get DDNS_DOMAINS "$DEFAULT_DDNS_DOMAINS")"
  fi
  EFFECTIVE_DDNS_DOMAINS="$(normalize_list "$EFFECTIVE_DDNS_DOMAINS")"
  EFFECTIVE_PORTS="$(normalize_list "$(env_or_config PORTS PORTS "$DEFAULT_PORTS")")"
  EFFECTIVE_RESOLVERS="$(normalize_list "$(env_or_config RESOLVERS RESOLVERS "$DEFAULT_RESOLVERS")")"
  EFFECTIVE_GRACE_SECONDS="$(env_or_config GRACE_SECONDS GRACE_SECONDS "$DEFAULT_GRACE_SECONDS")"
  EFFECTIVE_INTERVAL_SECONDS="$(env_or_config INTERVAL_SECONDS INTERVAL_SECONDS "$DEFAULT_INTERVAL_SECONDS")"
  EFFECTIVE_TABLE="$(env_or_config TABLE TABLE "$DEFAULT_TABLE")"
  EFFECTIVE_SET4="$(env_or_config SET4 SET4 "$DEFAULT_SET4")"
  EFFECTIVE_SET6="$(env_or_config SET6 SET6 "$DEFAULT_SET6")"
  EFFECTIVE_CHAIN="$(env_or_config CHAIN CHAIN "$DEFAULT_CHAIN")"
  EFFECTIVE_PRIORITY="$(env_or_config PRIORITY PRIORITY "$DEFAULT_PRIORITY")"
  EFFECTIVE_MANAGE_UDP="$(env_or_config MANAGE_UDP MANAGE_UDP "$DEFAULT_MANAGE_UDP")"
  EFFECTIVE_STATE_FILE="$(env_or_config STATE_FILE STATE_FILE "$DEFAULT_STATE_FILE")"
}

validate_effective_config() {
  local item
  [ -n "$EFFECTIVE_DDNS_DOMAINS" ] || { echo "ERROR: DDNS_DOMAINS cannot be empty." >&2; exit 1; }
  [ -n "$EFFECTIVE_PORTS" ] || { echo "ERROR: PORTS cannot be empty." >&2; exit 1; }
  for item in $EFFECTIVE_DDNS_DOMAINS; do
    case "$item" in
      *[!A-Za-z0-9._-]* | .* | *..* | *.) echo "ERROR: invalid DDNS domain: $item" >&2; exit 1 ;;
    esac
  done
  for item in $EFFECTIVE_PORTS; do
    case "$item" in
      *[!0-9]* | "") echo "ERROR: invalid port: $item" >&2; exit 1 ;;
    esac
    if [ "$item" -lt 1 ] || [ "$item" -gt 65535 ]; then
      echo "ERROR: invalid port: $item" >&2
      exit 1
    fi
  done
  for item in $EFFECTIVE_RESOLVERS; do
    is_valid_ip "$item" || { echo "ERROR: invalid resolver: $item" >&2; exit 1; }
  done
  case "$EFFECTIVE_GRACE_SECONDS" in *[!0-9]* | "") echo "ERROR: invalid GRACE_SECONDS." >&2; exit 1 ;; esac
  case "$EFFECTIVE_INTERVAL_SECONDS" in *[!0-9]* | "") echo "ERROR: invalid INTERVAL_SECONDS." >&2; exit 1 ;; esac
  if [ "$EFFECTIVE_GRACE_SECONDS" -lt 1 ]; then
    echo "ERROR: GRACE_SECONDS must be positive." >&2
    exit 1
  fi
  if [ "$EFFECTIVE_INTERVAL_SECONDS" -lt 1 ]; then
    echo "ERROR: INTERVAL_SECONDS must be positive." >&2
    exit 1
  fi
  for item in "$EFFECTIVE_TABLE" "$EFFECTIVE_SET4" "$EFFECTIVE_SET6" "$EFFECTIVE_CHAIN"; do
    case "$item" in
      "" | [0-9]* | *[!A-Za-z0-9_]*)
        echo "ERROR: TABLE/SET/CHAIN names may only contain letters, numbers, and underscores, and cannot start with a number." >&2
        exit 1
        ;;
    esac
  done
  case "$EFFECTIVE_PRIORITY" in -*) item="${EFFECTIVE_PRIORITY#-}" ;; *) item="$EFFECTIVE_PRIORITY" ;; esac
  case "$item" in *[!0-9]* | "") echo "ERROR: invalid PRIORITY." >&2; exit 1 ;; esac
  case "$EFFECTIVE_MANAGE_UDP" in 0|1|true|false|True|False|yes|no|YES|NO|on|off|ON|OFF) ;; *) echo "ERROR: invalid MANAGE_UDP." >&2; exit 1 ;; esac
  case "$EFFECTIVE_STATE_FILE" in
    /*) ;;
    *) echo "ERROR: STATE_FILE must be an absolute path." >&2; exit 1 ;;
  esac
  if printf '%s' "$EFFECTIVE_STATE_FILE" | grep -q '[[:cntrl:]]'; then
    echo "ERROR: invalid STATE_FILE." >&2
    exit 1
  fi
}

require_systemd_running() {
  if ! have_cmd systemctl || [ ! -d /run/systemd/system ]; then
    echo "ERROR: this installer requires a systemd-based host." >&2
    exit 1
  fi
}

write_updater() {
  install -d -m 0755 "$(dirname "$UPDATER")"
  cat > "$UPDATER" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile
import time

CONFIG_PATH = "/etc/default/xui-ddns-allowlist"
DEFAULTS = {
    "DDNS_DOMAINS": "hkt.akastrmix.com cmhk.akastrmix.com hkbn.akastrmix.com hinet.akastrmix.com",
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

NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
DOMAIN_RE = re.compile(r"^[A-Za-z0-9._-]+$")


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
                if key == "DDNS_DOMAIN":
                    raise ValueError("DDNS_DOMAIN is not supported; use DDNS_DOMAINS")
                if key:
                    cfg[key] = value
    return cfg


def split_words(value):
    return [item.strip() for item in value.replace(",", " ").split() if item.strip()]


def configured_domains(cfg):
    domains = split_words(cfg.get("DDNS_DOMAINS", ""))
    merged = []
    seen = set()
    for domain in domains:
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


def validate_config(cfg):
    for key in ("TABLE", "SET4", "SET6", "CHAIN"):
        if not NAME_RE.match(str(cfg[key])):
            raise ValueError(f"{key} must contain only letters, numbers, and underscores, and cannot start with a number")
    int(cfg["PRIORITY"])
    grace = int(cfg["GRACE_SECONDS"])
    if grace < 1:
        raise ValueError("GRACE_SECONDS must be positive")
    parse_ports(cfg["PORTS"])
    for domain in configured_domains(cfg):
        if not DOMAIN_RE.match(domain) or domain.startswith(".") or domain.endswith(".") or ".." in domain:
            raise ValueError(f"invalid DDNS domain: {domain}")
    for resolver in split_words(cfg["RESOLVERS"]):
        try:
            ipaddress.ip_address(resolver)
        except ValueError as exc:
            raise ValueError(f"invalid resolver: {resolver}") from exc
    if not os.path.isabs(cfg["STATE_FILE"]) or "\n" in cfg["STATE_FILE"] or "\r" in cfg["STATE_FILE"]:
        raise ValueError("STATE_FILE must be an absolute path")
    if str(cfg.get("MANAGE_UDP", "1")).strip() not in ("0", "1", "true", "false", "True", "False", "yes", "no", "YES", "NO", "on", "off", "ON", "OFF"):
        raise ValueError("invalid MANAGE_UDP")


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


def table_exists(cfg):
    return run(["nft", "list", "table", "inet", cfg["TABLE"]], check=False).returncode == 0


def ensure_table(cfg, force=False):
    if not force and check_rules(cfg):
        return False
    table = cfg["TABLE"]
    rules = desired_ruleset(cfg)
    batch = rules
    if table_exists(cfg):
        batch = f"delete table inet {table}\n{rules}"
    run(["nft", "-c", "-f", "-"], input_text=batch)
    run(["nft", "-f", "-"], input_text=batch)
    return True


def normalized_rule(line):
    return " ".join(line.strip().split())


def expected_chain_lines(cfg):
    ports = " ".join(nft_port_expr(parse_ports(cfg["PORTS"])).split())
    priority = int(cfg["PRIORITY"])
    lines = [
        f"type filter hook input priority {priority}; policy accept;",
        'iifname "lo" accept',
        f"tcp dport {ports} ip saddr @{cfg['SET4']} accept",
        f"tcp dport {ports} ip6 saddr @{cfg['SET6']} accept",
    ]
    if bool_config(cfg.get("MANAGE_UDP", "1")):
        lines.extend([
            f"udp dport {ports} ip saddr @{cfg['SET4']} accept",
            f"udp dport {ports} ip6 saddr @{cfg['SET6']} accept",
            f"udp dport {ports} drop",
        ])
    lines.append(f"tcp dport {ports} drop")
    return [normalized_rule(line) for line in lines]


def listed_chain_lines(cfg):
    proc = run(["nft", "list", "chain", "inet", cfg["TABLE"], cfg["CHAIN"]], check=False)
    if proc.returncode != 0:
        return None
    lines = []
    in_chain = False
    for raw in proc.stdout.splitlines():
        line = raw.strip()
        if line == f"chain {cfg['CHAIN']} {{":
            in_chain = True
            continue
        if not in_chain:
            continue
        if line == "}":
            break
        if line:
            lines.append(normalized_rule(line))
    return lines


def set_has_timeout(cfg, set_name, expected_type):
    proc = run(["nft", "list", "set", "inet", cfg["TABLE"], set_name], check=False)
    if proc.returncode != 0:
        return False
    lines = {normalized_rule(line) for line in proc.stdout.splitlines()}
    return f"type {expected_type}" in lines and "flags timeout" in lines


def check_rules(cfg):
    if not table_complete(cfg):
        return False
    if not set_has_timeout(cfg, cfg["SET4"], "ipv4_addr"):
        return False
    if not set_has_timeout(cfg, cfg["SET6"], "ipv6_addr"):
        return False
    return listed_chain_lines(cfg) == expected_chain_lines(cfg)


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
    if not os.path.exists(path):
        return {"4": {}, "6": {}}
    try:
        with open(path, "r", encoding="utf-8") as f:
            state = json.load(f)
    except json.JSONDecodeError as exc:
        raise ValueError(f"state file is not valid JSON: {path}") from exc
    except OSError as exc:
        raise ValueError(f"cannot read state file: {path}") from exc
    if not isinstance(state, dict):
        raise ValueError(f"state file must contain an object: {path}")
    for fam in ("4", "6"):
        if fam not in state:
            state[fam] = {}
        elif not isinstance(state[fam], dict):
            raise ValueError(f"state file has invalid {fam} family map: {path}")
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
    parser.add_argument("--check-rules", action="store_true", help="verify the active nft guard shape")
    parser.add_argument("--print-config", action="store_true")
    args = parser.parse_args()

    cfg = load_config(CONFIG_PATH)
    validate_config(cfg)
    domains = configured_domains(cfg)
    if args.check_rules:
        if check_rules(cfg):
            print("guard rules match expected configuration")
            return 0
        print("guard rules do not match expected configuration", file=sys.stderr)
        return 3
    if args.print_config:
        print(json.dumps({**cfg, "DOMAINS": domains}, indent=2, sort_keys=True))
        return 0

    now = int(time.time())
    state_path = cfg["STATE_FILE"]
    state = validate_state(load_state(state_path), now)
    if args.init_only:
        created = ensure_table(cfg, force=args.force_table)
        apply_sets(cfg, state, now)
        print(
            f"guard table ready: table={cfg['TABLE']} created={created} "
            f"restored_ipv4={','.join(sorted(state['4'])) or '-'} "
            f"restored_ipv6={','.join(sorted(state['6'])) or '-'}"
        )
        return 0

    resolvers = split_words(cfg["RESOLVERS"])
    if not resolvers:
        resolvers = [""]
    resolved, details = resolve_domains(domains, resolvers)
    resolved_count = len(resolved["4"]) + len(resolved["6"])
    if resolved_count == 0:
        if state["4"] or state["6"]:
            grace = int(cfg["GRACE_SECONDS"])
            expiry = now + grace
            for fam in ("4", "6"):
                for ip in list(state[fam]):
                    state[fam][ip] = expiry
            ensure_table(cfg, force=False)
            save_state(state_path, state)
            apply_sets(cfg, state, now)
            print(
                f"WARNING: no valid A/AAAA records resolved for {', '.join(domains)}; "
                f"extended stale allowlist for {grace}s",
                file=sys.stderr,
            )
            return 0
        print(
            f"ERROR: no valid A/AAAA records resolved for {', '.join(domains)}; no existing state to restore",
            file=sys.stderr,
        )
        return 2

    grace = int(cfg["GRACE_SECONDS"])
    expiry = now + grace
    for fam in ("4", "6"):
        for ip in resolved[fam]:
            state[fam][ip] = expiry
    state = validate_state(state, now)
    ensure_table(cfg, force=args.force_table)
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
  load_effective_config
  validate_effective_config

  if [ -f "$CONFIG" ]; then
    local old new
    old="$(mktemp)"
    new="$(mktemp)"
    cp -a "$CONFIG" "$old"
    cat > "$new" <<EOF
# Dynamic source allowlist for x-ui / 3x-ui panel ports.
# The updater resolves these DDNS names and allows current and recent IPs only.
DDNS_DOMAINS="$EFFECTIVE_DDNS_DOMAINS"
PORTS="$EFFECTIVE_PORTS"
RESOLVERS="$EFFECTIVE_RESOLVERS"
GRACE_SECONDS="$EFFECTIVE_GRACE_SECONDS"
INTERVAL_SECONDS="$EFFECTIVE_INTERVAL_SECONDS"
TABLE="$EFFECTIVE_TABLE"
SET4="$EFFECTIVE_SET4"
SET6="$EFFECTIVE_SET6"
CHAIN="$EFFECTIVE_CHAIN"
PRIORITY="$EFFECTIVE_PRIORITY"
MANAGE_UDP="$EFFECTIVE_MANAGE_UDP"
STATE_FILE="$EFFECTIVE_STATE_FILE"
EOF
    if ! cmp -s "$old" "$new"; then
      cp -a "$CONFIG" "$CONFIG.bak-$(date +%s)"
      cat "$new" > "$CONFIG"
    fi
    rm -f "$old" "$new"
    chmod 0644 "$CONFIG"
    return 0
  fi

  cat > "$CONFIG" <<EOF
# Dynamic source allowlist for x-ui / 3x-ui panel ports.
# The updater resolves these DDNS names and allows current and recent IPs only.
DDNS_DOMAINS="$EFFECTIVE_DDNS_DOMAINS"
PORTS="$EFFECTIVE_PORTS"
RESOLVERS="$EFFECTIVE_RESOLVERS"
GRACE_SECONDS="$EFFECTIVE_GRACE_SECONDS"
INTERVAL_SECONDS="$EFFECTIVE_INTERVAL_SECONDS"
TABLE="$EFFECTIVE_TABLE"
SET4="$EFFECTIVE_SET4"
SET6="$EFFECTIVE_SET6"
CHAIN="$EFFECTIVE_CHAIN"
PRIORITY="$EFFECTIVE_PRIORITY"
MANAGE_UDP="$EFFECTIVE_MANAGE_UDP"
STATE_FILE="$EFFECTIVE_STATE_FILE"
EOF
  chmod 0644 "$CONFIG"
}

write_systemd_units() {
  load_effective_config
  validate_effective_config
  local interval="$EFFECTIVE_INTERVAL_SECONDS"

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
After=local-fs.target nftables.service
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
  load_effective_config
  validate_effective_config
  local ports="$EFFECTIVE_PORTS"
  local port
  for port in $ports; do
    ufw allow "$port" >/dev/null || true
  done
}

warn_ufw_status() {
  if ! have_cmd ufw; then
    echo "not installed"
    return 0
  fi
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "active"
  else
    echo "inactive"
  fi
}

print_install_summary() {
  local timer_unit
  timer_unit="$(basename "$TIMER")"
  load_effective_config
  validate_effective_config

  echo
  echo "xui-ddns-allowlist installed"
  echo "==========================="
  printf "Protected ports:  %s\n" "$EFFECTIVE_PORTS"
  printf "DDNS domains:     %s\n" "$EFFECTIVE_DDNS_DOMAINS"
  printf "Timer:            %s, %s\n" "$(systemctl is-active "$timer_unit" 2>/dev/null || true)" "$(systemctl is-enabled "$timer_unit" 2>/dev/null || true)"
  printf "UFW:              %s\n" "$(warn_ufw_status)"
  printf "Config:           %s\n" "$CONFIG"
  echo
  echo "Allowed source IPs"
  echo "------------------"
  python3 - "$EFFECTIVE_TABLE" "$EFFECTIVE_SET4" "$EFFECTIVE_SET6" <<'PYEOF'
import re
import subprocess
import sys

table, set4, set6 = sys.argv[1:4]

def show(label, set_name):
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
    rows = re.findall(r"((?:\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F:]{2,})\s+timeout\s+\S+\s+expires\s+([^,}]+)", text)
    if not rows:
        print(f"  {label}: none")
    else:
        for ip, expires in rows:
            print(f"  {label}: {ip:<39} expires in {expires.strip()}")

show("IPv4", set4)
show("IPv6", set6)
PYEOF
  echo
  echo "Check later:"
  echo "  sudo bash install-xui-ddns-allowlist.sh --status"
}

install_all() {
  require_root
  require_systemd_running
  install_packages_if_needed
  install -d -m 0700 "$STATE_DIR"
  write_updater
  write_config
  write_systemd_units
  maybe_ensure_ufw_allow
  systemctl daemon-reload
  "$UPDATER" --force-table
  systemctl enable --now "$(basename "$INIT_SERVICE")" "$(basename "$TIMER")"
  print_install_summary
}

uninstall_all() {
  require_root
  local table
  table="$(config_get TABLE "$DEFAULT_TABLE")"
  systemctl disable --now "$(basename "$TIMER")" "$(basename "$INIT_SERVICE")" >/dev/null 2>&1 || true
  systemctl stop "$(basename "$SERVICE")" >/dev/null 2>&1 || true
  nft delete table inet "$table" >/dev/null 2>&1 || true
  rm -f "$UPDATER" "$SERVICE" "$TIMER" "$INIT_SERVICE"
  systemctl daemon-reload
  echo "Uninstalled $SCRIPT_NAME. Config and state were kept:"
  echo "  $CONFIG"
  echo "  $STATE_DIR"
  echo "UFW rules were not changed. If UFW allows the panel port, it may now be public."
  echo "Remove them manually if no longer needed."
}

status_all() {
  require_root
  load_effective_config
  validate_effective_config
  local table="$EFFECTIVE_TABLE"
  local set4="$EFFECTIVE_SET4"
  local set6="$EFFECTIVE_SET6"
  local ports="$EFFECTIVE_PORTS"
  local domains="$EFFECTIVE_DDNS_DOMAINS"
  local resolvers="$EFFECTIVE_RESOLVERS"
  local grace="$EFFECTIVE_GRACE_SECONDS"
  local manage_udp="$EFFECTIVE_MANAGE_UDP"

  local timer_unit service_unit guard_state guard_rules timer_state timer_enabled next_timer last_log first_resolver
  timer_unit="$(basename "$TIMER")"
  service_unit="$(basename "$SERVICE")"
  if nft list table inet "$table" >/dev/null 2>&1; then
    guard_state="active"
  else
    guard_state="missing"
  fi
  if [ -x "$UPDATER" ] && "$UPDATER" --check-rules >/dev/null 2>&1; then
    guard_rules="expected"
  else
    guard_rules="needs attention"
  fi

  timer_state="$(systemctl is-active "$timer_unit" 2>/dev/null || true)"
  timer_enabled="$(systemctl is-enabled "$timer_unit" 2>/dev/null || true)"
  next_timer="$(systemctl list-timers --no-pager --all "$timer_unit" 2>/dev/null | awk 'NR==2 {print $1, $2, $3, $4, $5}')"
  last_log="$(journalctl -u "$service_unit" -n 40 -o cat --no-pager 2>/dev/null | grep -E 'updated allowlist|ERROR:' | tail -n 1 || true)"
  first_resolver="$(normalize_list "$resolvers" | awk '{print $1}')"

  echo "xui-ddns-allowlist status"
  echo "========================="
  printf "Guard:            %s, rules %s (nft table inet %s)\n" "$guard_state" "$guard_rules" "$table"
  printf "Protected ports:  %s/tcp" "$(normalize_list "$ports")"
  if is_truthy "$manage_udp"; then
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
  echo "Firewall context"
  echo "----------------"
  if have_cmd ufw; then
    printf "  UFW: %s\n" "$(warn_ufw_status)"
    echo "  Note: this tool only manages nft table inet $table."
  else
    echo "  UFW: not installed"
    echo "  Note: this tool only manages nft table inet $table."
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
