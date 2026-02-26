#!/usr/bin/env bash
# scripts/drain_node.sh
# ─────────────────────────────────────────────────────────────────────────────
# Gracefully drain a compute node for maintenance.
# Waits for running jobs to finish, then marks the node as DRAIN.
#
# Usage:
#   bash drain_node.sh compute03
#   bash drain_node.sh compute03 "hardware fault — RAM dimm"
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NODE="${1:-}"
REASON="${2:-maintenance}"

if [[ -z "$NODE" ]]; then
    echo "Usage: $0 <nodename> [reason]"
    exit 1
fi

echo "=== Draining node: $NODE ==="
echo "    Reason: $REASON"

# Mark node DRAIN (new jobs won't be scheduled, running jobs finish)
scontrol update NodeName="$NODE" State=DRAIN Reason="$REASON"
echo "[✓] Node $NODE set to DRAIN"

# Wait for all jobs on this node to finish
echo "[*] Waiting for running jobs on $NODE to complete..."
while true; do
    RUNNING=$(squeue -h -w "$NODE" 2>/dev/null | wc -l)
    if (( RUNNING == 0 )); then
        echo "[✓] No running jobs on $NODE"
        break
    fi
    echo "    $RUNNING job(s) still running — waiting 30s"
    squeue -w "$NODE" 2>/dev/null || true
    sleep 30
done

echo ""
echo "=== $NODE is now idle and drained ==="
echo "    To resume after maintenance: sudo scontrol update NodeName=$NODE State=RESUME"
echo ""
scontrol show node "$NODE" | grep -E "NodeName=|State=|Reason="
