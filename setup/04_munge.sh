#!/usr/bin/env bash
# setup/04_munge.sh
# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — MUNGE authentication layer
#
# MUNGE provides shared credential validation for Slurm across all nodes.
# The same key must be bit-for-bit identical on every node.
#
# Usage:
#   On master (generates key):        sudo bash 04_munge.sh master
#   On compute (receives key):        sudo bash 04_munge.sh compute01
#
# Key distribution uses /home (NFS-shared), which is available after step 3.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

THIS_NODE="${1:-}"
CLUSTER_USER="paul"
KEY_STAGE="/home/${CLUSTER_USER}/.munge_stage"   # temporary staging on NFS

if [[ -z "$THIS_NODE" ]]; then
    echo "Usage: $0 <master|compute01|...|compute05>"
    exit 1
fi

echo "=== [04_munge.sh] MUNGE setup on $THIS_NODE ==="

# ── Install munge ─────────────────────────────────────────────────────────────
echo "[*] Installing munge"
apt-get update -qq
apt-get install -y munge libmunge2 -qq

# ── Ensure munge system user exists ──────────────────────────────────────────
if ! getent passwd munge &>/dev/null; then
    echo "[*] Creating munge system user"
    groupadd --system munge 2>/dev/null || true
    useradd --system --gid munge \
            --home-dir /var/lib/munge \
            --shell /usr/sbin/nologin \
            munge
fi

# ── Ensure runtime directories exist ─────────────────────────────────────────
for dir in /etc/munge /var/lib/munge /var/log/munge /run/munge; do
    mkdir -p "$dir"
    chown munge:munge "$dir"
    chmod 0700 "$dir"
done

# ─────────────────────────────────────────────────────────────────────────────
# MASTER — generate key and stage on NFS share for compute nodes
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$THIS_NODE" == "master" ]]; then
    echo "[*] Generating 1024-byte MUNGE key"
    dd if=/dev/urandom bs=1 count=1024 \
       of=/etc/munge/munge.key status=none

    chown munge:munge /etc/munge/munge.key
    chmod 0400 /etc/munge/munge.key

    # Stage key on NFS home so compute nodes can pick it up
    echo "[*] Staging key on NFS share: $KEY_STAGE"
    mkdir -p "$KEY_STAGE"
    chmod 0700 "$KEY_STAGE"
    cp /etc/munge/munge.key "${KEY_STAGE}/munge.key"
    chmod 0600 "${KEY_STAGE}/munge.key"
    chown "${CLUSTER_USER}:${CLUSTER_USER}" "${KEY_STAGE}/munge.key"

    echo "[✓] Key staged. Run 04_munge.sh on each compute node to pick it up."

# ─────────────────────────────────────────────────────────────────────────────
# COMPUTE — pull key from NFS staging area
# ─────────────────────────────────────────────────────────────────────────────
else
    if [[ ! -f "${KEY_STAGE}/munge.key" ]]; then
        echo "[✗] Staged key not found at ${KEY_STAGE}/munge.key"
        echo "    Run 04_munge.sh master first."
        exit 1
    fi

    echo "[*] Copying key from NFS stage"
    cp "${KEY_STAGE}/munge.key" /etc/munge/munge.key
    chown munge:munge /etc/munge/munge.key
    chmod 0400 /etc/munge/munge.key
fi

# ── Verify key hash matches master ───────────────────────────────────────────
echo ""
echo "=== MUNGE key checksum (must be identical on all nodes) ==="
sha256sum /etc/munge/munge.key

# ── Start munge ───────────────────────────────────────────────────────────────
systemctl enable munge
systemctl restart munge

echo ""
echo "=== MUNGE service status ==="
systemctl is-active munge && echo "[✓] munge is active" || { echo "[✗] munge failed"; exit 1; }

# ── Local self-test ───────────────────────────────────────────────────────────
echo ""
echo "=== Local MUNGE self-test ==="
if munge -n | unmunge | grep -q "STATUS:.*Success"; then
    echo "[✓] Local munge/unmunge succeeded"
else
    echo "[✗] Local munge/unmunge FAILED"
    journalctl -u munge -n 20 --no-pager
    exit 1
fi

# ── Cross-node test (only from compute) ──────────────────────────────────────
if [[ "$THIS_NODE" != "master" ]]; then
    echo ""
    echo "=== Cross-node MUNGE test ($THIS_NODE → master) ==="
    if munge -n | ssh -o BatchMode=yes master unmunge | grep -q "Success"; then
        echo "[✓] Cross-node authentication succeeded"
    else
        echo "[✗] Cross-node authentication FAILED — check munge on master"
        exit 1
    fi
fi

# ── Cleanup staging key (run after all nodes are done) ───────────────────────
if [[ "$THIS_NODE" == "master" ]]; then
    echo ""
    echo "=== Cleanup ==="
    echo "When all compute nodes are configured, remove the staged key:"
    echo "  rm -rf ${KEY_STAGE}"
fi

echo ""
echo "[✓] 04_munge.sh complete for $THIS_NODE"
