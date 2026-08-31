// Rank-0 (system) fesvr testbench for the Metro-MPI-partitioned Occamy.
//
// This is Occamy-specific GLUE that lives OUTSIDE Verilator: it is just the
// stock Snitch/Occamy fesvr testbench main (target/common/test/tb_bin.cc) with
// the three integration hooks the generated metro_mpi/README_integration.txt
// prescribes, so rank 0 boots a host ELF (e.g. hello_world) on the full SoC
// while the 4 occamy_cluster_wrapper instances run as MPI partition ranks.
//
//   - #include the generated rank0_harness.h   (defines the DPI function
//     dpi_occamy_cluster_wrapper that the generated quadrant stub calls, which
//     marshals the cluster ports to/from the cluster ranks over MPI)
//   - mpi_initialize() before the sim runs (the DPI is invoked during eval)
//   - metro_mpi_broadcast_shutdown() + mpi_finalize() after the program's
//     tohost exit, so the cluster ranks terminate cleanly.
//
// Build: substitute this file for tb_bin.cc in the rank-0 link, and additionally
// compile metro_mpi/metro_mpi.cpp as its own TU (G47 split). Verilator is NOT
// modified — only generated files + this glue are used.

#include <cstdio>

#include "sim.hh"

#include "rank0_harness.h"  // generated; pulls in metro_mpi.h (mpi_initialize/finalize)

int main(int argc, char **argv, char **env) {
    // Bring up MPI before the first eval (the quadrant DPI stub talks to the
    // cluster ranks during simulation).
    mpi_initialize();

    // Write binary path to .rtlbinary for the `make annotate` target (stock TB).
    FILE *fd;
    fd = fopen(".rtlbinary", "w");
    if (fd != NULL && argc >= 2) {
        fprintf(fd, "%s\n", argv[1]);
        fclose(fd);
    } else {
        fprintf(stderr, "Warning: Failed to write binary name to .rtlbinary\n");
    }

    // Stock Occamy fesvr run: loads the ELF, boots the host core, runs to the
    // program's tohost exit. The 4 clusters are DPI-stubbed -> MPI partition ranks.
    auto sim = std::make_unique<sim::Sim>(argc, argv);
    int ret = sim->run();

    // Tell the cluster ranks to stop, then tear down MPI.
    metro_mpi_broadcast_shutdown();
    mpi_finalize();
    return ret;
}
