/*
 * mpi/mpi_hello.c
 * ─────────────────────────────────────────────────────────────────────────────
 * MPI hello-world for validating Slurm + OpenMPI integration.
 * Each rank prints its rank number, total size, and the hostname it runs on.
 *
 * Compile:  mpicc -O2 -Wall mpi_hello.c -o mpi_hello
 * Run via Slurm:  sbatch mpi_test.slurm
 * ─────────────────────────────────────────────────────────────────────────────
 */
#include <mpi.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char** argv)
{
    MPI_Init(&argc, &argv);

    int rank, size;
    char hostname[256];

    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    gethostname(hostname, sizeof(hostname));

    /* Serialise output: rank 0 prints first, then signals next */
    if (rank == 0) {
        printf("MPI validation — %d ranks across %s\n", size, hostname);
        fflush(stdout);
    }

    /* Barrier so all lines arrive in order */
    MPI_Barrier(MPI_COMM_WORLD);

    for (int i = 0; i < size; i++) {
        if (rank == i) {
            printf("  Rank %3d / %d   host: %s\n", rank, size, hostname);
            fflush(stdout);
        }
        MPI_Barrier(MPI_COMM_WORLD);
    }

    MPI_Finalize();
    return 0;
}
