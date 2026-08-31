# Occamy Verilator Context for Metro-MPI Bring-Up

This note records the local Occamy setup used before trying the modified
Metro-MPI Verilator flow from `../verilator-private`.  The immediate goal was
to prove that a non-trivial Occamy configuration can be generated, Verilated,
built, and ticked with the local Verilator install before adding `--mmpi-o1`.

The MMPI notes in `../verilator-private/MMPI_CONTEXT.md` were read first.  For
this pass, no MMPI flags were used; this is the baseline Verilator sanity
check.

## Result Summary

- Local Verilator used:
  `../verilator-private/verilator-install/bin/verilator`
- Reported version:
  `Verilator 5.044 2026-01-01 rev v5.036-106-g31497e78d`
- Full Occamy config (`target/sim/cfg/full.hjson`) was generated, but a
  `testharness` lint-only Verilator run was killed by signal 9 after about
  952 s on this machine.
- A reduced but still repeated design was created:
  `target/sim/cfg/mmpi-2x2.hjson`
  - `nr_s1_quadrant: 2`
  - `s1_quadrant.nr_clusters: 2`
  - Total cluster wrappers: 4
  - Snitch harts traced by the smoke run: 36 (`4 clusters * 9 harts`)
- The 2x2 `testharness` passed Verilator frontend elaboration.
- The 2x2 C++ model built successfully.
- The 2x2 bounded smoke simulation ran for 20 cycles and exited with status 0.

## Relevant Local Structure

```text
../verilator-private/
  MMPI_CONTEXT.md
  verilator-install/bin/verilator
  src/V3Metro_MPI.cpp, src/V3MMPI_*.cpp, ...

occamy/
  Bender.yml
  Bender.lock
  Bender.local
  hw/occamy/*.sv.tpl
  hw/spm_interface/
  hw/vendor/
    openhwgroup_cva6/
    pulp_platform_axi_tlb/
    pulp_platform_opentitan_peripherals/
  target/sim/
    Makefile
    cfg/
      full.hjson
      single-cluster.hjson
      mmpi-2x2.hjson
    src/                 # generated RTL, ignored by target/sim/.gitignore
    test/
      testharness.sv
      uartdpi/
    work/                # Verilator work dirs, ignored
  deps/                  # Bender link, ignored
  .bender/               # Bender checkouts, ignored
```

`testharness` is the useful top for simulation.  It instantiates `occamy_top`,
HBM memory models, boot ROM/FLL register-memory stubs, PCIe memory, and UART
DPI.  Verilating `occamy_top` alone would require manually tying many external
ports.

## Tool Setup Used

Bender was not initially installed in `PATH`, so it was installed locally
outside the Occamy repository:

```bash
cd /home/kislay/Documents/gsoc
cargo install --git https://github.com/pulp-platform/bender \
  --root /home/kislay/Documents/gsoc/.codex-tools bender
```

Python generator dependencies were installed in a local venv outside the repo:

```bash
cd /home/kislay/Documents/gsoc
python3 -m venv /home/kislay/Documents/gsoc/.codex-venvs/occamy
/home/kislay/Documents/gsoc/.codex-venvs/occamy/bin/pip install \
  hjson jsonref mako jsonschema pyyaml tabulate pyelftools setuptools==80.9.0
```

`setuptools==80.9.0` matters because lowRISC `regtool.py` imports
`pkg_resources`; newer setuptools in this environment did not provide it.

Useful environment variables:

```bash
export GSOC=/home/kislay/Documents/gsoc
export OCCAMY=$GSOC/occamy
export BENDER=$GSOC/.codex-tools/bin/bender
export VENV=$GSOC/.codex-venvs/occamy
export VLT=$GSOC/verilator-private/verilator-install/bin/verilator
export PATH=$VENV/bin:$GSOC/.codex-tools/bin:$PATH
```

## Dependency Checkout

From the Occamy root:

```bash
cd $OCCAMY
$BENDER checkout
```

This created ignored Bender checkout/link directories:

```text
occamy/.bender/git/checkouts/...
occamy/deps/snitch_cluster -> .bender/git/checkouts/snitch_cluster-...
```

## RTL Generation

The full config was generated first:

```bash
cd $OCCAMY/target/sim
PATH=$VENV/bin:$GSOC/.codex-tools/bin:$PATH \
make BENDER=$BENDER VERIBLE_FMT=true CFG_OVERRIDE=cfg/full.hjson rtl
```

`VERIBLE_FMT=true` was used because `verible-verilog-format` was not installed.
This bypasses formatting only; it does not affect whether Verilator can parse
or elaborate the design.

The reduced MMPI trial config was then made from the full config:

```bash
cd $OCCAMY
cp target/sim/cfg/full.hjson target/sim/cfg/mmpi-2x2.hjson
sed -i \
  -e 's/nr_s1_quadrant: 6,/nr_s1_quadrant: 2,/' \
  -e 's/nr_clusters: 4,/nr_clusters: 2,/' \
  target/sim/cfg/mmpi-2x2.hjson
```

Generate RTL for the 2x2 config:

```bash
cd $OCCAMY/target/sim
PATH=$VENV/bin:$GSOC/.codex-tools/bin:$PATH \
make BENDER=$BENDER VERIBLE_FMT=true CFG_OVERRIDE=cfg/mmpi-2x2.hjson rtl
```

Generated top-level files included:

```text
target/sim/src/occamy_pkg.sv
target/sim/src/occamy_top.sv
target/sim/src/occamy_soc.sv
target/sim/src/occamy_quadrant_s1.sv
target/sim/src/occamy_quadrant_s1_ctrl.sv
target/sim/src/occamy_cluster_wrapper.sv
target/sim/src/occamy_cva6.sv
target/sim/test/testharness.sv
```

## Bender Verilator File List

Create a work directory and emit Bender's Verilator file list:

```bash
cd $OCCAMY
mkdir -p target/sim/work/occamy_2x2_vlt

$BENDER script verilator \
  -t rtl \
  -t occamy_sim \
  -t snitch_cluster \
  -t cv64a6_imafdc_sv39 \
  -DCOMMON_CELLS_ASSERTS_OFF \
  > target/sim/work/occamy_2x2_vlt/files
```

Observed size:

```text
1263 lines
96 KiB
```

## Smoke Harness

For a bounded hardware-only smoke test, the harness in
`target/sim/work/occamy_2x2_vlt/sim_main.cpp` instantiates `Vtestharness`,
drives `clk_i` and `rst_ni`, and exits after `OCCAMY_SMOKE_CYCLES` cycles.

```cpp
#include "Vtestharness.h"
#include "verilated.h"

#include <cstdlib>

int main(int argc, char** argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);

    Vtestharness top{&context};

    const char* cycles_env = std::getenv("OCCAMY_SMOKE_CYCLES");
    const vluint64_t cycles = cycles_env ? std::strtoull(cycles_env, nullptr, 0) : 20;

    top.clk_i = 0;
    top.rst_ni = 0;

    for (vluint64_t cycle = 0; cycle < cycles && !context.gotFinish(); ++cycle) {
        top.rst_ni = cycle >= 5;

        top.clk_i = 0;
        top.eval();
        context.timeInc(5);

        top.clk_i = 1;
        top.eval();
        context.timeInc(5);
    }

    top.final();
    return 0;
}
```

The generated `testharness` imports DPI symbols for memory and UART.  For this
baseline smoke test, a minimal `smoke_dpi.cpp` was used instead of the full
Snitch/FESVR runtime:

- `tb_memory_read`
- `tb_memory_write`
- `uartdpi_create`
- `uartdpi_close`
- `uartdpi_can_read`
- `uartdpi_read`
- `uartdpi_write`

The memory shim is byte-addressable and page-backed.  UART is a no-op.  This is
enough to prove that the Verilated hardware model can instantiate and tick; it
is not a full software/HTIF simulation.

## Verilator Warning Flags

These warnings were suppressed for the feasibility run:

```bash
VLT_WARN_FLAGS="
  -Wno-BLKANDNBLK
  -Wno-LITENDIAN
  -Wno-CASEINCOMPLETE
  -Wno-CMPCONST
  -Wno-WIDTH
  -Wno-WIDTHCONCAT
  -Wno-UNSIGNED
  -Wno-UNOPTFLAT
  -Wno-MODDUP
  -Wno-PINMISSING
  -Wno-IMPLICITSTATIC
  -Wno-ALWCOMBORDER
  -Wno-SYMRSVDWORD
  -Wno-LATCH
  -Wno-COMBDLY
  -Wno-SHORTREAL
  -Wno-fatal
"
```

Warnings seen without these suppressions were mostly duplicate modules from
overlapping package sources, missing pins in existing IP wrappers, latch/order
warnings, and `shortreal` promotion in Snitch tracing.

## 2x2 Frontend Check

Command:

```bash
cd $OCCAMY
$VLT \
  --Mdir target/sim/work/occamy_2x2_vlt \
  -f target/sim/work/occamy_2x2_vlt/files \
  -Wno-BLKANDNBLK -Wno-LITENDIAN -Wno-CASEINCOMPLETE -Wno-CMPCONST \
  -Wno-WIDTH -Wno-WIDTHCONCAT -Wno-UNSIGNED -Wno-UNOPTFLAT \
  -Wno-MODDUP -Wno-PINMISSING -Wno-IMPLICITSTATIC -Wno-ALWCOMBORDER \
  -Wno-SYMRSVDWORD -Wno-LATCH -Wno-COMBDLY -Wno-SHORTREAL -Wno-fatal \
  --unroll-count 1024 \
  --timing \
  --top-module testharness \
  --lint-only
```

Observed result:

```text
exit code: 0
Built from 2522.949 MB sources in 697 modules,
into 931.889 MB in 995 C++ files
Walltime 117.038 s
alloced 10721.559 MB
```

## 2x2 C++ Model Build

Command:

```bash
cd $OCCAMY
$VLT \
  --Mdir target/sim/work/occamy_2x2_vlt \
  -f target/sim/work/occamy_2x2_vlt/files \
  -Wno-BLKANDNBLK -Wno-LITENDIAN -Wno-CASEINCOMPLETE -Wno-CMPCONST \
  -Wno-WIDTH -Wno-WIDTHCONCAT -Wno-UNSIGNED -Wno-UNOPTFLAT \
  -Wno-MODDUP -Wno-PINMISSING -Wno-IMPLICITSTATIC -Wno-ALWCOMBORDER \
  -Wno-SYMRSVDWORD -Wno-LATCH -Wno-COMBDLY -Wno-SHORTREAL -Wno-fatal \
  --unroll-count 1024 \
  --timing \
  --top-module testharness \
  --cc \
  --exe \
    target/sim/work/occamy_2x2_vlt/sim_main.cpp \
    target/sim/work/occamy_2x2_vlt/smoke_dpi.cpp \
  --build \
  -j 1 \
  -CFLAGS "-std=c++14 -pthread"
```

Observed result:

```text
exit code: 0
Generated binary: target/sim/work/occamy_2x2_vlt/Vtestharness
Binary size: 92 MB
Built from 2522.949 MB sources in 697 modules,
into 1280.964 MB in 1354 C++ files
Walltime 1692.867 s
alloced 10711.309 MB
```

The first link attempt used `target/sim/test/uartdpi/uartdpi.c` and failed:

```text
undefined symbol: tb_memory_read
undefined symbol: tb_memory_write
undefined symbol: uartdpi_create / uartdpi_close / uartdpi_read / ...
```

The memory symbols come from Snitch's simulation runtime.  The UART symbols were
also name-mangled because the `.c` file was compiled by `mpic++`.  The minimal
`smoke_dpi.cpp` avoided both issues for this hardware-only smoke test.

## 2x2 Bounded Simulation

Zero-cycle startup/finalization check:

```bash
cd $OCCAMY/target/sim
timeout 180 env OCCAMY_SMOKE_CYCLES=0 \
  work/occamy_2x2_vlt/Vtestharness
```

Observed result:

```text
exit code: 0
```

One-cycle check:

```bash
cd $OCCAMY/target/sim
timeout 300 env OCCAMY_SMOKE_CYCLES=1 \
  work/occamy_2x2_vlt/Vtestharness
```

Observed result:

```text
exit code: 0
Tracer logs opened for harts 1 through 36
```

Twenty-cycle smoke run:

```bash
cd $OCCAMY/target/sim
timeout 300 env OCCAMY_SMOKE_CYCLES=20 \
  work/occamy_2x2_vlt/Vtestharness
```

Observed result:

```text
exit code: 0
Tracer logs opened for harts 1 through 36
```

Representative output:

```text
[Tracer] Logging Hart          1 to logs/trace_hart_00001.dasm
[Tracer] Logging Hart          2 to logs/trace_hart_00002.dasm
...
[Tracer] Logging Hart         35 to logs/trace_hart_00023.dasm
[Tracer] Logging Hart         36 to logs/trace_hart_00024.dasm
```

The run writes trace files under `target/sim/logs/`, which is ignored by the
target-level `.gitignore`.

## Full Config Attempt

The full config has:

```text
nr_s1_quadrant: 6
s1_quadrant.nr_clusters: 4
total clusters: 24
```

Frontend command used the same file-list shape and warning flags, but with RTL
generated from `cfg/full.hjson`.

Observed result:

```text
exit code: 137
Verilator threw signal 9
Walltime before kill: about 952 s
```

It parsed far enough to emit normal RTL warnings, but it did not complete the
frontend pass on this machine.  For the next MMPI trial, the 2x2 config is the
better starting point: it retains repeated Occamy quadrants and repeated
cluster wrappers, while still fitting the local Verilator frontend/build flow.

## Notes for MMPI Next Step

- Use `testharness` as the top for baseline simulation checks.
- For AST partition analysis, consider whether `testharness` or `occamy_top`
  gives the cleaner partition boundary.  `testharness` includes memory models;
  `occamy_top` exposes more external ports but avoids testbench wrappers.
- The 2x2 config should expose repeated hierarchy:
  `occamy_quadrant_s1` instances and `occamy_cluster_wrapper` instances.
- The modified Verilator's current MMPI heuristics look for repeated
  same-shaped module hierarchy, so this config is more useful than
  `single-cluster.hjson`.
- The first MMPI command to try should be a frontend-only generation pass using
  the same Bender file list and warning flags, adding `--mmpi-o1 --d1`.
