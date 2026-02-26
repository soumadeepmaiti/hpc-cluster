#!/usr/bin/env bash
# backup/backup_configs.sh
# ─────────────────────────────────────────────────────────────────────────────
# Daily backup of critical cluster configuration and state.
#
# Backs up:
#   - Slurm state directory (/var/spool/slurmctld)
#   - MUNGE cryptographic key (/etc/munge/munge.key)
#   - Slurm config files (/etc/slurm/)
#   - Network config (/etc/netplan/, /etc/hosts)
#   - NFS exports (/etc/exports)
#   - Chrony config (/etc/chrony/chrony.conf)
#   - systemd overrides for cluster services
#
# Scheduled via cron at 02:00 daily:
#   0 2 * * * /opt/hpc-cluster/backup/backup_configs.sh >> \
#             /var/log/slurm/backup.log 2>&1
#
# Retention: 7 daily backups kept; older ones auto-purged.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BACKUP_ROOT="/var/backups/hpc-cluster"
RETENTION_DAYS=7
LOG_PREFIX="[$(date '+%Y-%m-%dT%H:%M:%S')] [backup]"

# Create timestamped backup directory
STAMP=$(date '+%Y%m%d_%H%M%S')
DEST="${BACKUP_ROOT}/${STAMP}"
mkdir -p "$DEST"

echo "$LOG_PREFIX Starting backup → $DEST"

# ── Helper: copy if source exists ────────────────────────────────────────────
backup_item() {
    local src="$1"
    local label="${2:-$src}"
    if [[ -e "$src" ]]; then
        cp -a "$src" "$DEST/"
        echo "$LOG_PREFIX   [✓] $label"
    else
        echo "$LOG_PREFIX   [~] $label not found — skipping"
    fi
}

# ── Slurm state (slurmctld saves job and node state here) ────────────────────
if [[ -d /var/spool/slurmctld ]]; then
    mkdir -p "${DEST}/slurmctld_state"
    cp -a /var/spool/slurmctld/. "${DEST}/slurmctld_state/"
    echo "$LOG_PREFIX   [✓] Slurm controller state"
fi

# ── MUNGE key ─────────────────────────────────────────────────────────────────
if [[ -f /etc/munge/munge.key ]]; then
    mkdir -p "${DEST}/munge"
    cp /etc/munge/munge.key "${DEST}/munge/munge.key"
    chmod 0400 "${DEST}/munge/munge.key"
    echo "$LOG_PREFIX   [✓] MUNGE key (sha256: $(sha256sum /etc/munge/munge.key | awk '{print $1}'))"
fi

# ── Slurm config ──────────────────────────────────────────────────────────────
backup_item "/etc/slurm"               "Slurm config directory"

# ── Network and host config ───────────────────────────────────────────────────
backup_item "/etc/hosts"               "/etc/hosts"
backup_item "/etc/netplan"             "Netplan config"
backup_item "/etc/exports"             "NFS exports"
backup_item "/etc/chrony/chrony.conf"  "Chrony config"

# ── systemd overrides ─────────────────────────────────────────────────────────
backup_item "/etc/systemd/system/slurmd.service.d"    "slurmd systemd override"
backup_item "/etc/systemd/system/health_check.service" "health_check service"
backup_item "/etc/systemd/system/health_check.timer"   "health_check timer"

# ── SSH host keys (needed to restore node identity exactly) ──────────────────
if [[ -d /etc/ssh ]]; then
    mkdir -p "${DEST}/ssh_host_keys"
    cp /etc/ssh/ssh_host_*_key     "${DEST}/ssh_host_keys/" 2>/dev/null || true
    cp /etc/ssh/ssh_host_*_key.pub "${DEST}/ssh_host_keys/" 2>/dev/null || true
    echo "$LOG_PREFIX   [✓] SSH host keys"
fi

# ── Create a manifest ─────────────────────────────────────────────────────────
find "$DEST" -type f | sort > "${DEST}/MANIFEST.txt"
FILE_COUNT=$(wc -l < "${DEST}/MANIFEST.txt")

# ── Compress the backup ───────────────────────────────────────────────────────
ARCHIVE="${BACKUP_ROOT}/${STAMP}.tar.gz"
tar -czf "$ARCHIVE" -C "$BACKUP_ROOT" "$STAMP"
rm -rf "$DEST"

ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | awk '{print $1}')
echo "$LOG_PREFIX Compressed: $ARCHIVE ($ARCHIVE_SIZE, $FILE_COUNT files)"

# ── Purge old backups ─────────────────────────────────────────────────────────
echo "$LOG_PREFIX Purging backups older than ${RETENTION_DAYS} days"
find "$BACKUP_ROOT" -maxdepth 1 -name "*.tar.gz" \
     -mtime "+${RETENTION_DAYS}" -delete -print \
     | sed "s|^|$LOG_PREFIX   Removed: |"

REMAINING=$(find "$BACKUP_ROOT" -maxdepth 1 -name "*.tar.gz" | wc -l)
echo "$LOG_PREFIX Backup complete. $REMAINING backup(s) retained."
