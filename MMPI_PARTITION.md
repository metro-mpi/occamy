# Occamy Metro-MPI Partitioning — A 4-Partition Design

This note explains **which Occamy configuration** to use to get a partitioned
MPI simulation analogous to the OpenPiton 2×2 case (4 partition ranks + rank 0),
**why** it is the right one for the current Metro-MPI Verilator flow, the
**exact commands** (captured in `Makefile`), and how to **build & run** the
generated 5-rank split.

**Status (2026-06-09):** `make all` generates the full `metro_mpi/` split — **4
`occamy_cluster_wrapper` partitions (ranks 1–4) + rank 0 = 5 MPI ranks**.
Getting there required (a) the right config, (b) a *clean rebuild* of the
Verilator fork, and (c) the right `--top-module`. See §6 for build & run.

---

## 1. What the analyzer needs

The Metro-MPI analyzer (`--mmpi-o1 --d1`) partitions on **repeated module
instances that share a single direct parent scope** — like OpenPiton, where the
2×2 grid is 4 `tile` instances under one `chip`. Two facts about the **currently
committed** binary (commit `9c0cc7a72`) shaped the choices here:

1. **No `--mmpi-partition-module` override.** That option (described in
   `verilator-private/MMPI_CONTEXT.md`) lived only in an *uncommitted* tree; the
   committed binary rejects it (`Invalid option`). Selection is therefore
   whatever the **duplicate-hash heuristic** picks.
2. **The heuristic only looks at LEVEL 1** — the duplicate group among the
   *direct children* of `--top-module`. It does not descend to find a heavier
   group deeper down.

Together: **the module you want to partition must be a direct child of the top
module you pass.**

## 2. Occamy hierarchy and the config knobs

```
testharness
└─ occamy_top
   └─ occamy_soc
      └─ occamy_quadrant_s1            (one per `nr_s1_quadrant`)
         └─ occamy_cluster_wrapper     (one per `s1_quadrant.nr_clusters`)
            └─ ... Snitch cluster (9 harts, FPnew, SSR, TCDM) ...
```

The Snitch **`occamy_cluster_wrapper`** is the analog of an OpenPiton `tile`
(replicated compute engine); its parent **`occamy_quadrant_s1`** is the analog
of `chip`. Knobs live in `cfg/*.hjson`:

| Config                     | `nr_s1_quadrant` | `nr_clusters` | cluster_wrappers / quadrant | 4-partition?                         |
| -------------------------- | ---------------- | ------------- | --------------------------- | ------------------------------------ |
| `single-cluster.hjson`     | 1                | 1             | 1                           | no — only 1 instance                 |
| `mmpi-2x2.hjson`           | 2                | 2             | 2 under **each** of 2 quads | no — clusters split across **two** parents |
| `full.hjson`               | 6                | 4             | 4 under each of 6 quads     | too big; also multi-parent           |
| **`mmpi-1x4.hjson`** (new) | **1**            | **4**         | **4 under the one quadrant**| **yes — 4 instances, one parent**    |

The 2×2 config is the wrong shape: its four clusters live under **two**
`occamy_quadrant_s1` parents, which the analyzer rejects. **One quadrant with
four clusters** puts all four `occamy_cluster_wrapper` instances under a single
parent.

## 3. The chosen config: `cfg/mmpi-1x4.hjson` (1 quadrant × 4 clusters)

Derived from `cfg/full.hjson` by forcing `nr_s1_quadrant: 1` (keeping
`s1_quadrant.nr_clusters: 4`). Verified hierarchy:

```
occamy_quadrant_s1   i_occamy_quadrant_s1_0          <- single parent (rank 0)
├─ occamy_cluster_wrapper i_occamy_cluster_0         <- rank 1
├─ occamy_cluster_wrapper i_occamy_cluster_1         <- rank 2
├─ occamy_cluster_wrapper i_occamy_cluster_2         <- rank 3
└─ occamy_cluster_wrapper i_occamy_cluster_3         <- rank 4
```

All four are the **same** module with **no `#(...)` overrides**. The analyzer
assigns them ranks 1–4 (confirmed in `partition_report.json`).

## 4. Choosing the top module (the key trick)

Because the heuristic only inspects level 1, the top module decides what gets
partitioned:

| `--top-module`         | level-1 duplicate group selected           | useful? |
| ---------------------- | ------------------------------------------ | ------- |
| `testharness`          | **8 × `tb_memory_axi`** (HBM models)       | no — testbench memories |
| `occamy_top`           | **9 × `axi_multicut`** (interconnect cuts) | no      |
| **`occamy_quadrant_s1`** | **4 × `occamy_cluster_wrapper`**         | **yes** |

So set **`--top-module occamy_quadrant_s1`** (the clusters' direct parent).
**Rank 0 is then the quadrant** (its narrow/wide AXI crossbars +
`occamy_quadrant_s1_ctrl`); ranks 1–4 are the four Snitch clusters — a clean
analog of OpenPiton partitioning `chip` into `tile`s.

**Comm topology:** every cluster port talks only to rank 0 (`[system]`), never
cluster-to-cluster — Occamy clusters hang off the quadrant AXI crossbars
(star/hub), unlike OpenPiton tiles which talk to N/E/W/S neighbors (mesh). So
rank 0 is the hub all four clusters exchange with.

> Trade-off: rank 0 is the *quadrant*, not the full `testharness`/SoC, so this
> split does not carry the HBM/boot/UART environment needed to boot real
> software — it is a structural co-simulation. To keep `testharness` as rank 0
> while still selecting the clusters, the tool needs the
> `--mmpi-partition-module occamy_cluster_wrapper` override (the generalization
> work in progress in `verilator-private`, e.g. `src/V3MMPI_Util.h`).

## 5. Generate the split (`make`)

From the `occamy/` directory:

```bash
make rtl        # create cfg/mmpi-1x4.hjson + generate RTL
make flist      # Bender Verilator file list (1263 lines)
make partition  # verilator --mmpi-o1 --d1 (top=occamy_quadrant_s1) -> metro_mpi/
make all        # all of the above
```

Output lands in `target/sim/work-mmpi-1x4-partition/metro_mpi/`:
`partition_report.json`, `view_json.py`, `wire_trace.txt`,
`modified_occamy_quadrant_s1.v` (parent with the 4 clusters replaced by DPI
stubs), `modified_occamy_cluster_wrapper.v` (the DPI stub), four
`i_occamy_cluster_<n>_..._wrapper.v`, `metro_mpi.cpp`,
`occamy_cluster_wrapper_main.cpp`, `rank0_harness.h`, `Makefile`,
`flist.system`, `flist.library`, `README_integration.txt`.

The generated `flist.system` correctly swaps in the modified parent + wrappers +
DPI stub (drops the original `occamy_quadrant_s1.sv`/`occamy_cluster_wrapper.sv`);
`flist.library` keeps the real `occamy_cluster_wrapper.sv`.

## 6. Build & run the 5-rank MPI simulation — current status: BLOCKED

`make build-mpi` and `make run-mpi` exist and are wired correctly, but the build
is **currently blocked by a generator limitation** (see below). What works and
what doesn't:

- ✅ **Partition RTL verilates.** `verilator --cc occamy_cluster_wrapper` (the
  library/partition top) elaborates and emits C++ in ~30 s.
- ✅ **Build scaffolding is correct.** The generator's `metro_mpi/Makefile` is
  OpenPiton-templated and unusable for Occamy (hard-codes `-GTILE_TYPE=2` — no
  such param on `occamy_cluster_wrapper`; its `system` `-exe` points at a
  directory; `simulate_mpi` carries OpenPiton plusargs/xterm), so this repo
  drives the build itself from `Makefile` with the Occamy-correct flags:
  - `metro_mpi/metro_mpi_rank0_main.cpp` — a hand-written rank-0 testbench the
    generator does not emit (instantiates the modified `occamy_quadrant_s1`,
    includes `rank0_harness.h`, `mpi_initialize()`, drives `clk_i`/`rst_ni` for
    `OCCAMY_MPI_CYCLES` cycles, then `metro_mpi_broadcast_shutdown()` +
    `mpi_finalize()`; rank 0 is the clock master).
  - both models compiled/linked with `mpic++` + `-lsodium` (the fork is built
    `CXX=mpic++` and links libsodium), `-GTILE_TYPE=2` dropped.
- ❌ **The generated `occamy_cluster_wrapper_main.cpp` does not compile** (66
  errors). Root cause: the analyzer **does not resolve packed-struct / typedef
  port widths**, so every AXI request/response struct on the cluster boundary is
  reported as **width 1** in `partition_report.json`. But the real Verilated
  ports are wide vectors:

  | cluster port        | report width | actual Verilated type            |
  | ------------------- | ------------ | -------------------------------- |
  | `narrow_in_req_i`   | 1            | `VL_INW(...,256,0,9)`  = 257 bits |
  | `narrow_out_req_o`  | 1            | `VL_OUTW(...,260,0,9)` = 261 bits |
  | `wide_in_req_i`     | 1            | `VL_INW(...,746,0,24)` = 747 bits |
  | …the other AXI req/resp structs likewise |

  So the generated code emits `top->narrow_in_req_i = 0;` (assigning `int` to a
  `VlWide<9>`) and DPI signatures using `svBit` (1-bit) where the model has
  `svBitVecVal*` arrays — a width mismatch across the generated main, the DPI
  stubs, `rank0_harness.h`, and the MPI payload structs in `metro_mpi.cpp`.
  (A secondary bug: the clock-name fallback emits `top->clk` instead of the
  detected `clk_i` in `tick()`.)

This is a **tool limitation, not a config/build problem.** OpenPiton's `tile`
boundary is flat NoC vectors and bits, which the generator handles; Occamy's
cluster boundary is almost entirely wide AXI *packed structs*, which it does
not yet width-resolve. The fix belongs in the analyzer/generator (resolve
struct/typedef widths → then the existing >64-bit packed-32-bit-word MPI path
can engage), which is the generalization work in progress in `verilator-private`
(`src/V3MMPI_Util.h`). Hand-patching the marshalling for ~6 wide structs × 4
ranks would be fragile and would misrepresent the tool, so it is intentionally
not done here.

Once the generator resolves struct port widths, the flow is ready:

```bash
make build-mpi   # verilate+compile rank-0 (system) and partition (library) models
make run-mpi     # mpirun -np 1 <system> : -np 4 <partition>   (5 ranks)
# tunable: make run-mpi OCCAMY_MPI_CYCLES=500
```

> When it runs: because rank 0 is only the quadrant (no SoC/HBM/bootrom), the
> clusters are not fed a program, so the run exercises clock/reset +
> AXI/interrupt handshakes across MPI rather than booting software — a
> structural validation that the auto-generated split co-simulates across 5
> ranks.

---

## 7. Required: clean rebuild of the Verilator fork

This flow elaborates Occamy **only with a clean build of the committed tree**.

A previously-built binary (tagged `(mod)` — built from a *dirty* working tree)
aborted during front-end elaboration in the `V3Width` constant-function pass,
*before* the `--mmpi-o1` hook, with 17 errors like:

```
%Error: .../snitch_cluster.sv:265: Expecting expression to be constant,
        but can't determine constant for FUNCREF 'get_tcdm_port_offs'
   ... core_idx = ?32?h2        <-- the ?..? operands are X (unknown) bits
   ... Loop simulation took too long; ... set '--unroll-limit' above 1
```

The `?32?h…` operands are Verilator's notation for **X (unknown) bits**: loop
bounds (core/format counts) were not resolving to constants, so constant-function
simulation ran to its cap. Not fixed by `--unroll-count/-limit/-stmts`,
independent of `--timing`/`--mmpi`, reproduced on plain `--lint-only`.

**A clean rebuild of the committed source resolves it.** If those `?..?`-bit
constant-function errors ever reappear, rebuild clean rather than chasing flags:

```bash
cd verilator-private
export CXX=mpic++ LIBS=-lsodium      # the fork's required toolchain
make clean
rm -rf verilator-install
autoconf && ./configure --prefix="$PWD/verilator-install"
make -j"$(nproc)" && make install
verilator --version                  # should NOT show the "(mod)" suffix
```

`(mod)` in `verilator --version` means the binary was built from a tree with
uncommitted *tracked* changes; a clean build of `9c0cc7a72` shows
`rev v5.036-110-g9c0cc7a72` with no `(mod)`.
