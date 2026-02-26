#!/usr/bin/env bash
# backup/restore_configs.sh
# ─────────────────────────────────────────────────────────────────────────────
# Restore cluster configuration from a backup archive.
# Use after hardware replacement, OS reinstall, or state corruption.
#
# Usage:
#   sudo bash restore_configs.sh [/path/to/backup.tar.gz]
#
# If no path given, lists available backups and prompts for selection.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BACKUP_ROOT="/var/backups/hpc-cluster"

# ── Select backup ─────────────────────────────────────────────────────────────
ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" ]]; then
    echo "Available backups:"
    ls -lht "$BACKUP_ROOT"/*.tar.gz 2>/dev/null || { echo "No backups found in $BACKUP_ROOT"; exit 1; }
    echo ""
    read -rp "Enter path to backup archive: " ARCHIVE
fi

if [[ ! -f "$ARCHIVE" ]]; then
    echo "ERROR: Archive not found: $ARCHIVE"
    exit 1
fi

echo "=== Restoring from: $ARCHIVE ==="
echo ""
echo "WARNING: This will overwrite current configs. Services will be restarted."
read -rp "Continue? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Extract ───────────────────────────────────────────────────────────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

tar -xzf "$ARCHIVE" -C "$TMPDIR"
RESTORE_DIR=$(find "$TMPDIR" -maxdepth 1 -mindepth 1 -type d | head -1)

echo ""
echo "Restoring files from: $RESTORE_DIR"
cat "${RESTORE_DIR}/MANIFEST.txt" | head -20
echo "..."

# ── Stop services ─────────────────────────────────────────────────────────────
echo ""
echo "[*] Stopping cluster services"
systemctl stop slurmctld slurmd munge 2>/dev/null || true

# ── Restore MUNGE key ─────────────────────────────────────────────────────────
if [[ -f "${RESTORE_DIR}/munge/munge.key" ]]; then
    cp "${RESTORE_DIR}/munge/munge.key" /etc/munge/munge.key
    chown munge:munge /etc/munge/munge.key
    chmod 0400 /etc/munge/munge.key
    echo "[✓] MUNGE key restored"
fi

# ── Restore Slurm state ───────────────────────────────────────────────────────
if [[ -d "${RESTORE_DIR}/slurmctld_state" ]]; then
    mkdir -p /var/spool/slurmctld
    cp -a "${RESTORE_DIR}/slurmctld_state/." /var/spool/slurmctld/
    chown -R slurm:slurm /var/spool/slurmctld
    echo "[✓] Slurm controller state restored"
fi

# ── Restore Slurm config ──────────────────────────────────────────────────────
if [[ -d "${RESTORE_DIR}/slurm" ]]; then
    cp -a "${RESTORE_DIR}/slurm/." /etc/slurm/
    chown -R root:root /etc/slurm
    chmod 0644 /etc/slurm/*.conf
    echo "[✓] Slurm config restored"
fi

# ── Restore hosts ─────────────────────────────────────────────────────────────
[[ -f "${RESTORE_DIR}/hosts"    ]] && cp "${RESTORE_DIR}/hosts"    /etc/hosts    && echo "[✓] /etc/hosts restored"
[[ -f "${RESTORE_DIR}/exports"  ]] && cp "${RESTORE_DIR}/exports"  /etc/exports  && echo "[✓] /etc/exports restored"
[[ -d "${RESTORE_DIR}/netplan"  ]] && cp -a "${RESTORE_DIR}/netplan/." /etc/netplan/ && echo "[✓] Netplan restored"

# ── Restart services ──────────────────────────────────────────────────────────
echo ""
echo "[*] Restarting services"
systemctl start munge
sleep 2
systemctl start slurmctld
sleep 2
systemctl start slurmd 2>/dev/null || true

echo ""
echo "[✓] Restore complete."
echo "    Run: sinfo -N -l   to verify cluster state"
