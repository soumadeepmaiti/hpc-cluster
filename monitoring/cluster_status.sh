#!/usr/bin/env bash
# monitoring/cluster_status.sh
# ─────────────────────────────────────────────────────────────────────────────
# Cluster-wide status dashboard — run on master.
# Prints a summary of Slurm, node states, running jobs, and per-node
# resource utilisation via SSH.
#
# Scheduled via cron every 15 minutes; output appended to
# /var/log/slurm/cluster_status.log
#
# Cron entry (installed by install_cron.sh):
#   */15 * * * * /opt/hpc-cluster/monitoring/cluster_status.sh >> \
#                /var/log/slurm/cluster_status.log 2>&1
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

COMPUTE_NODES=(compute01 compute02 compute03 compute04 compute05)
SEP="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TS=$(date '+%Y-%m-%d %H:%M:%S')
echo "$SEP"
echo "  HPC Cluster Status Report — $TS"
echo "$SEP"

# ── 1. Slurm controller ───────────────────────────────────────────────────────
echo ""
echo "[ SLURM CONTROLLER ]"
if scontrol ping 2>/dev/null | grep -q "UP"; then
    echo "  slurmctld: UP"
else
    echo "  slurmctld: DOWN or unreachable"
fi

# ── 2. Node states ────────────────────────────────────────────────────────────
echo ""
echo "[ NODE STATES ]"
sinfo -N -o "  %-12N %-8t %-5C %-8m %-12E" 2>/dev/null || echo "  sinfo unavailable"

# ── 3. Running jobs ───────────────────────────────────────────────────────────
echo ""
echo "[ RUNNING JOBS ]"
JOB_COUNT=$(squeue -h 2>/dev/null | wc -l)
if (( JOB_COUNT == 0 )); then
    echo "  No jobs in queue."
else
    squeue -o "  %-8i %-10j %-10u %-8T %-12M %-5D %R" 2>/dev/null
fi

# ── 4. Per-node resource snapshot ────────────────────────────────────────────
echo ""
echo "[ PER-NODE RESOURCES ]"
printf "  %-12s %8s %8s %8s  %s\n" "HOST" "CPU%" "MEM%" "DISK%" "STATUS"
printf "  %-12s %8s %8s %8s  %s\n" "────────────" "─────" "─────" "─────" "──────"

for node in "${COMPUTE_NODES[@]}"; do
    DATA=$(ssh -o BatchMode=yes -o ConnectTimeout=3 "$node" '
        CPUS=$(nproc)
        LOAD=$(awk "{printf \"%.0f\", \$1*100/$CPUS}" /proc/loadavg)
        read TOTAL AVAIL < <(awk "/MemTotal/{t=\$2}/MemAvailable/{a=\$2}END{print t, a}" /proc/meminfo)
        MEM=$(( (TOTAL - AVAIL) * 100 / TOTAL ))
        DISK=$(df / | awk "NR==2{print \$5}" | tr -d "%")
        echo "$LOAD $MEM $DISK"
    ' 2>/dev/null || echo "ERR ERR ERR")

    read -r CPU MEM DISK <<< "$DATA"
    if [[ "$CPU" == "ERR" ]]; then
        STATE="UNREACHABLE"
    else
        STATE="OK"
        (( ${CPU:-0} > 90 )) && STATE="CPU_HIGH"
        (( ${MEM:-0} > 90 )) && STATE="MEM_HIGH"
        (( ${DISK:-0} > 85 )) && STATE="DISK_HIGH"
    fi
    printf "  %-12s %8s %8s %8s  %s\n" "$node" "${CPU}%" "${MEM}%" "${DISK}%" "$STATE"
done

# ── 5. MUNGE health ───────────────────────────────────────────────────────────
echo ""
echo "[ MUNGE AUTHENTICATION ]"
for node in "${COMPUTE_NODES[@]}"; do
    RESULT=$(munge -n | ssh -o BatchMode=yes -o ConnectTimeout=3 "$node" unmunge 2>/dev/null \
             | awk '/STATUS/{print $2}')
    if [[ "$RESULT" == "Success" ]]; then
        echo "  master → $node: OK"
    else
        echo "  master → $node: FAIL ($RESULT)"
    fi
done

echo ""
echo "$SEP"
echo ""
