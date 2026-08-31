# Makefile — Metro-MPI partition flow for Occamy
# ============================================================================
# Drives the custom MPI-parallelized Verilator fork
# (verilator-private/verilator-install/bin/verilator) over a deliberately
# chosen Occamy configuration whose hierarchy mirrors an OpenPiton 2x2:
# FOUR identical `occamy_cluster_wrapper` instances under a SINGLE parent
# (`occamy_quadrant_s1`) -> 4 partition ranks + rank 0  (= 5 MPI processes).
#
# Selection note: the committed Verilator (commit 9c0cc7a72) selects the
# partition module via the duplicate-hash heuristic, which only inspects the
# duplicate group at LEVEL 1 (the direct children of --top-module). It has no
# --mmpi-partition-module override yet. So to land on the clusters we set the
# top module to their direct parent, occamy_quadrant_s1: its level-1 duplicate
# group is exactly the 4 occamy_cluster_wrapper instances. (With
# --top-module testharness the heuristic instead picks the 8 tb_memory_axi HBM
# models; with occamy_top it picks 9 axi_multicut cuts.)
#
# See MMPI_PARTITION.md for the full rationale.
#
# Usage (from the occamy/ directory):
#   make rtl        # generate RTL for the 1-quadrant x 4-cluster config
#   make flist      # emit the Bender Verilator file list
#   make partition  # run --mmpi-o1 --d1 partition analysis -> metro_mpi/
#   make all        # rtl + flist + partition
#   make clean
# ============================================================================

# ---- Paths (override on the command line if your layout differs) -----------
GSOC        ?= /home/kislay/Documents/gsoc
OCCAMY      ?= $(GSOC)/occamy
VLT         ?= $(GSOC)/verilator-private/verilator-install/bin/verilator
BENDER      ?= $(GSOC)/.codex-tools/bin/bender
VENV_BIN    ?= $(GSOC)/.codex-venvs/occamy/bin

# The software-running (sw-*) targets need --mmpi-partition-module, which the
# plain VLT above does not support (it predates that flag). Point those
# targets at the newer verilator-dev tree instead. Override on the command
# line if your fork tree is laid out differently.
VLT_DEV     ?= $(GSOC)/verilator-dev/verilator-private/verilator-install/bin/verilator

# Put the venv (hjson/mako/reggen deps) and bender on PATH for the generators.
export PATH := $(VENV_BIN):$(dir $(BENDER)):$(PATH)

# ---- Configuration ---------------------------------------------------------
# 1 quadrant x 4 clusters. Derived from cfg/full.hjson (6 quadrants x 4) by
# forcing nr_s1_quadrant -> 1, keeping s1_quadrant.nr_clusters = 4.
CFG_NAME    ?= mmpi-1x4
CFG         ?= cfg/$(CFG_NAME).hjson

SIM_DIR     := $(OCCAMY)/target/sim
SRC_CFG     := $(SIM_DIR)/$(CFG)
FULL_CFG    := $(SIM_DIR)/cfg/full.hjson

# Work dirs (kept separate from the normal work-vlt/ simulator build).
FLIST_DIR   := $(SIM_DIR)/work-$(CFG_NAME)
FLIST       := $(FLIST_DIR)/files
PART_DIR    := $(SIM_DIR)/work-$(CFG_NAME)-partition

# Partition boundary. occamy_cluster_wrapper (the Snitch compute cluster) is the
# analog of an OpenPiton `tile`; occamy_quadrant_s1 (its parent) is the analog
# of `chip`. We make the quadrant the top so the level-1 duplicate group the
# heuristic sees is the 4 clusters. rank 0 then owns the quadrant interconnect.
TOP_MODULE       ?= occamy_quadrant_s1

# ---- Bender target set (must match the normal Occamy Verilator build) ------
BENDER_TARGETS := -t rtl -t occamy_sim -t snitch_cluster -t cv64a6_imafdc_sv39
BENDER_DEFS    := -DCOMMON_CELLS_ASSERTS_OFF

# ---- Verilator flags -------------------------------------------------------
# Warning suppressions mirror the documented Occamy baseline; the Metro-MPI
# flags (--mmpi-o1 --d1) run the partition analysis and exit before C++ codegen.
VLT_WARN := -Wno-BLKANDNBLK -Wno-LITENDIAN -Wno-CASEINCOMPLETE -Wno-CMPCONST \
            -Wno-WIDTH -Wno-WIDTHCONCAT -Wno-UNSIGNED -Wno-UNOPTFLAT \
            -Wno-MODDUP -Wno-PINMISSING -Wno-IMPLICITSTATIC -Wno-ALWCOMBORDER \
            -Wno-SYMRSVDWORD -Wno-LATCH -Wno-COMBDLY -Wno-SHORTREAL -Wno-fatal

VLT_COMMON := --top-module $(TOP_MODULE) --timing --unroll-count 1024

.PHONY: all rtl flist partition build-mpi build-lib build-sys run-mpi clean print-config

all: partition

# Generated split dir, MPI build settings.
MMPI_DIR    := $(PART_DIR)/metro_mpi
OCCAMY_MPI_CYCLES ?= 200
MPI_NP_PARTITIONS ?= 4    # ranks 1..4 = the 4 occamy_cluster_wrapper instances

print-config:
	@echo "CFG         = $(CFG)"
	@echo "VLT         = $(VLT)"
	@echo "TOP_MODULE  = $(TOP_MODULE)"
	@echo "FLIST       = $(FLIST)"
	@echo "PART_DIR    = $(PART_DIR)"

# ---- 1. Create the 1-quadrant x 4-cluster config (idempotent) --------------
$(SRC_CFG): $(FULL_CFG)
	@echo "[mmpi] Deriving $(CFG_NAME) (1 quadrant x 4 clusters) from full.hjson"
	cp $(FULL_CFG) $(SRC_CFG)
	sed -i -e 's/nr_s1_quadrant: 6,/nr_s1_quadrant: 1,/' $(SRC_CFG)
	@echo "[mmpi] knobs:"; grep -nE 'nr_s1_quadrant|nr_clusters' $(SRC_CFG)

# ---- 2. Generate RTL -------------------------------------------------------
rtl: $(SRC_CFG)
	@echo "[mmpi] Generating RTL for $(CFG)"
	$(MAKE) -C $(SIM_DIR) BENDER=$(BENDER) VERIBLE_FMT=true CFG_OVERRIDE=$(CFG) rtl
	@echo "[mmpi] cluster_wrapper instances under occamy_quadrant_s1:"
	@grep -c 'occamy_cluster_wrapper i_' $(SIM_DIR)/src/occamy_quadrant_s1.sv

# ---- 3. Emit Bender Verilator file list ------------------------------------
flist: rtl
	@echo "[mmpi] Writing Bender Verilator flist -> $(FLIST)"
	mkdir -p $(FLIST_DIR)
	cd $(OCCAMY) && $(BENDER) script verilator $(BENDER_TARGETS) $(BENDER_DEFS) > $(FLIST)
	@echo "[mmpi] flist lines: $$(wc -l < $(FLIST))"

# ---- 4. Run the Metro-MPI partition analysis -------------------------------
# Verilator writes metro_mpi/ relative to its CWD, so we run from PART_DIR to
# keep the normal simulator build untouched. --d1 exits right after analysis.
partition: flist
	@echo "[mmpi] Running Metro-MPI partition analysis (top=$(TOP_MODULE))"
	rm -rf $(PART_DIR) && mkdir -p $(PART_DIR)
	cd $(PART_DIR) && $(VLT) \
	    --cc --build --mmpi-o1 --d1 \
	    --Mdir Vmdir \
	    -f $(FLIST) \
	    $(VLT_COMMON) $(VLT_WARN) \
	    2>&1 | tee partition.log
	@echo "[mmpi] === metro_mpi/ contents ==="
	@ls -la $(PART_DIR)/metro_mpi/ 2>/dev/null || \
	    echo "[mmpi] metro_mpi/ NOT created -- see $(PART_DIR)/partition.log"
	@echo "[mmpi] Selected partition module:"; \
	    grep -E "Found [0-9]+ partition instances" $(PART_DIR)/partition.log || true

# ---- 5. Build & run the generated 5-rank MPI split -------------------------
# Both models build with mpic++ + -lsodium (the fork is MPI-built); the
# OpenPiton -GTILE_TYPE flag is intentionally absent. Wide AXI struct ports
# (257/747-bit) are marshalled as uint32_t[] word arrays over MPI_BYTE.
# The rank-0 driver is generator-produced as <TOP_MODULE>_rank0_main.cpp.

build-lib:        ## partition model (ranks 1..4): Voccamy_cluster_wrapper
	cd $(MMPI_DIR) && $(VLT) --cc --exe --Mdir obj_dir_lib \
	    --top-module occamy_cluster_wrapper \
	    occamy_cluster_wrapper_main.cpp metro_mpi.cpp -f flist.library \
	    --timing --unroll-count 1024 $(VLT_WARN) \
	    -CFLAGS "-I$(MMPI_DIR) -std=gnu++20 -fcoroutines"
	$(MAKE) -C $(MMPI_DIR)/obj_dir_lib -j6 -f Voccamy_cluster_wrapper.mk \
	    CXX=mpic++ LINK=mpic++ LDLIBS=-lsodium

build-sys:        ## rank-0 model: Voccamy_quadrant_s1 (clusters -> DPI stubs)
	cd $(MMPI_DIR) && $(VLT) --cc --exe --Mdir obj_dir_sys \
	    --top-module occamy_quadrant_s1 \
	    occamy_quadrant_s1_rank0_main.cpp metro_mpi.cpp -f flist.system \
	    --timing --unroll-count 1024 $(VLT_WARN) \
	    -CFLAGS "-I$(MMPI_DIR) -std=gnu++20 -fcoroutines"
	$(MAKE) -C $(MMPI_DIR)/obj_dir_sys -j6 -f Voccamy_quadrant_s1.mk \
	    CXX=mpic++ LINK=mpic++ LDLIBS=-lsodium

build-mpi: build-sys build-lib

run-mpi:          ## launch rank 0 (system) + 4 partition ranks under MPI
	cd $(MMPI_DIR) && OCCAMY_MPI_CYCLES=$(OCCAMY_MPI_CYCLES) mpirun \
	    -np 1 obj_dir_sys/Voccamy_quadrant_s1 \
	    $(foreach r,$(shell seq 1 $(MPI_NP_PARTITIONS)),: -np 1 obj_dir_lib/Voccamy_cluster_wrapper) \
	    2>&1 | tee $(MMPI_DIR)/simulate.log

# ============================================================================
# Software-running partition: boots a real RISC-V program (e.g. hello_world)
# on the partitioned design and produces output identical to the un-
# partitioned build. Unlike `partition`/`build-mpi`/`run-mpi` above (which
# make the *quadrant* the top module and only exercise clock/reset/AXI
# handshakes), this flow keeps `testharness` as top -- so rank 0 is the full
# fesvr-backed SoC (boot ROM, HBM, UART, RISC-V host core) -- and selects the
# 4 `occamy_cluster_wrapper` instances explicitly with
# `--mmpi-partition-module`. See RANK0_TB_MAIN.md for why `rank0_tb_main.cc`
# (the only hand-written file in this flow) is needed.
#
# Prerequisites (build once, standard non-partitioned Occamy flow):
#   make -C target/sim CFG_OVERRIDE=$(CFG) rtl
#   make -C target/sim CFG_OVERRIDE=$(CFG) bin/occamy_top.vlt   # -> work-vlt/, bin/occamy_top.vlt
#   make -C target/sim CFG_OVERRIDE=$(CFG) DEBUG=ON sw          # -> sw/host/apps/hello_world/build/*.part.elf
#
# Usage:
#   make partition-sw   # analyze + generate metro_mpi/ (testharness top, cluster override)
#   make build-sw        # verilate + link rank-0 (fesvr SoC) and the cluster partition
#   make run-sw           # defaults to the hello_world ELF; override with ELF=<path relative to target/sim/>
#   cat target/sim/uart0.log   # -> "Hello world!"
# ============================================================================

.PHONY: partition-sw build-sw-sys build-sw-lib build-sw run-sw

SW_PART_DIR   := $(SIM_DIR)/work-$(CFG_NAME)-sw-partition
SW_MMPI_DIR   := $(SW_PART_DIR)/metro_mpi
WORK_VLT_DIR  := $(SIM_DIR)/work-vlt
TB_BIN_CC     := $(wildcard $(OCCAMY)/.bender/git/checkouts/snitch_cluster-*/target/common/test/tb_bin.cc)
SNITCH_TEST_DIR := $(dir $(TB_BIN_CC))
VLT_ROOT      := $(shell $(VLT_DEV) --getenv VERILATOR_ROOT 2>/dev/null | awk 'NF{line=$$0} END{print line}')
SW_CLUSTER_MODULE ?= occamy_cluster_wrapper

partition-sw: flist
	@test -n "$(TB_BIN_CC)" || (echo "[mmpi-sw] tb_bin.cc not found under .bender/ -- run 'bender checkout' first" && exit 1)
	@echo "[mmpi-sw] Running Metro-MPI partition analysis (top=testharness, module=$(SW_CLUSTER_MODULE))"
	rm -rf $(SW_PART_DIR) && mkdir -p $(SW_PART_DIR)
	cd $(SW_PART_DIR) && $(VLT_DEV) \
	    --cc --mmpi-o1 --d1 --top-module testharness \
	    --mmpi-partition-module $(SW_CLUSTER_MODULE) \
	    -exe $(TB_BIN_CC) \
	    -f $(FLIST) \
	    --timing --unroll-count 1024 $(VLT_WARN) --Mdir Vmdir \
	    2>&1 | tee partition.log
	@grep -E "Found [0-9]+ partition instances" $(SW_PART_DIR)/partition.log || true

build-sw-sys: partition-sw
	@echo "[mmpi-sw] Verilating rank-0 (testharness, clusters stubbed) -- this takes several minutes"
	cd $(SW_PART_DIR) && $(VLT_DEV) --Mdir Vmdir_sys -f $(SW_MMPI_DIR)/flist.system \
	    --timing --unroll-count 1024 $(VLT_WARN) -j 4 --cc --build --top-module testharness
	@echo "[mmpi-sw] Compiling rank-0 glue (rank0_tb_main.cc + verilator_lib.cc + metro_mpi.cpp)"
	cd $(SW_PART_DIR) && mpic++ -std=gnu++20 -fcoroutines -pthread \
	    -I Vmdir_sys -I $(VLT_ROOT)/include -I $(VLT_ROOT)/include/vltstd \
	    -I $(WORK_VLT_DIR)/riscv-isa-sim/include -I $(SNITCH_TEST_DIR) \
	    -I $(SIM_DIR)/test -I $(SIM_DIR)/test/uartdpi -I $(SW_MMPI_DIR) \
	    -c $(SNITCH_TEST_DIR)/verilator_lib.cc $(OCCAMY)/rank0_tb_main.cc $(SW_MMPI_DIR)/metro_mpi.cpp
	@echo "[mmpi-sw] Linking bin/occamy_top.mpi.vlt"
	mkdir -p $(SW_PART_DIR)/bin
	cd $(SW_PART_DIR) && mpic++ -std=gnu++20 -L $(WORK_VLT_DIR)/lib \
	    -o bin/occamy_top.mpi.vlt \
	    rank0_tb_main.o verilator_lib.o metro_mpi.o \
	    $(WORK_VLT_DIR)/tb/common_lib.o $(WORK_VLT_DIR)/tb/ipc.o \
	    $(WORK_VLT_DIR)/tb/bootrom.o $(WORK_VLT_DIR)/tb/bootdata.o \
	    $(WORK_VLT_DIR)/tb/uartdpi.o \
	    $(WORK_VLT_DIR)/vlt/verilated.o $(WORK_VLT_DIR)/vlt/verilated_dpi.o \
	    $(WORK_VLT_DIR)/vlt/verilated_threads.o $(WORK_VLT_DIR)/vlt/verilated_timing.o \
	    $(WORK_VLT_DIR)/vlt/verilated_vcd_c.o \
	    Vmdir_sys/Vtestharness__ALL.a -lfesvr -lpthread -lsodium

build-sw-lib: partition-sw
	@echo "[mmpi-sw] Verilating + linking the cluster partition (ranks 1..4)"
	cd $(SW_MMPI_DIR) && $(VLT_DEV) --cc --exe --Mdir obj_dir_lib \
	    --top-module $(SW_CLUSTER_MODULE) \
	    $(SW_CLUSTER_MODULE)_main.cpp metro_mpi.cpp -f flist.library \
	    --timing --unroll-count 1024 $(VLT_WARN) \
	    -CFLAGS "-I$(SW_MMPI_DIR) -std=gnu++20 -fcoroutines"
	$(MAKE) -C $(SW_MMPI_DIR)/obj_dir_lib -j6 -f V$(SW_CLUSTER_MODULE).mk \
	    CXX=mpic++ LINK=mpic++ LDLIBS=-lsodium

build-sw: build-sw-sys build-sw-lib

# ELF defaults to hello_world (host-only, no toolchain args needed to build software offload apps).
# Run from SIM_DIR (not SW_PART_DIR): the testbench binary looks up bootrom/test
# assets by a path relative to target/sim/, the same convention as the plain
# (non-partitioned) bin/occamy_top.vlt documented in OCCAMY_RUN_SIMULATION.md.
ELF ?= sw/host/apps/hello_world/build/hello_world.part.elf
run-sw:
	@test -f "$(SIM_DIR)/$(ELF)" || (echo "[mmpi-sw] $(SIM_DIR)/$(ELF) not found -- build it first: make -C target/sim CFG_OVERRIDE=$(CFG) DEBUG=ON sw" && exit 1)
	cd $(SIM_DIR) && mpirun \
	    -np 1 work-$(CFG_NAME)-sw-partition/bin/occamy_top.mpi.vlt $(ELF) \
	    $(foreach r,$(shell seq 1 $(MPI_NP_PARTITIONS)),: -np 1 work-$(CFG_NAME)-sw-partition/metro_mpi/obj_dir_lib/V$(SW_CLUSTER_MODULE)) \
	    2>&1 | tee $(SW_PART_DIR)/run.log
	@echo "[mmpi-sw] uart0.log:"; cat $(SIM_DIR)/uart0.log 2>/dev/null || echo "(not found -- check run.log)"

clean:
	rm -rf $(FLIST_DIR) $(PART_DIR) $(SW_PART_DIR)
