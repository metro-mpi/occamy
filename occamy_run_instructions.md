# Occamy Run Instructions

A single reference for: (0) how the Occamy design is organized, (1) running a C
program (e.g. `hello_world`) **end-to-end** in two configurations with the plain
Verilator (no Metro-MPI), (2) using Metro-MPI to **generate the partition
analysis** for both configurations, and (3) the **modifications the generated
files need** to make the partitioned design build and run like the original.

> Verilator used everywhere below is the fork at
> `verilator-private/verilator-install/bin/verilator`. For Part 1 it is invoked
> as a normal Verilator (no `--mmpi-*` flags); for Part 2 it is invoked with
> `--mmpi-o1 --d1`.
>
> Companion docs (read for the deep detail this file summarizes):
> `OCCAMY_SETUP.md` (build the simulator + toolchains), `OCCAMY_RUN_SIMULATION.md`
> (full software run + verify), `OCCAMY_DUMMY_VERILATOR_RUN.md` (a worked custom-C
> run), `occamy/MMPI_PARTITION.md` (why the 1×4 partition shape), and
> `occamy/MMPI_CONTEXT.md` (the hardware-only smoke baseline).

> ### Verification status (replayed on a clean `occamy-orig`, 2026-06-24/25)
> These steps were re-run from scratch on a **clean upstream checkout
> (`occamy-orig`)** with the **unmodified** `verilator-private`
> (`rev v5.036-109-gb20c1de66` — the pre-generalization baseline):
> - **Part 0/2 setup + analysis: VERIFIED.** `bender checkout`, config derivation,
>   RTL gen, flist, and `--mmpi-o1 --d1` all ran; the analyzer correctly selected
>   **4 `occamy_cluster_wrapper` partitions** under `occamy_quadrant_s1`.
> - **Part 1 (full software run): VERIFIED natively, end-to-end on `occamy-orig`.**
>   No Docker. From the clean tree: ported the Verilator target + `patches/` into
>   `target/sim/Makefile`, built `bin/occamy_top.vlt` (94 MB, fesvr+libsodium) with
>   `RISCV_GCC_BINROOT=/home/kislay/tools/riscv64-gnu-toolchain/bin` (`gcc 12.2.0`),
>   built `hello_world.part.elf` with the host GCC, and ran it →
>   `[fesvr] Wrote entry point 0x80000000`, harts traced, `uart0.log` =
>   `Hello world!`, **exit 0**. This is the **golden reference** (unpartitioned).
>   (Snitch *device* apps still need the `15.0.0-snitch` LLVM — see §1.2.)
> - **Part 3: the partitioned split BUILDS and SIMULATES after 8 hand-edits.** The
>   baseline-generated files don't build as-is; I iterated patch→build→simulate (§3.0.1)
>   until the **5-rank MPI split ran to a clean shutdown** (`mpirun` exit 0: ranks 0–4
>   all "Ending Communication", "Rank 0: done", none hung). **BUT this is a
>   liveness/structural co-sim only — NOT correct and NOT software:** the AXI structs
>   are truncated to 1 bit (analyzer width-1 bug, worked around), and rank 0 is just
>   the quadrant (no CVA6/HBM/fesvr → no program runs). It is **not** the Part 1
>   "Hello world" run. See §3.0.1 for exactly what "ran" means + the validated edit set.
> - **Part 3 re-validated with `verilator-dev` (rev -110, 48 fixes): 8 edits → 3.**
>   Cleaned + re-looped: the analyzer/generator edits (#1 struct width, #2/#5 clock,
>   #3 rst_n/clk_en, #7 metro_mpi split) are **resolved by the tool** — both models
>   build with no width/clock edits and the 5-rank split still shuts down cleanly,
>   now with **full-width** AXI marshalling. Only #4 (deadlock-free shutdown), #6
>   (flist package), #8 (rank-0 driver) remain — the structural-cosim integration
>   pieces, not analyzer bugs. See §3.0.2.
> - **Part 3 re-validated with the 3 generator fixes (Fix A/B/C): 3 edits → 0.**
>   #4/#6/#8 are now emitted by the generator (Fix A probe-based shutdown loop, Fix B
>   package-preserving `flist.system`, Fix C default rank-0 driver gated on absent
>   `-exe`). `occamy-orig` regenerates → builds (`build-lib`+`build-sys`) → simulates
>   (5-rank clean shutdown, `mpirun` exit 0) with **zero hand-edits**. OpenPiton
>   (`mmpi-orig`) still regenerates + builds green (Fix C gates off via its `-exe`
>   harness; Fix B causes no `MODDUP`); the fixes were isolated to not break it. See §3.0.3.
> - **Part 4 — SOFTWARE-RUNNING partition matches the original (behavioral equivalence).**
>   With `top=testharness` + `--mmpi-partition-module occamy_cluster_wrapper`, rank 0 is
>   the full fesvr SoC and the 4 clusters are MPI ranks. It boots and runs `hello_world`
>   to `tohost` → `uart0.log` = `Hello world!`, `mpirun` exit 0 — **identical to the
>   unpartitioned golden run.** Only generated files + one separate rank-0 fesvr driver
>   (`rank0_tb_main.cc`); Verilator unmodified. Reaches tohost at ~3.7M cycles (~12 min;
>   needs `timeout` ≥1500 s). See **Part 4**.
>
> A clean checkout (`occamy-orig`) is missing two companion pieces this flow needs;
> add them first (see §0.3).

---

## 0. Occamy design organization (the hierarchy)

Occamy is a chiplet-style RISC-V SoC: one **CVA6** manager (host) core plus a set
of **Snitch compute clusters** grouped into **quadrants**, wired together by AXI
crossbars, with HBM/peripherals around the edge. From the simulation top down:

```
testharness                         ← simulation top (TB): HBM models, boot ROM,
│                                       UART DPI, fesvr/HTIF ELF loader, clock/reset
└─ occamy_top                       ← the chip top (pads/IO view of the SoC)
   └─ occamy_soc                    ← SoC: CVA6 host, peripherals, SoC crossbars,
      │                                and the quadrants
      └─ occamy_quadrant_s1   ×N    ← one per `nr_s1_quadrant`
         │                             (narrow+wide AXI crossbars +
         │                              occamy_quadrant_s1_ctrl + the clusters)
         └─ occamy_cluster_wrapper ×M ← one per `s1_quadrant.nr_clusters`
            └─ (Snitch cluster: ~9 harts, FPnew FPUs, SSR, TCDM, L1, I$/D$)
```

What each level is:

| Module | Role |
| --- | --- |
| **`testharness`** | The Verilator/simulation top. Provides everything *around* the chip needed to run software: HBM memory models, boot ROM, UART DPI, and the **fesvr/HTIF** path that loads an ELF and detects `tohost` exit. **This is the only top that can boot/run software.** |
| **`occamy_top`** | The chip top — the SoC as seen at the package boundary. |
| **`occamy_soc`** | The SoC proper: the **CVA6 host** core, peripherals, the SoC-level AXI interconnect, and the array of quadrants. |
| **`occamy_quadrant_s1`** | A quadrant: narrow + wide AXI crossbars, `occamy_quadrant_s1_ctrl`, and the cluster(s). This is the analog of OpenPiton's `chip` for partitioning purposes. |
| **`occamy_cluster_wrapper`** | **The replicated compute engine — the analog of an OpenPiton `tile`.** Wraps a full Snitch cluster. Its boundary is wide AXI **packed structs** (`narrow_*_req/resp`, `wide_*_req/resp`, 257–751 bits) plus clock/reset/interrupts. |
| Snitch cluster (inside the wrapper) | ~9 Snitch integer harts + FPnew FPUs + SSR streamers + TCDM scratchpad + L1 + I/D caches. |

### Configuration knobs

The shape is controlled in `target/sim/cfg/*.hjson`:

| Knob | Meaning |
| --- | --- |
| `nr_s1_quadrant` | number of `occamy_quadrant_s1` instances under `occamy_soc` |
| `s1_quadrant.nr_clusters` | number of `occamy_cluster_wrapper` instances under **each** quadrant |

`cfg/full.hjson` is `nr_s1_quadrant: 6`, `nr_clusters: 4` (24 clusters — too big for
this machine). The two configurations used in this doc are derived from it:

| This doc's name | `nr_s1_quadrant` | `nr_clusters` | total clusters | hierarchy shape |
| --- | --- | --- | --- | --- |
| **1×4** (`cfg/mmpi-1x4.hjson`) | 1 | 4 | 4 | **4 cluster_wrappers under ONE quadrant** |
| **4×2** (`cfg/mmpi-4x2.hjson`) | 4 | 2 | 8 | 2 cluster_wrappers under **each of 4** quadrants |

These two were chosen because they bracket the partitioning behavior: 1×4 puts all
replicas under a single parent (the easy/clean case for Metro-MPI); 4×2 spreads
clusters across multiple parents (the case that exposes Metro-MPI's single-parent
limit — see Part 2).

### Create the two config files

From the `occamy/target/sim/` directory (both derived from `full.hjson`):

```bash
cd occamy/target/sim

# 1×4 : 1 quadrant, 4 clusters
cp cfg/full.hjson cfg/mmpi-1x4.hjson
sed -i -e 's/nr_s1_quadrant: 6,/nr_s1_quadrant: 1,/' cfg/mmpi-1x4.hjson
#   (nr_clusters stays 4)

# 4×2 : 4 quadrants, 2 clusters each
cp cfg/full.hjson cfg/mmpi-4x2.hjson
sed -i -e 's/nr_s1_quadrant: 6,/nr_s1_quadrant: 4,/' \
       -e 's/nr_clusters: 4,/nr_clusters: 2,/' cfg/mmpi-4x2.hjson

# sanity
grep -nE 'nr_s1_quadrant|nr_clusters' cfg/mmpi-1x4.hjson cfg/mmpi-4x2.hjson
```

(The `occamy/Makefile` already derives `cfg/mmpi-1x4.hjson` for you in its `rtl`
target; the `mmpi-4x2.hjson` step above is the new one.)

### 0.3 Prerequisites for a clean checkout (e.g. `occamy-orig`)

A pristine upstream Occamy checkout is **missing two things this flow needs** (both
confirmed on `occamy-orig`):

1. **The Metro-MPI partition `Makefile`** (the one at the repo root that drives
   `rtl` / `flist` / `partition` / `build-mpi` / `run-mpi`). Upstream Occamy ships
   only `target/sim/Makefile` (VCS/Questa + the verilated `rtl` target). Copy the
   companion driver in:
   ```bash
   cp /home/kislay/Documents/gsoc/occamy/Makefile  <clean-occamy>/Makefile
   ```
   Then drive it with `OCCAMY=<clean-occamy>` so all paths resolve to that tree,
   e.g. `make -C occamy-orig OCCAMY=$PWD/occamy-orig all`.
   *(For Part 1 you additionally need the `target/sim/Makefile` Verilator section
   from `OCCAMY_SETUP.md §8` — it is not in upstream either.)*

2. **Bender dependencies checked out** (`deps/` is empty on a fresh clone):
   ```bash
   cd <clean-occamy>
   PATH=/home/kislay/Documents/gsoc/.codex-tools/bin:$PATH bender checkout
   ```
   On this workspace `bender checkout` resolved all 22 deps (incl. `snitch_cluster`)
   in ~12 s. If it fails on the locked `snitch_cluster` SHA, apply the SHA-fetch fix
   in `OCCAMY_SETUP.md §7`.

Also ensure `VERILATOR_ROOT` is **unset** in the environment (the installed wrapper
computes its own and errors on mismatch).

---

## Part 1 — Run a C program end-to-end (no Metro-MPI), for both configs

This is the **full software path**: top module `testharness`, fesvr loads the ELF,
the program runs to its `tohost` exit, UART output is captured. It is identical for
both configs — only the config (and therefore verilation size/time) differs. It
does **not** use any `--mmpi-*` flags; the fork runs as an ordinary Verilator.

> **Toolchains (native build works on this host).** Building the simulator + a
> host ELF needs the **CVA6 RV64 GCC** and (only for Snitch *device* apps) a
> pulp/Snitch **LLVM**. These are present on this host (just off the default
> `PATH`):
> - `riscv64-unknown-elf-gcc 12.2.0` at `/home/kislay/tools/riscv64-gnu-toolchain/bin`
> - a pulp LLVM at `/home/kislay/tools/llvm-vortex/bin` (`clang 18.1.7`)
>
> The Occamy Makefile finds GCC via `$(RISCV_GCC_BINROOT)`, so wire it up with:
> ```bash
> export RISCV_GCC_BINROOT=/home/kislay/tools/riscv64-gnu-toolchain/bin
> export LLVM_BINROOT=/home/kislay/tools/llvm-vortex/bin   # device apps only
> export PATH=/home/kislay/Documents/gsoc/verilator-private/verilator-install/bin:\
> /home/kislay/Documents/gsoc/.codex-tools/bin:/home/kislay/Documents/gsoc/.codex-venvs/occamy/bin:$PATH
> unset VERILATOR_ROOT
> ```
> Docker (`OCCAMY_SETUP.md`) is an *alternative*, not a requirement. `host`
> apps like `hello_world` need only GCC; the BLAS/DNN *device* apps need the
> exact `15.0.0-snitch` LLVM (the local `llvm-vortex` may differ — untested).
> `target/sim/Makefile` must contain the Verilator target from `OCCAMY_SETUP.md §8`
> (upstream lacks it — port it; see §0.3).

### 1.1 Build the simulator for a config

With the toolchain env from the gating note exported (and the Verilator target +
`patches/` ported into `target/sim/Makefile` per §0.3), build the fesvr simulator:

```bash
cd occamy-orig/target/sim     # or occamy/target/sim
# --- 1×4 ---   (this exact invocation was verified on occamy-orig)
make CFG_OVERRIDE=cfg/mmpi-1x4.hjson rtl
make BENDER=$GSOC/.codex-tools/bin/bender VERIBLE_FMT=true \
     CFG_OVERRIDE=cfg/mmpi-1x4.hjson VLT_JOBS=4 bin/occamy_top.vlt
```

`VERIBLE_FMT=true` skips the `verible-verilog-format` step (not installed here; it
does not affect elaboration). The build runs bender → RTL → verilate `testharness`
(~10–20 min) → fetch/build fesvr → TB compile → link with `mpic++ -lsodium`. On
occamy-orig this produced a 94 MB `bin/occamy_top.vlt`.

For the 4×2 build, **rebuild from its config** (hardware and software must come
from the same config; `make` records the last one in `cfg/lru.hjson`):

```bash
# --- 4×2 ---  (rebuild RTL + simulator for the new shape)
make CFG_OVERRIDE=cfg/mmpi-4x2.hjson rtl
make CFG_OVERRIDE=cfg/mmpi-4x2.hjson VLT_JOBS=4 bin/occamy_top.vlt
```

`bin/occamy_top.vlt` is the fesvr-backed simulator (top = `testharness`). First
build is ~10–20 min; 4×2 (8 clusters) is heavier than 1×4 (4 clusters).

### 1.2 Build the program (ELF)

```bash
cd occamy/target/sim
make sw 2>&1 | tee sw-build.log     # builds host + device apps for the current config
```

This produces, among others, `sw/host/apps/hello_world/build/hello_world.part.elf`
(host-only; prints over UART). For something that also exercises the Snitch
clusters use an offloaded app, e.g. `sw/host/apps/offload/build/offload-axpy.elf`
(see `OCCAMY_RUN_SIMULATION.md §4`).

> **Verified on occamy-orig (2026-06-25):** the **host** apps build natively with
> `riscv64-unknown-elf-gcc 12.2.0` — `hello_world.part.elf` (8.8 KB) was produced.
> But `make sw` then **fails on the Snitch *device* apps**:
> `clang: error: unsupported argument 'snitch' to option '-mcpu='`. The host's
> `llvm-vortex` (`clang 18.1.7`, a Vortex LLVM) does **not** implement `-mcpu=snitch`
> — that needs the pulp **`15.0.0-snitch`** LLVM. So on this host: **host apps OK,
> device/offload/BLAS apps blocked** until the Snitch LLVM is installed. For Phase 1
> with `hello_world` (host-only) this is fine; to build a cluster-offload workload
> you must install the `15.0.0-snitch` LLVM (or use the Docker container).
> If you only need a host ELF, build just it:
> `make -C sw/host` (skips the failing device tree).

### 1.3 Run to completion + verify

```bash
cd occamy/target/sim
mkdir -p logs
./bin/occamy_top.vlt sw/host/apps/hello_world/build/hello_world.part.elf
echo "exit = $?"          # 0 = program reached its tohost exit cleanly
tail -n 5 uart0.log       # expect: Hello world!
```

A **complete** run shows `[fesvr] Wrote … entry point …` near the start, the
`[Tracer] Logging Hart …` banners, self-terminates with exit 0, and writes the
program's UART output to `uart0.log`. (If you don't see the `[fesvr]` lines, you
ran a smoke/structural binary, not `occamy_top.vlt` — see `OCCAMY_RUN_SIMULATION.md
§0` and §10 for the full checklist.) Do the same for the 4×2 build.

Both configs run software the **same** way; nothing here is partitioned.

---

## Part 2 — Generate the Metro-MPI partition analysis for both configs

Now invoke the fork with `--mmpi-o1 --d1`. This reads the elaborated AST, picks a
group of replicated instances under one parent, and **emits a `metro_mpi/`
directory** (report + modified RTL + DPI stubs/wrappers + MPI glue + per-rank
mains). `--d1` exits right after the analysis (no C++ codegen). It writes
`metro_mpi/` relative to the CWD, so run it from a throwaway work dir.

Key rule (the duplicate-hash heuristic): **the module you partition must be a
replicated direct child of the `--top-module` you pass, all under one parent.**

### 2.1 Config 1×4 → partition the 4 clusters (the clean case)

Top = `occamy_quadrant_s1`; its level-1 duplicate group is exactly the 4
`occamy_cluster_wrapper` instances → 4 partition ranks + rank 0 = **5 ranks**. The
`occamy/Makefile` already encodes this:

```bash
cd occamy
make rtl        # derives cfg/mmpi-1x4.hjson, generates RTL
make flist      # bender Verilator file list
make partition  # verilator --mmpi-o1 --d1 --top-module occamy_quadrant_s1 -> metro_mpi/
# or simply: make all
```

Output lands in `target/sim/work-mmpi-1x4-partition/metro_mpi/`. Confirm the
selection:

```bash
grep -E "Found [0-9]+ partition instances" \
     target/sim/work-mmpi-1x4-partition/partition.log
# expect: Found 4 partition instances of module 'occamy_cluster_wrapper'
python3 - <<'PY'
import json
d=json.load(open("target/sim/work-mmpi-1x4-partition/metro_mpi/partition_report.json"))
# schema-robust: the baseline binary emits only {"partitions": {...}}; the
# generality-fixed binary adds a richer "partition_selection" block + schema_version.
if "partition_selection" in d:                       # generality-fixed binary
    s = d["partition_selection"]
    print(s["partition_module"], s["parent_hierarchy"], s["instance_count"])
else:                                                # baseline (rev -109) old schema
    print("partitions:", list(d["partitions"].keys()))
PY
```

`rank 0 = occamy_quadrant_s1` (the AXI crossbars + ctrl); ranks 1–4 = the four
clusters. Every cluster port talks only to rank 0 (star/hub topology), never
cluster-to-cluster.

> **Verified on `occamy-orig` with the baseline binary:** `make all` selected
> `i_occamy_cluster_0..3` (4 instances). The report is the **old schema**
> (`{"partitions": {...}}` only — no `partition_selection`/`schema_version`), and
> all AXI struct ports show **`width: 1`** (histogram `{1: 11, 9: 3, 10: 1, 48: 1}`
> for one cluster) — the root cause of the Part 3 build errors below.

### 2.2 Config 4×2 → what you can and cannot partition

In 4×2 the 8 clusters are **2 under each of 4 quadrants** — i.e. spread across
**multiple parents**. Metro-MPI partitions one group **under a single parent**, so
you cannot partition all 8 clusters in one run (the multi-parent limitation). Two
workable boundaries:

**(A) Clusters of a single quadrant** — top = `occamy_quadrant_s1`. Because the top
*is* the quadrant, Verilator elaborates one quadrant with its 2 clusters → **2
partition ranks + rank 0 = 3 ranks**. Same flow as 1×4, just fewer clusters:

```bash
cd occamy
# point the partition flow at the 4×2 config (override CFG_NAME/CFG):
make partition CFG_NAME=mmpi-4x2 TOP_MODULE=occamy_quadrant_s1
grep -E "Found [0-9]+ partition instances" target/sim/work-mmpi-4x2-partition/partition.log
# expect: Found 2 partition instances of module 'occamy_cluster_wrapper'
```

**(B) The 4 quadrants** — top = `occamy_soc`, partitioning the 4
`occamy_quadrant_s1` instances → 4 partition ranks + rank 0 = 5 ranks, where each
partition is a whole quadrant (2 clusters). **Verify before relying on it:**

```bash
cd occamy
make partition CFG_NAME=mmpi-4x2 TOP_MODULE=occamy_soc
grep -E "Found [0-9]+ partition instances" target/sim/work-mmpi-4x2-partition/partition.log
```

Caveats for (B), to check in `partition_report.json`:
- The heuristic only inspects level-1 and picks the heaviest duplicate group. Under
  `occamy_soc` it may select a different repeated group (e.g. `axi_multicut`)
  instead of the quadrants. If so, force it with
  `--mmpi-partition-module occamy_quadrant_s1` (available in the
  generality-fixed fork; the older committed binary rejects that flag).
- If the four `occamy_quadrant_s1` instances are **parameter-specialized** (per-quadrant
  IDs / base addresses), Verilator gives them distinct elaborated names and the
  name-based selection won't group them — the same class of problem that blocks
  Vortex. The 1×4 cluster boundary is known not to have this issue (the 4 clusters
  are identical, no `#(...)` overrides); the quadrant boundary is **not yet
  verified** here, so check the report.

> **Recommendation:** 1×4 (Part 2.1) is the proven, clean Metro-MPI shape. Use 4×2
> case (A) for a smaller 3-rank split, and treat 4×2 case (B) as exploratory until
> the report confirms 4 identical-named quadrant instances under one parent.

### 2.3 What gets generated (either config)

In the chosen `work-…-partition/metro_mpi/`:

```
partition_report.json              port-level analysis (ranks, widths, comm graph)
modified_<parent>.v                parent with the partition instances swapped for wrappers
modified_<partition>.v             the generic DPI-stub module
<inst>_<partition>_wrapper.v        one wrapper per partition instance
metro_mpi.h / metro_mpi.cpp         MPI datatypes + send/recv helpers (declarations / definitions)
<partition>_main.cpp               the partition-rank (ranks 1..N) executable main
rank0_harness.h                    the rank-0 DPI harness (to #include in your rank-0 main)
README_integration.txt             how to wire rank0_harness.h into a rank-0 testbench
flist.system / flist.library       split file lists for the system vs partition builds
Makefile                           generator's build recipe (OpenPiton-templated — see Part 3)
```

---

## Part 3 — Modifications the generated files need to build & run

The generated `metro_mpi/` is **not** directly executable for Occamy. The
`occamy/Makefile` already drives the build with Occamy-correct flags
(`build-sys` / `build-lib` / `run-mpi`), but the following modifications are
required so the partitioned design builds and co-simulates like the original. They
are listed in the order you hit them.

### 3.0 The difference, measured (unmodified `verilator-private` → what's needed)

This is the concrete gap between what the **baseline** binary
(`rev v5.036-109`) emits and a runnable split, captured by actually building it on
`occamy-orig`:

```bash
cd occamy-orig
make build-lib OCCAMY=$PWD CFG_NAME=mmpi-1x4   # verilates occamy_cluster_wrapper, compiles the partition main
```

Verilation succeeds; the **C++ compile of `occamy_cluster_wrapper_main.cpp` fails**,
with two error classes that map directly to two analyzer gaps:

**(i) Clock name — generated `tick()` drives `top->clk`, but the port is `clk_i`:**
```
occamy_cluster_wrapper_main.cpp:27: error: 'class Voccamy_cluster_wrapper' has no
        member named 'clk'; did you mean 'clk_i'?
        top->clk = 0;            ...   top->clk = !top->clk;   (3 sites)
```
(The init section already uses `clk_i`/`rst_ni`; only the clock-fallback in `tick()`
is wrong.) → analyzer clock detection (issues **G01–G03**).

**(ii) Port width — AXI structs reported width-1, but the Verilated ports are wide:**
```
occamy_cluster_wrapper_main.cpp:54: error: no match for 'operator=' (operand types
        are 'VlWide<9>' and 'int')
        top->narrow_in_req_i = 0;
   ... 'VlWide<3>', 'VlWide<9>', … and the wide_* structs are 'VlWide<24>'
```
The analyzer reported every `narrow_*`/`wide_*_req/resp` port as `width: 1`, so the
generator emitted scalar `= 0` and 1-bit `svBit` DPI args; the real ports are
`VlWide<9>` (≈257–288 b), `VlWide<24>` (≈747–768 b), etc. → packed-struct/typedef
**width resolution** (issues **G07/G38**). This is the dominant gap and it spans
four generated files at once (the partition main, the DPI stub
`modified_occamy_cluster_wrapper.v`, `rank0_harness.h`, and the payload structs in
`metro_mpi.cpp`), so hand-patching is fragile — it is really a **tool fix**.

Summary of every difference (baseline output → required), to re-check against the
generality-fixed binary:

| # | Baseline (`verilator-private` rev -109) emits | What's needed | Owner |
| --- | --- | --- | --- |
| 1 | AXI struct ports → `width: 1`; main assigns `VlWide<N> = int` | real widths (257/261/…/747); packed 32-bit-word MPI payloads | tool (G07/G38) |
| 2 | `tick()` toggles `top->clk` | toggle `top->clk_i` (detected clock) | tool (G01–G03) |
| 3 | main + `rank0_harness.h` both `#include "metro_mpi.cpp"` (no `metro_mpi.h`) | a `metro_mpi.h`/`.cpp` split, OR don't also compile `metro_mpi.cpp` separately (else duplicate symbols) | tool (G47) **or** Makefile (§3.3) |
| 4 | only `rank0_harness.h` + `README_integration.txt` (no rank-0 main) | a rank-0 driver `occamy_quadrant_s1_rank0_main.cpp` | hand-write (§3.1) |
| 5 | `flist.system` replaces `occamy_cluster_wrapper.sv` with the stub → loses `occamy_cluster_pkg` | keep the original source so the package survives | flist (§3.2) |
| 6 | old report schema (`{"partitions": …}`, no `partition_selection`/`schema_version`) | richer schema (additive; consumers reading the new fields differ) | tool (cosmetic) |

Items **1, 2, 3, 6** are analyzer/generator gaps the generality-fixed binary is meant
to close (verified earlier in `verilator-dev`: correct wide widths + `clk_i` + the
`metro_mpi.{h,cpp}` split). Items **4 and 5** are inherent to this structural-cosim
shape and remain even with the fixed binary. The detailed fixes follow.

### 3.0.1 VALIDATED modification set — patched, built, and **simulated** (occamy-orig)

The set below is not a guess: it was applied to the baseline-generated files on
`occamy-orig`, and iterated `build-lib` → `build-sys` → `run-mpi` until the 5-rank
split **actually simulated to a clean shutdown** (`mpirun` exit 0: ranks 0–4 all
print "Ending Communication", "Rank 0: done", no rank left alive). These are the
*minimum* edits that make it run with the unmodified `verilator-private` (rev -109):

| # | File (generated unless noted) | Edit | Unblocked |
| --- | --- | --- | --- |
| 1 | `occamy_cluster_wrapper_main.cpp` | every `top->clk` → `top->clk_i` (tick() + all 4 `handle_requests` cases) | partition **compile** |
| 2 | `occamy_cluster_wrapper_main.cpp` | the **8 `VlWide` AXI structs**: init `= 0;`→`= {};`; receive `top->X = req…;`→`top->X[0] = req…;`; send `resp… = top->X;`→`resp… = top->X[0];` | partition **compile** |
| 3 | `occamy_cluster_wrapper_main.cpp` | delete OpenPiton-only `top->rst_n = 1;` and `top->clk_en = 1;` (no such ports on the Occamy cluster) | partition **compile** |
| 4 | `occamy_cluster_wrapper_main.cpp` | shutdown loop: `handle_requests(); MPI_Iprobe(SHUTDOWN)` → blocking `MPI_Probe(0, MPI_ANY_TAG)`, and if the tag is `SHUTDOWN_TAG` consume it and exit **before** `handle_requests` | **simulate** (else all partition ranks deadlock after rank 0's shutdown) |
| 5 | `modified_occamy_cluster_wrapper.v` | DPI trigger `always @(posedge clk)` → `@(posedge clk_i)` | system **elaboration** |
| 6 | `flist.system` | add the original `…/src/occamy_cluster_wrapper.sv` back (it defines `occamy_cluster_pkg`; the stub doesn't) | system **elaboration** |
| 7 | `occamy/Makefile` (harness) | drop the second `metro_mpi.cpp` from `build-lib`/`build-sys` `-exe` lists (the baseline main already `#include`s it) | **link** (duplicate symbols) |
| 8 | `occamy_quadrant_s1_rank0_main.cpp` (**new, hand-written**) | rank-0 driver: include `rank0_harness.h`, `mpi_initialize()`, drive `clk_i`/`rst_ni` for `OCCAMY_MPI_CYCLES`, `metro_mpi_broadcast_shutdown()`, `mpi_finalize()` | system has no main otherwise |

Then it runs:
```bash
make build-lib OCCAMY=$PWD CFG_NAME=mmpi-1x4
make build-sys OCCAMY=$PWD CFG_NAME=mmpi-1x4
make run-mpi   OCCAMY=$PWD CFG_NAME=mmpi-1x4 OCCAMY_MPI_CYCLES=50   # 5 ranks, clean shutdown
```

Observed `run-mpi` output (`metro_mpi/simulate.log`, `mpirun` exit 0):
```
Rank 0 of 5: system (occamy_quadrant_s1) is alive.
Partition 'occamy_cluster_wrapper' is alive on Rank 1 of 5    (… ranks 2,3,4 likewise)
Initializing partition i_occamy_cluster_0 for Rank 1...       (… 1,2,3 likewise)
[Rank 0] Broadcasting shutdown signal.
Ending Communication from Rank 0
Rank 1: Shutting down.   Ending Communication from Rank 1
Rank 2: Shutting down.   Ending Communication from Rank 2
Rank 3: Shutting down.   Ending Communication from Rank 3
Rank 4: Shutting down.   Ending Communication from Rank 4
Rank 0: done.
```
(5 "Ending Communication" lines, no rank left alive — a clean 5-process shutdown.)

> **⚠️ What "it ran" means — and does NOT mean.** This is a **liveness / structural
> co-simulation only**, not a correct or software-running one. Three caveats:
>
> 1. **Truncated data (not functionally correct).** Edit #2 is a *workaround*, not a
>    fix: the analyzer reports the AXI structs as width 1, so the MPI payload carries
>    only **1 bit** of each 257/261/…/747-bit struct (copied into `word[0]`, upper
>    words 0). The clusters exchange **garbage/truncated** AXI traffic. The split
>    *starts, communicates over MPI each cycle, and shuts down cleanly* — but it does
>    not compute anything correct.
> 2. **No software runs (this is NOT Part 1).** Rank 0 here is just the *quadrant* —
>    no CVA6 host, no HBM, no boot ROM, no fesvr/HTIF — so there is nothing to load an
>    ELF into. It ticks clock/reset across MPI for `OCCAMY_MPI_CYCLES`; it does **not**
>    boot `hello_world`. The "Hello world!" run is the *unpartitioned* Part 1.
> 3. **8 hand-edits were required.** The unmodified generator's output does **not**
>    build or run as-is; the table above is the minimum to make it simulate.
>
> A behaviorally-correct split needs the analyzer to resolve the struct widths
> (G07/G38) so the full packed-word payload is marshalled, and ultimately a
> `top=testharness` + `--mmpi-partition-module occamy_cluster_wrapper` shape (rank 0
> keeps the SoC/fesvr) to run software. That is the point of re-running this with the
> generality-fixed binary — it should make edits #1, #2, #5, #7 unnecessary, leaving
> #4 (deadlock-free shutdown), #6 (flist package), #8 (rank-0 driver).

### 3.0.2 RE-VALIDATED with the generality-fixed binary (`verilator-dev`)

Cleaned `occamy-orig` and re-ran the **whole** loop (regenerate → build-lib →
build-sys → run-mpi) with **`verilator-dev`** (`rev -110`, the 48-issue binary:
G38 struct-width, G01–G03 clock, G04 control, G47 split). Result — **the analyzer/
generator edits are no longer needed; 8 hand-edits drop to 3**, and the split still
builds and simulates to a clean 5-rank shutdown:

| # | baseline edit | with `verilator-dev` |
| --- | --- | --- |
| 1 | AXI structs width-1 → `VlWide = int` | **RESOLVED** — report has real widths (257/261/747/751/530/526/92/88/18); the main emits per-word code (`top->X[0..N]`), the DPI stub declares full width (`input logic [256:0] …`), payloads are packed 32-bit words. |
| 2 | `tick()` drove `top->clk` | **RESOLVED** — uses `clk_i` (see note below on combinational treatment). |
| 3 | OpenPiton `top->rst_n`/`top->clk_en` | **RESOLVED** — not emitted (0 occurrences). |
| 5 | stub `always @(posedge clk)` (wrong name) | **RESOLVED** — no clk-name error (emits `always @(*)`). |
| 7 | main+harness `#include "metro_mpi.cpp"` | **RESOLVED** — `metro_mpi.h` split is generated; the Makefile's separate `metro_mpi.cpp` compile is now correct (restore it for this binary). |
| 4 | deadlock-prone shutdown loop | **STILL NEEDED** — generator loop unchanged. |
| 6 | flist drops `occamy_cluster_pkg` | **STILL NEEDED** — flist still replaces the source. |
| 8 | no rank-0 driver main | **STILL NEEDED** — generator emits only `rank0_harness.h`. |

**Build result:** both `Voccamy_cluster_wrapper` and `Voccamy_quadrant_s1` compiled
with **no** width/clock/`rst_n` edits (only #4/#6/#8 applied). **Run result:** 5 ranks
alive (now printing their role, e.g. `(instance i_occamy_cluster_0)` — the G32/G35
table), `[Rank 0] Broadcasting shutdown`, 5× `Ending Communication`, `Rank 0: done`,
no rank left alive — clean shutdown, `mpirun` exit 0. The AXI traffic is now
**full-width** (correct marshalling), not the baseline's 1-bit truncation.

Takeaways:
- The three remaining edits (#4, #6, #8) are **not analyzer bugs** — they are the
  structural-cosim integration pieces the generator doesn't yet emit: a deadlock-free
  shutdown loop, a package-aware system flist, and a rank-0 driver. Closing them would
  be follow-on generator features (e.g. emit the probe-based loop; keep the partition
  source / split out shared packages; emit a `<top>_rank0_main.cpp`).
- **Remaining analyzer nuance:** even `verilator-dev` returned `clocks: []` /
  `partition_kind: combinational` for `occamy_cluster_wrapper` — it did **not** flag
  `clk_i` as a structural clock, so the stub is `always @(*)` and `clk_i` is marshalled
  as an ordinary data port (rank 0 drives it). This still simulates cleanly, but a
  clk_i-aware clock detection would be the next refinement.
- It is **still a structural/liveness co-sim** (rank 0 is the quadrant, no
  SoC/fesvr → no software boot). Correct *and* software-running needs the
  `top=testharness` + `--mmpi-partition-module occamy_cluster_wrapper` shape (§2.1
  trade-off note). But the data is now correct-width, so this is a faithful structural
  co-sim, not a truncated one.

### 3.0.3 RE-VALIDATED with the 3 generator fixes — **3 hand-edits → 0**

The three "still needed" edits (#4/#6/#8) were the only thing standing between the
generator and a zero-touch flow. They are now implemented in `verilator-dev`
(`rev -110` + Fix A/B/C) — the structural-cosim integration the generator wasn't
emitting. Re-ran the **whole** loop on `occamy-orig` (`OCCAMY=…/occamy-orig`,
`VLT=…/verilator-dev/…/verilator`): regenerate → `build-lib` → `build-sys` →
`run-mpi`, applying **no** hand-edits. Result — **the split builds and simulates
to a clean 5-rank shutdown with zero modifications**:

| # | what was hand-edited before | generator fix | source |
| --- | --- | --- | --- |
| 4 | deadlock-prone shutdown loop (`MPI_Iprobe(SHUTDOWN)` *after* a blocking data recv) | **Fix A** — partition main loop now blocks on `MPI_Probe(0, MPI_ANY_TAG)`; if the next message from rank 0 is `SHUTDOWN_TAG`, consume it and exit *without* `handle_requests()` (so it neither blocks on a data recv nor leaves a dangling send). | `V3MMPI_partition_sim.cpp` |
| 6 | `flist.system` dropped `occamy_cluster_pkg` (replaced source with stub) | **Fix B** — `processFlist` now emits the **original partition source AND** the modified stub; the original module is unreferenced → Verilator prunes it, but its shared package/typedef definitions survive. | `V3MMPI_Makefile.cpp` |
| 8 | no rank-0 driver — had to hand-write `occamy_quadrant_s1_rank0_main.cpp` | **Fix C** — when the analysis command has **no `-exe`** testbench, the generator emits a default `<top>_rank0_main.cpp` (clock/reset name-fallback, `MMPI_CYCLES` env, `metro_mpi_broadcast_shutdown`). Gated on absent `-exe`. | `V3MMPI_main_rank_0.cpp` + `V3Metro_MPI.cpp` |

**Build result:** `Voccamy_cluster_wrapper` (19.9 MB) and `Voccamy_quadrant_s1`
(4.4 MB) both compiled with **zero** hand-edits — `build-sys` linked the
generator-emitted `occamy_quadrant_s1_rank0_main.o` (Fix C) against Fix B's
package-preserving `flist.system` with **no `MODDUP`** (the stub is named
`modified_occamy_cluster_wrapper`, distinct from the pruned original).
**Run result:** `mpirun` exit 0 — 5 ranks alive, Snitch harts boot, `[Rank 0]
Broadcasting shutdown`, all four cluster ranks print `Rank N: Shutting down.`
(Fix A — no deadlock), `Rank 0: simulation complete.`

**OpenPiton (`mmpi-orig`) regression — fixes do NOT break it.** Replayed the
`sims.pl` `--mmpi-o1` command for the `manycore_1x2` config with the same binary
(`-exe …/my_cmp_top.cpp`, the OpenPiton harness):
- **Fix C correctly gates OFF** — because `-exe` is present, **no** `cmp_top_rank0_main.cpp`
  is emitted; OpenPiton keeps using its own testbench. (Confirmed: no driver file, no
  "default rank-0 driver" log line.)
- **Fix B is safe** — `flist.system` keeps `tile.tmp.v` + `modified_tile.v`; the stub
  is `modified_tile` (distinct) so **no `MODDUP`**, and the original `tile` is pruned
  (0 tile TUs in `obj_dir_sys`). `tile.tmp.v` defines no shared package, so keeping it
  is a harmless extra parse.
- **Fix A compiles** into `Vtile`; both `Vcmp_top` and `Vtile` build clean.
- A *manual* (non-`sims.pl`) co-sim launch with a borrowed `mem.image` hits a
  deterministic Verilator `--timing` "Missed a time slot" error **on rank 0
  (`Vcmp_top`)** — but this was **isolated to be independent of all three fixes**
  (reverting Fix A's loop and removing Fix B's `tile.tmp.v` line each left it
  unchanged; Fix C emits nothing for OpenPiton). The pre-fix binary *also* fails to
  complete `hello_world` in this manual harness (it spins instead of erroring), so it
  is a test-environment limitation of the manual launch (the supported flow is
  `sims.pl -mmpi_run`, which provides `diag.ev`/image/coordination), not a regression.

### 3.0.4 Did the partitioned run match the original? — **quadrant-split: No; testharness-split: YES (see Part 4)**

The **Part 3 quadrant-split** (`top=occamy_quadrant_s1`) does **not** reproduce the
monolithic `hello_world` run — it is a structural/liveness co-sim only (rank 0 is just
the quadrant, no SoC/fesvr, no program). A clean-shutdown, exit-0 `mpirun` there does
**not** mean behavioral equivalence.

But the **testharness-split** shape (`top=testharness` + `--mmpi-partition-module
occamy_cluster_wrapper`) **does** reproduce it: rank 0 keeps the full SoC+fesvr and boots
the program while the clusters run as MPI ranks. That run prints the same `Hello world!`
and exits 0 as the golden reference — **full behavioral equivalence, achieved and
documented in Part 4 below.** The rest of this subsection explains the quadrant-split's
limitation (why Part 3 alone is not equivalent); Part 4 is the equivalent run.

The two Part 3 columns are different *kinds* of simulation:

| | Unpartitioned (Part 1 — **golden reference**) | Partitioned (Part 3 — 1×4 quadrant split) |
| --- | --- | --- |
| Top | `testharness` (full SoC) | `occamy_quadrant_s1` (one quadrant) |
| Rank 0 owns | CVA6 + HBM + fesvr + memory image | just the quadrant interconnect — **no SoC, no CVA6, no HBM, no fesvr, no image** |
| Software | boots, runs `hello_world` → `Hello world!` on `uart0.log`, `tohost` → **exit 0** | **none loaded** — Snitch harts are clocked but execute **0 instructions** (`metro_mpi/logs/trace_hart_*.dasm` are **0 bytes**) |
| Runs for | until the program writes `tohost` | a fixed `MMPI_CYCLES` (default 50), then `metro_mpi_broadcast_shutdown` |
| What it establishes | **functional correctness** | **structural liveness only**: the split builds, the AXI ports are marshalled full-width over MPI, all 5 ranks tick and shut down cleanly |

So Part 3 + the 3 generator fixes prove the partition **builds and the MPI co-simulation
is live and terminates cleanly** — they do **not** prove it computes the same result as
the monolith. There is no software output (`Hello world!`, `tohost`, UART) from the
partitioned run to diff against Part 1, because in the quadrant-split shape **rank 0 has
no program to boot**.

**Why:** the partition boundary is `occamy_quadrant_s1` so the duplicate-hash heuristic
lands on the 4 `occamy_cluster_wrapper` instances (§2.1). That necessarily makes rank 0
the *quadrant*, which sits below the SoC/fesvr — it never sees the memory image or the
CVA6 host that drive a real program.

**The behaviorally-equivalent run — achieved.** The `top=testharness` +
`--mmpi-partition-module occamy_cluster_wrapper` shape keeps the **full SoC + fesvr +
memory image** on rank 0 and boots `hello_world` with the clusters as MPI partitions. It
was run and produces the **same `Hello world!` + `tohost` exit 0** as the unpartitioned
golden reference. The v110 elaboration regression no longer blocks it (a clean rebuild of
the fork + the committed `--mmpi-partition-module` override resolve it). See **Part 4**.

### 3.1 Provide a rank-0 driver main (the generator does not emit one)

The generator emits `rank0_harness.h` + `README_integration.txt` that instruct you
to add `mpi_initialize()` / `metro_mpi_broadcast_shutdown()` / `mpi_finalize()` to
**your** testbench `main()`. For this structural co-simulation there is no existing
rank-0 testbench (rank 0 is the bare quadrant/SoC, not the full `testharness`), so
you must supply a small driver:

- **File:** `metro_mpi/occamy_quadrant_s1_rank0_main.cpp` (name must match what
  `occamy/Makefile`'s `build-sys` references; for case (B) it would be
  `occamy_soc_rank0_main.cpp`).
- **What it does:** `#include "rank0_harness.h"`; instantiate the **modified** top
  (`Voccamy_quadrant_s1`), `mpi_initialize()`, drive `clk_i` / `rst_ni` for
  `OCCAMY_MPI_CYCLES` cycles (rank 0 is the clock master; each posedge fires the
  DPI stubs → MPI exchange with ranks 1..N), then `metro_mpi_broadcast_shutdown()`
  and `mpi_finalize()`.
- A working reference exists at
  `target/sim/work-mmpi-1x4-partition_built/metro_mpi/occamy_quadrant_s1_rank0_main.cpp`
  — copy and adapt it.

> Note the clock is `clk_i` / reset is `rst_ni` on Occamy (not `clk` / `rst_n`).
> With the generality-fixed fork the analyzer detects `clk_i` structurally; with an
> older binary the generated `tick()` may emit `top->clk` and must be changed to
> `top->clk_i`.

### 3.2 Keep the partition source in `flist.system` (shared-package fix)

`occamy_cluster_wrapper.sv` defines **both** the module **and**
`package occamy_cluster_pkg`. The generated `flist.system` replaces that file with
the DPI stub, which **drops the package**, so the system build fails with:

```
%Error: occamy_pkg.sv: Package/class for '::' reference not found: 'occamy_cluster_pkg'
```

**Fix:** keep the original `occamy_cluster_wrapper.sv` line in `flist.system` (in
addition to `modified_occamy_cluster_wrapper.v` and the wrappers). The real cluster
module is unused in the system (the modified parent instantiates the wrappers, so
Verilator prunes it), but the **package definition survives**. Concretely, in
`flist.system` add the original path back:

```
/abs/.../target/sim/src/occamy_cluster_wrapper.sv          # keep: provides occamy_cluster_pkg
/abs/.../metro_mpi/modified_occamy_cluster_wrapper.v       # the DPI stub
/abs/.../metro_mpi/i_occamy_cluster_0_..._wrapper.v        # wrappers
...
```

(`flist.library` already keeps the real `occamy_cluster_wrapper.sv` — only
`flist.system` needs the fix.)

### 3.3 Reconcile the `metro_mpi.cpp` translation unit with the Makefile

How the MPI transport is packaged differs between the two binaries, and the build
must match:

- **Baseline (`rev -109`, no G47):** there is **no `metro_mpi.h`**; both
  `occamy_cluster_wrapper_main.cpp` and `rank0_harness.h` do `#include
  "metro_mpi.cpp"` (definitions pulled inline). In that case you must **not** also
  compile `metro_mpi.cpp` as a separate source, or you get **duplicate-symbol**
  link errors. But the supplied `occamy/Makefile` *does* pass `metro_mpi.cpp` to
  both `build-sys`/`build-lib` — so with the baseline binary, **remove
  `metro_mpi.cpp` from those two source lists** (rely on the `#include`).
- **Generality-fixed (G47):** the transport *is* split — `metro_mpi.h`
  (declarations, included by the mains + `rank0_harness.h`) and `metro_mpi.cpp` (the
  single definition). Then `metro_mpi.cpp` **must** be compiled into both binaries,
  exactly as the `occamy/Makefile` already does; omitting it gives undefined
  references (`mpi_initialize`, `getRank`, `metro_bit_masks`, …).

So the one-line rule: **the Makefile's `metro_mpi.cpp` argument is correct iff the
generated mains include `metro_mpi.h` (not `metro_mpi.cpp`).** Check which include
the generated main uses and align the source list accordingly.

### 3.4 Do not use the generator's `metro_mpi/Makefile` verbatim

It is OpenPiton-templated and not valid for Occamy (historically hardcodes
`-GTILE_TYPE=2` — no such parameter on `occamy_cluster_wrapper` — points the system
`-exe` at a directory, and bakes OpenPiton `xterm`/plusargs into `simulate_mpi`).
Build with the `occamy/Makefile` targets instead, which use the Occamy-correct
flags:

```bash
cd occamy
make build-mpi CFG_NAME=mmpi-1x4    # build-sys (rank 0) + build-lib (ranks 1..N)
make run-mpi   CFG_NAME=mmpi-1x4 OCCAMY_MPI_CYCLES=200   # 5-rank mpirun
# for 4×2 case (A): add MPI_NP_PARTITIONS=2 (3 ranks) and CFG_NAME=mmpi-4x2
```

Both models are compiled/linked with `mpic++` + `-lsodium` (the fork is built
`CXX=mpic++` and links libsodium), `--timing`, and `-std=gnu++20 -fcoroutines`.

> With the **generality-fixed** fork, the generated `metro_mpi/Makefile` is much
> cleaner (no `TILE_TYPE`, configurable launcher, derived rank count, `metro_mpi.cpp`
> auto-linked — issues G22–G28/G47), so this step shrinks to "supply the rank-0
> main from 3.1." With the **older committed** binary you additionally needed the
> wide-AXI-struct width fix (structs were reported as width 1 — issues G07/G38) and
> the `clk`→`clk_i` fix; those are resolved by the generality work.

### 3.5 What "running" means here (set expectations)

When it runs (`make run-mpi`), rank 0 is only the quadrant/SoC slice — **there is
no HBM / boot ROM / fesvr in it**, so the clusters are **not** fed a program. The
run exercises clock/reset + AXI/interrupt handshakes across MPI for
`OCCAMY_MPI_CYCLES` cycles and shuts down cleanly. It is a **structural /
liveness** co-simulation (all ranks start, communicate, and finalize), **not** a
software boot, and is currently behavior-unvalidated due to a ~1-cycle comm skew.
A real software run (booting `hello_world` etc.) is the **Part 1** path
(`testharness` + fesvr), which is unrelated to the partition split.

---

## Part 4 — Software-running partition: boot `hello_world` == the original (behavioral equivalence)

This is the milestone Part 3 sets up to: a **Metro-MPI-partitioned Occamy that boots and
runs a real program to completion, producing the same output as the unpartitioned
simulator.** It was run and **matches the golden reference** (`Hello world!`, `tohost`
exit 0).

**The idea.** Use the `testharness` top with the partition-module override so rank 0 stays
the *whole* fesvr-backed SoC (CVA6 host + HBM + bootrom + fesvr) and only the 4 Snitch
`occamy_cluster_wrapper` instances are split out as MPI ranks:

| | Unpartitioned (Part 1, golden) | **Part 4 partition (testharness-split)** |
| --- | --- | --- |
| Top | `testharness` | `testharness` (same) |
| Rank 0 | everything, one process | full SoC + fesvr + host + HBM; the 4 clusters → DPI stubs |
| Ranks 1–4 | — | the 4 `occamy_cluster_wrapper` Snitch clusters |
| `hello_world` result | `Hello world!`, exit 0 | **`Hello world!`, exit 0 (identical)** |

**Why it works (and why the 1-cycle comm skew doesn't break it):** `hello_world` is a
**host-only** app — it runs on the CVA6 host inside rank 0 and leaves the Snitch clusters
idle. The cluster↔SoC boundary is AXI, which is **latency-insensitive** (valid/ready), so
the partition's one-cycle boundary delay just adds latency the protocol already tolerates;
it does not corrupt an idle boundary. (A workload that *offloads* to the clusters would
stress the boundary harder and is the next thing to validate.)

**Everything Occamy-specific stays OUTSIDE Verilator** — only the generated `metro_mpi/`
files plus **one** hand-written rank-0 driver are used; the fork is unmodified.

### 4.1 Generate the testharness-split partition

Run the analysis with `top=testharness`, the cluster override, and the **real fesvr TB as
`-exe`** (so the generator's default-driver, Fix C, correctly gates *off* and you keep the
Occamy testbench). Reuse the Part 1 flist (`work-vlt/files`):

```bash
cd occamy-orig/target/sim
export PATH=$GSOC/verilator-dev/verilator-private/verilator-install/bin:$PATH   # the fork
unset VERILATOR_ROOT
TB=$GSOC/occamy-orig/.bender/git/checkouts/snitch_cluster-*/target/common/test/tb_bin.cc
mkdir -p work-mmpi-sw-partition && cd work-mmpi-sw-partition
verilator -cc --mmpi-o1 --d1 --top-module testharness \
  --mmpi-partition-module occamy_cluster_wrapper \
  -exe $TB -f ../work-vlt/files \
  -Wno-BLKANDNBLK -Wno-LITENDIAN -Wno-CASEINCOMPLETE -Wno-CMPCONST -Wno-WIDTH \
  -Wno-WIDTHCONCAT -Wno-UNSIGNED -Wno-UNOPTFLAT -Wno-fatal --unroll-count 1024 \
  --timing -Wno-MODDUP -Wno-PINMISSING -Wno-IMPLICITSTATIC --Mdir Vmdir
```

This finds `occamy_cluster_wrapper` ×4 under `testharness.i_occamy.i_occamy_soc.
i_occamy_quadrant_s1_0`, rewrites the parent, and emits `metro_mpi/` (modified parent,
4 wrappers, the DPI stub, `metro_mpi.{h,cpp}`, `rank0_harness.h`, `flist.{system,library}`).
No default rank-0 driver is emitted (`-exe` present).

### 4.2 The one piece of hand-written glue: `rank0_tb_main.cc`

The generated `metro_mpi/README_integration.txt` says to add three hooks to your testbench
`main()`. Apply them to a copy of the stock fesvr TB (`tb_bin.cc`) — this is the **only**
file you write, and it is Occamy-side, not in Verilator:

```cpp
#include <cstdio>
#include "sim.hh"
#include "rank0_harness.h"          // defines dpi_occamy_cluster_wrapper + the MPI helpers
int main(int argc, char **argv, char **env) {
    mpi_initialize();                            // (1) before the sim (DPI runs during eval)
    FILE *fd = fopen(".rtlbinary", "w");
    if (fd && argc >= 2) { fprintf(fd, "%s\n", argv[1]); fclose(fd); }
    auto sim = std::make_unique<sim::Sim>(argc, argv);
    int ret = sim->run();                        // stock fesvr run: boots+runs the ELF to tohost
    metro_mpi_broadcast_shutdown();              // (2) tell the cluster ranks to exit
    mpi_finalize();                              // (3)
    return ret;
}
```

### 4.3 Build the two models

**Rank 0 (system = fesvr SoC, clusters stubbed).** Verilate `flist.system` to a library,
then link with the TB objects (reuse Part 1's `work-vlt/tb/*.o` + `vlt/*.o` + `libfesvr.a`;
recompile `verilator_lib.cc` against the new `Vmdir_sys` since it includes the model header)
and your `rank0_tb_main.o` + a separate `metro_mpi.o`:

```bash
# (a) verilate the stubbed testharness  (~10-15 min; smaller than Part 1 — cluster internals gone)
verilator --Mdir Vmdir_sys -f metro_mpi/flist.system <same VLT flags as 4.1> \
  -j 4 --cc --build --top-module testharness
# (b) compile glue + metro_mpi against the new Mdir, link with reused fesvr TB objects
mpic++ -std=gnu++20 -fcoroutines -pthread -I Vmdir_sys -I $VLT_ROOT/include \
  -I $VLT_ROOT/include/vltstd -I work-vlt/riscv-isa-sim/include -I <snitch test dir> \
  -I test -I test/uartdpi -I metro_mpi -c {verilator_lib.cc,rank0_tb_main.cc,metro_mpi/metro_mpi.cpp}
mpic++ -std=gnu++20 -L work-vlt/lib -o bin/occamy_top.mpi.vlt \
  rank0_tb_main.o verilator_lib.o metro_mpi.o \
  work-vlt/tb/{common_lib,ipc,bootrom,bootdata,uartdpi}.o \
  work-vlt/vlt/{verilated,verilated_dpi,verilated_threads,verilated_timing,verilated_vcd_c}.o \
  Vmdir_sys/Vtestharness__ALL.a -lfesvr -lpthread -lsodium
```

**Ranks 1–4 (the cluster partition).** Identical to Part 3's `build-lib`, from *this*
generation's `metro_mpi/` (so the MPI struct layouts match rank 0):

```bash
cd metro_mpi
verilator --cc --exe --Mdir obj_dir_lib --top-module occamy_cluster_wrapper \
  occamy_cluster_wrapper_main.cpp metro_mpi.cpp -f flist.library \
  --timing --unroll-count 1024 <warns> -CFLAGS "-I$PWD -std=gnu++20 -fcoroutines"
make -C obj_dir_lib -j -f Voccamy_cluster_wrapper.mk CXX=mpic++ LINK=mpic++ LDLIBS=-lsodium
```

### 4.4 Run it — and compare to the golden reference

```bash
ELF=.../sw/host/apps/hello_world/build/hello_world.part.elf
SYS=.../work-mmpi-sw-partition/bin/occamy_top.mpi.vlt
LIB=.../work-mmpi-sw-partition/metro_mpi/obj_dir_lib/Voccamy_cluster_wrapper
mpirun -np 1 $SYS $ELF : -np 1 $LIB : -np 1 $LIB : -np 1 $LIB : -np 1 $LIB
cat uart0.log     # -> Hello world!     (identical to the unpartitioned Part 1 run)
```

**Verified result (occamy-orig, 1×4, 2026-06-25):**
- `uart0.log` = `Hello world!` — **identical to the unpartitioned golden reference**;
  `mpirun` exit 0.
- The log shows the real software boot — `[fesvr] Wrote … bootrom … entry point 0x80000000
  … bootdata`, then at the end `[Rank 0] Broadcasting shutdown`, all four
  `Rank N: Shutting down.`, `Ending Communication from Rank 0..4`.
- It reaches `tohost` at **~3.7M cycles**. **Give it enough wall-clock:** the MPI co-sim
  runs ~5k cycles/s here, so it needs ~12 min — a 600 s cap times out *short* of the boot
  (≈3.1M cycles) and looks like a hang but is not. Use a generous `timeout` (≥1500 s).
- This is **behaviorally equivalent for a host-only workload.** A cluster-*offloaded* app
  would exercise the boundary AXI under load and is the next validation step.

### 4.5 Both configs run software — 1×4 (cluster split) and 4×2 (quadrant split)

Both committed configs boot `hello_world` to the same `Hello world!` + exit 0 as their
unpartitioned selves — but the **partition boundary differs per config**, because of where
the repeated module sits in the hierarchy:

| Config | Partition module | Boundary | Ranks | Result |
| --- | --- | --- | --- | --- |
| **1×4** (1 quadrant × 4 clusters) | `occamy_cluster_wrapper` | 4 clusters under the **single** `occamy_quadrant_s1` instance | rank 0 (SoC/fesvr) + 4 cluster ranks | `Hello world!`, exit 0 (~3.7M cyc, ~12 min) |
| **4×2** (4 quadrants × 2 clusters) | `occamy_quadrant_s1` | 4 quadrants under the **single** `occamy_soc` instance | rank 0 (SoC/fesvr) + 4 quadrant ranks (2 clusters each) | `Hello world!`, exit 0 (~3.7M cyc, ~25 min) |

**Why 4×2 cannot split at the *cluster* boundary.** Its 8 `occamy_cluster_wrapper`
instances live under **four different** `occamy_quadrant_s1` parent *instances*. The
generator's parent-rewrite is at the *module* level (one `occamy_quadrant_s1.sv` with 2
cluster instances, elaborated 4×), so it cannot give the 8 physical clusters distinct MPI
ranks. The tool **detects this and refuses** (it does not silently mis-route):

```
[Metro-MPI] ERROR: --mmpi-partition-module 'occamy_cluster_wrapper' matched instances
under multiple parent scopes: …i_occamy_quadrant_s1_0 …_1 …_2 …_3
```

So for 4×2 you partition one level up, at `occamy_quadrant_s1` — its 4 instances **are**
under one parent (`occamy_soc`), a valid single-parent group. Everything else is identical
to §4.1–4.4: same `rank0_tb_main.cc` glue (it just `#include`s whatever `rank0_harness.h`
the run generated — here the DPI is `dpi_occamy_quadrant_s1`), same build/link recipe, run
with 4 partition ranks. Verilator is still unmodified.

```bash
# 4x2: regen RTL for the config, then analyze at the quadrant boundary
make CFG_OVERRIDE=cfg/mmpi-4x2.hjson VERIBLE_FMT=true rtl
bender script verilator -t rtl -DCOMMON_CELLS_ASSERTS_OFF -t cv64a6_imafdc_sv39 \
  -t occamy_sim -t snitch_cluster > files
verilator -cc --mmpi-o1 --d1 --top-module testharness \
  --mmpi-partition-module occamy_quadrant_s1 -exe <tb_bin.cc> -f files <VLT flags>
# build sys (testharness, quadrants stubbed) + lib (occamy_quadrant_s1) + rank-0 TB  (as §4.3)
# (rebuild bootdata.o from this config's test/bootdata.cc; the host hello_world ELF is config-independent)
mpirun -np 1 bin/occamy_top.mpi.vlt $ELF \
  : -np 1 obj_dir_lib/Voccamy_quadrant_s1 : -np 1 … : -np 1 … : -np 1 …   # 4 quadrant ranks
```

**Verified (occamy-orig, 2026-06-25):** 4×2 quadrant-split → `uart0.log` = `Hello world!`,
`mpirun` exit 0, `[Rank 0] Broadcasting shutdown` + all 4 `Rank N: Shutting down.` It is
slower than 1×4 (~2.5k cyc/s, ~25 min) because each partition rank is a whole quadrant with
**two** Snitch clusters. **General lesson:** pick the partition module so the repeated
instances share **one** parent instance — the deepest level where they're siblings under a
single parent.

---

## Quick reference

| Goal | Command(s) |
| --- | --- |
| Make the two configs | `sed` from `full.hjson` → `cfg/mmpi-1x4.hjson`, `cfg/mmpi-4x2.hjson` (§0) |
| Run software, 1×4 | `make CFG_OVERRIDE=cfg/mmpi-1x4.hjson bin/occamy_top.vlt && ./bin/occamy_top.vlt <elf>` |
| Run software, 4×2 | `make CFG_OVERRIDE=cfg/mmpi-4x2.hjson bin/occamy_top.vlt && ./bin/occamy_top.vlt <elf>` |
| Partition analysis, 1×4 | `cd occamy && make all` (top=`occamy_quadrant_s1`, 4 clusters) |
| Partition analysis, 4×2 (A) | `make partition CFG_NAME=mmpi-4x2 TOP_MODULE=occamy_quadrant_s1` (2 clusters) |
| Partition analysis, 4×2 (B) | `make partition CFG_NAME=mmpi-4x2 TOP_MODULE=occamy_soc` (4 quadrants — verify report) |
| Build + run the split | fix generated files (Part 3) → `make build-mpi … && make run-mpi …` |
