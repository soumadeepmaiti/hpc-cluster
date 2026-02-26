#!/usr/bin/env bash
# scripts/install_cron.sh
# ─────────────────────────────────────────────────────────────────────────────
# Install all automated maintenance tasks for the HPC cluster.
#
# On MASTER installs:
#   [cron]    Daily config + state backup               02:00
#   [cron]    Weekly Slurm accounting purge             Sunday 03:00
#   [cron]    Cluster status report                     Every 15 min
#   [systemd] Node health check timer                   Every 5 min
#   [logrotate] Slurm and health log rotation
#
# On COMPUTE nodes installs:
#   [systemd] Node health check timer                   Every 5 min
#   [logrotate] Health log rotation
#
# Usage:
#   On master:   sudo bash install_cron.sh master
#   On compute:  sudo bash install_cron.sh compute01
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

THIS_NODE="${1:-}"
INSTALL_DIR="/opt/hpc-cluster"
SCRIPTS_SRC="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -z "$THIS_NODE" ]]; then
    echo "Usage: $0 <master|compute01|...|compute05>"
    exit 1
fi

echo "=== [install_cron.sh] Installing automation on $THIS_NODE ==="

# ── Install scripts to /opt/hpc-cluster ──────────────────────────────────────
echo "[*] Installing scripts to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"/{monitoring,backup,scripts}
cp -a "${SCRIPTS_SRC}/monitoring/." "${INSTALL_DIR}/monitoring/"
cp -a "${SCRIPTS_SRC}/backup/."     "${INSTALL_DIR}/backup/"
cp -a "${SCRIPTS_SRC}/scripts/."    "${INSTALL_DIR}/scripts/"
chmod +x "${INSTALL_DIR}/monitoring/"*.sh \
         "${INSTALL_DIR}/backup/"*.sh \
         "${INSTALL_DIR}/scripts/"*.sh

# ── Install systemd health check timer (ALL nodes) ───────────────────────────
echo "[*] Installing health_check systemd timer"

cp "${SCRIPTS_SRC}/monitoring/health_check.service" \
   /etc/systemd/system/health_check.service

cp "${SCRIPTS_SRC}/monitoring/health_check.timer" \
   /etc/systemd/system/health_check.timer

# Update ExecStart to point to installed location
sed -i "s|ExecStart=.*|ExecStart=${INSTALL_DIR}/monitoring/health_check.sh|" \
    /etc/systemd/system/health_check.service

systemctl daemon-reload
systemctl enable health_check.timer
systemctl start  health_check.timer

echo "[✓] health_check.timer active"
systemctl list-timers health_check.timer --no-pager

# ── Install logrotate config (ALL nodes) ──────────────────────────────────────
echo "[*] Installing logrotate config"
cat > /etc/logrotate.d/hpc-cluster <<'EOF'
/var/log/slurm/*.log
/var/log/slurm/health.log
/var/log/slurm/cluster_status.log
/var/log/slurm/backup.log
{
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 slurm slurm
    sharedscripts
    postrotate
        systemctl kill -s HUP slurmctld.service 2>/dev/null || true
        systemctl kill -s HUP slurmd.service    2>/dev/null || true
    endscript
}
EOF
echo "[✓] logrotate config installed"

# ── MASTER-ONLY cron jobs ─────────────────────────────────────────────────────
if [[ "$THIS_NODE" == "master" ]]; then
    echo "[*] Installing master cron jobs"

    # Write cron to a temp file, install atomically
    CRON_TMP=$(mktemp)

    # Preserve existing root crontab (if any), strip our managed block
    crontab -l 2>/dev/null \
        | grep -v '# HPC-CLUSTER-MANAGED' \
        | grep -v 'backup_configs.sh' \
        | grep -v 'cluster_status.sh' \
        | grep -v 'slurm_accounting_purge' \
        > "$CRON_TMP" || true

    cat >> "$CRON_TMP" <<EOF

# ── HPC-CLUSTER-MANAGED (do not edit manually) ─────────────────────────────

# Daily backup of Slurm state, MUNGE key, and all cluster configs
0 2 * * *  ${INSTALL_DIR}/backup/backup_configs.sh >> /var/log/slurm/backup.log 2>&1

# Cluster-wide status report every 15 minutes
*/15 * * * *  ${INSTALL_DIR}/monitoring/cluster_status.sh >> /var/log/slurm/cluster_status.log 2>&1

# Weekly Slurm accounting cleanup (Sunday 03:00)
0 3 * * 0  sacct --purge --endtime=\$(date -d '90 days ago' +%Y-%m-%d) >> /var/log/slurm/accounting_purge.log 2>&1
EOF

    crontab "$CRON_TMP"
    rm "$CRON_TMP"

    echo "[✓] Master cron jobs installed:"
    crontab -l | grep -A20 'HPC-CLUSTER-MANAGED' | head -20
fi

echo ""
echo "=== Verification ==="
echo ""
echo "Active timers:"
systemctl list-timers health_check.timer --no-pager
echo ""
echo "Logrotate config:"
logrotate --debug /etc/logrotate.d/hpc-cluster 2>&1 | head -10

if [[ "$THIS_NODE" == "master" ]]; then
    echo ""
    echo "Crontab:"
    crontab -l | grep -A20 'HPC-CLUSTER-MANAGED'
fi

echo ""
echo "[✓] install_cron.sh complete for $THIS_NODE"
