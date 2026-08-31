# `rank0_tb_main.cc` — the only hand-written file for the software-running Occamy partition

This documents the **single** file I had to write by hand to make the Metro-MPI-partitioned
Occamy boot and run a real program (`hello_world`) to completion, matching the unpartitioned
simulator (see `occamy_run_instructions.md` Part 4). Canonical copy: `occamy/rank0_tb_main.cc`.

## What it is

It is the **rank-0 (system) testbench main** for the partitioned run. Rank 0 is the *full*
fesvr-backed Occamy SoC (CVA6 host + HBM + bootrom + fesvr); the 4 `occamy_cluster_wrapper`
Snitch clusters are split off as MPI ranks 1–4 (DPI stubs in rank 0).

It is a **near-verbatim copy of the stock Snitch/Occamy fesvr testbench**
(`.bender/.../target/common/test/tb_bin.cc`) with only the **three integration hooks** that
the generator's own `metro_mpi/README_integration.txt` prescribes. Nothing Occamy-specific
was added to Verilator — this file is the entire hand-written surface.

## Why it is needed (and why it is NOT in Verilator)

- The generator (Fix C) emits a default `<top>_rank0_main.cpp` driver **only when there is no
  `-exe` testbench**. For a *software* run, rank 0 must be the real fesvr testbench (it loads
  the ELF, boots the host, polls `tohost`) — a generic clock-ticking driver cannot boot
  software. So we pass the real TB as `-exe` (gating Fix C off) and integrate the harness into
  it here.
- The integration is **design/testbench-specific** (it depends on Occamy's `sim::Sim` TB
  framework), which is exactly the kind of thing that must stay **outside** the general tool.
  Verilator only emits the generic pieces: the DPI stub, the wrappers, the rewritten parent,
  `metro_mpi.{h,cpp}`, and `rank0_harness.h`. This file wires `rank0_harness.h` into Occamy's
  TB.

## The three hooks (the only diff vs the stock `tb_bin.cc`)

| Hook | Where | Why |
| --- | --- | --- |
| `#include "rank0_harness.h"` | top of file | Defines `dpi_occamy_cluster_wrapper(...)` — the imported DPI the generated quadrant stub calls each cycle, which marshals the cluster ports to/from the cluster ranks over MPI. Also pulls in `metro_mpi.h` (the lifecycle calls). |
| `mpi_initialize();` | first line of `main()`, **before** `sim::Sim` | The DPI fires during `eval()`, so MPI must be up before the first cycle. |
| `metro_mpi_broadcast_shutdown(); mpi_finalize();` | **after** `sim->run()` returns | After the program hits `tohost`, tell ranks 1–4 to exit, then tear down MPI cleanly. |

Everything else (the `.rtlbinary` write, `std::make_unique<sim::Sim>(argc, argv)`,
`sim->run()`) is the stock testbench, unchanged.

## The file

```cpp
#include <cstdio>
#include "sim.hh"
#include "rank0_harness.h"          // generated; defines the DPI + pulls in metro_mpi.h

int main(int argc, char **argv, char **env) {
    mpi_initialize();                            // (1) before the sim (DPI runs during eval)

    FILE *fd = fopen(".rtlbinary", "w");         // stock TB bookkeeping
    if (fd != NULL && argc >= 2) { fprintf(fd, "%s\n", argv[1]); fclose(fd); }
    else fprintf(stderr, "Warning: Failed to write binary name to .rtlbinary\n");

    auto sim = std::make_unique<sim::Sim>(argc, argv);  // stock fesvr run: ELF -> boot -> tohost
    int ret = sim->run();

    metro_mpi_broadcast_shutdown();              // (2) signal the cluster ranks to exit
    mpi_finalize();                              // (3) clean up MPI
    return ret;
}
```

## How it is built / linked

- Compile against the **partition's** generated `Vmdir_sys` headers and the `metro_mpi/` dir
  (for `rank0_harness.h`), with `-std=gnu++20 -fcoroutines` and the fesvr/Snitch-TB include set.
- It **replaces** `tb_bin.o` in the rank-0 link. Additionally compile `metro_mpi/metro_mpi.cpp`
  as its own translation unit (the G47 split — do not also `#include` it) and link it in.
- Link with the verilated stubbed-testharness archive (`Vtestharness__ALL.a`), the reused
  Snitch TB objects (`common_lib`/`ipc`/`bootrom`/`bootdata`/`uartdpi`), the verilated runtime,
  and `-lfesvr -lpthread -lsodium` via `mpic++`.

Full command sequence is in `occamy_run_instructions.md` §4.3.

## Status

Verified on `occamy-orig`, 1×4 config (2026-06-25): the partitioned run with this driver boots
`hello_world` and prints `Hello world!` with `mpirun` exit 0 — identical to the unpartitioned
golden run. It is the only file written by hand; the tool and all other inputs are generated.
