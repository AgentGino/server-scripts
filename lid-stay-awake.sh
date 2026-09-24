#!/usr/bin/env bash
#
# lid-stay-awake.sh
# Keep a laptop running as a server: ignore lid close, never suspend/hibernate,
# and disable GNOME idle-suspend. Intended to be run as root.
#
# Usage: sudo ./lid-stay-awake.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

echo "==> Configuring systemd-logind to ignore lid switch"
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-lid.conf <<'EOF'
[Login]
# Keep running with the lid closed (server use)
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
# Don't sleep on idle
IdleAction=ignore
EOF

echo "==> Masking sleep/hibernate targets"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo "==> Restarting systemd-logind"
systemctl restart systemd-logind

echo "==> Disabling GNOME idle suspend (for every logged-in user)"
for user in $(loginctl list-users --no-legend | awk '{print $2}'); do
  uid=$(id -u "$user" 2>/dev/null) || continue
  runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
  runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null || true
done

echo
echo "==> Done. Verify:"
echo "    cat /proc/acpi/button/lid/*/state   # 'closed' when shut"
echo "    uptime                              # should keep climbing"
echo "    journalctl -u systemd-logind -b | grep -i lid"
