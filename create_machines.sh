#!/usr/bin/env bash
set -euo pipefail

BR="br0"
BASE_IP_PREFIX="10.200.0."
BASE_IP_START=10
GW_IP="10.200.0.1"
DNS1="1.1.1.1"
DNS2="8.8.8.8"

MACHINES_FILE="${1:-./machines.txt}"
JUMP_USER="${2:-jump}"
USE_JUMP_USER="${USE_JUMP_USER:-1}"

IP_MAP="/var/lib/machines/.ip-map"

# Template settings (enabled by default)
USE_TEMPLATE="${USE_TEMPLATE:-1}"
TEMPLATE="/var/lib/machines/.template"

# Base packages for demo machines (curl included)
BASE_PKGS=(
  openssh-server
  curl ca-certificates wget
  git jq
  unzip zip tar
  vim-tiny less
  procps iproute2 iputils-ping dnsutils
  netcat-openbsd
  lsof

  # Node runtime (Ubuntu 24 native)
  nodejs npm

  # Native build tooling (npm modules)
  build-essential
  cmake
  python3
  pkg-config
  tmux rsync
)

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)."
  exit 1
fi

[[ -f "$MACHINES_FILE" ]] || { echo "Missing $MACHINES_FILE"; exit 1; }
ip link show "$BR" >/dev/null 2>&1 || { echo "Bridge $BR missing. Run host_prep.sh first."; exit 1; }

if [[ "$USE_JUMP_USER" == "1" ]]; then
  TARGET_USER="$JUMP_USER"
else
  TARGET_USER="${SUDO_USER:-}"
  [[ -n "$TARGET_USER" ]] || { echo "USE_JUMP_USER=0 requires sudo so SUDO_USER is set."; exit 1; }
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || { echo "Cannot find home for user $TARGET_USER"; exit 1; }

HOST_SSH_DIR="$TARGET_HOME/.ssh"
HOST_AUTH_KEYS="$HOST_SSH_DIR/authorized_keys"

install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$HOST_SSH_DIR"
touch "$HOST_AUTH_KEYS"
chown "$TARGET_USER:$TARGET_USER" "$HOST_AUTH_KEYS"
chmod 600 "$HOST_AUTH_KEYS"

touch "$IP_MAP"
chmod 600 "$IP_MAP"

dedupe_append_line() {
  local line="$1"
  local file="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

get_or_assign_last_octet() {
  local name="$1"
  local existing
  existing="$(awk -v n="$name" '$1==n{print $2}' "$IP_MAP" | tail -n1 || true)"
  if [[ -n "$existing" ]]; then
    echo "$existing"
    return
  fi

  local max
  max="$(awk 'NF>=2{print $2}' "$IP_MAP" | sort -n | tail -n1 || true)"
  [[ -n "$max" ]] || max=$((BASE_IP_START - 1))
  local next=$((max + 1))
  echo "$name $next" >> "$IP_MAP"
  echo "$next"
}

build_template_if_needed() {
  [[ "$USE_TEMPLATE" == "1" ]] || return 0
  [[ -d "$TEMPLATE" ]] && return 0

  echo "Building template rootfs at $TEMPLATE"
  mkdir -p "$TEMPLATE"
  debootstrap stable "$TEMPLATE" http://deb.debian.org/debian

  # Per-template network config just to allow apt (IP doesn't matter much)
  cat > "$TEMPLATE/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto host0
iface host0 inet static
    address 10.200.0.250
    netmask 255.255.255.0
    gateway ${GW_IP}
EOF

  cat > "$TEMPLATE/etc/resolv.conf" <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
EOF

  # Boot template as a temporary machine to install packages once
  TMP="template-build"
  mkdir -p /etc/systemd/nspawn
  cat > "/etc/systemd/nspawn/${TMP}.nspawn" <<EOF
[Exec]
Boot=yes
PrivateUsers=no

[Network]
Bridge=${BR}
EOF

  systemctl daemon-reload
  machinectl start "$TMP"

  PID="$(machinectl show "$TMP" -p Leader --value)"
  nsenter -t "$PID" -m -u -i -n -p /bin/bash <<INCHROOT
set -euo pipefail
apt update
DEBIAN_FRONTEND=noninteractive apt install -y ${BASE_PKGS[*]}
sed -i 's/^#\\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl enable --now ssh
systemctl restart ssh
INCHROOT

  machinectl stop "$TMP" || true
  rm -f "/etc/systemd/nspawn/${TMP}.nspawn"
  systemctl daemon-reload

  echo "Template built."
}

copy_from_template_or_debootstrap() {
  local name="$1"
  if [[ "$USE_TEMPLATE" == "1" ]]; then
    cp -a --reflink=auto "$TEMPLATE" "/var/lib/machines/$name"
  else
    mkdir -p "/var/lib/machines/$name"
    debootstrap stable "/var/lib/machines/$name" http://deb.debian.org/debian
  fi
}

build_template_if_needed

# Parse: first token = name, remainder of line = key (handles tabs/multi-space/header/CRLF)
while IFS=$' \t' read -r name pubkey; do
  [[ -z "${name:-}" ]] && continue
  [[ "${name:0:1}" == "#" ]] && continue

  # Skip header like: "name key"
  if [[ "$name" == "name" && "${pubkey:-}" == "key"* ]]; then
    continue
  fi

  # Trim CR and leading whitespace in pubkey remainder
  pubkey="${pubkey//$'\r'/}"
  pubkey="${pubkey#"${pubkey%%[![:space:]]*}"}"

  if [[ -z "${pubkey:-}" ]]; then
    echo "Skipping $name: missing key"
    continue
  fi
  if [[ "$pubkey" != ssh-* ]]; then
    echo "Skipping $name: key does not start with ssh- (parsed as: '$pubkey')"
    continue
  fi

  # Add key to host (jump or sudo user)
  dedupe_append_line "$pubkey" "$HOST_AUTH_KEYS"

  last_octet="$(get_or_assign_last_octet "$name")"
  ip_addr="${BASE_IP_PREFIX}${last_octet}"

  if [[ -d "/var/lib/machines/$name" ]]; then
    mkdir -p "/var/lib/machines/$name/root/.ssh"
    touch "/var/lib/machines/$name/root/.ssh/authorized_keys"
    chmod 700 "/var/lib/machines/$name/root/.ssh"
    chmod 600 "/var/lib/machines/$name/root/.ssh/authorized_keys"
    dedupe_append_line "$pubkey" "/var/lib/machines/$name/root/.ssh/authorized_keys"
    echo "Exists, updated keys: $name @ $ip_addr"
    continue
  fi

  echo "Creating $name @ $ip_addr"

  mkdir -p "/var/lib/machines"
  copy_from_template_or_debootstrap "$name"

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
    gateway ${GW_IP}
EOF

  cat > "/var/lib/machines/$name/etc/resolv.conf" <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
EOF

  # Ensure root authorized_keys exists in rootfs
  mkdir -p "/var/lib/machines/$name/root/.ssh"
  touch "/var/lib/machines/$name/root/.ssh/authorized_keys"
  chmod 700 "/var/lib/machines/$name/root/.ssh"
  chmod 600 "/var/lib/machines/$name/root/.ssh/authorized_keys"
  dedupe_append_line "$pubkey" "/var/lib/machines/$name/root/.ssh/authorized_keys"

  systemctl daemon-reload
  machinectl start "$name"

  # If we used a template, packages/sshd are already installed/enabled; just restart ssh.
  PID="$(machinectl show "$name" -p Leader --value)"
  nsenter -t "$PID" -m -u -i -n -p /bin/bash <<'INCHROOT'
set -euo pipefail
systemctl enable --now ssh
systemctl restart ssh
INCHROOT

done < "$MACHINES_FILE"

echo "Done. Host keys updated for $TARGET_USER at $HOST_AUTH_KEYS"
echo "IP map at $IP_MAP"

echo
echo "Machine roster:"
awk 'NF>=2{printf "  %-16s %s%s\n", $1, "'"$BASE_IP_PREFIX"'", $2}' "$IP_MAP" | sort

ROSTER="./roster.txt"
awk 'NF>=2{printf "%s %s%s\n", $1, "'"$BASE_IP_PREFIX"'", $2}' "$IP_MAP" | sort > "$ROSTER"
echo "Wrote roster: $ROSTER"