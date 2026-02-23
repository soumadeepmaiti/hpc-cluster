#!/usr/bin/env bash
# setup/01_network.sh
# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — Network configuration: static IPs, /etc/hosts, hostname, SSH trust
#
# Run on MASTER first, then distribute to each compute node.
# Usage:
#   On master:   sudo bash 01_network.sh master
#   On compute:  sudo bash 01_network.sh compute01   (or compute02 … compute05)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CLUSTER_USER="paul"
MASTER_IP="192.168.50.1"
IFACE="enp0s25"   # physical Ethernet interface — verify with: ip -br link

declare -A NODE_IPS=(
    [master]="192.168.50.1"
    [compute01]="192.168.50.11"
    [compute02]="192.168.50.12"
    [compute03]="192.168.50.13"
    [compute04]="192.168.50.14"
    [compute05]="192.168.50.15"
)

# ── Argument ──────────────────────────────────────────────────────────────────
THIS_NODE="${1:-}"
if [[ -z "$THIS_NODE" || -z "${NODE_IPS[$THIS_NODE]+x}" ]]; then
    echo "Usage: $0 <master|compute01|compute02|compute03|compute04|compute05>"
    exit 1
fi
THIS_IP="${NODE_IPS[$THIS_NODE]}"

echo "=== [01_network.sh] Configuring node: $THIS_NODE ($THIS_IP) ==="

# ── 1. Hostname ───────────────────────────────────────────────────────────────
echo "[*] Setting hostname to $THIS_NODE"
hostnamectl set-hostname "$THIS_NODE"

# ── 2. /etc/hosts (deploy cluster-wide hosts file) ───────────────────────────
echo "[*] Installing /etc/hosts"
cp "$(dirname "$0")/../configs/hosts" /etc/hosts

# ── 3. Static IP via netplan ──────────────────────────────────────────────────
echo "[*] Writing netplan config for $IFACE ($THIS_IP/24)"

NETPLAN_FILE="/etc/netplan/99-cluster.yaml"
cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      addresses:
        - ${THIS_IP}/24
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF

# Master also sets its own gateway (router or direct uplink)
if [[ "$THIS_NODE" == "master" ]]; then
    cat >> "$NETPLAN_FILE" <<EOF
      routes:
        - to: default
          via: ${MASTER_IP%.*}.254
EOF
else
    # Compute nodes route internet through master (NAT gateway)
    cat >> "$NETPLAN_FILE" <<EOF
      routes:
        - to: default
          via: ${MASTER_IP}
EOF
fi

chmod 600 "$NETPLAN_FILE"
netplan apply
echo "[✓] Netplan applied"

# ── 4. NAT masquerading on master ─────────────────────────────────────────────
if [[ "$THIS_NODE" == "master" ]]; then
    echo "[*] Enabling IP forwarding and NAT on master"

    # Kernel parameter
    sysctl -w net.ipv4.ip_forward=1
    grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf \
        || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

    # Detect the uplink interface (the one that is NOT the cluster LAN)
    UPLINK=$(ip route show default | awk '{print $5; exit}')
    if [[ -n "$UPLINK" && "$UPLINK" != "$IFACE" ]]; then
        echo "[*] Applying iptables NAT: $IFACE → $UPLINK"
        iptables -t nat -C POSTROUTING -o "$UPLINK" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -o "$UPLINK" -j MASQUERADE
        iptables -C FORWARD -i "$IFACE"  -o "$UPLINK" -j ACCEPT 2>/dev/null \
            || iptables -A FORWARD -i "$IFACE" -o "$UPLINK" -j ACCEPT
        iptables -C FORWARD -i "$UPLINK" -o "$IFACE" -m state \
            --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
            || iptables -A FORWARD -i "$UPLINK" -o "$IFACE" -m state \
               --state RELATED,ESTABLISHED -j ACCEPT

        # Persist rules
        apt-get install -y iptables-persistent -qq
        iptables-save > /etc/iptables/rules.v4
        echo "[✓] NAT rules saved"
    else
        echo "[!] Could not detect uplink interface — NAT not configured"
    fi

    # UFW: allow Slurm ports and NFS from cluster subnet
    ufw allow from 192.168.50.0/24 to any port 6817:6818 proto tcp comment "Slurm"
    ufw allow from 192.168.50.0/24 to any port 2049  proto tcp comment "NFS"
    ufw allow from 192.168.50.0/24 to any port 111   proto tcp comment "portmapper"
    ufw allow from 192.168.50.0/24 to any port 123   proto udp comment "NTP"
    ufw allow from 192.168.50.0/24 to any port 22    proto tcp comment "SSH"
fi

# ── 5. SSH key distribution ───────────────────────────────────────────────────
if [[ "$THIS_NODE" == "master" ]]; then
    echo "[*] Generating SSH key for $CLUSTER_USER (if not present)"
    sudo -u "$CLUSTER_USER" bash -c '
        [[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
    '
    echo ""
    echo "=== ACTION REQUIRED ==="
    echo "Run the following on master to distribute SSH keys to each compute node:"
    for node in compute01 compute02 compute03 compute04 compute05; do
        ip="${NODE_IPS[$node]}"
        echo "  ssh-copy-id ${CLUSTER_USER}@${ip}"
    done
fi

# ── Verification ──────────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="
echo "Hostname : $(hostname)"
echo "IP       : $(hostname -I)"
echo ""
echo "Ping tests:"
for node in "${!NODE_IPS[@]}"; do
    ip="${NODE_IPS[$node]}"
    if ping -c1 -W1 "$ip" &>/dev/null; then
        echo "  [✓] $node ($ip)"
    else
        echo "  [✗] $node ($ip) — unreachable (may not be configured yet)"
    fi
done

echo ""
echo "[✓] 01_network.sh complete for $THIS_NODE"
