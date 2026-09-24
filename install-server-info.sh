#!/usr/bin/env bash
#
# install-server-info.sh
# Install a curated set of CLI tools for inspecting/monitoring a server:
# hardware, sensors, disks, network, processes, and general system info.
# Intended to be run as root on Debian/Ubuntu.
#
# Usage: sudo ./install-server-info.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

# --- package list -----------------------------------------------------------
# Format: "category:package1 package2 ..."
CATEGORIES=(
  "system info:fastfetch inxi neofetch screenfetch"
  "hardware:hwinfo lshw dmidecode pciutils usbutils cpuid"
  "sensors:lm-sensors hddtemp nvme-cli smartmontools"
  "cpu/mem:sysstat procinfo s-tui cpufrequtils"
  "disks:parted gdisk fdisk util-linux ncdu duf tree"
  "processes:htop btop glances iotop-c iotop nmon atop lsof strace"
  "network:net-tools dnsutils traceroute mtr-tiny iftop nethogs bmon ethtool iptraf-ng tcpdump nmap"
  "utils:jq curl wget git tmux screen vim nano unzip zip psmisc pv"
  "bench:stress-ng sysbench"
  "power:powertop"
)

# --- gather every package into one list -------------------------------------
ALL_PKGS=()
for entry in "${CATEGORIES[@]}"; do
  read -ra pkgs <<< "${entry#*:}"
  ALL_PKGS+=("${pkgs[@]}")
done

echo "==> Updating package index"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# --- keep only packages that actually exist in the repos --------------------
AVAILABLE=()
MISSING=()
for pkg in "${ALL_PKGS[@]}"; do
  if apt-cache show "$pkg" >/dev/null 2>&1; then
    AVAILABLE+=("$pkg")
  else
    MISSING+=("$pkg")
  fi
done

echo "==> Installing ${#AVAILABLE[@]} packages (skipping ${#MISSING[@]} unavailable)"
if ((${#AVAILABLE[@]})); then
  apt-get install -y --no-install-recommends "${AVAILABLE[@]}"
fi

# --- post-install tweaks ----------------------------------------------------
if command -v sensors >/dev/null 2>&1 && [[ ! -f /etc/sensors.d/.configured ]]; then
  echo "==> Running sensors-detect (non-interactive)"
  mkdir -p /etc/sensors.d
  yes | sensors-detect >/dev/null 2>&1 || true
  touch /etc/sensors.d/.configured
fi

# Enable sysstat data collection if present
if [[ -f /etc/default/sysstat ]]; then
  sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
  systemctl enable --now sysstat 2>/dev/null || true
fi

# --- summary ----------------------------------------------------------------
echo
echo "==> Installed:"
for entry in "${CATEGORIES[@]}"; do
  cat_name="${entry%%:*}"
  printf '  %-12s ' "$cat_name"
  found=0
  for pkg in ${entry#*:}; do
    if [[ " ${AVAILABLE[*]} " == *" $pkg "* ]]; then
      printf '%s ' "$pkg"; found=1
    fi
  done
  ((found)) || printf '(none)'
  echo
done

if ((${#MISSING[@]})); then
  echo
  echo "==> Not available in repos (skipped): ${MISSING[*]}"
fi

echo
echo "Try: fastfetch | inxi -Fz | htop | btop | glances | sensors | smartctl -a /dev/sda"
