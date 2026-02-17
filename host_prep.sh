#!/usr/bin/env bash
set -euo pipefail

TAG="nspawn-demo"
BR="br0"
GW_CIDR="10.200.0.1/24"
SUBNET="10.200.0.0/24"
SYSCTL_FILE="/etc/sysctl.d/99-nspawn-demo.conf"

JUMP_USER="${1:-jump}"
CREATE_JUMP_USER="${CREATE_JUMP_USER:-1}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)."
  exit 1
fi

apt-get update
apt-get install -y debootstrap systemd-container iptables openssh-server bridge-utils

if ! ip link show "$BR" >/dev/null 2>&1; then
  ip link add "$BR" type bridge
fi

if ! ip -4 addr show dev "$BR" | grep -q "10.200.0.1/24"; then
  ip addr flush dev "$BR" || true
  ip addr add "$GW_CIDR" dev "$BR"
fi

ip link set "$BR" up

echo "net.ipv4.ip_forward=1" > "$SYSCTL_FILE"
sysctl -p "$SYSCTL_FILE" >/dev/null

EXT_IF="$(ip route | awk '/^default/{print $5; exit}')"
[[ -n "$EXT_IF" ]] || { echo "Could not determine external interface."; exit 1; }

iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$EXT_IF" -m comment --comment "$TAG" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$EXT_IF" -m comment --comment "$TAG" -j MASQUERADE

iptables -C FORWARD -i "$BR" -o "$EXT_IF" -m comment --comment "$TAG" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$BR" -o "$EXT_IF" -m comment --comment "$TAG" -j ACCEPT

iptables -C FORWARD -i "$EXT_IF" -o "$BR" -m state --state RELATED,ESTABLISHED -m comment --comment "$TAG" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$EXT_IF" -o "$BR" -m state --state RELATED,ESTABLISHED -m comment --comment "$TAG" -j ACCEPT

if [[ "$CREATE_JUMP_USER" == "1" ]]; then
  if ! id -u "$JUMP_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$JUMP_USER"
  fi
  install -d -m 700 -o "$JUMP_USER" -g "$JUMP_USER" "/home/$JUMP_USER/.ssh"
  touch "/home/$JUMP_USER/.ssh/authorized_keys"
  chown "$JUMP_USER:$JUMP_USER" "/home/$JUMP_USER/.ssh/authorized_keys"
  chmod 600 "/home/$JUMP_USER/.ssh/authorized_keys"
fi

echo "Host prep complete. Bridge=$BR GW=10.200.0.1 EXT_IF=$EXT_IF JumpUser=$JUMP_USER"