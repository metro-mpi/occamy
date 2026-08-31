# Getting Started: Metro-MPI Partitioned Occamy

This tree adds an automatic MPI-partitioning flow to upstream Occamy, built
on a custom Verilator fork ("Metro-MPI"). Given Occamy's existing,
unmodified RTL and Verilator build, the fork automatically finds a
repeated-module partition boundary (the Snitch compute clusters), analyzes
the ports crossing it, and generates everything needed to run the design as
several cooperating MPI processes instead of one monolithic simulation.

This document is a condensed quick-start. For full command-by-command
detail and background, see:
- `occamy_run_instructions.md` — the complete reference (RTL generation,
  partition analysis, build, run, both the structural and software-running
  flows, and both the 1×4 and 4×2 configurations).
- `MMPI_CONTEXT.md` — baseline (non-partitioned) Verilator bring-up notes.
- `MMPI_PARTITION.md` — why the 1×4 config (1 quadrant × 4 clusters) is the
  shape that makes the clusters a clean partition boundary.
- `RANK0_TB_MAIN.md` — what `rank0_tb_main.cc` does and why it's the only
  hand-written file in the software-running flow.

## 1. Prerequisites

You need two things beyond a normal Occamy checkout:

1. **The custom MPI Verilator fork**, built with an MPI-aware C++ compiler
   (`CXX=mpic++`) and linked against `libsodium`. Two variants matter:
   - a baseline build (supports the automatic/structural partition flow
     below);
   - the `verilator-dev` fork revision, which additionally supports
     `--mmpi-partition-module` (needed for the software-running flow, since
     it selects the cluster boundary explicitly rather than relying on the
     default heuristic).
2. **Bender**, a Python virtualenv with Occamy's RTL-generation dependencies
   (`hjson`, `mako`, `jsonschema`, ...), and the RISC-V toolchains to build
   host (CVA6) and device (Snitch) software.

`target/sim/native-env.sh` shows the exact environment variables this was
verified against — copy and adjust the paths for your machine, then
`source` it before running any `make` target below.

## 2. Structural partition flow (fast; proves the split builds and runs)

This keeps `occamy_quadrant_s1` as the Verilator top module, so the default
duplicate-hash selector finds the 4 `occamy_cluster_wrapper` instances as
the partition boundary automatically. Rank 0 is the quadrant's own
interconnect (not the full SoC), so this flow ticks the partitioned design
but does not boot software — it is the fast way to confirm the fork,
Bender, and RTL generation are all working together.

```bash
make rtl flist partition   # generate RTL, emit the file list, run the analysis
make build-mpi              # verilate + link rank 0 and the 4 cluster ranks
make run-mpi                 # launch all 5 ranks under mpirun
```

Override `OCCAMY_MPI_CYCLES=<N>` on `run-mpi` to change how many cycles are
ticked; see `make print-config` for the resolved paths/variables.

## 3. Software-running flow (boots a real RISC-V program)

This keeps `testharness` as the Verilator top module — so rank 0 is the
*entire* fesvr-backed SoC (boot ROM, HBM, UART, the CVA6 host core) — and
selects the cluster boundary explicitly with `--mmpi-partition-module`. The
result boots a real program and produces UART output identical to the
un-partitioned build.

```bash
# One-time baseline build (standard, non-partitioned Occamy flow):
make -C target/sim CFG_OVERRIDE=cfg/mmpi-1x4.hjson rtl
make -C target/sim CFG_OVERRIDE=cfg/mmpi-1x4.hjson bin/occamy_top.vlt
make -C target/sim CFG_OVERRIDE=cfg/mmpi-1x4.hjson DEBUG=ON sw

# The Metro-MPI software-running partition:
make partition-sw   # analysis + code generation (testharness top, cluster override)
make build-sw        # verilate + link rank 0 (fesvr SoC) and the cluster partition
make run-sw           # boots hello_world by default
```

Verify: `cat target/sim/uart0.log` should read `Hello world!`, matching the
un-partitioned `bin/occamy_top.vlt` run. `make run-sw ELF=<path>` runs a
different host ELF (path relative to `target/sim/`).

This flow takes noticeably longer than the structural one — verilating the
stubbed `testharness` alone takes several minutes, and a full `hello_world`
boot runs several million simulated cycles. Give it time before assuming it
has hung.

## 4. Interactive / manual boundary selection

`target/sim/spec.json` and `target/sim/sw_spec.json` are worked examples of
the manual selection path: instead of relying on automatic detection or the
`--mmpi-partition-module` override, export the elaborated hierarchy with
`--mmpi-out`, hand-pick instances into rank buckets (either by hand or with
the companion Streamlit partition viewer), and re-import the result with
`--mmpi-in` to generate the same way. Both example specs assign the same 4
clusters to ranks 1–4, one at each of the two top-module scopes used above.

## 5. Repo layout note

Everything the `make` targets above *generate* (RTL under `target/sim/src/`,
hierarchy dumps like `design.json`, and every `work-mmpi-*/`/`work-vlt/`
build directory) is intentionally excluded from version control — see
`.gitignore` — because it's large (multiple GB) and fully reproducible from
the commands above. What's committed is exactly the source-level additions:
this Makefile, the two `mmpi-*.hjson` config variants, `rank0_tb_main.cc`,
the fesvr patch, and the documentation.
