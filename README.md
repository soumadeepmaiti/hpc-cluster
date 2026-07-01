# Linux HPC Cluster

A production-grade HPC cluster built from bare-metal desktop workstations for simulation workloads.

---

## Cluster Architecture

```
                        ┌─────────────────────────────────┐
                        │           MASTER NODE            │
                        │   192.168.50.1  (master)        │
                        │                                  │
                        │  slurmctld  munged  nfs-server  │
                        │  chronyd    iptables NAT         │
                        └──────────────┬──────────────────┘
                                       │ enp0s25  (GbE switch)
              ┌────────────────────────┼───────────────────────┐
              │                        │                        │
   ┌──────────┴───────┐    ┌──────────┴───────┐   ┌──────────┴───────┐
   │   compute01      │    │   compute02      │   │   compute03      │
   │ 192.168.50.11    │    │ 192.168.50.12    │   │ 192.168.50.13    │
   │  slurmd  munged  │    │  slurmd  munged  │   │  slurmd  munged  │
   └──────────────────┘    └──────────────────┘   └──────────────────┘
```

| Node | Hostname | Role | CPUs | RAM |
|------|----------|------|------|-----|
| 0 | master | Controller + Login | 8 | 16 GB |
| 1 | compute01 | Compute | 8 | 16 GB |
| 2 | compute02 | Compute | 8 | 16 GB |
| 3 | compute03 | Compute | 8 | 16 GB |
| 4 | compute04 | Compute | 8 | 16 GB |
| 5 | compute05 | Compute | 8 | 16 GB |

---

## Software Stack

| Layer | Technology |
|-------|-----------|
| OS | Ubuntu 24.04 LTS |
| Workload Manager | Slurm 23.11.4 |
| Authentication | MUNGE 0.5.15 |
| Shared Storage | NFSv4 |
| Time Sync | chronyd (NTP hierarchy) |
| MPI | OpenMPI 4.1.6 |
| Firewall | iptables + ufw |

---

## Repository Structure

```
hpc-cluster/
├── setup/                  # One-time deployment scripts
│   ├── 01_network.sh       # Static IP, /etc/hosts, hostname
│   ├── 02_ntp.sh           # chronyd NTP hierarchy setup
│   ├── 03_nfs.sh           # NFS server (master) and client (compute)
│   ├── 04_munge.sh         # MUNGE key generation and distribution
│   ├── 05_slurm_master.sh  # slurmctld + slurm.conf deployment
│   └── 06_slurm_compute.sh # slurmd deployment on compute nodes
├── configs/
│   ├── slurm.conf          # Slurm workload manager config
│   ├── cgroup.conf         # Slurm cgroup resource enforcement
│   ├── chrony_master.conf  # NTP server config for master
│   ├── chrony_compute.conf # NTP client config for compute nodes
│   └── hosts               # /etc/hosts for all nodes
├── monitoring/
│   ├── health_check.sh     # Node health check (CPU, RAM, disk, Slurm)
│   ├── cluster_status.sh   # Cluster-wide status dashboard
│   └── node_report.sh      # Per-node resource utilisation report
├── backup/
│   ├── backup_configs.sh   # Backup Slurm state, MUNGE key, configs
│   └── restore_configs.sh  # Restore from backup after failure
├── slurm/
│   ├── mpi_test.slurm      # MPI validation job (srun --mpi=pmix)
│   ├── array_job.slurm     # Job array example
│   └── gpu_job.slurm       # GPU job template (GRES)
├── mpi/
│   ├── mpi_hello.c         # MPI hello-world rank/host validation
│   ├── mpi_scaling.c       # Strong scaling benchmark
│   └── Makefile
├── scripts/
│   ├── add_node.sh         # Add new compute node to running cluster
│   ├── drain_node.sh       # Gracefully drain a node for maintenance
│   └── fix_node_state.sh   # Clear DOWN/DRAIN state after slurmd restart
└── docs/
    ├── DEPLOYMENT.md       # Step-by-step deployment guide
    ├── TROUBLESHOOTING.md  # Common failures and fixes
    └── OPERATIONS.md       # Day-to-day cluster operations
```

---

## Automated Maintenance (cron + systemd)

All recurring operational tasks run unattended via cron and systemd timers:

| Task | Schedule | Mechanism |
|------|----------|-----------|
| Node health check | Every 5 min | systemd timer |
| Config + state backup | Daily 02:00 | cron |
| Log rotation | Daily 03:00 | cron + logrotate |
| Cluster status report | Every 15 min | cron |
| Slurm accounting purge | Weekly Sunday | cron |

---
