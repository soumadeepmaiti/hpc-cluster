# mpi/Makefile
# Compile MPI programs for the 6-node HPC cluster validation suite

CC       = mpicc
CFLAGS   = -O2 -march=native -Wall -Wextra
LDFLAGS  = -lm

TARGETS  = mpi_hello mpi_scaling

.PHONY: all clean

all: $(TARGETS)

mpi_hello: mpi_hello.c
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS)

mpi_scaling: mpi_scaling.c
	$(CC) $(CFLAGS) $< -o $@ $(LDFLAGS)

clean:
	rm -f $(TARGETS)
