#!/usr/bin/env bash
set -euo pipefail

NAME="${1:-}"
IP_MAP="/var/lib/machines/.ip-map"

if [[ -z "$NAME" ]]; then
  echo "Usage: $0 <machine-name>"
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)."
  exit 1
fi

echo "Removing machine: $NAME"

# Stop/terminate if running (ignore errors)
machinectl stop "$NAME" 2>/dev/null || true
machinectl terminate "$NAME" 2>/dev/null || true
systemctl stop "systemd-nspawn@${NAME}.service" 2>/dev/null || true

# Remove rootfs and nspawn config
rm -rf "/var/lib/machines/$NAME"
rm -f "/etc/systemd/nspawn/${NAME}.nspawn"

# Remove IP mapping entry (if present)
if [[ -f "$IP_MAP" ]]; then
  awk -v n="$NAME" '$1 != n' "$IP_MAP" > "${IP_MAP}.tmp"
  mv "${IP_MAP}.tmp" "$IP_MAP"
  chmod 600 "$IP_MAP" || true
fi

systemctl daemon-reload || true

echo "Removed: $NAME"
echo "You can now rerun: sudo ./create_machines.sh"