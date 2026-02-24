#!/usr/bin/env bash
# setup/03_nfs.sh
# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — Shared /home via NFSv4
#
# Master exports /home to the cluster subnet.
# Compute nodes mount /home from master so all users see a unified home dir.
#
# Usage:
#   On master:   sudo bash 03_nfs.sh master
#   On compute:  sudo bash 03_nfs.sh compute01
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

THIS_NODE="${1:-}"
MASTER_IP="192.168.50.1"
CLUSTER_SUBNET="192.168.50.0/24"

if [[ -z "$THIS_NODE" ]]; then
    echo "Usage: $0 <master|compute01|...|compute05>"
    exit 1
fi

echo "=== [03_nfs.sh] NFS setup on $THIS_NODE ==="

# ─────────────────────────────────────────────────────────────────────────────
# MASTER — configure NFS server
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$THIS_NODE" == "master" ]]; then
    echo "[*] Installing nfs-kernel-server"
    apt-get update -qq
    apt-get install -y nfs-kernel-server -qq

    # Ensure /home exists and is populated
    if [[ ! -d /home ]]; then
        mkdir -p /home
        chmod 755 /home
    fi

    # Write exports (idempotent)
    EXPORT_LINE="/home  ${CLUSTER_SUBNET}(rw,sync,no_subtree_check,no_root_squash)"
    if ! grep -qF "/home" /etc/exports; then
        echo "$EXPORT_LINE" >> /etc/exports
        echo "[*] Added /home to /etc/exports"
    else
        echo "[~] /etc/exports already contains a /home entry — review manually"
        grep "/home" /etc/exports
    fi

    exportfs -ra
    systemctl enable nfs-kernel-server
    systemctl restart nfs-kernel-server

    echo ""
    echo "=== Active exports ==="
    exportfs -v

# ─────────────────────────────────────────────────────────────────────────────
# COMPUTE — configure NFS client
# ─────────────────────────────────────────────────────────────────────────────
else
    echo "[*] Installing nfs-common"
    apt-get update -qq
    apt-get install -y nfs-common -qq

    # Add persistent fstab entry (idempotent)
    FSTAB_LINE="${MASTER_IP}:/home  /home  nfs4  defaults,_netdev,hard,timeo=600,retrans=5  0  0"
    if grep -q "^${MASTER_IP}:/home" /etc/fstab; then
        echo "[~] fstab already has NFS /home entry — skipping"
    else
        echo "$FSTAB_LINE" >> /etc/fstab
        echo "[*] Added NFS /home to /etc/fstab"
    fi

    # Remove stale duplicate entries from previous experiments
    # (safely collapse multiple identical lines to one)
    awk '!seen[$0]++' /etc/fstab > /tmp/fstab.clean && mv /tmp/fstab.clean /etc/fstab

    # Mount (idempotent)
    if findmnt /home | grep -q nfs; then
        echo "[~] /home already mounted via NFS"
    else
        mount -a
    fi

    echo ""
    echo "=== Mount verification ==="
    findmnt /home

    # Confirm we can see master's data
    if ls /home &>/dev/null; then
        echo "[✓] /home readable"
    else
        echo "[✗] /home not readable — check NFS server on master"
        exit 1
    fi
fi

echo ""
echo "[✓] 03_nfs.sh complete for $THIS_NODE"
