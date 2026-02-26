#!/usr/bin/env bash
# monitoring/health_check.sh
# ─────────────────────────────────────────────────────────────────────────────
# Per-node health check — runs every 5 minutes via systemd timer on all nodes.
#
# Checks:
#   1. CPU load vs threshold
#   2. Memory usage vs threshold
#   3. Disk usage vs threshold
#   4. slurmd / slurmctld service state
#   5. munge service state
#   6. NFS mount (compute nodes)
#   7. Cluster network reachability (ping master)
#
# Outputs a structured log line to /var/log/slurm/health.log and exits
# non-zero if any critical check fails (so systemd can track failures).
#
# Install: see monitoring/health_check.timer and health_check.service
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/slurm/health.log"
MASTER_IP="192.168.50.1"
CPU_WARN=80        # % load average threshold (1-min)
MEM_WARN=90        # % RAM used threshold
DISK_WARN=85       # % disk used threshold (root FS)
MAX_LOG_LINES=5000 # rotate in-script if file grows large

THIS_HOST=$(hostname -s)
TS=$(date '+%Y-%m-%dT%H:%M:%S')
STATUS="OK"
ISSUES=()

# ── Helpers ───────────────────────────────────────────────────────────────────
warn()  { ISSUES+=("WARN: $1");  STATUS="WARN"; }
crit()  { ISSUES+=("CRIT: $1");  STATUS="CRIT"; }
check() { echo "[$TS] [$THIS_HOST] [$STATUS] $*"; }

# ── 1. CPU load ───────────────────────────────────────────────────────────────
CPU_CORES=$(nproc)
LOAD_1=$(awk '{printf "%.0f", $1*100/'"$CPU_CORES"'}' /proc/loadavg)
if (( LOAD_1 > CPU_WARN )); then
    warn "CPU load ${LOAD_1}% (threshold ${CPU_WARN}%)"
fi

# ── 2. Memory ─────────────────────────────────────────────────────────────────
read -r MEM_TOTAL MEM_AVAIL < <(awk '
    /MemTotal/     {total=$2}
    /MemAvailable/ {avail=$2}
    END {print total, avail}
' /proc/meminfo)

if (( MEM_TOTAL > 0 )); then
    MEM_USED_PCT=$(( (MEM_TOTAL - MEM_AVAIL) * 100 / MEM_TOTAL ))
    if (( MEM_USED_PCT > MEM_WARN )); then
        warn "Memory ${MEM_USED_PCT}% used (threshold ${MEM_WARN}%)"
    fi
fi

# ── 3. Disk ───────────────────────────────────────────────────────────────────
DISK_USED=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if (( DISK_USED > DISK_WARN )); then
    warn "Root disk ${DISK_USED}% full (threshold ${DISK_WARN}%)"
fi

# ── 4. Slurm service ──────────────────────────────────────────────────────────
if [[ "$THIS_HOST" == "master" ]]; then
    if ! systemctl is-active slurmctld &>/dev/null; then
        crit "slurmctld is NOT active"
    fi
fi

if ! systemctl is-active slurmd &>/dev/null; then
    # master may not run slurmd — only flag if it should
    if [[ "$THIS_HOST" != "master" ]]; then
        crit "slurmd is NOT active"
    fi
fi

# ── 5. MUNGE ─────────────────────────────────────────────────────────────────
if ! systemctl is-active munge &>/dev/null; then
    crit "munge is NOT active"
elif ! munge -n | unmunge &>/dev/null; then
    crit "munge credential test failed"
fi

# ── 6. NFS mount (compute nodes only) ────────────────────────────────────────
if [[ "$THIS_HOST" != "master" ]]; then
    if ! findmnt /home | grep -q nfs &>/dev/null; then
        crit "/home is not NFS-mounted"
    fi
fi

# ── 7. Network reachability ───────────────────────────────────────────────────
if [[ "$THIS_HOST" != "master" ]]; then
    if ! ping -c1 -W2 "$MASTER_IP" &>/dev/null; then
        crit "Cannot reach master ($MASTER_IP)"
    fi
fi

# ── Build log line ────────────────────────────────────────────────────────────
ISSUE_STR="${ISSUES[*]:-none}"
LOG_LINE="[$TS] host=$THIS_HOST status=$STATUS cpu_load=${LOAD_1}% \
mem_used=${MEM_USED_PCT:-?}% disk_used=${DISK_USED}% issues=\"${ISSUE_STR}\""

# ── Write to log ──────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
echo "$LOG_LINE" >> "$LOG_FILE"

# In-script trim: keep the last MAX_LOG_LINES lines
LINE_COUNT=$(wc -l < "$LOG_FILE")
if (( LINE_COUNT > MAX_LOG_LINES )); then
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" \
        && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

# ── Stdout for systemd journal ───────────────────────────────────────────────
echo "$LOG_LINE"

# ── Exit code ─────────────────────────────────────────────────────────────────
[[ "$STATUS" == "CRIT" ]] && exit 2
[[ "$STATUS" == "WARN" ]] && exit 1
exit 0
