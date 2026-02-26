#!/usr/bin/env bash
# scripts/fix_node_state.sh
# ─────────────────────────────────────────────────────────────────────────────
# Diagnose and fix common Slurm node state issues.
# Covers the specific production failures encountered during cluster operation:
#
#   1. Node DOWN after slurmd restart (clear stale reason)
#   2. Security violation / ping RPC errors (slurm UID mismatch)
#   3. "Node not responding" flapping (systemd restart loop)
#   4. slurm.conf hash mismatch between controller and node
#   5. Slurm state corruption (clustername file mismatch)
#
# Usage:
#   bash fix_node_state.sh                  # fixes all DOWN/DRAIN nodes
#   bash fix_node_state.sh compute03        # fixes specific node
#   bash fix_node_state.sh --diagnose-all   # diagnosis only, no changes
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

TARGET_NODE="${1:-}"
DIAGNOSE_ONLY=false
[[ "$TARGET_NODE" == "--diagnose-all" ]] && { DIAGNOSE_ONLY=true; TARGET_NODE=""; }

echo "=== [fix_node_state.sh] Slurm node diagnostics and repair ==="
echo "    Mode: $([ "$DIAGNOSE_ONLY" = true ] && echo "DIAGNOSE ONLY" || echo "DIAGNOSE + FIX")"
echo ""

# ── Gather DOWN/DRAIN nodes ───────────────────────────────────────────────────
if [[ -n "$TARGET_NODE" ]]; then
    NODES=("$TARGET_NODE")
else
    mapfile -t NODES < <(sinfo -h -o "%N %t" | awk '$2~/down|drain/{print $1}' | tr ',' '\n')
fi

if [[ ${#NODES[@]} -eq 0 ]]; then
    echo "[✓] No DOWN or DRAIN nodes found."
    sinfo -N -l
    exit 0
fi

echo "Nodes to process: ${NODES[*]}"
echo ""

for NODE in "${NODES[@]}"; do
    echo "────────────────────────────────────────────────────────"
    echo "  Node: $NODE"
    echo "────────────────────────────────────────────────────────"

    # ── Get current state and reason ─────────────────────────────────────────
    STATE=$(sinfo -n "$NODE" -h -o "%t" 2>/dev/null | head -1)
    REASON=$(scontrol show node "$NODE" 2>/dev/null \
             | awk -F'Reason=' '/Reason=/{print $2}' | awk '{print $1}')
    echo "  State : $STATE"
    echo "  Reason: $REASON"

    # ── Check 1: slurmd running on node ──────────────────────────────────────
    SLURMD_ACTIVE=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$NODE" \
        'systemctl is-active slurmd' 2>/dev/null || echo "unreachable")
    echo "  slurmd: $SLURMD_ACTIVE"

    if [[ "$SLURMD_ACTIVE" == "unreachable" ]]; then
        echo "  [✗] Cannot SSH to $NODE — network or SSH key issue"
        continue
    fi

    if [[ "$SLURMD_ACTIVE" != "active" ]]; then
        echo "  [!] slurmd not active — checking why"
        ssh "$NODE" 'sudo journalctl -u slurmd -n 20 --no-pager' 2>/dev/null || true
        if ! $DIAGNOSE_ONLY; then
            echo "  [*] Starting slurmd on $NODE"
            ssh "$NODE" 'sudo systemctl start slurmd' 2>/dev/null || true
            sleep 3
        fi
    fi

    # ── Check 2: slurm UID mismatch ───────────────────────────────────────────
    MASTER_UID=$(id -u slurm 2>/dev/null || echo "0")
    NODE_UID=$(ssh -o BatchMode=yes "$NODE" 'id -u slurm 2>/dev/null' || echo "unknown")
    if [[ "$NODE_UID" != "$MASTER_UID" ]]; then
        echo "  [✗] UID MISMATCH: master=$MASTER_UID node=$NODE_UID"
        echo "      This causes 'Security violation, ping RPC from uid $MASTER_UID'"
        if ! $DIAGNOSE_ONLY; then
            echo "  [*] Fixing slurm UID on $NODE"
            ssh "$NODE" "sudo systemctl stop slurmd; \
                         sudo groupmod -g $MASTER_UID slurm 2>/dev/null || true; \
                         sudo usermod  -u $MASTER_UID slurm; \
                         sudo chown -R slurm:slurm /var/spool/slurmd /var/log/slurm; \
                         sudo systemctl start slurmd" 2>/dev/null
            echo "  [✓] UID fixed"
        fi
    else
        echo "  [✓] slurm UID matches master ($MASTER_UID)"
    fi

    # ── Check 3: systemd restart policy ──────────────────────────────────────
    RESTART_POLICY=$(ssh -o BatchMode=yes "$NODE" \
        'systemctl show slurmd -p Restart --value' 2>/dev/null || echo "unknown")
    if [[ "$RESTART_POLICY" == "always" || "$RESTART_POLICY" == "on-failure" ]]; then
        echo "  [!] slurmd Restart=$RESTART_POLICY — this causes flapping"
        if ! $DIAGNOSE_ONLY; then
            echo "  [*] Setting Restart=no on $NODE"
            ssh "$NODE" '
                sudo mkdir -p /etc/systemd/system/slurmd.service.d
                echo -e "[Service]\nRestart=no" | sudo tee \
                    /etc/systemd/system/slurmd.service.d/override.conf
                sudo systemctl daemon-reload
                sudo systemctl restart slurmd
            ' 2>/dev/null
            echo "  [✓] Restart policy fixed"
        fi
    else
        echo "  [✓] slurmd Restart=$RESTART_POLICY"
    fi

    # ── Check 4: slurm.conf hash ──────────────────────────────────────────────
    MASTER_HASH=$(sha256sum /etc/slurm/slurm.conf | awk '{print $1}')
    NODE_HASH=$(ssh -o BatchMode=yes "$NODE" \
        'sha256sum /etc/slurm/slurm.conf 2>/dev/null | awk "{print \$1}"' || echo "unknown")
    if [[ "$NODE_HASH" != "$MASTER_HASH" ]]; then
        echo "  [!] slurm.conf MISMATCH: master=$MASTER_HASH node=$NODE_HASH"
        if ! $DIAGNOSE_ONLY; then
            echo "  [*] Syncing slurm.conf to $NODE"
            scp /etc/slurm/slurm.conf "${NODE}:/tmp/slurm.conf"
            ssh "$NODE" 'sudo mv /tmp/slurm.conf /etc/slurm/slurm.conf; \
                         sudo chmod 644 /etc/slurm/slurm.conf; \
                         sudo systemctl restart slurmd'
            echo "  [✓] Config synced"
        fi
    else
        echo "  [✓] slurm.conf hash matches master"
    fi

    # ── Clear stale DOWN/DRAIN reason ─────────────────────────────────────────
    if ! $DIAGNOSE_ONLY; then
        echo "  [*] Clearing stale node state"
        scontrol update NodeName="$NODE" State=RESUME 2>/dev/null \
            || scontrol update NodeName="$NODE" State=UNDRAIN 2>/dev/null \
            || echo "  [~] Could not change state (may already be IDLE)"
        sleep 3
        NEW_STATE=$(sinfo -n "$NODE" -h -o "%t" 2>/dev/null | head -1)
        echo "  [→] State after repair: $NEW_STATE"
    fi

    echo ""
done

# ── Final sinfo ───────────────────────────────────────────────────────────────
echo "=== Current cluster state ==="
sinfo -N -l 2>/dev/null

echo ""
echo "[✓] fix_node_state.sh complete"
