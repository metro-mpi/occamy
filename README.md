# Metro-MPI Partitioned Occamy — Setup & Run Log

This file is a running, reproducible log of every command used to set up and run this repo's
Metro-MPI partitioning flow, for both **default** (automatic) and **guided** (manual) partition
selection, against the custom MPI-patched Verilator fork. It replaces the previous set of
top-level docs (`GETTING_STARTED.md`, `MMPI_CONTEXT.md`, `MMPI_PARTITION.md`,
`occamy_run_instructions.md`, `RANK0_TB_MAIN.md`) — their content has been folded in here as it
was actually exercised, command by command, rather than kept as separate speculative docs.

Environment: everything below runs inside the persistent `date-mmpi-dev-c` Docker container
(built from this session's `Dockerfile`/`Makefile` at the repo root one level up). Enter it with:

```bash
cd /scratch/sws0/user/karya/agentic
make shell
```

## 0. Toolchain

| Tool | Path | Verified with |
|---|---|---|
| Bender | `/tools/bender/bender` | `bender 0.27.1` |
| Verible | `/tools/verible/bin/verible-verilog-format` | present |
| RISC-V GCC (host/CVA6, RV64) | `/tools/riscv-cva6/bin/riscv64-unknown-elf-gcc` | present |
| pulp/Snitch LLVM (device, RV32) | `/tools/llvm/bin/clang` | present |
| Custom Metro-MPI Verilator | `/workspace/verilator/bin/verilator` | `Verilator 5.044 2026-01-01 rev vUNKNOWN-built20260820-89e8ff5` (clean build, no `(mod)` suffix) |
| Python deps (system-wide, no venv needed) | — | `hjson mako jsonschema pyyaml jsonref tabulate pyelftools bin2coe progressbar2 pandas prettytable termcolor json5`, `setuptools 78.1.0` (<81, required) |

Verify commands:
```bash
docker exec date-mmpi-dev-c /tools/bender/bender --version
docker exec date-mmpi-dev-c bash -c 'unset VERILATOR_ROOT; /workspace/verilator/bin/verilator --version'
docker exec date-mmpi-dev-c pip3 list
```

### 0a. If any of the above is missing (fresh container / different machine)

These currently live in the `date-mmpi-dev-c` container's own writable filesystem layer (not the
bind-mounted workspace, not this git repo), installed once in an earlier session doing a GSoC
topology sweep on a sibling Occamy checkout. If that container is ever removed (not just
stopped — `docker rm`, not `docker stop`) or you're setting this up on a different machine, none
of this comes back automatically and needs reinstalling. Exact pinned versions/sources (taken from
the sibling `occamy` repo's own `docker/Dockerfile`, which provisions the same tools the same way):

```bash
# Run inside the container, as root, targeting /tools/<name> for each:
mkdir -p /tools/bender && cd /tools/bender \
  && curl -fL -o bender.tar.gz "https://github.com/pulp-platform/bender/releases/download/v0.27.1/bender-0.27.1-x86_64-linux-gnu-ubuntu22.04.tar.gz" \
  && tar -xzf bender.tar.gz && rm bender.tar.gz

mkdir -p /tools/verible && cd /tools/verible \
  && curl -fL -o verible.tar.gz "https://github.com/chipsalliance/verible/releases/download/v0.0-3222-gb19cdf44/verible-v0.0-3222-gb19cdf44-CentOS-7.9.2009-Core-x86_64.tar.gz" \
  && tar -xzf verible.tar.gz --strip-components=1 && rm verible.tar.gz

mkdir -p /tools/riscv-cva6 && cd /tools/riscv-cva6 \
  && curl -fL -o riscv-gcc.tar.gz "https://static.dev.sifive.com/dev-tools/riscv64-unknown-elf-gcc-8.3.0-2020.04.0-x86_64-linux-ubuntu14.tar.gz" \
  && tar -xf riscv-gcc.tar.gz --strip-components=1 && rm riscv-gcc.tar.gz

mkdir -p /tools/llvm && cd /tools \
  && curl -fL -o llvm.tar.gz "https://github.com/pulp-platform/llvm-project/releases/download/15.0.0-snitch-0.5.0/riscv32-snitch-llvm-ubuntu2204-15.0.0-snitch-0.5.0.tar.gz" \
  && tar -xf llvm.tar.gz --strip-components=1 -C llvm && rm llvm.tar.gz

pip3 install hjson mako jsonschema pyyaml jsonref tabulate pyelftools bin2coe progressbar2 \
  pandas prettytable termcolor json5 "setuptools<81"
```

**Custom Metro-MPI Verilator** is not a pinned download — it's built from source, from the
`verilator` branch of this session's `kislay536/date_mmpi` clone (bind-mounted at
`/workspace/verilator` in this container):
```bash
docker exec -w /workspace/verilator date-mmpi-dev-c bash -c '
  export CXX=mpic++ LIBS=-lsodium
  autoconf && ./configure
  make -j"$(nproc)"
  make install   # produces bin/verilator in-tree (no --prefix used)
'
```
Requires `mpic++` (openmpi, already in this project's base `Dockerfile`) and `libsodium-dev`
(also already in the base image). Confirm with `verilator --version` — must **not** show a
`(mod)` suffix (that means a dirty tracked-file build; if it does, `make clean` and rebuild).

**Important gotcha, confirmed while doing this setup:** the container's `/workspace` bind mount
is fixed to whatever path was passed to `docker run` when the container was first created, and
does **not** follow later edits to the project `Makefile`. This container was created before this
session's tmp/NFS storage split was set up, so `/workspace` inside it is still bound to
`/scratch/sws0/user/karya/agentic/workspace` (NFS), not the newer `/tmp/karya/agentic/workspace`
(tmpfs). Recreating the container to pick up the faster mount would mean losing everything in the
table above (all container-layer-only, several GB, would need re-downloading/rebuilding), so this
repo intentionally lives under the NFS-backed path — check with:
```bash
docker inspect date-mmpi-dev-c --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
```

## 1. Getting this repo into the container's workspace

```bash
rsync -a /scratch/sws0/user/karya/agentic/occamy-mmpi/ /scratch/sws0/user/karya/agentic/workspace/occamy-mmpi/
```
Inside the container this is then visible at `/workspace/occamy-mmpi`.

## 2. Fetch Bender dependencies

```bash
docker exec -w /workspace/occamy-mmpi date-mmpi-dev-c bash -c '
export PATH=/tools/bender:$PATH
bender checkout
'
```

**Known failure and fix:** `Bender.lock` pins `snitch_cluster` to a commit
(`da57b043dfe0ba563a55a9d83bf362873c713648`) that's no longer reachable from any branch on the
upstream repo, so `bender checkout` fails with `cannot update ref ... nonexistent object`. Fix —
fetch that exact commit directly into bender's own git object cache, then retry:
```bash
docker exec -w /workspace/occamy-mmpi/.bender/git/db/snitch_cluster-3438c359197cb3b0 date-mmpi-dev-c \
  git fetch origin da57b043dfe0ba563a55a9d83bf362873c713648
docker exec -w /workspace/occamy-mmpi date-mmpi-dev-c bash -c 'export PATH=/tools/bender:$PATH; bender checkout'
```
(The exact `snitch_cluster-<hash>` cache directory name may differ per clone — check
`.bender/git/db/` for the actual name if this recurs.) After this, `bender checkout` succeeds and
populates `deps/snitch_cluster` (and everything nested under it: `common_cells`, `axi`, `idma`,
`riscv-dbg`, `cvfpu`, etc.).

## 3. Workload: `reduce` instead of `hello_world`

`hello_world` boots but leaves the compute clusters idle, so partitioning it shows no speedup (or
a net loss). This repo instead uses a hand-written cross-cluster compute+reduce kernel, `reduce`
(originally written for a prior GSoC topology sweep on a sibling Occamy checkout), ported in here:

- Each cluster's hart 0 does 500 deterministic scalar-add iterations, writes its partial sum into
  a shared-L3 array, every hart barriers (`snrt_global_barrier()`), then hart 0 checks each
  cluster's partial sum against its expected value.
- **Correctness signal: the process exit code equals the number of clusters that individually
  verified correct.** For a 4-cluster config, exit code 4 means full correctness — this is checked
  identically on the baseline and the partitioned run below.

Porting commands:
```bash
mkdir -p target/sim/sw/device/apps/reduce/src
cp <source-occamy>/target/sim/sw/device/apps/reduce/Makefile   target/sim/sw/device/apps/reduce/Makefile
cp <source-occamy>/target/sim/sw/device/apps/reduce/src/main.c target/sim/sw/device/apps/reduce/src/main.c
```
The device Makefile is fully generic (`APP ?= reduce`, includes `../common.mk`) — no path edits
needed. The host launcher (`sw/host/apps/offload/src/offload.c`) is identical between the two
repos already (it's a generic "wake snitches, wait, return their exit code" harness) — the only
change needed is registering the new device app in `sw/host/apps/offload/Makefile`:
```diff
 DEVICE_APPS  = blas/axpy
 DEVICE_APPS += blas/gemm
+DEVICE_APPS += reduce
```

## 4. Default (automatic) partitioning — structural flow

Keeps `occamy_quadrant_s1` as the Verilator top module, so the automatic duplicate-hash
heuristic (no selection flag — this is the literal "default" mode) finds the 4
`occamy_cluster_wrapper` instances on its own. Rank 0 is the quadrant's own interconnect (not the
full SoC), so this proves the partition split builds and runs correctly but does not boot
software.

```bash
docker exec -w /workspace/occamy-mmpi date-mmpi-dev-c bash -c '
  unset VERILATOR_ROOT
  export PATH=/tools/bender:$PATH
  MAKE_VARS="OCCAMY=/workspace/occamy-mmpi VLT=/workspace/verilator/bin/verilator BENDER=/tools/bender/bender VENV_BIN=/usr/bin"
  make $MAKE_VARS rtl        # -> confirms 4 occamy_cluster_wrapper instances under occamy_quadrant_s1
  make $MAKE_VARS flist      # -> target/sim/work-mmpi-1x4/files (1262 lines)
  make $MAKE_VARS partition  # -> metro_mpi/: "Found 4 partition instances of module '"'"'occamy_cluster_wrapper'"'"'"
  make $MAKE_VARS build-mpi  # -> obj_dir_sys/Voccamy_quadrant_s1 (rank 0), obj_dir_lib/Voccamy_cluster_wrapper (ranks 1-4)
  export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1   # container runs as root; mpirun refuses otherwise
  make $MAKE_VARS run-mpi
'
```

**Result: PASS.** All 5 MPI ranks came up, initialized, ticked `OCCAMY_MPI_CYCLES=200` cycles, and
shut down cleanly:
```
Rank 0 of 5: system ('occamy_quadrant_s1') is alive.
Partition 'occamy_cluster_wrapper' (instance i_occamy_cluster_0) is alive on Rank 1 of 5
Partition 'occamy_cluster_wrapper' (instance i_occamy_cluster_1) is alive on Rank 2 of 5
Partition 'occamy_cluster_wrapper' (instance i_occamy_cluster_2) is alive on Rank 3 of 5
Partition 'occamy_cluster_wrapper' (instance i_occamy_cluster_3) is alive on Rank 4 of 5
...
[Rank 0] Broadcasting shutdown signal.
Rank 1: Shutting down.  Rank 2: Shutting down.  Rank 3: Shutting down.  Rank 4: Shutting down.
Rank 0: simulation complete.
```
Full logs: `target/sim/work-mmpi-1x4-partition/partition.log` (analysis) and
`target/sim/work-mmpi-1x4-partition/metro_mpi/simulate.log` (run).

## 5. Guided (manual) partitioning — software-running flow with `reduce`

Keeps `testharness` as the Verilator top module (rank 0 is the *entire* fesvr-backed SoC: boot
ROM, HBM, UART, CVA6 host core), and selects the partition boundary by hand instead of relying on
the heuristic: export the elaborated hierarchy, pick instances into rank buckets, re-import. This
repo already ships a worked-example boundary spec at `target/sim/sw_spec.json` (verified below to
be byte-identical, modulo formatting, to the spec used in the earlier proven 11-config topology
sweep on a sibling checkout), assigning the same 4 clusters to ranks 1-4:
```json
{
  "schema_version": 2,
  "rank0": "system",
  "ranks": [
    {"rank": 1, "instances": ["$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_0.i_occamy_cluster_0"]},
    {"rank": 2, "instances": ["$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_0.i_occamy_cluster_1"]},
    {"rank": 3, "instances": ["$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_0.i_occamy_cluster_2"]},
    {"rank": 4, "instances": ["$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_0.i_occamy_cluster_3"]}
  ]
}
```

This isn't wired into the root `Makefile` as a target (the guided/`--mmpi-in` path is deliberately
manual, per `GETTING_STARTED.md` §4) — it's run as a sequence of raw Verilator + `mpic++` + `mpirun`
commands, mirroring the pattern the root `Makefile`'s `build-sw-*`/`run-sw` targets use for the
override-based software flow, just swapping `--mmpi-partition-module <name>` for `--mmpi-in
sw_spec.json`.

### 5a. Build the non-partitioned baseline (correctness reference) with `reduce`

```bash
docker exec -w /workspace/occamy-mmpi/target/sim date-mmpi-dev-c bash -c '
  source container-env.sh
  make CFG_OVERRIDE=cfg/mmpi-1x4.hjson rtl                      # no-op if already generated (shared with §4)
  make CFG_OVERRIDE=cfg/mmpi-1x4.hjson VLT_JOBS=4 bin/occamy_top.vlt   # ~13 min, full CVA6 SoC verilation

  # The reduce device app isn't registered in sw/device/Makefile's APPS list (same as the
  # proven sweep run  it is built directly via its own standalone Makefile, bypassing the
  # top-level make sw orchestrator entirely):
  make DEBUG=ON sw || true                 # builds axpy/gemm/hello_world/test_sys_dma; fails on reduce, that's expected
  make -C sw/host/apps/offload partial-build
  make -C sw/device/apps/reduce
  make -C sw/host/apps/offload "$PWD/sw/host/apps/offload/build/offload-reduce.elf"

  rm -f uart0.log; rm -rf logs
  time ./bin/occamy_top.vlt sw/host/apps/offload/build/offload-reduce.elf
  echo "EXIT=$?"
'
```
**Result: `EXIT=4`, 44.1s wall time.** (The `*** FAILED *** (tohost = 4)` line printed by the
harness is a false alarm — Occamy's generic pass/fail check treats any nonzero `tohost` as a
failed test, but for `reduce`, 4 is the *correct* value: all 4 clusters individually verified
their partial sum. This exit-code check, not the harness's FAILED/PASSED label, is `reduce`'s real
correctness signal.)

### 5b. Guided partition analysis (`--mmpi-in`)

```bash
docker exec -w /workspace/occamy-mmpi/target/sim date-mmpi-dev-c bash -c '
  source container-env.sh
  VLT=/workspace/verilator/bin/verilator
  FLIST=$PWD/work-mmpi-1x4/files
  TB_BIN=$(find /workspace/occamy-mmpi/.bender/git/checkouts/snitch_cluster-*/target/common/test/tb_bin.cc)
  VLT_WARN="-Wno-BLKANDNBLK -Wno-LITENDIAN -Wno-CASEINCOMPLETE -Wno-CMPCONST -Wno-WIDTH -Wno-WIDTHCONCAT -Wno-UNSIGNED -Wno-UNOPTFLAT -Wno-MODDUP -Wno-PINMISSING -Wno-IMPLICITSTATIC -Wno-ALWCOMBORDER -Wno-SYMRSVDWORD -Wno-LATCH -Wno-COMBDLY -Wno-SHORTREAL -Wno-fatal"
  PART_DIR=$PWD/work-mmpi-1x4-sw-guided
  rm -rf $PART_DIR && mkdir -p $PART_DIR
  cd $PART_DIR && $VLT --cc --mmpi-o1 --d1 --top-module testharness \
      --mmpi-in ../sw_spec.json -exe $TB_BIN \
      -f $FLIST --timing --unroll-count 1024 $VLT_WARN --Mdir Vmdir
'
```
**Result:** `[Metro-MPI] --mmpi-in: selected 4 instance(s) of module 'occamy_cluster_wrapper' under
parent '$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_0'` — the hand-picked
boundary matches the automatic heuristic's choice exactly, confirming the spec is valid for this
hierarchy.

### 5c. Build rank 0 (fesvr SoC) and the cluster partition

```bash
docker exec -w /workspace/occamy-mmpi/target/sim date-mmpi-dev-c bash -c '
  source container-env.sh
  PART_DIR=$PWD/work-mmpi-1x4-sw-guided
  MMPI_DIR=$PART_DIR/metro_mpi
  WORK_VLT_DIR=$PWD/work-vlt
  SNITCH_TEST_DIR=$(dirname $(find /workspace/occamy-mmpi/.bender/git/checkouts/snitch_cluster-*/target/common/test/tb_bin.cc))
  VLT_WARN="..."   # same as 5b

  # Verilate + build rank 0 (testharness, clusters DPI-stubbed)
  cd $PART_DIR && /workspace/verilator/bin/verilator --Mdir Vmdir_sys -f $MMPI_DIR/flist.system \
      --timing --unroll-count 1024 $VLT_WARN -j 4 --cc --build --top-module testharness

  # Compile the hand-written rank0 driver (rank0_tb_main.cc, see RANK0_TB_MAIN.md before it was
  # folded into this doc -- it's a near-verbatim copy of stock tb_bin.cc with 3 MPI hooks added)
  cd $PART_DIR && mpic++ -std=gnu++20 -fcoroutines -pthread \
      -I Vmdir_sys -I /workspace/verilator/include -I /workspace/verilator/include/vltstd \
      -I $WORK_VLT_DIR/riscv-isa-sim/include -I $SNITCH_TEST_DIR \
      -I ../test -I ../test/uartdpi -I $MMPI_DIR \
      -c $SNITCH_TEST_DIR/verilator_lib.cc /workspace/occamy-mmpi/rank0_tb_main.cc $MMPI_DIR/metro_mpi.cpp

  mkdir -p $PART_DIR/bin
  cd $PART_DIR && mpic++ -std=gnu++20 -L $WORK_VLT_DIR/lib -o bin/occamy_top.mpi.vlt \
      rank0_tb_main.o verilator_lib.o metro_mpi.o \
      $WORK_VLT_DIR/tb/{common_lib,ipc,bootrom,bootdata,uartdpi}.o \
      $WORK_VLT_DIR/vlt/{verilated,verilated_dpi,verilated_threads,verilated_timing,verilated_vcd_c}.o \
      Vmdir_sys/Vtestharness__ALL.a -lfesvr -lpthread -lsodium

  # Verilate + build the cluster partition (ranks 1-4)
  cd $MMPI_DIR && /workspace/verilator/bin/verilator --cc --exe --Mdir obj_dir_lib \
      --top-module occamy_cluster_wrapper \
      occamy_cluster_wrapper_main.cpp metro_mpi.cpp -f flist.library \
      --timing --unroll-count 1024 $VLT_WARN \
      -CFLAGS "-I$MMPI_DIR -std=gnu++20 -fcoroutines"
  make -C $MMPI_DIR/obj_dir_lib -j6 -f Voccamy_cluster_wrapper.mk CXX=mpic++ LINK=mpic++ LDLIBS=-lsodium
'
```

### 5d. Run

```bash
docker exec -w /workspace/occamy-mmpi/target/sim date-mmpi-dev-c bash -c '
  source container-env.sh
  PART_DIR=work-mmpi-1x4-sw-guided
  ELF=sw/host/apps/offload/build/offload-reduce.elf
  time mpirun \
      -np 1 $PART_DIR/bin/occamy_top.mpi.vlt $ELF \
      : -np 1 $PART_DIR/metro_mpi/obj_dir_lib/Voccamy_cluster_wrapper \
      : -np 1 $PART_DIR/metro_mpi/obj_dir_lib/Voccamy_cluster_wrapper \
      : -np 1 $PART_DIR/metro_mpi/obj_dir_lib/Voccamy_cluster_wrapper \
      : -np 1 $PART_DIR/metro_mpi/obj_dir_lib/Voccamy_cluster_wrapper
  echo "EXIT=$?"
'
```

**Result: PASS.** `EXIT=4` — identical to the baseline's exit code, meaning all 4 clusters
individually verified their `reduce` partial sum on the partitioned run too. Wall time **7.68s**
vs the baseline's **44.1s** — a real **~5.7x speedup** on this fresh checkout, consistent with the
~8.47x measured for the same 1x4 configuration in the earlier sweep (some variance is expected;
different run, different moment, same qualitative result — correctness preserved, substantial
speedup from partitioning a workload that actually keeps the clusters busy, unlike `hello_world`).

## 6. Everything else from the earlier 11-config sweep

Sections 4/5 above exercise one config (1x4) end to end. The `reduce` kernel was originally
developed as part of a full topology sweep across **11 configs** on a sibling checkout — this
section ports the rest of that sweep's artifacts and tooling into this repo, so the full sweep can
be reproduced here too. Running the *entire* 11-config sweep was not done as part of writing this
doc (it's genuinely many hours — the 32x1 config alone took ~79 minutes just for its baseline build
in the original run), but every distinct *kind* of artifact below (config file, `sw_spec.json`,
each script, each additional host app) has now actually been exercised at least once — see §6d for
exactly what passed, what's confirmed-but-slow, and what real bugs were found and fixed along the
way.

### 6a. The 11 configs

Two axes, both derived from `cfg/full.hjson` by overriding `nr_s1_quadrant` (quadrant count) and
`s1_quadrant.nr_clusters` (clusters per quadrant) — see the root `Makefile`'s `$(SRC_CFG)` rule for
the same derivation pattern already used for `mmpi-1x4.hjson`:

| Axis | Configs | `cfg/<name>.hjson` |
|---|---|---|
| Cluster (1 quadrant, growing clusters) | 1x1, 1x2\*, 1x4, 1x8, 1x16, 1x32 | `nr_s1_quadrant: 1`, `nr_clusters: {1,2,4,8,16,32}` |
| Quadrant (1 cluster/quadrant, growing quadrants) | 2x1, 4x1, 8x1, 16x1, 32x1 | `nr_s1_quadrant: {2,4,8,16,32}`, `nr_clusters: 1` |

\*1x2 has no `.hjson` in `cfg/` (the original sweep run for it used a config derived inline by
`setup_and_run.sh` itself — see §6c) but its `sw_spec_1x2.json` is present.

All 9 configs not already present (`mmpi-1x1/1x8/1x16/1x32/2x1/4x1/8x1/16x1/32x1.hjson`) are now in
`target/sim/cfg/`, alongside the already-used `mmpi-1x4.hjson`.

**Quadrant-axis partitioning is structurally different from cluster-axis**, which is why it needs
its own `sw_spec_<cfg>.json` rather than reusing the cluster-level pattern from §5: Metro-MPI's
`--mmpi-in` requires every partition instance to share **one parent module scope**. For cluster-axis
configs (`NQ==1`), the clusters all sit under the single quadrant, so partitioning at the cluster
level works (as in §5's `sw_spec.json`). For quadrant-axis configs (`NQ>1`), individual clusters
live under *different* quadrant parents — so partitioning has to happen one level up, at the
quadrant module itself (all quadrants share the single `i_occamy_soc` parent instead). Compare:
```json
// cluster-axis (e.g. sw_spec_1x8.json) -- partitions AT the cluster:
{"rank": 1, "instances": ["$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_0.i_occamy_cluster_0"]}

// quadrant-axis (e.g. sw_spec_4x1.json) -- partitions AT the quadrant, one rank per whole quadrant:
{"rank": 1, "instances": ["$root.testharness.i_occamy.i_occamy_soc.i_occamy_quadrant_s1_0"]}
```
All 11 `sw_spec_<cfg>.json` files are now in `target/sim/` (the generic `sw_spec.json` used live in
§5 is just the 1x4 one, already present before this section).

### 6b. Additional host-side apps (`target/sim/sw/host/apps/`)

- **`reduce_report/`** — an alternate launcher for the `reduce` device kernel (same
  `DEVICE_APPS = reduce`), using UART print output instead of just the process exit code. Useful if
  you want a human-readable report rather than `offload`'s bare exit-code check.
  **Two real bugs found and fixed while testing this repo** (both in the ported source, not in
  anything upstream):
  1. The original hand-rolled its own completion wait as a busy-poll on `sw_interrupt_pending()`
     instead of `host.c`'s `wait_snitches_done()` (which waits via `wfi()`), based on an earlier
     bisection that found UART hangs specifically after a `wfi`-based wait. **That doesn't hold up
     here** — see the UART finding below; `wait_snitches_done()` is what `offload.c` already uses
     successfully throughout §4/5, so this now just calls it directly (simpler, and no less
     correct).
  2. The original compared the return value (the reduce kernel's exit code — the *count* of
     clusters that verified correct, e.g. `4` for a fully-passing 1x4 run) against `0` to decide
     PASS/FAIL. That's backwards: `0` is the *worst* case, not success. Fixed to print the actual
     count instead of a wrong threshold.

  **The actual finding, from testing this on the 1x4 build:** UART output in this build is
  genuinely **real-time-baud-rate-accurate** (115200 baud, simulated cycle-by-cycle against a 1GHz
  core) — not broken, just slow enough to look like a hang if you don't wait long enough. Proof:
  the completely unmodified upstream `hello_world` — which never touches `wait_snitches_done()` or
  `sw_interrupt_pending()` at all — took the better part of 10 minutes of wall-clock time to print
  `"Hello world!"` (12 characters) in this exact build, confirmed via `EXIT=0` and the full string
  in `uart0.log`. Given that rate, `reduce_report`'s ~29-character report line is expected to need
  on a similar order of many minutes; I ran it for up to 25 minutes (partly overlapping with a
  concurrent build, which would have slowed it further via CPU contention) without it finishing —
  so the *fix* is verified correct against proven-working primitives (`wait_snitches_done()` and
  `print_uart()`, each independently confirmed elsewhere in this doc), but a full uninterrupted,
  uncontended end-to-end run of `reduce_report` itself was not completed. If you need to confirm
  it, run it alone (no concurrent builds) with a timeout of 30+ minutes.
- **`bisect1/`, `bisect2/`, `bisect3/`** — not workloads, debugging tools originally used to
  investigate the "UART hang" that turned out to be UART just being slow (see above). All three
  compile cleanly (verified) but were not run to completion for the same reason as `reduce_report`
  — same UART-after-wait pattern, same expected multi-minute-plus real time. `bisect1/2/3`'s
  Makefiles also had a harmless duplicate `DEVICE_APPS = reduce` / `DEVICE_APPS += reduce` pair
  (make warning, not an error) — cleaned up while porting.

### 6c. Reusable scripts (repo root)

- **`setup_and_run.sh`** — the actual per-config sweep driver. Ported here with one fix: it
  originally hardcoded `RANK0_TB_MAIN=/workspace/occamy/rank0_tb_main.cc` (a path specific to the
  sibling checkout it was developed against); changed to `$OCCAMY/rank0_tb_main.cc` so it correctly
  resolves against whatever checkout you point it at (this repo has its own `rank0_tb_main.cc` at
  root, same file, already used in §5c).

  ```
  Usage: setup_and_run.sh <copy_dir> <cfg_name> <n_quadrants> <n_clusters_per_quad> <n_ranks>
  ```
  It's self-contained per config: baseline RTL+build, platform-header/`libsnRuntime.a` regen,
  `reduce` device+host rebuild, baseline run, guided-partition build (auto-selecting cluster- vs
  quadrant-level partitioning based on `n_quadrants`), partitioned run — each step idempotent
  (skips already-built binaries).

  **Confirmed working end to end** — ran this script for real (`mmpi-1x1`, `1 1 1`) after fixing
  two real usage gotchas found in the process:

  1. **The script does not put `bender`/RISC-V-GCC/pulp-LLVM on `PATH` itself** — it only adds
     `/workspace/verilator/bin` (line 11). It relies on the rest already being on `PATH` from the
     calling shell. Source `container-env.sh` (§0) *before* invoking it, or every step past STEP 1
     fails with `bender: No such file or directory` / `riscv64-unknown-elf-gcc: not found` (the
     STEP 1 build still partially works because `Makefile.occamy`'s `default-build` target takes
     `BENDER=`/`VLT=` as explicit arguments — but STEP 2 onward calls bare `make`/`bender`).
  2. **`<copy_dir>` must be an isolated, single-config directory** — this mirrors exactly how the
     original sweep worked (`workspace/sweep/occamy-<cfg>/`, one rsync'd copy per config). STEP 1
     checks `if [ -s bin/occamy_top.vlt ]; then skip rebuild`, keyed only on that fixed path, with
     no config name in it. Point it at a directory that already has a *different* config's
     `bin/occamy_top.vlt` (e.g. this repo's own `target/sim/`, already built for 1x4 in §5) and it
     silently reuses the wrong binary instead of rebuilding for the new config. Either give each
     config its own copy (as below) or `rm -rf bin/ work-vlt/` first if reusing a directory.
  3. **A fresh isolated copy needs `sw/device/math/build/libmath.a` built once, separately** —
     every device app (`reduce` included, even though it doesn't call any math functions itself)
     unconditionally links `-lmath` via `../common.mk`. The original sweep's isolated copies all
     had this prebuilt already (carried over by their own rsync, which — unlike the exclusion
     pattern below — didn't strip build artifacts); a copy made the way shown below does need it
     built explicitly first, or STEP 3 fails with `ld.lld: error: unable to find library -lmath`.

  **Confirmed working end to end on `mmpi-1x1`** (1 quadrant, 1 cluster, 1 partition rank) after
  applying all three fixes above: baseline `EXIT=1`, guided-partitioned `EXIT=1` — matches, exactly
  the same correctness pattern as §5's 1x4 result, on the smallest possible cluster-axis config.

  ```bash
  # Fresh, isolated copy per config:
  rsync -a --exclude='.git' /scratch/sws0/user/karya/agentic/workspace/occamy-mmpi/ \
    /scratch/sws0/user/karya/agentic/workspace/occamy-mmpi-test-1x1/

  docker exec -w /workspace/occamy-mmpi-test-1x1/target/sim/sw/device/math date-mmpi-dev-c bash -c '
    source /workspace/occamy-mmpi/target/sim/container-env.sh
    make   # one-time: build libmath.a for this fresh copy
  '

  docker exec -w /workspace/occamy-mmpi-test-1x1 date-mmpi-dev-c bash -c '
    source /workspace/occamy-mmpi/target/sim/container-env.sh
    bash setup_and_run.sh /workspace/occamy-mmpi-test-1x1 mmpi-1x1 1 1 1
  '
  ```
  Reproducing this doc's own §5 result (1x4) works the same way, just against a copy already at
  that config (or `/workspace/occamy-mmpi` itself, which already has 1x4 *and* `libmath.a` built):
  ```bash
  docker exec -w /workspace/occamy-mmpi date-mmpi-dev-c bash -c '
    source target/sim/container-env.sh
    bash setup_and_run.sh /workspace/occamy-mmpi mmpi-1x4 1 4 4
  '
  ```
  Running the full 11-config sweep is this command looped over the table in §6a with the matching
  `(n_quadrants, n_clusters_per_quad, n_ranks)` triple per row and a fresh isolated copy (with
  `libmath.a` prebuilt) each time — only 1x1 and 1x4 have actually been run to completion here;
  budget real hours for the larger configs (32-cluster/32-quadrant baseline builds ran ~79 min each
  in the original sweep).

- **`Makefile.occamy`** — an alternate experiment-runner Makefile (targets: `default-smoke`,
  `default-hello`, `auto-smoke`, `auto-hello`, `manual-smoke*`, `manual-hello*`) that
  `setup_and_run.sh`'s STEP 1 partially reuses (`default-build`). Its own `manual-hello-build`
  target is hardcoded to `occamy_cluster_wrapper` and only works for cluster-axis configs —
  `setup_and_run.sh`'s `build_manual_hello()` function is the corrected, parameterized version
  (works for both axes via `$PARTITION_MODULE`), so prefer the script over this Makefile's targets
  directly for anything beyond 1x4.

- **`occamy_partition.sh`** — a standalone, config-overridable driver for just the raw
  `--mmpi-o1 --d1` structural partition analysis (no build, no run) — a quicker way to check what
  a new config's automatic partition boundary looks like before committing to a full build. Ported
  and adapted to this repo's actual container (it originally targeted a different, older Docker
  setup: a `gsoc` user and `/workspace/occamy`, vs. this repo's `date-mmpi-dev-c` container running
  as root with the checkout at `/workspace/occamy-mmpi`). **Confirmed working** — run for real
  against `cfg/mmpi-1x8.hjson` (a config never built before in this repo), completed cleanly with
  no errors in a couple of minutes. Note it hardcodes `--top-module testharness`, so — matching the
  documented selection rule in §4 — the automatic heuristic picks the 8 `tb_memory_axi` HBM models
  as the partition boundary under that top, not the clusters; that's expected, not a bug (this
  script is a quick "does analysis run cleanly" check, not a cluster-boundary finder — for that,
  use §4's approach with `--top-module occamy_quadrant_s1`). Run from the **host** (it internally
  does its own `docker exec`, so it errors confusingly if run from inside the container instead):
  ```bash
  cd /scratch/sws0/user/karya/agentic/workspace/occamy-mmpi
  CFG_OVERRIDE=cfg/mmpi-1x8.hjson bash occamy_partition.sh
  ```

- **`run_occamy_experiments.sh`** — an older six-experiment smoke-test harness (via
  `Makefile.occamy`'s `default/auto/manual-smoke/hello` targets) that predates the `reduce` kernel
  and the full sweep — targets the earlier `hello_world`-based flow. Kept for reference; prefer
  `setup_and_run.sh` for anything involving `reduce` or the 11-config sweep. Not run (superseded).

### 6d. What's actually been verified, as of this writing

| Item | Status |
|---|---|
| Default partitioning (§4) | **PASS** — built and run, all 5 ranks clean shutdown |
| Guided partitioning, `reduce`, 1x4 (§5) | **PASS** — baseline `EXIT=4`, partitioned `EXIT=4`, ~5.7x speedup |
| `occamy_partition.sh` | **PASS** — run against a new config (`mmpi-1x8`), completed cleanly |
| `bisect1`/`bisect2`/`bisect3` | Compile: **PASS**. Run to completion: not confirmed (see §6b — expected multi-minute UART cost, not attempted uncontended) |
| `reduce_report` | Compile: **PASS**. Two real logic bugs found and fixed (see §6b). Run to completion: not confirmed for the same UART-timing reason |
| `setup_and_run.sh`, `mmpi-1x1` | **PASS** — baseline `EXIT=1`, partitioned `EXIT=1`. Found and fixed 3 real gotchas along the way (missing `PATH` setup, stale cross-config binary reuse, missing `libmath.a` — all documented above) |
| `setup_and_run.sh`, other 9 configs | Not run (each is a real, possibly hours-long RTL+build job) |
| `Makefile.occamy` direct targets | Not run directly (exercised indirectly via `setup_and_run.sh`'s STEP 1, which calls its `default-build` target) |
| `run_occamy_experiments.sh` | Not run (superseded, predates `reduce`) |
| §0a toolchain install commands | Not run (the container already had everything; commands are transcribed from the sibling repo's own `Dockerfile`, not independently verified here) |
