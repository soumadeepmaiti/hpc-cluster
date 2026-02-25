#!/usr/bin/env bash
# setup/05_slurm_master.sh
# ─────────────────────────────────────────────────────────────────────────────
# Step 5 — Slurm controller (slurmctld) on master node
#
# Installs slurmctld, deploys slurm.conf and cgroup.conf, creates required
# directories, starts the service, and stages config on NFS for compute nodes.
#
# Run on MASTER only.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONFIGS_DIR="$(dirname "$0")/../configs"
CLUSTER_USER="paul"
SLURM_STAGE="/home/${CLUSTER_USER}/.slurm_stage"

echo "=== [05_slurm_master.sh] Slurm controller setup ==="

# ── Packages ──────────────────────────────────────────────────────────────────
echo "[*] Installing Slurm controller packages"
apt-get update -qq
apt-get install -y slurmctld slurmd slurm-client -qq

# ── Ensure slurm system user exists ──────────────────────────────────────────
if ! getent passwd slurm &>/dev/null; then
    echo "[*] Creating slurm system user"
    groupadd --system slurm 2>/dev/null || true
    useradd --system --gid slurm \
            --home-dir /nonexistent \
            --shell /usr/sbin/nologin \
            slurm
fi

SLURM_UID=$(id -u slurm)
SLURM_GID=$(id -g slurm)
echo "[*] slurm UID=$SLURM_UID GID=$SLURM_GID"
echo "    → Compute nodes MUST have the same UID/GID for Slurm auth to work."

# ── Directories ───────────────────────────────────────────────────────────────
echo "[*] Creating Slurm state and log directories"
for dir in /var/spool/slurmctld /var/spool/slurmd /var/log/slurm; do
    mkdir -p "$dir"
done
chown -R slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
chmod 0755 /var/spool/slurmctld /var/spool/slurmd /var/log/slurm

# ── Config files ──────────────────────────────────────────────────────────────
echo "[*] Deploying slurm.conf and cgroup.conf"
mkdir -p /etc/slurm
cp "${CONFIGS_DIR}/slurm.conf"  /etc/slurm/slurm.conf
cp "${CONFIGS_DIR}/cgroup.conf" /etc/slurm/cgroup.conf
chown root:root /etc/slurm/slurm.conf /etc/slurm/cgroup.conf
chmod 0644 /etc/slurm/slurm.conf /etc/slurm/cgroup.conf

# ── Stage configs on NFS for compute nodes ───────────────────────────────────
echo "[*] Staging Slurm configs on NFS share"
mkdir -p "$SLURM_STAGE"
chmod 0755 "$SLURM_STAGE"
cp /etc/slurm/slurm.conf  "${SLURM_STAGE}/slurm.conf"
cp /etc/slurm/cgroup.conf "${SLURM_STAGE}/cgroup.conf"
chown -R "${CLUSTER_USER}:${CLUSTER_USER}" "$SLURM_STAGE"

echo "[*] Staged slurm.conf hash: $(sha256sum /etc/slurm/slurm.conf | awk '{print $1}')"

# ── Start slurmctld ───────────────────────────────────────────────────────────
echo "[*] Enabling and starting slurmctld"
systemctl enable slurmctld
systemctl restart slurmctld

# ── Wait briefly for startup ──────────────────────────────────────────────────
sleep 3

# ── Verification ──────────────────────────────────────────────────────────────
echo ""
echo "=== Service status ==="
systemctl is-active slurmctld && echo "[✓] slurmctld is active" \
    || { echo "[✗] slurmctld failed"; journalctl -u slurmctld -n 30 --no-pager; exit 1; }

echo ""
echo "=== scontrol ping ==="
if scontrol ping 2>/dev/null | grep -q "UP"; then
    echo "[✓] slurmctld responds to ping"
else
    echo "[!] Controller not responding yet — may still be initialising"
fi

echo ""
echo "=== sinfo (nodes will show UNKNOWN until compute nodes register) ==="
sinfo -N -l 2>/dev/null || true

echo ""
echo "=== Next steps ==="
echo "  Run 06_slurm_compute.sh on each compute node."
echo "  slurm UID on this node is: $SLURM_UID — ensure compute nodes match."
echo ""
echo "[✓] 05_slurm_master.sh complete"
