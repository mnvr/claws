#!/usr/bin/env bash
set -euo pipefail

TAG="nspawn-demo"
BR="br0"
SYSCTL_FILE="/etc/sysctl.d/99-nspawn-demo.conf"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)."
  exit 1
fi

machines=()
if [[ -f "./machines.txt" ]]; then
  while read -r name rest; do
    [[ -z "${name:-}" ]] && continue
    [[ "${name:0:1}" == "#" ]] && continue
    machines+=("$name")
  done < ./machines.txt
else
  machines=("demo" "demo2")
fi

for m in "${machines[@]}"; do
  machinectl stop "$m" 2>/dev/null || true
  machinectl terminate "$m" 2>/dev/null || true
  systemctl stop "systemd-nspawn@${m}.service" 2>/dev/null || true
done

for m in "${machines[@]}"; do
  rm -rf "/var/lib/machines/${m}" || true
  rm -f "/etc/systemd/nspawn/${m}.nspawn" || true
done

systemctl daemon-reload || true

rm -f "$SYSCTL_FILE" || true
sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true

while iptables -t nat -S | grep -q -- "--comment ${TAG}"; do
  rule=$(iptables -t nat -S | grep -- "--comment ${TAG}" | head -n1)
  iptables -t nat ${rule/-A/-D} || true
done

while iptables -S | grep -q -- "--comment ${TAG}"; do
  rule=$(iptables -S | grep -- "--comment ${TAG}" | head -n1)
  iptables ${rule/-A/-D} || true
done

if ip link show "$BR" >/dev/null 2>&1; then
  ip link set "$BR" down || true
  ip link del "$BR" type bridge || true
fi

echo "Cleanup complete."