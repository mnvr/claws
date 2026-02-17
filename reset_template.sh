#!/usr/bin/env bash
set -euo pipefail

TEMPLATE="/var/lib/machines/.template"
TMP="template-build"
TMP_MACHINE="/var/lib/machines/${TMP}"
TMP_NSPAWN="/etc/systemd/nspawn/${TMP}.nspawn"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)."
  exit 1
fi

echo "Resetting template state..."

# Stop temporary template builder if present.
machinectl stop "$TMP" 2>/dev/null || true
machinectl terminate "$TMP" 2>/dev/null || true
systemctl stop "systemd-nspawn@${TMP}.service" 2>/dev/null || true

# Remove temporary builder config and any stale machine path.
rm -f "$TMP_NSPAWN" || true
if [[ -d "$TMP_MACHINE" && ! -L "$TMP_MACHINE" ]]; then
  rm -rf "$TMP_MACHINE"
else
  rm -f "$TMP_MACHINE" || true
fi

# Remove reusable template rootfs; it will be rebuilt on next create run.
rm -rf "$TEMPLATE" || true

systemctl daemon-reload || true

echo "Template reset complete."
echo "Next run will rebuild it:"
echo "  sudo ./create_machines.sh"
