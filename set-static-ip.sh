#!/usr/bin/env bash
#
# set-static-ip.sh
# Convert a DHCP interface to a static IP using netplan.
#
# Modes:
#   auto   (default)  reuse the current DHCP address/gateway/DNS
#   manual            pass --ip / --gateway / --dns (or a positional CIDR)
#
# Safety: applies the config, then schedules an automatic rollback via a
# transient systemd timer. Confirm within --timeout seconds to keep it,
# otherwise the previous config is restored. This protects SSH sessions.
#
# Usage:
#   sudo ./set-static-ip.sh                          # auto, current addr
#   sudo ./set-static-ip.sh 10.0.0.50/24             # auto gw/dns
#   sudo ./set-static-ip.sh --ip 10.0.0.50/24 --gateway 10.0.0.1 --dns 10.0.0.1,1.1.1.1
#   sudo ./set-static-ip.sh --interface enp0s25 --ip 10.0.0.50/24
#   sudo ./set-static-ip.sh --timeout 120
#   sudo ./set-static-ip.sh --revert                 # restore last backup
#
set -euo pipefail

# --- defaults ---------------------------------------------------------------
IFACE=""
CIDR=""
GATEWAY=""
DNS=""
TIMEOUT=60
REVERT=0
NO_DHCP6=0
ORIGIN_HINT="99-static-ip"
BACKUP_ROOT="/etc/netplan/backups"
RUN_DIR="/run/set-static-ip"
ROLLBACK_UNIT="static-ip-rollback"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# --- arg parsing ------------------------------------------------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interface|-i) IFACE="$2"; shift 2 ;;
    --ip)           CIDR="$2"; shift 2 ;;
    --gateway|-g)   GATEWAY="$2"; shift 2 ;;
    --dns|-d)       DNS="$2"; shift 2 ;;
    --timeout|-t)   TIMEOUT="$2"; shift 2 ;;
    --no-dhcp6)     NO_DHCP6=1; shift ;;
    --revert)       REVERT=1; shift ;;
    --yes|-y)       TIMEOUT=0; shift ;;   # skip confirmation, keep immediately
    -h|--help)      usage ;;
    -*)             die "Unknown option: $1" ;;
    *)              POSITIONAL+=("$1"); shift ;;
  esac
done
if ((${#POSITIONAL[@]})); then
  [[ -z "$CIDR" ]] && CIDR="${POSITIONAL[0]}" || die "Unexpected argument: ${POSITIONAL[0]}"
fi

[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"

# --- revert mode ------------------------------------------------------------
if ((REVERT)); then
  latest="$(ls -1dt "${BACKUP_ROOT}"/*/ 2>/dev/null | head -1 || true)"
  [[ -n "$latest" ]] || die "No backup found under ${BACKUP_ROOT}"
  log "Restoring netplan config from ${latest}"
  rm -f "/etc/netplan/${ORIGIN_HINT}.yaml"
  cp -a "${latest}"*.yaml /etc/netplan/ 2>/dev/null || true
  netplan generate
  netplan apply
  log "Reverted. Current addresses:"
  ip -4 -o addr show scope global | awk '{print "   " $2, $4}'
  exit 0
fi

# --- detect interface -------------------------------------------------------
if [[ -z "$IFACE" ]]; then
  IFACE="$(ip -4 route show default | awk '{print $5; exit}')"
fi
[[ -n "$IFACE" ]] || die "Could not detect a default interface; pass --interface"
[[ -e "/sys/class/net/${IFACE}" ]] || die "Interface ${IFACE} does not exist"

# --- gather current network info -------------------------------------------
cur_cidr="$(ip -4 -o addr show dev "$IFACE" scope global | awk '{print $4; exit}')"
[[ -n "$cur_cidr" ]] || die "Interface ${IFACE} has no IPv4 address"
cur_gw="$(ip -4 route show default dev "$IFACE" | awk '/^default/{print $3; exit}')"
cur_dns="$(resolvectl dns "$IFACE" 2>/dev/null | sed 's/.*: *//' | tr ' ' '\n' \
           | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | paste -sd, - || true)"

CIDR="${CIDR:-$cur_cidr}"
GATEWAY="${GATEWAY:-$cur_gw}"
DNS="${DNS:-${cur_dns:-1.1.1.1}}"

# --- validate ---------------------------------------------------------------
python3 - "$CIDR" <<'PY' || die "Invalid --ip (expected CIDR, e.g. 10.0.0.50/24)"
import ipaddress, sys
ipaddress.ip_interface(sys.argv[1])
PY
[[ -n "$GATEWAY" ]] || die "No gateway detected; pass --gateway"
python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$GATEWAY" \
  || die "Invalid --gateway: $GATEWAY"

IFACE_ADDR="${CIDR%%/*}"
log "Interface : ${IFACE}"
log "Static IP : ${CIDR}"
log "Gateway   : ${GATEWAY}"
log "DNS       : ${DNS}"

if [[ -e "/sys/class/net/${IFACE}/wireless" ]]; then
  warn "This is a WiFi interface. A DHCP reservation on your router is usually"
  warn "more reliable than a static IP for WiFi servers."
fi

# --- find the netplan section for this interface ----------------------------
section="$(netplan get all 2>/dev/null | python3 -c '
import sys, yaml
try:
    d = yaml.safe_load(sys.stdin) or {}
except Exception:
    d = {}
net = d.get("network", d)
iface = sys.argv[1]
for sec in ("ethernets", "wifis", "bridges", "bonds", "vlans"):
    if iface in (net.get(sec) or {}):
        print(sec); sys.exit(0)
sys.exit(1)
' "$IFACE" 2>/dev/null || true)"

if [[ -z "$section" ]]; then
  if [[ -e "/sys/class/net/${IFACE}/wireless" ]]; then section="wifis"; else section="ethernets"; fi
  warn "Interface not found in netplan config; assuming section '${section}'"
fi
log "Netplan section: network.${section}.${IFACE}"

# --- backup -----------------------------------------------------------------
ts="$(date +%Y%m%d-%H%M%S)"
backup_dir="${BACKUP_ROOT}/${ts}"
mkdir -p "$backup_dir"
cp -a /etc/netplan/*.yaml "$backup_dir"/ 2>/dev/null || true
log "Backed up /etc/netplan/*.yaml -> ${backup_dir}"

# --- build rollback script --------------------------------------------------
mkdir -p "$RUN_DIR"
cat > "${RUN_DIR}/rollback.sh" <<EOF
#!/usr/bin/env bash
set -e
echo "[\$(date)] Rolling back static IP config (not confirmed in time)" >&2
rm -f "/etc/netplan/${ORIGIN_HINT}.yaml"
cp -a "${backup_dir}"/*.yaml /etc/netplan/ 2>/dev/null || true
netplan generate
netplan apply
echo "[\$(date)] Rollback complete" >&2
EOF
chmod +x "${RUN_DIR}/rollback.sh"

# --- apply ------------------------------------------------------------------
# Normalize DNS into a valid YAML flow list: "a,b" / "a b" -> [a, b]
read -ra _dns_arr <<< "${DNS//,/ }"
for _d in "${_dns_arr[@]}"; do
  python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$_d" \
    || die "Invalid DNS server: $_d"
done
dns_joined="$(printf '%s, ' "${_dns_arr[@]}")"
dns_joined="${dns_joined%, }"
dns_list="[${dns_joined}]"
log "Writing static config"
netplan set --origin-hint "$ORIGIN_HINT" "network.${section}.${IFACE}.dhcp4=false"
netplan set --origin-hint "$ORIGIN_HINT" "network.${section}.${IFACE}.addresses=[${CIDR}]"
netplan set --origin-hint "$ORIGIN_HINT" "network.${section}.${IFACE}.routes=[{to: default, via: ${GATEWAY}}]"
netplan set --origin-hint "$ORIGIN_HINT" "network.${section}.${IFACE}.nameservers.addresses=${dns_list}"
if ((NO_DHCP6)); then
  netplan set --origin-hint "$ORIGIN_HINT" "network.${section}.${IFACE}.dhcp6=false"
fi

netplan generate
log "Applying config (network may briefly drop)"
netplan apply

# --- schedule rollback watchdog --------------------------------------------
if ((TIMEOUT > 0)); then
  systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
  systemctl reset-failed "${ROLLBACK_UNIT}.service" 2>/dev/null || true
  if systemd-run --on-active="${TIMEOUT}s" --unit="${ROLLBACK_UNIT}" \
       --description="Auto-rollback static IP if not confirmed" \
       "${RUN_DIR}/rollback.sh" >/dev/null 2>&1; then
    log "Auto-rollback scheduled in ${TIMEOUT}s"
  else
    warn "systemd-run failed; using background watchdog"
    nohup bash -c "sleep ${TIMEOUT}; ${RUN_DIR}/rollback.sh" >/dev/null 2>&1 &
  fi
fi

# --- confirm ----------------------------------------------------------------
printf '\n'
printf 'New address should be %s. Keep this configuration? [y/N] ' "$IFACE_ADDR"
answer=""
if [[ -r /dev/tty ]] && ((TIMEOUT > 0)); then
  IFS= read -r -t "$TIMEOUT" answer < /dev/tty || answer=""
elif ((TIMEOUT > 0)); then
  warn "No TTY available; waiting ${TIMEOUT}s for rollback"
  sleep "$TIMEOUT"
fi

case "$answer" in
  y|Y|yes|YES)
    log "Confirmed. Cancelling rollback."
    systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null || true
    systemctl reset-failed "${ROLLBACK_UNIT}.service" 2>/dev/null || true
    rm -f "${RUN_DIR}/rollback.sh"
    log "Static IP ${CIDR} is now permanent. Backup kept at ${backup_dir}"
    ;;
  *)
    log "Not confirmed. Rolling back now..."
    "${RUN_DIR}/rollback.sh"
    ;;
esac

echo
echo "Current addresses:"
ip -4 -o addr show scope global | awk '{print "   " $2, $4}'
