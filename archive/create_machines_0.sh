#!/usr/bin/env bash
set -euo pipefail

BR="br0"
BASE_IP_PREFIX="10.200.0."
BASE_IP_START=10
DNS1="1.1.1.1"
DNS2="8.8.8.8"

MACHINES_FILE="${1:-./machines.txt}"
JUMP_USER="${2:-jump}"  # host user whose authorized_keys will be updated
USE_JUMP_USER="${USE_JUMP_USER:-1}" # set 0 to add keys to current sudo user instead

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)."
  exit 1
fi

if [[ ! -f "$MACHINES_FILE" ]]; then
  echo "Missing $MACHINES_FILE"
  exit 1
fi

# Ensure bridge exists
ip link show "$BR" >/dev/null 2>&1 || { echo "Bridge $BR missing. Run host_prep.sh first."; exit 1; }

# Choose which host account gets keys
HOST_AUTH_KEYS=""
if [[ "$USE_JUMP_USER" == "1" ]]; then
  if ! id -u "$JUMP_USER" >/dev/null 2>&1; then
    echo "Jump user $JUMP_USER does not exist. Run host_prep.sh or set USE_JUMP_USER=0."
    exit 1
  fi
  HOST_AUTH_KEYS="/home/$JUMP_USER/.ssh/authorized_keys"
else
  # Add to the user who invoked sudo
  SUDO_USER_NAME="${SUDO_USER:-}"
  if [[ -z "$SUDO_USER_NAME" ]]; then
    echo "USE_JUMP_USER=0 requires sudo invocation so SUDO_USER is set."
    exit 1
  fi
  HOST_AUTH_KEYS="/home/$SUDO_USER_NAME/.ssh/authorized_keys"
fi

install -d -m 700 -o "$(stat -c %u "$(dirname "$HOST_AUTH_KEYS")")" -g "$(stat -c %g "$(dirname "$HOST_AUTH_KEYS")")" "$(dirname "$HOST_AUTH_KEYS")" 2>/dev/null || true
touch "$HOST_AUTH_KEYS"
chmod 600 "$HOST_AUTH_KEYS"

# Helper: resolve "key" field to actual public key line
resolve_key() {
  local k="$1"
  if [[ -f "$k" ]]; then
    cat "$k"
  else
    echo "$k"
  fi
}

# Helper: append key to host authorized_keys if absent
add_key_to_host() {
  local pub="$1"
  grep -qxF "$pub" "$HOST_AUTH_KEYS" 2>/dev/null || echo "$pub" >> "$HOST_AUTH_KEYS"
}

# Main loop
idx=0
while read -r name keyfield; do
  [[ -z "${name:-}" ]] && continue
  [[ "${name:0:1}" == "#" ]] && continue
  [[ -z "${keyfield:-}" ]] && { echo "Skipping $name: missing key"; continue; }

  pubkey="$(resolve_key "$keyfield")"

  add_key_to_host "$pubkey"

  # Skip if machine exists
  if [[ -d "/var/lib/machines/$name" ]]; then
    echo "Exists, skipping: $name"
    idx=$((idx+1))
    continue
  fi

  ip_last=$((BASE_IP_START + idx))
  ip_addr="${BASE_IP_PREFIX}${ip_last}"

  echo "Creating $name @ $ip_addr"

  mkdir -p "/var/lib/machines/$name"
  debootstrap stable "/var/lib/machines/$name" http://deb.debian.org/debian

  mkdir -p /etc/systemd/nspawn
  cat > "/etc/systemd/nspawn/${name}.nspawn" <<EOF
[Exec]
Boot=yes
PrivateUsers=no

[Network]
Bridge=${BR}
EOF

  cat > "/var/lib/machines/$name/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto host0
iface host0 inet static
    address ${ip_addr}
    netmask 255.255.255.0
    gateway 10.200.0.1
EOF

  cat > "/var/lib/machines/$name/etc/resolv.conf" <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
EOF

  systemctl daemon-reload
  machinectl start "$name"

  # Enter running container via nsenter (no DBus dependency)
  PID="$(machinectl show "$name" -p Leader --value)"
  nsenter -t "$PID" -m -u -i -n -p /bin/bash <<'INCHROOT'
set -euo pipefail

# Ensure apt isn't blocked by missing /etc/resolv.conf (already set in rootfs)
apt update
apt install -y openssh-server

# Root key-only SSH
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config

mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

systemctl enable --now ssh
systemctl restart ssh
INCHROOT

  # Add the pubkey to container root authorized_keys (do this from host to avoid quoting issues)
  echo "$pubkey" >> "/var/lib/machines/$name/root/.ssh/authorized_keys"
  # de-dup within container file
  awk '!seen[$0]++' "/var/lib/machines/$name/root/.ssh/authorized_keys" > "/var/lib/machines/$name/root/.ssh/authorized_keys.tmp"
  mv "/var/lib/machines/$name/root/.ssh/authorized_keys.tmp" "/var/lib/machines/$name/root/.ssh/authorized_keys"
  chmod 600 "/var/lib/machines/$name/root/.ssh/authorized_keys"

  idx=$((idx+1))
done < "$MACHINES_FILE"

echo "Done."
echo "Host authorized_keys updated: $HOST_AUTH_KEYS"