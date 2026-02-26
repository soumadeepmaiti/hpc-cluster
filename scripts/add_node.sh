#!/usr/bin/env bash
# scripts/add_node.sh
# ─────────────────────────────────────────────────────────────────────────────
# Add a new compute node to a running cluster without downtime.
#
# Steps:
#   1. Verify network reachability and SSH access
#   2. Check MUNGE authentication
#   3. Validate slurm.conf NodeName entry exists
#   4. Verify slurmd is active on new node
#   5. Resume the node in Slurm
#   6. Run a test job targeting the new node
#
# Usage:
#   bash add_node.sh compute06
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NEW_NODE="${1:-}"
if [[ -z "$NEW_NODE" ]]; then
    echo "Usage: $0 <new-nodename>"
    exit 1
fi

echo "=== Adding node: $NEW_NODE ==="

# ── 1. Network reachability ───────────────────────────────────────────────────
echo "[*] Checking network reachability"
if ! ping -c2 -W2 "$NEW_NODE" &>/dev/null; then
    echo "[✗] Cannot ping $NEW_NODE — check /etc/hosts and network"
    exit 1
fi
echo "[✓] Ping OK"

# ── 2. SSH access ─────────────────────────────────────────────────────────────
echo "[*] Testing SSH access"
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$NEW_NODE" 'hostname' &>/dev/null; then
    echo "[✗] SSH failed — run: ssh-copy-id paul@$NEW_NODE"
    exit 1
fi
echo "[✓] SSH OK: $(ssh "$NEW_NODE" hostname)"

# ── 3. MUNGE cross-node test ──────────────────────────────────────────────────
echo "[*] Testing MUNGE authentication"
if munge -n | ssh "$NEW_NODE" unmunge 2>/dev/null | grep -q "Success"; then
    echo "[✓] MUNGE OK"
else
    echo "[✗] MUNGE failed — check /etc/munge/munge.key on $NEW_NODE"
    exit 1
fi

# ── 4. slurm.conf contains NodeName entry ────────────────────────────────────
echo "[*] Checking slurm.conf for NodeName=$NEW_NODE"
if ! grep -q "^NodeName=${NEW_NODE}" /etc/slurm/slurm.conf; then
    echo "[✗] NodeName=${NEW_NODE} not found in /etc/slurm/slurm.conf"
    echo "    Add the node definition and re-run:"
    echo "    NodeName=${NEW_NODE} CPUs=8 Sockets=1 CoresPerSocket=4 ThreadsPerCore=2 RealMemory=15000 State=UNKNOWN"
    echo "    Then: sudo scontrol reconfigure"
    exit 1
fi
echo "[✓] NodeName entry found"

# ── 5. slurmd status on new node ─────────────────────────────────────────────
echo "[*] Checking slurmd on $NEW_NODE"
SLURMD_STATE=$(ssh "$NEW_NODE" 'systemctl is-active slurmd 2>/dev/null')
if [[ "$SLURMD_STATE" != "active" ]]; then
    echo "[!] slurmd not active ($SLURMD_STATE) — starting it"
    ssh "$NEW_NODE" 'sudo systemctl start slurmd'
    sleep 3
    SLURMD_STATE=$(ssh "$NEW_NODE" 'systemctl is-active slurmd 2>/dev/null')
fi
echo "[${SLURMD_STATE}] slurmd state: $SLURMD_STATE"

# ── 6. Reconfigure Slurm to pick up new node ─────────────────────────────────
echo "[*] Sending scontrol reconfigure"
scontrol reconfigure

sleep 5

# ── 7. Show node state ────────────────────────────────────────────────────────
echo ""
echo "=== Node state in Slurm ==="
scontrol show node "$NEW_NODE" | grep -E "NodeName=|State=|Reason="

NODE_STATE=$(sinfo -n "$NEW_NODE" -h -o "%t" 2>/dev/null | head -1)
if [[ "$NODE_STATE" == "idle" || "$NODE_STATE" == "mix" ]]; then
    echo "[✓] Node is $NODE_STATE — ready for jobs"
elif [[ "$NODE_STATE" == "down" || "$NODE_STATE" == "drain" ]]; then
    echo "[!] Node is $NODE_STATE — clearing state"
    scontrol update NodeName="$NEW_NODE" State=RESUME Reason=""
    sleep 2
    NODE_STATE=$(sinfo -n "$NEW_NODE" -h -o "%t" 2>/dev/null | head -1)
    echo "    State after resume: $NODE_STATE"
fi

# ── 8. Quick test job on new node ─────────────────────────────────────────────
echo ""
echo "[*] Submitting test job to $NEW_NODE"
JOB_ID=$(sbatch --wait \
    --job-name="add_node_test" \
    --nodelist="$NEW_NODE" \
    --nodes=1 --ntasks=1 \
    --time=00:01:00 \
    --output="/tmp/add_node_test_%j.out" \
    --wrap="hostname && nproc && echo OK" \
    | awk '{print $4}')

if [[ -f "/tmp/add_node_test_${JOB_ID}.out" ]]; then
    OUTPUT=$(cat "/tmp/add_node_test_${JOB_ID}.out")
    echo "[✓] Test job $JOB_ID output:"
    echo "$OUTPUT" | sed 's/^/    /'
    rm -f "/tmp/add_node_test_${JOB_ID}.out"
fi

echo ""
echo "[✓] Node $NEW_NODE added successfully"
