/*
 * mpi/mpi_scaling.c
 * ─────────────────────────────────────────────────────────────────────────────
 * Strong scaling benchmark — distributes a fixed workload across N ranks
 * and measures wall-clock time and efficiency.
 *
 * Each rank computes a partial sum of sin/cos over a shared iteration space.
 * Rank 0 collects results via MPI_Reduce and reports timing.
 *
 * Compile:  mpicc -O2 -march=native -Wall mpi_scaling.c -o mpi_scaling -lm
 * Run via Slurm:  sbatch with varying --ntasks (1, 2, 4, 8, 16, 32, 40)
 * ─────────────────────────────────────────────────────────────────────────────
 */
#include <mpi.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define N_TOTAL 400000000L   /* fixed problem size */

int main(int argc, char** argv)
{
    MPI_Init(&argc, &argv);

    int rank, size;
    char hostname[256];
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    gethostname(hostname, sizeof(hostname));

    /* Each rank owns iterations [rank, rank+size, rank+2*size, ...] */
    long local_n = N_TOTAL / size;
    long start   = (long)rank * local_n;
    long end     = (rank == size - 1) ? N_TOTAL : start + local_n;

    double t0 = MPI_Wtime();

    double local_sum = 0.0;
    for (long i = start; i < end; i++) {
        double x = (double)i * 1e-8;
        local_sum += sin(x) * cos(x * 0.5);
    }

    double global_sum = 0.0;
    MPI_Reduce(&local_sum, &global_sum, 1, MPI_DOUBLE, MPI_SUM, 0, MPI_COMM_WORLD);

    double elapsed = MPI_Wtime() - t0;
    double max_elapsed;
    MPI_Reduce(&elapsed, &max_elapsed, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        printf("=== MPI Strong Scaling Benchmark ===\n");
        printf("  Ranks        : %d\n", size);
        printf("  Problem size : %ld iterations\n", N_TOTAL);
        printf("  Wall time    : %.4f s\n", max_elapsed);
        printf("  Checksum     : %.10f\n", global_sum);
        printf("  MFLOP/s est. : %.1f\n",
               (double)N_TOTAL * 4 / max_elapsed / 1e6);
    }

    MPI_Finalize();
    return 0;
}
