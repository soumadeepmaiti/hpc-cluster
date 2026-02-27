# Troubleshooting Guide

Production failures encountered during cluster build and operation, with
root cause analysis and resolution for each.

---

## 1. NFS UID Mismatch — "Security violation, ping RPC from uid 995"

**Symptom**
```
slurmd: error: Security violation, ping RPC from uid 995
slurmd: error: Do you have SlurmUser configured as uid 995?
```
Node shows `Not responding` in `sinfo` despite slurmd being active and network
reachable.

**Root Cause**
The `slurm` system user was created by the package manager independently on
each node. Ubuntu assigns UIDs sequentially, so `slurm` got UID 995 on the
controller but UID 64030 on compute nodes (installed later). Slurm's
authentication is **UID-based**, not name-based: the controller sends RPCs as
UID 995, but slurmd on the compute node doesn't recognise that UID as
`SlurmUser`.

**Resolution**
```bash
# On every compute node — align to master's slurm UID/GID
MASTER_UID=$(ssh master 'id -u slurm')
MASTER_GID=$(ssh master 'id -g slurm')

sudo systemctl stop slurmd
sudo groupmod -g "$MASTER_GID" slurm
sudo usermod  -u "$MASTER_UID" -g "$MASTER_GID" slurm
sudo chown -R slurm:slurm /var/spool/slurmd /var/log/slurm
sudo systemctl start slurmd
```

Automated by: `scripts/fix_node_state.sh`

---

## 2. Slurm State Corruption — "CLUSTER NAME MISMATCH"

**Symptom**
```
slurmctld: fatal: CLUSTER NAME MISMATCH.
slurmctld has been started with "ClusterName=tum-hpc", but read "cluster"
from the state files in StateSaveLocation.
Running multiple clusters from a shared StateSaveLocation WILL CAUSE CORRUPTION.
```

**Root Cause**
`ClusterName` in `slurm.conf` was changed during initial setup experiments
(e.g. `cluster` → `tum-hpc`). Slurm writes the cluster name to
`/var/spool/slurmctld/clustername` and refuses to start if the file
contradicts the current config — a safety mechanism against accidental
cross-cluster state sharing.

**Resolution**
```bash
# Stop controller, remove the stale clustername file, restart
sudo systemctl stop slurmctld
sudo rm -f /var/spool/slurmctld/clustername
sudo systemctl start slurmctld

# Verify
scontrol ping
sinfo
```

---

## 3. SSH/VPN Conflict — Wrong IP for "master"

**Symptom**
`munge -n | ssh master unmunge` hangs indefinitely. The cross-node test never
returns, yet `ping master` works.

**Root Cause**
Tailscale (VPN) was installed on both nodes for remote access. It registered
a `Host master` entry in `~/.ssh/config` pointing to the Tailscale IP
`100.115.255.126` rather than the cluster LAN IP `192.168.50.1`. SSH was
silently connecting to the Tailscale address, which was either firewalled or
the Tailscale daemon was not accepting the connection.

```
debug2: resolve_canonicalize: hostname 100.115.255.126 is address
debug1: Connecting to 100.115.255.126 [100.115.255.126] port 22.
```

**Resolution**
```bash
# Override the Tailscale alias in ~/.ssh/config on slave nodes
cat >> ~/.ssh/config <<'EOF'
Host master
    HostName 192.168.50.1
    User paul
    IdentitiesOnly yes
EOF

# Verify
ssh -v master hostname 2>&1 | grep 'Connecting to'
# Must show: Connecting to 192.168.50.1
```

---

## 4. slurmd Restart Loop — Node Flapping

**Symptom**
`sinfo` shows the node alternating between `idle` and `not responding` every
30–60 seconds:
```
slurmctld: Node compute03 now responding
slurmctld: Node compute03 not responding
slurmctld: Node compute03 now responding   (repeated)
```
`journalctl -u slurmd` shows repeated `Stopping … Starting …` entries.

**Root Cause**
Ubuntu ships `slurmd.service` with `Restart=on-failure` (or `always`).
Slurm expects `slurmd` to be long-lived; any brief controller disconnection
causes slurmd to exit, which systemd immediately restarts. The restarting
daemon generates a fresh "hello" RPC to the controller mid-session, which the
controller sees as a disappearance followed by re-registration — triggering the
flap cycle.

**Resolution**
```bash
# On each compute node: override systemd restart policy
sudo mkdir -p /etc/systemd/system/slurmd.service.d
cat | sudo tee /etc/systemd/system/slurmd.service.d/override.conf <<'EOF'
[Service]
Restart=no
EOF
sudo systemctl daemon-reload
sudo systemctl restart slurmd
```

Automated by: `setup/06_slurm_compute.sh`

---

## 5. chronyd Not Serving — Compute Nodes Show `^?`

**Symptom**
```
chronyc sources -v
MS Name/IP address  Stratum Poll Reach LastRx Last sample
^? master                 0    6     0     -     +0ns[   +0ns] +/-    0ns
```
Compute node time drifts; MUNGE authentication becomes intermittently invalid.

**Root Cause**
`chrony.conf` on the master was missing two required directives:
- `allow 192.168.50.0/24` — without this, chronyd refuses to serve NTP
  responses to clients outside localhost
- `local stratum 10` — without this, if the master's upstream sync fails
  temporarily, it stops responding to NTP queries entirely

**Resolution**
Add both lines to `/etc/chrony/chrony.conf` on master:
```
allow 192.168.50.0/24
local stratum 10
```
Then restart: `sudo systemctl restart chrony`

Verify: `chronyc sources -v` on compute should show `^*` or `^+` for master.

Correct config: `configs/chrony_master.conf`

---

## 6. "Node not found" After slurm.conf Update

**Symptom**
```
slurmctld: error: slurmd registered on unknown node compute06
```

**Root Cause**
`slurm.conf` was updated on master (new `NodeName=compute06` added) but not
copied to the compute nodes, or `scontrol reconfigure` was not run. The
controller's in-memory node table and the slurmd config diverged.

**Resolution**
```bash
# Sync config to all nodes and reconfigure (no restart needed)
for node in compute01 compute02 compute03 compute04 compute05; do
    scp /etc/slurm/slurm.conf "${node}:/etc/slurm/slurm.conf"
    ssh "$node" 'sudo systemctl restart slurmd'
done
scontrol reconfigure
```

---

## Quick Diagnostic Commands

```bash
# Cluster overview
sinfo -N -l

# Check all DOWN/DRAIN nodes
sinfo -R

# Show specific node details
scontrol show node compute03

# MUNGE cross-node test
munge -n | ssh compute03 unmunge

# Slurm controller log (last 50 lines)
sudo journalctl -u slurmctld -n 50 --no-pager

# slurmd log on compute node
ssh compute03 'sudo journalctl -u slurmd -n 50 --no-pager'

# Check slurm UID consistency
for n in compute{01..05}; do echo "$n: $(ssh $n 'id slurm')"; done

# Check slurm.conf hash consistency
for n in compute{01..05}; do
    echo "$n: $(ssh $n 'sha256sum /etc/slurm/slurm.conf | awk "{print \$1}"')"
done
echo "master: $(sha256sum /etc/slurm/slurm.conf | awk '{print $1}')"
```
