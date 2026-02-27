#!/bin/bash
#SBATCH --job-name=mpi_validation
#SBATCH --partition=compute
#SBATCH --nodes=5
#SBATCH --ntasks=40
#SBATCH --ntasks-per-node=8
#SBATCH --cpus-per-task=1
#SBATCH --time=00:10:00
#SBATCH --output=/home/paul/slurm_logs/%x-%j.out
#SBATCH --error=/home/paul/slurm_logs/%x-%j.err

# MPI validation job — verifies Slurm + OpenMPI integration across all nodes
# Uses srun --mpi=pmix for PMIx-based process management

echo "=== MPI Validation Job ==="
echo "Job ID     : $SLURM_JOB_ID"
echo "Job name   : $SLURM_JOB_NAME"
echo "Nodes      : $SLURM_JOB_NODELIST"
echo "Tasks      : $SLURM_NTASKS"
echo "Start time : $(date)"
echo ""

cd /home/paul/mpi_tests || { echo "ERROR: /home/paul/mpi_tests not found"; exit 1; }

# Compile if needed
if [[ ! -f mpi_hello ]]; then
    echo "Compiling mpi_hello..."
    make mpi_hello
fi

# ── Test 1: Hello world — verify rank distribution across nodes ───────────────
echo "--- Test 1: Rank distribution ---"
srun --mpi=pmix -n "$SLURM_NTASKS" ./mpi_hello
echo ""

# ── Test 2: Scaling benchmark ─────────────────────────────────────────────────
if [[ ! -f mpi_scaling ]]; then
    make mpi_scaling
fi

echo "--- Test 2: Strong scaling benchmark ($SLURM_NTASKS ranks) ---"
srun --mpi=pmix -n "$SLURM_NTASKS" ./mpi_scaling
echo ""

echo "End time   : $(date)"
echo "=== MPI Validation Complete ==="
