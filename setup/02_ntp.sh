#!/usr/bin/env bash
# setup/02_ntp.sh
# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — NTP time synchronisation using chronyd hierarchy
#
# Master syncs from internet pools, then serves time to all compute nodes.
# Compute nodes sync exclusively from master to guarantee clock consistency.
#
# Usage:
#   On master:   sudo bash 02_ntp.sh master
#   On compute:  sudo bash 02_ntp.sh compute01   (or any compute node)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

THIS_NODE="${1:-}"
MASTER_IP="192.168.50.1"
CONFIGS_DIR="$(dirname "$0")/../configs"

if [[ -z "$THIS_NODE" ]]; then
    echo "Usage: $0 <master|compute01|...|compute05>"
    exit 1
fi

echo "=== [02_ntp.sh] NTP setup on $THIS_NODE ==="

# ── Install chrony ────────────────────────────────────────────────────────────
echo "[*] Installing chrony"
apt-get update -qq
apt-get install -y chrony -qq

# ── Deploy config ─────────────────────────────────────────────────────────────
if [[ "$THIS_NODE" == "master" ]]; then
    echo "[*] Deploying master chrony config (NTP server)"
    cp "${CONFIGS_DIR}/chrony_master.conf" /etc/chrony/chrony.conf
else
    echo "[*] Deploying compute chrony config (client → master)"
    cp "${CONFIGS_DIR}/chrony_compute.conf" /etc/chrony/chrony.conf
fi

# ── Restart and enable ────────────────────────────────────────────────────────
systemctl enable chrony
systemctl restart chrony

# ── Wait for initial sync ─────────────────────────────────────────────────────
echo "[*] Waiting for initial synchronisation (up to 30 s)..."
for i in $(seq 1 30); do
    if chronyc tracking 2>/dev/null | grep -q "Stratum.*[1-9]"; then
        break
    fi
    sleep 1
done

# ── Verification ──────────────────────────────────────────────────────────────
echo ""
echo "=== chronyc tracking ==="
chronyc tracking

echo ""
echo "=== chronyc sources -v ==="
chronyc sources -v

# Compute nodes must show master as '*' or '+'
if [[ "$THIS_NODE" != "master" ]]; then
    if chronyc sources | grep -q "^\^\*.*${MASTER_IP}"; then
        echo "[✓] Compute node is syncing from master (^*)"
    elif chronyc sources | grep -q "^\^\+.*${MASTER_IP}"; then
        echo "[✓] Compute node is syncing from master (^+)"
    elif chronyc sources | grep -q "${MASTER_IP}"; then
        echo "[~] Master is a known source but not yet selected — check again in 60 s"
    else
        echo "[✗] Master NOT in source list — check /etc/chrony/chrony.conf"
        exit 1
    fi
fi

echo ""
echo "[✓] 02_ntp.sh complete for $THIS_NODE"
