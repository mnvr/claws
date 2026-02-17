# Claws

This repository provisions disposable `systemd-nspawn` containers behind a bastion host with SSH key access.

It is designed for:

* Fast creation of multiple demo machines
* Bastion jump access
* Idempotent re-runs
* Optional reusable template rootfs for speed

---

# Files

## `host_prep.sh`

One-time host setup.

Creates:

* `br0` bridge (`10.200.0.1/24`)
* NAT + forwarding rules (tagged `nspawn-demo`)
* Enables IP forwarding
* Optional bastion user (`jump` by default)
* Ensures `/home/<jump>/.ssh/authorized_keys` exists

Run once:

```bash
sudo ./host_prep.sh
```

Optional:

```bash
sudo ./host_prep.sh myjumpuser
```

---

## `create_machines.sh`

Main provisioning script.

Reads `machines.txt` and:

* Creates missing containers
* Assigns stable IP per name (via `/var/lib/machines/.ip-map`)
* Installs base packages (curl, node, build tools, etc.)
* Enables root SSH (key-only)
* Adds each key to:

  * container root `authorized_keys`
  * host bastion user `authorized_keys`
* Prints roster
* Writes `./roster.txt`

Safe to run repeatedly. Only creates missing machines.

Default usage:

```bash
sudo ./create_machines.sh
```

Optional arguments:

```bash
sudo ./create_machines.sh ./machines.txt jump
```

Environment flags:

* `USE_TEMPLATE=1` (default) → use template rootfs
* `USE_TEMPLATE=0` → debootstrap per machine
* `USE_JUMP_USER=0` → add keys to sudo user instead of jump

---

## `machines.txt`

Format:

```
<name> <full-public-key-line>
```

Example:

```
manav ssh-ed25519 AAAAC3Nz... manav@ente.io
alice ssh-ed25519 AAAAC3Nz... alice@laptop
```

Rules:

* First token = machine name
* Remainder of line = full SSH public key
* Lines starting with `#` ignored
* Header `name key` ignored

---

## `remove_machine.sh`

Removes a single machine cleanly.

Removes:

* container rootfs
* `.nspawn` config
* IP mapping entry

Does not touch:

* bridge
* NAT rules
* other machines

Usage:

```bash
sudo ./remove_machine.sh manav
```

---

## `cleanup.sh`

Resets host to pre-demo state.

Removes:

* all machines listed in `machines.txt`
* bridge `br0`
* NAT rules tagged `nspawn-demo`
* IP forwarding config
* template rootfs

Usage:

```bash
sudo ./cleanup.sh
```

---

# Template System

Path:

```
/var/lib/machines/.template
```

If `USE_TEMPLATE=1`:

1. First run builds template via debootstrap
2. Installs base packages once
3. Subsequent machines are copied from template (fast)

To rebuild template:

```bash
sudo rm -rf /var/lib/machines/.template
```

Then run:

```bash
sudo ./create_machines.sh
```

Template only affects future machines.

---

# Networking Model

* Bridge: `br0`
* Gateway: `10.200.0.1`
* Subnet: `10.200.0.0/24`
* Machine IPs start at `10.200.0.10`
* NAT via host default route interface

Stable mapping stored in:

```
/var/lib/machines/.ip-map
```

Format:

```
<name> <last_octet>
```

---

# Access Model

Participants SSH:

```bash
ssh -J jump@claws:<port> root@10.200.0.X
```

Key is installed both:

* On host (jump user)
* Inside container (root)

---

# Base Packages Installed

Includes:

* Node.js (Ubuntu 24 native)
* npm
* build-essential
* cmake
* python3
* curl
* git
* jq
* networking tools

Sufficient for:

```bash
curl -fsSL https://openclaw.ai/install.sh | bash
```

---

# Design Goals

* Deterministic
* Idempotent
* Minimal moving parts
* Easy reset
* Safe to hand to automation agent
