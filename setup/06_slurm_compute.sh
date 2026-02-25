#!/usr/bin/env bash
# setup/06_slurm_compute.sh
# ─────────────────────────────────────────────────────────────────────────────
# Step 6 — Slurm compute daemon (slurmd) on compute nodes
#
# Pulls slurm.conf from NFS staging area, aligns slurm UID/GID with master,
# deploys systemd override to prevent restart loop, and starts slurmd.
#
# Run on EACH COMPUTE NODE after master setup is complete.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CLUSTER_USER="paul"
MASTER_IP="192.168.50.1"
SLURM_STAGE="/home/${CLUSTER_USER}/.slurm_stage"

echo "=== [06_slurm_compute.sh] Slurm compute setup on $(hostname) ==="

# ── Packages ──────────────────────────────────────────────────────────────────
echo "[*] Installing slurmd and slurm-client"
apt-get update -qq
apt-get install -y slurmd slurm-client -qq

# ── UID/GID alignment with master ─────────────────────────────────────────────
# CRITICAL: slurm user must have the SAME numeric UID/GID on every node.
# Slurm authentication is UID-based; mismatches cause "Security violation" errors.

MASTER_SLURM_UID=$(ssh -o BatchMode=yes "$MASTER_IP" "id -u slurm" 2>/dev/null || echo "")
MASTER_SLURM_GID=$(ssh -o BatchMode=yes "$MASTER_IP" "id -g slurm" 2>/dev/null || echo "")

if [[ -z "$MASTER_SLURM_UID" ]]; then
    echo "[!] Could not query master slurm UID via SSH — using fallback 995/986"
    MASTER_SLURM_UID=995
    MASTER_SLURM_GID=986
fi

echo "[*] Target slurm UID=$MASTER_SLURM_UID GID=$MASTER_SLURM_GID"

# Create or fix group
if ! getent group slurm &>/dev/null; then
    groupadd --system --gid "$MASTER_SLURM_GID" slurm
elif [[ "$(getent group slurm | cut -d: -f3)" != "$MASTER_SLURM_GID" ]]; then
    echo "[*] Fixing slurm GID: $(getent group slurm | cut -d: -f3) → $MASTER_SLURM_GID"
    systemctl stop slurmd 2>/dev/null || true
    groupmod -g "$MASTER_SLURM_GID" slurm
fi

# Create or fix user
if ! getent passwd slurm &>/dev/null; then
    useradd --system --uid "$MASTER_SLURM_UID" --gid "$MASTER_SLURM_GID" \
            --home-dir /nonexistent --shell /usr/sbin/nologin slurm
elif [[ "$(id -u slurm)" != "$MASTER_SLURM_UID" ]]; then
    echo "[*] Fixing slurm UID: $(id -u slurm) → $MASTER_SLURM_UID"
    systemctl stop slurmd 2>/dev/null || true
    usermod -u "$MASTER_SLURM_UID" -g "$MASTER_SLURM_GID" slurm
fi

echo "[✓] slurm UID=$(id -u slurm) GID=$(id -g slurm)"

# ── Directories ───────────────────────────────────────────────────────────────
echo "[*] Creating slurmd spool and log directories"
mkdir -p /var/spool/slurmd /var/log/slurm
chown -R slurm:slurm /var/spool/slurmd /var/log/slurm
chmod 0755 /var/spool/slurmd /var/log/slurm

# ── Deploy config from NFS stage ─────────────────────────────────────────────
if [[ ! -f "${SLURM_STAGE}/slurm.conf" ]]; then
    echo "[✗] slurm.conf not found at ${SLURM_STAGE}/slurm.conf"
    echo "    Run 05_slurm_master.sh on master first."
    exit 1
fi

echo "[*] Deploying slurm.conf and cgroup.conf from NFS stage"
mkdir -p /etc/slurm
cp "${SLURM_STAGE}/slurm.conf"  /etc/slurm/slurm.conf
cp "${SLURM_STAGE}/cgroup.conf" /etc/slurm/cgroup.conf
chown root:root /etc/slurm/slurm.conf /etc/slurm/cgroup.conf
chmod 0644 /etc/slurm/slurm.conf /etc/slurm/cgroup.conf

# Verify config hash matches master
LOCAL_HASH=$(sha256sum /etc/slurm/slurm.conf | awk '{print $1}')
STAGE_HASH=$(sha256sum "${SLURM_STAGE}/slurm.conf" | awk '{print $1}')
if [[ "$LOCAL_HASH" == "$STAGE_HASH" ]]; then
    echo "[✓] slurm.conf hash verified: $LOCAL_HASH"
else
    echo "[✗] Hash mismatch — /etc/slurm/slurm.conf may be corrupted"
    exit 1
fi

# ── systemd override: disable automatic restart ───────────────────────────────
# Slurm expects slurmd to be long-lived.
# systemd Restart=always fights Slurm's own fault-tolerance and causes
# node flapping ("not responding" / "now responding" loops).
echo "[*] Applying systemd override: Restart=no for slurmd"
mkdir -p /etc/systemd/system/slurmd.service.d
cat > /etc/systemd/system/slurmd.service.d/override.conf <<'EOF'
[Service]
Restart=no
EOF
systemctl daemon-reload

# ── Start slurmd ─────────────────────────────────────────────────────────────
echo "[*] Enabling and starting slurmd"
systemctl enable slurmd
systemctl restart slurmd

sleep 3

# ── Verification ──────────────────────────────────────────────────────────────
echo ""
echo "=== Service status ==="
systemctl is-active slurmd && echo "[✓] slurmd is active" \
    || { echo "[✗] slurmd failed"; journalctl -u slurmd -n 40 --no-pager; exit 1; }

echo ""
echo "=== slurmd auto-detected resources ==="
slurmd -C

echo ""
echo "=== Verify from master that this node appears IDLE ==="
echo "  ssh master 'sinfo -N -l'"
echo ""
echo "[✓] 06_slurm_compute.sh complete for $(hostname)"
