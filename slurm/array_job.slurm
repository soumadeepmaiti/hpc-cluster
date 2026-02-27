#!/bin/bash
#SBATCH --job-name=parameter_sweep
#SBATCH --partition=compute
#SBATCH --array=1-20%5
#   ↑ 20 tasks, max 5 running simultaneously
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --cpus-per-task=1
#SBATCH --time=01:00:00
#SBATCH --output=/home/paul/slurm_logs/%x-%A_%a.out
#SBATCH --error=/home/paul/slurm_logs/%x-%A_%a.err

# Job array example — parameter sweep
# SLURM_ARRAY_TASK_ID gives the current array index (1–20)
# Each task reads its parameter from a params file or computes it from the index

echo "=== Array Job ==="
echo "Array Job ID  : $SLURM_ARRAY_JOB_ID"
echo "Array Task ID : $SLURM_ARRAY_TASK_ID"
echo "Running on    : $(hostname)"
echo "Tasks         : $SLURM_NTASKS"

# Example: map task ID to a simulation parameter
PARAM=$(awk "NR==$SLURM_ARRAY_TASK_ID" /home/paul/params.txt 2>/dev/null \
        || echo "param_${SLURM_ARRAY_TASK_ID}")

echo "Parameter     : $PARAM"
echo ""

# Replace with actual simulation command, e.g.:
#   srun ./my_simulation --param "$PARAM" --output "results_${SLURM_ARRAY_TASK_ID}.h5"

# Placeholder workload
srun -n "$SLURM_NTASKS" bash -c \
    'echo "Rank=$SLURM_PROCID on $(hostname) — task '"$SLURM_ARRAY_TASK_ID"'"'

echo ""
echo "=== Task $SLURM_ARRAY_TASK_ID complete ==="
